-- LSP mocks for testing future functionality
local M = {}

-- Control variables for mock behavior
M._simulate_failure = false
M._simulate_proxy_failure = false

-- Mock implementations for functions that don't exist yet but tests expect

-- Mock remote-lsp.client functions
M.client_mocks = {
    start_lsp_server = function(config)
        if config and config.host and config.server_name then
            -- Check if we should simulate failure based on server name
            if config.server_name == "rust_analyzer" and M._simulate_failure then
                return false
            end
            return true -- Success
        end
        return false -- Failure
    end,

    get_server_config = function(server_name, config)
        return {
            root_dir = config.root_dir,
            file_types = config.file_types or { "rust" },
            init_options = {},
            capabilities = {
                workspace = {
                    workspaceFolders = true,
                },
            },
            watch_files = true,
        }
    end,

    initialize_with_capabilities = function(config)
        return config and config.host and config.server_name
    end,

    register_capability = function(registration)
        return registration and registration.id and registration.method
    end,

    shutdown_client = function(client_key)
        if M.client_mocks._active_clients[client_key] then
            M.client_mocks._active_clients[client_key] = nil
            return true
        end
        return false
    end,

    handle_registration_request = function(params)
        return params and params.registrations and #params.registrations > 0
    end,

    restart_server = function(server_id)
        return server_id ~= nil
    end,

    create_client = function(config)
        if config and config.host and config.server_name then
            return {
                file_watcher_config = config.file_watching or {
                    patterns = { "**/*.rs" },
                },
            }
        end
        return nil
    end,

    -- Mock client registry
    _active_clients = {},
}

-- Mock remote-lsp.handlers functions
M.handlers_mocks = {
    create_initialization_params = function(params)
        return {
            rootUri = params.root_uri,
            capabilities = params.capabilities or {
                workspace = {
                    didChangeWatchedFiles = { dynamicRegistration = true },
                    workspaceEdit = { documentChanges = true },
                },
            },
        }
    end,

    get_default_capabilities = function()
        return {
            workspace = {
                didChangeWatchedFiles = { dynamicRegistration = true },
                workspaceEdit = { documentChanges = true },
                didChangeConfiguration = { dynamicRegistration = true },
            },
            textDocument = {
                publishDiagnostics = { relatedInformation = true },
            },
        }
    end,

    translate_uri_to_remote = function(message, local_root, remote_root)
        local result = vim.deepcopy(message)
        if result.params and result.params.textDocument and result.params.textDocument.uri then
            result.params.textDocument.uri = result.params.textDocument.uri:gsub(local_root, remote_root)
        end
        return result
    end,

    process_message = function(message, context)
        -- Simple passthrough for most messages
        return message
    end,

    process_response = function(response, context)
        return response
    end,

    process_server_capabilities = function(capabilities)
        return capabilities
    end,

    create_file_change_notification = function(file_event, context)
        return {
            method = "workspace/didChangeWatchedFiles",
            params = {
                changes = {
                    {
                        uri = file_event.file_path:gsub(context.remote_root, "file://" .. context.local_root),
                        type = file_event.event_type == "modify" and 2 or 1,
                    },
                },
            },
        }
    end,

    batch_file_change_notifications = function(file_events, context)
        local changes = {}
        for _, event in ipairs(file_events) do
            table.insert(changes, {
                uri = event.file_path:gsub(context.remote_root, "file://" .. context.local_root),
                type = event.event_type == "modify" and 2 or 1,
            })
        end
        return {
            method = "workspace/didChangeWatchedFiles",
            params = { changes = changes },
        }
    end,

    filter_file_events = function(file_events, patterns)
        local filtered = {}
        for _, event in ipairs(file_events) do
            for _, pattern in ipairs(patterns) do
                if event.file_path:match(pattern:gsub("%*%*", ".*"):gsub("%*", "[^/]*")) then
                    table.insert(filtered, event)
                    break
                end
            end
        end
        return filtered
    end,

    create_git_change_notifications = function(git_event, context)
        return { git_event } -- Simple mock
    end,
}

