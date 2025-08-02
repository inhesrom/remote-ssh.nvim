local M = {}

local git_adapter = require('remote-gitsigns.git-adapter')
local buffer_detector = require('remote-gitsigns.buffer-detector')
local cache = require('remote-gitsigns.cache')
local log = require('logging').log

-- Default configuration
local default_config = {
    -- Enable gitsigns integration for remote files
    enabled = true,
    
    -- Timeout for Git operations (milliseconds)
    git_timeout = 30000,
    
    -- Cache configuration
    cache = {
        enabled = true,
        ttl = 300, -- 5 minutes
        max_entries = 1000,
        cleanup_enabled = true,
        cleanup_interval = 60, -- 1 minute
    },
    
    -- Buffer detection configuration
    detection = {
        -- Enable async detection to avoid blocking
        async_detection = true,
        
        -- File patterns to exclude from git detection
        exclude_patterns = {
            '*/%.git/*',
            '*/node_modules/*',
            '*/__pycache__/*',
            '*/%.venv/*',
            '*/venv/*',
            '*/%.env/*',
        },
        
        -- Timeout for git operations during detection
        detection_timeout = 10000, -- 10 seconds
    },
    
    -- Signs configuration (inherits from gitsigns if not specified)
    signs = nil,
    
    -- Automatically attach gitsigns to detected remote git buffers
    auto_attach = true,
    
    -- Debug mode
    debug = false,
}

local config = {}
local is_initialized = false

-- Check if gitsigns is available
local function check_gitsigns_available()
    local ok, gitsigns = pcall(require, 'gitsigns')
    if not ok then
        log("gitsigns.nvim not found - remote gitsigns integration disabled", vim.log.levels.WARN, true)
        return false
    end
    
    -- Check for required gitsigns functions
    if not gitsigns.attach then
        log("gitsigns.attach function not found - incompatible gitsigns version", vim.log.levels.ERROR, true)
        return false
    end
    
    return true, gitsigns
end

-- Set up user commands for manual control
local function setup_commands()
    local augroup = vim.api.nvim_create_augroup('RemoteGitsigns_Commands', { clear = true })
    
    -- Command to manually detect git repositories in remote buffers
    vim.api.nvim_create_user_command('RemoteGitsignsDetect', function(opts)
        local bufnr = opts.args and tonumber(opts.args) or vim.api.nvim_get_current_buf()
        
        log("Manually triggering git detection for buffer " .. bufnr, vim.log.levels.INFO, true)
        
        buffer_detector.detect_buffer(bufnr, function(is_git, git_root)
            if is_git then
                vim.notify("Git repository detected: " .. git_root, vim.log.levels.INFO)
                
                -- Try to attach gitsigns
                if config.auto_attach then
                    local ok, gitsigns = pcall(require, 'gitsigns')
                    if ok and gitsigns.attach then
                        pcall(gitsigns.attach, bufnr)
                    end
                end
            else
                vim.notify("No git repository found for buffer " .. bufnr, vim.log.levels.INFO)
            end
        end)
    end, {
        desc = "Manually detect git repository for remote buffer",
        nargs = '?',
    })
    
    -- Command to show cache statistics
    vim.api.nvim_create_user_command('RemoteGitsignsStats', function()
        local stats = cache.get_stats()
        local lines = {
            "Remote Gitsigns Cache Statistics:",
            "  Enabled: " .. tostring(config.cache.enabled),
            "  Hits: " .. stats.hits,
            "  Misses: " .. stats.misses,
            "  Hit Rate: " .. string.format("%.2f%%", (stats.hit_rate or 0) * 100),
            "  Current Size: " .. stats.current_size .. "/" .. stats.max_entries,
            "  Expired: " .. stats.expired_count,
            "  Evictions: " .. stats.evictions,
            "  Cleanups: " .. stats.cleanups,
            "  TTL: " .. stats.ttl .. "s",
        }
        
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end, {
        desc = "Show remote gitsigns cache statistics",
    })
    
    -- Command to clear cache
    vim.api.nvim_create_user_command('RemoteGitsignsClearCache', function()
        local count = cache.clear()
        vim.notify("Cleared " .. count .. " cache entries", vim.log.levels.INFO)
    end, {
        desc = "Clear remote gitsigns cache",
    })
    
    -- Command to show status
    vim.api.nvim_create_user_command('RemoteGitsignsStatus', function()
        local adapter_active = git_adapter.is_active()
        local bufnr = vim.api.nvim_get_current_buf()
        local buffer_status = buffer_detector.get_buffer_status(bufnr)
        local remote_info = git_adapter.get_remote_info(bufnr)
        
        local lines = {
            "Remote Gitsigns Status:",
            "  Enabled: " .. tostring(config.enabled),
            "  Git Adapter Active: " .. tostring(adapter_active),
            "  Current Buffer (" .. bufnr .. "):",
        }
        
        if buffer_status then
            table.insert(lines, "    Git Repository: " .. tostring(buffer_status.is_git))
            if buffer_status.git_root then
                table.insert(lines, "    Git Root: " .. buffer_status.git_root)
            end
        else
            table.insert(lines, "    Status: Not processed")
        end
        
        if remote_info then
            table.insert(lines, "    Host: " .. remote_info.host)
            table.insert(lines, "    Remote Path: " .. remote_info.remote_path)
            table.insert(lines, "    Protocol: " .. remote_info.protocol)
        end
        
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end, {
        desc = "Show remote gitsigns status",
    })
    
    log("Set up remote gitsigns user commands", vim.log.levels.DEBUG, false)
