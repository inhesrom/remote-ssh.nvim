#!/usr/bin/env python3

import json
import subprocess
import sys
import threading
import logging
import datetime
import os
import traceback
import signal
import time

# Set up logging to both file and stderr
timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
log_dir = os.path.expanduser("~/.cache/nvim/remote_lsp_logs")
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, f'proxy_log_{timestamp}.log')

logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stderr)
    ]
)

# Global flag to signal threads to exit
shutdown_requested = False

def replace_uris(obj, pattern, replacement, remote, protocol):
    """Replace URIs in JSON objects to handle the translation between local and remote paths."""
    if isinstance(obj, str):
        # When sending to SSH server (neovim to ssh): rsync://host/path -> file:///path
        if pattern.startswith(protocol) and obj.startswith(pattern):
            # Extract just the path part (after the host)
            parts = obj.split('/')
            path_index = 0
            for i, part in enumerate(parts):
                if part == remote:
                    path_index = i + 1
                    break

            path = '/' + '/'.join(parts[path_index:])
            new_uri = "file://" + path  # This becomes file:///path
            logging.debug(f"Replacing URI (neovim to ssh): {obj} -> {new_uri}")
            return new_uri

        # When sending to Neovim (ssh to neovim): file:///path -> rsync://host/path
        elif pattern.startswith("file://") and obj.startswith(pattern):
            path = obj[len("file://"):]  # Remove file:// prefix
            new_uri = f"{protocol}://{remote}{path}"
            logging.debug(f"Replacing URI (ssh to neovim): {obj} -> {new_uri}")
            return new_uri

    if isinstance(obj, dict):
        return {k: replace_uris(v, pattern, replacement, remote, protocol) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, pattern, replacement, remote, protocol) for item in obj]
    return obj

