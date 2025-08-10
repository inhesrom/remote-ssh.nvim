local test = require("tests.init")
local mocks = require("tests.mocks")
local lsp_mocks = require("tests.lsp_mocks")

test.describe("LSP Proxy Advanced Features", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
        -- Mock proxy process
        mocks.ssh_mock.set_response("ssh .* python3 .*/proxy%.py", "proxy_started")
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle complex workspace edits with file watcher awareness", function()
        local proxy = require("remote-lsp.proxy")

        local workspace_edit = {
            changes = {
                ["file:///remote/project/src/main.rs"] = {
                    {
                        range = { start = { line = 10, character = 0 }, ["end"] = { line = 10, character = 0 } },
                        newText = "use std::fs;\n",
                    },
                },
                ["file:///remote/project/src/lib.rs"] = {
                    {
                        range = { start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 } },
                        newText = "// Updated library\n",
                    },
                },
            },
        }

        local message = {
            method = "workspace/applyEdit",
            params = { edit = workspace_edit },
        }

        -- Future file watcher should be notified of these changes
        local processed = proxy.process_message(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        test.assert.truthy(processed.params.edit.changes)
        test.assert.equals(vim.tbl_count(processed.params.edit.changes), 2)
    end)

    test.it("should handle multi-root workspace for monorepo support", function()
        local proxy = require("remote-lsp.proxy")

        local message = {
            method = "workspace/workspaceFolders",
            params = {},
        }

        local response = {
            id = 1,
            result = {
                {
                    uri = "file:///remote/project/backend",
                    name = "Backend",
                },
                {
                    uri = "file:///remote/project/frontend",
                    name = "Frontend",
                },
            },
        }

        local processed = proxy.process_response(response, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        -- Future gitsigns should work across all workspace folders
        test.assert.equals(#processed.result, 2)
        test.assert.contains(processed.result[1].uri, "/home/user/project/backend")
    end)

    test.it("should prepare for gitsigns blame integration via LSP", function()
        local proxy = require("remote-lsp.proxy")

        -- Future gitsigns might send custom LSP requests for blame info
        local message = {
            method = "$/gitsigns/blame",
            params = {
                textDocument = {
                    uri = "file:///remote/project/src/main.rs",
                },
                position = { line = 10, character = 5 },
            },
        }

        local processed = proxy.process_message(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        test.assert.equals(processed.method, "$/gitsigns/blame")
        test.assert.truthy(processed.params.textDocument.uri)
    end)

    test.it("should handle file URI schemes for various protocols", function()
        local proxy = require("remote-lsp.proxy")

        local test_cases = {
            -- Standard file URIs
            { input = "file:///remote/project/main.rs", expected = "file:///home/user/project/main.rs" },
            -- Git URIs (for future gitsigns integration)
            { input = "git://remote/project/.git/main.rs", expected = "git://local/project/.git/main.rs" },
            -- SSH URIs
            { input = "ssh://user@host/project/main.rs", expected = "file:///home/user/project/main.rs" },
        }

        for _, case in ipairs(test_cases) do
            local result = proxy.translate_uri_to_local(case.input, "/remote/project", "/home/user/project")
            test.assert.equals(result, case.expected, "Failed for input: " .. case.input)
        end
    end)

    test.it("should support language server specific extensions", function()
        local proxy = require("remote-lsp.proxy")

        -- rust-analyzer specific request that future features might use
        local message = {
            method = "rust-analyzer/openDocs",
            params = {
                textDocument = {
                    uri = "file:///remote/project/src/main.rs",
                },
                position = { line = 5, character = 10 },
            },
        }

        local processed = proxy.process_message(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        test.assert.equals(processed.method, "rust-analyzer/openDocs")
        test.assert.contains(processed.params.textDocument.uri, "/home/user/project")
    end)

    test.it("should handle LSP progress notifications for file operations", function()
        local proxy = require("remote-lsp.proxy")

        -- Progress notification that might include file operations for watcher
        local message = {
            method = "$/progress",
            params = {
                token = "indexing-123",
                value = {
                    kind = "report",
                    message = "Indexing src/main.rs",
                    percentage = 50,
                },
            },
        }

        local processed = proxy.process_message(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        test.assert.equals(processed.method, "$/progress")
        test.assert.equals(processed.params.token, "indexing-123")
    end)
end)

test.describe("LSP Proxy Error Handling and Recovery", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should handle proxy connection failures gracefully", function()
        local proxy = require("remote-lsp.proxy")

        -- Enable proxy failure simulation
        lsp_mocks._simulate_proxy_failure = true

        -- Simulate proxy failure
        mocks.ssh_mock.set_response("ssh .* python3 .*/proxy%.py", "", "connection refused")

        local result = proxy.start_proxy({
            host = "test@localhost",
            remote_root = "/remote/project",
        })

        test.assert.falsy(result, "Should handle proxy startup failure")

        -- Reset failure simulation
        lsp_mocks._simulate_proxy_failure = false
    end)

    test.it("should recover from temporary SSH connection loss", function()
        local proxy = require("remote-lsp.proxy")

        -- Initial success
        local proxy_id = proxy.start_proxy({
            host = "test@localhost",
            remote_root = "/remote/project",
        })

        test.assert.truthy(proxy_id)

        -- Simulate temporary connection loss and recovery
        local recovered = proxy.check_and_recover_connection(proxy_id)
        test.assert.truthy(recovered)
    end)

    test.it("should handle malformed LSP messages gracefully", function()
        local proxy = require("remote-lsp.proxy")

        local malformed_message = {
            -- Missing required fields
            method = "textDocument/didOpen",
            -- No params
        }

        local processed = proxy.process_message(malformed_message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        -- Should not crash, might return error or sanitized message
        test.assert.truthy(processed)
    end)

    test.it("should handle large message payloads efficiently", function()
        local proxy = require("remote-lsp.proxy")

        -- Large completion response
        local large_message = {
            id = 1,
            result = {
                items = {},
            },
        }

        -- Generate large completion list
        for i = 1, 1000 do
            table.insert(large_message.result.items, {
                label = "completion_item_" .. i,
                kind = 1,
                detail = "Detailed description for item " .. i,
                documentation = string.rep("Lorem ipsum ", 100),
            })
        end

        local start_time = os.clock()
        local processed = proxy.process_response(large_message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })
        local end_time = os.clock()

        test.assert.truthy(processed)
        test.assert.truthy((end_time - start_time) < 1.0, "Processing should be fast even for large messages")
    end)
end)

test.describe("LSP Proxy Performance Optimizations", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        lsp_mocks.enable_lsp_mocks()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        lsp_mocks.disable_lsp_mocks()
    end)

    test.it("should batch URI translations efficiently", function()
        local proxy = require("remote-lsp.proxy")

        local message = {
            method = "textDocument/references",
            result = {},
        }

        -- Create many references for batch processing
        for i = 1, 100 do
            table.insert(message.result, {
                uri = "file:///remote/project/src/file" .. i .. ".rs",
                range = {
                    start = { line = i, character = 0 },
                    ["end"] = { line = i, character = 10 },
                },
            })
        end

        local start_time = os.clock()
        local processed = proxy.process_response(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })
        local end_time = os.clock()

        test.assert.equals(#processed.result, 100)
        test.assert.truthy((end_time - start_time) < 0.1, "Batch processing should be efficient")
    end)

    test.it("should cache URI translations for repeated use", function()
        local proxy = require("remote-lsp.proxy")

        local message = {
            method = "textDocument/publishDiagnostics",
            params = {
                uri = "file:///remote/project/src/main.rs",
                diagnostics = {},
            },
        }

        -- First translation (cold cache)
        local first = proxy.process_message(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        -- Second translation (warm cache)
        local second = proxy.process_message(message, {
            local_root = "/home/user/project",
            remote_root = "/remote/project",
        })

        test.assert.equals(first.params.uri, second.params.uri)
    end)

    test.it("should handle concurrent message processing", function()
        local proxy = require("remote-lsp.proxy")

        -- Simulate concurrent messages (future file watcher might send many)
        local messages = {}
        for i = 1, 10 do
            table.insert(messages, {
                id = i,
                method = "textDocument/didChange",
                params = {
                    textDocument = {
                        uri = "file:///remote/project/src/file" .. i .. ".rs",
                        version = i,
                    },
                    contentChanges = { { text = "new content " .. i } },
                },
            })
        end

        local results = {}
        for i, message in ipairs(messages) do
            results[i] = proxy.process_message(message, {
                local_root = "/home/user/project",
                remote_root = "/remote/project",
            })
        end

        test.assert.equals(#results, 10)
        for i, result in ipairs(results) do
            test.assert.equals(result.id, i)
        end
    end)
end)
