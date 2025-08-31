-- Test for autosave configuration functionality
local test = require("tests.init")

-- Add the plugin to path for testing
package.path = package.path .. ";lua/?.lua"

test.describe("Autosave Configuration", function()
    test.it("should have default autosave configuration enabled", function()
        local config = require("async-remote-write.config")

        -- Test default configuration
        test.assert.equals(config.config.autosave, true, "Default autosave should be enabled")
        test.assert.equals(config.config.save_debounce_ms, 3000, "Default debounce should be 3000ms")
    end)

    test.it("should allow configuring autosave to false", function()
        local config = require("async-remote-write.config")

        -- Configure with autosave disabled
        config.configure({ autosave = false })

        test.assert.equals(config.config.autosave, false, "Autosave should be disabled after configuration")
    end)

    test.it("should allow configuring autosave to true", function()
        local config = require("async-remote-write.config")

        -- Configure with autosave enabled
        config.configure({ autosave = true })

        test.assert.equals(config.config.autosave, true, "Autosave should be enabled after configuration")
    end)

    test.it("should not change autosave when configured with nil", function()
        local config = require("async-remote-write.config")

        -- Set a known state first
        config.configure({ autosave = false })
        local initial_state = config.config.autosave

        -- Configure with nil (should not change)
        config.configure({ autosave = nil, timeout = 60 })

        test.assert.equals(config.config.autosave, initial_state, "Autosave should not change when configured with nil")
        test.assert.equals(config.config.timeout, 60, "Other config options should still work")
    end)

    test.it("should allow configuring custom save_debounce_ms", function()
        local config = require("async-remote-write.config")

        -- Configure with custom debounce
        config.configure({ save_debounce_ms = 5000 })

        test.assert.equals(config.config.save_debounce_ms, 5000, "Custom debounce should be set")
    end)

    test.it("should handle combined configuration options", function()
        local config = require("async-remote-write.config")

        -- Configure multiple options at once
        config.configure({
            autosave = true,
            save_debounce_ms = 2000,
            timeout = 45,
            debug = true,
        })

        test.assert.equals(config.config.autosave, true, "Autosave should be enabled")
        test.assert.equals(config.config.save_debounce_ms, 2000, "Debounce should be 2000ms")
        test.assert.equals(config.config.timeout, 45, "Timeout should be 45")
        test.assert.equals(config.config.debug, true, "Debug should be enabled")
    end)
end)

test.describe("Autosave Save Process Logic", function()
    -- Mock the operations module functionality for testing
    local function mock_start_save_process(bufnr, is_manual, config_autosave, is_modified)
        is_manual = is_manual or false
        is_modified = is_modified == nil and true or is_modified -- Default to modified

        -- Simulate buffer validation
        if not bufnr or bufnr <= 0 then
            return false, "invalid_buffer"
        end

        -- Simulate remote path check
        local bufname = "rsync://user@host/path/to/file.txt" -- Mock remote buffer

        -- For manual saves, execute immediately regardless of autosave setting
        if is_manual then
            return true, "manual_save_executed"
        end

        -- For automatic saves, check if autosave is enabled
        if not config_autosave then
            return true, "autosave_disabled_ignored"
        end

        -- Only proceed if buffer is modified
        if not is_modified then
            return true, "buffer_not_modified_skipped"
        end

        return true, "autosave_debounced"
    end

    test.it("should execute manual saves immediately when autosave is enabled", function()
        local success, result = mock_start_save_process(1, true, true, true)

        test.assert.truthy(success, "Manual save should succeed")
        test.assert.equals(result, "manual_save_executed", "Manual save should be executed")
    end)

    test.it("should execute manual saves immediately when autosave is disabled", function()
        local success, result = mock_start_save_process(1, true, false, true)

        test.assert.truthy(success, "Manual save should succeed even with autosave disabled")
        test.assert.equals(result, "manual_save_executed", "Manual save should be executed")
    end)

    test.it("should execute automatic saves when autosave is enabled", function()
        local success, result = mock_start_save_process(1, false, true, true)

        test.assert.truthy(success, "Auto save should succeed when enabled")
        test.assert.equals(result, "autosave_debounced", "Auto save should be debounced")
    end)

    test.it("should ignore automatic saves when autosave is disabled", function()
        local success, result = mock_start_save_process(1, false, false, true)

        test.assert.truthy(success, "Function should return success to prevent fallbacks")
        test.assert.equals(result, "autosave_disabled_ignored", "Auto save should be ignored when disabled")
    end)

    test.it("should skip saves for unmodified buffers in auto mode", function()
        local success, result = mock_start_save_process(1, false, true, false)

        test.assert.truthy(success, "Function should succeed")
        test.assert.equals(result, "buffer_not_modified_skipped", "Unmodified buffers should be skipped")
    end)

    test.it("should handle invalid buffers", function()
        local success, result = mock_start_save_process(0, false, true, true)

        test.assert.falsy(success, "Invalid buffer should fail")
        test.assert.equals(result, "invalid_buffer", "Should return appropriate error")
    end)
end)

