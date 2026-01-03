local M = {}

local log = require("logging").log
local session_manager = require("remote-tui.session_manager")
local window_manager = require("remote-tui.window_manager")
local connection_manager = require("remote-tui.connection_manager")

-- Create a new TUI session with proper tracking
function M.create_tui_session(app_name, host_string, directory_path, connection_info)
    -- Validate inputs
    if not app_name or app_name == "" then
        vim.notify("App name is required", vim.log.levels.ERROR)
        return
    end

    if not host_string or host_string == "" then
        vim.notify("Host string is required", vim.log.levels.ERROR)
        return
    end

    -- Build SSH command
    local ssh_command = connection_manager.build_ssh_command(host_string, app_name, directory_path)
    ssh_command = table.concat(ssh_command, " ")
    log(ssh_command, vim.log.levels.DEBUG, true)

    -- Create floating window and buffer
    local buf, win = window_manager.create_floating_window()
    vim.bo[buf].bufhidden = "" -- Don't auto-wipe, we manage session lifecycle

    -- Create session metadata
    local session_metadata = session_manager.create_session_metadata(app_name, host_string, directory_path, connection_info)
    local session_id = session_metadata.id

    -- Setup hide keymap for hiding
    local config = require("remote-tui.config")
    local hide_key = config.get_keymaps().hide_session
    if hide_key and hide_key ~= "" then
        vim.keymap.set("t", hide_key, session_manager.hide_current_session, { buffer = buf, noremap = true, silent = true })
    end

    local job_id = vim.fn.termopen(ssh_command, {
        on_exit = function(job_id, exit_code, event_type)
            -- Remove from active sessions when terminal exits
            if session_manager.get_active_session(session_id) then
                log("TUI session exited: " .. session_metadata.display_name, vim.log.levels.INFO, true)
                session_manager.remove_active_session(session_id)
            end

            -- Close window if still valid
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, false)
            end
        end,
    })

    if job_id <= 0 then
        vim.notify("Failed to start terminal", vim.log.levels.ERROR)
        session_manager.decrement_id() -- Revert ID increment
        return
    end

    -- Register the active session
    session_manager.register_active_session(session_id, buf, win, session_metadata)

    log("Created TUI session: " .. session_metadata.display_name, vim.log.levels.INFO, true)
    vim.cmd("startinsert")

    return session_id
end

-- Create TUI session from buffer metadata
function M.create_from_buffer_metadata(app_name, buf_info)
    if not buf_info then
        vim.notify("No buffer metadata provided", vim.log.levels.ERROR)
        return
    end

    -- Use buffer metadata when available
    local directory_path = vim.fn.fnamemodify(buf_info.path, ":h")
    local host_string = buf_info.user and (buf_info.user .. "@" .. buf_info.host) or buf_info.host

    -- Create connection info from buffer metadata
    local connection_info = connection_manager.parse_buffer_connection_info(buf_info)

    return M.create_tui_session(app_name, host_string, directory_path, connection_info)
end

-- Create TUI session from manual connection info
function M.create_from_manual_input(app_name, manual_info)
    local valid, error_msg = connection_manager.validate_connection_info(manual_info)
    if not valid then
        vim.notify("Invalid connection info: " .. error_msg, vim.log.levels.ERROR)
        return
    end

    local directory_path = manual_info.path
    local host_string = connection_manager.build_host_string(manual_info)

    return M.create_tui_session(app_name, host_string, directory_path, manual_info)
end

-- Prompt for connection info and create session
function M.create_with_prompt(app_name)
    connection_manager.prompt_for_connection_info(function(manual_info)
        M.create_from_manual_input(app_name, manual_info)
    end)
end

-- Get session statistics
function M.get_session_stats()
    return session_manager.get_session_count()
end

return M
