-- Session picker for remote SSH plugin
-- Provides a floating window with session history and pinning functionality

local utils = require('async-remote-write.utils')
local config = require('async-remote-write.config')
local operations = require('async-remote-write.operations')

local M = {}

-- Icon system with nvim-web-devicons integration (same as tree browser)
local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

-- Primary icons (preferred Unicode icons)
local primary_icons = {
    folder_closed = " ",  -- Unicode closed folder icon
    folder_open = " ",    -- Unicode open folder icon
}

-- Default fallback icons when Unicode doesn't work properly
local fallback_icons = {
    folder_closed = "[+]",  -- ASCII fallback
    folder_open = "[-]",    -- ASCII fallback
    file_default = " • "    -- Simple ASCII fallback
}

-- Icon cache for performance
local icon_cache = {}
local MAX_ICON_CACHE_ENTRIES = 500

-- Evict old icon cache entries when over limit
local function evict_old_icon_cache_entries()
    local cache_size = vim.tbl_count(icon_cache)
    if cache_size <= MAX_ICON_CACHE_ENTRIES then
        return 0
    end

    -- For icon cache, we'll just clear half of it since we don't track timestamps
    local keys = vim.tbl_keys(icon_cache)
    local to_remove = math.floor(cache_size / 2)
    local removed_count = 0

    for i = 1, to_remove do
        if keys[i] then
            icon_cache[keys[i]] = nil
            removed_count = removed_count + 1
        end
    end

    if removed_count > 0 then
        utils.log("Evicted " .. removed_count .. " icon cache entries (cache size limit: " .. MAX_ICON_CACHE_ENTRIES .. ")", vim.log.levels.DEBUG, false, config.config)
    end

    return removed_count
end

-- Get file icon and highlight group
local function get_file_icon(filename, is_dir)
    -- Cache key
    local cache_key = filename .. (is_dir and "_dir" or "_file")

    if icon_cache[cache_key] then
        return icon_cache[cache_key].icon, icon_cache[cache_key].hl_group
    end

    local icon, hl_group

    utils.log("Getting icon for: " .. filename .. " (dir: " .. tostring(is_dir) .. ")", vim.log.levels.DEBUG, false, config.config)

    if is_dir then
        -- Directory icons - try primary Unicode icons first, fallback to ASCII
        icon = primary_icons.folder_closed

        if has_devicons then
            hl_group = "NvimTreeFolderClosed"
        else
            hl_group = "Directory"
        end

        utils.log("Directory icon: '" .. icon .. "' with highlight: " .. hl_group, vim.log.levels.DEBUG, false, config.config)
    else
        -- File icons
        if has_devicons then
            local extension = filename:match("%.([^%.]+)$") or ""
            local file_icon, color = devicons.get_icon_color(filename, extension, { default = true })
            icon = file_icon or fallback_icons.file_default

            -- Create a unique highlight group for this file type
            if color then
                hl_group = "DevIcon" .. (extension:gsub("[^%w]", "") or "Default")
                -- Set up the highlight group with the color
                vim.api.nvim_set_hl(0, hl_group, { fg = color })
            else
                hl_group = "NvimTreeNormal"
            end

            utils.log("File icon from devicons: '" .. (file_icon or "nil") .. "' -> '" .. icon .. "'", vim.log.levels.DEBUG, false, config.config)
        else
            -- Fallback file icon
            icon = fallback_icons.file_default
            hl_group = "Normal"

            utils.log("File fallback icon: '" .. icon .. "'", vim.log.levels.DEBUG, false, config.config)
        end
    end

    -- Cache the result with size management
    evict_old_icon_cache_entries()  -- Check size limits before adding
    icon_cache[cache_key] = { icon = icon, hl_group = hl_group }

    utils.log("Final icon result: '" .. icon .. "' with highlight: " .. hl_group, vim.log.levels.DEBUG, false, config.config)
    return icon, hl_group
end

-- Clear icon cache (useful when switching themes)
local function clear_icon_cache()
    icon_cache = {}
end

