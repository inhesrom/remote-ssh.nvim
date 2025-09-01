# 🕹️ Remote SSH

Edit remote files in Neovim with full LSP and TreeSitter support. This plugin runs language servers directly on remote machines while keeping your editing experience completely local, giving you the best of both worlds: responsive editing with full language features.

> [!NOTE]
> **Why this approach wins:** You get instant keystrokes and cursor movement (local editing) combined with accurate code intelligence that understands your entire remote project (remote LSP). No more choosing between responsiveness and functionality.

## 🔄 How it works

**The key insight:** Instead of running language servers locally (which lack remote project context) or editing remotely (which has network latency), this plugin runs language servers on the remote machine while keeping file editing completely local.

```
Local Neovim ←→ SSH ←→ Remote Language Server
(fast editing)       (full project context)
```

Here's what happens when you open a remote file:

1. **Fetch once:** Download the remote file to a local buffer for instant editing
2. **Connect LSP:** Start the language server on the remote machine with full project access
3. **Bridge communication:** Translate LSP messages between your local Neovim and remote server
4. **Save asynchronously:** File changes sync back to the remote machine in the background
5. **Enable TreeSitter:** Syntax highlighting works immediately on the local buffer

This gives you zero-latency editing with full LSP features like code completion, go-to-definition, and error checking.

## 🚀 Quick Start

### Prerequisites
- Passwordless SSH access to your remote server: `ssh user@host` (should work without password)
- Plugin installed and configured (see Installation section below)

### Steps
1. **Open a remote file:**
   ```vim
   :RemoteOpen rsync://user@host//path/to/file.cpp
   ```

2. **Or browse remote directories:**
   ```vim
   :RemoteTreeBrowser rsync://user@host//path/to/folder/
   ```
   Use `j/k` to navigate, `Enter` to open files, `q` to quit.

3. **Verify it works:**
   - You should see syntax highlighting immediately
   - LSP features (completion, hover, go-to-definition) should work within seconds
   - File saves happen automatically in the background

That's it! The plugin handles the rest automatically.

![RemoteTreeBrowser With Open Remote Buffers](./images/term.png)

## ✨ Features

### 🎯 Core Features
- **🧠 Full LSP Support** - Code completion, go-to-definition, hover documentation, and error checking work seamlessly
- **⚡ Zero-latency Editing** - All keystrokes and cursor movements happen instantly on local buffers
- **🎨 TreeSitter Syntax Highlighting** - Immediate syntax highlighting without network delays
- **💾 Smart Auto-save** - Files sync to remote machines asynchronously without blocking your workflow

### 🔧 Advanced Features  
- **👁️ File Change Detection** - Automatically detects when remote files are modified by others with conflict resolution
- **📁 Remote File Explorer** - Tree-based directory browsing with familiar navigation
- **🔍 Enhanced Search** - Telescope integration for searching remote buffers and file history
- **📚 Session History** - Track and quickly reopen recently used remote files and directories

### 🖥️ Language Server Support
Ready-to-use configurations for popular language servers:

**✅ Fully Supported & Tested:**
- **C/C++** (clangd) - Code completion, diagnostics, go-to-definition
- **Python** (pylsp) - Full IntelliSense with linting and formatting  
- **Rust** (rust-analyzer) - Advanced Rust language features
- **Lua** (lua_ls) - Neovim configuration and scripting support
- **CMake** (cmake-language-server) - Build system integration
- **XML** (lemminx) - Markup language support

**🟡 Available But Not Tested:**
- **Zig** (zls), **Go** (gopls), **Java** (jdtls)
- **JavaScript/TypeScript** (tsserver), **C#** (omnisharp)  
- **Python** (pyright), **Bash** (bashls)
> [!NOTE]
> If you find that desired LSP is not listed here, try testing it out, if it works (or not), open a GitHub issue and we can get it added to this list with the correct status

