local M = {}

-- Consolidated logging function
function M.log(msg, level, notify_user, config)
    level = level or vim.log.levels.DEBUG
    notify_user = notify_user or false

    -- Skip debug messages unless debug mode is enabled or log level is low enough
    if config ~= nil then
        if level == vim.log.levels.DEBUG and not config.debug and config.log_level > vim.log.levels.DEBUG then
            return
        end
    else
        config = {
            timeout = 30,          -- Default timeout in seconds
            log_level = vim.log.levels.INFO, -- Default log level
            debug = false,         -- Debug mode disabled by default
            check_interval = 1000, -- Status check interval in ms
        }
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