-- Setup default highlight groups for the session picker
local function setup_highlight_groups()
    -- Default highlight groups that work with most color schemes
    local highlights = {
        -- Folder states
        NvimTreeFolderOpen = { fg = "#90caf9", bold = true },        -- Light blue for open folders
        NvimTreeFolderClosed = { fg = "#ffb74d", bold = true },      -- Orange for closed folders

        -- General tree elements
        NvimTreeIndentMarker = { fg = "#4a4a4a" },                   -- Gray for arrows and indentation
        NvimTreeNormal = { fg = "#ffffff" },                         -- Default text color

        -- File type fallbacks (when nvim-web-devicons not available)
        RemoteSessionFile = { fg = "#e0e0e0" },                      -- Light gray for files
        RemoteSessionDirectory = { fg = "#ffb74d", bold = true },    -- Orange for directories
        RemoteSessionPinned = { fg = "#ffd700", bold = true },       -- Gold for pinned items
        RemoteSessionSelected = { bg = "#404040" },                  -- Gray background for selection
    }

    -- Only set highlights that don't already exist
    for hl_name, hl_def in pairs(highlights) do
        if vim.fn.hlexists(hl_name) == 0 then
            vim.api.nvim_set_hl(0, hl_name, hl_def)
        end
    end
end

-- Persistent storage path
local data_path = vim.fn.stdpath('data') .. '/remote-ssh-sessions.json'

-- Session history storage
local session_data = {
    history = {},           -- Array of session entries, most recent first
    pinned = {},           -- Array of pinned session entries
    max_history = 100      -- Maximum number of history entries to keep
}

