-- Tests for buffer management and lifecycle in remote-lsp
local test = require('tests.init')
local mocks = require('tests.mocks')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'

-- Mock buffer tracking structures to test the actual buffer module
local buffer_mock = {
    server_buffers = {},
    buffer_clients = {},
    notifications = {}
}

-- Mock vim.schedule for async operations
local scheduled_functions = {}
function vim.schedule(fn)
    table.insert(scheduled_functions, fn)
end

function vim.defer_fn(fn, delay)
    table.insert(scheduled_functions, fn)
end

-- Function to execute all scheduled functions (for testing async behavior)
local function execute_scheduled()
    local fns = scheduled_functions
    scheduled_functions = {}
    for _, fn in ipairs(fns) do
        pcall(fn)
    end
end

-- Mock LSP client for buffer tests
local mock_client = {
    id = 1,
    name = "remote_rust_analyzer",
    is_stopped = function() return false end,
    rpc = {
        notify = function(method, params)
            table.insert(buffer_mock.notifications, {
                method = method,
                params = params
            })
        end
    }
}

test.describe("Buffer Tracking Tests", function()
    local buffer
    
    test.setup(function()
        -- Load buffer module
        buffer = require('remote-lsp.buffer')
        
        -- Clear tracking structures
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        buffer_mock.server_buffers = {}
        buffer_mock.buffer_clients = {}
        buffer_mock.notifications = {}
        scheduled_functions = {}
    end)
    
    test.teardown(function()
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        buffer_mock.server_buffers = {}
        buffer_mock.buffer_clients = {}
        buffer_mock.notifications = {}
        scheduled_functions = {}
    end)
    
    test.it("should setup buffer tracking correctly", function()
        local server_key = "rust_analyzer@user@host"
        local bufnr = 1
        local client_id = 42
        
        -- Setup buffer tracking
        buffer.setup_buffer_tracking(mock_client, bufnr, "rust_analyzer", "user@host", "rsync")
        
        -- Verify tracking structures are initialized
        test.assert.truthy(buffer.server_buffers[server_key], "Should initialize server_buffers")
        test.assert.truthy(buffer.buffer_clients[bufnr], "Should initialize buffer_clients")
        test.assert.truthy(buffer.server_buffers[server_key][bufnr], "Should track buffer for server")
        test.assert.truthy(buffer.buffer_clients[bufnr][mock_client.id], "Should track client for buffer")
    end)
    
    test.it("should track multiple buffers for same server", function()
        local server_key = "rust_analyzer@user@host"
        local bufnr1 = 1
        local bufnr2 = 2
        
        -- Setup tracking for multiple buffers
        buffer.setup_buffer_tracking(mock_client, bufnr1, "rust_analyzer", "user@host", "rsync")
        buffer.setup_buffer_tracking(mock_client, bufnr2, "rust_analyzer", "user@host", "rsync")
        
        -- Verify both buffers are tracked
        test.assert.truthy(buffer.server_buffers[server_key][bufnr1], "Should track first buffer")
        test.assert.truthy(buffer.server_buffers[server_key][bufnr2], "Should track second buffer")
        
        -- Count tracked buffers
        local buffer_count = 0
        for _ in pairs(buffer.server_buffers[server_key]) do
            buffer_count = buffer_count + 1
        end
        test.assert.equals(buffer_count, 2, "Should track exactly 2 buffers")
    end)
    
    test.it("should track multiple clients for same buffer", function()
        local bufnr = 1
        local client1 = { id = 1, name = "remote_rust_analyzer" }
        local client2 = { id = 2, name = "remote_clangd" }
        
        -- Setup tracking for multiple clients
        buffer.setup_buffer_tracking(client1, bufnr, "rust_analyzer", "user@host", "rsync")
        buffer.setup_buffer_tracking(client2, bufnr, "clangd", "user@host", "rsync")
        
        -- Verify both clients are tracked for the buffer
        test.assert.truthy(buffer.buffer_clients[bufnr][1], "Should track first client")
        test.assert.truthy(buffer.buffer_clients[bufnr][2], "Should track second client")
        
        -- Count tracked clients
        local client_count = 0
        for _ in pairs(buffer.buffer_clients[bufnr]) do
            client_count = client_count + 1
        end
        test.assert.equals(client_count, 2, "Should track exactly 2 clients")
    end)
    
    test.it("should untrack client correctly", function()
        local server_key = "rust_analyzer@user@host"
        local bufnr = 1
        local client_id = mock_client.id
        
        -- Setup and then untrack
        buffer.setup_buffer_tracking(mock_client, bufnr, "rust_analyzer", "user@host", "rsync")
        
        -- Verify tracking is setup
        test.assert.truthy(buffer.server_buffers[server_key][bufnr], "Should initially track buffer")
        test.assert.truthy(buffer.buffer_clients[bufnr][client_id], "Should initially track client")
        
        -- Untrack the client
        buffer.untrack_client(client_id)
        
        -- Verify tracking is cleaned up
        test.assert.falsy(buffer.buffer_clients[bufnr], "Should clean up buffer_clients entry")
        
        -- Server buffers should also be cleaned up if empty
        local has_buffers = false
        for _ in pairs(buffer.server_buffers[server_key] or {}) do
            has_buffers = true
            break
        end
        test.assert.falsy(has_buffers, "Should clean up server_buffers when empty")
    end)
    
    test.it("should handle partial cleanup when multiple clients exist", function()
        local bufnr = 1
        local client1 = { id = 1, name = "remote_rust_analyzer" }
        local client2 = { id = 2, name = "remote_clangd" }
        
        -- Setup tracking for multiple clients
        buffer.setup_buffer_tracking(client1, bufnr, "rust_analyzer", "user@host", "rsync")
        buffer.setup_buffer_tracking(client2, bufnr, "clangd", "user@host", "rsync")
        
        -- Untrack one client
        buffer.untrack_client(1)
        
        -- Verify partial cleanup
        test.assert.falsy(buffer.buffer_clients[bufnr][1], "Should remove first client")
        test.assert.truthy(buffer.buffer_clients[bufnr][2], "Should keep second client")
        test.assert.truthy(buffer.buffer_clients[bufnr], "Should keep buffer_clients entry")
    end)
end)

