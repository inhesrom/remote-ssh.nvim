-- Terminal session management for remote-terminal module
local M = {}

local terminal_manager = require("remote-terminal.terminal_manager")
local config = require("remote-terminal.config")

--- Get remote context from the current environment
--- Tries multiple sources: current buffer, tree browser
---@return table|nil connection_info {user, host, port, path}
function M.get_remote_context()
    -- First try: current buffer
    local current_bufnr = vim.api.nvim_get_current_buf()
    local context = M.get_context_from_buffer(current_bufnr)
    if context then
        return context
    end

    -- Second try: tree browser
    context = M.get_context_from_tree_browser()
    if context then
        return context
    end

    return nil
end

--- Get remote context from a buffer
---@param bufnr number
---@return table|nil connection_info
function M.get_context_from_buffer(bufnr)
    -- Try to use async-remote-write utils
    local ok, utils = pcall(require, "async-remote-write.utils")
    if not ok then
        return nil
    end

    local remote_info = utils.get_remote_file_info(bufnr)
    if not remote_info then
        return nil
    end

    -- Extract directory from file path
    local directory = vim.fn.fnamemodify(remote_info.path, ":h")
    if directory == "." or directory == "" then
        directory = "~"
    end

    return {
        user = remote_info.user,
        host = remote_info.host,
        port = remote_info.port,
        path = directory,
    }
end

--- Get remote context from tree browser
---@return table|nil connection_info
function M.get_context_from_tree_browser()
    local ok, tree_browser = pcall(require, "async-remote-write.tree_browser")
    if not ok then
        return nil
    end

    local state = tree_browser.get_state()
    if not state or not state.base_url or state.base_url == "" then
        return nil
    end

    -- Parse the base_url
    local utils_ok, utils = pcall(require, "async-remote-write.utils")
    if not utils_ok then
        return nil
    end

    local remote_info = utils.parse_remote_path(state.base_url)
    if not remote_info then
        return nil
    end

    -- Parse user/host/port from host string
    local user, host, port
    local host_str = remote_info.host

    -- Check for user@host:port format
    local u, h, p = host_str:match("^([^@]+)@([^:]+):?(%d*)$")
    if u then
        user = u
        host = h
        port = p ~= "" and tonumber(p) or nil
    else
        -- Check for user@host format
        u, h = host_str:match("^([^@]+)@(.+)$")
        if u then
            user = u
            host = h
        else
            host = host_str
        end
    end

    return {
        user = user,
        host = host,
        port = port,
        path = remote_info.path or "~",
    }
end

--- Prompt user for connection info
---@param callback function(connection_info)
function M.prompt_for_connection_info(callback)
    local ok, connection_manager = pcall(require, "remote-tui.connection_manager")
    if ok then
        connection_manager.prompt_for_connection_info(callback)
    else
        -- Fallback implementation
        vim.ui.input({
            prompt = "Enter user@host[:port] (e.g., ubuntu@myserver.com:22): ",
            default = "",
        }, function(input)
            if not input or input:match("^%s*$") then
                vim.notify("No connection info provided", vim.log.levels.WARN)
                return
            end

            local user, host, port
            local u, h, p = input:match("^([^@]+)@([^:]+):?(%d*)$")
            if u then
                user = u
                host = h
                port = p ~= "" and tonumber(p) or nil
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
end

--- Build SSH command for terminal
---@param connection_info table {user, host, port, path}
---@return string[] ssh_cmd
function M.build_ssh_command(connection_info)
    local ssh_args = { "ssh" }

    -- Add robust connection options
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ConnectTimeout=10")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ServerAliveInterval=5")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ServerAliveCountMax=3")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "TCPKeepAlive=yes")

    -- Add -t for pseudo-terminal allocation (required for interactive shell)
    table.insert(ssh_args, "-t")

    -- Add port if specified
    if connection_info.port then
        table.insert(ssh_args, "-p")
        table.insert(ssh_args, tostring(connection_info.port))
    end

    -- Build host string
    local host_string
    if connection_info.user then
        host_string = connection_info.user .. "@" .. connection_info.host
    else
        host_string = connection_info.host
    end
    table.insert(ssh_args, host_string)

    -- Build the remote command: cd to path and exec shell
    local path = connection_info.path or "~"
    local remote_cmd = string.format("cd %s && exec $SHELL -l", vim.fn.shellescape(path))
    table.insert(ssh_args, remote_cmd)

    return ssh_args
end

--- Build host string for display
---@param connection_info table {user, host, port}
---@return string
function M.build_host_string(connection_info)
    local host_string = connection_info.host
    if connection_info.user then
        host_string = connection_info.user .. "@" .. host_string
    end
    if connection_info.port then
        host_string = host_string .. ":" .. tostring(connection_info.port)
    end
    return host_string
end

