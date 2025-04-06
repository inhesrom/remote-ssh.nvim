#!/usr/bin/env python3

import sys
import subprocess
import threading
import signal
import time
import re

# Global shutdown flag
shutdown_requested = False

def replace_uris_in_data(data, pattern, replacement):
    """Replace URIs in data using simple string replacement"""
    # Convert bytes to string for replacement
    if isinstance(data, bytes):
        text = data.decode('utf-8', errors='replace')

        # Use regex to replace URIs in JSON strings
        text = re.sub(f'"{pattern}([^"]*)"', f'"{replacement}\\1"', text)

        return text.encode('utf-8')
    return data

def process_stream(name, source, dest, pattern, replacement):
    """Process stream with simple string replacements"""
    print(f"Starting {name} handler", file=sys.stderr)

    try:
        while not shutdown_requested:
            # Read chunk of data
            data = source.read(4096)
            if not data:
                print(f"{name} - Stream closed", file=sys.stderr)
                break

            # Replace URIs in the data
            modified_data = replace_uris_in_data(data, pattern, replacement)

            # Write to destination
            dest.write(modified_data)
            dest.flush()
    except Exception as e:
        print(f"Error in {name}: {e}", file=sys.stderr)

    print(f"{name} handler exiting", file=sys.stderr)

def log_stderr(process):
    """Log stderr output"""
    try:
        while not shutdown_requested:
            line = process.stderr.readline()
            if not line:
                break
            print(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}", file=sys.stderr)
    except Exception as e:
        print(f"Error in stderr logger: {e}", file=sys.stderr)

    print("stderr logger exiting", file=sys.stderr)

def signal_handler(sig, frame):
    """Handle termination signals"""
    global shutdown_requested
    print(f"Received signal {sig}, shutting down", file=sys.stderr)
    shutdown_requested = True

def main():
    global shutdown_requested

    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Check arguments
    if len(sys.argv) < 4:
        print("Usage: proxy.py <user@remote> <protocol> <lsp_command> [args...]", file=sys.stderr)
        sys.exit(1)

    remote = sys.argv[1]
    protocol = sys.argv[2]
    lsp_command = sys.argv[3:]

    print(f"Starting proxy for {remote} using protocol {protocol} with command: {' '.join(lsp_command)}", file=sys.stderr)

    # Start SSH process
    cmd = ["ssh", "-q", remote, " ".join(lsp_command)]

    try:
        ssh_process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )
    except Exception as e:
        print(f"Failed to start SSH process: {e}", file=sys.stderr)
        sys.exit(1)

    # Start stderr logger
    stderr_thread = threading.Thread(target=log_stderr, args=(ssh_process,))
    stderr_thread.daemon = True
    stderr_thread.start()

    # URI patterns
    neovim_to_ssh_pattern = f"{protocol}://{remote}/"
    neovim_to_ssh_replacement = "file:///"

    ssh_to_neovim_pattern = "file:///"
    ssh_to_neovim_replacement = f"{protocol}://{remote}/"

    # Start I/O threads
    t1 = threading.Thread(
        target=process_stream,
        args=("neovim to ssh", sys.stdin.buffer, ssh_process.stdin,
              neovim_to_ssh_pattern, neovim_to_ssh_replacement)
    )

    t2 = threading.Thread(
        target=process_stream,
        args=("ssh to neovim", ssh_process.stdout, sys.stdout.buffer,
              ssh_to_neovim_pattern, ssh_to_neovim_replacement)
    )

    t1.daemon = False
    t2.daemon = False
    t1.start()
    t2.start()

    # Monitor SSH process
    try:
        while not shutdown_requested and ssh_process.poll() is None:
            time.sleep(0.1)

        if ssh_process.poll() is not None:
            print(f"SSH process exited with code {ssh_process.returncode}", file=sys.stderr)
            shutdown_requested = True
    except Exception as e:
        print(f"Error in main loop: {e}", file=sys.stderr)
        shutdown_requested = True
    finally:
        # Clean up
        shutdown_requested = True

        if ssh_process.poll() is None:
            try:
                print("Terminating SSH process...", file=sys.stderr)
                ssh_process.terminate()
                ssh_process.wait(timeout=2)
            except:
                ssh_process.kill()

        print("Proxy terminated", file=sys.stderr)

if __name__ == "__main__":
    main()
