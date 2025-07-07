-- SSH utility functions for remote connections
local M = {}

-- Helper function to detect localhost connections
local function is_localhost(host)
    -- Extract hostname from user@host format if present
    local hostname = host:match("@(.+)$") or host
    
    return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
end

-- Helper function to build SSH command with proper options
function M.build_ssh_cmd(host, command)
    local ssh_args = {"ssh"}
    
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
    local scp_args = {"scp"}
    
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

-- Expose is_localhost for other modules that might need it
M.is_localhost = is_localhost

return M