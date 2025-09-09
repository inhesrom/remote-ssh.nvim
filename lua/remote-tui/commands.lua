local M = {}

local log = require("logging").log
local utils = require("async-remote-write.utils")
local metadata = require("remote-buffer-metadata")
local build_ssh_cmd = require("async-remote-write.ssh_utils").build_ssh_cmd

M.config = {
    window = {
        type = "float", -- "float" or "split"
        width = 0.9, -- percentage of screen width (for float)
        height = 0.9, -- percentage of screen height (for float)
        border = "rounded", -- border style for floating windows
    },
}

-- TUI Session Management State
local TuiSessions = {
    active = {}, -- Currently visible sessions: {session_id: {buf, win, metadata}}
    hidden = {}, -- Hidden sessions: {session_id: {buf, config, metadata}}
    next_id = 1, -- Auto-incrementing session ID
}

-- Session metadata structure
local function create_session_metadata(app_name, host_string, directory_path, connection_info)
    return {
        id = TuiSessions.next_id,
        app_name = app_name,
        host_string = host_string,
        directory_path = directory_path,
        connection_info = connection_info, -- {user, host, port}
        created_at = os.time(),
        display_name = app_name .. " @ " .. (connection_info and connection_info.host or "unknown"),
    }
end

-- Hide the current TUI session (Ctrl+H functionality)
local function hide_current_session()
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)

    -- Find the session associated with this window
    local session_id = nil
    for id, session in pairs(TuiSessions.active) do
        if session.win == current_win and session.buf == current_buf then
            session_id = id
            break
        end
    end

    if not session_id then
        vim.notify("No active TUI session found in current window", vim.log.levels.WARN)
        return
    end

    local session = TuiSessions.active[session_id]

    -- Store window configuration before hiding
    local win_config = vim.api.nvim_win_get_config(current_win)

    -- Hide the window
    if vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_win_hide(current_win)
    end

    -- Move session from active to hidden
    TuiSessions.hidden[session_id] = {
        buf = session.buf,
        config = win_config,
        metadata = session.metadata,
    }

    TuiSessions.active[session_id] = nil

    log("Hidden TUI session: " .. session.metadata.display_name, vim.log.levels.INFO, true)
end

-- Restore a hidden session
local function restore_session(session_id)
    local session = TuiSessions.hidden[session_id]
    if not session then
        vim.notify("Session not found", vim.log.levels.ERROR)
        return
    end

    -- Check if buffer is still valid
    if not vim.api.nvim_buf_is_valid(session.buf) then
        vim.notify("Session buffer is no longer valid", vim.log.levels.ERROR)
        TuiSessions.hidden[session_id] = nil
        return
    end

    -- Recreate the floating window
    local win = vim.api.nvim_open_win(session.buf, true, session.config)

    -- Setup Ctrl+H keymap for the restored window
    vim.keymap.set("t", "<C-h>", hide_current_session, { buffer = session.buf, noremap = true, silent = true })

    -- Move session from hidden to active
    TuiSessions.active[session_id] = {
        buf = session.buf,
        win = win,
        metadata = session.metadata,
    }

    TuiSessions.hidden[session_id] = nil

    -- Enter terminal mode
    vim.cmd("startinsert")

    log("Restored TUI session: " .. session.metadata.display_name, vim.log.levels.INFO, true)
end

-- Delete a session (removes buffer and cleans up state)
local function delete_session(session_id, force)
    local session = TuiSessions.hidden[session_id] or TuiSessions.active[session_id]
    if not session then
        vim.notify("Session not found", vim.log.levels.ERROR)
        return false
    end

    if not force then
        return false -- Caller should handle confirmation
    end

    -- Force delete the buffer
    if vim.api.nvim_buf_is_valid(session.buf) then
        vim.api.nvim_buf_delete(session.buf, { force = true })
    end

    -- Clean up session state
    TuiSessions.hidden[session_id] = nil
    TuiSessions.active[session_id] = nil

    log("Deleted TUI session: " .. session.metadata.display_name, vim.log.levels.INFO, true)
    return true
