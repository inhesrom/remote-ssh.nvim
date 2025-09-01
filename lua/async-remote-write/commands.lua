local M = {}

local config = require("async-remote-write.config")
local utils = require("async-remote-write.utils")
local operations = require("async-remote-write.operations")
local process = require("async-remote-write.process")
local buffer = require("async-remote-write.buffer")
local browse = require("async-remote-write.browse")
local file_watcher = require("async-remote-write.file-watcher")

function M.register()
    vim.api.nvim_create_user_command("RemoteTreeBrowser", function(opts)
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.open_tree(opts.args)
    end, {
        nargs = 1,
        desc = "Open dedicated buffer-based remote file tree browser",
        complete = "file",
    })

    vim.api.nvim_create_user_command("RemoteTreeClose", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.close_tree()
    end, {
        nargs = 0,
        desc = "Close the remote tree browser",
    })

    vim.api.nvim_create_user_command("RemoteTreeBrowserHide", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.hide_tree()
    end, {
        nargs = 0,
        desc = "Hide the remote tree browser (keep buffer alive)",
    })

    vim.api.nvim_create_user_command("RemoteTreeBrowserShow", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.show_tree()
    end, {
        nargs = 0,
        desc = "Show the remote tree browser (reuse existing buffer)",
    })

    vim.api.nvim_create_user_command("RemoteTreeRefresh", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.refresh_tree()
    end, {
        nargs = 0,
        desc = "Refresh the remote tree browser",
    })

    vim.api.nvim_create_user_command("RemoteTreeRefreshFull", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.refresh_tree_full()
    end, {
        nargs = 0,
        desc = "Full refresh of remote tree browser (clears all caches including LSP project root cache)",
    })

    -- Tree Browser Cache Management Commands
    vim.api.nvim_create_user_command("RemoteTreeClearCache", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.clear_all_cache()
    end, {
        nargs = 0,
        desc = "Clear all tree browser cache (directory + icon cache)",
    })

    vim.api.nvim_create_user_command("RemoteTreeClearDirCache", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.clear_cache()
    end, {
        nargs = 0,
        desc = "Clear tree browser directory cache only",
    })

    vim.api.nvim_create_user_command("RemoteTreeClearIconCache", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.clear_icon_cache()
    end, {
        nargs = 0,
        desc = "Clear tree browser icon cache only",
    })

    vim.api.nvim_create_user_command("RemoteTreeCacheInfo", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.print_cache_info()
    end, {
        nargs = 0,
        desc = "Show tree browser cache information and statistics",
    })

    vim.api.nvim_create_user_command("RemoteTreeRefreshIcons", function()
        local tree_browser = require("async-remote-write.tree_browser")
        tree_browser.refresh_icons()
    end, {
        nargs = 0,
        desc = "Refresh tree browser icons (useful after installing nvim-web-devicons)",
    })

    -- Remote History Commands
    vim.api.nvim_create_user_command("RemoteHistory", function()
        local session_picker = require("async-remote-write.session_picker")
        session_picker.show_picker()
    end, {
        nargs = 0,
        desc = "Open Remote SSH history picker with pinned items and filtering",
    })

    vim.api.nvim_create_user_command("RemoteHistoryClear", function()
        local session_picker = require("async-remote-write.session_picker")
        session_picker.clear_history()
    end, {
        nargs = 0,
        desc = "Clear remote session history",
    })

    vim.api.nvim_create_user_command("RemoteHistoryClearPinned", function()
        local session_picker = require("async-remote-write.session_picker")
        session_picker.clear_pinned()
    end, {
        nargs = 0,
        desc = "Clear pinned remote sessions",
    })

    vim.api.nvim_create_user_command("RemoteHistoryStats", function()
        local session_picker = require("async-remote-write.session_picker")
        local stats = session_picker.get_stats()
        utils.log(
            string.format(
                "History Stats: %d history, %d pinned, %d total (max history: %d)",
                stats.history_count,
                stats.pinned_count,
                stats.total_sessions,
                stats.max_history
            ),
            vim.log.levels.INFO,
            true,
            config.config
        )
    end, {
        nargs = 0,
        desc = "Show remote session history statistics",
    })

    vim.api.nvim_create_user_command("RemoteGrep", function(opts)
        browse.grep_remote_directory(opts.args)
    end, {
        nargs = 1,
        desc = "Search for text in remote files using grep",
        complete = "file",
    })

    -- Add a command to open remote files
    vim.api.nvim_create_user_command("RemoteOpen", function(opts)
        operations.simple_open_remote_file(opts.args)
    end, {
        nargs = 1,
        desc = "Open a remote file with scp:// or rsync:// protocol",
        complete = "file",
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
                utils.log("No buffer found matching: " .. opts.args, vim.log.levels.ERROR, true, config.config)
                return
            end
        else
            -- Use current buffer
            bufnr = vim.api.nvim_get_current_buf()
        end

        operations.refresh_remote_buffer(bufnr)
    end, {
        nargs = "?",
        desc = "Refresh a remote buffer by re-fetching its content",
        complete = "buffer",
    })

    vim.api.nvim_create_user_command("RemoteRefreshAll", function()
        -- Find all remote buffers
        local remote_buffers = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
                local bufname = vim.api.nvim_buf_get_name(buf)
                if bufname:match("^scp://") or bufname:match("^rsync://") then
                    table.insert(remote_buffers, buf)
                end
            end
        end

        -- Notify how many buffers were found
        if #remote_buffers == 0 then
            utils.log("No remote buffers found to refresh", vim.log.levels.INFO, true, config.config)
            return
        else
            utils.log("Refreshing " .. #remote_buffers .. " remote buffers...", vim.log.levels.INFO, true)
        end

        -- Refresh each buffer
        for _, bufnr in ipairs(remote_buffers) do
            operations.refresh_remote_buffer(bufnr)
        end
    end, {
        desc = "Refresh all remote buffers by re-fetching their content",
    })

    -- Create command aliases to ensure compatibility with existing workflows
    vim.cmd([[
    command! -nargs=1 -complete=file Rscp RemoteOpen rsync://<args>
    command! -nargs=1 -complete=file Scp RemoteOpen scp://<args>
    command! -nargs=1 -complete=file E RemoteOpen <args>
    ]])

    -- Add user commands for write operations
    vim.api.nvim_create_user_command("AsyncWriteCancel", function()
        process.cancel_write()
    end, { desc = "Cancel ongoing asynchronous write operation" })

    vim.api.nvim_create_user_command("AsyncWriteStatus", function()
        process.get_status()
    end, { desc = "Show status of active asynchronous write operations" })

    -- Add force complete command
    vim.api.nvim_create_user_command("AsyncWriteForceComplete", function(opts)
        local success = opts.bang
        process.force_complete(nil, success)
    end, {
        desc = "Force complete a stuck write operation (! to mark as success)",
        bang = true,
    })

    -- Add debug command
    vim.api.nvim_create_user_command("AsyncWriteDebug", function()
        config.config.debug = not config.config.debug
        -- If enabling debug, set log_level to DEBUG
        if config.config.debug then
            config.config.log_level = vim.log.levels.DEBUG
            utils.log("Async write debugging enabled (log level set to DEBUG)", vim.log.levels.INFO, true)
        else
            config.config.log_level = vim.log.levels.INFO
            utils.log("Async write debugging disabled (log level set to INFO)", vim.log.levels.INFO, true, config.config)
        end
    end, { desc = "Toggle debugging for async write operations" })

    -- Add log level command
    vim.api.nvim_create_user_command("AsyncWriteLogLevel", function(opts)
        local level_name = opts.args:upper()
        local levels = {
            DEBUG = vim.log.levels.DEBUG,
            INFO = vim.log.levels.INFO,
            WARN = vim.log.levels.WARN,
            ERROR = vim.log.levels.ERROR,
        }

        if levels[level_name] then
            config.config.log_level = levels[level_name]
            -- If setting to DEBUG, also enable debug mode
            if level_name == "DEBUG" then
                config.config.debug = true
            end
            utils.log("Log level set to " .. level_name, vim.log.levels.INFO, true, config.config)
        else
            utils.log(
                "Invalid log level: " .. opts.args .. ". Use DEBUG, INFO, WARN, or ERROR",
                vim.log.levels.ERROR,
                true,
                config.config
            )
        end
    end, {
        desc = "Set the logging level (DEBUG, INFO, WARN, ERROR)",
        nargs = 1,
        complete = function()
            return { "DEBUG", "INFO", "WARN", "ERROR" }
        end,
    })

    -- Add reregister command for manual fixing of buffer autocommands
    vim.api.nvim_create_user_command("AsyncWriteReregister", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local result = buffer.register_buffer_autocommands(bufnr)
        if result then
            utils.log(
                "Successfully reregistered autocommands for buffer " .. bufnr,
                vim.log.levels.INFO,
                true,
                config.config
            )
        else
            utils.log("Failed to reregister autocommands (not a remote buffer?)", vim.log.levels.WARN, true, config.config)
        end
    end, { desc = "Reregister buffer-specific autocommands for current buffer" })

    -- Cache management commands
    vim.api.nvim_create_user_command("RemoteCacheStats", function()
        local stats = browse.get_cache_stats()
        local message = string.format(
            [[
Cache Statistics:
  Total Requests: %d
  Cache Hits: %d
  Cache Misses: %d
  Hit Rate: %s
  Evictions: %d

Cache Entries:
  Directory Listings: %d
  File Listings: %d
  Incremental Listings: %d]],
            stats.total_requests,
            stats.hits,
            stats.misses,
            stats.hit_rate,
            stats.evictions,
            stats.cache_entries.directory_listings,
            stats.cache_entries.file_listings,
            stats.cache_entries.incremental_listings
        )
        utils.log(message, vim.log.levels.INFO, true, config.config)
    end, { desc = "Show remote browsing cache statistics" })

    vim.api.nvim_create_user_command("RemoteCacheClear", function()
        browse.clear_cache()
    end, { desc = "Clear all remote browsing cache" })

    vim.api.nvim_create_user_command("RemoteCacheWarmStart", function(opts)
        if not opts.args or opts.args == "" then
            utils.log("Usage: RemoteCacheWarmStart <remote_url> [max_depth]", vim.log.levels.ERROR, true, config.config)
            return
        end

        local args = vim.split(opts.args, "%s+")
        local url = args[1]
        local max_depth = tonumber(args[2]) or 5

        local success = browse.start_cache_warming(url, { max_depth = max_depth })
        if success then
            utils.log("Started background cache warming for: " .. url, vim.log.levels.DEBUG, false, config.config)
        end
    end, {
        nargs = "+",
        desc = "Start background cache warming for a remote directory (usage: <url> [max_depth])",
        complete = "file",
    })

    vim.api.nvim_create_user_command("RemoteCacheWarmStop", function(opts)
        if not opts.args or opts.args == "" then
            utils.log("Usage: RemoteCacheWarmStop <remote_url>", vim.log.levels.ERROR, true, config.config)
            return
        end

        local success = browse.stop_cache_warming(opts.args)
        if success then
            utils.log("Stopped cache warming for: " .. opts.args, vim.log.levels.DEBUG, false, config.config)
        else
            utils.log("No active cache warming found for: " .. opts.args, vim.log.levels.DEBUG, false, config.config)
        end
    end, {
        nargs = 1,
        desc = "Stop background cache warming for a remote directory",
        complete = "file",
    })

    vim.api.nvim_create_user_command("RemoteCacheWarmStatus", function()
        local status = browse.get_cache_warming_status()
        local message = string.format(
            [[
Background Cache Warming Status:
  Active Jobs: %d
  Active URLs: %s

Statistics:
  Directories Warmed: %d
  Files Cached: %d
  Total Items Discovered: %d

Configuration:
  Max Depth: %d
  Max Concurrent: %d
  Batch Size: %d
  Auto Warm: %s]],
            status.active_jobs,
            #status.active_urls > 0 and table.concat(status.active_urls, ", ") or "none",
            status.stats.directories_warmed,
            status.stats.files_cached,
            status.stats.total_discovered,
            status.config.max_depth,
            status.config.max_concurrent,
            status.config.batch_size,
            status.config.auto_warm and "enabled" or "disabled"
        )
        utils.log(message, vim.log.levels.INFO, true, config.config)
    end, { desc = "Show background cache warming status and statistics" })

    vim.api.nvim_create_user_command("RemoteCacheWarmToggleAuto", function()
        local warming_status = browse.get_cache_warming_status()
        local new_state = not warming_status.config.auto_warm

        -- Update the config (Note: this updates the runtime config, not persistent)
        warming_status.config.auto_warm = new_state

        utils.log(
            "Auto cache warming " .. (new_state and "enabled" or "disabled"),
            vim.log.levels.DEBUG,
            false,
            config.config
        )
    end, { desc = "Toggle automatic cache warming on directory browse" })

    -- File watcher commands
    vim.api.nvim_create_user_command("RemoteWatchStart", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local success = file_watcher.start_watching(bufnr)
        if success then
            utils.log("File watching started for current buffer", vim.log.levels.INFO, true, config.config)
        else
            utils.log("Failed to start file watching (not a remote buffer?)", vim.log.levels.ERROR, true, config.config)
        end
    end, { desc = "Start file watching for current buffer" })

    vim.api.nvim_create_user_command("RemoteWatchStop", function()
        local bufnr = vim.api.nvim_get_current_buf()
        file_watcher.stop_watching(bufnr)
        utils.log("File watching stopped for current buffer", vim.log.levels.INFO, true, config.config)
    end, { desc = "Stop file watching for current buffer" })

    vim.api.nvim_create_user_command("RemoteWatchStatus", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local status = file_watcher.get_status(bufnr)

        local message = string.format(
            [[
File Watcher Status:
  Enabled: %s
  Active: %s
  Conflict State: %s
  Poll Interval: %dms
  Last Check: %s
  Last Remote Mtime: %s]],
            status.enabled and "yes" or "no",
            status.active and "yes" or "no",
            status.conflict_state,
            status.poll_interval,
            status.last_check and os.date("%Y-%m-%d %H:%M:%S", status.last_check) or "never",
            status.last_remote_mtime and os.date("%Y-%m-%d %H:%M:%S", status.last_remote_mtime) or "unknown"
        )
        utils.log(message, vim.log.levels.INFO, true, config.config)
    end, { desc = "Show file watching status for current buffer" })

    vim.api.nvim_create_user_command("RemoteWatchRefresh", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local success = file_watcher.force_refresh(bufnr)
        if success then
            utils.log("Remote content refresh initiated", vim.log.levels.INFO, true, config.config)
        else
            utils.log("Failed to refresh (not a remote buffer?)", vim.log.levels.ERROR, true, config.config)
        end
    end, { desc = "Force refresh from remote (overwrite local changes)" })

    vim.api.nvim_create_user_command("RemoteWatchConfigure", function(opts)
        local bufnr = vim.api.nvim_get_current_buf()
        local args = vim.split(opts.args, "%s+")

        if #args < 2 then
            utils.log("Usage: RemoteWatchConfigure <setting> <value>", vim.log.levels.ERROR, true, config.config)
            utils.log("Available settings: enabled, poll_interval, auto_refresh", vim.log.levels.INFO, true, config.config)
            return
        end

        local setting = args[1]
        local value = args[2]
        local opts_table = {}

        if setting == "enabled" then
            opts_table.enabled = value:lower() == "true"
        elseif setting == "poll_interval" then
            local interval = tonumber(value)
            if not interval or interval <= 0 then
                utils.log("Invalid poll interval: " .. value, vim.log.levels.ERROR, true, config.config)
                return
            end
            opts_table.poll_interval = interval
        elseif setting == "auto_refresh" then
            opts_table.auto_refresh = value:lower() == "true"
        else
            utils.log("Unknown setting: " .. setting, vim.log.levels.ERROR, true, config.config)
            return
        end

        file_watcher.configure(bufnr, opts_table)
        utils.log("File watcher configured: " .. setting .. " = " .. value, vim.log.levels.INFO, true, config.config)
    end, {
        nargs = "+",
        desc = "Configure file watcher settings for current buffer",
        complete = function(arg_lead, cmd_line, cursor_pos)
            local args = vim.split(cmd_line, "%s+")
            if #args == 2 then
                return { "enabled", "poll_interval", "auto_refresh" }
            elseif #args == 3 then
                if args[2] == "enabled" or args[2] == "auto_refresh" then
                    return { "true", "false" }
                elseif args[2] == "poll_interval" then
                    return { "1000", "5000", "10000", "30000" }
                end
            end
            return {}
        end,
    })

    vim.api.nvim_create_user_command("RemoteWatchDebug", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local bufname = vim.api.nvim_buf_get_name(bufnr)

        utils.log("=== File Watcher Debug Info ===", vim.log.levels.INFO, true, config.config)
        utils.log("Buffer: " .. bufnr .. " (" .. bufname .. ")", vim.log.levels.INFO, true, config.config)

        -- Test if it's a remote buffer
        local remote_info = file_watcher._get_remote_file_info(bufnr)

        if remote_info then
            utils.log("Remote Info:", vim.log.levels.INFO, true, config.config)
            utils.log("  Protocol: " .. remote_info.protocol, vim.log.levels.INFO, true, config.config)
            utils.log("  User: " .. (remote_info.user or "from SSH config"), vim.log.levels.INFO, true, config.config)
            utils.log("  Host: " .. remote_info.host, vim.log.levels.INFO, true, config.config)
            utils.log("  Port: " .. (remote_info.port or "default"), vim.log.levels.INFO, true, config.config)
            utils.log("  Path: " .. remote_info.path, vim.log.levels.INFO, true, config.config)

            -- Test the SSH command manually
            local ssh_utils = require("async-remote-write.ssh_utils")
            local escaped_path = vim.fn.shellescape(remote_info.path)
            local stat_command = string.format(
                "stat -c %%Y '%s' 2>/dev/null || stat -f %%m '%s' 2>/dev/null || (test -f '%s' && echo 'EXISTS' || echo 'NOTFOUND')",
                escaped_path,
                escaped_path,
                escaped_path
            )
            local ssh_cmd = ssh_utils.build_ssh_command(remote_info.user, remote_info.host, remote_info.port, stat_command)

            utils.log("SSH Command: " .. table.concat(ssh_cmd, " "), vim.log.levels.INFO, true, config.config)

            -- Try to run it manually for testing
            utils.log("Running SSH command test...", vim.log.levels.INFO, true, config.config)
            local Job = require("plenary.job")
            local job = Job:new({
                command = ssh_cmd[1],
                args = vim.list_slice(ssh_cmd, 2),
                enable_recording = true,
            })

            local ok, exit_code = pcall(function()
                return job:sync(10000) -- 10 second timeout for testing
            end)

            if ok then
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
                    local stdout_check = job:result()
                    if stdout_check and #stdout_check > 0 then
                        actual_exit_code = 0 -- Consider it success if we got output
                    else
                        actual_exit_code = 1 -- Consider it failure if no output
                    end
                elseif exit_code == nil then
                    -- If sync succeeded but returned nil, check if we got output to determine success
                    local stdout_check = job:result()
                    if stdout_check and #stdout_check > 0 then
                        actual_exit_code = 0 -- Consider it success if we got output
                    else
                        actual_exit_code = 1 -- Consider it failure if no output
                    end
                else
                    actual_exit_code = 1 -- Unknown format, assume failure
                end
                local stdout_result = job:result()
                local stderr_result = job:stderr_result()

                local stdout = ""
                local stderr = ""

                if stdout_result and type(stdout_result) == "table" then
                    stdout = table.concat(stdout_result, "\\n")
                elseif stdout_result then
                    stdout = tostring(stdout_result)
                end

                if stderr_result and type(stderr_result) == "table" then
                    stderr = table.concat(stderr_result, "\\n")
                elseif stderr_result then
                    stderr = tostring(stderr_result)
                end

                utils.log(
                    "Exit Code: " .. actual_exit_code .. " (raw: " .. tostring(exit_code) .. ")",
                    vim.log.levels.INFO,
                    true,
                    config.config
                )
                utils.log("Stdout: " .. stdout, vim.log.levels.INFO, true, config.config)
                utils.log("Stderr: " .. stderr, vim.log.levels.INFO, true, config.config)
            else
                utils.log("Failed to run SSH command: " .. tostring(exit_code), vim.log.levels.ERROR, true, config.config)
            end
        else
            utils.log("Not a remote buffer", vim.log.levels.INFO, true, config.config)
        end

        utils.log("=== End Debug Info ===", vim.log.levels.INFO, true, config.config)
    end, { desc = "Debug file watcher SSH connection and commands" })

    -- Dependency checking commands
    vim.api.nvim_create_user_command("RemoteDependencyCheck", function(opts)
        local dependency_checker = require("async-remote-write.dependency_checker")
        local target_hosts = nil

        if opts.args and opts.args ~= "" then
            -- Parse comma-separated host list
            target_hosts = {}
            for host in opts.args:gmatch("([^,]+)") do
                table.insert(target_hosts, vim.trim(host))
            end
        end

        local report, results = dependency_checker.check_dependencies(target_hosts)

        -- Display the report
        print(report)

        -- Also log summary
        local status_msg = "Dependency check completed: " .. string.upper(results.overall_status)
        if results.overall_status == "ok" then
            utils.log(status_msg, vim.log.levels.INFO, true, config.config)
        elseif results.overall_status == "warning" then
            utils.log(status_msg, vim.log.levels.WARN, true, config.config)
        else
            utils.log(status_msg, vim.log.levels.ERROR, true, config.config)
        end
    end, {
        nargs = "?",
        desc = "Check all dependencies for remote-ssh.nvim plugin (usage: [host1,host2,...] or empty for auto-discovery)",
        complete = "file",
    })

    vim.api.nvim_create_user_command("RemoteDependencyQuickCheck", function(opts)
        local dependency_checker = require("async-remote-write.dependency_checker")
        local target_hosts = nil

        if opts.args and opts.args ~= "" then
            target_hosts = {}
            for host in opts.args:gmatch("([^,]+)") do
                table.insert(target_hosts, vim.trim(host))
            end
        end

        local status, results = dependency_checker.quick_check(target_hosts)

        local status_icon = status == "ok" and "✅" or status == "warning" and "⚠️" or "❌"

        local message = "Remote SSH Plugin Status: " .. status_icon .. " " .. string.upper(status)

        if status == "ok" then
            utils.log(message .. " - All dependencies satisfied", vim.log.levels.INFO, true, config.config)
        elseif status == "warning" then
            utils.log(
                message .. " - Some optional components missing or remote issues",
                vim.log.levels.WARN,
                true,
                config.config
            )
            utils.log("Run :RemoteDependencyCheck for detailed report", vim.log.levels.INFO, true, config.config)
        else
            utils.log(message .. " - Critical dependencies missing", vim.log.levels.ERROR, true, config.config)
            utils.log("Run :RemoteDependencyCheck for detailed report", vim.log.levels.INFO, true, config.config)
        end
    end, {
        nargs = "?",
        desc = "Quick dependency status check (usage: [host1,host2,...] or empty for auto-discovery)",
        complete = "file",
    })

    utils.log("Registered user commands", vim.log.levels.DEBUG, false, config.config)
end

return M
