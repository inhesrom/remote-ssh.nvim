-- Session picker UI for remote-session
-- Floating window for session selection and management
local M = {}

local config = require("remote-session.config")
local session_manager = require("remote-session.session_manager")

-- Picker state
local PickerState = {
    bufnr = nil,
    win_id = nil,
    items = {},
    selected_idx = 1,
    filter_text = "",
    mode = "normal", -- 'normal' or 'filter'
}

--- Setup highlight groups for the picker
local function setup_highlight_groups()
    local highlights = {
        RemoteSessionActive = { fg = "#90caf9", bold = true },
        RemoteSessionMinimized = { fg = "#ffb74d" },
        RemoteSessionPersisted = { fg = "#9e9e9e" },
        RemoteSessionSelected = { bg = "#404040" },
        RemoteSessionHeader = { fg = "#ffffff", bold = true },
        RemoteSessionHelp = { fg = "#888888", italic = true },
        RemoteSessionFilter = { fg = "#4caf50" },
    }

    for hl_name, hl_def in pairs(highlights) do
        if vim.fn.hlexists(hl_name) == 0 then
            vim.api.nvim_set_hl(0, hl_name, hl_def)
        end
    end
end

--- Get state icon and highlight for a session
---@param session table
---@return string icon, string hl_group
local function get_state_display(session)
    local state = session.state or "persisted"

    if state == "active" then
        return "[ACTIVE]   ", "RemoteSessionActive"
    elseif state == "minimized" then
        return "[MINIMIZED]", "RemoteSessionMinimized"
    else
        return "[HISTORY]  ", "RemoteSessionPersisted"
    end
end

--- Format a session entry for display
---@param session table
---@param is_selected boolean
---@return string line
---@return table[] highlights
local function format_session_entry(session, is_selected)
    local state_icon, state_hl = get_state_display(session)
    local prefix = is_selected and "▶ " or "  "
    local line = prefix .. state_icon .. " " .. session.name

    local highlights = {}

    -- Selection highlight
    if is_selected then
        table.insert(highlights, {
            hl_group = "RemoteSessionSelected",
            col_start = 0,
            col_end = -1,
        })
    end

    -- State highlight
    table.insert(highlights, {
        hl_group = state_hl,
        col_start = #prefix,
        col_end = #prefix + #state_icon,
    })

    return line, highlights
end

--- Filter sessions based on filter text
---@return table[] filtered_sessions
local function filter_sessions()
    local all_sessions = session_manager.get_all_for_picker()

    if PickerState.filter_text == "" then
        return all_sessions
    end

    local filter_lower = string.lower(PickerState.filter_text)
    local filtered = {}

    for _, session in ipairs(all_sessions) do
        local name_lower = string.lower(session.name or "")
        local host_lower = string.lower(session.host or "")
        local path_lower = string.lower(session.path or "")

        if
            name_lower:find(filter_lower, 1, true)
            or host_lower:find(filter_lower, 1, true)
            or path_lower:find(filter_lower, 1, true)
        then
            table.insert(filtered, session)
        end
    end

    return filtered
end

--- Calculate optimal window size
---@return number width, number height
local function calculate_window_size()
    local picker_config = config.get("picker") or {}
    local width_config = picker_config.width or 0.6
    local max_height = picker_config.max_height or 20

    local editor_width = vim.o.columns
    local editor_height = vim.o.lines

    -- Calculate width
    local width
    if type(width_config) == "number" and width_config < 1 then
        width = math.floor(editor_width * width_config)
    else
        width = math.min(width_config, editor_width - 4)
    end
    width = math.max(width, 50)

    -- Calculate height based on content
    local sessions = session_manager.get_all_for_picker()
    local content_height = 7 + #sessions -- header + help + filter + sessions

    local height = math.min(content_height, max_height, editor_height - 4)
    height = math.max(height, 10)

    return width, height
end

