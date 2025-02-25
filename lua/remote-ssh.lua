local M = {}

-- Global variables set by setup
local on_attach
local capabilities
local filetype_to_server
local custom_root_dir = nil
local active_lsp_clients = {}

function M.setup(opts)
    -- Add verbose logging for setup process
    vim.notify("Setting up remote-ssh with options: " .. vim.inspect(opts), vim.log.levels.DEBUG)
    
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
end

-- Function to get the directory of the current Lua script
local function get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
end

-- Function to track active remote LSP clients with host information
local function track_client(client_id, bufnr, host)
    active_lsp_clients[client_id] = {
        bufnr = bufnr,
        host = host,
        timestamp = os.time()
    }
end

-- Function to untrack a client
local function untrack_client(client_id)
    active_lsp_clients[client_id] = nil
end

-- Function to cleanly shut down an LSP client and kill the remote process
local function shutdown_client(client_id, force_kill)
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
            local shutdown_ok, shutdown_err = pcall(function()
                -- Send explicit shutdown request
                client.rpc.notify("shutdown")
                vim.wait(100)  -- Give the server a moment to process
                client.rpc.notify("exit")
                vim.wait(100)  -- Give the server a moment to exit
            end)

            if not shutdown_ok then
                vim.notify("Shutdown request failed: " .. tostring(shutdown_err), vim.log.levels.WARN)
            end
        end
    end

    -- Then stop the client
    vim.lsp.stop_client(client_id, true)

    -- Force kill the remote process if requested
    if force_kill and client_info.host then
        vim.notify("Force killing any remaining LSP processes on " .. client_info.host, vim.log.levels.INFO)
        local binary_name = filetype_to_server[vim.bo[client_info.bufnr].filetype]
        local cmd = string.format("ssh %s 'pkill -f %s'", client_info.host, binary_name)
        vim.fn.jobstart(cmd, {
            on_exit = function(_, exit_code)
                if exit_code == 0 then
                    vim.notify("Successfully killed remote LSP processes", vim.log.levels.INFO)
                else
                    vim.notify("Failed to kill remote LSP processes (or none found)", vim.log.levels.WARN)
                end
            end
        })
    end

    untrack_client(client_id)
end

-- Function to stop all active remote LSP clients
function M.stop_all_clients(force_kill)
    force_kill = force_kill or false

    for client_id, _ in pairs(active_lsp_clients) do
        vim.notify("Stopping LSP client " .. client_id, vim.log.levels.INFO)
        shutdown_client(client_id, force_kill)
    end

    -- Double-check all clients are untracked
    active_lsp_clients = {}
end

-- Function to start LSP client for a netrw buffer
function M.start_remote_lsp(bufnr)
    vim.notify("Attempting to start remote LSP for buffer " .. bufnr, vim.log.levels.INFO)

    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return
    end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    vim.notify("Buffer name: " .. bufname, vim.log.levels.DEBUG)

    if not bufname:match("^scp://") then
        vim.notify("Not an scp URL: " .. bufname, vim.log.levels.WARN)
        return
    end

    local host, path = bufname:match("^scp://([^/]+)/(.+)$")
    if not host or not path then
        vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
        return
    end
    vim.notify("Host: " .. host .. ", Path: " .. path, vim.log.levels.DEBUG)

    local root_dir
    if custom_root_dir then
        root_dir = custom_root_dir
    else
        local dir = vim.fn.fnamemodify(path, ":h")
        root_dir = "scp://" .. host .. "/" .. dir
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

    local cmd = { "python3", "-u", proxy_path, host }
    vim.list_extend(cmd, lsp_args)

    vim.notify("Starting LSP with cmd: " .. table.concat(cmd, " "), vim.log.levels.INFO)

    -- Stop any existing clients for this buffer
    for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr })) do
        if client.name == "remote_" .. server_name then
            vim.notify("Stopping existing client " .. client.id, vim.log.levels.DEBUG)
            shutdown_client(client.id, true)
        end
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

            -- Add multiple buffer close events to ensure cleanup
            local autocmd_group = vim.api.nvim_create_augroup("RemoteLspClient" .. client.id, { clear = true })

            -- Watch for buffer closure events
            vim.api.nvim_create_autocmd({"BufWipeout", "BufDelete"}, {
                group = autocmd_group,
                buffer = attached_bufnr,
                callback = function()
                    vim.notify("Buffer closed, stopping LSP client: " .. client.id, vim.log.levels.INFO)
                    if client.is_stopped() then return end
                    shutdown_client(client.id, true)
                end
            })

            -- Also watch for file type changes
            vim.api.nvim_create_autocmd("FileType", {
                group = autocmd_group,
                buffer = attached_bufnr,
                callback = function()
                    vim.notify("Filetype changed, checking if LSP should be stopped: " .. client.id, vim.log.levels.DEBUG)
                    local ft = vim.bo[attached_bufnr].filetype
                    local server = filetype_to_server[ft]
                    if not server or server ~= server_name:gsub("^remote_", "") then
                        vim.notify("Filetype no longer matches LSP, stopping client: " .. client.id, vim.log.levels.INFO)
                        shutdown_client(client.id, true)
                    end
                end
            })
        end,
        on_exit = function(code, signal, client_id)
            vim.notify("LSP client exited: code=" .. code .. ", signal=" .. signal, vim.log.levels.INFO)
            untrack_client(client_id)
        end,
        flags = {
            debounce_text_changes = 150,
            allow_incremental_sync = true,
            exit_timeout = 3000, -- Wait up to 3 seconds for a clean shutdown
        },
        filetypes = { filetype },
    })

    if client_id ~= nil then
        vim.notify("LSP client " .. client_id .. " initiated for buffer " .. bufnr, vim.log.levels.INFO)
        track_client(client_id, bufnr, host)
        vim.lsp.buf_attach_client(bufnr, client_id)
    else
        vim.notify("Failed to start LSP client for " .. server_name, vim.log.levels.ERROR)
    end

    return client_id
