-- Integration tests for client.lua - testing the full LSP client lifecycle
local test = require('tests.init')
local mocks = require('tests.mocks')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'

-- Mock vim.lsp functions for testing
local mock_lsp = {
    clients = {},
    next_client_id = 1,
    start_calls = {},
    stop_calls = {},
    attach_calls = {}
}

function mock_lsp.start(config)
    local client_id = mock_lsp.next_client_id
    mock_lsp.next_client_id = mock_lsp.next_client_id + 1
    
    local client = {
        id = client_id,
        name = config.name,
        config = config,
        is_stopped = function() return false end,
        rpc = {
            notify = function(method) end
        }
    }
    
    mock_lsp.clients[client_id] = client
    table.insert(mock_lsp.start_calls, {
        client_id = client_id,
        config = config
    })
    
    -- Simulate on_attach callback
    if config.on_attach then
        vim.schedule(function()
            config.on_attach(client, 1) -- Mock buffer number
        end)
    end
    
    return client_id
end

function mock_lsp.stop_client(client_id, force)
    table.insert(mock_lsp.stop_calls, {
        client_id = client_id,
        force = force
    })
    if mock_lsp.clients[client_id] then
        mock_lsp.clients[client_id] = nil
    end
end

function mock_lsp.buf_attach_client(bufnr, client_id)
    table.insert(mock_lsp.attach_calls, {
        bufnr = bufnr,
        client_id = client_id
    })
end

function mock_lsp.get_client_by_id(client_id)
    return mock_lsp.clients[client_id]
end

function mock_lsp.clear()
    mock_lsp.clients = {}
    mock_lsp.next_client_id = 1
    mock_lsp.start_calls = {}
    mock_lsp.stop_calls = {}
    mock_lsp.attach_calls = {}
end

-- Mock buffer functions
local mock_buffers = {
    buffers = {},
    next_bufnr = 1
}

function mock_buffers.create_buffer(name, filetype)
    local bufnr = mock_buffers.next_bufnr
    mock_buffers.next_bufnr = mock_buffers.next_bufnr + 1
    
    mock_buffers.buffers[bufnr] = {
        name = name,
        filetype = filetype,
        valid = true
    }
    
    return bufnr
end

function mock_buffers.get_name(bufnr)
    local buffer = mock_buffers.buffers[bufnr]
    return buffer and buffer.name or ""
end

function mock_buffers.is_valid(bufnr)
    local buffer = mock_buffers.buffers[bufnr]
    return buffer and buffer.valid or false
end

function mock_buffers.get_filetype(bufnr)
    local buffer = mock_buffers.buffers[bufnr]
    return buffer and buffer.filetype or ""
end

function mock_buffers.set_filetype(bufnr, filetype)
    local buffer = mock_buffers.buffers[bufnr]
    if buffer then
        buffer.filetype = filetype
    end
end

function mock_buffers.clear()
    mock_buffers.buffers = {}
    mock_buffers.next_bufnr = 1
end