def handle_stream(stream_name, input_stream, output_stream, pattern, replacement, remote, protocol):
    """
    Read LSP messages from input_stream, replace URIs, and write to output_stream.
    """
    global shutdown_requested

    logging.info(f"Starting {stream_name} handler")

    while not shutdown_requested:
        try:
            # Check if stream is closed
            if hasattr(input_stream, 'peek'):
                try:
                    peek_result = input_stream.peek(1)
                    if not peek_result:
                        logging.info(f"{stream_name} - Input stream appears closed (peek returned empty)")
                        break
                except (IOError, ValueError) as e:
                    logging.info(f"{stream_name} - Input stream appears closed: {e}")
                    break

            # Read Content-Length header with timeout protection
            header = b""
            header_timeout = time.time() + 5  # 5 second timeout for header

            while not shutdown_requested and time.time() < header_timeout:
                try:
                    # Read with timeout
                    byte = input_stream.read(1)
                    if not byte:
                        logging.info(f"{stream_name} - Input stream closed during header read.")
                        return

                    header += byte
                    if header.endswith(b"\r\n\r\n"):
                        break
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error reading header: {e}")
                    return

            if not header.endswith(b"\r\n\r\n"):
                logging.error(f"{stream_name} - Timeout or invalid header format: {header}")
                return

            # Parse Content-Length
            content_length = None
            for line in header.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    try:
                        content_length = int(line.split(b":", 1)[1].strip())
                        break
                    except (ValueError, IndexError) as e:
                        logging.error(f"{stream_name} - Failed to parse Content-Length: {e}")

            if content_length is None:
                logging.error(f"{stream_name} - No valid Content-Length header found")
                continue

            # Read content with timeout protection
            content = b""
            content_timeout = time.time() + 5  # 5 second timeout for content

            while len(content) < content_length and not shutdown_requested and time.time() < content_timeout:
                try:
                    # Calculate how much to read at once (up to 4KB chunks)
                    bytes_to_read = min(content_length - len(content), 4096)
                    chunk = input_stream.read(bytes_to_read)

                    if not chunk:
                        logging.info(f"{stream_name} - Input stream closed during content read after {len(content)}/{content_length} bytes.")
                        return
                    content += chunk
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error reading content: {e}")
                    return

            if len(content) < content_length:
                logging.error(f"{stream_name} - Timeout or incomplete content: got {len(content)}/{content_length} bytes")
                return

            # Log when we get a complete message
            logging.debug(f"{stream_name} - Received complete message ({content_length} bytes)")

            try:
                # Decode content
                content_str = content.decode('utf-8')

                # Special logging for certain messages
                if '"method":"initialize"' in content_str:
                    logging.info(f"{stream_name} - INITIALIZE REQUEST: {content_str[:200]}...")
                elif '"id":1' in content_str and '"result"' in content_str:
                    logging.info(f"{stream_name} - INITIALIZE RESPONSE: {content_str[:200]}...")
                elif '"method":"initialized"' in content_str:
                    logging.info(f"{stream_name} - INITIALIZED NOTIFICATION: {content_str[:200]}...")
                elif '"method":"textDocument/hover"' in content_str:
                    logging.info(f"{stream_name} - HOVER REQUEST: {content_str[:200]}...")
                elif '"method":"textDocument/definition"' in content_str:
                    logging.info(f"{stream_name} - DEFINITION REQUEST: {content_str[:200]}...")

                # Parse JSON
                message = json.loads(content_str)

                # Check for shutdown/exit messages
                if stream_name == "neovim to ssh":
                    if message.get("method") == "shutdown":
                        logging.info("Shutdown message detected")
                    elif message.get("method") == "exit":
                        logging.info("Exit message detected, will terminate after processing")
                        shutdown_requested = True

                # Special handling for initialize message from neovim to ssh
                if stream_name == "neovim to ssh" and isinstance(message, dict) and message.get("method") == "initialize":
                    params = message.get("params", {})

                    # Fix rootUri
                    if "rootUri" in params and isinstance(params["rootUri"], str):
                        if params["rootUri"].startswith(f"file://{protocol}://{remote}/"):
                            params["rootUri"] = "file:///" + params["rootUri"].split("/", 6)[-1]
                            logging.info(f"Fixed rootUri: {params['rootUri']}")

                    # Fix rootPath
                    if "rootPath" in params and isinstance(params["rootPath"], str):
                        if params["rootPath"].startswith(f"{protocol}://{remote}/"):
                            params["rootPath"] = "/" + params["rootPath"].split("/", 4)[-1]
                            logging.info(f"Fixed rootPath: {params['rootPath']}")

                    # Fix workspaceFolders
                    if "workspaceFolders" in params and isinstance(params["workspaceFolders"], list):
                        for folder in params["workspaceFolders"]:
                            if "uri" in folder and isinstance(folder["uri"], str):
                                uri = folder["uri"]
                                if uri.startswith(f"file://{protocol}://{remote}/"):
                                    folder["uri"] = "file:///" + uri.split("/", 6)[-1]
                                    logging.info(f"Fixed workspace folder URI: {folder['uri']}")
                else:
                    # Replace URIs in all other messages
                    message = replace_uris(message, pattern, replacement, remote, protocol)

                # Serialize back to JSON
                new_content = json.dumps(message)

                # Send with new Content-Length
                try:
                    header = f"Content-Length: {len(new_content)}\r\n\r\n"
                    output_stream.write(header.encode('utf-8'))
                    output_stream.write(new_content.encode('utf-8'))
                    output_stream.flush()
                    logging.debug(f"{stream_name} - Sent message ({len(new_content)} bytes)")
                except (IOError, ValueError, BrokenPipeError) as e:
                    logging.error(f"{stream_name} - Error writing to output: {e}")
                    return

            except json.JSONDecodeError as e:
                logging.error(f"{stream_name} - JSON decode error: {e}")
                logging.error(f"Raw content: {content[:100]}...")
            except Exception as e:
                logging.error(f"{stream_name} - Error processing message: {e}")
                logging.error(traceback.format_exc())

        except BrokenPipeError:
            logging.error(f"{stream_name} - Broken pipe error: connection may have closed.")
            return
        except Exception as e:
            logging.error(f"{stream_name} - Error in handle_stream: {e}")
            logging.error(traceback.format_exc())
            return

    logging.info(f"{stream_name} - Thread exiting normally")

def signal_handler(sig, frame):
    """Handle interrupt signals to ensure clean shutdown"""
    global shutdown_requested
    logging.info(f"Received signal {sig}, initiating shutdown")
    shutdown_requested = True

def log_stderr_thread(process):
    global shutdown_requested

    while not shutdown_requested:
        try:
            line = process.stderr.readline()
            if not line:
                break
            error_text = line.decode('utf-8', errors='replace').strip()
            logging.error(f"LSP stderr: {error_text}")

            # Log any "command not found" errors clearly
            if "command not found" in error_text or "No such file" in error_text:
                logging.error(f"LANGUAGE SERVER ERROR: {error_text}")

        except (IOError, ValueError):
            break

    logging.info("stderr logger thread exiting")

