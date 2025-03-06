local M = {}

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp, ...}
local active_writes = {}

-- Configuration
local config = {
    timeout = 30,          -- Default timeout in seconds
    debug = false,         -- Debug mode
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

    -- Match host and path, handling patterns correctly
    -- First try matching with the standard pattern
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

        -- Also update the status line if possible
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

-- Function to handle write completion with improved LSP preservation
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

    -- Improved buffer validation - APPROACH 2
    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Buffer " .. bufnr .. " is no longer valid during write completion", vim.log.levels.ERROR)
        
        -- Safely stop and close timer if it exists
        if write_info.timer then
            safe_close_timer(write_info.timer)
            write_info.timer = nil
        end
        
        -- Clean up temp file
        if write_info.temp_file and vim.fn.filereadable(write_info.temp_file) == 1 then
            pcall(vim.fn.delete, write_info.temp_file)
        end
        if write_info.temp_dir and vim.fn.isdirectory(write_info.temp_dir) == 1 then
            pcall(vim.fn.delete, write_info.temp_dir, "rf")
        end
        
        -- Store buffer name for logging
        local buffer_name = write_info.buffer_name or "unknown"
        
        -- Remove from active writes table
        active_writes[bufnr] = nil
        
        -- Notify LSP that the save is complete (even though buffer is gone)
        vim.schedule(function()
            lsp_integration.notify_save_end(bufnr)
            notify(string.format("✓ File '%s' saved but buffer no longer exists", 
                vim.fn.fnamemodify(buffer_name, ":t")), vim.log.levels.INFO)
        end)
        
        return
    end

    log(string.format("Write complete for buffer %d with exit code %d", bufnr, exit_code))

    -- Safely stop and close timer if it exists
    if write_info.timer then
        safe_close_timer(write_info.timer)
        write_info.timer = nil
    end
    
    -- Store LSP client information before cleanup
    local lsp_clients = {}
    if vim.api.nvim_buf_is_valid(bufnr) then
        -- Get current LSP clients attached to the buffer
        local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
        for _, client in ipairs(clients) do
            table.insert(lsp_clients, client.id)
        end
    end

    -- Clean up temp file
    vim.schedule(function()
        if write_info.temp_file and vim.fn.filereadable(write_info.temp_file) == 1 then
            pcall(vim.fn.delete, write_info.temp_file)
        end
        if write_info.temp_dir and vim.fn.isdirectory(write_info.temp_dir) == 1 then
            pcall(vim.fn.delete, write_info.temp_dir, "rf")
        end
    end)

    -- Store the write info temporarily and remove from active writes table
    -- This prevents potential race conditions if callbacks fire multiple times
    local completed_info = vim.deepcopy(write_info)
    active_writes[bufnr] = nil

    -- Notify LSP module that save is complete
    vim.schedule(function()
        lsp_integration.notify_save_end(bufnr)
        
        -- Verify LSP connection still exists and hasn't been dropped
        if #lsp_clients > 0 and vim.api.nvim_buf_is_valid(bufnr) then
            -- Double-check LSP clients are still attached
            local current_clients = vim.lsp.get_active_clients({ bufnr = bufnr })
            if #current_clients == 0 then
                log("LSP clients were disconnected during save, attempting to reconnect", vim.log.levels.WARN)
                
                -- Attempt to restart LSP for this buffer
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
        -- Get duration
        local duration = os.time() - completed_info.start_time
        local duration_str = duration > 1 and (duration .. "s") or "less than a second"

        -- Set unmodified if this buffer still exists
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                -- IMPORTANT: Use pcall to avoid errors if buffer was closed
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)

                -- Update status line
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                notify(string.format("✓ File '%s' saved in %s", vim.fn.fnamemodify(bufname, ":t"), duration_str))
            else
                notify(string.format("✓ File saved in %s (buffer no longer exists)", duration_str))
            end
        end)
    else
        local error_info = error_msg or ""
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                notify(string.format("❌ Failed to save '%s': %s", vim.fn.fnamemodify(bufname, ":t"), error_info), vim.log.levels.ERROR)
            else
                notify(string.format("❌ Failed to save file: %s", error_info), vim.log.levels.ERROR)
            end
        end)
    end
end

