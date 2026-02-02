-- Session lifecycle module for remote-session
-- Handles create, open, minimize, restore, close operations
local M = {}

local config = require("remote-session.config")
local session_manager = require("remote-session.session_manager")
local naming = require("remote-session.naming")
local window_layout = require("remote-session.window_layout")
local persistence = require("remote-session.persistence")

--- Normalize a URL input to full rsync:// format
---@param input string User input URL
---@return string normalized_url
function M.normalize_url(input)
    if not input or input == "" then
        return ""
    end

    -- If already has protocol, use as-is
    if input:match("^rsync://") or input:match("^scp://") then
        return input
    end

    -- Otherwise, prepend rsync://
    return "rsync://" .. input
end

--- Parse URL to extract host and path
---@param url string Normalized URL
---@return table|nil parsed {host, path, user, port}
function M.parse_url(url)
    local ok, utils = pcall(require, "async-remote-write.utils")
    if not ok then
        return nil
    end

    return utils.parse_remote_path(url)
end

--- Create a new session
---@param url string Remote URL (will be normalized)
---@param opts table|nil Options {name, open_terminal}
---@return table|nil session The created session
function M.create(url, opts)
    opts = opts or {}

    -- Normalize URL
    url = M.normalize_url(url)
    if url == "" then
        vim.notify("[remote-session] Invalid URL", vim.log.levels.ERROR)
        return nil
    end

    -- Parse URL
    local parsed = M.parse_url(url)
    if not parsed then
        vim.notify("[remote-session] Failed to parse URL: " .. url, vim.log.levels.ERROR)
        return nil
    end

    -- Check if session for this URL already exists
    local existing = session_manager.find_by_url(url)
    if existing then
        -- Offer to switch to existing session
        local choice = vim.fn.confirm(
            "Session for this URL already exists: " .. existing.name .. "\nSwitch to existing session?",
            "&Yes\n&No, create new",
            1
        )
        if choice == 1 then
            M.restore(existing.id)
            return existing
        end
    end

    -- Generate name
    local name = opts.name or naming.generate_unique_name(parsed.host, parsed.path)

    -- Create session object
    local session = {
        name = name,
        url = url,
        host = parsed.host,
        path = parsed.path,
        state = "active",
        created_at = os.time(),
        last_accessed_at = os.time(),
        window_layout = window_layout.get_default_layout(),
        tree_browser_state = nil,
        terminal_ids = {},
        open_buffers = {},
    }

    -- Minimize current active session if configured
    local current_active = session_manager.get_active_session()
    if current_active and config.get("auto_minimize") then
        M.minimize(current_active.id)
    end

    -- Register the session
    local session_id = session_manager.register_session(session)
    session_manager.set_active(session_id)

    -- Open tree browser
    local ok_tree, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if ok_tree then
        tree_browser.open_tree(url)
    end

    -- Create terminal if configured
    local open_terminal = opts.open_terminal
    if open_terminal == nil then
        open_terminal = config.get("terminal", "auto_create")
    end

    if open_terminal then
        M.create_terminal_for_session(session_id)
    end

    vim.notify("[remote-session] Created session: " .. name, vim.log.levels.INFO)

    return session
end

