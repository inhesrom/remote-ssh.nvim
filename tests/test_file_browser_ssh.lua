-- Test file browser SSH functionality
local test = require("tests.init")

-- Mock ssh_utils functions for testing
local ssh_utils = {}

ssh_utils.is_localhost = function(host)
    return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

ssh_utils.build_ssh_cmd = function(host, command)
    local ssh_args = { "ssh" }

    -- Add IPv4 preference for localhost connections to avoid IPv6 issues
    if ssh_utils.is_localhost(host) then
        table.insert(ssh_args, "-4")
    end

    table.insert(ssh_args, host)
    table.insert(ssh_args, command)

    return ssh_args
end

ssh_utils.build_scp_cmd = function(source, destination, options)
    local scp_args = { "scp" }

    -- Add standard options
    if options then
        for _, opt in ipairs(options) do
            table.insert(scp_args, opt)
        end
    end

    -- Extract host from source or destination to check for localhost
    local host = nil
    if source:match("^[^:]+:") then
        host = source:match("^([^:]+):")
    elseif destination:match("^[^:]+:") then
        host = destination:match("^([^:]+):")
    end

    -- Add IPv4 preference for localhost connections
    if host and ssh_utils.is_localhost(host) then
        table.insert(scp_args, "-4")
    end

    table.insert(scp_args, source)
    table.insert(scp_args, destination)

    return scp_args
end

