local M = {}

local config = require("remote-lsp.config")
local utils = require("remote-lsp.utils")
local log = require("logging").log
local metadata = require("remote-buffer-metadata")

-- Note: All buffer tracking now handled by buffer-local metadata system

-- Initialize metadata schema for remote-lsp
metadata.register_schema("remote-lsp", {
    defaults = {
        clients = {}, -- client_id -> true
        server_key = nil, -- server_name@host
        save_in_progress = false,
        save_timestamp = nil,
        project_root = nil,
    },
    validators = {
        clients = function(v)
            return type(v) == "table"
        end,
        server_key = function(v)
            return type(v) == "string" or v == nil
        end,
        save_in_progress = function(v)
            return type(v) == "boolean"
        end,
        save_timestamp = function(v)
            return type(v) == "number" or v == nil
        end,
        project_root = function(v)
            return type(v) == "string" or v == nil
        end,
    },
})

-- Helper functions for metadata access
local function get_buffer_clients(bufnr)
    return metadata.get(bufnr, "remote-lsp", "clients") or {}
end

local function set_buffer_client(bufnr, client_id, active)
    local clients = get_buffer_clients(bufnr)
    if active then
        clients[client_id] = true
    else
        clients[client_id] = nil
    end
    metadata.set(bufnr, "remote-lsp", "clients", clients)
end

local function get_server_buffers(server_key)
    local result = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local buf_server_key = metadata.get(bufnr, "remote-lsp", "server_key")
            if buf_server_key == server_key then
                table.insert(result, bufnr)
            end
        end
    end
    return result
end

local function set_server_buffer(server_key, bufnr, active)
    if active then
        metadata.set(bufnr, "remote-lsp", "server_key", server_key)
    else
        metadata.set(bufnr, "remote-lsp", "server_key", nil)
    end
end

local function get_save_in_progress(bufnr)
    return metadata.get(bufnr, "remote-lsp", "save_in_progress") or false
end

local function set_save_in_progress(bufnr, in_progress)
    local success = metadata.set(bufnr, "remote-lsp", "save_in_progress", in_progress)
    if not success then
        return false
    end
    if in_progress then
        metadata.set(bufnr, "remote-lsp", "save_timestamp", os.time())
    else
        metadata.set(bufnr, "remote-lsp", "save_timestamp", nil)
    end
    return true
end