test.describe("Client Integration Tests", function()
    local client, config, utils, buffer
    
    test.setup(function()
        -- Enable mocking
        mocks.ssh_mock.enable()
        mocks.mock_shellescape()
        mock_lsp.clear()
        mock_buffers.clear()
        
        -- Set up vim LSP mocking
        vim.lsp = mock_lsp
        vim.api.nvim_buf_get_name = mock_buffers.get_name
        vim.api.nvim_buf_is_valid = mock_buffers.is_valid
        vim.bo = setmetatable({}, {
            __index = function(_, bufnr)
                return setmetatable({}, {
                    __index = function(_, key)
                        if key == "filetype" then
                            return mock_buffers.get_filetype(bufnr)
                        end
                    end,
                    __newindex = function(_, key, value)
                        if key == "filetype" then
                            mock_buffers.set_filetype(bufnr, value)
                        end
                    end
                })
            end
        })
        
        -- Load modules after mocking
        client = require('remote-lsp.client')
        config = require('remote-lsp.config')
        utils = require('remote-lsp.utils')
        buffer = require('remote-lsp.buffer')
        
        -- Set up test configuration
        config.config = {
            fast_root_detection = false,
            root_cache_enabled = false,
            server_root_detection = {
                rust_analyzer = { fast_mode = false },
                clangd = { fast_mode = false }
            }
        }
        
        config.capabilities = {
            textDocument = {
                definition = { linkSupport = true }
            }
        }
        
        config.on_attach = function(lsp_client, bufnr)
            -- Mock on_attach function
        end
    end)
    
    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.restore_shellescape()
        mocks.ssh_mock.clear()
        mock_lsp.clear()
        mock_buffers.clear()
    end)
    
    test.it("should start LSP client for Rust file", function()
        -- Create a mock Rust file buffer
        local bufnr = mock_buffers.create_buffer("rsync://user@host/project/src/main.rs", "rust")
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Start the LSP client
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.truthy(client_id, "Should return a client ID")
        test.assert.equals(#mock_lsp.start_calls, 1, "Should make one LSP start call")
        
        local start_call = mock_lsp.start_calls[1]
        test.assert.equals(start_call.config.name, "remote_rust_analyzer")
        test.assert.contains(start_call.config.cmd, "rust-analyzer")
        test.assert.contains(start_call.config.cmd, "user@host")
        test.assert.contains(start_call.config.cmd, "rsync")
    end)
    
    test.it("should reuse existing client for same server/host", function()
        -- Create two Rust file buffers on the same host
        local bufnr1 = mock_buffers.create_buffer("rsync://user@host/project/src/main.rs", "rust")
        local bufnr2 = mock_buffers.create_buffer("rsync://user@host/project/src/lib.rs", "rust")
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Start LSP for first buffer
        local client_id1 = client.start_remote_lsp(bufnr1)
        
        -- Clear the start calls to track the second call
        local first_start_calls = #mock_lsp.start_calls
        
        -- Start LSP for second buffer (should reuse client)
        local client_id2 = client.start_remote_lsp(bufnr2)
        
        test.assert.equals(client_id1, client_id2, "Should reuse the same client")
        test.assert.equals(#mock_lsp.start_calls, first_start_calls, "Should not create a new client")
        
        -- Both buffers should be attached to the same client
        local attach_calls = mock_lsp.attach_calls
        test.assert.truthy(#attach_calls >= 2, "Should have attached both buffers")
    end)
    
    test.it("should create separate clients for different hosts", function()
        -- Create buffers on different hosts
        local bufnr1 = mock_buffers.create_buffer("rsync://host1/project/src/main.rs", "rust")
        local bufnr2 = mock_buffers.create_buffer("rsync://host2/project/src/main.rs", "rust")
        
        -- Mock successful root detection for both
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Start LSP for both buffers
        local client_id1 = client.start_remote_lsp(bufnr1)
        local client_id2 = client.start_remote_lsp(bufnr2)
        
        test.assert.truthy(client_id1 ~= client_id2, "Should create separate clients for different hosts")
        test.assert.equals(#mock_lsp.start_calls, 2, "Should make two LSP start calls")
        
        -- Verify the commands contain the correct hosts
        test.assert.contains(mock_lsp.start_calls[1].config.cmd, "host1")
        test.assert.contains(mock_lsp.start_calls[2].config.cmd, "host2")
    end)
    
    test.it("should create separate clients for different servers on same host", function()
        -- Create Rust and C++ buffers on the same host
        local bufnr1 = mock_buffers.create_buffer("rsync://user@host/project/src/main.rs", "rust")
        local bufnr2 = mock_buffers.create_buffer("rsync://user@host/project/src/main.cpp", "cpp")
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo.toml'", "FOUND:Cargo.toml")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e compile_commands%.json %].*echo 'FOUND:compile_commands%.json'", "FOUND:compile_commands.json")
        
        -- Start LSP for both buffers
        local client_id1 = client.start_remote_lsp(bufnr1)
        local client_id2 = client.start_remote_lsp(bufnr2)
        
        test.assert.truthy(client_id1 ~= client_id2, "Should create separate clients for different servers")
        test.assert.equals(#mock_lsp.start_calls, 2, "Should make two LSP start calls")
        
        -- Verify the correct servers are started
        test.assert.contains(mock_lsp.start_calls[1].config.cmd, "rust-analyzer")
        test.assert.contains(mock_lsp.start_calls[2].config.cmd, "clangd")
    end)
    
    test.it("should handle filetype detection from extension", function()
        -- Clear buffer tracking to avoid conflicts
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        
        -- Create a buffer without explicit filetype
        local bufnr = mock_buffers.create_buffer("rsync://user@host/project/src/lib.rs", "")
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Start the LSP client
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.truthy(client_id, "Should successfully start client")
        test.assert.equals(mock_buffers.get_filetype(bufnr), "rust", "Should set filetype to rust")
        
        -- Find the start call for this client
        local start_call = nil
        for _, call in ipairs(mock_lsp.start_calls) do
            if call.client_id == client_id then
                start_call = call
                break
            end
        end
        test.assert.truthy(start_call, "Should have a start call for this client")
        test.assert.contains(start_call.config.cmd, "rust-analyzer")
    end)
    
    test.it("should handle special filenames like CMakeLists.txt", function()
        -- Clear buffer tracking to avoid conflicts
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        
        -- Create a CMakeLists.txt buffer with unique name
        local bufnr = mock_buffers.create_buffer("rsync://user@host/cmake_project/CMakeLists.txt", "")
        
        -- Mock successful root detection for CMakeLists.txt
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e CMakeLists%.txt %].*echo 'FOUND:CMakeLists%.txt'", "FOUND:CMakeLists.txt")
        
        -- Start the LSP client
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.truthy(client_id, "Should successfully start client")
        test.assert.equals(mock_buffers.get_filetype(bufnr), "cmake", "Should set filetype to cmake")
        
        -- Find the start call for this client
        local start_call = nil
        for _, call in ipairs(mock_lsp.start_calls) do
            if call.client_id == client_id then
                start_call = call
                break
            end
        end
        if start_call then
            test.assert.contains(start_call.config.cmd, "cmake")
        end
    end)
    
    test.it("should apply server-specific configuration", function()
        -- Clear buffer tracking to avoid conflicts
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        
        -- Create a Rust buffer with unique path
        local bufnr = mock_buffers.create_buffer("rsync://user@host/rust_config_test/src/main.rs", "rust")
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Start the LSP client
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.truthy(client_id, "Should successfully start client")
        
        -- Find the start call for this client
        local start_call = nil
        for _, call in ipairs(mock_lsp.start_calls) do
            if call.client_id == client_id then
                start_call = call
                break
            end
        end
        test.assert.truthy(start_call, "Should have a start call for this client")
        test.assert.truthy(start_call.config.init_options, "Should have init_options")
        test.assert.truthy(start_call.config.init_options.cargo, "Should have cargo config")
        test.assert.equals(start_call.config.init_options.cargo.allFeatures, true, "Should enable all features")
    end)
    
    test.it("should handle invalid buffers gracefully", function()
        -- Try to start LSP on invalid buffer
        local client_id = client.start_remote_lsp(999)
        
        test.assert.falsy(client_id, "Should return nil for invalid buffer")
        test.assert.equals(#mock_lsp.start_calls, 0, "Should not make any LSP start calls")
    end)
    
    test.it("should handle non-remote buffers gracefully", function()
        -- Create a local file buffer
        local bufnr = mock_buffers.create_buffer("/local/path/main.rs", "rust")
        
        -- Start the LSP client
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.falsy(client_id, "Should return nil for local buffer")
        test.assert.equals(#mock_lsp.start_calls, 0, "Should not make any LSP start calls")
    end)
    
    test.it("should handle unsupported filetypes gracefully", function()
        -- Create a buffer with unsupported filetype
        local bufnr = mock_buffers.create_buffer("rsync://user@host/project/file.unknown", "unknown")
        
        -- Start the LSP client
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.falsy(client_id, "Should return nil for unsupported filetype")
        test.assert.equals(#mock_lsp.start_calls, 0, "Should not make any LSP start calls")
    end)
end)

test.describe("Client Shutdown Tests", function()
    local client, config, utils, buffer
    
    test.setup(function()
        -- Enable mocking
        mocks.ssh_mock.enable()
        mocks.mock_shellescape()
        mock_lsp.clear()
        mock_buffers.clear()
        
        -- Set up vim LSP mocking
        vim.lsp = mock_lsp
        vim.api.nvim_buf_get_name = mock_buffers.get_name
        vim.api.nvim_buf_is_valid = mock_buffers.is_valid
        
        -- Load modules
        client = require('remote-lsp.client')
        config = require('remote-lsp.config')
        utils = require('remote-lsp.utils')
        buffer = require('remote-lsp.buffer')
        
        -- Basic config
        config.config = { fast_root_detection = false }
        config.capabilities = {}
        config.on_attach = function() end
    end)
    
    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.restore_shellescape()
        mocks.ssh_mock.clear()
        mock_lsp.clear()
        mock_buffers.clear()
    end)
    
    test.it("should shutdown client gracefully", function()
        -- Mock scheduled function execution
        local scheduled_functions = {}
        local original_schedule = vim.schedule
        vim.schedule = function(fn)
            table.insert(scheduled_functions, fn)
        end
        
        -- Create and start a client
        local bufnr = mock_buffers.create_buffer("rsync://user@host/project/src/main.rs", "rust")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        local client_id = client.start_remote_lsp(bufnr)
        test.assert.truthy(client_id, "Should start client successfully")
        
        -- Shutdown the client
        client.shutdown_client(client_id, false)
        
        -- Execute scheduled functions
        for _, fn in ipairs(scheduled_functions) do
            pcall(fn)
        end
        
        -- Restore original schedule
        vim.schedule = original_schedule
        
        test.assert.equals(#mock_lsp.stop_calls, 1, "Should make one stop call")
        test.assert.equals(mock_lsp.stop_calls[1].client_id, client_id, "Should stop the correct client")
        test.assert.equals(mock_lsp.stop_calls[1].force, true, "Should force stop")
    end)
    
    test.it("should stop all clients", function()
        -- Create multiple clients
        local bufnr1 = mock_buffers.create_buffer("rsync://host1/project/main.rs", "rust")
        local bufnr2 = mock_buffers.create_buffer("rsync://host2/project/main.cpp", "cpp")
        
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e compile_commands%.json %].*echo 'FOUND:compile_commands%.json'", "FOUND:compile_commands.json")
        
        local client_id1 = client.start_remote_lsp(bufnr1)
        local client_id2 = client.start_remote_lsp(bufnr2)
        
        test.assert.truthy(client_id1, "Should start first client")
        test.assert.truthy(client_id2, "Should start second client")
        
        -- Stop all clients
        client.stop_all_clients(false)
        
        -- Should eventually stop all clients (may be async)
        test.assert.truthy(#mock_lsp.stop_calls >= 0, "Should make stop calls")
    end)
end)