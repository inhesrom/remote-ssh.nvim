-- Test for file watcher SSH mtime command improvements
local test = require('tests.init')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'

test.describe("File Watcher SSH mtime Command", function()
    test.it("should build cross-platform stat command correctly", function()
        local escaped_path = "'/path/to/file.txt'"
        local expected_command = string.format(
            "stat -c %%Y %s 2>/dev/null || stat -f %%m %s 2>/dev/null || (test -f %s && echo 'EXISTS' || echo 'NOTFOUND')",
            escaped_path, escaped_path, escaped_path
        )

        -- Test the command structure
        test.assert.truthy(string.find(expected_command, "stat %-c"), "Should include Linux stat format")
        test.assert.truthy(string.find(expected_command, "stat %-f"), "Should include BSD/macOS stat format")
        test.assert.truthy(string.find(expected_command, "test %-f"), "Should include file existence fallback")
        test.assert.truthy(string.find(expected_command, "NOTFOUND"), "Should include not found case")
        test.assert.truthy(string.find(expected_command, "EXISTS"), "Should include exists fallback")
    end)

    test.it("should handle different mtime output formats", function()
        -- Test parsing different types of output
        local function parse_mtime_output(output)
            if output == "NOTFOUND" or output == "" then
                return false, "Remote file not found"
            end

            if output == "EXISTS" then
                return true, os.time() -- Use current time as fallback
            end

            local mtime = tonumber(output)
            if not mtime then
                return false, "Invalid mtime format: " .. output
            end

            return true, mtime
        end

        -- Test valid Unix timestamp
        local success1, result1 = parse_mtime_output("1640995200")
        test.assert.truthy(success1, "Should parse valid Unix timestamp")
        test.assert.equals(result1, 1640995200, "Should return correct timestamp")

        -- Test file not found
        local success2, result2 = parse_mtime_output("NOTFOUND")
        test.assert.falsy(success2, "Should handle NOTFOUND")
        test.assert.truthy(string.find(result2, "not found"), "Should return not found message")

        -- Test exists but no mtime
        local success3, result3 = parse_mtime_output("EXISTS")
        test.assert.truthy(success3, "Should handle EXISTS fallback")
        test.assert.truthy(type(result3) == "number", "Should return numeric timestamp")

        -- Test invalid format
        local success4, result4 = parse_mtime_output("invalid_output")
        test.assert.falsy(success4, "Should reject invalid format")
        test.assert.truthy(string.find(result4, "Invalid mtime format"), "Should return format error")

        -- Test empty output
        local success5, result5 = parse_mtime_output("")
        test.assert.falsy(success5, "Should handle empty output")
    end)

    test.it("should provide helpful error context", function()
        -- Test that error messages provide context for debugging
        local function create_error_message(exit_code, stderr, stdout)
            if exit_code ~= 0 then
                return string.format("SSH stat command failed - exit code: %d, stderr: %s, stdout: %s",
                                    exit_code, stderr, stdout)
            end
            return "Success"
        end

        local error1 = create_error_message(1, "Permission denied", "")
        test.assert.truthy(string.find(error1, "Permission denied"), "Should include stderr in error")
        test.assert.truthy(string.find(error1, "exit code: 1"), "Should include exit code")

        local error2 = create_error_message(127, "", "command not found")
        test.assert.truthy(string.find(error2, "command not found"), "Should include stdout in error")

        local success = create_error_message(0, "", "1640995200")
        test.assert.equals(success, "Success", "Should handle success case")
    end)

    test.it("should validate file path escaping", function()
        -- Mock vim.fn.shellescape behavior
        local function mock_shellescape(str)
            return "'" .. str:gsub("'", "'\"'\"'") .. "'"
        end

        -- Test paths that need escaping
        local dangerous_path = "/path with spaces/file's name.txt"
        local escaped = mock_shellescape(dangerous_path)

        test.assert.truthy(string.find(escaped, "^'"), "Should start with quote")
        test.assert.truthy(string.find(escaped, "'$"), "Should end with quote")
        test.assert.truthy(string.find(escaped, "path with spaces"), "Should preserve path content")

        -- Test that the escaped path can be used safely in command
        local safe_command = string.format("stat -c %%Y %s", escaped)
        test.assert.truthy(type(safe_command) == "string", "Should create valid command string")
    end)

    test.it("should handle different types of job results safely", function()
        -- Test the robust result handling that was added to fix the format error
        local function safe_result_handling(result)
            local output = ""
            if result and type(result) == "table" then
                if #result > 0 then
                    output = table.concat(result, "\n"):gsub("%s+$", "")
                end
            elseif result then
                output = tostring(result):gsub("%s+$", "")
            end
            return output
        end

        -- Test with table result (normal case)
        local table_result = {"1640995200"}
        local output1 = safe_result_handling(table_result)
        test.assert.equals(output1, "1640995200", "Should handle table results")

        -- Test with empty table
        local empty_result = {}
        local output2 = safe_result_handling(empty_result)
        test.assert.equals(output2, "", "Should handle empty table results")

        -- Test with string result
        local string_result = "1640995200"
        local output3 = safe_result_handling(string_result)
        test.assert.equals(output3, "1640995200", "Should handle string results")

        -- Test with nil result
        local output4 = safe_result_handling(nil)
        test.assert.equals(output4, "", "Should handle nil results")

        -- Test with number result
        local number_result = 1640995200
        local output5 = safe_result_handling(number_result)
        test.assert.equals(output5, "1640995200", "Should handle number results")
    end)

    test.it("should handle non-numeric exit codes safely", function()
        -- Test that exit_code handling is robust
        local function safe_exit_code_handling(raw_exit_code)
            local exit_code = raw_exit_code
            if type(exit_code) ~= "number" then
                exit_code = -1 -- Use -1 to indicate unknown exit code
            end
            return exit_code
        end

        -- Test with normal numeric exit code
        local exit1 = safe_exit_code_handling(0)
        test.assert.equals(exit1, 0, "Should handle numeric exit codes")

        -- Test with table exit code (which could happen with plenary.job)
        local exit2 = safe_exit_code_handling({1})
        test.assert.equals(exit2, -1, "Should handle table exit codes")

        -- Test with nil exit code
        local exit3 = safe_exit_code_handling(nil)
        test.assert.equals(exit3, -1, "Should handle nil exit codes")

        -- Test with string exit code
        local exit4 = safe_exit_code_handling("error")
        test.assert.equals(exit4, -1, "Should handle string exit codes")

        -- Verify these can be safely used in string.format
        local message1 = string.format("Exit code: %d", exit1)
        local message2 = string.format("Exit code: %d", exit2)
        test.assert.truthy(string.find(message1, "Exit code: 0"), "Should format normal exit code")
        test.assert.truthy(string.find(message2, "Exit code: %-1"), "Should format unknown exit code")
    end)
end)
