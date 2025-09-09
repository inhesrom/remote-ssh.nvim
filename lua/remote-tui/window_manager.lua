local M = {}

local config = require("remote-tui.config")

-- Create a floating window with given configuration
function M.create_floating_window(window_config)
    local conf = window_config or config.get_window_config()

    local width = math.floor(vim.o.columns * conf.width)
    local height = math.floor(vim.o.lines * conf.height)
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
        border = conf.border,
    }

    -- Create window
    local win = vim.api.nvim_open_win(buf, true, opts)
    return buf, win
end

-- Create a floating picker window
function M.create_picker_window(bufnr, title)
    local picker_config = config.get_picker_config()

    local width = math.floor(vim.o.columns * picker_config.width)
    local height = math.floor(vim.o.lines * picker_config.height)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create floating window
    local win_id = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = title or " TUI Sessions ",
        title_pos = "center",
    })

    -- Setup window options
    vim.api.nvim_win_set_option(win_id, "wrap", false)
    vim.api.nvim_win_set_option(win_id, "cursorline", false)

    return win_id
end

-- Setup highlight groups
function M.setup_highlights()
    local highlights = config.get_highlights()

    -- Set highlight groups
    for hl_name, hl_def in pairs(highlights) do
        vim.api.nvim_set_hl(0, hl_name, hl_def)
    end
end

-- Create a buffer with standard options for TUI purposes
function M.create_buffer(buffer_type, name)
    local buf = vim.api.nvim_create_buf(false, true)

    -- Setup buffer options based on type
    if buffer_type == "picker" then
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "swapfile", false)
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.api.nvim_buf_set_option(buf, "filetype", "tui-session-picker")
        if name then
            vim.api.nvim_buf_set_name(buf, name)
        end
    elseif buffer_type == "terminal" then
        -- Terminal buffers don't auto-wipe - we manage lifecycle
        vim.api.nvim_buf_set_option(buf, "bufhidden", "")
    end

    return buf
end

return M
