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

# Create logger with file handler for all messages
logger = logging.getLogger('proxy')
logger.setLevel(logging.DEBUG)

# File handler for all messages
file_handler = logging.FileHandler(log_file)
file_handler.setLevel(logging.DEBUG)
file_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
file_handler.setFormatter(file_formatter)
logger.addHandler(file_handler)

# Stderr handler only for errors and warnings (to avoid polluting LSP communication)
stderr_handler = logging.StreamHandler(sys.stderr)
stderr_handler.setLevel(logging.WARNING)
stderr_formatter = logging.Formatter('PROXY %(levelname)s: %(message)s')
stderr_handler.setFormatter(stderr_formatter)
logger.addHandler(stderr_handler)

shutdown_requested = False
ssh_process = None  # Global reference to SSH process

def replace_uris(obj, remote, protocol):
    """URI replacement with support for both exact matches and embedded URIs"""
    if isinstance(obj, str):
        import re
        result = obj

        # Handle malformed URIs like "file://rsync://host/path" (from LSP client initialization)
        malformed_prefix = f"file://{protocol}://{remote}/"
        if result.startswith(malformed_prefix):
            # Extract the path and convert to proper file:/// format
            path_part = result[len(malformed_prefix):]
            clean_path = path_part.lstrip('/')
            result = f"file:///{clean_path}"
            logger.debug(f"Fixed malformed URI: {obj} -> {result}")
            return result

        # Convert rsync://host/path to file:///path (for requests to LSP server)
        remote_prefix = f"{protocol}://{remote}/"

        # Handle both exact matches and embedded URIs with regex
        remote_pattern = re.escape(remote_prefix) + r'([^\s\)\]]*)'
        if re.search(remote_pattern, result):
            result = re.sub(remote_pattern, lambda m: f"file:///{m.group(1).lstrip('/')}", result)
            if result != obj:
                logger.debug(f"URI translation (rsync->file): {obj} -> {result}")
                return result

        # Convert file:///path to rsync://host/path (for responses from LSP server)
        # Handle both exact matches and embedded file:// URIs
        file_pattern = r'file:///([^\s\)\]]*)'
        if re.search(file_pattern, result):
            result = re.sub(file_pattern, lambda m: f"{protocol}://{remote}/{m.group(1)}", result)
            if result != obj:
                logger.debug(f"URI translation (file->rsync): {obj} -> {result}")
                return result

        # Handle file:// (without triple slash) patterns
        file_double_pattern = r'file://([^\s\)\]]*)'
        if re.search(file_double_pattern, result) and not re.search(r'file:///([^\s\)\]]*)', result):
            result = re.sub(file_double_pattern, lambda m: f"{protocol}://{remote}/{m.group(1)}", result)
            if result != obj:
                logger.debug(f"URI translation (file://->rsync): {obj} -> {result}")
                return result

        return result

    elif isinstance(obj, dict):
        return {k: replace_uris(v, remote, protocol) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [replace_uris(item, remote, protocol) for item in obj]

    return obj

def handle_stream(stream_name, input_stream, output_stream, remote, protocol):
    global shutdown_requested, ssh_process

    logger.info(f"Starting {stream_name} handler")

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
                            logger.info(f"{stream_name} - Input stream is closed")
                            return
                        # For process pipes, check if the process is still running
                        if stream_name == "ssh_to_neovim" and ssh_process is not None:
                            if ssh_process.poll() is not None:
                                logger.info(f"{stream_name} - SSH process has terminated (exit code: {ssh_process.returncode})")
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
                    logger.error(f"{stream_name} - Error reading header byte: {e}")
                    return

            # Parse Content-Length
            content_length = None
            for line in header.split(b"\r\n"):
                if line.startswith(b"Content-Length:"):
                    try:
                        content_length = int(line.split(b":")[1].strip())
                        break
                    except (ValueError, IndexError) as e:
                        logger.error(f"{stream_name} - Failed to parse Content-Length: {e}")

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
                            logger.info(f"{stream_name} - Input stream closed during content read")
                            return
                        if stream_name == "ssh_to_neovim" and ssh_process is not None:
                            if ssh_process.poll() is not None:
                                logger.info(f"{stream_name} - SSH process terminated during content read (exit code: {ssh_process.returncode})")
                                return

                        # Brief delay for potential temporary condition
                        import time
                        time.sleep(0.01)
                        continue

                    content += chunk
                except Exception as e:
                    logger.error(f"{stream_name} - Error reading content: {e}")
                    return

            try:
                # Decode and parse JSON
                content_str = content.decode('utf-8')
                message = json.loads(content_str)

                logger.debug(f"{stream_name} - Original message: {json.dumps(message, indent=2)}")

                # Check for exit messages
                if message.get("method") == "exit":
                    logger.info("Exit message detected")
                    shutdown_requested = True

                # Replace URIs
                translated_message = replace_uris(message, remote, protocol)

                logger.debug(f"{stream_name} - Translated message: {json.dumps(translated_message, indent=2)}")

                # Send translated message
                new_content = json.dumps(translated_message)
                header = f"Content-Length: {len(new_content)}\r\n\r\n"

                output_stream.write(header.encode('utf-8'))
                output_stream.write(new_content.encode('utf-8'))
                output_stream.flush()

            except json.JSONDecodeError as e:
                logger.error(f"{stream_name} - JSON decode error: {e}")
            except Exception as e:
                logger.error(f"{stream_name} - Error processing message: {e}")

        except Exception as e:
            logger.error(f"{stream_name} - Error in stream handler: {e}")
            return

    logger.info(f"{stream_name} - Handler exiting")

def main():
    global shutdown_requested, ssh_process

    if len(sys.argv) < 4:
        logger.error("Usage: proxy.py <user@remote> <protocol> [--root-dir <dir>] <lsp_command> [args...]")
        sys.exit(1)

    remote = sys.argv[1]
    protocol = sys.argv[2]

    # Parse --root-dir option
    root_dir = None
    lsp_command_start = 3
    if len(sys.argv) > 4 and sys.argv[3] == "--root-dir":
        root_dir = sys.argv[4]
        lsp_command_start = 5
        logger.info(f"Root directory specified: {root_dir}")

    lsp_command = sys.argv[lsp_command_start:]

    logger.info(f"Starting proxy for {remote} using {protocol} with command: {' '.join(lsp_command)}")

    # Start SSH process
    try:
        # For most LSP servers, ensure proper environment setup by sourcing shell config files
        # This is needed because SSH non-interactive sessions don't source .bashrc by default
        # Many LSP servers (rust-analyzer, node servers, etc.) depend on PATH modifications in .bashrc
        lsp_command_str = ' '.join(lsp_command)
        needs_env_setup = any(x in lsp_command_str for x in [
            'node', 'npm', 'npx', 'typescript-language-server', 'vscode-langservers-extracted',
            'rust-analyzer', 'rls', 'cargo', 'rustc',  # Rust tools
            'pyright', 'pylsp', 'jedi-language-server',  # Python tools that might be in ~/.local/bin
            'clangd', 'ccls',  # C/C++ tools
            'gopls',  # Go tools
            'java', 'jdtls',  # Java tools
            'lua-language-server', 'sumneko_lua',  # Lua tools
        ])

        # Add working directory change if root_dir is specified
        import shlex
        cd_command = f"cd {shlex.quote(root_dir)} && " if root_dir else ""

        if needs_env_setup:
            # Comprehensive environment setup that covers most common installation paths
            env_setup = (
                "source ~/.bashrc 2>/dev/null || true; "
                "source ~/.profile 2>/dev/null || true; "
                "source ~/.zshrc 2>/dev/null || true; "  # Some users use zsh
                "export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH; "
                "export CARGO_HOME=$HOME/.cargo 2>/dev/null || true; "  # Ensure Cargo env is set
                "export RUSTUP_HOME=$HOME/.rustup 2>/dev/null || true; "  # Ensure Rustup env is set
            )
            full_command = f"{env_setup} {cd_command}{lsp_command_str}"
            ssh_cmd = ["ssh", "-q", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", remote, full_command]
            logger.info(f"Using environment setup for LSP server: {cd_command}{lsp_command_str}")
        else:
            if root_dir:
                # Use shell command to change directory and run LSP
                full_command = f"{cd_command}{lsp_command_str}"
                ssh_cmd = ["ssh", "-q", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", remote, full_command]
            else:
                ssh_cmd = ["ssh", "-q", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", remote] + lsp_command
            logger.info(f"Using direct command for LSP server: {cd_command}{lsp_command_str}")

        logger.info(f"Executing: {' '.join(ssh_cmd)}")

        ssh_process = subprocess.Popen(
            ssh_cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )

        logger.info(f"SSH process started with PID: {ssh_process.pid}")

        # Start stderr monitoring thread to catch any LSP server errors
        def monitor_stderr():
            while not shutdown_requested:
                try:
                    line = ssh_process.stderr.readline()
                    if not line:
                        break
                    error_msg = line.decode('utf-8', errors='replace').strip()
                    if error_msg:
                        logger.error(f"LSP server stderr: {error_msg}")
                except:
                    break

        stderr_thread = threading.Thread(target=monitor_stderr)
        stderr_thread.daemon = True
        stderr_thread.start()

    except Exception as e:
        logger.error(f"Failed to start SSH process: {e}")
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
        logger.info("Interrupted")
    finally:
        shutdown_requested = True
        if ssh_process.poll() is None:
            ssh_process.terminate()
        t1.join(timeout=2)
        t2.join(timeout=2)
        logger.info("Proxy terminated")

if __name__ == "__main__":
    main()
