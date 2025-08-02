local M = {}

local ssh_utils = require('async-remote-write.ssh_utils')
local log = require('logging').log

-- Cache for Git repository information
local repo_cache = {}
local cache_ttl = 300 -- 5 minutes

-- Find Git root directory on remote host
function M.find_git_root(host, file_path)
    local cache_key = host .. ":" .. file_path
    local cached = repo_cache[cache_key]
    
    -- Check cache first
    if cached and (os.time() - cached.timestamp) < cache_ttl then
        log("Using cached git root for " .. cache_key .. ": " .. (cached.git_root or "none"), vim.log.levels.DEBUG, false)
        return cached.git_root
    end
    
    log("Finding git root for " .. host .. ":" .. file_path, vim.log.levels.DEBUG, false)
    
    local dir = vim.fs.dirname(file_path)
    local git_root = nil
    
    -- Keep going up until we find .git or reach root
    local attempts = 0
    local max_attempts = 20 -- Prevent infinite loops
    
    while dir and dir ~= "/" and dir ~= "" and attempts < max_attempts do
        attempts = attempts + 1
        
        -- Check if this directory has a .git subdirectory or file
        local check_cmd = string.format(
            '[ -d %s/.git ] || [ -f %s/.git ] && echo "found" || echo "notfound"',
            vim.fn.shellescape(dir),
            vim.fn.shellescape(dir)
        )
        
        local ssh_cmd = ssh_utils.build_ssh_cmd(host, check_cmd)
        local result = vim.system(ssh_cmd, { text = true, timeout = 5000 }):wait()
        
        if result.code == 0 and result.stdout and vim.trim(result.stdout) == "found" then
            git_root = dir
            log("Found git root: " .. git_root, vim.log.levels.DEBUG, false)
            break
        end
        
        -- Go up one directory
        local parent = vim.fs.dirname(dir)
        if parent == dir then
            -- We've reached the root
            break
        end
        dir = parent
    end
    
    -- Cache the result (even if nil)
    repo_cache[cache_key] = {
        git_root = git_root,
        timestamp = os.time()
    }
    
    if git_root then
        log("Git root found for " .. file_path .. ": " .. git_root, vim.log.levels.INFO, false)
    else
        log("No git root found for " .. file_path, vim.log.levels.DEBUG, false)
    end
    
    return git_root
end

-- Get Git repository info from remote host
function M.get_repo_info(host, workdir)
    local cache_key = host .. ":" .. workdir .. ":repo_info"
    local cached = repo_cache[cache_key]
    
    -- Check cache first
    if cached and (os.time() - cached.timestamp) < cache_ttl then
        log("Using cached repo info for " .. cache_key, vim.log.levels.DEBUG, false)
        return cached.info
    end
    
    log("Getting repo info for " .. host .. ":" .. workdir, vim.log.levels.DEBUG, false)
    
    local info_cmd = table.concat({
        'cd', vim.fn.shellescape(workdir), '&&',
        'git', 'rev-parse',
        '--show-toplevel',
        '--git-dir',
        '--abbrev-ref', 'HEAD', '2>/dev/null || echo "HEAD"'
    }, ' ')
    
    local ssh_cmd = ssh_utils.build_ssh_cmd(host, info_cmd)
    local result = vim.system(ssh_cmd, { text = true, timeout = 10000 }):wait()
    
    local info = nil
    if result.code == 0 and result.stdout then
        local lines = vim.split(result.stdout, '\n')
        -- Filter out empty lines
        local filtered_lines = {}
        for _, line in ipairs(lines) do
            line = vim.trim(line)
            if line ~= '' then
                table.insert(filtered_lines, line)
            end
        end
        
        if #filtered_lines >= 3 then
            info = {
                toplevel = filtered_lines[1],
                gitdir = filtered_lines[2],
                head = filtered_lines[3] or 'HEAD'
            }
            log("Got repo info - toplevel: " .. info.toplevel .. ", head: " .. info.head, vim.log.levels.DEBUG, false)
        else
            log("Insufficient repo info received: " .. vim.inspect(filtered_lines), vim.log.levels.WARN, false)
        end
    else
        log("Failed to get repo info: " .. (result.stderr or "unknown error"), vim.log.levels.WARN, false)
    end
    
    -- Cache the result
    repo_cache[cache_key] = {
        info = info,
        timestamp = os.time()
    }
    
    return info
