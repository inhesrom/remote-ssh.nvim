-- Naming module for remote-session
-- Handles auto-name generation for sessions
local M = {}

local session_manager = require("remote-session.session_manager")

--- Extract the last directory component from a path
---@param path string
---@return string
local function get_last_dir(path)
    -- Remove trailing slash if present
    path = path:gsub("/$", "")

    -- Handle root path
    if path == "" or path == "/" then
        return "root"
    end

    -- Extract last component
    local last = path:match("([^/]+)$")
    return last or "root"
end

--- Extract a short host identifier
---@param host string Full host string (may include user@)
---@return string Short host identifier
local function get_short_host(host)
    -- Remove user@ prefix if present
    host = host:gsub("^[^@]+@", "")

    -- Remove domain suffix for common patterns
    -- e.g., "myserver.example.com" -> "myserver"
    local short = host:match("^([^%.]+)")

    return short or host
end

--- Generate an auto-name for a session
--- Format: "{last_dir} @ {short_host}"
---@param host string Full host string
---@param path string Remote directory path
---@return string name Auto-generated name
function M.generate_name(host, path)
    local dir_name = get_last_dir(path)
    local short_host = get_short_host(host)

    return dir_name .. " @ " .. short_host
end

--- Make a name unique by appending a suffix if needed
---@param base_name string The base name to make unique
---@param exclude_session_id string|nil Session ID to exclude from collision check
---@return string unique_name
function M.make_unique(base_name, exclude_session_id)
    local all_sessions = session_manager.get_all_for_picker()

    -- Collect existing names (excluding the session we're renaming)
    local existing_names = {}
    for _, session in ipairs(all_sessions) do
        if session.id ~= exclude_session_id then
            existing_names[session.name] = true
        end
    end

    -- If base name doesn't exist, use it
    if not existing_names[base_name] then
        return base_name
    end

    -- Try adding numeric suffix
    local suffix = 2
    while true do
        local candidate = base_name .. " (" .. suffix .. ")"
        if not existing_names[candidate] then
            return candidate
        end
        suffix = suffix + 1

        -- Safety limit
        if suffix > 100 then
            return base_name .. " (" .. os.time() .. ")"
        end
    end
end

--- Generate a unique auto-name for a new session
---@param host string Full host string
---@param path string Remote directory path
---@return string name Unique auto-generated name
function M.generate_unique_name(host, path)
    local base_name = M.generate_name(host, path)
    return M.make_unique(base_name)
end

--- Validate a user-provided session name
---@param name string
---@return boolean is_valid
---@return string|nil error_message
function M.validate_name(name)
    if not name or name == "" then
        return false, "Name cannot be empty"
    end

    if #name > 100 then
        return false, "Name cannot exceed 100 characters"
    end

    -- Check for invalid characters
    if name:match("[%c]") then
        return false, "Name cannot contain control characters"
    end

    return true, nil
end

--- Parse a session name to extract components (if possible)
--- This is the inverse of generate_name, useful for display
---@param name string
---@return table|nil components {dir_name, host}
function M.parse_name(name)
    local dir_name, host = name:match("^(.+) @ (.+)$")
    if dir_name and host then
        return {
            dir_name = dir_name,
            host = host,
        }
    end
    return nil
end

--- Suggest a name based on URL
---@param url string Remote URL (rsync:// or similar)
---@return string|nil suggested_name
function M.suggest_from_url(url)
    -- Try to parse the URL
    local ok, utils = pcall(require, "async-remote-write.utils")
    if not ok then
        return nil
    end

    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        return nil
    end

    return M.generate_unique_name(remote_info.host, remote_info.path)
end

return M
