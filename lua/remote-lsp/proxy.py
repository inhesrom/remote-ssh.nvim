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
    level=logging.DEBUG,  # Changed from INFO to DEBUG for more verbose logging
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stderr)
    ]
)

# Global flag to signal threads to exit
shutdown_requested = False

def deep_replace_uris(obj, pattern, replacement, stream_name):
    """Recursively replace URIs in a complex object structure"""
    if isinstance(obj, str):
        if obj.startswith(pattern):
            new_uri = replacement + obj[len(pattern):]
            logging.debug(f"{stream_name} - Replacing URI: {obj} -> {new_uri}")
            return new_uri
        return obj

    if isinstance(obj, dict):
        for key, value in obj.items():
            new_value = deep_replace_uris(value, pattern, replacement, stream_name)
            if new_value is not value:  # Only update if something changed
                obj[key] = new_value

            # Special handling for textDocument URIs
            if key == "textDocument" and isinstance(value, dict) and "uri" in value:
                uri = value["uri"]
                if uri.startswith(pattern):
                    value["uri"] = replacement + uri[len(pattern):]
                    logging.info(f"{stream_name} - Replaced textDocument URI: {uri} -> {value['uri']}")

    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            new_item = deep_replace_uris(item, pattern, replacement, stream_name)
            if new_item is not item:  # Only update if something changed
                obj[i] = new_item

    return obj

def handle_stream(stream_name, input_stream, output_stream, pattern, replacement, remote, protocol):
    """
    Read LSP messages from input_stream, replace URIs, and write to output_stream.
    Uses a buffered approach to handle messages that may be sent in chunks.
    """
    global shutdown_requested

    logging.info(f"Starting {stream_name} handler")

    buffer = b""
    parsing_headers = True
    content_length = None

    while not shutdown_requested:
        try:
            # Read some data into the buffer
            chunk = input_stream.read(4096)  # Read a chunk of data
            if not chunk:
                logging.info(f"{stream_name} - Input stream closed during read")
                break

            buffer += chunk
            logging.debug(f"{stream_name} - Read {len(chunk)} bytes, buffer now {len(buffer)} bytes")

            # Process as many complete messages as possible
            while buffer and not shutdown_requested:
                # If we're parsing headers, look for the end of headers marker
                if parsing_headers:
                    header_end = buffer.find(b"\r\n\r\n")
                    if header_end == -1:
                        # We don't have complete headers yet, read more data
                        break

                    # Extract and parse headers
                    header_data = buffer[:header_end]
                    buffer = buffer[header_end + 4:]  # Skip the "\r\n\r\n"
                    logging.debug(f"{stream_name} - Parsed headers: {header_data}")

                    # Parse Content-Length header
                    content_length = None
                    for line in header_data.split(b"\r\n"):
                        if line.lower().startswith(b"content-length:"):
                            try:
                                content_length = int(line.split(b":", 1)[1].strip())
                                logging.debug(f"{stream_name} - Content-Length: {content_length}")
                            except (ValueError, IndexError) as e:
                                logging.error(f"{stream_name} - Failed to parse Content-Length: {e}")

                    if content_length is None:
                        logging.error(f"{stream_name} - No valid Content-Length header found")
                        # Reset and try again with next message
                        parsing_headers = True
                        continue

                    # Switch to parsing content
                    parsing_headers = False

                # If we're parsing content, check if we have enough data
                elif len(buffer) >= content_length:
                    # We have a complete message
                    content = buffer[:content_length]
                    buffer = buffer[content_length:]  # Remove processed content from buffer
                    logging.debug(f"{stream_name} - Have complete message of {content_length} bytes")

                    try:
                        # Decode content
                        content_str = content.decode('utf-8')

                        # For debugging specific messages
                        if '"method":"initialize"' in content_str or '"id":1' in content_str:
                            logging.info(f"{stream_name} - INITIALIZE MESSAGE: {content_str}")
                        elif '"method":"initialized"' in content_str:
                            logging.info(f"{stream_name} - INITIALIZED MESSAGE: {content_str}")
                        elif '"result"' in content_str and ('"id":1' in content_str):
                            logging.info(f"{stream_name} - INITIALIZE RESPONSE: {content_str}")

                        # Parse JSON
                        message = json.loads(content_str)

                        # Check for shutdown/exit messages
                        if stream_name == "neovim to ssh":
                            if message.get("method") == "shutdown":
                                logging.info("Shutdown message detected")
                            elif message.get("method") == "exit":
                                logging.info("Exit message detected, will terminate after processing")
                                shutdown_requested = True

                        # Replace URIs - we'll keep this simple to minimize transformation errors
                        if stream_name == "neovim to ssh":
                            # When sending to SSH server, replace rsync://host/ with file://
                            if isinstance(message, dict):
                                if "params" in message and isinstance(message["params"], dict):
                                    params = message["params"]

                                    # Fix root URI issues in initialize request
                                    if "rootUri" in params and isinstance(params["rootUri"], str):
                                        root_uri = params["rootUri"]
                                        if root_uri.startswith(f"file://{protocol}://{remote}/"):
                                            params["rootUri"] = "file:///" + root_uri.split("/", 6)[-1]
                                            logging.info(f"Fixed rootUri: {root_uri} -> {params['rootUri']}")

                                    # Fix root path issues
                                    if "rootPath" in params and isinstance(params["rootPath"], str):
                                        root_path = params["rootPath"]
                                        if root_path.startswith(f"{protocol}://{remote}/"):
                                            params["rootPath"] = "/" + root_path.split("/", 4)[-1]
                                            logging.info(f"Fixed rootPath: {root_path} -> {params['rootPath']}")

                                    # Fix workspace folders
                                    if "workspaceFolders" in params and isinstance(params["workspaceFolders"], list):
                                        for folder in params["workspaceFolders"]:
                                            if "uri" in folder and isinstance(folder["uri"], str):
                                                uri = folder["uri"]
                                                if uri.startswith(f"file://{protocol}://{remote}/"):
                                                    folder["uri"] = "file:///" + uri.split("/", 6)[-1]
                                                    logging.info(f"Fixed workspace folder URI: {uri} -> {folder['uri']}")
                        else:
                            # When sending to Neovim, replace file:// with rsync://host/
                            if isinstance(message, dict):
                                # Process textDocuments
                                deep_replace_uris(message, "file:///", f"{protocol}://{remote}/", stream_name)

                        # Serialize back to JSON
                        new_content = json.dumps(message)

                        # Send with new Content-Length
                        try:
                            header = f"Content-Length: {len(new_content)}\r\n\r\n"
                            output_stream.write(header.encode('utf-8'))
                            output_stream.write(new_content.encode('utf-8'))
                            output_stream.flush()
                            logging.debug(f"{stream_name} - Sent message ({len(new_content)} bytes)")

                        except (IOError, ValueError) as e:
                            logging.error(f"{stream_name} - Error writing to output: {e}")
                            return

                    except json.JSONDecodeError as e:
                        logging.error(f"{stream_name} - JSON decode error: {e}")
                        logging.error(f"Raw content: {content[:100]}...")
                    except Exception as e:
                        logging.error(f"{stream_name} - Error processing message: {e}")
                        logging.error(traceback.format_exc())

                    # Reset for next message
                    parsing_headers = True
                    content_length = None
                else:
                    # We don't have a complete message yet, read more data
                    logging.debug(f"{stream_name} - Need more data: have {len(buffer)}, need {content_length}")
                    break

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
            logging.error(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}")
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
