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

# Set up logging
timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
log_dir = os.path.expanduser("~/.cache/nvim/remote_lsp_logs")
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, f'proxy_log_{timestamp}.log')

logging.basicConfig(
    level=logging.DEBUG,  # Changed to DEBUG to see URI translations
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stderr)
    ]
)

shutdown_requested = False

def replace_uris(obj, remote, protocol):
    """Simple, reliable URI replacement"""
    if isinstance(obj, str):
        # Handle malformed URIs like "file://rsync://host/path" (from LSP client initialization)
        malformed_prefix = f"file://{protocol}://{remote}/"
        if obj.startswith(malformed_prefix):
            # Extract the path and convert to proper file:/// format
            path_part = obj[len(malformed_prefix):]
            clean_path = path_part.lstrip('/')
            result = f"file:///{clean_path}"
            logging.debug(f"Fixed malformed URI: {obj} -> {result}")
            return result
        
        # Convert rsync://host/path to file:///path
        remote_prefix = f"{protocol}://{remote}/"
        if obj.startswith(remote_prefix):
            # Extract path after the host
            path_part = obj[len(remote_prefix):]
            # Clean up any double slashes and ensure proper format
            clean_path = path_part.lstrip('/')
            result = f"file:///{clean_path}"
            logging.debug(f"URI translation: {obj} -> {result}")
            return result
            
        # Convert file:///path to rsync://host/path  
        elif obj.startswith("file:///"):
            path_part = obj[8:]  # Remove "file:///"
            result = f"{protocol}://{remote}/{path_part}"
            logging.debug(f"URI translation: {obj} -> {result}")
            return result
            
        # Handle file:// (without triple slash)
        elif obj.startswith("file://") and not obj.startswith("file:///"):
            path_part = obj[7:]  # Remove "file://"
            result = f"{protocol}://{remote}/{path_part}"
            logging.debug(f"URI translation: {obj} -> {result}")
            return result
            
    elif isinstance(obj, dict):
        return {k: replace_uris(v, remote, protocol) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, remote, protocol) for item in obj]
    
    return obj

def handle_stream(stream_name, input_stream, output_stream, remote, protocol):
    global shutdown_requested
    
    logging.info(f"Starting {stream_name} handler")
    
    while not shutdown_requested:
        try:
            # Read Content-Length header with proper EOF handling
            header = b""
            while not shutdown_requested:
                try:
                    byte = input_stream.read(1)
                    if not byte:
                        # Check if this is a real EOF or just no data available
                        # For stdin/stdout pipes, empty read usually means EOF
                        # But we should verify the process is still alive
                        if hasattr(input_stream, 'closed') and input_stream.closed:
                            logging.info(f"{stream_name} - Input stream is closed")
                            return
                        # For process pipes, check if the process is still running
                        if stream_name == "ssh_to_neovim" and hasattr(globals().get('ssh_process'), 'poll'):
                            if globals()['ssh_process'].poll() is not None:
                                logging.info(f"{stream_name} - SSH process has terminated")
                                return
                        
                        # If we can't determine the state, treat as potential temporary condition
                        # Try a small delay and check again
                        import time
                        time.sleep(0.01)  # 10ms delay
                        continue
                    
                    header += byte
                    if header.endswith(b"\r\n\r\n"):
                        break
                except Exception as e:
                    logging.error(f"{stream_name} - Error reading header byte: {e}")
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
                continue
            
            # Read content with proper error handling
            content = b""
            while len(content) < content_length and not shutdown_requested:
                try:
                    remaining = content_length - len(content)
                    chunk = input_stream.read(remaining)
                    if not chunk:
                        # Similar EOF checking as above
                        if hasattr(input_stream, 'closed') and input_stream.closed:
                            logging.info(f"{stream_name} - Input stream closed during content read")
                            return
                        if stream_name == "ssh_to_neovim" and hasattr(globals().get('ssh_process'), 'poll'):
                            if globals()['ssh_process'].poll() is not None:
                                logging.info(f"{stream_name} - SSH process terminated during content read")
                                return
                        
                        # Brief delay for potential temporary condition
                        import time
                        time.sleep(0.01)
                        continue
                    
                    content += chunk
                except Exception as e:
                    logging.error(f"{stream_name} - Error reading content: {e}")
                    return
            
            try:
                # Decode and parse JSON
                content_str = content.decode('utf-8')
                message = json.loads(content_str)
                
                logging.debug(f"{stream_name} - Original message: {json.dumps(message, indent=2)}")
                
                # Check for exit messages
                if message.get("method") == "exit":
                    logging.info("Exit message detected")
                    shutdown_requested = True
                
                # Replace URIs
                translated_message = replace_uris(message, remote, protocol)
                
                logging.debug(f"{stream_name} - Translated message: {json.dumps(translated_message, indent=2)}")
                
                # Send translated message
                new_content = json.dumps(translated_message)
                header = f"Content-Length: {len(new_content)}\r\n\r\n"
                
                output_stream.write(header.encode('utf-8'))
                output_stream.write(new_content.encode('utf-8'))
                output_stream.flush()
                
            except json.JSONDecodeError as e:
                logging.error(f"{stream_name} - JSON decode error: {e}")
            except Exception as e:
                logging.error(f"{stream_name} - Error processing message: {e}")
                
        except Exception as e:
            logging.error(f"{stream_name} - Error in stream handler: {e}")
            return
    
    logging.info(f"{stream_name} - Handler exiting")

def main():
    global shutdown_requested, ssh_process
    
    if len(sys.argv) < 4:
        logging.error("Usage: proxy.py <user@remote> <protocol> <lsp_command> [args...]")
        sys.exit(1)
    
    remote = sys.argv[1]
    protocol = sys.argv[2] 
    lsp_command = sys.argv[3:]
    
    logging.info(f"Starting proxy for {remote} using {protocol} with command: {' '.join(lsp_command)}")
    
    # Start SSH process
    try:
        cmd = ["ssh", "-q", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", remote] + lsp_command
        logging.info(f"Executing: {' '.join(cmd)}")
        
        ssh_process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )
        
        # Start stderr monitoring thread to catch any LSP server errors
        def monitor_stderr():
            while not shutdown_requested:
                try:
                    line = ssh_process.stderr.readline()
                    if not line:
                        break
                    error_msg = line.decode('utf-8', errors='replace').strip()
                    if error_msg:
                        logging.error(f"LSP server stderr: {error_msg}")
                except:
                    break
        
        stderr_thread = threading.Thread(target=monitor_stderr)
        stderr_thread.daemon = True
        stderr_thread.start()
        
    except Exception as e:
        logging.error(f"Failed to start SSH process: {e}")
        sys.exit(1)
    
    # Start I/O threads
    t1 = threading.Thread(
        target=handle_stream,
        args=("neovim_to_ssh", sys.stdin.buffer, ssh_process.stdin, remote, protocol)
    )
    t2 = threading.Thread(
        target=handle_stream, 
        args=("ssh_to_neovim", ssh_process.stdout, sys.stdout.buffer, remote, protocol)
    )
    
    t1.start()
    t2.start()
    
    try:
        ssh_process.wait()
    except KeyboardInterrupt:
        logging.info("Interrupted")
    finally:
        shutdown_requested = True
        if ssh_process.poll() is None:
            ssh_process.terminate()
        t1.join(timeout=2)
        t2.join(timeout=2)
        logging.info("Proxy terminated")

if __name__ == "__main__":
    main()
