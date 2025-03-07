local M = {}

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp, ...}
local active_writes = {}

-- Configuration
local config = {
    timeout = 30,          -- Default timeout in seconds
    debug = true,          -- Debug mode enabled by default
    check_interval = 1000, -- Status check interval in ms
}

-- LSP integration callbacks
local lsp_integration = {
    notify_save_start = function(bufnr) end,
    notify_save_end = function(bufnr) end
}

-- Function to get protocol and details from buffer name
local function parse_remote_path(bufname)
    local protocol
    if bufname:match("^scp://") then
        protocol = "scp"
    elseif bufname:match("^rsync://") then
        protocol = "rsync"
    else
        return nil
    end

    -- Match host and path
    local pattern = "^" .. protocol .. "://([^/]+)/(.+)$"
    local host, path = bufname:match(pattern)
    
    -- If that fails, try an alternative pattern for double slashes
    if not host or not path then
        local alt_pattern = "^" .. protocol .. "://([^/]+)//(.+)$"
        host, path = bufname:match(alt_pattern)
        
        -- If we matched with the alternative pattern, ensure path starts with '/'
        if host and path and not path:match("^/") then
            path = "/" .. path
        end
    end
    
    if not host or not path then
        return nil
    end

    -- Clean up path (remove any double slashes)
    path = path:gsub("//+", "/")

    return {
        protocol = protocol,
        host = host,
        path = path,
        full = bufname
    }
end

-- Log function that respects debug mode
local function log(msg, level)
    level = level or vim.log.levels.DEBUG
    if config.debug or level > vim.log.levels.DEBUG then
        vim.schedule(function()
            vim.notify("[AsyncWrite] " .. msg, level)
        end)
    end
end

-- Show a notification in the status line
local function notify(msg, level)
    vim.schedule(function()
        level = level or vim.log.levels.INFO
        vim.notify(msg, level)

        -- Update the status line if possible
        pcall(function()
            if vim.o.laststatus >= 2 then  -- Status line is visible
                vim.cmd("redrawstatus")
            end
        end)
    end)
end

-- Safely close a timer
local function safe_close_timer(timer)
    if timer then
        pcall(function()
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end)
    end
end

-- Function to handle write completion
local function on_write_complete(bufnr, job_id, exit_code, error_msg)
    -- Get current write info and validate
    local write_info = active_writes[bufnr]
    if not write_info then
        log("No active write found for buffer " .. bufnr, vim.log.levels.WARN)
        return
    end

    if write_info.job_id ~= job_id then
        log("Job ID mismatch for buffer " .. bufnr, vim.log.levels.WARN)
        return
    end

    -- Check if buffer still exists
    local buffer_exists = vim.api.nvim_buf_is_valid(bufnr)
    log(string.format("Write complete for buffer %d with exit code %d (buffer exists: %s)", 
                    bufnr, exit_code, tostring(buffer_exists)), vim.log.levels.INFO)

    -- Stop timer if it exists
    if write_info.timer then
        safe_close_timer(write_info.timer)
        write_info.timer = nil
    end
    
    -- Store essential info before removing the write
    local buffer_name = write_info.buffer_name
    local start_time = write_info.start_time
    
    -- Capture LSP client info if buffer still exists
    local lsp_clients = {}
    if buffer_exists then
        local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
        for _, client in ipairs(clients) do
            table.insert(lsp_clients, client.id)
        end
    end

    -- Remove from active writes table
    active_writes[bufnr] = nil

    -- Notify LSP module that save is complete
    vim.schedule(function()
        lsp_integration.notify_save_end(bufnr)
        
        -- Verify LSP connection still exists
        if #lsp_clients > 0 and buffer_exists then
            -- Double-check LSP clients are still attached
            local current_clients = vim.lsp.get_active_clients({ bufnr = bufnr })
            if #current_clients == 0 then
                log("LSP clients were disconnected during save, attempting to reconnect", vim.log.levels.WARN)
                
                -- Attempt to restart LSP
                local remote_ssh = require("remote-ssh")
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        remote_ssh.start_remote_lsp(bufnr)
                    end
                end, 100)
            end
        end
    end)

    -- Handle success or failure
    if exit_code == 0 then
        -- Calculate duration
        local duration = os.time() - start_time
        local duration_str = duration > 1 and (duration .. "s") or "less than a second"

        -- Mark buffer as saved if it still exists
        vim.schedule(function()
            if buffer_exists then
                -- Set buffer as not modified
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)

                -- Update status line
                local short_name = vim.fn.fnamemodify(buffer_name, ":t")
                notify(string.format("✓ File '%s' saved in %s", short_name, duration_str))
            else
                notify(string.format("✓ File saved in %s (buffer no longer exists)", duration_str))
            end
        end)
    else
        local error_info = error_msg or ""
        vim.schedule(function()
            if buffer_exists then
                local short_name = vim.fn.fnamemodify(buffer_name, ":t")
                notify(string.format("❌ Failed to save '%s': %s", short_name, error_info), vim.log.levels.ERROR)
            else
                notify(string.format("❌ Failed to save file: %s", error_info), vim.log.levels.ERROR)
            end
        end)
    end
