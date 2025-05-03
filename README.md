# 🕹️ Remote SSH

Adds seamless support for working with remote files in Neovim via SSH, SCP, or rsync protocols, with integrated Language Server Protocol (LSP) and TreeSitter support. This plugin handles the complexities of connecting remote language servers with your local Neovim instance, allowing you to work with remote projects as if they were local.

> [!NOTE]
> This plugin takes a unique approach by running language servers on the remote machine while keeping the editing experience completely local. This gives you full LSP features without needing to install language servers locally.

## 🔄 How it works

This plugin takes a unique approach to remote development:

1. It launches language servers **directly on the remote machine**
2. A Python proxy script handles communication between Neovim and the remote language servers
3. The plugin automatically translates file paths between local and remote formats
4. File operations happen asynchronously to prevent UI freezing
5. TreeSitter is automatically enabled for remote file buffers to provide syntax highlighting

This approach gives you full LSP functionality without network latency affecting editing operations.

## ✨ Features

- **Seamless LSP integration** - Code completion, goto definition, documentation, and other LSP features work transparently with remote files
- **TreeSitter support** - Syntax highlighting via TreeSitter works for remote files
- **Asynchronous file operations** - Remote files are saved and fetched in the background without blocking your editor
- **Multiple language server support** - Ready-to-use configurations for popular language servers:

| Language Server                 | Current support      |
| --------------------------------| ---------------------|
| C/C++ (clangd)                  | _Fully supported_ ✅ |
| Zig (zls)                       | _Fully supported_ ✅ |
| Lua (lua_ls)                    | _Fully supported_ ✅ |
| Rust (rust-analyzer)            | _Fully supported_ ✅ |
| JavaScript/TypeScript(tsserver) | _Fully supported_ ✅ |
| Go (gopls)                      | _Fully supported_ ✅ |
| XML (lemminx)                   | _Fully supported_ ✅ |
| CMake (cmake)                   | _Fully supported_ ✅ |
| Python (pyright)                |  _Not supported_  ❌ |
| Bash (bashls)                   |  _Not supported_  ❌ |

- **Automatic server management** - Language servers are automatically started on the remote machine
- **Smart path handling** - Handles path translations between local and remote file systems
- **Robust error handling** - Graceful recovery for network hiccups and connection issues
- **Remote file browsing** - Browse and search remote directories with Telescope integration

## 📜 Requirements

### Local machine 💻

- Neovim >= 0.7.0
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- OpenSSH client
- Python 3

### Remote machine ☁️

- SSH server
- Language servers for your programming languages
- Python 3

## 📥 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "inhesrom/remote-ssh.nvim",
  dependencies = {
    "neovim/nvim-lspconfig", -- Required for LSP configuration
  },
  config = function()
    require('remote-ssh').setup({
      -- Your configuration here
    })
  end
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'inhesrom/remote-ssh.nvim',
  requires = {'neovim/nvim-lspconfig'},
  config = function()
    require('remote-ssh').setup({
      -- Your configuration here
    })
  end
}
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
    -- Example: Use pylsp instead of pyright for Python
    python = "pyright",
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

### Browsing remote directories with Telescope

```vim
:RemoteBrowse rsync://user@remote-host/path/to/directory
```

## 🤖 Available commands

| Primary Commands          | What does it do?                                                            |
| ------------------------- | --------------------------------------------------------------------------- |
| `:RemoteOpen`             | Open a remote file with scp:// or rsync:// protocol                         |
| `:RemoteBrowse`           | Browse a remote directory and open multiple files at once with Telescope    |
| `:RemoteBrowseFiles`      | Browse all files recursively in a remote directory with Telescope           |
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