end

local ssh_wrap = function(host, tui_appname, directory_path)
    local cmd = "-t " -- interactive terminal session
        .. '"' -- quote the command being built
        .. "cd "
        .. directory_path -- cd into the dir before calling the command
        .. " && "
        .. " bash --login -c "
        .. "'"
        .. tui_appname -- TUI app to start
        .. "'"
        .. '"' -- end quote
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

-- Create a new TUI session with proper tracking
local function create_tui_session(app_name, host_string, directory_path, connection_info)
    local ssh_command = ssh_wrap(host_string, app_name, directory_path)
    ssh_command = table.concat(ssh_command, " ")
    log(ssh_command, vim.log.levels.WARN, true)

    local buf, win = create_floating_window(M.config)
    vim.bo[buf].bufhidden = "" -- Don't auto-wipe, we manage session lifecycle

    -- Create session metadata
    local session_metadata = create_session_metadata(app_name, host_string, directory_path, connection_info)
    local session_id = TuiSessions.next_id
    TuiSessions.next_id = TuiSessions.next_id + 1

    -- Setup Ctrl+H keymap for hiding
    vim.keymap.set("t", "<C-h>", hide_current_session, { buffer = buf, noremap = true, silent = true })

    local job_id = vim.fn.termopen(ssh_command, {
        on_exit = function(job_id, exit_code, event_type)
            -- Remove from active sessions when terminal exits
            if TuiSessions.active[session_id] then
                log("TUI session exited: " .. session_metadata.display_name, vim.log.levels.INFO, true)
                TuiSessions.active[session_id] = nil
            end

            -- Close window if still valid
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, false)
            end
        end,
    })

    if job_id <= 0 then
        vim.notify("Failed to start terminal", vim.log.levels.ERROR)
        TuiSessions.next_id = TuiSessions.next_id - 1 -- Revert ID increment
        return
    end

    -- Register the active session
    TuiSessions.active[session_id] = {
        buf = buf,
        win = win,
        metadata = session_metadata,
    }

    log("Created TUI session: " .. session_metadata.display_name, vim.log.levels.INFO, true)
    vim.cmd("startinsert")
end

-- Prompt user for remote connection info when buffer metadata is unavailable
local function prompt_for_connection_info(callback)
    vim.ui.input({
        prompt = "Enter user@host[:port] (e.g., ubuntu@myserver.com:22): ",
        default = "",
    }, function(input)
        if not input or input:match("^%s*$") then
            vim.notify("No connection info provided", vim.log.levels.WARN)
            return
        end

        -- Parse the input: user@host[:port]
        local user, host, port
        local user_host_port = input:match("^([^@]+)@([^:]+):?(%d*)$")
        if user_host_port then
            user, host, port = input:match("^([^@]+)@([^:]+):?(%d*)$")
            port = port ~= "" and tonumber(port) or nil
        else
            vim.notify("Invalid format. Use: user@host[:port]", vim.log.levels.ERROR)
            return
        end

        vim.ui.input({
            prompt = "Enter remote directory path (default: ~): ",
            default = "~",
        }, function(directory)
            if not directory or directory:match("^%s*$") then
                directory = "~"
            end

            callback({
                user = user,
                host = host,
                port = port,
                path = directory,
            })
        end)
    end)
end

-- TUI Session Picker
local TuiPicker = {
    bufnr = nil,
    win_id = nil,
    sessions = {}, -- List of hidden sessions
    selected_idx = 1,
    mode = "normal", -- 'normal' or 'confirm_delete'
    delete_session_id = nil,
}

