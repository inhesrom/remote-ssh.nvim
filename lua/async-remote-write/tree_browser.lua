-- Buffer-based tree browser for remote files
-- Provides a dedicated buffer with expandable file tree, caching, and background warming

local utils = require('async-remote-write.utils')
local config = require('async-remote-write.config')

local M = {}

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
                utils.log("Failed to list directory: " .. url, vim.log.levels.ERROR, true, config.config)
                if callback then callback(nil) end
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
        if callback then callback(nil) end
    end
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
                -- Warm subdirectories
                for _, file in ipairs(files) do
                    if file.is_dir then
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
        local icon = ""
        local prefix = ""
        
        if item.is_dir then
            if TreeBrowser.expanded_dirs[item.url] then
                icon = "📂 "
                prefix = "▼ "
            else
                icon = "📁 "
                prefix = "▶ "
            end
        else
            icon = "📄 "
            prefix = "  "
        end
        
        local line = indent .. prefix .. icon .. item.name
        table.insert(lines, {
            text = line,
            item = item
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
    
    for _, line_data in ipairs(lines) do
        table.insert(text_lines, line_data.text)
    end
    
    -- Update buffer content
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_lines(TreeBrowser.bufnr, 0, -1, false, text_lines)
    vim.api.nvim_buf_set_option(TreeBrowser.bufnr, 'modifiable', false)
    
    -- Store line data for interactions
    TreeBrowser.line_data = lines
end

-- Get tree item at cursor line
local function get_item_at_cursor()
    local line_num = vim.api.nvim_win_get_cursor(TreeBrowser.win_id)[1]
    if TreeBrowser.line_data and TreeBrowser.line_data[line_num] then
        return TreeBrowser.line_data[line_num].item
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

-- Open file in new buffer
local function open_file(item)
    if not item or item.is_dir then
        return
    end
    
    utils.log("Opening file: " .. item.url, vim.log.levels.INFO, true, config.config)
    vim.cmd("edit " .. item.url)
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
    
    TreeBrowser.base_url = url
    TreeBrowser.expanded_dirs = {}
    TreeBrowser.tree_data = {}
    
    -- Create buffer and window
    create_tree_buffer()
    
    -- Load initial tree
    load_initial_tree(url)
    
    utils.log("Opened remote tree browser for: " .. url, vim.log.levels.INFO, true, config.config)
end

-- Close tree browser
function M.close_tree()
    if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
        vim.api.nvim_win_close(TreeBrowser.win_id, false)
    end
    
    TreeBrowser.bufnr = nil
    TreeBrowser.win_id = nil
    
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
    
    utils.log("Refreshed remote tree", vim.log.levels.INFO, true, config.config)
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

return M