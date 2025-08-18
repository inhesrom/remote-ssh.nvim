local M = {}

local log = require("logging").log

-- Configuration
M.config = {
    timeout = 30, -- Default timeout in seconds
    log_level = vim.log.levels.INFO, -- Default log level
    debug = false, -- Debug mode disabled by default
    check_interval = 1000, -- Status check interval in ms

    -- Project root detection settings
    fast_root_detection = true, -- Use fast mode (no SSH calls) for better performance
    root_cache_enabled = true, -- Enable caching of project root results
    root_cache_ttl = 300, -- Cache time-to-live in seconds (5 minutes)
    max_root_search_depth = 10, -- Maximum directory levels to search upward

    -- Server-specific root detection overrides
    server_root_detection = {
        rust_analyzer = { fast_mode = false }, -- Disable fast mode for rust-analyzer
        clangd = { fast_mode = false }, -- Disable fast mode for clangd
    },
}

-- Global variables set by setup
M.on_attach = nil
M.capabilities = nil
M.server_configs = {} -- Table to store server-specific configurations
M.custom_root_dir = nil
local default_configs = require("remote-lsp.server_defaults_and_filetype_mappings")
M.ext_to_ft = default_configs.ext_to_ft
M.default_server_configs = default_configs.default_server_configs

-- Function to initialize configuration from the setup options
function M.initialize(opts)
    -- Add verbose logging for setup process
    log("Setting up remote-lsp with options: " .. vim.inspect(opts), vim.log.levels.DEBUG, false, M.config)

    -- Set on_attach callback
    M.on_attach = opts.on_attach
        or function(_, bufnr)
            log("LSP attached to buffer " .. bufnr, vim.log.levels.INFO, true, M.config)
        end

    -- Set capabilities
    M.capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()

    -- Enhance capabilities for better LSP support
    -- Explicitly request markdown for hover documentation
    M.capabilities.textDocument = M.capabilities.textDocument or {}
    M.capabilities.textDocument.hover = M.capabilities.textDocument.hover or {}
    M.capabilities.textDocument.hover.contentFormat = { "markdown", "plaintext" }

    -- Process filetype_to_server mappings
    if opts.filetype_to_server then
        for ft, server_name in pairs(opts.filetype_to_server) do
            if type(server_name) == "string" then
                -- Simple mapping from filetype to server name
                M.server_configs[ft] = { server_name = server_name }
            elseif type(server_name) == "table" then
                -- Advanced configuration with server name and options
                M.server_configs[ft] = server_name
            end
        end
    end

    -- Process server_configs from options
    if opts.server_configs then
        for server_name, config in pairs(opts.server_configs) do
            -- Merge with default configs if they exist
            if M.default_server_configs[server_name] then
                for k, v in pairs(M.default_server_configs[server_name]) do
                    if k == "init_options" then
                        config.init_options = vim.tbl_deep_extend(
                            "force",
                            M.default_server_configs[server_name].init_options or {},
                            config.init_options or {}
                        )
                    elseif k == "filetypes" or k == "root_patterns" then
                        config[k] = config[k] or vim.deepcopy(v)
                    else
                        config[k] = config[k] ~= nil and config[k] or v
                    end
                end
            end

            -- Register server config
            for _, ft in ipairs(config.filetypes or {}) do
                M.server_configs[ft] = {
                    server_name = server_name,
                    init_options = config.init_options,
                    cmd_args = config.cmd_args,
                    root_patterns = config.root_patterns,
                }
            end
        end
    end

    -- Log available filetype mappings
    local ft_count = 0
    for ft, _ in pairs(M.server_configs) do
        ft_count = ft_count + 1
    end
    log("Registered " .. ft_count .. " filetype to server mappings", vim.log.levels.DEBUG, false, M.config)

    -- Add default mappings for filetypes that don't have custom mappings
    for server_name, config in pairs(M.default_server_configs) do
        for _, ft in ipairs(config.filetypes or {}) do
            if not M.server_configs[ft] then
                M.server_configs[ft] = {
                    server_name = server_name,
                    init_options = config.init_options,
                    cmd_args = config.cmd_args,
                    root_patterns = config.root_patterns,
                }
            end
        end
    end

    -- Initialize the async write module
    require("async-remote-write").setup(opts.async_write_opts or {})

    -- Set up LSP integration with non-blocking handlers
    require("async-remote-write").setup_lsp_integration({
        notify_save_start = require("remote-lsp.buffer").notify_save_start,
        notify_save_end = require("remote-lsp.buffer").notify_save_end,
    })
end

-- Helper function to get server for filetype
function M.get_server_for_filetype(filetype)
    -- Check in the user-provided configurations first
    if M.server_configs[filetype] then
        return M.server_configs[filetype].server_name
    end

    -- Then check in default configurations
    for server_name, config in pairs(M.default_server_configs) do
        if vim.tbl_contains(config.filetypes, filetype) then
            return server_name
        end
    end

    return nil
end

return M
