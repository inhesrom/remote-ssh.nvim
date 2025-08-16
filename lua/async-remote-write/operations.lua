local M = {}

local config = require("async-remote-write.config")
local utils = require("async-remote-write.utils")
local process = require("async-remote-write.process")
local buffer = require("async-remote-write.buffer")
local ssh_utils = require("async-remote-write.ssh_utils")
local lsp -- Will be required later to avoid circular dependency

-- Non-blocking file loading helper functions
local function show_loading_progress(bufnr, message)
    message = message or "Loading remote file..."
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { message, "", "Please wait..." })
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
end

local function read_file_chunked(file_path, bufnr, chunk_size, on_complete)
    chunk_size = chunk_size or 1000 -- lines per chunk

    local file = io.open(file_path, "r")
    if not file then
        if on_complete then
            on_complete(false, "Failed to open file")
        end
        return
    end

    local current_line = 0
    local lines_buffer = {}

    local function read_next_chunk()
        lines_buffer = {} -- Clear buffer for this chunk

        -- Read chunk_size lines
        for i = 1, chunk_size do
            local line = file:read("*line")
            if not line then
                -- End of file reached
                file:close()

                -- Set any remaining lines
                if #lines_buffer > 0 then
                    vim.schedule(function()
                        if vim.api.nvim_buf_is_valid(bufnr) then
                            if current_line == 0 then
                                -- First and only chunk - replace entire buffer content
                                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines_buffer)
                            else
                                -- Final chunk - append to existing content
                                vim.api.nvim_buf_set_lines(bufnr, current_line, current_line, false, lines_buffer)
                            end
                        end
                    end)
                end

                -- Notify completion
                if on_complete then
                    vim.schedule(function()
                        on_complete(true)
                    end)
                end
                return
            end
            table.insert(lines_buffer, line)
        end

        -- Set this chunk in buffer
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                if current_line == 0 then
                    -- First chunk - replace entire buffer content (including loading message)
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines_buffer)
                else
                    -- Subsequent chunks - append to existing content
                    vim.api.nvim_buf_set_lines(bufnr, current_line, current_line, false, lines_buffer)
                end
                current_line = current_line + #lines_buffer

                -- Schedule next chunk with small delay to keep UI responsive
                vim.defer_fn(read_next_chunk, 1)
            else
                file:close()
                if on_complete then
                    on_complete(false, "Buffer became invalid")
                end
            end
        end)
    end

    read_next_chunk()
end

local function stream_file_to_buffer(file_path, bufnr, on_complete)
    local file = io.open(file_path, "r")
    if not file then
        if on_complete then
            on_complete(false, "Failed to open file")
        end
        return
    end

    local line_num = 0
    local batch_size = 100 -- Process 100 lines at a time for better performance
    local lines_batch = {}

    local function stream_next_batch()
        lines_batch = {}

        -- Read batch_size lines
        for i = 1, batch_size do
            local line = file:read("*line")
            if not line then
                -- End of file
                file:close()

                -- Set any remaining lines
                if #lines_batch > 0 then
                    vim.schedule(function()
                        if vim.api.nvim_buf_is_valid(bufnr) then
                            vim.api.nvim_buf_set_lines(bufnr, line_num, line_num, false, lines_batch)
                        end
                    end)
                end

                if on_complete then
                    vim.schedule(function()
                        on_complete(true)
                    end)
                end
                return
            end
            table.insert(lines_batch, line)
        end

        -- Set this batch in buffer
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_set_lines(bufnr, line_num, line_num, false, lines_batch)
                line_num = line_num + #lines_batch

                -- Update progress occasionally
                if line_num % 1000 == 0 then
                    utils.log("Loaded " .. line_num .. " lines...", vim.log.levels.DEBUG, false, config.config)
                end

                -- Continue streaming
                vim.defer_fn(stream_next_batch, 2) -- Slightly longer delay for large files
            else
                file:close()
                if on_complete then
                    on_complete(false, "Buffer became invalid")
                end
            end
        end)
    end

    stream_next_batch()
end

local function load_file_non_blocking(file_path, bufnr, on_complete)
    local filesize = vim.fn.getfsize(file_path)

    if filesize < 0 then
        if on_complete then
            on_complete(false, "File not readable")
        end
        return
    end

    utils.log("Loading file of size: " .. filesize .. " bytes", vim.log.levels.DEBUG, false, config.config)

    -- if filesize < 50000 then  -- Small files (< 50KB) - load normally
    --     local lines = vim.fn.readfile(file_path)
    --     vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    --     if on_complete then on_complete(true) end
    if filesize < 500000 then -- Medium files (< 500KB) - chunked loading
        utils.log("Using chunked loading for medium file", vim.log.levels.DEBUG, false, config.config)
        show_loading_progress(bufnr, "Loading remote file (chunked)...")
        read_file_chunked(file_path, bufnr, 1000, on_complete)
    else -- Large files - streaming
        utils.log("Using streaming for large file", vim.log.levels.DEBUG, false, config.config)
        show_loading_progress(bufnr, "Loading large remote file...")
        stream_file_to_buffer(file_path, bufnr, on_complete)
    end
end

