local M = {}

local config = require('remote-lsp.config')
local log = require('logging').log

-- Project root cache to avoid repeated SSH calls
local project_root_cache = {}

-- Function to get the directory of the current Lua script
function M.get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
end

-- Cache helper functions
local function get_cache_key(host, path, root_patterns)
    return host .. "|" .. path .. "|" .. table.concat(root_patterns or {}, ",")
end

local function is_cache_valid(entry)
    if not entry then return false end
    local ttl = config.config.root_cache_ttl or 300
    return (os.time() - entry.timestamp) < ttl
end

local function get_cached_root(host, path, root_patterns)
    if not config.config.root_cache_enabled then
        return nil
    end

    local key = get_cache_key(host, path, root_patterns)
    local entry = project_root_cache[key]
    if entry and is_cache_valid(entry) then
        log("Cache HIT for project root: " .. entry.root, vim.log.levels.DEBUG, false, config.config)
        return entry.root
    end
    return nil
end

local function cache_project_root(host, path, root_patterns, root)
    if not config.config.root_cache_enabled then
        return
    end

    local key = get_cache_key(host, path, root_patterns)
    project_root_cache[key] = {
        root = root,
        timestamp = os.time()
    }
    log("Cached project root: " .. root, vim.log.levels.DEBUG, false, config.config)
end

-- Helper function to determine protocol from bufname
function M.get_protocol(bufname)
    if bufname:match("^scp://") then
        return "scp"
    elseif bufname:match("^rsync://") then
        return "rsync"
    else
        return nil
    end
end

-- Parse host and path from buffer name
function M.parse_remote_buffer(bufname)
    local protocol = M.get_protocol(bufname)
    if not protocol then
        return nil, nil, nil
    end

    local pattern = "^" .. protocol .. "://([^/]+)/+(.+)$"  -- Allow multiple slashes after host
    local host, path = bufname:match(pattern)
    if host and path then
        -- Ensure path doesn't start with slash to prevent double slashes
        path = path:gsub("^/+", "")
    end
    return host, path, protocol
end

-- Batch check for multiple patterns in a directory via single SSH call
local function batch_check_patterns(host, search_dir, patterns)
    -- Create a shell command that checks for all patterns at once
    local pattern_checks = {}
    for _, pattern in ipairs(patterns) do
        table.insert(pattern_checks, string.format("[ -e %s ] && echo 'FOUND:%s'", vim.fn.shellescape(pattern), pattern))
    end

    local batch_cmd = string.format(
        "ssh %s 'cd %s 2>/dev/null && (%s)'",
        host,
        vim.fn.shellescape(search_dir),
        table.concat(pattern_checks, "; ")
    )

    log("Batch SSH Command: " .. batch_cmd, vim.log.levels.DEBUG, false, config.config)
    local result = vim.fn.trim(vim.fn.system(batch_cmd))
    log("Batch result: '" .. result .. "'", vim.log.levels.DEBUG, false, config.config)

    -- Parse results to find which patterns were found
    local found_patterns = {}
    for line in result:gmatch("FOUND:([^\n]+)") do
        table.insert(found_patterns, line)
    end

    return found_patterns
end

-- Get prioritized patterns for clangd (compile_commands.json has highest priority)
local function get_prioritized_patterns(patterns, server_name)
    if server_name == "clangd" then
        -- For clangd, prioritize compile_commands.json
        local prioritized = {}
        local remaining = {}

        for _, pattern in ipairs(patterns) do
            if pattern == "compile_commands.json" then
                table.insert(prioritized, pattern)
            else
                table.insert(remaining, pattern)
            end
        end

        -- Return compile_commands.json first, then others
        vim.list_extend(prioritized, remaining)
        return prioritized
    end

    return patterns
end

