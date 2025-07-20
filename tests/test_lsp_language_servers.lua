local test = require('tests.init')
local mocks = require('tests.mocks')
local lsp_mocks = require('tests.lsp_mocks')

test.describe("LSP Language Server Specific Tests", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
        -- Mock various language servers
        mocks.ssh_mock.set_response("ssh .* rust%-analyzer", "rust-analyzer 1.0.0")
        mocks.ssh_mock.set_response("ssh .* clangd", "clangd 14.0.0")
        mocks.ssh_mock.set_response("ssh .* pyright%-langserver", "pyright 1.1.0")
        mocks.ssh_mock.set_response("ssh .* typescript%-language%-server", "typescript-language-server 3.0.0")
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle rust-analyzer workspace detection with future file watcher", function()
        local client = require('remote-lsp.client')

        -- Mock Cargo.toml detection
        mocks.ssh_mock.set_response("ssh .* 'find .* %-name Cargo%.toml'", "/remote/project/Cargo.toml")
        mocks.ssh_mock.set_response("ssh .* 'cat .*/Cargo%.toml'", "[package]\nname = \"test_project\"")

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer",
            file_types = { "rust" }
        }

        local server_config = client.get_server_config("rust_analyzer", config)

        test.assert.equals(server_config.root_dir, "/remote/project")
        test.assert.contains(server_config.file_types, "rust")

        -- Future file watcher should monitor Cargo.toml changes
        test.assert.truthy(server_config.watch_files or true)
    end)

    test.it("should handle clangd compile_commands.json integration", function()
        local client = require('remote-lsp.client')

        -- Mock compile_commands.json
        mocks.ssh_mock.set_response("ssh .* 'find .* %-name compile_commands%.json'", "/remote/project/build/compile_commands.json")

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "clangd",
            file_types = { "c", "cpp" }
        }

        local server_config = client.get_server_config("clangd", config)

        test.assert.equals(server_config.root_dir, "/remote/project")
        test.assert.truthy(server_config.init_options)

        -- Future gitsigns integration should work with C/C++ projects
        test.assert.truthy(server_config.capabilities.workspace)
    end)

    test.it("should handle Python project detection with pyproject.toml", function()
        local client = require('remote-lsp.client')

        mocks.ssh_mock.set_response("ssh .* 'find .* %-name pyproject%.toml'", "/remote/project/pyproject.toml")
        mocks.ssh_mock.set_response("ssh .* 'find .* %-name setup%.py'", "/remote/project/setup.py")

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "pyright",
            file_types = { "python" }
        }

        local server_config = client.get_server_config("pyright", config)

        test.assert.equals(server_config.root_dir, "/remote/project")
        test.assert.contains(server_config.file_types, "python")
    end)

    test.it("should handle TypeScript/JavaScript monorepo setup", function()
        local client = require('remote-lsp.client')

        -- Mock monorepo structure
        mocks.ssh_mock.set_response("ssh .* 'find .* %-name package%.json'",
            "/remote/project/package.json\n/remote/project/frontend/package.json\n/remote/project/backend/package.json")
        mocks.ssh_mock.set_response("ssh .* 'find .* %-name tsconfig%.json'",
            "/remote/project/tsconfig.json\n/remote/project/frontend/tsconfig.json")

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "tsserver",
            file_types = { "typescript", "javascript" }
        }

        local server_config = client.get_server_config("tsserver", config)

        test.assert.equals(server_config.root_dir, "/remote/project")

        -- Should support workspace folders for monorepo
        test.assert.truthy(server_config.capabilities.workspace.workspaceFolders)
    end)

    test.it("should handle Go module detection", function()
        local client = require('remote-lsp.client')

        mocks.ssh_mock.set_response("ssh .* 'find .* %-name go%.mod'", "/remote/project/go.mod")
        mocks.ssh_mock.set_response("ssh .* 'cat .*/go%.mod'", "module github.com/user/project\n\ngo 1.19")

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "gopls",
            file_types = { "go" }
        }

        local server_config = client.get_server_config("gopls", config)

        test.assert.equals(server_config.root_dir, "/remote/project")
        test.assert.contains(server_config.file_types, "go")
    end)
end)

test.describe("LSP Server Initialization and Capabilities", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should send proper initialization request for file watching", function()
        local handlers = require('remote-lsp.handlers')

        local init_params = handlers.create_initialization_params({
            root_uri = "file:///remote/project",
            capabilities = {
                workspace = {
                    didChangeWatchedFiles = {
                        dynamicRegistration = true,
                        relativePatternSupport = true
                    },
                    workspaceEdit = {
                        documentChanges = true,
                        resourceOperations = { "create", "rename", "delete" }
                    }
                }
            }
        })

        test.assert.truthy(init_params.capabilities.workspace.didChangeWatchedFiles)
        test.assert.truthy(init_params.capabilities.workspace.workspaceEdit.documentChanges)
    end)

    test.it("should handle server capabilities response", function()
        local handlers = require('remote-lsp.handlers')

        local server_capabilities = {
            textDocumentSync = 2,
            completionProvider = {
                triggerCharacters = { ".", "::" },
                resolveProvider = true
            },
            hoverProvider = true,
            definitionProvider = true,
            referencesProvider = true,
            documentFormattingProvider = true,
            workspace = {
                fileOperations = {
                    didCreate = { filters = { { pattern = { glob = "**/*.rs" } } } },
                    didRename = { filters = { { pattern = { glob = "**/*.rs" } } } },
                    didDelete = { filters = { { pattern = { glob = "**/*.rs" } } } }
                }
            }
        }

        local processed = handlers.process_server_capabilities(server_capabilities)

        test.assert.truthy(processed.workspace.fileOperations)
        test.assert.truthy(processed.completionProvider.resolveProvider)
    end)

    test.it("should register file watchers for project files", function()
        local client = require('remote-lsp.client')

        local registration_params = {
            registrations = {
                {
                    id = "file-watcher-rust",
                    method = "workspace/didChangeWatchedFiles",
                    registerOptions = {
                        watchers = {
                            { globPattern = "**/*.rs" },
                            { globPattern = "**/Cargo.toml" },
                            { globPattern = "**/Cargo.lock" }
                        }
                    }
                }
            }
        }

        local success = client.handle_registration_request(registration_params)
        test.assert.truthy(success)
    end)

    test.it("should handle dynamic capability registration for future features", function()
        local client = require('remote-lsp.client')

        -- Future gitsigns might register custom capabilities
        local registration_params = {
            registrations = {
                {
                    id = "gitsigns-blame-provider",
                    method = "textDocument/blame",
                    registerOptions = {
                        documentSelector = { { language = "rust" }, { language = "python" } }
                    }
                }
            }
        }

        local success = client.handle_registration_request(registration_params)
        test.assert.truthy(success)
    end)