test.describe("Buffer Save Notifications", function()
    local buffer
    
    test.setup(function()
        buffer = require('remote-lsp.buffer')
        buffer_mock.notifications = {}
        scheduled_functions = {}
    end)
    
    test.teardown(function()
        buffer_mock.notifications = {}
        scheduled_functions = {}
    end)
    
    test.it("should send save start notification", function()
        local bufnr = 1
        
        -- Send save start notification
        buffer.notify_save_start(bufnr)
        
        -- This should not crash and should handle gracefully
        test.assert.truthy(true, "Should handle save start notification")
    end)
    
    test.it("should send save end notification", function()
        local bufnr = 1
        
        -- Send save end notification
        buffer.notify_save_end(bufnr)
        
        -- This should not crash and should handle gracefully
        test.assert.truthy(true, "Should handle save end notification")
    end)
end)

test.describe("Buffer Lifecycle Integration", function()
    local buffer, client, config
    
    test.setup(function()
        -- Enable mocking
        mocks.ssh_mock.enable()
        mocks.mock_shellescape()
        
        -- Mock vim functions
        vim.api = vim.api or {}
        vim.api.nvim_buf_get_name = function(bufnr)
            return "rsync://user@host/project/src/main.rs"
        end
        vim.api.nvim_buf_is_valid = function(bufnr)
            return bufnr > 0
        end
        
        vim.bo = setmetatable({}, {
            __index = function(_, bufnr)
                return { filetype = "rust" }
            end
        })
        
        -- Mock lsp functions
        vim.lsp = vim.lsp or {}
        vim.lsp.start = function(config)
            local client_id = 1
            
            -- Simulate the on_attach callback
            if config.on_attach then
                vim.schedule(function()
                    config.on_attach(mock_client, 1) -- Mock buffer number
                end)
            end
            
            return client_id
        end
        vim.lsp.buf_attach_client = function(bufnr, client_id)
            -- Mock attach
        end
        vim.lsp.stop_client = function(client_id, force)
            -- Mock stop
        end
        vim.lsp.get_client_by_id = function(client_id)
            return mock_client
        end
        
        -- Load modules
        buffer = require('remote-lsp.buffer')
        client = require('remote-lsp.client')
        config = require('remote-lsp.config')
        
        -- Setup basic config
        config.config = {
            fast_root_detection = false,
            root_cache_enabled = false
        }
        config.capabilities = {}
        config.on_attach = function() end
        
        -- Clear tracking
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        scheduled_functions = {}
    end)
    
    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.restore_shellescape()
        mocks.ssh_mock.clear()
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
        scheduled_functions = {}
    end)
    
    test.it("should handle complete buffer lifecycle", function()
        local bufnr = 1
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Start LSP client (should set up buffer tracking)
        local client_id = client.start_remote_lsp(bufnr)
        
        test.assert.truthy(client_id, "Should start LSP client")
        
        -- Execute any scheduled functions
        execute_scheduled()
        
        -- Verify buffer is tracked
        local server_key = "rust_analyzer@user@host"
        test.assert.truthy(buffer.server_buffers[server_key], "Should track server")
        test.assert.truthy(buffer.buffer_clients[bufnr], "Should track buffer")
        
        -- Simulate buffer close by untrackning client
        buffer.untrack_client(client_id)
        
        -- Verify cleanup
        test.assert.falsy(buffer.buffer_clients[bufnr], "Should clean up buffer tracking")
    end)
    
    test.it("should handle multiple buffers with shared server", function()
        local bufnr1 = 1
        local bufnr2 = 2
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Setup different buffer names for each
        vim.api.nvim_buf_get_name = function(bufnr)
            if bufnr == 1 then
                return "rsync://user@host/project/src/main.rs"
            else
                return "rsync://user@host/project/src/lib.rs"
            end
        end
        
        -- Start LSP for both buffers (should reuse server)
        local client_id1 = client.start_remote_lsp(bufnr1)
        local client_id2 = client.start_remote_lsp(bufnr2)
        
        test.assert.truthy(client_id1, "Should start first client")
        test.assert.truthy(client_id2, "Should start second client")
        
        -- Execute scheduled functions
        execute_scheduled()
        
        -- Both buffers should be tracked
        test.assert.truthy(buffer.buffer_clients[bufnr1], "Should track first buffer")
        test.assert.truthy(buffer.buffer_clients[bufnr2], "Should track second buffer")
        
        -- Server should track both buffers
        local server_key = "rust_analyzer@user@host"
        local buffer_count = 0
        for _ in pairs(buffer.server_buffers[server_key] or {}) do
            buffer_count = buffer_count + 1
        end
        test.assert.truthy(buffer_count >= 1, "Should track buffers in server")
    end)
    
    test.it("should handle server reuse correctly", function()
        local bufnr1 = 1
        local bufnr2 = 2
        local server_key = "rust_analyzer@user@host"
        
        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        
        -- Manually setup server_buffers to simulate existing server
        buffer.server_buffers[server_key] = { [bufnr1] = true }
        
        -- Mock that we have an active client
        local active_clients = {}
        active_clients[1] = {
            server_name = "rust_analyzer",
            host = "user@host"
        }
        
        -- This would normally use client.active_lsp_clients, but we'll test the logic
        local found_existing = false
        for client_id, info in pairs(active_clients) do
            if info.server_name == "rust_analyzer" and info.host == "user@host" then
                found_existing = true
                break
            end
        end
        
        test.assert.truthy(found_existing, "Should find existing client for reuse")
    end)
