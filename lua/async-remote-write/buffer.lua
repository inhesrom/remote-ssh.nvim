local M = {}

local config = require("async-remote-write.config")
local utils = require("async-remote-write.utils")
local migration = require("remote-buffer-metadata.migration")
local operations -- Will be required later to avoid circular dependency
local file_watcher -- Will be required later to avoid circular dependency

-- Note: All buffer state tracking now handled by buffer-local metadata system
-- Legacy global tables have been removed - see remote-buffer-metadata module

function M.track_buffer_state_after_save(bufnr)
    -- Only track if buffer is still valid
    if vim.api.nvim_buf_is_valid(bufnr) then
        local state = {
            time = os.time(),
            buftype = vim.api.nvim_buf_get_option(bufnr, "buftype"),
            autocmds_checked = false,
        }
        migration.set_buffer_state(bufnr, state)

        -- Schedule a check of autocommands after the write is complete
        vim.defer_fn(function()
            local buffer_state = migration.get_buffer_state(bufnr)
            if vim.api.nvim_buf_is_valid(bufnr) and buffer_state then
                -- Get current buftype
                local current_buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
                buffer_state.autocmds_checked = true
                buffer_state.buftype_after_delay = current_buftype
                migration.set_buffer_state(bufnr, buffer_state)

                -- Check if the buftype has changed
                if buffer_state.buftype ~= current_buftype then
                    utils.log(
                        "Buffer type changed after save: " .. buffer_state.buftype .. " -> " .. current_buftype,
                        vim.log.levels.WARN,
                        false,
                        config.config
                    )

                    -- If it's changed from acwrite, fix it
                    if buffer_state.buftype == "acwrite" and current_buftype ~= "acwrite" then
                        utils.log("Restoring buffer type to 'acwrite'", vim.log.levels.DEBUG, false, config.config)
                        vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
                    end
                end
            end
        end, 500) -- Check after 500ms
    end
end

function M.debug_buffer_state(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Get basic buffer info
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
    local modified = vim.api.nvim_buf_get_option(bufnr, "modified")
    local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")

    -- Need to require operations here to avoid circular dependency
    if not operations then
        operations = require("async-remote-write.operations")
    end

    -- Check if this buffer is in active_writes
    local active_writes = require("async-remote-write.process").get_active_writes()
    local in_active_writes = active_writes[bufnr] ~= nil

    -- Try to get autocommand info
    local autocmd_info = "Not available in Neovim API"
    if vim.fn.has("nvim-0.7") == 1 then
        -- For newer Neovim versions that support listing autocommands
        local augroup_id = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = false })
        if augroup_id then
            local autocmds = vim.api.nvim_get_autocmds({
                group = "AsyncRemoteWrite",
                pattern = { "scp://*", "rsync://*" },
            })
            autocmd_info = "Found " .. #autocmds .. " matching autocommands"
        else
            autocmd_info = "AsyncRemoteWrite augroup not found"
        end
    end

    -- Print diagnostic info
    utils.log("===== Buffer Diagnostics =====", vim.log.levels.INFO, true, config.config)
    utils.log("Buffer: " .. bufnr, vim.log.levels.INFO, true, config.config)
    utils.log("Name: " .. bufname, vim.log.levels.INFO, true, config.config)
    utils.log("Type: " .. buftype, vim.log.levels.INFO, true, config.config)
    utils.log("Modified: " .. tostring(modified), vim.log.levels.INFO, true, config.config)
    utils.log("Filetype: " .. filetype, vim.log.levels.INFO, true, config.config)
    utils.log("In active_writes: " .. tostring(in_active_writes), vim.log.levels.INFO, true, config.config)
    utils.log("Autocommands: " .. autocmd_info, vim.log.levels.INFO, true, config.config)

    -- Check if buffer matches our patterns
    local matches_scp = bufname:match("^scp://") ~= nil
    local matches_rsync = bufname:match("^rsync://") ~= nil
    utils.log("Matches scp pattern: " .. tostring(matches_scp), vim.log.levels.INFO, true, config.config)
    utils.log("Matches rsync pattern: " .. tostring(matches_rsync), vim.log.levels.INFO, true, config.config)

    -- Check for remote-ssh tracking
    local tracked_by_lsp = false
    if package.loaded["remote-lsp"] then
        local remote_lsp = require("remote-lsp")
        if remote_lsp.buffer_clients and remote_lsp.buffer_clients[bufnr] then
            tracked_by_lsp = true
        end
    end
    utils.log("Tracked by LSP: " .. tostring(tracked_by_lsp), vim.log.levels.INFO, true)

    return {
        bufnr = bufnr,
        bufname = bufname,
        buftype = buftype,
        modified = modified,
        in_active_writes = in_active_writes,
        autocmd_info = autocmd_info,
        matches_pattern = matches_scp or matches_rsync,
    }
