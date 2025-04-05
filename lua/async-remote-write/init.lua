local M = {}

-- Load submodules
local config = require('async-remote-write.config')
local operations = require('async-remote-write.operations')
local buffer = require('async-remote-write.buffer')
local process = require('async-remote-write.process')
local lsp = require('async-remote-write.lsp')
local commands = require('async-remote-write.commands')
local utils = require('async-remote-write.utils')
local browse = require('async-remote-write.browse')

-- Export key functions for external use
M.setup = function(opts)
    -- Initialize configuration
    config.configure(opts or {})

    -- Setup LSP integration
    lsp.setup()

    -- Setup file handlers for LSP and buffer commands
    lsp.setup_file_handlers()

    -- Setup user commands
    commands.register()

    -- Completely disable netrw for our protocols
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Set up monitoring and fallback autocommands
    buffer.setup_autocommands()

    -- Register autocommands for any already-open remote buffers
    buffer.register_existing_buffers()

    utils.log("Async write module initialized with configuration: " .. vim.inspect(config.config), vim.log.levels.DEBUG, false, config.config)
end

-- Public API functions
M.start_save_process = operations.start_save_process
M.force_complete = process.force_complete
M.cancel_write = process.cancel_write
M.get_status = process.get_status
M.open_remote_file = operations.open_remote_file
M.simple_open_remote_file = operations.simple_open_remote_file
M.refresh_remote_buffer = operations.refresh_remote_buffer
M.register_buffer_autocommands = buffer.register_buffer_autocommands
M.ensure_acwrite_state = buffer.ensure_acwrite_state
M.debug_buffer_state = buffer.debug_buffer_state
M.setup_lsp_integration = lsp.setup_lsp_integration
M.configure = config.configure
M.log = utils.log
M.browse_remote_directory = browse.browse_remote_directory

return M
