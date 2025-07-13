# 🕹️ Remote SSH

Adds seamless support for working with remote files in Neovim via SSH, SCP, or rsync protocols, with integrated Language Server Protocol (LSP) and TreeSitter support. This plugin handles the complexities of connecting remote language servers with your local Neovim instance, allowing you to work with remote projects as if they were local.

> [!NOTE]
> This plugin takes a unique approach by running language servers on the remote machine while keeping the editing experience completely local. This gives you full LSP features without needing to install language servers locally.

## 🔄 How it works

This plugin takes a unique approach to remote development, given the currently available remote neovim plugins:

```
┌─────────────┐    SSH     ┌──────────────┐
│   Neovim    │◄──────────►│ Remote Host  │
│  (Local)    │            │              │
│             │            │ ┌──────────┐ │
│ ┌─────────┐ │            │ │Language  │ │
│ │ LSP     │ │            │ │Server    │ │
│ │ Client  │ │            │ │          │ │
│ └─────────┘ │            │ │          │ │
└─────────────┘            │ └──────────┘ │
                           └──────────────┘
```

1. Opens a "Remote Buffer" - i.e. reads a remote file into a local buffer
2. It launches language servers **directly on the remote machine**
    - A Python proxy script handles communication between Neovim and the remote language servers
    - The plugin automatically translates file paths between local and remote formats
5. File operations like read and save happen asynchronously to prevent UI freezing
6. TreeSitter is automatically enabled for remote file buffers to provide syntax highlighting

This approach gives you code editing with LSP functionality without network latency affecting editing operations.

## 🚀 Quick Start

1. Install the plugin and restart Neovim
2. Open a remote file directly: `:RemoteOpen rsync://user@host//path/to_folder/file.cpp`
    - Or use `:RemoteTreeBrowser rsync://user@host//path/to_folder/`
        - This opens a file browser with browsable remote contents
3. LSP features will automatically work in most cases once the file opens

That's it! The plugin handles the rest automatically.

![RemoteTreeBrowser With Open Remote Buffers](./images/term.png)

## ✨ Features

- **Seamless LSP integration** - Code completion, goto definition, documentation, and other LSP features work transparently with remote files
- **TreeSitter support** - Syntax highlighting via TreeSitter works for remote files
- **Asynchronous file operations** - Remote files are saved and fetched in the background without blocking your editor
- **Multiple language server support** - Ready-to-use configurations for popular language servers:

| Language Server                 | Current support      |
| --------------------------------| ---------------------|
| C/C++ (clangd)                  | _Fully supported_ ✅ |
| Python (pylsp)                  | _Fully supported_ ✅ |
| Rust (rust-analyzer)            |  _Not supported_  ✅ |
| Lua (lua_ls)                    | _Fully supported_ ✅ |
| CMake (cmake)                   | _Fully supported_ ✅ |
| XML (lemminx)                   | _Fully supported_ ✅ |
| Zig (zls)                       | _Not tested_ 🟡      |
| Go (gopls)                      | _Not tested_ 🟡      |
| Java (jdtls)                      | _Not tested_ 🟡      |
| JavaScript/TypeScript(tsserver) | _Not tested_ 🟡      |
| Python (pyright)                |  _Not supported_  ❌ |
| Bash (bashls)                   |  _Not supported_  ❌ |

- **Automatic server management** - Language servers are automatically started on the remote machine
- **Smart path handling** - Handles path translations between local and remote file systems
- **Robust error handling** - Graceful recovery for network hiccups and connection issues
- **Remote file browsing** - Browse remote directories with tree-based file explorer
- **Enhanced telescope integration** - Use telescope-remote-buffer for advanced remote buffer navigation and searching

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
        'neovim/nvim-lspconfig',
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
    clangd = {},
    rust_analyzer = {},
    pylsp = {},
    lua_ls = {},
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

2. **Use Mason for automatic LSP server management**:

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
        log_level = vim.log.levels.INFO
    }
})
```

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
:RemoteTreeBrowse rsync://user@remote-host/path/to/directory
```

### Enhanced telescope integration

With telescope-remote-buffer, you get additional commands for managing remote buffers:

**Default keymaps** (configurable during setup as shown above):
- `<leader>fz` - Fuzzy search remote buffers
- `<leader>gb` - Browse remote buffers
- `<leader>rb` - Browse remote oldfiles

## 🤖 Available commands

| Primary Commands          | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteOpen`             | Open a remote file with scp:// or rsync:// protocol                         |
| `:RemoteTreeBrowse`       | Browse a remote directory with tree-based file explorer                     |
| `:RemoteGrep`             | Search for text in remote files using grep                                  |
| `:RemoteRefresh`          | Refresh a remote buffer by re-fetching its content                          |
| `:RemoteRefreshAll`       | Refresh all remote buffers                                                  |

| Debug Commands            | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteLspStart`         | Manually start LSP for the current remote buffer                            |
| `:RemoteLspStop`          | Stop all remote LSP servers and kill remote processes                       |
| `:RemoteLspRestart`       | Restart LSP server for the current buffer                                   |
| `:RemoteLspSetRoot`       | Set the root directory for the remote LSP server                            |
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
| `:TSRemoteHighlight`      | Manually enable TreeSitter highlighting for remote buffers                  |

## 🐛 Troubleshooting

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
   :lua print(vim.inspect(vim.lsp.get_active_clients()[1].server_capabilities))
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
I'll search the GitHub repositories you mentioned to verify and improve the accuracy of your comparison.Based on the repository information I found, here's a clearer and more accurate version:

## Neovim Remote SSH Solutions Comparison
1. **remote-nvim.nvim** (https://github.com/amitds1997/remote-nvim.nvim) - The most VS Code Remote SSH-like solution:
   * Automatically installs and launches Neovim on remote machines
   * Launches headless server on remote and connects TUI locally
   * Can copy over and sync your local Neovim configuration to remote
   * Supports SSH (password, key, ssh_config) and devcontainers
   * **Limitations**: Plugin has not yet reached maturity with breaking changes expected
   * Network latency inherent to the headless server + TUI approach

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