-- Setup highlight groups for the TUI session picker
local function setup_tui_picker_highlights()
    local highlights = {
        -- Header and UI elements
        TuiPickerHeader = { fg = "#61afef", bold = true }, -- Blue header
        TuiPickerHelp = { fg = "#98c379" }, -- Green help text
        TuiPickerWarning = { fg = "#e06c75", bold = true }, -- Red warning
        TuiPickerBorder = { fg = "#5c6370" }, -- Gray border
        
        -- Session entries
        TuiPickerSelected = { bg = "#3e4451", fg = "#abb2bf" }, -- Highlighted selection
        TuiPickerTimeStamp = { fg = "#d19a66" }, -- Orange timestamp
        TuiPickerAppName = { fg = "#e5c07b", bold = true }, -- Yellow app name
        TuiPickerHost = { fg = "#56b6c2" }, -- Cyan host
        TuiPickerSelector = { fg = "#c678dd", bold = true }, -- Purple selector arrow
        
        -- Special states
        TuiPickerEmpty = { fg = "#5c6370", italic = true }, -- Gray empty state
    }
    
    -- Set highlight groups
    for hl_name, hl_def in pairs(highlights) do
        vim.api.nvim_set_hl(0, hl_name, hl_def)
    end
end

-- Create TUI session picker UI
local function create_tui_picker()
    if next(TuiSessions.hidden) == nil then
        vim.notify("No hidden TUI sessions found", vim.log.levels.WARN)
        return
    end

    -- Setup highlight groups
    setup_tui_picker_highlights()

    -- Close existing picker if open
    if TuiPicker.bufnr and vim.api.nvim_buf_is_valid(TuiPicker.bufnr) then
        close_tui_picker()
    end

    -- Create buffer
    TuiPicker.bufnr = vim.api.nvim_create_buf(false, true)

    -- Setup buffer options
    vim.api.nvim_buf_set_option(TuiPicker.bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(TuiPicker.bufnr, "swapfile", false)
    vim.api.nvim_buf_set_option(TuiPicker.bufnr, "modifiable", false)
    vim.api.nvim_buf_set_option(TuiPicker.bufnr, "filetype", "tui-session-picker")
    vim.api.nvim_buf_set_name(TuiPicker.bufnr, "TUI Sessions")

    -- Calculate window size
    local width = math.floor(vim.o.columns * 0.6)
    local height = math.floor(vim.o.lines * 0.6)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create floating window
    TuiPicker.win_id = vim.api.nvim_open_win(TuiPicker.bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Hidden TUI Sessions ",
        title_pos = "center",
    })

    -- Setup window options
    vim.api.nvim_win_set_option(TuiPicker.win_id, "wrap", false)
    vim.api.nvim_win_set_option(TuiPicker.win_id, "cursorline", false)

    -- Reset state
    TuiPicker.selected_idx = 1
    TuiPicker.mode = "normal"
    TuiPicker.delete_session_id = nil

    -- Build sessions list
    TuiPicker.sessions = {}
    for session_id, session in pairs(TuiSessions.hidden) do
        table.insert(TuiPicker.sessions, {
            id = session_id,
            metadata = session.metadata,
        })
    end

    -- Sort by creation time (newest first)
    table.sort(TuiPicker.sessions, function(a, b)
        return a.metadata.created_at > b.metadata.created_at
    end)

    setup_tui_picker_keymaps()
    refresh_tui_picker_display()
end

-- Refresh the picker display
function refresh_tui_picker_display()
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
            
            local display_line = string.format("%s[%s] %s @ %s", prefix, time_str, app_name, host)
            table.insert(lines, display_line)
            
            -- Highlight entire line if selected
            if i == TuiPicker.selected_idx then
                table.insert(highlights, { line = current_line, hl_group = "TuiPickerSelected", col_start = 0, col_end = -1 })
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
            table.insert(highlights, { line = current_line, hl_group = "TuiPickerTimeStamp", col_start = timestamp_start, col_end = timestamp_end })
            
            -- Highlight app name
            local app_start = timestamp_end + 1 -- space after timestamp
            local app_end = app_start + #app_name
            table.insert(highlights, { line = current_line, hl_group = "TuiPickerAppName", col_start = app_start, col_end = app_end })
            
            -- Highlight host (after " @ ")
            local host_start = app_end + 3 -- " @ "
            local host_end = host_start + #host
            table.insert(highlights, { line = current_line, hl_group = "TuiPickerHost", col_start = host_start, col_end = host_end })
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
    if #TuiPicker.sessions == 0 then return end

    TuiPicker.selected_idx = TuiPicker.selected_idx + direction

    if TuiPicker.selected_idx < 1 then
        TuiPicker.selected_idx = #TuiPicker.sessions
    elseif TuiPicker.selected_idx > #TuiPicker.sessions then
        TuiPicker.selected_idx = 1
    end

    refresh_tui_picker_display()
