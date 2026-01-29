-- Terminal state management for remote-terminal module
local M = {}

-- Terminal state
local TerminalState = {
    terminals = {}, -- {id: session} all terminals
    active_terminal_id = nil, -- Currently displayed terminal
    next_id = 1,
    terminal_win_id = nil, -- Terminal pane window ID (left side)
    picker_win_id = nil, -- Picker sidebar window ID (right side)
    picker_bufnr = nil, -- Picker buffer (reused)
    split_visible = false,
}

--- Get the current state (for debugging or external access)
---@return table
function M.get_state()
    return {
        terminals = vim.deepcopy(TerminalState.terminals),
        active_terminal_id = TerminalState.active_terminal_id,
        terminal_win_id = TerminalState.terminal_win_id,
        picker_win_id = TerminalState.picker_win_id,
        picker_bufnr = TerminalState.picker_bufnr,
        split_visible = TerminalState.split_visible,
    }
end

--- Add a new terminal session
---@param session table Terminal session data
---@return number id The assigned terminal ID
function M.add_terminal(session)
    local id = TerminalState.next_id
    TerminalState.next_id = TerminalState.next_id + 1
    session.id = id
    TerminalState.terminals[id] = session

    -- If this is the first terminal, make it active
    if TerminalState.active_terminal_id == nil then
        TerminalState.active_terminal_id = id
    end

    return id
end

--- Remove a terminal by ID
---@param id number Terminal ID to remove
---@return boolean success
function M.remove_terminal(id)
    if not TerminalState.terminals[id] then
        return false
    end

    local session = TerminalState.terminals[id]

    -- Stop the job if running
    if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
        pcall(vim.fn.jobstop, session.job_id)
    end

    -- Delete the buffer
    if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
        pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
    end

    TerminalState.terminals[id] = nil

    -- If this was the active terminal, switch to another
    if TerminalState.active_terminal_id == id then
        TerminalState.active_terminal_id = nil
        local next_terminal = M.get_next_terminal()
        if next_terminal then
            TerminalState.active_terminal_id = next_terminal.id
        end
    end

    return true
end

--- Get a terminal by ID
---@param id number Terminal ID
---@return table|nil session
function M.get_terminal(id)
    return TerminalState.terminals[id]
end

--- Get terminal by buffer number
---@param bufnr number
---@return table|nil terminal
function M.get_terminal_by_bufnr(bufnr)
    for _, terminal in pairs(TerminalState.terminals) do
        if terminal.bufnr == bufnr then
            return terminal
        end
    end
    return nil
end

--- Get the active terminal session
---@return table|nil session
function M.get_active_terminal()
    if not TerminalState.active_terminal_id then
        return nil
    end
    return TerminalState.terminals[TerminalState.active_terminal_id]
end

--- Set the active terminal ID
---@param id number Terminal ID
---@return boolean success
function M.set_active_terminal(id)
    if not TerminalState.terminals[id] then
        return false
    end
    TerminalState.active_terminal_id = id
    return true
end

--- Get the active terminal ID
---@return number|nil
function M.get_active_terminal_id()
    return TerminalState.active_terminal_id
end

--- Get all terminal sessions as a list (sorted by ID)
---@return table[] sessions
function M.get_all_terminals()
    local list = {}
    for _, session in pairs(TerminalState.terminals) do
        table.insert(list, session)
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

--- Get the count of terminals
---@return number
function M.get_terminal_count()
    local count = 0
    for _ in pairs(TerminalState.terminals) do
        count = count + 1
    end
    return count
end

--- Get the next terminal (for cycling)
---@return table|nil session
function M.get_next_terminal()
    local terminals = M.get_all_terminals()
    if #terminals == 0 then
        return nil
    end

    if not TerminalState.active_terminal_id then
        return terminals[1]
    end

    for i, term in ipairs(terminals) do
        if term.id == TerminalState.active_terminal_id then
            return terminals[i % #terminals + 1]
        end
    end

    return terminals[1]
end

--- Get the previous terminal (for cycling)
---@return table|nil session
function M.get_previous_terminal()
    local terminals = M.get_all_terminals()
    if #terminals == 0 then
        return nil
    end

    if not TerminalState.active_terminal_id then
        return terminals[#terminals]
    end

    for i, term in ipairs(terminals) do
        if term.id == TerminalState.active_terminal_id then
            return terminals[(i - 2) % #terminals + 1]
        end
    end

    return terminals[#terminals]
end

--- Update terminal display name
---@param id number Terminal ID
---@param display_name string New display name
---@return boolean success
function M.rename_terminal(id, display_name)
    local session = TerminalState.terminals[id]
    if not session then
        return false
    end
    session.display_name = display_name
    return true
end

--- Set terminal window ID
---@param win_id number|nil
function M.set_terminal_win(win_id)
    TerminalState.terminal_win_id = win_id
end

--- Get terminal window ID
---@return number|nil
function M.get_terminal_win()
    return TerminalState.terminal_win_id
end

--- Set picker window ID
---@param win_id number|nil
function M.set_picker_win(win_id)
    TerminalState.picker_win_id = win_id
end

--- Get picker window ID
---@return number|nil
function M.get_picker_win()
    return TerminalState.picker_win_id
end

--- Set picker buffer number
---@param bufnr number|nil
function M.set_picker_bufnr(bufnr)
    TerminalState.picker_bufnr = bufnr
end

--- Get picker buffer number
---@return number|nil
function M.get_picker_bufnr()
    return TerminalState.picker_bufnr
end

--- Set split visibility state
---@param visible boolean
function M.set_split_visible(visible)
    TerminalState.split_visible = visible
end

--- Check if split is visible
---@return boolean
function M.is_split_visible()
    return TerminalState.split_visible
end

--- Check if terminal window is valid
---@return boolean
function M.is_terminal_win_valid()
    return TerminalState.terminal_win_id and vim.api.nvim_win_is_valid(TerminalState.terminal_win_id)
end

--- Check if picker window is valid
---@return boolean
function M.is_picker_win_valid()
    return TerminalState.picker_win_id and vim.api.nvim_win_is_valid(TerminalState.picker_win_id)
end

--- Close all terminals and clean up state
function M.close_all()
    for id, _ in pairs(TerminalState.terminals) do
        M.remove_terminal(id)
    end

    -- Reset state
    TerminalState.terminals = {}
    TerminalState.active_terminal_id = nil
    TerminalState.terminal_win_id = nil
    TerminalState.picker_win_id = nil
    TerminalState.split_visible = false
    -- Keep picker_bufnr for reuse
end

return M
