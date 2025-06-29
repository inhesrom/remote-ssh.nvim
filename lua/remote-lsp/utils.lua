local M = {}

local config = require('remote-lsp.config')
local log = require('logging').log

-- Function to get the directory of the current Lua script
function M.get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
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

-- Find root directory based on patterns by searching upward through directory tree
function M.find_project_root(host, path, root_patterns)
    if not root_patterns or #root_patterns == 0 then
        return vim.fn.fnamemodify(path, ":h")
    end

    -- Ensure we have an absolute path for SSH commands
    local absolute_path = path
    if not absolute_path:match("^/") then
        absolute_path = "/" .. absolute_path
    end

    -- Start from the directory containing the file
    local current_dir = vim.fn.fnamemodify(absolute_path, ":h")
    
    log("Searching for project root starting from: " .. current_dir .. " with patterns: " .. vim.inspect(root_patterns), vim.log.levels.INFO, true, config.config)
    log("Original path: " .. path .. " -> Absolute path: " .. absolute_path, vim.log.levels.INFO, true, config.config)
    
    -- Special handling for Rust workspaces: prioritize finding .git + Cargo.toml combination
    local is_rust_project = vim.tbl_contains(root_patterns, "Cargo.toml")
    if is_rust_project then
        log("Detected Rust project, using workspace-aware root detection", vim.log.levels.INFO, true, config.config)
        local workspace_root = M.find_rust_workspace_root(host, current_dir)
        if workspace_root then
            log("✅ Found Rust workspace root at: " .. workspace_root, vim.log.levels.INFO, true, config.config)
            return workspace_root
        end
        log("No Rust workspace root found, falling back to standard detection", vim.log.levels.INFO, true, config.config)
    end
    
    -- Standard search upward through directory tree (up to 10 levels)
    local search_dir = current_dir
    for level = 1, 10 do
        log("Level " .. level .. " - Searching in: " .. search_dir, vim.log.levels.INFO, true, config.config)
        
        -- Check each pattern individually with a simple ls command
        for _, pattern in ipairs(root_patterns) do
            local job_cmd = string.format(
                "ssh %s 'cd %s 2>/dev/null && ls -la %s 2>/dev/null'",
                host,
                vim.fn.shellescape(search_dir),
                vim.fn.shellescape(pattern)
            )
            
            log("SSH Command: " .. job_cmd, vim.log.levels.INFO, true, config.config)
            local result = vim.fn.trim(vim.fn.system(job_cmd))
            log("Result for " .. pattern .. ": '" .. result .. "'", vim.log.levels.INFO, true, config.config)
            
            if result ~= "" and not result:match("No such file") and not result:match("cannot access") then
                -- Found a root marker in this directory
                log("✅ Found project root at: " .. search_dir .. " (found: " .. pattern .. ")", vim.log.levels.INFO, true, config.config)
                return search_dir
            end
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
    return current_dir
end

-- Special function to find Rust workspace root (looks for .git + Cargo.toml combination)
function M.find_rust_workspace_root(host, start_dir)
    local search_dir = start_dir
    
    -- Search upward for directories that contain both .git and Cargo.toml
    for level = 1, 10 do
        log("Rust workspace search level " .. level .. " - Checking: " .. search_dir, vim.log.levels.INFO, true, config.config)
        
        -- Check for .git directory first (repository root)
        local git_cmd = string.format(
            "ssh %s 'cd %s 2>/dev/null && ls -la .git 2>/dev/null'",
            host,
            vim.fn.shellescape(search_dir)
        )
        
        local git_result = vim.fn.trim(vim.fn.system(git_cmd))
        log("Git check result: '" .. git_result .. "'", vim.log.levels.INFO, true, config.config)
        
        if git_result ~= "" and not git_result:match("No such file") and not git_result:match("cannot access") then
            -- Found .git, now check for Cargo.toml in the same directory
            local cargo_cmd = string.format(
                "ssh %s 'cd %s 2>/dev/null && ls -la Cargo.toml 2>/dev/null'",
                host,
                vim.fn.shellescape(search_dir)
            )
            
            local cargo_result = vim.fn.trim(vim.fn.system(cargo_cmd))
            log("Cargo.toml check result: '" .. cargo_result .. "'", vim.log.levels.INFO, true, config.config)
            
            if cargo_result ~= "" and not cargo_result:match("No such file") and not cargo_result:match("cannot access") then
                -- Found both .git and Cargo.toml - this is likely the workspace root
                log("Found .git + Cargo.toml at: " .. search_dir, vim.log.levels.INFO, true, config.config)
                return search_dir
            else
                -- Found .git but no Cargo.toml - this might be a non-Rust repo or the Cargo.toml is elsewhere
                log("Found .git but no Cargo.toml at: " .. search_dir, vim.log.levels.INFO, true, config.config)
            end
        end
        
        -- Move up one directory level
        local parent_dir = vim.fn.fnamemodify(search_dir, ":h")
        if parent_dir == search_dir or parent_dir == "/" or parent_dir == "" then
            log("Reached filesystem root in Rust workspace search", vim.log.levels.INFO, true, config.config)
            break
        end
        search_dir = parent_dir
    end
    
    return nil -- No workspace root found
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
