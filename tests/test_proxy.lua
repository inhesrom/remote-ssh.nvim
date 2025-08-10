-- Test cases for the LSP proxy script functionality
local test = require('tests.init')
local mocks = require('tests.mocks')

-- Mock LSP proxy functionality
local proxy_mock = {}

-- Mock the proxy.py URI replacement functionality
proxy_mock.replace_uris = function(obj, remote, protocol)
    if type(obj) == "string" then
        -- Handle malformed URIs like "file://rsync://host/path"
        local malformed_prefix = "file://" .. protocol .. "://" .. remote .. "/"
        if obj:match("^" .. vim.fn.escape(malformed_prefix, "()[]*+-?^$%.")) then
            local path_part = obj:sub(#malformed_prefix + 1)
            local clean_path = path_part:gsub("^/+", "")
            return "file:///" .. clean_path
        end

        -- Convert rsync://host/path to file:///path
        local remote_prefix = protocol .. "://" .. remote .. "/"
        if obj:match("^" .. vim.fn.escape(remote_prefix, "()[]*+-?^$%.")) then
            local path_part = obj:sub(#remote_prefix + 1)
            local clean_path = path_part:gsub("^/+", "")
            return "file:///" .. clean_path
        end

        -- Handle double-slash case: rsync://host//path
        local double_slash_prefix = protocol .. "://" .. remote .. "//"
        if obj:match("^" .. vim.fn.escape(double_slash_prefix, "()[]*+-?^$%.")) then
            local path_part = obj:sub(#double_slash_prefix + 1)
            local clean_path = path_part:gsub("^/+", "")
            return "file:///" .. clean_path
        end

        -- Convert file:///path to rsync://host/path
        if obj:match("^file:///") then
            local path_part = obj:sub(9) -- Remove "file:///"
            return protocol .. "://" .. remote .. "/" .. path_part
        end

        -- Handle file:// (without triple slash)
        if obj:match("^file://") and not obj:match("^file:///") then
            local path_part = obj:sub(8) -- Remove "file://"
            return protocol .. "://" .. remote .. "/" .. path_part
        end
    elseif type(obj) == "table" then
        local result = {}
        for k, v in pairs(obj) do
            -- Translate both keys and values if they contain URIs
            local new_key = k
            if type(k) == "string" then
                new_key = proxy_mock.replace_uris(k, remote, protocol)
            end
            result[new_key] = proxy_mock.replace_uris(v, remote, protocol)
        end
        return result
    end

    return obj
end

-- Mock LSP message creation
proxy_mock.create_lsp_message = function(method, params)
    return {
        jsonrpc = "2.0",
        id = 1,
        method = method,
        params = params or {}
    }
end

proxy_mock.create_lsp_response = function(id, result)
    return {
        jsonrpc = "2.0",
        id = id,
        result = result or {}
    }
end

-- Mock subprocess for testing proxy process creation
local subprocess_mock = {
    processes = {},
    next_pid = 1000
}

function subprocess_mock.Popen(cmd, options)
    local process = {
        pid = subprocess_mock.next_pid,
        cmd = cmd,
        stdin_data = "",
        stdout_data = "",
        stderr_data = "",
        exit_code = nil
    }

    process.stdin = {
        write = function(self, data)
            -- Mock stdin write
            process.stdin_data = (process.stdin_data or "") .. data
        end
    }

    process.stdout = {
        read = function(self, size)
            -- Mock stdout read
            return process.stdout_data or ""
        end
    }

    process.stderr = {
        readline = function(self)
            -- Mock stderr readline
            return process.stderr_data or ""
        end
    }

    process.poll = function(self)
        return process.exit_code
    end

    process.wait = function(self)
        return process.exit_code or 0
    end

    process.terminate = function(self)
        process.exit_code = -1
    end

    subprocess_mock.next_pid = subprocess_mock.next_pid + 1
    table.insert(subprocess_mock.processes, process)
    return process
end

function subprocess_mock.clear()
    subprocess_mock.processes = {}
    subprocess_mock.next_pid = 1000
end

test.describe("LSP Proxy URI Translation", function()
    test.setup(function()
        -- Add vim.fn.escape for pattern escaping
        vim.fn.escape = function(str, chars)
            local result = str
            for char in chars:gmatch(".") do
                result = result:gsub("%" .. char, "%%" .. char)
            end
            return result
        end
    end)

    test.it("should translate remote URIs to file URIs", function()
        local input = "rsync://user@host/project/src/main.rs"
        local expected = "file:///project/src/main.rs"
        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.equals(result, expected, "Should convert rsync URI to file URI")
    end)

    test.it("should translate file URIs to remote URIs", function()
        local input = "file:///project/src/main.rs"
        local expected = "rsync://user@host/project/src/main.rs"
        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.equals(result, expected, "Should convert file URI to rsync URI")
    end)

    test.it("should handle malformed URIs", function()
        local input = "file://rsync://user@host/project/src/main.rs"
        local expected = "file:///project/src/main.rs"
        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.equals(result, expected, "Should fix malformed URIs")
    end)

    test.it("should handle double slashes", function()
        local input = "rsync://user@host//project/src/main.rs"
        local expected = "file:///project/src/main.rs"
        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.equals(result, expected, "Should handle double slashes correctly")
    end)

    test.it("should handle file:// without triple slash", function()
        local input = "file://project/src/main.rs"
        local expected = "rsync://user@host/project/src/main.rs"
        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.equals(result, expected, "Should handle file:// format")
    end)

    test.it("should work with SCP protocol", function()
        local input = "scp://user@host/project/src/main.rs"
        local expected = "file:///project/src/main.rs"
        local result = proxy_mock.replace_uris(input, "user@host", "scp")

        test.assert.equals(result, expected, "Should work with SCP protocol")
    end)

    test.it("should translate URIs in complex objects", function()
        local input = {
            textDocument = {
                uri = "rsync://user@host/project/src/main.rs"
            },
            position = {
                line = 10,
                character = 5
            }
        }

        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.equals(result.textDocument.uri, "file:///project/src/main.rs")
        test.assert.equals(result.position.line, 10)
        test.assert.equals(result.position.character, 5)
    end)

    test.it("should handle nested URI translations", function()
        local input = {
            changes = {
                ["rsync://user@host/project/file1.rs"] = {
                    {
                        range = { start = { line = 0, character = 0 } },
                        newText = "new content"
                    }
                },
                ["rsync://user@host/project/file2.rs"] = {
                    {
                        range = { start = { line = 5, character = 0 } },
                        newText = "more content"
                    }
                }
            }
        }

        local result = proxy_mock.replace_uris(input, "user@host", "rsync")

        test.assert.truthy(result.changes["file:///project/file1.rs"])
        test.assert.truthy(result.changes["file:///project/file2.rs"])
        test.assert.falsy(result.changes["rsync://user@host/project/file1.rs"])
    end)
end)

test.describe("LSP Message Processing", function()
    test.it("should create proper LSP request messages", function()
        local message = proxy_mock.create_lsp_message("textDocument/definition", {
            textDocument = { uri = "file:///project/main.rs" },
            position = { line = 10, character = 5 }
        })

        test.assert.equals(message.jsonrpc, "2.0")
        test.assert.equals(message.method, "textDocument/definition")
        test.assert.equals(message.params.textDocument.uri, "file:///project/main.rs")
    end)

    test.it("should create proper LSP response messages", function()
        local response = proxy_mock.create_lsp_response(1, {
            uri = "file:///project/main.rs",
            range = { start = { line = 0, character = 0 } }
        })

        test.assert.equals(response.jsonrpc, "2.0")
        test.assert.equals(response.id, 1)
        test.assert.equals(response.result.uri, "file:///project/main.rs")
    end)

    test.it("should translate URIs in textDocument/definition request", function()
        local request = proxy_mock.create_lsp_message("textDocument/definition", {
            textDocument = { uri = "file:///project/src/main.rs" },
            position = { line = 42, character = 10 }
        })

        local translated = proxy_mock.replace_uris(request, "user@host", "rsync")

        test.assert.equals(translated.params.textDocument.uri, "rsync://user@host/project/src/main.rs")
        test.assert.equals(translated.params.position.line, 42)
    end)

    test.it("should translate URIs in textDocument/definition response", function()
        local response = proxy_mock.create_lsp_response(1, {
            uri = "rsync://user@host/project/src/lib.rs",
            range = {
                start = { line = 15, character = 4 },
                ["end"] = { line = 15, character = 12 }
            }
        })

        local translated = proxy_mock.replace_uris(response, "user@host", "rsync")

        test.assert.equals(translated.result.uri, "file:///project/src/lib.rs")
        test.assert.equals(translated.result.range.start.line, 15)
    end)

    test.it("should handle workspace/didChangeWatchedFiles", function()
        local notification = proxy_mock.create_lsp_message("workspace/didChangeWatchedFiles", {
            changes = {
                {
                    uri = "file:///project/Cargo.toml",
                    type = 2 -- Changed
                },
                {
                    uri = "file:///project/src/main.rs",
                    type = 1 -- Created
                }
            }
        })

        local translated = proxy_mock.replace_uris(notification, "user@host", "rsync")

        test.assert.equals(translated.params.changes[1].uri, "rsync://user@host/project/Cargo.toml")
        test.assert.equals(translated.params.changes[2].uri, "rsync://user@host/project/src/main.rs")
        test.assert.equals(translated.params.changes[1].type, 2)
    end)

    test.it("should handle textDocument/publishDiagnostics", function()
        local notification = proxy_mock.create_lsp_message("textDocument/publishDiagnostics", {
            uri = "rsync://user@host/project/src/main.rs",
            diagnostics = {
                {
                    range = {
                        start = { line = 5, character = 0 },
                        ["end"] = { line = 5, character = 10 }
                    },
                    severity = 1,
                    message = "unused variable"
                }
            }
        })

        local translated = proxy_mock.replace_uris(notification, "user@host", "rsync")

        test.assert.equals(translated.params.uri, "file:///project/src/main.rs")
        test.assert.equals(translated.params.diagnostics[1].message, "unused variable")
    end)
end)

test.describe("Proxy Process Management", function()
    test.setup(function()
        subprocess_mock.clear()
    end)

    test.teardown(function()
        subprocess_mock.clear()
    end)

    test.it("should create subprocess with correct command", function()
        local expected_cmd = {
            "python3", "-u", "lua/remote-lsp/proxy.py",
            "user@host", "rsync", "rust-analyzer"
        }

        local process = subprocess_mock.Popen(expected_cmd, {
            stdin = "PIPE",
            stdout = "PIPE",
            stderr = "PIPE"
        })

        test.assert.equals(process.cmd, expected_cmd)
        test.assert.truthy(process.pid >= 1000)
        test.assert.truthy(process.stdin)
        test.assert.truthy(process.stdout)
        test.assert.truthy(process.stderr)
    end)

    test.it("should handle process termination", function()
        local test_process = subprocess_mock.Popen({"python3", "proxy.py"}, {})

        test.assert.falsy(test_process.exit_code)

        test_process:terminate()

        test.assert.equals(test_process.exit_code, -1)
    end)

    test.it("should track multiple processes", function()
        local process1 = subprocess_mock.Popen({"python3", "proxy.py", "host1"}, {})
        local process2 = subprocess_mock.Popen({"python3", "proxy.py", "host2"}, {})

        test.assert.equals(#subprocess_mock.processes, 2)
        test.assert.truthy(process1.pid ~= process2.pid)
    end)
end)

test.describe("Integration with Remote LSP Client", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        subprocess_mock.clear()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
        subprocess_mock.clear()
    end)

    test.it("should simulate full LSP initialization flow", function()
        -- Mock the LSP initialization process
        local init_request = proxy_mock.create_lsp_message("initialize", {
            processId = 12345,
            rootUri = "file:///project",
            capabilities = {
                textDocument = {
                    definition = { linkSupport = true }
                }
            }
        })

        -- Translate for sending to remote server
        local remote_request = proxy_mock.replace_uris(init_request, "user@host", "rsync")
        test.assert.equals(remote_request.params.rootUri, "rsync://user@host/project")

        -- Mock server response
        local server_response = proxy_mock.create_lsp_response(1, {
            capabilities = {
                textDocumentSync = 1,
                definitionProvider = true
            },
            serverInfo = {
                name = "rust-analyzer",
                version = "0.3.0"
            }
        })

        -- Response doesn't need URI translation for this case
        local client_response = proxy_mock.replace_uris(server_response, "user@host", "rsync")
        test.assert.equals(client_response.result.capabilities.definitionProvider, true)
    end)

    test.it("should simulate textDocument/didOpen flow", function()
        local did_open = proxy_mock.create_lsp_message("textDocument/didOpen", {
            textDocument = {
                uri = "file:///project/src/main.rs",
                languageId = "rust",
                version = 1,
                text = "fn main() { println!(\"Hello, world!\"); }"
            }
        })

        local remote_notification = proxy_mock.replace_uris(did_open, "user@host", "rsync")
        test.assert.equals(remote_notification.params.textDocument.uri, "rsync://user@host/project/src/main.rs")
        test.assert.equals(remote_notification.params.textDocument.languageId, "rust")
    end)

    test.it("should simulate go-to-definition flow", function()
        -- Client request
        local definition_request = proxy_mock.create_lsp_message("textDocument/definition", {
            textDocument = { uri = "file:///project/src/main.rs" },
            position = { line = 5, character = 10 }
        })

        local remote_request = proxy_mock.replace_uris(definition_request, "user@host", "rsync")
        test.assert.equals(remote_request.params.textDocument.uri, "rsync://user@host/project/src/main.rs")

        -- Server response with location
        local server_response = proxy_mock.create_lsp_response(1, {
            uri = "rsync://user@host/project/src/lib.rs",
            range = {
                start = { line = 10, character = 0 },
                ["end"] = { line = 10, character = 8 }
            }
        })

        local client_response = proxy_mock.replace_uris(server_response, "user@host", "rsync")
        test.assert.equals(client_response.result.uri, "file:///project/src/lib.rs")
        test.assert.equals(client_response.result.range.start.line, 10)
    end)

    test.it("should handle diagnostic publishing", function()
        -- Server publishes diagnostics
        local diagnostics = proxy_mock.create_lsp_message("textDocument/publishDiagnostics", {
            uri = "rsync://user@host/project/src/main.rs",
            version = 1,
            diagnostics = {
                {
                    range = {
                        start = { line = 2, character = 4 },
                        ["end"] = { line = 2, character = 12 }
                    },
                    severity = 2, -- Warning
                    source = "rust-analyzer",
                    message = "unused variable: `x`",
                    code = "unused_variables"
                }
            }
        })

        local client_diagnostics = proxy_mock.replace_uris(diagnostics, "user@host", "rsync")
        test.assert.equals(client_diagnostics.params.uri, "file:///project/src/main.rs")
        test.assert.equals(client_diagnostics.params.diagnostics[1].message, "unused variable: `x`")
        test.assert.equals(client_diagnostics.params.diagnostics[1].severity, 2)
    end)

    test.it("Handle URI replacement in a key rather than just values", function()
        -- LSP rename response with workspace/applyEdit result containing multiple changes
        local rename_response = {
            id = 6,
            jsonrpc = "2.0",
            result = {
                changes = {
                    ["file:///home/garfieldcmix/git/KMITL-ComPro-1/lab-5/ex03.c"] = {
                        {
                            newText = "studentMarks",
                            range = {
                                ["end"] = {
                                    character = 20,
                                    line = 5
                                },
                                start = {
                                    character = 8,
                                    line = 5
                                }
                            }
                        },
                        {
                            newText = "studentMarks",
                            range = {
                                ["end"] = {
                                    character = 33,
                                    line = 9
                                },
                                start = {
                                    character = 21,
                                    line = 9
                                }
                            }
                        },
                        {
                            newText = "studentMarks",
                            range = {
                                ["end"] = {
                                    character = 33,
                                    line = 15
                                },
                                start = {
                                    character = 21,
                                    line = 15
                                }
                            }
                        },
                        {
                            newText = "studentMarks",
                            range = {
                                ["end"] = {
                                    character = 38,
                                    line = 17
                                },
                                start = {
                                    character = 26,
                                    line = 17
                                }
                            }
                        },
                        {
                            newText = "studentMarks",
                            range = {
                                ["end"] = {
                                    character = 38,
                                    line = 18
                                },
                                start = {
                                    character = 26,
                                    line = 18
                                }
                            }
                        }
                    }
                }
            }
        }

        local remote_response = proxy_mock.replace_uris(rename_response, "garfieldcmix@host", "rsync")

        test.assert.equals(remote_response.id, 6)
        test.assert.equals(remote_response.jsonrpc, "2.0")
        test.assert.truthy(remote_response.result.changes)

        -- Verify the file URI was translated from file:// to rsync://
        local expected_remote_key = "rsync://garfieldcmix@host/home/garfieldcmix/git/KMITL-ComPro-1/lab-5/ex03.c"
        local file_changes = remote_response.result.changes[expected_remote_key]
        test.assert.truthy(file_changes, "Should have changes for the translated rsync URI")
        test.assert.equals(#file_changes, 5, "Should have 5 text edits")

        -- Verify original file:// key is removed
        test.assert.falsy(remote_response.result.changes["file:///home/garfieldcmix/git/KMITL-ComPro-1/lab-5/ex03.c"])

        -- Verify all changes have the correct newText and structure
        for i, change in ipairs(file_changes) do
            test.assert.equals(change.newText, "studentMarks", "Change " .. i .. " should rename to studentMarks")
            test.assert.truthy(change.range, "Change " .. i .. " should have a range")
            test.assert.truthy(change.range.start, "Change " .. i .. " should have range start")
            test.assert.truthy(change.range["end"], "Change " .. i .. " should have range end")
        end

        -- Verify specific ranges are preserved correctly
        test.assert.equals(file_changes[1].range.start.line, 5)
        test.assert.equals(file_changes[1].range.start.character, 8)
        test.assert.equals(file_changes[1].range["end"].line, 5)
        test.assert.equals(file_changes[1].range["end"].character, 20)

        test.assert.equals(file_changes[5].range.start.line, 18)
        test.assert.equals(file_changes[5].range.start.character, 26)
        test.assert.equals(file_changes[5].range["end"].line, 18)
        test.assert.equals(file_changes[5].range["end"].character, 38)
        
        -- Verify middle ranges to ensure all edits are correct
        test.assert.equals(file_changes[2].range.start.line, 9)
        test.assert.equals(file_changes[2].range.start.character, 21)
        test.assert.equals(file_changes[2].range["end"].character, 33)
        
        test.assert.equals(file_changes[3].range.start.line, 15)
        test.assert.equals(file_changes[4].range.start.line, 17)
        
        -- Ensure only one file key exists in changes
        test.assert.equals(vim.tbl_count(remote_response.result.changes), 1, "Should have exactly one file in changes")
    end)
end)
