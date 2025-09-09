local M = {}

local session_manager = require("remote-tui.session_manager")
local window_manager = require("remote-tui.window_manager")

-- TUI Session Picker State
local TuiPicker = {
    bufnr = nil,
    win_id = nil,
    sessions = {}, -- List of hidden sessions
    selected_idx = 1,
    mode = "normal", -- 'normal' or 'confirm_delete'
    delete_session_id = nil,
}

-- Create TUI session picker UI
function M.show_picker()
    if not session_manager.has_hidden_sessions() then
        vim.notify("No hidden TUI sessions found", vim.log.levels.WARN)
        return
    end

    -- Setup highlight groups
    window_manager.setup_highlights()

    -- Close existing picker if open
    if TuiPicker.bufnr and vim.api.nvim_buf_is_valid(TuiPicker.bufnr) then
        M.close_picker()
    end

    -- Create buffer
    TuiPicker.bufnr = window_manager.create_buffer("picker", "TUI Sessions")

    -- Create floating window
    TuiPicker.win_id = window_manager.create_picker_window(TuiPicker.bufnr, " Hidden TUI Sessions ")

    -- Reset state
    TuiPicker.selected_idx = 1
    TuiPicker.mode = "normal"
    TuiPicker.delete_session_id = nil

    -- Build sessions list
    TuiPicker.sessions = {}
    for session_id, session in pairs(session_manager.get_hidden_sessions()) do
        table.insert(TuiPicker.sessions, {
            id = session_id,
            metadata = session.metadata,
        })
    end

    -- Sort by creation time (newest first)
    table.sort(TuiPicker.sessions, function(a, b)
        return a.metadata.created_at > b.metadata.created_at
    end)

    M.setup_keymaps()
    M.refresh_display()
end