end

-- Handle session selection
local function select_session()
    if #TuiPicker.sessions == 0 or not TuiPicker.sessions[TuiPicker.selected_idx] then
        return
    end

    local session = TuiPicker.sessions[TuiPicker.selected_idx]
    close_tui_picker()
    restore_session(session.id)
end

-- Handle delete request
local function request_delete_session()
    if #TuiPicker.sessions == 0 or not TuiPicker.sessions[TuiPicker.selected_idx] then
        return
    end

    local session = TuiPicker.sessions[TuiPicker.selected_idx]
    TuiPicker.mode = "confirm_delete"
    TuiPicker.delete_session_id = session.id
    refresh_tui_picker_display()
end

-- Confirm deletion
local function confirm_delete(confirm)
    if TuiPicker.mode ~= "confirm_delete" or not TuiPicker.delete_session_id then
        return
    end

    if confirm then
        delete_session(TuiPicker.delete_session_id, true)
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
        close_tui_picker()
        vim.notify("No more hidden sessions", vim.log.levels.INFO)
        return
    end

    refresh_tui_picker_display()
end

-- Close picker
function close_tui_picker()
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
function setup_tui_picker_keymaps()
    local opts = { noremap = true, silent = true, buffer = TuiPicker.bufnr }

    -- Navigation
    vim.keymap.set("n", "j", function() navigate_picker(1) end, opts)
    vim.keymap.set("n", "k", function() navigate_picker(-1) end, opts)
    vim.keymap.set("n", "<Down>", function() navigate_picker(1) end, opts)
    vim.keymap.set("n", "<Up>", function() navigate_picker(-1) end, opts)

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
    vim.keymap.set("n", "q", close_tui_picker, opts)
    vim.keymap.set("n", "<Esc>", close_tui_picker, opts)
end

function M.register()
    vim.api.nvim_create_user_command("RemoteTui", function(opts)
        log("Ran Remote TUI Command...", vim.log.levels.DEBUG, true)
        args = opts.args
        log("args: " .. args, vim.log.levels.DEBUG, true)

        -- Check if no arguments provided - open picker mode
        if not args or args:match("^%s*$") then
            log("No arguments provided, opening TUI session picker", vim.log.levels.INFO, true)
            create_tui_picker()
            return
        end

        local bufnr = vim.api.nvim_get_current_buf()

        local buf_info = utils.get_remote_file_info(bufnr)

        if not buf_info then
            log("No buffer metadata found, prompting user for connection info", vim.log.levels.INFO, true)
            prompt_for_connection_info(function(manual_info)
                local directory_path = manual_info.path
                local host_string = manual_info.user .. "@" .. manual_info.host
                create_tui_session(args, host_string, directory_path, manual_info)
            end)
            return
        end

        -- Use buffer metadata when available
        local directory_path = vim.fn.fnamemodify(buf_info.path, ":h")
        local host_string = buf_info.user and (buf_info.user .. "@" .. buf_info.host) or buf_info.host

        -- Create connection info from buffer metadata
        local connection_info = {
            user = buf_info.user,
            host = buf_info.host,
            port = buf_info.port,
        }

        create_tui_session(args, host_string, directory_path, connection_info)
    end, {
        nargs = "?",
        desc = "Open a remote TUI app (with args) or show TUI session picker (no args)",
    })
end

return M
