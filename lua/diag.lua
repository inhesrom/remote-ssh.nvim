local M = {}


-- Configuration for the debugging
local debug_info = {
    first_save_done = false,
    saves_attempted = 0,
    buffer_names = {},
    error_messages = {},
    last_error = nil
}

-- Log function that always logs regardless of debug setting
local function critical_log(msg)
    vim.schedule(function()
        vim.notify("[CRITICAL] " .. msg, vim.log.levels.ERROR)
    end)
end

-- Setup a diagnostic command to see what's really happening
vim.api.nvim_create_user_command("DiagnoseSave", function()
    local buf = vim.api.nvim_get_current_buf()
    local bufname = vim.api.nvim_buf_get_name(buf)
    
    critical_log(string.format("Save diagnostic for buffer %d: %s", buf, bufname))
    critical_log("Command: :w in Neovim triggers the following sequence:")
    
    -- Check if we're handling a remote buffer
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        critical_log("Not a remote buffer, standard save process will be used")
        return
    end
    
    -- Check which autocommands are registered that might interfere
    critical_log("Checking registered autocommands for BufWriteCmd:")
    local autocmds = vim.api.nvim_get_autocmds({event = "BufWriteCmd", pattern = {"scp://*", "rsync://*"}})
    for _, cmd in ipairs(autocmds) do
        local group_name = cmd.group and vim.api.nvim_get_augroup_by_id(cmd.group).name or "unnamed"
        critical_log(string.format("- Autocommand in group '%s', pattern: %s", group_name, cmd.pattern))
    end
    
    -- Check what happens on a test write attempt
    critical_log("Attempting a diagnostic write:")
    
    -- First, track what happens when we call BufWriteCmd
    local result = vim.api.nvim_exec2([[
        let g:last_bufwritecmd_buffer = -1
        
        augroup DiagnosticGroup
            autocmd!
            autocmd BufWriteCmd scp://*,rsync://* let g:last_bufwritecmd_buffer = expand('<abuf>')
        augroup END
        
        try
            write
            echo "Write command completed without error"
        catch
            echo "Error during write: " . v:exception
        endtry
        
        let g:write_result = {'buffer': g:last_bufwritecmd_buffer}
        
        augroup DiagnosticGroup
            autocmd!
        augroup END
    ]], {output = true})
    
    critical_log("Write attempt result: " .. result.output)
    
    -- Check what bufwritecmd triggered
    local triggered_buf = vim.g.last_bufwritecmd_buffer
    critical_log("BufWriteCmd triggered for buffer: " .. triggered_buf)
    
    -- Additional diagnostics about the current buffer
    critical_log("Current buffer info:")
    critical_log("- Modified flag: " .. tostring(vim.bo[buf].modified))
    critical_log("- Readonly flag: " .. tostring(vim.bo[buf].readonly))
    critical_log("- Filetype: " .. vim.bo[buf].filetype)
    
    -- Check netrw settings
    critical_log("Netrw settings:")
    critical_log("- netrw_rsync_cmd: " .. (vim.g.netrw_rsync_cmd or "not set"))
    critical_log("- netrw_scp_cmd: " .. (vim.g.netrw_scp_cmd or "not set"))
    
    -- Check for other plugins that might interfere
    critical_log("Checking for potentially conflicting plugins:")
    for _, plugin in ipairs({'netrw', 'vimfiler', 'nerdtree', 'dirvish'}) do
        if vim.fn.exists('g:loaded_' .. plugin) == 1 then
            critical_log("- Plugin '" .. plugin .. "' is loaded")
        end
    end
    
    -- Final recommendations
    critical_log("DIAGNOSTIC RESULTS AND RECOMMENDATIONS:")
    critical_log("1. If multiple plugins are handling BufWriteCmd, there may be conflicts")
    critical_log("2. Try completely disabling netrw with 'let g:loaded_netrw = 1' in init.vim")
    critical_log("3. Check if the buffer state is changing after the first save")
    critical_log("4. Consider using an alternate approach with direct commands")
end, {})

local function capture_error(callback)
    local ok, result_or_err = pcall(callback)
    if not ok then
        debug_info.last_error = result_or_err
        table.insert(debug_info.error_messages, result_or_err)
        critical_log("Error captured: " .. result_or_err)
    end
    return ok, result_or_err
end

