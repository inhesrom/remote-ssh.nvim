-- Tests for hover request/response URI translation issues
local test = require('tests.init')
local mocks = require('tests.mocks')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'

-- Mock proxy functionality to test URI translation for hover operations
local proxy_mock = {}

-- Helper function to escape pattern characters
local function escape_pattern(str)
    return str:gsub("([^%w])", "%%%1")
end

function proxy_mock.replace_uris(obj, remote, protocol)
    -- Simulate the proxy URI replacement logic matching the real proxy.py
    if type(obj) == "string" then
        local result = obj
        
        -- Convert rsync://host/path to file:///path (for requests to LSP server)
        local remote_prefix = protocol .. "://" .. remote .. "/"
        local escaped_prefix = escape_pattern(remote_prefix)
        
        -- Handle both exact matches and embedded URIs
        if result:find(escaped_prefix) then
            result = result:gsub(escaped_prefix .. "([^%s%)%]]*)", function(path)
                local clean_path = path:gsub("^/+", "")
                return "file:///" .. clean_path
            end)
            if result ~= obj then
                return result
            end
        end
        
        -- Convert file:///path to rsync://host/path (for responses from LSP server)
        if result:find("file:///") then
            result = result:gsub("file:///([^%s%)%]]*)", function(path)
                return protocol .. "://" .. remote .. "/" .. path
            end)
            if result ~= obj then
                return result
            end
        end
        
        -- Handle file:// (without triple slash) patterns
        if result:find("file://") and not result:find("file:///") then
            result = result:gsub("file://([^%s%)%]]*)", function(path)
                return protocol .. "://" .. remote .. "/" .. path
            end)
        end
        
        return result
    elseif type(obj) == "table" then
        local result = {}
        for k, v in pairs(obj) do
            result[k] = proxy_mock.replace_uris(v, remote, protocol)
        end
        return result
    else
        return obj
    end
end

-- Mock LSP client that captures hover requests/responses
local mock_lsp_client = {
    requests = {},
    responses = {},
    next_id = 1
}

function mock_lsp_client.send_request(method, params)
    local id = mock_lsp_client.next_id
    mock_lsp_client.next_id = mock_lsp_client.next_id + 1
    
    local request = {
        id = id,
        jsonrpc = "2.0",
        method = method,
        params = params
    }
    
    table.insert(mock_lsp_client.requests, request)
    return id
end

function mock_lsp_client.simulate_response(request_id, result)
    local response = {
        id = request_id,
        jsonrpc = "2.0",
        result = result
    }
    
    table.insert(mock_lsp_client.responses, response)
    return response
end

function mock_lsp_client.clear()
    mock_lsp_client.requests = {}
    mock_lsp_client.responses = {}
    mock_lsp_client.next_id = 1
end

