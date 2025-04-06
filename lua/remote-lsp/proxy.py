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
import select

# Set up logging
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

# Global flag
shutdown_requested = False

def replace_uris(data, pattern, replacement, remote, protocol):
    """Replace URIs within a string without parsing JSON"""
    if not isinstance(data, str):
        return data

    # Simple pattern-based replacement for URIs
    if pattern.startswith(protocol):
        # Replace protocol://host/path with file:///path
        data = data.replace(f'"{pattern}', '"file:///')
    else:
        # Replace file:///path with protocol://host/path
        data = data.replace('"file:///', f'"{pattern}')

    return data

def handle_stream(name, in_stream, out_stream, pattern, replacement, remote, protocol):
    """Process data between streams with more robust error handling"""
    logging.info(f"Starting {name} handler")

    buffer = b''
    headers = {}
    content_length = None

    # Set streams to non-blocking mode if possible
    if hasattr(in_stream, 'fileno'):
        try:
            import fcntl
            fd = in_stream.fileno()
            fl = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
        except (ImportError, AttributeError, OSError):
            pass

    while not shutdown_requested:
        try:
            # Use select to check if input is available
            if hasattr(in_stream, 'fileno'):
                ready, _, _ = select.select([in_stream], [], [], 0.1)
                if not ready:
                    continue

            # Reading header
            if content_length is None:
                chunk = in_stream.read(1)
                if not chunk:
                    logging.info(f"{name} - Input stream closed")
                    return

                buffer += chunk

                # Look for end of headers
                if b'\r\n\r\n' in buffer:
                    header_part, buffer = buffer.split(b'\r\n\r\n', 1)
                    header_lines = header_part.split(b'\r\n')

                    # Parse headers
                    for line in header_lines:
                        if b':' in line:
                            key, value = line.split(b':', 1)
                            headers[key.strip().lower()] = value.strip()

                    # Get content length
                    if b'content-length' in headers:
                        content_length = int(headers[b'content-length'])
                        logging.debug(f"{name} - Got content length: {content_length}")
                    else:
                        logging.error(f"{name} - No content length in headers")
                        headers = {}
                        buffer = b''
                        continue

            # Reading content
            elif len(buffer) < content_length:
                try:
                    # Try to read remaining content
                    bytes_to_read = min(4096, content_length - len(buffer))
                    chunk = in_stream.read(bytes_to_read)

                    if not chunk:
                        logging.info(f"{name} - Input stream closed during content read")
                        return

                    buffer += chunk
                except Exception as e:
                    logging.error(f"{name} - Error reading content: {e}")
                    content_length = None
                    headers = {}
                    buffer = b''
                    continue

            # Process complete message
            else:
                try:
                    content = buffer[:content_length]
                    buffer = buffer[content_length:]
                    content_str = content.decode('utf-8')

                    # Simple string replacement instead of JSON parsing
                    if ('"uri":"' in content_str or '"rootUri":"' in content_str or
                        '"workspaceFolders":[' in content_str):
                        modified_str = replace_uris(content_str, pattern, replacement, remote, protocol)
                        if modified_str != content_str:
                            logging.debug(f"{name} - Replaced URIs in message")
                            content_str = modified_str

                    # Send to output stream
                    out_header = f"Content-Length: {len(content_str)}\r\n\r\n"
                    out_stream.write(out_header.encode('utf-8'))
                    out_stream.write(content_str.encode('utf-8'))
                    out_stream.flush()

                    # Reset for next message
                    content_length = None
                    headers = {}

                except Exception as e:
                    logging.error(f"{name} - Error processing message: {e}")
                    traceback.print_exc()
                    content_length = None
                    headers = {}
                    buffer = b''
                    continue

        except (BrokenPipeError, ConnectionError, OSError) as e:
            logging.error(f"{name} - Pipe/connection error: {e}")
            return
        except Exception as e:
            logging.error(f"{name} - Unexpected error: {e}")
            traceback.print_exc()
            return

    logging.info(f"{name} - Thread exiting normally")

def log_stderr(process):
    """Log stderr output from the process"""
    while not shutdown_requested:
        try:
            line = process.stderr.readline()
            if not line:
                break
            logging.error(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}")
        except Exception:
            break
    logging.info("stderr logger thread exiting")

def signal_handler(sig, frame):
    global shutdown_requested
    logging.info(f"Received signal {sig}, initiating shutdown")
    shutdown_requested = True

def main():
    global shutdown_requested

    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Parse arguments
    if len(sys.argv) < 4:
        logging.error("Usage: proxy.py <user@remote> <protocol> <lsp_command> [args...]")
        sys.exit(1)

    remote = sys.argv[1]
    protocol = sys.argv[2]
    lsp_command = sys.argv[3:]

    logging.info(f"Starting proxy for {remote} using protocol {protocol} with command: {' '.join(lsp_command)}")

    # Start SSH process
    cmd = ["ssh", "-q", remote, " ".join(lsp_command)]
    logging.info(f"Executing: {' '.join(cmd)}")

    try:
        ssh_process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )
    except Exception as e:
        logging.error(f"Failed to start SSH process: {e}")
        traceback.print_exc()
        sys.exit(1)

    # Start stderr logger
    stderr_thread = threading.Thread(target=log_stderr, args=(ssh_process,))
    stderr_thread.daemon = True
    stderr_thread.start()

    # URI patterns
    incoming_pattern = f"{protocol}://{remote}/"  # neovim to ssh
    outgoing_pattern = "file:///"                 # ssh to neovim

    # Start I/O threads
    t1 = threading.Thread(
        target=handle_stream,
        args=("neovim to ssh", sys.stdin.buffer, ssh_process.stdin,
              incoming_pattern, outgoing_pattern, remote, protocol)
    )

    t2 = threading.Thread(
        target=handle_stream,
        args=("ssh to neovim", ssh_process.stdout, sys.stdout.buffer,
              outgoing_pattern, incoming_pattern, remote, protocol)
    )

    t1.daemon = False
    t2.daemon = False
    t1.start()
    t2.start()

    try:
        # Monitor process
        while not shutdown_requested and ssh_process.poll() is None:
            time.sleep(0.1)

        if ssh_process.poll() is not None:
            logging.info(f"SSH process exited with code {ssh_process.returncode}")
            shutdown_requested = True
    except Exception as e:
        logging.error(f"Error in main loop: {e}")
        shutdown_requested = True
    finally:
        # Clean up
        shutdown_requested = True

        if ssh_process.poll() is None:
            try:
                logging.info("Terminating SSH process...")
                ssh_process.terminate()
                ssh_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                ssh_process.kill()
            except Exception:
                logging.error("Error terminating SSH process", exc_info=True)

        logging.info("Waiting for threads to exit...")
        t1.join(timeout=2)
        t2.join(timeout=2)

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
        traceback.print_exc()
        sys.exit(1)
