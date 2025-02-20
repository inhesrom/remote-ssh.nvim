-- remote_ssh/init.lua
local M = {}

-- Global variables to store the remote host and workspace root
vim.g.remote_ssh_host = nil
local remote_workspace_root = nil

-- Function to determine the root directory for LSP
local function get_root_dir(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  -- Check if the buffer is a remote file
  if bufname:match("^scp://") then
    if remote_workspace_root then
      return remote_workspace_root
    else
      -- Fallback: use the directory of the file if no workspace root is set
      local remote_path = bufname:match("^scp://[^/]+(/.*)$")
      if remote_path then
        return vim.fn.fnamemodify(remote_path, ":h")
      end
    end
  end
  -- For local files, use lspconfig's default root pattern (e.g., .git)
  return require('lspconfig.util').root_pattern(".git", "package.json", "setup.py")(bufname)
end

-- Callback to modify the LSP config before starting the server
local function on_new_config(new_config, root_dir)
  if vim.g.remote_ssh_host and root_dir and not root_dir:match("^/tmp") then
    local original_cmd = new_config.cmd
    -- Prepend 'ssh' command to run the LSP server remotely
    new_config.cmd = {"ssh", vim.g.remote_ssh_host, unpack(original_cmd)}
  end
end

-- Public function to set up an LSP server with remote SSH support
function M.setup(server_name, config)
  config = config or {}
  -- Set the custom root_dir function
  config.root_dir = get_root_dir
  -- Set the on_new_config callback
  config.on_new_config = on_new_config
  -- Apply the configuration to the LSP server
  require('lspconfig')[server_name].setup(config)
end

-- Command to set the remote host and workspace root
function M.set_host(host, workspace_root)
  if not host or host == "" then
    print("Error: Remote host must be specified (e.g., user@host)")
    return
  end
  vim.g.remote_ssh_host = host
  remote_workspace_root = workspace_root
  if workspace_root then
    print("Connected to " .. host .. " with workspace root " .. workspace_root)
  else
    print("Connected to " .. host .. " (no workspace root specified)")
  end
end

-- Command to disconnect from the remote host
function M.disconnect()
  vim.g.remote_ssh_host = nil
  remote_workspace_root = nil
  print("Disconnected from remote host")
end

-- Define Neovim commands
vim.api.nvim_create_user_command(
  "RemoteSSHSetHost",
  function(opts)
    local args = vim.split(opts.args, "%s+")
    local host = args[1]
    local root = args[2]
    M.set_host(host, root)
  end,
  { nargs = "+", desc = "Set remote SSH host and optional workspace root (e.g., :RemoteSSHSetHost user@host /path)" }
)

vim.api.nvim_create_user_command(
  "RemoteSSHDisconnect",
  function()
    M.disconnect()
  end,
  { nargs = 0, desc = "Disconnect from remote SSH host" }
)

return M