test.describe("Hover URI Translation Tests", function()
    
    test.setup(function()
        mock_lsp_client.clear()
    end)
    
    test.teardown(function()
        mock_lsp_client.clear()
    end)
    
    test.it("should translate rsync URI to file URI in hover requests", function()
        local remote = "ianhersom@raspi0"
        local protocol = "rsync"
        
        -- Original hover request with rsync URI (from Neovim)
        local original_request = {
            id = 6,
            jsonrpc = "2.0",
            method = "textDocument/hover",
            params = {
                textDocument = {
                    uri = "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/tui/src/ui/music_player_client.rs"
                },
                position = {
                    character = 12,
                    line = 16
                }
            }
        }
        
        -- Translate the request (proxy should do this)
        local translated_request = proxy_mock.replace_uris(original_request, remote, protocol)
        
        -- Verify the URI was translated correctly
        test.assert.equals(translated_request.params.textDocument.uri, 
            "file:///home/ianhersom/repo/termusic/tui/src/ui/music_player_client.rs",
            "Request URI should be translated from rsync:// to file://")
        
        -- Verify other fields are preserved
        test.assert.equals(translated_request.method, "textDocument/hover")
        test.assert.equals(translated_request.params.position.character, 12)
        test.assert.equals(translated_request.params.position.line, 16)
    end)
    
    test.it("should translate file URI back to rsync URI in hover responses", function()
        local remote = "ianhersom@raspi0"
        local protocol = "rsync"
        
        -- Simulate rust-analyzer response with file URIs
        local rust_analyzer_response = {
            id = 6,
            jsonrpc = "2.0",
            result = {
                contents = {
                    kind = "markdown",
                    value = "```rust\nstruct MyStruct\n```\n\nDocumentation for MyStruct"
                },
                range = {
                    start = { line = 16, character = 8 },
                    ["end"] = { line = 16, character = 20 }
                }
            }
        }
        
        -- For responses that might contain URIs in various places
        local response_with_uris = {
            id = 7,
            jsonrpc = "2.0",
            result = {
                contents = {
                    kind = "markdown", 
                    value = "Documentation with link: [source](file:///home/ianhersom/repo/termusic/tui/src/ui/music_player_client.rs)"
                },
                range = {
                    start = { line = 16, character = 8 },
                    ["end"] = { line = 16, character = 20 }
                }
            }
        }
        
        -- Translate the response (proxy should do this)
        local translated_response = proxy_mock.replace_uris(response_with_uris, remote, protocol)
        
        -- Verify URIs in content are translated back
        test.assert.contains(translated_response.result.contents.value, 
            "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/tui/src/ui/music_player_client.rs",
            "Response URIs should be translated from file:// back to rsync://")
    end)
    
    test.it("should handle go-to-definition responses with file URIs", function()
        local remote = "ianhersom@raspi0"
        local protocol = "rsync"
        
        -- Simulate go-to-definition response from rust-analyzer
        local definition_response = {
            id = 8,
            jsonrpc = "2.0",
            result = {
                {
                    uri = "file:///home/ianhersom/repo/termusic/lib/src/types.rs",
                    range = {
                        start = { line = 42, character = 0 },
                        ["end"] = { line = 42, character = 15 }
                    }
                }
            }
        }
        
        -- Translate the response
        local translated_response = proxy_mock.replace_uris(definition_response, remote, protocol)
        
        -- Verify the URI was translated correctly
        test.assert.equals(translated_response.result[1].uri,
            "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/lib/src/types.rs",
            "Go-to-definition URI should be translated from file:// to rsync://")
            
        -- Verify range is preserved
        test.assert.equals(translated_response.result[1].range.start.line, 42)
    end)
    
    test.it("should handle workspace symbol responses with file URIs", function()
        local remote = "ianhersom@raspi0"
        local protocol = "rsync"
        
        -- Simulate workspace symbol response
        local symbol_response = {
            id = 9,
            jsonrpc = "2.0", 
            result = {
                {
                    name = "MyFunction",
                    kind = 12,
                    location = {
                        uri = "file:///home/ianhersom/repo/termusic/server/src/lib.rs",
                        range = {
                            start = { line = 100, character = 0 },
                            ["end"] = { line = 100, character = 20 }
                        }
                    }
                },
                {
                    name = "AnotherFunction", 
                    kind = 12,
                    location = {
                        uri = "file:///home/ianhersom/repo/termusic/client/src/main.rs",
                        range = {
                            start = { line = 50, character = 0 },
                            ["end"] = { line = 50, character = 25 }
                        }
                    }
                }
            }
        }
        
        -- Translate the response
        local translated_response = proxy_mock.replace_uris(symbol_response, remote, protocol)
        
        -- Verify all URIs were translated
        test.assert.equals(translated_response.result[1].location.uri,
            "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/server/src/lib.rs")
        test.assert.equals(translated_response.result[2].location.uri,
            "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/client/src/main.rs")
    end)
    
    test.it("should handle complex nested URI structures", function()
        local remote = "ianhersom@raspi0"
        local protocol = "rsync"
        
        -- Complex response with URIs in various nested locations
        local complex_response = {
            id = 10,
            jsonrpc = "2.0",
            result = {
                items = {
                    {
                        label = "mod utils",
                        detail = "module",
                        documentation = {
                            kind = "markdown",
                            value = "Module defined in [utils.rs](file:///home/ianhersom/repo/termusic/src/utils.rs)"
                        },
                        additionalTextEdits = {
                            {
                                range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
                                newText = "use crate::utils::*;\n"
                            }
                        }
                    }
                },
                metadata = {
                    workspaceRoot = "file:///home/ianhersom/repo/termusic"
                }
            }
        }
        
        -- Translate the response
        local translated_response = proxy_mock.replace_uris(complex_response, remote, protocol)
        
        -- Verify nested URIs are translated
        test.assert.contains(translated_response.result.items[1].documentation.value,
            "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/src/utils.rs",
            "URIs in documentation should be translated")
        test.assert.equals(translated_response.result.metadata.workspaceRoot,
            "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic",
            "Workspace root URI should be translated")
    end)
    
    test.it("should preserve non-URI strings unchanged", function()
        local remote = "ianhersom@raspi0"
        local protocol = "rsync"
        
        local response_with_mixed_content = {
            id = 11,
            jsonrpc = "2.0",
            result = {
                contents = {
                    kind = "markdown",
                    value = "This is documentation that mentions file:// but not as a URI, and talks about rsync://something else entirely. Here's a real URI: file:///home/ianhersom/repo/termusic/src/main.rs"
                }
            }
        }
        
        local translated = proxy_mock.replace_uris(response_with_mixed_content, remote, protocol)
        
        -- Should only translate the actual URI, not the text mentions
        test.assert.contains(translated.result.contents.value, "rsync://ianhersom@raspi0/home/ianhersom/repo/termusic/src/main.rs")
        test.assert.contains(translated.result.contents.value, "mentions file:// but not as a URI")
        test.assert.contains(translated.result.contents.value, "talks about rsync://something else")
    end)
end)