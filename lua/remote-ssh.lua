local M = {}

local async_write = require('async-remote-write')

-- Global variables set by setup
local on_attach
local capabilities
local filetype_to_server
local custom_root_dir = nil

-- Tracking structures
-- Map client_id to info about the client
local active_lsp_clients = {}
-- Map server_name+host to list of buffers using it
local server_buffers = {}
-- Map bufnr to client_ids
local buffer_clients = {}

-- Helper function to determine protocol from bufname
local function get_protocol(bufname)
    if bufname:match("^scp://") then
        return "scp"
    elseif bufname:match("^rsync://") then
        return "rsync"
    else
        return nil
    end
end

function M.setup(opts)
    -- Add verbose logging for setup process
    vim.notify("Setting up remote-lsp with options: " .. vim.inspect(opts), vim.log.levels.DEBUG)
    
    on_attach = opts.on_attach or function(_, bufnr)
        vim.notify("LSP attached to buffer " .. bufnr, vim.log.levels.INFO)
    end
    capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()
    filetype_to_server = opts.filetype_to_server or {}
    
    -- Log available filetype mappings
    local ft_count = 0
    for ft, server in pairs(filetype_to_server) do
        ft_count = ft_count + 1
    end
    vim.notify("Registered " .. ft_count .. " filetype to server mappings", vim.log.levels.INFO)

    async_write.setup()
end

-- Function to get the directory of the current Lua script
local function get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
end

-- Get a unique server key based on server name and host
local function get_server_key(server_name, host)
    return server_name .. "@" .. host
end

-- Function to track client with server and buffer information
local function track_client(client_id, server_name, bufnr, host, protocol)
    vim.notify("Tracking client " .. client_id .. " for server " .. server_name .. " on buffer " .. bufnr, vim.log.levels.DEBUG)
    
    -- Track client info
    active_lsp_clients[client_id] = {
        server_name = server_name,
        bufnr = bufnr,
        host = host,
        protocol = protocol,
        timestamp = os.time()
    }
    
    -- Track which buffers use which server
    local server_key = get_server_key(server_name, host)
    if not server_buffers[server_key] then
        server_buffers[server_key] = {}
    end
    server_buffers[server_key][bufnr] = true
    
    -- Track which clients are attached to which buffers
    if not buffer_clients[bufnr] then
        buffer_clients[bufnr] = {}
    end
    buffer_clients[bufnr][client_id] = true
end

-- Function to untrack a client
local function untrack_client(client_id)
    local client_info = active_lsp_clients[client_id]
    if not client_info then return end
    
    -- Remove from server-buffer tracking
    if client_info.server_name and client_info.host then
        local server_key = get_server_key(client_info.server_name, client_info.host)
        if server_buffers[server_key] and server_buffers[server_key][client_info.bufnr] then
            server_buffers[server_key][client_info.bufnr] = nil
            
            -- If no more buffers use this server, remove the server entry
            if vim.tbl_isempty(server_buffers[server_key]) then
                server_buffers[server_key] = nil
            end
        end
    end
    
    -- Remove from buffer-client tracking
    if client_info.bufnr and buffer_clients[client_info.bufnr] then
        buffer_clients[client_info.bufnr][client_id] = nil
        
        -- If no more clients for this buffer, remove the buffer entry
        if vim.tbl_isempty(buffer_clients[client_info.bufnr]) then
            buffer_clients[client_info.bufnr] = nil
        end
    end
    
    -- Remove the client info itself
    active_lsp_clients[client_id] = nil
end