end

-- User command to set custom root directory and restart LSP
vim.api.nvim_create_user_command(
    "SetRemoteLspRoot",
    function(opts)
        local bufnr = vim.api.nvim_get_current_buf()
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if not bufname:match("^scp://") then
            vim.notify("Not an scp:// buffer", vim.log.levels.ERROR)
            return
        end

        local host = bufname:match("^scp://([^/]+)/(.+)$")
        if not host then
            vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
            return
        end

        local user_input = opts.args
        if user_input == "" then
            custom_root_dir = nil
            vim.notify("Reset remote LSP root to buffer-derived directory", vim.log.levels.INFO)
        else
            if not user_input:match("^/") then
                local current_dir = vim.fn.fnamemodify(bufname:match("^scp://[^/]+/(.+)$"), ":h")
                user_input = current_dir .. "/" .. user_input
            end
            custom_root_dir = "scp://" .. host .. "/" .. vim.fn.substitute(user_input, "//+", "/", "g")
            vim.notify("Set remote LSP root to " .. custom_root_dir, vim.log.levels.INFO)
        end

        M.start_remote_lsp(bufnr)
    end,
    {
        nargs = "?",
        desc = "Set the root directory for the remote LSP server (e.g., '/path/to/project')",
    }
)

-- Add auto commands for SCP files with proper timing
local autocmd_group = vim.api.nvim_create_augroup("RemoteLSP", { clear = true })

-- Update autocmd to use multiple events for better reliability
vim.api.nvim_create_autocmd({"BufReadPost", "FileType"}, {
    pattern = "scp://*",
    group = autocmd_group,
    callback = function()
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
    end,
})

-- Add cleanup on VimLeave
vim.api.nvim_create_autocmd("VimLeave", {
    group = autocmd_group,
    callback = function()
        vim.notify("VimLeave: Stopping all remote LSP clients", vim.log.levels.INFO)
        -- Force kill on exit
        M.stop_all_clients(true)
    end,
})

-- Add an autocmd to clean up orphaned processes periodically
vim.api.nvim_create_autocmd("CursorHold", {
    group = autocmd_group,
    callback = function()
        -- Every 30 seconds, check for any clients that have lost their buffer
        local current_time = os.time()

        for client_id, info in pairs(active_lsp_clients) do
            if info.timestamp and current_time - info.timestamp > 3600 then -- 1 hour timeout
                vim.notify("LSP client " .. client_id .. " has been active for over an hour, checking if buffer still exists", vim.log.levels.DEBUG)

                if not vim.api.nvim_buf_is_valid(info.bufnr) then
                    vim.notify("Buffer " .. info.bufnr .. " no longer exists, stopping LSP client " .. client_id, vim.log.levels.INFO)
                    shutdown_client(client_id, true)
                else
                    -- Update timestamp to avoid checking too often
                    active_lsp_clients[client_id].timestamp = current_time
                end
            end
        end
    end,
})

-- Add a command to manually start the LSP for the current buffer
vim.api.nvim_create_user_command(
    "StartRemoteLsp",
    function()
        local bufnr = vim.api.nvim_get_current_buf()
        M.start_remote_lsp(bufnr)
    end,
    {
        desc = "Manually start the remote LSP server for the current buffer",
    }
)

