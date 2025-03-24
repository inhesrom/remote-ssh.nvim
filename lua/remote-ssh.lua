local M = {}

local async_write = require('async-remote-write')

-- Use the consolidated logging function from async-remote-write
local log = async_write.log

-- Global variables set by setup
local on_attach
local capabilities
local server_configs = {}  -- Table to store server-specific configurations
local custom_root_dir = nil

-- Tracking structures
-- Map client_id to info about the client
local active_lsp_clients = {}
-- Map server_name+host to list of buffers using it
local server_buffers = {}
-- Map bufnr to client_ids
local buffer_clients = {}

-- Track buffer save operations to prevent LSP disconnection during save
local buffer_save_in_progress = {}
local buffer_save_timestamps = {}

-- Function to notify that a buffer save is starting - optimized to be non-blocking
local function notify_save_start(bufnr)
    -- Set the flag immediately (this is fast)
    buffer_save_in_progress[bufnr] = true
    buffer_save_timestamps[bufnr] = os.time()

    -- Log with scheduling to avoid blocking
    log("Save started for buffer " .. bufnr, vim.log.levels.DEBUG)

    -- Schedule LSP willSave notifications to avoid blocking
    vim.schedule(function()
        -- Only proceed if buffer is still valid
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        -- Notify LSP clients about willSave event if they support it
        local clients = vim.lsp.get_active_clients({ bufnr = bufnr })

        for _, client in ipairs(clients) do
            -- Skip clients that don't support document sync
            if not client.server_capabilities.textDocumentSync then
                goto continue
            end

            -- Check if client supports willSave notification
            local supports_will_save = false

            if type(client.server_capabilities.textDocumentSync) == "table" and
               client.server_capabilities.textDocumentSync.willSave then
                supports_will_save = true
            end

            if supports_will_save then
                -- Get buffer information
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                local uri = vim.uri_from_fname(bufname)

                -- Send willSave notification asynchronously
                client.notify('textDocument/willSave', {
                    textDocument = {
                        uri = uri
                    },
                    reason = 1  -- 1 = Manual save
                })
            end

            ::continue::
        end
    end)
end

local function notify_buffer_modified(bufnr)
    -- Check if the buffer is valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    -- Get all LSP clients attached to this buffer
    local clients = vim.lsp.get_active_clients({ bufnr = bufnr })

    for _, client in ipairs(clients) do
        -- Skip clients that don't support document sync
        if not client.server_capabilities.textDocumentSync then
            goto continue
        end

        -- Get buffer information
        local bufname = vim.api.nvim_buf_get_name(bufnr)

        -- Create minimal document info
        local uri = vim.uri_from_fname(bufname)
        local doc_version = vim.lsp.util.buf_versions[bufnr] or 0

        -- Increment document version
        vim.lsp.util.buf_versions[bufnr] = doc_version + 1

        -- Prepare didSave notification - don't include text unless required
        local params = {
            textDocument = {
                uri = uri,
                version = doc_version + 1
            }
        }

        -- Check if we need to include text based on server capabilities
        local include_text = false

        -- Handle different types of textDocumentSync.save
        if type(client.server_capabilities.textDocumentSync) == "table" and
           client.server_capabilities.textDocumentSync.save then
            -- If save is an object with includeText property
            if type(client.server_capabilities.textDocumentSync.save) == "table" and
               client.server_capabilities.textDocumentSync.save.includeText then
                include_text = true
            end
        end

        if include_text then
            -- We'll use a scheduled, non-blocking approach to get text if needed
            vim.schedule(function()
                -- Get buffer content
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local text = table.concat(lines, "\n")

                -- Add text to params
                params.text = text

                -- Send notification with text
                client.notify('textDocument/didSave', params)
            end)
        else
            -- If text isn't required, we can notify immediately without blocking
            client.notify('textDocument/didSave', params)
        end

        ::continue::
    end
end

-- Function to notify that a buffer save is complete - optimized to be non-blocking
local function notify_save_end(bufnr)
    -- Clear the in-progress flag and timestamp (this is fast)
    buffer_save_in_progress[bufnr] = nil
    buffer_save_timestamps[bufnr] = nil

    -- Log with scheduling to avoid blocking
    log("Save completed for buffer " .. bufnr, vim.log.levels.DEBUG)

    -- Schedule the potentially slow LSP operations
    vim.schedule(function()
        -- Only notify if buffer is still valid
        if vim.api.nvim_buf_is_valid(bufnr) then
            -- Notify any attached LSP clients that the save completed
            notify_buffer_modified(bufnr)

            -- Check if we need to restart LSP
            local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
            if #clients == 0 and buffer_clients[bufnr] and not vim.tbl_isempty(buffer_clients[bufnr]) then
                log("LSP disconnected after save, restarting", vim.log.levels.WARN)
                -- Defer to ensure buffer is stable
                vim.defer_fn(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.start_remote_lsp(bufnr)
                    end
                end, 100)
            end
        end
    end)
end