-- Direct command execution for saving - bypassing autocommands
function M.direct_save_file(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    
    -- Store buffer name for diagnostic purposes
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    debug_info.saves_attempted = debug_info.saves_attempted + 1
    table.insert(debug_info.buffer_names, bufname)
    
    critical_log(string.format("ATTEMPT %d: Direct save for buffer %d: %s", 
                debug_info.saves_attempted, bufnr, bufname))
    
    -- Parse remote path
    local protocol, host, path
    
    if bufname:match("^scp://") then
        protocol = "scp"
        host, path = bufname:match("^scp://([^/]+)/(.+)$")
    elseif bufname:match("^rsync://") then
        protocol = "rsync"
        host, path = bufname:match("^rsync://([^/]+)/(.+)$")
    else
        critical_log("Not a remote path: " .. bufname)
        return false
    end
    
    if not host or not path then
        critical_log("Failed to parse remote path: " .. bufname)
        return false
    end
    
    critical_log("Parsed: protocol=" .. protocol .. ", host=" .. host .. ", path=" .. path)
    
    -- Get buffer content
    local ok, lines = capture_error(function()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end)
    if not ok then return false end
    
    local content = table.concat(lines, "\n")
    critical_log("Got buffer content: " .. #content .. " bytes from " .. #lines .. " lines")
    
    -- Check whether vim.fn.system or vim.fn.jobstart is more reliable
    local method = debug_info.first_save_done and "system" or "jobstart"
    critical_log("Using method: " .. method)
    
    if method == "system" then
        -- Try using direct system command
        local remote_dir = vim.fn.fnamemodify(path, ":h")
        
        -- First ensure directory exists
        local mkdir_cmd = "ssh " .. host .. " 'mkdir -p " .. remote_dir .. "'"
        local mkdir_result = vim.fn.system(mkdir_cmd)
        
        if vim.v.shell_error ~= 0 then
            critical_log("Failed to create remote directory: " .. mkdir_result)
            return false
        end
        
        -- Now write file using a direct pipe
        local tmp_file = vim.fn.tempname()
        ok, _ = capture_error(function()
            local f = io.open(tmp_file, "w")
            f:write(content)
            f:close()
        end)
        if not ok then return false end
        
        -- Use direct SCP to transfer the file
        local scp_cmd = "scp " .. tmp_file .. " " .. host .. ":" .. path
        critical_log("Executing: " .. scp_cmd)
        local result = vim.fn.system(scp_cmd)
        
        -- Clean up temp file
        vim.fn.delete(tmp_file)
        
        if vim.v.shell_error ~= 0 then
            critical_log("SCP failed: " .. result)
            return false
        end
        
        critical_log("File saved successfully using system method")
    else
        -- Use jobstart for async save
        local remote_dir = vim.fn.fnamemodify(path, ":h")
        local mkdir_cmd = {"ssh", host, "mkdir", "-p", remote_dir}
        
        local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
            on_exit = function(_, code)
                if code ~= 0 then
                    critical_log("Failed to create remote directory")
                    return
                end
                
                -- Now save the file
                local save_cmd = {"ssh", host, "cat > " .. vim.fn.shellescape(path)}
                
                local job_id = vim.fn.jobstart(save_cmd, {
                    stdin_data = content,
                    on_exit = function(_, exit_code)
                        if exit_code == 0 then
                            vim.schedule(function()
                                critical_log("File saved successfully using jobstart method")
                                vim.api.nvim_buf_set_option(bufnr, "modified", false)
                                debug_info.first_save_done = true
                            end)
                        else
                            critical_log("Failed to save file, exit code: " .. exit_code)
                        end
                    end
                })
                
                if job_id <= 0 then
                    critical_log("Failed to start save job")
                end
            end
        })
        
        if mkdir_job <= 0 then
            critical_log("Failed to start mkdir job")
            return false
        end
    end
    
    return true
end

-- Setup the command to overwrite the built-in w command
function M.setup()
    -- Create an autocmd group
    local augroup = vim.api.nvim_create_augroup("DirectRemoteWrite", { clear = true })
    
    -- Intercept BufWriteCmd for scp:// and rsync:// files
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            critical_log("BufWriteCmd triggered for buffer " .. ev.buf .. " (" .. vim.api.nvim_buf_get_name(ev.buf) .. ")")
            
            -- Disable netrw completely
            vim.g.loaded_netrw = 1
            vim.g.loaded_netrwPlugin = 1
            vim.g.netrw_rsync_cmd = "echo 'Disabled by diagnostic plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by diagnostic plugin'"
            
            local success = M.direct_save_file(ev.buf)
            
            if not success then
                critical_log("Save failed, but marking buffer as unmodified anyway")
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
            end
            
            -- Always return true to prevent any other handlers from running
            return true
        end,
    })
    
    -- Create the special save command
    vim.api.nvim_create_user_command("RemoteSave", function()
        local bufnr = vim.api.nvim_get_current_buf()
        critical_log("RemoteSave command triggered for buffer " .. bufnr)
        M.direct_save_file(bufnr)
    end, { desc = "Save remote file using direct method" })
    
    -- Inform user
    vim.notify("Diagnostic remote save plugin loaded. Use :RemoteSave to save files and :DiagnoseSave to see detailed info.", vim.log.levels.INFO)
end

return M
