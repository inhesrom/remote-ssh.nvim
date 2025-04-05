local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local process = require('async-remote-write.process')
local buffer = require('async-remote-write.buffer')
local lsp -- Will be required later to avoid circular dependency

-- Helper function to fetch content from a remote server
-- Update this function in operations.lua
function M.fetch_remote_content(host, path, callback)
    -- Ensure path starts with / for SSH commands
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    local cmd = {"ssh", host, "cat " .. vim.fn.shellescape(path)}
    local output = {}
    local stderr_output = {}

    utils.log("Fetching content with command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG, false, config.config)

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    table.insert(output, line)
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                utils.log("Failed to fetch remote content: " .. table.concat(stderr_output, "\n"), vim.log.levels.ERROR, false, config.config)
                callback(nil, stderr_output)
            else
                utils.log("Successfully fetched " .. #output .. " lines of content", vim.log.levels.DEBUG, false, config.config)
                callback(output, nil)
            end
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, false, config.config)
        callback(nil, {"Failed to start SSH process"})
    end

    return job_id
end

-- NEW APPROACH: Direct streaming to remote host
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require('async-remote-write.lsp')
    end

    -- Validate buffer first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        utils.log("Cannot save invalid buffer: " .. bufnr, vim.log.levels.ERROR, false, config.config)
        return true
    end

    -- Ensure 'buftype' is 'acwrite' to trigger BufWriteCmd
    local buftype = vim.api.nvim_buf_get_option(bufnr, 'buftype')
    if buftype ~= 'acwrite' then
        utils.log("Buffer type is not 'acwrite', resetting it for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
        vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
    end

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Check if there's already a write in progress
    local active_writes = process._internal.active_writes
    if active_writes[bufnr] then
        local elapsed = os.time() - active_writes[bufnr].start_time
        if elapsed > config.config.timeout / 2 then
            utils.log("Previous write may be stuck (running for " .. elapsed .. "s), forcing completion", vim.log.levels.WARN, false, config.config)
            process.force_complete(bufnr, true)
        else
            utils.log("⏳ A save operation is already in progress for this buffer", vim.log.levels.WARN, true, config.config)
            return true
        end
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false  -- Not a remote path we can handle
    end

    utils.log("Starting save for buffer " .. bufnr .. ": " .. bufname, vim.log.levels.DEBUG, false, config.config)

    -- Parse remote path
    local remote_path = utils.parse_remote_path(bufname)
    if not remote_path then
        vim.schedule(function()
            utils.log("Not a valid remote path: " .. bufname, vim.log.levels.ERROR, false, config.config)
            lsp.notify_save_end(bufnr)
        end)
        return true
    end

    -- Notify LSP immediately that we're saving
    lsp.notify_save_start(bufnr)

    -- Visual feedback for user
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            local short_name = vim.fn.fnamemodify(bufname, ":t")
            utils.log(string.format("💾 Saving '%s' in background...", short_name), vim.log.levels.INFO, true, config.config)
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
        if content == "" then
            error("Cannot save empty buffer with no contents")
        end
    end)

    if not ok then
        vim.schedule(function()
            utils.log("Failed to get buffer content: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
            lsp.notify_save_end(bufnr)
        end)
        return true
    end

    -- Start the save process
    local start_time = os.time()

    -- Create a temporary file to hold the content
    local temp_file = vim.fn.tempname()

    -- Write buffer content to temporary file
    local write_ok, write_err = pcall(function()
        local file = io.open(temp_file, "w")
        if not file then
            error("Failed to open temporary file: " .. temp_file)
        end
        file:write(content)
        file:close()
    end)

    if not write_ok then
        vim.schedule(function()
            utils.log("Failed to write to temporary file: " .. tostring(write_err), vim.log.levels.ERROR, false, config.config)
            lsp.notify_save_end(bufnr)
        end)
        pcall(vim.fn.delete, temp_file)
        return true
    end

    -- Prepare directory on remote host
    local remote_dir = vim.fn.fnamemodify(remote_path.path, ":h")
    local mkdir_cmd = {"ssh", remote_path.host, "mkdir", "-p", remote_dir}

    local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
        on_exit = function(_, mkdir_exit_code)
            if mkdir_exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Failed to create remote directory: " .. remote_dir, vim.log.levels.ERROR, false, config.config)
                    lsp.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Build command based on protocol
            local save_cmd
            if remote_path.protocol == "scp" then
                save_cmd = {
                    "scp",
                    "-q",  -- quiet mode
                    temp_file,
                    remote_path.host .. ":" .. vim.fn.shellescape(remote_path.path)
                }
            elseif remote_path.protocol == "rsync" then
                save_cmd = {
                    "rsync",
                    "-az",  -- archive mode and compress
                    "--quiet",  -- quiet mode
                    temp_file,
                    remote_path.host .. ":" .. remote_path.path
                }
            else
                vim.schedule(function()
                    utils.log("Unsupported protocol: " .. remote_path.protocol, vim.log.levels.ERROR, false, config.config)
                    lsp.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Create job with proper handlers
            local job_id
            local on_exit_wrapper = function(_, exit_code)
                -- Clean up the temporary file regardless of success or failure
                pcall(vim.fn.delete, temp_file)

                -- Access on_write_complete through process._internal
                if not process._internal.active_writes[bufnr] or process._internal.active_writes[bufnr].job_id ~= job_id then
                    utils.log("Ignoring exit for job " .. job_id .. " (no longer tracked)", vim.log.levels.DEBUG, false, config.config)
                    return
                end
                process._internal.on_write_complete(bufnr, job_id, exit_code)
            end

            -- Launch the transfer job
            job_id = vim.fn.jobstart(save_cmd, {
                on_exit = on_exit_wrapper
            })

            if job_id <= 0 then
                vim.schedule(function()
                    utils.log("❌ Failed to start save job", vim.log.levels.ERROR, true, config.config)
                    lsp.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Set up timer to monitor the job
            local timer = process.setup_job_timer(bufnr)

            -- Track the write operation
            process._internal.active_writes[bufnr] = {
                job_id = job_id,
                start_time = start_time,
                buffer_name = bufname,
                remote_path = remote_path,
                timer = timer,
                elapsed = 0,
                temp_file = temp_file  -- Track the temp file for cleanup if needed
            }

            utils.log("Save job started with ID " .. job_id .. " for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
        end
    })

    if mkdir_job <= 0 then
        vim.schedule(function()
            utils.log("❌ Failed to ensure remote directory", vim.log.levels.ERROR, true, config.config)
            lsp.notify_save_end(bufnr)
        end)
        pcall(vim.fn.delete, temp_file)
    end

    -- Return true to indicate we're handling the write
    return true
end

-- Enhanced open_remote_file function with better error handling and logging
function M.open_remote_file(url, position)
    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require('async-remote-write.lsp')
    end

    -- Add extensive logging at the start
    utils.log("Opening remote file: " .. url, vim.log.levels.DEBUG, false, config.config)
    if position then
        utils.log("With position - line: " .. position.line .. ", character: " .. position.character, vim.log.levels.DEBUG, false, config.config)
    end

    -- Parse URL using our enhanced function
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Not a supported remote URL format: " .. url, vim.log.levels.ERROR, true, config.config)
        utils.log("Failed to parse remote URL: " .. url, vim.log.levels.ERROR, false, config.config)
        return
    end

    local protocol = remote_info.protocol
    local host = remote_info.host
    local path = remote_info.path

    utils.log("Parsed remote URL - Protocol: " .. protocol .. ", Host: " .. host .. ", Path: " .. path, vim.log.levels.DEBUG, false, config.config)

    -- Check if buffer already exists and is loaded
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname == url then
                utils.log("Buffer already loaded, switching to it: " .. url, vim.log.levels.DEBUG, false, config.config)
                vim.api.nvim_set_current_buf(bufnr)

                -- Jump to position if provided
                if position then
                    pcall(vim.api.nvim_win_set_cursor, 0, {position.line + 1, position.character})
                end

                return
            end
        end
    end

    -- Create a temporary local file
    local temp_file = vim.fn.tempname()
    utils.log("Created temporary file: " .. temp_file, vim.log.levels.DEBUG, false, config.config)

    -- Build the appropriate command depending on if we have double slashes or not
    local remote_target
    if remote_info.has_double_slash then
        -- Keep the exact format as it appears in the URL
        remote_target = host .. ":" .. path
        utils.log("Using double-slash format for remote target", vim.log.levels.DEBUG, false, config.config)
    else
        -- Standard format
        remote_target = host .. ":" .. vim.fn.shellescape(path)
    end

    -- Use scp/rsync to fetch the file
    local cmd
    if protocol == "scp" then
        cmd = {"scp", "-q", remote_target, temp_file}
    else -- rsync
        cmd = {"rsync", "-az", "--quiet", remote_target, temp_file}
    end

    utils.log("Fetch command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG, false, config.config)
    -- Show status to user
    utils.log("Fetching remote file: " .. url, vim.log.levels.INFO, true, config.config)

    -- Run the command with detailed error logging
    local job_id = vim.fn.jobstart(cmd, {
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        utils.log("Fetch stderr: " .. line, vim.log.levels.ERROR, false, config.config)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Failed to fetch file with exit code " .. exit_code, vim.log.levels.ERROR, false, config.config)
                    utils.log("Failed to fetch remote file (exit code " .. exit_code .. ")", vim.log.levels.ERROR, true, config.config)

                    -- Try a fallback approach with an alternative command format
                    utils.log("Trying fallback approach for fetching remote file", vim.log.levels.DEBUG, false, config.config)
                    local fallback_cmd
                    if protocol == "scp" then
                        if remote_info.has_double_slash then
                            -- Use a different format for double-slash paths
                            fallback_cmd = {"ssh", host, "cat " .. path .. " > " .. temp_file}
                        else
                            fallback_cmd = {"scp", "-q", host .. ":" .. vim.fn.shellescape(path), temp_file}
                        end
                    else
                        if remote_info.has_double_slash then
                            fallback_cmd = {"ssh", host, "cat " .. path .. " > " .. temp_file}
                        else
                            fallback_cmd = {"rsync", "-az", "--quiet", host .. ":" .. vim.fn.shellescape(path), temp_file}
                        end
                    end

                    utils.log("Fallback command: " .. table.concat(fallback_cmd, " "), vim.log.levels.DEBUG, false, config.config)
                    utils.log("Trying alternative approach to fetch file...", vim.log.levels.INFO, true, config.config)

                    local fallback_job_id = vim.fn.jobstart(fallback_cmd, {
                        on_exit = function(_, fallback_exit_code)
                            if fallback_exit_code ~= 0 then
                                vim.schedule(function()
                                    utils.log("Fallback fetch also failed with exit code " .. fallback_exit_code, vim.log.levels.ERROR, false, config.config)
                                    utils.log("Failed to fetch remote file with alternative method", vim.log.levels.ERROR, true)
                                end)
                            else
                                -- Process the successfully fetched file
                                process_fetched_file()
                            end
                        end
                    })

                    if fallback_job_id <= 0 then
                        utils.log("Failed to start fallback fetch job", vim.log.levels.ERROR, false, config.config)
                        utils.log("Could not start alternative fetch method", vim.log.levels.ERROR, true, config.config)
                    end
                end)
                return
            end

            -- Success case - process the fetched file
            process_fetched_file()
        end
    })

    -- Function to process the fetched file and load it into a buffer
    function process_fetched_file()
        vim.schedule(function()
            -- Check if temp file exists and has content
            if vim.fn.filereadable(temp_file) ~= 1 then
                utils.log("Temp file not readable: " .. temp_file, vim.log.levels.ERROR, false, config.config)
                utils.log("Failed to create readable temp file", vim.log.levels.ERROR, true, config.config)
                return
            end

            local filesize = vim.fn.getfsize(temp_file)
            utils.log("Temp file size: " .. filesize .. " bytes", vim.log.levels.DEBUG, false, config.config)

            if filesize <= 0 then
                utils.log("Temp file is empty, fetch may have failed", vim.log.levels.WARN, false, config.config)
                utils.log("Warning: Fetched file appears to be empty", vim.log.levels.WARN, true, config.config)
            end

            -- Create a new buffer
            local bufnr = vim.api.nvim_create_buf(true, false)
            utils.log("Created new buffer with ID: " .. bufnr, vim.log.levels.DEBUG, false, config.config)

            -- Set the buffer name to the remote URL
            vim.api.nvim_buf_set_name(bufnr, url)

            -- Set buffer type to 'acwrite' to ensure BufWriteCmd is used
            vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')

            -- Read the temp file content
            local lines = vim.fn.readfile(temp_file)
            utils.log("Read " .. #lines .. " lines from temp file", vim.log.levels.DEBUG, false, config.config)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

            -- Set the buffer as not modified
            vim.api.nvim_buf_set_option(bufnr, "modified", false)

            -- Display the buffer
            vim.api.nvim_set_current_buf(bufnr)

            -- Delete the temp file
            vim.fn.delete(temp_file)
            utils.log("Deleted temp file", vim.log.levels.DEBUG, false, config.config)

            -- Set filetype
            local ext = vim.fn.fnamemodify(path, ":e")
            if ext and ext ~= "" then
                vim.filetype.match({ filename = path })
                utils.log("Set filetype based on extension: " .. ext, vim.log.levels.DEBUG, false, config.config)
            end

            -- Jump to position if provided
            if position then
                pcall(vim.api.nvim_win_set_cursor, 0, {position.line + 1, position.character})
                utils.log("Jumped to position: " .. position.line + 1 .. ":" .. position.character, vim.log.levels.DEBUG, false, config.config)
            end

            -- Register buffer-specific autocommands for saving
            buffer.register_buffer_autocommands(bufnr)

            -- Start LSP for this buffer
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    utils.log("Starting LSP for new buffer", vim.log.levels.DEBUG, false, config.config)
                    require('remote-lsp').start_remote_lsp(bufnr)
                end
            end)

            utils.log("Remote file loaded successfully", vim.log.levels.INFO, true, config.config)
        end)
    end

    if job_id <= 0 then
        utils.log("Failed to start fetch job, jobstart returned: " .. job_id, vim.log.levels.ERROR, false, config.config)
        utils.log("Failed to start fetch job", vim.log.levels.ERROR, true, config.config)
    else
        utils.log("Started fetch job with ID: " .. job_id, vim.log.levels.DEBUG, false, config.config)
    end
end

function M.simple_open_remote_file(url, position)
    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require('async-remote-write.lsp')
    end

    utils.log("Opening remote file: " .. url, vim.log.levels.DEBUG, false, config.config)

    -- Parse remote URL
    local remote_info = utils.parse_remote_path(url)
    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path has a leading slash for the SSH command
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    -- Directly fetch content from remote server
    utils.log("Fetching remote file: " .. url, vim.log.levels.INFO, true, config.config)

    M.fetch_remote_content(host, path, function(content, error)
        if not content then
            utils.log("Error fetching remote file: " .. (error and table.concat(error, "; ") or "unknown error"), vim.log.levels.ERROR, true, config.config)
            return
        end

        vim.schedule(function()
            -- Check for existing buffer with this name
            local existing_bufnr

            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == url then
                    existing_bufnr = bufnr
                    break
                end
            end

            local bufnr
            if existing_bufnr then
                bufnr = existing_bufnr
                utils.log("Reusing existing buffer: " .. bufnr, vim.log.levels.DEBUG, false, config.config)

                -- Make buffer modifiable
                local was_modifiable = vim.api.nvim_buf_get_option(bufnr, 'modifiable')
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
                end

                -- Clear and replace content
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)

                -- Restore modifiable state
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, 'modifiable', was_modifiable)
                end
            else
                -- Create new buffer
                bufnr = vim.api.nvim_create_buf(true, false)
                utils.log("Created new buffer: " .. bufnr, vim.log.levels.DEBUG, false, config.config)

                -- Set buffer name
                vim.api.nvim_buf_set_name(bufnr, url)

                -- Set buffer content
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
            end

            vim.api.nvim_buf_set_option(bufnr, 'buflisted', true)  -- Make it show in buffer list
            vim.api.nvim_buf_set_option(bufnr, 'bufhidden', '')    -- Don't hide/delete when not visible
            vim.api.nvim_buf_set_option(bufnr, 'swapfile', true)   -- Use a swapfile (helps persistence)

            -- Set buffer type to 'acwrite' to ensure BufWriteCmd is used
            vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')

            -- Set the buffer as not modified
            vim.api.nvim_buf_set_option(bufnr, "modified", false)

            -- Display the buffer
            vim.api.nvim_set_current_buf(bufnr)

            -- Set filetype
            local ext = vim.fn.fnamemodify(path, ":e")
            if ext and ext ~= "" then
                vim.filetype.match({ filename = path })
            end

            if position then
                -- Defer the cursor positioning to ensure buffer is fully loaded
                vim.defer_fn(function()
                    if not vim.api.nvim_buf_is_valid(bufnr) then
                        return
                    end

                    -- Validate the position is within buffer boundaries
                    local line_count = vim.api.nvim_buf_line_count(bufnr)
                    local line = position.line + 1  -- LSP is 0-based, Vim is 1-based

                    -- Ensure line is valid
                    if line <= 0 then
                        line = 1
                    elseif line > line_count then
                        line = line_count
                    end

                    -- Get the line content to determine max character position
                    local line_content = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
                    local max_col = #line_content
                    local col = position.character

                    -- Ensure column is valid
                    if col > max_col then
                        col = max_col
                    elseif col < 0 then
                        col = 0
                    end

                    -- Now safely set the cursor position
                    utils.log("Setting cursor to validated position: " .. line .. ":" .. col, vim.log.levels.DEBUG, false, config.config)
                    pcall(vim.api.nvim_win_set_cursor, 0, {line, col})
                end, 100)  -- Small delay to ensure buffer is ready
            end

            -- Register buffer-specific autocommands for saving
            buffer.register_buffer_autocommands(bufnr)

            -- Start LSP for this buffer
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    require('remote-lsp').start_remote_lsp(bufnr)
                end
            end)

            utils.log("Remote file loaded successfully", vim.log.levels.INFO, true, config.config)
        end)
    end)
