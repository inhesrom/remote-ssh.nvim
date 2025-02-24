#!/usr/bin/env python3

import json
import subprocess
import sys
import threading
import logging

# Set up logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

def replace_uris(obj, pattern, replacement, remote):
    if isinstance(obj, dict):
        return {k: replace_uris(v, pattern, replacement) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, pattern, replacement) for item in obj]
    elif isinstance(obj, str):
        if obj.startswith(f"file://scp://{remote}/"):
            new_uri = "file://" + obj[len(f"file://scp://{remote}/"):]
            logging.debug(f"Fixing URI: {obj} -> {new_uri}")
            return new_uri
        elif obj.startswith(pattern):
            logging.debug(f"Replacing URI: {obj} -> {replacement + obj[len(pattern):]}")
            return replacement + obj[len(pattern):]
    return obj

def handle_stream(input_stream, output_stream, pattern, replacement, remote):
    """
    Read LSP messages from input_stream, replace URIs, and write to output_stream.
    """
    while True:
        try:
            # Read Content-Length header
            line = input_stream.readline().decode('utf-8')
            if not line:
                logging.info("Input stream closed.")
                break
            if line.startswith("Content-Length:"):
                length = int(line.split(":")[1].strip())
                # Read empty line
                input_stream.readline()
                # Read content
                content = input_stream.read(length).decode('utf-8')
                # Parse JSON
                try:
                    message = json.loads(content)
                except json.JSONDecodeError as e:
                    logging.error(f"Failed to parse JSON: {e}")
                    continue
                # Replace URIs
                message = replace_uris(message, pattern, replacement, remote)
                # Serialize back to JSON
                new_content = json.dumps(message)
                # Send with new Content-Length
                output_stream.write(
                    f"Content-Length: {len(new_content)}\r\n\r\n{new_content}".encode('utf-8')
                )
                output_stream.flush()
        except BrokenPipeError:
            logging.error("Broken pipe error: SSH connection may have closed.")
            break
        except Exception as e:
            logging.error(f"Error in handle_stream: {e}")
            break

def main():
    if len(sys.argv) < 3:  # Fixed: Check for at least 3 args (script, remote, lsp_command)
        print("Usage: proxy.py <user@remote> <lsp_command> [args...]", file=sys.stderr)
        sys.exit(1)

    remote = sys.argv[1]
    lsp_command = sys.argv[2:]  # Take the LSP command and its arguments (e.g., ["clangd", "--background-index"])
    if not lsp_command:
        print("Error: No LSP command provided", file=sys.stderr)
        sys.exit(1)

    # Start SSH process to run the specified LSP server remotely
    try:
        ssh_process = subprocess.Popen(
            ["ssh", "-q", remote] + lsp_command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            bufsize=0
        )
    except Exception as e:
        logging.error(f"Failed to start SSH process: {e}")
        sys.exit(1)

    # Patterns for URI replacement
    incoming_pattern = f"scp://{remote}/"  # From Neovim
    incoming_replacement = "file://"      # To LSP server
    outgoing_pattern = "file://"          # From LSP server
    outgoing_replacement = f"scp://{remote}/"  # To Neovim

    # Handle Neovim -> SSH
    def neovim_to_ssh():
        handle_stream(sys.stdin.buffer, ssh_process.stdin, incoming_pattern, incoming_replacement, remote)

    # Handle SSH -> Neovim
    def ssh_to_neovim():
        handle_stream(ssh_process.stdout, sys.stdout.buffer, outgoing_pattern, outgoing_replacement, remote)

    # Run both directions in parallel
    t1 = threading.Thread(target=neovim_to_ssh)
    t2 = threading.Thread(target=ssh_to_neovim)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

if __name__ == "__main__":
    main()