### 🛠️ Technical Features
- **Automatic Server Management** - Language servers start automatically on remote machines
- **Smart Path Translation** - Seamless handling of local vs remote file paths for LSP
- **Robust Error Recovery** - Graceful handling of network issues and connection problems

## 📜 Requirements

### Local machine 💻

- Neovim >= 0.10.0
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- OpenSSH client
- Python 3
- rsync

### Remote machine ☁️

- SSH server
- Language servers for your programming languages
- Python 3
- rsync
- find (for directory browsing)
- grep (for remote file searching)

### 💻 Platform Support

| Platform | Support |
|----------|----------|
| Linux    | ✅ Full |
| macOS    | ✅ Full |
| Windows  | 🟡 WSL recommended |

## 📥 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "inhesrom/remote-ssh.nvim",
    branch = "master",
    dependencies = {
        "inhesrom/telescope-remote-buffer", --See https://github.com/inhesrom/telescope-remote-buffer for features
        "nvim-telescope/telescope.nvim",
        "nvim-lua/plenary.nvim",
        "neovim/nvim-lspconfig",
        -- nvim-notify is recommended, but not necessarily required into order to get notifcations during operations - https://github.com/rcarriga/nvim-notify
        "rcarriga/nvim-notify",
    },
    config = function ()
        require('telescope-remote-buffer').setup(
            -- Default keymaps to open telescope and search open buffers including "remote" open buffers
            --fzf = "<leader>fz",
            --match = "<leader>gb",
            --oldfiles = "<leader>rb"
        )

        -- setup lsp_config here or import from part of neovim config that sets up LSP

        require('remote-ssh').setup({
            on_attach = lsp_config.on_attach,
            capabilities = lsp_config.capabilities,
            filetype_to_server = lsp_config.filetype_to_server
        })
    end
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
    'inhesrom/remote-ssh.nvim',
    branch = "master",
    requires = {
        "inhesrom/telescope-remote-buffer",
        "nvim-telescope/telescope.nvim",
        "nvim-lua/plenary.nvim",
        'neovim/nvim-lspconfig',
    },
    config = function()
        require('telescope-remote-buffer').setup()

        -- setup lsp_config here or import from part of neovim config that sets up LSP

        require('remote-ssh').setup({
            on_attach = lsp_config.on_attach,
            capabilities = lsp_config.capabilities,
            filetype_to_server = lsp_config.filetype_to_server
        })
    end
}
```

## 🔧 Setup Prerequisites

### SSH Key Configuration (Required)

For seamless remote development, you need passwordless SSH access to your remote servers:

```bash
# Generate SSH key if you don't have one
ssh-keygen -t ed25519 -C "your_email@example.com"

# Copy key to remote server
ssh-copy-id user@remote-server

# Test passwordless connection
ssh user@remote-server
```

### LSP Configuration Setup

You'll need to configure LSP servers for the plugin to work properly. Here's a basic setup:

1. **Create an LSP utility file** (e.g., `lsp_util.lua`):

```lua
-- lsp_util.lua
local M = {}

