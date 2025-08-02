local M = {}

local log = require('logging').log

-- Cache storage
local cache_data = {}
local cache_metadata = {}

-- Default configuration
local default_config = {
    -- Time-to-live for cache entries (seconds)
    ttl = 300, -- 5 minutes
    
    -- Maximum number of cache entries
    max_entries = 1000,
    
    -- Enable periodic cleanup
    cleanup_enabled = true,
    
    -- Cleanup interval (seconds)
    cleanup_interval = 60, -- 1 minute
    
    -- Enable cache statistics
    stats_enabled = true,
}

local config = vim.deepcopy(default_config)
local stats = {
    hits = 0,
    misses = 0,
    sets = 0,
    evictions = 0,
    cleanups = 0,
}

-- Cleanup timer
local cleanup_timer = nil

-- Generate cache key from components
local function make_key(...)
    local parts = {...}
    for i, part in ipairs(parts) do
        parts[i] = tostring(part)
    end
    return table.concat(parts, ":")
end

-- Check if cache entry is expired
local function is_expired(entry_meta)
    if not entry_meta then
        return true
    end
    
    local now = os.time()
    return (now - entry_meta.timestamp) >= config.ttl
end

-- Evict expired entries
local function cleanup_expired()
    local now = os.time()
    local removed = 0
    
    for key, meta in pairs(cache_metadata) do
        if is_expired(meta) then
            cache_data[key] = nil
            cache_metadata[key] = nil
            removed = removed + 1
        end
    end
    
    if removed > 0 then
        log("Cleaned up " .. removed .. " expired cache entries", vim.log.levels.DEBUG, false)
        if config.stats_enabled then
            stats.cleanups = stats.cleanups + 1
            stats.evictions = stats.evictions + removed
        end
    end
    
    return removed
end

