-- Test cases for root directory detection
local test = require('tests.init')
local mocks = require('tests.mocks')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'
local utils = require('remote-lsp.utils')
local config = require('remote-lsp.config')

test.describe("Root Directory Detection", function()
    test.setup(function()
        -- Enable SSH mocking
        mocks.ssh_mock.enable()
        mocks.mock_shellescape()

        -- Setup default config for testing
        config.config = {
            fast_root_detection = false,
            root_cache_enabled = false, -- Disable cache for testing
            max_root_search_depth = 10,
            server_root_detection = {
                rust_analyzer = { fast_mode = false },
                clangd = { fast_mode = false }
            }
        }
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.restore_shellescape()
        mocks.ssh_mock.clear()
        mocks.mock_fs.clear()
    end)

    test.it("should find Rust workspace root with .git and Cargo.toml", function()
        -- Setup Rust workspace structure
        mocks.create_project_structure(mocks.project_fixtures.rust_workspace)

        -- Mock SSH responses for directory checks
        mocks.ssh_mock.set_response("ssh .* 'cd .*/crate1/src.*ls %-la", "")
        mocks.ssh_mock.set_response("ssh .* 'cd .*/crate1.*ls %-la", "")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e %.git %].*echo 'FOUND:%.git'", "FOUND:.git")

        local root = utils.find_project_root("testhost", "/project/crate1/src/main.rs",
            {"Cargo.toml", ".git"}, "rust_analyzer")

        test.assert.equals(root, "/project")
    end)

    test.it("should prioritize compile_commands.json for clangd", function()
        -- Setup C++ project structure
        mocks.create_project_structure(mocks.project_fixtures.cpp_cmake)

        -- Mock SSH responses - compile_commands.json should be found first
        mocks.ssh_mock.set_response("ssh .* 'cd .*/src.*'.*%[ %-e compile_commands%.json %].*echo 'FOUND:compile_commands%.json'", "FOUND:compile_commands.json")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e %.git %].*echo 'FOUND:%.git'", "FOUND:.git")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e CMakeLists%.txt %].*echo 'FOUND:CMakeLists%.txt'", "FOUND:CMakeLists.txt")

        local root = utils.find_project_root("testhost", "/project/src/main.cpp",
            {".git", "compile_commands.json", "CMakeLists.txt"}, "clangd")

        test.assert.equals(root, "/project")

        -- Verify that compile_commands.json was checked first in the batch command
        local call_log = mocks.ssh_mock.get_call_log()
        local batch_call = nil
        for _, call in ipairs(call_log) do
            if call:match("compile_commands%.json.*%.git") then
                batch_call = call
                break
            end
        end
        test.assert.truthy(batch_call, "Should have made a batch call with compile_commands.json first")
    end)

    test.it("should handle path normalization correctly", function()
        -- Test with double slashes in path
        mocks.ssh_mock.set_response("ssh .* 'cd .*/project.*'.*%[ %-e %.git %].*echo 'FOUND:%.git'", "FOUND:.git")

        local root = utils.find_project_root("testhost", "//project//file.rs",
            {".git"}, "rust_analyzer")

        test.assert.equals(root, "/project")
    end)

    test.it("should use file directory when no root markers found", function()
        -- Mock SSH responses with no matches
        mocks.ssh_mock.set_response("ssh .*", "")

        local root = utils.find_project_root("testhost", "/some/deep/path/file.py",
            {"pyproject.toml", ".git"}, "pyright")

        test.assert.equals(root, "/some/deep/path")
    end)

    test.it("should stop at filesystem root", function()
        -- Mock SSH responses with no matches and verify we don't go past root
        mocks.ssh_mock.set_response("ssh .*", "")

        local root = utils.find_project_root("testhost", "/file.py",
            {"pyproject.toml", ".git"}, "pyright")

        test.assert.equals(root, "/")

        -- Check that we don't make calls above the root directory
        local call_log = mocks.ssh_mock.get_call_log()
        local has_empty_path = false
        for _, call in ipairs(call_log) do
            if call:match("'cd ''") or call:match("'cd '/'") then
                has_empty_path = true
                break
            end
        end
        test.assert.falsy(has_empty_path, "Should not attempt to search above filesystem root")
    end)

    test.it("should cache results when enabled", function()
        -- Enable cache for this test
        config.config.root_cache_enabled = true
        config.config.root_cache_ttl = 300

        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e %.git %].*echo 'FOUND:%.git'", "FOUND:.git")

        -- First call should make SSH calls
        local root1 = utils.find_project_root("testhost", "/project/file.py",
            {".git"}, "pyright")
        local first_call_count = #mocks.ssh_mock.get_call_log()

        -- Second call should use cache (no additional SSH calls)
        local root2 = utils.find_project_root("testhost", "/project/file.py",
            {".git"}, "pyright")
        local second_call_count = #mocks.ssh_mock.get_call_log()

        test.assert.equals(root1, root2)
        test.assert.equals(first_call_count, second_call_count,
            "Second call should not make additional SSH calls (cache hit)")

        -- Cleanup
        utils.clear_project_root_cache()
        config.config.root_cache_enabled = false
    end)

    test.it("should handle Rust workspace detection correctly", function()
        -- Mock responses for Rust workspace detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*/crate1.*ls %-la %.git", "drwxr-xr-x  8 user user 4096 Jan 1 12:00 .git")
        mocks.ssh_mock.set_response("ssh .* 'cd .*/crate1.*ls %-la Cargo%.toml", "")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*ls %-la %.git", "drwxr-xr-x  8 user user 4096 Jan 1 12:00 .git")
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*ls %-la Cargo%.toml", "-rw-r--r--  1 user user  123 Jan 1 12:00 Cargo.toml")

        local root = utils.find_project_root("testhost", "/workspace/crate1/src/lib.rs",
            {"Cargo.toml", ".git"}, "rust_analyzer")

        test.assert.equals(root, "/workspace")
    end)