test.describe("Autosave Buffer Autocommand Registration Logic", function()
    -- Mock the buffer autocommand registration logic
    local function mock_register_buffer_autocommands(bufnr, config_autosave)
        local registered_autocmds = {}

        -- Always register BufWriteCmd for manual saves
        table.insert(registered_autocmds, "BufWriteCmd")

        -- Only register text change events if autosave is enabled
        if config_autosave then
            table.insert(registered_autocmds, "TextChanged")
            table.insert(registered_autocmds, "TextChangedI")
            table.insert(registered_autocmds, "InsertLeave")
        end

        return registered_autocmds
    end

    test.it("should register all autocommands when autosave is enabled", function()
        local autocmds = mock_register_buffer_autocommands(1, true)

        test.assert.contains(autocmds, "BufWriteCmd", "Should register BufWriteCmd for manual saves")
        test.assert.contains(autocmds, "TextChanged", "Should register TextChanged for auto saves")
        test.assert.contains(autocmds, "TextChangedI", "Should register TextChangedI for auto saves")
        test.assert.contains(autocmds, "InsertLeave", "Should register InsertLeave for auto saves")
        test.assert.equals(#autocmds, 4, "Should register exactly 4 autocommands when autosave is enabled")
    end)

    test.it("should register only manual save autocommands when autosave is disabled", function()
        local autocmds = mock_register_buffer_autocommands(1, false)

        test.assert.contains(autocmds, "BufWriteCmd", "Should register BufWriteCmd for manual saves")
        test.assert.equals(#autocmds, 1, "Should register only 1 autocommand when autosave is disabled")

        -- Verify text change autocommands are NOT registered
        local has_text_changed = false
        local has_text_changed_i = false
        local has_insert_leave = false

        for _, autocmd in ipairs(autocmds) do
            if autocmd == "TextChanged" then
                has_text_changed = true
            elseif autocmd == "TextChangedI" then
                has_text_changed_i = true
            elseif autocmd == "InsertLeave" then
                has_insert_leave = true
            end
        end

        test.assert.falsy(has_text_changed, "TextChanged should not be registered when autosave is disabled")
        test.assert.falsy(has_text_changed_i, "TextChangedI should not be registered when autosave is disabled")
        test.assert.falsy(has_insert_leave, "InsertLeave should not be registered when autosave is disabled")
    end)
end)

test.describe("Autosave Configuration Integration", function()
    test.it("should maintain backward compatibility with existing configurations", function()
        local config = require("async-remote-write.config")

        -- Reset to defaults
        config.config.autosave = true
        config.config.save_debounce_ms = 3000
        config.config.timeout = 30
        config.config.debug = false

        -- Configure with only existing options (no autosave specified)
        config.configure({
            timeout = 60,
            debug = true,
        })

        -- Autosave should remain at default (true) when not specified
        test.assert.equals(config.config.autosave, true, "Autosave should remain enabled by default")
        test.assert.equals(config.config.timeout, 60, "Timeout should be updated")
        test.assert.equals(config.config.debug, true, "Debug should be updated")
    end)

    test.it("should work with async_write_opts style configuration", function()
        -- This simulates how the configuration would be used in practice
        local mock_setup_options = {
            async_write_opts = {
                autosave = false,
                save_debounce_ms = 1500,
                timeout = 45,
                debug = true,
            },
        }

        local config = require("async-remote-write.config")

        -- Simulate the setup process
        config.configure(mock_setup_options.async_write_opts)

        test.assert.equals(config.config.autosave, false, "Autosave should be disabled as configured")
        test.assert.equals(config.config.save_debounce_ms, 1500, "Debounce should be set to custom value")
        test.assert.equals(config.config.timeout, 45, "Timeout should be set to custom value")
        test.assert.equals(config.config.debug, true, "Debug should be enabled")
    end)
end)
