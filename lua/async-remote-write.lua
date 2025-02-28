local M = {}

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp, ...}
local active_writes = {}

-- Keep buffer content snapshots
-- Map of bufnr -> {lines = {}, timestamp = timestamp}
local buffer_snapshots = {}

-- Configuration
local config = {
    timeout = 30,          -- Default timeout in seconds
    debug = false,         -- Debug mode
    check_interval = 1000, -- Status check interval in ms
    return_delay = 10,     -- Short delay (ms) for initial return from write
}

-- LSP integration callbacks
local lsp_integration = {
    notify_save_start = function(bufnr) end,
    notify_save_end = function(bufnr) end
}

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

    -- Match host and path, handling patterns correctly
    local host, path = bufname:match("^" .. protocol .. "://([^/]+)/(.+)$")
    if not host or not path then
        return nil
    end

    -- Clean up path (remove any double slashes)
    path = path:gsub("^/+", "/")

    return {
        protocol = protocol,
        host = host,
        path = path,
        full = bufname
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

-- Take a snapshot of the buffer content
local function take_buffer_snapshot(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Cannot take snapshot - invalid buffer: " .. bufnr)
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local snapshot = {
        lines = lines,
        timestamp = os.time()
    }

    buffer_snapshots[bufnr] = snapshot
    log("Snapshot taken for buffer " .. bufnr .. " with " .. #lines .. " lines")

    return snapshot
end

-- Create a temporary file with the buffer snapshot
local function create_temp_file_from_snapshot(bufnr, callback)
    local snapshot = buffer_snapshots[bufnr]
    if not snapshot then
        log("No snapshot found for buffer " .. bufnr, vim.log.levels.ERROR)
        callback(nil, nil)
        return
    end

    -- Schedule this operation to happen after returning to the main loop
    vim.schedule(function()
        local temp_dir = vim.fn.tempname()
        vim.fn.mkdir(temp_dir, "p")
        local temp_file = temp_dir .. "/temp_file"

        -- Write the snapshot contents to temp file
        local ok = pcall(vim.fn.writefile, snapshot.lines, temp_file)

        if ok and vim.fn.filereadable(temp_file) == 1 then
            callback(temp_file, temp_dir)
        else
            log("Failed to create temporary file", vim.log.levels.ERROR)
            callback(nil, nil)
        end
    end)
end

-- Show a notification in the status line
local function notify(msg, level)
    vim.schedule(function()
        level = level or vim.log.levels.INFO
        vim.notify(msg, level)

        -- Also update the status line if possible
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

-- Function to ensure remote directory exists asynchronously
local function ensure_remote_dir(remote_path, callback)
    local host = remote_path.host
    local path = remote_path.path
    local dir = vim.fn.fnamemodify(path, ":h")

    log("Ensuring remote directory exists: " .. dir)

    -- Use ssh to create the directory if it doesn't exist - ASYNCHRONOUSLY
    local cmd = {"ssh", host, "mkdir", "-p", dir}

    local job_id = vim.fn.jobstart(cmd, {
        on_exit = function(_, exit_code)
            if exit_code == 0 then
                log("Remote directory created successfully")
                callback(true)
            else
                log("Failed to create remote directory", vim.log.levels.ERROR)
                callback(false)
            end
        end,
        stdout_buffered = true,
        stderr_buffered = true
    })

    if job_id <= 0 then
        log("Failed to start directory creation job", vim.log.levels.ERROR)
        callback(false)
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

    log(string.format("Write complete for buffer %d with exit code %d", bufnr, exit_code))

    -- Safely stop and close timer if it exists
    if write_info.timer then
        safe_close_timer(write_info.timer)
        write_info.timer = nil
    end

    -- Clean up temp file
    vim.schedule(function()
        if write_info.temp_file and vim.fn.filereadable(write_info.temp_file) == 1 then
            pcall(vim.fn.delete, write_info.temp_file)
        end
        if write_info.temp_dir and vim.fn.isdirectory(write_info.temp_dir) == 1 then
            pcall(vim.fn.delete, write_info.temp_dir, "rf")
        end

        -- Clean up snapshot
        buffer_snapshots[bufnr] = nil
    end)

    -- Store the write info temporarily and remove from active writes table
    -- This prevents potential race conditions if callbacks fire multiple times
    local completed_info = vim.deepcopy(write_info)
    active_writes[bufnr] = nil

    -- Notify LSP module that save is complete
    vim.schedule(function()
        lsp_integration.notify_save_end(bufnr)
    end)

    -- Handle success or failure
    if exit_code == 0 then
        -- Get duration
        local duration = os.time() - completed_info.start_time
        local duration_str = duration > 1 and (duration .. "s") or "less than a second"

        -- Set unmodified if this buffer still exists
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)

                -- Update status line
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                notify(string.format("✓ File '%s' saved in %s", vim.fn.fnamemodify(bufname, ":t"), duration_str))
            else
                notify(string.format("✓ File saved in %s (buffer no longer exists)", duration_str))
            end
        end)
    else
        local error_info = error_msg or ""
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                notify(string.format("❌ Failed to save '%s': %s", vim.fn.fnamemodify(bufname, ":t"), error_info), vim.log.levels.ERROR)
            else
                notify(string.format("❌ Failed to save file: %s", error_info), vim.log.levels.ERROR)
            end
        end)
    end
end

-- Set up a timer to monitor job progress
local function setup_job_timer(bufnr)
    local timer = vim.loop.new_timer()

    -- Check job status every second
    timer:start(1000, config.check_interval, vim.schedule_wrap(function()
        -- Check if write info still exists
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

            -- Force completion
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 0)
            end)

            safe_close_timer(timer)
        elseif elapsed > config.timeout then
            -- Job timed out
            log("Job timed out after " .. elapsed .. " seconds", vim.log.levels.WARN)

            -- Try to stop the job
            pcall(vim.fn.jobstop, write_info.job_id)

            -- Force completion with error
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 1, "Timeout after " .. elapsed .. " seconds")
            end)

            safe_close_timer(timer)
        end
    end))

    return timer