--- Refresh the picker display
local function refresh_display()
    if not PickerState.bufnr or not vim.api.nvim_buf_is_valid(PickerState.bufnr) then
        return
    end

    PickerState.items = filter_sessions()

    -- Clamp selected index
    if PickerState.selected_idx > #PickerState.items then
        PickerState.selected_idx = math.max(1, #PickerState.items)
    end

    local lines = {}
    local all_highlights = {}

    -- Get window width for formatting
    local width = 60
    if PickerState.win_id and vim.api.nvim_win_is_valid(PickerState.win_id) then
        width = vim.api.nvim_win_get_width(PickerState.win_id)
    end

    -- Header
    local show_hints = config.get("picker", "show_hints") ~= false
    if show_hints then
        local title = " Remote Sessions "
        local top_line = "╭─" .. title .. string.rep("─", math.max(0, width - #title - 4)) .. "╮"
        table.insert(lines, top_line)

        local help = "<Enter>:Open <m>:Minimize <d>:Delete <r>:Rename </>:Filter <q>:Quit"
        local help_line = "│ " .. help .. string.rep(" ", math.max(0, width - #help - 4)) .. " │"
        table.insert(lines, help_line)
        table.insert(all_highlights, { line = 1, hl_group = "RemoteSessionHelp", col_start = 2, col_end = #help + 2 })

        local bottom_line = "╰" .. string.rep("─", width - 2) .. "╯"
        table.insert(lines, bottom_line)
        table.insert(lines, "")
    end

    -- Filter line
    local filter_line = "Filter: " .. PickerState.filter_text
    if PickerState.mode == "filter" then
        filter_line = filter_line .. "█"
        table.insert(all_highlights, {
            line = #lines,
            hl_group = "RemoteSessionFilter",
            col_start = 0,
            col_end = -1,
        })
    end
    table.insert(lines, filter_line)
    table.insert(lines, "")

    local content_start_line = #lines

    -- Session entries
    if #PickerState.items == 0 then
        table.insert(lines, "  No sessions found")
        table.insert(all_highlights, {
            line = #lines - 1,
            hl_group = "Comment",
            col_start = 0,
            col_end = -1,
        })
    else
        for i, session in ipairs(PickerState.items) do
            local is_selected = (i == PickerState.selected_idx)
            local line, highlights = format_session_entry(session, is_selected)

            table.insert(lines, line)

            local line_idx = #lines - 1
            for _, hl in ipairs(highlights) do
                hl.line = line_idx
                table.insert(all_highlights, hl)
            end
        end
    end

    -- Update buffer
    vim.api.nvim_buf_set_option(PickerState.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(PickerState.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(PickerState.bufnr, "modifiable", false)

    -- Apply highlights
    local ns_id = vim.api.nvim_create_namespace("RemoteSessionPicker")
    vim.api.nvim_buf_clear_namespace(PickerState.bufnr, ns_id, 0, -1)

    for _, hl in ipairs(all_highlights) do
        vim.api.nvim_buf_add_highlight(PickerState.bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
    end
end

--- Navigate in the picker
---@param direction number 1 for down, -1 for up
local function navigate(direction)
    if #PickerState.items == 0 then
        return
    end

    PickerState.selected_idx = PickerState.selected_idx + direction

    if PickerState.selected_idx < 1 then
        PickerState.selected_idx = #PickerState.items
    elseif PickerState.selected_idx > #PickerState.items then
        PickerState.selected_idx = 1
    end

    refresh_display()
end

--- Get currently selected session
---@return table|nil session
local function get_selected_session()
    if #PickerState.items == 0 then
        return nil
    end
    return PickerState.items[PickerState.selected_idx]
end

--- Open/restore selected session
local function open_selected()
    local session = get_selected_session()
    if not session then
        return
    end

    M.close()

    local session_module = require("remote-session.session")

    if session.state == "active" then
        -- Already active, nothing to do
        vim.notify("[remote-session] Session is already active", vim.log.levels.INFO)
    else
        session_module.restore(session.id)
    end
end

--- Minimize selected session
local function minimize_selected()
    local session = get_selected_session()
    if not session then
        return
    end

    if session.state ~= "active" then
        vim.notify("[remote-session] Can only minimize active sessions", vim.log.levels.WARN)
        return
    end

    local session_module = require("remote-session.session")
    session_module.minimize(session.id)

    refresh_display()
end

--- Delete selected session
local function delete_selected()
    local session = get_selected_session()
    if not session then
        return
    end

    local choice = vim.fn.confirm("Delete session: " .. session.name .. "?", "&Yes\n&No", 2)
    if choice ~= 1 then
        return
    end

    local session_module = require("remote-session.session")
    session_module.close(session.id, { force = true })

    refresh_display()
end

--- Rename selected session
local function rename_selected()
    local session = get_selected_session()
    if not session then
        return
    end

    M.close()

    local session_module = require("remote-session.session")
    session_module.rename(session.id)
end

--- Handle filter input
---@param char string
local function handle_filter_input(char)
    if char == "" then -- Backspace
        PickerState.filter_text = string.sub(PickerState.filter_text, 1, -2)
    else
        PickerState.filter_text = PickerState.filter_text .. char
    end

    PickerState.selected_idx = 1
    refresh_display()
end

--- Setup keymaps for the picker
local function setup_keymaps()
    local opts = { noremap = true, silent = true, buffer = PickerState.bufnr }

    -- Navigation
    vim.keymap.set("n", "j", function()
        if PickerState.mode == "filter" then
            handle_filter_input("j")
        else
            navigate(1)
        end
    end, opts)

    vim.keymap.set("n", "k", function()
        if PickerState.mode == "filter" then
            handle_filter_input("k")
        else
            navigate(-1)
        end
    end, opts)

    vim.keymap.set("n", "<Down>", function()
        navigate(1)
    end, opts)
    vim.keymap.set("n", "<Up>", function()
        navigate(-1)
    end, opts)

    -- Selection
    vim.keymap.set("n", "<CR>", open_selected, opts)
    vim.keymap.set("n", "<Space>", open_selected, opts)

    -- Minimize
    vim.keymap.set("n", "m", function()
        if PickerState.mode == "filter" then
            handle_filter_input("m")
        else
            minimize_selected()
        end
    end, opts)

    -- Delete
    vim.keymap.set("n", "d", function()
        if PickerState.mode == "filter" then
            handle_filter_input("d")
        else
            delete_selected()
        end
    end, opts)

    -- Rename
    vim.keymap.set("n", "r", function()
        if PickerState.mode == "filter" then
            handle_filter_input("r")
        else
            rename_selected()
        end
    end, opts)

    -- Filter mode
    vim.keymap.set("n", "/", function()
        PickerState.mode = "filter"
        refresh_display()
    end, opts)

    -- Exit filter mode
    vim.keymap.set("n", "<Esc>", function()
        if PickerState.mode == "filter" then
            PickerState.mode = "normal"
            refresh_display()
        else
            M.close()
        end
    end, opts)

    -- Clear filter
    vim.keymap.set("n", "<C-c>", function()
        PickerState.filter_text = ""
        PickerState.selected_idx = 1
        PickerState.mode = "normal"
        refresh_display()
    end, opts)

    -- Close
    vim.keymap.set("n", "q", function()
        if PickerState.mode == "filter" then
            handle_filter_input("q")
        else
            M.close()
        end
    end, opts)

    -- Backspace in filter mode
    vim.keymap.set("n", "<BS>", function()
        if PickerState.mode == "filter" then
            handle_filter_input("")
        end
    end, opts)

    -- Character input for filter mode
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:/ \\"
    for i = 1, #chars do
        local char = chars:sub(i, i)
        if not vim.tbl_contains({ "j", "k", "m", "d", "r", "q", "/" }, char) then
            vim.keymap.set("n", char, function()
                if PickerState.mode == "filter" then
                    handle_filter_input(char)
                end
            end, opts)
        end
    end
end

--- Show the session picker
function M.show()
    -- Close existing picker if open
    if PickerState.bufnr and vim.api.nvim_buf_is_valid(PickerState.bufnr) then
        M.close()
    end

    setup_highlight_groups()

    -- Create buffer
    PickerState.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(PickerState.bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(PickerState.bufnr, "swapfile", false)
    vim.api.nvim_buf_set_option(PickerState.bufnr, "modifiable", false)
    vim.api.nvim_buf_set_option(PickerState.bufnr, "filetype", "remote-session-picker")
    vim.api.nvim_buf_set_name(PickerState.bufnr, "Remote Sessions")

    -- Calculate window size
    local width, height = calculate_window_size()
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create floating window
    PickerState.win_id = vim.api.nvim_open_win(PickerState.bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Remote Sessions ",
        title_pos = "center",
    })

    -- Window options
    vim.api.nvim_win_set_option(PickerState.win_id, "wrap", false)
    vim.api.nvim_win_set_option(PickerState.win_id, "cursorline", false)

    -- Setup keymaps
    setup_keymaps()

    -- Reset state
    PickerState.selected_idx = 1
    PickerState.filter_text = ""
    PickerState.mode = "normal"

    -- Initial display
    refresh_display()
end

--- Close the session picker
function M.close()
    if PickerState.win_id and vim.api.nvim_win_is_valid(PickerState.win_id) then
        vim.api.nvim_win_close(PickerState.win_id, false)
    end

    if PickerState.bufnr and vim.api.nvim_buf_is_valid(PickerState.bufnr) then
        vim.api.nvim_buf_delete(PickerState.bufnr, { force = true })
    end

    PickerState.bufnr = nil
    PickerState.win_id = nil
    PickerState.items = {}
end

--- Check if picker is open
---@return boolean
function M.is_open()
    return PickerState.bufnr ~= nil and vim.api.nvim_buf_is_valid(PickerState.bufnr)
end

return M
