-- Window layout module for remote-session
-- Handles capturing and restoring window layouts with proportional sizing
local M = {}

local config = require("remote-session.config")

---@class WindowLayout
---@field tree_browser_width_ratio number 0.0-1.0 of editor width
---@field terminal_height_ratio number 0.0-1.0 of editor height
---@field tree_browser_visible boolean
---@field terminal_visible boolean

--- Get default window layout from config
---@return WindowLayout
function M.get_default_layout()
    local defaults = config.get("default_layout")
    return {
        tree_browser_width_ratio = defaults.tree_browser_width_ratio or 0.2,
        terminal_height_ratio = defaults.terminal_height_ratio or 0.3,
        tree_browser_visible = true,
        terminal_visible = true,
    }
end

--- Capture the current window layout for a session
---@return WindowLayout
function M.capture_layout()
    local layout = M.get_default_layout()

    -- Get editor dimensions
    local editor_width = vim.o.columns
    local editor_height = vim.o.lines

    -- Try to find tree browser window
    local tree_browser_win = M.find_tree_browser_window()
    if tree_browser_win and vim.api.nvim_win_is_valid(tree_browser_win) then
        local width = vim.api.nvim_win_get_width(tree_browser_win)
        layout.tree_browser_width_ratio = width / editor_width
        layout.tree_browser_visible = true
    else
        layout.tree_browser_visible = false
    end

    -- Try to find terminal window
    local terminal_win = M.find_terminal_window()
    if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
        local height = vim.api.nvim_win_get_height(terminal_win)
        layout.terminal_height_ratio = height / editor_height
        layout.terminal_visible = true
    else
        layout.terminal_visible = false
    end

    return layout
end

--- Find the tree browser window (if open)
---@return number|nil win_id
function M.find_tree_browser_window()
    local ok, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if not ok then
        return nil
    end

    local state = tree_browser.get_state()
    if state and state.base_url then
        -- Tree browser state exists, but we need to find its window
        -- Check all windows for the tree browser buffer
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            local bufname = vim.api.nvim_buf_get_name(buf)
            if bufname:match("^Remote Tree:") then
                return win
            end
        end
    end

    return nil
end

--- Find the terminal window (if open)
---@return number|nil win_id
function M.find_terminal_window()
    local ok, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
    if not ok then
        return nil
    end

    return terminal_manager.get_terminal_win()
end

--- Calculate actual pixel dimensions from layout ratios
---@param layout WindowLayout
---@return table dimensions {tree_width, terminal_height}
function M.calculate_dimensions(layout)
    local editor_width = vim.o.columns
    local editor_height = vim.o.lines

    -- Calculate tree browser width (minimum 30, maximum 80% of screen)
    local tree_width = math.floor(editor_width * layout.tree_browser_width_ratio)
    tree_width = math.max(30, math.min(tree_width, math.floor(editor_width * 0.8)))

    -- Calculate terminal height (minimum 5 lines, maximum 70% of screen)
    local terminal_height = math.floor(editor_height * layout.terminal_height_ratio)
    terminal_height = math.max(5, math.min(terminal_height, math.floor(editor_height * 0.7)))

    return {
        tree_width = tree_width,
        terminal_height = terminal_height,
    }
end

--- Apply a window layout
---@param layout WindowLayout
---@param session_url string|nil URL for tree browser
---@return boolean success
function M.apply_layout(layout, session_url)
    local dimensions = M.calculate_dimensions(layout)

    -- Apply tree browser layout
    if layout.tree_browser_visible and session_url then
        local ok, tree_browser = pcall(require, "async-remote-write.tree_browser")
        if ok then
            -- Open tree browser if not already open
            if not tree_browser.is_open() then
                tree_browser.open_tree(session_url)
            end

            -- Set width
            local tree_win = M.find_tree_browser_window()
            if tree_win and vim.api.nvim_win_is_valid(tree_win) then
                vim.api.nvim_win_set_width(tree_win, dimensions.tree_width)
            end
        end
    end

    -- Apply terminal layout
    if layout.terminal_visible then
        local ok, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
        if ok and terminal_manager.is_split_visible() then
            local terminal_win = terminal_manager.get_terminal_win()
            if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
                vim.api.nvim_win_set_height(terminal_win, dimensions.terminal_height)
            end
        end
    end

    return true
end

--- Hide all session windows (for minimizing)
---@return boolean success
function M.hide_session_windows()
    -- Hide tree browser
    local ok_tree, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if ok_tree then
        tree_browser.hide_tree()
    end

    -- Hide terminal
    local ok_term, window_manager = pcall(require, "remote-terminal.window_manager")
    if ok_term then
        window_manager.hide_split()
    end

    return true
end

--- Show session windows with layout
---@param layout WindowLayout
---@param session table Session data
---@return boolean success
function M.show_session_windows(layout, session)
    -- Show tree browser
    if layout.tree_browser_visible and session.url then
        local ok, tree_browser = pcall(require, "async-remote-write.tree_browser")
        if ok then
            if tree_browser.is_open() then
                tree_browser.show_tree()
            else
                tree_browser.open_tree(session.url)
            end
        end
    end

    -- Show terminal if there are associated terminals
    if layout.terminal_visible and session.terminal_ids and #session.terminal_ids > 0 then
        local ok, window_manager = pcall(require, "remote-terminal.window_manager")
        if ok then
            window_manager.show_split()
        end
    end

    -- Apply dimensions
    M.apply_layout(layout, session.url)

    return true
end

--- Check if any session windows are currently visible
---@return boolean
function M.are_session_windows_visible()
    local tree_visible = M.find_tree_browser_window() ~= nil

    local terminal_visible = false
    local ok, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
    if ok then
        terminal_visible = terminal_manager.is_split_visible()
    end

    return tree_visible or terminal_visible
end

--- Get current visibility state
---@return table state {tree_browser_visible, terminal_visible}
function M.get_visibility_state()
    local tree_visible = M.find_tree_browser_window() ~= nil

    local terminal_visible = false
    local ok, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
    if ok then
        terminal_visible = terminal_manager.is_split_visible()
    end

    return {
        tree_browser_visible = tree_visible,
        terminal_visible = terminal_visible,
    }
end

return M