--- Create a terminal for a session
---@param session_id string
---@return number|nil terminal_id
function M.create_terminal_for_session(session_id)
    local session = session_manager.get_session(session_id)
    if not session then
        return nil
    end

    local ok, terminal_session = pcall(require, "remote-terminal.terminal_session")
    if not ok then
        return nil
    end

    -- Build connection info from session
    local user, host = nil, session.host
    local user_host = session.host:match("^([^@]+)@(.+)$")
    if user_host then
        user, host = session.host:match("^([^@]+)@(.+)$")
    end

    local connection_info = {
        user = user,
        host = host,
        port = nil,
        path = session.path,
    }

    -- Create terminal
    local terminal = terminal_session.create_session(connection_info, function(new_session)
        if new_session then
            -- Associate terminal with session
            session_manager.add_terminal(session_id, new_session.id)

            -- Also register in terminal_manager
            local ok_tm, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
            if ok_tm and terminal_manager.associate_terminal_with_session then
                terminal_manager.associate_terminal_with_session(new_session.id, session_id)
            end

            -- Show the terminal split window
            local ok_wm, window_manager = pcall(require, "remote-terminal.window_manager")
            if ok_wm then
                if not terminal_manager.is_split_visible() or not window_manager.is_layout_valid() then
                    window_manager.create_split(new_session.bufnr)
                    -- Initialize picker keymaps
                    local ok_picker, picker = pcall(require, "remote-terminal.picker")
                    if ok_picker then
                        local picker_bufnr = terminal_manager.get_picker_bufnr()
                        if picker_bufnr then
                            picker.init_buffer(picker_bufnr)
                        end
                        picker.refresh()
                    end
                else
                    -- Just switch to the new terminal
                    window_manager.switch_terminal(new_session.id)
                end
            end
        end
    end)

    return terminal and terminal.id or nil
end

--- Minimize a session
---@param session_id string
---@return boolean success
function M.minimize(session_id)
    local session = session_manager.get_session(session_id)
    if not session then
        vim.notify("[remote-session] Session not found", vim.log.levels.ERROR)
        return false
    end

    -- Capture current window layout
    session.window_layout = window_layout.capture_layout()

    -- Capture tree browser state
    local ok_tree, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if ok_tree and tree_browser.is_open() then
        local tree_state = tree_browser.get_state()
        if tree_state then
            session.tree_browser_state = {
                expanded_dirs = tree_state.expanded_dirs,
                -- We could also save cursor position here
            }
        end
    end

    -- Capture open buffer positions
    session.open_buffers = M.capture_buffer_states(session.url)

    -- Check for unsaved buffers
    if config.get("confirm_close") then
        local unsaved = M.get_unsaved_buffers(session.url)
        if #unsaved > 0 then
            local choice = vim.fn.confirm(
                "Session has unsaved buffers:\n"
                    .. table.concat(
                        vim.tbl_map(function(b)
                            return "  " .. vim.api.nvim_buf_get_name(b)
                        end, unsaved),
                        "\n"
                    )
                    .. "\n\nMinimize anyway?",
                "&Save all\n&Discard\n&Cancel",
                1
            )
            if choice == 1 then
                for _, bufnr in ipairs(unsaved) do
                    vim.api.nvim_buf_call(bufnr, function()
                        vim.cmd("write")
                    end)
                end
            elseif choice == 3 or choice == 0 then
                return false
            end
        end
    end

    -- Hide windows
    window_layout.hide_session_windows()

    -- Update state
    session_manager.set_minimized(session_id)

    vim.notify("[remote-session] Minimized: " .. session.name, vim.log.levels.INFO)

    return true
end

