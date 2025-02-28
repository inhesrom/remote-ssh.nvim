local M = {}

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp}
local active_writes = {}

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

-- Create a temporary file with the buffer content
local function create_temp_file(bufnr)
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/temp_file"
    
    -- Get all lines from buffer and write to temp file
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.fn.writefile(lines, temp_file)
    
    return temp_file
end

-- Show a notification in the status line
local function notify(msg, level)
    level = level or vim.log.levels.INFO
    vim.notify(msg, level)
    
    -- Also update the status line if possible
    if vim.o.laststatus >= 2 then  -- Status line is visible
        vim.cmd("redrawstatus")
    end
end

-- Function to ensure remote directory exists
local function ensure_remote_dir(remote_path)
    local host = remote_path.host
    local path = remote_path.path
    local dir = vim.fn.fnamemodify(path, ":h")
    
    -- Log what we're doing
    vim.notify("Ensuring remote directory exists: " .. dir, vim.log.levels.DEBUG)
    
    -- Use ssh to create the directory if it doesn't exist
    local cmd = {"ssh", host, "mkdir", "-p", dir}
    
    local job_id = vim.fn.jobstart(cmd, {
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                notify(string.format("❌ Failed to create directory on remote host: %s", dir), vim.log.levels.ERROR)
            end
        end,
        stdout_buffered = true,
        stderr_buffered = true,
    })
    
    -- Wait for the directory creation to complete
    vim.fn.jobwait({job_id}, 5000)  -- Wait up to 5 seconds
    
    return true
end