-- Function to stop an LSP client
function M.shutdown_client(client_id, force_kill)
    -- Add error handling
    local ok, err = pcall(function()
        local client_info = active_lsp_clients[client_id]
        if not client_info then
            vim.notify("Client " .. client_id .. " not found in active clients", vim.log.levels.WARN)
            return
        end

        vim.notify("Shutting down client " .. client_id, vim.log.levels.INFO)
        
        -- Send proper shutdown sequence to the LSP server
        local client = vim.lsp.get_client_by_id(client_id)
        if client and not client.is_stopped() then
            -- First try a graceful shutdown
            vim.notify("Sending shutdown request to LSP server", vim.log.levels.DEBUG)
            
            -- Get client's RPC object if available
            if client.rpc then
                -- Attempt a clean shutdown sequence
                client.rpc.notify("shutdown")
                vim.wait(100)  -- Give the server a moment to process
                client.rpc.notify("exit")
                vim.wait(100)  -- Give the server a moment to exit
            end
        end
        
        -- Then stop the client
        vim.lsp.stop_client(client_id, true)
        
        -- Only force kill if this server isn't used by other buffers
        if force_kill and client_info.host and client_info.server_name then
            local server_key = get_server_key(client_info.server_name, client_info.host)
            
            -- Check if any buffers still use this server
            if not server_buffers[server_key] or vim.tbl_isempty(server_buffers[server_key]) then
                -- No buffers using this server, kill the process
                vim.notify("No buffers using server " .. server_key .. ", killing remote process", vim.log.levels.INFO)
                local cmd = string.format("ssh %s 'pkill -f %s'", client_info.host, client_info.server_name)
                vim.fn.jobstart(cmd, {
                    on_exit = function(_, exit_code)
                        if exit_code == 0 then
                            vim.notify("Successfully killed remote LSP process for " .. server_key, vim.log.levels.INFO)
                        else
                            vim.notify("Failed to kill remote LSP process for " .. server_key .. " (or none found)", vim.log.levels.WARN)
                        end
                    end
                })
            else
                vim.notify("Not killing remote process for " .. server_key .. " as it's still used by other buffers", vim.log.levels.INFO)
            end
        end
        
        untrack_client(client_id)
    end)
    
    if not ok then
        vim.notify("Error shutting down client: " .. tostring(err), vim.log.levels.ERROR)
    end
end

-- Function to safely handle buffer untracking
local function safe_untrack_buffer(bufnr)
    local ok, err = pcall(function()
        vim.notify("Untracking buffer " .. bufnr, vim.log.levels.DEBUG)
        
        -- Get clients for this buffer
        local clients = buffer_clients[bufnr] or {}
        local client_ids = vim.tbl_keys(clients)
        
        -- For each client, check if we should shut it down
        for _, client_id in ipairs(client_ids) do
            local client_info = active_lsp_clients[client_id]
            if client_info then
                local server_key = get_server_key(client_info.server_name, client_info.host)
                
                -- Untrack this buffer from the server
                if server_buffers[server_key] then
                    server_buffers[server_key][bufnr] = nil
                    
                    -- Check if this was the last buffer using this server
                    if vim.tbl_isempty(server_buffers[server_key]) then
                        -- This was the last buffer, shut down the server
                        vim.notify("Last buffer using server " .. server_key .. " closed, shutting down client " .. client_id, vim.log.levels.INFO)
                        M.shutdown_client(client_id, true)
                    else
                        -- Other buffers still use this server, just untrack this buffer
                        vim.notify("Buffer " .. bufnr .. " closed but server " .. server_key .. " still has active buffers, keeping client " .. client_id, vim.log.levels.DEBUG)
                        
                        -- Still untrack the client from this buffer specifically
                        if buffer_clients[bufnr] then
                            buffer_clients[bufnr][client_id] = nil
                        end
                    end
                end
            end
        end
        
        -- Finally remove the buffer from our tracking
        buffer_clients[bufnr] = nil
    end)
    
    if not ok then
        vim.notify("Error untracking buffer: " .. tostring(err), vim.log.levels.ERROR)
    end
end

-- Function to stop all active remote LSP clients
function M.stop_all_clients(force_kill)
    force_kill = force_kill or false
    
    -- Keep track of server_keys we've already processed
    local processed_servers = {}
    
    for client_id, info in pairs(active_lsp_clients) do
        local server_key = get_server_key(info.server_name, info.host)
        
        -- Only process each server once
        if not processed_servers[server_key] then
            vim.notify("Stopping LSP clients for server " .. server_key, vim.log.levels.INFO)
            M.shutdown_client(client_id, force_kill)
            processed_servers[server_key] = true
        end
    end
    
    -- Reset all tracking structures
    active_lsp_clients = {}
    server_buffers = {}
    buffer_clients = {}
end

