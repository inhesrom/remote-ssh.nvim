local M = {}

local log = require("logging").log

-- TUI Session Management State
local TuiSessions = {
    active = {}, -- Currently visible sessions: {session_id: {buf, win, metadata}}
    hidden = {}, -- Hidden sessions: {session_id: {buf, config, metadata}}
    next_id = 1, -- Auto-incrementing session ID
}

-- Session metadata structure
function M.create_session_metadata(app_name, host_string, directory_path, connection_info)
    local session_id = TuiSessions.next_id
    TuiSessions.next_id = TuiSessions.next_id + 1

    return {
        id = session_id,
        app_name = app_name,
        host_string = host_string,
        directory_path = directory_path,
        connection_info = connection_info, -- {user, host, port}
        created_at = os.time(),
        display_name = app_name .. " @ " .. (connection_info and connection_info.host or "unknown"),
    }
end

-- Get next session ID
function M.get_next_id()
    return TuiSessions.next_id
end

-- Increment session ID counter
function M.increment_id()
    TuiSessions.next_id = TuiSessions.next_id + 1
end

-- Decrement session ID counter (for error cases)
function M.decrement_id()
    TuiSessions.next_id = TuiSessions.next_id - 1
end

-- Register an active session
function M.register_active_session(session_id, buf, win, metadata)
    TuiSessions.active[session_id] = {
        buf = buf,
        win = win,
        metadata = metadata,
    }
end

-- Get active session by ID
function M.get_active_session(session_id)
    return TuiSessions.active[session_id]
end

-- Remove active session
function M.remove_active_session(session_id)
    TuiSessions.active[session_id] = nil
end

-- Get all active sessions
function M.get_active_sessions()
    return TuiSessions.active
end

-- Hide the current TUI session (Ctrl+H functionality)
function M.hide_current_session()
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)

    -- Find the session associated with this window
    local session_id = nil
    for id, session in pairs(TuiSessions.active) do
        if session.win == current_win and session.buf == current_buf then
            session_id = id
            break
        end
    end

    if not session_id then
        vim.notify("No active TUI session found in current window", vim.log.levels.WARN)
        return
    end

    local session = TuiSessions.active[session_id]

    -- Store window configuration before hiding
    local win_config = vim.api.nvim_win_get_config(current_win)

    -- Hide the window
    if vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_win_hide(current_win)
    end

    -- Move session from active to hidden
    TuiSessions.hidden[session_id] = {
        buf = session.buf,
        config = win_config,
        metadata = session.metadata,
    }

    TuiSessions.active[session_id] = nil

    log("Hidden TUI session: " .. session.metadata.display_name, vim.log.levels.INFO, true)
end

-- Restore a hidden session
function M.restore_session(session_id)
    local session = TuiSessions.hidden[session_id]
    if not session then
        vim.notify("Session not found", vim.log.levels.ERROR)
        return
    end

    -- Check if buffer is still valid
    if not vim.api.nvim_buf_is_valid(session.buf) then
        vim.notify("Session buffer is no longer valid", vim.log.levels.ERROR)
        TuiSessions.hidden[session_id] = nil
        return
    end

    -- Recreate the floating window
    local win = vim.api.nvim_open_win(session.buf, true, session.config)

    -- Setup hide keymap for the restored window
    local config = require("remote-tui.config")
    local hide_key = config.get_keymaps().hide_session
    if hide_key and hide_key ~= "" then
        vim.keymap.set("t", hide_key, M.hide_current_session, { buffer = session.buf, noremap = true, silent = true })
    end

    -- Move session from hidden to active
    TuiSessions.active[session_id] = {
        buf = session.buf,
        win = win,
        metadata = session.metadata,
    }

    TuiSessions.hidden[session_id] = nil

    -- Enter terminal mode
    vim.cmd("startinsert")

    log("Restored TUI session: " .. session.metadata.display_name, vim.log.levels.INFO, true)
end

-- Delete a session (removes buffer and cleans up state)
function M.delete_session(session_id, force)
    local session = TuiSessions.hidden[session_id] or TuiSessions.active[session_id]
    if not session then
        vim.notify("Session not found", vim.log.levels.ERROR)
        return false
    end

    if not force then
        return false -- Caller should handle confirmation
    end

    -- Force delete the buffer
    if vim.api.nvim_buf_is_valid(session.buf) then
        vim.api.nvim_buf_delete(session.buf, { force = true })
    end

    -- Clean up session state
    TuiSessions.hidden[session_id] = nil
    TuiSessions.active[session_id] = nil

    log("Deleted TUI session: " .. session.metadata.display_name, vim.log.levels.INFO, true)
    return true
end

-- Get all hidden sessions
function M.get_hidden_sessions()
    return TuiSessions.hidden
end

-- Get hidden session by ID
function M.get_hidden_session(session_id)
    return TuiSessions.hidden[session_id]
end

-- Check if there are any hidden sessions
function M.has_hidden_sessions()
    return next(TuiSessions.hidden) ~= nil
end

-- Get session count
function M.get_session_count()
    return {
        active = vim.tbl_count(TuiSessions.active),
        hidden = vim.tbl_count(TuiSessions.hidden),
        total = vim.tbl_count(TuiSessions.active) + vim.tbl_count(TuiSessions.hidden),
    }
end

return M