--- Restore a minimized or persisted session
---@param session_id string
---@return boolean success
function M.restore(session_id)
    local session = session_manager.get_session(session_id)

    -- If not in runtime, try to load from persistence
    if not session then
        session = session_manager.load_from_persistence(session_id)
    end

    if not session then
        vim.notify("[remote-session] Session not found", vim.log.levels.ERROR)
        return false
    end

    -- Remember original state before we change it
    local original_state = session.state

    -- Minimize current active session if different
    local current_active = session_manager.get_active_session()
    if current_active and current_active.id ~= session_id and config.get("auto_minimize") then
        M.minimize(current_active.id)
    end

    -- Set as active
    session_manager.set_active(session_id)

    -- Restore tree browser with state
    local ok_tree, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if ok_tree then
        if session.tree_browser_state then
            -- Open tree with restored state
            M.open_tree_with_state(session.url, session.tree_browser_state)
        else
            tree_browser.open_tree(session.url)
        end
    end

    -- Determine if we should show/create terminal
    local should_show_terminal = true
    if session.window_layout and session.window_layout.terminal_visible == false then
        should_show_terminal = false
    end

    if should_show_terminal then
        -- Check if we have runtime terminals that still exist
        local valid_terminal_id = nil
        if session.terminal_ids and #session.terminal_ids > 0 then
            local ok_tm, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
            if ok_tm then
                for _, term_id in ipairs(session.terminal_ids) do
                    local term = terminal_manager.get_terminal(term_id)
                    if term and term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
                        valid_terminal_id = term_id
                        break
                    end
                end
            end
        end

        if valid_terminal_id then
            -- Set the active terminal to one from this session
            local ok_tm, terminal_manager = pcall(require, "remote-terminal.terminal_manager")
            if ok_tm then
                terminal_manager.set_active_terminal(valid_terminal_id)
            end

            -- Show existing terminals
            local ok_wm, window_manager = pcall(require, "remote-terminal.window_manager")
            if ok_wm then
                window_manager.show_split()
            end
        else
            -- No valid terminals exist, create a new one
            -- This handles both persisted sessions and minimized sessions where terminal was closed
            M.create_terminal_for_session(session_id)
        end
    end

    -- Apply window layout
    window_layout.apply_layout(session.window_layout, session.url)

    -- Restore buffer cursor positions
    if session.open_buffers then
        M.restore_buffer_states(session.open_buffers)
    end

    vim.notify("[remote-session] Restored: " .. session.name, vim.log.levels.INFO)

    return true
end

--- Open tree browser with restored state
---@param url string
---@param state table Tree browser state
function M.open_tree_with_state(url, state)
    local ok, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if not ok then
        return
    end

    -- First open the tree
    tree_browser.open_tree(url)

    -- Then restore expanded directories
    if state and state.expanded_dirs then
        -- Wait a bit for initial load, then restore state
        vim.defer_fn(function()
            tree_browser.restore_state({
                base_url = url,
                expanded_dirs = state.expanded_dirs,
            })
        end, 200)
    end
end

--- Close a session
---@param session_id string
---@param opts table|nil {force: boolean}
---@return boolean success
function M.close(session_id, opts)
    opts = opts or {}
    local session = session_manager.get_session(session_id)

    if not session then
        -- Try to just delete from persistence
        persistence.delete_session(session_id)
        return true
    end

    -- Check for unsaved buffers
    if not opts.force and config.get("confirm_close") then
        local unsaved = M.get_unsaved_buffers(session.url)
        if #unsaved > 0 then
            local choice = vim.fn.confirm(
                "Session has unsaved buffers. Close anyway?",
                "&Save all\n&Discard\n&Cancel",
                1
            )
            if choice == 1 then
                for _, bufnr in ipairs(unsaved) do
                    vim.api.nvim_buf_call(bufnr, function()
                        vim.cmd("write")
                    end)
                end
            elseif choice == 3 or choice == 0 then
                return false
            end
        end
    end

    -- Check for running terminals
    if not opts.force and config.get("confirm_terminal_close") and session.terminal_ids and #session.terminal_ids > 0 then
        local choice = vim.fn.confirm(
            "Session has " .. #session.terminal_ids .. " terminal(s). Close session?",
            "&Yes\n&No",
            1
        )
        if choice ~= 1 then
            return false
        end
    end

    -- Close tree browser if this is the active session
    if session_manager.is_active(session_id) then
        local ok_tree, tree_browser = pcall(require, "async-remote-write.tree_browser")
        if ok_tree then
            tree_browser.close_tree()
        end
    end

    -- Close associated terminals
    local ok_ts, terminal_session = pcall(require, "remote-terminal.terminal_session")
    if ok_ts and session.terminal_ids then
        for _, terminal_id in ipairs(session.terminal_ids) do
            terminal_session.close_terminal(terminal_id)
        end
    end

    -- Close session buffers
    M.close_session_buffers(session.url)

    -- Unregister from runtime
    session_manager.unregister_session(session_id)

    -- Delete from persistence
    persistence.delete_session(session_id)

    vim.notify("[remote-session] Closed: " .. session.name, vim.log.levels.INFO)

    return true