-- Parse host and path from buffer name
local function parse_remote_buffer(bufname)
    local protocol = get_protocol(bufname)
    if not protocol then
        return nil, nil, nil
    end
    
    local pattern = "^" .. protocol .. "://([^/]+)/(.+)$"
    local host, path = bufname:match(pattern)
    return host, path, protocol
end

-- Function to start LSP client for a remote buffer
function M.start_remote_lsp(bufnr)
    vim.notify("Attempting to start remote LSP for buffer " .. bufnr, vim.log.levels.INFO)
    
    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return
    end
    
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    vim.notify("Buffer name: " .. bufname, vim.log.levels.DEBUG)
    
    local protocol = get_protocol(bufname)
    if not protocol then
        vim.notify("Not a remote URL: " .. bufname, vim.log.levels.WARN)
        return
    end
    
    local host, path, _ = parse_remote_buffer(bufname)
    if not host or not path then
        vim.notify("Invalid remote URL: " .. bufname, vim.log.levels.ERROR)
        return
    end
    vim.notify("Host: " .. host .. ", Path: " .. path .. ", Protocol: " .. protocol, vim.log.levels.DEBUG)
    
    local root_dir
    if custom_root_dir then
        root_dir = custom_root_dir
    else
        local dir = vim.fn.fnamemodify(path, ":h")
        root_dir = protocol .. "://" .. host .. "/" .. dir
    end
    vim.notify("Root dir: " .. root_dir, vim.log.levels.DEBUG)
    
    local filetype = vim.bo[bufnr].filetype
    vim.notify("Initial filetype: " .. (filetype or "nil"), vim.log.levels.DEBUG)
    
    -- If no filetype is detected, infer it from the extension
    if not filetype or filetype == "" then
        local ext = vim.fn.fnamemodify(bufname, ":e")
        local ext_to_ft = {
            c = "c",
            cpp = "cpp", 
            cxx = "cpp",
            cc = "cpp",
            h = "c",
            hpp = "cpp",
            py = "python",
            rs = "rust",
        }
        filetype = ext_to_ft[ext] or ""
        if filetype ~= "" then
            vim.bo[bufnr].filetype = filetype
            vim.notify("Set filetype to " .. filetype .. " for buffer " .. bufnr, vim.log.levels.INFO)
        else
            vim.notify("No filetype detected or inferred for buffer " .. bufnr, vim.log.levels.WARN)
            return
        end
    end
    
    -- Check if filetype_to_server is correctly populated
    if type(filetype_to_server) ~= "table" then
        vim.notify("filetype_to_server is not a table. Type: " .. type(filetype_to_server), vim.log.levels.ERROR)
        return
    end
    
    local server_name = filetype_to_server[filetype]
    if not server_name then
        vim.notify("No LSP server for filetype: " .. filetype .. ". Available mappings: " .. vim.inspect(filetype_to_server), vim.log.levels.WARN)
        return
    end
    vim.notify("Server name: " .. server_name, vim.log.levels.DEBUG)
    
    -- Check if this server is already running for this host
    local server_key = get_server_key(server_name, host)
    if server_buffers[server_key] then
        -- Find an existing client for this server and attach it to this buffer
        for client_id, info in pairs(active_lsp_clients) do
            if info.server_name == server_name and info.host == host then
                vim.notify("Reusing existing LSP client " .. client_id .. " for server " .. server_key, vim.log.levels.INFO)
                
                -- Track this buffer for the server
                server_buffers[server_key][bufnr] = true
                
                -- Track this client for the buffer
                if not buffer_clients[bufnr] then
                    buffer_clients[bufnr] = {}
                end
                buffer_clients[bufnr][client_id] = true
                
                -- Attach the client to the buffer
                vim.lsp.buf_attach_client(bufnr, client_id)
                return client_id
            end
        end
    end
    
    local lspconfig = require('lspconfig')
    if not lspconfig then
        vim.notify("lspconfig module not found", vim.log.levels.ERROR)
        return
    end
    
    local lsp_config = lspconfig[server_name]
    if not lsp_config then
        vim.notify("LSP config not found for: " .. server_name .. ". Is the server installed?", vim.log.levels.ERROR)
        return
    end
    
    local lsp_cmd = lsp_config.document_config.default_config.cmd
    if not lsp_cmd then
        vim.notify("No cmd defined for server: " .. server_name, vim.log.levels.ERROR)
        return
    end
    vim.notify("LSP command: " .. vim.inspect(lsp_cmd), vim.log.levels.DEBUG)
    
    -- Extract just the binary name and arguments
    local binary_name = lsp_cmd[1]:match("([^/\\]+)$") or lsp_cmd[1] -- Get the basename, fallback to full name
    local lsp_args = { binary_name }
    
    for i = 2, #lsp_cmd do
        vim.notify("Adding LSP arg: " .. lsp_cmd[i], vim.log.levels.DEBUG)
        table.insert(lsp_args, lsp_cmd[i])
    end
    
    local proxy_path = get_script_dir() .. "/proxy.py"
    if not vim.fn.filereadable(proxy_path) then
        vim.notify("Proxy script not found at: " .. proxy_path, vim.log.levels.ERROR)
        return
    end
    
    local cmd = { "python3", "-u", proxy_path, host, protocol }
    vim.list_extend(cmd, lsp_args)
    
    vim.notify("Starting LSP with cmd: " .. table.concat(cmd, " "), vim.log.levels.INFO)
    
    -- Create a server key and initialize tracking if needed
    if not server_buffers[server_key] then
        server_buffers[server_key] = {}
    end
    
    -- Add custom handlers to ensure proper lifecycle management
    local client_id = vim.lsp.start({
        name = "remote_" .. server_name,
        cmd = cmd,
        root_dir = root_dir,
        capabilities = capabilities,
        on_attach = function(client, attached_bufnr)
            on_attach(client, attached_bufnr)
            vim.notify("LSP client started successfully", vim.log.levels.INFO)
            
            -- Track this client
            track_client(client.id, server_name, attached_bufnr, host, protocol)
            
            -- Add buffer closure detection with full error handling
            local autocmd_group = vim.api.nvim_create_augroup("RemoteLspBuffer" .. attached_bufnr, { clear = true })
            
            vim.api.nvim_create_autocmd({"BufDelete", "BufWipeout"}, {
                group = autocmd_group,
                buffer = attached_bufnr,
                callback = function()
                    vim.notify("Buffer " .. attached_bufnr .. " closed, checking if LSP server should be stopped", vim.log.levels.INFO)
                    -- Use helper with built-in error handling
                    safe_untrack_buffer(attached_bufnr)
                end,
            })
        end,
        on_exit = function(code, signal, client_id)
            vim.notify("LSP client exited: code=" .. code .. ", signal=" .. signal, vim.log.levels.INFO)
            untrack_client(client_id)
        end,
        flags = {
            debounce_text_changes = 150,
            allow_incremental_sync = true,
        },
        filetypes = { filetype },
    })
    
    if client_id ~= nil then
        vim.notify("LSP client " .. client_id .. " initiated for buffer " .. bufnr, vim.log.levels.INFO)
        vim.lsp.buf_attach_client(bufnr, client_id)
        return client_id
    else
        vim.notify("Failed to start LSP client for " .. server_name, vim.log.levels.ERROR)
        return nil
    end
