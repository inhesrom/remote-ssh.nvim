local M = {}

function M.setup(opts)
    opts = opts or {}
    
    local remote_treesitter = require('remote-treesitter')
    local remote_lsp = require('remote-lsp')
    
    -- Setup core remote functionality
    remote_lsp.setup(opts)
    remote_treesitter.setup()
    
    -- Setup gitsigns integration if requested and available
    if opts.gitsigns and opts.gitsigns.enabled then
        local ok, remote_gitsigns = pcall(require, 'remote-gitsigns')
        if ok then
            remote_gitsigns.setup(opts.gitsigns)
        else
            vim.notify('Failed to load remote-gitsigns module: ' .. tostring(remote_gitsigns), vim.log.levels.WARN)
        end
    end
end

return M
