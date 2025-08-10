-- SSH utility functions for remote connections
local M = {}

local Job = require("plenary.job")
local async = require("plenary.async")

-- Helper function to detect localhost connections
local function is_localhost(host)
    -- Extract hostname from user@host format if present
    local hostname = host:match("@(.+)$") or host

    return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
end

-- Helper function to build SSH command with proper options
function M.build_ssh_cmd(host, command)
    local ssh_args = { "ssh" }

    -- Add robust connection options to handle various SSH issues
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ConnectTimeout=10")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ServerAliveInterval=5")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ServerAliveCountMax=3")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "TCPKeepAlive=yes")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ControlMaster=no")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ControlPath=none")

    -- Add IPv4 preference for localhost connections to avoid IPv6 issues
    if is_localhost(host) then
        table.insert(ssh_args, "-4")
    end

    table.insert(ssh_args, host)
    table.insert(ssh_args, command)

    return ssh_args
end

-- Helper function to build SCP command with proper options
function M.build_scp_cmd(source, destination, options)
    local scp_args = { "scp" }

    -- Add robust connection options to handle various SSH issues
    table.insert(scp_args, "-o")
    table.insert(scp_args, "ConnectTimeout=10")
    table.insert(scp_args, "-o")
    table.insert(scp_args, "ServerAliveInterval=5")
    table.insert(scp_args, "-o")
    table.insert(scp_args, "ServerAliveCountMax=3")
    table.insert(scp_args, "-o")
    table.insert(scp_args, "TCPKeepAlive=yes")

    -- Add standard options
    if options then
        for _, opt in ipairs(options) do
            table.insert(scp_args, opt)
        end
    end

    -- Extract host from source or destination to check for localhost
    local host = nil
    if source:match("^[^:]+:") then
        host = source:match("^([^:]+):")
    elseif destination:match("^[^:]+:") then
        host = destination:match("^([^:]+):")
    end

    -- Add IPv4 preference for localhost connections
    if host and is_localhost(host) then
        table.insert(scp_args, "-4")
    end

    table.insert(scp_args, source)
    table.insert(scp_args, destination)

    return scp_args
end

-- Helper function to build SSH command with user, host, port, and command
function M.build_ssh_command(user, host, port, command)
    local ssh_args = { "ssh" }

    -- Add robust connection options to handle various SSH issues
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ConnectTimeout=10")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ServerAliveInterval=5")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ServerAliveCountMax=3")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "TCPKeepAlive=yes")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ControlMaster=no")
    table.insert(ssh_args, "-o")
    table.insert(ssh_args, "ControlPath=none")

    -- Add port if specified
    if port and port ~= "" and tonumber(port) then
        table.insert(ssh_args, "-p")
        table.insert(ssh_args, tostring(port))
    end

    -- Add IPv4 preference for localhost connections to avoid IPv6 issues
    local full_host = user and (user .. "@" .. host) or host
    if is_localhost(full_host) then
        table.insert(ssh_args, "-4")
    end

    -- Add user@host
    table.insert(ssh_args, full_host)
    table.insert(ssh_args, command)

    return ssh_args
end

-- Plenary job template for SSH operations
function M.create_ssh_job(user, host, port, command, options)
    options = options or {}

    local ssh_args = M.build_ssh_command(user, host, port, command)

    return Job:new({
        command = ssh_args[1],
        args = vim.list_slice(ssh_args, 2),
        enable_recording = true,
        timeout = options.timeout or 30000,
        on_stderr = options.on_stderr or function(error, data)
            if data and options.debug then
                vim.schedule(function()
                    print("SSH Error: " .. data)
                end)
            end
        end,
        on_stdout = options.on_stdout,
        on_exit = options.on_exit,
    })
end

-- Async SSH command execution with plenary
M.run_ssh_command_async = async.wrap(function(user, host, port, command, options, callback)
    options = options or {}

    local job = M.create_ssh_job(user, host, port, command, {
        timeout = options.timeout,
        debug = options.debug,
        on_stderr = options.on_stderr,
    })

    local ok, exit_code = pcall(function()
        return job:sync(options.timeout or 30000)
    end)

    if not ok then
        callback(false, "SSH job timed out or failed to start", nil, nil)
        return
    end

    local stdout = job:result() or {}
    local stderr = job:stderr_result() or {}

    callback(true, exit_code, stdout, stderr)
end, 6)

-- Synchronous wrapper for SSH command execution
function M.run_ssh_command(user, host, port, command, options, callback)
    M.run_ssh_command_async(user, host, port, command, options, callback)
end

-- Plenary job template for SCP operations
function M.create_scp_job(source, destination, options)
    options = options or {}

    local scp_args = M.build_scp_cmd(source, destination, options.scp_options)

    return Job:new({
        command = scp_args[1],
        args = vim.list_slice(scp_args, 2),
        enable_recording = true,
        timeout = options.timeout or 30000,
        on_stderr = options.on_stderr or function(error, data)
            if data and options.debug then
                vim.schedule(function()
                    print("SCP Error: " .. data)
                end)
            end
        end,
        on_stdout = options.on_stdout,
        on_exit = options.on_exit,
    })
end

-- Async SCP operation with plenary
M.run_scp_async = async.wrap(function(source, destination, options, callback)
    options = options or {}

    local job = M.create_scp_job(source, destination, {
        timeout = options.timeout,
        debug = options.debug,
        scp_options = options.scp_options,
        on_stderr = options.on_stderr,
    })

    local ok, exit_code = pcall(function()
        return job:sync(options.timeout or 30000)
    end)

    if not ok then
        callback(false, "SCP job timed out or failed to start", nil, nil)
        return
    end

    local stdout = job:result() or {}
    local stderr = job:stderr_result() or {}

    callback(true, exit_code, stdout, stderr)
end, 4)

-- Synchronous wrapper for SCP operations
function M.run_scp(source, destination, options, callback)
    M.run_scp_async(source, destination, options, callback)
end

-- Expose is_localhost for other modules that might need it
M.is_localhost = is_localhost

return M
