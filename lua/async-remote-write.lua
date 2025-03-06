local M = {}

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp, ...}
local active_writes = {}

-- Configuration
local config = {
    timeout = 30,          -- Default timeout in seconds
    debug = false,         -- Debug mode
    check_interval = 1000, -- Status check interval in ms
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

-- Generate a unique temporary filename
local function get_temp_file_path()
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/tempfile"
    return temp_file, temp_dir
end

-- Perform remote file transfer using file already written to disk
local function transfer_temp_file(bufnr, temp_file, temp_dir, remote_path)
    -- Ensure remote directory exists
    local dir = vim.fn.fnamemodify(remote_path.path, ":h")
    local mkdir_cmd = {"ssh", remote_path.host, "mkdir", "-p", dir}

    -- Start remote directory creation
    local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_exit = function(_, mkdir_exit_code)
            if mkdir_exit_code ~= 0 then
                vim.schedule(function()
                    log("Failed to create remote directory", vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end

            -- Now do the actual file transfer
            local start_time = os.time()
            local cmd, destination

            if remote_path.protocol == "scp" then
                destination = remote_path.host .. ":" .. remote_path.path
                cmd = {"scp", "-q", temp_file, destination}
            elseif remote_path.protocol == "rsync" then
                destination = remote_path.host .. ":" .. remote_path.path
                cmd = {"rsync", "-az", temp_file, destination}
            else
                vim.schedule(function()
                    log("Unsupported protocol: " .. remote_path.protocol, vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end

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
                vim.schedule(function()
                    notify("❌ Failed to start save job", vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
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
                type = remote_path.protocol,
                completed = false
            }
        end
    })

    if mkdir_job <= 0 then
        vim.schedule(function()
            notify("❌ Failed to ensure remote directory", vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
    end
end

-- Start the save process using a rapid write to temp file first
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Check if there's already a write in progress
    if active_writes[bufnr] then
        -- Schedule notification to avoid blocking
        vim.schedule(function()
            notify("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN)
        end)
        return true -- Still return true to indicate we're handling the write
    end

    vim.schedule(function ()
        notify("Remote buffer save starting", vim.log.levels.INFO)
    end)

    -- Get buffer name and check if it's a remote path (quick check)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local protocol

    if bufname:match("^scp://") then
        protocol = "scp"
    elseif bufname:match("^rsync://") then
        protocol = "rsync"
    else
        return false
    end

    -- Parse remote path
    local remote_path = parse_remote_path(bufname)
    if not remote_path then
        vim.schedule(function()
            log(string.format("Not a valid remote path: %s", bufname), vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Generate a temporary file path
    local temp_file, temp_dir = get_temp_file_path()
    if not temp_file then
        vim.schedule(function()
            log("Failed to create temporary file", vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Notify LSP immediately that we're saving (this is fast)
    lsp_integration.notify_save_start(bufnr)

    -- Schedule visual feedback for user
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            local short_name = vim.fn.fnamemodify(bufname, ":t")
            notify(string.format("💾 Saving '%s' in background...", short_name))
        end
    end)

    -- Write buffer to temp file - this is extremely fast as it uses Vim's internal file writing
    -- which is highly optimized (even for large files)
    local write_cmd = string.format("silent noautocmd write! %s", vim.fn.fnameescape(temp_file))

    -- Execute the write command to create the temp file
    local ok, err = pcall(vim.cmd, write_cmd)
    if not ok then
        vim.schedule(function()
            log("Failed to write temporary file: " .. tostring(err), vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Now we have the temp file, we can do the transfer completely asynchronously
    transfer_temp_file(bufnr, temp_file, temp_dir, remote_path)

    -- Return true immediately to indicate we're handling the write
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
            -- This will use the fast temp file approach
            local success = M.start_save_process(ev.buf)
            if success then
                return true -- tell vim the handling of BufWriteCmd was completed
            else
                -- Schedule this to avoid blocking
                vim.schedule(function()
                    notify("Falling back to synchronous netrw write...", vim.log.levels.WARN)
                end)
            end
        end,
        desc = "Handle remote file saving asynchronously",
        priority = 1000  -- Highest priority
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

-- Helper to estimate the buffer size
function M.get_buffer_stats(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    
    -- Sample a few lines to estimate size
    local sample_size = math.min(line_count, 100)
    local sample_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, sample_size, false), "\n")
    local avg_line_size = #sample_text / sample_size
    local estimated_size = avg_line_size * line_count
    
    return {
        line_count = line_count,
        estimated_size = estimated_size,
        estimated_kb = math.floor(estimated_size / 1024),
        avg_line_size = avg_line_size
    }
end

return M
