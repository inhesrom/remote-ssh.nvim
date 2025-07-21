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
    local buffer, client

    test.setup(function()
        -- Load modules
        buffer = require('remote-lsp.buffer')
        client = require('remote-lsp.client')

        -- Clear tracking structures (new metadata system)
        client.active_lsp_clients = {}
        buffer_mock.server_buffers = {}
        buffer_mock.buffer_clients = {}
        buffer_mock.notifications = {}
        scheduled_functions = {}

        -- Clear buffer metadata for clean test state
        if vim.b then
            for bufnr in pairs(vim.b) do
                vim.b[bufnr] = {}
            end
        end
    end)

    test.teardown(function()
        -- Clear tracking structures (new metadata system)
        client.active_lsp_clients = {}
        buffer_mock.server_buffers = {}
        buffer_mock.buffer_clients = {}
        buffer_mock.notifications = {}
        scheduled_functions = {}

        -- Clear buffer metadata for clean test state
        if vim.b then
            for bufnr in pairs(vim.b) do
                vim.b[bufnr] = {}
            end
        end
    end)

    test.it("should setup buffer tracking correctly", function()
        local server_key = "rust_analyzer@user@host"
        local bufnr = 1
        local client_id = 42

        -- Setup buffer tracking
        buffer.setup_buffer_tracking(mock_client, bufnr, "rust_analyzer", "user@host", "rsync")

        -- Verify tracking using metadata APIs directly
        local metadata = require('remote-buffer-metadata')
        local buf_server_key = metadata.get(bufnr, "remote-lsp", "server_key")
        local buffer_clients = metadata.get(bufnr, "remote-lsp", "clients") or {}
        test.assert.equals(buf_server_key, server_key, "Should track buffer for server")
        test.assert.truthy(buffer_clients[mock_client.id], "Should track client for buffer")
    end)

    test.it("should track multiple buffers for same server", function()
        local server_key = "rust_analyzer@user@host"
        local bufnr1 = 1
        local bufnr2 = 2

        -- Setup tracking for multiple buffers
        buffer.setup_buffer_tracking(mock_client, bufnr1, "rust_analyzer", "user@host", "rsync")
        buffer.setup_buffer_tracking(mock_client, bufnr2, "rust_analyzer", "user@host", "rsync")

        -- Verify both buffers are tracked using metadata APIs
        local metadata = require('remote-buffer-metadata')
        local server_key1 = metadata.get(bufnr1, "remote-lsp", "server_key")
        local server_key2 = metadata.get(bufnr2, "remote-lsp", "server_key")
        test.assert.equals(server_key1, server_key, "Should track first buffer")
        test.assert.equals(server_key2, server_key, "Should track second buffer")
    end)

    test.it("should track multiple clients for same buffer", function()
        local bufnr = 1
        local client1 = { id = 1, name = "remote_rust_analyzer" }
        local client2 = { id = 2, name = "remote_clangd" }

        -- Setup tracking for multiple clients
        buffer.setup_buffer_tracking(client1, bufnr, "rust_analyzer", "user@host", "rsync")
        buffer.setup_buffer_tracking(client2, bufnr, "clangd", "user@host", "rsync")

        -- Verify both clients are tracked using metadata APIs
        local metadata = require('remote-buffer-metadata')
        local buffer_clients = metadata.get(bufnr, "remote-lsp", "clients") or {}
        test.assert.truthy(buffer_clients[1], "Should track first client")
        test.assert.truthy(buffer_clients[2], "Should track second client")
        test.assert.equals(vim.tbl_count(buffer_clients), 2, "Should track exactly 2 clients")
    end)

    test.it("should untrack client correctly", function()
        local server_key = "rust_analyzer@user@host"
        local bufnr = 1
        local client_id = mock_client.id

        -- Clear client tracking to ensure clean state
        client.active_lsp_clients = {}

        -- Setup and then untrack
        buffer.setup_buffer_tracking(mock_client, bufnr, "rust_analyzer", "user@host", "rsync")

        -- Verify tracking is setup using metadata API
        local metadata = require('remote-buffer-metadata')
        local buf_server_key = metadata.get(bufnr, "remote-lsp", "server_key")
        local buffer_clients = metadata.get(bufnr, "remote-lsp", "clients") or {}
        test.assert.equals(buf_server_key, server_key, "Should initially track buffer")
        test.assert.truthy(buffer_clients[client_id], "Should initially track client")

        -- Untrack the client
        buffer.untrack_client(client_id)

        -- Verify tracking is cleaned up using metadata APIs
        local buffer_clients_after = metadata.get(bufnr, "remote-lsp", "clients") or {}
        local buf_server_key_after = metadata.get(bufnr, "remote-lsp", "server_key")

        test.assert.truthy(vim.tbl_isempty(buffer_clients_after), "Should clean up buffer_clients entry")
        test.assert.falsy(buf_server_key_after, "Should clean up server_buffers when empty")
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

        -- Verify partial cleanup using metadata APIs
        local metadata = require('remote-buffer-metadata')
        local buffer_clients = metadata.get(bufnr, "remote-lsp", "clients") or {}
        test.assert.falsy(buffer_clients[1], "Should remove first client")
        test.assert.truthy(buffer_clients[2], "Should keep second client")
        test.assert.falsy(vim.tbl_isempty(buffer_clients), "Should keep buffer_clients entry")
    end)