local function load_content_non_blocking(content, bufnr, on_complete)
    local line_count = #content
    utils.log("Loading content with " .. line_count .. " lines", vim.log.levels.DEBUG, false, config.config)

    if line_count < 1000 then -- Small content - load normally
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
        if on_complete then
            on_complete(true)
        end
    elseif line_count < 5000 then -- Medium content - chunked loading
        utils.log("Using chunked loading for medium content", vim.log.levels.DEBUG, false, config.config)
        show_loading_progress(bufnr, "Loading remote file (chunked)...")

        local chunk_size = 1000
        local current_line = 0

        local function load_next_chunk()
            local end_line = math.min(current_line + chunk_size, line_count)
            local chunk = {}

            for i = current_line + 1, end_line do
                table.insert(chunk, content[i])
            end

            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    if current_line == 0 then
                        -- First chunk - replace entire buffer content (including loading message)
                        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chunk)
                    else
                        -- Subsequent chunks - append to existing content
                        vim.api.nvim_buf_set_lines(bufnr, current_line, current_line, false, chunk)
                    end
                    current_line = end_line

                    if current_line >= line_count then
                        -- Loading complete
                        if on_complete then
                            on_complete(true)
                        end
                    else
                        -- Schedule next chunk
                        vim.defer_fn(load_next_chunk, 1)
                    end
                else
                    if on_complete then
                        on_complete(false, "Buffer became invalid")
                    end
                end
            end)
        end

        load_next_chunk()
    else -- Large content - streaming
        utils.log("Using streaming for large content", vim.log.levels.DEBUG, false, config.config)
        show_loading_progress(bufnr, "Loading large remote file...")

        local batch_size = 100
        local current_line = 0

        local function stream_next_batch()
            local end_line = math.min(current_line + batch_size, line_count)
            local batch = {}

            for i = current_line + 1, end_line do
                table.insert(batch, content[i])
            end

            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    if current_line == 0 then
                        -- First batch - replace entire buffer content (including loading message)
                        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, batch)
                    else
                        -- Subsequent batches - append to existing content
                        vim.api.nvim_buf_set_lines(bufnr, current_line, current_line, false, batch)
                    end
                    current_line = end_line

                    -- Update progress occasionally
                    if current_line % 1000 == 0 then
                        utils.log("Loaded " .. current_line .. " lines...", vim.log.levels.DEBUG, false, config.config)
                    end

                    if current_line >= line_count then
                        -- Loading complete
                        if on_complete then
                            on_complete(true)
                        end
                    else
                        -- Continue streaming
                        vim.defer_fn(stream_next_batch, 2)
                    end
                else
                    if on_complete then
                        on_complete(false, "Buffer became invalid")
                    end
                end
            end)
        end

        stream_next_batch()
    end
end

