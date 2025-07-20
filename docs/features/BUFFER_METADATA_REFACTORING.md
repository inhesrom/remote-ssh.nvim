# Buffer Metadata Refactoring Plan

## Executive Summary

This document outlines a comprehensive plan to refactor the remote-ssh.nvim plugin from global tracking tables to buffer-local metadata storage. This refactoring will create a more maintainable, extensible architecture that automatically handles memory management and provides a foundation for other remote buffer plugins.

## Current Architecture Analysis

### Global Tracking Tables in Use

The current codebase uses multiple global module tables to track buffer state:

#### LSP Module (`lua/remote-lsp/buffer.lua`)
```lua
M.buffer_clients = {}           -- bufnr -> {client_id -> true}
M.server_buffers = {}           -- server_key -> {bufnr -> true}
M.buffer_save_in_progress = {}  -- bufnr -> boolean
M.buffer_save_timestamps = {}   -- bufnr -> timestamp
```

#### Async Write Module (`lua/async-remote-write/`)
```lua
-- process.lua
local active_writes = {}        -- bufnr -> {job_id, start_time, ...}

-- buffer.lua
local buffer_state_after_save = {}  -- bufnr -> {time, buftype, ...}
M.buffer_has_specific_autocmds = {} -- bufnr -> boolean
```

### Current Problems

1. **Manual Memory Management**: Each module must implement cleanup logic in autocommands
2. **Memory Leaks**: Risk of orphaned entries when cleanup fails
3. **Scattered State**: Buffer metadata spread across multiple global tables
4. **No Type Safety**: No validation or schema enforcement
5. **Poor Extensibility**: Hard for other plugins to add their own metadata
6. **Complex Cleanup Logic**: 100+ lines of autocommand cleanup code per module

## Proposed Architecture: Buffer-Local Metadata System

### Core Design Principles

1. **Centralized Metadata API**: Unified buffer metadata management system
2. **Extensible Schema**: Plugin-specific metadata schemas with validation
3. **Automatic Cleanup**: Buffer deletion automatically cleans up all metadata
4. **Type Safety**: Schema validation and default values
5. **Migration Support**: Gradual migration with compatibility wrappers
6. **Plugin Ecosystem**: Enable other remote buffer plugins to use the same system

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                 Buffer-Local Metadata System                │
├─────────────────────────────────────────────────────────────┤
│  Core API (remote-buffer-metadata)                         │
│  ├── Schema Registry                                       │
│  ├── Type Validation                                       │
│  ├── Default Values                                        │
│  └── Migration Utilities                                   │
├─────────────────────────────────────────────────────────────┤
│  Plugin Schemas                                            │
│  ├── remote-lsp: {clients, server_key, save_state}        │
│  ├── async-remote-write: {host, protocol, sync_state}     │
│  ├── file-watching: {enabled, intervals, timestamps}      │
│  └── [extensible for other plugins]                       │
├─────────────────────────────────────────────────────────────┤
│  Storage Layer                                             │
│  └── vim.b[bufnr].remote_metadata = {plugin_name: data}   │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1)

#### Create Core Metadata Module

