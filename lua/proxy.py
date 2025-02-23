#!/usr/bin/env python3

import json
import subprocess
import sys
import threading

def replace_uris(obj, pattern, replacement):
    """
    Recursively traverse a JSON object and replace URIs matching 'pattern' with 'replacement'.
    """
    if isinstance(obj, dict):
        return {k: replace_uris(v, pattern, replacement) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, pattern, replacement) for item in obj]
    elif isinstance(obj, str) and obj.startswith(pattern):
        return replacement + obj[len(pattern):]
    return obj

def handle_stream(input_stream, output_stream, pattern, replacement):
    """
    Read LSP messages from input_stream, replace URIs, and write to output_stream.
    """
    while True:
        # Read Content-Length header
        line = input_stream.readline().decode('utf-8')
        if not line:
            break
        if line.startswith("Content-Length:"):
            length = int(line.split(":")[1].strip())
            # Read empty line
            input_stream.readline()
            # Read content
            content = input_stream.read(length).decode('utf-8')
            # Parse JSON
            message = json.loads(content)
            # Replace URIs
            message = replace_uris(message, pattern, replacement)
            # Serialize back to JSON
            new_content = json.dumps(message)
            # Send with new Content-Length
            output_stream.write(
                f"Content-Length: {len(new_content)}\r\n\r\n{new_content}".encode('utf-8')
            )
            output_stream.flush()

def main():
    if len(sys.argv) < 2:
        print("Usage: proxy.py <user@remote> <lsp_command> [args...]")
        sys.exit(1)

    remote = sys.argv[1]
    lsp_command = sys.argv[2:]  # Take the LSP command and its arguments (e.g., ["clangd", "--background-index"])
    if not lsp_command:
        print("Error: No LSP command provided")
        sys.exit(1)

    # Start SSH process to run the specified LSP server remotely
    ssh_process = subprocess.Popen(
        ["ssh", "-q", remote] + lsp_command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        bufsize=0
    )

    # Patterns for URI replacement
    incoming_pattern = f"scp://{remote}/"  # From Neovim
    incoming_replacement = "file:///"      # To LSP server
    outgoing_pattern = "file:///"          # From LSP server
    outgoing_replacement = f"scp://{remote}/"  # To Neovim

    # Handle Neovim -> SSH
    def neovim_to_ssh():
        handle_stream(sys.stdin.buffer, ssh_process.stdin, incoming_pattern, incoming_replacement)

    # Handle SSH -> Neovim
    def ssh_to_neovim():
        handle_stream(ssh_process.stdout, sys.stdout.buffer, outgoing_pattern, outgoing_replacement)

    # Run both directions in parallel
    t1 = threading.Thread(target=neovim_to_ssh)
    t2 = threading.Thread(target=ssh_to_neovim)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

if __name__ == "__main__":
    main()