-- Setup a cleanup timer to handle stuck flags
local function setup_save_status_cleanup()
    local timer = vim.loop.new_timer()

    timer:start(15000, 15000, vim.schedule_wrap(function()
        local now = os.time()
        for bufnr, timestamp in pairs(buffer_save_timestamps) do
            if now - timestamp > 30 then -- 30 seconds max save time
                log("Detected stuck save flag for buffer " .. bufnr .. ", cleaning up", vim.log.levels.WARN)
                buffer_save_in_progress[bufnr] = nil
                buffer_save_timestamps[bufnr] = nil

                -- Also check if the buffer is still valid
                if vim.api.nvim_buf_is_valid(bufnr) then
                    -- Make sure LSP is still connected
                    local has_lsp = false
                    for client_id, info in pairs(active_lsp_clients) do
                        if info.bufnr == bufnr then
                            has_lsp = true
                            break
                        end
                    end

                    if not has_lsp then
                        log("LSP disconnected during save, attempting to reconnect", vim.log.levels.WARN)
                        -- Try to restart LSP
                        vim.schedule(function()
                            M.start_remote_lsp(bufnr)
                        end)
                    end
                end
            end
        end
    end))

    return timer
end

-- Helper function to determine protocol from bufname
local function get_protocol(bufname)
    if bufname:match("^scp://") then
        return "scp"
    elseif bufname:match("^rsync://") then
        return "rsync"
    else
        return nil
    end
end

-- Default server configurations with initialization options
local default_server_configs = {
    -- C/C++
    clangd = {
        filetypes = { "c", "cpp", "objc", "objcpp", "h", "hpp" },
        root_patterns = { ".git", "compile_commands.json", "compile_flags.txt" },
        init_options = {
            usePlaceholders = true,
            completeUnimported = true,
            clangdFileStatus = true
        }
    },
    -- Python
    pyright = {
        filetypes = { "python" },
        root_patterns = { "pyproject.toml", "setup.py", "requirements.txt", ".git" },
        init_options = {
            disableOrganizeImports = false,
            disableLanguageServices = false
        }
    },
    -- Rust
    rust_analyzer = {
        filetypes = { "rust" },
        root_patterns = { "Cargo.toml", "rust-project.json", ".git" },
        init_options = {
            cargo = {
                allFeatures = true,
            },
            procMacro = {
                enable = true
            }
        }
    },
    -- Zig
    zls = {
        filetypes = { "zig" },
        root_patterns = { "build.zig", ".git" },
        init_options = {}
    },
    -- Lua
    lua_ls = {
        filetypes = { "lua" },
        root_patterns = { ".luarc.json", ".luacheckrc", ".git" },
        init_options = {
            diagnostics = {
                globals = { "vim" }
            }
        }
    },
    -- Bash
    bashls = {-- npm install -g bash-language-server
        filetypes = { "sh", "bash" },
        root_patterns = { ".bashrc", ".bash_profile", ".git" },
        init_options = {
            enableSourceErrorHighlight = true,
            explainshellEndpoint = "",
            globPattern = "*@(.sh|.inc|.bash|.command)"
        }
    },
    -- JavaScript/TypeScript
    tsserver = {
        filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
        root_patterns = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
        init_options = {}
    },
    -- Go
    gopls = {
        filetypes = { "go", "gomod" },
        root_patterns = { "go.mod", "go.work", ".git" },
        init_options = {
            usePlaceholders = true,
            completeUnimported = true,
        }
    },
    -- CMake
    cmake = {-- pip install cmake-language-server
        filetypes = { "cmake" },
        root_patterns = { "CMakeLists.txt", ".git" },
        init_options = {
            buildDirectory = "BUILD"
        },
    },
    -- XML
    lemminx = {-- npm install -g lemminx
        filetypes = { "xml", "xsd", "xsl", "svg" },
        root_patterns = { ".git", "pom.xml", "schemas", "catalog.xml" },
        init_options = {
            xmlValidation = {
                enabled = true
            },
            xmlCatalogs = {
                enabled = true
            }
        }
    },
}

-- Extension to filetype mapping for better filetype detection
local ext_to_ft = {
    -- C/C++
    c = "c",
    h = "c",
    cpp = "cpp",
    cxx = "cpp",
    cc = "cpp",
    hpp = "cpp",
    -- Python
    py = "python",
    pyi = "python",
    -- Rust
    rs = "rust",
    -- Zig
    zig = "zig",
    -- Lua
    lua = "lua",
    -- JavaScript/TypeScript
    js = "javascript",
    jsx = "javascriptreact",
    ts = "typescript",
    tsx = "typescriptreact",
    -- Go
    go = "go",
    mod = "gomod",

    -- Add CMake extension mapping
    cmake = "cmake",

    -- Add XML extension mappings
    xml = "xml",
    xsd = "xml",
    xsl = "xml",
    svg = "xml",
}

-- Helper function to map filetype to server name
local function get_server_for_filetype(filetype)
    -- Check in the user-provided configurations first
    if server_configs[filetype] then
        return server_configs[filetype].server_name
    end

    -- Then check in default configurations
    for server_name, config in pairs(default_server_configs) do
        if vim.tbl_contains(config.filetypes, filetype) then
            return server_name
        end
    end

    return nil
end

-- Optimize the publishDiagnostics handler to avoid blocking after save
local function setup_optimized_lsp_handlers()
    local original_publish_diagnostics = vim.lsp.handlers["textDocument/publishDiagnostics"]

    vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
        -- Check if this is for a remote buffer
        local uri = result and result.uri
        if uri and (uri:match("^scp://") or uri:match("^rsync://")) then
            -- Schedule diagnostic processing to avoid blocking
            vim.schedule(function()
                original_publish_diagnostics(err, result, ctx, config)
            end)
            return
        end

        -- For non-remote buffers, use the original handler
        return original_publish_diagnostics(err, result, ctx, config)
    end
end

