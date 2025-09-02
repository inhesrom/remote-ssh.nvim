local M = {}

local config = require("async-remote-write.config")
local utils = require("async-remote-write.utils")
local ssh_utils = require("async-remote-write.ssh_utils")
local metadata = require("remote-buffer-metadata")
local Job = require("plenary.job")

-- File watcher state tracking
local active_watchers = {}

-- Add retry logic with exponential backoff (fully async)
local function retry_with_backoff(fn, max_retries, initial_delay, callback)
    max_retries = max_retries or 3
    initial_delay = initial_delay or 1000

    local function attempt(retry_count, delay)
        fn(function(success, result)
            if success or retry_count >= max_retries then
                callback(success, result)
            else
                utils.log(
                    string.format("Retry %d/%d failed: %s", retry_count, max_retries, result or "unknown error"),
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )

                vim.defer_fn(function()
                    attempt(retry_count + 1, delay * 2)
                end, delay)
            end
        end)
    end

    attempt(1, initial_delay)
end

-- Get buffer's file watching metadata
local function get_watcher_data(bufnr)
    return metadata.get(bufnr, "file_watching") or {}
end

-- Set buffer's file watching metadata
local function set_watcher_data(bufnr, data)
    -- Update all keys in the data table
    for k, v in pairs(data) do
        metadata.set(bufnr, "file_watching", k, v)
    end
end