end

-- Perform asynchronous write for SCP
function M.async_write_scp(bufnr, remote_path, temp_file, temp_dir)
    local start_time = os.time()

    -- Format destination properly for scp
    local destination = remote_path.host .. ":" .. remote_path.path

    log("SCP destination: " .. destination)

    -- Use scp command to upload the file
    local cmd = {"scp", "-q", temp_file, destination}

    notify(string.format("💾 Saving '%s' in background...", vim.fn.fnamemodify(remote_path.path, ":t")))

    -- Create job wrapper with error handling
    local job_id
    local on_exit_wrapper = vim.schedule_wrap(function(_, exit_code)
        -- Prevent handling if job is no longer tracked
        if not active_writes[bufnr] or active_writes[bufnr].job_id ~= job_id then
            log("Ignoring exit for job " .. job_id .. " (no longer tracked)")
            return
        end

        on_write_complete(bufnr, job_id, exit_code)
    end)

    job_id = vim.fn.jobstart(cmd, {
        on_exit = on_exit_wrapper,
        stdout_buffered = true,
        stderr_buffered = true,
    })

    if job_id <= 0 then
        notify("❌ Failed to start save job", vim.log.levels.ERROR)
        return false
    end

    -- Set up timer for this job
    local timer = setup_job_timer(bufnr)

    -- Store write info
    active_writes[bufnr] = {
        job_id = job_id,
        start_time = start_time,
        temp_file = temp_file,
        temp_dir = temp_dir,
        remote_path = remote_path,
        timer = timer,
        type = "scp",
        completed = false
    }

    return true
end

