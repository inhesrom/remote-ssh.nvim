# Remote LSP Architecture

This document explains how the remote LSP system works with the proxy mechanism in remote-ssh.nvim.

## Architecture Overview

The plugin implements a sophisticated proxy-based architecture that enables seamless LSP functionality for remote files. The system keeps editing local while running language servers on the remote machine where the code actually lives.

## Core Components

### 1. Python Proxy Script (`lua/remote-lsp/proxy.py`)

The proxy script is the core component that enables LSP communication between the local Neovim client and remote LSP servers. It acts as a bidirectional translator and relay.

**Key Functions:**
- **URI Translation**: Converts between local file URIs (`file:///path`) and remote URIs (`rsync://host/path` or `scp://host/path`)
- **Message Relay**: Forwards LSP messages between Neovim and the remote LSP server via SSH
- **Environment Setup**: Ensures proper shell environment on the remote machine for LSP servers (sources `.bashrc`, `.profile`, etc.)
- **Protocol Handling**: Manages the LSP protocol's Content-Length headers and JSON message format

### 2. LSP Client Manager (`lua/remote-lsp/client.lua`)

- Detects remote files by protocol (`scp://` or `rsync://`)
- Determines appropriate language server based on filetype
- Spawns proxy processes for each remote host/server combination
- Manages client lifecycle and cleanup

### 3. Buffer Integration (`lua/remote-lsp/buffer.lua`)

- Tracks which buffers use which LSP servers
- Handles buffer-specific LSP operations
- Manages save notifications to prevent disconnections
- Provides cleanup on buffer close

## Communication Flow

```
┌─────────────┐    stdin/stdout    ┌─────────────┐    SSH pipe    ┌─────────────┐
│   Neovim    │◄─────────────────►│   Proxy     │◄─────────────►│ Remote LSP  │
│ LSP Client  │                   │ (proxy.py)  │                │   Server    │
└─────────────┘                   └─────────────┘                └─────────────┘
       │                                 │                              │
       │                                 │                              │
   Local file                       URI Translation                Remote file
   URIs (file:///)                 & Message Relay                URIs (rsync://)
```

## How It Works Step-by-Step

1. **Remote File Detection**: When you open a remote file (`rsync://user@host/path/file.cpp`), the plugin detects the remote protocol

2. **Proxy Initialization**: The system spawns a Python proxy with:
   ```bash
   python3 proxy.py <host> <protocol> <lsp_command>
   ```

3. **SSH Connection**: The proxy establishes an SSH connection to the remote host and spawns the LSP server process there

4. **Bidirectional Communication**: Two threads handle message passing:
   - `neovim_to_ssh`: Forwards LSP requests from Neovim to remote server
   - `ssh_to_neovim`: Forwards LSP responses from remote server to Neovim

5. **URI Translation**: The proxy automatically translates file paths:
   - **Outbound**: `file:///local/path` → `rsync://host/remote/path`
   - **Inbound**: `rsync://host/remote/path` → `file:///local/path`

6. **LSP Protocol Handling**: Maintains proper LSP message format with Content-Length headers and JSON payloads

## Key Features

### Path Translation
- Handles multiple URI formats and edge cases
- Supports both `rsync://` and `scp://` protocols
- Normalizes paths to prevent URI parsing issues

**From Remote to Local** (for LSP responses):
- `rsync://host/path` → `file:///path`
- `scp://host/path` → `file:///path`
- Handles malformed URIs like `file://rsync://host/path`

**From Local to Remote** (for LSP requests):
- `file:///path` → `rsync://host/path`
- `file://path` → `rsync://host/path`

**Special Cases**:
- Double-slash handling: `rsync://host//path` → `file:///path`
- Path normalization to prevent URI issues

### Server Management

**Server Discovery** (`lua/remote-lsp/config.lua`):
- Maps file extensions to filetypes
- Maps filetypes to LSP server names
- Provides default configurations for 15+ language servers

**Server Lifecycle**:
1. **Startup**: Proxy spawns LSP server on remote machine with proper environment
2. **Tracking**: Buffers and clients are tracked to manage server reuse
3. **Shutdown**: Graceful shutdown with proper LSP exit sequence
4. **Cleanup**: Remote processes are killed when no longer needed

**Server Reuse**: Multiple buffers from the same host can share a single LSP server instance

### Error Handling
- Monitors SSH process health
- Handles network disconnections gracefully
- Provides comprehensive logging for debugging
- Implements proper timeout handling

### Performance Optimizations
- **Local Buffers**: Editing happens locally to eliminate latency
- **Async Operations**: File saves and LSP operations don't block UI
- **Caching**: Project root detection results are cached
- **Fast Mode**: Skip expensive remote operations when needed

## Proxy Communication Protocol

The proxy implements the LSP protocol exactly:

**Message Format**:
```
Content-Length: <byte_count>\r\n\r\n
<JSON_message_payload>
```

**Message Processing**:
1. Reads Content-Length header
2. Reads exact number of bytes for JSON payload
3. Parses JSON and performs URI translation
4. Forwards translated message to destination
5. Handles errors and EOF conditions gracefully

## Integration Points

### File Operations
- Integrates with async write system for remote file saves
- Notifies LSP servers about file changes
- Handles "go to definition" for remote files

### Project Management
- Searches remote filesystem for project markers (`.git`, `Cargo.toml`, etc.)
- Sets appropriate LSP root directories
- Supports multiple project structures

### Language Server Support
- Pre-configured for 15+ language servers
- Automatic filetype-to-server mapping
- Custom server configurations supported

### Advanced Features

**Project Root Detection**:
- Searches remote filesystem for project markers (`.git`, `Cargo.toml`, etc.)
- Caches results to avoid repeated SSH calls
- Supports fast mode that skips expensive remote operations

**Environment Setup**:
- Automatically sources shell configuration files
- Sets up PATH for language servers that need specific environments
- Handles different shell types (bash, zsh)

**Multi-Protocol Support**:
- Supports both `scp://` and `rsync://` protocols
- Handles protocol-specific URI translation
- Maintains compatibility with different remote access methods

## The Unique Advantage

This architecture provides the best of both worlds:

- **Local editing responsiveness** - No network latency for keystrokes
- **Remote LSP accuracy** - Language servers run where the code lives
- **Full LSP features** - Code completion, diagnostics, go-to-definition all work seamlessly
- **Simple setup** - No complex remote Neovim installations needed

The proxy handles all the complexity of translating between local and remote contexts, making remote development feel completely natural while maintaining the performance and feature completeness of local development.

## Comparison to Other Solutions

Unlike other remote development solutions that either:
1. Run everything remotely (introducing editing latency)
2. Run everything locally (losing project context)
3. Require complex setup and synchronization

This plugin provides a hybrid approach that combines local editing performance with remote LSP accuracy, requiring minimal setup while providing full language server functionality.
