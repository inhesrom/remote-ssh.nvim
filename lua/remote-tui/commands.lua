local M = {}

local log = require("logging").log
local utils = require("async-remote-write.utils")
local metadata = require("remote-buffer-metadata")
local build_ssh_cmd = require("async-remote-write.ssh_utils").build_ssh_cmd

M.config = {
    window = {
        type = "float", -- "float" or "split"
        width = 0.9,    -- percentage of screen width (for float)
        height = 0.9,   -- percentage of screen height (for float)
        border = "rounded", -- border style for floating windows
    },
}

local ssh_wrap = function(host, tui_appname, directory_path)
    local cmd = "-t "               -- interactive terminal session
        .. "\""                     -- quote the command being built
        .. "cd " .. directory_path  -- cd into the dir before calling the command
        .. " && "
        .. " bash --login -c "
        .. "'"
        .. tui_appname              -- TUI app to start
        .. "'"
        .. "\""                     -- end quote
    local ssh_command_table = build_ssh_cmd(host, cmd)
    return ssh_command_table
end

local function create_floating_window(config)
    local width = math.floor(vim.o.columns * config.window.width)
    local height = math.floor(vim.o.lines * config.window.height)
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - height) / 2)

    -- Create buffer
    local buf = vim.api.nvim_create_buf(false, true)

    -- Window options
    local opts = {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = row,
        style = "minimal",
        border = config.window.border,
    }

    -- Create window
    local win = vim.api.nvim_open_win(buf, true, opts)
    return buf, win
end

function M.register()
    vim.api.nvim_create_user_command("RemoteTui", function(opts)
        log("Ran Remote TUI Command...", vim.log.levels.WARN, true)
        args = opts.args
        log("args: " .. args, vim.log.levels.WARN, true)
        local bufnr = vim.api.nvim_get_current_buf()
        -- local git_root_path = vim.b[bufnr].remote_lsp.project_root
        -- log("git root: " .. git_root_path, vim.log.levels.WARN, true)
        local buf_info = utils.get_remote_file_info(bufnr)
        local directory_path = vim.fn.fnamemodify(buf_info.path, ":h")
        local ssh_command = ssh_wrap(buf_info.user .. "@" .. buf_info.host, args, directory_path)
        ssh_command = table.concat(ssh_command, " ")
        log(ssh_command, vim.log.levels.WARN, true)

        local buf, win = create_floating_window(M.config)
        vim.bo[buf].bufhidden = "wipe"

        local job_id = vim.fn.termopen(ssh_command, {
        on_exit = function(job_id, exit_code, event_type)
          -- Close window when terminal exits
          if vim.api.nvim_win_is_valid(win) then
            -- vim.api.nvim_win_close(win, true)
          end
        end,
        })

        if job_id <= 0 then
            vim.notify("Failed to start terminal", vim.log.levels.ERROR)
            return
        end

        vim.cmd("startinsert")
    end, {
        nargs = 1,
        desc = "Open a remote TUI app using the current buffers metadata about the remote host",
    })
end

return M