--- Create a new terminal session
---@param connection_info table {user, host, port, path}
---@param callback function|nil Called with session on success
---@return table|nil session
function M.create_session(connection_info, callback)
    -- Create a new buffer for the terminal
    local bufnr = vim.api.nvim_create_buf(false, true)
    if not bufnr or bufnr == 0 then
        vim.notify("Failed to create terminal buffer", vim.log.levels.ERROR)
        return nil
    end

    -- Build SSH command
    local ssh_cmd = M.build_ssh_command(connection_info)
    local host_string = M.build_host_string(connection_info)

    -- Create session data
    local session = {
        bufnr = bufnr,
        job_id = nil,
        connection_info = {
            user = connection_info.user,
            host = connection_info.host,
            port = connection_info.port,
        },
        host_string = host_string,
        directory_path = connection_info.path or "~",
        created_at = os.time(),
        display_name = "shell @ " .. connection_info.host,
    }

    -- Register the session first to get ID
    local id = terminal_manager.add_terminal(session)
    session.id = id

    -- Set buffer name
    vim.api.nvim_buf_set_name(bufnr, "Terminal " .. id .. ": " .. host_string)

    -- Open terminal in the buffer
    -- Need to switch to the buffer first
    local original_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(bufnr)

    -- Start the terminal
    local job_id = vim.fn.termopen(ssh_cmd, {
        on_exit = function(job_id, exit_code, event)
            -- Handle terminal exit
            vim.schedule(function()
                M.handle_terminal_exit(id, exit_code)
            end)
        end,
    })

    -- Restore original buffer if it's still valid
    if vim.api.nvim_buf_is_valid(original_buf) then
        vim.api.nvim_set_current_buf(original_buf)
    end

    if job_id <= 0 then
        vim.notify("Failed to start terminal: " .. tostring(job_id), vim.log.levels.ERROR)
        terminal_manager.remove_terminal(id)
        return nil
    end

    session.job_id = job_id

    if callback then
        callback(session)
    end

    return session
end

--- Handle terminal exit
---@param id number Terminal ID
---@param exit_code number
function M.handle_terminal_exit(id, exit_code)
    local session = terminal_manager.get_terminal(id)
    if not session then
        return
    end

    -- Mark as exited but don't remove yet
    session.exited = true
    session.exit_code = exit_code

    -- Refresh picker to show exit status
    local ok, picker = pcall(require, "remote-terminal.picker")
    if ok then
        picker.refresh()
    end
end

--- Create a new terminal from current context or prompt for info
---@param callback function|nil Called with session on success
function M.new_terminal(callback)
    local context = M.get_remote_context()

    if context then
        local session = M.create_session(context, callback)
        return session
    else
        -- Prompt for connection info
        M.prompt_for_connection_info(function(connection_info)
            M.create_session(connection_info, callback)
        end)
    end
end

--- Close the active terminal
function M.close_active_terminal()
    local active_id = terminal_manager.get_active_terminal_id()
    if not active_id then
        vim.notify("No active terminal to close", vim.log.levels.WARN)
        return
    end

    terminal_manager.remove_terminal(active_id)

    -- Update UI
    local window_manager = require("remote-terminal.window_manager")
    local picker = require("remote-terminal.picker")

    if terminal_manager.get_terminal_count() == 0 then
        -- No more terminals, hide the split
        window_manager.hide_split()
    else
        -- Switch to next terminal and refresh
        local next_terminal = terminal_manager.get_active_terminal()
        if next_terminal then
            window_manager.switch_terminal(next_terminal.id)
        end
        picker.refresh()
    end
end

--- Close a specific terminal by ID
---@param id number
function M.close_terminal(id)
    if not terminal_manager.get_terminal(id) then
        return
    end

    terminal_manager.remove_terminal(id)

    -- Update UI
    local window_manager = require("remote-terminal.window_manager")
    local picker = require("remote-terminal.picker")

    if terminal_manager.get_terminal_count() == 0 then
        window_manager.hide_split()
    else
        local active = terminal_manager.get_active_terminal()
        if active then
            window_manager.switch_terminal(active.id)
        end
        picker.refresh()
    end
end

--- Rename the active terminal
---@param new_name string|nil If nil, prompt for name
function M.rename_active_terminal(new_name)
    local active_id = terminal_manager.get_active_terminal_id()
    if not active_id then
        vim.notify("No active terminal to rename", vim.log.levels.WARN)
        return
    end

    if new_name then
        terminal_manager.rename_terminal(active_id, new_name)
        local picker = require("remote-terminal.picker")
        picker.refresh()
    else
        vim.ui.input({
            prompt = "New terminal name: ",
            default = terminal_manager.get_terminal(active_id).display_name,
        }, function(input)
            if input and not input:match("^%s*$") then
                terminal_manager.rename_terminal(active_id, input)
                local picker = require("remote-terminal.picker")
                picker.refresh()
            end
        end)
    end
end

--- Rename a specific terminal by ID
---@param id number
---@param new_name string|nil
function M.rename_terminal(id, new_name)
    local session = terminal_manager.get_terminal(id)
    if not session then
        return
    end

    if new_name then
        terminal_manager.rename_terminal(id, new_name)
        local picker = require("remote-terminal.picker")
        picker.refresh()
    else
        vim.ui.input({
            prompt = "New terminal name: ",
            default = session.display_name,
        }, function(input)
            if input and not input:match("^%s*$") then
                terminal_manager.rename_terminal(id, input)
                local picker = require("remote-terminal.picker")
                picker.refresh()
            end
        end)
    end
end

return M