-- Load session data from persistent storage
local function load_session_data()
    local file = io.open(data_path, 'r')
    if not file then
        utils.log("No existing session data found, starting fresh", vim.log.levels.DEBUG, false, config.config)
        return
    end

    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local ok, data = pcall(vim.json.decode, content)
        if ok and data then
            session_data.history = data.history or {}
            session_data.pinned = data.pinned or {}
            session_data.max_history = data.max_history or 100
            utils.log("Loaded " .. #session_data.history .. " history entries and " .. #session_data.pinned .. " pinned entries", vim.log.levels.DEBUG, false, config.config)
        else
            utils.log("Failed to parse session data, starting fresh", vim.log.levels.WARN, false, config.config)
        end
    end
end

-- Save session data to persistent storage
local function save_session_data()
    local content = vim.json.encode(session_data)
    local file = io.open(data_path, 'w')
    if file then
        file:write(content)
        file:close()
        utils.log("Saved session data to " .. data_path, vim.log.levels.DEBUG, false, config.config)
    else
        utils.log("Failed to save session data to " .. data_path, vim.log.levels.ERROR, false, config.config)
    end
end

-- Initialize session data on module load
load_session_data()

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

    -- Check if this URL is already pinned
    local is_pinned = false
    for _, pinned_entry in ipairs(session_data.pinned) do
        if pinned_entry.url == url then
            is_pinned = true
            -- Update the timestamp on the pinned entry to show recent access
            pinned_entry.timestamp = os.time()
            break
        end
    end

    -- Remove any existing entry with the same URL from history to avoid duplicates
    session_data.history = vim.tbl_filter(function(entry)
        return entry.url ~= url
    end, session_data.history)

    -- Only add to history if not pinned
    if not is_pinned then
        -- Add new entry at the beginning
        local entry = create_session_entry(url, entry_type, metadata)
        table.insert(session_data.history, 1, entry)

        -- Trim history to max size
        if #session_data.history > session_data.max_history then
            session_data.history = vim.list_slice(session_data.history, 1, session_data.max_history)
        end
    end

    -- Save to persistent storage
    save_session_data()

    utils.log("Added to session history: " .. url .. (is_pinned and " (updated pinned timestamp)" or ""), vim.log.levels.DEBUG, false, config.config)
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

-- Get formatted display text for a session entry with file icons
local function format_entry_display(entry, index, is_pinned)
    local pin_icon = is_pinned and "📌 " or "   "
    local time_str = os.date("%m/%d %H:%M", entry.timestamp)
    local host_str = entry.host and entry.host or ""

    -- Get appropriate file/directory icon and display path
    local file_icon, file_hl_group, display_path
    if entry.type == "tree_browser" then
        -- For tree browser sessions, always use folder icon
        file_icon, file_hl_group = get_file_icon("folder", true)  -- true = is_dir
        display_path = entry.display_name  -- Directory path
    else
        -- For files, use the actual filename to get proper file type icon
        file_icon, file_hl_group = get_file_icon(entry.display_name, false) -- false = is_file
        -- Show full path for files
        display_path = entry.metadata and entry.metadata.full_path or entry.display_name
    end

    -- Format: [PIN] [TIME] [HOST] [ICON] [PATH] [(pinned)]
    local display_text = string.format("%s%s %s %s %s%s",
        pin_icon, time_str, host_str, file_icon, display_path,
        is_pinned and " (pinned)" or "")

    return display_text, file_hl_group
end

-- Filter items based on filter text
local function filter_items()
    local all_items = {}
    local pinned_ids = {}

    -- First, add pinned items and track their IDs
    for _, entry in ipairs(session_data.pinned) do
        table.insert(all_items, entry)
        pinned_ids[entry.id] = true
    end

    -- Then add history items, but skip any that are already pinned
    for _, entry in ipairs(session_data.history) do
        if not pinned_ids[entry.id] then
            table.insert(all_items, entry)
        end
    end

    -- If no filter, return all items
    if SessionPicker.filter_text == "" then
        return all_items
    end

    -- Apply filter
    local filtered = {}
    local filter_lower = string.lower(SessionPicker.filter_text)

    for _, entry in ipairs(all_items) do
        if string.find(string.lower(entry.display_name), filter_lower) or
           string.find(string.lower(entry.host or ""), filter_lower) then
            table.insert(filtered, entry)
        end
    end

    return filtered
end

-- Calculate optimal window size based on current content
local function calculate_optimal_size()
    local items = filter_items()
    local max_width = 50  -- Smaller minimum width

    -- Use a compact header
    local title = "Remote SSH Sessions"
    local help = "<Enter>:Open <p>:Pin </>:Filter <q>:Quit"
    
    -- Measure actual content width needed
    max_width = math.max(max_width, #title + 8)  -- Title + border padding
    max_width = math.max(max_width, #help + 8)   -- Help + border padding

    -- Measure filter line
    local filter_line = "Filter: " .. SessionPicker.filter_text
    if SessionPicker.mode == "filter" then
        filter_line = filter_line .. "█"
    end
    max_width = math.max(max_width, #filter_line + 2)  -- Reduced padding

    -- Measure session entries (this is the main constraint)
    if #items > 0 then
        for i, entry in ipairs(items) do
            local is_pinned = vim.tbl_contains(vim.tbl_map(function(p) return p.id end, session_data.pinned), entry.id)
            local display_text, _ = format_entry_display(entry, i, is_pinned)
            local full_line = "▶ " .. display_text
            max_width = math.max(max_width, #full_line + 2)  -- Reduced padding
        end
    else
        max_width = math.max(max_width, #"  No sessions found" + 2)
    end

    -- Calculate height - more compact
    local content_height = 3 + 1 + math.max(1, #items) + 1  -- Compact header + filter + entries + minimal padding

    -- Apply constraints with smaller limits
    local final_width = math.min(max_width, vim.o.columns - 8)  -- More margin
    final_width = math.max(final_width, 45)  -- Smaller minimum

    local final_height = math.min(content_height, vim.o.lines - 8)  -- More margin
    final_height = math.max(final_height, 8)  -- Smaller minimum

    return final_width, final_height
end

-- Refresh the picker display
local function refresh_display()
    if not SessionPicker.bufnr or not vim.api.nvim_buf_is_valid(SessionPicker.bufnr) then
        return
    end

    -- Get filtered items
    SessionPicker.items = filter_items()

    -- Resize window if needed
    if SessionPicker.win_id and vim.api.nvim_win_is_valid(SessionPicker.win_id) then
        local new_width, new_height = calculate_optimal_size()
        local current_width = vim.api.nvim_win_get_width(SessionPicker.win_id)
        local current_height = vim.api.nvim_win_get_height(SessionPicker.win_id)

        -- Only resize if dimensions changed significantly
        if math.abs(new_width - current_width) > 5 or math.abs(new_height - current_height) > 2 then
            local row = math.floor((vim.o.lines - new_height) / 2)
            local col = math.floor((vim.o.columns - new_width) / 2)

            vim.api.nvim_win_set_config(SessionPicker.win_id, {
                relative = 'editor',
                width = new_width,
                height = new_height,
                row = row,
                col = col,
                style = 'minimal',
                border = 'rounded',
                title = ' Remote SSH Sessions ',
                title_pos = 'center'
            })
        end
    end

    local lines = {}
    local highlights = {}

    -- Header (dynamically sized)
    local function create_header(window_width)
        local content_width = window_width - 4 -- Account for borders and padding
        local title = " Remote SSH Session Picker "
        local line1_content = " Select a session to open or pin/unpin entries "
        local line2_content = " <Enter>:Open <p>:Pin/Unpin </>:Filter <q>:Quit "

        local top_line = "╭─" .. title .. string.rep("─", math.max(0, content_width - #title - 2)) .. "╮"
        local mid1_line = "│" .. line1_content .. string.rep(" ", math.max(0, content_width - #line1_content)) .. "│"
        local mid2_line = "│" .. line2_content .. string.rep(" ", math.max(0, content_width - #line2_content)) .. "│"
        local bottom_line = "╰" .. string.rep("─", content_width) .. "╯"

        return { top_line, mid1_line, mid2_line, bottom_line }
    end

    -- Get window width from buffer - we'll estimate based on max content
    local estimated_width = 60
    if SessionPicker.win_id and vim.api.nvim_win_is_valid(SessionPicker.win_id) then
        estimated_width = vim.api.nvim_win_get_width(SessionPicker.win_id)
    end

    local header_lines = create_header(estimated_width)
    for _, line in ipairs(header_lines) do
        table.insert(lines, line)
    end
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
            local display_text, file_hl_group = format_entry_display(entry, i, is_pinned)

            -- Add selection indicator
            local line_start_col = 0
            if i == SessionPicker.selected_idx then
                display_text = "▶ " .. display_text
                table.insert(highlights, {line = #lines, hl_group = "RemoteSessionSelected", col_start = 0, col_end = -1})
                line_start_col = 2
            else
                display_text = "  " .. display_text
                line_start_col = 2
            end

            table.insert(lines, display_text)
            local current_line = #lines - 1

            -- Calculate positions for different highlight elements
            -- Format: [PIN] [TIME] [HOST] [ICON] [PATH] [(pinned)]
            local pin_start = line_start_col
            local pin_end = pin_start + 3  -- "📌 " or "   "

            -- Find icon position (after time and host) - recalculate these values here
            local time_str = os.date("%m/%d %H:%M", entry.timestamp)
            local time_len = #time_str + 1  -- time + space
            local host_len = entry.host and (#entry.host + 1) or 0  -- host + space (no @ prefix)
            local icon_start = pin_end + time_len + host_len
            local icon_end = icon_start + 3  -- file icon + space (now has space after icon)

            -- Add specific highlights for different elements
            if is_pinned then
                -- Highlight pin icon
                table.insert(highlights, {line = current_line, hl_group = "RemoteSessionPinned", col_start = pin_start, col_end = pin_end})
            end

            -- Highlight file icon with appropriate color
            if file_hl_group then
                table.insert(highlights, {line = current_line, hl_group = file_hl_group, col_start = icon_start, col_end = icon_end})
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

    -- Check if already pinned by URL (more reliable than ID)
    for i, pinned_entry in ipairs(session_data.pinned) do
        if pinned_entry.url == entry.url then
            pinned_idx = i
            break
        end
    end

    if pinned_idx then
        -- Unpin: remove from pinned list and add back to history
        local unpinned_entry = table.remove(session_data.pinned, pinned_idx)

        -- Add back to history at the top (with current timestamp)
        unpinned_entry.timestamp = os.time()
        table.insert(session_data.history, 1, unpinned_entry)

        utils.log("Unpinned: " .. entry.display_name, vim.log.levels.INFO, true, config.config)
    else
        -- Pin: remove from history and add to pinned list
        local pinned_entry = vim.deepcopy(entry)
        table.insert(session_data.pinned, pinned_entry)

        -- Remove from history
        session_data.history = vim.tbl_filter(function(hist_entry)
            return hist_entry.url ~= entry.url
        end, session_data.history)

        utils.log("Pinned: " .. entry.display_name, vim.log.levels.INFO, true, config.config)
    end

    -- Save to persistent storage
    save_session_data()

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

    -- Navigation (these should always work)
    vim.keymap.set('n', 'j', function()
        if SessionPicker.mode ~= "filter" then
            navigate(1)
        end
    end, opts)
    vim.keymap.set('n', 'k', function()
        if SessionPicker.mode ~= "filter" then
            navigate(-1)
        end
    end, opts)
    vim.keymap.set('n', '<Down>', function() navigate(1) end, opts)
    vim.keymap.set('n', '<Up>', function() navigate(-1) end, opts)

    -- Selection
    vim.keymap.set('n', '<CR>', open_selected, opts)
    vim.keymap.set('n', '<Space>', open_selected, opts)

    -- Pin/Unpin (should always work)
    vim.keymap.set('n', 'p', function()
        if SessionPicker.mode ~= "filter" then
            toggle_pin()
        else
            handle_filter_input('p')
        end
    end, opts)

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
        SessionPicker.mode = "normal"
        refresh_display()
    end, opts)

    -- Close picker (should always work)
    vim.keymap.set('n', 'q', function()
        if SessionPicker.mode ~= "filter" then
            M.close_picker()
        else
            handle_filter_input('q')
        end
    end, opts)
    vim.keymap.set('n', '<C-q>', M.close_picker, opts)

    -- Filter input handling - only create keymaps for filter mode
    local function handle_char_input(char)
        return function()
            if SessionPicker.mode == "filter" then
                handle_filter_input(char)
            end
        end
    end

    -- Create keymaps for all alphanumeric and special characters
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:/ \\"
    for i = 1, #chars do
        local char = chars:sub(i, i)
        -- Don't override existing important keys when not in filter mode
        if not vim.tbl_contains({'j', 'k', 'p', 'q', '/'}, char) then
            vim.keymap.set('n', char, handle_char_input(char), opts)
        end
    end

    -- Special handling for letters that have other functions
    vim.keymap.set('n', 'j', function()
        if SessionPicker.mode == "filter" then
            handle_filter_input('j')
        else
            navigate(1)
        end
    end, opts)

    vim.keymap.set('n', 'k', function()
        if SessionPicker.mode == "filter" then
            handle_filter_input('k')
        else
            navigate(-1)
        end
    end, opts)

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

    -- Setup highlight groups
    setup_highlight_groups()

    -- Create buffer
    SessionPicker.bufnr = vim.api.nvim_create_buf(false, true)

    -- Setup buffer options
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'swapfile', false)
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(SessionPicker.bufnr, 'filetype', 'remote-session-picker')
    vim.api.nvim_buf_set_name(SessionPicker.bufnr, 'Remote SSH Session Picker')

    -- Calculate initial window size
    local width, height = calculate_optimal_size()
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
    save_session_data()
    utils.log("Cleared session history", vim.log.levels.INFO, true, config.config)
end

-- Clear pinned sessions
function M.clear_pinned()
    session_data.pinned = {}
    save_session_data()
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
        save_session_data()
        utils.log("Set max history size to " .. max, vim.log.levels.DEBUG, false, config.config)
    end
end

-- Setup auto-save on Neovim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        save_session_data()
    end,
    group = vim.api.nvim_create_augroup("RemoteSessionPickerSave", { clear = true }),
    desc = "Save remote session data on Neovim exit"
})

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