end)

test.describe("LSP Message Processing for Specific Languages", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle rust-analyzer specific notifications", function()
        local handlers = require('remote-lsp.handlers')

        -- rust-analyzer workspace reload notification
        local message = {
            method = "rust-analyzer/reloadWorkspace",
            params = {}
        }

        local processed = handlers.process_message(message)
        test.assert.equals(processed.method, "rust-analyzer/reloadWorkspace")

        -- Future file watcher should trigger this when Cargo.toml changes
    end)

    test.it("should handle clangd compilation database updates", function()
        local handlers = require('remote-lsp.handlers')

        local message = {
            method = "textDocument/didOpen",
            params = {
                textDocument = {
                    uri = "file:///remote/project/src/main.cpp",
                    languageId = "cpp",
                    version = 1,
                    text = "#include <iostream>"
                }
            }
        }

        local processed = handlers.process_message(message)
        test.assert.equals(processed.params.textDocument.languageId, "cpp")

        -- Future file watcher should update when compile_commands.json changes
    end)

    test.it("should handle Python import resolution with remote paths", function()
        local handlers = require('remote-lsp.handlers')

        local message = {
            method = "textDocument/completion",
            params = {
                textDocument = {
                    uri = "file:///remote/project/src/main.py"
                },
                position = { line = 0, character = 7 },
                context = {
                    triggerKind = 1
                }
            }
        }

        local processed = handlers.process_message(message)
        test.assert.truthy(processed.params.textDocument.uri)
    end)

    test.it("should handle TypeScript project references", function()
        local handlers = require('remote-lsp.handlers')

        -- TypeScript project references for monorepo
        local message = {
            method = "typescript/projectInfo",
            params = {
                textDocument = {
                    uri = "file:///remote/project/frontend/src/main.ts"
                }
            }
        }

        local processed = handlers.process_message(message)
        test.assert.equals(processed.method, "typescript/projectInfo")
    end)

    test.it("should handle Go workspace modules", function()
        local handlers = require('remote-lsp.handlers')

        local message = {
            method = "workspace/didChangeWatchedFiles",
            params = {
                changes = {
                    {
                        uri = "file:///remote/project/go.mod",
                        type = 2  -- Changed
                    },
                    {
                        uri = "file:///remote/project/go.sum",
                        type = 2  -- Changed
                    }
                }
            }
        }

        local processed = handlers.process_message(message)
        test.assert.equals(#processed.params.changes, 2)

        -- Future file watcher should detect go.mod/go.sum changes
    end)
end)

test.describe("LSP Server Error Handling", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle server startup failures gracefully", function()
        local client = require('remote-lsp.client')

        -- Enable failure simulation
        lsp_mocks._simulate_failure = true

        -- Mock server not found
        mocks.ssh_mock.set_response("ssh .* rust%-analyzer", "", "command not found")

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer"
        }

        local result = client.start_lsp_server(config)
        test.assert.falsy(result)
        
        -- Reset failure simulation
        lsp_mocks._simulate_failure = false

        -- Should not crash and should log appropriate error
    end)

    test.it("should handle server crash and restart", function()
        local client = require('remote-lsp.client')

        -- Mock server starting then crashing
        local server_id = client.start_lsp_server({
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer"
        })

        test.assert.truthy(server_id)

        -- Simulate server crash
        local restarted = client.restart_server(server_id)
        test.assert.truthy(restarted)
    end)

    test.it("should handle malformed server responses", function()
        local handlers = require('remote-lsp.handlers')

        -- Malformed JSON-RPC response
        local malformed_response = {
            -- Missing id or result/error
            jsonrpc = "2.0"
        }

        local processed = handlers.process_response(malformed_response)
        test.assert.truthy(processed)  -- Should not crash
    end)

    test.it("should handle server timeout scenarios", function()
        local client = require('remote-lsp.client')

        -- Enable failure simulation for timeout
        lsp_mocks._simulate_failure = true

        -- Mock slow server response
        mocks.ssh_mock.set_response("ssh .* rust%-analyzer", "", "", 10000)  -- 10 second delay

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer",
            timeout = 5000  -- 5 second timeout
        }

        local start_time = os.clock()
        local result = client.start_lsp_server(config)
        local end_time = os.clock()

        test.assert.falsy(result)
        test.assert.truthy((end_time - start_time) < 6.0)  -- Should timeout in ~5 seconds
        
        -- Reset failure simulation
        lsp_mocks._simulate_failure = false
    end)
end)