function M.setup(opts)
    -- Add verbose logging for setup process
    log("Setting up remote-ssh with options: " .. vim.inspect(opts), vim.log.levels.DEBUG)

    on_attach = opts.on_attach or function(_, bufnr)
        log("LSP attached to buffer " .. bufnr, vim.log.levels.INFO, true)
    end

    capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()

    -- Enhance capabilities for better LSP support
    -- Explicitly request markdown for hover documentation
    capabilities.textDocument = capabilities.textDocument or {}
    capabilities.textDocument.hover = capabilities.textDocument.hover or {}
    capabilities.textDocument.hover.contentFormat = {"markdown", "plaintext"}

    -- Process filetype_to_server mappings
    if opts.filetype_to_server then
        for ft, server_name in pairs(opts.filetype_to_server) do
            if type(server_name) == "string" then
                -- Simple mapping from filetype to server name
                server_configs[ft] = { server_name = server_name }
            elseif type(server_name) == "table" then
                -- Advanced configuration with server name and options
                server_configs[ft] = server_name
            end
        end
    end

    -- Process server_configs from options
    if opts.server_configs then
        for server_name, config in pairs(opts.server_configs) do
            -- Merge with default configs if they exist
            if default_server_configs[server_name] then
                for k, v in pairs(default_server_configs[server_name]) do
                    if k == "init_options" then
                        config.init_options = vim.tbl_deep_extend("force",
                            default_server_configs[server_name].init_options or {},
                            config.init_options or {})
                    elseif k == "filetypes" or k == "root_patterns" then
                        config[k] = config[k] or vim.deepcopy(v)
                    else
                        config[k] = config[k] ~= nil and config[k] or v
                    end
                end
            end

            -- Register server config
            for _, ft in ipairs(config.filetypes or {}) do
                server_configs[ft] = {
                    server_name = server_name,
                    init_options = config.init_options,
                    cmd_args = config.cmd_args,
                    root_patterns = config.root_patterns
                }
            end
        end
    end

    -- Log available filetype mappings
    local ft_count = 0
    for ft, _ in pairs(server_configs) do
        ft_count = ft_count + 1
    end
    log("Registered " .. ft_count .. " filetype to server mappings", vim.log.levels.DEBUG)

    for server_name, config in pairs(default_server_configs) do
        for _, ft in ipairs(config.filetypes or {}) do
            if not server_configs[ft] then
                server_configs[ft] = {
                    server_name = server_name,
                    init_options = config.init_options,
                    cmd_args = config.cmd_args,
                    root_patterns = config.root_patterns
                }
            end
        end
    end

    -- Initialize the async write module
    async_write.setup(opts.async_write_opts or {})

    -- Set up LSP integration with non-blocking handlers
    async_write.setup_lsp_integration({
        notify_save_start = notify_save_start,
        notify_save_end = notify_save_end
    })

    -- Set up optimized LSP handlers
    setup_optimized_lsp_handlers()

    -- Start the cleanup timer
    M._cleanup_timer = setup_save_status_cleanup()

    -- Add command to help with LSP troubleshooting
    vim.api.nvim_create_user_command(
        "RemoteLspDebugTraffic",
        function(opts)
            local enable = opts.bang or false
            M.debug_lsp_traffic(enable)
        end,
        {
            desc = "Enable/disable LSP traffic debugging (! to enable)",
            bang = true
        }
    )
end

-- Helper function to debug LSP communications
function M.debug_lsp_traffic(enable)
    if enable then
        -- Enable logging of LSP traffic
        vim.lsp.set_log_level("debug")

        -- Log more details about LSP message exchanges
        if vim.fn.has('nvim-0.8') == 1 then
            -- For Neovim 0.8+
            local path = vim.fn.stdpath("cache") .. "/lsp.log"
            vim.lsp.set_log_level("debug")
            vim.cmd("let g:lsp_log_file = " .. vim.inspect(path))
            vim.cmd("lua vim.lsp.log.set_format_func(vim.inspect)")
            log("LSP logging enabled at: " .. path, vim.log.levels.INFO, true)
        else
            -- For older Neovim
            local path = vim.fn.stdpath("cache") .. "/lsp.log"
            vim.lsp.set_log_level("debug")
            vim.cmd("let g:lsp_log_file = " .. vim.inspect(path))
            log("LSP logging enabled at: " .. path, vim.log.levels.INFO, true)
        end
    else
        -- Disable verbose logging
        vim.lsp.set_log_level("warn")
        log("LSP debug logging disabled", vim.log.levels.INFO, true)
    end
end

-- Function to get the directory of the current Lua script
local function get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
end

-- Get a unique server key based on server name and host
local function get_server_key(server_name, host)
    return server_name .. "@" .. host
end

-- Function to track client with server and buffer information
local function track_client(client_id, server_name, bufnr, host, protocol)
    log("Tracking client " .. client_id .. " for server " .. server_name .. " on buffer " .. bufnr, vim.log.levels.DEBUG)

    -- Track client info
    active_lsp_clients[client_id] = {
        server_name = server_name,
        bufnr = bufnr,
        host = host,
        protocol = protocol,
        timestamp = os.time()
    }

    -- Track which buffers use which server
    local server_key = get_server_key(server_name, host)
    if not server_buffers[server_key] then
        server_buffers[server_key] = {}
    end
    server_buffers[server_key][bufnr] = true

    -- Track which clients are attached to which buffers
    if not buffer_clients[bufnr] then
        buffer_clients[bufnr] = {}
    end
    buffer_clients[bufnr][client_id] = true
end