**File: `lua/remote-buffer-metadata/init.lua`**
```lua
local M = {}

-- Central registries
local metadata_schemas = {}
local default_values = {}
local cleanup_handlers = {}
local reverse_indexes = {}

-- Schema registration for plugins
function M.register_schema(plugin_name, schema)
    metadata_schemas[plugin_name] = schema
    default_values[plugin_name] = schema.defaults or {}
    cleanup_handlers[plugin_name] = schema.cleanup

    -- Initialize reverse indexes if specified
    if schema.reverse_indexes then
        for _, index_def in ipairs(schema.reverse_indexes) do
            local index_key = plugin_name .. ":" .. index_def.name
            reverse_indexes[index_key] = {}
        end
    end
end

-- Core metadata access
function M.get(bufnr, plugin_name, key)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local metadata = vim.b[bufnr].remote_metadata or {}
    if not metadata[plugin_name] then
        metadata[plugin_name] = vim.deepcopy(default_values[plugin_name] or {})
        vim.b[bufnr].remote_metadata = metadata
    end

    if key then
        return metadata[plugin_name][key]
    else
        return metadata[plugin_name]
    end
end

function M.set(bufnr, plugin_name, key, value)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local metadata = vim.b[bufnr].remote_metadata or {}
    if not metadata[plugin_name] then
        metadata[plugin_name] = vim.deepcopy(default_values[plugin_name] or {})
    end

    -- Validate if schema exists
    local schema = metadata_schemas[plugin_name]
    if schema and schema.validators and schema.validators[key] then
        if not schema.validators[key](value) then
            error(string.format("Invalid value for %s.%s: %s", plugin_name, key, vim.inspect(value)))
        end
    end

    local old_value = metadata[plugin_name][key]
    metadata[plugin_name][key] = value
    vim.b[bufnr].remote_metadata = metadata

    -- Update reverse indexes
    M._update_reverse_indexes(bufnr, plugin_name, key, old_value, value)

    return true
end

-- Atomic updates
function M.update(bufnr, plugin_name, update_fn)
    local data = M.get(bufnr, plugin_name)
    if data then
        update_fn(data)
        vim.b[bufnr].remote_metadata[plugin_name] = data
    end
end

-- Bulk operations
function M.get_all_plugin_data(plugin_name)
    local result = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local data = M.get(bufnr, plugin_name)
            if data and not vim.tbl_isempty(data) then
                result[bufnr] = data
            end
        end
    end
    return result
end

-- Query buffers by metadata criteria
function M.query_buffers(plugin_name, key, value)
    local result = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local metadata_value = M.get(bufnr, plugin_name, key)
            if metadata_value == value then
                table.insert(result, bufnr)
            end
        end
    end
    return result
end

-- Reverse index management
function M._update_reverse_indexes(bufnr, plugin_name, key, old_value, new_value)
    local schema = metadata_schemas[plugin_name]
    if not schema or not schema.reverse_indexes then
        return
    end

    for _, index_def in ipairs(schema.reverse_indexes) do
        if index_def.key == key then
            local index_key = plugin_name .. ":" .. index_def.name
            local index = reverse_indexes[index_key]

            -- Remove old mapping
            if old_value and index[old_value] then
                index[old_value][bufnr] = nil
                if vim.tbl_isempty(index[old_value]) then
                    index[old_value] = nil
                end
            end

            -- Add new mapping
            if new_value then
                if not index[new_value] then
                    index[new_value] = {}
                end
                index[new_value][bufnr] = true
            end
        end
    end
end

function M.get_reverse_index(plugin_name, index_name, value)
    local index_key = plugin_name .. ":" .. index_name
    local index = reverse_indexes[index_key]
    if index and index[value] then
        return vim.tbl_keys(index[value])
    end
    return {}
end

-- Setup automatic cleanup
function M.setup_cleanup()
    local augroup = vim.api.nvim_create_augroup("RemoteBufferMetadataCleanup", { clear = true })

    vim.api.nvim_create_autocmd({"BufDelete", "BufWipeout"}, {
        group = augroup,
        callback = function(ev)
            local bufnr = ev.buf
            local metadata = vim.b[bufnr].remote_metadata

            if metadata then
                -- Run plugin-specific cleanup handlers
                for plugin_name, plugin_data in pairs(metadata) do
                    local cleanup_fn = cleanup_handlers[plugin_name]
                    if cleanup_fn then
                        pcall(cleanup_fn, bufnr, plugin_data)
                    end

                    -- Clean up reverse indexes
                    local schema = metadata_schemas[plugin_name]
                    if schema and schema.reverse_indexes then
                        for _, index_def in ipairs(schema.reverse_indexes) do
                            local value = plugin_data[index_def.key]
                            if value then
                                M._update_reverse_indexes(bufnr, plugin_name, index_def.key, value, nil)
                            end
                        end
                    end
                end
            end
        end
    })
end

return M
```

#### Create Schema Definitions

