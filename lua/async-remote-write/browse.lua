local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local operations = require('async-remote-write.operations')

local selected_files = {}
local files_to_delete = {}
local files_to_create = {}
local MAX_FILES = 50000 -- Limit the total number of files
local CHUNK_SIZE = 500 -- Number of files to load per chunk
local CACHE_TTL = 60 -- Cache time-to-live in seconds

-- Map to track the status of each file for visual feedback
local file_status = {}

-- Incremental loading state
local incremental_state = {}

-- Smart cache system
local cache = {
    directory_listings = {}, -- Cache for directory browse results
    file_listings = {},      -- Cache for recursive file listings  
    incremental_listings = {}, -- Cache for incremental file chunks
    stats = {
        hits = 0,
        misses = 0,
        evictions = 0,
        total_requests = 0
    }
}

-- Cache management functions
local function get_cache_key(url, extra_params)
    local key = url
    if extra_params then
        key = key .. "|" .. vim.inspect(extra_params)
    end
    return key
end

local function is_cache_valid(entry)
    if not entry then return false end
    local now = os.time()
    return (now - entry.timestamp) < CACHE_TTL
end

local function cache_get(cache_type, key)
    cache.stats.total_requests = cache.stats.total_requests + 1
    
    local cache_store = cache[cache_type]
    if not cache_store then return nil end
    
    local entry = cache_store[key]
    if entry and is_cache_valid(entry) then
        cache.stats.hits = cache.stats.hits + 1
        utils.log("Cache HIT for " .. cache_type .. ": " .. key, vim.log.levels.DEBUG, false, config.config)
        return entry.data
    else
        cache.stats.misses = cache.stats.misses + 1
        if entry then
            utils.log("Cache EXPIRED for " .. cache_type .. ": " .. key, vim.log.levels.DEBUG, false, config.config)
            cache_store[key] = nil
            cache.stats.evictions = cache.stats.evictions + 1
        else
            utils.log("Cache MISS for " .. cache_type .. ": " .. key, vim.log.levels.DEBUG, false, config.config)
        end
        return nil
    end
end

local function cache_set(cache_type, key, data)
    local cache_store = cache[cache_type]
    if not cache_store then return end
    
    cache_store[key] = {
        data = data,
        timestamp = os.time()
    }
    utils.log("Cache SET for " .. cache_type .. ": " .. key .. " (" .. #data .. " items)", vim.log.levels.DEBUG, false, config.config)
end

local function cache_invalidate_pattern(pattern)
    local invalidated = 0
    for cache_type, cache_store in pairs(cache) do
        if type(cache_store) == "table" and cache_type ~= "stats" then
            for key, _ in pairs(cache_store) do
                if key:match(pattern) then
                    cache_store[key] = nil
                    invalidated = invalidated + 1
                end
            end
        end
    end
    if invalidated > 0 then
        utils.log("Cache invalidated " .. invalidated .. " entries matching: " .. pattern, vim.log.levels.DEBUG, false, config.config)
        cache.stats.evictions = cache.stats.evictions + invalidated
    end
end

local function cache_clear()
    local total = 0
    for cache_type, cache_store in pairs(cache) do
        if type(cache_store) == "table" and cache_type ~= "stats" then
            for key, _ in pairs(cache_store) do
                total = total + 1
            end
            cache[cache_type] = {}
        end
    end
    cache.stats.evictions = cache.stats.evictions + total
    utils.log("Cache cleared " .. total .. " entries", vim.log.levels.INFO, true, config.config)
end

function M.get_cache_stats()
    local hit_rate = cache.stats.total_requests > 0 and 
        (cache.stats.hits / cache.stats.total_requests * 100) or 0
    
    return {
        hits = cache.stats.hits,
        misses = cache.stats.misses,
        evictions = cache.stats.evictions,
        total_requests = cache.stats.total_requests,
        hit_rate = string.format("%.1f%%", hit_rate),
        cache_entries = {
            directory_listings = vim.tbl_count(cache.directory_listings),
            file_listings = vim.tbl_count(cache.file_listings),
            incremental_listings = vim.tbl_count(cache.incremental_listings)
        }
    }
end

function M.clear_cache()
    cache_clear()
end

-- Background cache warming system
local cache_warming = {
    active_jobs = {},       -- Track active warming jobs
    warming_queue = {},     -- Queue of directories to warm
    stats = {
        directories_warmed = 0,
        files_cached = 0,
        start_time = nil,
        total_discovered = 0
    },
    config = {
        max_depth = 5,      -- Maximum depth to cache
        max_concurrent = 2, -- Maximum concurrent SSH jobs
        batch_size = 10,    -- Directories per batch
        auto_warm = true    -- Auto-warm on first browse
    }
}

function M.start_cache_warming(url, options)
    options = options or {}
    local max_depth = options.max_depth or cache_warming.config.max_depth
    local max_concurrent = options.max_concurrent or cache_warming.config.max_concurrent
    
    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Invalid remote URL for cache warming: " .. url, vim.log.levels.ERROR, true, config.config)
        return false
    end

    -- Check if already warming this path
    local warming_key = remote_info.host .. ":" .. remote_info.path
    if cache_warming.active_jobs[warming_key] then
        utils.log("Cache warming already active for: " .. url, vim.log.levels.INFO, true, config.config)
        return false
    end

    utils.log("Starting background cache warming for: " .. url .. " (max depth: " .. max_depth .. ")", 
              vim.log.levels.DEBUG, false, config.config)

    -- Initialize warming state
    cache_warming.stats.start_time = os.time()
    cache_warming.stats.directories_warmed = 0
    cache_warming.stats.files_cached = 0
    cache_warming.stats.total_discovered = 0

    -- Start breadth-first warming
    cache_warming.active_jobs[warming_key] = {
        url = url,
        max_depth = max_depth,
        current_depth = 0,
        queue = {url},
        processed = {},
        start_time = os.time()
    }

    M.process_warming_queue(warming_key)
    return true
end

function M.process_warming_queue(warming_key)
    local job = cache_warming.active_jobs[warming_key]
    if not job or #job.queue == 0 then
        if job then
            M.finish_cache_warming(warming_key)
        end
        return
    end

    -- Process next batch of directories
    local batch = {}
    local batch_size = math.min(cache_warming.config.batch_size, #job.queue)
    
    for i = 1, batch_size do
        local dir_url = table.remove(job.queue, 1)
        if dir_url and not job.processed[dir_url] then
            table.insert(batch, dir_url)
            job.processed[dir_url] = true
        end
    end

    if #batch == 0 then
        M.process_warming_queue(warming_key)
        return
    end

    -- Process batch in parallel
    M.warm_directory_batch(batch, job, warming_key)
end

function M.warm_directory_batch(batch, job, warming_key)
    local completed_count = 0
    local total_batch = #batch

    for _, dir_url in ipairs(batch) do
        M.warm_single_directory(dir_url, job, function(discovered_dirs)
            completed_count = completed_count + 1
            
            -- Add discovered directories to queue if within depth limit
            if job.current_depth < job.max_depth then
                for _, new_dir in ipairs(discovered_dirs or {}) do
                    if not job.processed[new_dir] then
                        table.insert(job.queue, new_dir)
                    end
                end
            end

            -- Continue processing when batch is complete
            if completed_count >= total_batch then
                job.current_depth = job.current_depth + 1
                
                vim.schedule(function()
                    -- Update progress
                    cache_warming.stats.directories_warmed = cache_warming.stats.directories_warmed + total_batch
                    -- Only log progress every 10 directories to reduce verbosity
                    if cache_warming.stats.directories_warmed % 10 == 0 then
                        utils.log("Cache warming progress: " .. cache_warming.stats.directories_warmed .. 
                                 " directories, depth " .. job.current_depth .. "/" .. job.max_depth,
                                 vim.log.levels.DEBUG, false, config.config)
                    end
                    
                    -- Continue with next batch
                    M.process_warming_queue(warming_key)
                end)
            end
        end)
    end
end

function M.warm_single_directory(dir_url, job, callback)
    -- Check if already cached
    local cache_key = get_cache_key(dir_url, {type = "level_based"})
    local cached_items = cache_get("directory_listings", cache_key)
    
    if cached_items then
        -- Already cached, extract subdirectories and continue
        local subdirs = {}
        for _, item in ipairs(cached_items) do
            if item.is_dir and item.name ~= ".." then
                table.insert(subdirs, item.url)
            end
        end
        callback(subdirs)
        return
    end

    -- Parse URL for SSH command
    local remote_info = utils.parse_remote_path(dir_url)
    if not remote_info then
        callback({})
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path formatting
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- Use same command as level-based browser
    local bash_cmd = [[
    cd %s 2>/dev/null && \
    find . -maxdepth 1 -not -name "." | while read f; do \
      if [ -d "$f" ]; then echo "d $f"; else echo "f $f"; fi \
    done | sort
    ]]

    local cmd = {"ssh", host, string.format(bash_cmd, vim.fn.shellescape(path))}
    local output = {}

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            vim.schedule(function()
                local subdirs = {}
                
                if exit_code == 0 then
                    -- Parse and cache results
                    local items = M.parse_level_output(output, path, remote_info.protocol, host)
                    cache_set("directory_listings", cache_key, items)
                    
                    -- Count files for stats
                    local file_count = 0
                    for _, item in ipairs(items) do
                        if item.is_dir and item.name ~= ".." then
                            table.insert(subdirs, item.url)
                        elseif not item.is_dir then
                            file_count = file_count + 1
                        end
                    end
                    
                    cache_warming.stats.files_cached = cache_warming.stats.files_cached + file_count
                    cache_warming.stats.total_discovered = cache_warming.stats.total_discovered + #items
                end
                
                callback(subdirs)
            end)
        end
    })

    if job_id <= 0 then
        callback({})
    end
end

function M.finish_cache_warming(warming_key)
    local job = cache_warming.active_jobs[warming_key]
    if not job then return end

    local duration = os.time() - job.start_time
    local stats = cache_warming.stats
    
    utils.log("Cache warming completed for: " .. job.url .. 
             " (" .. stats.directories_warmed .. " dirs, " ..
             stats.files_cached .. " files, " ..
             stats.total_discovered .. " total items in " .. duration .. "s)",
             vim.log.levels.DEBUG, false, config.config)

    cache_warming.active_jobs[warming_key] = nil
end

function M.stop_cache_warming(url)
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then return false end
    
    local warming_key = remote_info.host .. ":" .. remote_info.path
    
    if cache_warming.active_jobs[warming_key] then
        cache_warming.active_jobs[warming_key] = nil
        utils.log("Stopped cache warming for: " .. url, vim.log.levels.DEBUG, false, config.config)
        return true
    end
    
    return false
end

function M.get_cache_warming_status()
    local active_count = 0
    local active_urls = {}
    
    for warming_key, job in pairs(cache_warming.active_jobs) do
        active_count = active_count + 1
        table.insert(active_urls, job.url)
    end
    
    return {
        active_jobs = active_count,
        active_urls = active_urls,
        stats = cache_warming.stats,
        config = cache_warming.config
    }
