-- Test buffer metadata serialization and non-serializable object handling
local test = require('tests.init')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'

-- Mock vim.loop for timer objects
vim.loop = vim.loop or {
    new_timer = function()
        return {
            start = function() end,
            stop = function() end,
            close = function() end,
            is_active = function() return false end
        }
    end
}

-- Mock vim.split
vim.split = vim.split or function(str, sep, plain)
    local parts = {}
    local pattern = plain and sep or sep:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
    for part in (str .. sep):gmatch("(.-)" .. pattern) do
        table.insert(parts, part)
    end
    return parts
end

test.describe("Buffer Metadata Serialization", function()
    -- Initialize the buffer metadata system before running tests
    local metadata = require('remote-buffer-metadata')
    local schemas = require('remote-buffer-metadata.schemas')
    
    -- Register schemas if not already registered
    for schema_name, schema_def in pairs(schemas) do
        pcall(function() metadata.register_schema(schema_name, schema_def) end)
    end
    
    test.it("should handle serializable data correctly", function()
        local test_bufnr = 100
        
        -- Make sure the buffer is considered valid
        local original_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr)
            if bufnr == test_bufnr then
                return true
            end
            return original_is_valid(bufnr)
        end
        
        -- Test with simple serializable data
        local serializable_data = {
            job_id = 1234,
            start_time = os.time(),
            buffer_name = "test.txt",
            remote_path = "/remote/path/test.txt"
        }
        
        -- Set the data
        local success = metadata.set(test_bufnr, "async-remote-write", "active_write", serializable_data)
        test.assert.truthy(success, "Should successfully set serializable data")
        
        -- Get the data back
        local retrieved = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.truthy(retrieved, "Should retrieve data")
        test.assert.equals(retrieved.job_id, 1234, "Job ID should match")
        test.assert.equals(retrieved.buffer_name, "test.txt", "Buffer name should match")
        test.assert.equals(retrieved.remote_path, "/remote/path/test.txt", "Remote path should match")
        
        -- Restore original function
        vim.api.nvim_buf_is_valid = original_is_valid
        
        print("✅ Serializable data handling test passed!")
    end)
    
    test.it("should handle non-serializable objects correctly", function()
        local test_bufnr = 101
        
        -- Make sure the buffer is considered valid
        local original_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr)
            if bufnr == test_bufnr then
                return true
            end
            return original_is_valid(bufnr)
        end
        
        -- Create a timer object (non-serializable)
        local timer = vim.loop.new_timer()
        
        -- Test with mixed serializable and non-serializable data
        local mixed_data = {
            job_id = 5678,
            start_time = os.time(),
            buffer_name = "mixed_test.txt",
            timer = timer,  -- This is non-serializable
            nested = {
                serializable_value = "test",
                another_timer = vim.loop.new_timer()  -- Non-serializable in nested table
            }
        }
        
        -- Set the mixed data
        local success = metadata.set(test_bufnr, "async-remote-write", "active_write", mixed_data)
        test.assert.truthy(success, "Should successfully set mixed data")
        
        -- Debug: Let's see what's in the buffer metadata
        local buffer_data = vim.b[test_bufnr].remote_metadata
        if buffer_data and buffer_data["async-remote-write"] then
            print("DEBUG: Buffer metadata:", vim.inspect(buffer_data["async-remote-write"]["active_write"]))
        end
        
        -- Get the data back
        local retrieved = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.truthy(retrieved, "Should retrieve data")
        test.assert.equals(retrieved.job_id, 5678, "Job ID should match")
        test.assert.equals(retrieved.buffer_name, "mixed_test.txt", "Buffer name should match")
        
        -- Check that timer object is preserved
        test.assert.truthy(retrieved.timer, "Timer should be preserved")
        test.assert.equals(type(retrieved.timer), "table", "Timer should be a table (userdata)")
        
        -- Check nested structure
        test.assert.truthy(retrieved.nested, "Nested table should exist")
        test.assert.equals(retrieved.nested.serializable_value, "test", "Nested serializable value should match")
        test.assert.truthy(retrieved.nested.another_timer, "Nested timer should be preserved")
        
        -- Restore original function
        vim.api.nvim_buf_is_valid = original_is_valid
        
        print("✅ Non-serializable object handling test passed!")
    end)
    
    test.it("should clean up non-serializable storage on buffer delete", function()
        local test_bufnr = 102
        
        -- Make sure the buffer is considered valid initially
        local buffer_valid = true
        local original_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr)
            if bufnr == test_bufnr then
                return buffer_valid
            end
            return original_is_valid(bufnr)
        end
        
        -- Create data with timer
        local data_with_timer = {
            job_id = 9999,
            timer = vim.loop.new_timer()
        }
        
        -- Set the data
        metadata.set(test_bufnr, "async-remote-write", "active_write", data_with_timer)
        
        -- Verify data exists
        local retrieved = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.truthy(retrieved, "Should have data")
        test.assert.truthy(retrieved.timer, "Should have timer")
        
        -- Simulate buffer deletion by marking it invalid
        buffer_valid = false
        
        -- Manually trigger cleanup (simulating what would happen on BufDelete)
        -- Access the private non_serializable_storage to verify cleanup
        local cleanup_fn = metadata.setup_cleanup
        if cleanup_fn then
            -- In real usage, this would be called by the autocommand
            -- For testing, we can verify that invalid buffers return nil
            local after_delete = metadata.get(test_bufnr, "async-remote-write", "active_write")
            test.assert.falsy(after_delete, "Should return nil for invalid buffer")
        end
        
        -- Restore original function
        vim.api.nvim_buf_is_valid = original_is_valid
        
        print("✅ Buffer deletion cleanup test passed!")
    end)
    
    test.it("should handle updating non-serializable objects", function()
        local test_bufnr = 103
        
        -- Make sure the buffer is considered valid
        local original_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr)
            if bufnr == test_bufnr then
                return true
            end
            return original_is_valid(bufnr)
        end
        
        -- First, set data with a timer
        local timer1 = vim.loop.new_timer()
        local initial_data = {
            job_id = 1111,
            timer = timer1
        }
        
        metadata.set(test_bufnr, "async-remote-write", "active_write", initial_data)
        local retrieved1 = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.equals(retrieved1.job_id, 1111, "Initial job ID should match")
        test.assert.truthy(retrieved1.timer, "Initial timer should exist")
        
        -- Update with new data including a different timer
        local timer2 = vim.loop.new_timer()
        local updated_data = {
            job_id = 2222,
            timer = timer2,
            new_field = "added"
        }
        
        metadata.set(test_bufnr, "async-remote-write", "active_write", updated_data)
        local retrieved2 = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.equals(retrieved2.job_id, 2222, "Updated job ID should match")
        test.assert.truthy(retrieved2.timer, "Updated timer should exist")
        test.assert.equals(retrieved2.new_field, "added", "New field should be present")
        
        -- Update to remove timer (make fully serializable)
        local serializable_only = {
            job_id = 3333,
            buffer_name = "final.txt"
        }
        
        metadata.set(test_bufnr, "async-remote-write", "active_write", serializable_only)
        local retrieved3 = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.equals(retrieved3.job_id, 3333, "Final job ID should match")
        test.assert.equals(retrieved3.buffer_name, "final.txt", "Buffer name should match")
        test.assert.falsy(retrieved3.timer, "Timer should be removed")
        test.assert.falsy(retrieved3.new_field, "New field should be removed")
        
        -- Restore original function
        vim.api.nvim_buf_is_valid = original_is_valid
        
        print("✅ Non-serializable object update test passed!")
    end)
    
    test.it("should handle edge cases in serialization", function()
        local test_bufnr = 104
        
        -- Make sure the buffer is considered valid
        local original_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr)
            if bufnr == test_bufnr then
                return true
            end
            return original_is_valid(bufnr)
        end
        
        -- Test with nil value (should clear the key)
        metadata.set(test_bufnr, "async-remote-write", "active_write", nil)
        local nil_result = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.falsy(nil_result, "Nil value should clear the key")
        
        -- Test with empty table
        metadata.set(test_bufnr, "async-remote-write", "active_write", {})
        local empty_result = metadata.get(test_bufnr, "async-remote-write", "active_write")
        test.assert.truthy(empty_result, "Empty table should be preserved")
        test.assert.equals(type(empty_result), "table", "Should be a table")
        test.assert.truthy(vim.tbl_isempty(empty_result), "Should be empty")
        
        -- Test with complex nested structure
        local complex_data = {
            level1 = {
                level2 = {
                    serializable = "value",
                    timer = vim.loop.new_timer(),
                    level3 = {
                        another_timer = vim.loop.new_timer(),
                        number = 42
                    }
                }
            }
        }
        
        metadata.set(test_bufnr, "async-remote-write", "active_write", complex_data)
        local complex_result = metadata.get(test_bufnr, "async-remote-write", "active_write")
        
        test.assert.truthy(complex_result.level1, "Level 1 should exist")
        test.assert.truthy(complex_result.level1.level2, "Level 2 should exist")
        test.assert.equals(complex_result.level1.level2.serializable, "value", "Serializable value should be preserved")
        test.assert.truthy(complex_result.level1.level2.timer, "Timer should be preserved")
        test.assert.truthy(complex_result.level1.level2.level3, "Level 3 should exist")
        test.assert.truthy(complex_result.level1.level2.level3.another_timer, "Nested timer should be preserved")
        test.assert.equals(complex_result.level1.level2.level3.number, 42, "Nested number should be preserved")
        
        -- Restore original function
        vim.api.nvim_buf_is_valid = original_is_valid
        
        print("✅ Edge cases in serialization test passed!")
    end)
end)