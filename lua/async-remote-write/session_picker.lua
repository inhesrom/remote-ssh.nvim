-- Session picker for remote SSH plugin
-- Provides a floating window with session history and pinning functionality

local utils = require('async-remote-write.utils')
local config = require('async-remote-write.config')
local operations = require('async-remote-write.operations')

local M = {}

-- Session history storage
local session_data = {
    history = {},           -- Array of session entries, most recent first
    pinned = {},           -- Array of pinned session entries
    max_history = 100      -- Maximum number of history entries to keep
}

-- Session entry structure
local function create_session_entry(url, entry_type, metadata)
    return {
        url = url,
        type = entry_type,          -- 'file' or 'tree_browser'
        timestamp = os.time(),
        display_name = metadata.display_name or utils.parse_remote_path(url).path or url,
        host = utils.parse_remote_path(url).host,
        metadata = metadata or {},
        id = tostring(os.time()) .. "_" .. math.random(1000, 9999)
    }
end

-- Add session entry to history
local function add_to_history(url, entry_type, metadata)
    if not url then return end
    
    -- Remove any existing entry with the same URL to avoid duplicates
    session_data.history = vim.tbl_filter(function(entry)
        return entry.url ~= url
    end, session_data.history)
    
    -- Add new entry at the beginning
    local entry = create_session_entry(url, entry_type, metadata)
    table.insert(session_data.history, 1, entry)
    
    -- Trim history to max size
    if #session_data.history > session_data.max_history then
        session_data.history = vim.list_slice(session_data.history, 1, session_data.max_history)
    end
    
    utils.log("Added to session history: " .. url, vim.log.levels.DEBUG, false, config.config)
end

-- Session picker UI state
local SessionPicker = {
    bufnr = nil,
    win_id = nil,
    items = {},             -- Combined list of pinned + history items
    selected_idx = 1,       -- Currently selected item index
    filter_text = "",       -- Current filter text
    mode = "normal"         -- 'normal' or 'filter'
}

-- Get formatted display text for a session entry
local function format_entry_display(entry, index, is_pinned)
    local pin_icon = is_pinned and "📌 " or "   "
    local type_icon = entry.type == "file" and "📄" or "📁"
    local time_str = os.date("%m/%d %H:%M", entry.timestamp)
    local host_str = entry.host and ("@" .. entry.host) or ""
    
    return string.format("%s%s %s %s %s%s", 
        pin_icon, type_icon, time_str, entry.display_name, host_str,
        is_pinned and " (pinned)" or "")
end

-- Filter items based on filter text
local function filter_items()
    if SessionPicker.filter_text == "" then
        return vim.list_extend(vim.deepcopy(session_data.pinned), vim.deepcopy(session_data.history))
    end
    
    local filtered = {}
    local filter_lower = string.lower(SessionPicker.filter_text)
    
    -- Filter pinned items
    for _, entry in ipairs(session_data.pinned) do
        if string.find(string.lower(entry.display_name), filter_lower) or
           string.find(string.lower(entry.host or ""), filter_lower) then
            table.insert(filtered, entry)
        end
    end
    
    -- Filter history items
    for _, entry in ipairs(session_data.history) do
        if string.find(string.lower(entry.display_name), filter_lower) or
           string.find(string.lower(entry.host or ""), filter_lower) then
            table.insert(filtered, entry)
        end
    end
    
    return filtered
end