-- Find root directory based on patterns by searching upward through directory tree
function M.find_project_root(host, path, root_patterns, server_name)
    if not root_patterns or #root_patterns == 0 then
        return vim.fn.fnamemodify(path, ":h")
    end

    -- Check cache first
    local cached_root = get_cached_root(host, path, root_patterns)
    if cached_root then
        return cached_root
    end

    -- Ensure we have an absolute path for SSH commands
    local absolute_path = path
    if not absolute_path:match("^/") then
        absolute_path = "/" .. absolute_path
    end
    -- Clean up multiple slashes
    absolute_path = absolute_path:gsub("//+", "/")

    -- Start from the directory containing the file
    local current_dir = vim.fn.fnamemodify(absolute_path, ":h")

    -- Get prioritized patterns for server-specific optimization
    local prioritized_patterns = get_prioritized_patterns(root_patterns, server_name)

    log("Searching for project root starting from: " .. current_dir .. " with patterns: " .. vim.inspect(prioritized_patterns), vim.log.levels.DEBUG, false, config.config)
    log("Original path: " .. path .. " -> Absolute path: " .. absolute_path, vim.log.levels.DEBUG, false, config.config)

    -- Special handling for Rust workspaces: prioritize finding .git + Cargo.toml combination
    local is_rust_project = vim.tbl_contains(root_patterns, "Cargo.toml")
    if is_rust_project then
        log("Detected Rust project, using workspace-aware root detection", vim.log.levels.DEBUG, false, config.config)
        local workspace_root = M.find_rust_workspace_root(host, current_dir)
        if workspace_root then
            log("Found Rust workspace root at: " .. workspace_root, vim.log.levels.DEBUG, false, config.config)
            cache_project_root(host, path, root_patterns, workspace_root)
            return workspace_root
        end
        log("No Rust workspace root found, falling back to standard detection", vim.log.levels.DEBUG, false, config.config)
    end

    -- Standard search upward through directory tree (up to 10 levels)
    local search_dir = current_dir
    for level = 1, 10 do
        log("Level " .. level .. " - Searching in: " .. search_dir, vim.log.levels.DEBUG, false, config.config)

        -- Use batch checking for better performance
        local found_patterns = batch_check_patterns(host, search_dir, prioritized_patterns)

        if #found_patterns > 0 then
            -- Found root marker(s) in this directory
            log("Found project root at: " .. search_dir .. " (found: " .. table.concat(found_patterns, ", ") .. ")", vim.log.levels.DEBUG, false, config.config)
            cache_project_root(host, path, root_patterns, search_dir)
            return search_dir
        end

        -- Move up one directory level
        local parent_dir = vim.fn.fnamemodify(search_dir, ":h")
        if parent_dir == search_dir or parent_dir == "/" or parent_dir == "" then
            -- Reached root or invalid path
            log("Reached filesystem root, stopping search", vim.log.levels.INFO, true, config.config)
            break
        end
        search_dir = parent_dir
    end

    -- If no root markers found after searching upward, use the file's directory
    log("No project root found, using file directory: " .. current_dir, vim.log.levels.DEBUG, false, config.config)
    cache_project_root(host, path, root_patterns, current_dir)
    return current_dir
end

