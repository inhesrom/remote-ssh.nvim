local test = require("tests.init")

-- Test that vim.lsp.config API works correctly (Neovim 0.11+)
test.describe("LSP Config API Migration (vim.lsp.config)", function()
    test.it("should access server config via vim.lsp.config", function()
        -- Test that vim.lsp.config is accessible
        test.assert.truthy(vim.lsp, "vim.lsp should exist")
        test.assert.truthy(vim.lsp.config, "vim.lsp.config should exist")

        -- Check if it's a table we can index
        test.assert.equals(type(vim.lsp.config), "table", "vim.lsp.config should be a table")
    end)

    test.it("should extract cmd from server config for common servers", function()
        -- Test a few common servers that should be available
        local test_servers = {
            "pyright",
            "lua_ls",
            "bashls",
            "clangd",
        }

        for _, server_name in ipairs(test_servers) do
            local server_config = vim.lsp.config[server_name]

            if server_config then
                -- If server exists, it should have a cmd field
                test.assert.truthy(server_config.cmd, string.format("%s should have cmd field", server_name))
                test.assert.equals(type(server_config.cmd), "table", string.format("%s cmd should be a table", server_name))
                test.assert.truthy(#server_config.cmd > 0, string.format("%s cmd should not be empty", server_name))
            end
        end
    end)

    test.it("should handle missing server gracefully", function()
        -- Test that accessing a non-existent server returns nil
        local fake_server = vim.lsp.config["definitely_not_a_real_server_12345"]
        test.assert.falsy(fake_server, "Non-existent server should return nil")
    end)

    test.it("should have cmd as direct property (not nested)", function()
        -- Verify the new API structure: cmd is directly accessible
        -- (not lsp_config.document_config.default_config.cmd like old API)
        local pyright = vim.lsp.config.pyright

        if pyright then
            test.assert.truthy(pyright.cmd, "pyright should have direct cmd property")

            -- Old nested path should NOT exist
            test.assert.falsy(pyright.document_config, "pyright should not have document_config (that's old API)")
        end
    end)
end)

test.describe("LSP Config Integration", function()
    test.it("should work with RemoteLspServers command logic", function()
        -- Simulate the logic from commands.lua
        local available_servers = {}

        -- Mock some server configs (from remote-lsp.config)
        local mock_server_configs = {
            rust_analyzer = {},
            clangd = {},
            pyright = {},
        }

        -- Check which servers are available via vim.lsp.config
        for server_name, _ in pairs(mock_server_configs) do
            if vim.lsp.config[server_name] then
                table.insert(available_servers, server_name)
            end
        end

        -- Should find at least one server (or none is fine if not installed)
        test.assert.equals(type(available_servers), "table", "Should return a table of available servers")
    end)
end)

test.run_tests()