-- Check remote file modification time using SSH stat command (fully async with plenary)
local function check_remote_mtime_async(remote_info, bufnr, callback)
    if not remote_info then
        callback(false, "No remote file info")
        return
    end

    -- Build SSH command to get file modification time
    -- Try both GNU/Linux format (-c %Y) and BSD/macOS format (-f %m)
    -- Fall back to basic file existence check if both fail
    local escaped_path = vim.fn.shellescape(remote_info.path)
    local stat_command = string.format(
        "stat -c %%Y '%s' 2>/dev/null || stat -f %%m '%s' 2>/dev/null || (test -f '%s' && echo 'EXISTS' || echo 'NOTFOUND')",
        escaped_path,
        escaped_path,
        escaped_path
    )
    local ssh_cmd = ssh_utils.build_ssh_command(remote_info.user, remote_info.host, remote_info.port, stat_command)

    utils.log(
        string.format("Checking remote mtime: %s", table.concat(ssh_cmd, " ")),
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    local job = Job:new({
        command = ssh_cmd[1],
        args = vim.list_slice(ssh_cmd, 2),
        enable_recording = true,
        on_stderr = function(error, data)
            if data then
                utils.log("SSH stat error: " .. data, vim.log.levels.ERROR, false, config.config)
            end
        end,
        on_exit = function(job_obj, exit_code)
            vim.schedule(function()
                -- Unregister job after completion
                local job_id = tostring(job_obj.pid or "unknown")
                if bufnr and active_watchers[bufnr] and active_watchers[bufnr].active_jobs then
                    active_watchers[bufnr].active_jobs[job_id] = nil
                end

                -- Handle different types of exit codes from plenary.job
                local actual_exit_code = 0 -- Default to success
                if type(exit_code) == "number" then
                    -- Only treat small numbers as actual exit codes (0-255 range typical for exit codes)
                    if exit_code >= 0 and exit_code <= 255 then
                        actual_exit_code = exit_code
                    else
                        -- Large numbers are probably output data, not exit codes
                        actual_exit_code = 0 -- Assume success if we got numeric output
                    end
                elseif type(exit_code) == "table" then
                    -- Tables from plenary.job might contain output, not exit codes
                    -- Check if we got output, and if so, consider it success
                    local stdout_check = job_obj:result()
                    if stdout_check and #stdout_check > 0 then
                        actual_exit_code = 0 -- Consider it success if we got output
                    else
                        actual_exit_code = 1 -- Consider it failure if no output
                    end
                elseif exit_code == nil then
                    -- If sync succeeded but returned nil, check if we got output to determine success
                    local stdout_check = job_obj:result()
                    if stdout_check and #stdout_check > 0 then
                        actual_exit_code = 0 -- Consider it success if we got output
                    else
                        actual_exit_code = 1 -- Consider it failure if no output
                    end
                else
                    actual_exit_code = 1 -- Unknown format, assume failure
                end

                utils.log(
                    string.format(
                        "SSH job completed - raw_exit_code: %s (type: %s), actual_exit_code: %d",
                        tostring(exit_code),
                        type(exit_code),
                        actual_exit_code
                    ),
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )

                if actual_exit_code ~= 0 then
                    local stderr_result = job_obj:stderr_result()
                    local stdout_result = job_obj:result()

                    local stderr = ""
                    local stdout = ""

                    if stderr_result and type(stderr_result) == "table" then
                        stderr = table.concat(stderr_result, "\n")
                    elseif stderr_result then
                        stderr = tostring(stderr_result)
                    end

                    if stdout_result and type(stdout_result) == "table" then
                        stdout = table.concat(stdout_result, "\n")
                    elseif stdout_result then
                        stdout = tostring(stdout_result)
                    end

                    utils.log(
                        string.format(
                            "SSH stat command failed - exit code: %d, stderr: %s, stdout: %s",
                            actual_exit_code,
                            stderr,
                            stdout
                        ),
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                    callback(false, "SSH command failed: " .. (stderr ~= "" and stderr or "exit code " .. actual_exit_code))
                    return
                end

                local stdout_lines = job_obj:result()
                if not stdout_lines then
                    callback(false, "No output from stat command")
                    return
                end

                local output = ""
                if type(stdout_lines) == "table" then
                    if #stdout_lines == 0 then
                        callback(false, "No output from stat command")
                        return
                    end
                    output = table.concat(stdout_lines, "\n"):gsub("%s+$", "")
                else
                    output = tostring(stdout_lines):gsub("%s+$", "")
                end
                utils.log(string.format("SSH stat output: '%s'", output), vim.log.levels.DEBUG, false, config.config)

                if output == "NOTFOUND" or output == "" then
                    utils.log(
                        "Remote file not found - this may be normal for new files",
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                    callback(false, "Remote file not found")
                    return
                end

                if output == "EXISTS" then
                    -- File exists but we couldn't get mtime - use current time as fallback
                    local fallback_mtime = os.time()
                    utils.log(
                        "File exists but mtime unavailable - using current time as fallback",
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                    callback(true, fallback_mtime)
                    return
                end

                local mtime = tonumber(output)
                if not mtime then
                    callback(false, "Invalid mtime format: " .. output)
                    return
                end

                callback(true, mtime)
            end)
        end,
    })

    -- Register job for cancellation if buffer is being watched
    local job_id = tostring(job.pid or os.time() .. math.random(1000, 9999))
    if bufnr and active_watchers[bufnr] then
        active_watchers[bufnr].active_jobs[job_id] = job
    end

    -- Start the job asynchronously (non-blocking)
    job:start()
end

-- Synchronous wrapper for backward compatibility
local function check_remote_mtime(remote_info, callback, bufnr)
    check_remote_mtime_async(remote_info, bufnr, callback)
end

-- Fetch remote file content and update buffer (fully async with plenary)
local function fetch_and_update_buffer(bufnr, remote_info, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        if callback then
            callback(false, "Buffer no longer valid")
        end
        return
    end

    -- Build scp command to fetch remote content
    local temp_file = vim.fn.tempname()

    -- Build remote target - handle SSH config aliases where user might be nil
    local remote_target
    if remote_info.user then
        remote_target = remote_info.user .. "@" .. remote_info.host .. ":" .. remote_info.path
    else
        -- For SSH config aliases, let SSH config handle the user
        remote_target = remote_info.host .. ":" .. remote_info.path
    end

    local cmd = { "scp", "-q" }

    -- Add port if specified
    if remote_info.port then
        table.insert(cmd, "-P")
        table.insert(cmd, tostring(remote_info.port))
    end

    table.insert(cmd, remote_target)
    table.insert(cmd, temp_file)

    utils.log(
        string.format("Fetching remote content for buffer %d: %s", bufnr, table.concat(cmd, " ")),
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    local job = Job:new({
        command = cmd[1],
        args = vim.list_slice(cmd, 2),
        enable_recording = true,
        on_stderr = function(error, data)
            if data then
                utils.log("SCP fetch error: " .. data, vim.log.levels.ERROR, false, config.config)
            end
        end,
        on_exit = function(job_obj, exit_code)
            vim.schedule(function()
                if exit_code ~= 0 then
                    local stderr_result = job_obj:stderr_result()
                    local error_msg = "Failed to fetch remote content"
                    if stderr_result and #stderr_result > 0 then
                        error_msg = error_msg .. ": " .. table.concat(stderr_result, "\n")
                    else
                        error_msg = error_msg .. " (exit code: " .. tostring(exit_code) .. ")"
                    end

                    pcall(vim.fn.delete, temp_file)
                    utils.log(error_msg, vim.log.levels.ERROR, false, config.config)
                    if callback then
                        callback(false, error_msg)
                    end
                    return
                end

                -- Read the temp file content and update buffer
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    pcall(vim.fn.delete, temp_file)
                    if callback then
                        callback(false, "Buffer no longer valid")
                    end
                    return
                end

                local success_read, lines = pcall(vim.fn.readfile, temp_file)
                pcall(vim.fn.delete, temp_file)

                if not success_read then
                    local error_msg = "Failed to read downloaded content: " .. tostring(lines)
                    utils.log(error_msg, vim.log.levels.ERROR, false, config.config)
                    if callback then
                        callback(false, error_msg)
                    end
                    return
                end

                -- Store cursor position and view if buffer is visible
                local win = vim.fn.bufwinid(bufnr)
                local cursor_pos = { 1, 0 }
                local view = nil

                if win ~= -1 then
                    cursor_pos = vim.api.nvim_win_get_cursor(win)
                    view = vim.fn.winsaveview()
                end

                -- Make buffer modifiable
                local was_modifiable = vim.api.nvim_buf_get_option(bufnr, "modifiable")
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
                end

                -- Update buffer content
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

                -- Restore buffer state
                vim.api.nvim_buf_set_option(bufnr, "modified", false)
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, "modifiable", was_modifiable)
                end

                -- Restore cursor position and view
                if win ~= -1 then
                    pcall(vim.api.nvim_win_set_cursor, win, cursor_pos)
                    if view then
                        pcall(vim.fn.winrestview, view)
                    end
                end

                -- Update buffer metadata with new sync time
                local watcher_data = get_watcher_data(bufnr)
                watcher_data.last_sync_time = os.time()
                set_watcher_data(bufnr, watcher_data)

                utils.log(
                    string.format("📥 Remote changes pulled for buffer %d (%d lines)", bufnr, #lines),
                    vim.log.levels.INFO,
                    true,
                    config.config
                )
                if callback then
                    callback(true)
                end
            end)
        end,
    })

    -- Start the job asynchronously
    job:start()
end

-- Detect conflicts between local and remote changes
local function detect_conflict(bufnr, remote_mtime)
    local watcher_data = get_watcher_data(bufnr)
    local async_data = metadata.get(bufnr, "async_remote_write") or {}

    -- Check if buffer has unsaved local changes
    local has_local_changes = vim.api.nvim_buf_get_option(bufnr, "modified")

    -- Check if we have a recent save
    local last_save_time = async_data.last_sync_time
    local recent_save = last_save_time and (os.time() - last_save_time) < 30 -- Within 30 seconds

    -- Check if remote file was modified after our last known state
    local last_known_mtime = watcher_data.last_remote_mtime
    local remote_changed = not last_known_mtime or remote_mtime > last_known_mtime

    -- If no remote change, no action needed
    if not remote_changed then
        return "no_change"
    end

    -- If we recently saved, check if the remote change is likely from our save
    if recent_save and last_save_time then
        -- If remote mtime is close to our save time (within 5 seconds), it's likely our save
        local mtime_diff = math.abs(remote_mtime - last_save_time)
        if mtime_diff <= 5 then
            -- This remote change was likely caused by our own save, ignore it
            return "no_change"
        end

        -- Remote change happened significantly after our save, someone else changed it
        if has_local_changes then
            return "conflict" -- We have unsaved changes AND someone else changed the remote
        else
            return "safe_to_pull" -- No local changes, safe to pull the external change
        end
    end

    -- No recent save from us
    if has_local_changes then
        return "conflict" -- Remote changed and we have local changes
    else
        return "safe_to_pull" -- Remote changed but no local changes
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

        utils.log(
            string.format("⚠️  Conflict detected in '%s': remote file changed", short_name),
            vim.log.levels.WARN,
            true,
            config.config
        )
        utils.log(
            "Use :RemoteRefresh to pull remote changes (will overwrite local changes)",
            vim.log.levels.INFO,
            true,
            config.config
        )

        -- Update remote mtime even in conflict state
        watcher_data.last_remote_mtime = remote_mtime
        set_watcher_data(bufnr, watcher_data)
    end
end

-- Main file watching poll function (fully async)
local function poll_remote_file_async(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        callback(false, "Buffer no longer valid")
        return
    end

    local watcher_data = get_watcher_data(bufnr)
    if not watcher_data.enabled then
        callback(false, "Watching disabled")
        return
    end

    local remote_info = utils.get_remote_file_info(bufnr)
    if not remote_info then
        callback(false, "No remote file info found")
        return
    end

    -- Use retry logic for robustness
    retry_with_backoff(
        function(retry_callback)
            check_remote_mtime(remote_info, retry_callback, bufnr)
        end,
        2,
        1000,
        function(success, result) -- 2 retries, 1 second initial delay
            if not success then
                -- Make SSH failures more visible - use WARN level for first few failures
                local watcher_data = get_watcher_data(bufnr)
                local failure_count = (watcher_data.mtime_failure_count or 0) + 1
                watcher_data.mtime_failure_count = failure_count
                set_watcher_data(bufnr, watcher_data)

                local log_level = failure_count <= 3 and vim.log.levels.WARN or vim.log.levels.DEBUG
                utils.log(
                    string.format("Failed to check remote mtime (attempt %d): %s", failure_count, result),
                    log_level,
                    false,
                    config.config
                )
                callback(false, result)
                return
            end

            -- Reset failure count on success
            local watcher_data = get_watcher_data(bufnr)
            if watcher_data.mtime_failure_count then
                watcher_data.mtime_failure_count = 0
                set_watcher_data(bufnr, watcher_data)
            end

            local remote_mtime = result
            local conflict_type = detect_conflict(bufnr, remote_mtime)

            utils.log(
                string.format("Poll result for buffer %d: mtime=%d, conflict=%s", bufnr, remote_mtime, conflict_type),
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Always update last check time and remote mtime on successful polls
            local current_data = get_watcher_data(bufnr)
            current_data.last_check_time = os.time()
            current_data.last_remote_mtime = remote_mtime
            set_watcher_data(bufnr, current_data)

            if conflict_type ~= "no_change" then
                handle_conflict(bufnr, remote_info, remote_mtime, conflict_type)
            end

            callback(true, conflict_type)
        end
    )
end

-- Async wrapper (no longer synchronous since everything is async now)
local function poll_remote_file(bufnr)
    poll_remote_file_async(bufnr, function(success, result)
        -- All processing is handled in the async callback chain
        if not success then
            utils.log(
                string.format("File polling completed with error for buffer %d: %s", bufnr, result or "unknown"),
                vim.log.levels.DEBUG,
                false,
                config.config
            )
        else
            utils.log(
                string.format("File polling completed successfully for buffer %d: %s", bufnr, result or "no_change"),
                vim.log.levels.DEBUG,
                false,
                config.config
            )
        end
    end)
end

-- Start file watching for a buffer
function M.start_watching(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local remote_info = utils.get_remote_file_info(bufnr)
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
            utils.log(
                string.format("📡 File watching started for buffer %d (initial mtime: %d)", bufnr, mtime),
                vim.log.levels.INFO,
                false,
                config.config
            )
        else
            -- Still start watching, but without initial mtime - polling will try to get it later
            watcher_data.last_remote_mtime = nil
            watcher_data.mtime_failure_count = 1 -- Track initial failure
            set_watcher_data(bufnr, watcher_data)
            utils.log(
                string.format("⚠️  Started watching but failed to get initial mtime: %s", mtime),
                vim.log.levels.WARN,
                false,
                config.config
            )
            utils.log(
                "   File watching will continue - polling may succeed once the file exists",
                vim.log.levels.INFO,
                false,
                config.config
            )
            utils.log("   Use :RemoteWatchDebug to test SSH connection manually", vim.log.levels.INFO, false, config.config)
        end
    end, bufnr)

    set_watcher_data(bufnr, watcher_data)

    -- Start polling timer
    local timer = vim.loop.new_timer()
    timer:start(
        watcher_data.poll_interval,
        watcher_data.poll_interval,
        vim.schedule_wrap(function()
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
        end)
    )

    active_watchers[bufnr] = {
        timer = timer,
        remote_info = remote_info,
        active_jobs = {}, -- Track active plenary jobs for cancellation
        last_poll_time = os.time(),
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
                    utils.log(
                        string.format("Cancelled active job %s for buffer %d", job_id, bufnr),
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                end
            end
        end

        active_watchers[bufnr] = nil

        local watcher_data = get_watcher_data(bufnr)
        watcher_data.enabled = false
        set_watcher_data(bufnr, watcher_data)

        utils.log(
            string.format("📡 File watching stopped for buffer %d", bufnr),
            vim.log.levels.INFO,
            false,
            config.config
        )
    end
end

-- Force refresh from remote (user command)
function M.force_refresh(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local remote_info = utils.get_remote_file_info(bufnr)
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
            utils.log(
                string.format("❌ Failed to refresh: %s", error_msg or "Unknown error"),
                vim.log.levels.ERROR,
                true,
                config.config
            )
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
        poll_interval = watcher_data.poll_interval or 5000,
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

-- Export helper function for debugging
M._get_remote_file_info = utils.get_remote_file_info

return M