-- Evict oldest entries if cache is full
local function evict_if_full()
    local current_size = 0
    for _ in pairs(cache_data) do
        current_size = current_size + 1
    end
    
    if current_size >= config.max_entries then
        -- Find oldest entries
        local entries_by_age = {}
        for key, meta in pairs(cache_metadata) do
            table.insert(entries_by_age, {key = key, timestamp = meta.timestamp})
        end
        
        -- Sort by timestamp (oldest first)
        table.sort(entries_by_age, function(a, b)
            return a.timestamp < b.timestamp
        end)
        
        -- Remove oldest entries until we're under the limit
        local to_remove = current_size - config.max_entries + 10 -- Remove a few extra
        local removed = 0
        
        for i = 1, math.min(to_remove, #entries_by_age) do
            local key = entries_by_age[i].key
            cache_data[key] = nil
            cache_metadata[key] = nil
            removed = removed + 1
        end
        
        if removed > 0 then
            log("Evicted " .. removed .. " cache entries due to size limit", vim.log.levels.DEBUG, false)
            if config.stats_enabled then
                stats.evictions = stats.evictions + removed
            end
        end
    end
end

-- Set up periodic cleanup
local function setup_cleanup()
    if cleanup_timer then
        cleanup_timer:stop()
        cleanup_timer = nil
    end
    
    if config.cleanup_enabled and config.cleanup_interval > 0 then
        cleanup_timer = vim.loop.new_timer()
        if cleanup_timer then
            cleanup_timer:start(config.cleanup_interval * 1000, config.cleanup_interval * 1000, function()
                vim.schedule(function()
                    cleanup_expired()
                end)
            end)
            log("Started cache cleanup timer (interval: " .. config.cleanup_interval .. "s)", vim.log.levels.DEBUG, false)
        end
    end
end

-- Get value from cache
function M.get(...)
    local key = make_key(...)
    local meta = cache_metadata[key]
    
    if not meta or is_expired(meta) then
        if config.stats_enabled then
            stats.misses = stats.misses + 1
        end
        
        -- Clean up expired entry
        if meta then
            cache_data[key] = nil
            cache_metadata[key] = nil
        end
        
        return nil
    end
    
    if config.stats_enabled then
        stats.hits = stats.hits + 1
    end
    
    -- Update access time
    meta.last_access = os.time()
    
    return cache_data[key]
end

-- Set value in cache
function M.set(value, ...)
    local key = make_key(...)
    
    -- Evict old entries if needed
    evict_if_full()
    
    -- Store data and metadata
    cache_data[key] = value
    cache_metadata[key] = {
        timestamp = os.time(),
        last_access = os.time(),
        size = type(value) == 'string' and #value or 1
    }
    
    if config.stats_enabled then
        stats.sets = stats.sets + 1
    end
    
    log("Cached value with key: " .. key, vim.log.levels.DEBUG, false)
end

-- Check if key exists in cache (without updating access time)
function M.has(...)
    local key = make_key(...)
    local meta = cache_metadata[key]
    return meta ~= nil and not is_expired(meta)
end

-- Delete specific key from cache
function M.delete(...)
    local key = make_key(...)
    local existed = cache_data[key] ~= nil
    
    cache_data[key] = nil
    cache_metadata[key] = nil
    
    if existed then
        log("Deleted cache key: " .. key, vim.log.levels.DEBUG, false)
    end
    
    return existed
end

-- Clear all cache entries
function M.clear()
    local count = 0
    for _ in pairs(cache_data) do
        count = count + 1
    end
    
    cache_data = {}
    cache_metadata = {}
    
    log("Cleared " .. count .. " cache entries", vim.log.levels.DEBUG, false)
    return count
end

-- Clear cache entries matching a pattern
function M.clear_pattern(pattern)
    local removed = 0
    local keys_to_remove = {}
    
    for key in pairs(cache_data) do
        if key:match(pattern) then
            table.insert(keys_to_remove, key)
        end
    end
    
    for _, key in ipairs(keys_to_remove) do
        cache_data[key] = nil
        cache_metadata[key] = nil
        removed = removed + 1
    end
    
    if removed > 0 then
        log("Cleared " .. removed .. " cache entries matching pattern: " .. pattern, vim.log.levels.DEBUG, false)
    end
    
    return removed
end

-- Get cache statistics
function M.get_stats()
    if not config.stats_enabled then
        return { stats_disabled = true }
    end
    
    local current_size = 0
    local total_size = 0
    local expired_count = 0
    
    for key, meta in pairs(cache_metadata) do
        current_size = current_size + 1
        total_size = total_size + (meta.size or 1)
        
        if is_expired(meta) then
            expired_count = expired_count + 1
        end
    end
    
    local hit_rate = 0
    local total_requests = stats.hits + stats.misses
    if total_requests > 0 then
        hit_rate = stats.hits / total_requests
    end
    
    return {
        hits = stats.hits,
        misses = stats.misses,
        sets = stats.sets,
        evictions = stats.evictions,
        cleanups = stats.cleanups,
        hit_rate = hit_rate,
        current_size = current_size,
        total_size = total_size,
        expired_count = expired_count,
        max_entries = config.max_entries,
        ttl = config.ttl,
    }
end

-- Reset statistics
function M.reset_stats()
    stats = {
        hits = 0,
        misses = 0,
        sets = 0,
        evictions = 0,
        cleanups = 0,
    }
    log("Reset cache statistics", vim.log.levels.DEBUG, false)
end

-- Configure cache settings
function M.configure(opts)
    local old_config = vim.deepcopy(config)
    config = vim.tbl_deep_extend('force', config, opts or {})
    
    -- Restart cleanup timer if settings changed
    if config.cleanup_enabled ~= old_config.cleanup_enabled or
       config.cleanup_interval ~= old_config.cleanup_interval then
        setup_cleanup()
    end
    
    -- Clear cache if TTL changed significantly
    if math.abs(config.ttl - old_config.ttl) > 60 then
        log("TTL changed significantly, clearing cache", vim.log.levels.INFO, false)
        M.clear()
    end
    
    log("Updated cache configuration", vim.log.levels.DEBUG, false)
end

-- Get current configuration
function M.get_config()
    return vim.deepcopy(config)
end

-- Initialize cache system
function M.setup(opts)
    M.configure(opts or {})
    setup_cleanup()
    log("Cache system initialized", vim.log.levels.INFO, false)
end

-- Shutdown cache system
function M.shutdown()
    if cleanup_timer then
        cleanup_timer:stop()
        cleanup_timer = nil
    end
    
    local count = M.clear()
    log("Cache system shutdown, cleared " .. count .. " entries", vim.log.levels.INFO, false)
end

-- Convenience functions for common cache patterns

-- Cache git repository information
function M.cache_repo_info(host, workdir, info)
    M.set(info, 'repo_info', host, workdir)
end

function M.get_repo_info(host, workdir)
    return M.get('repo_info', host, workdir)
end

-- Cache git root discovery
function M.cache_git_root(host, file_path, git_root)
    M.set(git_root, 'git_root', host, file_path)
end

function M.get_git_root(host, file_path)
    return M.get('git_root', host, file_path)
end

-- Cache file status
function M.cache_file_status(host, workdir, file_path, status)
    M.set(status, 'file_status', host, workdir, file_path)
end

function M.get_file_status(host, workdir, file_path)
    return M.get('file_status', host, workdir, file_path)
end

-- Cache git show output
function M.cache_file_content(host, workdir, file_path, revision, content)
    M.set(content, 'file_content', host, workdir, file_path, revision or 'HEAD')
end

function M.get_file_content(host, workdir, file_path, revision)
    return M.get('file_content', host, workdir, file_path, revision or 'HEAD')
end

-- Initialize with default configuration
M.setup()

return M