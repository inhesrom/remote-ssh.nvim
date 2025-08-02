# Remote Gitsigns Integration

This document describes the remote gitsigns functionality that provides Git signs and status for remote files accessed via SSH.

## Overview

The remote gitsigns integration extends remote-ssh.nvim to provide gitsigns functionality for remote files. It automatically detects when remote buffers are part of Git repositories and enables the same Git status indicators you get with local files.

## Features

- **Automatic Detection**: Automatically detects remote Git repositories
- **Git Signs**: Shows added, changed, and deleted lines in the sign column
- **Git Status**: Provides git status information for remote files
- **Caching**: Intelligent caching system for performance
- **SSH Integration**: Uses existing SSH connections from remote-lsp
- **Transparent Operation**: Works seamlessly with existing gitsigns configuration

## Setup

### Basic Configuration

Add gitsigns configuration to your remote-ssh setup:

```lua
require('remote-ssh').setup({
    -- ... your existing remote-ssh config ...
    
    gitsigns = {
        enabled = true,
    }
})
```

### Advanced Configuration

```lua
require('remote-ssh').setup({
    -- ... your existing remote-ssh config ...
    
    gitsigns = {
        -- Enable remote gitsigns integration
        enabled = true,
        
        -- Timeout for Git operations (milliseconds)
        git_timeout = 30000,
        
        -- Cache configuration
        cache = {
            enabled = true,
            ttl = 300, -- 5 minutes
            max_entries = 1000,
            cleanup_enabled = true,
            cleanup_interval = 60, -- 1 minute
        },
        
        -- Buffer detection configuration
        detection = {
            -- Enable async detection to avoid blocking
            async_detection = true,
            
            -- File patterns to exclude from git detection
            exclude_patterns = {
                '*/%.git/*',
                '*/node_modules/*',
                '*/__pycache__/*',
                '*/%.venv/*',
                '*/venv/*',
                '*/%.env/*',
            },
            
            -- Timeout for git operations during detection
            detection_timeout = 10000, -- 10 seconds
        },
        
        -- Automatically attach gitsigns to detected remote git buffers
        auto_attach = true,
        
        -- Debug mode
        debug = false,
    }
})
```

## Requirements

1. **gitsigns.nvim**: Must be installed and available
2. **Git on Remote Host**: Git must be installed on the remote server
3. **SSH Access**: Working SSH connection to the remote host
4. **Git Repository**: Remote files must be in a Git repository

## How It Works

### 1. Detection

When you open a remote file (via `scp://` or `rsync://` URLs), the system:

1. Checks if the file is part of a Git repository on the remote host
2. Finds the Git repository root directory
3. Registers the buffer with the git adapter

### 2. Git Command Interception

The adapter intercepts gitsigns' git commands and:

1. Detects when the command is for a remote buffer
2. Translates the command to run on the remote host via SSH
3. Returns results in the format gitsigns expects

### 3. Caching

To improve performance, the system caches:

- Git repository discovery results
- Repository information (root, head, etc.)
- File status information
- Git command outputs

## User Commands

The integration provides several user commands for manual control:

### `:RemoteGitsignsDetect [bufnr]`

Manually trigger git repository detection for a buffer:

```vim
:RemoteGitsignsDetect        " Detect current buffer
:RemoteGitsignsDetect 123    " Detect buffer 123
```

### `:RemoteGitsignsStats`

Show cache statistics:

```vim
:RemoteGitsignsStats
```

Output example:
```
Remote Gitsigns Cache Statistics:
  Enabled: true
  Hits: 45
  Misses: 12
  Hit Rate: 78.95%
  Current Size: 23/1000
  Expired: 2
  Evictions: 0
  Cleanups: 1
  TTL: 300s
```

### `:RemoteGitsignsClearCache`

Clear all cached git data:

```vim
:RemoteGitsignsClearCache
```

### `:RemoteGitsignsStatus`

Show the current status of remote gitsigns:

```vim
:RemoteGitsignsStatus
```

Output example:
```
Remote Gitsigns Status:
  Enabled: true
  Git Adapter Active: true
  Current Buffer (123):
    Git Repository: true
    Git Root: /home/user/project
    Host: dev-server
    Remote Path: /home/user/project/src/main.py
    Protocol: scp
```

## API Functions

You can also control remote gitsigns programmatically:

