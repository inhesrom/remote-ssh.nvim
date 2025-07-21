local M = {}

-- Central registries
local metadata_schemas = {}
local default_values = {}
local cleanup_handlers = {}
local reverse_indexes = {}
-- Store non-serializable objects separately (these won't persist across Neovim sessions)
local non_serializable_storage = {}

-- Helper function to check if a value is serializable
local function is_serializable(value)
    local value_type = type(value)
    
    -- Basic serializable types
    if value_type == "nil" or value_type == "boolean" or value_type == "number" or value_type == "string" then
        return true
    end
    
    -- Tables need recursive checking
    if value_type == "table" then
        for k, v in pairs(value) do
            if not is_serializable(k) or not is_serializable(v) then
                return false
            end
        end
        return true
    end
    
    -- Functions, userdata, threads are not serializable
    return false
end

-- Simplified approach: check if entire value tree is serializable
local function prepare_for_storage(value)
    if is_serializable(value) then
        -- Value is fully serializable, store normally
        return value, nil
    else
        -- Value has non-serializable parts, store placeholder and keep original separately
        return "_NON_SERIALIZABLE_", value
    end
end

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

    local data = metadata[plugin_name]
    if key then
        local value = data[key]
        -- Check if this is a non-serializable placeholder
        if value == "_NON_SERIALIZABLE_" then
            local storage_key = bufnr .. ":" .. plugin_name .. ":" .. key
            return non_serializable_storage[storage_key]
        end
        return value
    else
        -- Return the full plugin data
        local result = {}
        for k, v in pairs(data) do
            if v == "_NON_SERIALIZABLE_" then
                local storage_key = bufnr .. ":" .. plugin_name .. ":" .. k
                result[k] = non_serializable_storage[storage_key]
            else
                result[k] = v
            end
        end
        return result
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

    -- Get old value
    local old_value = M.get(bufnr, plugin_name, key)
    
    -- Prepare value for storage
    local storage_value, non_serializable_value = prepare_for_storage(value)
    
    -- Clean up old non-serializable storage for this key
    local storage_key = bufnr .. ":" .. plugin_name .. ":" .. key
    non_serializable_storage[storage_key] = nil
    
    -- Update the metadata
    metadata[plugin_name][key] = storage_value
    vim.b[bufnr].remote_metadata = metadata
    
    -- Store non-serializable part separately if needed
    if non_serializable_value then
        non_serializable_storage[storage_key] = non_serializable_value
    end

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
                    
                    -- Clean up non-serializable storage for this plugin
                    -- Remove all storage keys that start with bufnr:plugin_name:
                    local prefix = bufnr .. ":" .. plugin_name .. ":"
                    for storage_key in pairs(non_serializable_storage) do
                        if storage_key:sub(1, #prefix) == prefix then
                            non_serializable_storage[storage_key] = nil
                        end
                    end
                end
            end
        end
    })
end

return M
