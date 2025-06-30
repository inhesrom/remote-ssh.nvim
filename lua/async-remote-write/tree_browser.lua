-- Buffer-based tree browser for remote files
-- Provides a dedicated buffer with expandable file tree, caching, and background warming

local utils = require('async-remote-write.utils')
local config = require('async-remote-write.config')

local M = {}

-- Icon system with nvim-web-devicons integration
local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

-- Default fallback icons when nvim-web-devicons is not available
local fallback_icons = {
    folder_closed = "[+]",  -- Simple ASCII fallback
    folder_open = "[-]",    -- Simple ASCII fallback
    file_default = " • "    -- Simple ASCII fallback
}

-- Icon cache for performance
local icon_cache = {}

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
        -- Directory icons - always use fallback icons for better compatibility
        icon = is_expanded and fallback_icons.folder_open or fallback_icons.folder_closed
        
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
    
    -- Cache the result
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
}

-- Cache and warming configuration
local CACHE_TTL = 300  -- 5 minutes
local WARMING_MAX_DEPTH = 5

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

-- Store directory data in cache
local function cache_directory(url, data)
    TreeBrowser.cache[url] = {
        data = data,
        timestamp = os.time()
    }
end

-- Load directory via SSH
local function load_directory(url, callback)
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        if callback then callback(nil) end
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
                utils.log("Failed to list directory: " .. url, vim.log.levels.DEBUG, false, config.config)
                if callback then callback(nil) end
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
        if callback then callback(nil) end
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
    
    -- Refresh
    vim.keymap.set('n', 'R', function()
        M.refresh_tree()
    end, opts)
    
    -- Close tree
    vim.keymap.set('n', 'q', function()
        M.close_tree()
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
    if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
        vim.api.nvim_win_close(TreeBrowser.win_id, false)
    end
    
    TreeBrowser.bufnr = nil
    TreeBrowser.win_id = nil
    TreeBrowser.file_win_id = nil  -- Reset file window reference
    
    utils.log("Closed remote tree browser", vim.log.levels.DEBUG, false, config.config)
end

-- Refresh tree (reload from remote)
function M.refresh_tree()
    if not TreeBrowser.base_url then
        return
    end
    
    -- Clear cache for this tree
    for url, _ in pairs(TreeBrowser.cache) do
        if url:find(TreeBrowser.base_url, 1, true) == 1 then
            TreeBrowser.cache[url] = nil
        end
    end
    
    -- Reload tree
    load_initial_tree(TreeBrowser.base_url)
    
    utils.log("Refreshed remote tree", vim.log.levels.DEBUG, false, config.config)
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
        -- Override fallback icons
        if icon_config.folder_closed then
            fallback_icons.folder_closed = icon_config.folder_closed
        end
        if icon_config.folder_open then
            fallback_icons.folder_open = icon_config.folder_open
        end
        if icon_config.file_default then
            fallback_icons.file_default = icon_config.file_default
        end
        
        -- Clear cache to force icon regeneration
        clear_icon_cache()
        
        utils.log("Updated tree browser icons", vim.log.levels.DEBUG, false, config.config)
    end
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

return M