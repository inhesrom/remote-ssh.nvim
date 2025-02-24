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

def replace_uris(obj, pattern, replacement, remote):
    """Replace URIs in JSON objects to handle the translation between local and remote paths."""
    if isinstance(obj, str):
        if obj.startswith(f"file://scp://{remote}/"):
            new_uri = "file://" + obj[len(f"file://scp://{remote}/"):]
            logging.debug(f"Fixing URI: {obj} -> {new_uri}")
            return new_uri
        elif obj.startswith(pattern):
            logging.debug(f"Replacing URI: {obj} -> {replacement + obj[len(pattern):]}")
            return replacement + obj[len(pattern):]
    if isinstance(obj, dict):
        return {k: replace_uris(v, pattern, replacement, remote) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, pattern, replacement, remote) for item in obj]
    return obj

def handle_stream(stream_name, input_stream, output_stream, pattern, replacement, remote):
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
            while not shutdown_requested:
                try:
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
            
            # Parse Content-Length
            content_length = None
            for line in header.split(b"\r\n"):
                if line.startswith(b"Content-Length:"):
                    try:
                        content_length = int(line.split(b":")[1].strip())
                        break
                    except (ValueError, IndexError) as e:
                        logging.error(f"{stream_name} - Failed to parse Content-Length: {e}")
            
            if content_length is None:
                logging.error(f"{stream_name} - No valid Content-Length header found")
                continue
            
            # Read content
            content = b""
            bytes_read = 0
            while bytes_read < content_length and not shutdown_requested:
                try:
                    chunk = input_stream.read(content_length - bytes_read)
                    if not chunk:
                        logging.info(f"{stream_name} - Input stream closed during content read after {bytes_read} bytes")
                        return
                    content += chunk
                    bytes_read += len(chunk)
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error reading content: {e}")
                    return
            
            if shutdown_requested:
                logging.info(f"{stream_name} - Shutdown requested during content read")
                return
                
            try:
                # Decode content
                content_str = content.decode('utf-8')
                logging.debug(f"{stream_name} - Received: {content_str[:200]}...")
                
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
                message = replace_uris(message, pattern, replacement, remote)
                
                # Serialize back to JSON
                new_content = json.dumps(message)
                
                # Send with new Content-Length
                try:
                    header = f"Content-Length: {len(new_content)}\r\n\r\n"
                    output_stream.write(header.encode('utf-8'))
                    output_stream.write(new_content.encode('utf-8'))
                    output_stream.flush()
                    logging.debug(f"{stream_name} - Sent: {new_content[:200]}...")
                except (IOError, ValueError) as e:
                    logging.error(f"{stream_name} - Error writing to output: {e}")
                    return
                    
            except json.JSONDecodeError as e:
                logging.error(f"{stream_name} - JSON decode error: {e}")
                logging.error(f"Raw content: {content[:100]}")
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
            logging.error(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}")
        except (IOError, ValueError):
            break
    
    logging.info("stderr logger thread exiting")

def neovim_to_ssh_thread(input_stream, output_stream, pattern, replacement, remote):
    global shutdown_requested
    
    handle_stream("neovim to ssh", input_stream, output_stream, pattern, replacement, remote)
    logging.info("neovim_to_ssh thread exiting")
    
    # When this thread exits, signal the other thread to exit
    shutdown_requested = True

def ssh_to_neovim_thread(input_stream, output_stream, pattern, replacement, remote):
    global shutdown_requested
    
    handle_stream("ssh to neovim", input_stream, output_stream, pattern, replacement, remote)
    logging.info("ssh_to_neovim thread exiting")
    
    # When this thread exits, signal the other thread to exit
    shutdown_requested = True

def main():
    global shutdown_requested
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    if len(sys.argv) < 3:
        logging.error("Usage: proxy.py <user@remote> <lsp_command> [args...]")
        sys.exit(1)

    remote = sys.argv[1]
    lsp_command = sys.argv[2:]
    
    logging.info(f"Starting proxy for {remote} with command: {' '.join(lsp_command)}")
    
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
    incoming_pattern = f"scp://{remote}/"  # From Neovim
    incoming_replacement = "file://"       # To LSP server
    outgoing_pattern = "file://"           # From LSP server
    outgoing_replacement = f"scp://{remote}/"  # To Neovim

    # Create I/O threads using their dedicated functions
    t1 = threading.Thread(
        target=neovim_to_ssh_thread, 
        args=(sys.stdin.buffer, ssh_process.stdin, incoming_pattern, incoming_replacement, remote)
    )
    
    t2 = threading.Thread(
        target=ssh_to_neovim_thread,
        args=(ssh_process.stdout, sys.stdout.buffer, outgoing_pattern, outgoing_replacement, remote)
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
