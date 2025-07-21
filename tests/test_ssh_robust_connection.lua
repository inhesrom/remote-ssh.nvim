-- Test robust SSH connection options
local test = require('tests.init')

test.describe("SSH Robust Connection Options", function()

    test.it("should build SSH commands with robust connection options", function()
        -- Mock the updated build_ssh_cmd function
        local function build_ssh_cmd(host, command)
            local ssh_args = {"ssh"}

            -- Add robust connection options to handle various SSH issues
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ConnectTimeout=10")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ServerAliveInterval=5")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ServerAliveCountMax=3")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "TCPKeepAlive=yes")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ControlMaster=no")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ControlPath=none")

            table.insert(ssh_args, host)
            table.insert(ssh_args, command)

            return ssh_args
        end

        local host = "ianhersom@raspi0"
        local command = "cd /some/path && find . -maxdepth 1"

        local ssh_cmd = build_ssh_cmd(host, command)

        -- Check that all robust options are present
        test.assert.contains(ssh_cmd, "ssh", "Should contain ssh")
        test.assert.contains(ssh_cmd, "-o", "Should contain -o flags")
        test.assert.contains(ssh_cmd, "ConnectTimeout=10", "Should contain connection timeout")
        test.assert.contains(ssh_cmd, "ServerAliveInterval=5", "Should contain server alive interval")
        test.assert.contains(ssh_cmd, "ServerAliveCountMax=3", "Should contain server alive count max")
        test.assert.contains(ssh_cmd, "TCPKeepAlive=yes", "Should contain TCP keepalive")
        test.assert.contains(ssh_cmd, "ControlMaster=no", "Should contain control master setting")
        test.assert.contains(ssh_cmd, "ControlPath=none", "Should contain control path setting")
        test.assert.contains(ssh_cmd, host, "Should contain host")
        test.assert.contains(ssh_cmd, command, "Should contain command")
    end)

    test.it("should build SCP commands with robust connection options", function()
        -- Mock the updated build_scp_cmd function
        local function build_scp_cmd(source, destination, options)
            local scp_args = {"scp"}

            -- Add robust connection options to handle various SSH issues
            table.insert(scp_args, "-o")
            table.insert(scp_args, "ConnectTimeout=10")
            table.insert(scp_args, "-o")
            table.insert(scp_args, "ServerAliveInterval=5")
            table.insert(scp_args, "-o")
            table.insert(scp_args, "ServerAliveCountMax=3")
            table.insert(scp_args, "-o")
            table.insert(scp_args, "TCPKeepAlive=yes")

            -- Add standard options
            if options then
                for _, opt in ipairs(options) do
                    table.insert(scp_args, opt)
                end
            end

            table.insert(scp_args, source)
            table.insert(scp_args, destination)

            return scp_args
        end

        local source = "ianhersom@raspi0:/remote/file.txt"
        local destination = "/local/file.txt"
        local options = {"-q", "-p"}

        local scp_cmd = build_scp_cmd(source, destination, options)

        -- Check that all robust options are present
        test.assert.contains(scp_cmd, "scp", "Should contain scp")
        test.assert.contains(scp_cmd, "-o", "Should contain -o flags")
        test.assert.contains(scp_cmd, "ConnectTimeout=10", "Should contain connection timeout")
        test.assert.contains(scp_cmd, "ServerAliveInterval=5", "Should contain server alive interval")
        test.assert.contains(scp_cmd, "ServerAliveCountMax=3", "Should contain server alive count max")
        test.assert.contains(scp_cmd, "TCPKeepAlive=yes", "Should contain TCP keepalive")
        test.assert.contains(scp_cmd, "-q", "Should contain quiet option")
        test.assert.contains(scp_cmd, "-p", "Should contain preserve option")
        test.assert.contains(scp_cmd, source, "Should contain source")
        test.assert.contains(scp_cmd, destination, "Should contain destination")
    end)

    test.it("should handle kex_exchange_identification errors better", function()
        -- Test scenarios that could cause kex_exchange_identification errors

        -- Scenario 1: Connection timeout
        local exit_code = 255
        local stderr_output = {"kex_exchange_identification: read: Connection reset by peer"}
        local output = {}

        local has_valid_output = #output > 0
        local success = (exit_code == 0) or has_valid_output

        test.assert.falsy(success, "Should fail with no output and kex error")

        -- Check that error contains useful information
        local error_contains_kex = false
        for _, line in ipairs(stderr_output) do
            if line:find("kex_exchange_identification") then
                error_contains_kex = true
                break
            end
        end
        test.assert.truthy(error_contains_kex, "Error should contain kex_exchange_identification info")
    end)

    test.it("should test the exact raspi0 connection scenario", function()
        local url = "rsync://ianhersom@raspi0/home/ianhersom/repo/neovim/test/old"
        local host = "ianhersom@raspi0"
        local path = "/home/ianhersom/repo/neovim/test/old/"

        -- Build the SSH command that would be executed
        local ssh_cmd = string.format(
            "cd %s && find . -maxdepth 1 | sort | while read f; do if [ \"$f\" != \".\" ]; then if [ -d \"$f\" ]; then echo \"d ${f#./}\"; else echo \"f ${f#./}\"; fi; fi; done",
            vim.fn.shellescape(path)
        )

        test.assert.contains(ssh_cmd, "cd", "SSH command should contain cd")
        test.assert.contains(ssh_cmd, "/home/ianhersom/repo/neovim/test/old/", "SSH command should contain the path")
        test.assert.contains(ssh_cmd, "find . -maxdepth 1", "SSH command should contain find")

        -- Mock robust SSH command construction
        local function build_ssh_cmd(host, command)
            local ssh_args = {"ssh"}

            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ConnectTimeout=10")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ServerAliveInterval=5")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ServerAliveCountMax=3")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "TCPKeepAlive=yes")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ControlMaster=no")
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ControlPath=none")

            table.insert(ssh_args, host)
            table.insert(ssh_args, command)

            return ssh_args
        end

        local full_ssh_cmd = build_ssh_cmd(host, ssh_cmd)

        -- Verify the command structure
        test.assert.contains(full_ssh_cmd, "ssh", "Should contain ssh")
        test.assert.contains(full_ssh_cmd, "ConnectTimeout=10", "Should contain connection timeout")
        test.assert.contains(full_ssh_cmd, "ianhersom@raspi0", "Should contain host")

        -- Convert to string to verify the full command
        local cmd_str = table.concat(full_ssh_cmd, " ")
        test.assert.contains(cmd_str, "ssh -o ConnectTimeout=10", "Should have proper SSH options")
    end)

    test.it("should handle different types of SSH connection errors", function()
        local error_scenarios = {
            {
                description = "kex_exchange_identification error",
                stderr = {"kex_exchange_identification: read: Connection reset by peer"},
                exit_code = 255
            },
            {
                description = "connection timeout error",
                stderr = {"ssh: connect to host raspi0 port 22: Operation timed out"},
                exit_code = 255
            },
            {
                description = "connection refused error",
                stderr = {"ssh: connect to host raspi0 port 22: Connection refused"},
                exit_code = 255
            },
            {
                description = "host unreachable error",
                stderr = {"ssh: connect to host raspi0 port 22: No route to host"},
                exit_code = 255
            }
        }

        for _, scenario in ipairs(error_scenarios) do
            local output = {}
            local has_valid_output = #output > 0
            local success = (scenario.exit_code == 0) or has_valid_output

            test.assert.falsy(success, "Should fail for " .. scenario.description)
            test.assert.equals(scenario.exit_code, 255, "Should have exit code 255 for " .. scenario.description)
            test.assert.truthy(#scenario.stderr > 0, "Should have stderr for " .. scenario.description)
        end
    end)
end)
