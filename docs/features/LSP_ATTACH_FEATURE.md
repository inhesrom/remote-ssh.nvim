# LSP PID Attachment Feature Proposal

## Overview

This document outlines a proposed feature for attaching to existing LSP server processes on remote machines by Process ID (PID), rather than always starting new LSP instances.

### Use Cases

- **Persistent Development Sessions**: Attach to LSP servers running in tmux/screen sessions
- **Resource Conservation**: Reuse expensive-to-start LSP servers (like rust-analyzer with large workspaces)
- **Development Workflow**: Maintain LSP state across Neovim restarts
- **Multi-Client Access**: Allow multiple Neovim instances to share the same remote LSP server

## Current Architecture Analysis

The existing system works by:

1. **proxy.py** launches new LSP servers via SSH and creates fresh processes
2. **client.lua** tracks running LSP clients by `server_name+host` combinations
3. Each new buffer either reuses an existing Neovim LSP client or starts a completely new LSP process
4. LSP communication happens through stdin/stdout pipes established during process spawn

### Current Reconnection Logic

Location: `lua/remote-lsp/client.lua:137-159`

```lua
-- Check if this server is already running for this host
local server_key = utils.get_server_key(server_name, host)
if buffer.server_buffers[server_key] then
    -- Find an existing client for this server and attach it to this buffer
    for client_id, info in pairs(M.active_lsp_clients) do
        if info.server_name == server_name and info.host == host then
            log("Reusing existing LSP client " .. client_id .. " for server " .. server_key)
            -- ... attach to buffer
        end
    end
end
```

This only reuses **Neovim LSP clients**, not the underlying remote LSP server processes.

## Challenges for PID-Based Attachment

### 1. Process Discovery & Validation

- **PID Validation**: Verify the PID exists and is actually an LSP server process
- **Server Type Detection**: Confirm it's the correct LSP server type (rust-analyzer, clangd, etc.)
- **Process Ownership**: Handle permission issues and process ownership
- **Stale PID Handling**: Gracefully handle cases where PID is dead or recycled

### 2. Communication Channel Establishment

- **Existing Pipes**: Running processes have their own stdin/stdout that we can't directly access
- **Process Substitution**: Need to redirect or intercept existing process I/O
- **Alternative Channels**: Consider named pipes, Unix sockets, or process attachment methods

### 3. LSP Protocol State Management

- **Workspace State**: Running LSP servers have existing workspace state and capabilities
- **Client Synchronization**: Neovim's LSP client needs to sync with server's current state
- **Root Directory**: Handle potential mismatches between expected and actual root directories
- **Initialization**: Skip or adapt LSP initialization for already-running servers

## Proposed Implementation Approaches

### Option 1: Process Attachment via Communication Bridge

**Concept**: Create a communication bridge that connects to an existing LSP process.

```lua
-- New function in client.lua
function M.attach_to_existing_lsp(server_name, host, pid, root_dir)
    -- 1. Validate PID exists and is correct LSP server
    local validate_cmd = string.format(
        "ssh %s 'ps -p %d -o comm= | grep -q %s && echo \"valid\"'",
        host, pid, server_name
    )

    -- 2. Create communication bridge to existing process
    local bridge_cmd = {
        "python3", "-u", proxy_path, host, protocol,
        "--attach-pid", tostring(pid),
        "--root-dir", root_dir
    }

    -- 3. Start LSP client that connects to existing process
    local client_id = vim.lsp.start({
        name = "remote_" .. server_name .. "_attached_" .. pid,
        cmd = bridge_cmd,
        root_dir = root_dir,
        capabilities = capabilities,
        on_attach = on_attach
    })

    return client_id
end
```

**Proxy Enhancement**:
```python
# Enhanced proxy.py
def attach_to_existing_process(host, pid, server_name):
    # Validate process exists and is correct type
    validate_cmd = f"ps -p {pid} -o comm= | grep -q {server_name}"
    result = subprocess.run(["ssh", host, validate_cmd])
    if result.returncode != 0:
        raise Exception(f"Invalid PID {pid} for {server_name}")

    # Create bidirectional communication with existing process
    # This is the challenging part - need process substitution or ptrace
    pass
```

### Option 2: Socket-Based Communication

**Concept**: Signal existing LSP to create a communication socket.

```python
# Enhanced proxy.py for socket attachment
def attach_via_socket(host, pid, server_name):
    # 1. Create named pipe or Unix socket on remote
    socket_path = f"/tmp/nvim_lsp_{server_name}_{pid}.sock"

    # 2. Signal existing LSP to bind to socket (if it supports this)
    # This would require LSP servers to handle SIGUSR1 or similar
    signal_cmd = f"ssh {host} 'kill -USR1 {pid}'"
    subprocess.run(signal_cmd.split())

    # 3. Connect to socket for LSP communication
    sock = create_ssh_socket_tunnel(host, socket_path)

    # 4. Proxy LSP messages through socket
    return proxy_through_socket(sock)
```

**Limitations**:
- Requires LSP servers to support socket creation on signal
- Most LSP servers don't have this capability built-in

### Option 3: Process Substitution Approach (Recommended)

**Concept**: Use process manipulation to redirect existing process I/O.

