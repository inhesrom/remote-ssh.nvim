-- Test cases for the LSP proxy script functionality
local test = require('tests.init')
local mocks = require('tests.mocks')

-- Mock LSP proxy functionality
local proxy_mock = {}

-- Call the actual proxy.py replace_uris function
proxy_mock.replace_uris = function(obj, remote, protocol)
    -- Create a Python test script that uses the actual proxy.py function
    local test_script = [[#!/usr/bin/env python3
import sys
import json
import os

# Add the current directory to Python path to import proxy
sys.path.insert(0, os.path.join(os.getcwd(), 'lua/remote-lsp'))

# Import the actual replace_uris function
from proxy import replace_uris

def main():
    # Read arguments: obj_json, remote, protocol
    if len(sys.argv) != 4:
        print("Usage: test_script.py <obj_json> <remote> <protocol>", file=sys.stderr)
        sys.exit(1)

    obj_json = sys.argv[1]
    remote = sys.argv[2]
    protocol = sys.argv[3]

    try:
        # Parse the JSON object
        obj = json.loads(obj_json)

        # Call the actual replace_uris function
        result = replace_uris(obj, remote, protocol)

        # Convert result to Lua table syntax and output
        def json_to_lua(obj, indent=0):
            if isinstance(obj, str):
                # Escape quotes and backslashes for Lua string literals
                escaped = obj.replace('\\', '\\\\').replace('"', '\\"')
                return f'"{escaped}"'
            elif isinstance(obj, bool):
                return str(obj).lower()
            elif isinstance(obj, (int, float)):
                return str(obj)
            elif obj is None:
                return 'nil'
            elif isinstance(obj, list):
                items = [json_to_lua(item, indent+1) for item in obj]
                return '{' + ', '.join(items) + '}'
            elif isinstance(obj, dict):
                items = []
                for k, v in obj.items():
                    # Handle special "end" key (Lua reserved word)
                    key_str = f'["end"]' if k == "end" else f'["{k}"]'
                    items.append(f'{key_str} = {json_to_lua(v, indent+1)}')
                return '{' + ', '.join(items) + '}'
            return str(obj)

        print(json_to_lua(result))

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
]]

    -- Write the test script
    local script_path = "/tmp/proxy_test_runner.py"
    local script_file = io.open(script_path, "w")
    if not script_file then
        error("Failed to create test script")
    end
    script_file:write(test_script)
    script_file:close()

    -- Convert Lua object to JSON string manually for simple cases
    local obj_json
    if type(obj) == "string" then
        obj_json = '"' .. obj:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    elseif type(obj) == "table" then
        -- Handle the complex table case by converting to JSON manually
        -- This is a simplified JSON encoder for our test cases
        local function to_json(o)
            if type(o) == "string" then
                return '"' .. o:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
            elseif type(o) == "number" then
                return tostring(o)
            elseif type(o) == "boolean" then
                return o and "true" or "false"
            elseif type(o) == "table" then
                local parts = {}
                local is_array = true
                local max_index = 0

                -- Check if it's an array
                for k, v in pairs(o) do
                    if type(k) ~= "number" or k <= 0 or k ~= math.floor(k) then
                        is_array = false
                        break
                    end
                    max_index = math.max(max_index, k)
                end

                if is_array and max_index > 0 then
                    -- Handle as array
                    for i = 1, max_index do
                        parts[i] = to_json(o[i] or vim.NIL)
                    end
                    return "[" .. table.concat(parts, ",") .. "]"
                else
                    -- Handle as object
                    for k, v in pairs(o) do
                        table.insert(parts, to_json(tostring(k)) .. ":" .. to_json(v))
                    end
                    return "{" .. table.concat(parts, ",") .. "}"
                end
            else
                return "null"
            end
        end
        obj_json = to_json(obj)
    else
        obj_json = "null"
    end

    -- Execute the Python script with our data (assuming we're running from project root)
    local cmd = string.format("python3 '%s' '%s' '%s' '%s' 2>&1",
        script_path,
        obj_json:gsub("'", "'\"'\"'"),
        remote:gsub("'", "'\"'\"'"),
        protocol:gsub("'", "'\"'\"'"))

    local handle = io.popen(cmd)
    local result = handle:read("*a")
    local success = handle:close()

    -- Clean up
    os.remove(script_path)

    if not success then
        error("Python script execution failed: " .. result)
    end

    result = result:gsub("%s*$", "") -- trim whitespace

    -- Parse Lua table syntax returned by Python script
    if result:match('^".*"$') then
        -- String result
        return result:gsub('^"', ''):gsub('"$', ''):gsub('\\"', '"'):gsub('\\\\', '\\')
    elseif result:match('^{.*}$') then
        -- Lua table - use load to evaluate it directly
        local func = load("return " .. result)
        if func then
            local success, parsed = pcall(func)
            if success then
                return parsed
            end
        end

        -- Fallback: return the original object if parsing fails
        return obj
    else
        -- Return as-is for other cases
        return result
    end
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