-- Helper function to restore file permissions on remote server
local function restore_file_permissions(host, path, permissions, callback)
    if not permissions then
        callback(true) -- No permissions to restore, consider it successful
        return
    end

    -- Build chmod command to restore file permissions
    local chmod_cmd = { "ssh", host, "chmod", permissions, path }
    local stderr_output = {}

    utils.log(
        "Restoring file permissions with command: " .. table.concat(chmod_cmd, " "),
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    local job_id = vim.fn.jobstart(chmod_cmd, {
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
                utils.log(
                    "Failed to restore file permissions: " .. table.concat(stderr_output, "\n"),
                    vim.log.levels.WARN,
                    false,
                    config.config
                )
                callback(false)
            else
                utils.log(
                    "Successfully restored file permissions: " .. permissions,
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                callback(true)
            end
        end,
    })

    if job_id <= 0 then
        utils.log("Failed to start permissions restore job", vim.log.levels.WARN, false, config.config)
        callback(false)
    end
end

-- Helper function to capture file permissions from remote server
local function capture_file_permissions(host, path, callback)
    -- Build stat command to get file permissions
    local stat_cmd = { "ssh", host, "stat", "-c", "%a:%A", path }
    local stdout_output = {}
    local stderr_output = {}

    utils.log(
        "Capturing file permissions with command: " .. table.concat(stat_cmd, " "),
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    local job_id = vim.fn.jobstart(stat_cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stdout_output, line)
                    end
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
                utils.log(
                    "Failed to capture file permissions: " .. table.concat(stderr_output, "\n"),
                    vim.log.levels.WARN,
                    false,
                    config.config
                )
                callback(nil, nil)
            else
                local output = table.concat(stdout_output, "")
                local octal_perms, mode_string = output:match("^(%d+):(.+)$")
                if octal_perms and mode_string then
                    utils.log(
                        "Captured file permissions: " .. octal_perms .. " (" .. mode_string .. ")",
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                    callback(octal_perms, mode_string)
                else
                    utils.log("Failed to parse permissions output: " .. output, vim.log.levels.WARN, false, config.config)
                    callback(nil, nil)
                end
            end
        end,
    })

    if job_id <= 0 then
        utils.log("Failed to start permissions capture job", vim.log.levels.WARN, false, config.config)
        callback(nil, nil)
    end
end

-- Helper function to fetch content from a remote server
-- Update this function in operations.lua
function M.fetch_remote_content(host, path, callback)
    -- Ensure path starts with / for SSH commands
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    -- Use the same temporary file approach as open_remote_file() which works correctly
    local temp_file = vim.fn.tempname()
    -- Use the same path handling logic as open_remote_file() - don't always shellescape
    local remote_target = host .. ":" .. path
    local cmd = { "scp", "-q", remote_target, temp_file }
    local stderr_output = {}

    utils.log("Fetching content with command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG, false, config.config)

    local job_id = vim.fn.jobstart(cmd, {
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
                utils.log(
                    "Failed to fetch remote content: " .. table.concat(stderr_output, "\n"),
                    vim.log.levels.ERROR,
                    false,
                    config.config
                )
                pcall(vim.fn.delete, temp_file)
                callback(nil, stderr_output)
            else
                -- Read the temp file content exactly like open_remote_file() does
                local lines = vim.fn.readfile(temp_file)
                pcall(vim.fn.delete, temp_file)

                utils.log(
                    "Successfully fetched " .. #lines .. " lines of content",
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                utils.log(
                    "DEBUG: First 3 lines: " .. vim.inspect(vim.list_slice(lines, 1, 3)),
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                if #lines > 3 then
                    utils.log(
                        "DEBUG: Last 3 lines: " .. vim.inspect(vim.list_slice(lines, #lines - 2, #lines)),
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                end

                callback(lines, nil)
            end
        end,
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, false, config.config)
        pcall(vim.fn.delete, temp_file)
        callback(nil, { "Failed to start SSH process" })
    end

    return job_id
end

-- Updated function to properly handle rsync paths without over-escaping
local function actual_start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require("async-remote-write.lsp")
    end

    -- Validate buffer first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        utils.log("Cannot save invalid buffer: " .. bufnr, vim.log.levels.ERROR, false, config.config)
        return true
    end

    -- Ensure 'buftype' is 'acwrite' to trigger BufWriteCmd
    local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
    if buftype ~= "acwrite" then
        utils.log(
            "Buffer type is not 'acwrite', resetting it for buffer " .. bufnr,
            vim.log.levels.DEBUG,
            false,
            config.config
        )
        vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
    end

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Check if there's already a write in progress - be more strict about preventing duplicates
    local current_write = process._internal.get_active_write(bufnr)
    if current_write then
        local elapsed = os.time() - current_write.start_time
        utils.log(
            "DEBUG: Save already in progress for buffer " .. bufnr .. " (elapsed: " .. elapsed .. "s)",
            vim.log.levels.DEBUG,
            false,
            config.config
        )

        if elapsed > config.config.timeout / 2 then
            utils.log(
                "Previous write may be stuck (running for " .. elapsed .. "s), forcing completion",
                vim.log.levels.WARN,
                false,
                config.config
            )
            process.force_complete(bufnr, true)
        else
            utils.log(
                "⏳ A save operation is already in progress for this buffer (blocking duplicate)",
                vim.log.levels.WARN,
                true,
                config.config
            )
            return true
        end
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false -- Not a remote path we can handle
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

    -- Get buffer content FIRST, before any autocommands (formatters, etc.) modify it
    -- This serves as a backup in case something goes wrong during formatting
    local content = ""
    local original_line_count = 0
    local ok, err = pcall(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            error("Buffer is no longer valid")
        end
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Check if buffer ends with a newline by comparing to file on disk
        local ends_with_newline = vim.api.nvim_buf_get_option(bufnr, "eol")

        -- Join lines with newlines
        content = table.concat(lines, "\n")

        -- Add final newline only if buffer expects it
        if ends_with_newline and #lines > 0 then
            content = content .. "\n"
        end

        original_line_count = #lines

        -- Debug: log some line details
        utils.log(
            "DEBUG: Buffer lines breakdown - first 3 lines: " .. vim.inspect(vim.list_slice(lines, 1, 3)),
            vim.log.levels.DEBUG,
            false,
            config.config
        )
        if #lines > 3 then
            utils.log(
                "DEBUG: Last 3 lines: " .. vim.inspect(vim.list_slice(lines, #lines - 2, #lines)),
                vim.log.levels.DEBUG,
                false,
                config.config
            )
        end

        -- Debug: check for trailing whitespace patterns
        local empty_lines_at_end = 0
        for i = #lines, 1, -1 do
            if lines[i] == "" then
                empty_lines_at_end = empty_lines_at_end + 1
            else
                break
            end
        end
        utils.log("DEBUG: Empty lines at end: " .. empty_lines_at_end, vim.log.levels.DEBUG, false, config.config)
        if content == "" then
            error("Cannot save empty buffer with no contents")
        end
    end)

    utils.log(
        "DEBUG: Captured initial content - " .. original_line_count .. " lines, " .. #content .. " chars",
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    if not ok then
        vim.schedule(function()
            utils.log("Failed to get buffer content: " .. tostring(err), vim.log.levels.ERROR, false, config.config)
            lsp.notify_save_end(bufnr)
        end)
        return true
    end

    -- Store original buffer state to detect changes
    local original_modified = vim.api.nvim_buf_get_option(bufnr, "modified")
    local original_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

    -- Fire BufWritePre autocommand AFTER capturing content
    -- This is where formatters (prettier, black, etc.) will run and modify the buffer
    vim.cmd("doautocmd BufWritePre " .. vim.fn.fnameescape(bufname))

    -- Check if buffer was modified by BufWritePre autocommands (formatters, LSP actions, etc.)
    local new_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    if new_changedtick ~= original_changedtick then
        utils.log(
            "Buffer was formatted/modified by BufWritePre autocommands (changedtick: "
                .. original_changedtick
                .. " -> "
                .. new_changedtick
                .. ") - re-capturing formatted content",
            vim.log.levels.INFO,
            false,
            config.config
        )

        -- Re-capture content after autocommands to get the formatted/modified version
        local new_ok, new_err = pcall(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
                error("Buffer is no longer valid after BufWritePre")
            end
            local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- Re-check final newline handling after BufWritePre
            local ends_with_newline = vim.api.nvim_buf_get_option(bufnr, "eol")

            -- Join lines with newlines
            content = table.concat(new_lines, "\n")

            -- Add final newline only if buffer expects it
            if ends_with_newline and #new_lines > 0 then
                content = content .. "\n"
            end
            utils.log(
                "DEBUG: Re-captured after BufWritePre - "
                    .. #new_lines
                    .. " lines, "
                    .. #content
                    .. " chars (was "
                    .. original_line_count
                    .. " lines)",
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Debug: log line differences
            utils.log(
                "DEBUG: First 3 lines after BufWritePre: " .. vim.inspect(vim.list_slice(new_lines, 1, 3)),
                vim.log.levels.DEBUG,
                false,
                config.config
            )
            if #new_lines > 3 then
                utils.log(
                    "DEBUG: Last 3 lines after BufWritePre: "
                        .. vim.inspect(vim.list_slice(new_lines, #new_lines - 2, #new_lines)),
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
            end

            -- Debug: check what changed
            local new_empty_lines_at_end = 0
            for i = #new_lines, 1, -1 do
                if new_lines[i] == "" then
                    new_empty_lines_at_end = new_empty_lines_at_end + 1
                else
                    break
                end
            end
            utils.log(
                "DEBUG: Empty lines at end after BufWritePre: " .. new_empty_lines_at_end,
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Debug: try to find what exactly changed
            if #content ~= content:len() then
                utils.log(
                    "DEBUG: Content length mismatch after join - this shouldn't happen!",
                    vim.log.levels.WARN,
                    true,
                    config.config
                )
            end
        end)

        if not new_ok then
            vim.schedule(function()
                utils.log(
                    "Failed to re-capture buffer content after BufWritePre: " .. tostring(new_err),
                    vim.log.levels.ERROR,
                    false,
                    config.config
                )
                lsp.notify_save_end(bufnr)
            end)
            return true
        end
    end

    -- Notify LSP that we're saving
    lsp.notify_save_start(bufnr)

    -- Visual feedback for user
    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            local short_name = vim.fn.fnamemodify(bufname, ":t")
            utils.log(
                string.format("💾 Saving '%s' in background...", short_name),
                vim.log.levels.INFO,
                true,
                config.config
            )
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

    -- Write buffer content to temporary file with proper line ending handling
    local write_ok, write_err = pcall(function()
        local file = io.open(temp_file, "wb") -- Use binary mode to control line endings
        if not file then
            error("Failed to open temporary file: " .. temp_file)
        end

        -- Don't add extra newlines - write content exactly as captured
        file:write(content)
        file:close()

        utils.log(
            "DEBUG: Wrote " .. #content .. " chars to temp file: " .. temp_file,
            vim.log.levels.DEBUG,
            false,
            config.config
        )

        -- Verify temp file contents match what we wrote
        local verify_file = io.open(temp_file, "rb")
        if verify_file then
            local temp_content = verify_file:read("*a")
            verify_file:close()
            if temp_content == content then
                utils.log("DEBUG: Temp file content matches buffer content", vim.log.levels.DEBUG, false, config.config)
            else
                utils.log(
                    "DEBUG: MISMATCH! Temp file has " .. #temp_content .. " chars vs buffer " .. #content .. " chars",
                    vim.log.levels.WARN,
                    true,
                    config.config
                )
                -- Log first few different bytes
                for i = 1, math.min(#temp_content, #content, 100) do
                    if temp_content:byte(i) ~= content:byte(i) then
                        utils.log(
                            "DEBUG: First diff at byte "
                                .. i
                                .. ": temp="
                                .. temp_content:byte(i)
                                .. " vs buffer="
                                .. content:byte(i),
                            vim.log.levels.WARN,
                            true,
                            config.config
                        )
                        break
                    end
                end
            end
        end
    end)

    if not write_ok then
        vim.schedule(function()
            utils.log(
                "Failed to write to temporary file: " .. tostring(write_err),
                vim.log.levels.ERROR,
                false,
                config.config
            )
            lsp.notify_save_end(bufnr)
        end)
        pcall(vim.fn.delete, temp_file)
        return true
    end

    -- Prepare directory on remote host - use the proper path without escaping
    local remote_dir = vim.fn.fnamemodify(remote_path.path, ":h")
    local mkdir_cmd = ssh_utils.build_ssh_cmd(remote_path.host, "mkdir -p " .. remote_dir)

    local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
        on_exit = function(_, mkdir_exit_code)
            if mkdir_exit_code ~= 0 then
                vim.schedule(function()
                    utils.log(
                        "Failed to create remote directory: " .. remote_dir,
                        vim.log.levels.ERROR,
                        false,
                        config.config
                    )
                    lsp.notify_save_end(bufnr)
                end)
                pcall(vim.fn.delete, temp_file)
                return
            end

            -- Build command based on protocol
            local save_cmd
            if remote_path.protocol == "scp" then
                -- For SCP, use a simple format without extra escaping
                save_cmd = {
                    "scp",
                    "-q", -- quiet mode
                    "-p", -- preserve modification times and modes
                    "-C", -- disable compression to avoid any content changes
                    temp_file,
                    remote_path.host .. ":" .. remote_path.path,
                }
                utils.log("DEBUG: SCP command: " .. table.concat(save_cmd, " "), vim.log.levels.DEBUG, false, config.config)
            elseif remote_path.protocol == "rsync" then
                -- For rsync, use a format that works with both single and double slash paths
                local remote_target
                if remote_path.has_double_slash then
                    -- For double slash format, keep it consistent
                    remote_target = remote_path.host .. "://" .. remote_path.path:gsub("^/", "")
                else
                    -- For single slash format, don't escape the path
                    remote_target = remote_path.host .. ":" .. remote_path.path
                end

                utils.log("Rsync target: " .. remote_target, vim.log.levels.DEBUG, false, config.config)

                save_cmd = {
                    "rsync",
                    "-a", -- archive mode (no compression to avoid content changes)
                    "--quiet", -- quiet mode
                    "--no-whole-file", -- use delta transfer for efficiency
                    temp_file,
                    remote_target,
                }
                utils.log(
                    "DEBUG: Rsync command: " .. table.concat(save_cmd, " "),
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )

                -- Log the exact command for debugging
                utils.log("Rsync command: " .. table.concat(save_cmd, " "), vim.log.levels.DEBUG, false, config.config)
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
                local current_write = process._internal.get_active_write(bufnr)
                if not current_write or current_write.job_id ~= job_id then
                    utils.log(
                        "Ignoring exit for job " .. job_id .. " (no longer tracked)",
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                    return
                end

                -- On successful write, restore file permissions if available
                if exit_code == 0 then
                    -- Get stored permissions from buffer metadata
                    local metadata = require("remote-buffer-metadata")
                    local stored_permissions = metadata.get(bufnr, "async_remote_write", "file_permissions")

                    if stored_permissions then
                        -- Restore permissions after successful save
                        restore_file_permissions(remote_path.host, remote_path.path, stored_permissions, function(success)
                            if not success then
                                utils.log(
                                    "Warning: File saved but permissions could not be restored",
                                    vim.log.levels.WARN,
                                    true,
                                    config.config
                                )
                            end

                            -- Continue with normal post-save processing
                            vim.schedule(function()
                                if vim.api.nvim_buf_is_valid(bufnr) then
                                    -- Check buffer state before BufWritePost
                                    local pre_post_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                                    local pre_post_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

                                    -- Temporarily disable autocommands that might modify the buffer
                                    local old_eventignore = vim.o.eventignore
                                    vim.o.eventignore = "TextChanged,TextChangedI,TextChangedP"

                                    -- Fire BufWritePost autocommand
                                    vim.cmd("doautocmd BufWritePost " .. vim.fn.fnameescape(bufname))

                                    -- Restore eventignore
                                    vim.o.eventignore = old_eventignore

                                    -- Check if buffer was modified by BufWritePost (shouldn't happen but let's verify)
                                    local post_post_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
                                    if post_post_changedtick ~= pre_post_changedtick then
                                        local post_post_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                                        utils.log(
                                            "DEBUG: Buffer was modified by BufWritePost! changedtick: "
                                                .. pre_post_changedtick
                                                .. " -> "
                                                .. post_post_changedtick
                                                .. ", lines: "
                                                .. #pre_post_lines
                                                .. " -> "
                                                .. #post_post_lines,
                                            vim.log.levels.WARN,
                                            true,
                                            config.config
                                        )
                                    end
                                end
                            end)

                            process._internal.on_write_complete(bufnr, job_id, exit_code)
                        end)
                    else
                        -- No permissions to restore, continue with normal processing
                        vim.schedule(function()
                            if vim.api.nvim_buf_is_valid(bufnr) then
                                -- Check buffer state before BufWritePost
                                local pre_post_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                                local pre_post_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

                                -- Temporarily disable autocommands that might modify the buffer
                                local old_eventignore = vim.o.eventignore
                                vim.o.eventignore = "TextChanged,TextChangedI,TextChangedP"

                                -- Fire BufWritePost autocommand
                                vim.cmd("doautocmd BufWritePost " .. vim.fn.fnameescape(bufname))

                                -- Restore eventignore
                                vim.o.eventignore = old_eventignore

                                -- Check if buffer was modified by BufWritePost (shouldn't happen but let's verify)
                                local post_post_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
                                if post_post_changedtick ~= pre_post_changedtick then
                                    local post_post_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                                    utils.log(
                                        "DEBUG: Buffer was modified by BufWritePost! changedtick: "
                                            .. pre_post_changedtick
                                            .. " -> "
                                            .. post_post_changedtick
                                            .. ", lines: "
                                            .. #pre_post_lines
                                            .. " -> "
                                            .. #post_post_lines,
                                        vim.log.levels.WARN,
                                        true,
                                        config.config
                                    )
                                end
                            end
                        end)

                        process._internal.on_write_complete(bufnr, job_id, exit_code)
                    end
                else
                    -- Save failed, just complete normally
                    process._internal.on_write_complete(bufnr, job_id, exit_code)
                end
            end

            -- Launch the transfer job
            job_id = vim.fn.jobstart(save_cmd, {
                on_exit = on_exit_wrapper,
                -- Add stderr AND stdout capture for debugging
                on_stderr = function(_, data)
                    if data and #data > 0 then
                        for _, line in ipairs(data) do
                            if line and line ~= "" then
                                utils.log("Save stderr: " .. line, vim.log.levels.ERROR, false, config.config)
                            end
                        end
                    end
                end,
                on_stdout = function(_, data)
                    if data and #data > 0 then
                        for _, line in ipairs(data) do
                            if line and line ~= "" then
                                utils.log("Save stdout: " .. line, vim.log.levels.DEBUG, false, config.config)
                            end
                        end
                    end
                end,
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
            local write_info = {
                job_id = job_id,
                start_time = start_time,
                buffer_name = bufname,
                remote_path = remote_path,
                timer = timer,
                elapsed = 0,
                temp_file = temp_file, -- Track the temp file for cleanup if needed
            }
            process._internal.set_active_write(bufnr, write_info)

            utils.log(
                "Save job started with ID " .. job_id .. " for buffer " .. bufnr,
                vim.log.levels.DEBUG,
                false,
                config.config
            )
        end,
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

-- Debounced save function that delays actual save to handle rapid editing
function M.start_save_process(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local migration = require("remote-buffer-metadata.migration")

    -- Validate buffer first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        utils.log("Cannot save invalid buffer: " .. bufnr, vim.log.levels.ERROR, false, config.config)
        return true
    end

    -- Get buffer name and check if it's a remote path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false -- Not a remote path we can handle
    end

    -- Only start debounced save if buffer is actually modified
    local is_modified = vim.api.nvim_buf_get_option(bufnr, "modified")
    if not is_modified then
        utils.log("Buffer " .. bufnr .. " is not modified, skipping save", vim.log.levels.DEBUG, false, config.config)
        return true
    end

    -- Cancel any existing save timer for this buffer
    local existing_timer = migration.get_save_timer(bufnr)
    if existing_timer then
        utils.log("Canceling previous save timer for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
        if not existing_timer:is_closing() then
            existing_timer:close()
        end
        migration.set_save_timer(bufnr, nil)
    end

    -- Create a new timer for debounced save
    local timer = vim.loop.new_timer()
    migration.set_save_timer(bufnr, timer)

    local debounce_ms = config.config.save_debounce_ms
    utils.log("Scheduling save for buffer " .. bufnr .. " in " .. debounce_ms .. "ms", vim.log.levels.DEBUG, false, config.config)

    timer:start(debounce_ms, 0, function()
        vim.schedule(function()
            -- Clear the timer from metadata
            migration.set_save_timer(bufnr, nil)

            -- Check if buffer is still valid
            if vim.api.nvim_buf_is_valid(bufnr) then
                local current_bufname = vim.api.nvim_buf_get_name(bufnr)
                -- Verify buffer is still a remote file
                if current_bufname:match("^scp://") or current_bufname:match("^rsync://") then
                    -- Only execute save if we're in normal mode
                    local current_mode = vim.api.nvim_get_mode().mode
                    if current_mode == 'n' then
                        utils.log("Executing debounced save for buffer " .. bufnr .. " (normal mode)", vim.log.levels.DEBUG, false, config.config)
                        actual_start_save_process(bufnr)
                    else
                        utils.log("User still in " .. current_mode .. " mode, rescheduling save for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
                        -- Reschedule save with same delay for consistency
                        local retry_timer = vim.loop.new_timer()
                        migration.set_save_timer(bufnr, retry_timer)
                        retry_timer:start(debounce_ms, 0, function() -- Use same debounce time
                            vim.schedule(function()
                                migration.set_save_timer(bufnr, nil)
                                local retry_mode = vim.api.nvim_get_mode().mode
                                if retry_mode == 'n' and vim.api.nvim_buf_is_valid(bufnr) then
                                    utils.log("Retry: Executing debounced save for buffer " .. bufnr .. " (normal mode)", vim.log.levels.DEBUG, false, config.config)
                                    actual_start_save_process(bufnr)
                                else
                                    utils.log("Retry failed: User still in " .. retry_mode .. " mode or buffer invalid, save cancelled", vim.log.levels.DEBUG, false, config.config)
                                end
                            end)
                        end)
                    end
                else
                    utils.log("Buffer " .. bufnr .. " is no longer remote, skipping save", vim.log.levels.DEBUG, false, config.config)
                end
            else
                utils.log("Buffer " .. bufnr .. " no longer valid, skipping save", vim.log.levels.DEBUG, false, config.config)
            end
        end)
    end)

    -- Always return true to prevent netrw fallback
    return true
end

function M.simple_open_remote_file(url, position, target_win)
    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require("async-remote-write.lsp")
    end

    utils.log("Opening remote file: " .. url, vim.log.levels.DEBUG, false, config.config)

    -- Remember the target window (current window when function is called)
    -- This ensures the file opens in the correct window even if user switches windows during loading
    local target_window = target_win or vim.api.nvim_get_current_win()

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
    utils.log("Fetching remote file: " .. url, vim.log.levels.DEBUG, false, config.config)

    -- Capture file permissions first, then fetch content
    capture_file_permissions(host, path, function(permissions, mode_string)
        M.fetch_remote_content(host, path, function(content, error)
            if not content then
                utils.log(
                    "Error fetching remote file: " .. (error and table.concat(error, "; ") or "unknown error"),
                    vim.log.levels.ERROR,
                    true,
                    config.config
                )
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
                    local was_modifiable = vim.api.nvim_buf_get_option(bufnr, "modifiable")
                    if not was_modifiable then
                        vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
                    end

                    -- Clear content first
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

                    -- Load content using non-blocking approach for large content
                    load_content_non_blocking(content, bufnr, function()
                        -- Restore modifiable state after loading
                        if not was_modifiable then
                            vim.api.nvim_buf_set_option(bufnr, "modifiable", was_modifiable)
                        end
                        -- Set the buffer as not modified after loading is complete
                        vim.api.nvim_buf_set_option(bufnr, "modified", false)
                    end)
                else
                    -- Create new buffer
                    bufnr = vim.api.nvim_create_buf(true, false)
                    utils.log("Created new buffer: " .. bufnr, vim.log.levels.DEBUG, false, config.config)

                    -- Set buffer name
                    vim.api.nvim_buf_set_name(bufnr, url)

                    -- Load content using non-blocking approach
                    load_content_non_blocking(content, bufnr, function()
                        -- Set the buffer as not modified after loading is complete
                        vim.api.nvim_buf_set_option(bufnr, "modified", false)
                    end)
                end

                vim.api.nvim_buf_set_option(bufnr, "buflisted", true) -- Make it show in buffer list
                vim.api.nvim_buf_set_option(bufnr, "bufhidden", "") -- Don't hide/delete when not visible
                vim.api.nvim_buf_set_option(bufnr, "swapfile", true) -- Use a swapfile (helps persistence)

                -- Set buffer type to 'acwrite' to ensure BufWriteCmd is used
                vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")

                -- Note: modified = false is set after loading is complete in the callback

                -- Display the buffer in the target window
                -- First check if the target window is still valid and appropriate
                local function is_suitable_window(win_id)
                    if not vim.api.nvim_win_is_valid(win_id) then
                        return false
                    end

                    local buf_in_win = vim.api.nvim_win_get_buf(win_id)
                    local buftype = vim.api.nvim_buf_get_option(buf_in_win, "buftype")
                    local bufname = vim.api.nvim_buf_get_name(buf_in_win)

                    -- Check for unsuitable buffer types
                    if buftype == "nofile" or buftype == "terminal" or buftype == "prompt" then
                        return false
                    end

                    -- Check for special buffer names that indicate tree browser or other special buffers
                    if bufname:match("TreeBrowser") or bufname:match("NvimTree") or bufname:match("neo%-tree") then
                        return false
                    end

                    -- Accept normal files or remote files
                    return buftype == "" or buftype == "acwrite"
                end

                -- Try to use the target window if it's suitable
                if is_suitable_window(target_window) then
                    vim.api.nvim_win_set_buf(target_window, bufnr)
                    vim.api.nvim_set_current_win(target_window)
                else
                    -- Find a suitable window or create one
                    local suitable_win = nil
                    for _, win_id in ipairs(vim.api.nvim_list_wins()) do
                        if is_suitable_window(win_id) then
                            suitable_win = win_id
                            break
                        end
                    end

                    if suitable_win then
                        vim.api.nvim_win_set_buf(suitable_win, bufnr)
                        vim.api.nvim_set_current_win(suitable_win)
                    else
                        -- Create a new window for the file
                        vim.cmd("rightbelow vsplit")
                        local new_win = vim.api.nvim_get_current_win()
                        vim.api.nvim_win_set_buf(new_win, bufnr)
                    end
                end

                -- Set filetype
                local ext = vim.fn.fnamemodify(path, ":e")
                if ext and ext ~= "" then
                    vim.filetype.match({ filename = path })
                end

                -- Fire BufReadPost to initialize buffer properly, but protect against modifications
                local buffer_path = vim.api.nvim_buf_get_name(bufnr)
                local old_eventignore = vim.o.eventignore
                vim.o.eventignore = "TextChanged,TextChangedI,TextChangedP"
                vim.cmd("doautocmd BufReadPost " .. vim.fn.fnameescape(buffer_path))
                vim.o.eventignore = old_eventignore

                if position then
                    -- Defer the cursor positioning to ensure buffer is fully loaded
                    vim.defer_fn(function()
                        if not vim.api.nvim_buf_is_valid(bufnr) then
                            return
                        end

                        -- Validate the position is within buffer boundaries
                        local line_count = vim.api.nvim_buf_line_count(bufnr)
                        local line = position.line + 1 -- LSP is 0-based, Vim is 1-based

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
                        utils.log(
                            "Setting cursor to validated position: " .. line .. ":" .. col,
                            vim.log.levels.DEBUG,
                            false,
                            config.config
                        )
                        pcall(vim.api.nvim_win_set_cursor, 0, { line, col })

                        -- Center the view on the match
                        vim.cmd("normal! zz")
                    end, 100) -- Small delay to ensure buffer is ready
                end

                -- Store file permissions in buffer metadata
                if permissions then
                    local metadata = require("remote-buffer-metadata")
                    metadata.set(bufnr, "async_remote_write", "host", host)
                    metadata.set(bufnr, "async_remote_write", "remote_path", path)
                    metadata.set(bufnr, "async_remote_write", "protocol", remote_info.protocol)
                    metadata.set(bufnr, "async_remote_write", "file_permissions", permissions)
                    metadata.set(bufnr, "async_remote_write", "file_mode", mode_string)
                    utils.log(
                        "Stored file permissions in metadata: " .. permissions,
                        vim.log.levels.DEBUG,
                        false,
                        config.config
                    )
                end

                -- Register buffer-specific autocommands for saving
                buffer.register_buffer_autocommands(bufnr)

                -- Start LSP for this buffer
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        require("remote-lsp").start_remote_lsp(bufnr)
                    end
                end)

                -- Track this file opening in session history
                local session_picker = require("async-remote-write.session_picker")
                session_picker.track_file_open(url, {
                    display_name = vim.fn.fnamemodify(path, ":t"), -- Just filename
                    full_path = path,
                })

                utils.log("Remote file loaded successfully", vim.log.levels.DEBUG, false, config.config)
            end)
        end)
    end)
end

function M.refresh_remote_buffer(bufnr)
    -- Make sure lsp module is loaded
    if not lsp then
        lsp = require("async-remote-write.lsp")
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
    local is_modified = vim.api.nvim_buf_get_option(bufnr, "modified")
    if is_modified then
        local choice = vim.fn.confirm("Buffer is modified. Discard changes and refresh?", "&Yes\n&No", 2)
        if choice ~= 1 then
            utils.log("Buffer refresh cancelled", vim.log.levels.INFO, true, config.config)
            return false
        end
    end

    -- Visual feedback for user
    utils.log("Refreshing remote file...", vim.log.levels.DEBUG, false, config.config)

    -- Capture file permissions first, then fetch content
    capture_file_permissions(remote_info.host, remote_info.path, function(permissions, mode_string)
        M.fetch_remote_content(remote_info.host, remote_info.path, function(content, error)
            if not content then
                vim.schedule(function()
                    utils.log(
                        "Error refreshing remote file: " .. (error and table.concat(error, "; ") or "unknown error"),
                        vim.log.levels.ERROR,
                        true,
                        config.config
                    )
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
                local cursor_pos = { 0, 0 }
                local view = nil

                if win ~= -1 then
                    cursor_pos = vim.api.nvim_win_get_cursor(win)
                    view = vim.fn.winsaveview()
                end

                -- Make buffer modifiable
                local was_modifiable = vim.api.nvim_buf_get_option(bufnr, "modifiable")
                if not was_modifiable then
                    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
                end

                -- Clear content first
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

                -- Load content using non-blocking approach
                load_content_non_blocking(content, bufnr, function(success, error_msg)
                    if success then
                        -- Mark buffer as unmodified
                        vim.api.nvim_buf_set_option(bufnr, "modified", false)

                        -- Restore modifiable state
                        if not was_modifiable then
                            vim.api.nvim_buf_set_option(bufnr, "modifiable", was_modifiable)
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

                        -- Update file permissions in buffer metadata if captured
                        if permissions then
                            local metadata = require("remote-buffer-metadata")
                            metadata.set(bufnr, "async_remote_write", "host", remote_info.host)
                            metadata.set(bufnr, "async_remote_write", "remote_path", remote_info.path)
                            metadata.set(bufnr, "async_remote_write", "protocol", remote_info.protocol)
                            metadata.set(bufnr, "async_remote_write", "file_permissions", permissions)
                            metadata.set(bufnr, "async_remote_write", "file_mode", mode_string)
                            utils.log(
                                "Updated file permissions in metadata: " .. permissions,
                                vim.log.levels.DEBUG,
                                false,
                                config.config
                            )
                        end

                        -- Restart LSP for this buffer (moved into callback)
                        vim.schedule(function()
                            if vim.api.nvim_buf_is_valid(bufnr) then
                                utils.log("Restarting LSP for refreshed buffer", vim.log.levels.DEBUG, false, config.config)
                                -- Notify LSP integration that we're done with the operation (similar to save)
                                lsp.notify_save_end(bufnr)

                                -- Restart the LSP client for this buffer
                                if package.loaded["remote-lsp"] then
                                    require("remote-lsp").start_remote_lsp(bufnr)
                                end
                            end
                        end)

                        utils.log("Remote file refreshed successfully", vim.log.levels.DEBUG, false, config.config)
                    else
                        utils.log(
                            "Failed to refresh file content: " .. (error_msg or "unknown error"),
                            vim.log.levels.ERROR,
                            true,
                            config.config
                        )

                        -- Restore modifiable state even on failure
                        if not was_modifiable then
                            vim.api.nvim_buf_set_option(bufnr, "modifiable", was_modifiable)
                        end
                    end
                end)
            end)
        end)
    end)

    return true
end

return M
