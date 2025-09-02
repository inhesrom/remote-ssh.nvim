local M = {}

local log = require("logging").log

local ssh_wrap = function(command, user, host)

end

function M.register()
    vim.api.nvim_create_user_command("RemoteTui", function(opts)
        local bufnr = vim.api.nvim_get_current_buf()
        local metadata = vim.b[bufnr].remote_metadata
        metadata
    end, {

    })
end

return M