**File: `lua/remote-buffer-metadata/schemas.lua`**
```lua
local M = {}

-- Remote LSP schema
M.remote_lsp = {
    defaults = {
        clients = {},           -- client_id -> true
        server_key = nil,       -- server_name@host
        save_in_progress = false,
        save_timestamp = nil,
        project_root = nil
    },
    validators = {
        clients = function(v) return type(v) == "table" end,
        server_key = function(v) return type(v) == "string" or v == nil end,
        save_in_progress = function(v) return type(v) == "boolean" end,
        save_timestamp = function(v) return type(v) == "number" or v == nil end,
        project_root = function(v) return type(v) == "string" or v == nil end
    },
    reverse_indexes = {
        { name = "server_buffers", key = "server_key" }
    },
    cleanup = function(bufnr, data)
        -- Custom cleanup logic for LSP clients
        if data.clients then
            for client_id, _ in pairs(data.clients) do
                -- Cleanup will be handled by migration wrappers initially
                print("Cleaning up LSP client", client_id, "for buffer", bufnr)
            end
        end
    end
}

-- Async remote write schema
M.async_remote_write = {
    defaults = {
        host = nil,
        remote_path = nil,
        protocol = nil,
        active_write = nil,     -- {job_id, start_time, timer}
        last_sync_time = nil,
        buffer_state = nil,     -- post-save state tracking
        has_specific_autocmds = false
    },
    validators = {
        host = function(v) return type(v) == "string" or v == nil end,
        protocol = function(v) return v == "scp" or v == "rsync" or v == nil end,
        active_write = function(v) return type(v) == "table" or v == nil end,
        has_specific_autocmds = function(v) return type(v) == "boolean" end
    },
    cleanup = function(bufnr, data)
        -- Clean up active write operations
        if data.active_write and data.active_write.job_id then
            vim.fn.jobstop(data.active_write.job_id)
        end
        if data.active_write and data.active_write.timer then
            data.active_write.timer:close()
        end
    end
}

-- File watching schema (new feature)
M.file_watching = {
    defaults = {
        enabled = false,
        strategy = "polling",   -- polling, inotify, hybrid
        poll_interval = 5000,
        last_remote_mtime = nil,
        last_check_time = nil,
        watch_job_id = nil,
        conflict_state = "none", -- none, detected, resolving
        auto_refresh = true
    },
    validators = {
        enabled = function(v) return type(v) == "boolean" end,
        strategy = function(v) return vim.tbl_contains({"polling", "inotify", "hybrid"}, v) end,
        poll_interval = function(v) return type(v) == "number" and v > 0 end,
        conflict_state = function(v) return vim.tbl_contains({"none", "detected", "resolving"}, v) end
    },
    cleanup = function(bufnr, data)
        -- Clean up file watching jobs
        if data.watch_job_id then
            vim.fn.jobstop(data.watch_job_id)
        end
    end
}

return M
```

### Phase 2: Migration Utilities (Week 2)

#### Create Migration Layer