-- Mock remote-lsp.utils functions
M.utils_mocks = {
    detect_file_watcher_capabilities = function(host)
        return {
            inotify_available = true,
            inotify_path = "/usr/bin/inotifywait",
        }
    end,

    build_inotify_command = function(path, config)
        local cmd = "inotifywait"
        if config.recursive then
            cmd = cmd .. " -r"
        end
        cmd = cmd .. " " .. path
        return cmd
    end,

    debounce_file_events = function(events, debounce_ms)
        -- Simple mock: just return last event for same file
        local debounced = {}
        local seen = {}
        for _, event in ipairs(events) do
            if not seen[event.file_path] then
                table.insert(debounced, event)
                seen[event.file_path] = true
            end
        end
        return debounced
    end,

    prioritize_file_events = function(file_events)
        table.sort(file_events, function(a, b)
            local priority_order = { high = 1, medium = 2, low = 3 }
            return (priority_order[a.priority] or 2) < (priority_order[b.priority] or 2)
        end)
        return file_events
    end,

    setup_file_watcher = function(config)
        if config.fallback_to_polling then
            return {
                type = "polling",
                interval = config.poll_interval or 5000,
            }
        end
        return {
            type = "inotify",
            patterns = config.patterns or {},
        }
    end,
}

-- Mock remote-lsp.proxy functions (this module doesn't exist yet)
M.proxy_mocks = {
    process_message = function(message, context)
        local result = vim.deepcopy(message)
        if context and context.remote_root and context.local_root then
            -- Simple URI translation mock
            local function translate_uri(uri)
                if uri and type(uri) == "string" then
                    return uri:gsub(context.remote_root, context.local_root)
                end
                return uri
            end

            -- Recursively translate URIs in the message
            local function translate_recursive(obj)
                if type(obj) == "table" then
                    for k, v in pairs(obj) do
                        if k == "uri" then
                            obj[k] = translate_uri(v)
                        elseif type(v) == "table" then
                            translate_recursive(v)
                        end
                    end
                end
            end

            translate_recursive(result)
        end
        return result
    end,

    process_response = function(response, context)
        return M.proxy_mocks.process_message(response, context)
    end,

    translate_uri_to_local = function(uri, remote_root, local_root)
        -- Handle different URI schemes properly
        if uri:match("^git://") then
            return uri:gsub("remote", "local")
        elseif uri:match("^ssh://") then
            -- Extract path from ssh://user@host/path and convert to file://
            local path = uri:match("ssh://[^/]+(.*)$")
            if path then
                return "file://" .. local_root .. path:gsub("^/project", "")
            end
            return uri:gsub(remote_root, "file://" .. local_root)
        else
            return uri:gsub(remote_root, local_root)
        end
    end,

    start_proxy = function(config)
        if config and config.host then
            -- Check if we should simulate failure
            if M._simulate_proxy_failure then
                return nil
            end
            return math.random(1000, 9999) -- Mock proxy ID
        end
        return nil
    end,

    check_and_recover_connection = function(proxy_id)
        return proxy_id ~= nil
    end,
}

-- Function to enable LSP mocks
function M.enable_lsp_mocks()
    -- Clear any existing modules to force reload with mocks
    package.loaded["remote-lsp.client"] = nil
    package.loaded["remote-lsp.handlers"] = nil
    package.loaded["remote-lsp.utils"] = nil
    package.loaded["remote-lsp.proxy"] = nil

    -- Load modules and extend with mock functions
    package.loaded["remote-lsp.client"] = setmetatable(M.client_mocks, {
        __index = function(t, k)
            if k == "active_lsp_clients" then
                return t._active_clients
            end
            return rawget(t, k)
        end,
    })

    package.loaded["remote-lsp.handlers"] = M.handlers_mocks

    -- For utils, just use mocks for now to avoid circular dependencies
    package.loaded["remote-lsp.utils"] = M.utils_mocks

    package.loaded["remote-lsp.proxy"] = M.proxy_mocks
end

-- Function to disable LSP mocks
function M.disable_lsp_mocks()
    package.loaded["remote-lsp.client"] = nil
    package.loaded["remote-lsp.handlers"] = nil
    package.loaded["remote-lsp.proxy"] = nil
    package.loaded["remote-lsp.utils"] = nil

    -- Clear preload functions
    package.preload["remote-lsp.client"] = nil
    package.preload["remote-lsp.handlers"] = nil
    package.preload["remote-lsp.utils"] = nil
    package.preload["remote-lsp.proxy"] = nil
end

return M
