local M = {}

local config = require('remote-lsp.config')
local utils = require('remote-lsp.utils')
local log = require('logging').log

-- Tracking structures
-- Map server_name+host to list of buffers using it
M.server_buffers = {}
-- Map bufnr to client_ids
M.buffer_clients = {}

-- Track buffer save operations to prevent LSP disconnection during save
M.buffer_save_in_progress = {}
M.buffer_save_timestamps = {}

-- Function to track client with server and buffer information
function M.track_client(client_id, server_name, bufnr, host, protocol)
    log("Tracking client " .. client_id .. " for server " .. server_name .. " on buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

    -- Get client module
    local client = require('remote-lsp.client')

    -- Track client info
    client.active_lsp_clients[client_id] = {
        server_name = server_name,
        bufnr = bufnr,
        host = host,
        protocol = protocol,
        timestamp = os.time()
    }

    -- Track which buffers use which server
    local server_key = utils.get_server_key(server_name, host)
    if not M.server_buffers[server_key] then
        M.server_buffers[server_key] = {}
    end
    M.server_buffers[server_key][bufnr] = true

    -- Track which clients are attached to which buffers
    if not M.buffer_clients[bufnr] then
        M.buffer_clients[bufnr] = {}
    end
    M.buffer_clients[bufnr][client_id] = true
end

-- Function to untrack a client
function M.untrack_client(client_id)
    -- Get client module
    local client = require('remote-lsp.client')

    local client_info = client.active_lsp_clients[client_id]
    if not client_info then return end

    -- Remove from server-buffer tracking
    if client_info.server_name and client_info.host then
        local server_key = utils.get_server_key(client_info.server_name, client_info.host)
        if M.server_buffers[server_key] and M.server_buffers[server_key][client_info.bufnr] then
            M.server_buffers[server_key][client_info.bufnr] = nil

            -- If no more buffers use this server, remove the server entry
            if vim.tbl_isempty(M.server_buffers[server_key]) then
                M.server_buffers[server_key] = nil
            end
        end
    end

    -- Remove from buffer-client tracking
    if client_info.bufnr and M.buffer_clients[client_info.bufnr] then
        M.buffer_clients[client_info.bufnr][client_id] = nil

        -- If no more clients for this buffer, remove the buffer entry
        if vim.tbl_isempty(M.buffer_clients[client_info.bufnr]) then
            M.buffer_clients[client_info.bufnr] = nil
        end
    end

    -- Remove the client info itself
    client.active_lsp_clients[client_id] = nil
end

-- Function to safely handle buffer untracking
function M.safe_untrack_buffer(bufnr)
    local ok, err = pcall(function()
        -- Check if a save is in progress for this buffer
        if M.buffer_save_in_progress[bufnr] then
            log("Save in progress for buffer " .. bufnr .. ", not untracking LSP", vim.log.levels.DEBUG, false, config.config)
            return
        end

        log("Untracking buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

        -- Get clients for this buffer
        local clients = M.buffer_clients[bufnr] or {}
        local client_ids = vim.tbl_keys(clients)

        -- Get client module
        local client_module = require('remote-lsp.client')

        -- For each client, check if we should shut it down
        for _, client_id in ipairs(client_ids) do
            local client_info = client_module.active_lsp_clients[client_id]
            if client_info then
                local server_key = utils.get_server_key(client_info.server_name, client_info.host)

                -- Untrack this buffer from the server
                if M.server_buffers[server_key] then
                    M.server_buffers[server_key][bufnr] = nil

                    -- Check if this was the last buffer using this server
                    if vim.tbl_isempty(M.server_buffers[server_key]) then
                        -- This was the last buffer, shut down the server
                        log("Last buffer using server " .. server_key .. " closed, shutting down client " .. client_id, vim.log.levels.DEBUG, false, config.config)
                        -- Schedule the shutdown to avoid blocking
                        vim.schedule(function()
                            client_module.shutdown_client(client_id, true)
                        end)
                    else
                        -- Other buffers still use this server, just untrack this buffer
                        log("Buffer " .. bufnr .. " closed but server " .. server_key .. " still has active buffers, keeping client " .. client_id, vim.log.levels.DEBUG, false, config.config)

                        -- Still untrack the client from this buffer specifically
                        if M.buffer_clients[bufnr] then
                            M.buffer_clients[bufnr][client_id] = nil
                        end
                    end
                end
            end
        end

        -- Finally remove the buffer from our tracking
        M.buffer_clients[bufnr] = nil
    end)

    if not ok then
        log("Error untracking buffer: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
    end
end

-- Setup buffer tracking for a client
function M.setup_buffer_tracking(client, bufnr, server_name, host, protocol)
    -- Track this client
    M.track_client(client.id, server_name, bufnr, host, protocol)

    -- Add buffer closure detection with full error handling
    local autocmd_group = vim.api.nvim_create_augroup("RemoteLspBuffer" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd({"BufDelete", "BufWipeout", "BufUnload"}, {
        group = autocmd_group,
        buffer = bufnr,
        callback = function(ev)
            -- Skip untracking if the buffer is just being saved
            if M.buffer_save_in_progress[bufnr] then
                log("Buffer " .. bufnr .. " is being saved, not untracking LSP", vim.log.levels.DEBUG, false, config.config)
                return
            end

            -- Only untrack if this is a genuine buffer close
            if ev.event == "BufDelete" or ev.event == "BufWipeout" then
                log("Buffer " .. bufnr .. " closed (" .. ev.event .. "), checking if LSP server should be stopped", vim.log.levels.DEBUG, false, config.config)
                -- Schedule the untracking to avoid blocking
                vim.schedule(function()
                    M.safe_untrack_buffer(bufnr)
                end)
            end
        end,
    })

    -- Add LSP crash/exit detection
    local exit_handler_group = vim.api.nvim_create_augroup("RemoteLspExit" .. client.id, { clear = true })

    -- Create an autocommand to detect and handle server exit
    vim.api.nvim_create_autocmd("LspDetach", {
        group = exit_handler_group,
        callback = function(ev)
            if ev.data and ev.data.client_id == client.id then
                vim.schedule(function()
                    -- Get client module
                    local client_module = require('remote-lsp.client')

                    -- Only report unexpected disconnections
                    if client_module.active_lsp_clients[client.id] then
                        log(string.format("Remote LSP %s disconnected. Use :RemoteLspStart to reconnect if needed.", server_name), vim.log.levels.WARN, true, config.config)
                    end

                    -- Clean up tracking
                    M.untrack_client(client.id)
                end)
            end
        end
    })
end

-- Function to notify that a buffer save is starting - optimized to be non-blocking
function M.notify_save_start(bufnr)
    -- Set the flag immediately (this is fast)
    M.buffer_save_in_progress[bufnr] = true
    M.buffer_save_timestamps[bufnr] = os.time()

    -- Log with scheduling to avoid blocking
    log("Save started for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

    -- Schedule LSP willSave notifications to avoid blocking
    vim.schedule(function()
        -- Only proceed if buffer is still valid
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        -- Notify LSP clients about willSave event if they support it
        local clients = vim.lsp.get_clients({ bufnr = bufnr })

        for _, client in ipairs(clients) do
            -- Skip clients that don't support document sync
            if not client.server_capabilities.textDocumentSync then
                goto continue
            end

            -- Check if client supports willSave notification
            local supports_will_save = false

            if type(client.server_capabilities.textDocumentSync) == "table" and
               client.server_capabilities.textDocumentSync.willSave then
                supports_will_save = true
            end

            if supports_will_save then
                -- Get buffer information
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                local uri = vim.uri_from_fname(bufname)

                -- Send willSave notification asynchronously
                client.notify('textDocument/willSave', {
                    textDocument = {
                        uri = uri
                    },
                    reason = 1  -- 1 = Manual save
                })
            end

            ::continue::
        end
    end)
end

-- Function to notify that a buffer has changed
function M.notify_buffer_modified(bufnr)
    -- Check if the buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    -- Get all LSP clients attached to this buffer
    local clients = vim.lsp.get_active_clients({ bufnr = bufnr })

    for _, client in ipairs(clients) do
        -- Skip clients that don't support document sync
        if not client.server_capabilities.textDocumentSync then
            goto continue
        end

        -- Get buffer information
        local bufname = vim.api.nvim_buf_get_name(bufnr)

        -- Create minimal document info
        local uri = vim.uri_from_fname(bufname)
        local doc_version = vim.lsp.util.buf_versions[bufnr] or 0

        -- Increment document version
        vim.lsp.util.buf_versions[bufnr] = doc_version + 1

        -- Prepare didSave notification - don't include text unless required
        local params = {
            textDocument = {
                uri = uri,
                version = doc_version + 1
            }
        }

        -- Check if we need to include text based on server capabilities
        local include_text = false

        -- Handle different types of textDocumentSync.save
        if type(client.server_capabilities.textDocumentSync) == "table" and
           client.server_capabilities.textDocumentSync.save then
            -- If save is an object with includeText property
            if type(client.server_capabilities.textDocumentSync.save) == "table" and
               client.server_capabilities.textDocumentSync.save.includeText then
                include_text = true
            end
        end

        if include_text then
            -- We'll use a scheduled, non-blocking approach to get text if needed
            vim.schedule(function()
                -- Get buffer content
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local text = table.concat(lines, "\n")

                -- Add text to params
                params.text = text

                -- Send notification with text
                client.notify('textDocument/didSave', params)
            end)
        else
            -- If text isn't required, we can notify immediately without blocking
            client.notify('textDocument/didSave', params)
        end

        ::continue::
    end
end

-- Function to notify that a buffer save is complete - optimized to be non-blocking
function M.notify_save_end(bufnr)
    -- Clear the in-progress flag and timestamp (this is fast)
    M.buffer_save_in_progress[bufnr] = nil
    M.buffer_save_timestamps[bufnr] = nil

    -- Log with scheduling to avoid blocking
    log("Save completed for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

    -- Schedule the potentially slow LSP operations
    vim.schedule(function()
        -- Only notify if buffer is still valid
        if vim.api.nvim_buf_is_valid(bufnr) then
            -- Notify any attached LSP clients that the save completed
            M.notify_buffer_modified(bufnr)

            -- Check if we need to restart LSP
            local clients = vim.lsp.get_clients({ bufnr = bufnr })
            if #clients == 0 and M.buffer_clients[bufnr] and not vim.tbl_isempty(M.buffer_clients[bufnr]) then
                log("LSP disconnected after save, restarting", vim.log.levels.WARN, false, config.config)
                -- Defer to ensure buffer is stable
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        require('remote-lsp.client').start_remote_lsp(bufnr)
                    end
                end, 100)
            end
        end
    end)
end

-- Setup a cleanup timer to handle stuck flags
function M.setup_save_status_cleanup()
    local timer = vim.loop.new_timer()

    timer:start(15000, 15000, vim.schedule_wrap(function()
        local now = os.time()
        for bufnr, timestamp in pairs(M.buffer_save_timestamps) do
            if now - timestamp > 30 then -- 30 seconds max save time
                log("Detected stuck save flag for buffer " .. bufnr .. ", cleaning up", vim.log.levels.WARN, false, config.config)
                M.buffer_save_in_progress[bufnr] = nil
                M.buffer_save_timestamps[bufnr] = nil

                -- Also check if the buffer is still valid
                if vim.api.nvim_buf_is_valid(bufnr) then
                    -- Make sure LSP is still connected
                    local has_lsp = false

                    -- Get client module
                    local client_module = require('remote-lsp.client')

                    for client_id, info in pairs(client_module.active_lsp_clients) do
                        if info.bufnr == bufnr then
                            has_lsp = true
                            break
                        end
                    end

                    if not has_lsp then
                        log("LSP disconnected during save, attempting to reconnect", vim.log.levels.WARN, false, config.config)
                        -- Try to restart LSP
                        vim.schedule(function()
                            require('remote-lsp.client').start_remote_lsp(bufnr)
                        end)
                    end
                end
            end
        end
    end))

    return timer
end

-- Add auto commands for remote files with proper timing
function M.setup_autocommands()
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
                    log("Autocmd triggered for " .. bufname .. " with filetype " .. (filetype or "nil"), vim.log.levels.DEBUG, false, config.config)

                    if filetype and filetype ~= "" then
                        -- Start LSP in a scheduled callback to avoid blocking the UI
                        vim.schedule(function()
                            require('remote-lsp.client').start_remote_lsp(bufnr)
                        end)
                    end
                end, 100) -- Small delay to ensure filetype detection has completed
            end)

            if not ok then
                log("Error in autocmd: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
            end
        end,
    })

    -- Add cleanup on VimLeave
    vim.api.nvim_create_autocmd("VimLeave", {
        group = autocmd_group,
        callback = function()
            local ok, err = pcall(function()
                log("VimLeave: Stopping all remote LSP clients", vim.log.levels.DEBUG, false, config.config)
                -- Force kill on exit
                require('remote-lsp.client').stop_all_clients(true)
            end)

            if not ok then
                log("Error in VimLeave: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
            end
        end,
    })
end

return M
