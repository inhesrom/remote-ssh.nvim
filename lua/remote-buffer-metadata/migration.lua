local M = {}
local metadata = require("remote-buffer-metadata")

-- Migration state
local migration_active = false -- Migration completed - now using new system only
local legacy_modules = {}

function M.register_legacy_module(module_name, legacy_tables)
    legacy_modules[module_name] = legacy_tables
end

-- Compatibility wrapper functions
function M.get_buffer_clients(bufnr)
    if migration_active then
        -- Try new system first, fallback to legacy
        local clients = metadata.get(bufnr, "remote-lsp", "clients")
        if clients and not vim.tbl_isempty(clients) then
            return clients
        end

        -- Fallback to legacy system
        local remote_lsp_buffer = package.loaded["remote-lsp.buffer"]
        if remote_lsp_buffer and remote_lsp_buffer.buffer_clients then
            return remote_lsp_buffer.buffer_clients[bufnr] or {}
        end
    end

    return metadata.get(bufnr, "remote-lsp", "clients") or {}
end

function M.set_buffer_client(bufnr, client_id, active)
    local clients = M.get_buffer_clients(bufnr)
    if active then
        clients[client_id] = true
    else
        clients[client_id] = nil
    end

    -- If no clients left, clear the entire clients table
    local has_clients = false
    for _, _ in pairs(clients) do
        has_clients = true
        break
    end

    if has_clients then
        metadata.set(bufnr, "remote-lsp", "clients", clients)
    else
        metadata.set(bufnr, "remote-lsp", "clients", {})
    end

    -- Also update legacy system during migration
    if migration_active then
        local remote_lsp_buffer = package.loaded["remote-lsp.buffer"]
        if remote_lsp_buffer and remote_lsp_buffer.buffer_clients then
            if active then
                if not remote_lsp_buffer.buffer_clients[bufnr] then
                    remote_lsp_buffer.buffer_clients[bufnr] = {}
                end
                remote_lsp_buffer.buffer_clients[bufnr][client_id] = true
            else
                if remote_lsp_buffer.buffer_clients[bufnr] then
                    remote_lsp_buffer.buffer_clients[bufnr][client_id] = nil
                    -- If no clients left, remove the buffer entry entirely
                    local buffer_has_clients = false
                    for _, _ in pairs(remote_lsp_buffer.buffer_clients[bufnr]) do
                        buffer_has_clients = true
                        break
                    end
                    if not buffer_has_clients then
                        remote_lsp_buffer.buffer_clients[bufnr] = nil
                    end
                end
            end
        end
    end
end

function M.get_server_buffers(server_key)
    -- Use reverse index from new system
    local buffers = metadata.get_reverse_index("remote-lsp", "server_buffers", server_key)

    if migration_active and vim.tbl_isempty(buffers) then
        -- Fallback to legacy system
        local remote_lsp_buffer = package.loaded["remote-lsp.buffer"]
        if remote_lsp_buffer and remote_lsp_buffer.server_buffers and remote_lsp_buffer.server_buffers[server_key] then
            buffers = {}
            for bufnr, _ in pairs(remote_lsp_buffer.server_buffers[server_key]) do
                table.insert(buffers, bufnr)
            end
        end
    end

    return buffers
end

function M.set_server_buffer(server_key, bufnr, active)
    metadata.set(bufnr, "remote-lsp", "server_key", active and server_key or nil)

    -- Also update legacy system during migration
    if migration_active then
        local remote_lsp_buffer = package.loaded["remote-lsp.buffer"]
        if remote_lsp_buffer and remote_lsp_buffer.server_buffers then
            if not remote_lsp_buffer.server_buffers[server_key] then
                remote_lsp_buffer.server_buffers[server_key] = {}
            end
            remote_lsp_buffer.server_buffers[server_key][bufnr] = active and true or nil
        end
    end
end

-- Save state compatibility
function M.get_save_in_progress(bufnr)
    local in_progress = metadata.get(bufnr, "remote-lsp", "save_in_progress")

    if migration_active and not in_progress then
        local remote_lsp_buffer = package.loaded["remote-lsp.buffer"]
        if remote_lsp_buffer and remote_lsp_buffer.buffer_save_in_progress then
            in_progress = remote_lsp_buffer.buffer_save_in_progress[bufnr] or false
        end
    end

    return in_progress
end