-- Function to untrack a client
local function untrack_client(client_id)
    local client_info = active_lsp_clients[client_id]
    if not client_info then return end

    -- Remove from server-buffer tracking
    if client_info.server_name and client_info.host then
        local server_key = get_server_key(client_info.server_name, client_info.host)
        if server_buffers[server_key] and server_buffers[server_key][client_info.bufnr] then
            server_buffers[server_key][client_info.bufnr] = nil

            -- If no more buffers use this server, remove the server entry
            if vim.tbl_isempty(server_buffers[server_key]) then
                server_buffers[server_key] = nil
            end
        end
    end

    -- Remove from buffer-client tracking
    if client_info.bufnr and buffer_clients[client_info.bufnr] then
        buffer_clients[client_info.bufnr][client_id] = nil

        -- If no more clients for this buffer, remove the buffer entry
        if vim.tbl_isempty(buffer_clients[client_info.bufnr]) then
            buffer_clients[client_info.bufnr] = nil
        end
    end

    -- Remove the client info itself
    active_lsp_clients[client_id] = nil
end

-- Function to stop an LSP client - optimized to use scheduling for potentially slow operations
function M.shutdown_client(client_id, force_kill)
    -- Add error handling
    local ok, err = pcall(function()
        local client_info = active_lsp_clients[client_id]
        if not client_info then
            log("Client " .. client_id .. " not found in active clients", vim.log.levels.WARN)
            return
        end

        log("Shutting down client " .. client_id, vim.log.levels.DEBUG)

        -- Send proper shutdown sequence to the LSP server
        local client = vim.lsp.get_client_by_id(client_id)
        if client and not client.is_stopped() then
            -- First try a graceful shutdown
            log("Sending shutdown request to LSP server", vim.log.levels.DEBUG)

            -- Get client's RPC object if available
            if client.rpc then
                -- Attempt a clean shutdown sequence asynchronously
                vim.schedule(function()
                    client.rpc.notify("shutdown")
                    vim.defer_fn(function()
                        client.rpc.notify("exit")
                    end, 100)
                end)
            end
        end

        -- Schedule the stop operation
        vim.schedule(function()
            -- Then stop the client
            vim.lsp.stop_client(client_id, true)

            -- Only force kill if this server isn't used by other buffers
            if force_kill and client_info.host and client_info.server_name then
                local server_key = get_server_key(client_info.server_name, client_info.host)

                -- Check if any buffers still use this server
                if not server_buffers[server_key] or vim.tbl_isempty(server_buffers[server_key]) then
                    -- No buffers using this server, kill the process
                    log("No buffers using server " .. server_key .. ", killing remote process", vim.log.levels.DEBUG)
                    local cmd = string.format("ssh %s 'pkill -f %s'", client_info.host, client_info.server_name)
                    vim.fn.jobstart(cmd, {
                        on_exit = function(_, exit_code)
                            if exit_code == 0 then
                                log("Successfully killed remote LSP process for " .. server_key, vim.log.levels.DEBUG)
                            else
                                log("Failed to kill remote LSP process for " .. server_key .. " (or none found)", vim.log.levels.DEBUG)
                            end
                        end
                    })
                else
                    log("Not killing remote process for " .. server_key .. " as it's still used by other buffers", vim.log.levels.DEBUG)
                end
            end

            untrack_client(client_id)
        end)
    end)

    if not ok then
        log("Error shutting down client: " .. tostring(err), vim.log.levels.ERROR)
    end
end

-- Function to safely handle buffer untracking
local function safe_untrack_buffer(bufnr)
    local ok, err = pcall(function()
        -- Check if a save is in progress for this buffer
        if buffer_save_in_progress[bufnr] then
            log("Save in progress for buffer " .. bufnr .. ", not untracking LSP", vim.log.levels.DEBUG)
            return
        end

        log("Untracking buffer " .. bufnr, vim.log.levels.DEBUG)

        -- Get clients for this buffer
        local clients = buffer_clients[bufnr] or {}
        local client_ids = vim.tbl_keys(clients)

        -- For each client, check if we should shut it down
        for _, client_id in ipairs(client_ids) do
            local client_info = active_lsp_clients[client_id]
            if client_info then
                local server_key = get_server_key(client_info.server_name, client_info.host)

                -- Untrack this buffer from the server
                if server_buffers[server_key] then
                    server_buffers[server_key][bufnr] = nil

                    -- Check if this was the last buffer using this server
                    if vim.tbl_isempty(server_buffers[server_key]) then
                        -- This was the last buffer, shut down the server
                        log("Last buffer using server " .. server_key .. " closed, shutting down client " .. client_id, vim.log.levels.DEBUG)
                        -- Schedule the shutdown to avoid blocking
                        vim.schedule(function()
                            M.shutdown_client(client_id, true)
                        end)
                    else
                        -- Other buffers still use this server, just untrack this buffer
                        log("Buffer " .. bufnr .. " closed but server " .. server_key .. " still has active buffers, keeping client " .. client_id, vim.log.levels.DEBUG)

                        -- Still untrack the client from this buffer specifically
                        if buffer_clients[bufnr] then
                            buffer_clients[bufnr][client_id] = nil
                        end
                    end
                end
            end
        end

        -- Finally remove the buffer from our tracking
        buffer_clients[bufnr] = nil
    end)

    if not ok then
        log("Error untracking buffer: " .. tostring(err), vim.log.levels.ERROR)
    end
end

