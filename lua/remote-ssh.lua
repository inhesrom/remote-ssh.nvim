local M = {}

local remote_treesitter = require('remote-treesitter')
local remote_lsp = require('remote-lsp')

function M.setup(opts)
    remote_treesitter.setup()
    remote_lsp.setup(opts)
end

return M
