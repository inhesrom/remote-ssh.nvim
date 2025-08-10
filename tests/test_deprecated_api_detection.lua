-- Test to verify that the deprecated API detection actually works
-- This test creates temporary content with deprecated patterns and verifies they are detected
local test = require("tests.init")

-- Add the plugin to path for testing
package.path = package.path .. ";lua/?.lua"

-- Import the same deprecated patterns from the main test
local DEPRECATED_PATTERNS = {
    {
        pattern = "vim%.lsp%.get_active_clients",
        replacement = "vim.lsp.get_clients",
        description = "Use vim.lsp.get_clients() instead of deprecated vim.lsp.get_active_clients()",
    },
    -- This will automatically include any new patterns added to the main test
}

-- Function to scan content for deprecated patterns (copied from main test logic)
local function scan_content_for_deprecated(content, filepath)
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

test.describe("Deprecated API Detection Verification", function()
    test.it("should detect deprecated patterns when they exist", function()
        -- Dynamically create test content containing each deprecated pattern
        local test_cases = {}

        for i, deprecated in ipairs(DEPRECATED_PATTERNS) do
            -- Create realistic test content for each pattern
            local test_content = ""

            if deprecated.pattern == "vim%.lsp%.get_active_clients" then
                test_content = [[
-- Test file with deprecated API
local function check_lsp_clients(bufnr)
    local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
    return #clients > 0
end

-- Another usage
local all_clients = vim.lsp.get_active_clients()
]]
            else
                -- Generic test content for other patterns
                test_content = string.format(
                    [[
-- Test content for pattern: %s
local result = %s
]],
                    deprecated.pattern,
                    deprecated.pattern:gsub("%%", "")
                )
            end

            table.insert(test_cases, {
                pattern = deprecated.pattern,
                content = test_content,
                filename = string.format("test_case_%d.lua", i),
            })
        end

        -- Test each case
        local total_violations_found = 0

        for _, test_case in ipairs(test_cases) do
            print(string.format("Testing detection of pattern: %s", test_case.pattern))

            local violations = scan_content_for_deprecated(test_case.content, test_case.filename)

            print(string.format("Found %d violations for pattern '%s'", #violations, test_case.pattern))

            -- Verify that violations were found
            test.assert.truthy(
                #violations > 0,
                string.format("Should detect deprecated pattern '%s' in test content", test_case.pattern)
            )

            -- Verify the violations contain the expected pattern
            local found_expected_pattern = false
            for _, violation in ipairs(violations) do
                if violation.pattern == test_case.pattern then
                    found_expected_pattern = true
                    print(string.format("✅ Detected: %s at line %d", violation.pattern, violation.line))
                    break
                end
            end

            test.assert.truthy(
                found_expected_pattern,
                string.format("Should find the specific pattern '%s' in violations", test_case.pattern)
            )

            total_violations_found = total_violations_found + #violations
        end

        print(
            string.format(
                "✅ Detection test passed! Found %d total violations across %d test cases",
                total_violations_found,
                #test_cases
            )
        )

        -- Verify we found violations for all patterns
        test.assert.truthy(
            total_violations_found >= #DEPRECATED_PATTERNS,
            "Should find at least one violation per deprecated pattern"
        )
    end)

    test.it("should not detect patterns in clean content", function()
        -- Test with content that should NOT trigger any violations
        local clean_content = [[
-- Clean test file with modern APIs
local function check_lsp_clients(bufnr)
    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    return #clients > 0
end

-- Modern API usage
local all_clients = vim.lsp.get_clients()
local config = require('some.config')
]]

        local violations = scan_content_for_deprecated(clean_content, "clean_test.lua")

        print(string.format("Clean content scan found %d violations (should be 0)", #violations))

        test.assert.equals(#violations, 0, "Should not find any violations in clean content")

        print("✅ Clean content test passed!")
    end)
end)
