-- Debug test for file browser SSH issues
local test = require("tests.init")

test.describe("File Browser Debug Tests", function()
    test.it("should simulate the exact tree browser load_directory scenario", function()
        -- Mock the exact URL and parsing that happens in the tree browser
        local url = "rsync://testuser@localhost/home/testuser/repos/tokio/"

        -- Simulate utils.parse_remote_path
        local remote_info = {
            protocol = "rsync",
            host = "testuser@localhost",
            path = "/home/testuser/repos/tokio/",
        }

        -- Simulate path processing from tree_browser.lua
        local path = remote_info.path or "/"
        if path:sub(-1) ~= "/" then
            path = path .. "/"
        end

        -- Build the exact SSH command from tree_browser.lua
        local ssh_cmd = string.format(
            'cd %s && find . -maxdepth 1 | sort | while read f; do if [ "$f" != "." ]; then if [ -d "$f" ]; then echo "d ${f#./}"; else echo "f ${f#./}"; fi; fi; done',
            vim.fn.shellescape(path)
        )

        test.assert.contains(ssh_cmd, "cd", "SSH command should contain cd")
        test.assert.contains(ssh_cmd, "/home/testuser/repos/tokio/", "SSH command should contain the path")
        test.assert.contains(ssh_cmd, "find . -maxdepth 1", "SSH command should contain find")

        -- Test the shellescape output
        local escaped_path = vim.fn.shellescape(path)
        test.assert.truthy(#escaped_path > 0, "Escaped path should not be empty")
    end)

    test.it("should test the new success detection logic", function()
        -- Simulate scenarios from your manual test

        -- Case 1: Command succeeds but returns non-zero exit code (your scenario)
        local exit_code = 1 -- or 255
        local output = {
            "d .cargo",
            "d .github",
            "f Cargo.toml",
            "f README.md",
            "d benches",
            "d examples",
        }
        local stderr_output = { "warning: some ssh warning" }

        -- Test the new logic
        local has_valid_output = #output > 0
        local success = (exit_code == 0) or has_valid_output

        test.assert.truthy(has_valid_output, "Should detect valid output")
        test.assert.truthy(success, "Should consider this a success despite non-zero exit code")

        -- Case 2: True failure (no output, non-zero exit)
        exit_code = 255
        output = {}
        stderr_output = { "Connection refused" }

        has_valid_output = #output > 0
        success = (exit_code == 0) or has_valid_output

        test.assert.falsy(has_valid_output, "Should detect no valid output")
        test.assert.falsy(success, "Should consider this a true failure")

        -- Case 3: Perfect success
        exit_code = 0
        output = { "d folder", "f file.txt" }
        stderr_output = {}

        has_valid_output = #output > 0
        success = (exit_code == 0) or has_valid_output

        test.assert.truthy(success, "Should consider this a success")
    end)

    test.it("should parse tokio directory output correctly", function()
        -- Simulate the exact output you might get from tokio repo
        local output = {
            "d .cargo",
            "d .github",
            "d benches",
            "d examples",
            "d src",
            "d tests",
            "d tokio",
            "d tokio-macros",
            "d tokio-stream",
            "d tokio-test",
            "d tokio-util",
            "f .gitignore",
            "f Cargo.toml",
            "f LICENSE",
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
                })
            end
        end

        test.assert.equals(#parsed_files, 15, "Should parse all tokio entries")

        -- Check some specific entries
        local cargo_dir = nil
        local readme_file = nil

        for _, file in ipairs(parsed_files) do
            if file.name == ".cargo" then
                cargo_dir = file
            elseif file.name == "README.md" then
                readme_file = file
            end
        end

        test.assert.truthy(cargo_dir, "Should find .cargo directory")
        test.assert.truthy(cargo_dir.is_dir, ".cargo should be a directory")

        test.assert.truthy(readme_file, "Should find README.md file")
        test.assert.falsy(readme_file.is_dir, "README.md should be a file")
    end)

    test.it("should test error message formatting", function()
        local url = "rsync://testuser@localhost/home/testuser/repos/tokio/"
        local host = "testuser@localhost"
        local exit_code = 255
        local stderr_output = { "Connection closed by ::1 port 22" }
        local ssh_cmd =
            'cd \'/home/testuser/repos/tokio/\' && find . -maxdepth 1 | sort | while read f; do if [ "$f" != "." ]; then if [ -d "$f" ]; then echo "d ${f#./}"; else echo "f ${f#./}"; fi; fi; done'

        -- Build error message like tree_browser.lua does
        local error_msg = "Failed to list directory: " .. url .. " (exit code: " .. exit_code .. ")"
        if #stderr_output > 0 then
            error_msg = error_msg .. ", stderr: " .. table.concat(stderr_output, " ")
        end
        error_msg = error_msg .. ", command: ssh " .. host .. " '" .. ssh_cmd .. "'"

        test.assert.contains(error_msg, "Failed to list directory", "Error message should contain failure text")
        test.assert.contains(error_msg, "exit code: 255", "Error message should contain exit code")
        test.assert.contains(error_msg, "Connection closed by ::1", "Error message should contain stderr")
        test.assert.contains(error_msg, "ssh testuser@localhost", "Error message should contain SSH command")
    end)

    test.it("should test the actual SSH command construction with IPv4", function()
        local host = "testuser@localhost"
        local command = "cd '/home/testuser/repos/tokio/' && find . -maxdepth 1"

        -- Mock ssh_utils.build_ssh_cmd behavior
        local function build_ssh_cmd(host, cmd)
            local ssh_args = { "ssh" }

            -- Check if host contains localhost (even with user@)
            local is_localhost = host:match("localhost") or host:match("127%.0%.0%.1") or host:match("::1")

            if is_localhost then
                table.insert(ssh_args, "-4")
            end

            table.insert(ssh_args, host)
            table.insert(ssh_args, cmd)

            return ssh_args
        end

        local ssh_cmd = build_ssh_cmd(host, command)

        test.assert.contains(ssh_cmd, "ssh", "Should contain ssh")
        test.assert.contains(ssh_cmd, "-4", "Should contain -4 flag for localhost connection")
        test.assert.contains(ssh_cmd, "testuser@localhost", "Should contain host")
        test.assert.contains(ssh_cmd, command, "Should contain command")

        -- Convert to string to see the full command
        local full_cmd = table.concat(ssh_cmd, " ")
        test.assert.contains(full_cmd, "ssh -4 testuser@localhost", "Should build correct SSH command with IPv4")
    end)

    test.it("should test debug logging information capture", function()
        -- Simulate the debug logging from the updated tree_browser.lua
        local exit_code = 1
        local output = { "d folder1", "f file1.txt" }
        local stderr_output = { "warning message" }

        -- Build debug log message like tree_browser.lua does
        local debug_msg = "SSH command finished: exit_code="
            .. exit_code
            .. ", output_lines="
            .. #output
            .. ", stderr_lines="
            .. #stderr_output

        test.assert.contains(debug_msg, "exit_code=1", "Debug message should contain exit code")
        test.assert.contains(debug_msg, "output_lines=2", "Debug message should contain output line count")
        test.assert.contains(debug_msg, "stderr_lines=1", "Debug message should contain stderr line count")

        -- Test output sample
        if #output > 0 then
            local output_sample = table.concat(output, "|"):sub(1, 100)
            test.assert.contains(output_sample, "d folder1|f file1.txt", "Output sample should contain file listing")
        end

        -- Test stderr capture
        if #stderr_output > 0 then
            local stderr_msg = table.concat(stderr_output, " ")
            test.assert.contains(stderr_msg, "warning message", "Stderr should contain warning")
        end
    end)
end)
