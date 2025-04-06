#!/usr/bin/env python3

import subprocess
import sys
import threading
import os
import signal
import time

# Global flag
shutdown_requested = False

def forward_data(name, source, dest):
    """Just forward data from source to dest without modification"""
    try:
        while not shutdown_requested:
            data = source.read(1024)
            if not data:
                print(f"{name} stream closed", file=sys.stderr)
                break
            dest.write(data)
            dest.flush()
    except Exception as e:
        print(f"Error in {name}: {e}", file=sys.stderr)
    print(f"{name} forwarder exiting", file=sys.stderr)

def log_stderr(process):
    """Log stderr without any special processing"""
    try:
        for line in process.stderr:
            print(f"LSP stderr: {line.strip()}", file=sys.stderr)
    except Exception as e:
        print(f"Error in stderr logger: {e}", file=sys.stderr)
    print("stderr logger exiting", file=sys.stderr)

def signal_handler(sig, frame):
    global shutdown_requested
    print(f"Received signal {sig}, initiating shutdown", file=sys.stderr)
    shutdown_requested = True

def main():
    global shutdown_requested

    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Check arguments
    if len(sys.argv) < 4:
        print("Usage: proxy.py <user@remote> <protocol> <lsp_command> [args...]", file=sys.stderr)
        sys.exit(1)

    remote = sys.argv[1]
    protocol = sys.argv[2]
    lsp_command = sys.argv[3:]

    print(f"Starting proxy for {remote} with command: {' '.join(lsp_command)}", file=sys.stderr)

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

    # Start threads
    stderr_thread = threading.Thread(target=log_stderr, args=(ssh_process,))
    stderr_thread.daemon = True
    stderr_thread.start()

    t1 = threading.Thread(
        target=forward_data,
        args=("stdin->ssh", sys.stdin.buffer, ssh_process.stdin)
    )

    t2 = threading.Thread(
        target=forward_data,
        args=("ssh->stdout", ssh_process.stdout, sys.stdout.buffer)
    )

    t1.daemon = False
    t2.daemon = False
    t1.start()
    t2.start()

    # Monitor process
    try:
        while not shutdown_requested and ssh_process.poll() is None:
            time.sleep(0.1)

        if ssh_process.poll() is not None:
            print(f"SSH process exited with code {ssh_process.returncode}", file=sys.stderr)
    except Exception as e:
        print(f"Error in main loop: {e}", file=sys.stderr)
    finally:
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
