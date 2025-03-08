local M = {}

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp, ...}
local active_writes = {}

-- Configuration
local config = {
    timeout = 30,          -- Default timeout in seconds
    debug = true,          -- Debug mode enabled by default
    check_interval = 1000, -- Status check interval in ms
}

-- LSP integration callbacks
local lsp_integration = {
    notify_save_start = function(bufnr) end,
    notify_save_end = function(bufnr) end
}

local buffer_state_after_save = {}

-- Function to get protocol and details from buffer name
local function parse_remote_path(bufname)
    local protocol
    if bufname:match("^scp://") then
        protocol = "scp"
    elseif bufname:match("^rsync://") then
        protocol = "rsync"
    else
        return nil
    end

    -- Enhanced pattern matching for double-slash issues
    local host, path

    -- First try the standard pattern (protocol://host/path)
    local pattern = "^" .. protocol .. "://([^/]+)/(.+)$"
    host, path = bufname:match(pattern)

    -- If that fails, try the double-slash pattern (protocol://host//path)
    if not host or not path then
        local alt_pattern = "^" .. protocol .. "://([^/]+)//(.+)$"
        host, path = bufname:match(alt_pattern)

        -- Ensure path starts with / for consistency
        if host and path and not path:match("^/") then
            path = "/" .. path
        end
    end

    if not host or not path then
        return nil
    end

    return {
        protocol = protocol,
        host = host,
        path = path,
        full = bufname,
        -- Store the exact original format for accurate command construction
        has_double_slash = bufname:match("^" .. protocol .. "://[^/]+//") ~= nil
    }
end

-- Log function that respects debug mode
local function log(msg, level)
    level = level or vim.log.levels.DEBUG
    if config.debug or level > vim.log.levels.DEBUG then
        vim.schedule(function()
            vim.notify("[AsyncWrite] " .. msg, level)
        end)
    end
end

-- Show a notification in the status line
local function notify(msg, level)
    vim.schedule(function()
        level = level or vim.log.levels.INFO
        vim.notify(msg, level)

        -- Update the status line if possible
        pcall(function()
            if vim.o.laststatus >= 2 then  -- Status line is visible
                vim.cmd("redrawstatus")
            end
        end)
    end)
end

-- Safely close a timer
local function safe_close_timer(timer)
    if timer then
        pcall(function()
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end)
    end
end

local function track_buffer_state_after_save(bufnr)
    -- Only track if buffer is still valid
    if vim.api.nvim_buf_is_valid(bufnr) then
        buffer_state_after_save[bufnr] = {
            time = os.time(),
            buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype'),
            autocmds_checked = false
        }

        -- Schedule a check of autocommands after the write is complete
        vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) and buffer_state_after_save[bufnr] then
                -- Get current buftype
                local current_buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
                buffer_state_after_save[bufnr].autocmds_checked = true
                buffer_state_after_save[bufnr].buftype_after_delay = current_buftype

                -- Check if the buftype has changed
                if buffer_state_after_save[bufnr].buftype ~= current_buftype then
                    log("Buffer type changed after save: " .. buffer_state_after_save[bufnr].buftype ..
                        " -> " .. current_buftype, vim.log.levels.WARN)

                    -- If it's changed from acwrite, fix it
                    if buffer_state_after_save[bufnr].buftype == 'acwrite' and current_buftype ~= 'acwrite' then
                        log("Restoring buffer type to 'acwrite'", vim.log.levels.INFO)
                        vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
                    end
                end
            end
        end, 500)  -- Check after 500ms
    end
end

-- Function to handle write completion
local function on_write_complete(bufnr, job_id, exit_code, error_msg)
    -- Get current write info and validate
    local write_info = active_writes[bufnr]
    if not write_info then
        log("No active write found for buffer " .. bufnr, vim.log.levels.WARN)
        return
    end

    if write_info.job_id ~= job_id then
        log("Job ID mismatch for buffer " .. bufnr, vim.log.levels.WARN)
        return
    end

    -- Check if buffer still exists
    local buffer_exists = vim.api.nvim_buf_is_valid(bufnr)
    log(string.format("Write complete for buffer %d with exit code %d (buffer exists: %s)",
                    bufnr, exit_code, tostring(buffer_exists)), vim.log.levels.INFO)

    -- Stop timer if it exists
    if write_info.timer then
        safe_close_timer(write_info.timer)
        write_info.timer = nil
    end

    -- Store essential info before removing the write
    local buffer_name = write_info.buffer_name
    local start_time = write_info.start_time

    -- Capture LSP client info if buffer still exists
    local lsp_clients = {}
    if buffer_exists then
        local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
        for _, client in ipairs(clients) do
            table.insert(lsp_clients, client.id)
        end
    end

    track_buffer_state_after_save(bufnr)

    -- Remove from active writes table
    active_writes[bufnr] = nil

    -- Notify LSP module that save is complete
    vim.schedule(function()
        lsp_integration.notify_save_end(bufnr)

        -- Verify LSP connection still exists
        if #lsp_clients > 0 and buffer_exists then
            -- Double-check LSP clients are still attached
            local current_clients = vim.lsp.get_active_clients({ bufnr = bufnr })
            if #current_clients == 0 then
                log("LSP clients were disconnected during save, attempting to reconnect", vim.log.levels.WARN)

                -- Attempt to restart LSP
                local remote_ssh = require("remote-ssh")
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        remote_ssh.start_remote_lsp(bufnr)
                    end
                end, 100)
            end
        end
    end)

    -- Handle success or failure
    if exit_code == 0 then
        -- Calculate duration
        local duration = os.time() - start_time
        local duration_str = duration > 1 and (duration .. "s") or "less than a second"

        -- Mark buffer as saved if it still exists
        vim.schedule(function()
            if buffer_exists then
                -- Set buffer as not modified
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)

                -- Reregister autocommands for this buffer
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.register_buffer_autocommands(bufnr)
                    end
                end, 10)

                -- Update status line
                local short_name = vim.fn.fnamemodify(buffer_name, ":t")
                notify(string.format("✓ File '%s' saved in %s", short_name, duration_str))
            else
                notify(string.format("✓ File saved in %s (buffer no longer exists)", duration_str))
            end
        end)
    else
        local error_info = error_msg or ""
        vim.schedule(function()
            if buffer_exists then
                local short_name = vim.fn.fnamemodify(buffer_name, ":t")
                notify(string.format("❌ Failed to save '%s': %s", short_name, error_info), vim.log.levels.ERROR)
            else
                notify(string.format("❌ Failed to save file: %s", error_info), vim.log.levels.ERROR)
            end
        end)
    end
