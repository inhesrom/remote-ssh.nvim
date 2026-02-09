-- Test SSH command escaping functionality
local test = require("tests.init")
local ssh_utils = require("async-remote-write.ssh_utils")

test.describe("SSH Command Escaping", function()
    test.it("should properly escape paths with spaces", function()
        local path = "/home/user/My Documents/test dir/"
        local ssh_cmd = ssh_utils.build_list_dir_cmd(path)

        -- Verify command structure
        test.assert.contains(ssh_cmd, "sh -c", "SSH command should use sh -c")
        test.assert.contains(ssh_cmd, "find", "SSH command should contain find command")
        test.assert.contains(ssh_cmd, "My Documents", "SSH command should contain the path")
    end)

    test.it("should properly escape paths with quotes", function()
        local path = "/home/user/test's dir/"
        local ssh_cmd = ssh_utils.build_list_dir_cmd(path)

        -- Verify command structure
        test.assert.contains(ssh_cmd, "sh -c", "SSH command should use sh -c")
        -- Verify the path is properly shell-escaped and passed as argument
        local escaped_path = vim.fn.shellescape(path)
        test.assert.contains(ssh_cmd, escaped_path, "SSH command should contain properly escaped path")
    end)

    test.it("should properly escape paths with special characters", function()
        local path = "/home/user/test (dir) & more/"
        local ssh_cmd = ssh_utils.build_list_dir_cmd(path)

        -- Verify command structure is maintained
        test.assert.contains(ssh_cmd, "sh -c", "SSH command should use sh -c")
        test.assert.contains(ssh_cmd, "find", "SSH command should contain find command")
    end)

    test.it("should handle simple paths without breaking", function()
        local path = "/home/user/simple/"
        local ssh_cmd = ssh_utils.build_list_dir_cmd(path)

        -- Verify command contains expected elements
        test.assert.contains(ssh_cmd, "/home/user/simple", "SSH command should contain the path")
        test.assert.contains(ssh_cmd, "find . -maxdepth 1", "SSH command should contain find with maxdepth")
        test.assert.contains(ssh_cmd, "sort", "SSH command should contain sort")
        test.assert.contains(ssh_cmd, "while IFS= read -r f", "SSH command should contain while loop")
    end)

    test.it("should pass path as argument to avoid quoting issues", function()
        local path = '/home/user/test\'s "quoted" dir/'
        local ssh_cmd = ssh_utils.build_list_dir_cmd(path)

        -- The key feature: path is passed as $1 argument, not embedded in script
        test.assert.contains(ssh_cmd, "_ ", "SSH command should have placeholder for $0")
        test.assert.contains(ssh_cmd, 'cd "$1"', "Script should reference $1 for path")
    end)
end)
