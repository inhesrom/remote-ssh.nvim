local M = {}

local config = require("async-remote-write.config")
local utils = require("async-remote-write.utils")
local process -- Will be required later to avoid circular dependency
local operations -- Will be required later to avoid circular dependency

-- LSP integration callbacks
local lsp_integration = {
    notify_save_start = function(bufnr) end,
    notify_save_end = function(bufnr) end,
}

-- Set up LSP integration
function M.setup_lsp_integration(callbacks)
    if type(callbacks) ~= "table" then
        utils.log("Invalid LSP integration callbacks", vim.log.levels.ERROR, false, config.config)
        return
    end

    if type(callbacks.notify_save_start) == "function" then
        lsp_integration.notify_save_start = callbacks.notify_save_start
        utils.log("Registered LSP save start callback", vim.log.levels.DEBUG, false, config.config)
    end

    if type(callbacks.notify_save_end) == "function" then
        lsp_integration.notify_save_end = callbacks.notify_save_end
        utils.log("Registered LSP save end callback", vim.log.levels.DEBUG, false, config.config)
    end

    utils.log("LSP integration set up", vim.log.levels.DEBUG, false, config.config)
end

-- Setup file handlers for LSP and buffer commands
function M.setup_file_handlers()
    -- Create autocmd to intercept BufReadCmd for remote protocols
    local augroup = vim.api.nvim_create_augroup("RemoteFileOpen", { clear = true })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = { "scp://*", "rsync://*" },
        group = augroup,
        callback = function(ev)
            local url = ev.match
            utils.log("Intercepted BufReadCmd for " .. url, vim.log.levels.DEBUG, false, config.config)

            -- Delay requiring operations.lua to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            -- Use our custom remote file opener
            vim.schedule(function()
                operations.simple_open_remote_file(url)
            end)

            -- Return true to indicate we've handled it
            return true
        end,
        desc = "Intercept remote file opening and use custom opener",
    })

    -- Store the original vim.lsp.buf.definition function
    local orig_lsp_buf_definition = vim.lsp.buf.definition

    -- Helper function to create on_list callback for remote file handling
    local function create_remote_on_list(orig_on_list)
        return function(options)
            -- Check if any of the items contain remote URIs
            local has_remote = false
            local remote_item = nil

            if options.items then
                for _, item in ipairs(options.items) do
                    local uri = item.filename or item.uri
                    if uri and (uri:match("^scp://") or uri:match("^rsync://")) then
                        has_remote = true
                        remote_item = item
                        break
                    end
                end
            end

            if has_remote and remote_item then
                utils.log("Handling remote LSP target: " .. remote_item.filename, vim.log.levels.DEBUG, false, config.config)

                -- Delay requiring operations.lua to avoid circular dependency
                if not operations then
                    operations = require("async-remote-write.operations")
                end

                -- Extract position from the item
                local position = nil
                if remote_item.lnum and remote_item.col then
                    position = {
                        line = remote_item.lnum - 1,  -- Convert to 0-based
                        character = remote_item.col - 1  -- Convert to 0-based
                    }
                end

                -- Schedule opening the remote file with position
                vim.schedule(function()
                    operations.simple_open_remote_file(remote_item.filename, position)
                end)
                return
            end

            -- For non-remote results, use the original on_list callback or default behavior
            if orig_on_list then
                orig_on_list(options)
            else
                -- Default behavior: jump to the first location
                if options.items and #options.items > 0 then
                    vim.lsp.util.jump_to_location(options.items[1], 'utf-8', false)
                end
            end
        end
    end

    -- Override vim.lsp.buf.definition to handle remote files
    vim.lsp.buf.definition = function(opts)
        opts = opts or {}
        local orig_on_list = opts.on_list
        opts.on_list = create_remote_on_list(orig_on_list)
        return orig_lsp_buf_definition(opts)
    end

    -- Override other LSP location-based functions
    local lsp_functions_to_intercept = {
        "references",
        "implementation",
        "type_definition",
        "declaration",
    }

    for _, func_name in ipairs(lsp_functions_to_intercept) do
        local orig_func = vim.lsp.buf[func_name]
        if orig_func then
            vim.lsp.buf[func_name] = function(opts)
                opts = opts or {}
                local orig_on_list = opts.on_list
                opts.on_list = create_remote_on_list(orig_on_list)
                return orig_func(opts)
            end
        end
    end

    local original_jump_to_location = vim.lsp.util.jump_to_location

    vim.lsp.util.jump_to_location = function(location, offset_encoding, reuse_win)
        -- Check if this is a remote location first
        local uri = location.uri or location.targetUri

        if uri and (uri:match("^scp://") or uri:match("^rsync://")) then
            utils.log("Intercepting LSP jump to remote location: " .. uri, vim.log.levels.DEBUG, false, config.config)

            -- Extract position information
            local position = location.range and location.range.start
                or location.targetSelectionRange and location.targetSelectionRange.start

            -- Delay requiring operations.lua to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            -- Use our custom handler for remote files
            vim.schedule(function()
                operations.simple_open_remote_file(uri, position)
            end)

            -- Return true to indicate we've handled it
            return true
        end

        -- For non-remote locations, use the original handler
        return original_jump_to_location(location, offset_encoding, reuse_win)
    end

    utils.log("Set up remote file handlers for LSP and buffer commands", vim.log.levels.DEBUG, false, config.config)
end

-- Function to notify that a buffer save is starting
function M.notify_save_start(bufnr)
    -- Call the registered callback
    lsp_integration.notify_save_start(bufnr)
end

-- Function to notify that a buffer save has completed
function M.notify_save_end(bufnr)
    -- Call the registered callback
    lsp_integration.notify_save_end(bufnr)
end

function M.setup()
    -- This function is called during init to make sure the module is loaded
    -- but doesn't need to do anything specific yet.
    utils.log("LSP module initialized", vim.log.levels.DEBUG, false, config.config)
end

return M
