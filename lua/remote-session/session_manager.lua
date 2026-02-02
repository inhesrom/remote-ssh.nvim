-- Session manager for remote-session
-- Core state management for active and minimized sessions
local M = {}

local config = require("remote-session.config")
local persistence = require("remote-session.persistence")

---@class RemoteSession
---@field id string Unique ID (timestamp_random)
---@field name string Display name
---@field url string Base rsync:// URL
---@field host string Parsed hostname
---@field path string Remote directory path
---@field state "active"|"minimized"|"persisted"
---@field created_at number Unix timestamp
---@field last_accessed_at number Unix timestamp
---@field window_layout WindowLayout
---@field tree_browser_state TreeBrowserState|nil
---@field terminal_ids number[] Associated terminal IDs
---@field open_buffers BufferState[]

---@class WindowLayout
---@field tree_browser_width_ratio number 0.0-1.0 of editor width
---@field terminal_height_ratio number 0.0-1.0 of editor height
---@field tree_browser_visible boolean
---@field terminal_visible boolean

---@class TreeBrowserState
---@field expanded_dirs table<string, boolean> URLs of expanded directories
---@field scroll_position number|nil
---@field cursor_line number|nil

---@class BufferState
---@field url string Remote file URL
---@field cursor_pos number[] {line, col}
---@field winid number|nil

-- Runtime state (not persisted)
local runtime_state = {
    -- Currently active session (only one at a time)
    active_session_id = nil,

    -- Minimized sessions (still loaded in memory)
    minimized_sessions = {}, -- Map of session_id -> true

    -- All loaded sessions (active + minimized)
    sessions = {}, -- Map of session_id -> RemoteSession
}

--- Generate a unique session ID
---@return string id
local function generate_session_id()
    return tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

--- Get the currently active session
---@return RemoteSession|nil
function M.get_active_session()
    if not runtime_state.active_session_id then
        return nil
    end
    return runtime_state.sessions[runtime_state.active_session_id]
end

--- Get the active session ID
---@return string|nil
function M.get_active_session_id()
    return runtime_state.active_session_id
end

--- Get a session by ID
---@param session_id string
---@return RemoteSession|nil
function M.get_session(session_id)
    return runtime_state.sessions[session_id]
end

--- Get all loaded sessions (active + minimized)
---@return table<string, RemoteSession>
function M.get_all_sessions()
    return runtime_state.sessions
end

--- Get all minimized sessions
---@return RemoteSession[]
function M.get_minimized_sessions()
    local result = {}
    for session_id in pairs(runtime_state.minimized_sessions) do
        local session = runtime_state.sessions[session_id]
        if session then
            table.insert(result, session)
        end
    end
    -- Sort by last_accessed_at
    table.sort(result, function(a, b)
        return (a.last_accessed_at or 0) > (b.last_accessed_at or 0)
    end)
    return result
end

--- Get count of minimized sessions
---@return number
function M.get_minimized_count()
    local count = 0
    for _ in pairs(runtime_state.minimized_sessions) do
        count = count + 1
    end
    return count
end

--- Check if a session is active
---@param session_id string
---@return boolean
function M.is_active(session_id)
    return runtime_state.active_session_id == session_id
end

--- Check if a session is minimized
---@param session_id string
---@return boolean
function M.is_minimized(session_id)
    return runtime_state.minimized_sessions[session_id] == true
end

--- Register a new session
---@param session RemoteSession
---@return string session_id
function M.register_session(session)
    if not session.id then
        session.id = generate_session_id()
    end

    session.created_at = session.created_at or os.time()
    session.last_accessed_at = os.time()
    session.state = session.state or "active"
    session.terminal_ids = session.terminal_ids or {}
    session.open_buffers = session.open_buffers or {}

    runtime_state.sessions[session.id] = session

    return session.id
end

--- Set a session as active
---@param session_id string
---@return boolean success
function M.set_active(session_id)
    local session = runtime_state.sessions[session_id]
    if not session then
        return false
    end

    -- Remove from minimized if it was there
    runtime_state.minimized_sessions[session_id] = nil

    -- Update state
    session.state = "active"
    session.last_accessed_at = os.time()

    runtime_state.active_session_id = session_id

    return true
end

--- Set a session as minimized
---@param session_id string
---@return boolean success
function M.set_minimized(session_id)
    local session = runtime_state.sessions[session_id]
    if not session then
        return false
    end

    -- If this was the active session, clear active
    if runtime_state.active_session_id == session_id then
        runtime_state.active_session_id = nil
    end

    -- Add to minimized
    runtime_state.minimized_sessions[session_id] = true
    session.state = "minimized"
    session.last_accessed_at = os.time()

    -- Persist the minimized session
    persistence.save_session(session)

    return true
end

