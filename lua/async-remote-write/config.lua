local M = {}

local log = require("logging").log

-- Configuration
M.config = {
    timeout = 30, -- Default timeout in seconds
    log_level = vim.log.levels.INFO, -- Default log level
    debug = false, -- Debug mode disabled by default
    check_interval = 1000, -- Status check interval in ms
    save_debounce_ms = 3000, -- Delay before initiating save to handle rapid editing
    autosave = true, -- Enable automatic saving on text changes (can be disabled while keeping manual saves)
    logging = {
        max_entries = 1000, -- Ring buffer size
        include_context = true, -- Include contextual data in logs
        viewer = {
            height = 15, -- Split height in lines
            auto_scroll = true, -- Auto-scroll to bottom
            position = "bottom", -- Position of split (bottom/top)
        },
    },
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

    if opts.autosave ~= nil then
        M.config.autosave = opts.autosave
    end

    if opts.logging then
        if opts.logging.max_entries then
            M.config.logging.max_entries = opts.logging.max_entries
            -- Update logging module configuration
            require("logging").buffer_config.max_entries = opts.logging.max_entries
        end
        if opts.logging.include_context ~= nil then
            M.config.logging.include_context = opts.logging.include_context
            -- Update logging module configuration
            require("logging").buffer_config.include_context = opts.logging.include_context
        end
        if opts.logging.viewer then
            M.config.logging.viewer = vim.tbl_extend("force", M.config.logging.viewer, opts.logging.viewer)
        end
    end

    log("Configuration updated: " .. vim.inspect(M.config), vim.log.levels.DEBUG, false, M.config)
end

return M
