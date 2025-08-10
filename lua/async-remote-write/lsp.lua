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

    -- Intercept the LSP handler for textDocument/definition
    -- Save the original handler
    local orig_definition_handler = vim.lsp.handlers["textDocument/definition"]

    -- Create a new handler that intercepts remote URLs
    -- Enhanced LSP definition handler with better URI handling
    vim.lsp.handlers["textDocument/definition"] = function(err, result, ctx, config_opt)
        if err or not result or vim.tbl_isempty(result) then
            -- Pass through to original handler for error cases
            return orig_definition_handler(err, result, ctx, config_opt)
        end

        utils.log("Definition handler received result: " .. vim.inspect(result), vim.log.levels.DEBUG, false, config.config)

        -- Extract target URI based on result format
        local target_uri, position

        if result.uri then
            -- Single location
            target_uri = result.uri
            position = result.range and result.range.start
        elseif type(result) == "table" then
            if result[1] and result[1].uri then
                -- Array of locations - take the first one
                target_uri = result[1].uri
                position = result[1].range and result[1].range.start
            elseif result[1] and result[1].targetUri then
                -- LocationLink[] format
                target_uri = result[1].targetUri
                position = result[1].targetSelectionRange and result[1].targetSelectionRange.start
                    or result[1].targetRange and result[1].targetRange.start
            end
        end

        if not target_uri then
            utils.log("No target URI found in definition result", vim.log.levels.WARN, false, config.config)
            return orig_definition_handler(err, result, ctx, config_opt)
        end

        utils.log("LSP definition target URI: " .. target_uri, vim.log.levels.DEBUG, false, config.config)

        -- Check if this is a remote URI we should handle
        if target_uri:match("^scp://") or target_uri:match("^rsync://") then
            utils.log("Handling remote definition target: " .. target_uri, vim.log.levels.DEBUG, false, config.config)

            -- Delay requiring operations.lua to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            -- Schedule opening the remote file with position
            vim.schedule(function()
                operations.simple_open_remote_file(target_uri, position)
            end)
            return
        end

        -- For non-remote URIs, use the original handler
        return orig_definition_handler(err, result, ctx, config_opt)
    end

    -- Also intercept other LSP location-based handlers
    local handlers_to_intercept = {
        "textDocument/references",
        "textDocument/implementation",
        "textDocument/typeDefinition",
        "textDocument/declaration",
    }

    for _, handler_name in ipairs(handlers_to_intercept) do
        local orig_handler = vim.lsp.handlers[handler_name]
        if orig_handler then
            vim.lsp.handlers[handler_name] = function(err, result, ctx, config_opt)
                -- Reuse the same intercept logic as for definitions
                return vim.lsp.handlers["textDocument/definition"](err, result, ctx, config_opt)
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
