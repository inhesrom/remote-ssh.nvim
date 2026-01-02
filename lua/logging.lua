local M = {}

-- Ring buffer configuration
M.buffer_config = {
    max_entries = 1000,
    include_context = true,
}

-- Log storage (ring buffer)
local log_buffer = {}
local log_buffer_index = 1
local log_count = 0

-- Log viewer state
local viewer_state = {
    bufnr = nil,
    win_id = nil,
    filter_level = nil, -- nil = show all
    auto_scroll = true,
}

-- Convert log level to string
local function level_to_string(level)
    if level == vim.log.levels.DEBUG then
        return "DEBUG"
    elseif level == vim.log.levels.INFO then
        return "INFO"
    elseif level == vim.log.levels.WARN then
        return "WARN"
    elseif level == vim.log.levels.ERROR then
        return "ERROR"
    else
        return "UNKNOWN"
    end
end

-- Convert string to log level
local function string_to_level(str)
    str = string.upper(str)
    if str == "DEBUG" then
        return vim.log.levels.DEBUG
    elseif str == "INFO" then
        return vim.log.levels.INFO
    elseif str == "WARN" then
        return vim.log.levels.WARN
    elseif str == "ERROR" then
        return vim.log.levels.ERROR
    else
        return nil
    end
end

-- Store log entry in ring buffer
local function store_log_entry(entry)
    log_buffer[log_buffer_index] = entry
    log_buffer_index = (log_buffer_index % M.buffer_config.max_entries) + 1
    log_count = math.min(log_count + 1, M.buffer_config.max_entries)
end

-- Get log entries with optional filtering
function M.get_log_entries(filter_opts)
    filter_opts = filter_opts or {}
    local entries = {}

    -- Calculate the starting index for reading the ring buffer
    local start_idx
    if log_count < M.buffer_config.max_entries then
        start_idx = 1
    else
        start_idx = log_buffer_index
    end

    -- Read entries in chronological order
    for i = 0, log_count - 1 do
        local idx = ((start_idx + i - 1) % M.buffer_config.max_entries) + 1
        local entry = log_buffer[idx]

        if entry then
            -- Apply level filter if specified
            if not filter_opts.min_level or entry.level >= filter_opts.min_level then
                table.insert(entries, entry)
            end
        end
    end

    return entries
end

-- Clear all log entries
function M.clear_logs()
    log_buffer = {}
    log_buffer_index = 1
    log_count = 0
end

-- Get log statistics
function M.get_log_stats()
    local stats = {
        total = 0,
        error = 0,
        warn = 0,
        info = 0,
        debug = 0,
    }

    local entries = M.get_log_entries()
    stats.total = #entries

    for _, entry in ipairs(entries) do
        if entry.level == vim.log.levels.ERROR then
            stats.error = stats.error + 1
        elseif entry.level == vim.log.levels.WARN then
            stats.warn = stats.warn + 1
        elseif entry.level == vim.log.levels.INFO then
            stats.info = stats.info + 1
        elseif entry.level == vim.log.levels.DEBUG then
            stats.debug = stats.debug + 1
        end
    end

    return stats
end

-- Format log entry for display
local function format_log_entry(entry)
    local lines = {}

    -- Format timestamp
    local timestamp = os.date("%Y-%m-%d %H:%M:%S", entry.timestamp)

    -- Format module
    local module_str = entry.module and ("[" .. entry.module .. "]") or ""

    -- Main log line - ensure no newlines in the message
    local clean_message = tostring(entry.message):gsub("\n", " ")
    local main_line = string.format("[%s] [%-5s] %s %s", timestamp, entry.level_name, module_str, clean_message)
    table.insert(lines, main_line)

    -- Add context if available and enabled
    if M.buffer_config.include_context and entry.context then
        for key, value in pairs(entry.context) do
            if type(value) == "table" then
                -- Use vim.inspect but replace newlines to keep it on one line
                value = vim.inspect(value):gsub("\n", " ")
            end
            -- Ensure the entire line has no newlines
            local context_line = "  └─ " .. tostring(key) .. "=" .. tostring(value)
            context_line = context_line:gsub("\n", " ")
            table.insert(lines, context_line)
        end
    end

    return lines
end

