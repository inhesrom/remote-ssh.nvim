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
        vim.notify("[AsyncWrite] " .. msg, level)
    end
end

-- Create a temporary file with the buffer content
local function create_temp_file(bufnr)
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/temp_file"
    
    -- Get all lines from buffer and write to temp file
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.fn.writefile(lines, temp_file)
    
    return temp_file, temp_dir
end

-- Show a notification in the status line
local function notify(msg, level)
    level = level or vim.log.levels.INFO
    vim.notify(msg, level)
    
    -- Also update the status line if possible
    pcall(function()
        if vim.o.laststatus >= 2 then  -- Status line is visible
            vim.cmd("redrawstatus")
        end
    end)
end

-- Handle job timeout
local function check_timeouts()
    local now = os.time()
    local to_complete = {}
    
    for bufnr, info in pairs(active_writes) do
        local elapsed = now - info.start_time
        if elapsed > config.timeout then
            table.insert(to_complete, {
                bufnr = bufnr,
                job_id = info.job_id,
                elapsed = elapsed
            })
        end
    end
    
    for _, item in ipairs(to_complete) do
        log(string.format("Job for buffer %d timed out after %d seconds", item.bufnr, item.elapsed), vim.log.levels.WARN)
        
        -- Try to stop the job
        pcall(vim.fn.jobstop, item.job_id)
        
        -- Force completion with error
        vim.schedule(function()
            on_write_complete(item.bufnr, item.job_id, 1, "Timeout after " .. item.elapsed .. " seconds")
        end)
    end
end

-- Function to ensure remote directory exists
local function ensure_remote_dir(remote_path)
    local host = remote_path.host
    local path = remote_path.path
    local dir = vim.fn.fnamemodify(path, ":h")
    
    log("Ensuring remote directory exists: " .. dir)
    
    -- Use ssh to create the directory if it doesn't exist
    local cmd = {"ssh", host, "mkdir", "-p", dir}
    
    local result = vim.fn.system(cmd)
    local success = vim.v.shell_error == 0
    
    if not success then
        log("Failed to create directory: " .. result, vim.log.levels.ERROR)
    end
    
    return success
end

-- Function to handle write completion
function on_write_complete(bufnr, job_id, exit_code, error_msg)
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
    
    -- Stop any timer
    if write_info.timer then
        write_info.timer:stop()
        write_info.timer:close()
    end
    
    -- Clean up temp file
    if write_info.temp_file and vim.fn.filereadable(write_info.temp_file) == 1 then
        vim.fn.delete(write_info.temp_file)
    end
    if write_info.temp_dir and vim.fn.isdirectory(write_info.temp_dir) == 1 then
        vim.fn.delete(write_info.temp_dir, "rf")
    end
    
    -- Remove from active writes before any potential errors
    active_writes[bufnr] = nil
    
    -- Handle success or failure
    if exit_code == 0 then
        -- Get duration
        local duration = os.time() - write_info.start_time
        local duration_str = duration > 1 and (duration .. "s") or "less than a second"
        
        -- Set unmodified if this buffer still exists
        if vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)
            
            -- Update status line
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            notify(string.format("✓ File '%s' saved in %s", vim.fn.fnamemodify(bufname, ":t"), duration_str))
        else
            notify(string.format("✓ File saved in %s (buffer no longer exists)", duration_str))
        end
    else
        local error_info = error_msg or ""
        if vim.api.nvim_buf_is_valid(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            notify(string.format("❌ Failed to save '%s': %s", vim.fn.fnamemodify(bufname, ":t"), error_info), vim.log.levels.ERROR)
        else
            notify(string.format("❌ Failed to save file: %s", error_info), vim.log.levels.ERROR)
        end
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
            timer:stop()
            timer:close()
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
            
            timer:stop()
            timer:close()
        elseif elapsed > config.timeout then
            -- Job timed out
            log("Job timed out after " .. elapsed .. " seconds", vim.log.levels.WARN)
            
            -- Try to stop the job
            pcall(vim.fn.jobstop, write_info.job_id)
            
            -- Force completion with error
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 1, "Timeout after " .. elapsed .. " seconds")
            end)
            
            timer:stop()
            timer:close()
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
    
    local job_id = vim.fn.jobstart(cmd, {
        on_exit = vim.schedule_wrap(function(_, exit_code)
            on_write_complete(bufnr, job_id, exit_code)
        end),
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
        type = "scp"
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
    
    local job_id = vim.fn.jobstart(cmd, {
        on_exit = vim.schedule_wrap(function(_, exit_code)
            on_write_complete(bufnr, job_id, exit_code)
        end),
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
        type = "rsync"
    }
    
    return true
end

-- Main write handler function
function M.async_write(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    
    -- Check if there's already a write in progress
    if active_writes[bufnr] then
        notify("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN)
        return false
    end
    
    -- Get buffer name
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local remote_path = parse_remote_path(bufname)
    
    if not remote_path then
        log(string.format("Not a remote path: %s", bufname), vim.log.levels.WARN)
        return false
    end
    
    log("Remote path info: " .. vim.inspect(remote_path))
    
    -- Ensure remote directory exists
    if not ensure_remote_dir(remote_path) then
        notify("❌ Failed to create remote directory", vim.log.levels.ERROR)
        return false
    end
    
    -- Create temp file with buffer content
    local temp_file, temp_dir = create_temp_file(bufnr)
    if not temp_file or vim.fn.filereadable(temp_file) ~= 1 then
        notify("❌ Failed to create temporary file", vim.log.levels.ERROR)
        return false
    end
    
    -- Call the appropriate write function based on protocol
    if remote_path.protocol == "scp" then
        return M.async_write_scp(bufnr, remote_path, temp_file, temp_dir)
    elseif remote_path.protocol == "rsync" then
        return M.async_write_rsync(bufnr, remote_path, temp_file, temp_dir)
    else
        notify(string.format("Unsupported protocol: %s", remote_path.protocol), vim.log.levels.ERROR)
        vim.fn.delete(temp_file)
        return false
    end
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
            local success = M.async_write(ev.buf)
            -- If async write failed, fallback to synchronous write
            if not success then
                notify("Falling back to synchronous write...", vim.log.levels.WARN)
                vim.cmd("noautocmd w")
            end
        end,
    })
    
    -- Add user commands
    vim.api.nvim_create_user_command("AsyncWriteCancel", function()
        M.cancel_write()
    end, { desc = "Cancel ongoing asynchronous write operation" })
    
    vim.api.nvim_create_user_command("AsyncWriteStatus", function()
        local status = M.get_status()
        if status.count == 0 then
            notify("No active write operations", vim.log.levels.INFO)
        else
            notify(string.format("%d active write operation(s):", status.count), vim.log.levels.INFO)
            for _, detail in ipairs(status.details) do
                notify(string.format("  Buffer %d: %s (%s to %s) - running for %ds (job %d)", 
                    detail.bufnr, detail.name, detail.type, detail.host, detail.elapsed, detail.job_id), 
                    vim.log.levels.INFO)
            end
        end
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

return M
