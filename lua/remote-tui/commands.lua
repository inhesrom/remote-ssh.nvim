local M = {}

local log = require("logging").log
local utils = require("async-remote-write.utils")

-- Import our new modules
local session_picker = require("remote-tui.session_picker")
local tui_session = require("remote-tui.tui_session")

function M.register()
    vim.api.nvim_create_user_command("RemoteTui", function(opts)
        log("Ran Remote TUI Command...", vim.log.levels.DEBUG, true)
        local args = opts.args
        log("args: " .. args, vim.log.levels.DEBUG, true)

        -- Check if no arguments provided - open picker mode
        if not args or args:match("^%s*$") then
            log("No arguments provided, opening TUI session picker", vim.log.levels.INFO, true)
            session_picker.show_picker()
            return
        end

        local bufnr = vim.api.nvim_get_current_buf()
        local buf_info = utils.get_remote_file_info(bufnr)

        if not buf_info then
            log("No buffer metadata found, prompting user for connection info", vim.log.levels.INFO, true)
            tui_session.create_with_prompt(args)
            return
        end

        -- Use buffer metadata when available
        tui_session.create_from_buffer_metadata(args, buf_info)
    end, {
        nargs = "?",
        desc = "Open a remote TUI app (with args) or show TUI session picker (no args)",
    })
end

return M