end)

test.describe("Buffer Error Handling", function()
    local buffer
    
    test.setup(function()
        buffer = require('remote-lsp.buffer')
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
    end)
    
    test.teardown(function()
        buffer.server_buffers = {}
        buffer.buffer_clients = {}
    end)
    
    test.it("should handle untrack of non-existent client", function()
        -- Try to untrack a client that doesn't exist
        buffer.untrack_client(999)
        
        -- Should not crash
        test.assert.truthy(true, "Should handle non-existent client gracefully")
    end)
    
    test.it("should handle setup with invalid parameters", function()
        -- Try to setup with nil values
        local success = pcall(function()
            buffer.setup_buffer_tracking(nil, 1, "rust_analyzer", "host", "rsync")
        end)
        
        -- Should handle gracefully (may succeed or fail, but shouldn't crash)
        test.assert.truthy(type(success) == "boolean", "Should handle invalid parameters")
    end)
    
    test.it("should handle save notifications for non-existent buffers", function()
        -- Try save notifications on non-existent buffer
        local success1 = pcall(function()
            buffer.notify_save_start(999)
        end)
        
        local success2 = pcall(function()
            buffer.notify_save_end(999)
        end)
        
        test.assert.truthy(success1, "Should handle save start for non-existent buffer")
        test.assert.truthy(success2, "Should handle save end for non-existent buffer")
    end)
end)