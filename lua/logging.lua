local M = {}

-- Consolidated logging function
function M.log(msg, level, notify_user)
    level = level or vim.log.levels.DEBUG
    notify_user = notify_user or false

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