--- Remove a session from runtime state
---@param session_id string
---@return boolean success
function M.unregister_session(session_id)
    if not runtime_state.sessions[session_id] then
        return false
    end

    -- Clear from active if needed
    if runtime_state.active_session_id == session_id then
        runtime_state.active_session_id = nil
    end

    -- Clear from minimized
    runtime_state.minimized_sessions[session_id] = nil

    -- Remove from sessions
    runtime_state.sessions[session_id] = nil

    return true
end

--- Update session's window layout
---@param session_id string
---@param layout WindowLayout
function M.update_window_layout(session_id, layout)
    local session = runtime_state.sessions[session_id]
    if session then
        session.window_layout = layout
        session.last_accessed_at = os.time()
    end
end

--- Update session's tree browser state
---@param session_id string
---@param state TreeBrowserState
function M.update_tree_browser_state(session_id, state)
    local session = runtime_state.sessions[session_id]
    if session then
        session.tree_browser_state = state
        session.last_accessed_at = os.time()
    end
end

--- Add a terminal to session
---@param session_id string
---@param terminal_id number
function M.add_terminal(session_id, terminal_id)
    local session = runtime_state.sessions[session_id]
    if session then
        if not vim.tbl_contains(session.terminal_ids, terminal_id) then
            table.insert(session.terminal_ids, terminal_id)
        end
    end
end

--- Remove a terminal from session
---@param session_id string
---@param terminal_id number
function M.remove_terminal(session_id, terminal_id)
    local session = runtime_state.sessions[session_id]
    if session then
        session.terminal_ids = vim.tbl_filter(function(id)
            return id ~= terminal_id
        end, session.terminal_ids)
    end
end

--- Get terminals for a session
---@param session_id string
---@return number[]
function M.get_terminals(session_id)
    local session = runtime_state.sessions[session_id]
    if session then
        return session.terminal_ids or {}
    end
    return {}
end

--- Update session's open buffers
---@param session_id string
---@param buffers BufferState[]
function M.update_open_buffers(session_id, buffers)
    local session = runtime_state.sessions[session_id]
    if session then
        session.open_buffers = buffers
        session.last_accessed_at = os.time()
    end
end

--- Rename a session
---@param session_id string
---@param new_name string
---@return boolean success
function M.rename_session(session_id, new_name)
    local session = runtime_state.sessions[session_id]
    if not session then
        return false
    end

    session.name = new_name
    session.last_accessed_at = os.time()

    -- Update persistence
    persistence.save_session(session)

    return true
end

--- Find session by URL
---@param url string
---@return RemoteSession|nil
function M.find_by_url(url)
    -- Check runtime sessions first
    for _, session in pairs(runtime_state.sessions) do
        if session.url == url then
            return session
        end
    end

    -- Check persisted sessions
    return persistence.find_session_by_url(url)
end

--- Load a persisted session into runtime
---@param session_id string
---@return RemoteSession|nil
function M.load_from_persistence(session_id)
    local persisted = persistence.get_session(session_id)
    if not persisted then
        return nil
    end

    -- Copy to runtime
    persisted.id = session_id
    runtime_state.sessions[session_id] = persisted

    return persisted
end

--- Get all sessions (runtime + persisted) for picker display
---@return RemoteSession[]
function M.get_all_for_picker()
    local result = {}
    local seen_ids = {}

    -- Add active session first
    if runtime_state.active_session_id then
        local active = runtime_state.sessions[runtime_state.active_session_id]
        if active then
            table.insert(result, active)
            seen_ids[active.id] = true
        end
    end

    -- Add minimized sessions
    for _, session in ipairs(M.get_minimized_sessions()) do
        if not seen_ids[session.id] then
            table.insert(result, session)
            seen_ids[session.id] = true
        end
    end

    -- Add persisted sessions not already in runtime
    local persisted = persistence.get_sessions_sorted()
    for _, session in ipairs(persisted) do
        if not seen_ids[session.id] then
            session.state = "persisted"
            table.insert(result, session)
            seen_ids[session.id] = true
        end
    end

    return result
end

--- Persist all minimized sessions
function M.persist_all_minimized()
    for session_id in pairs(runtime_state.minimized_sessions) do
        local session = runtime_state.sessions[session_id]
        if session then
            persistence.save_session(session)
        end
    end
end

--- Initialize the session manager
function M.init()
    -- Initialize persistence
    persistence.init()

    -- Setup auto-persist on Neovim exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            M.persist_all_minimized()
        end,
        group = vim.api.nvim_create_augroup("RemoteSessionManager", { clear = true }),
        desc = "Persist minimized remote sessions on Neovim exit",
    })
end

--- Get runtime state (for debugging)
---@return table
function M.get_runtime_state()
    return vim.deepcopy(runtime_state)
end

--- Clear all runtime state (for testing)
function M.clear_runtime_state()
    runtime_state.active_session_id = nil
    runtime_state.minimized_sessions = {}
    runtime_state.sessions = {}
end

return M