test.describe("File Browser SSH Commands", function()
    test.it("should build SSH commands correctly for localhost", function()
        local host = "localhost"
        local command = "cd /test && find . -maxdepth 1"

        local ssh_cmd = ssh_utils.build_ssh_cmd(host, command)

        -- Should include -4 flag for localhost
        test.assert.contains(ssh_cmd, "ssh", "SSH command should contain ssh")
        test.assert.contains(ssh_cmd, "-4", "SSH command should contain -4 flag for localhost")
        test.assert.contains(ssh_cmd, "localhost", "SSH command should contain localhost")
        test.assert.contains(ssh_cmd, command, "SSH command should contain the command")
    end)

    test.it("should build SSH commands correctly for remote hosts", function()
        local host = "remote.server.com"
        local command = "cd /test && find . -maxdepth 1"

        local ssh_cmd = ssh_utils.build_ssh_cmd(host, command)

        -- Should NOT include -4 flag for remote hosts
        test.assert.contains(ssh_cmd, "ssh", "SSH command should contain ssh")
        test.assert.contains(ssh_cmd, "remote.server.com", "SSH command should contain remote host")
        test.assert.contains(ssh_cmd, command, "SSH command should contain the command")

        -- Convert to string to check for -4 flag absence
        local cmd_str = table.concat(ssh_cmd, " ")
        test.assert.falsy(cmd_str:find(" -4 "), "SSH command should NOT contain -4 flag for remote hosts")
    end)

    test.it("should detect localhost variations correctly", function()
        test.assert.truthy(ssh_utils.is_localhost("localhost"), "Should detect localhost")
        test.assert.truthy(ssh_utils.is_localhost("127.0.0.1"), "Should detect 127.0.0.1")
        test.assert.truthy(ssh_utils.is_localhost("::1"), "Should detect ::1")
        test.assert.falsy(ssh_utils.is_localhost("remote.server.com"), "Should not detect remote host as localhost")
        test.assert.falsy(ssh_utils.is_localhost("192.168.1.100"), "Should not detect other IP as localhost")
    end)

    test.it("should parse directory listing output correctly", function()
        local output = {
            "d folder1",
            "f file1.txt",
            "d folder2",
            "f file2.py",
            "d .hidden",
            "f README.md",
        }

        local parsed_files = {}
        for _, line in ipairs(output) do
            local file_type, name = line:match("^([df])%s+(.+)$")
            if file_type and name and name ~= "." and name ~= ".." then
                local is_dir = (file_type == "d")
                table.insert(parsed_files, {
                    name = name,
                    is_dir = is_dir,
                    type = file_type,
                })
            end
        end

        test.assert.equals(#parsed_files, 6, "Should parse all 6 entries")

        -- Check specific entries
        test.assert.equals(parsed_files[1].name, "folder1", "First entry should be folder1")
        test.assert.truthy(parsed_files[1].is_dir, "folder1 should be a directory")

        test.assert.equals(parsed_files[2].name, "file1.txt", "Second entry should be file1.txt")
        test.assert.falsy(parsed_files[2].is_dir, "file1.txt should be a file")
    end)

    test.it("should handle malformed directory listing output", function()
        local output = {
            "d folder1",
            "invalid line",
            "f file1.txt",
            "",
            "x unknown_type",
            "d folder2",
        }

        local parsed_files = {}
        for _, line in ipairs(output) do
            local file_type, name = line:match("^([df])%s+(.+)$")
            if file_type and name and name ~= "." and name ~= ".." then
                table.insert(parsed_files, {
                    name = name,
                    is_dir = (file_type == "d"),
                })
            end
        end

        -- Should only parse valid entries
        test.assert.equals(#parsed_files, 3, "Should parse only valid entries")
        test.assert.equals(parsed_files[1].name, "folder1", "Should parse folder1")
        test.assert.equals(parsed_files[2].name, "file1.txt", "Should parse file1.txt")
        test.assert.equals(parsed_files[3].name, "folder2", "Should parse folder2")
    end)

    test.it("should construct directory listing command correctly", function()
        local path = "/home/user/test/"
        local escaped_path = vim.fn.shellescape(path)

        local ssh_cmd = string.format(
            'cd %s && find . -maxdepth 1 | sort | while read f; do if [ "$f" != "." ]; then if [ -d "$f" ]; then echo "d ${f#./}"; else echo "f ${f#./}"; fi; fi; done',
            escaped_path
        )

        test.assert.contains(ssh_cmd, "cd", "Command should contain cd")
        test.assert.contains(ssh_cmd, "find", "Command should contain find")
        test.assert.contains(ssh_cmd, "-maxdepth 1", "Command should contain maxdepth limit")
        test.assert.contains(ssh_cmd, "sort", "Command should contain sort")
        test.assert.contains(ssh_cmd, "while read", "Command should contain while loop")
        test.assert.contains(ssh_cmd, 'echo "d', "Command should output directory marker")
        test.assert.contains(ssh_cmd, 'echo "f', "Command should output file marker")
    end)

    test.it("should handle exit codes and output correctly", function()
        -- Test successful case (exit code 0, has output)
        local exit_code = 0
        local output = { "d folder1", "f file1.txt" }
        local stderr_output = {}

        local has_valid_output = #output > 0
        local success = (exit_code == 0) or has_valid_output

        test.assert.truthy(success, "Should succeed with exit code 0 and output")

        -- Test successful case (exit code non-zero, but has output)
        exit_code = 1
        output = { "d folder1", "f file1.txt" }
        stderr_output = { "some warning" }

        has_valid_output = #output > 0
        success = (exit_code == 0) or has_valid_output

        test.assert.truthy(success, "Should succeed with non-zero exit code but valid output")

        -- Test failure case (exit code non-zero, no output)
        exit_code = 255
        output = {}
        stderr_output = { "Connection refused" }

        has_valid_output = #output > 0
        success = (exit_code == 0) or has_valid_output

        test.assert.falsy(success, "Should fail with non-zero exit code and no output")
    end)

    test.it("should handle path escaping correctly", function()
        local test_paths = {
            "/simple/path",
            "/path with spaces/",
            "/path/with'quotes/",
            '/path/with"double quotes"/',
            "/path/with (parentheses)/",
            "/path/with&special&chars/",
        }

        for _, path in ipairs(test_paths) do
            local escaped_path = vim.fn.shellescape(path)

            -- Should not be empty
            test.assert.truthy(#escaped_path > 0, "Escaped path should not be empty for: " .. path)

            -- Should contain the original path content in some form
            local path_content = path:gsub("[^%w/]", "") -- Remove special chars for checking
            if #path_content > 3 then -- Only check if there's substantial content
                test.assert.contains(
                    escaped_path,
                    path_content:sub(1, 5),
                    "Escaped path should contain path content for: " .. path
                )
            end
        end
    end)

    test.it("should build SCP commands correctly", function()
        local source = "localhost:/home/user/file.txt"
        local destination = "/tmp/local_file.txt"
        local options = { "-q", "-p" }

        local scp_cmd = ssh_utils.build_scp_cmd(source, destination, options)

        test.assert.contains(scp_cmd, "scp", "SCP command should contain scp")
        test.assert.contains(scp_cmd, "-q", "SCP command should contain -q option")
        test.assert.contains(scp_cmd, "-p", "SCP command should contain -p option")
        test.assert.contains(scp_cmd, "-4", "SCP command should contain -4 for localhost")
        test.assert.contains(scp_cmd, source, "SCP command should contain source")
        test.assert.contains(scp_cmd, destination, "SCP command should contain destination")
    end)

    test.it("should handle empty or invalid outputs gracefully", function()
        local test_cases = {
            {}, -- Empty output
            { "" }, -- Single empty line
            { "", "", "" }, -- Multiple empty lines
            { " ", "  ", "\t" }, -- Whitespace only
        }

        for i, output in ipairs(test_cases) do
            local parsed_files = {}
            for _, line in ipairs(output) do
                if line and line ~= "" then
                    local file_type, name = line:match("^([df])%s+(.+)$")
                    if file_type and name and name ~= "." and name ~= ".." then
                        table.insert(parsed_files, { name = name, is_dir = (file_type == "d") })
                    end
                end
            end

            test.assert.equals(#parsed_files, 0, "Should handle empty/invalid output case " .. i)
        end
    end)
end)
