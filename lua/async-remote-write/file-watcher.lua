local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local ssh_utils = require('async-remote-write.ssh_utils')
local metadata = require('remote-buffer-metadata')
local Job = require('plenary.job')
local async = require('plenary.async')

-- File watcher state tracking
local active_watchers = {}

-- Add retry logic with exponential backoff
local function retry_with_backoff(fn, max_retries, initial_delay)
    max_retries = max_retries or 3
    initial_delay = initial_delay or 1000

    local function attempt(retry_count, delay)
        return async.wrap(function(callback)
            fn(function(success, result)
                if success or retry_count >= max_retries then
                    callback(success, result)
                else
                    utils.log(string.format("Retry %d/%d failed: %s", retry_count, max_retries, result or "unknown error"),
                             vim.log.levels.DEBUG, false, config.config)

                    vim.defer_fn(function()
                        attempt(retry_count + 1, delay * 2)(callback)
                    end, delay)
                end
            end)
        end, 1)
    end

    return attempt(1, initial_delay)
end

-- Get buffer's file watching metadata
local function get_watcher_data(bufnr)
    return metadata.get(bufnr, 'file_watching') or {}
end

-- Set buffer's file watching metadata
local function set_watcher_data(bufnr, data)
    -- Update all keys in the data table
    for k, v in pairs(data) do
        metadata.set(bufnr, 'file_watching', k, v)
    end
end

-- Parse remote file info from buffer
local function get_remote_file_info(bufnr)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not bufname or bufname == "" then
        return nil
    end

    -- Parse scp:// or rsync:// URLs
    local protocol, user, host, port, path = bufname:match("^(scp)://([^@]+)@([^:/]+):?(%d*)(/.*)$")
    if not protocol then
        protocol, user, host, port, path = bufname:match("^(rsync)://([^@]+)@([^:/]+):?(%d*)(/.*)$")
    end

    if not protocol or not host or not path then
        return nil
    end

    return {
        protocol = protocol,
        user = user,
        host = host,
        port = port ~= "" and tonumber(port) or nil,
        path = path
    }
end

-- Check remote file modification time using SSH stat command (async with plenary)
local check_remote_mtime_async = async.wrap(function(remote_info, bufnr, callback)
    if not remote_info then
        callback(false, "No remote file info")
        return
    end

    -- Build SSH command to get file modification time
    local ssh_cmd = ssh_utils.build_ssh_command(
        remote_info.user,
        remote_info.host,
        remote_info.port,
        string.format("stat -c %%Y '%s' 2>/dev/null || echo 'NOTFOUND'", vim.fn.shellescape(remote_info.path))
    )

    utils.log(string.format("Checking remote mtime: %s", table.concat(ssh_cmd, " ")), vim.log.levels.DEBUG, false, config.config)

    local job = Job:new({
        command = ssh_cmd[1],
        args = vim.list_slice(ssh_cmd, 2),
        enable_recording = true,
        on_stderr = function(error, data)
            if data then
                utils.log("SSH stat error: " .. data, vim.log.levels.DEBUG, false, config.config)
            end
        end,
    })

    -- Register job for cancellation if buffer is being watched
    local job_id = tostring(job.pid or os.time() .. math.random(1000, 9999))
    if bufnr and active_watchers[bufnr] then
        active_watchers[bufnr].active_jobs[job_id] = job
    end

    local ok, exit_code = pcall(function()
        return job:sync(30000) -- 30 second timeout
    end)

    -- Unregister job after completion
    if bufnr and active_watchers[bufnr] and active_watchers[bufnr].active_jobs then
        active_watchers[bufnr].active_jobs[job_id] = nil
    end

    if not ok then
        callback(false, "SSH job timed out or failed to start")
        return
    end

    if exit_code ~= 0 then
        local stderr = table.concat(job:stderr_result() or {}, "\n")
        callback(false, "SSH command failed: " .. stderr)
        return
    end

    local stdout_lines = job:result()
    if not stdout_lines or #stdout_lines == 0 then
        callback(false, "No output from stat command")
        return
    end

    local output = table.concat(stdout_lines, "\n"):gsub("%s+$", "")
    if output == "NOTFOUND" or output == "" then
        callback(false, "Remote file not found")
        return
    end

    local mtime = tonumber(output)
    if not mtime then
        callback(false, "Invalid mtime format: " .. output)
        return
    end

    callback(true, mtime)
end, 3)

-- Synchronous wrapper for backward compatibility
local function check_remote_mtime(remote_info, callback, bufnr)
    check_remote_mtime_async(remote_info, bufnr, callback)
end

