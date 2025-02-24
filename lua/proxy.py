#!/usr/bin/env python3

import json
import subprocess
import sys
import threading
import logging
import datetime

# Set up logging
timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
logging.basicConfig(filename=f'proxy_log_{timestamp}.log', level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

def replace_uris(obj, pattern, replacement, remote):
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
    logging.debug(f"Starting stream {stream_name} handler with params: input_stream={str(input_stream)}, output_stream={str(output_stream)}, pattern={pattern}, replacement={replacement}, remote={remote}")
    while True:
        try:
            # Read Content-Length header
            line = input_stream.readline().decode('utf-8')
            if not line:
                logging.info(f"{stream_name} - Input stream closed.")
                break
            if line.startswith("Content-Length:"):
                length = int(line.split(":")[1].strip())
                # Read empty line
                input_stream.readline()
                # Read content
                content = input_stream.read(length).decode('utf-8')
                logging.debug(f"{stream_name} - Received content from input stream {str(input_stream)}" + " - " + content)
                # Parse JSON
                try:
                    message = json.loads(content)
                except json.JSONDecodeError as e:
                    logging.error(f"{stream_name} - Failed to parse JSON: {e}")
                    continue
                # Replace URIs
                message = replace_uris(message, pattern, replacement, remote)

                # Serialize back to JSON
                new_content = json.dumps(message)

                # Send with new Content-Length
                write_contents = f"Content-Length: {len(new_content)}\r\n\r\n{new_content}"
                logging.debug(f"{stream_name} - Writing to output stream {str(output_stream)}: " + write_contents)

                output_stream.write(write_contents.encode('utf-8'))
                output_stream.flush()
        except BrokenPipeError:
            logging.error(f"{stream_name} - Broken pipe error: SSH connection may have closed.")
            break
        except Exception as e:
            logging.error(f"{stream_name} - Error in handle_stream: {e}")
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
            ["ssh", "-q", remote, " ".join(lsp_command) + " --log=verbose > /tmp/clangd.log 2>&1"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )

        logging.info(f"Started SSH process with command: ssh -q {remote} {' '.join(lsp_command)}")

        def log_stderr():
            while True:
                line = ssh_process.stderr.readline()
                if not line:
                    break
                logging.error(f"LSP server stderr: {line.decode('utf-8').strip()}")

        stderr_thread = threading.Thread(target=log_stderr)
        stderr_thread.daemon = True
        stderr_thread.start()
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
        handle_stream("neovim to ssh", sys.stdin.buffer, ssh_process.stdin, incoming_pattern, incoming_replacement, remote)

    # Handle SSH -> Neovim
    def ssh_to_neovim():
        handle_stream("ssh to neovim", ssh_process.stdout, sys.stdout.buffer, outgoing_pattern, outgoing_replacement, remote)

    # Run both directions in parallel
    t1 = threading.Thread(target=neovim_to_ssh)
    t2 = threading.Thread(target=ssh_to_neovim)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

if __name__ == "__main__":
    main()
