-- Persistence module for remote-session
-- Handles JSON file I/O for saving/loading sessions
local M = {}

local config = require("remote-session.config")

-- Storage path
local data_dir = vim.fn.stdpath("data") .. "/remote-ssh"
local data_path = data_dir .. "/sessions.json"

-- Cached session data
local session_data = {
    sessions = {}, -- Map of session_id -> session_entry
    version = 1, -- Schema version for future migrations
    last_updated = nil,
}

--- Ensure the data directory exists
local function ensure_data_dir()
    if vim.fn.isdirectory(data_dir) == 0 then
        vim.fn.mkdir(data_dir, "p")
    end
end

--- Load session data from disk
---@return boolean success
function M.load()
    if not config.get("persistence", "enabled") then
        return false
    end

    local file = io.open(data_path, "r")
    if not file then
        -- No existing data, start fresh
        return true
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return true
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or not data then
        vim.notify("[remote-session] Failed to parse session data, starting fresh", vim.log.levels.WARN)
        return false
    end

    -- Validate and migrate if needed
    if data.version and data.version > session_data.version then
        vim.notify("[remote-session] Session data from newer version, some features may not work", vim.log.levels.WARN)
    end

    session_data.sessions = data.sessions or {}
    session_data.version = data.version or 1
    session_data.last_updated = data.last_updated

    return true
end

--- Save session data to disk
---@return boolean success
function M.save()
    if not config.get("persistence", "enabled") then
        return false
    end

    ensure_data_dir()

    session_data.last_updated = os.time()

    -- Trim to max persisted if needed
    local max_persisted = config.get("persistence", "max_persisted") or 50
    local sessions_list = {}
    for id, session in pairs(session_data.sessions) do
        table.insert(sessions_list, { id = id, session = session })
    end

    -- Sort by last_accessed_at (most recent first)
    table.sort(sessions_list, function(a, b)
        return (a.session.last_accessed_at or 0) > (b.session.last_accessed_at or 0)
    end)

    -- Keep only max_persisted sessions
    if #sessions_list > max_persisted then
        local trimmed = {}
        for i = 1, max_persisted do
            trimmed[sessions_list[i].id] = sessions_list[i].session
        end
        session_data.sessions = trimmed
    end

    local ok, content = pcall(vim.json.encode, session_data)
    if not ok then
        vim.notify("[remote-session] Failed to encode session data", vim.log.levels.ERROR)
        return false
    end

    local file = io.open(data_path, "w")
    if not file then
        vim.notify("[remote-session] Failed to write session data to " .. data_path, vim.log.levels.ERROR)
        return false
    end

    file:write(content)
    file:close()

    return true
end

--- Get a session by ID
---@param session_id string
---@return table|nil session
function M.get_session(session_id)
    return session_data.sessions[session_id]
end

--- Get all persisted sessions
---@return table sessions Map of session_id -> session_entry
function M.get_all_sessions()
    return vim.deepcopy(session_data.sessions)
end

--- Get sessions sorted by last access time (most recent first)
---@return table[] sessions
function M.get_sessions_sorted()
    local list = {}
    for id, session in pairs(session_data.sessions) do
        session.id = id
        table.insert(list, session)
    end

    table.sort(list, function(a, b)
        return (a.last_accessed_at or 0) > (b.last_accessed_at or 0)
    end)

    return list
end

--- Save or update a session
---@param session table Session data to save
---@return boolean success
function M.save_session(session)
    if not session or not session.id then
        return false
    end

    -- Clone to avoid references
    local session_copy = vim.deepcopy(session)

    -- Remove runtime-only fields that shouldn't be persisted
    session_copy.terminal_ids = nil -- Terminals are recreated

    -- Set state to persisted if not already set
    if session_copy.state ~= "minimized" then
        session_copy.state = "persisted"
    end

    session_data.sessions[session.id] = session_copy

    return M.save()
end

--- Delete a session
---@param session_id string
---@return boolean success
function M.delete_session(session_id)
    if not session_data.sessions[session_id] then
        return false
    end

    session_data.sessions[session_id] = nil
    return M.save()
end

--- Check if a session with the given URL exists
---@param url string
---@return table|nil session
function M.find_session_by_url(url)
    for id, session in pairs(session_data.sessions) do
        if session.url == url then
            session.id = id
            return session
        end
    end
    return nil
end

--- Clear all persisted sessions
---@return boolean success
function M.clear_all()
    session_data.sessions = {}
    return M.save()
end

--- Get statistics about persisted sessions
---@return table stats
function M.get_stats()
    local count = 0
    local by_state = { active = 0, minimized = 0, persisted = 0 }
    local oldest_access = math.huge
    local newest_access = 0

    for _, session in pairs(session_data.sessions) do
        count = count + 1
        local state = session.state or "persisted"
        by_state[state] = (by_state[state] or 0) + 1

        local access_time = session.last_accessed_at or session.created_at or 0
        if access_time < oldest_access then
            oldest_access = access_time
        end
        if access_time > newest_access then
            newest_access = access_time
        end
    end

    return {
        total_count = count,
        by_state = by_state,
        oldest_access = oldest_access ~= math.huge and oldest_access or nil,
        newest_access = newest_access > 0 and newest_access or nil,
        last_updated = session_data.last_updated,
    }
end

--- Initialize persistence module
function M.init()
    M.load()

    -- Setup auto-save on Neovim exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            M.save()
        end,
        group = vim.api.nvim_create_augroup("RemoteSessionPersistence", { clear = true }),
        desc = "Save remote session data on Neovim exit",
    })
end

return M
