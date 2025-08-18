local M = {}

-- Default server configurations with initialization options
M.default_server_configs = {
    -- C/C++
    clangd = {
        filetypes = { "c", "cpp", "objc", "objcpp", "h", "hpp" },
        root_patterns = { ".git", "compile_commands.json", "compile_flags.txt" },
        init_options = {
            usePlaceholders = true,
            completeUnimported = true,
            clangdFileStatus = true,
        },
    },
    -- Python servers
    pyright = {
        filetypes = { "python" },
        root_patterns = { "pyproject.toml", "setup.py", "requirements.txt", ".git" },
        init_options = {
            disableOrganizeImports = false,
            disableLanguageServices = false,
        },
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
                jedi_symbols = { enabled = true },
            },
        },
    },
    jedi_language_server = {
        filetypes = { "python" },
        root_patterns = { "pyproject.toml", "setup.py", "requirements.txt", ".git" },
        init_options = {
            completion = { enabled = true },
            hover = { enabled = true },
            references = { enabled = true },
            signature_help = { enabled = true },
            symbols = { enabled = true },
        },
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
                    enable = true,
                },
            },
            diagnostics = {
                enable = true,
                enableExperimental = false,
            },
            checkOnSave = {
                enable = true,
                command = "clippy",
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
                        enable = true,
                    },
                },
                diagnostics = {
                    enable = true,
                    enableExperimental = false,
                },
                checkOnSave = {
                    enable = true,
                    command = "clippy",
                },
                files = {
                    watcherExclude = {
                        "**/target/**",
                    },
                    excludeDirs = {
                        "target",
                    },
                },
                workspace = {
                    symbol = {
                        search = {
                            scope = "workspace",
                            kind = "all_symbols",
                        },
                    },
                },
                server = {
                    extraEnv = {
                        RUST_LOG = "error",
                    },
                },
            },
        },
    },
    -- Zig
    zls = {
        filetypes = { "zig" },
        root_patterns = { "build.zig", ".git" },
        init_options = {},
    },
    -- Lua
    lua_ls = {
        filetypes = { "lua" },
        root_patterns = { ".luarc.json", ".luacheckrc", ".git" },
        init_options = {
            diagnostics = {
                globals = { "vim" },
            },
        },
    },
    -- Bash
    bashls = { -- npm install -g bash-language-server
        filetypes = { "sh", "bash" },
        root_patterns = { ".bashrc", ".bash_profile", ".git" },
        init_options = {
            enableSourceErrorHighlight = true,
            explainshellEndpoint = "",
            globPattern = "*@(.sh|.inc|.bash|.command)",
        },
    },
    -- JavaScript/TypeScript servers
    tsserver = {
        filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
        root_patterns = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
        init_options = {
            preferences = {
                disableSuggestions = false,
                includeCompletionsForModuleExports = true,
                includeCompletionsWithInsertText = true,
            },
        },
    },
    typescript_language_server = {
        filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
        root_patterns = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
        init_options = {
            preferences = {
                disableSuggestions = false,
                includeCompletionsForModuleExports = true,
                includeCompletionsWithInsertText = true,
            },
        },
    },
    -- CSS/HTML/JSON servers (from vscode-langservers-extracted)
    cssls = {
        filetypes = { "css", "scss", "less" },
        root_patterns = { "package.json", ".git" },
        init_options = {
            provideFormatter = true,
        },
    },
    html = {
        filetypes = { "html" },
        root_patterns = { "package.json", ".git" },
        init_options = {
            provideFormatter = true,
            configurationSection = { "html", "css", "javascript" },
        },
    },
    jsonls = {
        filetypes = { "json", "jsonc" },
        root_patterns = { "package.json", ".git" },
        init_options = {
            provideFormatter = true,
        },
    },
    -- Go
    gopls = {
        filetypes = { "go", "gomod" },
        root_patterns = { "go.mod", "go.work", ".git" },
        init_options = {
            usePlaceholders = true,
            completeUnimported = true,
        },
    },
    -- CMake
    cmake = { -- pip install cmake-language-server
        filetypes = { "cmake" },
        root_patterns = { "CMakeLists.txt", ".git" },
        init_options = {
            buildDirectory = "BUILD",
        },
    },
    -- XML
    lemminx = { -- npm install -g lemminx
        filetypes = { "xml", "xsd", "xsl", "svg" },
        root_patterns = { ".git", "pom.xml", "schemas", "catalog.xml" },
        init_options = {
            xmlValidation = {
                enabled = true,
            },
            xmlCatalogs = {
                enabled = true,
            },
        },
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

return M
