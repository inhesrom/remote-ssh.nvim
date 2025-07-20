local test = require('tests.init')
local mocks = require('tests.mocks')
local lsp_mocks = require('tests.lsp_mocks')

test.describe("LSP Core Functionality", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
        
        -- Debug: Check if mocks are properly loaded
        local handlers = require('remote-lsp.handlers')
        if not handlers.process_message then
            print("WARNING: process_message not found in handlers")
            for k, v in pairs(handlers) do
                print("Handler key:", k, type(v))
            end
        end
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should initialize LSP client with proper configuration", function()
        local client = require('remote-lsp.client')

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer"
        }

        local result = client.start_lsp_server(config)
        test.assert.truthy(result, "LSP client should initialize successfully")
    end)

    test.it("should handle LSP server startup failure gracefully", function()
        mocks.ssh_mock.set_response("ssh .* rust%-analyzer", "", "command not found")

        -- Enable failure simulation
        local lsp_mocks = require('tests.lsp_mocks')
        lsp_mocks._simulate_failure = true
        
        local client = require('remote-lsp.client')
        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer"
        }

        local result = client.start_lsp_server(config)
        test.assert.falsy(result, "Should handle server startup failure")
        
        -- Reset failure simulation
        lsp_mocks._simulate_failure = false
    end)

    test.it("should properly format LSP initialization request", function()
        local handlers = require('remote-lsp.handlers')

        local init_params = handlers.create_initialization_params({
            root_uri = "file:///remote/project",
            capabilities = {
                textDocument = {
                    completion = { completionItem = { snippetSupport = true } }
                }
            }
        })

        test.assert.equals(init_params.rootUri, "file:///remote/project")
        test.assert.truthy(init_params.capabilities.textDocument.completion)
    end)

    test.it("should handle file watching capabilities for future integration", function()
        local handlers = require('remote-lsp.handlers')

        -- Test that file watching capabilities are properly set up
        local capabilities = handlers.get_default_capabilities()

        -- This should be present for future file watcher integration
        test.assert.truthy(capabilities.workspace)
        test.assert.truthy(capabilities.workspace.didChangeWatchedFiles)
    end)

    test.it("should prepare for gitsigns integration via workspace capabilities", function()
        local handlers = require('remote-lsp.handlers')

        local capabilities = handlers.get_default_capabilities()

        -- Ensure workspace capabilities that gitsigns might need
        test.assert.truthy(capabilities.workspace.workspaceEdit)
        test.assert.truthy(capabilities.workspace.didChangeConfiguration)
    end)
end)

test.describe("LSP Message Handling", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle textDocument/didOpen with proper URI translation", function()
        local handlers = require('remote-lsp.handlers')

        local local_uri = "file:///home/user/project/src/main.rs"
        local remote_uri = "file:///remote/project/src/main.rs"

        local message = {
            method = "textDocument/didOpen",
            params = {
                textDocument = {
                    uri = local_uri,
                    languageId = "rust",
                    version = 1,
                    text = "fn main() {}"
                }
            }
        }

        local translated = handlers.translate_uri_to_remote(message, "/home/user/project", "/remote/project")
        test.assert.equals(translated.params.textDocument.uri, remote_uri)
    end)

    test.it("should handle textDocument/didChange for file watcher integration", function()
        local handlers = require('remote-lsp.handlers')

        local message = {
            method = "textDocument/didChange",
            params = {
                textDocument = {
                    uri = "file:///remote/project/src/main.rs",
                    version = 2
                },
                contentChanges = {
                    {
                        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 2 } },
                        text = "fn"
                    }
                }
            }
        }

        -- This should work with future file watcher that might send similar messages
        local processed = handlers.process_message(message)
        test.assert.equals(processed.method, "textDocument/didChange")
        test.assert.equals(processed.params.textDocument.version, 2)
    end)

    test.it("should support workspace/didChangeWatchedFiles for future file watcher", function()
        local handlers = require('remote-lsp.handlers')

        -- Simulate file watcher event that future implementation might send
        local message = {
            method = "workspace/didChangeWatchedFiles",
            params = {
                changes = {
                    {
                        uri = "file:///remote/project/src/lib.rs",
                        type = 2  -- Changed
                    }
                }
            }
        }

        local processed = handlers.process_message(message)
        test.assert.equals(processed.method, "workspace/didChangeWatchedFiles")
        test.assert.equals(#processed.params.changes, 1)
    end)
end)