end)

test.describe("Fast Root Detection", function()
    test.setup(function()
        config.config = {
            fast_root_detection = true,
            root_cache_enabled = false
        }
    end)

    test.it("should use file directory in fast mode", function()
        local root = utils.find_project_root_fast("testhost", "/some/path/file.rs",
            {"Cargo.toml", ".git"})

        test.assert.equals(root, "/some/path")
    end)

    test.it("should handle relative paths in fast mode", function()
        local root = utils.find_project_root_fast("testhost", "relative/path/file.rs",
            {"Cargo.toml", ".git"})

        test.assert.equals(root, "/relative/path")
    end)
end)

test.describe("Server-specific Root Detection Settings", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        mocks.mock_shellescape()

        config.config = {
            fast_root_detection = true, -- Default to fast mode
            root_cache_enabled = false,
            server_root_detection = {
                rust_analyzer = { fast_mode = false }, -- Override for rust-analyzer
                clangd = { fast_mode = false }         -- Override for clangd
            }
        }
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.restore_shellescape()
        mocks.ssh_mock.clear()
    end)

    test.it("should respect server-specific fast mode override", function()
        -- Mock a successful root detection
        mocks.ssh_mock.set_response("ssh .* 'cd .*'.*%[ %-e Cargo%.toml %].*echo 'FOUND:Cargo%.toml'", "FOUND:Cargo.toml")

        -- This should use standard detection despite global fast mode being true
        local root = utils.find_project_root("testhost", "/project/src/main.rs",
            {"Cargo.toml"}, "rust_analyzer")

        -- Should have made SSH calls (not fast mode)
        local call_log = mocks.ssh_mock.get_call_log()
        test.assert.truthy(#call_log > 0, "Should have made SSH calls for rust_analyzer despite fast mode default")
    end)
end)
