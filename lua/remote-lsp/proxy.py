#!/usr/bin/env python3

import sys
import subprocess
import threading
import signal
import re
import os

# Global flag
shutdown_requested = False

def forward_stream(name, source, dest, pattern, replacement):
    """Forward stream data with simple URI pattern replacements"""
    print(f"{name} started", file=sys.stderr)

    # Buffer for reading
    buffer = b""

    try:
        while not shutdown_requested:
            # Read some data (up to 4K)
            chunk = source.read(4096)
            if not chunk:
                print(f"{name} - input stream closed", file=sys.stderr)
                break

            # Add to buffer and convert to string for processing
            buffer += chunk
            text = buffer.decode('utf-8', errors='replace')

            # Simple regex replacements for URIs in JSON strings
            text = re.sub(f'["\']({pattern})([^"\']*)["\']', f'"{replacement}\\2"', text)

            # Convert back to bytes and forward
            output = text.encode('utf-8')
            dest.write(output)
            dest.flush()

            # Clear buffer
            buffer = b""

    except Exception as e:
        print(f"Error in {name}: {e}", file=sys.stderr)

    print(f"{name} exiting", file=sys.stderr)

def log_stderr(proc):
    """Simple stderr logger"""
    try:
        while not shutdown_requested:
            line = proc.stderr.readline()
            if not line:
                break
            print(f"LSP stderr: {line.decode('utf-8', errors='replace').strip()}", file=sys.stderr)
    except Exception as e:
        print(f"Error in stderr logger: {e}", file=sys.stderr)

def signal_handler(sig, frame):
    """Handle termination signals"""
    global shutdown_requested
    print(f"Received signal {sig}", file=sys.stderr)
    shutdown_requested = True

def main():
    global shutdown_requested

    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Check arguments
    if len(sys.argv) < 4:
        print("Usage: proxy.py <host> <protocol> <command...>", file=sys.stderr)
        sys.exit(1)

    remote = sys.argv[1]
    protocol = sys.argv[2]
    command = sys.argv[3:]

    # Patterns for replacement
    neovim_to_ssh_pattern = f"{protocol}://{remote}"
    neovim_to_ssh_replacement = "file://"

    ssh_to_neovim_pattern = "file://"
    ssh_to_neovim_replacement = f"{protocol}://{remote}"

    # Start SSH process
    cmd = ["ssh", "-q", remote, " ".join(command)]

    try:
        ssh_proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )
    except Exception as e:
        print(f"Failed to start SSH: {e}", file=sys.stderr)
        sys.exit(1)

    # Start threads
    stderr_thread = threading.Thread(
        target=log_stderr,
        args=(ssh_proc,)
    )

    client_to_server = threading.Thread(
        target=forward_stream,
        args=("client→server", sys.stdin.buffer, ssh_proc.stdin,
              neovim_to_ssh_pattern, neovim_to_ssh_replacement)
    )

    server_to_client = threading.Thread(
        target=forward_stream,
        args=("server→client", ssh_proc.stdout, sys.stdout.buffer,
              ssh_to_neovim_pattern, ssh_to_neovim_replacement)
    )

    stderr_thread.daemon = True
    stderr_thread.start()
    client_to_server.start()
    server_to_client.start()

    # Wait for process to finish
    try:
        while not shutdown_requested:
            if ssh_proc.poll() is not None:
                print(f"SSH process exited with code {ssh_proc.returncode}", file=sys.stderr)
                break
            # Sleep briefly to avoid busy waiting
            import time
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        # Clean up
        shutdown_requested = True

        # Terminate SSH if still running
        if ssh_proc.poll() is None:
            ssh_proc.terminate()
            try:
                ssh_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                ssh_proc.kill()

        # Wait for threads
        client_to_server.join(timeout=1)
        server_to_client.join(timeout=1)

        print("Proxy terminated", file=sys.stderr)

if __name__ == "__main__":
    main()
