local M = {}

local remote_git = require('remote-gitsigns.remote-git')
local git_adapter = require('remote-gitsigns.git-adapter')
local utils = require('async-remote-write.utils')
local metadata = require('remote-buffer-metadata')
local log = require('logging').log

-- Track buffers we've already processed to avoid duplicate work
local processed_buffers = {}

-- Configuration
local config = {
    -- File patterns to exclude from git detection
    exclude_patterns = {
        '*/%.git/*',
        '*/node_modules/*',
        '*/__pycache__/*',
        '*/%.venv/*',
        '*/venv/*',
        '*/%.env/*'
    },
    
    -- Enable async detection to avoid blocking
    async_detection = true,
    
    -- Timeout for git operations during detection
    detection_timeout = 10000, -- 10 seconds
}

-- Check if a path matches any exclude pattern
local function is_excluded_path(path)
    for _, pattern in ipairs(config.exclude_patterns) do
        if path:match(pattern) then
            log("Path excluded by pattern '" .. pattern .. "': " .. path, vim.log.levels.DEBUG, false)
            return true
        end
    end
    return false
end

-- Check if remote buffer is in a Git repository
function M.check_remote_git_buffer(bufnr, callback)
    -- Avoid processing the same buffer multiple times
    if processed_buffers[bufnr] then
        local result = processed_buffers[bufnr]
        if callback then
            callback(result.is_git, result.git_root)
        end
        return result.is_git
    end
    
    -- Validate buffer
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Invalid buffer: " .. bufnr, vim.log.levels.DEBUG, false)
        processed_buffers[bufnr] = { is_git = false, git_root = nil }
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    
    -- Only process remote buffers
    if not (bufname:match('^scp://') or bufname:match('^rsync://')) then
        log("Not a remote buffer: " .. bufname, vim.log.levels.DEBUG, false)
        processed_buffers[bufnr] = { is_git = false, git_root = nil }
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    -- Parse remote path
    local parsed = utils.parse_remote_path(bufname)
    if not parsed then
        log("Failed to parse remote path: " .. bufname, vim.log.levels.ERROR, false)
        processed_buffers[bufnr] = { is_git = false, git_root = nil }
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    -- Check if path should be excluded
    if is_excluded_path(parsed.path) then
        processed_buffers[bufnr] = { is_git = false, git_root = nil }
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    log("Checking git repository for buffer " .. bufnr .. ": " .. bufname, vim.log.levels.DEBUG, false)
    
    -- Function to perform the actual git detection
    local function do_git_detection()
        -- Find Git root on remote host
        local git_root = remote_git.find_git_root(parsed.host, parsed.path)
        
        local result = { is_git = false, git_root = git_root }
        
        if git_root then
            log("Found git root for buffer " .. bufnr .. ": " .. git_root, vim.log.levels.INFO, false)
            
            -- Register with git adapter
            local success = git_adapter.register_remote_buffer(bufnr, {
                host = parsed.host,
                remote_path = parsed.path,
                git_root = git_root,
                protocol = parsed.protocol
            })
            
            if success then
                result.is_git = true
                
                -- Store git info in buffer metadata for other components
                metadata.set(bufnr, 'remote-gitsigns', 'git_root', git_root)
                metadata.set(bufnr, 'remote-gitsigns', 'host', parsed.host)
                metadata.set(bufnr, 'remote-gitsigns', 'remote_path', parsed.path)
                metadata.set(bufnr, 'remote-gitsigns', 'protocol', parsed.protocol)
                
                log("Successfully registered git buffer " .. bufnr, vim.log.levels.INFO, false)
            else
                log("Failed to register git buffer " .. bufnr, vim.log.levels.ERROR, false)
            end
        else
            log("No git repository found for buffer " .. bufnr, vim.log.levels.DEBUG, false)
        end
        
        -- Cache the result
        processed_buffers[bufnr] = result
        
        -- Call callback if provided
        if callback then
            callback(result.is_git, result.git_root)
        end
        
        return result.is_git
    end
    
    -- Perform detection (async or sync based on config)
    if config.async_detection and callback then
        -- Async detection
        vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                do_git_detection()
            else
                callback(false, nil)
            end
        end, 10) -- Small delay to avoid blocking
        
        return nil -- Result will come via callback
    else
        -- Synchronous detection
        return do_git_detection()
    end
end

