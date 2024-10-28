-- plugin/remote_ssh_core.lua
local Job = require('plenary.job')
local Path = require('plenary.path')
local scan = require('plenary.scandir')
local M = {}

-- Utility functions for path handling
local utils = {}
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
        line = line:trim()
        if line:match('^Host ') then
            current_host = line:match('^Host (.+)'):trim()
            hosts[current_host] = {}
        elseif current_host and line:match('^%s*[%w-]+%s+.+') then
            local key, value = line:match('^%s*([%w-]+)%s+(.+)')
            hosts[current_host][key:lower()] = value:trim()
        end
    end
    
    return hosts
end

-- SSH Connection Handler
M.SSHConnection = {}
M.SSHConnection.__index = M.SSHConnection

function M.SSHConnection.new(host, opts)
    local self = setmetatable({}, M.SSHConnection)
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

function M.SSHConnection:build_ssh_command()
    local cmd = {'ssh'}
    
    -- Add SSH options
    table.insert(cmd, '-o', 'BatchMode=yes')  -- Don't ask for passwords
    table.insert(cmd, '-o', 'ConnectTimeout=' .. self.opts.timeout)
    
    if self.opts.port ~= 22 then
        table.insert(cmd, '-p', tostring(self.opts.port))
    end
    
    if self.opts.identity_file then
        table.insert(cmd, '-i', self.opts.identity_file)
    end
    
    -- Build host string
    local host_string = self.host
    if self.opts.user then
        host_string = self.opts.user .. '@' .. host_string
    end
    
    table.insert(cmd, host_string)
    return cmd
end

function M.SSHConnection:test_connection()
    return Job:new({
        command = self:build_ssh_command()[1],
        args = vim.list_slice(self:build_ssh_command(), 2),
        on_exit = function(j, code)
            if code == 0 then
                self.status = 'connected'
                vim.notify('Successfully connected to ' .. self.host)
            else
                self.status = 'error'
                vim.notify('Failed to connect to ' .. self.host, vim.log.levels.ERROR)
            end
        end,
    }):sync()
end

-- File System Operations
function M.SSHConnection:read_file(remote_path, callback)
    local cmd = self:build_ssh_command()
    table.insert(cmd, 'cat')
    table.insert(cmd, remote_path)
    
    local output = {}
    local job = Job:new({
        command = cmd[1],
        args = vim.list_slice(cmd, 2),
        on_stdout = function(_, data)
            table.insert(output, data)
        end,
        on_exit = function(j, code)
            if code == 0 then
                callback(table.concat(output, '\n'), nil)
            else
                callback(nil, 'Failed to read remote file: ' .. remote_path)
            end
        end,
    })
    
    table.insert(self.jobs, job)
    job:start()
end

function M.SSHConnection:write_file(remote_path, content, callback)
    local tmp_file = Path:new(vim.fn.tempname())
    tmp_file:write(content, 'w')
    
    local cmd = self:build_ssh_command()
    -- Use cat and redirection to handle special characters in content
    table.insert(cmd, 'cat > ' .. vim.fn.shellescape(remote_path))
    
    local job = Job:new({
        command = cmd[1],
        args = vim.list_slice(cmd, 2),
        writer = tmp_file:read(),
        on_exit = function(j, code)
            os.remove(tmp_file.filename)
            if code == 0 then
                callback(true, nil)
            else
                callback(false, 'Failed to write remote file: ' .. remote_path)
            end
        end,
    })
    
    table.insert(self.jobs, job)
    job:start()
end

function M.SSHConnection:list_directory(remote_path, callback)
    local cmd = self:build_ssh_command()
    table.insert(cmd, 'ls -la')
    table.insert(cmd, remote_path)
    
    local output = {}
    local job = Job:new({
        command = cmd[1],
        args = vim.list_slice(cmd, 2),
        on_stdout = function(_, data)
            table.insert(output, data)
        end,
        on_exit = function(j, code)
            if code == 0 then
                local files = {}
                -- Skip first line (total) and parse ls output
                for i = 2, #output do
                    local line = output[i]
                    local perms, links, user, group, size, date, name = 
                        line:match('^(.-)%s+(%d+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%S+%s+%S+%s+%S+)%s+(.+)$')
                    if perms and name then
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
                callback(files, nil)
            else
                callback(nil, 'Failed to list directory: ' .. remote_path)
            end
        end,
    })
    
    table.insert(self.jobs, job)
    job:start()
end

-- Buffer integration
function M.SSHConnection:create_remote_buffer(remote_path)
    local buf = vim.api.nvim_create_buf(true, false)
    local display_path = string.format('ssh://%s/%s', self.host, remote_path)
    vim.api.nvim_buf_set_name(buf, display_path)
    
    -- Set buffer-local options
    vim.api.nvim_buf_set_option(buf, 'buftype', 'acwrite')
    
    -- Set up autocommands for this buffer
    local group = vim.api.nvim_create_augroup('RemoteSSH_' .. buf, { clear = true })
    
    -- Handle buffer writes
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = group,
        buffer = buf,
        callback = function()
            local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
            self:write_file(remote_path, content, function(success, err)
                if success then
                    vim.notify('Saved ' .. display_path)
                    vim.api.nvim_buf_set_option(buf, 'modified', false)
                else
                    vim.notify('Error saving ' .. display_path .. ': ' .. (err or 'unknown error'), vim.log.levels.ERROR)
                end
            end)
            return true
        end,
    })
    
    -- Load initial content
    self:read_file(remote_path, function(content, err)
        if content then
            vim.schedule(function()
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n'))
                vim.api.nvim_buf_set_option(buf, 'modified', false)
            end)
        else
            vim.notify('Error reading ' .. display_path .. ': ' .. (err or 'unknown error'), vim.log.levels.ERROR)
        end
    end)
    
    return buf
end

function M.SSHConnection:cleanup()
    for _, job in ipairs(self.jobs) do
        job:shutdown()
    end
    self.jobs = {}
    self.status = 'disconnected'
end

return M