end

-- User command to set custom root directory and restart LSP
vim.api.nvim_create_user_command(
    "SetRemoteLspRoot",
    function(opts)
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            
            local protocol = get_protocol(bufname)
            if not protocol then
                vim.notify("Not a remote buffer", vim.log.levels.ERROR)
                return
            end

            local host, _, _ = parse_remote_buffer(bufname)
            if not host then
                vim.notify("Invalid remote URL: " .. bufname, vim.log.levels.ERROR)
                return
            end

            local user_input = opts.args
            if user_input == "" then
                custom_root_dir = nil
                vim.notify("Reset remote LSP root to buffer-derived directory", vim.log.levels.INFO)
            else
                if not user_input:match("^/") then
                    local current_dir = vim.fn.fnamemodify(bufname:match("^" .. protocol .. "://[^/]+/(.+)$"), ":h")
                    user_input = current_dir .. "/" .. user_input
                end
                custom_root_dir = protocol .. "://" .. host .. "/" .. vim.fn.substitute(user_input, "//+", "/", "g")
                vim.notify("Set remote LSP root to " .. custom_root_dir, vim.log.levels.INFO)
            end

            M.start_remote_lsp(bufnr)
        end)
        
        if not ok then
            vim.notify("Error setting root: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
    {
        nargs = "?",
        desc = "Set the root directory for the remote LSP server (e.g., '/path/to/project')",
    }
)

