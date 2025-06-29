local M = {}

local config = require('remote-lsp.config')
local client = require('remote-lsp.client')
local buffer = require('remote-lsp.buffer')
local utils = require('remote-lsp.utils')
local log = require('logging').log

-- Register all user commands
function M.register()
    -- User command to set custom root directory and restart LSP
    vim.api.nvim_create_user_command(
        "RemoteLspSetRoot",
        function(opts)
            local ok, err = pcall(function()
                local bufnr = vim.api.nvim_get_current_buf()
                local bufname = vim.api.nvim_buf_get_name(bufnr)

                local protocol = utils.get_protocol(bufname)
                if not protocol then
                    log("Not a remote buffer", vim.log.levels.ERROR, true)
                    return
                end

                local host, _, _ = utils.parse_remote_buffer(bufname)
                if not host then
                    log("Invalid remote URL: " .. bufname, vim.log.levels.ERROR, true)
                    return
                end

                local user_input = opts.args
                if user_input == "" then
                    config.custom_root_dir = nil
                    log("Reset remote LSP root to buffer-derived directory", vim.log.levels.INFO, true)
                else
                    if not user_input:match("^/") then
                        local current_dir = vim.fn.fnamemodify(bufname:match("^" .. protocol .. "://[^/]+/(.+)$"), ":h")
                        user_input = current_dir .. "/" .. user_input
                    end
                    config.custom_root_dir = protocol .. "://" .. host .. "/" .. vim.fn.substitute(user_input, "//+", "/", "g")
                    log("Set remote LSP root to " .. config.custom_root_dir, vim.log.levels.INFO, true)
                end

                -- Schedule LSP restart to avoid blocking
                vim.schedule(function()
                    client.start_remote_lsp(bufnr)
                end)
            end)

            if not ok then
                log("Error setting root: " .. tostring(err), vim.log.levels.ERROR, true)
            end
        end,
        {
            nargs = "?",
            desc = "Set the root directory for the remote LSP server (e.g., '/path/to/project')",
        }
    )

    -- Add a command to manually start the LSP for the current buffer
    vim.api.nvim_create_user_command(
        "RemoteLspStart",
        function()
            local ok, err = pcall(function()
                local bufnr = vim.api.nvim_get_current_buf()
                -- Schedule the LSP start to avoid UI blocking
                vim.schedule(function()
                    client.start_remote_lsp(bufnr)
                end)
            end)

            if not ok then
                log("Error starting LSP: " .. tostring(err), vim.log.levels.ERROR, true)
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
                client.stop_all_clients(true)
            end)

            if not ok then
                log("Error stopping LSP: " .. tostring(err), vim.log.levels.ERROR, true)
            end
        end,
        {
            desc = "Stop all remote LSP servers and kill remote processes",
        }
    )

    -- Add a command to restart LSP safely
    vim.api.nvim_create_user_command(
        "RemoteLspRestart",
        function()
            local ok, err = pcall(function()
                local bufnr = vim.api.nvim_get_current_buf()

                -- Get current clients for this buffer
                local clients = buffer.buffer_clients[bufnr] or {}
                local client_ids = vim.tbl_keys(clients)

                if #client_ids == 0 then
                    log("No active LSP clients for this buffer", vim.log.levels.WARN, true)
                    return
                end

                -- Shut down existing clients
                for _, client_id in ipairs(client_ids) do
                    client.shutdown_client(client_id, false)
                end

                -- Clear tracking for this buffer
                buffer.buffer_clients[bufnr] = {}

                -- Wait a moment then restart
                vim.defer_fn(function()
                    client.start_remote_lsp(bufnr)
                end, 1000)

                log("Restarting LSP for current buffer", vim.log.levels.INFO, true)
            end)

            if not ok then
                log("Error restarting LSP: " .. tostring(err), vim.log.levels.ERROR, true)
            end
        end,
        {
            desc = "Restart LSP server for the current buffer",
        }
    )

    -- Add a command to list available language servers
    vim.api.nvim_create_user_command(
        "RemoteLspServers",
        function()
            local ok, err = pcall(function()
                local lspconfig = require('lspconfig')
                local available_servers = {}

                -- Get list of configured servers
                for server_name, _ in pairs(config.default_server_configs) do
                    if lspconfig[server_name] then
                        table.insert(available_servers, server_name)
                    end
                end

                -- Add user-configured servers that aren't in default configs
                for _, config_item in pairs(config.server_configs) do
                    if type(config_item) == "table" and config_item.server_name and not vim.tbl_contains(available_servers, config_item.server_name) then
                        if lspconfig[config_item.server_name] then
                            table.insert(available_servers, config_item.server_name)
                        end
                    end
                end

                table.sort(available_servers)

                log("Available Remote LSP Servers:", vim.log.levels.INFO, true)
                for _, server_name in ipairs(available_servers) do
                    local filetypes = {}

                    -- Find filetypes for this server
                    if config.default_server_configs[server_name] and config.default_server_configs[server_name].filetypes then
                        filetypes = config.default_server_configs[server_name].filetypes
                    end

                    -- Also check user configs
                    for ft, config_item in pairs(config.server_configs) do
                        if type(config_item) == "table" and config_item.server_name == server_name then
                            table.insert(filetypes, ft)
                        elseif config_item == server_name then
                            table.insert(filetypes, ft)
                        end
                    end

                    log(string.format("  %s: %s", server_name, table.concat(filetypes, ", ")), vim.log.levels.INFO, true)
                end
            end)

            if not ok then
                log("Error listing servers: " .. tostring(err), vim.log.levels.ERROR, true)
            end
        end,
        {
            desc = "List available remote LSP servers and their filetypes",
        }
    )

    -- Add a command to debug and print current server-buffer relationships
    vim.api.nvim_create_user_command(
        "RemoteLspDebug",
        function()
            local ok, err = pcall(function()
                -- Print active clients
                log("Active LSP Clients:", vim.log.levels.INFO, true)
                for client_id, info in pairs(client.active_lsp_clients) do
                    log(string.format("  Client %d: server=%s, buffer=%d, host=%s, protocol=%s",
                        client_id, info.server_name, info.bufnr, info.host, info.protocol or "unknown"), vim.log.levels.INFO, true)
                end

                -- Print server-buffer relationships
                log("Server-Buffer Relationships:", vim.log.levels.INFO, true)
                for server_key, buffers in pairs(buffer.server_buffers) do
                    local buffer_list = vim.tbl_keys(buffers)
                    log(string.format("  Server %s: buffers=%s",
                        server_key, table.concat(buffer_list, ", ")), vim.log.levels.INFO, true)
                end

                -- Print buffer-client relationships
                log("Buffer-Client Relationships:", vim.log.levels.INFO, true)
                for bufnr, clients in pairs(buffer.buffer_clients) do
                    local client_list = vim.tbl_keys(clients)
                    log(string.format("  Buffer %d: clients=%s",
                        bufnr, table.concat(client_list, ", ")), vim.log.levels.INFO, true)
                end

                -- Print buffer save status
                log("Buffers with active saves:", vim.log.levels.INFO, true)
                local save_buffers = {}
                for bufnr, _ in pairs(buffer.buffer_save_in_progress) do
                    table.insert(save_buffers, bufnr)
                end

                if #save_buffers > 0 then
                    log("  Buffers with active saves: " .. table.concat(save_buffers, ", "), vim.log.levels.INFO, true)
                else
                    log("  No buffers with active saves", vim.log.levels.INFO, true)
                end

                -- Print buffer filetype info
                log("Buffer Filetype Info:", vim.log.levels.INFO, true)
                for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        local bufname = vim.api.nvim_buf_get_name(bufnr)
                        if utils.get_protocol(bufname) then
                            local filetype = vim.bo[bufnr].filetype
                            log(string.format("  Buffer %d: name=%s, filetype=%s",
                                bufnr, bufname, filetype or "nil"), vim.log.levels.INFO, true)
                        end
                    end
                end

                -- Print capabilities info
                log("LSP Capabilities:", vim.log.levels.INFO, true)
                for client_id, _ in pairs(client.active_lsp_clients) do
                    local lsp_client = vim.lsp.get_client_by_id(client_id)
                    if lsp_client then
                        log(string.format("  Client %d (%s):", client_id, lsp_client.name or "unknown"), vim.log.levels.INFO, true)
                        log(string.format("    Root directory: %s", lsp_client.config.root_dir or "not set"), vim.log.levels.INFO, true)

                        -- Check for key capabilities
                        local caps = lsp_client.server_capabilities
                        if caps then
                            local supports_didSave = caps.textDocumentSync and caps.textDocumentSync.save
                            local needs_content = supports_didSave and caps.textDocumentSync.save.includeText

                            log(string.format("    textDocumentSync: %s", caps.textDocumentSync and "yes" or "no"), vim.log.levels.INFO, true)
                            log(string.format("    supports didSave: %s", supports_didSave and "yes" or "no"), vim.log.levels.INFO, true)
                            log(string.format("    requires content on save: %s", needs_content and "yes" or "no"), vim.log.levels.INFO, true)
                            log(string.format("    hover provider: %s", caps.hoverProvider and "yes" or "no"), vim.log.levels.INFO, true)
                            log(string.format("    definition provider: %s", caps.definitionProvider and "yes" or "no"), vim.log.levels.INFO, true)
                            log(string.format("    workspace folders: %s", caps.workspace and caps.workspace.workspaceFolders and "yes" or "no"), vim.log.levels.INFO, true)
                        end
                    end
                end
            end)

            if not ok then
                log("Error in debug command: " .. tostring(err), vim.log.levels.ERROR, true)
            end
        end,
        {
            desc = "Print debug information about remote LSP clients and buffer relationships",
        }
    )

    -- Add command to check async write status
    vim.api.nvim_create_user_command(
        "RemoteFileStatus",
        function()
            require('async-remote-write').get_status()
        end,
        {
            desc = "Show status of remote file operations",
        }
    )

    -- Add command to help with LSP troubleshooting
    vim.api.nvim_create_user_command(
        "RemoteLspDebugTraffic",
        function(opts)
            local enable = opts.bang or false
            utils.debug_lsp_traffic(enable)
        end,
        {
            desc = "Enable/disable LSP traffic debugging (! to enable)",
            bang = true
        }
    )

    log("User commands registered", vim.log.levels.DEBUG, false, config.config)
end

return M