-- Setup buffer tracking for a client
local function setup_buffer_tracking(client, bufnr, server_name, host, protocol)
    -- Track this client
    track_client(client.id, server_name, bufnr, host, protocol)

    -- Add buffer closure detection with full error handling
    local autocmd_group = vim.api.nvim_create_augroup("RemoteLspBuffer" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd({"BufDelete", "BufWipeout", "BufUnload"}, {
        group = autocmd_group,
        buffer = bufnr,
        callback = function(ev)
            -- Skip untracking if the buffer is just being saved
            if buffer_save_in_progress[bufnr] then
                log("Buffer " .. bufnr .. " is being saved, not untracking LSP", vim.log.levels.DEBUG)
                return
            end

            -- Only untrack if this is a genuine buffer close
            if ev.event == "BufDelete" or ev.event == "BufWipeout" then
                log("Buffer " .. bufnr .. " closed (" .. ev.event .. "), checking if LSP server should be stopped", vim.log.levels.DEBUG)
                -- Schedule the untracking to avoid blocking
                vim.schedule(function()
                    safe_untrack_buffer(bufnr)
                end)
            end
        end,
    })

    -- Add LSP crash/exit detection
    local exit_handler_group = vim.api.nvim_create_augroup("RemoteLspExit" .. client.id, { clear = true })

    -- Create an autocommand to detect and handle server exit
    vim.api.nvim_create_autocmd("LspDetach", {
        group = exit_handler_group,
        callback = function(ev)
            if ev.data and ev.data.client_id == client.id then
                vim.schedule(function()
                    -- Only report unexpected disconnections
                    if active_lsp_clients[client.id] then
                        log(string.format(
                            "Remote LSP %s disconnected. Use :RemoteLspStart to reconnect if needed.",
                            server_name
                        ), vim.log.levels.WARN, true)
                    end

                    -- Clean up tracking
                    untrack_client(client.id)
                end)
            end
        end
    })
end

-- Function to stop all active remote LSP clients
function M.stop_all_clients(force_kill)
    force_kill = force_kill or false

    -- Keep track of server_keys we've already processed
    local processed_servers = {}
    local clients_to_stop = {}

    -- First collect all clients we need to stop (without modifying the table while iterating)
    for client_id, info in pairs(active_lsp_clients) do
        local server_key = get_server_key(info.server_name, info.host)

        -- Only process each server once
        if not processed_servers[server_key] then
            processed_servers[server_key] = true
            table.insert(clients_to_stop, client_id)
        end
    end

    -- Then stop each client (scheduled to avoid blocking)
    vim.schedule(function()
        for _, client_id in ipairs(clients_to_stop) do
            local info = active_lsp_clients[client_id]
            if info then
                local server_key = get_server_key(info.server_name, info.host)
                log("Stopping LSP client for server " .. server_key, vim.log.levels.DEBUG)
                M.shutdown_client(client_id, force_kill)
            end
        end

        -- Reset all tracking structures after a delay to ensure everything is cleaned up
        vim.defer_fn(function()
            active_lsp_clients = {}
            server_buffers = {}
            buffer_clients = {}
        end, 500)
    end)
end

-- Parse host and path from buffer name
local function parse_remote_buffer(bufname)
    local protocol = get_protocol(bufname)
    if not protocol then
        return nil, nil, nil
    end

    local pattern = "^" .. protocol .. "://([^/]+)/(.+)$"
    local host, path = bufname:match(pattern)
    return host, path, protocol
end

-- Find root directory based on patterns
local function find_project_root(host, path, root_patterns)
    if not root_patterns or #root_patterns == 0 then
        return vim.fn.fnamemodify(path, ":h")
    end

    -- Start from the directory containing the file
    local dir = vim.fn.fnamemodify(path, ":h")

    -- Check for root markers using a non-blocking job if possible
    local job_cmd = string.format(
        "ssh %s 'cd %s && find . -maxdepth 2 -name \".git\" -o -name \"compile_commands.json\" | head -n 1'",
        host, vim.fn.shellescape(dir)
    )

    local result = vim.fn.trim(vim.fn.system(job_cmd))
    if result ~= "" then
        -- Found a marker, get its directory
        local marker_dir = vim.fn.fnamemodify(result, ":h")
        if marker_dir == "." then
            return dir
        else
            return dir .. "/" .. marker_dir
        end
    end

    -- If no root markers found, just use the file's directory
    return dir
end

-- Function to start LSP client for a remote buffer
function M.start_remote_lsp(bufnr)
    log("Attempting to start remote LSP for buffer " .. bufnr, vim.log.levels.DEBUG)

    if not vim.api.nvim_buf_is_valid(bufnr) then
        log("Invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return
    end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    log("Buffer name: " .. bufname, vim.log.levels.DEBUG)

    local protocol = get_protocol(bufname)
    if not protocol then
        log("Not a remote URL: " .. bufname, vim.log.levels.DEBUG)
        return
    end

    local host, path, _ = parse_remote_buffer(bufname)
    if not host or not path then
        log("Invalid remote URL: " .. bufname, vim.log.levels.ERROR)
        return
    end
    log("Host: " .. host .. ", Path: " .. path .. ", Protocol: " .. protocol, vim.log.levels.DEBUG)

    -- Determine filetype
    local filetype = vim.bo[bufnr].filetype
    log("Initial filetype: " .. (filetype or "nil"), vim.log.levels.DEBUG)

    if not filetype or filetype == "" then
        local basename = vim.fn.fnamemodify(bufname, ":t")

        -- Check for special filenames first
        if basename == "CMakeLists.txt" then
            filetype = "cmake"
        else
            -- Fall back to extension-based detection
            local ext = vim.fn.fnamemodify(bufname, ":e")
            filetype = ext_to_ft[ext] or ""
        end

        if filetype ~= "" then
            vim.bo[bufnr].filetype = filetype
            log("Set filetype to " .. filetype .. " for buffer " .. bufnr, vim.log.levels.DEBUG)
        else
            log("No filetype detected or inferred for buffer " .. bufnr, vim.log.levels.DEBUG)
            return
        end
    end

    -- Determine server name based on filetype
    local server_name = get_server_for_filetype(filetype)
    if not server_name then
        log("No LSP server for filetype: " .. filetype, vim.log.levels.WARN)
        return
    end
    log("Server name: " .. server_name, vim.log.levels.DEBUG)

    -- Get server configuration
    local server_config = server_configs[filetype] or {}
    local root_patterns = server_config.root_patterns

    if default_server_configs[server_name] then
        root_patterns = root_patterns or default_server_configs[server_name].root_patterns
    end

    -- Determine root directory
    local root_dir
    if custom_root_dir then
        root_dir = custom_root_dir
    else
        local dir = vim.fn.fnamemodify(path, ":h")
        -- Here we could use find_project_root instead if we add SSH root detection
        root_dir = protocol .. "://" .. host .. "/" .. dir
    end
    log("Root dir: " .. root_dir, vim.log.levels.DEBUG)

    -- Check if this server is already running for this host
    local server_key = get_server_key(server_name, host)
    if server_buffers[server_key] then
        -- Find an existing client for this server and attach it to this buffer
        for client_id, info in pairs(active_lsp_clients) do
            if info.server_name == server_name and info.host == host then
                log("Reusing existing LSP client " .. client_id .. " for server " .. server_key, vim.log.levels.INFO, true)

                -- Track this buffer for the server
                server_buffers[server_key][bufnr] = true

                -- Track this client for the buffer
                if not buffer_clients[bufnr] then
                    buffer_clients[bufnr] = {}
                end
                buffer_clients[bufnr][client_id] = true

                -- Attach the client to the buffer
                vim.lsp.buf_attach_client(bufnr, client_id)
                return client_id
            end
        end
    end

    local lspconfig = require('lspconfig')
    if not lspconfig then
        log("lspconfig module not found", vim.log.levels.ERROR)
        return
    end

    local lsp_config = lspconfig[server_name]
    if not lsp_config then
        log("LSP config not found for: " .. server_name .. ". Is the server installed?", vim.log.levels.ERROR, true)
        return
    end

    local lsp_cmd = lsp_config.document_config.default_config.cmd
    if not lsp_cmd then
        log("No cmd defined for server: " .. server_name, vim.log.levels.ERROR, true)
        return
    end
    log("LSP command: " .. vim.inspect(lsp_cmd), vim.log.levels.DEBUG)

    -- Extract just the binary name and arguments
    local binary_name = lsp_cmd[1]:match("([^/\\]+)$") or lsp_cmd[1] -- Get the basename, fallback to full name
    local lsp_args = { binary_name }

    for i = 2, #lsp_cmd do
        log("Adding LSP arg: " .. lsp_cmd[i], vim.log.levels.DEBUG)
        table.insert(lsp_args, lsp_cmd[i])
    end

    -- Add server-specific command arguments if provided
    if server_config.cmd_args then
        for _, arg in ipairs(server_config.cmd_args) do
            table.insert(lsp_args, arg)
        end
    end

    local proxy_path = get_script_dir() .. "/proxy.py"
    if not vim.fn.filereadable(proxy_path) then
        log("Proxy script not found at: " .. proxy_path, vim.log.levels.ERROR, true)
        return
    end

    -- Special handling for specific servers
    if server_name == "pyright" then
        local cmd = {
            "python3",
            "-u",
            proxy_path,
            host,
            protocol,
            -- Add environment setup for pyright
            "PYTHONUNBUFFERED=1"
        }

        -- Add all the args
        vim.list_extend(cmd, lsp_args)

        -- Prepare to start the server
        lsp_args = cmd
    else
        -- Standard command for other servers
        local cmd = { "python3", "-u", proxy_path, host, protocol }
        vim.list_extend(cmd, lsp_args)

        -- Prepare to start the server
        lsp_args = cmd
    end

    log("Starting LSP with cmd: " .. table.concat(lsp_args, " "), vim.log.levels.DEBUG)

    -- Create a server key and initialize tracking if needed
    if not server_buffers[server_key] then
        server_buffers[server_key] = {}
    end

    -- Get initialization options
    local init_options = {}
    if server_config.init_options then
        init_options = server_config.init_options
    elseif default_server_configs[server_name] and default_server_configs[server_name].init_options then
        init_options = default_server_configs[server_name].init_options
    end

    -- Add custom handlers to ensure proper lifecycle management
    local client_id = vim.lsp.start({
        name = "remote_" .. server_name,
        cmd = lsp_args,
        root_dir = root_dir,
        capabilities = capabilities,
        init_options = init_options,
        on_attach = function(client, attached_bufnr)
            on_attach(client, attached_bufnr)
            log("LSP client started successfully", vim.log.levels.INFO, true)

            -- Use our improved buffer tracking
            setup_buffer_tracking(client, attached_bufnr, server_name, host, protocol)
        end,
        on_exit = function(code, signal, client_id)
            vim.schedule(function()
                log("LSP client exited: code=" .. code .. ", signal=" .. signal, vim.log.levels.DEBUG)
                untrack_client(client_id)
            end)
        end,
        flags = {
            debounce_text_changes = 150,
            allow_incremental_sync = true,
        },
        filetypes = { filetype },
    })

    if client_id ~= nil then
        log("LSP client " .. client_id .. " initiated for buffer " .. bufnr, vim.log.levels.DEBUG)
        vim.lsp.buf_attach_client(bufnr, client_id)
        return client_id
    else
        log("Failed to start LSP client for " .. server_name, vim.log.levels.ERROR, true)
        return nil
    end
end

-- User command to set custom root directory and restart LSP
vim.api.nvim_create_user_command(
    "RemoteLspSetRoot",
    function(opts)
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()
            local bufname = vim.api.nvim_buf_get_name(bufnr)

            local protocol = get_protocol(bufname)
            if not protocol then
                log("Not a remote buffer", vim.log.levels.ERROR, true)
                return
            end

            local host, _, _ = parse_remote_buffer(bufname)
            if not host then
                log("Invalid remote URL: " .. bufname, vim.log.levels.ERROR, true)
                return
            end

            local user_input = opts.args
            if user_input == "" then
                custom_root_dir = nil
                log("Reset remote LSP root to buffer-derived directory", vim.log.levels.INFO, true)
            else
                if not user_input:match("^/") then
                    local current_dir = vim.fn.fnamemodify(bufname:match("^" .. protocol .. "://[^/]+/(.+)$"), ":h")
                    user_input = current_dir .. "/" .. user_input
                end
                custom_root_dir = protocol .. "://" .. host .. "/" .. vim.fn.substitute(user_input, "//+", "/", "g")
                log("Set remote LSP root to " .. custom_root_dir, vim.log.levels.INFO, true)
            end

            -- Schedule LSP restart to avoid blocking
            vim.schedule(function()
                M.start_remote_lsp(bufnr)
            end)
        end)

        if not ok then
            log("Error setting root: " .. tostring(err), vim.log.levels.ERROR, true)
        end
    end,
    {
        nargs = "?",
        desc = "Set the root directory for the remote LSP server (e.g., '/path/to/project')",
    }
)

-- Add auto commands for remote files with proper timing
local autocmd_group = vim.api.nvim_create_augroup("RemoteLSP", { clear = true })

-- Update autocmd to use multiple events for better reliability
vim.api.nvim_create_autocmd({"BufReadPost", "FileType"}, {
    pattern = {"scp://*", "rsync://*"},
    group = autocmd_group,
    callback = function()
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()
            local bufname = vim.api.nvim_buf_get_name(bufnr)

            -- Delay the LSP startup to ensure filetype is properly detected
            vim.defer_fn(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                local filetype = vim.bo[bufnr].filetype
                log("Autocmd triggered for " .. bufname .. " with filetype " .. (filetype or "nil"), vim.log.levels.DEBUG)

                if filetype and filetype ~= "" then
                    -- Start LSP in a scheduled callback to avoid blocking the UI
                    vim.schedule(function()
                        M.start_remote_lsp(bufnr)
                    end)
                end
            end, 100) -- Small delay to ensure filetype detection has completed
        end)

        if not ok then
            log("Error in autocmd: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
})

-- Add cleanup on VimLeave
vim.api.nvim_create_autocmd("VimLeave", {
    group = autocmd_group,
    callback = function()
        local ok, err = pcall(function()
            log("VimLeave: Stopping all remote LSP clients", vim.log.levels.DEBUG)
            -- Force kill on exit
            M.stop_all_clients(true)
        end)

        if not ok then
            log("Error in VimLeave: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
})

-- Add a command to manually start the LSP for the current buffer
vim.api.nvim_create_user_command(
    "RemoteLspStart",
    function()
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()
            -- Schedule the LSP start to avoid UI blocking
            vim.schedule(function()
                M.start_remote_lsp(bufnr)
            end)
        end)

        if not ok then
            log("Error starting LSP: " .. tostring(err), vim.log.levels.ERROR, true)
        end
    end,
    {
        desc = "Manually start the remote LSP server for the current buffer",
    }
)

-- Add a command to stop all remote LSP clients
vim.api.nvim_create_user_command(
    "RemoteLspStop",
    function()
        local ok, err = pcall(function()
            M.stop_all_clients(true)
        end)

        if not ok then
            log("Error stopping LSP: " .. tostring(err), vim.log.levels.ERROR, true)
        end
    end,
    {
        desc = "Stop all remote LSP servers and kill remote processes",
    }
)

-- Add a command to restart pyright safely
vim.api.nvim_create_user_command(
    "RemoteLspRestart",
    function()
        local ok, err = pcall(function()
            local bufnr = vim.api.nvim_get_current_buf()

            -- Get current clients for this buffer
            local clients = buffer_clients[bufnr] or {}
            local client_ids = vim.tbl_keys(clients)

            if #client_ids == 0 then
                log("No active LSP clients for this buffer", vim.log.levels.WARN, true)
                return
            end

            -- Shut down existing clients
            for _, client_id in ipairs(client_ids) do
                M.shutdown_client(client_id, false)
            end

            -- Clear tracking for this buffer
            buffer_clients[bufnr] = {}

            -- Wait a moment then restart
            vim.defer_fn(function()
                M.start_remote_lsp(bufnr)
            end, 1000)

            log("Restarting LSP for current buffer", vim.log.levels.INFO, true)
        end)

        if not ok then
            log("Error restarting LSP: " .. tostring(err), vim.log.levels.ERROR, true)
        end
    end,
    {
        desc = "Restart LSP server for the current buffer",
    }
)

-- Add a command to list available language servers
vim.api.nvim_create_user_command(
    "RemoteLspServers",
    function()
        local ok, err = pcall(function()
            local lspconfig = require('lspconfig')
            local available_servers = {}

            -- Get list of configured servers
            for server_name, _ in pairs(default_server_configs) do
                if lspconfig[server_name] then
                    table.insert(available_servers, server_name)
                end
            end

            -- Add user-configured servers that aren't in default configs
            for _, config in pairs(server_configs) do
                if type(config) == "table" and config.server_name and not vim.tbl_contains(available_servers, config.server_name) then
                    if lspconfig[config.server_name] then
                        table.insert(available_servers, config.server_name)
                    end
                end
            end

            table.sort(available_servers)

            log("Available Remote LSP Servers:", vim.log.levels.INFO, true)
            for _, server_name in ipairs(available_servers) do
                local filetypes = {}

                -- Find filetypes for this server
                if default_server_configs[server_name] and default_server_configs[server_name].filetypes then
                    filetypes = default_server_configs[server_name].filetypes
                end

                -- Also check user configs
                for ft, config in pairs(server_configs) do
                    if type(config) == "table" and config.server_name == server_name then
                        table.insert(filetypes, ft)
                    elseif config == server_name then
                        table.insert(filetypes, ft)
                    end
                end

                log(string.format("  %s: %s", server_name, table.concat(filetypes, ", ")), vim.log.levels.INFO, true)
            end
        end)

        if not ok then
            log("Error listing servers: " .. tostring(err), vim.log.levels.ERROR, true)
        end
    end,
    {
        desc = "List available remote LSP servers and their filetypes",
    }
)

-- Add a command to debug and print current server-buffer relationships
vim.api.nvim_create_user_command(
    "RemoteLspDebug",
    function()
        local ok, err = pcall(function()
            -- Print active clients
            log("Active LSP Clients:", vim.log.levels.INFO, true)
            for client_id, info in pairs(active_lsp_clients) do
                log(string.format("  Client %d: server=%s, buffer=%d, host=%s, protocol=%s",
                    client_id, info.server_name, info.bufnr, info.host, info.protocol or "unknown"), vim.log.levels.INFO, true)
            end

            -- Print server-buffer relationships
            log("Server-Buffer Relationships:", vim.log.levels.INFO, true)
            for server_key, buffers in pairs(server_buffers) do
                local buffer_list = vim.tbl_keys(buffers)
                log(string.format("  Server %s: buffers=%s",
                    server_key, table.concat(buffer_list, ", ")), vim.log.levels.INFO, true)
            end

            -- Print buffer-client relationships
            log("Buffer-Client Relationships:", vim.log.levels.INFO, true)
            for bufnr, clients in pairs(buffer_clients) do
                local client_list = vim.tbl_keys(clients)
                log(string.format("  Buffer %d: clients=%s",
                    bufnr, table.concat(client_list, ", ")), vim.log.levels.INFO, true)
            end

            -- Print buffer save status
            log("Buffers with active saves:", vim.log.levels.INFO, true)
            local save_buffers = {}
            for bufnr, _ in pairs(buffer_save_in_progress) do
                table.insert(save_buffers, bufnr)
            end

            if #save_buffers > 0 then
                log("  Buffers with active saves: " .. table.concat(save_buffers, ", "), vim.log.levels.INFO, true)
            else
                log("  No buffers with active saves", vim.log.levels.INFO, true)
            end

            -- Print buffer filetype info
            log("Buffer Filetype Info:", vim.log.levels.INFO, true)
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    local bufname = vim.api.nvim_buf_get_name(bufnr)
                    if get_protocol(bufname) then
                        local filetype = vim.bo[bufnr].filetype
                        log(string.format("  Buffer %d: name=%s, filetype=%s",
                            bufnr, bufname, filetype or "nil"), vim.log.levels.INFO, true)
                    end
                end
            end

            -- Print capabilities info
            log("LSP Capabilities:", vim.log.levels.INFO, true)
            for client_id, _ in pairs(active_lsp_clients) do
                local client = vim.lsp.get_client_by_id(client_id)
                if client then
                    log(string.format("  Client %d capabilities:", client_id), vim.log.levels.INFO, true)

                    -- Check for key capabilities
                    local caps = client.server_capabilities
                    if caps then
                        local supports_didSave = caps.textDocumentSync and caps.textDocumentSync.save
                        local needs_content = supports_didSave and caps.textDocumentSync.save.includeText

                        log(string.format("    textDocumentSync: %s", caps.textDocumentSync and "yes" or "no"), vim.log.levels.INFO, true)
                        log(string.format("    supports didSave: %s", supports_didSave and "yes" or "no"), vim.log.levels.INFO, true)
                        log(string.format("    requires content on save: %s", needs_content and "yes" or "no"), vim.log.levels.INFO, true)
                    end
                end
            end
        end)

        if not ok then
            log("Error in debug command: " .. tostring(err), vim.log.levels.ERROR, true)
        end
    end,
    {
        desc = "Print debug information about remote LSP clients and buffer relationships",
    }
)

-- Add command to check async write status
vim.api.nvim_create_user_command(
    "RemoteFileStatus",
    function()
        async_write.get_status()
    end,
    {
        desc = "Show status of remote file operations",
    }
)

M.async_write = async_write
M.buffer_clients = buffer_clients  -- Export for testing/debugging

return M
