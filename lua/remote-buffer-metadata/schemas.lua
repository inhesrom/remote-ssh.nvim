local M = {}

-- Remote LSP schema
M.remote_lsp = {
    defaults = {
        clients = {}, -- client_id -> true
        server_key = nil, -- server_name@host
        save_in_progress = false,
        save_timestamp = nil,
        project_root = nil,
    },
    validators = {
        clients = function(v)
            return type(v) == "table"
        end,
        server_key = function(v)
            return type(v) == "string" or v == nil
        end,
        save_in_progress = function(v)
            return type(v) == "boolean"
        end,
        save_timestamp = function(v)
            return type(v) == "number" or v == nil
        end,
        project_root = function(v)
            return type(v) == "string" or v == nil
        end,
    },
    reverse_indexes = {
        { name = "server_buffers", key = "server_key" },
    },
    cleanup = function(bufnr, data)
        -- Custom cleanup logic for LSP clients
        if data.clients then
            for client_id, _ in pairs(data.clients) do
                -- Cleanup will be handled by migration wrappers initially
                local log = require("logging").log
                local config = require("remote-lsp.config")
                log(
                    "Cleaning up LSP client " .. client_id .. " for buffer " .. bufnr,
                    vim.log.levels.DEBUG,
                    false,
                    config.config
                )
            end
        end
    end,
}

-- Async remote write schema
M.async_remote_write = {
    defaults = {
        host = nil,
        remote_path = nil,
        protocol = nil,
        active_write = nil, -- {job_id, start_time, timer}
        last_sync_time = nil,
        buffer_state = nil, -- post-save state tracking
        has_specific_autocmds = false,
        file_permissions = nil, -- original file permissions (octal string)
        file_mode = nil, -- original file mode info
    },
    validators = {
        host = function(v)
            return type(v) == "string" or v == nil
        end,
        protocol = function(v)
            return v == "scp" or v == "rsync" or v == nil
        end,
        active_write = function(v)
            return type(v) == "table" or v == nil
        end,
        has_specific_autocmds = function(v)
            return type(v) == "boolean"
        end,
        file_permissions = function(v)
            return type(v) == "string" or v == nil
        end,
        file_mode = function(v)
            return type(v) == "string" or v == nil
        end,
    },
    cleanup = function(bufnr, data)
        -- Clean up active write operations
        if data.active_write and data.active_write.job_id then
            vim.fn.jobstop(data.active_write.job_id)
        end
        if data.active_write and data.active_write.timer then
            if type(data.active_write.timer.close) == "function" then
                data.active_write.timer:close()
            end
        end
    end,
}

-- File watching schema (new feature)
M.file_watching = {
    defaults = {
        enabled = false,
        strategy = "polling", -- polling, inotify, hybrid
        poll_interval = 5000,
        last_remote_mtime = nil,
        last_check_time = nil,
        watch_job_id = nil,
        conflict_state = "none", -- none, detected, resolving
        auto_refresh = true,
    },
    validators = {
        enabled = function(v)
            return type(v) == "boolean"
        end,
        strategy = function(v)
            return vim.tbl_contains({ "polling", "inotify", "hybrid" }, v)
        end,
        poll_interval = function(v)
            return type(v) == "number" and v > 0
        end,
        conflict_state = function(v)
            return vim.tbl_contains({ "none", "detected", "resolving" }, v)
        end,
    },
    cleanup = function(bufnr, data)
        -- Clean up file watching jobs
        if data.watch_job_id then
            vim.fn.jobstop(data.watch_job_id)
        end
    end,
}

return M