-- Fetch remote file content and update buffer
local function fetch_and_update_buffer(bufnr, remote_info, callback)
    local operations = require('async-remote-write.operations')

    -- Use existing fetch_remote_content function
    operations.fetch_remote_content(bufnr, function(success, error_msg)
        if success then
            -- Update buffer metadata with new sync time
            local watcher_data = get_watcher_data(bufnr)
            watcher_data.last_sync_time = os.time()
            set_watcher_data(bufnr, watcher_data)

            utils.log(string.format("📥 Remote changes pulled for buffer %d", bufnr), vim.log.levels.INFO, true, config.config)
            if callback then callback(true) end
        else
            utils.log(string.format("❌ Failed to fetch remote content: %s", error_msg or "Unknown error"), vim.log.levels.ERROR, true, config.config)
            if callback then callback(false, error_msg) end
        end
    end)
end

-- Detect conflicts between local and remote changes
local function detect_conflict(bufnr, remote_mtime)
    local watcher_data = get_watcher_data(bufnr)
    local async_data = metadata.get(bufnr, 'async_remote_write') or {}

    -- Check if buffer has unsaved local changes
    local has_local_changes = vim.api.nvim_buf_get_option(bufnr, 'modified')

    -- Check if we have a recent save that's newer than remote change
    local last_save_time = async_data.last_sync_time
    local recent_save = last_save_time and (os.time() - last_save_time) < 30 -- Within 30 seconds

    -- Check if remote file was modified after our last known state
    local last_known_mtime = watcher_data.last_remote_mtime
    local remote_changed = not last_known_mtime or remote_mtime > last_known_mtime

    if remote_changed and (has_local_changes or recent_save) then
        return "conflict"
    elseif remote_changed then
        return "safe_to_pull"
    else
        return "no_change"
    end
end

-- Handle conflict resolution strategies
local function handle_conflict(bufnr, remote_info, remote_mtime, conflict_type)
    local watcher_data = get_watcher_data(bufnr)

    if conflict_type == "safe_to_pull" then
        -- No local changes, safe to pull remote changes
        fetch_and_update_buffer(bufnr, remote_info, function(success)
            if success then
                watcher_data.last_remote_mtime = remote_mtime
                watcher_data.conflict_state = "none"
                set_watcher_data(bufnr, watcher_data)
            end
        end)

    elseif conflict_type == "conflict" then
        -- Mark conflict state and notify user
        watcher_data.conflict_state = "detected"
        set_watcher_data(bufnr, watcher_data)

        local bufname = vim.api.nvim_buf_get_name(bufnr)
        local short_name = vim.fn.fnamemodify(bufname, ":t")

        utils.log(string.format("⚠️  Conflict detected in '%s': remote file changed", short_name), vim.log.levels.WARN, true, config.config)
        utils.log("Use :RemoteRefresh to pull remote changes (will overwrite local changes)", vim.log.levels.INFO, true, config.config)

        -- Update remote mtime even in conflict state
        watcher_data.last_remote_mtime = remote_mtime
        set_watcher_data(bufnr, watcher_data)
    end
end

