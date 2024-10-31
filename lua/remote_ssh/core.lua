-- lua/remote_ssh/core.lua
local Job = require('plenary.job')
local Path = require('plenary.path')

local M = {}

-- Utility functions
local utils = {}
function utils.trim(s)
    return s:match('^%s*(.-)%s*$')
end

function utils.normalize_path(path)
    return path:gsub('\\', '/'):gsub('/+', '/')
end

function utils.parse_ssh_config()
    local config_path = vim.fn.expand('~/.ssh/config')
    if vim.fn.filereadable(config_path) == 0 then
        return {}
    end

    local hosts = {}
    local current_host = nil

    for line in io.lines(config_path) do
        line = utils.trim(line)
        if line:match('^Host ') then
            current_host = utils.trim(line:match('^Host (.+)'))
            hosts[current_host] = {}
        elseif current_host and line:match('^%s*[%w-]+%s+.+') then
            local key, value = line:match('^%s*([%w-]+)%s+(.+)')
            if key and value then
                key = utils.trim(key):lower()
                value = utils.trim(value)
                hosts[current_host][key] = value
            end
        end
    end

    return hosts
end

-- SSH Connection Handler
local SSHConnection = {}
SSHConnection.__index = SSHConnection

function M.new(host, opts)
    local self = setmetatable({}, SSHConnection)
    self.host = host
    self.opts = vim.tbl_deep_extend('force', {
        port = 22,
        identity_file = nil,
        user = nil,
        timeout = 30,
    }, opts or {})

    -- Load SSH config for this host
    local ssh_config = utils.parse_ssh_config()
    if ssh_config[host] then
        self.opts = vim.tbl_deep_extend('force', self.opts, ssh_config[host])
    end

    self.status = 'disconnected'
    self.jobs = {}
    return self
end

function SSHConnection:test_connection()
    local cmd = string.format('ssh -o BatchMode=yes %s echo test', self.host)
    local success, reason, code = os.execute(cmd)
    print("success: " .. tostring(success))
    print("reason: " .. tostring(reason))
    print("code: " .. tostring(code))

    if success then
        self.status = 'connected'
        vim.notify('Successfully connected to ' .. self.host)
        return true
    else
        self.status = 'error'
        vim.notify('Failed to connect to ' .. self.host, vim.log.levels.ERROR)
        return false
    end
end

-- Also simplify the build_ssh_command for other operations
function SSHConnection:build_ssh_command()
    local cmd = {}
    table.insert(cmd, 'ssh')
    table.insert(cmd, '-o')
    table.insert(cmd, 'BatchMode=yes')
    table.insert(cmd, self.host)
    return cmd
end

function SSHConnection:read_file(remote_path, callback)
    local cmd = string.format('ssh -o BatchMode=yes %s cat %s', self.host, vim.fn.shellescape(remote_path))
    local handle = io.popen(cmd, 'r')
    if handle then
        local content = handle:read('*a')
        handle:close()
        if content then
            callback(content, nil)
        else
            callback(nil, 'Failed to read remote file: ' .. remote_path)
        end
    else
        callback(nil, 'Failed to execute remote command')
    end
end

function SSHConnection:list_directory(remote_path, callback)
    local cmd = string.format('ssh -o BatchMode=yes %s ls -la %s', 
        self.host, 
        vim.fn.shellescape(remote_path)
    )
    
    local handle = io.popen(cmd, 'r')
    if handle then
        local output = {}
        for line in handle:lines() do
            table.insert(output, line)
        end
        handle:close()
        
        local files = {}
        -- Skip first line (total) and parse ls output
        for i = 2, #output do
            local line = output[i]
            if line then
                local perms, links, user, group, size, date1, date2, date3, name = 
                    line:match('^([drwx%-]+)%s+(%d+)%s+([^%s]+)%s+([^%s]+)%s+(%d+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+(.+)$')
                
                if perms and name then
                    name = utils.trim(name)
                    table.insert(files, {
                        name = name,
                        type = perms:sub(1,1) == 'd' and 'directory' or 'file',
                        size = tonumber(size),
                        permissions = perms,
                        user = user,
                        group = group,
                    })
                end
            end
        end
        callback(files, nil)
    else
        callback(nil, 'Failed to list directory: ' .. remote_path)
    end
end

function SSHConnection:write_file(remote_path, content, callback)
    -- Create a temporary file with the content
    local tmp_file = vim.fn.tempname()
    local file = io.open(tmp_file, 'w')
    if file then
        file:write(content)
        file:close()
    else
        callback(false, 'Failed to create temporary file')
        return
    end

    -- Build and execute the command to copy the file to remote
    local cmd = string.format('ssh -o BatchMode=yes %s "cat > %s" < %s', 
        self.host, 
        vim.fn.shellescape(remote_path),
        vim.fn.shellescape(tmp_file)
    )
    
    local success, _, code = os.execute(cmd)
    os.remove(tmp_file)
    
    if success then
        callback(true, nil)
    else
        callback(false, 'Failed to write remote file: ' .. remote_path)
    end
end

function SSHConnection:create_remote_buffer(remote_path)
    local buf = vim.api.nvim_create_buf(true, false)
    local display_path = string.format('ssh://%s/%s', self.host, remote_path)
    vim.api.nvim_buf_set_name(buf, display_path)

    -- Set buffer-local options
    vim.api.nvim_buf_set_option(buf, 'buftype', 'acwrite')
    vim.api.nvim_buf_set_option(buf, 'modified', false)

    -- Set up autocommands for this buffer
    local group = vim.api.nvim_create_augroup('RemoteSSH_' .. buf, { clear = true })

    -- Handle buffer writes
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = group,
        buffer = buf,
        callback = function()
            local written = false
            local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
            
            self:write_file(remote_path, content, function(success, err)
                if success then
                    vim.schedule(function()
                        vim.notify('Saved ' .. display_path)
                        vim.api.nvim_buf_set_option(buf, 'modified', false)
                    end)
                    written = true
                else
                    vim.schedule(function()
                        vim.notify('Error saving ' .. display_path .. ': ' .. (err or 'unknown error'), vim.log.levels.ERROR)
                    end)
                    written = false
                end
            end)
            
            return written
        end,
    })

    -- Load initial content
    self:read_file(remote_path, function(content, err)
        if content then
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n'))
                    vim.api.nvim_buf_set_option(buf, 'modified', false)
                end
            end)
        else
            vim.notify('Error reading ' .. display_path .. ': ' .. (err or 'unknown error'), vim.log.levels.ERROR)
        end
    end)

    -- Switch to the buffer
    vim.api.nvim_set_current_buf(buf)

    return buf
end
function SSHConnection:cleanup()
    for _, job in ipairs(self.jobs) do
        job:shutdown()
    end
    self.jobs = {}
    self.status = 'disconnected'
end

return M
