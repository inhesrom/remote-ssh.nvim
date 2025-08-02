local M = {}

local ssh_utils = require('async-remote-write.ssh_utils')
local utils = require('async-remote-write.utils')
local log = require('logging').log

-- Store original gitsigns git command function
local original_git_command = nil
local is_hooked = false

-- Map of buffer numbers to remote info for fast lookups
local buffer_remote_info = {}

-- Map of working directories to remote info
local cwd_remote_info = {}

-- Execute git command on remote host
local function execute_remote_git_command(remote_info, args, spec)
    spec = spec or {}
    
    -- Build git command - ensure we're in the right directory
    local git_args = vim.deepcopy(args)
    
    -- Add git-specific flags that gitsigns expects
    local git_cmd = {
        'cd', vim.fn.shellescape(remote_info.remote_workdir), '&&',
        'git',
        '--no-pager',
        '--no-optional-locks',
        '--literal-pathspecs',
        '-c', 'gc.auto=0'
    }
    
    -- Add the actual git command arguments
    vim.list_extend(git_cmd, git_args)
    
    local command = table.concat(git_cmd, ' ')
    
    log("Executing remote git command: " .. command, vim.log.levels.DEBUG, false)
    
    -- Use existing SSH infrastructure
    local ssh_cmd = ssh_utils.build_ssh_cmd(remote_info.host, command)
    
    -- Execute synchronously as gitsigns expects
    local result = vim.system(ssh_cmd, {
        cwd = spec.cwd,
        timeout = spec.timeout or 30000,
        text = spec.text ~= false,
    }):wait()
    
    -- Process output like gitsigns expects
    local stdout_lines = {}
    if result.stdout then
        stdout_lines = vim.split(result.stdout, '\n')
        -- Remove final empty line if present (gitsigns expects this)
        if #stdout_lines > 0 and stdout_lines[#stdout_lines] == '' then
            table.remove(stdout_lines)
        end
    end
    
    -- Handle errors as gitsigns expects
    if not spec.ignore_error and result.code > 0 then
        log("Git command failed with code " .. result.code .. ": " .. (result.stderr or ""), vim.log.levels.ERROR, false)
    end
    
    local stderr = result.stderr
    if stderr == '' then
        stderr = nil
    end
    
    log("Git command completed with " .. #stdout_lines .. " lines of output", vim.log.levels.DEBUG, false)
    
    return stdout_lines, stderr, result.code
end

-- Hook into gitsigns git command execution
function M.setup_git_command_hook()
    -- Only hook if gitsigns is available and not already hooked
    if is_hooked then
        log("Git command hook already installed", vim.log.levels.DEBUG, false)
        return true
    end
    
    local ok, gitsigns_git_cmd_module = pcall(require, 'gitsigns.git.cmd')
    if not ok then
        log("gitsigns.git.cmd module not found", vim.log.levels.WARN, false)
        return false
    end
    
    -- Store original function (gitsigns.git.cmd is the function itself)
    original_git_command = gitsigns_git_cmd_module
    
    -- Create our adapter function
    local function git_command_adapter(args, spec)
        spec = spec or {}
        
        -- Check if this is for a remote buffer by checking the cwd
        local cwd = spec.cwd
        if not cwd then
            -- Try to get cwd from current context
            cwd = vim.loop.cwd()
        end
        
        local remote_info = cwd_remote_info[cwd]
        
        -- Also check current buffer if no cwd match (safely)
        if not remote_info then
            -- Avoid nvim_get_current_buf() in fast event context
            -- Instead, rely on cwd-based detection which is more reliable anyway
            log("No remote info found for cwd: " .. tostring(cwd), vim.log.levels.DEBUG, false)
        end
        
        if remote_info then
            log("Routing git command through remote adapter for " .. remote_info.host, vim.log.levels.DEBUG, false)
            -- Route through remote execution
            return execute_remote_git_command(remote_info, args, spec)
        else
            log("Using local git command execution", vim.log.levels.DEBUG, false)
            -- Use original local execution
            return original_git_command(args, spec)
        end
    end
    
    -- Replace the git command module
    -- We need to modify the package.loaded entry to intercept all requires
    package.loaded['gitsigns.git.cmd'] = git_command_adapter
    
    is_hooked = true
    log("Successfully hooked gitsigns git command execution", vim.log.levels.INFO, false)
    
    return true
end

-- Register remote buffer for git operations
function M.register_remote_buffer(bufnr, remote_info)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local parsed = utils.parse_remote_path(bufname)
    
    if not parsed then
        log("Failed to parse remote path: " .. bufname, vim.log.levels.ERROR, false)
        return false
    end
    
    -- Store buffer-specific remote info
    buffer_remote_info[bufnr] = {
        host = parsed.host,
        remote_path = parsed.path,
        remote_workdir = remote_info.git_root,
        protocol = parsed.protocol
    }
    
    -- Also store by potential working directory paths that gitsigns might use
    local potential_cwds = {
        remote_info.git_root,     -- Git root directory (most important)
        vim.fs.dirname(parsed.path), -- Directory of remote path
        parsed.path,              -- Full remote path
        bufname,                  -- Full buffer name
    }
    
    for _, cwd in ipairs(potential_cwds) do
        if cwd and cwd ~= '' then
            cwd_remote_info[cwd] = buffer_remote_info[bufnr]
        end
    end
    
    log("Registered remote buffer " .. bufnr .. " with git root: " .. remote_info.git_root, vim.log.levels.DEBUG, false)
    
    return true
end

-- Unregister remote buffer
function M.unregister_remote_buffer(bufnr)
    local remote_info = buffer_remote_info[bufnr]
    if remote_info then
        -- Remove from cwd mappings
        for cwd, info in pairs(cwd_remote_info) do
            if info == remote_info then
                cwd_remote_info[cwd] = nil
            end
        end
        
        -- Remove buffer mapping
        buffer_remote_info[bufnr] = nil
        
        log("Unregistered remote buffer " .. bufnr, vim.log.levels.DEBUG, false)
    end
end

-- Get remote info for buffer (for debugging)
function M.get_remote_info(bufnr)
    return buffer_remote_info[bufnr]
end

-- Debug function to get all registered mappings
function M.get_debug_info()
    return {
        buffer_remote_info = buffer_remote_info,
        cwd_remote_info = cwd_remote_info,
        is_hooked = is_hooked,
        has_original = original_git_command ~= nil
    }
end

-- Check if adapter is active
function M.is_active()
    return is_hooked
end

-- Reset the adapter (for testing)
function M.reset()
    if original_git_command then
        package.loaded['gitsigns.git.cmd'] = original_git_command
    end
    
    buffer_remote_info = {}
    cwd_remote_info = {}
    is_hooked = false
    original_git_command = nil
    
    log("Reset git adapter", vim.log.levels.DEBUG, false)
end

return M