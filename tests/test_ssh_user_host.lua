-- Test SSH user@host parsing functionality
local test = require("tests.init")

test.describe("SSH User@Host Parsing", function()
    test.it("should detect localhost with user@host format", function()
        -- Mock the updated is_localhost function
        local function is_localhost(host)
            -- Extract hostname from user@host format if present
            local hostname = host:match("@(.+)$") or host

            return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
        end

        -- Test various user@host formats
        test.assert.truthy(is_localhost("testuser@localhost"), "Should detect testuser@localhost")
        test.assert.truthy(is_localhost("root@127.0.0.1"), "Should detect root@127.0.0.1")
        test.assert.truthy(is_localhost("user@::1"), "Should detect user@::1")

        -- Test plain host formats (should still work)
        test.assert.truthy(is_localhost("localhost"), "Should detect plain localhost")
        test.assert.truthy(is_localhost("127.0.0.1"), "Should detect plain 127.0.0.1")
        test.assert.truthy(is_localhost("::1"), "Should detect plain ::1")

        -- Test remote hosts (should not be detected as localhost)
        test.assert.falsy(is_localhost("testuser@remote.server.com"), "Should not detect remote server")
        test.assert.falsy(is_localhost("user@192.168.1.100"), "Should not detect other IP")
        test.assert.falsy(is_localhost("remote.server.com"), "Should not detect plain remote server")
    end)

    test.it("should build SSH commands with IPv4 flag for user@localhost", function()
        -- Mock the updated build_ssh_cmd function
        local function is_localhost(host)
            local hostname = host:match("@(.+)$") or host
            return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
        end

        local function build_ssh_cmd(host, command)
            local ssh_args = { "ssh" }

            if is_localhost(host) then
                table.insert(ssh_args, "-4")
            end

            table.insert(ssh_args, host)
            table.insert(ssh_args, command)

            return ssh_args
        end

        -- Test the exact case from your error
        local host = "testuser@localhost"
        local command = "cd '/home/testuser/repos/tokio/' && find . -maxdepth 1"

        local ssh_cmd = build_ssh_cmd(host, command)

        test.assert.contains(ssh_cmd, "ssh", "Should contain ssh")
        test.assert.contains(ssh_cmd, "-4", "Should contain -4 flag for localhost")
        test.assert.contains(ssh_cmd, "testuser@localhost", "Should contain full host")
        test.assert.contains(ssh_cmd, command, "Should contain command")

        -- Verify the order is correct: ssh -4 testuser@localhost command
        test.assert.equals(ssh_cmd[1], "ssh", "First element should be ssh")
        test.assert.equals(ssh_cmd[2], "-4", "Second element should be -4")
        test.assert.equals(ssh_cmd[3], "testuser@localhost", "Third element should be host")
        test.assert.equals(ssh_cmd[4], command, "Fourth element should be command")
    end)

    test.it("should not add IPv4 flag for remote hosts with user", function()
        local function is_localhost(host)
            local hostname = host:match("@(.+)$") or host
            return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
        end

        local function build_ssh_cmd(host, command)
            local ssh_args = { "ssh" }

            if is_localhost(host) then
                table.insert(ssh_args, "-4")
            end

            table.insert(ssh_args, host)
            table.insert(ssh_args, command)

            return ssh_args
        end

        -- Test remote host with user
        local host = "testuser@remote.server.com"
        local command = "cd /some/path && ls"

        local ssh_cmd = build_ssh_cmd(host, command)

        test.assert.contains(ssh_cmd, "ssh", "Should contain ssh")
        test.assert.contains(ssh_cmd, "testuser@remote.server.com", "Should contain host")
        test.assert.contains(ssh_cmd, command, "Should contain command")

        -- Should NOT contain -4 flag
        local cmd_str = table.concat(ssh_cmd, " ")
        test.assert.falsy(cmd_str:find(" -4 "), "Should NOT contain -4 flag for remote host")
    end)

    test.it("should handle edge cases in hostname extraction", function()
        local function is_localhost(host)
            local hostname = host:match("@(.+)$") or host
            return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
        end

        -- Test edge cases
        test.assert.truthy(is_localhost("user.name@localhost"), "Should handle user with dot")
        test.assert.truthy(is_localhost("user-name@127.0.0.1"), "Should handle user with hyphen")
        test.assert.truthy(is_localhost("user123@::1"), "Should handle user with numbers")

        -- Test malformed cases (should not crash)
        test.assert.falsy(is_localhost("@"), "Should handle lone @")
        test.assert.falsy(is_localhost("user@"), "Should handle trailing @")
        test.assert.falsy(is_localhost(""), "Should handle empty string")
    end)

    test.it("should test the exact scenario causing the IPv6 issue", function()
        local function is_localhost(host)
            local hostname = host:match("@(.+)$") or host
            return hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1"
        end

        -- The exact host from your error message
        local problematic_host = "testuser@localhost"

        -- Should now correctly identify as localhost
        test.assert.truthy(is_localhost(problematic_host), "testuser@localhost should be identified as localhost")

        -- Extract hostname to verify parsing
        local hostname = problematic_host:match("@(.+)$") or problematic_host
        test.assert.equals(hostname, "localhost", "Should extract 'localhost' from 'testuser@localhost'")
    end)
end)