```python
# Modified proxy.py for PID attachment
def main():
    if "--attach-pid" in sys.argv:
        pid = int(sys.argv[sys.argv.index("--attach-pid") + 1])
        host = sys.argv[1]

        # Use advanced process substitution to tap into existing LSP
        # This is complex but most compatible approach
        ssh_cmd = [
            "ssh", host,
            f"""
            # Create named pipes for communication
            mkfifo /tmp/nvim_in_{pid} /tmp/nvim_out_{pid}

            # Use gdb/ptrace to redirect existing process I/O
            gdb -p {pid} -batch \\
                -ex 'call close(0)' \\
                -ex 'call close(1)' \\
                -ex 'call open("/tmp/nvim_in_{pid}", 0)' \\
                -ex 'call open("/tmp/nvim_out_{pid}", 1)' \\
                -ex 'detach' \\
                -ex 'quit' &

            # Bridge the named pipes to our stdin/stdout
            cat /tmp/nvim_out_{pid} &
            cat > /tmp/nvim_in_{pid}
            """
        ]

        # Execute the complex SSH command
        ssh_process = subprocess.Popen(ssh_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        # ... rest of proxy logic
```

**Alternative using socat**:
```bash
# On remote server, create bidirectional pipe to existing process
exec 3< <(cat) 4> >(cat)
gdb -p $PID -batch -ex 'call dup2(3,0)' -ex 'call dup2(4,1)' -ex 'detach' -ex 'quit'
```

## Implementation Strategy

### Phase 1: Discovery & Validation (Week 1-2)

**New Commands**:
```vim
:RemoteLspList host                    " List running LSP processes on host
:RemoteLspProcesses host pattern       " Search for LSP processes by pattern
```

**Implementation**:
```lua
-- In commands.lua
function M.list_remote_lsp_processes(host)
    local cmd = string.format(
        "ssh %s 'ps aux | grep -E \"(rust-analyzer|clangd|pylsp|lua-language-server)\" | grep -v grep'",
        host
    )

    local result = vim.fn.system(cmd)
    -- Parse and display results in a buffer or quickfix list
end
```

### Phase 2: Communication Bridge (Week 3-4)

**Extend proxy.py**:
- Add `--attach-pid` mode
- Implement process attachment using Option 3 (process substitution)
- Add robust error handling for attachment failures

**Test Cases**:
- Attach to rust-analyzer in existing workspace
- Handle PID that doesn't exist
- Handle PID that's not an LSP server
- Test communication after attachment

### Phase 3: Integration & Polish (Week 5-6)

**New Commands**:
```vim
:RemoteLspAttach server_name host pid root_dir  " Attach to existing LSP by PID
:RemoteLspDetach                                " Detach without killing remote process
:RemoteLspStatus                                " Show attachment status
```

**State Synchronization**:
- Query attached LSP server for current capabilities
- Sync workspace folders and file states
- Handle root directory mismatches gracefully

## Recommended Implementation: Option 3

**Why Process Substitution is Best**:

1. **Universal Compatibility**: Works with any LSP server using stdin/stdout
2. **No Server Modification**: Doesn't require LSP servers to support additional protocols
3. **Maintains Architecture**: Fits within existing proxy.py communication model
4. **Graceful Degradation**: Can fallback to normal process spawning if attachment fails

**Technical Requirements**:
- `gdb` or `ptrace` capability on remote systems
- Named pipe (`mkfifo`) support
- Appropriate permissions for process attachment

## Usage Examples

### Typical Workflow

```bash
# 1. Start a long-running LSP server in tmux
ssh myserver
tmux new -s development
cd /large/rust/project
rust-analyzer  # Let it index the project (may take 10+ minutes)

# 2. From Neovim, discover and attach
:RemoteLspList myserver
# Shows: rust-analyzer (PID: 12345) - /large/rust/project

:RemoteLspAttach rust_analyzer myserver 12345 /large/rust/project
# Now editing remote files gets instant LSP features

# 3. Later, detach without killing the server
:RemoteLspDetach
# rust-analyzer keeps running in tmux session
```

### Configuration

```lua
-- In remote-ssh setup
require('remote-ssh').setup({
    -- ... existing config

    -- Enable PID attachment features
    enable_pid_attachment = true,

    -- Attachment timeout (for process substitution)
    attachment_timeout = 10000,  -- 10 seconds

    -- Default behavior when multiple LSP instances found
    attachment_strategy = "prompt", -- "prompt" | "newest" | "oldest"
})
```

## Security Considerations

1. **Process Ownership**: Only allow attachment to processes owned by the SSH user
2. **PID Validation**: Verify PID corresponds to expected LSP server binary
3. **Permission Checks**: Ensure user has ptrace/gdb permissions if required
4. **Timeout Handling**: Prevent hanging on failed attachment attempts

## Future Enhancements

1. **LSP Server Discovery**: Auto-discover running LSP servers in common locations
2. **Persistent Sessions**: Save attachment information for automatic reconnection
3. **Multi-Client Support**: Allow multiple Neovim instances to share one LSP server
4. **Health Monitoring**: Detect when attached process dies and handle gracefully

## Conclusion

PID-based LSP attachment would significantly improve the development experience for large remote projects by allowing persistent LSP sessions. The process substitution approach provides the best balance of compatibility and functionality while maintaining the existing architecture's robustness.

Implementation complexity is moderate to high, but the benefits for users working with large remote codebases (especially Rust, C++, and other languages with expensive-to-start LSP servers) would be substantial.