**File: `lua/remote-buffer-metadata/migration.lua`**
```lua
local M = {}
local metadata = require('remote-buffer-metadata')

-- Migration state
local migration_active = true
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
        local remote_lsp_buffer = package.loaded['remote-lsp.buffer']
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

    metadata.set(bufnr, "remote-lsp", "clients", clients)

    -- Also update legacy system during migration
    if migration_active then
        local remote_lsp_buffer = package.loaded['remote-lsp.buffer']
        if remote_lsp_buffer and remote_lsp_buffer.buffer_clients then
            if not remote_lsp_buffer.buffer_clients[bufnr] then
                remote_lsp_buffer.buffer_clients[bufnr] = {}
            end
            remote_lsp_buffer.buffer_clients[bufnr][client_id] = active and true or nil
        end
    end
end

function M.get_server_buffers(server_key)
    -- Use reverse index from new system
    local buffers = metadata.get_reverse_index("remote-lsp", "server_buffers", server_key)

    if migration_active and vim.tbl_isempty(buffers) then
        -- Fallback to legacy system
        local remote_lsp_buffer = package.loaded['remote-lsp.buffer']
        if remote_lsp_buffer and remote_lsp_buffer.server_buffers and remote_lsp_buffer.server_buffers[server_key] then
            buffers = vim.tbl_keys(remote_lsp_buffer.server_buffers[server_key])
        end
    end

    return buffers
end

function M.set_server_buffer(server_key, bufnr, active)
    metadata.set(bufnr, "remote-lsp", "server_key", active and server_key or nil)

    -- Also update legacy system during migration
    if migration_active then
        local remote_lsp_buffer = package.loaded['remote-lsp.buffer']
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
        local remote_lsp_buffer = package.loaded['remote-lsp.buffer']
        if remote_lsp_buffer and remote_lsp_buffer.buffer_save_in_progress then
            in_progress = remote_lsp_buffer.buffer_save_in_progress[bufnr] or false
        end
    end

    return in_progress
end

function M.set_save_in_progress(bufnr, in_progress)
    metadata.set(bufnr, "remote-lsp", "save_in_progress", in_progress)
    if in_progress then
        metadata.set(bufnr, "remote-lsp", "save_timestamp", os.time())
    else
        metadata.set(bufnr, "remote-lsp", "save_timestamp", nil)
    end

    -- Also update legacy system during migration
    if migration_active then
        local remote_lsp_buffer = package.loaded['remote-lsp.buffer']
        if remote_lsp_buffer then
            if remote_lsp_buffer.buffer_save_in_progress then
                remote_lsp_buffer.buffer_save_in_progress[bufnr] = in_progress and true or nil
            end
            if remote_lsp_buffer.buffer_save_timestamps then
                remote_lsp_buffer.buffer_save_timestamps[bufnr] = in_progress and os.time() or nil
            end
        end
    end
end

-- Active writes compatibility
function M.get_active_write(bufnr)
    local active_write = metadata.get(bufnr, "async-remote-write", "active_write")

    if migration_active and not active_write then
        local process_module = package.loaded['async-remote-write.process']
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
        local process_module = package.loaded['async-remote-write.process']
        if process_module then
            local active_writes = process_module.get_active_writes()
            active_writes[bufnr] = write_info
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

return M
```

### Phase 3: LSP Module Migration (Week 3)

#### Update `lua/remote-lsp/buffer.lua`

Replace all global table access with migration wrapper calls:

```lua
-- Before:
M.buffer_clients[bufnr][client_id] = true

-- After:
local migration = require('remote-buffer-metadata.migration')
migration.set_buffer_client(bufnr, client_id, true)
```

```lua
-- Before:
if M.buffer_save_in_progress[bufnr] then

-- After:
local migration = require('remote-buffer-metadata.migration')
if migration.get_save_in_progress(bufnr) then
```

#### Update `lua/remote-lsp/client.lua`

Replace server-buffer tracking:

```lua
-- Before:
local server_key = utils.get_server_key(server_name, host)
if not M.server_buffers[server_key] then
    M.server_buffers[server_key] = {}
end
M.server_buffers[server_key][bufnr] = true

-- After:
local migration = require('remote-buffer-metadata.migration')
local server_key = utils.get_server_key(server_name, host)
migration.set_server_buffer(server_key, bufnr, true)
```

### Phase 4: Async Write Module Migration (Week 4)

#### Update `lua/async-remote-write/process.lua`

Replace `active_writes` table:

```lua
-- Before:
local active_writes = {}
function M.get_active_writes()
    return active_writes
end

-- After:
local migration = require('remote-buffer-metadata.migration')
function M.get_active_writes()
    -- Return legacy-compatible table during migration
    local result = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local write_info = migration.get_active_write(bufnr)
        if write_info then
            result[bufnr] = write_info
        end
    end
    return result
end
```

#### Update `lua/async-remote-write/buffer.lua`

Replace buffer state tracking:

```lua
-- Before:
local buffer_state_after_save = {}

-- After:
local metadata = require('remote-buffer-metadata')
local function get_buffer_state(bufnr)
    return metadata.get(bufnr, "async-remote-write", "buffer_state")
end
```

### Phase 5: Cleanup and Optimization (Week 5)

#### Remove Global Tables

Once migration is complete, remove all global tracking tables:

1. Remove `M.buffer_clients`, `M.server_buffers` from `remote-lsp/buffer.lua`
2. Remove `active_writes` from `async-remote-write/process.lua`
3. Remove `buffer_state_after_save` from `async-remote-write/buffer.lua`
4. Remove manual cleanup autocommands (replaced by automatic cleanup)

#### Performance Optimizations

1. **Lazy Loading**: Only load metadata when accessed
2. **Efficient Queries**: Use reverse indexes for common queries
3. **Memory Optimization**: Clear empty metadata objects
4. **Batch Updates**: Optimize bulk operations