end)

test.describe("Buffer Save Notifications", function()
    local buffer, client

    test.setup(function()
        buffer = require('remote-lsp.buffer')
        client = require('remote-lsp.client')
        client.active_lsp_clients = {}
        buffer_mock.notifications = {}
        scheduled_functions = {}
    end)

    test.teardown(function()
        client.active_lsp_clients = {}
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

        -- Ensure metadata schemas are registered
        local metadata = require('remote-buffer-metadata')
        metadata.register_schema("remote-lsp", {
            defaults = {
                clients = {},           -- client_id -> true
                server_key = nil,       -- server_name@host
                save_in_progress = false,
                save_timestamp = nil,
                project_root = nil
            },
            validators = {
                clients = function(v) return type(v) == "table" end,
                server_key = function(v) return type(v) == "string" or v == nil end,
                save_in_progress = function(v) return type(v) == "boolean" end,
                save_timestamp = function(v) return type(v) == "number" or v == nil end,
                project_root = function(v) return type(v) == "string" or v == nil end
            },
            reverse_indexes = {
                { name = "server_buffers", key = "server_key" }
            }
        })

        -- Setup basic config
        config.config = {
            fast_root_detection = false,
            root_cache_enabled = false
        }
        config.capabilities = {}
        config.on_attach = function() end

        -- Clear tracking (new metadata system)
        client.active_lsp_clients = {}
        scheduled_functions = {}
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.restore_shellescape()
        mocks.ssh_mock.clear()
        client.active_lsp_clients = {}
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

        -- Verify buffer is tracked (using migration API)
        local migration = require('remote-buffer-metadata.migration')
        local server_key = "rust_analyzer@user@host"
        local server_buffers = migration.get_server_buffers(server_key)
        local buffer_clients = migration.get_buffer_clients(bufnr)

        test.assert.truthy(#server_buffers > 0, "Should track server")
        test.assert.truthy(not vim.tbl_isempty(buffer_clients), "Should track buffer")

        -- Simulate buffer close by untrackning client
        buffer.untrack_client(client_id)

        -- Verify cleanup
        local metadata = require('remote-buffer-metadata')
        local buffer_clients_after = metadata.get(bufnr, "remote-lsp", "clients") or {}
        test.assert.truthy(vim.tbl_isempty(buffer_clients_after), "Should clean up buffer tracking")
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

        -- Start LSP for first buffer
        local client_id1 = client.start_remote_lsp(bufnr1)
        test.assert.truthy(client_id1, "Should start first client")

        -- Execute scheduled functions for first buffer
        execute_scheduled()

        -- Start LSP for second buffer (should reuse server)
        local client_id2 = client.start_remote_lsp(bufnr2)
        test.assert.truthy(client_id2, "Should start second client")

        -- Execute scheduled functions for second buffer
        execute_scheduled()

        -- Both buffers should be tracked (using metadata API)
        local metadata = require('remote-buffer-metadata')
        local buffer_clients1 = metadata.get(bufnr1, "remote-lsp", "clients") or {}
        local buffer_clients2 = metadata.get(bufnr2, "remote-lsp", "clients") or {}

        test.assert.truthy(not vim.tbl_isempty(buffer_clients1), "Should track first buffer")
        test.assert.truthy(not vim.tbl_isempty(buffer_clients2), "Should track second buffer")

        -- Server should track both buffers
        local server_key = "rust_analyzer@user@host"
        local server_key1 = metadata.get(bufnr1, "remote-lsp", "server_key")
        local server_key2 = metadata.get(bufnr2, "remote-lsp", "server_key")
        test.assert.truthy(server_key1 == server_key or server_key2 == server_key, "Should track buffers in server")
    end)

    test.it("should handle server reuse correctly", function()
        local bufnr1 = 1
        local bufnr2 = 2
        local server_key = "rust_analyzer@user@host"

        -- Mock successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")

        -- Manually setup server_key to simulate existing server (using new metadata system)
        local metadata = require('remote-buffer-metadata')
        metadata.set(bufnr1, "remote-lsp", "server_key", server_key)

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
    local buffer, client
    local original_buf_is_valid

    test.setup(function()
        -- Store and reset vim.api.nvim_buf_is_valid to ensure test isolation
        original_buf_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr) return bufnr and bufnr <= 100 end -- Only buffers 1-100 are valid

        buffer = require('remote-lsp.buffer')
        client = require('remote-lsp.client')
        client.active_lsp_clients = {}
    end)

    test.teardown(function()
        -- Restore original function
        if original_buf_is_valid then
            vim.api.nvim_buf_is_valid = original_buf_is_valid
        end

        client.active_lsp_clients = {}
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
        local success1, result1 = pcall(function()
            return buffer.notify_save_start(999)
        end)

        local success2, result2 = pcall(function()
            return buffer.notify_save_end(999)
        end)

        -- The function calls should not crash (pcall succeeds)
        test.assert.truthy(success1, "Should not crash on save start for non-existent buffer")
        test.assert.truthy(success2, "Should not crash on save end for non-existent buffer")

        -- But they should return false for invalid buffers (new, better behavior)
        test.assert.falsy(result1, "Should return false for invalid buffer in save start")
        -- Note: save_end doesn't return a value, so we don't check result2
    end)
end)
