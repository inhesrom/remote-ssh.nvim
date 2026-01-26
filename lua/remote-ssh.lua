local M = {}

function M.setup(opts)
    local version = require("version")
    -- print("Plugin version: " .. version.version)

    local remote_treesitter = require("remote-treesitter")
    local remote_lsp = require("remote-lsp")
    local remote_tui = require("remote-tui")
    local remote_terminal = require("remote-terminal")

    remote_lsp.setup(opts)
    remote_treesitter.setup()
    remote_tui.setup(opts and opts.remote_tui_opts or {})
    remote_terminal.setup(opts and opts.remote_terminal_opts or {})
end

return M
