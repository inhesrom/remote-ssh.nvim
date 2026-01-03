local M = {}

local config = require("remote-tui.config")
local commands = require("remote-tui.commands")

function M.setup(opts)
    config.setup(opts or {})
    commands.register()
end

return M
