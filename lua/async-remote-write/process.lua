local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local buffer = require('async-remote-write.buffer')

-- Track ongoing write operations
-- Map of bufnr -> {job_id = job_id, start_time = timestamp, ...}
local active_writes = {}

-- Function to get active_writes (used by other modules)
function M.get_active_writes()
    return active_writes
end

-- Function to handle write completion
local function on_write_complete(bufnr, job_id, exit_code, error_msg)
    local lsp = require('async-remote-write.lsp')

    -- Get current write info and validate
    local write_info = active_writes[bufnr]
    if not write_info then
        utils.log("No active write found for buffer " .. bufnr, vim.log.levels.WARN, false, config.config)
        return
    end

    if write_info.job_id ~= job_id then
        utils.log("Job ID mismatch for buffer " .. bufnr, vim.log.levels.WARN, false, config.config)
        return
    end

    -- Check if buffer still exists
    local buffer_exists = vim.api.nvim_buf_is_valid(bufnr)
    utils.log(string.format("Write complete for buffer %d with exit code %d (buffer exists: %s)",
                    bufnr, exit_code, tostring(buffer_exists)), vim.log.levels.DEBUG, false, config.config)

    -- Stop timer if it exists
    if write_info.timer then
        utils.safe_close_timer(write_info.timer)
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

    buffer.track_buffer_state_after_save(bufnr)

    -- Remove from active writes table
    active_writes[bufnr] = nil

    -- Notify LSP module that save is complete
    vim.schedule(function()
        lsp.notify_save_end(bufnr)

        -- Verify LSP connection still exists
        if #lsp_clients > 0 and buffer_exists then
            -- Double-check LSP clients are still attached
            local current_clients = vim.lsp.get_active_clients({ bufnr = bufnr })
            if #current_clients == 0 then
                utils.log("LSP clients were disconnected during save, attempting to reconnect", vim.log.levels.WARN, false, config.config)

                -- Attempt to restart LSP
                local remote_lsp = require("remote-lsp")
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        remote_lsp.start_remote_lsp(bufnr)
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

                -- Reregister autocommands for this buffer
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        buffer.register_buffer_autocommands(bufnr)
                    end
                end, 10)

                -- Update status line
                local short_name = vim.fn.fnamemodify(buffer_name, ":t")
                utils.log(string.format("✓ File '%s' saved in %s", short_name, duration_str), vim.log.levels.INFO, true, config.config)
            else
                utils.log(string.format("✓ File saved in %s (buffer no longer exists)", duration_str), vim.log.levels.INFO, true, config.config)
            end
        end)
    else
        local error_info = error_msg or ""
        vim.schedule(function()
            if buffer_exists then
                local short_name = vim.fn.fnamemodify(buffer_name, ":t")
                utils.log(string.format("❌ Failed to save '%s': %s", short_name, error_info), vim.log.levels.ERROR, true, config.config)
            else
                utils.log(string.format("❌ Failed to save file: %s", error_info), vim.log.levels.ERROR, true, config.config)
            end
        end)
    end
end

-- Set up a timer to monitor job progress
function M.setup_job_timer(bufnr)
    local timer = vim.loop.new_timer()

    -- Check job status regularly
    timer:start(1000, config.config.check_interval, vim.schedule_wrap(function()
        local write_info = active_writes[bufnr]
        if not write_info then
            utils.safe_close_timer(timer)
            return
        end

        -- Update elapsed time
        local elapsed = os.time() - write_info.start_time
        write_info.elapsed = elapsed

        -- Check if job is still running
        local job_running = vim.fn.jobwait({write_info.job_id}, 0)[1] == -1

        if not job_running then
            -- Job finished but callback wasn't triggered
            utils.log("Job finished but callback wasn't triggered, forcing completion", vim.log.levels.WARN, false, config.config)
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 0)
            end)
            utils.safe_close_timer(timer)
        elseif elapsed > config.config.timeout then
            -- Job timed out
            utils.log("Job timed out after " .. elapsed .. " seconds", vim.log.levels.WARN, false, config.config)
            pcall(vim.fn.jobstop, write_info.job_id)
            vim.schedule(function()
                on_write_complete(bufnr, write_info.job_id, 1, "Timeout after " .. elapsed .. " seconds")
            end)
            utils.safe_close_timer(timer)
        end
    end))

    return timer
end

-- Force complete a stuck write operation
function M.force_complete(bufnr, success)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    success = success or false

    local write_info = active_writes[bufnr]
    if not write_info then
        utils.log("No active write operation for this buffer", vim.log.levels.WARN, true, config.config)
        return false
    end

    -- Stop the job if it's still running
    pcall(vim.fn.jobstop, write_info.job_id)

    -- Force completion
    on_write_complete(bufnr, write_info.job_id, success and 0 or 1,
        success and nil or "Manually forced completion")

    utils.log(success and "✓ Write operation marked as completed" or
        "✓ Write operation marked as failed", vim.log.levels.INFO, true, config.config)

    return true
end

-- Cancel an ongoing write operation
function M.cancel_write(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local write_info = active_writes[bufnr]
    if not write_info then
        utils.log("No active write operation to cancel", vim.log.levels.WARN, true, config.config)
        return false
    end

    -- Stop the job
    pcall(vim.fn.jobstop, write_info.job_id)

    -- Force completion with error
    on_write_complete(bufnr, write_info.job_id, 1, "Cancelled by user")

    utils.log("✓ Write operation cancelled", vim.log.levels.INFO, true, config.config)
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

    utils.log(string.format("Active write operations: %d", count), vim.log.levels.INFO, true, config.config)

    for _, detail in ipairs(details) do
        utils.log(string.format("  Buffer %d: %s (%s to %s) - running for %ds (job %d)",
            detail.bufnr, detail.name, detail.protocol, detail.host, detail.elapsed, detail.job_id),
            vim.log.levels.INFO, true, config.config)
    end

    return {
        count = count,
        details = details
    }
end

-- Export the on_write_complete function and active_writes for use by operations.lua
M._internal = {
    on_write_complete = on_write_complete,
    active_writes = active_writes
}

return M
