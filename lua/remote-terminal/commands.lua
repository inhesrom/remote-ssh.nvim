-- User commands for remote-terminal module
local M = {}

--- Register all user commands
function M.register()
    -- :RemoteTerminalNew - Create new terminal
    vim.api.nvim_create_user_command("RemoteTerminalNew", function(opts)
        local terminal_session = require("remote-terminal.terminal_session")
        local window_manager = require("remote-terminal.window_manager")
        local terminal_manager = require("remote-terminal.terminal_manager")
        local picker = require("remote-terminal.picker")

        terminal_session.new_terminal(function(session)
            if not session then
                return
            end

            -- Ensure split is visible
            if not terminal_manager.is_split_visible() or not window_manager.is_layout_valid() then
                window_manager.create_split(session.bufnr)
                -- Initialize picker keymaps
                local picker_bufnr = terminal_manager.get_picker_bufnr()
                if picker_bufnr then
                    picker.init_buffer(picker_bufnr)
                end
            else
                -- Just switch to the new terminal
                window_manager.switch_terminal(session.id)
            end

            -- Refresh picker
            picker.refresh()

            -- Focus the terminal and enter insert mode
            window_manager.focus_terminal()
        end)
    end, {
        desc = "Create a new remote terminal",
    })

    -- :RemoteTerminalClose - Close current terminal
    vim.api.nvim_create_user_command("RemoteTerminalClose", function(opts)
        local terminal_session = require("remote-terminal.terminal_session")
        terminal_session.close_active_terminal()
    end, {
        desc = "Close the current remote terminal",
    })

    -- :RemoteTerminalToggle - Toggle terminal split visibility
    vim.api.nvim_create_user_command("RemoteTerminalToggle", function(opts)
        local window_manager = require("remote-terminal.window_manager")
        local terminal_manager = require("remote-terminal.terminal_manager")
        local picker = require("remote-terminal.picker")

        if terminal_manager.is_split_visible() and window_manager.is_layout_valid() then
            window_manager.hide_split()
        else
            if terminal_manager.get_terminal_count() > 0 then
                window_manager.show_split()
                -- Reinitialize picker keymaps when showing
                local picker_bufnr = terminal_manager.get_picker_bufnr()
                if picker_bufnr then
                    picker.init_buffer(picker_bufnr)
                end
            else
                vim.notify("No remote terminals. Use :RemoteTerminalNew to create one.", vim.log.levels.INFO)
            end
        end
    end, {
        desc = "Toggle remote terminal split visibility",
    })

    -- :RemoteTerminalRename - Rename current terminal
    vim.api.nvim_create_user_command("RemoteTerminalRename", function(opts)
        local terminal_session = require("remote-terminal.terminal_session")
        local new_name = opts.args ~= "" and opts.args or nil
        terminal_session.rename_active_terminal(new_name)
    end, {
        nargs = "?",
        desc = "Rename the current remote terminal",
    })

    -- :RemoteTerminalList - List all terminals (for debugging)
    vim.api.nvim_create_user_command("RemoteTerminalList", function(opts)
        local terminal_manager = require("remote-terminal.terminal_manager")
        local terminals = terminal_manager.get_all_terminals()

        if #terminals == 0 then
            vim.notify("No remote terminals", vim.log.levels.INFO)
            return
        end

        local active_id = terminal_manager.get_active_terminal_id()
        local lines = { "Remote Terminals:" }
        for _, term in ipairs(terminals) do
            local marker = term.id == active_id and " * " or "   "
            local status = term.exited and " [exited]" or ""
            table.insert(
                lines,
                string.format(
                    "%s%d: %s (%s)%s",
                    marker,
                    term.id,
                    term.display_name,
                    term.host_string,
                    status
                )
            )
        end
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end, {
        desc = "List all remote terminals",
    })
end

return M