function M.set_save_in_progress(bufnr, in_progress)
    -- Check if buffer is valid first
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local success = metadata.set(bufnr, "remote-lsp", "save_in_progress", in_progress)
    if success and in_progress then
        metadata.set(bufnr, "remote-lsp", "save_timestamp", os.time())
    elseif success and not in_progress then
        metadata.set(bufnr, "remote-lsp", "save_timestamp", nil)
    end

    -- Also update legacy system during migration
    if migration_active then
        local remote_lsp_buffer = package.loaded["remote-lsp.buffer"]
        if remote_lsp_buffer then
            if remote_lsp_buffer.buffer_save_in_progress then
                remote_lsp_buffer.buffer_save_in_progress[bufnr] = in_progress and true or nil
            end
            if remote_lsp_buffer.buffer_save_timestamps then
                remote_lsp_buffer.buffer_save_timestamps[bufnr] = in_progress and os.time() or nil
            end
        end
    end

    return success
end

-- Active writes compatibility
function M.get_active_write(bufnr)
    local active_write = metadata.get(bufnr, "async-remote-write", "active_write")

    if migration_active and not active_write then
        local process_module = package.loaded["async-remote-write.process"]
        if process_module then
            local active_writes = process_module.get_active_writes()
            active_write = active_writes[bufnr]
        end
    end

    return active_write
end

function M.set_active_write(bufnr, write_info)
    metadata.set(bufnr, "async-remote-write", "active_write", write_info)

    -- Also update legacy system during migration
    if migration_active then
        local process_module = package.loaded["async-remote-write.process"]
        if process_module then
            local active_writes = process_module.get_active_writes()
            active_writes[bufnr] = write_info
        end
    end
end

-- Save timer compatibility
function M.get_save_timer(bufnr)
    return metadata.get(bufnr, "async-remote-write", "save_timer")
end

function M.set_save_timer(bufnr, timer)
    metadata.set(bufnr, "async-remote-write", "save_timer", timer)
end

-- Buffer state compatibility
function M.get_buffer_state(bufnr)
    local buffer_state = metadata.get(bufnr, "async-remote-write", "buffer_state")

    if migration_active and not buffer_state then
        local buffer_module = package.loaded["async-remote-write.buffer"]
        if buffer_module and buffer_module.buffer_state_after_save then
            buffer_state = buffer_module.buffer_state_after_save[bufnr]
        end
    end

    return buffer_state
end

function M.set_buffer_state(bufnr, state)
    metadata.set(bufnr, "async-remote-write", "buffer_state", state)

    -- Also update legacy system during migration
    if migration_active then
        local buffer_module = package.loaded["async-remote-write.buffer"]
        if buffer_module and buffer_module.buffer_state_after_save then
            buffer_module.buffer_state_after_save[bufnr] = state
        end
    end
end

-- Has specific autocmds compatibility
function M.get_has_specific_autocmds(bufnr)
    local has_autocmds = metadata.get(bufnr, "async-remote-write", "has_specific_autocmds")

    if migration_active and not has_autocmds then
        local buffer_module = package.loaded["async-remote-write.buffer"]
        if buffer_module and buffer_module.buffer_has_specific_autocmds then
            has_autocmds = buffer_module.buffer_has_specific_autocmds[bufnr] or false
        end
    end

    return has_autocmds
end

function M.set_has_specific_autocmds(bufnr, has_autocmds)
    metadata.set(bufnr, "async-remote-write", "has_specific_autocmds", has_autocmds)

    -- Also update legacy system during migration
    if migration_active then
        local buffer_module = package.loaded["async-remote-write.buffer"]
        if buffer_module then
            if not buffer_module.buffer_has_specific_autocmds then
                buffer_module.buffer_has_specific_autocmds = {}
            end
            buffer_module.buffer_has_specific_autocmds[bufnr] = has_autocmds and true or nil
        end
    end
end

-- Migration completion
function M.complete_migration()
    migration_active = false

    -- Clear legacy tables
    for module_name, tables in pairs(legacy_modules) do
        local module = package.loaded[module_name]
        if module then
            for table_name, _ in pairs(tables) do
                if module[table_name] then
                    module[table_name] = {}
                end
            end
        end
    end
end

function M.is_migration_active()
    return migration_active
end

-- Initialize schemas on first load
local function init_schemas()
    local schemas = require("remote-buffer-metadata.schemas")

    -- Register all schemas
    for schema_name, schema_def in pairs(schemas) do
        metadata.register_schema(schema_name, schema_def)
    end

    -- Setup automatic cleanup only if vim is available
    if vim and vim.api then
        metadata.setup_cleanup()
    end
end

-- Auto-initialize when module is loaded
init_schemas()

return M
