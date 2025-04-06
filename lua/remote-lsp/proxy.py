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
        # Handle case where URI starts with file:// followed by protocol://remote/
        if obj.startswith(f"file://{protocol}://{remote}/"):
            new_uri = "file:///" + obj.split("/", 6)[-1]
            logging.debug(f"Fixed double-protocol URI: {obj} -> {new_uri}")
            return new_uri
        # Standard case: replace protocol://remote/ with file:///
        elif obj.startswith(pattern):
            new_uri = replacement + obj[len(pattern):]
            logging.debug(f"Replacing URI: {obj} -> {new_uri}")
            return new_uri
        # Reverse case: replace file:/// with protocol://remote/
        elif replacement.startswith("file://") and obj.startswith("file:///"):
            new_uri = pattern + obj[8:]  # 8 is len("file:///")
            logging.debug(f"Reverse replacing URI: {obj} -> {new_uri}")
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
            # Read Content-Length header
            header = b""
            while not shutdown_requested:
                byte = input_stream.read(1)
                if not byte:
                    logging.info(f"{stream_name} - Input stream closed.")
                    return
                header += byte
                if header.endswith(b"\r\n\r\n"):
                    break

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

            # Read content
            content = b""
            while len(content) < content_length and not shutdown_requested:
                chunk = input_stream.read(content_length - len(content))
                if not chunk:
                    logging.info(f"{stream_name} - Input stream closed during content read.")
                    return
                content += chunk

            # Log when we get a complete message
            logging.debug(f"{stream_name} - Received complete message ({content_length} bytes)")

            try:
                # Decode content
                content_str = content.decode('utf-8')

                # Special logging for initialize messages
                if '"method":"initialize"' in content_str:
                    logging.info(f"{stream_name} - INITIALIZE REQUEST: {content_str[:200]}...")
                elif '"id":1' in content_str and '"result"' in content_str:
                    logging.info(f"{stream_name} - INITIALIZE RESPONSE: {content_str[:200]}...")
                elif '"method":"initialized"' in content_str:
                    logging.info(f"{stream_name} - INITIALIZED NOTIFICATION: {content_str[:200]}...")

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
                    # Standard URI replacement for all other messages
                    message = replace_uris(message, pattern, replacement, remote, protocol)

                # Serialize back to JSON
                new_content = json.dumps(message)

                # Send with new Content-Length
                header = f"Content-Length: {len(new_content)}\r\n\r\n"
                output_stream.write(header.encode('utf-8'))
                output_stream.write(new_content.encode('utf-8'))
                output_stream.flush()
                logging.debug(f"{stream_name} - Sent message ({len(new_content)} bytes)")

            except json.JSONDecodeError as e:
                logging.error(f"{stream_name} - JSON decode error: {e}")
                logging.error(f"Raw content: {content[:100]}...")
            except Exception as e:
                logging.error(f"{stream_name} - Error processing message: {e}")
                logging.error(traceback.format_exc())

        except BrokenPipeError:
            logging.error(f"{stream_name} - Broken pipe error: SSH connection may have closed.")
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
