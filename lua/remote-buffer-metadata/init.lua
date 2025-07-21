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
    -- Check if vim is available and buffer is valid
    if not vim or not vim.api or not vim.b or not vim.api.nvim_buf_is_valid(bufnr) then
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
    -- Check if vim is available and buffer is valid
    if not vim or not vim.api or not vim.b or not vim.api.nvim_buf_is_valid(bufnr) then
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
        local result = {}
        for k, _ in pairs(index[value]) do
            table.insert(result, k)
        end
        return result
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
