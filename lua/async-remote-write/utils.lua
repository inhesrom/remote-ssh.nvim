local M = {}

-- Function to get protocol and details from buffer name
function M.parse_remote_path(bufname)
    local protocol
    if bufname:match("^scp://") then
        protocol = "scp"
    elseif bufname:match("^rsync://") then
        protocol = "rsync"
    else
        return nil
    end

    -- Enhanced pattern matching for double-slash issues
    local host, path

    -- First try the standard pattern (protocol://host/path)
    local pattern = "^" .. protocol .. "://([^/]+)/(.+)$"
    host, path = bufname:match(pattern)

    -- If that fails, try the double-slash pattern (protocol://host//path)
    if not host or not path then
        local alt_pattern = "^" .. protocol .. "://([^/]+)//(.+)$"
        host, path = bufname:match(alt_pattern)

        -- Ensure path starts with / for consistency
        if host and path and not path:match("^/") then
            path = "/" .. path
        end
    end

    if not host or not path then
        return nil
    end

    -- Always ensure path starts with a slash for consistency
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return {
        protocol = protocol,
        host = host,
        path = path,
        full = bufname,
        -- Store the exact original format for accurate command construction
        has_double_slash = bufname:match("^" .. protocol .. "://[^/]+//") ~= nil,
    }
end

function M.get_remote_file_info(bufnr)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not bufname or bufname == "" then
        return nil
    end

    -- Use centralized parser that supports SSH config aliases and double-slash format
    local remote_info = M.parse_remote_path(bufname)
    if not remote_info then
        return nil
    end

    -- Extract user and port from host if present (format: user@host:port)
    local user, host, port

    -- Check for user@host:port format
    local user_host_port = remote_info.host:match("^([^@]+)@([^:]+):?(%d*)$")
    if user_host_port then
        user, host, port = remote_info.host:match("^([^@]+)@([^:]+):?(%d*)$")
        port = port ~= "" and tonumber(port) or nil
    else
        -- Check for user@host format (no port)
        local user_host = remote_info.host:match("^([^@]+)@(.+)$")
        if user_host then
            user, host = remote_info.host:match("^([^@]+)@(.+)$")
        else
            -- Just host (no user or port)
            host = remote_info.host
        end
    end

    return {
        protocol = remote_info.protocol,
        user = user,
        host = host,
        port = port,
        path = remote_info.path,
        full = remote_info.full,
        has_double_slash = remote_info.has_double_slash,
    }
end

-- Safely close a timer
function M.safe_close_timer(timer)
    if timer then
        pcall(function()
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end)
    end
end

-- Import unified logging module
local logging = require("logging")

-- Logging function that delegates to unified logging module
function M.log(msg, level, notify_user, config, context)
    -- Add module context if not provided
    if not context then
        context = {}
    end
    if not context.module then
        context.module = "async-remote-write"
    end

    return logging.log(msg, level, notify_user, config, context)
end

return M
