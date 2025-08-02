# Debugging Remote Gitsigns

If you're not seeing gitsigns annotations on remote buffers, follow these debugging steps:

## Step 1: Check Dependencies

Make sure you have `gitsigns.nvim` installed. Add it to your plugin manager:

```lua
return {
    "inhesrom/remote-ssh.nvim",
    branch = "remote-gitsigns", 
    dependencies = {
        "lewis6991/gitsigns.nvim", -- ← ADD THIS
        "inhesrom/telescope-remote-buffer",
        "nvim-telescope/telescope.nvim",
        "nvim-lua/plenary.nvim",
    },
    config = function()
        -- Setup gitsigns first
        require('gitsigns').setup() -- ← ADD THIS
        
        require('telescope-remote-buffer').setup()
        
        -- Your existing setup...
        require('remote-ssh').setup({
            on_attach = lsp_util.on_attach,
            capabilities = lsp_util.capabilities, 
            filetype_to_server = lsp_util.filetype_to_server,
            gitsigns = {
                enabled = true,
                auto_attach = true,
            }
        })
    end
}
```

## Step 2: Run Debug Script

1. Open a remote file via SSH: `:e scp://your-host//path/to/git/repo/file.py`
2. Run the debug script: `:luafile debug_gitsigns.lua`
3. Check the output for issues

## Step 3: Manual Commands

Try these commands in Neovim with a remote buffer open:

```vim
:lua print(require('remote-gitsigns').is_initialized())
:lua print(vim.inspect(require('remote-gitsigns').get_status()))
:RemoteGitsignsStatus
:RemoteGitsignsDetect
```

## Step 4: Check Git Repository

Make sure the remote file is actually in a git repository:

```bash
# SSH to your remote host and check
ssh your-host
cd /path/to/your/file
git status  # Should show git repo info
```

## Common Issues

1. **Gitsigns not installed** - Add `lewis6991/gitsigns.nvim` dependency
2. **Gitsigns not configured** - Call `require('gitsigns').setup()` before remote-ssh setup
3. **Not a git repo** - Remote file must be in a git repository  
4. **SSH timeout** - Increase `git_timeout` in config
5. **Path parsing** - Make sure you're using the correct scp:// format

## Configuration Options

If basic setup doesn't work, try more explicit configuration:

```lua
require('remote-ssh').setup({
    -- ... your other config ...
    gitsigns = {
        enabled = true,
        auto_attach = true,
        debug = true, -- Enable debug logging
        git_timeout = 30000, -- 30 second timeout
        cache = {
            enabled = true,
            ttl = 300, -- 5 minutes
        },
        detection = {
            async_detection = false, -- Try sync detection first
        }
    }
})
```