local M = {}

local log = require("logging").log

-- Configuration
M.config = {
    timeout = 30, -- Default timeout in seconds
    log_level = vim.log.levels.INFO, -- Default log level
    debug = false, -- Debug mode disabled by default
    check_interval = 1000, -- Status check interval in ms
    save_debounce_ms = 3000, -- Delay before initiating save to handle rapid editing
}

-- Configure timeout, log level, and debug settings
function M.configure(opts)
    opts = opts or {}

    if opts.timeout then
        M.config.timeout = opts.timeout
    end

    if opts.debug ~= nil then
        M.config.debug = opts.debug

        -- If debug is explicitly enabled, set log_level to DEBUG
        if opts.debug then
            M.config.log_level = vim.log.levels.DEBUG
        end
    end

    if opts.log_level ~= nil then
        M.config.log_level = opts.log_level
    end

    if opts.check_interval then
        M.config.check_interval = opts.check_interval
    end

    if opts.save_debounce_ms then
        M.config.save_debounce_ms = opts.save_debounce_ms
    end

    log("Configuration updated: " .. vim.inspect(M.config), vim.log.levels.DEBUG, false, M.config)
end

return M