end

-- Set up a timer to monitor job progress
local function setup_job_timer(bufnr)
    local timer = vim.loop.new_timer()

    -- Check job status regularly
    timer:start(1000, config.check_interval, vim.schedule_wrap(function()
        local write_info = active_writes[bufnr]
        if not write_info then
            safe_close_timer(timer)
            return
        end

        -- Update elapsed time
        local elapsed = os.time() - write_info.start_time
        write_info.elapsed = elapsed

        -- Check if job is still running
        local job_running = vim.fn.jobwait({write_info.job_id}, 0)[1] == -1

        if not job_running then
            -- Job finished but callback wasn't triggered
            log("Job finished but callback wasn't triggered, forcing completion", vim.log.levels.WARN)
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 0)
            end)
            safe_close_timer(timer)
        elseif elapsed > config.timeout then
            -- Job timed out
            log("Job timed out after " .. elapsed .. " seconds", vim.log.levels.WARN)
            pcall(vim.fn.jobstop, write_info.job_id)
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 1, "Timeout after " .. elapsed .. " seconds")
            end)
            safe_close_timer(timer)
        end
    end))

    return timer
end

-- NEW APPROACH: Direct streaming to remote host
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    
    -- Validate buffer first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Cannot save invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return true
    end

    -- Ensure 'buftype' is 'acwrite' to trigger BufWriteCmd
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
    if buftype ~= 'acwrite' then
        log("Buffer type is not 'acwrite', resetting it for buffer " .. bufnr, vim.log.levels.WARN)
        vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
    end

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Check if there's already a write in progress
    if active_writes[bufnr] then
        local elapsed = os.time() - active_writes[bufnr].start_time
        if elapsed > config.timeout / 2 then
            log("Previous write may be stuck (running for " .. elapsed .. "s), forcing completion", vim.log.levels.WARN)
            M.force_complete(bufnr, true)
        else
            vim.schedule(function()
                notify("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN)
            end)
            return true
        end
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false  -- Not a remote path we can handle
    end

    log("Starting save for buffer " .. bufnr .. ": " .. bufname, vim.log.levels.INFO)

    -- Parse remote path
    local remote_path = parse_remote_path(bufname)
    if not remote_path then
        vim.schedule(function()
            log("Not a valid remote path: " .. bufname, vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Notify LSP immediately that we're saving
    lsp_integration.notify_save_start(bufnr)

    -- Visual feedback for user
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            local short_name = vim.fn.fnamemodify(bufname, ":t")
            notify(string.format("💾 Saving '%s' in background...", short_name))
        end
    end)

    -- Get buffer content
    local content = ""
    local ok, err = pcall(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            error("Buffer is no longer valid")
        end
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        content = table.concat(lines, "\n")
    end)

    if not ok then
        vim.schedule(function()
            log("Failed to get buffer content: " .. tostring(err), vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Start the save process
    local start_time = os.time()

    -- Prepare directory on remote host
    local remote_dir = vim.fn.fnamemodify(remote_path.path, ":h")
    local mkdir_cmd = {"ssh", remote_path.host, "mkdir", "-p", remote_dir}
    
    local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
        on_exit = function(_, mkdir_exit_code)
            if mkdir_exit_code ~= 0 then
                vim.schedule(function()
                    log("Failed to create remote directory: " .. remote_dir, vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end
            
            -- Build command based on protocol
            local save_cmd
            if remote_path.protocol == "scp" then
                save_cmd = {
                    "ssh", 
                    remote_path.host, 
                    "cat > " .. vim.fn.shellescape(remote_path.path)
                }
            elseif remote_path.protocol == "rsync" then
                save_cmd = {
                    "ssh", 
                    remote_path.host, 
                    "cat > " .. vim.fn.shellescape(remote_path.path)
                }
            else
                vim.schedule(function()
                    log("Unsupported protocol: " .. remote_path.protocol, vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end
            
            -- Create job with proper handlers
            local job_id
            local on_exit_wrapper = function(_, exit_code)
                if not active_writes[bufnr] or active_writes[bufnr].job_id ~= job_id then
                    log("Ignoring exit for job " .. job_id .. " (no longer tracked)")
                    return
                end
                on_write_complete(bufnr, job_id, exit_code)
            end
            
            -- Launch job with stdin as pipe
            job_id = vim.fn.jobstart(save_cmd, {
                on_exit = on_exit_wrapper,
                stdin = "pipe"
            })
            
            if job_id <= 0 then
                vim.schedule(function()
                    notify("❌ Failed to start save job", vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end
            
            -- Send content to job's stdin
            local send_ok, send_err = pcall(vim.fn.chansend, job_id, content)
            if not send_ok then
                log("Failed to send content: " .. tostring(send_err), vim.log.levels.ERROR)
                pcall(vim.fn.jobstop, job_id)
                vim.schedule(function()
                    on_write_complete(bufnr, job_id, 1, "Failed to send content")
                end)
                return
            end
            
            -- Close stdin channel
            pcall(vim.fn.chanclose, job_id, "stdin")
            
            -- Set up timer to monitor the job
            local timer = setup_job_timer(bufnr)
            
            -- Track the write operation
            active_writes[bufnr] = {
                job_id = job_id,
                start_time = start_time,
                buffer_name = bufname,
                remote_path = remote_path,
                timer = timer,
                elapsed = 0
            }
            
            log("Save job started with ID " .. job_id .. " for buffer " .. bufnr, vim.log.levels.INFO)
        end
    })
    
    if mkdir_job <= 0 then
        vim.schedule(function()
            notify("❌ Failed to ensure remote directory", vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
    end

    -- Return true to indicate we're handling the write
    return true
end

-- Force complete a stuck write operation
function M.force_complete(bufnr, success)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    success = success or false

    local write_info = active_writes[bufnr]
    if not write_info then
        notify("No active write operation for this buffer", vim.log.levels.WARN)
        return false
    end

    -- Stop the job if it's still running
    pcall(vim.fn.jobstop, write_info.job_id)

    -- Force completion
    on_write_complete(bufnr, write_info.job_id, success and 0 or 1,
        success and nil or "Manually forced completion")

    notify(success and "✓ Write operation marked as completed" or
        "✓ Write operation marked as failed", vim.log.levels.INFO)

    return true
end

-- Cancel an ongoing write operation
function M.cancel_write(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local write_info = active_writes[bufnr]
    if not write_info then
        notify("No active write operation to cancel", vim.log.levels.WARN)
        return false
    end

    -- Stop the job
    pcall(vim.fn.jobstop, write_info.job_id)

    -- Force completion with error
    on_write_complete(bufnr, write_info.job_id, 1, "Cancelled by user")

    notify("✓ Write operation cancelled", vim.log.levels.INFO)
    return true
end

-- Get status of active write operations
function M.get_status()
    local count = 0
    local details = {}

    for bufnr, info in pairs(active_writes) do
        count = count + 1
        local elapsed = os.time() - info.start_time
        local bufname = vim.api.nvim_buf_is_valid(bufnr) and 
                        vim.api.nvim_buf_get_name(bufnr) or 
                        info.buffer_name or "unknown"

        table.insert(details, {
            bufnr = bufnr,
            name = vim.fn.fnamemodify(bufname, ":t"),
            elapsed = elapsed,
            protocol = info.remote_path.protocol,
            host = info.remote_path.host,
            job_id = info.job_id
        })
    end

    notify(string.format("Active write operations: %d", count), vim.log.levels.INFO)

    for _, detail in ipairs(details) do
        notify(string.format("  Buffer %d: %s (%s to %s) - running for %ds (job %d)",
            detail.bufnr, detail.name, detail.protocol, detail.host, detail.elapsed, detail.job_id),
            vim.log.levels.INFO)
    end

    return {
        count = count,
        details = details
    }
end

-- Configure timeout and debug settings
function M.configure(opts)
    opts = opts or {}

    if opts.timeout then
        config.timeout = opts.timeout
    end

    if opts.debug ~= nil then
        config.debug = opts.debug
    end

    if opts.check_interval then
        config.check_interval = opts.check_interval
    end

    log("Configuration updated: " .. vim.inspect(config))
end

-- Set up LSP integration
function M.setup_lsp_integration(callbacks)
    if type(callbacks) ~= "table" then
        log("Invalid LSP integration callbacks", vim.log.levels.ERROR)
        return
    end

    if type(callbacks.notify_save_start) == "function" then
        lsp_integration.notify_save_start = callbacks.notify_save_start
        log("Registered LSP save start callback", vim.log.levels.DEBUG)
    end

    if type(callbacks.notify_save_end) == "function" then
        lsp_integration.notify_save_end = callbacks.notify_save_end
        log("Registered LSP save end callback", vim.log.levels.DEBUG)
    end

    log("LSP integration set up")
end

-- Setup file handlers for LSP and buffer commands
function M.setup_file_handlers()
    -- Create autocmd to intercept BufReadCmd for remote protocols
    local augroup = vim.api.nvim_create_augroup("RemoteFileOpen", { clear = true })
    
    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            local url = ev.match
            log("Intercepted BufReadCmd for " .. url, vim.log.levels.DEBUG)
            
            -- Use our custom remote file opener
            vim.schedule(function()
                M.open_remote_file(url)
            end)
            
            -- Return true to indicate we've handled it
            return true
        end,
        desc = "Intercept remote file opening and use custom opener",
    })
    
    -- Intercept the LSP handler for textDocument/definition
    -- Save the original handler
    local orig_definition_handler = vim.lsp.handlers["textDocument/definition"]
    
    -- Create a new handler that intercepts remote URLs
    vim.lsp.handlers["textDocument/definition"] = function(err, result, ctx, config)
        if err or not result or vim.tbl_isempty(result) then
            -- Pass through to original handler for error cases
            return orig_definition_handler(err, result, ctx, config)
        end
        
        -- Function to check if a uri is remote
        local function is_remote_uri(uri)
            return uri:match("^scp://") or uri:match("^rsync://") or 
                  uri:match("^file://scp://") or uri:match("^file://rsync://")
        end
        
        -- Check if we need to handle a remote URI
        local target_uri
        local position
        if result.uri then -- Single location
            target_uri = result.uri
            position = result.range and result.range.start
        elseif type(result) == "table" and result[1] and result[1].uri then -- Multiple locations
            target_uri = result[1].uri
            position = result[1].range and result[1].range.start
        end
        
        if target_uri and is_remote_uri(target_uri) then
            log("Handling LSP definition for remote URI: " .. target_uri, vim.log.levels.DEBUG)
            
            -- Convert file:// URI to our format if needed
            local clean_uri = target_uri
            if target_uri:match("^file://scp://") then
                clean_uri = target_uri:gsub("^file://", "")
            elseif target_uri:match("^file://rsync://") then
                clean_uri = target_uri:gsub("^file://", "")
            end
            
            -- Schedule opening the remote file
            vim.schedule(function()
                M.open_remote_file(clean_uri, position)
            end)
            
            return
        end
        
        -- For non-remote URIs, use the original handler
        return orig_definition_handler(err, result, ctx, config)
    end
    
    -- Also intercept other LSP location-based handlers
    local handlers_to_intercept = {
        "textDocument/references",
        "textDocument/implementation",
        "textDocument/typeDefinition",
        "textDocument/declaration"
    }
    
    for _, handler_name in ipairs(handlers_to_intercept) do
        local orig_handler = vim.lsp.handlers[handler_name]
        if orig_handler then
            vim.lsp.handlers[handler_name] = function(err, result, ctx, config)
                -- Reuse the same intercept logic as for definitions
                return vim.lsp.handlers["textDocument/definition"](err, result, ctx, config)
            end
        end
    end
    
    log("Set up remote file handlers for LSP and buffer commands", vim.log.levels.INFO)
end

-- Improved open_remote_file function to handle position jumping
function M.open_remote_file(url, position)
    -- Parse URL
    local protocol, host, path
    if url:match("^scp://") then
        protocol = "scp"
        host, path = url:match("^scp://([^/]+)/(.+)$")
    elseif url:match("^rsync://") then
        protocol = "rsync"
        host, path = url:match("^rsync://([^/]+)/(.+)$")
    else
        notify("Not a supported remote URL: " .. url, vim.log.levels.ERROR)
        return
    end
    
    if not host or not path then
        notify("Invalid URL format: " .. url, vim.log.levels.ERROR)
        return
    end
    
    -- Check if buffer already exists and is loaded
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname == url then
                log("Buffer already loaded, switching to it: " .. url, vim.log.levels.DEBUG)
                vim.api.nvim_set_current_buf(bufnr)
                
                -- Jump to position if provided
                if position then
                    vim.api.nvim_win_set_cursor(0, {position.line + 1, position.character})
                end
                
                return
            end
        end
    end
    
    -- Create a temporary local file
    local temp_file = vim.fn.tempname()
    
    -- Use scp/rsync to fetch the file
    local cmd
    if protocol == "scp" then
        cmd = {"scp", "-q", host .. ":" .. path, temp_file}
    else -- rsync
        cmd = {"rsync", "-az", host .. ":" .. path, temp_file}
    end
    
    -- Show status
    notify("Fetching remote file: " .. url, vim.log.levels.INFO)
    
    -- Run the command
    local job_id = vim.fn.jobstart(cmd, {
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    notify("Failed to fetch remote file (exit code " .. exit_code .. ")", vim.log.levels.ERROR)
                end)
                return
            end
            
            -- Open the temp file in a new buffer
            vim.schedule(function()
                -- Create a new buffer
                local bufnr = vim.api.nvim_create_buf(true, false)
                
                -- Set the buffer name to the remote URL
                vim.api.nvim_buf_set_name(bufnr, url)
                
                -- Set buffer type to 'acwrite' to ensure BufWriteCmd is used
                vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
                
                -- Read the temp file content
                local lines = vim.fn.readfile(temp_file)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                
                -- Set the buffer as not modified
                vim.api.nvim_buf_set_option(bufnr, "modified", false)
                
                -- Display the buffer
                vim.api.nvim_set_current_buf(bufnr)
                
                -- Delete the temp file
                vim.fn.delete(temp_file)
                
                -- Set filetype
                local ext = vim.fn.fnamemodify(path, ":e")
                if ext and ext ~= "" then
                    vim.filetype.match({ filename = path })
                end
                
                -- Jump to position if provided
                if position then
                    vim.api.nvim_win_set_cursor(0, {position.line + 1, position.character})
                end
                
                -- Start LSP for this buffer
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        require('remote-ssh').start_remote_lsp(bufnr)
                    end
                end)
                
                notify("Remote file loaded successfully", vim.log.levels.INFO)
            end)
        end
    })
    
    if job_id <= 0 then
        notify("Failed to start fetch job", vim.log.levels.ERROR)
    end
end

function M.setup_user_commands()
    -- Add a command to open remote files
    vim.api.nvim_create_user_command("RemoteOpen", function(opts)
        M.open_remote_file(opts.args)
    end, {
        nargs = 1,
        desc = "Open a remote file with scp:// or rsync:// protocol",
        complete = "file"
    })
    
    -- Create command aliases to ensure compatibility with existing workflows
    vim.cmd [[
    command! -nargs=1 -complete=file Rscp RemoteOpen rsync://<args>
    command! -nargs=1 -complete=file Scp RemoteOpen scp://<args>
    command! -nargs=1 -complete=file E RemoteOpen <args>
    ]]
end

-- Register autocmd to intercept write commands for remote files
function M.setup(opts)
    -- Apply configuration
    M.configure(opts)
    
    -- Completely disable netrw for these protocols
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"
    
    -- Create an autocmd group
    local augroup = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = true })

    -- Intercept BufWriteCmd for scp:// and rsync:// files
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            -- Get buffer name for detailed logging
            local bufname = vim.api.nvim_buf_get_name(ev.buf)
            log("BufWriteCmd triggered for buffer " .. ev.buf .. ": " .. bufname, vim.log.levels.INFO)
            
            -- Double-check protocol and make absolutely sure netrw is disabled
            vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"
            
            -- Try to start the save process
            local ok, result = pcall(function()
                return M.start_save_process(ev.buf)
            end)
            
            if not ok then
                -- If there was an error in the save process, log it but still return true
                log("Error in async save process: " .. tostring(result), vim.log.levels.ERROR)
                -- Set unmodified anyway to avoid repeated save attempts
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
                return true
            end
            
            if not result then
                -- If start_save_process returned false, log warning but still return true
                -- This prevents netrw from taking over
                log("Failed to start async save process, but preventing netrw fallback", vim.log.levels.WARN)
                -- Set unmodified anyway to avoid repeated save attempts  
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
            end
            
            -- Always return true to prevent netrw fallback
            return true
        end,
        desc = "Handle remote file saving asynchronously",
    })   

    -- Also intercept FileWriteCmd as a backup
    vim.api.nvim_create_autocmd("FileWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            log("FileWriteCmd triggered for " .. ev.file, vim.log.levels.INFO)
            
            -- Find which buffer has this file
            local bufnr = nil
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf) == ev.file then
                    bufnr = buf
                    break
                end
            end
            
            if not bufnr then
                log("No buffer found for " .. ev.file, vim.log.levels.ERROR)
                return true
            end
            
            -- Use the same handler as BufWriteCmd
            local ok, result = pcall(function()
                return M.start_save_process(bufnr)
            end)
            
            if not ok or not result then
                log("FileWriteCmd handler fallback: setting buffer as unmodified", vim.log.levels.WARN)
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)
            end
            
            return true
        end
    })

    -- Setup user commands
    M.setup_user_commands()
    
    -- Setup file handlers for LSP and buffer commands
    M.setup_file_handlers()

    -- Add user commands for write operations
    vim.api.nvim_create_user_command("AsyncWriteCancel", function()
        M.cancel_write()
    end, { desc = "Cancel ongoing asynchronous write operation" })

    vim.api.nvim_create_user_command("AsyncWriteStatus", function()
        M.get_status()
    end, { desc = "Show status of active asynchronous write operations" })

    -- Add force complete command
    vim.api.nvim_create_user_command("AsyncWriteForceComplete", function(opts)
        local success = opts.bang
        M.force_complete(nil, success)
    end, {
        desc = "Force complete a stuck write operation (! to mark as success)",
        bang = true
    })

    -- Add debug command
    vim.api.nvim_create_user_command("AsyncWriteDebug", function()
        config.debug = not config.debug
        notify("Async write debugging " .. (config.debug and "enabled" or "disabled"), vim.log.levels.INFO)
    end, { desc = "Toggle debugging for async write operations" })

    log("Async write module initialized with configuration: " .. vim.inspect(config))
end

return M
