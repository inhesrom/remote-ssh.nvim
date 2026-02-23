-- Remote Session - Unified session management for remote-ssh.nvim
-- Combines file browser + terminal into cohesive, persistable sessions
local M = {}

local config = require("remote-session.config")
local session_manager = require("remote-session.session_manager")
local session = require("remote-session.session")
local picker = require("remote-session.picker")
local statusline = require("remote-session.statusline")
local commands = require("remote-session.commands")

--- Setup remote-session with configuration
---@param opts table|nil Configuration options
function M.setup(opts)
    -- Apply configuration
    config.setup(opts)

    -- Initialize session manager (loads persistence)
    session_manager.init()

    -- Register user commands
    commands.register()
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Open a session by URL or show picker if no URL provided
---@param url string|nil Remote URL (e.g., "user@host//path" or "rsync://user@host//path")
---@param opts table|nil Options {name, open_terminal}
function M.open(url, opts)
    session.open(url, opts)
end

--- Create a new session
---@param url string Remote URL
---@param opts table|nil Options {name, open_terminal}
---@return table|nil session Created session
function M.create(url, opts)
    return session.create(url, opts)
end

--- Minimize the current active session
---@return boolean success
function M.minimize()
    local active_id = session_manager.get_active_session_id()
    if not active_id then
        vim.notify("[remote-session] No active session to minimize", vim.log.levels.WARN)
        return false
    end
    return session.minimize(active_id)
end

--- Restore a minimized or persisted session
---@param session_id string Session ID
---@return boolean success
function M.restore(session_id)
    return session.restore(session_id)
end

--- Close a session
---@param session_id string|nil Session ID (uses active if nil)
---@param opts table|nil Options {force}
---@return boolean success
function M.close(session_id, opts)
    session_id = session_id or session_manager.get_active_session_id()
    if not session_id then
        vim.notify("[remote-session] No session to close", vim.log.levels.WARN)
        return false
    end
    return session.close(session_id, opts)
end

--- Rename a session
---@param session_id string|nil Session ID (uses active if nil)
---@param new_name string|nil New name (prompts if nil)
function M.rename(session_id, new_name)
    session.rename(session_id, new_name)
end

--- Show the session picker
function M.show_picker()
    picker.show()
end

-- =============================================================================
-- Query API
-- =============================================================================

--- Get the currently active session
---@return table|nil session
function M.get_active_session()
    return session_manager.get_active_session()
end

--- Get all minimized sessions
---@return table[] sessions
function M.get_minimized_sessions()
    return session_manager.get_minimized_sessions()
end

--- Get count of minimized sessions
---@return number count
function M.get_minimized_count()
    return session_manager.get_minimized_count()
end

--- Get all sessions (for picker display)
---@return table[] sessions
function M.get_all_sessions()
    return session_manager.get_all_for_picker()
end

--- Find a session by URL
---@param url string Remote URL
---@return table|nil session
function M.find_by_url(url)
    return session_manager.find_by_url(session.normalize_url(url))
end

--- Check if a session is active
---@param session_id string
---@return boolean
function M.is_active(session_id)
    return session_manager.is_active(session_id)
end

--- Check if a session is minimized
---@param session_id string
---@return boolean
function M.is_minimized(session_id)
    return session_manager.is_minimized(session_id)
end

-- =============================================================================
-- Statusline API
-- =============================================================================

--- Get statusline component string
--- Returns formatted string showing active session and minimized count
--- Example: "SSH: signal-lemon-rs @ bizon-rf [+2 minimized]"
---@return string component
function M.statusline_component()
    return statusline.component()
end

--- Get minimal statusline component (just session name)
---@return string component
function M.statusline_minimal()
    return statusline.minimal()
end

--- Get icon-based statusline component
---@return string component
function M.statusline_icon()
    return statusline.icon()
end

--- Get detailed statusline component
---@return string component
function M.statusline_detailed()
    return statusline.detailed()
end

--- Get lualine-compatible component
---@return table component
function M.lualine()
    return statusline.lualine()
end

--- Check if there's an active session (for statusline conditions)
---@return boolean
function M.has_active_session()
    return statusline.has_active_session()
end

--- Check if there are any sessions (for statusline conditions)
---@return boolean
function M.has_any_session()
    return statusline.has_any_session()
end

-- =============================================================================
-- Utility API
-- =============================================================================

--- Normalize a URL to full rsync:// format
---@param input string
---@return string normalized_url
function M.normalize_url(input)
    return session.normalize_url(input)
end

--- Get configuration value
---@vararg string Path segments
---@return any
function M.get_config(...)
    return config.get(...)
end

--- Set configuration value
---@vararg any Path segments followed by value
function M.set_config(...)
    config.set(...)
end

return M