def neovim_to_ssh_thread(input_stream, output_stream, pattern, replacement, remote, protocol):
    global shutdown_requested

    handle_stream("neovim to ssh", input_stream, output_stream, pattern, replacement, remote, protocol)
    logging.info("neovim_to_ssh thread exiting")

    # When this thread exits, signal the other thread to exit
    shutdown_requested = True

def ssh_to_neovim_thread(input_stream, output_stream, pattern, replacement, remote, protocol):
    global shutdown_requested

    handle_stream("ssh to neovim", input_stream, output_stream, pattern, replacement, remote, protocol)
    logging.info("ssh_to_neovim thread exiting")

    # When this thread exits, signal the other thread to exit
    shutdown_requested = True

def main():
    global shutdown_requested

    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    if len(sys.argv) < 4:
        logging.error("Usage: proxy.py <user@remote> <protocol> <lsp_command> [args...]")
        sys.exit(1)

    remote = sys.argv[1]
    protocol = sys.argv[2]
    lsp_command = sys.argv[3:]

    if protocol not in ["scp", "rsync"]:
        logging.error(f"Unsupported protocol: {protocol}. Must be 'scp' or 'rsync'")
        sys.exit(1)

    logging.info(f"Starting proxy for {remote} using protocol {protocol} with command: {' '.join(lsp_command)}")

    # Start SSH process to run the specified LSP server remotely
    try:
        cmd = ["ssh", "-q", remote, " ".join(lsp_command)]
        logging.info(f"Executing: {' '.join(cmd)}")

        ssh_process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )

        # Start stderr logging thread
        stderr_thread = threading.Thread(target=log_stderr_thread, args=(ssh_process,))
        stderr_thread.daemon = True
        stderr_thread.start()

    except Exception as e:
        logging.error(f"Failed to start SSH process: {e}")
        logging.error(traceback.format_exc())
        sys.exit(1)

    # Patterns for URI replacement
    incoming_pattern = f"{protocol}://{remote}/"  # From Neovim
    incoming_replacement = "file://"              # To LSP server
    outgoing_pattern = "file://"                  # From LSP server
    outgoing_replacement = f"{protocol}://{remote}/"  # To Neovim

    # Create I/O threads using their dedicated functions
    t1 = threading.Thread(
        target=neovim_to_ssh_thread,
        args=(sys.stdin.buffer, ssh_process.stdin, incoming_pattern, incoming_replacement, remote, protocol)
    )

    t2 = threading.Thread(
        target=ssh_to_neovim_thread,
        args=(ssh_process.stdout, sys.stdout.buffer, outgoing_pattern, outgoing_replacement, remote, protocol)
    )

    # Don't use daemon threads - we want to join them properly
    t1.daemon = False
    t2.daemon = False

    t1.start()
    t2.start()

    try:
        # Wait for process to finish or shutdown to be requested
        while not shutdown_requested and ssh_process.poll() is None:
            try:
                ssh_process.wait(timeout=0.1)  # Short timeout to check shutdown flag frequently
            except subprocess.TimeoutExpired:
                # This is expected due to the short timeout
                pass

        if ssh_process.poll() is not None:
            logging.info(f"SSH process exited with code {ssh_process.returncode}")
            shutdown_requested = True

    except KeyboardInterrupt:
        logging.info("Received keyboard interrupt, terminating...")
        shutdown_requested = True
    except Exception as e:
        logging.error(f"Error in main loop: {e}")
        logging.error(traceback.format_exc())
        shutdown_requested = True
    finally:
        # Clean up process if still running
        if ssh_process.poll() is None:
            try:
                logging.info("Terminating SSH process...")
                ssh_process.terminate()
                try:
                    ssh_process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    logging.info("SSH process didn't terminate, killing...")
                    ssh_process.kill()
            except:
                logging.error("Error terminating SSH process", exc_info=True)

        # Set shutdown flag to ensure threads exit
        shutdown_requested = True

        # Wait for threads to complete with timeout
        logging.info("Waiting for threads to exit...")
        t1.join(timeout=2)
        t2.join(timeout=2)

        # Check if threads are still alive
        if t1.is_alive() or t2.is_alive():
            logging.warning("Some threads didn't exit cleanly")
        else:
            logging.info("All threads exited cleanly")

        logging.info("Proxy terminated")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logging.error(f"Unhandled exception in main: {e}")
        logging.error(traceback.format_exc())
        sys.exit(1)