-- Main file watching poll function (async)
local poll_remote_file_async = async.wrap(function(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        callback(false, "Buffer no longer valid")
        return
    end

    local watcher_data = get_watcher_data(bufnr)
    if not watcher_data.enabled then
        callback(false, "Watching disabled")
        return
    end

    local remote_info = get_remote_file_info(bufnr)
    if not remote_info then
        callback(false, "No remote file info found")
        return
    end

    -- Use retry logic for robustness
    local check_with_retry = retry_with_backoff(function(retry_callback)
        check_remote_mtime(remote_info, retry_callback, bufnr)
    end, 2, 1000) -- 2 retries, 1 second initial delay

    check_with_retry(function(success, result)
        if not success then
            utils.log(string.format("Failed to check remote mtime after retries: %s", result), vim.log.levels.DEBUG, false, config.config)
            callback(false, result)
            return
        end

        local remote_mtime = result
        local conflict_type = detect_conflict(bufnr, remote_mtime)

        utils.log(string.format("Poll result for buffer %d: mtime=%d, conflict=%s", bufnr, remote_mtime, conflict_type), vim.log.levels.DEBUG, false, config.config)

        if conflict_type ~= "no_change" then
            handle_conflict(bufnr, remote_info, remote_mtime, conflict_type)
        else
            -- Update last check time even if no changes
            local current_data = get_watcher_data(bufnr)
            current_data.last_check_time = os.time()
            set_watcher_data(bufnr, current_data)
        end

        callback(true, conflict_type)
    end)
end, 2)

-- Synchronous wrapper for backward compatibility
local function poll_remote_file(bufnr)
    poll_remote_file_async(bufnr, function(success, result)
        -- Result is handled in the async callback
    end)
end

-- Start file watching for a buffer
function M.start_watching(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local remote_info = get_remote_file_info(bufnr)
    if not remote_info then
        utils.log("Cannot start watching: not a remote buffer", vim.log.levels.DEBUG, false, config.config)
        return false
    end

    local watcher_data = get_watcher_data(bufnr)

    -- Don't start if already watching
    if watcher_data.enabled and active_watchers[bufnr] then
        return true
    end

    -- Initialize watcher data
    watcher_data.enabled = true
    watcher_data.strategy = watcher_data.strategy or "polling"
    watcher_data.poll_interval = watcher_data.poll_interval or 5000
    watcher_data.conflict_state = "none"
    watcher_data.last_check_time = os.time()

    -- Get initial remote mtime
    check_remote_mtime(remote_info, function(success, mtime)
        if success then
            watcher_data.last_remote_mtime = mtime
            set_watcher_data(bufnr, watcher_data)
            utils.log(string.format("📡 File watching started for buffer %d (initial mtime: %d)", bufnr, mtime), vim.log.levels.INFO, false, config.config)
        else
            utils.log(string.format("⚠️  Started watching but failed to get initial mtime: %s", mtime), vim.log.levels.WARN, false, config.config)
        end
    end, bufnr)

    set_watcher_data(bufnr, watcher_data)

    -- Start polling timer
    local timer = vim.loop.new_timer()
    timer:start(watcher_data.poll_interval, watcher_data.poll_interval, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            M.stop_watching(bufnr)
            return
        end

        local current_data = get_watcher_data(bufnr)
        if not current_data.enabled then
            M.stop_watching(bufnr)
            return
        end

        poll_remote_file(bufnr)
    end))

    active_watchers[bufnr] = {
        timer = timer,
        remote_info = remote_info,
        active_jobs = {}, -- Track active plenary jobs for cancellation
        last_poll_time = os.time()
    }

    return true
end

-- Stop file watching for a buffer
function M.stop_watching(bufnr)
    local watcher = active_watchers[bufnr]
    if watcher then
        -- Close timer
        if watcher.timer then
            watcher.timer:close()
        end

        -- Cancel any active jobs
        if watcher.active_jobs then
            for job_id, job in pairs(watcher.active_jobs) do
                if job and type(job.shutdown) == "function" then
                    pcall(job.shutdown, job)
                    utils.log(string.format("Cancelled active job %s for buffer %d", job_id, bufnr), vim.log.levels.DEBUG, false, config.config)
                end
            end
        end

        active_watchers[bufnr] = nil

        local watcher_data = get_watcher_data(bufnr)
        watcher_data.enabled = false
        set_watcher_data(bufnr, watcher_data)

        utils.log(string.format("📡 File watching stopped for buffer %d", bufnr), vim.log.levels.INFO, false, config.config)
    end
end

-- Force refresh from remote (user command)
function M.force_refresh(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local remote_info = get_remote_file_info(bufnr)
    if not remote_info then
        utils.log("❌ Not a remote buffer", vim.log.levels.ERROR, true, config.config)
        return false
    end

    local watcher_data = get_watcher_data(bufnr)
    watcher_data.conflict_state = "resolving"
    set_watcher_data(bufnr, watcher_data)

    fetch_and_update_buffer(bufnr, remote_info, function(success, error_msg)
        local current_data = get_watcher_data(bufnr)
        if success then
            current_data.conflict_state = "none"
            utils.log("✅ Remote content refreshed", vim.log.levels.INFO, true, config.config)
        else
            current_data.conflict_state = "detected"
            utils.log(string.format("❌ Failed to refresh: %s", error_msg or "Unknown error"), vim.log.levels.ERROR, true, config.config)
        end
        set_watcher_data(bufnr, current_data)
    end)

    return true
end

-- Get watching status for a buffer
function M.get_status(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local watcher_data = get_watcher_data(bufnr)
    local is_active = active_watchers[bufnr] ~= nil

    return {
        enabled = watcher_data.enabled or false,
        active = is_active,
        conflict_state = watcher_data.conflict_state or "none",
        last_check = watcher_data.last_check_time,
        last_remote_mtime = watcher_data.last_remote_mtime,
        poll_interval = watcher_data.poll_interval or 5000
    }
end

-- Configure file watching settings
function M.configure(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    local watcher_data = get_watcher_data(bufnr)

    if opts.enabled ~= nil then
        watcher_data.enabled = opts.enabled
    end

    if opts.poll_interval then
        watcher_data.poll_interval = opts.poll_interval

        -- Restart timer with new interval if watching
        if active_watchers[bufnr] then
            M.stop_watching(bufnr)
            vim.defer_fn(function()
                M.start_watching(bufnr)
            end, 100)
        end
    end

    if opts.auto_refresh ~= nil then
        watcher_data.auto_refresh = opts.auto_refresh
    end

    set_watcher_data(bufnr, watcher_data)
end

-- Clean up on buffer delete
function M.cleanup_buffer(bufnr)
    M.stop_watching(bufnr)
end

return M
