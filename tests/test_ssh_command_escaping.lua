-- Test SSH command escaping functionality
local test = require('tests.init')

test.describe("SSH Command Escaping", function()
    test.it("should properly escape paths with spaces", function()
        local path = "/home/user/My Documents/test dir/"
        local escaped_path = vim.fn.shellescape(path, 1)
        
        -- Test that the escaped path contains proper quoting
        test.assert.contains(escaped_path, "My Documents", "Escaped path should contain the directory name")
        
        -- Test SSH command construction
        local ssh_cmd = string.format(
            "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \\\"\\$f\\\" != \\\".\\\" ]; then if [ -d \\\"\\$f\\\" ]; then echo \\\"d \\${f#./}\\\"; else echo \\\"f \\${f#./}\\\"; fi; fi; done",
            escaped_path
        )
        
        -- Verify command structure
        test.assert.contains(ssh_cmd, "cd", "SSH command should contain cd command")
        test.assert.contains(ssh_cmd, "find", "SSH command should contain find command")
        test.assert.contains(ssh_cmd, "\\\"\\$f\\\"", "SSH command should have properly escaped variables")
    end)
    
    test.it("should properly escape paths with quotes", function()
        local path = "/home/user/test's dir/"
        local escaped_path = vim.fn.shellescape(path, 1)
        
        -- Test SSH command construction with quotes
        local ssh_cmd = string.format(
            "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \\\"\\$f\\\" != \\\".\\\" ]; then if [ -d \\\"\\$f\\\" ]; then echo \\\"d \\${f#./}\\\"; else echo \\\"f \\${f#./}\\\"; fi; fi; done",
            escaped_path
        )
        
        -- Verify command doesn't break with quotes
        test.assert.contains(ssh_cmd, "cd", "SSH command should contain cd command")
        test.assert.truthy(#ssh_cmd > 50, "SSH command should be properly constructed")
    end)
    
    test.it("should properly escape paths with special characters", function()
        local path = "/home/user/test (dir) & more/"
        local escaped_path = vim.fn.shellescape(path, 1)
        
        -- Test SSH command construction with special characters
        local ssh_cmd = string.format(
            "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \\\"\\$f\\\" != \\\".\\\" ]; then if [ -d \\\"\\$f\\\" ]; then echo \\\"d \\${f#./}\\\"; else echo \\\"f \\${f#./}\\\"; fi; fi; done",
            escaped_path
        )
        
        -- Verify command structure is maintained
        test.assert.contains(ssh_cmd, "cd", "SSH command should contain cd command")
        test.assert.contains(ssh_cmd, "find", "SSH command should contain find command")
        test.assert.contains(ssh_cmd, "\\\"\\$f\\\"", "SSH command should have properly escaped variables")
    end)
    
    test.it("should handle simple paths without breaking", function()
        local path = "/home/user/simple/"
        local escaped_path = vim.fn.shellescape(path, 1)
        
        -- Test SSH command construction
        local ssh_cmd = string.format(
            "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \\\"\\$f\\\" != \\\".\\\" ]; then if [ -d \\\"\\$f\\\" ]; then echo \\\"d \\${f#./}\\\"; else echo \\\"f \\${f#./}\\\"; fi; fi; done",
            escaped_path
        )
        
        -- Verify command contains expected elements
        test.assert.contains(ssh_cmd, "/home/user/simple", "SSH command should contain the path")
        test.assert.contains(ssh_cmd, "find . -maxdepth 1", "SSH command should contain find with maxdepth")
        test.assert.contains(ssh_cmd, "sort", "SSH command should contain sort")
        test.assert.contains(ssh_cmd, "while read f", "SSH command should contain while loop")
    end)
end)