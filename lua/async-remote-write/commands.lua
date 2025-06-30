local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local operations = require('async-remote-write.operations')
local process = require('async-remote-write.process')
local buffer = require('async-remote-write.buffer')
local browse = require('async-remote-write.browse')

function M.register()

    vim.api.nvim_create_user_command("RemoteBrowse", function(opts)
        browse.browse_remote_directory(opts.args, true) -- true = reset selections
    end, {
        nargs = 1,
        desc = "Browse a remote directory and open files with Telescope",
        complete = "file"
    })

    vim.api.nvim_create_user_command("RemoteBrowseFiles", function(opts)
        browse.browse_remote_files(opts.args, true) -- true = reset selections
    end, {
        nargs = 1,
        desc = "Browse all files recursively in a remote directory with Telescope",
        complete = "file"
    })

    vim.api.nvim_create_user_command("RemoteBrowseFilesIncremental", function(opts)
        browse.browse_remote_files_incremental(opts.args, true) -- true = reset selections
    end, {
        nargs = 1,
        desc = "Browse files with incremental loading (500 files per chunk, <C-l> to load more)",
        complete = "file"
    })

    vim.api.nvim_create_user_command("RemoteBrowseLevel", function(opts)
        browse.browse_remote_level_based(opts.args, true) -- true = reset selections
    end, {
        nargs = 1,
        desc = "Browse with level-by-level discovery (guaranteed directory visibility, <C-r> for recursive)",
        complete = "file"
    })
    
    vim.api.nvim_create_user_command("RemoteBrowseTree", function(opts)
        browse.browse_remote_directory_tree(opts.args, true) -- true = reset selections
    end, {
        nargs = 1,
        desc = "Browse with tree-based expansion (Enter:expand/collapse, Tab:select, <C-o>:process)",
        complete = "file"
    })
    
    vim.api.nvim_create_user_command("RemoteBrowseTreeV2", function(opts)
        browse.browse_remote_tree_v2(opts.args, true) -- true = reset selections
    end, {
        nargs = 1,
        desc = "New tree browser with background warming and correct ordering",
        complete = "file"
    })
    
    vim.api.nvim_create_user_command("RemoteGrep", function(opts)
        browse.grep_remote_directory(opts.args)
    end, {
        nargs = 1,
        desc = "Search for text in remote files using grep",
        complete = "file"
    })

    -- Add a command to open remote files
    vim.api.nvim_create_user_command("RemoteOpen", function(opts)
        operations.open_remote_file(opts.args)
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
        complete = "buffer"
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
        desc = "Refresh all remote buffers by re-fetching their content"
    })

    -- Create command aliases to ensure compatibility with existing workflows
    vim.cmd [[
    command! -nargs=1 -complete=file Rscp RemoteOpen rsync://<args>
    command! -nargs=1 -complete=file Scp RemoteOpen scp://<args>
    command! -nargs=1 -complete=file E RemoteOpen <args>
    ]]

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
        bang = true
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
            ERROR = vim.log.levels.ERROR
        }

        if levels[level_name] then
            config.config.log_level = levels[level_name]
            -- If setting to DEBUG, also enable debug mode
            if level_name == "DEBUG" then
                config.config.debug = true
            end
            utils.log("Log level set to " .. level_name, vim.log.levels.INFO, true, config.config)
        else
            utils.log("Invalid log level: " .. opts.args .. ". Use DEBUG, INFO, WARN, or ERROR", vim.log.levels.ERROR, true, config.config)
        end
    end, {
        desc = "Set the logging level (DEBUG, INFO, WARN, ERROR)",
        nargs = 1,
        complete = function()
            return { "DEBUG", "INFO", "WARN", "ERROR" }
        end
    })

    -- Add reregister command for manual fixing of buffer autocommands
    vim.api.nvim_create_user_command("AsyncWriteReregister", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local result = buffer.register_buffer_autocommands(bufnr)
        if result then
            utils.log("Successfully reregistered autocommands for buffer " .. bufnr, vim.log.levels.INFO, true, config.config)
        else
            utils.log("Failed to reregister autocommands (not a remote buffer?)", vim.log.levels.WARN, true, config.config)
        end
    end, { desc = "Reregister buffer-specific autocommands for current buffer" })

    -- Cache management commands
    vim.api.nvim_create_user_command("RemoteCacheStats", function()
        local stats = browse.get_cache_stats()
        local message = string.format([[
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
        complete = "file"
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
        complete = "file"
    })

    vim.api.nvim_create_user_command("RemoteCacheWarmStatus", function()
        local status = browse.get_cache_warming_status()
        local message = string.format([[ 
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
        
        utils.log("Auto cache warming " .. (new_state and "enabled" or "disabled"), 
                 vim.log.levels.DEBUG, false, config.config)
    end, { desc = "Toggle automatic cache warming on directory browse" })

    utils.log("Registered user commands", vim.log.levels.DEBUG, false, config.config)
end

return M