-- Add a command to stop all remote LSP clients
vim.api.nvim_create_user_command(
    "StopRemoteLsp",
    function()
        M.stop_all_clients(true)
    end,
    {
        desc = "Stop all remote LSP servers and kill remote processes",
    }
)

-- Add a command to check for orphaned LSP processes
vim.api.nvim_create_user_command(
    "CleanupRemoteLsp",
    function(opts)
        local force = opts.bang
        
        -- Get all active clients in buffers
        local current_buffers = vim.api.nvim_list_bufs()
        for client_id, info in pairs(active_lsp_clients) do
            local valid_buffer = false
            for _, bufnr in ipairs(current_buffers) do
                if bufnr == info.bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                    valid_buffer = true
                    break
                end
            end
            
            if not valid_buffer then
                vim.notify("Found orphaned LSP client " .. client_id .. " for invalid buffer " .. info.bufnr, vim.log.levels.INFO)
                shutdown_client(client_id, force)
            end
        end
        
        -- For each unique host, check for orphaned processes
        local hosts = {}
        for _, info in pairs(active_lsp_clients) do
            if info.host then
                hosts[info.host] = true
            end
        end
        
        for host, _ in pairs(hosts) do
            vim.notify("Checking for orphaned LSP processes on " .. host, vim.log.levels.INFO)
            
            -- Get a list of all possible LSP server processes
            local server_names = {}
            for _, server in pairs(filetype_to_server) do
                server_names[server] = true
            end
            
            -- Create a grep pattern to find potentially orphaned processes
            local grep_pattern = table.concat(vim.tbl_keys(server_names), "\\|")
            if grep_pattern == "" then
                grep_pattern = "clangd\\|pyright\\|rust-analyzer"  -- Default servers to check for
            end
            
            -- First check if any of these processes are running too long
            local cmd = string.format("ssh %s 'ps -eo pid,etime,args | grep -E \"(%s)\" | grep -v grep'", host, grep_pattern)
            
            local check_job_id = vim.fn.jobstart(cmd, {
                on_stdout = function(_, data)
                    if not data then return end
                    
                    for _, line in ipairs(data) do
                        if line and line ~= "" then
                            -- Process line to extract PID, elapsed time, and command
                            local pid, etime, args = line:match("^%s*(%d+)%s+([^%s]+)%s+(.+)$")
                            
                            if pid and etime and args then
                                -- Check if the process has been running for too long (e.g., > 2 hours)
                                local days, hrs, mins, secs = etime:match("(%d+)-(%d+):(%d+):(%d+)")
                                
                                if not days then
                                    hrs, mins, secs = etime:match("(%d+):(%d+):(%d+)")
                                    
                                    if not hrs then
                                        mins, secs = etime:match("(%d+):(%d+)")
                                        if mins then
                                            hrs = 0
                                        end
                                    end
                                    
                                    days = 0
                                end
                                
                                days = tonumber(days or 0)
                                hrs = tonumber(hrs or 0)
                                mins = tonumber(mins or 0)
                                
                                -- If process running > 2 hours and force is true, kill it
                                if force and (days > 0 or hrs > 2) then
                                    vim.notify("Killing long-running LSP process: PID=" .. pid .. " TIME=" .. etime .. " CMD=" .. args, vim.log.levels.INFO)
                                    
                                    -- Kill the process
                                    local kill_cmd = string.format("ssh %s 'kill -9 %s'", host, pid)
                                    vim.fn.jobstart(kill_cmd)
                                elseif days > 0 or hrs > 2 then
                                    vim.notify("Found long-running LSP process: PID=" .. pid .. " TIME=" .. etime .. " CMD=" .. args .. " (use :CleanupRemoteLsp! to force kill)", vim.log.levels.WARN)
                                end
                            end
                        end
                    end
                end,
                on_exit = function(_, exit_code)
                    if exit_code ~= 0 and exit_code ~= 1 then  -- 1 means no matches found
                        vim.notify("Error checking for orphaned processes: " .. exit_code, vim.log.levels.ERROR)
                    elseif exit_code == 0 then
                        vim.notify("Orphaned process check completed", vim.log.levels.INFO)
                    end
                end
            })
            
            if check_job_id <= 0 then
                vim.notify("Failed to start job to check for orphaned processes", vim.log.levels.ERROR)
            end
        end
    end,
    {
        desc = "Check for orphaned LSP processes and clean them up (! to force kill)",
        bang = true,
    }
)

return M
