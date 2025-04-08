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
        has_double_slash = bufname:match("^" .. protocol .. "://[^/]+//") ~= nil
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

-- Consolidated logging function
function M.log(msg, level, notify_user, config)
    level = level or vim.log.levels.DEBUG
    notify_user = notify_user or false
    config = config or {
        timeout = 30,          -- Default timeout in seconds
        log_level = vim.log.levels.INFO, -- Default log level
        debug = false,         -- Debug mode disabled by default
        check_interval = 1000, -- Status check interval in ms
    }

    -- Skip debug messages unless debug mode is enabled or log level is low enough
    if level == vim.log.levels.DEBUG and not config.debug and config.log_level > vim.log.levels.DEBUG then
        return
    end

    -- Only log if message level meets or exceeds the configured log level
    if level >= config.log_level then
        vim.schedule(function()
            local prefix = notify_user and "" or "[AsyncWrite] "
            vim.notify(prefix .. msg, level)

            -- Update the status line if this is a user notification
            if notify_user and vim.o.laststatus >= 2 then
                pcall(function() vim.cmd("redrawstatus") end)
            end
        end)
    end
end

return M
