-- Terminal picker sidebar for remote-terminal module
local M = {}

local config = require("remote-terminal.config")
local terminal_manager = require("remote-terminal.terminal_manager")

-- Track the line-to-terminal mapping for the picker
local line_to_terminal_id = {}

--- Get the terminal ID at a specific line in the picker
---@param line number 1-indexed line number
---@return number|nil terminal_id
function M.get_terminal_at_line(line)
    return line_to_terminal_id[line]
end

--- Render the picker content
---@return string[] lines
---@return table[] highlights Array of {line, col_start, col_end, hl_group}
local function render_picker_content()
    local lines = {}
    local highlights = {}
    line_to_terminal_id = {}

    -- Header
    table.insert(lines, " Terminals")
    table.insert(highlights, { line = 1, col_start = 0, col_end = -1, hl_group = "TerminalPickerHeader" })
    table.insert(lines, string.rep("-", config.get("picker", "width") - 2))

    local terminals = terminal_manager.get_all_terminals()
    local active_id = terminal_manager.get_active_terminal_id()

    if #terminals == 0 then
        table.insert(lines, " (no terminals)")
        table.insert(highlights, { line = 3, col_start = 0, col_end = -1, hl_group = "TerminalPickerNormal" })
    else
        for i, term in ipairs(terminals) do
            local line_num = #lines + 1
            line_to_terminal_id[line_num] = term.id

            -- Build line content
            local prefix = term.id == active_id and " > " or "   "
            local id_str = tostring(term.id)
            local name = term.display_name or ("shell @ " .. term.connection_info.host)

            -- Truncate name if needed
            local max_name_len = config.get("picker", "width") - #prefix - #id_str - 2
            if #name > max_name_len then
                name = name:sub(1, max_name_len - 1) .. "~"
            end

            local line = prefix .. id_str .. " " .. name

            -- Add exit indicator if terminal has exited
            if term.exited then
                line = line .. " [X]"
            end

            table.insert(lines, line)

            -- Highlights
            local hl_group = term.id == active_id and "TerminalPickerSelected" or "TerminalPickerNormal"
            table.insert(highlights, { line = line_num, col_start = 0, col_end = -1, hl_group = hl_group })

            -- ID highlight
            table.insert(highlights, {
                line = line_num,
                col_start = #prefix,
                col_end = #prefix + #id_str,
                hl_group = "TerminalPickerId",
            })
        end
    end

    return lines, highlights
end

--- Refresh the picker display
function M.refresh()
    local picker_bufnr = terminal_manager.get_picker_bufnr()
    if not picker_bufnr or not vim.api.nvim_buf_is_valid(picker_bufnr) then
        return
    end

    local lines, highlights = render_picker_content()

    -- Make buffer modifiable temporarily
    vim.api.nvim_set_option_value("modifiable", true, { buf = picker_bufnr })
    vim.api.nvim_set_option_value("readonly", false, { buf = picker_bufnr })

    -- Set lines
    vim.api.nvim_buf_set_lines(picker_bufnr, 0, -1, false, lines)

    -- Clear existing highlights and apply new ones
    vim.api.nvim_buf_clear_namespace(picker_bufnr, -1, 0, -1)
    local ns_id = vim.api.nvim_create_namespace("remote_terminal_picker")

    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(picker_bufnr, ns_id, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end

    -- Make buffer non-modifiable
    vim.api.nvim_set_option_value("modifiable", false, { buf = picker_bufnr })
    vim.api.nvim_set_option_value("readonly", true, { buf = picker_bufnr })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = picker_bufnr })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = picker_bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = picker_bufnr })

    -- Position cursor on active terminal
    local picker_win = terminal_manager.get_picker_win()
    if picker_win and vim.api.nvim_win_is_valid(picker_win) then
        local active_id = terminal_manager.get_active_terminal_id()
        if active_id then
            for line, term_id in pairs(line_to_terminal_id) do
                if term_id == active_id then
                    pcall(vim.api.nvim_win_set_cursor, picker_win, { line, 0 })
                    break
                end
            end
        end
    end
end

