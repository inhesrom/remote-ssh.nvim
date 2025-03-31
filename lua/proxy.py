#!/usr/bin/env python3

import json
import subprocess
import sys
import threading
import logging
import datetime
import time
import os
import traceback
import signal
import re

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
        protocol_prefix = f"file://{protocol}://{remote}/"

        if obj.startswith(protocol_prefix):
            new_uri = "file://" + obj[len(protocol_prefix):]
            logging.debug(f"Fixing URI: {obj} -> {new_uri}")
            return new_uri
        elif obj.startswith(pattern):
            logging.debug(f"Replacing URI: {obj} -> {replacement + obj[len(pattern):]}")
            return replacement + obj[len(pattern):]
    if isinstance(obj, dict):
        return {k: replace_uris(v, pattern, replacement, remote, protocol) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, pattern, replacement, remote, protocol) for item in obj]
    return obj

class LSPMessageParser:
    """Parser for LSP messages with proper buffering."""

    def __init__(self, stream_name):
        self.stream_name = stream_name
        self.buffer = b""
        self.reset_state()

    def reset_state(self):
        """Reset parser state for a new message."""
        self.content_length = None
        self.content_type = "utf-8"  # Default content type
        self.headers_complete = False

    def feed(self, data):
        """Feed data into the buffer and try to extract messages."""
        if data:
            self.buffer += data

        messages = []
        while not shutdown_requested:
            # If we're at the beginning of a message, parse headers
            if not self.headers_complete:
                # Check if we have a complete header section
                header_end = self.buffer.find(b"\r\n\r\n")
                if header_end == -1:
                    # Incomplete headers, need more data
                    break

                # Extract and parse headers
                header_section = self.buffer[:header_end]
                self.buffer = self.buffer[header_end + 4:]  # +4 for "\r\n\r\n"

                # Parse headers
                headers = header_section.split(b"\r\n")
                for header in headers:
                    if header.startswith(b"Content-Length:"):
                        try:
                            self.content_length = int(header.split(b":")[1].strip())
                        except (ValueError, IndexError) as e:
                            logging.error(f"{self.stream_name} - Failed to parse Content-Length: {e}")
                            self.reset_state()
                            break
                    elif header.startswith(b"Content-Type:"):
                        content_type = header.split(b":")[1].strip().decode("ascii", errors="ignore")
                        if "charset=" in content_type:
                            charset = content_type.split("charset=")[1].strip()
                            self.content_type = charset

                if self.content_length is None:
                    logging.error(f"{self.stream_name} - No valid Content-Length header found")
                    # Skip this malformed message attempt
                    self.reset_state()
                    # Try to resync by looking for the next potential header
                    next_header = self.buffer.find(b"Content-Length:")
                    if next_header > 0:
                        self.buffer = self.buffer[next_header:]
                    continue

                self.headers_complete = True

            # If we have complete headers, check if we have enough data for the message content
            if len(self.buffer) < self.content_length:
                # Not enough data yet
                break

            # We have a complete message, extract it
            content = self.buffer[:self.content_length]
            self.buffer = self.buffer[self.content_length:]

            try:
                # Decode content using the specified content type
                content_str = content.decode(self.content_type)

                # Extract the message
                messages.append(content_str)

            except UnicodeDecodeError as e:
                logging.error(f"{self.stream_name} - Failed to decode message: {e}")
                logging.error(f"Raw content: {content[:100]}...")
            except Exception as e:
                logging.error(f"{self.stream_name} - Error processing message content: {e}")

            # Reset for the next message
            self.reset_state()

            # If buffer is empty, no need to continue
            if not self.buffer:
                break

        return messages

def handle_stream(stream_name, input_stream, output_stream, pattern, replacement, remote, protocol):
    """
    Read LSP messages from input_stream, replace URIs, and write to output_stream.
    Improved with proper buffering and error handling.
    """
    global shutdown_requested

    reconnect_attempts = 0
    max_reconnect_attempts = 10
    backoff_time = 0.1

    logging.info(f"Starting {stream_name} handler")

    # Create message parser
    parser = LSPMessageParser(stream_name)

    while not shutdown_requested:
        try:
            # Try to read data from the input stream
            try:
                data = input_stream.read(4096)  # Read in reasonably sized chunks
                if data:
                    logging.debug(f"{stream_name} - Raw data received: {data[:100].hex()}")
                if not data:
                    # End of stream
                    if reconnect_attempts >= max_reconnect_attempts:
                        logging.info(f"{stream_name} - Stream closed and max reconnect attempts reached")
                        break
                    else:
                        logging.info(f"{stream_name} - Stream appears closed, attempt {reconnect_attempts+1}/{max_reconnect_attempts}")
                        time.sleep(backoff_time)
                        reconnect_attempts += 1
                        backoff_time = min(backoff_time * 1.5, 5.0)  # Exponential backoff, max 5 seconds
                        continue
                else:
                    # Reset reconnect counter on successful read
                    reconnect_attempts = 0
                    backoff_time = 0.1
            except (IOError, ValueError) as e:
                logging.error(f"{stream_name} - Error reading from stream: {e}")
                if reconnect_attempts >= max_reconnect_attempts:
                    break
                else:
                    time.sleep(backoff_time)
                    reconnect_attempts += 1
                    backoff_time = min(backoff_time * 1.5, 5.0)
                    continue

            # Process incoming data
            messages = parser.feed(data)

            # Process each complete message
            for content_str in messages:
                logging.debug(f"{stream_name} - Received message: {content_str[:200]}...")

                try:
                    # Parse JSON
                    message = json.loads(content_str)

                    # Check for shutdown/exit messages
                    if stream_name == "neovim to ssh":
                        if message.get("method") == "shutdown":
                            logging.info("Shutdown message detected")
                        elif message.get("method") == "exit":
                            logging.info("Exit message detected, will terminate after processing")
                            shutdown_requested = True

                    # Replace URIs
                    message = replace_uris(message, pattern, replacement, remote, protocol)

                    # Serialize back to JSON
                    new_content = json.dumps(message)

                    # Send with new Content-Length
                    try:
                        header = f"Content-Length: {len(new_content.encode('utf-8'))}\r\n\r\n"
                        output_stream.write(header.encode('utf-8'))
                        output_stream.write(new_content.encode('utf-8'))
                        output_stream.flush()
                        logging.debug(f"{stream_name} - Sent: {new_content[:200]}...")
                    except (IOError, ValueError) as e:
                        logging.error(f"{stream_name} - Error writing to output: {e}")
                        return

                except json.JSONDecodeError as e:
                    logging.error(f"{stream_name} - JSON decode error: {e}")
                    logging.error(f"Raw content: {content_str[:200]}...")
                except Exception as e:
                    logging.error(f"{stream_name} - Error processing message: {e}")
                    logging.error(traceback.format_exc())

        except BrokenPipeError:
            logging.error(f"{stream_name} - Broken pipe error: Connection may have closed.")
            return
        except Exception as e:
            logging.error(f"{stream_name} - Error in handle_stream: {e}")
            logging.error(traceback.format_exc())
            time.sleep(1)  # Brief pause to avoid tight error loops

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
        cmd = ["ssh", "-q", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", remote, " ".join(lsp_command)]
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
