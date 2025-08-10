-- Test to prevent deprecated API usage in the codebase
local test = require("tests.init")

-- Add the plugin to path for testing
package.path = package.path .. ";lua/?.lua"

-- List of deprecated statements to check for
local DEPRECATED_PATTERNS = {
    {
        pattern = "vim%.lsp%.get_active_clients",
        replacement = "vim.lsp.get_clients",
        description = "Use vim.lsp.get_clients() instead of deprecated vim.lsp.get_active_clients()",
    },
    -- Add more deprecated patterns here as needed:
    -- {
    --     pattern = "some_deprecated_function",
    --     replacement = "new_function",
    --     description = "Use new_function() instead of deprecated some_deprecated_function()"
    -- }
}

-- Directories to scan for Lua files
local SCAN_DIRECTORIES = {
    "lua/",
    "tests/",
}

-- Files to exclude from scanning (if any)
local EXCLUDE_FILES = {
    "tests/test_deprecated_api.lua", -- Exclude this test file itself
    "tests/test_deprecated_api_detection.lua", -- Exclude the detection verification test
}

local function file_exists(filepath)
    local file = io.open(filepath, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function read_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function is_excluded_file(filepath)
    for _, excluded in ipairs(EXCLUDE_FILES) do
        if filepath:match(excluded .. "$") then
            return true
        end
    end
    return false
end

local function find_lua_files(directory)
    local files = {}

    -- Simple recursive file finder using shell command
    local handle = io.popen("find " .. directory .. " -name '*.lua' 2>/dev/null")
    if handle then
        for line in handle:lines() do
            if not is_excluded_file(line) then
                table.insert(files, line)
            end
        end
        handle:close()
    end

    return files
end

local function scan_file_for_deprecated(filepath, content)
    local violations = {}

    for _, deprecated in ipairs(DEPRECATED_PATTERNS) do
        local line_num = 1
        for line in content:gmatch("[^\r\n]+") do
            if line:match(deprecated.pattern) then
                table.insert(violations, {
                    file = filepath,
                    line = line_num,
                    content = line:match("^%s*(.-)%s*$"), -- trim whitespace
                    pattern = deprecated.pattern,
                    replacement = deprecated.replacement,
                    description = deprecated.description,
                })
            end
            line_num = line_num + 1
        end
    end

    return violations
end

test.describe("Deprecated API Usage Tests", function()
    test.it("should not contain any deprecated API calls", function()
        local all_violations = {}
        local scanned_files = 0

        -- Scan all specified directories
        for _, directory in ipairs(SCAN_DIRECTORIES) do
            local lua_files = find_lua_files(directory)

            for _, filepath in ipairs(lua_files) do
                if file_exists(filepath) then
                    scanned_files = scanned_files + 1
                    local content = read_file(filepath)
                    if content then
                        local violations = scan_file_for_deprecated(filepath, content)
                        for _, violation in ipairs(violations) do
                            table.insert(all_violations, violation)
                        end
                    end
                end
            end
        end

        -- Print summary of scan
        print(string.format("Scanned %d Lua files for deprecated API usage", scanned_files))

        -- If violations found, print detailed report and fail
        if #all_violations > 0 then
            print("\n❌ DEPRECATED API USAGE FOUND:")
            print("=" .. string.rep("=", 50))

            for _, violation in ipairs(all_violations) do
                print(string.format("\nFile: %s:%d", violation.file, violation.line))
                print(string.format("Found: %s", violation.pattern))
                print(string.format("Line: %s", violation.content))
                print(string.format("Fix: %s", violation.description))
                print("-" .. string.rep("-", 50))
            end

            print(string.format("\nTotal violations: %d", #all_violations))
            print("Please update the code to use the modern APIs before proceeding.")

            test.assert.equals(#all_violations, 0, "Found deprecated API usage - see details above")
        else
            print("✅ No deprecated API usage found - all good!")
        end
    end)
end)
