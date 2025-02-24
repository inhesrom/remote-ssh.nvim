#!/usr/bin/env python3

import json
import subprocess
import sys
import threading
import logging
import datetime
import os
import traceback

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
    logging.info(f"Starting {stream_name} handler")
    
    content_buffer = b""
    content_length = None
    
    while True:
        try:
            # Read Content-Length header
            header = b""
            while True:
                byte = input_stream.read(1)
                if not byte:
                    logging.info(f"{stream_name} - Input stream closed.")
                    return
                
                header += byte
                if header.endswith(b"\r\n\r\n"):
                    break
            
            # Parse Content-Length
            for line in header.split(b"\r\n"):
                if line.startswith(b"Content-Length:"):
                    content_length = int(line.split(b":")[1].strip())
                    break
            
            if content_length is None:
                logging.error(f"{stream_name} - No Content-Length header found")
                continue
            
            # Read content
            content = input_stream.read(content_length)
            if not content:
                logging.info(f"{stream_name} - Content stream closed")
                return
            
            try:
                # Decode content
                content_str = content.decode('utf-8')
                logging.debug(f"{stream_name} - Received: {content_str[:200]}...")
                
                # Parse JSON
                message = json.loads(content_str)
                
                # Replace URIs
                message = replace_uris(message, pattern, replacement, remote)
                
                # Serialize back to JSON
                new_content = json.dumps(message)
                
                # Send with new Content-Length
                header = f"Content-Length: {len(new_content)}\r\n\r\n"
                output_stream.write(header.encode('utf-8'))
                output_stream.write(new_content.encode('utf-8'))
                output_stream.flush()
                
                logging.debug(f"{stream_name} - Sent: {new_content[:200]}...")
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

def main():
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
        def log_stderr():
            while True:
                line = ssh_process.stderr.readline()
                if not line:
                    break
                logging.error(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}")
        
        stderr_thread = threading.Thread(target=log_stderr)
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

    # Handle Neovim -> SSH
    def neovim_to_ssh():
        handle_stream("neovim to ssh", sys.stdin.buffer, ssh_process.stdin, incoming_pattern, incoming_replacement, remote)
        logging.info("neovim_to_ssh thread exiting")
        
    # Handle SSH -> Neovim
    def ssh_to_neovim():
        handle_stream("ssh to neovim", ssh_process.stdout, sys.stdout.buffer, outgoing_pattern, outgoing_replacement, remote)
        logging.info("ssh_to_neovim thread exiting")

    # Run both directions in parallel
    t1 = threading.Thread(target=neovim_to_ssh)
    t2 = threading.Thread(target=ssh_to_neovim)
    t1.daemon = True
    t2.daemon = True
    t1.start()
    t2.start()
    
    try:
        # Wait for process to finish
        ssh_process.wait()
        logging.info(f"SSH process exited with code {ssh_process.returncode}")
    except KeyboardInterrupt:
        logging.info("Received keyboard interrupt, terminating...")
    finally:
        # Clean up
        try:
            ssh_process.terminate()
        except:
            pass
        
        t1.join(timeout=1)
        t2.join(timeout=1)
        logging.info("Proxy terminated")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logging.error(f"Unhandled exception in main: {e}")
        logging.error(traceback.format_exc())
        sys.exit(1)
