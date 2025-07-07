-- Buffer-based tree browser for remote files
-- Provides a dedicated buffer with expandable file tree, caching, and background warming

local utils = require('async-remote-write.utils')
local config = require('async-remote-write.config')

local M = {}

-- Icon system with nvim-web-devicons integration
local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

-- Primary icons (preferred Unicode icons)
local primary_icons = {
    folder_closed = " ",  -- Unicode closed folder icon
    folder_open = " ",    -- Unicode open folder icon
}

-- Default fallback icons when Unicode doesn't work properly
local fallback_icons = {
    folder_closed = "[+]",  -- ASCII fallback
    folder_open = "[-]",    -- ASCII fallback
    file_default = " • "    -- Simple ASCII fallback
}

-- Icon cache for performance
local icon_cache = {}

-- Cache and warming configuration constants (must be defined before functions that use them)
local CACHE_TTL = 300  -- 5 minutes
local WARMING_MAX_DEPTH = 5
local MAX_CACHE_ENTRIES = 500  -- Maximum directory cache entries
local MAX_ICON_CACHE_ENTRIES = 500  -- Maximum icon cache entries

-- Evict old icon cache entries when over limit (forward declaration)
local function evict_old_icon_cache_entries()
    local cache_size = vim.tbl_count(icon_cache)
    if cache_size <= MAX_ICON_CACHE_ENTRIES then
        return 0
    end

    -- For icon cache, we'll just clear half of it since we don't track timestamps
    local keys = vim.tbl_keys(icon_cache)
    local to_remove = math.floor(cache_size / 2)
    local removed_count = 0

    for i = 1, to_remove do
        if keys[i] then
            icon_cache[keys[i]] = nil
            removed_count = removed_count + 1
        end
    end

    if removed_count > 0 then
        utils.log("Evicted " .. removed_count .. " icon cache entries (cache size limit: " .. MAX_ICON_CACHE_ENTRIES .. ")", vim.log.levels.DEBUG, false, config.config)
    end

    return removed_count
end

-- Get file icon and highlight group
local function get_file_icon(filename, is_dir, is_expanded)
    -- Cache key
    local cache_key = filename .. (is_dir and "_dir" or "_file") .. (is_expanded and "_exp" or "_col")

    if icon_cache[cache_key] then
        return icon_cache[cache_key].icon, icon_cache[cache_key].hl_group
    end

    local icon, hl_group

    -- Debug logging
    utils.log("Getting icon for: " .. filename .. " (dir: " .. tostring(is_dir) .. ", expanded: " .. tostring(is_expanded) .. ")", vim.log.levels.DEBUG, false, config.config)

    if is_dir then
        -- Directory icons - try primary Unicode icons first, fallback to ASCII
        icon = is_expanded and primary_icons.folder_open or primary_icons.folder_closed

        if has_devicons then
            hl_group = is_expanded and "NvimTreeFolderOpen" or "NvimTreeFolderClosed"
        else
            hl_group = "Directory"
        end

        utils.log("Directory icon: '" .. icon .. "' with highlight: " .. hl_group, vim.log.levels.DEBUG, false, config.config)
    else
        -- File icons
        if has_devicons then
            local extension = filename:match("%.([^%.]+)$") or ""
            local file_icon, color = devicons.get_icon_color(filename, extension, { default = true })
            icon = file_icon or fallback_icons.file_default

            -- Create a unique highlight group for this file type
            if color then
                hl_group = "DevIcon" .. (extension:gsub("[^%w]", "") or "Default")
                -- Set up the highlight group with the color
                vim.api.nvim_set_hl(0, hl_group, { fg = color })
            else
                hl_group = "NvimTreeNormal"
            end

            utils.log("File icon from devicons: '" .. (file_icon or "nil") .. "' -> '" .. icon .. "'", vim.log.levels.DEBUG, false, config.config)
        else
            -- Fallback file icon
            icon = fallback_icons.file_default
            hl_group = "Normal"

            utils.log("File fallback icon: '" .. icon .. "'", vim.log.levels.DEBUG, false, config.config)
        end
    end

    -- Cache the result with size management
    evict_old_icon_cache_entries()  -- Check size limits before adding
    icon_cache[cache_key] = { icon = icon, hl_group = hl_group }

    utils.log("Final icon result: '" .. icon .. "' with highlight: " .. hl_group, vim.log.levels.DEBUG, false, config.config)
    return icon, hl_group
end


-- Clear icon cache (useful when switching themes)
local function clear_icon_cache()
    icon_cache = {}
end

-- Setup default highlight groups for the tree browser
local function setup_highlight_groups()
    -- Default highlight groups that work with most color schemes
    local highlights = {
        -- Folder states
        NvimTreeFolderOpen = { fg = "#90caf9", bold = true },        -- Light blue for open folders
        NvimTreeFolderClosed = { fg = "#ffb74d", bold = true },      -- Orange for closed folders

        -- General tree elements
        NvimTreeIndentMarker = { fg = "#4a4a4a" },                   -- Gray for arrows and indentation
        NvimTreeNormal = { fg = "#ffffff" },                         -- Default text color

        -- File type fallbacks (when nvim-web-devicons not available)
        RemoteTreeFile = { fg = "#e0e0e0" },                         -- Light gray for files
        RemoteTreeDirectory = { fg = "#ffb74d", bold = true },       -- Orange for directories
    }

    -- Only set highlights that don't already exist
    for hl_name, hl_def in pairs(highlights) do
        if vim.fn.hlexists(hl_name) == 0 then
            vim.api.nvim_set_hl(0, hl_name, hl_def)
        end
    end
end

-- Tree browser state
local TreeBrowser = {
    bufnr = nil,                    -- Buffer number for the tree
    win_id = nil,                   -- Window ID
    base_url = "",                  -- Root URL being browsed
    tree_data = {},                 -- Tree structure data
    expanded_dirs = {},             -- Set of expanded directory URLs
    cursor_line = 1,                -- Current cursor position
    cache = {},                     -- Local cache for quick access
    warming_jobs = {},              -- Active warming jobs
    file_win_id = nil,              -- Window ID for file display (reuse this window)
    active_ssh_jobs = {},           -- Track active SSH jobs for cleanup
    max_concurrent_ssh_jobs = 20,   -- Maximum concurrent SSH connections
}

-- Create tree item structure
local function create_tree_item(file_info, depth, parent_url)
    return {
        name = file_info.name,
        url = file_info.url,
        is_dir = file_info.is_dir,
        depth = depth,
        parent_url = parent_url,
        expanded = false,
        cached_at = nil,
        children = nil  -- Will be populated when expanded
    }
end