end

function M.refresh_remote_buffer(bufnr)
    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require('async-remote-write.lsp')
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Check if buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        utils.log("Cannot refresh invalid buffer", vim.log.levels.ERROR, true, config.config)
        return false
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        utils.log("Not a remote buffer: " .. bufname, vim.log.levels.ERROR, true, config.config)
        return false
    end

    utils.log("Refreshing remote buffer " .. bufnr .. ": " .. bufname, vim.log.levels.DEBUG, false, config.config)

    -- Parse remote path
    local remote_info = utils.parse_remote_path(bufname)
    if not remote_info then
        utils.log("Failed to parse remote path: " .. bufname, vim.log.levels.ERROR, true, config.config)
        return false
    end

    -- Check if buffer is modified
    local is_modified = vim.api.nvim_buf_get_option(bufnr, 'modified')
    if is_modified then
        local choice = vim.fn.confirm(
            "Buffer is modified. Discard changes and refresh?",
            "&Yes\n&No",
            2
        )
        if choice ~= 1 then
            utils.log("Buffer refresh cancelled", vim.log.levels.INFO, true, config.config)
            return false
        end
    end

    -- Visual feedback for user
    utils.log("Refreshing remote file...", vim.log.levels.INFO, true, config.config)

    -- Fetch content from remote server
    M.fetch_remote_content(remote_info.host, remote_info.path, function(content, error)
        if not content then
            vim.schedule(function()
                utils.log("Error refreshing remote file: " .. (error and table.concat(error, "; ") or "unknown error"), vim.log.levels.ERROR, true, config.config)
            end)
            return
        end

        vim.schedule(function()
            -- Make sure buffer still exists
            if not vim.api.nvim_buf_is_valid(bufnr) then
                utils.log("Buffer no longer exists", vim.log.levels.ERROR, true, config.config)
                return
            end

            -- Store cursor position and view
            local win = vim.fn.bufwinid(bufnr)
            local cursor_pos = {0, 0}
            local view = nil

            if win ~= -1 then
                cursor_pos = vim.api.nvim_win_get_cursor(win)
                view = vim.fn.winsaveview()
            end

            -- Make buffer modifiable
            local was_modifiable = vim.api.nvim_buf_get_option(bufnr, 'modifiable')
            if not was_modifiable then
                vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
            end

            -- Clear and replace content
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)

            -- Mark buffer as unmodified
            vim.api.nvim_buf_set_option(bufnr, "modified", false)

            -- Restore modifiable state
            if not was_modifiable then
                vim.api.nvim_buf_set_option(bufnr, 'modifiable', was_modifiable)
            end

            -- Restore cursor position and view
            if win ~= -1 then
                -- Check if cursor position is still valid
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                if cursor_pos[1] <= line_count then
                    pcall(vim.api.nvim_win_set_cursor, win, cursor_pos)
                    if view then
                        pcall(vim.fn.winrestview, view)
                    end
                end
            end

            -- Restart LSP for this buffer
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    utils.log("Restarting LSP for refreshed buffer", vim.log.levels.DEBUG, false, config.config)
                    -- Notify LSP integration that we're done with the operation (similar to save)
                    lsp.notify_save_end(bufnr)

                    -- Restart the LSP client for this buffer
                    if package.loaded['remote-lsp'] then
                        require('remote-lsp').start_remote_lsp(bufnr)
                    end
                end
            end)

            utils.log("Remote file refreshed successfully", vim.log.levels.INFO, true, config.config)
        end)
    end)

    return true
end

return M