test.describe("LSP Git Integration Preparation", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
        -- Mock git commands that gitsigns might use
        mocks.ssh_mock.set_response("ssh .* 'cd .* && git rev%-parse %-%-show%-toplevel'", "/remote/project")
        mocks.ssh_mock.set_response("ssh .* 'cd .* && git status %-%-porcelain'", "M  src/main.rs")
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle workspace/executeCommand for future gitsigns integration", function()
        local handlers = require('remote-lsp.handlers')

        -- Simulate command that gitsigns might send via LSP
        local message = {
            method = "workspace/executeCommand",
            params = {
                command = "gitsigns.stage_hunk",
                arguments = {
                    {
                        uri = "file:///remote/project/src/main.rs",
                        range = { start = { line = 10, character = 0 }, ["end"] = { line = 15, character = 0 } }
                    }
                }
            }
        }

        local processed = handlers.process_message(message)
        test.assert.equals(processed.method, "workspace/executeCommand")
        test.assert.equals(processed.params.command, "gitsigns.stage_hunk")
    end)

    test.it("should support textDocument/publishDiagnostics with git-aware context", function()
        local handlers = require('remote-lsp.handlers')

        local message = {
            method = "textDocument/publishDiagnostics",
            params = {
                uri = "file:///remote/project/src/main.rs",
                diagnostics = {
                    {
                        range = { start = { line = 5, character = 0 }, ["end"] = { line = 5, character = 10 } },
                        severity = 1,
                        message = "unused variable",
                        source = "rust-analyzer"
                    }
                }
            }
        }

        -- Future gitsigns integration might need to correlate diagnostics with git changes
        local processed = handlers.process_message(message)
        test.assert.equals(processed.params.uri, "file:///remote/project/src/main.rs")
        test.assert.equals(#processed.params.diagnostics, 1)
    end)
end)

test.describe("LSP Client Lifecycle with Future Features", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should initialize client with file watching registration capability", function()
        local client = require('remote-lsp.client')

        local config = {
            host = "test@localhost",
            root_dir = "/remote/project",
            server_name = "rust_analyzer",
            -- Future file watcher configuration
            enable_file_watching = true,
            watch_patterns = { "**/*.rs", "Cargo.toml" }
        }

        local initialized = client.initialize_with_capabilities(config)
        test.assert.truthy(initialized)
    end)

    test.it("should register for file change notifications", function()
        local client = require('remote-lsp.client')

        -- This should prepare for future file watcher integration
        local registration = {
            id = "file-watcher-1",
            method = "workspace/didChangeWatchedFiles",
            registerOptions = {
                watchers = {
                    { globPattern = "**/*.rs" },
                    { globPattern = "**/Cargo.toml" }
                }
            }
        }

        local success = client.register_capability(registration)
        test.assert.truthy(success)
    end)

    test.it("should handle client shutdown with cleanup for watchers and git", function()
        local client = require('remote-lsp.client')

        -- Mock active client
        client._active_clients = {
            ["test@localhost:/remote/project"] = {
                id = 1,
                server_name = "rust_analyzer",
                watchers = { "file-watcher-1" },
                git_integration = true
            }
        }

        local success = client.shutdown_client("test@localhost:/remote/project")
        test.assert.truthy(success)
        test.assert.truthy(vim.tbl_isempty(client._active_clients))
    end)
end)