-- Function to track client with server and buffer information
function M.track_client(client_id, server_name, bufnr, host, protocol)
    log(
        "Tracking client " .. client_id .. " for server " .. server_name .. " on buffer " .. bufnr,
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    -- Get client module
    local client = require("remote-lsp.client")

    -- Track client info
    client.active_lsp_clients[client_id] = {
        server_name = server_name,
        bufnr = bufnr,
        host = host,
        protocol = protocol,
        timestamp = os.time(),
    }

    -- Track which buffers use which server
    local server_key = utils.get_server_key(server_name, host)
    metadata.set(bufnr, "remote-lsp", "server_key", server_key)

    -- Track which clients are attached to which buffers
    local clients = metadata.get(bufnr, "remote-lsp", "clients") or {}
    clients[client_id] = true
    metadata.set(bufnr, "remote-lsp", "clients", clients)
end

-- Function to untrack a client
function M.untrack_client(client_id)
    -- Get client module
    local client = require("remote-lsp.client")

    local client_info = client.active_lsp_clients[client_id]
    if not client_info then
        return
    end

    -- Remove from server-buffer tracking
    if client_info.server_name and client_info.host then
        local server_key = utils.get_server_key(client_info.server_name, client_info.host)
        local server_buffers = get_server_buffers(server_key)

        if vim.tbl_contains(server_buffers, client_info.bufnr) then
            set_server_buffer(server_key, client_info.bufnr, false)
        end
    end

    -- Remove from buffer-client tracking
    if client_info.bufnr then
        set_buffer_client(client_info.bufnr, client_id, false)
    end

    -- Remove the client info itself
    client.active_lsp_clients[client_id] = nil
end

-- Function to safely handle buffer untracking
function M.safe_untrack_buffer(bufnr)
    local ok, err = pcall(function()
        -- Check if a save is in progress for this buffer
        if get_save_in_progress(bufnr) then
            log(
                "Save in progress for buffer " .. bufnr .. ", not untracking LSP",
                vim.log.levels.DEBUG,
                false,
                config.config
            )
            return
        end

        log("Untracking buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

        -- Get clients for this buffer
        local clients = get_buffer_clients(bufnr)
        local client_ids = {}
        for client_id, _ in pairs(clients) do
            table.insert(client_ids, client_id)
        end

        -- Get client module
        local client_module = require("remote-lsp.client")

        -- For each client, check if we should shut it down
        for _, client_id in ipairs(client_ids) do
            local client_info = client_module.active_lsp_clients[client_id]
            if client_info then
                local server_key = utils.get_server_key(client_info.server_name, client_info.host)

                -- Untrack this buffer from the server
                local server_buffers = get_server_buffers(server_key)
                if vim.tbl_contains(server_buffers, bufnr) then
                    set_server_buffer(server_key, bufnr, false)

                    -- Check if this was the last buffer using this server
                    local remaining_buffers = get_server_buffers(server_key)
                    if vim.tbl_isempty(remaining_buffers) then
                        -- This was the last buffer, shut down the server
                        log(
                            "Last buffer using server " .. server_key .. " closed, shutting down client " .. client_id,
                            vim.log.levels.DEBUG,
                            false,
                            config.config
                        )
                        -- Schedule the shutdown to avoid blocking
                        vim.schedule(function()
                            client_module.shutdown_client(client_id, true)
                        end)
                    else
                        -- Other buffers still use this server, just untrack this buffer
                        log(
                            "Buffer "
                                .. bufnr
                                .. " closed but server "
                                .. server_key
                                .. " still has active buffers, keeping client "
                                .. client_id,
                            vim.log.levels.DEBUG,
                            false,
                            config.config
                        )

                        -- Still untrack the client from this buffer specifically
                        set_buffer_client(bufnr, client_id, false)
                    end
                end
            end
        end

        -- Finally remove the buffer from our tracking
        local clients = get_buffer_clients(bufnr)
        for client_id, _ in pairs(clients) do
            set_buffer_client(bufnr, client_id, false)
        end
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

    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
        group = autocmd_group,
        buffer = bufnr,
        callback = function(ev)
            -- Skip untracking if the buffer is just being saved
            if get_save_in_progress(bufnr) then
                log("Buffer " .. bufnr .. " is being saved, not untracking LSP", vim.log.levels.DEBUG, false, config.config)
                return
            end

            -- Only untrack if this is a genuine buffer close
            if ev.event == "BufDelete" or ev.event == "BufWipeout" then
                log(
                    "Buffer " .. bufnr .. " closed (" .. ev.event .. "), checking if LSP server should be stopped",
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
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
                    local client_module = require("remote-lsp.client")

                    -- Only report unexpected disconnections
                    if client_module.active_lsp_clients[client.id] then
                        log(
                            string.format(
                                "Remote LSP %s disconnected. Use :RemoteLspStart to reconnect if needed.",
                                server_name
                            ),
                            vim.log.levels.WARN,
                            true,
                            config.config
                        )
                    end

                    -- Clean up tracking
                    M.untrack_client(client.id)
                end)
            end
        end,
    })
end

-- Function to notify that a buffer save is starting - optimized to be non-blocking
function M.notify_save_start(bufnr)
    -- Check if buffer is valid first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    -- Set the flag immediately (this is fast)
    local success = set_save_in_progress(bufnr, true)
    if not success then
        return false
    end

    -- Log with scheduling to avoid blocking
    log("Save started for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

    -- Schedule LSP willSave notifications to avoid blocking
    if vim.schedule then
        vim.schedule(function()
            -- Only proceed if buffer is still valid
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end

            -- Notify LSP clients about willSave event if they support it
            local clients = vim.lsp.get_clients({ bufnr = bufnr })

            for _, client in ipairs(clients) do
                -- Only process clients that support document sync
                if client.server_capabilities.textDocumentSync then
                    -- Check if client supports willSave notification
                    local supports_will_save = false

                    if
                        type(client.server_capabilities.textDocumentSync) == "table"
                        and client.server_capabilities.textDocumentSync.willSave
                    then
                        supports_will_save = true
                    end

                    if supports_will_save then
                        -- Get buffer information
                        local bufname = vim.api.nvim_buf_get_name(bufnr)
                        local uri = vim.uri_from_fname(bufname)

                        -- Send willSave notification asynchronously
                        client.notify("textDocument/willSave", {
                            textDocument = {
                                uri = uri,
                            },
                            reason = 1, -- 1 = Manual save
                        })
                    end
                end
            end
        end)
    end

    return true
end

-- Function to notify that a buffer has changed
function M.notify_buffer_modified(bufnr)
    -- Check if the buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    -- Get all LSP clients attached to this buffer
    local clients = vim.lsp.get_clients({ bufnr = bufnr })

    for _, client in ipairs(clients) do
        -- Only process clients that support document sync
        if client.server_capabilities.textDocumentSync then
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
                    version = doc_version + 1,
                },
            }

            -- Check if we need to include text based on server capabilities
            local include_text = false

            -- Handle different types of textDocumentSync.save
            if
                type(client.server_capabilities.textDocumentSync) == "table"
                and client.server_capabilities.textDocumentSync.save
            then
                -- If save is an object with includeText property
                if
                    type(client.server_capabilities.textDocumentSync.save) == "table"
                    and client.server_capabilities.textDocumentSync.save.includeText
                then
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
                    client.notify("textDocument/didSave", params)
                end)
            else
                -- If text isn't required, we can notify immediately without blocking
                client.notify("textDocument/didSave", params)
            end
        end
    end
