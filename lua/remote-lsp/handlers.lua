local M = {}

local config = require('remote-lsp.config')
local log = require('logging').log

-- Optimize the publishDiagnostics handler to avoid blocking after save
function M.setup_optimized_handlers()
    local original_publish_diagnostics = vim.lsp.handlers["textDocument/publishDiagnostics"]

    vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config_opt)
        -- Check if this is for a remote buffer
        local uri = result and result.uri
        if uri and (uri:match("^scp://") or uri:match("^rsync://")) then
            -- Schedule diagnostic processing to avoid blocking
            vim.schedule(function()
                original_publish_diagnostics(err, result, ctx, config_opt)
            end)
            return
        end

        -- For non-remote buffers, use the original handler
        return original_publish_diagnostics(err, result, ctx, config_opt)
    end

    log("Optimized LSP handlers set up", vim.log.levels.DEBUG, false, config.config)
end

return M