```lua
local remote_gitsigns = require('remote-gitsigns')

-- Check if initialized
if remote_gitsigns.is_initialized() then
    -- Manually detect a buffer
    remote_gitsigns.detect_buffer(bufnr, function(is_git, git_root)
        if is_git then
            print("Git root: " .. git_root)
        end
    end)
    
    -- Detect all remote buffers
    remote_gitsigns.detect_all_buffers(function(results)
        for bufnr, result in pairs(results) do
            if result.is_git then
                print("Buffer " .. bufnr .. " is in git repo: " .. result.git_root)
            end
        end
    end)
    
    -- Get status information
    local status = remote_gitsigns.get_status()
    print("Cache enabled: " .. tostring(status.cache_enabled))
    
    -- Refresh a buffer's git status
    remote_gitsigns.refresh_buffer() -- current buffer
    remote_gitsigns.refresh_buffer(123) -- specific buffer
end
```

## Performance Considerations

### Caching

The system uses intelligent caching to minimize SSH operations:

- **Repository Discovery**: Cached for 5 minutes (configurable)
- **Git Status**: Cached briefly to avoid repeated calls
- **File Content**: Cached for diff operations

### SSH Connection Reuse

The system reuses SSH connections established by remote-lsp when possible, reducing connection overhead.

### Async Operations

Git repository detection runs asynchronously by default to avoid blocking the UI.

## Troubleshooting

### 1. Gitsigns Not Working on Remote Files

**Check if gitsigns is installed:**
```vim
:lua print(pcall(require, 'gitsigns'))
```

**Check if remote gitsigns is enabled:**
```vim
:RemoteGitsignsStatus
```

**Manually trigger detection:**
```vim
:RemoteGitsignsDetect
```

### 2. Git Repository Not Detected

**Check if Git is available on remote host:**
```bash
ssh your-host 'which git'
```

**Check file path exclusions:**
The file might be excluded by patterns in `detection.exclude_patterns`.

**Check SSH connectivity:**
```bash
ssh your-host 'echo "SSH works"'
```

### 3. Poor Performance

**Check cache statistics:**
```vim
:RemoteGitsignsStats
```

**Adjust cache settings:**
```lua
gitsigns = {
    cache = {
        ttl = 600, -- Increase cache time
        max_entries = 2000, -- Increase cache size
    }
}
```

### 4. Debug Mode

Enable debug mode for detailed logging:

```lua
gitsigns = {
    enabled = true,
    debug = true,
}
```

Then check logs with `:messages` or your logging setup.

## Limitations

1. **Network Dependency**: Requires active SSH connection
2. **Performance**: Slower than local git operations due to SSH overhead
3. **Git Version**: Requires compatible git version on remote host
4. **Large Repositories**: May be slower with very large git repositories

## Examples

### Basic Remote Development Setup

```lua
-- ~/.config/nvim/init.lua
require('remote-ssh').setup({
    -- Remote LSP configuration
    servers = {
        python = { server_name = 'pylsp' },
        javascript = { server_name = 'ts_ls' },
    },
    
    -- Enable gitsigns for remote files
    gitsigns = {
        enabled = true,
        auto_attach = true,
    }
})

-- Optional: Custom keymaps for remote gitsigns
vim.keymap.set('n', '<leader>gd', ':RemoteGitsignsDetect<CR>', { desc = 'Detect remote git' })
vim.keymap.set('n', '<leader>gs', ':RemoteGitsignsStatus<CR>', { desc = 'Remote gitsigns status' })
```

### Working with Remote Files

1. Open a remote file:
   ```vim
   :e scp://dev-server//home/user/project/src/main.py
   ```

2. The system automatically:
   - Detects the Git repository
   - Enables gitsigns functionality
   - Shows git signs in the sign column

3. Use normal gitsigns functionality:
   - View git hunks
   - Stage/unstage changes
   - Navigate between changes

### Multiple Remote Hosts

The system works with multiple remote hosts simultaneously:

```lua
-- Each remote host is handled independently
-- Open files from different hosts:
-- :e scp://dev-server//home/user/project/main.py
-- :e scp://test-server//opt/app/src/test.py

-- Each will have its own git repository detection and caching
```

## Integration with Other Plugins

### With Telescope

```lua
-- Use telescope to browse remote files
require('telescope').setup({
    extensions = {
        -- Configure telescope for remote browsing
    }
})

-- Browse and open remote files, gitsigns will activate automatically
```

### With Git Plugins

Remote gitsigns works alongside other git plugins:

- **vim-fugitive**: Can be used for more complex git operations
- **gv.vim**: For git log browsing (may need manual refresh)
- **git-messenger**: For showing commit messages

## Contributing

If you encounter issues or have suggestions for improvement, please open an issue or pull request in the remote-ssh.nvim repository.

## License

This integration is part of remote-ssh.nvim and uses the same license.