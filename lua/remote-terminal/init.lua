-- Remote Terminal module for remote-ssh.nvim
-- Provides VS Code-style terminal management with bottom split and picker sidebar
local M = {}

local config = require("remote-terminal.config")
local commands = require("remote-terminal.commands")
local terminal_manager = require("remote-terminal.terminal_manager")
local terminal_session = require("remote-terminal.terminal_session")
local window_manager = require("remote-terminal.window_manager")
local picker = require("remote-terminal.picker")

--- Setup the remote-terminal module
---@param opts table|nil Configuration options
function M.setup(opts)
    config.setup(opts)
    commands.register()
end

-- Export public API

--- Create a new remote terminal
---@param callback function|nil Called with session on success
function M.new_terminal(callback)
    terminal_session.new_terminal(function(session)
        if not session then
            if callback then
                callback(nil)
            end
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
            window_manager.switch_terminal(session.id)
        end

        picker.refresh()
        window_manager.focus_terminal()

        if callback then
            callback(session)
        end
    end)
end

--- Close the active terminal
function M.close_terminal()
    terminal_session.close_active_terminal()
end

--- Toggle terminal split visibility
function M.toggle()
    if terminal_manager.is_split_visible() and window_manager.is_layout_valid() then
        window_manager.hide_split()
    else
        if terminal_manager.get_terminal_count() > 0 then
            window_manager.show_split()
            local picker_bufnr = terminal_manager.get_picker_bufnr()
            if picker_bufnr then
                picker.init_buffer(picker_bufnr)
            end
        else
            vim.notify("No remote terminals. Use :RemoteTerminalNew to create one.", vim.log.levels.INFO)
        end
    end
end

--- Rename the active terminal
---@param name string|nil New name (prompts if nil)
function M.rename(name)
    terminal_session.rename_active_terminal(name)
end

--- Get all terminal sessions
---@return table[] sessions
function M.get_terminals()
    return terminal_manager.get_all_terminals()
end

--- Get the active terminal session
---@return table|nil session
function M.get_active_terminal()
    return terminal_manager.get_active_terminal()
end

--- Check if terminal split is visible
---@return boolean
function M.is_visible()
    return terminal_manager.is_split_visible()
end

--- Switch to a specific terminal by ID
---@param id number Terminal ID
function M.switch_to(id)
    window_manager.switch_terminal(id)
    window_manager.focus_terminal()
end

--- Focus the terminal window
function M.focus_terminal()
    window_manager.focus_terminal()
end

--- Focus the picker window
function M.focus_picker()
    window_manager.focus_picker()
end

return M
