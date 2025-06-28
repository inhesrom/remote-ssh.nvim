local M = {}

local config = require('remote-lsp.config')
local buffer = require('remote-lsp.buffer')
local utils = require('remote-lsp.utils')
local log = require('logging').log

-- Tracking structures
-- Map client_id to info about the client
M.active_lsp_clients = {}

-- Function to start LSP client for a remote buffer
function M.start_remote_lsp(bufnr)
    log("Attempting to start remote LSP for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Invalid buffer: " .. bufnr, vim.log.levels.ERROR, false, config.config)
        return
    end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    log("Buffer name: " .. bufname, vim.log.levels.DEBUG, false, config.config)

    local protocol = utils.get_protocol(bufname)
    if not protocol then
        log("Not a remote URL: " .. bufname, vim.log.levels.DEBUG, false, config.config)
        return
    end

    local host, path, _ = utils.parse_remote_buffer(bufname)
    if not host or not path then
        log("Invalid remote URL: " .. bufname, vim.log.levels.ERROR, false, config.config)
        return
    end

    -- FIX: Remove leading slashes from path to prevent double slashes in URIs
    path = path:gsub("^/+", "")

    log("Host: " .. host .. ", Path: " .. path .. ", Protocol: " .. protocol, vim.log.levels.DEBUG, false, config.config)

    -- Determine filetype
    local filetype = vim.bo[bufnr].filetype
    log("Initial filetype: " .. (filetype or "nil"), vim.log.levels.DEBUG, false, config.config)

    if not filetype or filetype == "" then
        local basename = vim.fn.fnamemodify(bufname, ":t")

        -- Check for special filenames first
        if basename == "CMakeLists.txt" then
            filetype = "cmake"
        else
            -- Fall back to extension-based detection
            local ext = vim.fn.fnamemodify(bufname, ":e")
            filetype = config.ext_to_ft[ext] or ""
        end

        if filetype ~= "" then
            vim.bo[bufnr].filetype = filetype
            log("Set filetype to " .. filetype .. " for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
        else
            log("No filetype detected or inferred for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
            return
        end
    end

    -- Determine server name based on filetype
    local server_name = config.get_server_for_filetype(filetype)
    if not server_name then
        log("No LSP server for filetype: " .. filetype, vim.log.levels.WARN, false, config.config)
        return
    end

    -- For Python, check if we should prefer a specific server
    if filetype == "python" and server_name == "pyright" then
        -- Check if other Python servers are available and configured
        local available_python_servers = {}
        for name, _ in pairs(config.default_server_configs) do
            if name:match("python") or name == "pylsp" or name == "jedi_language_server" then
                table.insert(available_python_servers, name)
            end
        end

        -- If user has specified a preference, use it
        if config.server_configs[filetype] and config.server_configs[filetype].server_name then
            server_name = config.server_configs[filetype].server_name
        end
    end

    log("Server name: " .. server_name, vim.log.levels.DEBUG, false, config.config)

    -- Get server configuration
    local server_config = config.server_configs[filetype] or {}
    local root_patterns = server_config.root_patterns

    if config.default_server_configs[server_name] then
        root_patterns = root_patterns or config.default_server_configs[server_name].root_patterns
    end

    -- Determine root directory using pattern-based search
    local root_dir
    if config.custom_root_dir then
        root_dir = config.custom_root_dir
    else
        -- Use the improved project root finder that searches for patterns like Cargo.toml
        local project_root = utils.find_project_root(host, path, root_patterns)
        
        -- Convert to local path format for LSP client initialization
        -- The proxy will handle translating remote URIs to local file URIs
        local clean_dir = project_root:gsub("^/+", "")  -- Remove leading slashes
        if clean_dir == "" then
            clean_dir = "."  -- Handle root directory case
        end
        root_dir = "/" .. clean_dir
    end
    log("Project root dir: " .. root_dir, vim.log.levels.DEBUG, false, config.config)

    -- Check if this server is already running for this host
    local server_key = utils.get_server_key(server_name, host)
    if buffer.server_buffers[server_key] then
        -- Find an existing client for this server and attach it to this buffer
        for client_id, info in pairs(M.active_lsp_clients) do
            if info.server_name == server_name and info.host == host then
                log("Reusing existing LSP client " .. client_id .. " for server " .. server_key, vim.log.levels.INFO, true, config.config)

                -- Track this buffer for the server
                buffer.server_buffers[server_key][bufnr] = true

                -- Track this client for the buffer
                if not buffer.buffer_clients[bufnr] then
                    buffer.buffer_clients[bufnr] = {}
                end
                buffer.buffer_clients[bufnr][client_id] = true

                -- Attach the client to the buffer
                vim.lsp.buf_attach_client(bufnr, client_id)
                return client_id
            end
        end
    end

    local lspconfig = require('lspconfig')
    if not lspconfig then
        log("lspconfig module not found", vim.log.levels.ERROR, false, config.config)
        return
    end

    local lsp_config = lspconfig[server_name]
    if not lsp_config then
        log("LSP config not found for: " .. server_name .. ". Is the server installed?", vim.log.levels.ERROR, true, config.config)
        return
    end

    local lsp_cmd = lsp_config.document_config.default_config.cmd
    if not lsp_cmd then
        log("No cmd defined for server: " .. server_name, vim.log.levels.ERROR, true, config.config)
        return
    end
    log("LSP command: " .. vim.inspect(lsp_cmd), vim.log.levels.DEBUG, false, config.config)

    -- Handle complex LSP commands properly
    local lsp_args = {}

    -- For npm-based servers and complex commands, preserve the full command structure
    if lsp_cmd[1]:match("node") or lsp_cmd[1]:match("npm") or lsp_cmd[1]:match("npx") then
        -- For Node.js based servers, use the full command as-is
        for i = 1, #lsp_cmd do
            table.insert(lsp_args, lsp_cmd[i])
        end
    else
        -- For other servers, extract just the binary name but preserve all arguments
        local binary_name = lsp_cmd[1]:match("([^/\\]+)$") or lsp_cmd[1]
        table.insert(lsp_args, binary_name)

        for i = 2, #lsp_cmd do
            log("Adding LSP arg: " .. lsp_cmd[i], vim.log.levels.DEBUG, false, config.config)
            table.insert(lsp_args, lsp_cmd[i])
        end
    end

    -- Add server-specific command arguments if provided
    if server_config.cmd_args then
        for _, arg in ipairs(server_config.cmd_args) do
            table.insert(lsp_args, arg)
        end
    end

    local proxy_path = utils.get_script_dir() .. "/proxy.py"
    if not vim.fn.filereadable(proxy_path) then
        log("Proxy script not found at: " .. proxy_path, vim.log.levels.ERROR, true)
        return
    end

    local cmd = { "python3", "-u", proxy_path, host, protocol }
    vim.list_extend(cmd, lsp_args)
    lsp_args = cmd


    log("Starting LSP with cmd: " .. table.concat(lsp_args, " "), vim.log.levels.DEBUG, false, config.config)

    -- Create a server key and initialize tracking if needed
    if not buffer.server_buffers[server_key] then
        buffer.server_buffers[server_key] = {}
    end

    -- Get initialization options
    local init_options = {}
    if server_config.init_options then
        init_options = server_config.init_options
    elseif config.default_server_configs[server_name] and config.default_server_configs[server_name].init_options then
        init_options = config.default_server_configs[server_name].init_options
    end

    -- Add custom handlers to ensure proper lifecycle management
    local client_id = vim.lsp.start({
        name = "remote_" .. server_name,
        cmd = lsp_args,
        root_dir = root_dir,
        capabilities = config.capabilities,
        init_options = init_options,
        on_attach = function(client, attached_bufnr)
            config.on_attach(client, attached_bufnr)
            log("LSP client started successfully", vim.log.levels.INFO, true)

            -- Use our improved buffer tracking
            buffer.setup_buffer_tracking(client, attached_bufnr, server_name, host, protocol)
        end,
        on_exit = function(code, signal, client_id)
            vim.schedule(function()
                log("LSP client exited: code=" .. code .. ", signal=" .. signal, vim.log.levels.DEBUG, false, config.config)
                buffer.untrack_client(client_id)
            end)
        end,
        flags = {
            debounce_text_changes = 150,
            allow_incremental_sync = true,
        },
        filetypes = { filetype },
    })

    if client_id ~= nil then
        log("LSP client " .. client_id .. " initiated for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
        vim.lsp.buf_attach_client(bufnr, client_id)
        return client_id
    else
        log("Failed to start LSP client for " .. server_name, vim.log.levels.ERROR, true)
        return nil
    end
end

-- Function to stop an LSP client - optimized to use scheduling for potentially slow operations
function M.shutdown_client(client_id, force_kill)
    -- Add error handling
    local ok, err = pcall(function()
        local client_info = M.active_lsp_clients[client_id]
        if not client_info then
            log("Client " .. client_id .. " not found in active clients", vim.log.levels.WARN, false, config.config)
            return
        end

        log("Shutting down client " .. client_id, vim.log.levels.DEBUG, false, config.config)

        -- Send proper shutdown sequence to the LSP server
        local client = vim.lsp.get_client_by_id(client_id)
        if client and not client.is_stopped() then
            -- First try a graceful shutdown
            log("Sending shutdown request to LSP server", vim.log.levels.DEBUG, false, config.config)

            -- Get client's RPC object if available
            if client.rpc then
                -- Attempt a clean shutdown sequence asynchronously
                vim.schedule(function()
                    client.rpc.notify("shutdown")
                    vim.defer_fn(function()
                        client.rpc.notify("exit")
                    end, 100)
                end)
            end
        end

        -- Schedule the stop operation
        vim.schedule(function()
            -- Then stop the client
            vim.lsp.stop_client(client_id, true)

            -- Only force kill if this server isn't used by other buffers
            if force_kill and client_info.host and client_info.server_name then
                local server_key = utils.get_server_key(client_info.server_name, client_info.host)

                -- Check if any buffers still use this server
                if not buffer.server_buffers[server_key] or vim.tbl_isempty(buffer.server_buffers[server_key]) then
                    -- No buffers using this server, kill the process
                    log("No buffers using server " .. server_key .. ", killing remote process", vim.log.levels.DEBUG, false, config.config)
                    local cmd = string.format("ssh %s 'pkill -f %s'", client_info.host, client_info.server_name)
                    vim.fn.jobstart(cmd, {
                        on_exit = function(_, exit_code)
                            if exit_code == 0 then
                                log("Successfully killed remote LSP process for " .. server_key, vim.log.levels.DEBUG, false, config.config)
                            else
                                log("Failed to kill remote LSP process for " .. server_key .. " (or none found)", vim.log.levels.DEBUG, false, config.config)
                            end
                        end
                    })
                else
                    log("Not killing remote process for " .. server_key .. " as it's still used by other buffers", vim.log.levels.DEBUG, false, config.config)
                end
            end

            buffer.untrack_client(client_id)
        end)
    end)

    if not ok then
        log("Error shutting down client: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
    end
end

-- Function to stop all active remote LSP clients
function M.stop_all_clients(force_kill)
    force_kill = force_kill or false

    -- Keep track of server_keys we've already processed
    local processed_servers = {}
    local clients_to_stop = {}

    -- First collect all clients we need to stop (without modifying the table while iterating)
    for client_id, info in pairs(M.active_lsp_clients) do
        local server_key = utils.get_server_key(info.server_name, info.host)

        -- Only process each server once
        if not processed_servers[server_key] then
            processed_servers[server_key] = true
            table.insert(clients_to_stop, client_id)
        end
    end

    -- Then stop each client (scheduled to avoid blocking)
    vim.schedule(function()
        for _, client_id in ipairs(clients_to_stop) do
            local info = M.active_lsp_clients[client_id]
            if info then
                local server_key = utils.get_server_key(info.server_name, info.host)
                log("Stopping LSP client for server " .. server_key, vim.log.levels.DEBUG, false, config.config)
                M.shutdown_client(client_id, force_kill)
            end
        end

        -- Reset all tracking structures after a delay to ensure everything is cleaned up
        vim.defer_fn(function()
            M.active_lsp_clients = {}
            buffer.server_buffers = {}
            buffer.buffer_clients = {}
        end, 500)
    end)
end

return M