--- Setup keymaps for the picker buffer
---@param bufnr number
function M.setup_keymaps(bufnr)
    local picker_keymaps = config.get("picker_keymaps") or {}
    local opts = { buffer = bufnr, noremap = true, silent = true }

    -- Navigate down
    if picker_keymaps.navigate_down then
        vim.keymap.set("n", picker_keymaps.navigate_down, function()
            M.navigate_down()
        end, opts)
    end
    vim.keymap.set("n", "<Down>", function()
        M.navigate_down()
    end, opts)

    -- Navigate up
    if picker_keymaps.navigate_up then
        vim.keymap.set("n", picker_keymaps.navigate_up, function()
            M.navigate_up()
        end, opts)
    end
    vim.keymap.set("n", "<Up>", function()
        M.navigate_up()
    end, opts)

    -- Select terminal
    if picker_keymaps.select then
        vim.keymap.set("n", picker_keymaps.select, function()
            M.select_current()
        end, opts)
    end

    -- Mouse click to select terminal
    vim.keymap.set("n", "<LeftMouse>", function()
        -- Process the mouse click to position cursor, then select
        local mouse_pos = vim.fn.getmousepos()
        if mouse_pos.line > 0 then
            pcall(vim.api.nvim_win_set_cursor, 0, { mouse_pos.line, 0 })
            M.select_current()
        end
    end, opts)

    -- Rename terminal
    if picker_keymaps.rename then
        vim.keymap.set("n", picker_keymaps.rename, function()
            M.rename_current()
        end, opts)
    end

    -- Delete terminal
    if picker_keymaps.delete then
        vim.keymap.set("n", picker_keymaps.delete, function()
            M.delete_current()
        end, opts)
    end

    -- New terminal
    if picker_keymaps.new then
        vim.keymap.set("n", picker_keymaps.new, function()
            vim.cmd("RemoteTerminalNew")
        end, opts)
    end

    -- Close split
    if picker_keymaps.close then
        vim.keymap.set("n", picker_keymaps.close, function()
            vim.cmd("RemoteTerminalToggle")
        end, opts)
    end
end

--- Navigate down in the picker
function M.navigate_down()
    local picker_win = terminal_manager.get_picker_win()
    if not picker_win or not vim.api.nvim_win_is_valid(picker_win) then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(picker_win)
    local current_line = cursor[1]

    -- Find next valid line
    local terminals = terminal_manager.get_all_terminals()
    local header_lines = 2 -- Header + separator

    if #terminals == 0 then
        return
    end

    local max_line = header_lines + #terminals
    local next_line = current_line + 1

    if next_line > max_line then
        next_line = header_lines + 1 -- Wrap to first terminal
    elseif next_line <= header_lines then
        next_line = header_lines + 1
    end

    vim.api.nvim_win_set_cursor(picker_win, { next_line, 0 })
end

--- Navigate up in the picker
function M.navigate_up()
    local picker_win = terminal_manager.get_picker_win()
    if not picker_win or not vim.api.nvim_win_is_valid(picker_win) then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(picker_win)
    local current_line = cursor[1]

    -- Find previous valid line
    local terminals = terminal_manager.get_all_terminals()
    local header_lines = 2

    if #terminals == 0 then
        return
    end

    local max_line = header_lines + #terminals
    local prev_line = current_line - 1

    if prev_line <= header_lines then
        prev_line = max_line -- Wrap to last terminal
    end

    vim.api.nvim_win_set_cursor(picker_win, { prev_line, 0 })
end

--- Select the terminal under cursor
function M.select_current()
    local picker_win = terminal_manager.get_picker_win()
    if not picker_win or not vim.api.nvim_win_is_valid(picker_win) then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(picker_win)
    local current_line = cursor[1]

    local term_id = M.get_terminal_at_line(current_line)
    if not term_id then
        return
    end

    local window_manager = require("remote-terminal.window_manager")
    window_manager.switch_terminal(term_id)
    window_manager.focus_terminal()
end

--- Rename the terminal under cursor
function M.rename_current()
    local picker_win = terminal_manager.get_picker_win()
    if not picker_win or not vim.api.nvim_win_is_valid(picker_win) then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(picker_win)
    local current_line = cursor[1]

    local term_id = M.get_terminal_at_line(current_line)
    if not term_id then
        return
    end

    local terminal_session = require("remote-terminal.terminal_session")
    terminal_session.rename_terminal(term_id)
end

--- Delete the terminal under cursor
function M.delete_current()
    local picker_win = terminal_manager.get_picker_win()
    if not picker_win or not vim.api.nvim_win_is_valid(picker_win) then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(picker_win)
    local current_line = cursor[1]

    local term_id = M.get_terminal_at_line(current_line)
    if not term_id then
        return
    end

    local terminal_session = require("remote-terminal.terminal_session")
    terminal_session.close_terminal(term_id)
end

--- Initialize the picker buffer
---@param bufnr number
function M.init_buffer(bufnr)
    M.setup_keymaps(bufnr)
    M.refresh()
end

return M
