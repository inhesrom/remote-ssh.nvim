-- Statusline component for remote-session
-- Provides a function to display active session and minimized count
local M = {}

local config = require("remote-session.config")
local session_manager = require("remote-session.session_manager")

--- Get the statusline component string
--- Returns formatted string for statusline, or empty string if no active session
---@return string component
function M.component()
    local active = session_manager.get_active_session()
    local minimized_count = session_manager.get_minimized_count()

    -- If no active session and no minimized sessions, return empty
    if not active and minimized_count == 0 then
        return config.get("statusline", "no_session_text") or ""
    end

    -- If no active session but have minimized sessions
    if not active then
        local show_minimized = config.get("statusline", "show_minimized_count")
        if show_minimized and minimized_count > 0 then
            return "SSH: [" .. minimized_count .. " minimized]"
        end
        return ""
    end

    -- We have an active session
    local format_str
    local show_minimized = config.get("statusline", "show_minimized_count")

    if show_minimized and minimized_count > 0 then
        format_str = config.get("statusline", "format_with_minimized") or "SSH: {name} [+{minimized_count} minimized]"
    else
        format_str = config.get("statusline", "format") or "SSH: {name}"
    end

    -- Replace placeholders
    local result = format_str
        :gsub("{name}", active.name or "unnamed")
        :gsub("{host}", active.host or "")
        :gsub("{path}", active.path or "")
        :gsub("{minimized_count}", tostring(minimized_count))

    return result
end

--- Get minimal statusline component (just session name)
---@return string component
function M.minimal()
    local active = session_manager.get_active_session()
    if not active then
        return ""
    end
    return active.name or ""
end

--- Get icon-based statusline component
--- Returns icon with session count indicator
---@return string component
function M.icon()
    local active = session_manager.get_active_session()
    local minimized_count = session_manager.get_minimized_count()

    if not active and minimized_count == 0 then
        return ""
    end

    local icon = "󰣀" -- SSH/remote icon

    if active then
        if minimized_count > 0 then
            return icon .. " " .. active.name .. " +" .. minimized_count
        else
            return icon .. " " .. active.name
        end
    else
        return icon .. " [" .. minimized_count .. "]"
    end
end

--- Get detailed statusline component with state indicators
---@return string component
function M.detailed()
    local active = session_manager.get_active_session()
    local minimized_count = session_manager.get_minimized_count()

    if not active and minimized_count == 0 then
        return ""
    end

    local parts = {}

    if active then
        table.insert(parts, "● " .. active.name)
    end

    if minimized_count > 0 then
        table.insert(parts, "○×" .. minimized_count)
    end

    return "SSH: " .. table.concat(parts, " ")
end

--- Get lualine-compatible component table
--- Use in lualine config: require("remote-session.statusline").lualine()
---@return table lualine_component
function M.lualine()
    return {
        function()
            return M.component()
        end,
        cond = function()
            local active = session_manager.get_active_session()
            local minimized = session_manager.get_minimized_count()
            return active ~= nil or minimized > 0
        end,
    }
end

--- Check if there's an active session
---@return boolean
function M.has_active_session()
    return session_manager.get_active_session() ~= nil
end

--- Check if there are any sessions (active or minimized)
---@return boolean
function M.has_any_session()
    return session_manager.get_active_session() ~= nil or session_manager.get_minimized_count() > 0
end

--- Get session summary for display
---@return table summary {active_name, minimized_count, total_count}
function M.get_summary()
    local active = session_manager.get_active_session()
    local minimized_count = session_manager.get_minimized_count()

    return {
        active_name = active and active.name or nil,
        active_host = active and active.host or nil,
        minimized_count = minimized_count,
        total_count = (active and 1 or 0) + minimized_count,
    }
end

return M