-- Get cached directory data
local function get_cached_directory(url)
    local cache_entry = TreeBrowser.cache[url]
    if cache_entry and (os.time() - cache_entry.timestamp) < CACHE_TTL then
        return cache_entry.data
    end
    return nil
end

-- Cleanup expired cache entries
local function cleanup_expired_cache()
    local now = os.time()
    local removed_count = 0

    for url, entry in pairs(TreeBrowser.cache) do
        if (now - entry.timestamp) >= CACHE_TTL then
            TreeBrowser.cache[url] = nil
            removed_count = removed_count + 1
        end
    end

    if removed_count > 0 then
        utils.log("Cleaned up " .. removed_count .. " expired cache entries", vim.log.levels.DEBUG, false, config.config)
    end

    return removed_count
end

-- Evict oldest cache entries when over limit
local function evict_old_cache_entries()
    local cache_size = vim.tbl_count(TreeBrowser.cache)
    if cache_size <= MAX_CACHE_ENTRIES then
        return 0
    end

    -- Create list of entries with timestamps
    local entries = {}
    for url, entry in pairs(TreeBrowser.cache) do
        table.insert(entries, { url = url, timestamp = entry.timestamp })
    end

    -- Sort by timestamp (oldest first)
    table.sort(entries, function(a, b) return a.timestamp < b.timestamp end)

    -- Remove oldest entries
    local to_remove = cache_size - MAX_CACHE_ENTRIES
    local removed_count = 0

    for i = 1, to_remove do
        if entries[i] then
            TreeBrowser.cache[entries[i].url] = nil
            removed_count = removed_count + 1
        end
    end

    if removed_count > 0 then
        utils.log("Evicted " .. removed_count .. " old cache entries (cache size limit: " .. MAX_CACHE_ENTRIES .. ")", vim.log.levels.DEBUG, false, config.config)
    end

    return removed_count
end

-- Store directory data in cache with automatic cleanup
local function cache_directory(url, data)
    -- Clean up expired entries first
    cleanup_expired_cache()

    -- Evict old entries if needed
    evict_old_cache_entries()

    -- Store new entry
    TreeBrowser.cache[url] = {
        data = data,
        timestamp = os.time()
    }
end

-- Track active SSH jobs for cleanup
local function track_ssh_job(job_id, url, callback)
    if job_id > 0 then
        TreeBrowser.active_ssh_jobs[job_id] = {
            url = url,
            callback = callback,
            timestamp = os.time()
        }
        utils.log("Tracking SSH job " .. job_id .. " for " .. url, vim.log.levels.DEBUG, false, config.config)
    end
end

-- Remove SSH job from tracking
local function untrack_ssh_job(job_id)
    if TreeBrowser.active_ssh_jobs[job_id] then
        utils.log("Untracking SSH job " .. job_id, vim.log.levels.DEBUG, false, config.config)
        TreeBrowser.active_ssh_jobs[job_id] = nil
    end
end

-- Get count of active SSH jobs
local function get_active_ssh_job_count()
    return vim.tbl_count(TreeBrowser.active_ssh_jobs)
end

-- Clean up stale SSH jobs
local function cleanup_stale_ssh_jobs()
    local now = os.time()
    local stale_threshold = 30 -- 30 seconds
    local cleaned_count = 0

    for job_id, job_info in pairs(TreeBrowser.active_ssh_jobs) do
        if (now - job_info.timestamp) > stale_threshold then
            utils.log("Cleaning up stale SSH job " .. job_id .. " for " .. job_info.url, vim.log.levels.DEBUG, false, config.config)
            pcall(vim.fn.jobstop, job_id)
            TreeBrowser.active_ssh_jobs[job_id] = nil
            cleaned_count = cleaned_count + 1
        end
    end

    if cleaned_count > 0 then
        utils.log("Cleaned up " .. cleaned_count .. " stale SSH jobs", vim.log.levels.DEBUG, false, config.config)
    end

    return cleaned_count
end

-- Stop all active SSH jobs
local function stop_all_ssh_jobs()
    local stopped_count = 0

    for job_id, job_info in pairs(TreeBrowser.active_ssh_jobs) do
        utils.log("Stopping SSH job " .. job_id .. " for " .. job_info.url, vim.log.levels.DEBUG, false, config.config)
        pcall(vim.fn.jobstop, job_id)
        stopped_count = stopped_count + 1
    end

    TreeBrowser.active_ssh_jobs = {}

    if stopped_count > 0 then
        utils.log("Stopped " .. stopped_count .. " active SSH jobs", vim.log.levels.DEBUG, false, config.config)
    end

    return stopped_count
end