-- Refresh the picker display
function M.refresh_display()
    if not TuiPicker.bufnr or not vim.api.nvim_buf_is_valid(TuiPicker.bufnr) then
        return
    end

    local lines = {}
    local highlights = {}

    -- Header
    table.insert(lines, "═══ Hidden TUI Sessions ═══")
    table.insert(highlights, { line = #lines - 1, hl_group = "TuiPickerHeader", col_start = 0, col_end = -1 })

    table.insert(lines, "")

    table.insert(lines, "Enter: Restore session  |  d: Delete  |  q: Quit")
    table.insert(highlights, { line = #lines - 1, hl_group = "TuiPickerHelp", col_start = 0, col_end = -1 })

    table.insert(lines, "")

    if TuiPicker.mode == "confirm_delete" then
        table.insert(lines, "⚠️  Delete session? Press 'y' to confirm, 'n' to cancel")
        table.insert(highlights, { line = #lines - 1, hl_group = "TuiPickerWarning", col_start = 0, col_end = -1 })
        table.insert(lines, "")
    end

    -- Session entries
    if #TuiPicker.sessions == 0 then
        table.insert(lines, "  No hidden sessions")
        table.insert(highlights, { line = #lines - 1, hl_group = "TuiPickerEmpty", col_start = 0, col_end = -1 })
    else
        for i, session in ipairs(TuiPicker.sessions) do
            local current_line = #lines
            local prefix = (i == TuiPicker.selected_idx) and "▶ " or "  "
            local time_str = os.date("%m/%d %H:%M", session.metadata.created_at)

            -- Parse app name and host from display_name (format: "app @ host")
            local app_name, host = session.metadata.display_name:match("^(.+) @ (.+)$")
            if not app_name then
                app_name = session.metadata.app_name or "unknown"
                host = session.metadata.connection_info and session.metadata.connection_info.host or "unknown"
            end

            -- Get directory path, with fallback handling
            local directory = session.metadata.directory_path or "~"
            -- Shorten long paths for display
            if #directory > 30 then
                directory = "..." .. directory:sub(-27)
            end

            local display_line = string.format("%s[%s] %s @ %s:%s", prefix, time_str, app_name, host, directory)
            table.insert(lines, display_line)

            -- Highlight entire line if selected
            if i == TuiPicker.selected_idx then
                table.insert(
                    highlights,
                    { line = current_line, hl_group = "TuiPickerSelected", col_start = 0, col_end = -1 }
                )
            end

            -- Calculate positions for different elements
            local col_offset = #prefix

            -- Highlight selector arrow
            if i == TuiPicker.selected_idx then
                table.insert(highlights, { line = current_line, hl_group = "TuiPickerSelector", col_start = 0, col_end = 2 })
            end

            -- Highlight timestamp [MM/dd HH:MM]
            local timestamp_start = col_offset
            local timestamp_end = timestamp_start + #("[" .. time_str .. "]")
            table.insert(highlights, {
                line = current_line,
                hl_group = "TuiPickerTimeStamp",
                col_start = timestamp_start,
                col_end = timestamp_end,
            })

            -- Highlight app name
            local app_start = timestamp_end + 1 -- space after timestamp
            local app_end = app_start + #app_name
            table.insert(
                highlights,
                { line = current_line, hl_group = "TuiPickerAppName", col_start = app_start, col_end = app_end }
            )

            -- Highlight host (after " @ ")
            local host_start = app_end + 3 -- " @ "
            local host_end = host_start + #host
            table.insert(
                highlights,
                { line = current_line, hl_group = "TuiPickerHost", col_start = host_start, col_end = host_end }
            )

            -- Highlight directory path (after ":")
            local dir_start = host_end + 1 -- ":"
            local dir_end = dir_start + #directory
            table.insert(
                highlights,
                { line = current_line, hl_group = "TuiPickerDirectory", col_start = dir_start, col_end = dir_end }
            )
        end
    end

    -- Update buffer content
    vim.api.nvim_buf_set_option(TuiPicker.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(TuiPicker.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(TuiPicker.bufnr, "modifiable", false)

    -- Apply highlights
    local ns_id = vim.api.nvim_create_namespace("TuiSessionPicker")
    vim.api.nvim_buf_clear_namespace(TuiPicker.bufnr, ns_id, 0, -1)

    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(TuiPicker.bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
    end
end

-- Navigate in picker
local function navigate_picker(direction)
    if #TuiPicker.sessions == 0 then
        return
    end

    TuiPicker.selected_idx = TuiPicker.selected_idx + direction

    if TuiPicker.selected_idx < 1 then
        TuiPicker.selected_idx = #TuiPicker.sessions
    elseif TuiPicker.selected_idx > #TuiPicker.sessions then
        TuiPicker.selected_idx = 1
    end

    M.refresh_display()
end

-- Handle session selection
local function select_session()
    if #TuiPicker.sessions == 0 or not TuiPicker.sessions[TuiPicker.selected_idx] then
        return
    end

    local session = TuiPicker.sessions[TuiPicker.selected_idx]
    M.close_picker()
    session_manager.restore_session(session.id)
end

-- Handle delete request
local function request_delete_session()
    if #TuiPicker.sessions == 0 or not TuiPicker.sessions[TuiPicker.selected_idx] then
        return
    end

    local session = TuiPicker.sessions[TuiPicker.selected_idx]
    TuiPicker.mode = "confirm_delete"
    TuiPicker.delete_session_id = session.id
    M.refresh_display()
end

-- Confirm deletion
local function confirm_delete(confirm)
    if TuiPicker.mode ~= "confirm_delete" or not TuiPicker.delete_session_id then
        return
    end

    if confirm then
        session_manager.delete_session(TuiPicker.delete_session_id, true)
        -- Remove from picker sessions list
        for i, session in ipairs(TuiPicker.sessions) do
            if session.id == TuiPicker.delete_session_id then
                table.remove(TuiPicker.sessions, i)
                break
            end
        end
        -- Adjust selected index if needed
        if TuiPicker.selected_idx > #TuiPicker.sessions then
            TuiPicker.selected_idx = math.max(1, #TuiPicker.sessions)
        end
    end

    TuiPicker.mode = "normal"
    TuiPicker.delete_session_id = nil

    if #TuiPicker.sessions == 0 then
        M.close_picker()
        vim.notify("No more hidden sessions", vim.log.levels.INFO)
        return
    end

    M.refresh_display()
end

-- Close picker
function M.close_picker()
    if TuiPicker.win_id and vim.api.nvim_win_is_valid(TuiPicker.win_id) then
        vim.api.nvim_win_close(TuiPicker.win_id, false)
    end

    if TuiPicker.bufnr and vim.api.nvim_buf_is_valid(TuiPicker.bufnr) then
        vim.api.nvim_buf_delete(TuiPicker.bufnr, { force = true })
    end

    TuiPicker.bufnr = nil
    TuiPicker.win_id = nil
    TuiPicker.sessions = {}
end

-- Setup keymaps for picker
function M.setup_keymaps()
    local opts = { noremap = true, silent = true, buffer = TuiPicker.bufnr }

    -- Navigation
    vim.keymap.set("n", "j", function()
        navigate_picker(1)
    end, opts)
    vim.keymap.set("n", "k", function()
        navigate_picker(-1)
    end, opts)
    vim.keymap.set("n", "<Down>", function()
        navigate_picker(1)
    end, opts)
    vim.keymap.set("n", "<Up>", function()
        navigate_picker(-1)
    end, opts)

    -- Selection
    vim.keymap.set("n", "<CR>", select_session, opts)
    vim.keymap.set("n", "<Space>", select_session, opts)

    -- Delete
    vim.keymap.set("n", "d", function()
        if TuiPicker.mode == "normal" then
            request_delete_session()
        end
    end, opts)

    -- Confirm delete
    vim.keymap.set("n", "y", function()
        if TuiPicker.mode == "confirm_delete" then
            confirm_delete(true)
        end
    end, opts)

    vim.keymap.set("n", "n", function()
        if TuiPicker.mode == "confirm_delete" then
            confirm_delete(false)
        end
    end, opts)

    -- Close picker
    vim.keymap.set("n", "q", M.close_picker, opts)
    vim.keymap.set("n", "<Esc>", M.close_picker, opts)
end

-- Check if picker is currently open
function M.is_open()
    return TuiPicker.bufnr and vim.api.nvim_buf_is_valid(TuiPicker.bufnr)
end

-- Get picker state
function M.get_state()
    return {
        open = M.is_open(),
        session_count = #TuiPicker.sessions,
        selected_idx = TuiPicker.selected_idx,
        mode = TuiPicker.mode,
    }
end

return M
