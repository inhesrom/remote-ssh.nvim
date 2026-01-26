-- Window management for remote-terminal module
local M = {}

local config = require("remote-terminal.config")
local terminal_manager = require("remote-terminal.terminal_manager")

--- Calculate the split height based on configuration
---@return number height in lines
local function calculate_height()
    local height_config = config.get("window", "height")
    local screen_height = vim.o.lines

    if type(height_config) == "number" and height_config > 0 and height_config < 1 then
        -- Percentage of screen
        return math.floor(screen_height * height_config)
    elseif type(height_config) == "number" and height_config >= 1 then
        -- Absolute number of lines
        return math.floor(height_config)
    end

    -- Default to 30%
    return math.floor(screen_height * 0.3)
end

--- Create the bottom split layout with terminal pane and picker sidebar
---@param terminal_bufnr number|nil Buffer to display in terminal pane
---@return boolean success
function M.create_split(terminal_bufnr)
    -- Save current window to return to later if needed
    local original_win = vim.api.nvim_get_current_win()

    -- Calculate dimensions
    local height = calculate_height()
    local picker_width = config.get("picker", "width") or 25

    -- Create bottom horizontal split
    vim.cmd("botright " .. height .. "split")
    local terminal_win = vim.api.nvim_get_current_win()

    -- Set buffer in terminal window if provided
    if terminal_bufnr and vim.api.nvim_buf_is_valid(terminal_bufnr) then
        vim.api.nvim_win_set_buf(terminal_win, terminal_bufnr)
    end

    -- Configure terminal window
    M.configure_terminal_window(terminal_win)

    -- Create vertical split for picker sidebar (right side)
    vim.cmd("vertical rightbelow " .. picker_width .. "split")
    local picker_win = vim.api.nvim_get_current_win()

    -- Get or create picker buffer
    local picker_bufnr = terminal_manager.get_picker_bufnr()
    if not picker_bufnr or not vim.api.nvim_buf_is_valid(picker_bufnr) then
        picker_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(picker_bufnr, "Remote Terminals")
        terminal_manager.set_picker_bufnr(picker_bufnr)
    end

    vim.api.nvim_win_set_buf(picker_win, picker_bufnr)

    -- Configure picker window
    M.configure_picker_window(picker_win)

    -- Store window IDs
    terminal_manager.set_terminal_win(terminal_win)
    terminal_manager.set_picker_win(picker_win)
    terminal_manager.set_split_visible(true)

    -- Focus the terminal window
    vim.api.nvim_set_current_win(terminal_win)

    return true
end

--- Configure options for the terminal window
---@param win_id number
function M.configure_terminal_window(win_id)
    if not vim.api.nvim_win_is_valid(win_id) then
        return
    end

    vim.api.nvim_set_option_value("number", false, { win = win_id })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win_id })
    vim.api.nvim_set_option_value("winfixheight", true, { win = win_id })
end

--- Configure options for the picker window
---@param win_id number
function M.configure_picker_window(win_id)
    if not vim.api.nvim_win_is_valid(win_id) then
        return
    end

    vim.api.nvim_set_option_value("number", false, { win = win_id })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win_id })
    vim.api.nvim_set_option_value("winfixheight", true, { win = win_id })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = win_id })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_id })
    vim.api.nvim_set_option_value("wrap", false, { win = win_id })
end

--- Hide the terminal split (close windows but keep buffers alive)
function M.hide_split()
    local terminal_win = terminal_manager.get_terminal_win()
    local picker_win = terminal_manager.get_picker_win()

    -- Close picker window first (it's inside the terminal split)
    if picker_win and vim.api.nvim_win_is_valid(picker_win) then
        vim.api.nvim_win_hide(picker_win)
    end

    -- Close terminal window
    if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
        vim.api.nvim_win_hide(terminal_win)
    end

    terminal_manager.set_terminal_win(nil)
    terminal_manager.set_picker_win(nil)
    terminal_manager.set_split_visible(false)
end

--- Show the terminal split (recreate windows with existing buffers)
---@return boolean success
function M.show_split()
    local active_terminal = terminal_manager.get_active_terminal()
    local terminal_bufnr = active_terminal and active_terminal.bufnr or nil

    local success = M.create_split(terminal_bufnr)
    if not success then
        return false
    end

    -- Refresh picker display
    local picker = require("remote-terminal.picker")
    picker.refresh()

    -- Start insert mode in terminal if we have an active terminal
    if active_terminal and terminal_bufnr then
        local terminal_win = terminal_manager.get_terminal_win()
        if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
            vim.api.nvim_set_current_win(terminal_win)
            vim.cmd("startinsert")
        end
    end

    return true
end

--- Toggle the terminal split visibility
function M.toggle_split()
    if terminal_manager.is_split_visible() then
        M.hide_split()
    else
        if terminal_manager.get_terminal_count() > 0 then
            M.show_split()
        else
            vim.notify("No remote terminals. Use :RemoteTerminalNew to create one.", vim.log.levels.INFO)
        end
    end
end

--- Switch the displayed terminal in the terminal pane
---@param terminal_id number
---@return boolean success
function M.switch_terminal(terminal_id)
    local session = terminal_manager.get_terminal(terminal_id)
    if not session then
        return false
    end

    local terminal_win = terminal_manager.get_terminal_win()
    if not terminal_win or not vim.api.nvim_win_is_valid(terminal_win) then
        -- Split not visible, show it first
        terminal_manager.set_active_terminal(terminal_id)
        return M.show_split()
    end

    -- Set the buffer in the terminal window
    if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
        vim.api.nvim_win_set_buf(terminal_win, session.bufnr)
        terminal_manager.set_active_terminal(terminal_id)

        -- Refresh picker to update selection
        local picker = require("remote-terminal.picker")
        picker.refresh()

        return true
    end

    return false
end

--- Focus the terminal window
function M.focus_terminal()
    local terminal_win = terminal_manager.get_terminal_win()
    if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
        vim.api.nvim_set_current_win(terminal_win)
        vim.cmd("startinsert")
    end
end

--- Focus the picker window
function M.focus_picker()
    local picker_win = terminal_manager.get_picker_win()
    if picker_win and vim.api.nvim_win_is_valid(picker_win) then
        vim.api.nvim_set_current_win(picker_win)
        vim.cmd("stopinsert")
    end
end

--- Check if the terminal split layout is valid
---@return boolean
function M.is_layout_valid()
    return terminal_manager.is_terminal_win_valid() and terminal_manager.is_picker_win_valid()
end

--- Ensure the split is visible, creating it if needed
---@return boolean success
function M.ensure_visible()
    if M.is_layout_valid() and terminal_manager.is_split_visible() then
        return true
    end

    local active_terminal = terminal_manager.get_active_terminal()
    if active_terminal then
        return M.show_split()
    end

    return false
end

return M