end

function M.ensure_acwrite_state(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Check if buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        utils.log("Cannot ensure state of invalid buffer: " .. bufnr, vim.log.levels.ERROR, false, config.config)
        return false
    end

    -- Get buffer info
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    -- Skip if not a remote path
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false
    end

    -- Ensure buffer type is 'acwrite'
    local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
    if buftype ~= "acwrite" then
        utils.log(
            "Fixing buffer type from '" .. buftype .. "' to 'acwrite' for buffer " .. bufnr,
            vim.log.levels.DEBUG,
            false,
            config.config
        )
        vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
    end

    -- Ensure netrw commands are disabled
    vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
    vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

    -- Ensure autocommands exist
    if vim.fn.exists("#AsyncRemoteWrite#BufWriteCmd#" .. vim.fn.fnameescape(bufname)) == 0 then
        utils.log("Autocommands for buffer do not exist, re-registering", vim.log.levels.DEBUG, false, config.config)

        -- Re-register autocommands specifically for this buffer
        local augroup = vim.api.nvim_create_augroup("AsyncRemoteWrite", { clear = false })

        vim.api.nvim_create_autocmd("BufWriteCmd", {
            pattern = bufname,
            group = augroup,
            callback = function(ev)
                utils.log("Re-registered BufWriteCmd triggered for " .. bufname, vim.log.levels.DEBUG, false, config.config)
                -- Need to require here to avoid circular dependency
                if not operations then
                    operations = require("async-remote-write.operations")
                end
                return operations.start_save_process(ev.buf)
            end,
            desc = "Handle specific remote file saving asynchronously",
        })
    end

    return true
end

function M.register_buffer_autocommands(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Skip if buffer is not valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        utils.log("Cannot register autocommands for invalid buffer: " .. bufnr, vim.log.levels.ERROR, false, config.config)
        return false
    end

    -- Get buffer name
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    -- Skip if not a remote path
    if not (bufname:match("^scp://") or bufname:match("^rsync://")) then
        return false
    end

    utils.log("Registering autocommands for buffer " .. bufnr .. ": " .. bufname, vim.log.levels.DEBUG, false, config.config)

    -- Mark this buffer as having buffer-specific autocommands to prevent fallback conflicts
    migration.set_has_specific_autocmds(bufnr, true)

    -- Ensure buffer type is correct
    local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
    if buftype ~= "acwrite" then
        utils.log("Setting buftype to 'acwrite' for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
        vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
    end

    -- Create an augroup specifically for this buffer
    local augroup_name = "AsyncRemoteWrite_Buffer_" .. bufnr
    local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

    -- Register BufWriteCmd specifically for this buffer
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr, -- This is key - use buffer instead of pattern for buffer-specific autocommand
        group = augroup,
        callback = function(ev)
            utils.log(
                "Buffer-specific BufWriteCmd triggered for buffer " .. ev.buf,
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Ensure netrw commands are disabled
            vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

            -- Try to start the save process
            -- Need to require here to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            local ok, result = pcall(function()
                return operations.start_save_process(ev.buf)
            end)

            if not ok then
                utils.log("Error in async save process: " .. tostring(result), vim.log.levels.ERROR, false, config.config)
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
                return true
            end

            if not result then
                utils.log("Failed to start async save process", vim.log.levels.WARN, false, config.config)
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
            end

            return true
        end,
        desc = "Handle buffer-specific remote file saving asynchronously",
    })

    -- Add text change monitoring for debounced saves
    -- TextChanged fires after changes in normal mode
    vim.api.nvim_create_autocmd("TextChanged", {
        buffer = bufnr,
        group = augroup,
        callback = function(ev)
            utils.log(
                "TextChanged triggered for buffer " .. ev.buf .. ", starting debounced save",
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Need to require here to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            -- Start debounced save process
            operations.start_save_process(ev.buf)
        end,
        desc = "Trigger debounced save on text changes",
    })

    -- TextChangedI fires after changes in insert mode
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        group = augroup,
        callback = function(ev)
            utils.log(
                "TextChangedI triggered for buffer " .. ev.buf .. ", starting debounced save",
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Need to require here to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            -- Start debounced save process
            operations.start_save_process(ev.buf)
        end,
        desc = "Trigger debounced save on insert mode text changes",
    })

    -- InsertLeave for when user exits insert mode (good trigger point)
    vim.api.nvim_create_autocmd("InsertLeave", {
        buffer = bufnr,
        group = augroup,
        callback = function(ev)
            utils.log(
                "InsertLeave triggered for buffer " .. ev.buf .. ", starting debounced save",
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Need to require here to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            -- Start debounced save process
            operations.start_save_process(ev.buf)
        end,
        desc = "Trigger debounced save when leaving insert mode",
    })

    -- Also add a BufEnter command to ensure this buffer's autocommands stay registered
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = bufnr,
        group = augroup,
        callback = function()
            -- This ensures that if we return to this buffer, we maintain its autocommands
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    -- Check if the autocommands exist for this buffer
                    local has_autocmd = false
                    if vim.fn.has("nvim-0.7") == 1 then
                        local autocmds = vim.api.nvim_get_autocmds({
                            group = augroup_name,
                            event = { "BufWriteCmd", "TextChanged", "TextChangedI", "InsertLeave" },
                            buffer = bufnr,
                        })
                        has_autocmd = #autocmds >= 4 -- Should have all 4 events
                    end

                    if not has_autocmd then
                        utils.log(
                            "Buffer autocommands missing on buffer enter, reregistering for buffer " .. bufnr,
                            vim.log.levels.DEBUG,
                            false,
                            config.config
                        )
                        M.register_buffer_autocommands(bufnr)
                    end
                end
            end, 10) -- Small delay to ensure buffer is loaded
        end,
    })

    -- Start file watching for this buffer if enabled
    vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            -- Re-validate that buffer is still remote (buffer name could have changed)
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match("^scp://") or bufname:match("^rsync://") then
                if not file_watcher then
                    file_watcher = require("async-remote-write.file-watcher")
                end
                utils.log(
                    "Starting file watcher for buffer " .. bufnr .. ": " .. bufname,
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                file_watcher.start_watching(bufnr)
            else
                utils.log(
                    "Buffer " .. bufnr .. " is no longer remote, skipping file watcher start (bufname: " .. bufname .. ")",
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
            end
        end
    end, 200) -- Delay to ensure buffer is fully loaded

    utils.log("Successfully registered autocommands for buffer " .. bufnr, vim.log.levels.DEBUG, false, config.config)
    return true
end

-- Register autocmd to intercept write commands for remote files
function M.setup_autocommands()
    -- Create a monitoring augroup for detecting new remote buffers
    local monitor_augroup = vim.api.nvim_create_augroup("AsyncRemoteWriteMonitor", { clear = true })

    -- Create a global fallback augroup - this handles files that haven't been properly registered yet
    local fallback_augroup = vim.api.nvim_create_augroup("AsyncRemoteWriteFallback", { clear = true })

    -- Register on BufReadPost to set up buffer-specific commands
    vim.api.nvim_create_autocmd("BufReadPost", {
        pattern = { "scp://*", "rsync://*" },
        group = monitor_augroup,
        callback = function(ev)
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    utils.log("BufReadPost trigger for buffer " .. ev.buf, vim.log.levels.DEBUG, false, config.config)
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 50) -- Small delay to ensure buffer is loaded
        end,
    })

    -- Add a FileType detection hook for catching buffers we might have missed
    vim.api.nvim_create_autocmd("FileType", {
        pattern = { "scp://*", "rsync://*" },
        group = monitor_augroup,
        callback = function(ev)
            local bufname = vim.api.nvim_buf_get_name(ev.buf)
            if bufname:match("^scp://") or bufname:match("^rsync://") then
                local url = ev.match
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(ev.buf) then
                        utils.log(
                            "FileType trigger for remote buffer " .. ev.buf,
                            vim.log.levels.DEBUG,
                            false,
                            config.config
                        )
                        local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
                        local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")

                        -- Need to require here to avoid circular dependency
                        if not operations then
                            operations = require("async-remote-write.operations")
                        end

                        if is_empty then
                            operations.simple_open_remote_file(url)
                        end
                        M.register_buffer_autocommands(ev.buf)
                    end
                end, 50) -- Small delay to ensure buffer is loaded
            end
        end,
    })

    -- Add a BufNew detection hook to catch buffers as they're created
    vim.api.nvim_create_autocmd("BufNew", {
        pattern = { "scp://*", "rsync://*" },
        group = monitor_augroup,
        callback = function(ev)
            local url = ev.match
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    utils.log("BufNew trigger for buffer " .. ev.buf, vim.log.levels.DEBUG, false, config.config)
                    local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
                    local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")

                    -- Need to require here to avoid circular dependency
                    if not operations then
                        operations = require("async-remote-write.operations")
                    end

                    if is_empty then
                        operations.simple_open_remote_file(url)
                    end
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 100) -- Small delay to ensure buffer is loaded
        end,
    })

    -- FALLBACK: Global pattern-based autocmds as a safety net
    -- These will catch any remote files that somehow missed our buffer-specific registration
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = { "scp://*", "rsync://*" },
        group = fallback_augroup,
        callback = function(ev)
            -- Skip if this buffer already has buffer-specific autocommands
            if migration.get_has_specific_autocmds(ev.buf) then
                utils.log(
                    "FALLBACK BufWriteCmd skipped for buffer " .. ev.buf .. " (has buffer-specific autocommands)",
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                return true -- Let the buffer-specific autocommand handle it
            end

            -- Get buffer name for detailed logging
            local bufname = vim.api.nvim_buf_get_name(ev.buf)
            utils.log(
                "FALLBACK BufWriteCmd triggered for buffer " .. ev.buf .. ": " .. bufname,
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Double-check protocol and make absolutely sure netrw is disabled
            vim.g.netrw_rsync_cmd = "echo 'Disabled by async-remote-write plugin'"
            vim.g.netrw_scp_cmd = "echo 'Disabled by async-remote-write plugin'"

            -- Register proper buffer-specific autocommands for next time
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 10)

            -- Try to start the save process
            -- Need to require here to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            local ok, result = pcall(function()
                return operations.start_save_process(ev.buf)
            end)

            if not ok then
                -- If there was an error in the save process, log it but still return true
                utils.log("Error in async save process: " .. tostring(result), vim.log.levels.ERROR, false, config.config)
                -- Set unmodified anyway to avoid repeated save attempts
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
                return true
            end

            if not result then
                -- If start_save_process returned false, log warning but still return true
                -- This prevents netrw from taking over
                utils.log(
                    "Failed to start async save process, but preventing netrw fallback",
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                -- Set unmodified anyway to avoid repeated save attempts
                pcall(vim.api.nvim_buf_set_option, ev.buf, "modified", false)
            end

            -- Always return true to prevent netrw fallback
            return true
        end,
        desc = "Fallback handler for remote file saving asynchronously",
    })

    -- Also intercept FileWriteCmd as a backup
    vim.api.nvim_create_autocmd("FileWriteCmd", {
        pattern = { "scp://*", "rsync://*" },
        group = fallback_augroup,
        callback = function(ev)
            utils.log("FALLBACK FileWriteCmd triggered for " .. ev.file, vim.log.levels.DEBUG, false, config.config)

            -- Find which buffer has this file
            local bufnr = nil
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(buf) == ev.file then
                    bufnr = buf
                    break
                end
            end

            if not bufnr then
                utils.log("No buffer found for " .. ev.file, vim.log.levels.ERROR, false, config.config)
                return true
            end

            -- Register proper buffer-specific autocommands for next time
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    M.register_buffer_autocommands(bufnr)
                end
            end, 10)

            -- Use the same handler as BufWriteCmd
            -- Need to require here to avoid circular dependency
            if not operations then
                operations = require("async-remote-write.operations")
            end

            local ok, result = pcall(function()
                return operations.start_save_process(bufnr)
            end)

            if not ok or not result then
                utils.log(
                    "FileWriteCmd handler fallback: setting buffer as unmodified",
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
                pcall(vim.api.nvim_buf_set_option, bufnr, "modified", false)
            end

            return true
        end,
    })

    -- FALLBACK: Text change monitoring for buffers without buffer-specific autocommands
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
        pattern = { "scp://*", "rsync://*" },
        group = fallback_augroup,
        callback = function(ev)
            -- Skip if this buffer already has buffer-specific autocommands
            if migration.get_has_specific_autocmds(ev.buf) then
                return -- Let the buffer-specific autocommand handle it
            end

            utils.log(
                "FALLBACK " .. ev.event .. " triggered for buffer " .. ev.buf .. ", starting debounced save",
                vim.log.levels.DEBUG,
                false,
                config.config
            )

            -- Register proper buffer-specific autocommands for next time
            vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    M.register_buffer_autocommands(ev.buf)
                end
            end, 10)

            -- Start debounced save process
            if not operations then
                operations = require("async-remote-write.operations")
            end
            operations.start_save_process(ev.buf)
        end,
        desc = "Fallback text change monitoring for debounced saves",
    })

    -- Cleanup save timers when buffers are deleted
    vim.api.nvim_create_autocmd("BufDelete", {
        pattern = { "scp://*", "rsync://*" },
        group = monitor_augroup,
        callback = function(ev)
            local save_timer = migration.get_save_timer(ev.buf)
            if save_timer then
                utils.log("Cleaning up save timer for deleted buffer " .. ev.buf, vim.log.levels.DEBUG, false, config.config)
                if not save_timer:is_closing() then
                    save_timer:close()
                end
                migration.set_save_timer(ev.buf, nil)
            end
        end,
        desc = "Cleanup save timers on buffer deletion",
    })
end

function M.register_existing_buffers()
    -- Register autocommands for any already-open remote buffers
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local bufname = vim.api.nvim_buf_get_name(bufnr)
            if bufname:match("^scp://") or bufname:match("^rsync://") then
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.register_buffer_autocommands(bufnr)
                    end
                end, 100)
            end
        end
    end
end

return M
