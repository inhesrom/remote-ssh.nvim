local M = {}

local build_ssh_cmd = require("async-remote-write.ssh_utils").build_ssh_cmd

-- SSH command wrapper function
function M.build_ssh_command(host, tui_appname, directory_path)
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

-- Prompt user for remote connection info when buffer metadata is unavailable
function M.prompt_for_connection_info(callback)
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

-- Validate connection info structure
function M.validate_connection_info(connection_info)
    if type(connection_info) ~= "table" then
        return false, "Connection info must be a table"
    end
    
    if not connection_info.user or type(connection_info.user) ~= "string" then
        return false, "User must be a non-empty string"
    end
    
    if not connection_info.host or type(connection_info.host) ~= "string" then
        return false, "Host must be a non-empty string"
    end
    
    if connection_info.port and type(connection_info.port) ~= "number" then
        return false, "Port must be a number if provided"
    end
    
    if not connection_info.path or type(connection_info.path) ~= "string" then
        return false, "Path must be a non-empty string"
    end
    
    return true, nil
end

-- Build host string from connection info
function M.build_host_string(connection_info)
    if connection_info.user then
        return connection_info.user .. "@" .. connection_info.host
    else
        return connection_info.host
    end
end

-- Parse connection info from buffer metadata
function M.parse_buffer_connection_info(buf_info)
    if not buf_info then
        return nil
    end
    
    return {
        user = buf_info.user,
        host = buf_info.host,
        port = buf_info.port,
    }
end

return M