-- Load directory via SSH with connection limiting
local function load_directory(url, callback)
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        if callback then callback(nil) end
        return
    end

    -- Check if we have too many concurrent SSH connections
    cleanup_stale_ssh_jobs()
    local active_count = get_active_ssh_job_count()
    if active_count >= TreeBrowser.max_concurrent_ssh_jobs then
        utils.log("Too many concurrent SSH connections (" .. active_count .. "/" .. TreeBrowser.max_concurrent_ssh_jobs .. "), queuing request for " .. url, vim.log.levels.WARN, true, config.config)
        -- Queue the request for later processing
        vim.defer_fn(function()
            load_directory(url, callback)
        end, 1000)
        return
    end

    local host = remote_info.host
    local path = remote_info.path or "/"

    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    local ssh_cmd = string.format(
        "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \"$f\" != \".\" ]; then if [ -d \"$f\" ]; then echo \"d ${f#./}\"; else echo \"f ${f#./}\"; fi; fi; done",
        vim.fn.shellescape(path)
    )

    local output = {}
    local stderr_output = {}
    local job_id = vim.fn.jobstart({'ssh', host, ssh_cmd}, {
        on_stdout = function(_, data)
            for _, line in ipairs(data) do
                if line and line ~= "" then
                    table.insert(output, line)
                end
            end
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data) do
                if line and line ~= "" then
                    table.insert(stderr_output, line)
                end
            end
        end,
        on_exit = function(_, code)
            -- Always untrack the job when it exits
            untrack_ssh_job(job_id)

            if code == 0 then
                local files = {}
                for _, line in ipairs(output) do
                    local file_type, name = line:match("^([df])%s+(.+)$")
                    if file_type and name and name ~= "." and name ~= ".." then
                        local is_dir = (file_type == "d")
                        local file_path = path .. name
                        if file_path:sub(1, 1) ~= "/" then
                            file_path = "/" .. file_path
                        end
                        local file_url = remote_info.protocol .. "://" .. host .. file_path

                        table.insert(files, {
                            name = name,
                            url = file_url,
                            is_dir = is_dir,
                            path = file_path
                        })
                    end
                end

                -- Cache the result
                cache_directory(url, files)

                if callback then callback(files) end
            else
                local error_msg = "Failed to list directory: " .. url .. " (exit code: " .. code .. ")"
                if #stderr_output > 0 then
                    error_msg = error_msg .. ", stderr: " .. table.concat(stderr_output, " ")
                end
                error_msg = error_msg .. ", command: ssh " .. host .. " '" .. ssh_cmd .. "'"
                utils.log(error_msg, vim.log.levels.ERROR, true, config.config)
                if callback then callback(nil) end
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job for " .. url, vim.log.levels.ERROR, true, config.config)
        if callback then callback(nil) end
    else
        -- Track the SSH job for cleanup
        track_ssh_job(job_id, url, callback)
        utils.log("Started SSH job " .. job_id .. " for " .. url .. " (active jobs: " .. (get_active_ssh_job_count()) .. "/" .. TreeBrowser.max_concurrent_ssh_jobs .. ")", vim.log.levels.DEBUG, false, config.config)
    end
end

-- Check if a directory should be skipped during warming
local function should_skip_warming(dir_name, dir_path)
    -- Skip hidden directories that commonly cause issues
    local skip_patterns = {
        "^%.",           -- Hidden directories (.git, .cache, etc.)
        "node_modules",  -- Node.js dependencies
        "target",        -- Rust build directory
        "build",         -- Build directories
        "BUILD",         -- Build directories (uppercase)
        "dist",          -- Distribution directories
        "__pycache__",   -- Python cache
        "venv",          -- Python virtual environments
        "env",           -- Environment directories
        "%.egg%-info",   -- Python egg info
        "cmake%.deps",   -- CMake dependencies
    }

    for _, pattern in ipairs(skip_patterns) do
        if dir_name:match(pattern) then
            return true
        end
    end

    return false
end

-- Start background warming for a directory
local function start_background_warming(url, max_depth)
    if TreeBrowser.warming_jobs[url] then
        return -- Already warming
    end

    TreeBrowser.warming_jobs[url] = true
    utils.log("Starting background warming for: " .. url, vim.log.levels.DEBUG, false, config.config)

    local function warm_recursive(current_url, current_depth)
        if current_depth >= max_depth then
            return
        end

        -- Check if we should throttle warming based on active SSH jobs
        local active_count = get_active_ssh_job_count()
        if active_count >= (TreeBrowser.max_concurrent_ssh_jobs - 2) then
            utils.log("Throttling background warming due to high SSH job count (" .. active_count .. "/" .. TreeBrowser.max_concurrent_ssh_jobs .. ")", vim.log.levels.DEBUG, false, config.config)
            -- Delay and retry warming
            vim.defer_fn(function()
                warm_recursive(current_url, current_depth)
            end, 2000)
            return
        end

        load_directory(current_url, function(files)
            if files then
                -- Warm subdirectories, but skip problematic ones
                for _, file in ipairs(files) do
                    if file.is_dir and not should_skip_warming(file.name, file.path) then
                        warm_recursive(file.url, current_depth + 1)
                    end
                end
            end
        end)
    end

    warm_recursive(url, 0)
end

-- Build tree lines for display
local function build_tree_lines(tree_data, lines, depth)
    lines = lines or {}
    depth = depth or 0

    for _, item in ipairs(tree_data) do
        local indent = string.rep("  ", depth)
        local is_expanded = item.is_dir and TreeBrowser.expanded_dirs[item.url]

        -- Get appropriate icons and highlight groups
        local file_icon, file_hl = get_file_icon(item.name, item.is_dir, is_expanded)

        -- Build line with just icon and name (no separate arrows)
        local line = indent .. file_icon .. " " .. item.name

        table.insert(lines, {
            text = line,
            item = item,
            highlights = {
                -- Highlight the file/folder icon
                { hl_group = file_hl, col_start = #indent, col_end = #indent + #file_icon + 1 }
            }
        })

        -- Add children if expanded
        if item.is_dir and TreeBrowser.expanded_dirs[item.url] and item.children then
            build_tree_lines(item.children, lines, depth + 1)
        end
    end

    return lines
end

-- Refresh the buffer display
local function refresh_display()
    if not TreeBrowser.bufnr or not vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        return
    end

    local lines = build_tree_lines(TreeBrowser.tree_data)
    local text_lines = {}

    -- Create banner with host and path information
    local remote_info = utils.parse_remote_path(TreeBrowser.base_url)
    if remote_info then
        local host = remote_info.host
        local path = remote_info.path or "/"

        -- Calculate banner width to fit content
        local min_width = 42
        local host_width = #host + 7  -- "Host: " prefix
        local path_width = #path + 7  -- "Path: " prefix
        local banner_width = math.max(min_width, host_width + 2, path_width + 2)

        -- Add banner lines
        local top_line = "╭─ Remote SSH Browser " .. string.rep("─", banner_width - 22) .. "╮"
        local host_line = "│ Host: " .. host .. string.rep(" ", banner_width - host_width - 1) .. "│"
        local path_line = "│ Path: " .. path .. string.rep(" ", banner_width - path_width - 1) .. "│"
        local bottom_line = "╰" .. string.rep("─", banner_width - 2) .. "╯"

        table.insert(text_lines, top_line)
        table.insert(text_lines, host_line)
        table.insert(text_lines, path_line)
        table.insert(text_lines, bottom_line)
        table.insert(text_lines, "")
    end

    for _, line_data in ipairs(lines) do
        table.insert(text_lines, line_data.text)
    end

    -- Update buffer content
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_lines(TreeBrowser.bufnr, 0, -1, false, text_lines)
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'modifiable', false)

    -- Apply syntax highlighting
    local banner_offset = remote_info and 5 or 0
    local ns_id = vim.api.nvim_create_namespace("RemoteTreeBrowser")
    vim.api.nvim_buf_clear_namespace(TreeBrowser.bufnr, ns_id, 0, -1)

    -- Apply highlights for each line with icons
    for i, line_data in ipairs(lines) do
        local line_num = i + banner_offset - 1  -- Convert to 0-based line number
        if line_data.highlights then
            for _, hl in ipairs(line_data.highlights) do
                vim.api.nvim_buf_add_highlight(
                    TreeBrowser.bufnr,
                    ns_id,
                    hl.hl_group,
                    line_num,
                    hl.col_start,
                    hl.col_end
                )
            end
        end
    end

    -- Store line data for interactions
    TreeBrowser.line_data = lines
    TreeBrowser.banner_offset = banner_offset
end

-- Get tree item at cursor line
local function get_item_at_cursor()
    local line_num = vim.api.nvim_win_get_cursor(TreeBrowser.win_id)[1]
    local banner_offset = TreeBrowser.banner_offset or 0
    local adjusted_line_num = line_num - banner_offset

    if TreeBrowser.line_data and adjusted_line_num > 0 and TreeBrowser.line_data[adjusted_line_num] then
        return TreeBrowser.line_data[adjusted_line_num].item
    end
    return nil
end

-- Find tree item by URL in tree_data
local function find_item_in_tree(tree_data, url)
    for _, item in ipairs(tree_data) do
        if item.url == url then
            return item
        end
        if item.children then
            local found = find_item_in_tree(item.children, url)
            if found then
                return found
            end
        end
    end
    return nil
end

-- Toggle directory expansion
local function toggle_directory(item)
    if not item or not item.is_dir then
        return
    end

    if TreeBrowser.expanded_dirs[item.url] then
        -- Collapse
        TreeBrowser.expanded_dirs[item.url] = nil
        utils.log("Collapsed: " .. item.name, vim.log.levels.DEBUG, false, config.config)
        refresh_display()
    else
        -- Expand
        TreeBrowser.expanded_dirs[item.url] = true
        utils.log("Expanding: " .. item.name, vim.log.levels.DEBUG, false, config.config)

        -- Check if we have cached data
        local cached_files = get_cached_directory(item.url)
        if cached_files then
            -- Use cached data
            item.children = {}
            for _, file_info in ipairs(cached_files) do
                table.insert(item.children, create_tree_item(file_info, item.depth + 1, item.url))
            end
            refresh_display()
        else
            -- Load directory
            load_directory(item.url, function(files)
                if files then
                    item.children = {}
                    for _, file_info in ipairs(files) do
                        table.insert(item.children, create_tree_item(file_info, item.depth + 1, item.url))
                    end
                    refresh_display()
                end
            end)
        end
    end
end

-- Open file in new buffer to the right of tree browser
local function open_file(item)
    if not item or item.is_dir then
        return
    end

    utils.log("Opening file: " .. item.url, vim.log.levels.DEBUG, false, config.config)

    -- Save current window and buffer
    local tree_win = TreeBrowser.win_id

    -- Find or create target window for file display
    local target_win = nil

    -- First, check if we have a stored file window that's still valid
    if TreeBrowser.file_win_id and vim.api.nvim_win_is_valid(TreeBrowser.file_win_id) then
        target_win = TreeBrowser.file_win_id
    else
        -- Look for a suitable existing window (not the tree browser)
        local windows = vim.api.nvim_tabpage_list_wins(0)
        for _, win_id in ipairs(windows) do
            if win_id ~= tree_win then
                local buf_in_win = vim.api.nvim_win_get_buf(win_id)
                local buftype = vim.api.nvim_buf_get_option(buf_in_win, 'buftype')
                -- Accept normal files or remote files (more flexible matching)
                if buftype == '' or buftype == 'acwrite' then
                    target_win = win_id
                    TreeBrowser.file_win_id = win_id  -- Store for future use
                    break
                end
            end
        end
    end

    if not target_win then
        -- Create new window to the right of tree browser
        vim.api.nvim_set_current_win(tree_win)
        vim.cmd("rightbelow vsplit")
        target_win = vim.api.nvim_get_current_win()
        TreeBrowser.file_win_id = target_win  -- Store the new window
    end

    vim.api.nvim_set_current_win(target_win)

    -- Use direct file opening like simple_open_remote_file for performance
    local operations = require('async-remote-write.operations')
    operations.simple_open_remote_file(item.url)

    -- Maintain tree browser width
    if vim.api.nvim_win_is_valid(tree_win) then
        vim.api.nvim_win_set_width(tree_win, 40)
    end
end

-- Handle enter key press
local function handle_enter()
    local item = get_item_at_cursor()
    if not item then
        return
    end

    if item.is_dir then
        toggle_directory(item)
    else
        open_file(item)
    end
end

-- Handle double click
local function handle_double_click()
    handle_enter()
end

-- Delete file or directory
local function delete_item()
    local item = get_item_at_cursor()
    if not item then
        utils.log("No item selected", vim.log.levels.WARN, true, config.config)
        return
    end

    local item_type = item.is_dir and "directory" or "file"
    local confirmation = vim.fn.confirm(
        "Delete " .. item_type .. ":\n" .. item.name .. "\n\nThis action cannot be undone!",
        "&Yes\n&No",
        2
    )

    if confirmation ~= 1 then
        utils.log("Delete cancelled", vim.log.levels.INFO, true, config.config)
        return
    end

    utils.log("Deleting " .. item_type .. ": " .. item.name, vim.log.levels.INFO, true, config.config)

    -- Parse remote info from the item URL
    local remote_info = utils.parse_remote_path(item.url)
    if not remote_info then
        utils.log("Failed to parse remote path: " .. item.url, vim.log.levels.ERROR, true, config.config)
        return
    end

    -- Build SSH command to delete the item
    local delete_cmd
    if item.is_dir then
        delete_cmd = string.format("ssh %s 'rm -rf %s'",
            remote_info.host,
            vim.fn.shellescape(remote_info.path))
    else
        delete_cmd = string.format("ssh %s 'rm -f %s'",
            remote_info.host,
            vim.fn.shellescape(remote_info.path))
    end

    utils.log("Delete command: " .. delete_cmd, vim.log.levels.DEBUG, false, config.config)

    local job_id = vim.fn.jobstart(delete_cmd, {
        on_exit = function(_, exit_code)
            vim.schedule(function()
                if exit_code == 0 then
                    utils.log("Successfully deleted " .. item_type .. ": " .. item.name, vim.log.levels.INFO, true, config.config)

                    -- Clear cache for the parent directory and related entries
                    local parent_url = vim.fn.fnamemodify(item.url, ":h")
                    TreeBrowser.cache[parent_url] = nil
                    TreeBrowser.cache[item.url] = nil  -- Clear the deleted item's cache too

                    -- Clear any cache entries that start with the parent URL
                    for cache_url, _ in pairs(TreeBrowser.cache) do
                        if cache_url:find(parent_url, 1, true) == 1 then
                            TreeBrowser.cache[cache_url] = nil
                        end
                    end

                    -- Force a full tree refresh - this is the most reliable approach
                    utils.log("Refreshing tree to show deletion...", vim.log.levels.DEBUG, false, config.config)
                    M.refresh_tree()
                else
                    utils.log("Failed to delete " .. item_type .. ": " .. item.name, vim.log.levels.ERROR, true, config.config)
                end
            end)
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        utils.log("Delete error: " .. line, vim.log.levels.ERROR, false, config.config)
                    end
                end
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start delete job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Create new directory
local function create_directory()
    local item = get_item_at_cursor()
    local parent_url
    local parent_path

    if item then
        if item.is_dir then
            -- Create inside the selected directory
            parent_url = item.url
            parent_path = item.name
        else
            -- Create in the same directory as the selected file
            parent_url = vim.fn.fnamemodify(item.url, ":h")
            parent_path = vim.fn.fnamemodify(item.name, ":h")
            if parent_path == "." then parent_path = "" end
        end
    else
        -- Create in root directory
        parent_url = TreeBrowser.base_url
        parent_path = ""
    end

    local dir_name = vim.fn.input("Directory name: ")
    if not dir_name or dir_name == "" then
        utils.log("Directory creation cancelled", vim.log.levels.INFO, true, config.config)
        return
    end

    -- Validate directory name
    if dir_name:match("[/\\]") then
        utils.log("Directory name cannot contain / or \\", vim.log.levels.ERROR, true, config.config)
        return
    end

    utils.log("Creating directory: " .. dir_name, vim.log.levels.INFO, true, config.config)

    -- Parse remote info
    local remote_info = utils.parse_remote_path(parent_url)
    if not remote_info then
        utils.log("Failed to parse remote path: " .. parent_url, vim.log.levels.ERROR, true, config.config)
        return
    end

    -- Build the full path for the new directory
    local new_dir_path
    if remote_info.path == "/" or remote_info.path == "" then
        new_dir_path = "/" .. dir_name
    else
        new_dir_path = remote_info.path .. "/" .. dir_name
    end

    -- Build SSH command to create directory
    local create_cmd = string.format("ssh %s 'mkdir -p %s'",
        remote_info.host,
        vim.fn.shellescape(new_dir_path))

    utils.log("Create command: " .. create_cmd, vim.log.levels.DEBUG, false, config.config)

    local job_id = vim.fn.jobstart(create_cmd, {
        on_exit = function(_, exit_code)
            vim.schedule(function()
                if exit_code == 0 then
                    utils.log("Successfully created directory: " .. dir_name, vim.log.levels.INFO, true, config.config)

                    -- Clear cache for the parent directory and related entries
                    TreeBrowser.cache[parent_url] = nil

                    -- Clear any cache entries that start with the parent URL
                    for cache_url, _ in pairs(TreeBrowser.cache) do
                        if cache_url:find(parent_url, 1, true) == 1 then
                            TreeBrowser.cache[cache_url] = nil
                        end
                    end

                    -- Force a full tree refresh to show the new directory
                    utils.log("Refreshing tree to show new directory...", vim.log.levels.DEBUG, false, config.config)
                    M.refresh_tree()
                else
                    utils.log("Failed to create directory: " .. dir_name, vim.log.levels.ERROR, true, config.config)
                end
            end)
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        utils.log("Create error: " .. line, vim.log.levels.ERROR, false, config.config)
                    end
                end
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start create job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Create new file
local function create_file()
    local item = get_item_at_cursor()
    local parent_url
    local parent_path

    if item then
        if item.is_dir then
            -- Create inside the selected directory
            parent_url = item.url
            parent_path = item.name
        else
            -- Create in the same directory as the selected file
            parent_url = vim.fn.fnamemodify(item.url, ":h")
            parent_path = vim.fn.fnamemodify(item.name, ":h")
            if parent_path == "." then parent_path = "" end
        end
    else
        -- Create in root directory
        parent_url = TreeBrowser.base_url
        parent_path = ""
    end

    local file_name = vim.fn.input("File name: ")
    if not file_name or file_name == "" then
        utils.log("File creation cancelled", vim.log.levels.INFO, true, config.config)
        return
    end

    -- Validate file name
    if file_name:match("[/\\]") then
        utils.log("File name cannot contain / or \\", vim.log.levels.ERROR, true, config.config)
        return
    end

    utils.log("Creating file: " .. file_name, vim.log.levels.INFO, true, config.config)

    -- Parse remote info
    local remote_info = utils.parse_remote_path(parent_url)
    if not remote_info then
        utils.log("Failed to parse remote path: " .. parent_url, vim.log.levels.ERROR, true, config.config)
        return
    end

    -- Build the full path for the new file
    local new_file_path
    if remote_info.path == "/" or remote_info.path == "" then
        new_file_path = "/" .. file_name
    else
        new_file_path = remote_info.path .. "/" .. file_name
    end

    -- Build SSH command to create file
    local create_cmd = string.format("ssh %s 'touch %s'",
        remote_info.host,
        vim.fn.shellescape(new_file_path))

    utils.log("Create file command: " .. create_cmd, vim.log.levels.DEBUG, false, config.config)

    local job_id = vim.fn.jobstart(create_cmd, {
        on_exit = function(_, exit_code)
            vim.schedule(function()
                if exit_code == 0 then
                    utils.log("Successfully created file: " .. file_name, vim.log.levels.INFO, true, config.config)

                    -- Clear cache for the parent directory and related entries
                    TreeBrowser.cache[parent_url] = nil

                    -- Clear any cache entries that start with the parent URL
                    for cache_url, _ in pairs(TreeBrowser.cache) do
                        if cache_url:find(parent_url, 1, true) == 1 then
                            TreeBrowser.cache[cache_url] = nil
                        end
                    end

                    -- Force a full tree refresh to show the new file
                    utils.log("Refreshing tree to show new file...", vim.log.levels.DEBUG, false, config.config)
                    M.refresh_tree()
                else
                    utils.log("Failed to create file: " .. file_name, vim.log.levels.ERROR, true, config.config)
                end
            end)
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        utils.log("Create file error: " .. line, vim.log.levels.ERROR, false, config.config)
                    end
                end
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start create file job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Setup buffer keymaps
local function setup_keymaps()
    local opts = { noremap = true, silent = true, buffer = TreeBrowser.bufnr }

    -- Enter to expand/collapse or open file
    vim.keymap.set('n', '<CR>', handle_enter, opts)
    vim.keymap.set('n', '<2-LeftMouse>', handle_double_click, opts)

    -- Space to toggle expansion without opening files
    vim.keymap.set('n', '<Space>', function()
        local item = get_item_at_cursor()
        if item and item.is_dir then
            toggle_directory(item)
        end
    end, opts)

    -- File/Directory operations (NvimTree-style)
    vim.keymap.set('n', 'd', delete_item, opts)           -- Delete file/directory
    vim.keymap.set('n', 'a', create_file, opts)           -- Create file
    vim.keymap.set('n', 'A', create_directory, opts)      -- Create directory

    -- Refresh
    vim.keymap.set('n', 'R', function()
        M.refresh_tree()
    end, opts)

    -- Close tree
    vim.keymap.set('n', 'q', function()
        M.close_tree()
    end, opts)

    -- Help mapping
    vim.keymap.set('n', '?', function()
        local help_text = [[
Remote Tree Browser - Keybindings:

Navigation:
  <CR>     - Open file / Toggle directory
  <Space>  - Toggle directory expansion

File Operations:
  a        - Create new file
  A        - Create new directory
  d        - Delete file/directory (with confirmation)

Tree Operations:
  R        - Refresh tree
  q        - Close tree browser
  ?        - Show this help
]]
        vim.notify(help_text, vim.log.levels.INFO)
    end, opts)
end

-- Create and setup the tree buffer
local function create_tree_buffer()
    -- Create buffer
    TreeBrowser.bufnr = vim.api.nvim_create_buf(false, true)

    -- Setup buffer options
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'swapfile', false)
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'filetype', 'remote-tree')
    vim.api.nvim_buf_set_name(TreeBrowser.bufnr, 'Remote Tree: ' .. TreeBrowser.base_url)

    -- Open in split window
    vim.cmd('vsplit')
    TreeBrowser.win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(TreeBrowser.win_id, TreeBrowser.bufnr)

    -- Setup window options
    vim.api.nvim_win_set_width(TreeBrowser.win_id, 40)
    vim.api.nvim_win_set_option(TreeBrowser.win_id, 'wrap', false)
    vim.api.nvim_win_set_option(TreeBrowser.win_id, 'number', false)
    vim.api.nvim_win_set_option(TreeBrowser.win_id, 'relativenumber', false)
    vim.api.nvim_win_set_option(TreeBrowser.win_id, 'signcolumn', 'no')

    -- Setup keymaps
    setup_keymaps()
end

-- Load initial tree structure
local function load_initial_tree(url)
    utils.log("Loading initial tree for: " .. url, vim.log.levels.DEBUG, false, config.config)

    load_directory(url, function(files)
        if files then
            TreeBrowser.tree_data = {}
            for _, file_info in ipairs(files) do
                table.insert(TreeBrowser.tree_data, create_tree_item(file_info, 0, url))
            end
            refresh_display()

            -- Start background warming
            start_background_warming(url, WARMING_MAX_DEPTH)
        else
            utils.log("Failed to load initial tree", vim.log.levels.ERROR, true, config.config)
        end
    end)
end

-- Public API functions

-- Open tree browser for a remote URL
function M.open_tree(url)
    if not url then
        utils.log("No URL provided for tree browser", vim.log.levels.ERROR, true, config.config)
        return
    end

    -- Parse and validate URL
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    -- Check if tree browser is already open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        -- If it's the same URL, just focus the existing window
        if TreeBrowser.base_url == url then
            if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
                vim.api.nvim_set_current_win(TreeBrowser.win_id)
                utils.log("Tree browser already open for this URL, focusing window", vim.log.levels.DEBUG, false, config.config)
                return
            end
        end
        -- Different URL or invalid window, close the existing one first
        M.close_tree()
    end

    -- Setup highlight groups
    setup_highlight_groups()

    TreeBrowser.base_url = url
    TreeBrowser.expanded_dirs = {}
    TreeBrowser.tree_data = {}
    TreeBrowser.file_win_id = nil  -- Reset file window reference for new tree

    -- Create buffer and window
    create_tree_buffer()

    -- Load initial tree
    load_initial_tree(url)

    utils.log("Opened remote tree browser for: " .. url, vim.log.levels.DEBUG, false, config.config)
end

-- Close tree browser
function M.close_tree()
    -- Stop all active SSH jobs first
    local stopped_count = stop_all_ssh_jobs()
    if stopped_count > 0 then
        utils.log("Stopped " .. stopped_count .. " SSH jobs on tree close", vim.log.levels.DEBUG, false, config.config)
    end

    if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
        vim.api.nvim_win_close(TreeBrowser.win_id, false)
    end

    -- Properly delete the buffer to avoid name conflicts
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        vim.api.nvim_buf_delete(TreeBrowser.bufnr, { force = true })
    end

    TreeBrowser.bufnr = nil
    TreeBrowser.win_id = nil
    TreeBrowser.file_win_id = nil  -- Reset file window reference
    TreeBrowser.warming_jobs = {}  -- Clear warming jobs

    utils.log("Closed remote tree browser", vim.log.levels.DEBUG, false, config.config)
end

-- Refresh tree while preserving expansion state
function M.refresh_tree()
    if not TreeBrowser.base_url then
        utils.log("No tree browser open to refresh", vim.log.levels.WARN, true, config.config)
        return
    end

    utils.log("Refreshing tree browser (preserving expansion state)...", vim.log.levels.DEBUG, false, config.config)

    -- Store current cursor position and expanded state for restoration
    local current_line = 1
    if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
        current_line = vim.api.nvim_win_get_cursor(TreeBrowser.win_id)[1]
    end
    local expanded_state = vim.deepcopy(TreeBrowser.expanded_dirs)

    -- Clear all directory cache for this tree
    for url, _ in pairs(TreeBrowser.cache) do
        if url:find(TreeBrowser.base_url, 1, true) == 1 then
            TreeBrowser.cache[url] = nil
        end
    end

    -- Clear icon cache completely (since file lists might change)
    M.clear_icon_cache()

    -- Reset tree data but preserve expanded directories
    TreeBrowser.tree_data = {}

    -- Reload tree from scratch
    load_initial_tree(TreeBrowser.base_url)

    -- Restore expanded state after tree loads
    vim.defer_fn(function()
        if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
            utils.log("Restoring " .. vim.tbl_count(expanded_state) .. " expanded directories...", vim.log.levels.DEBUG, false, config.config)

            -- Restore the expanded directories state
            TreeBrowser.expanded_dirs = expanded_state

            -- Re-expand all directories that were previously expanded
            local function restore_expansions(tree_items)
                for _, item in ipairs(tree_items) do
                    if item.is_dir and expanded_state[item.url] then
                        -- This directory was expanded, so expand it again
                        local cached_files = get_cached_directory(item.url)
                        if cached_files then
                            -- Use cached data
                            item.children = {}
                            for _, file_info in ipairs(cached_files) do
                                table.insert(item.children, create_tree_item(file_info, item.depth + 1, item.url))
                            end
                            -- Recursively restore expansions for children
                            if item.children then
                                restore_expansions(item.children)
                            end
                        else
                            -- Load directory and restore its expansions
                            load_directory(item.url, function(files)
                                if files then
                                    item.children = {}
                                    for _, file_info in ipairs(files) do
                                        table.insert(item.children, create_tree_item(file_info, item.depth + 1, item.url))
                                    end
                                    -- Recursively restore expansions for children
                                    restore_expansions(item.children)
                                    refresh_display()
                                end
                            end)
                        end
                    end
                end
            end

            -- Start restoration process
            restore_expansions(TreeBrowser.tree_data)

            -- Refresh display to show restored state
            refresh_display()

            -- Try to restore cursor position
            if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
                pcall(vim.api.nvim_win_set_cursor, TreeBrowser.win_id, {current_line, 0})
            end

            utils.log("Tree browser refreshed with expansion state preserved", vim.log.levels.DEBUG, false, config.config)
        end
    end, 100)
end

-- Enhanced refresh that includes clearing all related caches
function M.refresh_tree_full()
    if not TreeBrowser.base_url then
        utils.log("No tree browser open to refresh", vim.log.levels.WARN, true, config.config)
        return
    end

    utils.log("Performing full tree browser refresh (clearing all caches)...", vim.log.levels.INFO, true, config.config)

    -- Clear all tree browser caches
    M.clear_all_cache()

    -- Clear remote-lsp project root cache if available
    local has_remote_lsp, remote_lsp_utils = pcall(require, 'remote-lsp.utils')
    if has_remote_lsp and remote_lsp_utils.clear_project_root_cache then
        remote_lsp_utils.clear_project_root_cache()
        utils.log("Cleared remote-lsp project root cache", vim.log.levels.DEBUG, false, config.config)
    end

    -- Reset all tree state
    TreeBrowser.expanded_dirs = {}
    TreeBrowser.tree_data = {}

    -- Reload tree from scratch
    load_initial_tree(TreeBrowser.base_url)

    utils.log("Full tree browser refresh completed", vim.log.levels.INFO, true, config.config)
end

-- Check if tree browser is open
function M.is_open()
    return TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr)
end

-- Get current tree state (for persistence)
function M.get_state()
    return {
        base_url = TreeBrowser.base_url,
        expanded_dirs = vim.deepcopy(TreeBrowser.expanded_dirs),
        cache = vim.deepcopy(TreeBrowser.cache)
    }
end

-- Restore tree state (for quick reopen)
function M.restore_state(state)
    if state then
        TreeBrowser.expanded_dirs = state.expanded_dirs or {}
        TreeBrowser.cache = state.cache or {}

        if state.base_url then
            M.open_tree(state.base_url)
        end
    end
end

-- Configuration API functions

-- Configure custom icons
function M.setup_icons(icon_config)
    if icon_config then
        -- Override primary icons (preferred)
        if icon_config.folder_closed then
            primary_icons.folder_closed = icon_config.folder_closed
        end
        if icon_config.folder_open then
            primary_icons.folder_open = icon_config.folder_open
        end
        if icon_config.file_default then
            fallback_icons.file_default = icon_config.file_default
        end

        -- Clear cache to force icon regeneration
        clear_icon_cache()

        utils.log("Updated tree browser icons", vim.log.levels.DEBUG, false, config.config)
    end
end

-- Use ASCII fallback icons (for terminals that don't support Unicode well)
function M.use_ascii_icons()
    primary_icons.folder_closed = fallback_icons.folder_closed
    primary_icons.folder_open = fallback_icons.folder_open

    -- Clear cache to force icon regeneration
    clear_icon_cache()

    -- Refresh display if tree is open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        refresh_display()
    end

    utils.log("Switched to ASCII fallback icons", vim.log.levels.INFO, true, config.config)
end

-- Restore Unicode icons
function M.use_unicode_icons()
    primary_icons.folder_closed = " "
    primary_icons.folder_open = " "

    -- Clear cache to force icon regeneration
    clear_icon_cache()

    -- Refresh display if tree is open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        refresh_display()
    end

    utils.log("Switched to Unicode folder icons", vim.log.levels.INFO, true, config.config)
end

-- Configure custom highlight groups
function M.setup_highlights(highlight_config)
    if highlight_config then
        for hl_name, hl_def in pairs(highlight_config) do
            vim.api.nvim_set_hl(0, hl_name, hl_def)
        end

        utils.log("Updated tree browser highlights", vim.log.levels.DEBUG, false, config.config)
    end
end

-- Get current icon configuration
function M.get_icon_config()
    return {
        has_devicons = has_devicons,
        primary_icons = vim.deepcopy(primary_icons),
        fallback_icons = vim.deepcopy(fallback_icons),
        cache_size = vim.tbl_count(icon_cache)
    }
end

-- Refresh icons (useful after installing nvim-web-devicons)
function M.refresh_icons()
    -- Re-check for devicons availability
    has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Clear cache to regenerate icons
    clear_icon_cache()

    -- Refresh display if tree is open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        refresh_display()
    end

    utils.log("Refreshed tree browser icons (nvim-web-devicons " .. (has_devicons and "available" or "not available") .. ")", vim.log.levels.INFO, true, config.config)
    utils.log("Current fallback icons: " .. vim.inspect(fallback_icons), vim.log.levels.DEBUG, false, config.config)
end

-- Cache Management API

-- Clear directory cache only
function M.clear_cache()
    local cache_count = vim.tbl_count(TreeBrowser.cache)
    TreeBrowser.cache = {}

    utils.log("Cleared " .. cache_count .. " directory cache entries", vim.log.levels.INFO, true, config.config)

    -- Refresh display if tree is open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        refresh_display()
    end

    return cache_count
end

-- Clear icon cache only
function M.clear_icon_cache()
    local icon_count = vim.tbl_count(icon_cache)
    clear_icon_cache()

    utils.log("Cleared " .. icon_count .. " icon cache entries", vim.log.levels.INFO, true, config.config)

    -- Refresh display if tree is open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        refresh_display()
    end

    return icon_count
end

-- Clear all caches (directory + icon)
function M.clear_all_cache()
    local cache_count = vim.tbl_count(TreeBrowser.cache)
    local icon_count = vim.tbl_count(icon_cache)

    TreeBrowser.cache = {}
    clear_icon_cache()

    local total_cleared = cache_count + icon_count
    utils.log("Cleared all caches: " .. cache_count .. " directory + " .. icon_count .. " icon entries (" .. total_cleared .. " total)", vim.log.levels.INFO, true, config.config)

    -- Refresh display if tree is open
    if TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr) then
        refresh_display()
    end

    return { directory = cache_count, icon = icon_count, total = total_cleared }
end

-- Cache Inspection API

-- Get cache size information
function M.get_cache_size()
    local dir_count = vim.tbl_count(TreeBrowser.cache)
    local icon_count = vim.tbl_count(icon_cache)
    local total = dir_count + icon_count

    return {
        directory_cache = dir_count,
        icon_cache = icon_count,
        total_entries = total
    }
end

-- Get detailed cache information
function M.get_cache_info()
    local now = os.time()
    local dir_cache_info = {}
    local expired_count = 0

    -- Analyze directory cache
    for url, entry in pairs(TreeBrowser.cache) do
        local age = now - entry.timestamp
        local is_expired = age >= CACHE_TTL
        if is_expired then
            expired_count = expired_count + 1
        end

        table.insert(dir_cache_info, {
            url = url,
            timestamp = entry.timestamp,
            age_seconds = age,
            is_expired = is_expired,
            entry_count = entry.data and #entry.data or 0
        })
    end

    -- Sort by age (newest first)
    table.sort(dir_cache_info, function(a, b) return a.age_seconds < b.age_seconds end)

    local cache_info = {
        ttl_seconds = CACHE_TTL,
        current_time = now,
        limits = {
            max_directory_entries = MAX_CACHE_ENTRIES,
            max_icon_entries = MAX_ICON_CACHE_ENTRIES
        },
        directory_cache = {
            total_entries = vim.tbl_count(TreeBrowser.cache),
            expired_entries = expired_count,
            active_entries = vim.tbl_count(TreeBrowser.cache) - expired_count,
            usage_percent = math.floor((vim.tbl_count(TreeBrowser.cache) / MAX_CACHE_ENTRIES) * 100),
            entries = dir_cache_info
        },
        icon_cache = {
            total_entries = vim.tbl_count(icon_cache),
            usage_percent = math.floor((vim.tbl_count(icon_cache) / MAX_ICON_CACHE_ENTRIES) * 100),
            has_devicons = has_devicons
        },
        tree_state = {
            is_open = TreeBrowser.bufnr and vim.api.nvim_buf_is_valid(TreeBrowser.bufnr),
            base_url = TreeBrowser.base_url,
            expanded_dirs_count = vim.tbl_count(TreeBrowser.expanded_dirs)
        }
    }

    return cache_info
end

-- Get cache entries for a specific URL pattern
function M.get_cache_entries(url_pattern)
    local matches = {}

    for url, entry in pairs(TreeBrowser.cache) do
        if not url_pattern or url:find(url_pattern, 1, true) then
            local age = os.time() - entry.timestamp
            table.insert(matches, {
                url = url,
                timestamp = entry.timestamp,
                age_seconds = age,
                is_expired = age >= CACHE_TTL,
                entry_count = entry.data and #entry.data or 0,
                data = entry.data
            })
        end
    end

    return matches
end

-- Print cache info to user (for debugging)
function M.print_cache_info()
    local info = M.get_cache_info()
    local size_info = M.get_cache_size()

    print("=== Remote Tree Browser Cache Info ===")
    print(string.format("Total Entries: %d (Directory: %d, Icon: %d)",
        size_info.total_entries, size_info.directory_cache, size_info.icon_cache))
    print(string.format("Directory Cache: %d/%d entries (%d%% full), %d active, %d expired (TTL: %ds)",
        info.directory_cache.total_entries, info.limits.max_directory_entries, info.directory_cache.usage_percent,
        info.directory_cache.active_entries, info.directory_cache.expired_entries, info.ttl_seconds))
    print(string.format("Icon Cache: %d/%d entries (%d%% full)",
        info.icon_cache.total_entries, info.limits.max_icon_entries, info.icon_cache.usage_percent))
    print(string.format("Tree State: %s, Base URL: %s",
        info.tree_state.is_open and "Open" or "Closed", info.tree_state.base_url or "None"))
    print(string.format("nvim-web-devicons: %s", info.icon_cache.has_devicons and "Available" or "Not Available"))

    if info.directory_cache.total_entries > 0 then
        print("\nDirectory Cache Entries:")
        for i, entry in ipairs(info.directory_cache.entries) do
            if i <= 5 then  -- Show only first 5 entries
                local status = entry.is_expired and "[EXPIRED]" or "[ACTIVE]"
                print(string.format("  %s %s (age: %ds, %d items)",
                    status, entry.url, entry.age_seconds, entry.entry_count))
            end
        end
        if #info.directory_cache.entries > 5 then
            print(string.format("  ... and %d more entries", #info.directory_cache.entries - 5))
        end
    end
end

-- SSH Job Management API

-- Get active SSH job count
function M.get_active_ssh_job_count()
    return get_active_ssh_job_count()
end

-- Get active SSH job info
function M.get_active_ssh_jobs()
    local jobs = {}
    local now = os.time()

    for job_id, job_info in pairs(TreeBrowser.active_ssh_jobs) do
        table.insert(jobs, {
            job_id = job_id,
            url = job_info.url,
            age_seconds = now - job_info.timestamp,
            timestamp = job_info.timestamp
        })
    end

    return jobs
end

-- Clean up stale SSH jobs (public API)
function M.cleanup_stale_ssh_jobs()
    return cleanup_stale_ssh_jobs()
end

-- Stop all SSH jobs (public API)
function M.stop_all_ssh_jobs()
    return stop_all_ssh_jobs()
end

-- Configure maximum concurrent SSH jobs
function M.set_max_concurrent_ssh_jobs(max_jobs)
    if type(max_jobs) == "number" and max_jobs > 0 and max_jobs <= 50 then
        TreeBrowser.max_concurrent_ssh_jobs = max_jobs
        utils.log("Set max concurrent SSH jobs to " .. max_jobs, vim.log.levels.INFO, true, config.config)
    else
        utils.log("Invalid max concurrent SSH jobs value: " .. tostring(max_jobs), vim.log.levels.ERROR, true, config.config)
    end
end

-- Get current SSH job limits
function M.get_ssh_job_limits()
    return {
        max_concurrent = TreeBrowser.max_concurrent_ssh_jobs,
        current_active = get_active_ssh_job_count()
    }
end

-- Print SSH job info to user (for debugging)
function M.print_ssh_job_info()
    local active_jobs = M.get_active_ssh_jobs()
    local limits = M.get_ssh_job_limits()

    print("=== Remote Tree Browser SSH Job Info ===")
    print(string.format("Active SSH Jobs: %d/%d", limits.current_active, limits.max_concurrent))

    if #active_jobs > 0 then
        print("\nActive SSH Jobs:")
        for i, job in ipairs(active_jobs) do
            print(string.format("  Job %d: %s (age: %ds)", job.job_id, job.url, job.age_seconds))
        end
    else
        print("No active SSH jobs")
    end
end

-- Setup automatic cleanup on Neovim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        local stopped_count = stop_all_ssh_jobs()
        if stopped_count > 0 then
            utils.log("Stopped " .. stopped_count .. " SSH jobs on Neovim exit", vim.log.levels.DEBUG, false, config.config)
        end
    end,
    group = vim.api.nvim_create_augroup("RemoteTreeBrowserCleanup", { clear = true }),
    desc = "Clean up SSH jobs on Neovim exit"
})

return M