end

--- Get unsaved buffers for a session URL
---@param url string Session URL
---@return number[] bufnrs
function M.get_unsaved_buffers(url)
    local unsaved = {}
    local host_pattern = url:match("://([^/]+)")

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match(host_pattern) and vim.bo[bufnr].modified then
                table.insert(unsaved, bufnr)
            end
        end
    end

    return unsaved
end

--- Capture buffer states for a session
---@param url string Session URL
---@return table[] buffer_states
function M.capture_buffer_states(url)
    local states = {}
    local host_pattern = url:match("://([^/]+)")

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match(host_pattern) then
                -- Find window displaying this buffer
                local winid = nil
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_get_buf(win) == bufnr then
                        winid = win
                        break
                    end
                end

                local cursor_pos = { 1, 0 }
                if winid then
                    cursor_pos = vim.api.nvim_win_get_cursor(winid)
                end

                table.insert(states, {
                    url = bufname,
                    cursor_pos = cursor_pos,
                    winid = winid,
                })
            end
        end
    end

    return states
end

--- Restore buffer cursor states
---@param states table[] Buffer states
function M.restore_buffer_states(states)
    for _, state in ipairs(states) do
        -- Find buffer by name
        local bufnr = vim.fn.bufnr(state.url)
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            -- Find window displaying this buffer
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == bufnr then
                    pcall(vim.api.nvim_win_set_cursor, win, state.cursor_pos)
                    break
                end
            end
        end
    end
end

--- Close all buffers for a session
---@param url string Session URL
function M.close_session_buffers(url)
    local host_pattern = url:match("://([^/]+)")

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match(host_pattern) then
                -- Don't close tree browser buffer
                if not bufname:match("^Remote Tree:") then
                    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
                end
            end
        end
    end
end

--- Open a session by URL (creates new or restores existing)
---@param url string|nil URL to open (shows picker if nil)
---@param opts table|nil Options
function M.open(url, opts)
    opts = opts or {}

    if not url or url == "" then
        -- Show picker
        local picker = require("remote-session.picker")
        picker.show()
        return
    end

    -- Normalize URL
    url = M.normalize_url(url)

    -- Check for existing session
    local existing = session_manager.find_by_url(url)
    if existing then
        -- Restore existing session
        M.restore(existing.id)
    else
        -- Create new session
        M.create(url, opts)
    end
end

--- Rename the active session or a specific session
---@param session_id string|nil Session ID (uses active if nil)
---@param new_name string|nil New name (prompts if nil)
function M.rename(session_id, new_name)
    session_id = session_id or session_manager.get_active_session_id()
    if not session_id then
        vim.notify("[remote-session] No active session to rename", vim.log.levels.WARN)
        return
    end

    local session = session_manager.get_session(session_id)
    if not session then
        vim.notify("[remote-session] Session not found", vim.log.levels.ERROR)
        return
    end

    if new_name then
        -- Validate and apply
        local valid, err = naming.validate_name(new_name)
        if not valid then
            vim.notify("[remote-session] Invalid name: " .. err, vim.log.levels.ERROR)
            return
        end

        local unique_name = naming.make_unique(new_name, session_id)
        session_manager.rename_session(session_id, unique_name)
        vim.notify("[remote-session] Renamed to: " .. unique_name, vim.log.levels.INFO)
    else
        -- Prompt for name
        vim.ui.input({
            prompt = "New session name: ",
            default = session.name,
        }, function(input)
            if input and input ~= "" then
                M.rename(session_id, input)
            end
        end)
    end
end

return M