end

-- Set up a timer to monitor job progress
local function setup_job_timer(bufnr)
    local timer = vim.loop.new_timer()

    -- Check job status regularly
    timer:start(1000, config.check_interval, vim.schedule_wrap(function()
        local write_info = active_writes[bufnr]
        if not write_info then
            safe_close_timer(timer)
            return
        end

        -- Update elapsed time
        local elapsed = os.time() - write_info.start_time
        write_info.elapsed = elapsed

        -- Check if job is still running
        local job_running = vim.fn.jobwait({write_info.job_id}, 0)[1] == -1

        if not job_running then
            -- Job finished but callback wasn't triggered
            log("Job finished but callback wasn't triggered, forcing completion", vim.log.levels.WARN)
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 0)
            end)
            safe_close_timer(timer)
        elseif elapsed > config.timeout then
            -- Job timed out
            log("Job timed out after " .. elapsed .. " seconds", vim.log.levels.WARN)
            pcall(vim.fn.jobstop, write_info.job_id)
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 1, "Timeout after " .. elapsed .. " seconds")
            end)
            safe_close_timer(timer)
        end
    end))

    return timer
end

-- NEW APPROACH: Direct streaming to remote host
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Validate buffer first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Cannot save invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return true
    end

    -- Ensure 'buftype' is 'acwrite' to trigger BufWriteCmd
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
    if buftype ~= 'acwrite' then
        log("Buffer type is not 'acwrite', resetting it for buffer " .. bufnr, vim.log.levels.WARN)
        vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
    end

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Check if there's already a write in progress
    if active_writes[bufnr] then
        local elapsed = os.time() - active_writes[bufnr].start_time
        if elapsed > config.timeout / 2 then
            log("Previous write may be stuck (running for " .. elapsed .. "s), forcing completion", vim.log.levels.WARN)
            M.force_complete(bufnr, true)
        else
            vim.schedule(function()
                notify("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN)
            end)
            return true
        end
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false  -- Not a remote path we can handle
    end

    log("Starting save for buffer " .. bufnr .. ": " .. bufname, vim.log.levels.INFO)

    -- Parse remote path
    local remote_path = parse_remote_path(bufname)
    if not remote_path then
        vim.schedule(function()
            log("Not a valid remote path: " .. bufname, vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Notify LSP immediately that we're saving
    lsp_integration.notify_save_start(bufnr)

    -- Visual feedback for user
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            local short_name = vim.fn.fnamemodify(bufname, ":t")
            notify(string.format("💾 Saving '%s' in background...", short_name))
        end
    end)

    -- Get buffer content
    local content = ""
    local ok, err = pcall(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            error("Buffer is no longer valid")
        end
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        content = table.concat(lines, "\n")
        if content == "" then
            error("Cannot save empty buffer with no contents")
        end
    end)

    if not ok then
        vim.schedule(function()
            log("Failed to get buffer content: " .. tostring(err), vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Start the save process
    local start_time = os.time()

    -- Create a temporary file to hold the content
    local temp_file = vim.fn.tempname()

    -- Write buffer content to temporary file
    local write_ok, write_err = pcall(function()
        local file = io.open(temp_file, "w")
        if not file then
            error("Failed to open temporary file: " .. temp_file)
        end
        file:write(content)
        file:close()
    end)

    if not write_ok then
        vim.schedule(function()
            log("Failed to write to temporary file: " .. tostring(write_err), vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        pcall(vim.fn.delete, temp_file)
        return true
    end

    -- Prepare directory on remote host
    local remote_dir = vim.fn.fnamemodify(remote_path.path, ":h")
    local mkdir_cmd = {"ssh", remote_path.host, "mkdir", "-p", remote_dir}

    local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
        on_exit = function(_, mkdir_exit_code)
            if mkdir_exit_code ~= 0 then
                vim.schedule(function()
                    log("Failed to create remote directory: " .. remote_dir, vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Build command based on protocol
            local save_cmd
            if remote_path.protocol == "scp" then
                save_cmd = {
                    "scp",
                    "-q",  -- quiet mode
                    temp_file,
                    remote_path.host .. ":" .. vim.fn.shellescape(remote_path.path)
                }
            elseif remote_path.protocol == "rsync" then
                save_cmd = {
                    "rsync",
                    "-az",  -- archive mode and compress
                    "--quiet",  -- quiet mode
                    temp_file,
                    remote_path.host .. ":" .. remote_path.path
                }
            else
                vim.schedule(function()
                    log("Unsupported protocol: " .. remote_path.protocol, vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Create job with proper handlers
            local job_id
            local on_exit_wrapper = function(_, exit_code)
                -- Clean up the temporary file regardless of success or failure
                pcall(vim.fn.delete, temp_file)

                if not active_writes[bufnr] or active_writes[bufnr].job_id ~= job_id then
                    log("Ignoring exit for job " .. job_id .. " (no longer tracked)")
                    return
                end
                on_write_complete(bufnr, job_id, exit_code)
            end

            -- Launch the transfer job
            job_id = vim.fn.jobstart(save_cmd, {
                on_exit = on_exit_wrapper
            })

            if job_id <= 0 then
                vim.schedule(function()
                    notify("❌ Failed to start save job", vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Set up timer to monitor the job
            local timer = setup_job_timer(bufnr)

            -- Track the write operation
            active_writes[bufnr] = {
                job_id = job_id,
                start_time = start_time,
                buffer_name = bufname,
                remote_path = remote_path,
                timer = timer,
                elapsed = 0,
                temp_file = temp_file  -- Track the temp file for cleanup if needed
            }

            log("Save job started with ID " .. job_id .. " for buffer " .. bufnr, vim.log.levels.INFO)
        end
    })

    if mkdir_job <= 0 then
        vim.schedule(function()
            notify("❌ Failed to ensure remote directory", vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        pcall(vim.fn.delete, temp_file)
    end

    -- Return true to indicate we're handling the write
    return true
end

-- Force complete a stuck write operation
function M.force_complete(bufnr, success)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    success = success or false

    local write_info = active_writes[bufnr]
    if not write_info then
        notify("No active write operation for this buffer", vim.log.levels.WARN)
        return false
    end

    -- Stop the job if it's still running
    pcall(vim.fn.jobstop, write_info.job_id)

    -- Force completion
    on_write_complete(bufnr, write_info.job_id, success and 0 or 1,
        success and nil or "Manually forced completion")

    notify(success and "✓ Write operation marked as completed" or
        "✓ Write operation marked as failed", vim.log.levels.INFO)

    return true
end

-- Cancel an ongoing write operation
function M.cancel_write(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local write_info = active_writes[bufnr]
    if not write_info then
        notify("No active write operation to cancel", vim.log.levels.WARN)
        return false
    end

    -- Stop the job
    pcall(vim.fn.jobstop, write_info.job_id)

    -- Force completion with error
    on_write_complete(bufnr, write_info.job_id, 1, "Cancelled by user")

    notify("✓ Write operation cancelled", vim.log.levels.INFO)
    return true
end

-- Get status of active write operations
function M.get_status()
    local count = 0
    local details = {}

    for bufnr, info in pairs(active_writes) do
        count = count + 1
        local elapsed = os.time() - info.start_time
        local bufname = vim.api.nvim_buf_is_valid(bufnr) and
                        vim.api.nvim_buf_get_name(bufnr) or
                        info.buffer_name or "unknown"

        table.insert(details, {
            bufnr = bufnr,
            name = vim.fn.fnamemodify(bufname, ":t"),
            elapsed = elapsed,
            protocol = info.remote_path.protocol,
            host = info.remote_path.host,
            job_id = info.job_id
        })
    end

    notify(string.format("Active write operations: %d", count), vim.log.levels.INFO)

    for _, detail in ipairs(details) do
        notify(string.format("  Buffer %d: %s (%s to %s) - running for %ds (job %d)",
            detail.bufnr, detail.name, detail.protocol, detail.host, detail.elapsed, detail.job_id),
            vim.log.levels.INFO)
    end

    return {
        count = count,
        details = details
    }
end

-- Configure timeout and debug settings
function M.configure(opts)
    opts = opts or {}

    if opts.timeout then
        config.timeout = opts.timeout
    end

    if opts.debug ~= nil then
        config.debug = opts.debug
    end

    if opts.check_interval then
        config.check_interval = opts.check_interval
    end

    log("Configuration updated: " .. vim.inspect(config))
end

-- Set up LSP integration
function M.setup_lsp_integration(callbacks)
    if type(callbacks) ~= "table" then
        log("Invalid LSP integration callbacks", vim.log.levels.ERROR)
        return
    end

    if type(callbacks.notify_save_start) == "function" then
        lsp_integration.notify_save_start = callbacks.notify_save_start
        log("Registered LSP save start callback", vim.log.levels.DEBUG)
    end

    if type(callbacks.notify_save_end) == "function" then
        lsp_integration.notify_save_end = callbacks.notify_save_end
        log("Registered LSP save end callback", vim.log.levels.DEBUG)
    end

    log("LSP integration set up")
end

-- Setup file handlers for LSP and buffer commands
function M.setup_file_handlers()
    -- Create autocmd to intercept BufReadCmd for remote protocols
    local augroup = vim.api.nvim_create_augroup("RemoteFileOpen", { clear = true })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            local url = ev.match
            log("Intercepted BufReadCmd for " .. url, vim.log.levels.DEBUG)

            -- Use our custom remote file opener
            vim.schedule(function()
                M.simple_open_remote_file(url)
            end)

            -- Return true to indicate we've handled it
            return true
        end,
        desc = "Intercept remote file opening and use custom opener",
    })

    -- Intercept the LSP handler for textDocument/definition
    -- Save the original handler
    local orig_definition_handler = vim.lsp.handlers["textDocument/definition"]

    -- Create a new handler that intercepts remote URLs
    -- Enhanced LSP definition handler with better URI handling
    vim.lsp.handlers["textDocument/definition"] = function(err, result, ctx, config)
        if err or not result or vim.tbl_isempty(result) then
            -- Pass through to original handler for error cases
            return orig_definition_handler(err, result, ctx, config)
        end

        log("Definition handler received result: " .. vim.inspect(result), vim.log.levels.DEBUG)

        -- Extract target URI based on result format
        local target_uri, position

        if result.uri then
            -- Single location
            target_uri = result.uri
            position = result.range and result.range.start
        elseif type(result) == "table" then
            if result[1] and result[1].uri then
                -- Array of locations - take the first one
                target_uri = result[1].uri
                position = result[1].range and result[1].range.start
            elseif result[1] and result[1].targetUri then
                -- LocationLink[] format
                target_uri = result[1].targetUri
                position = result[1].targetSelectionRange and result[1].targetSelectionRange.start or
                          result[1].targetRange and result[1].targetRange.start
            end
        end

        if not target_uri then
            log("No target URI found in definition result", vim.log.levels.WARN)
            return orig_definition_handler(err, result, ctx, config)
        end

        log("LSP definition target URI: " .. target_uri, vim.log.levels.INFO)

        -- Check if this is a remote URI we should handle
        if target_uri:match("^scp://") or target_uri:match("^rsync://") then
            log("Handling remote definition target: " .. target_uri, vim.log.levels.INFO)

            -- Schedule opening the remote file with position
            vim.schedule(function()
                M.simple_open_remote_file(target_uri, position)
            end)
            return
        end

        -- For non-remote URIs, use the original handler
        return orig_definition_handler(err, result, ctx, config)
    end

    -- Also intercept other LSP location-based handlers
    local handlers_to_intercept = {
        "textDocument/references",
        "textDocument/implementation",
        "textDocument/typeDefinition",
        "textDocument/declaration"
    }

    for _, handler_name in ipairs(handlers_to_intercept) do
        local orig_handler = vim.lsp.handlers[handler_name]
        if orig_handler then
            vim.lsp.handlers[handler_name] = function(err, result, ctx, config)
                -- Reuse the same intercept logic as for definitions
                return vim.lsp.handlers["textDocument/definition"](err, result, ctx, config)
            end
        end
    end

    local original_jump_to_location = vim.lsp.util.jump_to_location

    vim.lsp.util.jump_to_location = function(location, offset_encoding, reuse_win)
        -- Check if this is a remote location first
        local uri = location.uri or location.targetUri

        if uri and (uri:match("^scp://") or uri:match("^rsync://")) then
            log("Intercepting LSP jump to remote location: " .. uri, vim.log.levels.DEBUG)

            -- Extract position information
            local position = location.range and location.range.start or
                             location.targetSelectionRange and location.targetSelectionRange.start

            -- Use our custom handler for remote files
            vim.schedule(function()
                M.simple_open_remote_file(uri, position)
            end)

            -- Return true to indicate we've handled it
            return true
        end

        -- For non-remote locations, use the original handler
        return original_jump_to_location(location, offset_encoding, reuse_win)
    end

    log("Set up remote file handlers for LSP and buffer commands", vim.log.levels.INFO)
end

-- Enhanced open_remote_file function with better error handling and logging
function M.open_remote_file(url, position)
    -- Add extensive logging at the start
    log("Opening remote file: " .. url, vim.log.levels.INFO)
    if position then
        log("With position - line: " .. position.line .. ", character: " .. position.character, vim.log.levels.DEBUG)
    end

    -- Parse URL using our enhanced function
    local remote_info = parse_remote_path(url)
    if not remote_info then
        notify("Not a supported remote URL format: " .. url, vim.log.levels.ERROR)
        log("Failed to parse remote URL: " .. url, vim.log.levels.ERROR)
        return
    end

    local protocol = remote_info.protocol
    local host = remote_info.host
    local path = remote_info.path

    log("Parsed remote URL - Protocol: " .. protocol .. ", Host: " .. host .. ", Path: " .. path, vim.log.levels.DEBUG)

    -- Check if buffer already exists and is loaded
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname == url then
                log("Buffer already loaded, switching to it: " .. url, vim.log.levels.DEBUG)
                vim.api.nvim_set_current_buf(bufnr)

                -- Jump to position if provided
                if position then
                    pcall(vim.api.nvim_win_set_cursor, 0, {position.line + 1, position.character})
                end

                return
            end
        end
    end

    -- Create a temporary local file
    local temp_file = vim.fn.tempname()
    log("Created temporary file: " .. temp_file, vim.log.levels.DEBUG)

    -- Build the appropriate command depending on if we have double slashes or not
    local remote_target
    if remote_info.has_double_slash then
        -- Keep the exact format as it appears in the URL
        remote_target = host .. ":" .. path
        log("Using double-slash format for remote target", vim.log.levels.DEBUG)
    else
        -- Standard format
        remote_target = host .. ":" .. vim.fn.shellescape(path)
    end

    -- Use scp/rsync to fetch the file
    local cmd
    if protocol == "scp" then
        cmd = {"scp", "-q", remote_target, temp_file}
    else -- rsync
        cmd = {"rsync", "-az", "--quiet", remote_target, temp_file}
    end

    log("Fetch command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG)
    -- Show status to user
    notify("Fetching remote file: " .. url, vim.log.levels.INFO)

    -- Run the command with detailed error logging
    local job_id = vim.fn.jobstart(cmd, {
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        log("Fetch stderr: " .. line, vim.log.levels.ERROR)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    log("Failed to fetch file with exit code " .. exit_code, vim.log.levels.ERROR)
                    notify("Failed to fetch remote file (exit code " .. exit_code .. ")", vim.log.levels.ERROR)

                    -- Try a fallback approach with an alternative command format
                    log("Trying fallback approach for fetching remote file", vim.log.levels.INFO)
                    local fallback_cmd
                    if protocol == "scp" then
                        if remote_info.has_double_slash then
                            -- Use a different format for double-slash paths
                            fallback_cmd = {"ssh", host, "cat " .. path .. " > " .. temp_file}
                        else
                            fallback_cmd = {"scp", "-q", host .. ":" .. vim.fn.shellescape(path), temp_file}
                        end
                    else
                        if remote_info.has_double_slash then
                            fallback_cmd = {"ssh", host, "cat " .. path .. " > " .. temp_file}
                        else
                            fallback_cmd = {"rsync", "-az", "--quiet", host .. ":" .. vim.fn.shellescape(path), temp_file}
                        end
                    end

                    log("Fallback command: " .. table.concat(fallback_cmd, " "), vim.log.levels.DEBUG)
                    notify("Trying alternative approach to fetch file...", vim.log.levels.INFO)

                    local fallback_job_id = vim.fn.jobstart(fallback_cmd, {
                        on_exit = function(_, fallback_exit_code)
                            if fallback_exit_code ~= 0 then
                                vim.schedule(function()
                                    log("Fallback fetch also failed with exit code " .. fallback_exit_code, vim.log.levels.ERROR)
                                    notify("Failed to fetch remote file with alternative method", vim.log.levels.ERROR)
                                end)
                            else
                                -- Process the successfully fetched file
                                process_fetched_file()
                            end
                        end
                    })

                    if fallback_job_id <= 0 then
                        log("Failed to start fallback fetch job", vim.log.levels.ERROR)
                        notify("Could not start alternative fetch method", vim.log.levels.ERROR)
                    end
                end)
                return
            end

            -- Success case - process the fetched file
            process_fetched_file()
        end
    })

    -- Function to process the fetched file and load it into a buffer
    function process_fetched_file()
        vim.schedule(function()
            -- Check if temp file exists and has content
            if vim.fn.filereadable(temp_file) ~= 1 then
                log("Temp file not readable: " .. temp_file, vim.log.levels.ERROR)
                notify("Failed to create readable temp file", vim.log.levels.ERROR)
                return
            end

            local filesize = vim.fn.getfsize(temp_file)
            log("Temp file size: " .. filesize .. " bytes", vim.log.levels.DEBUG)

            if filesize <= 0 then
                log("Temp file is empty, fetch may have failed", vim.log.levels.WARN)
                notify("Warning: Fetched file appears to be empty", vim.log.levels.WARN)
            end

            -- Create a new buffer
            local bufnr = vim.api.nvim_create_buf(true, false)
            log("Created new buffer with ID: " .. bufnr, vim.log.levels.DEBUG)

            -- Set the buffer name to the remote URL
            vim.api.nvim_buf_set_name(bufnr, url)

            -- Set buffer type to 'acwrite' to ensure BufWriteCmd is used
            vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')

            -- Read the temp file content
            local lines = vim.fn.readfile(temp_file)
            log("Read " .. #lines .. " lines from temp file", vim.log.levels.DEBUG)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

            -- Set the buffer as not modified
            vim.api.nvim_buf_set_option(bufnr, "modified", false)

            -- Display the buffer
            vim.api.nvim_set_current_buf(bufnr)

            -- Delete the temp file
            vim.fn.delete(temp_file)
            log("Deleted temp file", vim.log.levels.DEBUG)

            -- Set filetype
            local ext = vim.fn.fnamemodify(path, ":e")
            if ext and ext ~= "" then
                vim.filetype.match({ filename = path })
                log("Set filetype based on extension: " .. ext, vim.log.levels.DEBUG)
            end

            -- Jump to position if provided
            if position then
                pcall(vim.api.nvim_win_set_cursor, 0, {position.line + 1, position.character})
                log("Jumped to position: " .. position.line + 1 .. ":" .. position.character, vim.log.levels.DEBUG)
            end

            -- Register buffer-specific autocommands for saving
            M.register_buffer_autocommands(bufnr)

            -- Start LSP for this buffer
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    log("Starting LSP for new buffer", vim.log.levels.DEBUG)
                    require('remote-ssh').start_remote_lsp(bufnr)
                end
            end)

            notify("Remote file loaded successfully", vim.log.levels.INFO)
        end)
    end

    if job_id <= 0 then
        log("Failed to start fetch job, jobstart returned: " .. job_id, vim.log.levels.ERROR)
        notify("Failed to start fetch job", vim.log.levels.ERROR)
    else
        log("Started fetch job with ID: " .. job_id, vim.log.levels.DEBUG)
    end
end

function M.fetch_remote_content(host, path, callback)
    local cmd = {"ssh", host, "cat " .. vim.fn.shellescape(path)}
    local output = {}
    local stderr_output = {}

    log("Fetching content with command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG)

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    table.insert(output, line)
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                log("Failed to fetch remote content: " .. table.concat(stderr_output, "\n"), vim.log.levels.ERROR)
                callback(nil, stderr_output)
            else
                log("Successfully fetched " .. #output .. " lines of content", vim.log.levels.DEBUG)
                callback(output, nil)
            end
        end
    })

    if job_id <= 0 then
        log("Failed to start SSH job", vim.log.levels.ERROR)
        callback(nil, {"Failed to start SSH process"})
    end

    return job_id
end

function M.simple_open_remote_file(url, position)
    log("Opening remote file: " .. url, vim.log.levels.INFO)

    -- Parse remote URL
    local remote_info = parse_remote_path(url)
    if not remote_info then
        notify("Invalid remote URL: " .. url, vim.log.levels.ERROR)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Directly fetch content from remote server
    notify("Fetching remote file: " .. url, vim.log.levels.INFO)

    M.fetch_remote_content(host, path, function(content, error)
        if not content then
            notify("Error fetching remote file: " .. (error and table.concat(error, "; ") or "unknown error"), vim.log.levels.ERROR)
            return
        end

        vim.schedule(function()
            -- Check for existing buffer with this name
            local existing_bufnr

            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == url then
                    existing_bufnr = bufnr
                    break
                end
            end

            local bufnr
            if existing_bufnr then
                bufnr = existing_bufnr
                log("Reusing existing buffer: " .. bufnr, vim.log.levels.DEBUG)

                -- Make buffer modifiable
                local was_modifiable = vim.api.nvim_buf_get_option(bufnr, 'modifiable')
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
                end

                -- Clear and replace content
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)

                -- Restore modifiable state
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, 'modifiable', was_modifiable)
                end
            else
                -- Create new buffer
                bufnr = vim.api.nvim_create_buf(true, false)
                log("Created new buffer: " .. bufnr, vim.log.levels.DEBUG)

                -- Set buffer name
                vim.api.nvim_buf_set_name(bufnr, url)

                -- Set buffer content
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
            end

            vim.api.nvim_buf_set_option(bufnr, 'buflisted', true)  -- Make it show in buffer list
            vim.api.nvim_buf_set_option(bufnr, 'bufhidden', '')    -- Don't hide/delete when not visible
            vim.api.nvim_buf_set_option(bufnr, 'swapfile', true)   -- Use a swapfile (helps persistence)

            -- Set buffer type to 'acwrite' to ensure BufWriteCmd is used
            vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')

            -- Set the buffer as not modified
            vim.api.nvim_buf_set_option(bufnr, "modified", false)

            -- Display the buffer
            vim.api.nvim_set_current_buf(bufnr)

            -- Set filetype
            local ext = vim.fn.fnamemodify(path, ":e")
            if ext and ext ~= "" then
                vim.filetype.match({ filename = path })
            end

            if position then
                -- Defer the cursor positioning to ensure buffer is fully loaded
                vim.defer_fn(function()
                    if not vim.api.nvim_buf_is_valid(bufnr) then
                        return
                    end

                    -- Validate the position is within buffer boundaries
                    local line_count = vim.api.nvim_buf_line_count(bufnr)
                    local line = position.line + 1  -- LSP is 0-based, Vim is 1-based

                    -- Ensure line is valid
                    if line <= 0 then
                        line = 1
                    elseif line > line_count then
                        line = line_count
                    end

                    -- Get the line content to determine max character position
                    local line_content = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
                    local max_col = #line_content
                    local col = position.character

                    -- Ensure column is valid
                    if col > max_col then
                        col = max_col
                    elseif col < 0 then
                        col = 0
                    end

                    -- Now safely set the cursor position
                    log("Setting cursor to validated position: " .. line .. ":" .. col, vim.log.levels.DEBUG)
                    pcall(vim.api.nvim_win_set_cursor, 0, {line, col})
                end, 100)  -- Small delay to ensure buffer is ready
            end

            -- Register buffer-specific autocommands for saving
            M.register_buffer_autocommands(bufnr)

            -- Start LSP for this buffer
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    require('remote-ssh').start_remote_lsp(bufnr)
                end
            end)

            notify("Remote file loaded successfully", vim.log.levels.INFO)
        end)
    end)
end


function M.refresh_remote_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Check if buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        notify("Cannot refresh invalid buffer", vim.log.levels.ERROR)
        return false
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        notify("Not a remote buffer: " .. bufname, vim.log.levels.ERROR)
        return false
    end

    log("Refreshing remote buffer " .. bufnr .. ": " .. bufname, vim.log.levels.INFO)

    -- Parse remote path
    local remote_info = parse_remote_path(bufname)
    if not remote_info then
        notify("Failed to parse remote path: " .. bufname, vim.log.levels.ERROR)
        return false
    end

    -- Check if buffer is modified
    local is_modified = vim.api.nvim_buf_get_option(bufnr, 'modified')
    if is_modified then
        local choice = vim.fn.confirm(
            "Buffer is modified. Discard changes and refresh?",
            "&Yes\n&No",
            2
        )
        if choice ~= 1 then
            notify("Buffer refresh cancelled", vim.log.levels.INFO)
            return false
        end
    end

    -- Visual feedback for user
    notify("Refreshing remote file...", vim.log.levels.INFO)

    -- Fetch content from remote server
    M.fetch_remote_content(remote_info.host, remote_info.path, function(content, error)
        if not content then
            vim.schedule(function()
                notify("Error refreshing remote file: " .. (error and table.concat(error, "; ") or "unknown error"), vim.log.levels.ERROR)
            end)
            return
        end

        vim.schedule(function()
            -- Make sure buffer still exists
            if not vim.api.nvim_buf_is_valid(bufnr) then
                notify("Buffer no longer exists", vim.log.levels.ERROR)
                return
            end

            -- Store cursor position and view
            local win = vim.fn.bufwinid(bufnr)
            local cursor_pos = {0, 0}
            local view = nil

            if win ~= -1 then
                cursor_pos = vim.api.nvim_win_get_cursor(win)
                view = vim.fn.winsaveview()
            end

            -- Make buffer modifiable
            local was_modifiable = vim.api.nvim_buf_get_option(bufnr, 'modifiable')
            if not was_modifiable then
                vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
            end

            -- Clear and replace content
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)

            -- Mark buffer as unmodified
            vim.api.nvim_buf_set_option(bufnr, "modified", false)

            -- Restore modifiable state
            if not was_modifiable then
                vim.api.nvim_buf_set_option(bufnr, 'modifiable', was_modifiable)
            end

            -- Restore cursor position and view
            if win ~= -1 then
                -- Check if cursor position is still valid
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                if cursor_pos[1] <= line_count then
                    pcall(vim.api.nvim_win_set_cursor, win, cursor_pos)
                    if view then
                        pcall(vim.fn.winrestview, view)
                    end
                end
            end

            notify("Remote file refreshed successfully", vim.log.levels.INFO)
        end)
    end)

    return true
end


function M.debug_buffer_state(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Get basic buffer info
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
    local modified = vim.api.nvim_buf_get_option(bufnr, 'modified')
    local filetype = vim.api.nvim_buf_get_option(bufnr, 'filetype')

    -- Check if this buffer is in active_writes
    local in_active_writes = active_writes[bufnr] ~= nil

    -- Try to get autocommand info
    local autocmd_info = "Not available in Neovim API"
    if vim.fn.has('nvim-0.7') == 1 then
        -- For newer Neovim versions that support listing autocommands
        local augroup_id = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = false })
        if augroup_id then
            local autocmds = vim.api.nvim_get_autocmds({
                group = "AsyncRemoteWrite",
                pattern = {"scp://*", "rsync://*"}
            })
            autocmd_info = "Found " .. #autocmds .. " matching autocommands"
        else
            autocmd_info = "AsyncRemoteWrite augroup not found"
        end
    end

    -- Print diagnostic info
    vim.notify("===== Buffer Diagnostics =====", vim.log.levels.INFO)
    vim.notify("Buffer: " .. bufnr, vim.log.levels.INFO)
    vim.notify("Name: " .. bufname, vim.log.levels.INFO)
    vim.notify("Type: " .. buftype, vim.log.levels.INFO)
    vim.notify("Modified: " .. tostring(modified), vim.log.levels.INFO)
    vim.notify("Filetype: " .. filetype, vim.log.levels.INFO)
    vim.notify("In active_writes: " .. tostring(in_active_writes), vim.log.levels.INFO)
    vim.notify("Autocommands: " .. autocmd_info, vim.log.levels.INFO)

    -- Check if buffer matches our patterns
    local matches_scp = bufname:match("^scp://") ~= nil
    local matches_rsync = bufname:match("^rsync://") ~= nil
    vim.notify("Matches scp pattern: " .. tostring(matches_scp), vim.log.levels.INFO)
    vim.notify("Matches rsync pattern: " .. tostring(matches_rsync), vim.log.levels.INFO)

    -- Check for remote-ssh tracking
    local tracked_by_lsp = false
    if package.loaded['remote-ssh'] then
        local remote_ssh = require('remote-ssh')
        if remote_ssh.buffer_clients and remote_ssh.buffer_clients[bufnr] then
            tracked_by_lsp = true
        end
    end
    vim.notify("Tracked by LSP: " .. tostring(tracked_by_lsp), vim.log.levels.INFO)

    return {
        bufnr = bufnr,
        bufname = bufname,
        buftype = buftype,
        modified = modified,
        in_active_writes = in_active_writes,
        autocmd_info = autocmd_info,
        matches_pattern = matches_scp or matches_rsync
    }
end

function M.ensure_acwrite_state(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Check if buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Cannot ensure state of invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return false
    end

    -- Get buffer info
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    -- Skip if not a remote path
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false
    end

    -- Ensure buffer type is 'acwrite'
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
    if buftype ~= 'acwrite' then
        log("Fixing buffer type from '" .. buftype .. "' to 'acwrite' for buffer " .. bufnr, vim.log.levels.INFO)
        vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
    end

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Ensure autocommands exist
    if vim.fn.exists('#AsyncRemoteWrite#BufWriteCmd#' .. vim.fn.fnameescape(bufname)) == 0 then
        log("Autocommands for buffer do not exist, re-registering", vim.log.levels.WARN)

        -- Re-register autocommands specifically for this buffer
        local augroup = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = false })

        vim.api.nvim_create_autocmd("BufWriteCmd", {
            pattern = bufname,
            group = augroup,
            callback = function(ev)
                log("Re-registered BufWriteCmd triggered for " .. bufname, vim.log.levels.INFO)
                return M.start_save_process(ev.buf)
            end,
            desc = "Handle specific remote file saving asynchronously",
        })
    end

    return true
end

function M.setup_user_commands()
    -- Add a command to open remote files
    vim.api.nvim_create_user_command("RemoteOpen", function(opts)
        M.open_remote_file(opts.args)
    end, {
        nargs = 1,
        desc = "Open a remote file with scp:// or rsync:// protocol",
        complete = "file"
    })

    vim.api.nvim_create_user_command("RemoteRefresh", function(opts)
        local bufnr
        -- If args provided, try to find buffer by name
        if opts.args and opts.args ~= "" then
            -- Find buffer with matching name
            local found = false
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(buf) then
                    local bufname = vim.api.nvim_buf_get_name(buf)
                    if bufname:match(opts.args) then
                        bufnr = buf
                        found = true
                        break
                    end
                end
            end

            if not found then
                notify("No buffer found matching: " .. opts.args, vim.log.levels.ERROR)
                return
            end
        else
            -- Use current buffer
            bufnr = vim.api.nvim_get_current_buf()
        end

        M.refresh_remote_buffer(bufnr)
    end, {
        nargs = "?",
        desc = "Refresh a remote buffer by re-fetching its content",
        complete = "buffer"
    })

    -- Create command aliases to ensure compatibility with existing workflows
    vim.cmd [[
    command! -nargs=1 -complete=file Rscp RemoteOpen rsync://<args>
    command! -nargs=1 -complete=file Scp RemoteOpen scp://<args>
    command! -nargs=1 -complete=file E RemoteOpen <args>
    ]]
end

function M.register_buffer_autocommands(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Skip if buffer is not valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Cannot register autocommands for invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return false
    end

    -- Get buffer name
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    -- Skip if not a remote path
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false
    end

    log("Registering autocommands for buffer " .. bufnr .. ": " .. bufname, vim.log.levels.INFO)

    -- Ensure buffer type is correct
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
    if buftype ~= 'acwrite' then
        log("Setting buftype to 'acwrite' for buffer " .. bufnr, vim.log.levels.INFO)
        vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
    end

    -- Create an augroup specifically for this buffer
    local augroup_name = "AsyncRemoteWrite_Buffer_" .. bufnr
    local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

    -- Register BufWriteCmd specifically for this buffer
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,  -- This is key - use buffer instead of pattern for buffer-specific autocommand
        group = augroup,
        callback = function(ev)
            log("Buffer-specific BufWriteCmd triggered for buffer " .. ev.buf, vim.log.levels.INFO)

            -- Ensure netrw commands are disabled
            vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

            -- Try to start the save process
            local ok, result = pcall(function()
                return M.start_save_process(ev.buf)
            end)

            if not ok then
                log("Error in async save process: " .. tostring(result), vim.log.levels.ERROR)
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
                return true
            end

            if not result then
                log("Failed to start async save process", vim.log.levels.WARN)
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
            end

            return true
        end,
        desc = "Handle buffer-specific remote file saving asynchronously",
    })

    -- Also add a BufEnter command to ensure this buffer's autocommands stay registered
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = bufnr,
        group = augroup,
        callback = function()
            -- This ensures that if we return to this buffer, we maintain its autocommands
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    -- Check if the BufWriteCmd exists for this buffer
                    local has_autocmd = false
                    if vim.fn.has('nvim-0.7') == 1 then
                        local autocmds = vim.api.nvim_get_autocmds({
                            group = augroup_name,
                            event = "BufWriteCmd",
                            buffer = bufnr
                        })
                        has_autocmd = #autocmds > 0
                    end

                    if not has_autocmd then
                        log("BufWriteCmd missing on buffer enter, reregistering for buffer " .. bufnr, vim.log.levels.WARN)
                        M.register_buffer_autocommands(bufnr)
                    end
                end
            end, 10)  -- Small delay to ensure buffer is loaded
        end,
    })

    log("Successfully registered autocommands for buffer " .. bufnr, vim.log.levels.INFO)
    return true
end

-- Register autocmd to intercept write commands for remote files
function M.setup(opts)
    -- Apply configuration
    M.configure(opts)

    -- Completely disable netrw for these protocols
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Create a monitoring augroup for detecting new remote buffers
    local monitor_augroup = vim.api.nvim_create_augroup("AsyncRemoteWriteMonitor", { clear = true })

    -- Create a global fallback augroup - this handles files that haven't been properly registered yet
    local fallback_augroup = vim.api.nvim_create_augroup("AsyncRemoteWriteFallback", { clear = true })

    -- Register on BufReadPost to set up buffer-specific commands
    vim.api.nvim_create_autocmd("BufReadPost", {
        pattern = {"scp://*", "rsync://*"},
        group = monitor_augroup,
        callback = function(ev)
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    log("BufReadPost trigger for buffer " .. ev.buf, vim.log.levels.DEBUG)
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 50)  -- Small delay to ensure buffer is loaded
        end,
    })

    -- Add a FileType detection hook for catching buffers we might have missed
    vim.api.nvim_create_autocmd("FileType", {
        pattern = {"scp://*", "rsync://*"},
        group = monitor_augroup,
        callback = function(ev)
            local bufname = vim.api.nvim_buf_get_name(ev.buf)
            if bufname:match("^scp://") or bufname:match("^rsync://") then
                local url = ev.match
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(ev.buf) then
                        log("FileType trigger for remote buffer " .. ev.buf, vim.log.levels.DEBUG)
                        local lines = vim.api.nvim_buf_get_lines(ev.buf.bufnr, 0, -1, false)
                        local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")
                        if is_empty then
                            M.simple_open_remote_file(url)
                        end
                        M.register_buffer_autocommands(ev.buf)
                    end
                end, 50)  -- Small delay to ensure buffer is loaded
            end
        end,
    })

    -- Add a BufNew detection hook to catch buffers as they're created
    vim.api.nvim_create_autocmd("BufNew", {
        pattern = {"scp://*", "rsync://*"},
        group = monitor_augroup,
        callback = function(ev)
            local url = ev.match
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    log("BufNew trigger for buffer " .. ev.buf, vim.log.levels.DEBUG)
                    local lines = vim.api.nvim_buf_get_lines(ev.buf.bufnr, 0, -1, false)
                    local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")
                    if is_empty then
                        M.simple_open_remote_file(url)
                    end
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 100)  -- Small delay to ensure buffer is loaded
        end,
    })

    -- FALLBACK: Global pattern-based autocmds as a safety net
    -- These will catch any remote files that somehow missed our buffer-specific registration
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = fallback_augroup,
        callback = function(ev)
            -- Get buffer name for detailed logging
            local bufname = vim.api.nvim_buf_get_name(ev.buf)
            log("FALLBACK BufWriteCmd triggered for buffer " .. ev.buf .. ": " .. bufname, vim.log.levels.WARN)

            -- Double-check protocol and make absolutely sure netrw is disabled
            vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

            -- Register proper buffer-specific autocommands for next time
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 10)

            -- Try to start the save process
            local ok, result = pcall(function()
                return M.start_save_process(ev.buf)
            end)

            if not ok then
                -- If there was an error in the save process, log it but still return true
                log("Error in async save process: " .. tostring(result), vim.log.levels.ERROR)
                -- Set unmodified anyway to avoid repeated save attempts
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
                return true
            end

            if not result then
                -- If start_save_process returned false, log warning but still return true
                -- This prevents netrw from taking over
                log("Failed to start async save process, but preventing netrw fallback", vim.log.levels.WARN)
                -- Set unmodified anyway to avoid repeated save attempts
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
            end

            -- Always return true to prevent netrw fallback
            return true
        end,
        desc = "Fallback handler for remote file saving asynchronously",
    })

    -- Also intercept FileWriteCmd as a backup
    vim.api.nvim_create_autocmd("FileWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = fallback_augroup,
        callback = function(ev)
            log("FALLBACK FileWriteCmd triggered for " .. ev.file, vim.log.levels.WARN)

            -- Find which buffer has this file
            local bufnr = nil
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf) == ev.file then
                    bufnr = buf
                    break
                end
            end

            if not bufnr then
                log("No buffer found for " .. ev.file, vim.log.levels.ERROR)
                return true
            end

            -- Register proper buffer-specific autocommands for next time
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    M.register_buffer_autocommands(bufnr)
                end
            end, 10)

            -- Use the same handler as BufWriteCmd
            local ok, result = pcall(function()
                return M.start_save_process(bufnr)
            end)

            if not ok or not result then
                log("FileWriteCmd handler fallback: setting buffer as unmodified", vim.log.levels.WARN)
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)
            end

            return true
        end
    })

    -- Setup user commands
    M.setup_user_commands()

    -- Setup file handlers for LSP and buffer commands
    M.setup_file_handlers()

    -- Add user commands for write operations
    vim.api.nvim_create_user_command("AsyncWriteCancel", function()
        M.cancel_write()
    end, { desc = "Cancel ongoing asynchronous write operation" })

    vim.api.nvim_create_user_command("AsyncWriteStatus", function()
        M.get_status()
    end, { desc = "Show status of active asynchronous write operations" })

    -- Add force complete command
    vim.api.nvim_create_user_command("AsyncWriteForceComplete", function(opts)
        local success = opts.bang
        M.force_complete(nil, success)
    end, {
        desc = "Force complete a stuck write operation (! to mark as success)",
        bang = true
    })

    -- Add debug command
    vim.api.nvim_create_user_command("AsyncWriteDebug", function()
        config.debug = not config.debug
        notify("Async write debugging " .. (config.debug and "enabled" or "disabled"), vim.log.levels.INFO)
    end, { desc = "Toggle debugging for async write operations" })

    -- Add reregister command for manual fixing of buffer autocommands
    vim.api.nvim_create_user_command("AsyncWriteReregister", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local result = M.register_buffer_autocommands(bufnr)
        if result then
            notify("Successfully reregistered autocommands for buffer " .. bufnr, vim.log.levels.INFO)
        else
            notify("Failed to reregister autocommands (not a remote buffer?)", vim.log.levels.WARN)
        end
    end, { desc = "Reregister buffer-specific autocommands for current buffer" })

    -- Register autocommands for any already-open remote buffers
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match("^scp://") or bufname:match("^rsync://") then
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.register_buffer_autocommands(bufnr)
                    end
                end, 100)
            end
        end
    end

    log("Async write module initialized with configuration: " .. vim.inspect(config))
end

return M