-- Set up syntax highlighting for log viewer
local function setup_syntax_highlighting(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd([[syntax clear]])

        -- Highlight log levels
        vim.cmd([[syntax match LogError /\[ERROR\]/]])
        vim.cmd([[syntax match LogWarn /\[WARN \]/]])
        vim.cmd([[syntax match LogInfo /\[INFO \]/]])
        vim.cmd([[syntax match LogDebug /\[DEBUG\]/]])

        -- Highlight timestamps
        vim.cmd([[syntax match LogTimestamp /\[\d\{4}-\d\{2}-\d\{2} \d\{2}:\d\{2}:\d\{2}\]/]])

        -- Highlight modules
        vim.cmd([[syntax match LogModule /\[\w\+\]/]])

        -- Highlight context lines
        vim.cmd([[syntax match LogContext /^\s*└─.*/]])

        -- Set highlight colors
        vim.cmd([[highlight LogError guifg=#ff6b6b ctermfg=Red]])
        vim.cmd([[highlight LogWarn guifg=#ffd93d ctermfg=Yellow]])
        vim.cmd([[highlight LogInfo guifg=#6bceff ctermfg=Blue]])
        vim.cmd([[highlight LogDebug guifg=#888888 ctermfg=Gray]])
        vim.cmd([[highlight LogTimestamp guifg=#98c379 ctermfg=Green]])
        vim.cmd([[highlight LogModule guifg=#c678dd ctermfg=Magenta]])
        vim.cmd([[highlight LogContext guifg=#666666 ctermfg=DarkGray]])
    end)
end

-- Refresh log viewer buffer
local function refresh_log_viewer()
    if not viewer_state.bufnr or not vim.api.nvim_buf_is_valid(viewer_state.bufnr) then
        return
    end

    -- Get filtered entries
    local filter_opts = {}
    if viewer_state.filter_level then
        filter_opts.min_level = viewer_state.filter_level
    end
    local entries = M.get_log_entries(filter_opts)

    -- Format all entries
    local lines = {}

    -- Add header
    local stats = M.get_log_stats()
    local filter_str = viewer_state.filter_level and (" [Filter: " .. level_to_string(viewer_state.filter_level) .. "]") or ""
    table.insert(
        lines,
        string.format(
            "Remote SSH Plugin - Log Viewer%s                    [ERROR: %d | WARN: %d | INFO: %d | DEBUG: %d]",
            filter_str,
            stats.error,
            stats.warn,
            stats.info,
            stats.debug
        )
    )
    table.insert(lines, string.rep("─", 120))
    table.insert(lines, "")

    -- Add log entries
    for _, entry in ipairs(entries) do
        local formatted_lines = format_log_entry(entry)
        for _, line in ipairs(formatted_lines) do
            table.insert(lines, line)
        end
        table.insert(lines, "") -- Blank line between entries
    end

    -- Add footer
    table.insert(lines, "")
    table.insert(lines, string.rep("─", 120))
    local footer = string.format(
        "Keybindings: [r]efresh [C]lear [1]ERROR [2]WARN [3]INFO [4]DEBUG [0]ALL [g]auto-scroll [q]uit [?]help"
    )
    table.insert(lines, footer)
    table.insert(
        lines,
        string.format(
            "Total entries: %d | Showing: %d | Auto-scroll: %s",
            stats.total,
            #entries,
            viewer_state.auto_scroll and "ON" or "OFF"
        )
    )

    -- Update buffer
    vim.api.nvim_buf_set_option(viewer_state.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(viewer_state.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(viewer_state.bufnr, "modifiable", false)

    -- Auto-scroll to bottom if enabled
    if viewer_state.auto_scroll and viewer_state.win_id and vim.api.nvim_win_is_valid(viewer_state.win_id) then
        vim.api.nvim_win_set_cursor(viewer_state.win_id, { #lines, 0 })
    end
end

-- Close log viewer
function M.close_log_viewer()
    if viewer_state.win_id and vim.api.nvim_win_is_valid(viewer_state.win_id) then
        vim.api.nvim_win_close(viewer_state.win_id, true)
    end
    viewer_state.win_id = nil
    viewer_state.bufnr = nil
end

-- Set filter level
local function set_filter_level(level)
    viewer_state.filter_level = level
    refresh_log_viewer()
end

-- Toggle auto-scroll
local function toggle_auto_scroll()
    viewer_state.auto_scroll = not viewer_state.auto_scroll
    refresh_log_viewer()
end

-- Show help
local function show_help()
    local help_lines = {
        "Remote SSH Log Viewer - Help",
        "",
        "Keybindings:",
        "  q     - Close log viewer",
        "  r     - Refresh log viewer",
        "  C     - Clear all logs",
        "  1     - Show ERROR only",
        "  2     - Show WARN and above",
        "  3     - Show INFO and above",
        "  4     - Show all (DEBUG and above)",
        "  0     - Clear filter (show all)",
        "  g     - Toggle auto-scroll",
        "  ?     - Show this help",
        "",
        "Commands:",
        "  :RemoteSSHLog              - Open log viewer",
        "  :RemoteSSHLogClear         - Clear all logs",
        "  :RemoteSSHLogFilter <level> - Filter by level",
        "",
        "Press any key to close this help...",
    }

    vim.api.nvim_echo({ { table.concat(help_lines, "\n"), "Normal" } }, true, {})
end

-- Set up keybindings for log viewer
local function setup_keybindings(bufnr)
    local opts = { noremap = true, silent = true, buffer = bufnr }

    vim.keymap.set("n", "q", M.close_log_viewer, opts)
    vim.keymap.set("n", "r", refresh_log_viewer, opts)
    vim.keymap.set("n", "C", function()
        M.clear_logs()
        refresh_log_viewer()
    end, opts)
    vim.keymap.set("n", "1", function()
        set_filter_level(vim.log.levels.ERROR)
    end, opts)
    vim.keymap.set("n", "2", function()
        set_filter_level(vim.log.levels.WARN)
    end, opts)
    vim.keymap.set("n", "3", function()
        set_filter_level(vim.log.levels.INFO)
    end, opts)
    vim.keymap.set("n", "4", function()
        set_filter_level(vim.log.levels.DEBUG)
    end, opts)
    vim.keymap.set("n", "0", function()
        set_filter_level(nil)
    end, opts)
    vim.keymap.set("n", "g", toggle_auto_scroll, opts)
    vim.keymap.set("n", "?", show_help, opts)
end

-- Open log viewer
function M.open_log_viewer(opts)
    opts = opts or {}
    local height = opts.height or 15

    -- If viewer is already open, just focus it
    if viewer_state.win_id and vim.api.nvim_win_is_valid(viewer_state.win_id) then
        vim.api.nvim_set_current_win(viewer_state.win_id)
        refresh_log_viewer()
        return
    end

    -- Create or reuse buffer
    if not viewer_state.bufnr or not vim.api.nvim_buf_is_valid(viewer_state.bufnr) then
        viewer_state.bufnr = vim.api.nvim_create_buf(false, true)

        -- Set buffer options
        vim.api.nvim_buf_set_option(viewer_state.bufnr, "buftype", "nofile")
        vim.api.nvim_buf_set_option(viewer_state.bufnr, "bufhidden", "hide")
        vim.api.nvim_buf_set_option(viewer_state.bufnr, "swapfile", false)
        vim.api.nvim_buf_set_option(viewer_state.bufnr, "filetype", "remote-ssh-log")
        vim.api.nvim_buf_set_name(viewer_state.bufnr, "Remote SSH Log")

        -- Set up syntax highlighting
        setup_syntax_highlighting(viewer_state.bufnr)

        -- Set up keybindings
        setup_keybindings(viewer_state.bufnr)
    end

    -- Create horizontal split at bottom
    vim.cmd("botright " .. height .. "split")
    viewer_state.win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(viewer_state.win_id, viewer_state.bufnr)

    -- Set window options
    vim.api.nvim_win_set_option(viewer_state.win_id, "number", true)
    vim.api.nvim_win_set_option(viewer_state.win_id, "wrap", false)

    -- Populate buffer
    refresh_log_viewer()
end

-- Filter logs by level (command function)
function M.filter_by_level(level_str)
    local level = string_to_level(level_str)
    if not level then
        vim.notify("Invalid log level: " .. level_str .. ". Use ERROR, WARN, INFO, or DEBUG", vim.log.levels.ERROR)
        return
    end

    viewer_state.filter_level = level

    -- Refresh if viewer is open
    if viewer_state.bufnr and vim.api.nvim_buf_is_valid(viewer_state.bufnr) then
        refresh_log_viewer()
    end
end

-- Consolidated logging function (enhanced)
function M.log(msg, level, notify_user, config, context)
    level = level or vim.log.levels.DEBUG
    notify_user = notify_user or false
    config = config
        or {
            timeout = 30,
            log_level = vim.log.levels.INFO,
            debug = false,
            check_interval = 1000,
        }

    -- Store in buffer
    store_log_entry({
        timestamp = os.time(),
        level = level,
        level_name = level_to_string(level),
        message = msg,
        module = context and context.module,
        context = context,
    })

    -- Determine if we should show a notification
    -- Respect notify_user as ultimate override to prevent spam from background operations
    local should_notify = false

    if notify_user == true then
        -- User explicitly requested notification for this message
        should_notify = true
    elseif notify_user == false then
        -- User explicitly requested NO notification (e.g., background warming)
        should_notify = false
    else
        -- notify_user is nil - use default behavior based on log level
        if level >= vim.log.levels.WARN then
            -- Show WARN and ERROR as notifications by default
            should_notify = true
        end
    end

    -- Show notification if needed AND message meets log level threshold
    if should_notify and level >= config.log_level then
        vim.schedule(function()
            local prefix = notify_user and "" or "[AsyncWrite] "
            vim.notify(prefix .. msg, level)

            -- Update the status line if this is a user notification
            if notify_user and vim.o.laststatus >= 2 then
                pcall(function()
                    vim.cmd("redrawstatus")
                end)
            end
        end)
    end

    -- Refresh log viewer if open
    if viewer_state.bufnr and vim.api.nvim_buf_is_valid(viewer_state.bufnr) then
        vim.schedule(function()
            refresh_log_viewer()
        end)
    end
end

return M
