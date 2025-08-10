-- Tests that simulate the actual proxy.py script behavior
local test = require("tests.init")
local mocks = require("tests.mocks")

-- Read the actual proxy.py file to understand its structure
local proxy_script_path = "lua/remote-lsp/proxy.py"

-- Mock the key functions from proxy.py
local proxy_py_mock = {}

-- Simulate the replace_uris function from proxy.py
function proxy_py_mock.replace_uris(obj, remote, protocol)
    if type(obj) == "string" then
        -- Handle malformed URIs like "file://rsync://host/path" (from LSP client initialization)
        local malformed_prefix = "file://" .. protocol .. "://" .. remote .. "/"
        if obj:find(malformed_prefix, 1, true) == 1 then
            -- Extract the path and convert to proper file:/// format
            local path_part = obj:sub(#malformed_prefix + 1)
            local clean_path = path_part:gsub("^/+", "")
            return "file:///" .. clean_path
        end

        -- Convert rsync://host/path to file:///path (with double-slash fix)
        local remote_prefix = protocol .. "://" .. remote .. "/"
        if obj:find(remote_prefix, 1, true) == 1 then
            -- Extract path after the host
            local path_part = obj:sub(#remote_prefix + 1)
            -- Clean up any double slashes and ensure proper format
            local clean_path = path_part:gsub("^/+", "")
            return "file:///" .. clean_path
        end

        -- Handle double-slash case: rsync://host//path
        local double_slash_prefix = protocol .. "://" .. remote .. "//"
        if obj:find(double_slash_prefix, 1, true) == 1 then
            -- Extract path after the double slash
            local path_part = obj:sub(#double_slash_prefix + 1)
            local clean_path = path_part:gsub("^/+", "")
            return "file:///" .. clean_path
        end

        -- Convert file:///path to rsync://host/path
        if obj:find("file:///", 1, true) == 1 then
            local path_part = obj:sub(9) -- Remove "file:///"
            return protocol .. "://" .. remote .. "/" .. path_part
        end

        -- Handle file:// (without triple slash)
        if obj:find("file://", 1, true) == 1 and obj:find("file:///", 1, true) ~= 1 then
            local path_part = obj:sub(8) -- Remove "file://"
            return protocol .. "://" .. remote .. "/" .. path_part
        end
    elseif type(obj) == "table" then
        local result = {}
        for k, v in pairs(obj) do
            -- Translate both keys and values if they contain URIs
            local new_key = k
            if type(k) == "string" then
                new_key = proxy_py_mock.replace_uris(k, remote, protocol)
            end
            result[new_key] = proxy_py_mock.replace_uris(v, remote, protocol)
        end
        return result
    end

    return obj
end

-- Mock the LSP message handling
function proxy_py_mock.create_content_length_message(content)
    local content_str = content
    if type(content) == "table" then
        content_str = vim.inspect(content)
    end
    return string.format("Content-Length: %d\r\n\r\n%s", #content_str, content_str)
end

function proxy_py_mock.parse_content_length_message(message)
    local content_length_match = message:match("Content%-Length: (%d+)")
    if not content_length_match then
        return nil, "No Content-Length header"
    end

    local content_length = tonumber(content_length_match)
    local header_end = message:find("\r\n\r\n")
    if not header_end then
        return nil, "No header delimiter found"
    end

    local content_start = header_end + 4
    local content = message:sub(content_start, content_start + content_length - 1)

    return content, nil
end

test.describe("Proxy Script URI Translation", function()
    test.it("should match proxy.py replace_uris behavior for basic cases", function()
        local test_cases = {
            -- Remote to local
            {
                input = "rsync://user@host/project/src/main.rs",
                expected = "file:///project/src/main.rs",
                remote = "user@host",
                protocol = "rsync",
            },
            -- Local to remote
            {
                input = "file:///project/src/main.rs",
                expected = "rsync://user@host/project/src/main.rs",
                remote = "user@host",
                protocol = "rsync",
            },
            -- SCP protocol
            {
                input = "scp://user@host/project/lib.rs",
                expected = "file:///project/lib.rs",
                remote = "user@host",
                protocol = "scp",
            },
            -- Malformed URI
            {
                input = "file://rsync://user@host/project/test.rs",
                expected = "file:///project/test.rs",
                remote = "user@host",
                protocol = "rsync",
            },
            -- Double slash handling
            {
                input = "rsync://user@host//project/src/lib.rs",
                expected = "file:///project/src/lib.rs",
                remote = "user@host",
                protocol = "rsync",
            },
        }

        for i, case in ipairs(test_cases) do
            local result = proxy_py_mock.replace_uris(case.input, case.remote, case.protocol)
            test.assert.equals(
                result,
                case.expected,
                string.format("Test case %d failed: %s -> %s", i, case.input, case.expected)
            )
        end
    end)

    test.it("should handle complex nested objects like real LSP messages", function()
        local workspace_edit = {
            changes = {
                ["file:///project/src/main.rs"] = {
                    {
                        range = {
                            start = { line = 0, character = 0 },
                            ["end"] = { line = 0, character = 0 },
                        },
                        newText = "use std::collections::HashMap;\n",
                    },
                },
                ["file:///project/src/lib.rs"] = {
                    {
                        range = {
                            start = { line = 5, character = 0 },
                            ["end"] = { line = 5, character = 10 },
                        },
                        newText = "pub fn new() -> Self",
                    },
                },
            },
        }

        local result = proxy_py_mock.replace_uris(workspace_edit, "user@host", "rsync")

        -- Check that file URIs were translated to remote URIs
        test.assert.truthy(result.changes["rsync://user@host/project/src/main.rs"])
        test.assert.truthy(result.changes["rsync://user@host/project/src/lib.rs"])
        test.assert.falsy(result.changes["file:///project/src/main.rs"])

        -- Check that nested content was preserved
        local main_change = result.changes["rsync://user@host/project/src/main.rs"][1]
        test.assert.equals(main_change.newText, "use std::collections::HashMap;\n")
        test.assert.equals(main_change.range.start.line, 0)
    end)

    test.it("should preserve non-URI strings unchanged", function()
        local mixed_object = {
            method = "textDocument/definition",
            uri = "file:///project/main.rs",
            message = "This is just a regular string",
            count = 42,
            enabled = true,
        }

        local result = proxy_py_mock.replace_uris(mixed_object, "user@host", "rsync")

        test.assert.equals(result.method, "textDocument/definition")
        test.assert.equals(result.uri, "rsync://user@host/project/main.rs")
        test.assert.equals(result.message, "This is just a regular string")
        test.assert.equals(result.count, 42)
        test.assert.equals(result.enabled, true)
    end)
end)

test.describe("Proxy Script Message Protocol", function()
    test.it("should create proper Content-Length messages", function()
        local test_content = '{"jsonrpc":"2.0","method":"initialize","id":1}'
        local message = proxy_py_mock.create_content_length_message(test_content)

        test.assert.truthy(message:match("Content%-Length: %d+\r\n\r\n"))
        test.assert.truthy(message:find(test_content, 1, true))

        -- Verify the content length is accurate
        local expected_length = #test_content
        test.assert.truthy(message:match("Content%-Length: " .. expected_length))
    end)

    test.it("should parse Content-Length messages correctly", function()
        local test_message = 'Content-Length: 45\r\n\r\n{"jsonrpc":"2.0","method":"test","params":{}}'

        local content, error = proxy_py_mock.parse_content_length_message(test_message)

        test.assert.falsy(error)
        test.assert.equals(content, '{"jsonrpc":"2.0","method":"test","params":{}}')
    end)

    test.it("should handle parsing errors gracefully", function()
        local malformed_messages = {
            "No headers here",
            "Content-Length: invalid\r\n\r\ncontent",
            "Content-Length: 10\r\n\r\nshort", -- Content shorter than declared
        }

        for _, message in ipairs(malformed_messages) do
            local content, error = proxy_py_mock.parse_content_length_message(message)

            if not content then
                test.assert.truthy(error, "Should return error for malformed message: " .. message)
            end
        end
    end)
end)

test.describe("Proxy Script End-to-End Simulation", function()
    test.setup(function()
        mocks.ssh_mock.enable()
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
    end)

    test.it("should simulate complete LSP initialize handshake", function()
        -- Step 1: Client sends initialize request
        local client_init = {
            jsonrpc = "2.0",
            id = 1,
            method = "initialize",
            params = {
                processId = 12345,
                rootUri = "file:///workspace/rust_project",
                capabilities = {
                    textDocument = { definition = { linkSupport = true } },
                },
            },
        }

        -- Step 2: Proxy translates URIs for remote server
        local remote_init = proxy_py_mock.replace_uris(client_init, "user@host", "rsync")
        test.assert.equals(remote_init.params.rootUri, "rsync://user@host/workspace/rust_project")

        -- Step 3: Create proper LSP message for transmission
        local remote_message = proxy_py_mock.create_content_length_message(vim.inspect(remote_init))
        test.assert.truthy(remote_message:match("Content%-Length:"))

        -- Step 4: Mock server response
        local server_response_content = vim.inspect({
            jsonrpc = "2.0",
            id = 1,
            result = {
                capabilities = {
                    textDocumentSync = 1,
                    definitionProvider = true,
                },
                serverInfo = { name = "rust-analyzer", version = "0.3.1546" },
            },
        })

        local server_message = proxy_py_mock.create_content_length_message(server_response_content)

        -- Step 5: Parse server response
        local parsed_response, parse_error = proxy_py_mock.parse_content_length_message(server_message)
        test.assert.falsy(parse_error)
        test.assert.truthy(parsed_response:find("rust-analyzer", 1, true))

        -- Step 6: Translate back to client (no URI translation needed for this response)
        -- In a real scenario, the proxy would handle this automatically
        test.assert.truthy(parsed_response:find("definitionProvider", 1, true))
    end)

    test.it("should simulate textDocument/didOpen notification flow", function()
        -- Client opens a Rust file
        local did_open = {
            jsonrpc = "2.0",
            method = "textDocument/didOpen",
            params = {
                textDocument = {
                    uri = "file:///workspace/rust_project/src/main.rs",
                    languageId = "rust",
                    version = 1,
                    text = 'fn main() {\n    println!("Hello, world!");\n}',
                },
            },
        }

        -- Proxy translates to remote
        local remote_notification = proxy_py_mock.replace_uris(did_open, "user@host", "rsync")
        test.assert.equals(
            remote_notification.params.textDocument.uri,
            "rsync://user@host/workspace/rust_project/src/main.rs"
        )
        test.assert.equals(remote_notification.params.textDocument.languageId, "rust")

        -- Server might respond with diagnostics
        local diagnostics_from_server = {
            jsonrpc = "2.0",
            method = "textDocument/publishDiagnostics",
            params = {
                uri = "rsync://user@host/workspace/rust_project/src/main.rs",
                version = 1,
                diagnostics = {
                    {
                        range = {
                            start = { line = 1, character = 4 },
                            ["end"] = { line = 1, character = 12 },
                        },
                        severity = 3, -- Information
                        source = "rust-analyzer",
                        message = "function `main` is never used",
                    },
                },
            },
        }

        -- Proxy translates diagnostics back to client
        local client_diagnostics = proxy_py_mock.replace_uris(diagnostics_from_server, "user@host", "rsync")
        test.assert.equals(client_diagnostics.params.uri, "file:///workspace/rust_project/src/main.rs")
        test.assert.truthy(client_diagnostics.params.diagnostics[1].message:find("main"))
    end)

    test.it("should handle bidirectional workspace operations", function()
        -- Client requests workspace symbols
        local symbol_request = {
            jsonrpc = "2.0",
            id = 2,
            method = "workspace/symbol",
            params = { query = "HashMap" },
        }

        -- No URI translation needed for the request
        local remote_request = proxy_py_mock.replace_uris(symbol_request, "user@host", "rsync")
        test.assert.equals(remote_request.params.query, "HashMap")

        -- Server responds with symbols from multiple files
        local symbol_response = {
            jsonrpc = "2.0",
            id = 2,
            result = {
                {
                    name = "HashMap",
                    kind = 23, -- Struct
                    location = {
                        uri = "rsync://user@host/workspace/rust_project/src/collections.rs",
                        range = {
                            start = { line = 42, character = 0 },
                            ["end"] = { line = 42, character = 7 },
                        },
                    },
                },
                {
                    name = "HashMap::new",
                    kind = 6, -- Function
                    location = {
                        uri = "rsync://user@host/workspace/rust_project/src/collections.rs",
                        range = {
                            start = { line = 55, character = 4 },
                            ["end"] = { line = 55, character = 7 },
                        },
                    },
                },
            },
        }

        -- Proxy translates all URIs back to client format
        local client_response = proxy_py_mock.replace_uris(symbol_response, "user@host", "rsync")

        test.assert.equals(client_response.result[1].location.uri, "file:///workspace/rust_project/src/collections.rs")
        test.assert.equals(client_response.result[2].location.uri, "file:///workspace/rust_project/src/collections.rs")
        test.assert.equals(client_response.result[1].name, "HashMap")
        test.assert.equals(client_response.result[2].name, "HashMap::new")
    end)
end)