-- Refresh the picker display
local function refresh_display()
    if not SessionPicker.bufnr or not vim.api.nvim_buf_is_valid(SessionPicker.bufnr) then
        return
    end
    
    -- Get filtered items
    SessionPicker.items = filter_items()
    
    local lines = {}
    local highlights = {}
    
    -- Header
    table.insert(lines, "╭─ Remote SSH Session Picker ─────────────────────────╮")
    table.insert(lines, "│ Select a session to open or pin/unpin entries      │")
    table.insert(lines, "│ <Enter>:Open <p>:Pin/Unpin </>:Filter <q>:Quit      │")
    table.insert(lines, "╰─────────────────────────────────────────────────────╯")
    table.insert(lines, "")
    
    -- Filter input line
    if SessionPicker.mode == "filter" then
        table.insert(lines, "Filter: " .. SessionPicker.filter_text .. "█")
        table.insert(highlights, {line = #lines - 1, hl_group = "Search", col_start = 0, col_end = -1})
    else
        table.insert(lines, "Filter: " .. SessionPicker.filter_text)
    end
    table.insert(lines, "")
    
    local header_lines = #lines
    
    -- Session entries
    if #SessionPicker.items == 0 then
        table.insert(lines, "  No sessions found")
        table.insert(highlights, {line = #lines - 1, hl_group = "Comment", col_start = 0, col_end = -1})
    else
        for i, entry in ipairs(SessionPicker.items) do
            local is_pinned = vim.tbl_contains(vim.tbl_map(function(p) return p.id end, session_data.pinned), entry.id)
            local display_text = format_entry_display(entry, i, is_pinned)
            
            -- Add selection indicator
            if i == SessionPicker.selected_idx then
                display_text = "▶ " .. display_text
                table.insert(highlights, {line = #lines, hl_group = "Visual", col_start = 0, col_end = -1})
            else
                display_text = "  " .. display_text
            end
            
            table.insert(lines, display_text)
            
            -- Add specific highlights for different elements
            if is_pinned then
                -- Highlight pinned entries
                table.insert(highlights, {line = #lines - 1, hl_group = "Special", col_start = 2, col_end = 4})
            end
        end
    end
    
    -- Update buffer content
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_lines(SessionPicker.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'modifiable', false)
    
    -- Apply highlights
    local ns_id = vim.api.nvim_create_namespace("RemoteSessionPicker")
    vim.api.nvim_buf_clear_namespace(SessionPicker.bufnr, ns_id, 0, -1)
    
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(
            SessionPicker.bufnr,
            ns_id,
            hl.hl_group,
            hl.line,
            hl.col_start,
            hl.col_end
        )
    end
end

-- Handle navigation
local function navigate(direction)
    if #SessionPicker.items == 0 then return end
    
    SessionPicker.selected_idx = SessionPicker.selected_idx + direction
    
    if SessionPicker.selected_idx < 1 then
        SessionPicker.selected_idx = #SessionPicker.items
    elseif SessionPicker.selected_idx > #SessionPicker.items then
        SessionPicker.selected_idx = 1
    end
    
    refresh_display()
end

-- Open selected session
local function open_selected()
    if #SessionPicker.items == 0 or not SessionPicker.items[SessionPicker.selected_idx] then
        return
    end
    
    local entry = SessionPicker.items[SessionPicker.selected_idx]
    
    -- Close picker first
    M.close_picker()
    
    -- Add to history (moves to top)
    add_to_history(entry.url, entry.type, entry.metadata)
    
    if entry.type == "file" then
        operations.simple_open_remote_file(entry.url)
    elseif entry.type == "tree_browser" then
        local tree_browser = require('async-remote-write.tree_browser')
        tree_browser.open_tree(entry.url)
    end
    
    utils.log("Opened session: " .. entry.url, vim.log.levels.INFO, true, config.config)
end

-- Toggle pin status of selected item
local function toggle_pin()
    if #SessionPicker.items == 0 or not SessionPicker.items[SessionPicker.selected_idx] then
        return
    end
    
    local entry = SessionPicker.items[SessionPicker.selected_idx]
    local pinned_idx = nil
    
    -- Check if already pinned
    for i, pinned_entry in ipairs(session_data.pinned) do
        if pinned_entry.id == entry.id then
            pinned_idx = i
            break
        end
    end
    
    if pinned_idx then
        -- Unpin
        table.remove(session_data.pinned, pinned_idx)
        utils.log("Unpinned: " .. entry.display_name, vim.log.levels.INFO, true, config.config)
    else
        -- Pin (add to pinned list if not already there)
        table.insert(session_data.pinned, entry)
        utils.log("Pinned: " .. entry.display_name, vim.log.levels.INFO, true, config.config)
    end
    
    refresh_display()
end

-- Handle filter input
local function handle_filter_input(char)
    if char == "" then -- Backspace
        SessionPicker.filter_text = string.sub(SessionPicker.filter_text, 1, -2)
    else
        SessionPicker.filter_text = SessionPicker.filter_text .. char
    end
    
    SessionPicker.selected_idx = 1
    refresh_display()
end

-- Setup keymaps for the picker
local function setup_keymaps()
    local opts = { noremap = true, silent = true, buffer = SessionPicker.bufnr }
    
    -- Navigation
    vim.keymap.set('n', 'j', function() navigate(1) end, opts)
    vim.keymap.set('n', 'k', function() navigate(-1) end, opts)
    vim.keymap.set('n', '<Down>', function() navigate(1) end, opts)
    vim.keymap.set('n', '<Up>', function() navigate(-1) end, opts)
    
    -- Selection
    vim.keymap.set('n', '<CR>', open_selected, opts)
    vim.keymap.set('n', '<Space>', open_selected, opts)
    
    -- Pin/Unpin
    vim.keymap.set('n', 'p', toggle_pin, opts)
    
    -- Filter mode
    vim.keymap.set('n', '/', function()
        SessionPicker.mode = "filter"
        refresh_display()
    end, opts)
    
    -- Exit filter mode
    vim.keymap.set('n', '<Esc>', function()
        if SessionPicker.mode == "filter" then
            SessionPicker.mode = "normal"
            refresh_display()
        else
            M.close_picker()
        end
    end, opts)
    
    -- Clear filter
    vim.keymap.set('n', '<C-c>', function()
        SessionPicker.filter_text = ""
        SessionPicker.selected_idx = 1
        refresh_display()
    end, opts)
    
    -- Close picker
    vim.keymap.set('n', 'q', M.close_picker, opts)
    vim.keymap.set('n', '<C-q>', M.close_picker, opts)
    
    -- Filter input handling (when in filter mode)
    for i = 32, 126 do  -- Printable ASCII characters
        local char = string.char(i)
        vim.keymap.set('n', char, function()
            if SessionPicker.mode == "filter" then
                handle_filter_input(char)
            end
        end, opts)
    end
    
    -- Backspace in filter mode
    vim.keymap.set('n', '<BS>', function()
        if SessionPicker.mode == "filter" then
            handle_filter_input("")
        end
    end, opts)
end

-- Create and show the session picker
function M.show_picker()
    -- Close existing picker if open
    if SessionPicker.bufnr and vim.api.nvim_buf_is_valid(SessionPicker.bufnr) then
        M.close_picker()
    end
    
    -- Create buffer
    SessionPicker.bufnr = vim.api.nvim_create_buf(false, true)
    
    -- Setup buffer options
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'swapfile', false)
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'filetype', 'remote-session-picker')
    vim.api.nvim_buf_set_name(SessionPicker.bufnr, 'Remote SSH Session Picker')
    
    -- Calculate window size
    local width = math.min(80, vim.o.columns - 4)
    local height = math.min(25, vim.o.lines - 4)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    
    -- Create floating window
    SessionPicker.win_id = vim.api.nvim_open_win(SessionPicker.bufnr, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = ' Remote SSH Sessions ',
        title_pos = 'center'
    })
    
    -- Setup window options
    vim.api.nvim_win_set_option(SessionPicker.win_id, 'wrap', false)
    vim.api.nvim_win_set_option(SessionPicker.win_id, 'cursorline', false)
    
    -- Setup keymaps
    setup_keymaps()
    
    -- Reset state
    SessionPicker.selected_idx = 1
    SessionPicker.filter_text = ""
    SessionPicker.mode = "normal"
    
    -- Initial display
    refresh_display()
    
    utils.log("Opened remote SSH session picker", vim.log.levels.DEBUG, false, config.config)
end

-- Close the session picker
function M.close_picker()
    if SessionPicker.win_id and vim.api.nvim_win_is_valid(SessionPicker.win_id) then
        vim.api.nvim_win_close(SessionPicker.win_id, false)
    end
    
    if SessionPicker.bufnr and vim.api.nvim_buf_is_valid(SessionPicker.bufnr) then
        vim.api.nvim_buf_delete(SessionPicker.bufnr, { force = true })
    end
    
    SessionPicker.bufnr = nil
    SessionPicker.win_id = nil
    SessionPicker.items = {}
    
    utils.log("Closed remote SSH session picker", vim.log.levels.DEBUG, false, config.config)
end

-- Public API functions

-- Track file opening
function M.track_file_open(url, metadata)
    add_to_history(url, "file", metadata or {})
end

-- Track tree browser opening
function M.track_tree_browser_open(url, metadata)
    add_to_history(url, "tree_browser", metadata or {})
end

-- Get session history
function M.get_history()
    return vim.deepcopy(session_data.history)
end

-- Get pinned sessions
function M.get_pinned()
    return vim.deepcopy(session_data.pinned)
end

-- Clear history
function M.clear_history()
    session_data.history = {}
    utils.log("Cleared session history", vim.log.levels.INFO, true, config.config)
end

-- Clear pinned sessions
function M.clear_pinned()
    session_data.pinned = {}
    utils.log("Cleared pinned sessions", vim.log.levels.INFO, true, config.config)
end

-- Configure maximum history size
function M.set_max_history(max)
    if type(max) == "number" and max > 0 then
        session_data.max_history = max
        -- Trim current history if needed
        if #session_data.history > max then
            session_data.history = vim.list_slice(session_data.history, 1, max)
        end
        utils.log("Set max history size to " .. max, vim.log.levels.DEBUG, false, config.config)
    end
end

-- Get session statistics
function M.get_stats()
    return {
        history_count = #session_data.history,
        pinned_count = #session_data.pinned,
        max_history = session_data.max_history,
        total_sessions = #session_data.history + #session_data.pinned
    }
end

return M