-- Function to handle write completion
local function on_write_complete(bufnr, job_id, exit_code)
    local write_info = active_writes[bufnr]
    if not write_info or write_info.job_id ~= job_id then
        -- This write operation was already handled or superseded
        return
    end
    
    -- Clean up temp file
    if write_info.temp_file and vim.fn.filereadable(write_info.temp_file) == 1 then
        vim.fn.delete(write_info.temp_file)
    end
    if write_info.temp_dir and vim.fn.isdirectory(write_info.temp_dir) == 1 then
        vim.fn.delete(write_info.temp_dir, "rf")
    end
    
    -- Remove from active writes
    active_writes[bufnr] = nil
    
    -- Handle success or failure
    if exit_code == 0 then
        -- Get duration
        local duration = os.time() - write_info.start_time
        local duration_str = duration > 1 and (duration .. "s") or "less than a second"
        
        -- Set unmodified if this buffer still exists
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_set_option(bufnr, "modified", false)
            
            -- Update status line
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            notify(string.format("✓ File '%s' saved in %s", vim.fn.fnamemodify(bufname, ":t"), duration_str))
        else
            notify(string.format("✓ File saved in %s (buffer no longer exists)", duration_str))
        end
    else
        if vim.api.nvim_buf_is_valid(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            notify(string.format("❌ Failed to save '%s'", vim.fn.fnamemodify(bufname, ":t")), vim.log.levels.ERROR)
        else
            notify("❌ Failed to save file (buffer no longer exists)", vim.log.levels.ERROR)
        end
    end
end

-- Perform asynchronous write for SCP
function M.async_write_scp(bufnr, remote_path, temp_file)
    local start_time = os.time()
    
    -- Format destination properly for scp
    local destination = remote_path.host .. ":" .. remote_path.path
    
    -- Debug output
    vim.notify("SCP destination: " .. destination, vim.log.levels.DEBUG)
    
    -- Use scp command to upload the file
    local cmd = {"scp", "-q", temp_file, destination}
    
    notify(string.format("💾 Saving '%s' in background...", vim.fn.fnamemodify(remote_path.path, ":t")))
    
    local job_id = vim.fn.jobstart(cmd, {
        on_exit = function(_, exit_code)
            vim.schedule(function()
                on_write_complete(bufnr, job_id, exit_code)
            end)
        end,
        stdout_buffered = true,
        stderr_buffered = true,
    })
    
    if job_id <= 0 then
        notify("❌ Failed to start save job", vim.log.levels.ERROR)
        return false
    end
    
    active_writes[bufnr] = {
        job_id = job_id,
        start_time = start_time,
        temp_file = temp_file,
        temp_dir = vim.fn.fnamemodify(temp_file, ":h"),
        remote_path = remote_path
    }
    
    return true
end

-- Perform asynchronous write for rsync
function M.async_write_rsync(bufnr, remote_path, temp_file)
    local start_time = os.time()
    
    -- Format destination properly for rsync
    local destination = remote_path.host .. ":" .. remote_path.path
    
    -- Debug output
    vim.notify("Rsync destination: " .. destination, vim.log.levels.DEBUG)
    
    -- Use rsync command to upload the file
    local cmd = {"rsync", "-az", temp_file, destination}
    
    notify(string.format("💾 Saving '%s' in background...", vim.fn.fnamemodify(remote_path.path, ":t")))
    
    local job_id = vim.fn.jobstart(cmd, {
        on_exit = function(_, exit_code)
            vim.schedule(function()
                on_write_complete(bufnr, job_id, exit_code)
            end)
        end,
        stdout_buffered = true,
        stderr_buffered = true,
    })
    
    if job_id <= 0 then
        notify("❌ Failed to start save job", vim.log.levels.ERROR)
        return false
    end
    
    active_writes[bufnr] = {
        job_id = job_id,
        start_time = start_time,
        temp_file = temp_file,
        temp_dir = vim.fn.fnamemodify(temp_file, ":h"),
        remote_path = remote_path
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
        notify(string.format("Not a remote path: %s", bufname), vim.log.levels.ERROR)
        return false
    end
    
    -- Debug output
    vim.notify("Remote path info: " .. vim.inspect(remote_path), vim.log.levels.DEBUG)
    
    -- Ensure remote directory exists
    ensure_remote_dir(remote_path)
    
    -- Create temp file with buffer content
    local temp_file = create_temp_file(bufnr)
    if not temp_file or vim.fn.filereadable(temp_file) ~= 1 then
        notify("❌ Failed to create temporary file", vim.log.levels.ERROR)
        return false
    end
    
    -- Call the appropriate write function based on protocol
    if remote_path.protocol == "scp" then
        return M.async_write_scp(bufnr, remote_path, temp_file)
    elseif remote_path.protocol == "rsync" then
        return M.async_write_rsync(bufnr, remote_path, temp_file)
    else
        notify(string.format("Unsupported protocol: %s", remote_path.protocol), vim.log.levels.ERROR)
        vim.fn.delete(temp_file)
        return false
    end
end

-- Cancel an ongoing write operation
function M.cancel_write(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    
    local write_info = active_writes[bufnr]
    if not write_info then
        notify("No active write operation to cancel", vim.log.levels.WARN)
        return false
    end
    
    -- Terminate the job
    if vim.fn.jobstop(write_info.job_id) == 1 then
        -- Clean up temp file
        if write_info.temp_file and vim.fn.filereadable(write_info.temp_file) == 1 then
            vim.fn.delete(write_info.temp_file)
        end
        if write_info.temp_dir and vim.fn.isdirectory(write_info.temp_dir) == 1 then
            vim.fn.delete(write_info.temp_dir, "rf")
        end
        
        -- Remove from active writes
        active_writes[bufnr] = nil
        
        notify("✓ Write operation cancelled", vim.log.levels.INFO)
        return true
    else
        notify("❌ Failed to cancel write operation", vim.log.levels.ERROR)
        return false
    end
end

-- Get status of active write operations
function M.get_status()
    local count = 0
    local details = {}
    
    for bufnr, info in pairs(active_writes) do
        count = count + 1
        local duration = os.time() - info.start_time
        local bufname = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or "unknown"
        
        table.insert(details, {
            bufnr = bufnr,
            name = vim.fn.fnamemodify(bufname, ":t"),
            duration = duration,
            protocol = info.remote_path.protocol,
            host = info.remote_path.host
        })
    end
    
    return {
        count = count,
        details = details
    }
end

-- Register autocmd to intercept write commands for remote files
function M.setup()
    -- Create an autocmd group
    local augroup = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = true })
    
    -- Intercept BufWriteCmd for scp:// and rsync:// files
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            -- Enable verbose logging for debugging
            vim.g.async_remote_write_debug = true
            
            local success = M.async_write(ev.buf)
            -- If async write failed, fallback to regular write
            if not success then
                vim.notify("Falling back to synchronous write...", vim.log.levels.WARN)
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
            vim.notify("No active write operations", vim.log.levels.INFO)
        else
            vim.notify(string.format("%d active write operation(s):", status.count), vim.log.levels.INFO)
            for _, detail in ipairs(status.details) do
                vim.notify(string.format("  Buffer %d: %s (%s://%s) - %ds", 
                    detail.bufnr, detail.name, detail.protocol, detail.host, detail.duration), 
                    vim.log.levels.INFO)
            end
        end
    end, { desc = "Show status of active asynchronous write operations" })
    
    -- Add debug command
    vim.api.nvim_create_user_command("AsyncWriteDebug", function()
        if vim.g.async_remote_write_debug then
            vim.g.async_remote_write_debug = false
            vim.notify("Async write debugging disabled", vim.log.levels.INFO)
        else
            vim.g.async_remote_write_debug = true
            vim.notify("Async write debugging enabled", vim.log.levels.INFO)
        end
    end, { desc = "Toggle debugging for async write operations" })
end

return M