end

-- Function to notify that a buffer save is complete - optimized to be non-blocking
function M.notify_save_end(bufnr)
    -- Clear the in-progress flag and timestamp (this is fast)
    set_save_in_progress(bufnr, false)

    -- Log with scheduling to avoid blocking
    log("Save completed for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)

    -- Schedule the potentially slow LSP operations
    vim.schedule(function()
        -- Only notify if buffer is still valid
        if vim.api.nvim_buf_is_valid(bufnr) then
            -- Notify any attached LSP clients that the save completed
            M.notify_buffer_modified(bufnr)

            -- Check if we need to restart LSP (with debouncing)
            local clients = vim.lsp.get_clients({ bufnr = bufnr })
            local buffer_clients = get_buffer_clients(bufnr)
            if #clients == 0 and not vim.tbl_isempty(buffer_clients) then
                -- Check if we recently attempted a reconnection
                local last_reconnect_key = "last_reconnect_" .. bufnr
                local last_reconnect = vim.g[last_reconnect_key] or 0
                local now = vim.fn.localtime()

                if now - last_reconnect > 10 then -- Debounce for 10 seconds
                    log("LSP disconnected after save, restarting", vim.log.levels.WARN, false, config.config)
                    vim.g[last_reconnect_key] = now

                    -- Defer to ensure buffer is stable
                    vim.defer_fn(function()
                        if vim.api.nvim_buf_is_valid(bufnr) then
                            require("remote-lsp.client").start_remote_lsp(bufnr)
                        end
                    end, 500) -- Increased delay to 500ms
                else
                    log("LSP reconnection debounced for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
                end
            end
        end
    end)
end

-- Setup a cleanup timer to handle stuck flags
function M.setup_save_status_cleanup()
    local timer = vim.loop.new_timer()

    timer:start(
        15000,
        15000,
        vim.schedule_wrap(function()
            local now = os.time()

            -- Check all buffers for stuck save operations
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    local save_timestamp = require("remote-buffer-metadata").get(bufnr, "remote-lsp", "save_timestamp")
                    if save_timestamp and (now - save_timestamp > 30) then -- 30 seconds max save time
                        log(
                            "Detected stuck save flag for buffer " .. bufnr .. ", cleaning up",
                            vim.log.levels.WARN,
                            false,
                            config.config
                        )
                        set_save_in_progress(bufnr, false)
                    end

                    -- Also check if the buffer is still valid
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        -- Make sure LSP is still connected (use proper APIs)
                        local has_active_vim_lsp = #vim.lsp.get_clients({ bufnr = bufnr }) > 0
                        local has_tracked_clients = not vim.tbl_isempty(get_buffer_clients(bufnr))

                        -- Only reconnect if we have tracked clients but no active LSP clients
                        if has_tracked_clients and not has_active_vim_lsp then
                            -- Check if we recently attempted a reconnection (debouncing)
                            local cleanup_reconnect_key = "cleanup_reconnect_" .. bufnr
                            local last_cleanup_reconnect = vim.g[cleanup_reconnect_key] or 0
                            local now_cleanup = vim.fn.localtime()

                            if now_cleanup - last_cleanup_reconnect > 30 then -- Debounce for 30 seconds
                                log(
                                    "LSP disconnected during save, attempting to reconnect",
                                    vim.log.levels.WARN,
                                    false,
                                    config.config
                                )
                                vim.g[cleanup_reconnect_key] = now_cleanup

                                -- Try to restart LSP
                                vim.schedule(function()
                                    require("remote-lsp.client").start_remote_lsp(bufnr)
                                end)
                            else
                                log(
                                    "LSP cleanup reconnection debounced for buffer " .. bufnr,
                                    vim.log.levels.DEBUG,
                                    false,
                                    config.config
                                )
                            end
                        end
                    end
                end
            end
        end)
    )

    return timer
end

-- Add auto commands for remote files with proper timing
function M.setup_autocommands()
    local autocmd_group = vim.api.nvim_create_augroup("RemoteLSP", { clear = true })

    -- Update autocmd to use multiple events for better reliability
    vim.api.nvim_create_autocmd({ "BufReadPost", "FileType" }, {
        pattern = { "scp://*", "rsync://*" },
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
                    log(
                        "Autocmd triggered for " .. bufname .. " with filetype " .. (filetype or "nil"),
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )

                    if filetype and filetype ~= "" then
                        -- Start LSP in a scheduled callback to avoid blocking the UI
                        vim.schedule(function()
                            require("remote-lsp.client").start_remote_lsp(bufnr)
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
                require("remote-lsp.client").stop_all_clients(true)
            end)

            if not ok then
                log("Error in VimLeave: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
            end
        end,
    })
end

return M
