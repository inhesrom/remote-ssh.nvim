local M = {}

-- Load submodules
local config = require('remote-lsp.config')
local client = require('remote-lsp.client')
local buffer = require('remote-lsp.buffer')
local handlers = require('remote-lsp.handlers')
local commands = require('remote-lsp.commands')
local utils = require('remote-lsp.utils')

-- Main setup function
function M.setup(opts)
  config.initialize(opts)
  handlers.setup_optimized_handlers()
  commands.register()
  buffer.setup_autocommands()

  -- Set up cleanup timer for save operations
  M._cleanup_timer = buffer.setup_save_status_cleanup()

  return M
end

-- Export public API
M.start_remote_lsp = client.start_remote_lsp
M.stop_all_clients = client.stop_all_clients
M.shutdown_client = client.shutdown_client
M.debug_lsp_traffic = utils.debug_lsp_traffic
M.async_write = require('async-remote-write')
M.buffer_clients = buffer.buffer_clients -- Export for testing/debugging

return M