-- Special function to find Rust workspace root (looks for .git + Cargo.toml combination)
function M.find_rust_workspace_root(host, start_dir)
    local search_dir = start_dir

    -- Search upward for directories that contain both .git and Cargo.toml
    for level = 1, 10 do
        log("Rust workspace search level " .. level .. " - Checking: " .. search_dir, vim.log.levels.DEBUG, false, config.config)

        -- Check for .git directory first (repository root)
        local git_cmd = string.format(
            "ssh %s 'cd %s 2>/dev/null && ls -la .git 2>/dev/null'",
            host,
            vim.fn.shellescape(search_dir)
        )

        local git_result = vim.fn.trim(vim.fn.system(git_cmd))
        log("Git check result: '" .. git_result .. "'", vim.log.levels.DEBUG, false, config.config)

        if git_result ~= "" and not git_result:match("No such file") and not git_result:match("cannot access") then
            -- Found .git, now check for Cargo.toml in the same directory
            local cargo_cmd = string.format(
                "ssh %s 'cd %s 2>/dev/null && ls -la Cargo.toml 2>/dev/null'",
                host,
                vim.fn.shellescape(search_dir)
            )

            local cargo_result = vim.fn.trim(vim.fn.system(cargo_cmd))
            log("Cargo.toml check result: '" .. cargo_result .. "'", vim.log.levels.DEBUG, false, config.config)

            if cargo_result ~= "" and not cargo_result:match("No such file") and not cargo_result:match("cannot access") then
                -- Found both .git and Cargo.toml - this is likely the workspace root
                log("Found .git + Cargo.toml at: " .. search_dir, vim.log.levels.DEBUG, false, config.config)
                return search_dir
            else
                -- Found .git but no Cargo.toml - this might be a non-Rust repo or the Cargo.toml is elsewhere
                log("Found .git but no Cargo.toml at: " .. search_dir, vim.log.levels.DEBUG, false, config.config)
            end
        end

        -- Move up one directory level
        local parent_dir = vim.fn.fnamemodify(search_dir, ":h")
        if parent_dir == search_dir or parent_dir == "/" or parent_dir == "" then
            log("Reached filesystem root in Rust workspace search", vim.log.levels.DEBUG, false, config.config)
            break
        end
        search_dir = parent_dir
    end

    return nil -- No workspace root found
end

-- Cache management functions
function M.clear_project_root_cache()
    project_root_cache = {}
    log("Cleared project root cache", vim.log.levels.INFO, true, config.config)
end

function M.get_project_root_cache_stats()
    local cache_size = vim.tbl_count(project_root_cache)
    local valid_entries = 0
    for _, entry in pairs(project_root_cache) do
        if is_cache_valid(entry) then
            valid_entries = valid_entries + 1
        end
    end
    local ttl = config.config.root_cache_ttl or 300
    return {
        total_entries = cache_size,
        valid_entries = valid_entries,
        expired_entries = cache_size - valid_entries,
        ttl_seconds = ttl,
        cache_enabled = config.config.root_cache_enabled
    }
end

-- Fast project root finder that skips expensive SSH calls (for performance)
function M.find_project_root_fast(host, path, root_patterns)
    -- Check cache first
    local cached_root = get_cached_root(host, path, root_patterns)
    if cached_root then
        return cached_root
    end

    -- For fast mode, just use the file's directory without SSH calls
    local absolute_path = path
    if not absolute_path:match("^/") then
        absolute_path = "/" .. absolute_path
    end
    local current_dir = vim.fn.fnamemodify(absolute_path, ":h")

    log("Fast mode: Using file directory as project root: " .. current_dir, vim.log.levels.DEBUG, false, config.config)
    cache_project_root(host, path, root_patterns, current_dir)
    return current_dir
end

-- Get a unique server key based on server name and host
function M.get_server_key(server_name, host)
    return server_name .. "@" .. host
end

-- Function to debug LSP communications
function M.debug_lsp_traffic(enable)
    if enable then
        -- Enable logging of LSP traffic
        vim.lsp.set_log_level("debug")

        -- Log more details about LSP message exchanges
        if vim.fn.has('nvim-0.8') == 1 then
            -- For Neovim 0.8+
            local path = vim.fn.stdpath("cache") .. "/lsp.log"
            vim.lsp.set_log_level("debug")
            vim.cmd("let g:lsp_log_file = " .. vim.inspect(path))
            vim.cmd("lua vim.lsp.log.set_format_func(vim.inspect)")
            log("LSP logging enabled at: " .. path, vim.log.levels.INFO, true, config.config)
        else
            -- For older Neovim
            local path = vim.fn.stdpath("cache") .. "/lsp.log"
            vim.lsp.set_log_level("debug")
            vim.cmd("let g:lsp_log_file = " .. vim.inspect(path))
            log("LSP logging enabled at: " .. path, vim.log.levels.INFO, true, config.config)
        end
    else
        -- Disable verbose logging
        vim.lsp.set_log_level("warn")
        log("LSP debug logging disabled", vim.log.levels.INFO, true, config.config)
    end
end

return M
