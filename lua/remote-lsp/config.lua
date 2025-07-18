local M = {}

local log = require('logging').log

-- Configuration
M.config = {
    timeout = 30,          -- Default timeout in seconds
    log_level = vim.log.levels.INFO, -- Default log level
    debug = false,         -- Debug mode disabled by default
    check_interval = 1000, -- Status check interval in ms

    -- Project root detection settings
    fast_root_detection = true,   -- Use fast mode (no SSH calls) for better performance
    root_cache_enabled = true,    -- Enable caching of project root results
    root_cache_ttl = 300,         -- Cache time-to-live in seconds (5 minutes)
    max_root_search_depth = 10,   -- Maximum directory levels to search upward

    -- Server-specific root detection overrides
    server_root_detection = {
        rust_analyzer = { fast_mode = false },  -- Disable fast mode for rust-analyzer
        clangd = { fast_mode = false },         -- Disable fast mode for clangd
    },
}

-- Global variables set by setup
M.on_attach = nil
M.capabilities = nil
M.server_configs = {}  -- Table to store server-specific configurations
M.custom_root_dir = nil

-- Default server configurations with initialization options
M.default_server_configs = {
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
    -- Python servers
    pyright = {
        filetypes = { "python" },
        root_patterns = { "pyproject.toml", "setup.py", "requirements.txt", ".git" },
        init_options = {
            disableOrganizeImports = false,
            disableLanguageServices = false
        }
    },
    pylsp = {
        filetypes = { "python" },
        root_patterns = { "pyproject.toml", "setup.py", "requirements.txt", ".git" },
        init_options = {
            plugins = {
                pycodestyle = { enabled = true },
                pyflakes = { enabled = true },
                pylint = { enabled = false },
                rope_completion = { enabled = true },
                jedi_completion = { enabled = true },
                jedi_hover = { enabled = true },
                jedi_references = { enabled = true },
                jedi_signature_help = { enabled = true },
                jedi_symbols = { enabled = true }
            }
        }
    },
    jedi_language_server = {
        filetypes = { "python" },
        root_patterns = { "pyproject.toml", "setup.py", "requirements.txt", ".git" },
        init_options = {
            completion = { enabled = true },
            hover = { enabled = true },
            references = { enabled = true },
            signature_help = { enabled = true },
            symbols = { enabled = true }
        }
    },
    -- Rust
    rust_analyzer = {
        filetypes = { "rust" },
        root_patterns = { "Cargo.toml", "Cargo.lock", "rust-project.json", ".git" },
        init_options = {
            cargo = {
                allFeatures = true,
                loadOutDirsFromCheck = true,
                buildScripts = {
                    enable = true,
                },
                autoreload = true,
            },
            procMacro = {
                enable = true,
                attributes = {
                    enable = true
                }
            },
            diagnostics = {
                enable = true,
                enableExperimental = false,
            },
            checkOnSave = {
                enable = true,
                command = "clippy"
            },
        },
        settings = {
            ["rust-analyzer"] = {
                cargo = {
                    allFeatures = true,
                    loadOutDirsFromCheck = true,
                    buildScripts = {
                        enable = true,
                    },
                    autoreload = true,
                },
                procMacro = {
                    enable = true,
                    attributes = {
                        enable = true
                    }
                },
                diagnostics = {
                    enable = true,
                    enableExperimental = false,
                },
                checkOnSave = {
                    enable = true,
                    command = "clippy"
                },
                files = {
                    watcherExclude = {
                        "**/target/**"
                    },
                    excludeDirs = {
                        "target"
                    }
                },
                workspace = {
                    symbol = {
                        search = {
                            scope = "workspace",
                            kind = "all_symbols"
                        }
                    }
                },
                server = {
                    extraEnv = {
                        RUST_LOG = "error"
                    }
                }
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
    -- JavaScript/TypeScript servers
    tsserver = {
        filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
        root_patterns = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
        init_options = {
            preferences = {
                disableSuggestions = false,
                includeCompletionsForModuleExports = true,
                includeCompletionsWithInsertText = true
            }
        }
    },
    typescript_language_server = {
        filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
        root_patterns = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
        init_options = {
            preferences = {
                disableSuggestions = false,
                includeCompletionsForModuleExports = true,
                includeCompletionsWithInsertText = true
            }
        }
    },
    -- CSS/HTML/JSON servers (from vscode-langservers-extracted)
    cssls = {
        filetypes = { "css", "scss", "less" },
        root_patterns = { "package.json", ".git" },
        init_options = {
            provideFormatter = true
        }
    },
    html = {
        filetypes = { "html" },
        root_patterns = { "package.json", ".git" },
        init_options = {
            provideFormatter = true,
            configurationSection = { "html", "css", "javascript" }
        }
    },
    jsonls = {
        filetypes = { "json", "jsonc" },
        root_patterns = { "package.json", ".git" },
        init_options = {
            provideFormatter = true
        }
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
M.ext_to_ft = {
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
    sh = "sh",
    bash = "bash",
    -- Add XML extension mappings
    xml = "xml",
    xsd = "xml",
    xsl = "xml",
    svg = "xml",
    -- CSS/HTML/JSON extensions
    css = "css",
    scss = "css",
    less = "css",
    html = "html",
    htm = "html",
    json = "json",
    jsonc = "json",
}

-- Function to initialize configuration from the setup options
function M.initialize(opts)
    -- Add verbose logging for setup process
    log("Setting up remote-lsp with options: " .. vim.inspect(opts), vim.log.levels.DEBUG, false, M.config)

    -- Set on_attach callback
    M.on_attach = opts.on_attach or function(_, bufnr)
        log("LSP attached to buffer " .. bufnr, vim.log.levels.INFO, true, M.config)
    end

    -- Set capabilities
    M.capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()

    -- Enhance capabilities for better LSP support
    -- Explicitly request markdown for hover documentation
    M.capabilities.textDocument = M.capabilities.textDocument or {}
    M.capabilities.textDocument.hover = M.capabilities.textDocument.hover or {}
    M.capabilities.textDocument.hover.contentFormat = {"markdown", "plaintext"}

    -- Process filetype_to_server mappings
    if opts.filetype_to_server then
        for ft, server_name in pairs(opts.filetype_to_server) do
            if type(server_name) == "string" then
                -- Simple mapping from filetype to server name
                M.server_configs[ft] = { server_name = server_name }
            elseif type(server_name) == "table" then
                -- Advanced configuration with server name and options
                M.server_configs[ft] = server_name
            end
        end
    end

    -- Process server_configs from options
    if opts.server_configs then
        for server_name, config in pairs(opts.server_configs) do
            -- Merge with default configs if they exist
            if M.default_server_configs[server_name] then
                for k, v in pairs(M.default_server_configs[server_name]) do
                    if k == "init_options" then
                        config.init_options = vim.tbl_deep_extend("force",
                            M.default_server_configs[server_name].init_options or {},
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
                M.server_configs[ft] = {
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
    for ft, _ in pairs(M.server_configs) do
        ft_count = ft_count + 1
    end
    log("Registered " .. ft_count .. " filetype to server mappings", vim.log.levels.DEBUG, false, M.config)

    -- Add default mappings for filetypes that don't have custom mappings
    for server_name, config in pairs(M.default_server_configs) do
        for _, ft in ipairs(config.filetypes or {}) do
            if not M.server_configs[ft] then
                M.server_configs[ft] = {
                    server_name = server_name,
                    init_options = config.init_options,
                    cmd_args = config.cmd_args,
                    root_patterns = config.root_patterns
                }
            end
        end
    end

    -- Initialize the async write module
    require('async-remote-write').setup(opts.async_write_opts or {})

    -- Set up LSP integration with non-blocking handlers
    require('async-remote-write').setup_lsp_integration({
        notify_save_start = require('remote-lsp.buffer').notify_save_start,
        notify_save_end = require('remote-lsp.buffer').notify_save_end
    })
end

-- Helper function to get server for filetype
function M.get_server_for_filetype(filetype)
    -- Check in the user-provided configurations first
    if M.server_configs[filetype] then
        return M.server_configs[filetype].server_name
    end

    -- Then check in default configurations
    for server_name, config in pairs(M.default_server_configs) do
        if vim.tbl_contains(config.filetypes, filetype) then
            return server_name
        end
    end

    return nil
end

return M