### Phase 6: Documentation and Testing (Week 6)

#### API Documentation

**File: `docs/BUFFER_METADATA_API.md`**

Document the new API for plugin developers:

```lua
-- Plugin registration
local metadata = require('remote-buffer-metadata')
metadata.register_schema('my-plugin', {
    defaults = { enabled = false, config = {} },
    validators = { enabled = function(v) return type(v) == "boolean" end }
})

-- Basic usage
metadata.set(bufnr, 'my-plugin', 'enabled', true)
local enabled = metadata.get(bufnr, 'my-plugin', 'enabled')

-- Atomic updates
metadata.update(bufnr, 'my-plugin', function(data)
    data.enabled = true
    data.config.timeout = 5000
end)

-- Querying across buffers
local enabled_buffers = metadata.query_buffers('my-plugin', 'enabled', true)
```

#### Migration Guide

**File: `docs/MIGRATION_TO_BUFFER_METADATA.md`**

Provide migration guide for:
1. Plugin developers using the old API
2. Users with existing configurations
3. Breaking changes and compatibility notes

## Benefits of This Refactoring

### 1. Automatic Memory Management
- No more manual cleanup autocommands
- Buffer deletion automatically cleans up all metadata
- Eliminates memory leak risks

### 2. Plugin Extensibility
```lua
-- Other plugins can easily integrate
metadata.register_schema('nvim-telescope-remote', {
    defaults = { search_roots = {}, last_search = nil }
})

metadata.register_schema('gitsigns-remote', {
    defaults = { remote_git_dir = nil, branch_info = nil }
})
```

### 3. Type Safety and Validation
```lua
-- Automatic validation
metadata.set(bufnr, 'remote-lsp', 'save_in_progress', "not a boolean")  -- Error!

-- Schema defaults
local clients = metadata.get(bufnr, 'remote-lsp', 'clients')  -- Always returns table
```

### 4. Better Debugging
```lua
-- All buffer metadata visible in one place
:lua print(vim.inspect(vim.b[123].remote_metadata))
-- {
--   ["remote-lsp"] = { clients = {}, server_key = "rust-analyzer@server" },
--   ["async-remote-write"] = { host = "server", protocol = "scp" },
--   ["file-watching"] = { enabled = true, strategy = "polling" }
-- }
```

### 5. Simplified Code
- Remove 100+ lines of cleanup autocommands
- Eliminate complex cross-module dependencies
- Unified API reduces cognitive load

## Implementation Risks and Mitigations

### Risk: Buffer Variable Limitations
**Issue**: Buffer variables have serialization limitations
**Mitigation**: Schema validation ensures only serializable data

### Risk: Migration Complexity
**Issue**: Dual system during migration period
**Mitigation**: Comprehensive compatibility wrappers and testing

### Risk: Performance Impact
**Issue**: Buffer variable access might be slower than Lua tables
**Mitigation**: Benchmarking and caching for hot paths

### Risk: Backward Compatibility
**Issue**: Breaking changes for users
**Mitigation**: Gradual migration with compatibility mode

## Success Metrics

1. **Code Reduction**: Remove 200+ lines of cleanup code
2. **Memory Safety**: Zero buffer-related memory leaks
3. **Plugin Adoption**: At least 2 other remote plugins use the new system
4. **Performance**: No regression in buffer operation speed
5. **User Experience**: Seamless migration with no user action required

## Future Extensions

This architecture enables several future enhancements:

1. **Remote File Watching**: Built-in metadata schema ready
2. **Cross-Plugin Integration**: Shared metadata between remote plugins
3. **Persistence Layer**: Optional metadata persistence across sessions
4. **Analytics**: Buffer usage and performance metrics
5. **Plugin Ecosystem**: Foundation for remote development plugin ecosystem

## Conclusion

This refactoring transforms remote-ssh.nvim from a single-plugin solution to a platform for remote development tools. The buffer-local metadata system provides automatic memory management, type safety, and extensibility while significantly reducing code complexity.

The phased migration approach ensures stability during transition while the compatibility layer provides seamless upgrades for existing users. This foundation will enable rapid development of advanced features like file watching and cross-plugin integration.
