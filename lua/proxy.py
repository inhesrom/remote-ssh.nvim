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

# Set up logging to both file and stderr
timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
log_dir = os.path.expanduser("~/.cache/nvim/remote_lsp_logs")
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, f'proxy_log_{timestamp}.log')

logging.basicConfig(
    level=logging.DEBUG,  # Set to DEBUG to get maximum information
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

def handle_stream(stream_name, input_stream, output_stream, pattern, replacement, remote, protocol):
    """
    Read LSP messages from input_stream, replace URIs, and write to output_stream.
    """
    # Declare global variables at the START of the function
    global shutdown_requested

    logging.info(f"Starting {stream_name} handler")

    content_buffer = b""
    content_length = None

    # Check if the input stream supports peek
    can_peek = hasattr(input_stream, 'peek')

    while not shutdown_requested:
        try:
            # Check if stream is closed
            if can_peek:
                try:
                    peek_result = input_stream.peek(1)
                    if not peek_result:
                        logging.info(f"{stream_name} - Input stream appears closed (peek returned empty)")
                        break
                except (IOError, ValueError) as e:
                    logging.info(f"{stream_name} - Input stream appears closed: {e}")
                    break

            # Read Content-Length header
            header = b""
            header_timeout = time.time() + 30  # 30 second timeout
            consecutive_empty_reads = 0
            max_empty_reads = 5

            logging.debug(f"{stream_name} - Starting to read header")

            while not shutdown_requested:
                if time.time() > header_timeout:
                    logging.error(f"{stream_name} - Timeout reading header")
                    return

                try:
                    byte = input_stream.read(1)
                    if not byte:
                        consecutive_empty_reads += 1
                        logging.debug(f"{stream_name} - Empty read #{consecutive_empty_reads} while reading header")

                        if consecutive_empty_reads >= max_empty_reads:
                            logging.info(f"{stream_name} - Input stream closed during header read after {consecutive_empty_reads} empty reads")
                            return

                        time.sleep(0.1)  # Wait a bit before retrying
                        continue
                    else:
                        consecutive_empty_reads = 0  # Reset counter when we get data

                    header += byte
                    if header.endswith(b"\r\n\r\n"):
                        break
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error reading header: {e}")
                    logging.error(traceback.format_exc())
                    return

            logging.debug(f"{stream_name} - Finished reading header: {header[:50]}")

            # Parse Content-Length
            content_length = None
            for line in header.split(b"\r\n"):
                if line.startswith(b"Content-Length:"):
                    try:
                        content_length = int(line.split(b":")[1].strip())
                        break
                    except (ValueError, IndexError) as e:
                        logging.error(f"{stream_name} - Failed to parse Content-Length: {e}")
                        logging.error(f"Raw header line: {line}")

            if content_length is None:
                logging.error(f"{stream_name} - No valid Content-Length header found in: {header}")
                continue

            logging.debug(f"{stream_name} - Content length: {content_length}")

            # Read content
            content = b""
            bytes_read = 0
            consecutive_empty_reads = 0
            content_timeout = time.time() + max(30, content_length / 1000)  # Timeout based on content size

            logging.debug(f"{stream_name} - Starting to read content")

            while bytes_read < content_length and not shutdown_requested:
                if time.time() > content_timeout:
                    logging.error(f"{stream_name} - Timeout reading content after reading {bytes_read}/{content_length} bytes")
                    return

                try:
                    chunk = input_stream.read(min(1024, content_length - bytes_read))
                    if not chunk:
                        consecutive_empty_reads += 1
                        logging.debug(f"{stream_name} - Empty read #{consecutive_empty_reads} while reading content")

                        if consecutive_empty_reads >= max_empty_reads:
                            logging.info(f"{stream_name} - Input stream closed during content read after {bytes_read}/{content_length} bytes")
                            return

                        time.sleep(0.1)  # Wait before retrying
                        continue
                    else:
                        consecutive_empty_reads = 0  # Reset counter

                    content += chunk
                    bytes_read += len(chunk)
                    logging.debug(f"{stream_name} - Read {len(chunk)} bytes, total {bytes_read}/{content_length}")
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error reading content: {e}")
                    logging.error(traceback.format_exc())
                    return

            if shutdown_requested:
                logging.info(f"{stream_name} - Shutdown requested during content read")
                return

            try:
                # Decode content
                content_str = content.decode('utf-8')
                logging.debug(f"{stream_name} - Received message: {content_str[:200]}...")

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
                    header = f"Content-Length: {len(new_content)}\r\n\r\n"
                    logging.debug(f"{stream_name} - Sending header: {header.strip()}")
                    output_stream.write(header.encode('utf-8'))
                    output_stream.write(new_content.encode('utf-8'))
                    output_stream.flush()
                    logging.debug(f"{stream_name} - Sent message: {new_content[:200]}...")
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error writing to output: {e}")
                    logging.error(traceback.format_exc())
                    return

            except json.JSONDecodeError as e:
                logging.error(f"{stream_name} - JSON decode error: {e}")
                logging.error(f"Raw content: {content[:1000]}")
                logging.error(traceback.format_exc())
            except Exception as e:
                logging.error(f"{stream_name} - Error processing message: {e}")
                logging.error(traceback.format_exc())

        except BrokenPipeError as e:
            logging.error(f"{stream_name} - Broken pipe error: SSH connection may have closed: {e}")
            logging.error(traceback.format_exc())
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

    logging.info("Starting stderr logging thread")
    while not shutdown_requested:
        try:
            # Use select to check if data is available
            if process.stderr.fileno() >= 0:  # Check if file descriptor is valid
                r, _, _ = select.select([process.stderr], [], [], 0.5)
                if process.stderr in r:
                    line = process.stderr.readline()
                    if not line:
                        logging.info("Stderr stream closed")
                        break
                    logging.error(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}")
            else:
                logging.info("Stderr file descriptor no longer valid")
                break
        except (IOError, ValueError) as e:
            logging.error(f"Error reading stderr: {e}")
            break
        except Exception as e:
            logging.error(f"Unexpected error in stderr thread: {e}")
            logging.error(traceback.format_exc())
            break

    logging.info("stderr logger thread exiting")

def neovim_to_ssh_thread(input_stream, output_stream, pattern, replacement, remote, protocol):
    global shutdown_requested

    try:
        handle_stream("neovim to ssh", input_stream, output_stream, pattern, replacement, remote, protocol)
    except Exception as e:
        logging.error(f"Error in neovim_to_ssh thread: {e}")
        logging.error(traceback.format_exc())
    finally:
        logging.info("neovim_to_ssh thread exiting")
        shutdown_requested = True

def ssh_to_neovim_thread(input_stream, output_stream, pattern, replacement, remote, protocol):
    global shutdown_requested

    try:
        handle_stream("ssh to neovim", input_stream, output_stream, pattern, replacement, remote, protocol)
    except Exception as e:
        logging.error(f"Error in ssh_to_neovim thread: {e}")
        logging.error(traceback.format_exc())
    finally:
        logging.info("ssh_to_neovim thread exiting")
        shutdown_requested = True

def main():
    global shutdown_requested

    def keepalive_thread():
        global shutdown_requested
        logging.info("Starting keepalive thread")
        while not shutdown_requested:
            try:
                # Just poll to keep connection alive
                if ssh_process.poll() is not None:
                    exit_code = ssh_process.poll()
                    logging.info(f"SSH process terminated during keepalive with code {exit_code}")

                    # Try to get remaining stderr output
                    stderr_data, _ = ssh_process.communicate(timeout=1)
                    if stderr_data:
                        for line in stderr_data.decode('utf-8', errors='replace').splitlines():
                            logging.error(f"Final stderr output: {line}")

                    shutdown_requested = True
                    break

                # Send a signal 0 to test if process is alive
                os.kill(ssh_process.pid, 0)
                logging.debug("Keepalive check: SSH process is alive")

                # Check if stdin is still writable with select
                if hasattr(ssh_process.stdin, 'fileno'):
                    try:
                        rlist, wlist, xlist = select.select([], [ssh_process.stdin], [], 0.1)
                        if not wlist:
                            logging.warning("SSH stdin not writable, connection may be broken")
                    except Exception as e:
                        logging.error(f"Select error in keepalive: {e}")
                time.sleep(2)
            except OSError as e:
                logging.error(f"Process error in keepalive: {e}")
                shutdown_requested = True
                break
            except Exception as e:
                logging.error(f"Keepalive error: {e}")
                logging.error(traceback.format_exc())
                break

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

    # Test the SSH connection first
    try:
        logging.info("Testing SSH connection...")
        test_cmd = ["ssh", "-q", remote, "echo 'Connection test successful'"]
        test_process = subprocess.run(test_cmd, capture_output=True, timeout=10)

        if test_process.returncode != 0:
            logging.error(f"SSH connection test failed with code {test_process.returncode}")
            if test_process.stderr:
                logging.error(f"SSH test stderr: {test_process.stderr.decode('utf-8', errors='replace')}")
            sys.exit(1)
        else:
            logging.info("SSH connection test successful")
    except subprocess.TimeoutExpired:
        logging.error("SSH connection test timed out")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Error testing SSH connection: {e}")
        logging.error(traceback.format_exc())
        sys.exit(1)

    # Start SSH process to run the specified LSP server remotely
    try:
        # For pyright, add environment variables and ensure proper command format
        if "pyright" in " ".join(lsp_command):
            # Create a wrapper script approach
            script_lines = [
                "#!/bin/bash",
                "set -e",
                "export PYTHONUNBUFFERED=1",
                "export NODE_NO_WARNINGS=1",
                f"echo 'Starting command: {' '.join(lsp_command)}' >&2",
                f"exec {' '.join(lsp_command)} 2>/tmp/pyright_debug.log"
            ]

            script_content = "\n".join(script_lines)

            # Create temporary script locally
            temp_script = f"/tmp/pyright_wrapper_{timestamp}.sh"
            with open(temp_script, "w") as f:
                f.write(script_content)
            os.chmod(temp_script, 0o755)

            # Use scp to copy it to remote server
            copy_cmd = ["scp", temp_script, f"{remote}:/tmp/"]
            logging.info(f"Copying script: {' '.join(copy_cmd)}")
            copy_process = subprocess.run(copy_cmd, capture_output=True)

            if copy_process.returncode != 0:
                logging.error(f"Failed to copy script: {copy_process.stderr.decode('utf-8')}")
                sys.exit(1)

            remote_script = f"/tmp/{os.path.basename(temp_script)}"
            cmd = ["ssh", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                  remote, remote_script]
        else:
            cmd = ["ssh", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                  remote, " ".join(lsp_command)]

        logging.info(f"Executing: {' '.join(cmd)}")

        # Set environment for the subprocess
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"

        ssh_process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=env
        )

        # Check if process starts correctly
        time.sleep(0.5)
        if ssh_process.poll() is not None:
            logging.error(f"SSH process failed to start, exit code: {ssh_process.poll()}")
            stderr_data, _ = ssh_process.communicate()
            if stderr_data:
                logging.error(f"SSH stderr: {stderr_data.decode('utf-8', errors='replace')}")
            sys.exit(1)

        logging.info(f"SSH process started with PID {ssh_process.pid}")

        # Start stderr logging thread
        stderr_thread = threading.Thread(target=log_stderr_thread, args=(ssh_process,))
        stderr_thread.daemon = True
        stderr_thread.start()

    except Exception as e:
        logging.error(f"Failed to start SSH process: {e}")
        logging.error(traceback.format_exc())
        sys.exit(1)

    try:
        keepalive = threading.Thread(target=keepalive_thread)
        keepalive.daemon = True
        keepalive.start()
    except Exception as e:
        logging.error(f"Failed to start SSH keepalive process {e}")
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
                ssh_process.wait(timeout=0.5)  # Short timeout to check shutdown flag frequently
            except subprocess.TimeoutExpired:
                # This is expected due to the short timeout
                pass

        if ssh_process.poll() is not None:
            exit_code = ssh_process.poll()
            logging.info(f"SSH process exited with code {exit_code}")

            # Try to get any remaining stderr output
            try:
                stderr_data, _ = ssh_process.communicate(timeout=1)
                if stderr_data:
                    for line in stderr_data.decode('utf-8', errors='replace').splitlines():
                        logging.error(f"Final stderr output: {line}")
            except Exception as e:
                logging.error(f"Error getting final stderr: {e}")

            shutdown_requested = True

            # Check remote log if possible
            if "pyright" in " ".join(lsp_command):
                try:
                    logging.info("Checking remote pyright debug log...")
                    check_cmd = ["ssh", remote, "cat /tmp/pyright_debug.log"]
                    check_process = subprocess.run(check_cmd, capture_output=True, timeout=5)
                    if check_process.stdout:
                        logging.info("Remote debug log contents:")
                        for line in check_process.stdout.decode('utf-8', errors='replace').splitlines():
                            logging.info(f"  {line}")
                    else:
                        logging.info("Remote debug log is empty")
                except Exception as e:
                    logging.error(f"Error checking remote log: {e}")

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
        t1.join(timeout=5)
        t2.join(timeout=5)

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