-- Perform asynchronous write for rsync
function M.async_write_rsync(bufnr, remote_path, temp_file, temp_dir)
    local start_time = os.time()

    -- Format destination properly for rsync
    local destination = remote_path.host .. ":" .. remote_path.path

    log("Rsync destination: " .. destination)

    -- Use rsync command to upload the file
    local cmd = {"rsync", "-az", temp_file, destination}

    notify(string.format("💾 Saving '%s' in background...", vim.fn.fnamemodify(remote_path.path, ":t")))

    -- Create job wrapper with error handling
    local job_id
    local on_exit_wrapper = vim.schedule_wrap(function(_, exit_code)
        -- Prevent handling if job is no longer tracked
        if not active_writes[bufnr] or active_writes[bufnr].job_id ~= job_id then
            log("Ignoring exit for job " .. job_id .. " (no longer tracked)")
            return
        end

        on_write_complete(bufnr, job_id, exit_code)
    end)

    job_id = vim.fn.jobstart(cmd, {
        on_exit = on_exit_wrapper,
        on_stderr = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        log("rsync stderr: " .. line, vim.log.levels.WARN)
                    end
                end
            end
        end,
        stdout_buffered = true,
    })

    if job_id <= 0 then
        notify("❌ Failed to start save job", vim.log.levels.ERROR)
        return false
    end

    -- Set up timer for this job
    local timer = setup_job_timer(bufnr)

    -- Store write info
    active_writes[bufnr] = {
        job_id = job_id,
        start_time = start_time,
        temp_file = temp_file,
        temp_dir = temp_dir,
        remote_path = remote_path,
        timer = timer,
        type = "rsync",
        completed = false
    }

    return true
end

