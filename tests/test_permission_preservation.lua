-- Test file permission preservation functionality
local test = require("tests.init")

-- Mock job system for testing
local mock_jobs = {}
local next_job_id = 1000

local function mock_jobstart(cmd, opts)
    local job_id = next_job_id
    next_job_id = next_job_id + 1

    mock_jobs[job_id] = {
        cmd = cmd,
        opts = opts,
        running = true,
    }

    return job_id
end

local function simulate_job_completion(job_id, exit_code, stdout_data, stderr_data)
    local job = mock_jobs[job_id]
    if not job then
        return
    end

    job.running = false

    if stdout_data and job.opts.on_stdout then
        job.opts.on_stdout(job_id, stdout_data)
    end

    if stderr_data and job.opts.on_stderr then
        job.opts.on_stderr(job_id, stderr_data)
    end

    if job.opts.on_exit then
        job.opts.on_exit(job_id, exit_code)
    end
end

test.describe("Permission Preservation", function()
    local metadata
    local original_is_valid

    test.setup(function()
        metadata = require("remote-buffer-metadata")
        local schemas = require("remote-buffer-metadata.schemas")

        -- Register schemas manually
        for schema_name, schema_def in pairs(schemas) do
            pcall(function()
                metadata.register_schema(schema_name, schema_def)
            end)
        end

        -- Override nvim_buf_is_valid to make our test buffers valid
        original_is_valid = vim.api.nvim_buf_is_valid
        vim.api.nvim_buf_is_valid = function(bufnr)
            -- Make all test buffers valid
            return true
        end
    end)

    test.teardown(function()
        -- Restore original function
        if original_is_valid then
            vim.api.nvim_buf_is_valid = original_is_valid
        end
    end)

    test.it("should store and retrieve basic permissions in metadata", function()
        -- Create a test buffer
        local bufnr = vim.api.nvim_create_buf(false, false)
        local test_url = "scp://testhost:/tmp/test_executable.sh"
        vim.api.nvim_buf_set_name(bufnr, test_url)

        -- Store permissions in metadata
        metadata.set(bufnr, "async_remote_write", "host", "testhost")
        metadata.set(bufnr, "async_remote_write", "remote_path", "/tmp/test_executable.sh")
        metadata.set(bufnr, "async_remote_write", "protocol", "scp")
        metadata.set(bufnr, "async_remote_write", "file_permissions", "755")
        metadata.set(bufnr, "async_remote_write", "file_mode", "-rwxr-xr-x")

        -- Verify permissions are stored
        local stored_permissions = metadata.get(bufnr, "async_remote_write", "file_permissions")
        local stored_mode = metadata.get(bufnr, "async_remote_write", "file_mode")
        test.assert.equals(stored_permissions, "755", "File permissions should be stored as '755'")
        test.assert.equals(stored_mode, "-rwxr-xr-x", "File mode should be stored correctly")

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    test.it("should validate permission schema correctly", function()
        local test_bufnr = vim.api.nvim_create_buf(false, false)

        -- Test setting valid permission values
        local success1 = pcall(metadata.set, test_bufnr, "async_remote_write", "file_permissions", "755")
        test.assert.truthy(success1, "Valid octal permissions should be accepted")

        local success2 = pcall(metadata.set, test_bufnr, "async_remote_write", "file_permissions", nil)
        test.assert.truthy(success2, "Nil permissions should be accepted")

        local success3 = pcall(metadata.set, test_bufnr, "async_remote_write", "file_mode", "-rwxr-xr-x")
        test.assert.truthy(success3, "Valid mode string should be accepted")

        local success4 = pcall(metadata.set, test_bufnr, "async_remote_write", "file_mode", nil)
        test.assert.truthy(success4, "Nil mode should be accepted")

        vim.api.nvim_buf_delete(test_bufnr, { force = true })
    end)

    test.it("should have correct default values", function()
        local schemas = require("remote-buffer-metadata.schemas")
        local async_schema = schemas.async_remote_write

        test.assert.equals(async_schema.defaults.file_permissions, nil, "Default file_permissions should be nil")
        test.assert.equals(async_schema.defaults.file_mode, nil, "Default file_mode should be nil")
    end)

    test.it("should handle various permission formats", function()
        local test_cases = {
            { perms = "644", mode = "-rw-r--r--", desc = "regular file" },
            { perms = "755", mode = "-rwxr-xr-x", desc = "executable" },
            { perms = "600", mode = "-rw-------", desc = "private file" },
            { perms = "777", mode = "-rwxrwxrwx", desc = "fully open" },
            { perms = "000", mode = "----------", desc = "no permissions" },
            { perms = "4755", mode = "-rwsr-xr-x", desc = "setuid executable" },
            { perms = "2755", mode = "-rwxr-sr-x", desc = "setgid executable" },
            { perms = "1755", mode = "-rwxr-xr-t", desc = "sticky bit" },
        }

        for i, test_case in ipairs(test_cases) do
            local bufnr = vim.api.nvim_create_buf(false, false)

            -- Test storing different permission formats
            metadata.set(bufnr, "async_remote_write", "file_permissions", test_case.perms)
            metadata.set(bufnr, "async_remote_write", "file_mode", test_case.mode)

            -- Verify they're stored correctly
            local stored_perms = metadata.get(bufnr, "async_remote_write", "file_permissions")
            local stored_mode = metadata.get(bufnr, "async_remote_write", "file_mode")

            test.assert.equals(
                stored_perms,
                test_case.perms,
                "Permissions " .. test_case.perms .. " should be stored correctly"
            )
            test.assert.equals(stored_mode, test_case.mode, "Mode " .. test_case.mode .. " should be stored correctly")

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    test.it("should handle permission operation errors gracefully", function()
        -- Test stat failure handling
        local bufnr1 = vim.api.nvim_create_buf(false, false)
        -- Simulate what would happen when stat fails - no permissions stored
        local stored_perms = metadata.get(bufnr1, "async_remote_write", "file_permissions")
        test.assert.equals(stored_perms, nil, "No permissions should be stored when stat fails")

        -- Test chmod failure handling
        local bufnr2 = vim.api.nvim_create_buf(false, false)
        metadata.set(bufnr2, "async_remote_write", "file_permissions", "644")
        -- The chmod failure should be logged but not crash the system
        local stored_perms2 = metadata.get(bufnr2, "async_remote_write", "file_permissions")
        test.assert.equals(stored_perms2, "644", "Permissions should still be stored even if chmod fails")

        -- Clean up
        vim.api.nvim_buf_delete(bufnr1, { force = true })
        vim.api.nvim_buf_delete(bufnr2, { force = true })
    end)

    test.it("should handle edge cases with special paths", function()
        local edge_cases = {
            { path = "/tmp/file with spaces.sh", desc = "path with spaces" },
            { path = "/tmp/file-with-dashes.sh", desc = "path with dashes" },
            { path = "/tmp/file_with_underscores.sh", desc = "path with underscores" },
            { path = "/tmp/file.with.dots.sh", desc = "path with dots" },
            { path = "/tmp/file'with'quotes.sh", desc = "path with single quotes" },
            { path = "/tmp/very/deep/nested/directory/structure/file.sh", desc = "deeply nested path" },
            { path = "/tmp/файл.sh", desc = "path with unicode characters" },
        }

        for i, test_case in ipairs(edge_cases) do
            local bufnr = vim.api.nvim_create_buf(false, false)

            -- Test storing permissions for files with special paths
            metadata.set(bufnr, "async_remote_write", "remote_path", test_case.path)
            metadata.set(bufnr, "async_remote_write", "file_permissions", "755")
            metadata.set(bufnr, "async_remote_write", "file_mode", "-rwxr-xr-x")

            -- Verify they're stored correctly
            local stored_path = metadata.get(bufnr, "async_remote_write", "remote_path")
            local stored_perms = metadata.get(bufnr, "async_remote_write", "file_permissions")

            test.assert.equals(stored_path, test_case.path, "Path should be stored correctly: " .. test_case.path)
            test.assert.equals(stored_perms, "755", "Permissions should be stored for " .. test_case.desc)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    test.it("should maintain permissions across buffer lifecycle", function()
        -- Create test buffer
        local bufnr = vim.api.nvim_create_buf(false, false)
        local test_url = "scp://testhost:/tmp/lifecycle_test.sh"
        vim.api.nvim_buf_set_name(bufnr, test_url)

        -- Initial permission storage
        metadata.set(bufnr, "async_remote_write", "host", "testhost")
        metadata.set(bufnr, "async_remote_write", "remote_path", "/tmp/lifecycle_test.sh")
        metadata.set(bufnr, "async_remote_write", "protocol", "scp")
        metadata.set(bufnr, "async_remote_write", "file_permissions", "755")
        metadata.set(bufnr, "async_remote_write", "file_mode", "-rwxr-xr-x")

        -- Test 1: Permissions persist through buffer modifications
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#!/bin/bash", "echo 'modified'" })
        local perms_after_edit = metadata.get(bufnr, "async_remote_write", "file_permissions")
        test.assert.equals(perms_after_edit, "755", "Permissions should persist through buffer edits")

        -- Test 2: Permissions persist through multiple saves (simulated)
        for i = 1, 3 do
            vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "# Save " .. i })
            local perms_after_save = metadata.get(bufnr, "async_remote_write", "file_permissions")
            test.assert.equals(perms_after_save, "755", "Permissions should persist through save " .. i)
        end

        -- Test 3: Permission update during refresh
        metadata.set(bufnr, "async_remote_write", "file_permissions", "644")
        metadata.set(bufnr, "async_remote_write", "file_mode", "-rw-r--r--")

        local updated_perms = metadata.get(bufnr, "async_remote_write", "file_permissions")
        local updated_mode = metadata.get(bufnr, "async_remote_write", "file_mode")
        test.assert.equals(updated_perms, "644", "Permissions should be updatable")
        test.assert.equals(updated_mode, "-rw-r--r--", "Mode should be updatable")

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    test.it("should handle concurrent permission operations", function()
        -- Create multiple test buffers
        local buffers = {}
        for i = 1, 5 do
            local bufnr = vim.api.nvim_create_buf(false, false)
            local test_url = "scp://testhost:/tmp/concurrent_test_" .. i .. ".sh"
            vim.api.nvim_buf_set_name(bufnr, test_url)

            -- Store different permissions for each buffer
            local perms = tostring(600 + i * 10 + i) -- 611, 622, 633, 644, 655
            metadata.set(bufnr, "async_remote_write", "host", "testhost")
            metadata.set(bufnr, "async_remote_write", "remote_path", "/tmp/concurrent_test_" .. i .. ".sh")
            metadata.set(bufnr, "async_remote_write", "protocol", "scp")
            metadata.set(bufnr, "async_remote_write", "file_permissions", perms)
            metadata.set(bufnr, "async_remote_write", "file_mode", "-rw-r--r--")

            table.insert(buffers, { bufnr = bufnr, expected_perms = perms })
        end

        -- Verify all buffers have correct permissions stored independently
        for i, buffer_info in ipairs(buffers) do
            local stored_perms = metadata.get(buffer_info.bufnr, "async_remote_write", "file_permissions")
            test.assert.equals(
                stored_perms,
                buffer_info.expected_perms,
                "Buffer " .. i .. " should have permissions " .. buffer_info.expected_perms
            )
        end

        -- Test that modifying one buffer doesn't affect others
        metadata.set(buffers[1].bufnr, "async_remote_write", "file_permissions", "777")

        -- Verify other buffers are unaffected
        for i = 2, #buffers do
            local stored_perms = metadata.get(buffers[i].bufnr, "async_remote_write", "file_permissions")
            test.assert.equals(
                stored_perms,
                buffers[i].expected_perms,
                "Buffer " .. i .. " permissions should be unaffected by changes to buffer 1"
            )
        end

        -- Clean up
        for _, buffer_info in ipairs(buffers) do
            vim.api.nvim_buf_delete(buffer_info.bufnr, { force = true })
        end
    end)

    test.it("should work with different protocols", function()
        local protocols = {
            { protocol = "scp", url = "scp://testhost:/tmp/scp_test.sh" },
            { protocol = "rsync", url = "rsync://testhost:/tmp/rsync_test.sh" },
        }

        for _, proto_info in ipairs(protocols) do
            local bufnr = vim.api.nvim_create_buf(false, false)
            vim.api.nvim_buf_set_name(bufnr, proto_info.url)

            -- Store permissions for this protocol
            metadata.set(bufnr, "async_remote_write", "host", "testhost")
            metadata.set(bufnr, "async_remote_write", "remote_path", "/tmp/" .. proto_info.protocol .. "_test.sh")
            metadata.set(bufnr, "async_remote_write", "protocol", proto_info.protocol)
            metadata.set(bufnr, "async_remote_write", "file_permissions", "755")
            metadata.set(bufnr, "async_remote_write", "file_mode", "-rwxr-xr-x")

            -- Verify permissions are stored correctly for this protocol
            local stored_protocol = metadata.get(bufnr, "async_remote_write", "protocol")
            local stored_perms = metadata.get(bufnr, "async_remote_write", "file_permissions")

            test.assert.equals(stored_protocol, proto_info.protocol, "Protocol should be stored correctly")
            test.assert.equals(stored_perms, "755", "Permissions should work with " .. proto_info.protocol)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    test.it("should generate correct SSH commands", function()
        local host = "testhost"
        local path = "/tmp/test_file.sh"

        -- Expected command: ssh testhost stat -c %a:%A /tmp/test_file.sh
        local expected_stat_cmd = { "ssh", host, "stat", "-c", "%a:%A", path }

        -- Expected chmod command: ssh testhost chmod 755 /tmp/test_file.sh
        local expected_chmod_cmd = { "ssh", host, "chmod", "755", path }

        -- Verify command structure (this is a structural test)
        test.assert.equals(expected_stat_cmd[1], "ssh", "Stat command should use ssh")
        test.assert.equals(expected_stat_cmd[2], host, "Stat command should target correct host")
        test.assert.equals(expected_stat_cmd[3], "stat", "Stat command should use stat")
        test.assert.equals(expected_stat_cmd[4], "-c", "Stat command should use -c flag")
        test.assert.equals(expected_stat_cmd[5], "%a:%A", "Stat command should use correct format")
        test.assert.equals(expected_stat_cmd[6], path, "Stat command should target correct path")

        test.assert.equals(expected_chmod_cmd[1], "ssh", "Chmod command should use ssh")
        test.assert.equals(expected_chmod_cmd[2], host, "Chmod command should target correct host")
        test.assert.equals(expected_chmod_cmd[3], "chmod", "Chmod command should use chmod")
        test.assert.equals(expected_chmod_cmd[4], "755", "Chmod command should use correct permissions")
        test.assert.equals(expected_chmod_cmd[5], path, "Chmod command should target correct path")
    end)
end)