end

-- Execute git command and return parsed output (compatible with gitsigns expectations)
function M.execute_git_command(host, workdir, args, opts)
    opts = opts or {}
    
    log("Executing git command: " .. table.concat(args, ' ') .. " in " .. workdir, vim.log.levels.DEBUG, false)
    
    -- Build git command with proper directory change
    local git_cmd = {
        'cd', vim.fn.shellescape(workdir), '&&',
        'git'
    }
    
    -- Add the git arguments
    vim.list_extend(git_cmd, args)
    
    local command = table.concat(git_cmd, ' ')
    local ssh_cmd = ssh_utils.build_ssh_cmd(host, command)
    
    local result = vim.system(ssh_cmd, {
        text = opts.text ~= false,
        timeout = opts.timeout or 30000,
    }):wait()
    
    -- Handle errors appropriately
    if not opts.ignore_error and result.code > 0 then
        log("Git command failed with code " .. result.code .. ": " .. (result.stderr or ""), vim.log.levels.ERROR, false)
    end
    
    -- Process stdout into lines as gitsigns expects
    local stdout_lines = {}
    if result.stdout then
        stdout_lines = vim.split(result.stdout, '\n')
        -- Remove final empty line if present
        if #stdout_lines > 0 and stdout_lines[#stdout_lines] == '' then
            table.remove(stdout_lines)
        end
    end
    
    log("Git command completed with " .. #stdout_lines .. " lines of output", vim.log.levels.DEBUG, false)
    
    return {
        stdout = stdout_lines,
        stderr = result.stderr,
        code = result.code
    }
end

-- Check if a remote path is in a Git repository
function M.is_git_repo(host, file_path)
    local git_root = M.find_git_root(host, file_path)
    return git_root ~= nil, git_root
end

-- Get git status for a file
function M.get_file_status(host, workdir, file_path)
    -- Make path relative to workdir
    local rel_path = file_path
    if vim.startswith(file_path, workdir) then
        rel_path = file_path:sub(#workdir + 2) -- +2 to skip the trailing slash
    end
    
    local result = M.execute_git_command(host, workdir, {
        'status', '--porcelain', '--', rel_path
    }, { ignore_error = true })
    
    if result.code == 0 and #result.stdout > 0 then
        local status_line = result.stdout[1]
        if status_line and #status_line >= 2 then
            return {
                index = status_line:sub(1, 1),
                working = status_line:sub(2, 2),
                path = status_line:sub(4) -- Skip the space
            }
        end
    end
    
    return nil
end

-- Get git show output for a file (for diff comparison)
function M.get_file_at_revision(host, workdir, file_path, revision)
    revision = revision or 'HEAD'
    
    -- Make path relative to workdir
    local rel_path = file_path
    if vim.startswith(file_path, workdir) then
        rel_path = file_path:sub(#workdir + 2)
    end
    
    local result = M.execute_git_command(host, workdir, {
        'show', revision .. ':' .. rel_path
    }, { ignore_error = true, text = false })
    
    if result.code == 0 then
        return result.stdout
    end
    
    return nil
end

-- Clear cache (useful for testing or manual refresh)
function M.clear_cache()
    repo_cache = {}
    log("Cleared git repository cache", vim.log.levels.DEBUG, false)
end

-- Get cache statistics
function M.get_cache_stats()
    local count = 0
    local expired = 0
    local now = os.time()
    
    for _, cached in pairs(repo_cache) do
        count = count + 1
        if (now - cached.timestamp) >= cache_ttl then
            expired = expired + 1
        end
    end
    
    return {
        total = count,
        expired = expired,
        ttl = cache_ttl
    }
end

return M