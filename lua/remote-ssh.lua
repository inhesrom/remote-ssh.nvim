local M = {}

function M.setup(opts)
    local version = require("version")
    print("Plugin version: " .. version.version)

    local remote_treesitter = require("remote-treesitter")
    local remote_lsp = require("remote-lsp")

    remote_lsp.setup(opts)
    remote_treesitter.setup()
end

return M