end

function M.invalidate_cache_for_path(url)
    -- Invalidate cache entries for the specific path and its parent directories
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then return end
    
    local host = remote_info.host
    local path = remote_info.path
    
    -- Create patterns to match cache entries for this host and path hierarchy
    local patterns = {
        host,  -- Match any cache entry for this host
        vim.fn.escape(path, ".*[]()^$-+?{}|\\"),  -- Exact path match
    }
    
    -- Also invalidate parent directories
    local parent_path = path
    while parent_path ~= "/" and parent_path ~= "" do
        parent_path = vim.fn.fnamemodify(parent_path, ":h")
        if parent_path and parent_path ~= "" and parent_path ~= "/" then
            table.insert(patterns, vim.fn.escape(parent_path, ".*[]()^$-+?{}|\\"))
        end
    end
    
    for _, pattern in ipairs(patterns) do
        cache_invalidate_pattern(pattern)
    end
    
    utils.log("Invalidated cache for path: " .. url, vim.log.levels.DEBUG, false, config.config)
end

-- Function to browse a remote directory and show results in Telescope
function M.browse_remote_directory(url, reset_selections)
    -- Reset selections only if explicitly requested
    -- For command invocations, we want to reset, but for directory navigation, preserve selections
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        utils.log("Reset file selections", vim.log.levels.DEBUG, false, config.config)
    end

    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)

    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path starts with a slash (absolute path)
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    -- Ensure path ends with a slash for consistency
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- Log the browsing operation
    utils.log("Browsing remote directory: " .. url, vim.log.levels.INFO, true, config.config)

    -- Auto-start cache warming if enabled and not already active
    if cache_warming.config.auto_warm then
        local warming_key = remote_info.host .. ":" .. remote_info.path
        if not cache_warming.active_jobs[warming_key] then
            utils.log("Auto-starting cache warming for: " .. url, vim.log.levels.DEBUG, false, config.config)
            M.start_cache_warming(url, { max_depth = cache_warming.config.max_depth })
        end
    end

    -- Check cache first
    local cache_key = get_cache_key(url)
    local cached_files = cache_get("directory_listings", cache_key)
    
    if cached_files then
        utils.log("Using cached directory listing (" .. #cached_files .. " items)", vim.log.levels.INFO, true, config.config)
        M.show_files_in_telescope(cached_files, url)
        return
    end

    -- Use a bash script that's compatible with most systems
    local bash_cmd = [[
    cd %s && \
    find . -maxdepth 1 | sort | while read f; do
      if [ "$f" != "." ]; then
        if [ -d "$f" ]; then echo "d ${f#./}"; else echo "f ${f#./}"; fi
      fi
    done
    ]]

    local cmd = {"ssh", host, string.format(bash_cmd, vim.fn.shellescape(path))}

    -- Create job to execute command
    local output = {}
    local stderr_output = {}

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Error listing directory: " .. table.concat(stderr_output, "\n"), vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            vim.schedule(function()
                -- Process output to get file list
                local files = M.parse_find_output(output, path, remote_info.protocol, host)

                -- Cache the results
                cache_set("directory_listings", cache_key, files)

                -- Check if directory is empty
                if #files == 0 then
                    utils.log("Directory is empty", vim.log.levels.INFO, true, config.config)
                    return
                end

                -- Show files in Telescope
                M.show_files_in_telescope(files, url)
            end)
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to browse all files recursively in a remote directory and show results in Telescope
function M.browse_remote_files(url, reset_selections)
    -- Reset selections only if explicitly requested
    -- For command invocations, we want to reset, but for directory navigation, preserve selections
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        utils.log("Reset file selections", vim.log.levels.DEBUG, false, config.config)
    end

    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)

    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path starts with a slash (absolute path)
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    -- Ensure path ends with a slash for consistency
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- Log the browsing operation
    utils.log("Browsing remote files recursively: " .. url, vim.log.levels.INFO, true, config.config)
    
    -- Check cache first
    local cache_key = get_cache_key(url, {type = "recursive", max_files = MAX_FILES})
    local cached_files = cache_get("file_listings", cache_key)
    
    if cached_files then
        utils.log("Using cached file listing (" .. #cached_files .. " items)", vim.log.levels.INFO, true, config.config)
        M.show_files_in_telescope_with_filename_filter(cached_files, url)
        return
    end
    
    utils.log("Searching for up to " .. MAX_FILES .. " files...", vim.log.levels.INFO, true, config.config)

    -- First, verify the directory exists and is accessible
    local check_dir_cmd = {"ssh", host, "ls -la " .. vim.fn.shellescape(path) .. " 2>&1"}

    -- Progress indicator timer
    local progress_count = 0
    local progress_chars = {"-", "\\", "|", "/"}
    local progress_timer = vim.loop.new_timer()
    local searching = false

    progress_timer:start(200, 200, vim.schedule_wrap(function()
        if searching then
            progress_count = (progress_count % 4) + 1
            utils.log("Searching files " .. progress_chars[progress_count], vim.log.levels.INFO, true, config.config)
        end
    end))

    -- Create job to execute directory check command
    local check_output = {}

    local check_job_id = vim.fn.jobstart(check_dir_cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(check_output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(check_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                progress_timer:close()
                vim.schedule(function()
                    utils.log("Error accessing directory: " .. table.concat(check_output, "\n"),
                              vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            -- Directory exists, proceed with file listing
            vim.schedule(function()
                utils.log("Directory exists, searching for files...", vim.log.levels.INFO, true, config.config)
                searching = true

                -- Use an optimized find command with proper sorting before limiting
                local bash_cmd = [[
                cd %s 2>/dev/null && \
                find . -type f -not -path "*/\\.git/*" -not -path "*/node_modules/*" \
                -not -path "*/build/*" -not -path "*/target/*" -not -path "*/dist/*" \
                -not -path "*/\\.*" -maxdepth 10 | sort | head -n %d
                ]]

                -- Log the command for debugging
                local formatted_cmd = string.format(bash_cmd, vim.fn.shellescape(path), MAX_FILES)
                utils.log("SSH command: " .. formatted_cmd, vim.log.levels.DEBUG, true, config.config)

                local cmd = {"ssh", host, formatted_cmd}

                -- Create job to execute command
                local output = {}
                local stderr_output = {}

                -- Set a timeout for long-running commands
                local timeout_timer = vim.loop.new_timer()
                local has_completed = false

                timeout_timer:start(30000, 0, vim.schedule_wrap(function()
                    if not has_completed then
                        searching = false
                        progress_timer:close()
                        utils.log("SSH command timed out after 30 seconds", vim.log.levels.ERROR, true, config.config)
                        pcall(vim.fn.jobstop, job_id)
                        timeout_timer:close()
                    end
                end))

                local job_id = vim.fn.jobstart(cmd, {
                    on_stdout = function(_, data)
                        if data and #data > 0 then
                            for _, line in ipairs(data) do
                                if line and line ~= "" then
                                    -- Store raw file paths
                                    table.insert(output, line)
                                end
                            end
                        end
                    end,
                    on_stderr = function(_, data)
                        if data and #data > 0 then
                            for _, line in ipairs(data) do
                                if line and line ~= "" then
                                    table.insert(stderr_output, line)
                                end
                            end
                        end
                    end,
                    on_exit = function(_, exit_code)
                        has_completed = true
                        searching = false
                        pcall(function() timeout_timer:close() end)
                        pcall(function() progress_timer:close() end)

                        if exit_code ~= 0 then
                            vim.schedule(function()
                                utils.log("Error listing files (exit code " .. exit_code .. "): " ..
                                          table.concat(stderr_output, "\n"),
                                          vim.log.levels.ERROR, true, config.config)
                            end)
                            return
                        end

                        vim.schedule(function()
                            utils.log("SSH command completed, processing results...",
                                      vim.log.levels.INFO, true, config.config)

                            -- Create file entries directly here
                            local files = {}
                            local seen_paths = {}

                            for _, file_path in ipairs(output) do
                                -- Limit total files processed
                                if #files >= MAX_FILES then
                                    break
                                end

                                -- Remove leading ./ if present
                                local rel_path = file_path:gsub("^%./", "")

                                -- Skip if we've already seen this path
                                if seen_paths[rel_path] then
                                    goto continue
                                end

                                -- Mark as seen
                                seen_paths[rel_path] = true

                                -- Get just the filename for search purposes
                                local filename = vim.fn.fnamemodify(rel_path, ":t")

                                -- Format the full path
                                local full_path = path .. rel_path

                                -- Format the URL - ensure we have only one slash after the host
                                local url_path = full_path
                                if url_path:sub(1, 1) ~= "/" then
                                    url_path = "/" .. url_path
                                end

                                -- Construct the proper URL
                                local file_url = remote_info.protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

                                table.insert(files, {
                                    name = filename,       -- Just the filename for filtering
                                    rel_path = rel_path,   -- Relative path for display
                                    path = full_path,      -- Full path
                                    url = file_url,        -- Complete URL
                                    is_dir = false,        -- Always false for files
                                    type = "f"             -- Always "f" for files
                                })

                                ::continue::
                            end

                            -- Check if directory is empty
                            if #files == 0 then
                                utils.log("No files found in " .. path, vim.log.levels.INFO, true, config.config)
                                return
                            end

                            local truncated = #output > MAX_FILES
                            utils.log("Found " .. #files .. " files" .. (truncated and " (results limited)" or ""),
                                      vim.log.levels.INFO, true, config.config)

                            -- Cache the results
                            cache_set("file_listings", cache_key, files)

                            -- Show files in Telescope with custom filename-only filtering
                            M.show_files_in_telescope_with_filename_filter(files, url)
                        end)
                    end
                })

                if job_id <= 0 then
                    searching = false
                    progress_timer:close()
                    utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
                    pcall(function() timeout_timer:close() end)
                else
                    utils.log("Started SSH job with ID: " .. job_id, vim.log.levels.DEBUG, true, config.config)
                end
            end)
        end
    })

    if check_job_id <= 0 then
        progress_timer:close()
        utils.log("Failed to start directory check job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to browse files with incremental loading
function M.browse_remote_files_incremental(url, reset_selections)
    -- Reset selections only if explicitly requested
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        incremental_state = {}
        utils.log("Reset file selections", vim.log.levels.DEBUG, false, config.config)
    end

    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path formatting
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- Initialize incremental state for this URL
    local state_key = url
    if not incremental_state[state_key] then
        incremental_state[state_key] = {
            files = {},
            directories = {},
            file_offset = 0,
            has_more_files = true,
            loading = false,
            total_loaded = 0,
            directories_loaded = false
        }
    end

    local state = incremental_state[state_key]
    
    -- If we're starting fresh, load directories first, then files
    if state.total_loaded == 0 then
        if not state.directories_loaded then
            M.load_all_directories(url, state, function()
                M.load_file_chunk(url, state, function()
                    M.show_files_in_telescope_incremental(state.files, url, state)
                end)
            end)
        else
            M.load_file_chunk(url, state, function()
                M.show_files_in_telescope_incremental(state.files, url, state)
            end)
        end
    else
        -- Show existing files
        M.show_files_in_telescope_incremental(state.files, url, state)
    end
end

-- Function to load ALL directories first (no pagination)
function M.load_all_directories(url, state, callback)
    if state.loading or state.directories_loaded then
        return
    end

    state.loading = true
    local remote_info = utils.parse_remote_path(url)
    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path formatting
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    utils.log("Loading ALL directories from " .. path, vim.log.levels.INFO, true, config.config)

    -- Find ALL directories (no limit)
    local bash_cmd = [[
    cd %s 2>/dev/null && \
    find . -type d -not -path "*/\\.git/*" -not -path "*/node_modules/*" \
    -not -path "*/build/*" -not -path "*/target/*" -not -path "*/dist/*" \
    -not -path "*/\\.*" -maxdepth 10 | grep -v '^\\.$' | sort
    ]]

    local formatted_cmd = string.format(bash_cmd, vim.fn.shellescape(path))
    local cmd = {"ssh", host, formatted_cmd}
    local output = {}
    local stderr_output = {}

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            state.loading = false
            
            if exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Error loading directories: " .. table.concat(stderr_output, "\n"),
                              vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            vim.schedule(function()
                local directories = {}
                local seen_paths = {}

                -- Process directory output
                for _, dir_path in ipairs(output) do
                    local rel_path = dir_path:gsub("^%./", "")
                    
                    if seen_paths[rel_path] then
                        goto continue
                    end
                    seen_paths[rel_path] = true

                    local dirname = vim.fn.fnamemodify(rel_path, ":t")
                    local full_path = path .. rel_path
                    local url_path = full_path
                    if url_path:sub(1, 1) ~= "/" then
                        url_path = "/" .. url_path
                    end

                    local dir_url = remote_info.protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

                    local dir_entry = {
                        name = dirname,
                        rel_path = rel_path,
                        path = full_path,
                        url = dir_url,
                        is_dir = true,
                        type = "d"
                    }

                    table.insert(directories, dir_entry)
                    table.insert(state.files, dir_entry)

                    ::continue::
                end

                -- Sort directories alphabetically
                table.sort(directories, function(a, b)
                    return a.name < b.name
                end)

                -- Add parent directory if we're not at root
                local parent_url = M.get_parent_directory(url)
                if parent_url then
                    local parent_entry = {
                        name = "..",
                        rel_path = "..",
                        path = M.get_path_from_url(parent_url),
                        url = parent_url,
                        is_dir = true,
                        type = "d"
                    }
                    -- Parent goes at the end (bottom)
                    table.insert(state.files, parent_entry)
                end

                state.directories = directories
                state.directories_loaded = true
                state.total_loaded = #state.files

                utils.log("Loaded " .. #directories .. " directories" .. (parent_url and " (+ parent)" or ""), 
                         vim.log.levels.INFO, true, config.config)

                if callback then
                    callback()
                end
            end)
        end
    })

    if job_id <= 0 then
        state.loading = false
        utils.log("Failed to start SSH job for directory loading", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to load a chunk of files (files only, directories already loaded)
function M.load_file_chunk(url, state, callback)
    if state.loading or not state.has_more_files then
        return
    end

    state.loading = true
    local remote_info = utils.parse_remote_path(url)
    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path formatting
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    utils.log("Loading file chunk starting at offset " .. state.file_offset, vim.log.levels.INFO, true, config.config)

    -- Find ONLY files (directories already loaded)
    local bash_cmd = [[
    cd %s 2>/dev/null && \
    find . -type f -not -path "*/\\.git/*" -not -path "*/node_modules/*" \
    -not -path "*/build/*" -not -path "*/target/*" -not -path "*/dist/*" \
    -not -path "*/\\.*" -maxdepth 10 | sort | \
    tail -n +%d | head -n %d
    ]]

    local formatted_cmd = string.format(bash_cmd, 
        vim.fn.shellescape(path), 
        state.file_offset + 1,  -- tail uses 1-based indexing
        CHUNK_SIZE
    )

    local cmd = {"ssh", host, formatted_cmd}
    local output = {}
    local stderr_output = {}

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            state.loading = false
            
            if exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Error loading file chunk: " .. table.concat(stderr_output, "\n"),
                              vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            vim.schedule(function()
                local chunk_files = {}
                local seen_paths = {}

                -- Process file output (files only, no directories)
                for _, file_path in ipairs(output) do
                    local rel_path = file_path:gsub("^%./", "")
                    
                    if seen_paths[rel_path] then
                        goto continue
                    end
                    seen_paths[rel_path] = true

                    local filename = vim.fn.fnamemodify(rel_path, ":t")
                    local full_path = path .. rel_path
                    local url_path = full_path
                    if url_path:sub(1, 1) ~= "/" then
                        url_path = "/" .. url_path
                    end

                    local file_url = remote_info.protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

                    local file_entry = {
                        name = filename,
                        rel_path = rel_path,
                        path = full_path,
                        url = file_url,
                        is_dir = false,  -- Only files in this function
                        type = "f"       -- Always files
                    }

                    table.insert(chunk_files, file_entry)

                    ::continue::
                end

                -- Sort files alphabetically (they're all files)
                table.sort(chunk_files, function(a, b)
                    return a.name < b.name
                end)

                -- Insert files in the right position: after existing files but before directories
                local insert_position = 1
                -- Find where files end and directories begin in the existing list
                for i, entry in ipairs(state.files) do
                    if entry.is_dir then
                        insert_position = i
                        break
                    else
                        insert_position = i + 1
                    end
                end

                -- Insert all chunk files at the calculated position
                for i, file_entry in ipairs(chunk_files) do
                    table.insert(state.files, insert_position + i - 1, file_entry)
                end

                -- Update state
                state.file_offset = state.file_offset + #output
                state.total_loaded = #state.files
                state.has_more_files = #output == CHUNK_SIZE

                utils.log("Loaded " .. #chunk_files .. " files (total: " .. state.total_loaded .. " items)", 
                         vim.log.levels.INFO, true, config.config)

                if callback then
                    callback()
                end
            end)
        end
    })

    if job_id <= 0 then
        state.loading = false
        utils.log("Failed to start SSH job for chunk loading", vim.log.levels.ERROR, true, config.config)
    end
end

-- Level-based browsing state
local level_browse_state = {
    expanded_dirs = {},  -- Track which directories are expanded
    file_offsets = {},   -- Track file pagination per directory
    dir_cache = {}       -- Cache directory contents
}

-- Function to browse with level-by-level discovery (hierarchical approach)
function M.browse_remote_level_based(url, reset_selections)
    -- Reset selections only if explicitly requested
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        utils.log("Reset file selections", vim.log.levels.DEBUG, false, config.config)
    end

    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path formatting
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    utils.log("Level-based browsing: " .. url, vim.log.levels.INFO, true, config.config)

    -- Auto-start cache warming if enabled and not already active
    if cache_warming.config.auto_warm then
        local remote_info = utils.parse_remote_path(url)
        if remote_info then
            local warming_key = remote_info.host .. ":" .. remote_info.path
            if not cache_warming.active_jobs[warming_key] then
                utils.log("Auto-starting cache warming for: " .. url, vim.log.levels.DEBUG, false, config.config)
                M.start_cache_warming(url, { max_depth = cache_warming.config.max_depth })
            end
        end
    end

    -- Check cache first
    local cache_key = get_cache_key(url, {type = "level_based"})
    local cached_items = cache_get("directory_listings", cache_key)
    
    if cached_items then
        utils.log("Using cached level listing (" .. #cached_items .. " items)", vim.log.levels.INFO, true, config.config)
        M.show_level_based_telescope(cached_items, url)
        return
    end

    -- Use maxdepth 1 to get ONLY immediate children
    local bash_cmd = [[
    cd %s 2>/dev/null && \
    find . -maxdepth 1 -not -name "." | while read f; do \
      if [ -d "$f" ]; then echo "d $f"; else echo "f $f"; fi \
    done | sort
    ]]

    local cmd = {"ssh", host, string.format(bash_cmd, vim.fn.shellescape(path))}
    local output = {}
    local stderr_output = {}

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Error listing directory: " .. table.concat(stderr_output, "\n"), 
                              vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            vim.schedule(function()
                local items = M.parse_level_output(output, path, remote_info.protocol, host)
                
                -- Cache the results
                cache_set("directory_listings", cache_key, items)

                if #items == 0 then
                    utils.log("Directory is empty", vim.log.levels.INFO, true, config.config)
                    return
                end

                M.show_level_based_telescope(items, url)
            end)
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to parse level-based output (immediate children only)
function M.parse_level_output(output, path, protocol, host)
    local items = {}
    
    for _, line in ipairs(output) do
        local file_type, name = line:match("^([fd])%s+(.+)$")
        
        if file_type and name then
            -- Remove leading ./ if present
            name = name:gsub("^%./", "")
            
            local is_dir = (file_type == "d")
            local full_path = path .. name
            local url_path = full_path
            if url_path:sub(1, 1) ~= "/" then
                url_path = "/" .. url_path
            end

            local item_url = protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

            table.insert(items, {
                name = name,
                path = full_path,
                url = item_url,
                is_dir = is_dir,
                type = file_type,
                level = 0,  -- All items at current level
                expanded = false  -- Directories start collapsed
            })
        end
    end

    -- Sort: files first, then directories, with special handling for parent
    table.sort(items, function(a, b)
        -- Parent directory (..) always comes last
        if a.name == ".." then
            return false
        elseif b.name == ".." then
            return true
        -- Files first, then directories
        elseif a.is_dir and not b.is_dir then
            return false
        elseif not a.is_dir and b.is_dir then
            return true
        else
            return a.name < b.name
        end
    end)

    -- Add parent directory entry
    local parent_url = M.get_parent_directory(protocol .. "://" .. host .. path)
    if parent_url then
        table.insert(items, {
            name = "..",
            path = M.get_path_from_url(parent_url),
            url = parent_url,
            is_dir = true,
            type = "d",
            level = 0,
            expanded = false
        })
    end

    return items
end

-- Function to reset state variables
function M.reset_state()
    selected_files = {}
    files_to_delete = {}
    files_to_create = {}
    file_status = {}
    incremental_state = {}
    utils.log("Reset file picker state", vim.log.levels.DEBUG, false, config.config)
end

function M.reset_incremental_state_for_url(url)
    incremental_state[url] = nil
    utils.log("Reset incremental state for: " .. url, vim.log.levels.DEBUG, false, config.config)
end

-- Tree state for expandable directory browser
local tree_state = {
    expanded_dirs = {},  -- Track which directories are expanded
    tree_items = {},     -- Flattened list of visible items with indentation
    base_url = nil       -- Current base URL
}

-- Function to browse remote directory with tree-based expansion
function M.browse_remote_directory_tree(url, reset_selections)
    -- Reset selections only if explicitly requested
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        tree_state.expanded_dirs = {}
        tree_state.tree_items = {}
        utils.log("Reset file selections and tree state", vim.log.levels.DEBUG, false, config.config)
    end

    tree_state.base_url = url
    
    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    -- Auto-start cache warming if enabled and not already active
    if cache_warming.config.auto_warm then
        local warming_key = remote_info.host .. ":" .. remote_info.path
        if not cache_warming.active_jobs[warming_key] then
            utils.log("Auto-starting cache warming for: " .. url, vim.log.levels.DEBUG, false, config.config)
            M.start_cache_warming(url, { max_depth = cache_warming.config.max_depth })
        end
    end

    -- Load the root directory
    M.build_tree_structure(url, 0, function()
        M.show_tree_in_telescope()
    end)
end

-- Function to load a directory and its contents for tree view
function M.load_directory_for_tree(url, depth, callback)
    local cache_key = "dir:" .. url
    
    -- First check cache warming data (prioritize warmed cache)
    local warming_cache_key = get_cache_key(url, {type = "level_based"})
    local warmed_data = cache_get("directory_listings", warming_cache_key)
    if warmed_data then
        cache.stats.hits = cache.stats.hits + 1
        utils.log("Cache hit from warming system for directory: " .. url, vim.log.levels.DEBUG, false, config.config)
        
        -- Also store in tree cache format for future tree-specific access
        cache.directory_listings[cache_key] = warmed_data
        
        -- Add items to tree
        M.add_directory_to_tree(warmed_data, url, depth)
        if callback then callback() end
        return
    end
    
    -- Fall back to tree-specific cache
    if cache.directory_listings[cache_key] then
        cache.stats.hits = cache.stats.hits + 1
        utils.log("Cache hit for directory: " .. url, vim.log.levels.DEBUG, false, config.config)
        
        -- Add items to tree
        M.add_directory_to_tree(cache.directory_listings[cache_key], url, depth)
        if callback then callback() end
        return
    end

    cache.stats.misses = cache.stats.misses + 1
    local remote_info = utils.parse_remote_path(url)
    
    local host = remote_info.host
    local path = remote_info.path or "/"
    
    -- Ensure path ends with /
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- Build the SSH command 
    local ssh_cmd = string.format(
        "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \"$f\" != \".\" ]; then if [ -d \"$f\" ]; then echo \"d ${f#./}\"; else echo \"f ${f#./}\"; fi; fi; done",
        vim.fn.shellescape(path)
    )

    local output = {}
    local job_id = vim.fn.jobstart({'ssh', host, ssh_cmd}, {
        on_stdout = function(_, data)
            for _, line in ipairs(data) do
                if line and line ~= "" then
                    table.insert(output, line)
                end
            end
        end,
        on_exit = function(_, code)
            if code == 0 then
                local files = M.parse_find_output(output, path, remote_info.protocol, host)
                
                -- Cache the result
                cache.directory_listings[cache_key] = files
                
                -- Add to tree
                M.add_directory_to_tree(files, url, depth)
                
                if callback then callback() end
            else
                utils.log("Failed to list directory: " .. url, vim.log.levels.ERROR, true, config.config)
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to add directory contents to tree structure (legacy - replaced by new tree building)
function M.add_directory_to_tree(files, parent_url, depth)
    -- This function is now handled by the new tree building system
    -- For compatibility, we'll use build_items_from_files but append to existing tree_state
    M.build_items_from_files(files, parent_url, depth, function(items)
        for _, item in ipairs(items) do
            table.insert(tree_state.tree_items, item)
        end
    end)
end

-- Function to rebuild tree items (used after expand/collapse)
function M.rebuild_tree_items()
    tree_state.tree_items = {}
    M.build_tree_structure(tree_state.base_url, 0, function()
        M.refresh_telescope_tree()
    end)
end

-- Function to build tree structure with correct ordering
function M.build_tree_structure(url, depth, callback)
    M.build_tree_node(url, depth, function(node_items)
        -- Replace the entire tree with the newly built structure
        tree_state.tree_items = node_items
        if callback then callback() end
    end)
end

-- Function to build a tree node and return flattened items in correct order
function M.build_tree_node(url, depth, callback)
    local cache_key = "dir:" .. url
    
    -- First check cache warming data (prioritize warmed cache)
    local warming_cache_key = get_cache_key(url, {type = "level_based"})
    local warmed_data = cache_get("directory_listings", warming_cache_key)
    if warmed_data then
        cache.stats.hits = cache.stats.hits + 1
        utils.log("Cache hit from warming system for directory: " .. url, vim.log.levels.DEBUG, false, config.config)
        
        -- Also store in tree cache format for future tree-specific access
        cache.directory_listings[cache_key] = warmed_data
        
        -- Build tree items from cached data
        M.build_items_from_files(warmed_data, url, depth, callback)
        return
    end
    
    -- Fall back to tree-specific cache
    if cache.directory_listings[cache_key] then
        cache.stats.hits = cache.stats.hits + 1
        utils.log("Cache hit for directory: " .. url, vim.log.levels.DEBUG, false, config.config)
        
        -- Build tree items from cached data
        M.build_items_from_files(cache.directory_listings[cache_key], url, depth, callback)
        return
    end

    -- Load directory if not cached
    M.load_directory_for_tree(url, depth, function()
        local files = cache.directory_listings[cache_key]
        if files then
            M.build_items_from_files(files, url, depth, callback)
        elseif callback then
            callback({})
        end
    end)
end

-- Function to build flattened tree items from files with proper ordering  
function M.build_items_from_files(files, parent_url, depth, callback)
    local result_items = {}
    
    -- Recursive helper to build tree items properly
    local function add_items_recursively(files_list, current_depth, parent_url_param)
        local indent = string.rep("  ", current_depth)
        
        for _, file in ipairs(files_list) do
            if file.name ~= ".." then -- Skip parent directory entries
                local is_expanded = tree_state.expanded_dirs[file.url] or false
                local tree_item = {
                    name = file.name,
                    url = file.url,
                    is_dir = file.is_dir,
                    depth = current_depth,
                    indent = indent,
                    parent_url = parent_url_param,
                    expanded = is_expanded
                }
                table.insert(result_items, tree_item)
                
                -- If this directory is expanded, add its children immediately after
                if file.is_dir and is_expanded then
                    local cache_key = "dir:" .. file.url
                    local child_files = nil
                    
                    -- Try cache warming first
                    local warming_cache_key = get_cache_key(file.url, {type = "level_based"})
                    local warmed_data = cache_get("directory_listings", warming_cache_key)
                    if warmed_data then
                        child_files = warmed_data
                        cache.directory_listings[cache_key] = warmed_data
                    elseif cache.directory_listings[cache_key] then
                        child_files = cache.directory_listings[cache_key]
                    end
                    
                    -- Recursively add children
                    if child_files then
                        add_items_recursively(child_files, current_depth + 1, file.url)
                    end
                end
            end
        end
    end
    
    -- Start the recursive build
    add_items_recursively(files, depth, parent_url)
    
    if callback then callback(result_items) end
end

-- Function to toggle directory expansion
function M.toggle_directory_expansion(dir_url)
    if tree_state.expanded_dirs[dir_url] then
        -- Collapse: remove this directory from expanded list
        tree_state.expanded_dirs[dir_url] = nil
        utils.log("Collapsed directory: " .. dir_url, vim.log.levels.DEBUG, false, config.config)
    else
        -- Expand: add to expanded list and load contents
        tree_state.expanded_dirs[dir_url] = true
        utils.log("Expanded directory: " .. dir_url, vim.log.levels.DEBUG, false, config.config)
    end
    
    -- Rebuild the tree
    M.rebuild_tree_items()
end

-- Function to toggle directory expansion while preserving cursor position
function M.toggle_directory_expansion_with_picker(dir_url, prompt_bufnr)
    local action_state = require('telescope.actions.state')
    local finders = require('telescope.finders')
    
    if tree_state.expanded_dirs[dir_url] then
        -- Collapse: remove this directory from expanded list
        tree_state.expanded_dirs[dir_url] = nil
        utils.log("Collapsed directory: " .. dir_url, vim.log.levels.DEBUG, false, config.config)
    else
        -- Expand: add to expanded list and load contents
        tree_state.expanded_dirs[dir_url] = true
        utils.log("Expanded directory: " .. dir_url, vim.log.levels.DEBUG, false, config.config)
    end
    
    -- Rebuild the tree and refresh current picker
    tree_state.tree_items = {}
    M.build_tree_structure(tree_state.base_url, 0, function()
        local current_picker = action_state.get_current_picker(prompt_bufnr)
        current_picker:refresh(finders.new_table({
            results = tree_state.tree_items,
            entry_maker = current_picker.finder.entry_maker
        }))
    end)
end

-- Function to parse find output into a list of files
function M.parse_find_output(output, path, protocol, host)
    local files = {}

    for _, line in ipairs(output) do
        -- Parse the line (type, name format)
        local file_type, name = line:match("^([df])%s+(.+)$")

        if file_type and name and name ~= "." and name ~= ".." then
            -- Check if it's a directory or file
            local is_dir = (file_type == "d")

            -- Format the full path
            local full_path = path .. name

            -- Format the URL - ensure we have only one slash after the host
            local url_path = full_path
            if url_path:sub(1, 1) ~= "/" then
                url_path = "/" .. url_path
            end

            -- Construct the proper URL with double slash after host to ensure path is treated as absolute
            local file_url = protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

            table.insert(files, {
                name = name,
                path = full_path,
                url = file_url,
                is_dir = is_dir,
                type = file_type
            })
        end
    end

    -- Sort files first, then directories, then parent directory (..) at the very bottom
    table.sort(files, function(a, b)
        -- Parent directory (..) always comes last
        if a.name == ".." then
            return false
        elseif b.name == ".." then
            return true
        -- Regular sorting: files first, then directories
        elseif a.is_dir and not b.is_dir then
            return false  -- directories go after files
        elseif not a.is_dir and b.is_dir then
            return true   -- files go before directories
        else
            return a.name < b.name
        end
    end)

    -- Add a special entry for the parent directory
    local parent_url = M.get_parent_directory(protocol .. "://" .. host .. path)
    if parent_url then
        table.insert(files, 1, {
            name = "..",
            path = M.get_path_from_url(parent_url),
            url = parent_url,
            is_dir = true,
            type = "d" -- It's a directory
        })
    end

    return files
end

-- Extract path from URL
function M.get_path_from_url(url)
    local remote_info = utils.parse_remote_path(url)
    if remote_info then
        return remote_info.path
    end
    return nil
end

-- Function to show files in Telescope with filename-only filtering
function M.show_files_in_telescope_with_filename_filter(files, base_url)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    utils.log("Setting up Telescope picker...", vim.log.levels.INFO, true, config.config)

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local sorters = require('telescope.sorters')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Use Telescope's built-in generic sorter but customize it for filename-only matching
    local filename_sorter = sorters.get_generic_fuzzy_sorter()

    -- Create a picker with standard sorting but customized display
    pickers.new({}, {
        prompt_title = "Remote Files: " .. base_url .. " (Tab:cycle status, d:delete, n:new, <C-o>:process, <C-x>:clear)",
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local icon, icon_hl
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                local prefix = ""
                
                if is_selected then
                    prefix = "+ " -- Plus sign for open
                elseif is_to_delete then
                    prefix = "- " -- Minus sign for deletion
                else
                    prefix = "  "
                end

                -- Always a file in this view
                if has_devicons then
                    local ext = entry.name:match("%.([^%.]+)$") or ""
                    local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                    if dev_icon then
                        icon = dev_icon .. " "

                        -- Try to use devicons highlight group if available
                        local filetype = vim.filetype.match({ filename = entry.name }) or ext
                        icon_hl = "DevIcon" .. filetype:upper()

                        -- Create highlight group if it doesn't exist
                        if dev_color and not vim.fn.hlexists(icon_hl) then
                            vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                else
                    icon = "📄 "
                    icon_hl = "Normal"
                end

                -- Display relative path but search by filename only
                return {
                    value = entry,
                    display = function()
                        local display_text = prefix .. icon .. entry.rel_path
                        local highlights = {
                            { { 0, #prefix }, is_selected and "diffAdded" or (is_to_delete and "diffRemoved" or "Comment") },
                            { { #prefix, #prefix + #icon }, icon_hl }
                        }
                        return display_text, highlights
                    end,
                    ordinal = entry.name, -- Use only filename for searching
                    path = entry.path
                }
            end
        }),
        sorter = filename_sorter,
        attach_mappings = function(prompt_bufnr, map)
            -- Toggle selection action
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if selection then
                    local file = selection.value
                    local url = file.url
                    
                    -- Get current status
                    local status = file_status[url] or "none"
                    
                    -- Cycle through statuses: none -> open -> delete -> none
                    if status == "none" then
                        -- Mark for opening
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        -- Mark for deletion
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        -- Clear status
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    
                    -- Update the visual selection in Telescope
                    if status == "none" or status == "open" then
                        -- For "none" -> "open" or "open" -> "delete", select the item
                        actions.toggle_selection(prompt_bufnr)
                    else
                        -- For "delete" -> "none", unselect the item
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end
            
            -- Add a function to mark a file for deletion
            local mark_for_deletion = function()
                local selection = action_state.get_selected_entry()
                if selection then
                    local file = selection.value
                    local url = file.url
                    
                    -- Toggle deletion status
                    if file_status[url] == "delete" then
                        -- Unmark for deletion
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Unmarked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual selection
                        actions.toggle_selection(prompt_bufnr)
                    else
                        -- Mark for deletion and unmark for opening
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual selection
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end
            
            -- Add a 'Reset all and refresh' function
            local reset_all_and_refresh = function()
                -- Store current URL
                local current_url = base_url
                
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Clear visual selections
                actions.clear_all(prompt_bufnr)
                
                -- Close current picker and reopen with reset selections
                actions.close(prompt_bufnr)
                M.browse_remote_files(current_url, true)
                
                utils.log("Reset all selections and refreshed view", vim.log.levels.INFO, true, config.config)
            end
            
            -- Add function to create a new file
            local create_new_file = function()
                -- Prompt for filename
                local current_dir = vim.fn.fnamemodify(base_url, ":h")
                if current_dir:sub(-1) ~= "/" then
                    current_dir = current_dir .. "/"
                end
                
                actions.close(prompt_bufnr)
                
                vim.ui.input({prompt = "Enter new filename: "}, function(filename)
                    if not filename or filename == "" then
                        utils.log("File creation cancelled", vim.log.levels.INFO, true, config.config)
                        -- Reopen the browser
                        M.browse_remote_files(base_url, false)
                        return
                    end
                    
                    -- Construct the full file path and URL
                    local remote_info = utils.parse_remote_path(base_url)
                    if not remote_info then
                        utils.log("Invalid remote URL: " .. base_url, vim.log.levels.ERROR, true, config.config)
                        return
                    end
                    
                    local host = remote_info.host
                    local path = remote_info.path
                    
                    -- Ensure path is a directory
                    if path:sub(-1) ~= "/" then
                        path = vim.fn.fnamemodify(path, ":h") .. "/"
                    end
                    
                    local file_path = path .. filename
                    local file_url = remote_info.protocol .. "://" .. host .. "/" .. file_path:gsub("^/", "")
                    
                    -- Add to files to create
                    local new_file = {
                        name = filename,
                        rel_path = filename,
                        path = file_path,
                        url = file_url,
                        is_dir = false,
                        type = "f"
                    }
                    
                    files_to_create[file_url] = new_file
                    file_status[file_url] = "create"
                    utils.log("Added file to create: " .. filename, vim.log.levels.INFO, true, config.config)
                    
                    -- Reopen the browser
                    M.browse_remote_files(base_url, false)
                end)
            end

            -- Modify default select action
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()

                if selection then
                    -- For files, toggle our persistent selection
                    toggle_selection()
                end
            end)

            -- Add mapping to toggle selection
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)
            
            -- Add mapping for deletion marking
            map("i", "d", mark_for_deletion)
            map("n", "d", mark_for_deletion)
            
            -- Add mapping for file creation
            map("i", "n", create_new_file)
            map("n", "n", create_new_file)
            
            -- Add mapping for reset and refresh (R key)
            map("i", "R", reset_all_and_refresh)
            map("n", "R", reset_all_and_refresh)

            -- Add custom key mapping to open all selected files, create new files and delete marked files
            map("i", "<C-o>", function()
                actions.close(prompt_bufnr)
                
                -- Process deletions first
                local delete_count = 0
                for url, file in pairs(files_to_delete) do
                    delete_count = delete_count + 1
                end
                
                if delete_count > 0 then
                    local confirm = vim.fn.confirm("Delete " .. delete_count .. " file(s)?", "&Yes\n&No", 2)
                    
                    if confirm == 1 then
                        -- User confirmed, so perform deletions
                        for url, file in pairs(files_to_delete) do
                            -- Parse the remote URL
                            local remote_info = utils.parse_remote_path(url)
                            if remote_info then
                                local host = remote_info.host
                                local path = remote_info.path
                                
                                -- Ensure path has leading slash
                                if path:sub(1, 1) ~= "/" then
                                    path = "/" .. path
                                end
                                
                                -- Run SSH command to delete the file
                                local cmd = {"ssh", host, "rm -f " .. vim.fn.shellescape(path)}
                                local job_id = vim.fn.jobstart(cmd, {
                                    on_exit = function(_, exit_code)
                                        if exit_code ~= 0 then
                                            utils.log("Failed to delete file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                        else
                                            utils.log("Deleted file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                            -- Invalidate cache for this file's directory
                                            M.invalidate_cache_for_path(url)
                                        end
                                    end
                                })
                                
                                if job_id <= 0 then
                                    utils.log("Failed to start deletion job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                end
                            end
                        end
                    else
                        utils.log("Deletion cancelled", vim.log.levels.INFO, true, config.config)
                    end
                end
                
                -- Process file creations
                local create_count = 0
                for url, file in pairs(files_to_create) do
                    create_count = create_count + 1
                end
                
                if create_count > 0 then
                    utils.log("Creating " .. create_count .. " new file(s)", vim.log.levels.INFO, true, config.config)
                    
                    for url, file in pairs(files_to_create) do
                        -- Create an empty file via SSH touch command
                        local remote_info = utils.parse_remote_path(url)
                        if remote_info then
                            local host = remote_info.host
                            local path = remote_info.path
                            
                            -- Ensure path has leading slash
                            if path:sub(1, 1) ~= "/" then
                                path = "/" .. path
                            end
                            
                            local cmd = {"ssh", host, "touch " .. vim.fn.shellescape(path)}
                            local job_id = vim.fn.jobstart(cmd, {
                                on_exit = function(_, exit_code)
                                    if exit_code ~= 0 then
                                        utils.log("Failed to create file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                    else
                                        utils.log("Created file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                        
                                        -- Invalidate cache for this file's directory
                                        M.invalidate_cache_for_path(url)
                                        
                                        -- Open the newly created file
                                        operations.simple_open_remote_file(url)
                                    end
                                end
                            })
                            
                            if job_id <= 0 then
                                utils.log("Failed to start creation job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                            end
                        end
                    end
                end

                -- Now proceed with opening selected files
                local open_count = 0
                for _, _ in pairs(selected_files) do
                    open_count = open_count + 1
                end

                if open_count == 0 then
                    -- If no files are explicitly selected but we have a current selection
                    local current = action_state.get_selected_entry()
                    if current then
                        utils.log("Opening file: " .. current.value.rel_path, vim.log.levels.INFO, true, config.config)
                        operations.simple_open_remote_file(current.value.url)
                    else
                        utils.log("No files selected to open", vim.log.levels.INFO, true, config.config)
                    end
                else
                    -- Open all selected files
                    utils.log("Opening " .. open_count .. " selected files", vim.log.levels.INFO, true, config.config)
                    for url, file in pairs(selected_files) do
                        operations.simple_open_remote_file(url)
                    end
                end
                
                -- Reset tracking tables
                files_to_delete = {}
                files_to_create = {}
            end)

            -- Add mapping to clear all selections and marks
            map("i", "<C-x>", function()
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Simply close and reopen the picker to reset the UI
                local current_url = base_url
                
                -- Close the current picker
                actions.close(prompt_bufnr)
                
                -- Reopening with true to indicate we want to start with fresh selections
                -- Our modified browse function will see this and respect the reset parameter
                M.browse_remote_files(current_url, true)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)
            
            -- Add the same mapping for normal mode
            map("n", "<C-x>", function()
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Simply close and reopen the picker to reset the UI
                local current_url = base_url
                
                -- Close the current picker
                actions.close(prompt_bufnr)
                
                -- Reopening with true to indicate we want to start with fresh selections
                -- Our modified browse function will see this and respect the reset parameter
                M.browse_remote_files(current_url, true)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)

            return true
        end,
        -- Enable multi-selection mode
        multi_selection = true,
    }):find()
end

-- Function to show files in Telescope with multi-select support and persistent selection
function M.show_files_in_telescope(files, base_url, custom_title)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Create a picker with multi-select enabled
    pickers.new({}, {
        prompt_title = custom_title or ("Remote Files: " .. base_url .. " (Tab:cycle status, d:delete, n:new, <C-o>:process, <C-x>:clear)"),
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local icon, icon_hl
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                local prefix = ""
                
                if is_selected then
                    prefix = "+ " -- Plus sign for open
                elseif is_to_delete then
                    prefix = "- " -- Minus sign for deletion
                else
                    prefix = "  "
                end

                if entry.name == ".." then
                    -- Parent directory
                    icon = "⬆️ "
                    icon_hl = "Special"
                elseif entry.is_dir then
                    -- Directory
                    icon = "📁 "
                    icon_hl = "Directory"
                else
                    -- File - try to use devicons if available
                    if has_devicons then
                        local ext = entry.name:match("%.([^%.]+)$") or ""
                        local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                        if dev_icon then
                            icon = dev_icon .. " "

                            -- Try to use devicons highlight group if available
                            local filetype = vim.filetype.match({ filename = entry.name }) or ext
                            icon_hl = "DevIcon" .. filetype:upper()

                            -- Create highlight group if it doesn't exist
                            if dev_color and not vim.fn.hlexists(icon_hl) then
                                vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                            end
                        else
                            icon = "📄 "
                            icon_hl = "Normal"
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                end

                -- Use Telescope's highlighting capabilities with selection indicator
                return {
                    value = entry,
                    display = function()
                        local display_text = prefix .. icon .. entry.name
                        local highlights = {
                            { { 0, #prefix }, is_selected and "diffAdded" or (is_to_delete and "diffRemoved" or "Comment") },
                            { { #prefix, #prefix + #icon }, icon_hl }
                        }
                        return display_text, highlights
                    end,
                    ordinal = entry.name,
                    path = entry.path
                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- Toggle selection action
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if selection and not selection.value.is_dir then
                    local file = selection.value
                    local url = file.url
                    
                    -- Get current status
                    local status = file_status[url] or "none"
                    
                    -- Cycle through statuses: none -> open -> delete -> none
                    if status == "none" then
                        -- Mark for opening
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        -- Mark for deletion
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        -- Clear status
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    
                    -- Update the visual selection in Telescope
                    if status == "none" or status == "open" then
                        -- For "none" -> "open" or "open" -> "delete", select the item
                        actions.toggle_selection(prompt_bufnr)
                    else
                        -- For "delete" -> "none", unselect the item
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end

            -- Modify default select action
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()

                if selection and selection.value.is_dir then
                    -- If it's a directory, browse into it while preserving selections
                    actions.close(prompt_bufnr)
                    M.browse_remote_directory(selection.value.url, false) -- false = don't reset selections
                else
                    -- For files, toggle our persistent selection
                    toggle_selection()
                end
            end)
            
            -- Add a function to mark a file for deletion
            local mark_for_deletion = function()
                local selection = action_state.get_selected_entry()
                if selection and not selection.value.is_dir then
                    local file = selection.value
                    local url = file.url
                    
                    -- Toggle deletion status
                    if file_status[url] == "delete" then
                        -- Unmark for deletion
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Unmarked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual display by toggling selection if needed
                        actions.toggle_selection(prompt_bufnr)
                    else
                        -- Mark for deletion and unmark for opening
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual display by toggling selection if needed
                        actions.toggle_selection(prompt_bufnr)
                    end
                elseif selection and selection.value.is_dir then
                    utils.log("Cannot mark directories for deletion", vim.log.levels.WARN, true, config.config)
                end
            end
            
            -- Add a 'Reset all and refresh' function
            local reset_all_and_refresh = function()
                -- Store current URL
                local current_url = base_url
                
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Clear visual selections
                actions.clear_all(prompt_bufnr)
                
                -- Close current picker and reopen with reset selections
                actions.close(prompt_bufnr)
                M.browse_remote_directory(current_url, true)
                
                utils.log("Reset all selections and refreshed view", vim.log.levels.INFO, true, config.config)
            end
            
            -- Add function to create a new file
            local create_new_file = function()
                -- Prompt for filename
                local current_dir = vim.fn.fnamemodify(base_url, ":h")
                if current_dir:sub(-1) ~= "/" then
                    current_dir = current_dir .. "/"
                end
                
                actions.close(prompt_bufnr)
                
                vim.ui.input({prompt = "Enter new filename: "}, function(filename)
                    if not filename or filename == "" then
                        utils.log("File creation cancelled", vim.log.levels.INFO, true, config.config)
                        -- Reopen the browser
                        M.browse_remote_directory(base_url, false)
                        return
                    end
                    
                    -- Construct the full file path and URL
                    local remote_info = utils.parse_remote_path(base_url)
                    if not remote_info then
                        utils.log("Invalid remote URL: " .. base_url, vim.log.levels.ERROR, true, config.config)
                        return
                    end
                    
                    local host = remote_info.host
                    local path = remote_info.path
                    
                    -- Ensure path is a directory
                    if path:sub(-1) ~= "/" then
                        path = vim.fn.fnamemodify(path, ":h") .. "/"
                    end
                    
                    local file_path = path .. filename
                    local file_url = remote_info.protocol .. "://" .. host .. "/" .. file_path:gsub("^/", "")
                    
                    -- Add to files to create
                    local new_file = {
                        name = filename,
                        path = file_path,
                        url = file_url,
                        is_dir = false,
                        type = "f"
                    }
                    
                    files_to_create[file_url] = new_file
                    file_status[file_url] = "create"
                    utils.log("Added file to create: " .. filename, vim.log.levels.INFO, true, config.config)
                    
                    -- Reopen the browser
                    M.browse_remote_directory(base_url, false)
                end)
            end
            
            -- Add mapping for deletion marking
            map("i", "d", mark_for_deletion)
            map("n", "d", mark_for_deletion)
            
            -- Add mapping for file creation
            map("i", "n", create_new_file)
            map("n", "n", create_new_file)
            
            -- Add mapping for reset and refresh (R key)
            map("i", "R", reset_all_and_refresh)
            map("n", "R", reset_all_and_refresh)

            -- Add mapping to toggle selection
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)

            -- Add custom key mapping to open all selected files, create new files, and delete marked files
            map("i", "<C-o>", function()
                actions.close(prompt_bufnr)
                
                -- Process deletions first
                local delete_count = 0
                for url, file in pairs(files_to_delete) do
                    delete_count = delete_count + 1
                end
                
                if delete_count > 0 then
                    local confirm = vim.fn.confirm("Delete " .. delete_count .. " file(s)?", "&Yes\n&No", 2)
                    
                    if confirm == 1 then
                        -- User confirmed, so perform deletions
                        for url, file in pairs(files_to_delete) do
                            -- Parse the remote URL
                            local remote_info = utils.parse_remote_path(url)
                            if remote_info then
                                local host = remote_info.host
                                local path = remote_info.path
                                
                                -- Ensure path has leading slash
                                if path:sub(1, 1) ~= "/" then
                                    path = "/" .. path
                                end
                                
                                -- Run SSH command to delete the file
                                local cmd = {"ssh", host, "rm -f " .. vim.fn.shellescape(path)}
                                local job_id = vim.fn.jobstart(cmd, {
                                    on_exit = function(_, exit_code)
                                        if exit_code ~= 0 then
                                            utils.log("Failed to delete file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                        else
                                            utils.log("Deleted file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                            -- Invalidate cache for this file's directory
                                            M.invalidate_cache_for_path(url)
                                        end
                                    end
                                })
                                
                                if job_id <= 0 then
                                    utils.log("Failed to start deletion job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                end
                            end
                        end
                    else
                        utils.log("Deletion cancelled", vim.log.levels.INFO, true, config.config)
                    end
                end
                
                -- Process file creations
                local create_count = 0
                for url, file in pairs(files_to_create) do
                    create_count = create_count + 1
                end
                
                if create_count > 0 then
                    utils.log("Creating " .. create_count .. " new file(s)", vim.log.levels.INFO, true, config.config)
                    
                    for url, file in pairs(files_to_create) do
                        -- Create an empty file via SSH touch command
                        local remote_info = utils.parse_remote_path(url)
                        if remote_info then
                            local host = remote_info.host
                            local path = remote_info.path
                            
                            -- Ensure path has leading slash
                            if path:sub(1, 1) ~= "/" then
                                path = "/" .. path
                            end
                            
                            local cmd = {"ssh", host, "touch " .. vim.fn.shellescape(path)}
                            local job_id = vim.fn.jobstart(cmd, {
                                on_exit = function(_, exit_code)
                                    if exit_code ~= 0 then
                                        utils.log("Failed to create file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                    else
                                        utils.log("Created file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                        
                                        -- Invalidate cache for this file's directory
                                        M.invalidate_cache_for_path(url)
                                        
                                        -- Open the newly created file
                                        operations.simple_open_remote_file(url)
                                    end
                                end
                            })
                            
                            if job_id <= 0 then
                                utils.log("Failed to start creation job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                            end
                        end
                    end
                end
                
                -- Now proceed with opening selected files
                local open_count = 0
                for _, _ in pairs(selected_files) do
                    open_count = open_count + 1
                end

                if open_count == 0 then
                    -- If no files are explicitly selected but we have a current selection
                    -- that's a file, use that one
                    local current = action_state.get_selected_entry()
                    if current and not current.value.is_dir then
                        utils.log("Opening file: " .. current.value.name, vim.log.levels.INFO, true, config.config)
                        operations.simple_open_remote_file(current.value.url)
                    else
                        utils.log("No files selected to open", vim.log.levels.INFO, true, config.config)
                    end
                else
                    -- Open all selected files
                    utils.log("Opening " .. open_count .. " selected files", vim.log.levels.INFO, true, config.config)
                    for url, file in pairs(selected_files) do
                        operations.simple_open_remote_file(url)
                    end
                end
                
                -- Reset tracking tables
                files_to_delete = {}
                files_to_create = {}
            end)

            -- Add mapping to clear all selections and marks
            map("i", "<C-x>", function()
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Simply close and reopen the picker to reset the UI
                local current_url = base_url
                
                -- Close the current picker
                actions.close(prompt_bufnr)
                
                -- Reopening with true to indicate we want to start with fresh selections
                -- Our modified browse function will see this and respect the reset parameter
                M.browse_remote_directory(current_url, true)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)
            
            -- Add the same mapping for normal mode
            map("n", "<C-x>", function()
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Simply close and reopen the picker to reset the UI
                local current_url = base_url
                
                -- Close the current picker
                actions.close(prompt_bufnr)
                
                -- Reopening with true to indicate we want to start with fresh selections
                -- Our modified browse function will see this and respect the reset parameter
                M.browse_remote_directory(current_url, true)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)

            return true
        end,
        -- Enable multi-selection mode
        multi_selection = true,
    }):find()
end

-- Function to show files in Telescope with incremental loading support
function M.show_files_in_telescope_incremental(files, base_url, state)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local sorters = require('telescope.sorters')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Create a dynamic title showing loading progress
    local title_suffix = ""
    if state.loading then
        title_suffix = " [Loading...]"
    elseif state.has_more_files then
        local file_count = state.total_loaded - #state.directories - (M.get_parent_directory(base_url) and 1 or 0)
        title_suffix = " [" .. #state.directories .. " dirs, " .. file_count .. " files, <C-l> for more]"
    else
        local file_count = state.total_loaded - #state.directories - (M.get_parent_directory(base_url) and 1 or 0)
        title_suffix = " [" .. #state.directories .. " dirs, " .. file_count .. " files, all loaded]"
    end

    local filename_sorter = sorters.get_generic_fuzzy_sorter()

    -- Create a picker with incremental loading support
    pickers.new({}, {
        prompt_title = "Remote Files: " .. base_url .. title_suffix .. " (Tab:cycle status, d:delete, n:new, <C-o>:process, <C-x>:clear)",
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local icon, icon_hl
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                local prefix = ""
                
                if is_selected then
                    prefix = "+ "
                elseif is_to_delete then
                    prefix = "- "
                else
                    prefix = "  "
                end

                -- Get file/directory icon
                if entry.is_dir then
                    icon = "📁 "
                    icon_hl = "Directory"
                elseif has_devicons then
                    local ext = entry.name:match("%.([^%.]+)$") or ""
                    local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                    if dev_icon then
                        icon = dev_icon .. " "
                        local filetype = vim.filetype.match({ filename = entry.name }) or ext
                        icon_hl = "DevIcon" .. filetype:upper()

                        if dev_color and not vim.fn.hlexists(icon_hl) then
                            vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                else
                    icon = "📄 "
                    icon_hl = "Normal"
                end

                return {
                    value = entry,
                    display = function()
                        local display_text = prefix .. icon .. entry.rel_path
                        local highlights = {
                            { { 0, #prefix }, is_selected and "diffAdded" or (is_to_delete and "diffRemoved" or "Comment") },
                            { { #prefix, #prefix + #icon }, icon_hl }
                        }
                        return display_text, highlights
                    end,
                    ordinal = entry.name, -- Use only filename for searching
                    path = entry.path
                }
            end
        }),
        sorter = filename_sorter,
        attach_mappings = function(prompt_bufnr, map)
            -- Toggle selection action
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if selection and not selection.value.is_dir then
                    local file = selection.value
                    local url = file.url
                    
                    local status = file_status[url] or "none"
                    
                    if status == "none" then
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    
                    if status == "none" or status == "open" then
                        actions.toggle_selection(prompt_bufnr)
                    else
                        actions.toggle_selection(prompt_bufnr)
                    end
                elseif selection and selection.value.is_dir then
                    utils.log("Cannot select directories (press Enter to navigate)", vim.log.levels.INFO, true, config.config)
                end
            end

            -- Load more files function
            local load_more = function()
                utils.log("Load more requested. State: has_more_files=" .. tostring(state.has_more_files) .. 
                         ", loading=" .. tostring(state.loading) .. 
                         ", total_loaded=" .. state.total_loaded .. 
                         ", file_offset=" .. state.file_offset, vim.log.levels.DEBUG, false, config.config)
                         
                if state.has_more_files and not state.loading then
                    utils.log("Loading next file chunk...", vim.log.levels.INFO, true, config.config)
                    actions.close(prompt_bufnr)
                    M.load_file_chunk(base_url, state, function()
                        M.show_files_in_telescope_incremental(state.files, base_url, state)
                    end)
                else
                    if state.loading then
                        utils.log("Already loading more files...", vim.log.levels.INFO, true, config.config)
                    else
                        utils.log("All files have been loaded (total: " .. state.total_loaded .. " items)", vim.log.levels.INFO, true, config.config)
                    end
                end
            end

            -- Default select action
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                if selection and selection.value.is_dir then
                    -- If it's a directory, browse into it (reset incremental state for new directory)
                    actions.close(prompt_bufnr)
                    M.reset_incremental_state_for_url(selection.value.url)
                    M.browse_remote_files_incremental(selection.value.url, false) -- false = don't reset selections
                else
                    -- For files, toggle selection
                    toggle_selection()
                end
            end)

            -- Add all the same mappings as the original function
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)
            
            -- Add mapping to load more files
            map("i", "<C-l>", load_more)  
            map("n", "<C-l>", load_more)

            -- Add other mappings (same as original)
            map("i", "d", function()
                local selection = action_state.get_selected_entry()
                if selection then
                    local file = selection.value
                    local url = file.url
                    
                    if file_status[url] == "delete" then
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Unmarked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        actions.toggle_selection(prompt_bufnr)
                    else
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end)
            
            map("n", "d", function()
                local selection = action_state.get_selected_entry()
                if selection then
                    local file = selection.value
                    local url = file.url
                    
                    if file_status[url] == "delete" then
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Unmarked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        actions.toggle_selection(prompt_bufnr)
                    else
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end)

            -- Process files action (same as original)
            map("i", "<C-o>", function()
                actions.close(prompt_bufnr)
                
                -- Process deletions, creations, and openings (same logic as original)
                local delete_count = 0
                for url, file in pairs(files_to_delete) do
                    delete_count = delete_count + 1
                end
                
                if delete_count > 0 then
                    local confirm = vim.fn.confirm("Delete " .. delete_count .. " file(s)?", "&Yes\n&No", 2)
                    
                    if confirm == 1 then
                        for url, file in pairs(files_to_delete) do
                            local remote_info = utils.parse_remote_path(url)
                            if remote_info then
                                local host = remote_info.host
                                local path = remote_info.path
                                
                                if path:sub(1, 1) ~= "/" then
                                    path = "/" .. path
                                end
                                
                                local cmd = {"ssh", host, "rm -f " .. vim.fn.shellescape(path)}
                                local job_id = vim.fn.jobstart(cmd, {
                                    on_exit = function(_, exit_code)
                                        if exit_code ~= 0 then
                                            utils.log("Failed to delete file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                        else
                                            utils.log("Deleted file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                            -- Invalidate cache for this file's directory
                                            M.invalidate_cache_for_path(url)
                                        end
                                    end
                                })
                                
                                if job_id <= 0 then
                                    utils.log("Failed to start deletion job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                end
                            end
                        end
                    else
                        utils.log("Deletion cancelled", vim.log.levels.INFO, true, config.config)
                    end
                end
                
                -- Open selected files
                local open_count = 0
                for _, _ in pairs(selected_files) do
                    open_count = open_count + 1
                end

                if open_count == 0 then
                    local current = action_state.get_selected_entry()
                    if current then
                        utils.log("Opening file: " .. current.value.rel_path, vim.log.levels.INFO, true, config.config)
                        operations.simple_open_remote_file(current.value.url)
                    else
                        utils.log("No files selected to open", vim.log.levels.INFO, true, config.config)
                    end
                else
                    utils.log("Opening " .. open_count .. " selected files", vim.log.levels.INFO, true, config.config)
                    for url, file in pairs(selected_files) do
                        operations.simple_open_remote_file(url)
                    end
                end
                
                files_to_delete = {}
                files_to_create = {}
            end)

            -- Clear selections
            map("i", "<C-x>", function()
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                actions.close(prompt_bufnr)
                M.show_files_in_telescope_incremental(state.files, base_url, state)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)
            
            map("n", "<C-x>", function()
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                actions.close(prompt_bufnr)
                M.show_files_in_telescope_incremental(state.files, base_url, state)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)

            return true
        end,
        multi_selection = true,
    }):find()
end

-- Function to get the parent directory of a URL
function M.get_parent_directory(url)
    local remote_info = utils.parse_remote_path(url)

    if not remote_info then
        return nil
    end

    local host = remote_info.host
    local path = remote_info.path
    local protocol = remote_info.protocol

    -- Remove trailing slash if present
    if path:sub(-1) == "/" then
        path = path:sub(1, -2)
    end

    -- Get parent path
    local parent_path = path:match("^(.+)/[^/]+$")

    if not parent_path then
        -- We're at the root or a direct child of root
        if path:match("^/[^/]*$") then
            -- At root or direct child of root, return root
            parent_path = "/"
        else
            return nil
        end
    end

    -- Ensure parent_path ends with a slash for consistency
    if parent_path:sub(-1) ~= "/" then
        parent_path = parent_path .. "/"
    end

    -- Construct URL with proper format to avoid hostname concatenation issues
    -- Make sure we properly format with double-slash after host for absolute paths
    return protocol .. "://" .. host .. "/" .. parent_path:gsub("^/", "")
end

-- Function to grep in a remote directory and show results in Telescope
-- This function searches for a pattern in remote files and shows results in Telescope
-- When a result is selected, it opens the file and jumps to the matching line
function M.grep_remote_directory(url)
    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)

    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path starts with a slash (absolute path)
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    -- Ensure path ends with a slash for consistency
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- First, prompt for the search pattern
    vim.ui.input({ prompt = "Search pattern: " }, function(pattern)
        if not pattern or pattern == "" then
            utils.log("Search cancelled", vim.log.levels.INFO, true, config.config)
            return
        end

        utils.log("Searching for: " .. pattern, vim.log.levels.INFO, true, config.config)

        -- Using grep -n to get line numbers and context for matched lines
        local grep_cmd = string.format(
            "cd %s && find . -type f | xargs grep -n -i %s",
            vim.fn.shellescape(path),
            vim.fn.shellescape(pattern)
        )

        -- Create the complete SSH command
        local cmd = {"ssh", host, grep_cmd}

        utils.log("Running command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG, false, config.config)

        -- Show a notification that we're searching
        vim.notify("Searching remote files for '" .. pattern .. "'...", vim.log.levels.INFO)

        -- Create job to execute search command
        local output = {}
        local stderr_output = {}

        local job_id = vim.fn.jobstart(cmd, {
            on_stdout = function(_, data)
                if data and #data > 0 then
                    for _, line in ipairs(data) do
                        if line and line ~= "" then
                            table.insert(output, line)
                        end
                    end
                end
            end,
            on_stderr = function(_, data)
                if data and #data > 0 then
                    for _, line in ipairs(data) do
                        if line and line ~= "" then
                            table.insert(stderr_output, line)
                        end
                    end
                end
            end,
            on_exit = function(_, exit_code)
                vim.schedule(function()
                    -- Process the results
                    if #output == 0 then
                        vim.notify("No matches found for '" .. pattern .. "'", vim.log.levels.INFO)
                        return
                    end

                    utils.log("Found " .. #output .. " matches", vim.log.levels.INFO, true, config.config)

                    -- Process the matches
                    local matches = {}
                    
                    for _, line in ipairs(output) do
                        -- Parse the output format: ./path/to/file.ext:line_number:matched_content
                        local rel_path, line_num, content = line:match("^%.[\\/]?([^:]+):(%d+):(.*)$")
                        
                        if rel_path and line_num and content then
                            -- Get full information for the match
                            local full_path = path .. rel_path
                            local filename = vim.fn.fnamemodify(rel_path, ":t")
                            local file_url = remote_info.protocol .. "://" .. host .. "/" .. full_path:gsub("^/", "")
                            
                            table.insert(matches, {
                                name = filename,
                                rel_path = rel_path,
                                path = full_path,
                                url = file_url,
                                line_num = tonumber(line_num),
                                content = content
                            })
                        end
                    end

                    -- Show matches in Telescope
                    M.show_grep_results_in_telescope(matches, pattern, url)
                end)
            end
        })

        if job_id <= 0 then
            utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
        end
    end)
end



-- Display grep results in Telescope
-- When a match is selected, opens the file and positions the cursor at the matching line
function M.show_grep_results_in_telescope(matches, pattern, base_url)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Create a finder from the matches
    pickers.new({}, {
        prompt_title = "Results for '" .. pattern .. "'",
        finder = finders.new_table({
            results = matches,
            entry_maker = function(entry)
                local icon, icon_hl
                
                -- Get icon if available
                if has_devicons then
                    local ext = entry.name:match("%.([^%.]+)$") or ""
                    local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                    if dev_icon then
                        icon = dev_icon .. " "

                        -- Try to use devicons highlight group if available
                        local filetype = vim.filetype.match({ filename = entry.name }) or ext
                        icon_hl = "DevIcon" .. filetype:upper()

                        -- Create highlight group if it doesn't exist
                        if dev_color and not vim.fn.hlexists(icon_hl) then
                            vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                else
                    icon = "📄 "
                    icon_hl = "Normal"
                end

                -- Format display string to show file path, line number, and matched content
                local display_text = entry.rel_path .. ":" .. entry.line_num .. ": " .. entry.content

                return {
                    value = entry,
                    display = function()
                        local highlights = {
                            { { 0, #icon }, icon_hl }
                        }
                        return icon .. display_text, highlights
                    end,
                    ordinal = display_text,
                    path = entry.path,
                    url = entry.url,
                    line_num = entry.line_num
                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- On selection, open the file at the specific line
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                
                if selection and selection.url then
                    actions.close(prompt_bufnr)
                    local line_num = selection.line_num or 1
                    
                    -- Open the file and pass position information
                    operations.simple_open_remote_file(selection.url, {line = line_num - 1, character = 0})
                end
            end)
            
            return true
        end,
    }):find()
end

-- Function to show level-based browse results in Telescope
function M.show_level_based_telescope(items, base_url)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Count files and directories for title
    local file_count = 0
    local dir_count = 0
    for _, item in ipairs(items) do
        if item.name ~= ".." then
            if item.is_dir then
                dir_count = dir_count + 1
            else
                file_count = file_count + 1
            end
        end
    end

    local title = "Level Browse: " .. base_url .. " [" .. file_count .. " files, " .. dir_count .. " dirs] (Enter:navigate, Tab:select, <C-r>:recursive search)"

    pickers.new({}, {
        prompt_title = title,
        finder = finders.new_table({
            results = items,
            entry_maker = function(entry)
                local icon, icon_hl
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                local prefix = ""
                
                if is_selected then
                    prefix = "+ "
                elseif is_to_delete then
                    prefix = "- "
                else
                    prefix = "  "
                end

                -- Get appropriate icon
                if entry.name == ".." then
                    icon = "⬆️ "
                    icon_hl = "Special"
                elseif entry.is_dir then
                    icon = "📁 "
                    icon_hl = "Directory"
                elseif has_devicons then
                    local ext = entry.name:match("%.([^%.]+)$") or ""
                    local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                    if dev_icon then
                        icon = dev_icon .. " "
                        local filetype = vim.filetype.match({ filename = entry.name }) or ext
                        icon_hl = "DevIcon" .. filetype:upper()

                        if dev_color and not vim.fn.hlexists(icon_hl) then
                            vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                else
                    icon = "📄 "
                    icon_hl = "Normal"
                end

                return {
                    value = entry,
                    display = function()
                        local display_text = prefix .. icon .. entry.name
                        local highlights = {
                            { { 0, #prefix }, is_selected and "diffAdded" or (is_to_delete and "diffRemoved" or "Comment") },
                            { { #prefix, #prefix + #icon }, icon_hl }
                        }
                        return display_text, highlights
                    end,
                    ordinal = entry.name,
                    path = entry.path
                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- Default action: navigate directories, select files
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                if selection and selection.value.is_dir then
                    -- Navigate to directory
                    actions.close(prompt_bufnr)
                    M.browse_remote_level_based(selection.value.url, false)
                else
                    -- Toggle file selection
                    local file = selection.value
                    local url = file.url
                    
                    local status = file_status[url] or "none"
                    if status == "none" then
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    actions.toggle_selection(prompt_bufnr)
                end
            end)

            -- Tab to cycle file selection states (directories cannot be selected)
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if selection and not selection.value.is_dir then
                    local file = selection.value
                    local url = file.url
                    
                    local status = file_status[url] or "none"
                    if status == "none" then
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    actions.toggle_selection(prompt_bufnr)
                elseif selection and selection.value.is_dir then
                    utils.log("Cannot select directories (press Enter to navigate)", vim.log.levels.INFO, true, config.config)
                end
            end

            -- Recursive search in current directory
            local recursive_search = function()
                actions.close(prompt_bufnr)
                M.browse_remote_files_incremental(base_url, false)
            end

            -- Process selected files and deletions
            local process_files = function()
                actions.close(prompt_bufnr)
                
                -- Count operations
                local delete_count = 0
                for _, _ in pairs(files_to_delete) do
                    delete_count = delete_count + 1
                end
                
                local open_count = 0
                for _, _ in pairs(selected_files) do
                    open_count = open_count + 1
                end

                -- Handle deletions
                if delete_count > 0 then
                    local confirm = vim.fn.confirm("Delete " .. delete_count .. " file(s)?", "&Yes\n&No", 2)
                    if confirm == 1 then
                        for url, file in pairs(files_to_delete) do
                            local remote_info = utils.parse_remote_path(url)
                            if remote_info then
                                local host = remote_info.host
                                local path = remote_info.path
                                
                                if path:sub(1, 1) ~= "/" then
                                    path = "/" .. path
                                end
                                
                                local cmd = {"ssh", host, "rm -f " .. vim.fn.shellescape(path)}
                                local job_id = vim.fn.jobstart(cmd, {
                                    on_exit = function(_, exit_code)
                                        if exit_code ~= 0 then
                                            utils.log("Failed to delete file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                        else
                                            utils.log("Deleted file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                            M.invalidate_cache_for_path(url)
                                        end
                                    end
                                })
                                
                                if job_id <= 0 then
                                    utils.log("Failed to start deletion job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                end
                            end
                        end
                    end
                end

                -- Handle file opening
                if open_count > 0 then
                    utils.log("Opening " .. open_count .. " selected files", vim.log.levels.INFO, true, config.config)
                    for url, _ in pairs(selected_files) do
                        operations.simple_open_remote_file(url)
                    end
                end

                -- Reset selections
                files_to_delete = {}
                selected_files = {}
            end

            -- Add mappings
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)
            map("i", "<C-r>", recursive_search)
            map("n", "<C-r>", recursive_search)
            map("i", "<C-o>", process_files)
            map("n", "<C-o>", process_files)

            return true
        end,
        multi_selection = true,
    }):find()
end

-- Function to show tree structure in telescope
function M.show_tree_in_telescope()
    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Create telescope picker
    local picker = pickers.new({}, {
        prompt_title = "Remote Tree: " .. tree_state.base_url .. " (Enter:expand/collapse, Tab:select, <C-o>:process)",
        finder = finders.new_table({
            results = tree_state.tree_items,
            entry_maker = function(entry)
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                
                local prefix = ""
                if is_selected then
                    prefix = "+ "
                elseif is_to_delete then
                    prefix = "- "
                else
                    prefix = "  "
                end

                -- Get appropriate icon for tree
                local icon = ""
                local icon_hl = ""
                
                if entry.is_dir then
                    -- Use different icons for expanded/collapsed directories
                    if entry.expanded then
                        icon = "📂 "  -- Open folder
                    else
                        icon = "📁 "  -- Closed folder
                    end
                    icon_hl = "Directory"
                elseif has_devicons then
                    local ext = entry.name:match("%.([^%.]+)$") or ""
                    local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })
                    if dev_icon then
                        icon = dev_icon .. " "
                        icon_hl = dev_color and dev_color or "Normal"
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                else
                    icon = "📄 "
                    icon_hl = "Normal"
                end

                local display = entry.indent .. prefix .. icon .. entry.name
                
                return {
                    value = entry,
                    display = display,
                    ordinal = entry.name,
                    hl = { {icon_hl, #entry.indent + #prefix, #entry.indent + #prefix + #icon} }
                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- Toggle file selection
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if not selection or not selection.value then return end
                
                local entry = selection.value
                if not entry.is_dir then
                    if selected_files[entry.url] then
                        selected_files[entry.url] = nil
                        file_status[entry.url] = nil
                    else
                        selected_files[entry.url] = {
                            path = entry.url,
                            name = entry.name
                        }
                        file_status[entry.url] = "selected"
                    end
                    
                    -- Refresh the current picker without losing cursor position
                    local current_picker = action_state.get_current_picker(prompt_bufnr)
                    current_picker:refresh(finders.new_table({
                        results = tree_state.tree_items,
                        entry_maker = current_picker.finder.entry_maker
                    }))
                end
            end

            -- Process selected files
            local process_files = function()
                if next(selected_files) == nil and next(files_to_delete) == nil and next(files_to_create) == nil then
                    utils.log("No files selected for processing", vim.log.levels.WARN, true, config.config)
                    return
                end

                actions.close(prompt_bufnr)
                
                -- Process files similar to regular browser
                local total_operations = 0
                
                for _, file in pairs(selected_files) do
                    total_operations = total_operations + 1
                    utils.log("Opening file: " .. file.path, vim.log.levels.INFO, true, config.config)
                    vim.cmd("edit " .. file.path)
                end
                
                utils.log("Processed " .. total_operations .. " operations", vim.log.levels.INFO, true, config.config)
                
                -- Reset selections
                files_to_delete = {}
                selected_files = {}
                file_status = {}
            end

            -- Replace default action to expand/collapse directories
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                if not selection or not selection.value then return end
                
                local entry = selection.value
                if entry.is_dir then
                    -- Toggle directory expansion
                    M.toggle_directory_expansion_with_picker(entry.url, prompt_bufnr)
                else
                    -- For files, toggle selection
                    toggle_selection()
                end
            end)

            -- Add mappings
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)
            map("i", "<C-o>", process_files)
            map("n", "<C-o>", process_files)

            return true
        end,
        multi_selection = true,
    })
    
    picker:find()
end

-- Function to refresh the telescope tree picker
function M.refresh_telescope_tree()
    -- This creates a new picker - should only be used when no current picker exists
    -- For in-picker refreshes, use the picker.refresh() method instead
    vim.schedule(function()
        M.show_tree_in_telescope()
    end)
end

return M