end

-- Set up integration with gitsigns
local function setup_gitsigns_integration()
    local gitsigns_available, gitsigns = check_gitsigns_available()
    if not gitsigns_available then
        return false
    end
    
    -- Set up git command hook
    if not git_adapter.setup_git_command_hook() then
        log("Failed to setup gitsigns git command hook", vim.log.levels.ERROR, true)
        return false
    end
    
    -- Set up buffer detection
    buffer_detector.setup_detection()
    
    -- Process any existing remote buffers
    vim.defer_fn(function()
        buffer_detector.detect_all_remote_buffers(function(results)
            local git_buffers = 0
            for bufnr, result in pairs(results) do
                if result.is_git then
                    git_buffers = git_buffers + 1
                    
                    -- Auto-attach gitsigns if configured
                    if config.auto_attach then
                        vim.defer_fn(function()
                            if vim.api.nvim_buf_is_valid(bufnr) then
                                log("Auto-attaching gitsigns to buffer " .. bufnr, vim.log.levels.DEBUG, false)
                                pcall(gitsigns.attach, bufnr)
                            end
                        end, 100)
                    end
                end
            end
            
            if git_buffers > 0 then
                log("Found " .. git_buffers .. " remote git buffers", vim.log.levels.INFO, true)
            end
        end)
    end, 500) -- Give everything time to initialize
    
    return true
end

-- Main setup function
function M.setup(opts)
    if is_initialized then
        log("Remote gitsigns already initialized", vim.log.levels.WARN, false)
        return
    end
    
    -- Merge configuration
    config = vim.tbl_deep_extend('force', default_config, opts or {})
    
    if not config.enabled then
        log("Remote gitsigns disabled by configuration", vim.log.levels.INFO, false)
        return
    end
    
    log("Setting up remote gitsigns integration...", vim.log.levels.INFO, false)
    
    -- Configure cache
    if config.cache.enabled then
        cache.configure(config.cache)
        log("Cache configured with TTL: " .. config.cache.ttl .. "s", vim.log.levels.DEBUG, false)
    else
        cache.shutdown()
        log("Cache disabled", vim.log.levels.DEBUG, false)
    end
    
    -- Configure buffer detector
    buffer_detector.configure(config.detection)
    
    -- Set up user commands
    setup_commands()
    
    -- Set up gitsigns integration
    if not setup_gitsigns_integration() then
        log("Failed to setup gitsigns integration", vim.log.levels.ERROR, true)
        return
    end
    
    is_initialized = true
    log("Remote gitsigns integration enabled successfully", vim.log.levels.INFO, true)
    
    -- Set up cleanup on VimLeavePre
    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = vim.api.nvim_create_augroup('RemoteGitsigns_Cleanup', { clear = true }),
        callback = function()
            M.shutdown()
        end,
    })
end

-- Shutdown function
function M.shutdown()
    if not is_initialized then
        return
    end
    
    log("Shutting down remote gitsigns integration...", vim.log.levels.DEBUG, false)
    
    -- Reset git adapter
    git_adapter.reset()
    
    -- Reset buffer detector
    buffer_detector.reset()
    
    -- Shutdown cache
    if config.cache and config.cache.enabled then
        cache.shutdown()
    end
    
    is_initialized = false
    log("Remote gitsigns integration shut down", vim.log.levels.DEBUG, false)
end

-- Get current configuration
function M.get_config()
    return vim.deepcopy(config)
end

-- Check if initialized
function M.is_initialized()
    return is_initialized
end

-- Get status information
function M.get_status()
    return {
        initialized = is_initialized,
        enabled = config.enabled,
        git_adapter_active = git_adapter.is_active(),
        cache_enabled = config.cache and config.cache.enabled,
        cache_stats = config.cache and config.cache.enabled and cache.get_stats() or nil,
    }
end

-- Manual detection function (useful for testing)
function M.detect_buffer(bufnr, callback)
    if not is_initialized then
        log("Remote gitsigns not initialized", vim.log.levels.ERROR, false)
        return false
    end
    
    return buffer_detector.detect_buffer(bufnr, callback)
end

-- Detect all remote buffers
function M.detect_all_buffers(callback)
    if not is_initialized then
        log("Remote gitsigns not initialized", vim.log.levels.ERROR, false)
        return {}
    end
    
    return buffer_detector.detect_all_remote_buffers(callback)
end

-- Force refresh of a buffer's git status
function M.refresh_buffer(bufnr)
    if not is_initialized then
        log("Remote gitsigns not initialized", vim.log.levels.ERROR, false)
        return false
    end
    
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    
    -- Clear any cached data for this buffer
    local remote_info = git_adapter.get_remote_info(bufnr)
    if remote_info then
        cache.clear_pattern(remote_info.host .. ":" .. remote_info.remote_path)
        cache.clear_pattern(remote_info.host .. ":" .. remote_info.remote_workdir)
    end
    
    -- Re-detect the buffer
    return M.detect_buffer(bufnr, function(is_git, git_root)
        if is_git and config.auto_attach then
            -- Try to trigger gitsigns update
            local ok, gitsigns = pcall(require, 'gitsigns')
            if ok and gitsigns.refresh then
                pcall(gitsigns.refresh, bufnr)
            elseif ok and gitsigns.attach then
                pcall(gitsigns.attach, bufnr)
            end
        end
    end)
end

return M