-- Set up a timer to monitor job progress
local function setup_job_timer(bufnr)
    local timer = vim.loop.new_timer()

    -- Check job status every second
    timer:start(1000, config.check_interval, vim.schedule_wrap(function()
        -- Check if write info still exists
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

            -- Force completion
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 0)
            end)

            safe_close_timer(timer)
        elseif elapsed > config.timeout then
            -- Job timed out
            log("Job timed out after " .. elapsed .. " seconds", vim.log.levels.WARN)

            -- Try to stop the job
            pcall(vim.fn.jobstop, write_info.job_id)

            -- Force completion with error
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 1, "Timeout after " .. elapsed .. " seconds")
            end)

            safe_close_timer(timer)
        end
    end))

    return timer
end

-- Generate a unique temporary filename
local function get_temp_file_path()
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/tempfile"
    return temp_file, temp_dir
end

-- Perform remote file transfer using file already written to disk
local function transfer_temp_file(bufnr, temp_file, temp_dir, remote_path)
    -- Ensure remote directory exists
    local dir = vim.fn.fnamemodify(remote_path.path, ":h")
    local mkdir_cmd = {"ssh", remote_path.host, "mkdir", "-p", dir}

    -- Start remote directory creation
    local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_exit = function(_, mkdir_exit_code)
            if mkdir_exit_code ~= 0 then
                vim.schedule(function()
                    log("Failed to create remote directory", vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end

            -- Now do the actual file transfer
            local start_time = os.time()
            local cmd, destination

            if remote_path.protocol == "scp" then
                destination = remote_path.host .. ":" .. remote_path.path
                cmd = {"scp", "-q", temp_file, destination}
            elseif remote_path.protocol == "rsync" then
                destination = remote_path.host .. ":" .. remote_path.path
                cmd = {"rsync", "-az", temp_file, destination}
            else
                vim.schedule(function()
                    log("Unsupported protocol: " .. remote_path.protocol, vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end

            -- Create job wrapper with error handling
            local job_id
            local on_exit_wrapper = vim.schedule_wrap(function(_, exit_code)
                -- Prevent handling if job is no longer tracked
                if not active_writes[bufnr] or active_writes[bufnr].job_id ~= job_id then
                    log("Ignoring exit for job " .. job_id .. " (no longer tracked)")
                    return
                end

                on_write_complete(bufnr, job_id, exit_code)
            end)

            job_id = vim.fn.jobstart(cmd, {
                on_exit = on_exit_wrapper,
                stdout_buffered = true,
                stderr_buffered = true,
            })

            if job_id <= 0 then
                vim.schedule(function()
                    notify("❌ Failed to start save job", vim.log.levels.ERROR)
                    lsp_integration.notify_save_end(bufnr)
                end)
                return
            end

            -- Set up timer for this job
            local timer = setup_job_timer(bufnr)

            -- Store write info
            active_writes[bufnr] = {
                job_id = job_id,
                start_time = start_time,
                temp_file = temp_file,
                temp_dir = temp_dir,
                remote_path = remote_path,
                timer = timer,
                type = remote_path.protocol,
                completed = false,
                buffer_name = vim.api.nvim_buf_get_name(bufnr) -- Store buffer name
            }
        end
    })

    if mkdir_job <= 0 then
        vim.schedule(function()
            notify("❌ Failed to ensure remote directory", vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
    end
end

-- Start the save process using a rapid write to temp file first
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Check if there's already a write in progress
    if active_writes[bufnr] then
        -- Schedule notification to avoid blocking
        vim.schedule(function()
            notify("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN)
        end)
        return true -- Still return true to indicate we're handling the write
    end

    -- Get buffer name and check if it's a remote path (quick check)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local protocol
    
    if bufname:match("^scp://") then
        protocol = "scp"
    elseif bufname:match("^rsync://") then
        protocol = "rsync"
    else
        -- Not a remote path we can handle
        return false
    end

    vim.schedule(function ()
        notify("Remote buffer save starting: " .. bufname, vim.log.levels.INFO)
    end)

    -- Parse remote path - with more robust error handling
    local remote_path = parse_remote_path(bufname)
    if not remote_path then
        vim.schedule(function()
            log(string.format("Not a valid remote path: %s", bufname), vim.log.levels.ERROR)
            
            -- Print details for debugging
            local url_parts = vim.split(bufname, "://", { plain = true })
            if #url_parts == 2 then
                local rest = url_parts[2]
                local host_path = vim.split(rest, "/", { plain = true })
                log("Protocol: " .. url_parts[1], vim.log.levels.DEBUG)
                log("Host part: " .. (host_path[1] or "nil"), vim.log.levels.DEBUG)
                log("Path part: " .. (host_path[2] or "nil"), vim.log.levels.DEBUG)
            end
            
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Generate a temporary file path
    local temp_file, temp_dir = get_temp_file_path()
    if not temp_file then
        vim.schedule(function()
            log("Failed to create temporary file", vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Notify LSP immediately that we're saving (this is fast)
    lsp_integration.notify_save_start(bufnr)

    -- Schedule visual feedback for user
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            local short_name = vim.fn.fnamemodify(bufname, ":t")
            notify(string.format("💾 Saving '%s' in background...", short_name))
        end
    end)

    -- APPROACH 1: Direct buffer content extraction instead of using vim.cmd
    local ok, err = pcall(function()
        -- Get all lines from the buffer
        if not vim.api.nvim_buf_is_valid(bufnr) then
            error("Buffer is no longer valid")
        end
        
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local content = table.concat(lines, "\n")
        
        -- Write content to temp file
        local file = io.open(temp_file, "w")
        if not file then
            error("Failed to open temporary file for writing")
        end
        
        file:write(content)
        file:close()
    end)

    if not ok then
        vim.schedule(function()
            log("Failed to write temporary file: " .. tostring(err), vim.log.levels.ERROR)
            lsp_integration.notify_save_end(bufnr)
        end)
        return true
    end

    -- Now we have the temp file, we can do the transfer completely asynchronously
    transfer_temp_file(bufnr, temp_file, temp_dir, remote_path)

    -- Return true immediately to indicate we're handling the write
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
    local stopped = pcall(vim.fn.jobstop, write_info.job_id)

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
        local bufname = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or info.buffer_name or "unknown"

        table.insert(details, {
            bufnr = bufnr,
            name = vim.fn.fnamemodify(bufname, ":t"),
            elapsed = elapsed,
            protocol = info.remote_path.protocol,
            host = info.remote_path.host,
            job_id = info.job_id,
            type = info.type
        })
    end

    notify(string.format("Active write operations: %d", count), vim.log.levels.INFO)

    for _, detail in ipairs(details) do
        notify(string.format("  Buffer %d: %s (%s to %s) - running for %ds (job %d)",
            detail.bufnr, detail.name, detail.type, detail.host, detail.elapsed, detail.job_id),
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

    -- ENHANCED: Intercept ALL file operations for remote protocols
    -- First, intercept BufWriteCmd with improved logging and error handling
    -- Intercept BufWriteCmd for scp:// and rsync:// files
   vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = {"scp://*", "rsync://*"},
        group = augroup,
        callback = function(ev)
            -- Get buffer name for detailed logging
            local bufname = vim.api.nvim_buf_get_name(ev.buf)
            vim.notify("BufWriteCmd triggered for buffer " .. ev.buf .. ": " .. bufname, vim.log.levels.INFO)
            
            -- Double-check protocol and make absolutely sure netrw is disabled
            vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"
            
            -- Try to start the save process
            local ok, result = pcall(function()
                return M.start_save_process(ev.buf)
            end)
            
            if not ok then
                -- If there was an error in the save process, log it but still return true
                vim.notify("Error in async save process: " .. tostring(result), vim.log.levels.ERROR)
                -- Set unmodified anyway to avoid repeated save attempts
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
                return true
            end
            
            if not result then
                -- If start_save_process returned false, log warning but still return true
                -- This prevents netrw from taking over
                vim.notify("Failed to start async save process, but preventing netrw fallback", vim.log.levels.WARN)
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
            vim.notify("FileWriteCmd triggered for " .. ev.file, vim.log.levels.INFO)
            
            -- Find which buffer has this file
            local bufnr = nil
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf) == ev.file then
                    bufnr = buf
                    break
                end
            end
            
            if not bufnr then
                vim.notify("No buffer found for " .. ev.file, vim.log.levels.ERROR)
                return true
            end
            
            -- Use the same handler as BufWriteCmd
            local ok, result = pcall(function()
                return M.start_save_process(bufnr)
            end)
            
            if not ok or not result then
                vim.notify("FileWriteCmd handler fallback: setting buffer as unmodified", vim.log.levels.WARN)
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

-- Helper to estimate the buffer size
function M.get_buffer_stats(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    
    -- Sample a few lines to estimate size
    local sample_size = math.min(line_count, 100)
    local sample_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, sample_size, false), "\n")
    local avg_line_size = #sample_text / sample_size
    local estimated_size = avg_line_size * line_count
    
    return {
        line_count = line_count,
        estimated_size = estimated_size,
        estimated_kb = math.floor(estimated_size / 1024),
        avg_line_size = avg_line_size
    }
end

return M