-- Setup autocommands to detect remote Git buffers automatically
function M.setup_detection()
    local augroup = vim.api.nvim_create_augroup('RemoteGitsigns_Detection', { clear = true })
    
    -- Check buffers when they're read
    vim.api.nvim_create_autocmd('BufReadPost', {
        group = augroup,
        pattern = { 'scp://*', 'rsync://*' },
        callback = function(args)
            log("BufReadPost triggered for buffer " .. args.buf, vim.log.levels.DEBUG, false)
            
            -- Use a small delay to ensure buffer is fully loaded
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(args.buf) then
                    M.check_remote_git_buffer(args.buf, function(is_git, git_root)
                        if is_git then
                            -- Trigger gitsigns to process this buffer
                            vim.defer_fn(function()
                                if vim.api.nvim_buf_is_valid(args.buf) then
                                    -- Try to trigger gitsigns update
                                    local ok, gitsigns = pcall(require, 'gitsigns')
                                    if ok and gitsigns.attach then
                                        log("Triggering gitsigns attach for buffer " .. args.buf, vim.log.levels.DEBUG, false)
                                        pcall(gitsigns.attach, args.buf)
                                    end
                                end
                            end, 500) -- Give git adapter time to register
                        end
                    end)
                end
            end, 100)
        end,
    })
    
    -- Check buffers when they become current (in case we missed them)
    vim.api.nvim_create_autocmd('BufEnter', {
        group = augroup,
        pattern = { 'scp://*', 'rsync://*' },
        callback = function(args)
            -- Only check if we haven't processed this buffer yet
            if not processed_buffers[args.buf] then
                log("BufEnter triggered for unprocessed buffer " .. args.buf, vim.log.levels.DEBUG, false)
                M.check_remote_git_buffer(args.buf)
            end
        end,
    })
    
    -- Check buffers when filetype is detected (fallback)
    vim.api.nvim_create_autocmd('FileType', {
        group = augroup,
        callback = function(args)
            local bufname = vim.api.nvim_buf_get_name(args.buf)
            if (bufname:match('^scp://') or bufname:match('^rsync://')) and 
               not processed_buffers[args.buf] then
                log("FileType triggered for unprocessed remote buffer " .. args.buf, vim.log.levels.DEBUG, false)
                M.check_remote_git_buffer(args.buf)
            end
        end,
    })
    
    -- Clean up when buffer is deleted
    vim.api.nvim_create_autocmd('BufDelete', {
        group = augroup,
        callback = function(args)
            if processed_buffers[args.buf] then
                log("Cleaning up buffer " .. args.buf, vim.log.levels.DEBUG, false)
                
                -- Unregister from git adapter
                git_adapter.unregister_remote_buffer(args.buf)
                
                -- Clean up our tracking
                processed_buffers[args.buf] = nil
                
                -- Clean up metadata
                metadata.clear_namespace(args.buf, 'remote-gitsigns')
            end
        end,
    })
    
    log("Remote git buffer detection set up", vim.log.levels.INFO, false)
end

-- Manually trigger detection for a specific buffer (useful for testing)
function M.detect_buffer(bufnr, callback)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    
    -- Clear any cached result to force re-detection
    processed_buffers[bufnr] = nil
    
    return M.check_remote_git_buffer(bufnr, callback)
end

-- Check all currently open remote buffers
function M.detect_all_remote_buffers(callback)
    local remote_buffers = {}
    local pending = 0
    local results = {}
    
    -- Find all remote buffers
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match('^scp://') or bufname:match('^rsync://') then
                table.insert(remote_buffers, bufnr)
            end
        end
    end
    
    if #remote_buffers == 0 then
        log("No remote buffers found", vim.log.levels.DEBUG, false)
        if callback then
            callback({})
        end
        return {}
    end
    
    log("Detecting git repositories for " .. #remote_buffers .. " remote buffers", vim.log.levels.INFO, false)
    
    pending = #remote_buffers
    
    -- Process each buffer
    for _, bufnr in ipairs(remote_buffers) do
        M.check_remote_git_buffer(bufnr, function(is_git, git_root)
            results[bufnr] = { is_git = is_git, git_root = git_root }
            pending = pending - 1
            
            if pending == 0 and callback then
                callback(results)
            end
        end)
    end
    
    -- If all detections were synchronous, call callback immediately
    if pending == 0 and callback then
        callback(results)
    end
    
    return results
end

-- Get detection status for a buffer
function M.get_buffer_status(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    return processed_buffers[bufnr]
end

-- Update configuration
function M.configure(opts)
    config = vim.tbl_deep_extend('force', config, opts or {})
    log("Updated buffer detector configuration", vim.log.levels.DEBUG, false)
end

-- Get current configuration
function M.get_config()
    return vim.deepcopy(config)
end

-- Reset detector state (useful for testing)
function M.reset()
    processed_buffers = {}
    log("Reset buffer detector state", vim.log.levels.DEBUG, false)
end

return M