-- Initialize the save process by taking a buffer snapshot
-- This is the ONLY part that runs in the BufWriteCmd context
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Check if there's already a write in progress
    if active_writes[bufnr] then
        log("A save operation is already in progress for buffer " .. bufnr, vim.log.levels.WARN)

        -- Schedule a notification to avoid blocking
        vim.schedule(function()
            notify("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN)
        end)

        return true -- Still return true to indicate we're handling the write
    end

    -- Get buffer name
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    -- Quick check if this is a remote path (this is fast)
    if not bufname:match("^scp://") and not bufname:match("^rsync://") then
        log("Not a remote path: " .. bufname)
        return false
    end

    -- Take a snapshot of the buffer content (this is the only potentially slow operation)
    local snapshot = take_buffer_snapshot(bufnr)
    if not snapshot then
        log("Failed to take buffer snapshot", vim.log.levels.ERROR)
        return false
    end

    -- Schedule the actual save process to run after this handler returns
    -- This is key to preventing the initial blocking
    vim.defer_fn(function()
        M.continue_save_process(bufnr)
    end, config.return_delay)

    -- Notify that save is starting (visual feedback)
    vim.schedule(function()
        notify(string.format("💾 Preparing to save '%s'...", vim.fn.fnamemodify(bufname, ":t")))
    end)

    -- We're handling the write
    return true
end

-- Continue the save process after the BufWriteCmd handler has returned
function M.continue_save_process(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Buffer " .. bufnr .. " is no longer valid", vim.log.levels.WARN)

        -- Clean up snapshot
        buffer_snapshots[bufnr] = nil
        return
    end

    -- Get buffer name
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local remote_path = parse_remote_path(bufname)

    if not remote_path then
        log(string.format("Not a remote path: %s", bufname), vim.log.levels.WARN)

        -- Clean up snapshot
        buffer_snapshots[bufnr] = nil
        return
    end

    -- Notify LSP module that save is starting
    lsp_integration.notify_save_start(bufnr)

    log("Remote path info: " .. vim.inspect(remote_path))

    -- Ensure remote directory exists asynchronously
    ensure_remote_dir(remote_path, function(dir_success)
        if not dir_success then
            -- Notify LSP module that save failed
            vim.schedule(function()
                lsp_integration.notify_save_end(bufnr)
                notify("❌ Failed to create remote directory", vim.log.levels.ERROR)

                -- Clean up snapshot
                buffer_snapshots[bufnr] = nil
            end)
            return
        end

        -- Create temp file asynchronously from snapshot
        create_temp_file_from_snapshot(bufnr, function(temp_file, temp_dir)
            if not temp_file or vim.fn.filereadable(temp_file) ~= 1 then
                -- Notify LSP module that save failed
                vim.schedule(function()
                    lsp_integration.notify_save_end(bufnr)
                    notify("❌ Failed to create temporary file", vim.log.levels.ERROR)

                    -- Clean up snapshot
                    buffer_snapshots[bufnr] = nil
                end)
                return
            end

            -- Call the appropriate write function based on protocol
            local success = false
            if remote_path.protocol == "scp" then
                success = M.async_write_scp(bufnr, remote_path, temp_file, temp_dir)
            elseif remote_path.protocol == "rsync" then
                success = M.async_write_rsync(bufnr, remote_path, temp_file, temp_dir)
            else
                vim.schedule(function()
                    notify(string.format("Unsupported protocol: %s", remote_path.protocol), vim.log.levels.ERROR)
                    vim.fn.delete(temp_file)
                    lsp_integration.notify_save_end(bufnr)

                    -- Clean up snapshot
                    buffer_snapshots[bufnr] = nil
                end)
                success = false
            end

            -- If we failed to start the save, notify LSP module and clean up
            if not success then
                vim.schedule(function()
                    lsp_integration.notify_save_end(bufnr)

                    -- Clean up snapshot
                    buffer_snapshots[bufnr] = nil
                end)
            end
        end)
    end)
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
    local stopped = pcall(vim.fn.jobstop, write_info.job_id)

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
        local bufname = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or "unknown"

        table.insert(details, {
            bufnr = bufnr,
            name = vim.fn.fnamemodify(bufname, ":t"),
            elapsed = elapsed,
            protocol = info.remote_path.protocol,
            host = info.remote_path.host,
            job_id = info.job_id,
            type = info.type
        })
    end

    notify(string.format("Active write operations: %d", count), vim.log.levels.INFO)

    for _, detail in ipairs(details) do
        notify(string.format("  Buffer %d: %s (%s to %s) - running for %ds (job %d)",
            detail.bufnr, detail.name, detail.type, detail.host, detail.elapsed, detail.job_id),
            vim.log.levels.INFO)
    end

    -- Also show pending snapshots
    local snapshot_count = 0
    for bufnr, _ in pairs(buffer_snapshots) do
        if not active_writes[bufnr] then
            snapshot_count = snapshot_count + 1
            local bufname = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or "unknown"
            notify(string.format("  Buffer %d: %s (snapshot pending write)",
                bufnr, vim.fn.fnamemodify(bufname, ":t")),
                vim.log.levels.INFO)
        end
    end

    return {
        count = count,
        details = details,
        snapshots = snapshot_count
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

    if opts.return_delay then
        config.return_delay = opts.return_delay
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

-- Register autocmd to intercept write commands for remote files
function M.setup(opts)
    -- Apply configuration
    M.configure(opts)

    -- Create an autocmd group
    local augroup = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = true })

    -- Intercept BufWriteCmd for scp:// and rsync:// files
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            -- This is the ONLY part that runs in the BufWriteCmd context!
            -- It must be extremely fast to avoid blocking
            local success = M.start_save_process(ev.buf)

            -- If start_save_process failed, fallback to synchronous write
            if not success then
                -- Schedule this to avoid blocking
                vim.schedule(function()
                    notify("Falling back to synchronous write...", vim.log.levels.WARN)
                end)
                vim.cmd("noautocmd w")
            end
        end,
    })

    -- Add user commands
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

    log("Async write module initialized with configuration: " .. vim.inspect(config))
end

-- Expose API for testing/debugging
M._config = config
M._active_writes = active_writes
M._buffer_snapshots = buffer_snapshots

return M