-- LSP on_attach function with key mappings
M.on_attach = function(client, bufnr)
    local nmap = function(keys, func, desc)
        vim.keymap.set('n', keys, func, { buffer = bufnr, desc = desc })
    end

    -- Key mappings
    nmap('gd', require('telescope.builtin').lsp_definitions, '[G]oto [D]efinition')
    nmap('gr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')
    nmap('gI', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')
    nmap('K', vim.lsp.buf.hover, 'Hover Documentation')
    nmap('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
    nmap('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')
end

-- LSP capabilities
local capabilities = vim.lsp.protocol.make_client_capabilities()
M.capabilities = require('cmp_nvim_lsp').default_capabilities(capabilities)

-- Server definitions
M.servers = {
    clangd = {},            -- C/C++
    rust_analyzer = {},     -- Rust
    pylsp = {},             -- Python
    lua_ls = {},            -- Lua
    -- Add more servers as needed
}

-- Generate filetype to server mapping
M.filetype_to_server = {}
for server_name, _ in pairs(M.servers) do
    local filetypes = require('lspconfig')[server_name].document_config.default_config.filetypes or {}
    for _, ft in ipairs(filetypes) do
        M.filetype_to_server[ft] = server_name
    end
end

return M
```

2. **Use Mason for automatic local LSP management/installation**:
> [!NOTE]
> You will need to manually ensure that the corresponding remote LSP is installed on the remote host

```lua
-- In your plugin configuration
{
    'williamboman/mason.nvim',
    dependencies = { 'williamboman/mason-lspconfig.nvim' },
    config = function()
        require('mason').setup()
        require('mason-lspconfig').setup({
            ensure_installed = vim.tbl_keys(require('lsp_util').servers),
        })
    end
}
```

## 🌐 Remote Server Setup

### Language Server Installation

Install the required language servers on your remote development machines:

#### Python (pylsp)
```bash
# On remote server
pip3 install python-lsp-server[all]
# Optional: for better performance
pip3 install python-lsp-ruff  # Fast linting
```

#### C/C++ (clangd)
```bash
# Ubuntu/Debian
sudo apt install clangd

# CentOS/RHEL/Rocky
sudo dnf install clang-tools-extra

# macOS
brew install llvm

# Arch Linux
sudo pacman -S clang
```

#### Rust (rust-analyzer)
```bash
# Install via rustup (recommended)
rustup component add rust-analyzer

# Or via package manager
# Ubuntu 22.04+: sudo apt install rust-analyzer
# macOS: brew install rust-analyzer
# Arch: sudo pacman -S rust-analyzer
```

#### Lua (lua-language-server)
```bash
# Ubuntu/Debian (if available in repos)
sudo apt install lua-language-server

# macOS
brew install lua-language-server

# Or install manually from releases:
# https://github.com/LuaLS/lua-language-server/releases
```

#### Java (jdtls)
```bash
# Install Java first
sudo apt install openjdk-17-jdk  # Ubuntu
brew install openjdk@17          # macOS

# jdtls will be automatically downloaded by Mason
```

#### CMake (cmake-language-server)
```bash
# Install via pip
pip3 install cmake-language-server

# Or via package manager
sudo apt install cmake-language-server  # Ubuntu 22.04+
```

### Remote System Requirements

Ensure your remote systems have the following:

```bash
# Check Python 3 availability
python3 --version

# Check rsync availability
rsync --version

# Verify SSH server is running
systemctl status ssh  # Ubuntu/Debian
systemctl status sshd # CentOS/RHEL

# Test SSH access
ssh user@remote-server "echo 'SSH working'"
```

## ⚙️ Configuration

Here's a default configuration with comments explaining each option:

```lua
require('remote-ssh').setup({
    -- Optional: Custom on_attach function for LSP clients
    on_attach = function(client, bufnr)
        -- Your LSP keybindings and setup
    end,

    -- Optional: Custom capabilities for LSP clients
    capabilities = vim.lsp.protocol.make_client_capabilities(),

    -- Custom mapping from filetype to LSP server name
    filetype_to_server = {
        -- Example: Use pylsp for Python (default and recommended)
        python = "pylsp",
        -- More customizations...
    },

    -- Custom server configurations
    server_configs = {
        -- Custom config for clangd
        clangd = {
            filetypes = { "c", "cpp", "objc", "objcpp" },
            root_patterns = { ".git", "compile_commands.json" },
            init_options = {
                usePlaceholders = true,
                completeUnimported = true
            }
        },
        -- More server configs...
    },

    -- Async write configuration
    async_write_opts = {
        timeout = 30,         -- Timeout in seconds for write operations
        debug = false,        -- Enable debug logging
        log_level = vim.log.levels.INFO,
        autosave = true,      -- Enable automatic saving on text changes (default: true)
                              -- Set to false to disable auto-save while keeping manual saves (:w) working
        save_debounce_ms = 3000 -- Delay before initiating auto-save to handle rapid editing (default: 3000)
    }
})
```

### Autosave Configuration

The plugin includes an intelligent autosave feature that automatically saves remote files as you edit them. This feature is enabled by default but can be customized or disabled:

**Enable autosave (default behavior):**
```lua
require('remote-ssh').setup({
    async_write_opts = {
        autosave = true,        -- Auto-save on text changes
        save_debounce_ms = 3000 -- Wait 3 seconds after editing before saving
    }
})
```

**Disable autosave while keeping manual saves working:**
```lua
require('remote-ssh').setup({
    async_write_opts = {
        autosave = false  -- Disable auto-save, but `:w` still works
    }
})
```

**Note:** Manual saves (`:w`, `:write`) always work regardless of the autosave setting. When autosave is disabled, you'll need to manually save your changes using `:w` or similar commands.

## 🎥 Examples

### Opening and editing remote files

```bash
# In your terminal
nvim rsync://user@remote-host/path/to/file.cpp
```

Or from within Neovim:

```vim
:e rsync://user@remote-host/path/to/file.cpp
```

### Using the RemoteOpen command

```vim
:RemoteOpen rsync://user@remote-host/path/to/file.cpp
```

### Browsing remote directories

```vim
:RemoteTreeBrowser rsync://user@remote-host/path/to/directory
```

### Enhanced telescope integration

With telescope-remote-buffer, you get additional commands for managing remote buffers:

**Default keymaps** (configurable during setup as shown above):
- `<leader>fz` - Fuzzy search remote buffers
- `<leader>gb` - Browse remote buffers
- `<leader>rb` - Browse remote oldfiles

## 👁️ Remote File Watching

The plugin includes an intelligent file watching system that monitors remote files for changes made by other users or processes. This helps prevent conflicts and keeps your local buffer synchronized with the remote file state.

### How it Works

1. **Automatic Detection**: When you open a remote file, the file watcher automatically starts monitoring it
2. **Change Detection**: Uses SSH to periodically check the remote file's modification time (mtime)
3. **Smart Conflict Resolution**: Distinguishes between changes from your own saves vs. external changes
4. **Conflict Handling**: When conflicts are detected, you'll be notified and can choose how to resolve them

### Conflict Resolution Strategies

- **No Conflict**: Remote file hasn't changed since your last interaction
- **Safe to Pull**: Remote file changed, but you have no unsaved local changes - automatically pulls the remote content
- **Conflict Detected**: Both local and remote files have changes - requires manual resolution

### File Watcher Configuration

You can configure the file watcher behavior for each buffer, if you find the defaults are not working for you:

```vim
" Set poll interval to 10 seconds
:RemoteWatchConfigure poll_interval 10000

" Enable auto-refresh (automatically pull non-conflicting changes)
:RemoteWatchConfigure auto_refresh true

" Disable file watching for current buffer
:RemoteWatchConfigure enabled false
```

### SSH Config Alias Support

The file watcher supports SSH config aliases, allowing you to use simplified hostnames:

```bash
# ~/.ssh/config
Host myserver
    HostName server.example.com
    User myuser
    Port 2222
```

Then use in Neovim:
```vim
:RemoteOpen rsync://myserver-alias//path/to/file.cpp
```

Note the double slash (`//`) format which is automatically detected and handled.

## 📚 Remote Session History

The plugin includes a comprehensive session history feature that tracks all your remote file and directory access, providing quick navigation to recently used items.

### Features

- **🎨 File Type Icons**: Shows proper file type icons with colors (using nvim-web-devicons if available)
- **📌 Pin Favorites**: Pin frequently used sessions to keep them at the top
- **🔍 Smart Filtering**: Filter sessions by filename or hostname
- **💾 Persistent Storage**: History persists across Neovim sessions
- **📁 Mixed Content**: Tracks both individual files and directory browsing sessions
- **⚡ Fast Navigation**: Quickly jump to any previously accessed remote location

### Usage

```vim
:RemoteHistory
```

Opens a floating window with your session history where you can:

- **Navigate**: Use `j/k` or arrow keys to move through sessions
- **Open**: Press `Enter` or `Space` to open the selected session
- **Pin/Unpin**: Press `p` to pin or unpin sessions
- **Filter**: Press `/` to enter filter mode, then type to search
- **Exit**: Press `q` or `Esc` to close the picker

### Display Format

Each session shows: `[PIN] [TIME] [HOST] [ICON] [PATH] [(pinned)]`

Example:
```
▶ 📌 12/04 14:30 myserver  /home/user/config.lua (pinned)
   12/04 14:25 myserver 📁 /home/user/project
   12/04 14:20 devbox 🐍 /app/main.py
   12/04 14:15 myserver 📝 /home/user/README.md
```

### Automatic Tracking

Sessions are automatically tracked when you:
- Open remote files using `:RemoteOpen` or `:e rsync://...`
- Browse remote directories using `:RemoteTreeBrowser`
- Use any command that opens remote content

### Configuration

- **Storage**: Sessions saved to `~/.local/share/nvim/remote-ssh-sessions.json`
- **History Limit**: Default 100 entries (configurable)
- **Window Size**: Dynamically sized to fit content (minimum 60x10, maximum available screen space)
- **Auto-save**: Changes saved immediately and on Neovim exit

## 🤖 Available commands

| Primary Commands          | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteOpen`             | Open a remote file with scp:// or rsync:// protocol                         |
| `:RemoteTreeBrowser`       | Browse a remote directory with tree-based file explorer                     |
| `:RemoteTreeBrowserHide`       | Hide the remote file browser                     |
| `:RemoteTreeBrowserShow`       | Show the remote file browser                     |
| `:RemoteHistory`          | Open remote session history picker with pinned items and filtering          |
| `:RemoteGrep`             | Search for text in remote files using grep                                  |
| `:RemoteRefresh`          | Refresh a remote buffer by re-fetching its content                          |
| `:RemoteRefreshAll`       | Refresh all remote buffers                                                  |

| Remote History Commands   | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteHistory`          | Open session history picker with pinned items and filtering                 |
| `:RemoteHistoryClear`     | Clear remote session history                                                |
| `:RemoteHistoryClearPinned` | Clear pinned remote sessions                                              |
| `:RemoteHistoryStats`     | Show remote session history statistics                                      |

| File Watcher Commands     | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteWatchStart`       | Start file watching for current buffer (monitors remote changes)            |
| `:RemoteWatchStop`        | Stop file watching for current buffer                                       |
| `:RemoteWatchStatus`      | Show file watching status for current buffer                                |
| `:RemoteWatchRefresh`     | Force refresh from remote (overwrite local changes)                         |
| `:RemoteWatchConfigure`   | Configure file watcher settings (enabled, poll_interval, auto_refresh)      |
| `:RemoteWatchDebug`       | Debug file watcher SSH connection and commands                              |

| Debug Commands            | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteLspStart`         | Manually start LSP for the current remote buffer                            |
| `:RemoteLspStop`          | Stop all remote LSP servers and kill remote processes                       |
| `:RemoteLspRestart`       | Restart LSP server for the current buffer                                   |
| `:RemoteLspSetRoot`       | Manually set the root directory for the remote LSP server, override automatic discovery                            |
| `:RemoteLspServers`       | List available remote LSP servers                                           |
| `:RemoteLspDebug`         | Print debug information about remote LSP clients                            |
| `:RemoteLspDebugTraffic`  | Enable/disable LSP traffic debugging                                        |
| `:RemoteFileStatus`       | Show status of remote file operations                                       |
| `:AsyncWriteCancel`       | Cancel ongoing asynchronous write operation                                 |
| `:AsyncWriteStatus`       | Show status of active asynchronous write operations                         |
| `:AsyncWriteForceComplete`| Force complete a stuck write operation                                      |
| `:AsyncWriteDebug`        | Toggle debugging for async write operations                                 |
| `:AsyncWriteLogLevel`     | Set the logging level (DEBUG, INFO, WARN, ERROR)                            |
| `:AsyncWriteReregister`   | Reregister buffer-specific autocommands for current buffer                  |
| `:RemoteDependencyCheck`  | Check all plugin dependencies (local tools, Neovim, Lua modules, SSH hosts) |
| `:RemoteDependencyQuickCheck` | Quick dependency status overview with summary                           |
| `:TSRemoteHighlight`      | Manually enable TreeSitter highlighting for remote buffers                  |

## 🔍 Dependency Checking

The plugin includes a comprehensive dependency checking system to help diagnose setup issues and ensure all required components are properly installed and configured.

### Quick Status Check

For a rapid overview of your system status:

```vim
:RemoteDependencyQuickCheck
```

This provides a simple ✅/⚠️/❌ status indicator and tells you if critical dependencies are missing.

### Comprehensive Dependency Check

For detailed diagnostics and troubleshooting:

```vim
:RemoteDependencyCheck
```

This performs a thorough check of:

**Local Machine:**
- ✅ **System Tools**: `ssh`, `scp`, `rsync`, `python3`, `stat`
- ✅ **Neovim Version**: >= 0.10.0 requirement
- ✅ **Lua Dependencies**: `plenary.nvim`, `nvim-lspconfig`, `telescope.nvim` (optional), `nvim-notify` (optional)

**Remote Hosts:**
- 🔗 **SSH Connectivity**: Tests passwordless SSH access and response times
- 🛠️ **Remote Tools**: `python3`, `rsync`, `find`, `grep`, `stat`, `ls`
- 📡 **Auto-discovery**: Automatically finds hosts from `~/.ssh/config`

### Host-Specific Checking

You can check specific hosts instead of auto-discovery:

```vim
" Single host
:RemoteDependencyCheck myserver

" Multiple hosts
:RemoteDependencyCheck server1,server2,server3
```

### Understanding the Output

The dependency checker provides color-coded results:

- ✅ **Green**: Component is properly installed and working
- ⚠️ **Yellow**: Optional component missing or minor issues
- ❌ **Red**: Critical dependency missing - plugin won't work properly

Each failed dependency includes:
- Detailed error messages
- Version information where available
- Specific recommendations for fixing the issue

### Common Issues Detected

The dependency checker will identify issues like:
- Missing `rsync` (prevents RemoteOpen from working)
- SSH connectivity problems (timeouts, authentication failures)
- Missing Neovim plugins (`plenary.nvim`, `nvim-lspconfig`)
- Outdated Neovim version
- Missing remote tools needed for directory browsing
- SSH configuration problems

**💡 Pro tip**: Run `:RemoteDependencyCheck` after initial setup to ensure everything is configured correctly, and whenever you encounter issues with RemoteOpen or RemoteTreeBrowser.

## 🐛 Troubleshooting

### First Steps

Before diving into specific troubleshooting steps, always start with the dependency checker:

```vim
:RemoteDependencyCheck
```

This will identify most common setup issues including missing dependencies, SSH configuration problems, and plugin installation issues.

### Common Issues

#### LSP Server Not Starting

**Symptoms**: No LSP features (completion, hover, etc.) in remote files

**Solutions**:
1. **Check if language server is installed on remote**:
   ```bash
   ssh user@server "which clangd"  # Example for clangd
   ssh user@server "which rust-analyzer"  # Example for rust-analyzer
   ```

2. **Verify Mason installation locally**:
   ```vim
   :Mason
   :MasonLog
   ```

3. **Check LSP client status**:
   ```vim
   :LspInfo
   :RemoteLspDebug
   ```

4. **Enable LSP debug logging**:
   ```vim
   :RemoteLspDebugTraffic on
   :LspLog
   ```

#### SSH Connection Issues

**Symptoms**: "Connection refused", "Permission denied", or timeout errors

**Solutions**:
1. **Test basic SSH connectivity**:
   ```bash
   ssh user@server
   ```

2. **Check SSH key authentication**:
   ```bash
   ssh-add -l  # List loaded keys
   ssh user@server "echo SSH key auth working"
   ```

3. **Verify SSH config**:
   ```bash
   # Add to ~/.ssh/config
   Host myserver
       HostName server.example.com
       User myuser
       IdentityFile ~/.ssh/id_ed25519
   ```

4. **Check remote SSH server status**:
   ```bash
   ssh user@server "systemctl status sshd"
   ```

#### Remote File Access Issues

**Symptoms**: Files won't open, save, or refresh

**Solutions**:
1. **Check file permissions**:
   ```bash
   ssh user@server "ls -la /path/to/file"
   ```

2. **Verify rsync availability**:
   ```bash
   ssh user@server "rsync --version"
   ```

3. **Test file operations manually**:
   ```bash
   rsync user@server:/path/to/file /tmp/test-file
   ```

4. **Check async write status**:
   ```vim
   :AsyncWriteStatus
   :RemoteFileStatus
   ```

#### Python/Proxy Issues

**Symptoms**: "Python not found" or proxy connection errors

**Solutions**:
1. **Check Python 3 on remote**:
   ```bash
   ssh user@server "python3 --version"
   ssh user@server "which python3"
   ```

2. **Verify proxy script permissions**:
   ```bash
   ls -la ~/.local/share/nvim/lazy/remote-ssh.nvim/lua/remote-lsp/proxy.py
   ```

3. **Check proxy logs**:
   ```bash
   ls -la ~/.cache/nvim/remote_lsp_logs/
   ```

#### Completion Not Working

**Symptoms**: No autocomplete suggestions in remote files

**Solutions**:
1. **Check nvim-cmp configuration**:
   ```vim
   :lua print(vim.inspect(require('cmp').get_config()))
   ```

2. **Verify LSP client attachment**:
   ```vim
   :LspInfo
   ```

3. **Check LSP server capabilities**:
   ```vim
   :lua print(vim.inspect(vim.lsp.get_clients()[1].server_capabilities))
   ```

#### File Watcher Issues

**Symptoms**: File watcher shows "not a remote buffer" or doesn't detect changes

**Solutions**:
1. **Check if file watcher is running**:
   ```vim
   :RemoteWatchStatus
   ```

2. **Test SSH connection manually**:
   ```vim
   :RemoteWatchDebug
   ```

3. **Verify SSH config alias setup**:
   ```bash
   # Test SSH config alias
   ssh myserver "echo 'SSH alias working'"
   ```

4. **Check file watcher logs**:
   ```vim
   :AsyncWriteDebug  # Enable debug logging
   :AsyncWriteLogLevel DEBUG
   ```

5. **Restart file watcher**:
   ```vim
   :RemoteWatchStop
   :RemoteWatchStart
   ```

**Symptoms**: File watcher causing UI blocking or performance issues

**Solutions**:
1. **Increase poll interval**:
   ```vim
   :RemoteWatchConfigure poll_interval 10000  # 10 seconds
   ```

2. **Check for SSH connection multiplexing**:
   ```bash
   # Add to ~/.ssh/config
   Host *
       ControlMaster auto
       ControlPath ~/.ssh/control-%r@%h:%p
       ControlPersist 10m
   ```

### Debug Commands Reference

```vim
# LSP Debugging
:RemoteLspDebug           # Show remote LSP client information
:RemoteLspServers         # List available LSP servers
:RemoteLspDebugTraffic on # Enable LSP traffic debugging
:LspInfo                  # Show LSP client information
:LspLog                   # View LSP logs

# File Operation Debugging
:RemoteFileStatus         # Show remote file operation status
:AsyncWriteStatus         # Show async write operation status
:AsyncWriteDebug          # Toggle async write debugging

# File Watcher Debugging
:RemoteWatchStatus        # Show file watcher status for current buffer
:RemoteWatchDebug         # Test SSH connection and debug file watcher
:RemoteWatchStart         # Start file watching for current buffer
:RemoteWatchStop          # Stop file watching for current buffer

# Dependency Checking
:RemoteDependencyCheck    # Comprehensive dependency check with detailed report
:RemoteDependencyQuickCheck  # Quick dependency status check

# General Debugging
:checkhealth              # General Neovim health check
:Mason                    # Open Mason UI for server management
:MasonLog                 # View Mason installation logs
```

### Performance Tips

1. **Use SSH connection multiplexing**:
   ```bash
   # Add to ~/.ssh/config
   Host *
       ControlMaster auto
       ControlPath ~/.ssh/control-%r@%h:%p
       ControlPersist 10m
   ```

2. **Configure SSH keep-alive**:
   ```bash
   # Add to ~/.ssh/config
   Host *
       ServerAliveInterval 60
       ServerAliveCountMax 3
   ```

3. **Optimize rsync transfers**:
   ```bash
   # For large files, consider compression
   Host myserver
       Compression yes
   ```

## ⚠️ Caveats

- Language servers must be installed on the remote machine
- SSH access to the remote machine is required
- Performance depends on network connection quality
- For very large projects, initial LSP startup may take longer

## 📝 Tips for best experience

1. **SSH Config**: Using SSH config file entries can simplify working with remote hosts
2. **Language Servers**: Ensure language servers are properly installed on remote systems
3. **Project Structure**: For best results, work with proper project structures that language servers can recognize
4. **Network**: A stable network connection improves the overall experience

## FAQ

### Why use this plugin instead of just mounting remote directories locally?

While mounting remote directories (via SSHFS, etc.) is a valid approach, it has several drawbacks:
- Network latency affects every file operation
- Syncing large projects can be time-consuming
- Language servers running locally might not have access to the full project context

This plugin runs language servers directly on the remote machine where your code lives, providing a more responsive experience with full access to project context.

### How does this differ from Neovim's built-in remote file editing?

Neovim's built-in remote file editing doesn't provide LSP support. This plugin extends the built-in functionality by:
1. Enabling LSP features for remote files
2. Providing asynchronous file saving
3. Handling the complexities of remote path translation for LSP
4. Adding TreeSitter support for syntax highlighting
5. Providing commands for browsing and searching remote directories

## Comparison to other Remote Neovim Plugins
1. **remote-nvim.nvim** (https://github.com/amitds1997/remote-nvim.nvim) - The most VS Code Remote SSH-like solution:
   * Automatically installs and launches Neovim on remote machines
   * Launches headless server on remote and connects TUI locally
   * Can copy over and sync your local Neovim configuration to remote
   * Supports SSH (password, key, ssh_config) and devcontainers
   * **Limitations**: Plugin has not yet reached maturity with breaking changes expected
   * Network latency inherent to the headless server + TUI approach
   * Remote server may not be able to access generic internet content in some controlled developement environments

2. **distant.nvim** (https://github.com/chipsenkbeil/distant.nvim) - Theoretically addresses latency:
   * Alpha stage software in rapid development and may break or change frequently
   * Requires distant 0.20.x binary installation on both local and remote machines
   * Requires neovim 0.8+
   * **Limitations**: Limited documentation and setup complexity; experimental status makes it unreliable for production use

3. **This remote-ssh.nvim** (https://github.com/inhesrom/remote-ssh.nvim):
   * Uses SSH for all file operations
   * Syncs buffer contents locally to eliminate editing lag
   * Only requires language server installation on remote (supports clangd for C++, pylsp for Python)
   * Includes tree-based remote file browser (`:RemoteTreeBrowser`)
   * Focused on simplicity and immediate usability
   * **Limitations**: Plugin has not yet reached maturity with breaking changes expected

The key trade-off is between feature completeness (remote-nvim.nvim) and responsiveness (this plugin's local buffer approach).

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

- Report bugs via GitHub Issues
- Submit feature requests
- Contribute code via Pull Requests
- Improve documentation

## Buy Me a Coffee
If you feel so inclined, out of appreciation for this work, send a coffee my way!
[Buy Me a Coffee Link](https://coff.ee/inhesrom)

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
