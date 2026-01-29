-- Remote Terminal module for remote-ssh.nvim
-- Provides VS Code-style terminal management with bottom split and picker sidebar
local M = {}

local config = require("remote-terminal.config")
local commands = require("remote-terminal.commands")
local terminal_manager = require("remote-terminal.terminal_manager")
local terminal_session = require("remote-terminal.terminal_session")
local window_manager = require("remote-terminal.window_manager")
local picker = require("remote-terminal.picker")

--- Setup global terminal keymaps (called once during setup)
local function setup_global_keymaps()
    local cfg = require("remote-terminal.config")
    local keymaps = cfg.get("keymaps") or {}

    local opts = { noremap = true, silent = true }

    -- Toggle split - works from any terminal
    if keymaps.toggle_split and keymaps.toggle_split ~= "" then
        vim.keymap.set("t", keymaps.toggle_split, function()
            -- Only act if we have remote terminals
            if terminal_manager.get_terminal_count() > 0 then
                window_manager.toggle_split()
            end
        end, opts)
    end

    -- New terminal - works from any terminal
    if keymaps.new_terminal and keymaps.new_terminal ~= "" then
        vim.keymap.set("t", keymaps.new_terminal, function()
            vim.cmd("RemoteTerminalNew")
        end, opts)
    end

    -- Close terminal - only if in a remote terminal buffer
    if keymaps.close_terminal and keymaps.close_terminal ~= "" then
        vim.keymap.set("t", keymaps.close_terminal, function()
            local bufnr = vim.api.nvim_get_current_buf()
            if terminal_manager.get_terminal_by_bufnr(bufnr) then
                vim.cmd("RemoteTerminalClose")
            end
        end, opts)
    end

    -- Next terminal - only if remote terminals exist
    if keymaps.next_terminal and keymaps.next_terminal ~= "" then
        vim.keymap.set("t", keymaps.next_terminal, function()
            if terminal_manager.get_terminal_count() > 0 then
                window_manager.cycle_next()
            end
        end, opts)
    end

    -- Previous terminal - only if remote terminals exist
    if keymaps.prev_terminal and keymaps.prev_terminal ~= "" then
        vim.keymap.set("t", keymaps.prev_terminal, function()
            if terminal_manager.get_terminal_count() > 0 then
                window_manager.cycle_prev()
            end
        end, opts)
    end
end

--- Setup the remote-terminal module
---@param opts table|nil Configuration options
function M.setup(opts)
    config.setup(opts)
    commands.register()
    setup_global_keymaps()
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