-- Add auto commands for remote files with proper timing
local autocmd_group = vim.api.nvim_create_augroup("RemoteLSP", { clear = true })

-- Update autocmd to use multiple events for better reliability
vim.api.nvim_create_autocmd({"BufReadPost", "FileType"}, {
    pattern = {"scp://*", "rsync://*"},
    group = autocmd_group,
    callback = function()
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            
            -- Delay the LSP startup to ensure filetype is properly detected
            vim.defer_fn(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end
                
                local filetype = vim.bo[bufnr].filetype
                vim.notify("Autocmd triggered for " .. bufname .. " with filetype " .. (filetype or "nil"), vim.log.levels.DEBUG)
                
                if filetype and filetype ~= "" then
                    M.start_remote_lsp(bufnr)
                end
            end, 100) -- Small delay to ensure filetype detection has completed
        end)
        
        if not ok then
            vim.notify("Error in autocmd: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
})

-- Add cleanup on VimLeave
vim.api.nvim_create_autocmd("VimLeave", {
    group = autocmd_group,
    callback = function()
        local ok, err = pcall(function()
            vim.notify("VimLeave: Stopping all remote LSP clients", vim.log.levels.INFO)
            -- Force kill on exit
            M.stop_all_clients(true)
        end)
        
        if not ok then
            vim.notify("Error in VimLeave: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
})

-- Add a command to manually start the LSP for the current buffer
vim.api.nvim_create_user_command(
    "RemoteLspStart",
    function()
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()
            M.start_remote_lsp(bufnr)
        end)
        
        if not ok then
            vim.notify("Error starting LSP: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
    {
        desc = "Manually start the remote LSP server for the current buffer",
    }
)

-- Add a command to stop all remote LSP clients
vim.api.nvim_create_user_command(
    "RemoteLspStop",
    function()
        local ok, err = pcall(function()
            M.stop_all_clients(true)
        end)
        
        if not ok then
            vim.notify("Error stopping LSP: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
    {
        desc = "Stop all remote LSP servers and kill remote processes",
    }
)

-- Add a command to debug and print current server-buffer relationships
vim.api.nvim_create_user_command(
    "RemoteLspDebug",
    function()
        local ok, err = pcall(function()
            -- Print active clients
            vim.notify("Active LSP Clients:", vim.log.levels.INFO)
            for client_id, info in pairs(active_lsp_clients) do
                vim.notify(string.format("  Client %d: server=%s, buffer=%d, host=%s, protocol=%s",
                    client_id, info.server_name, info.bufnr, info.host, info.protocol or "unknown"), vim.log.levels.INFO)
            end

            -- Print server-buffer relationships
            vim.notify("Server-Buffer Relationships:", vim.log.levels.INFO)
            for server_key, buffers in pairs(server_buffers) do
                local buffer_list = vim.tbl_keys(buffers)
                vim.notify(string.format("  Server %s: buffers=%s",
                    server_key, table.concat(buffer_list, ", ")), vim.log.levels.INFO)
            end

            -- Print buffer-client relationships
            vim.notify("Buffer-Client Relationships:", vim.log.levels.INFO)
            for bufnr, clients in pairs(buffer_clients) do
                local client_list = vim.tbl_keys(clients)
                vim.notify(string.format("  Buffer %d: clients=%s",
                    bufnr, table.concat(client_list, ", ")), vim.log.levels.INFO)
            end

            -- Print buffer filetype info
            vim.notify("Buffer Filetype Info:", vim.log.levels.INFO)
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    local bufname = vim.api.nvim_buf_get_name(bufnr)
                    if get_protocol(bufname) then
                        local filetype = vim.bo[bufnr].filetype
                        vim.notify(string.format("  Buffer %d: name=%s, filetype=%s",
                            bufnr, bufname, filetype or "nil"), vim.log.levels.INFO)
                    end
                end
            end
        end)

        if not ok then
            vim.notify("Error in debug command: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
    {
        desc = "Print debug information about remote LSP clients and buffer relationships",
    }
)

M.async_write = async_write

return M
