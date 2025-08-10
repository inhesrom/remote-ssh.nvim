-- Test framework for remote-ssh.nvim
local M = {}

-- Simple test assertion framework
M.assert = {}

function M.assert.equals(actual, expected, message)
    if actual ~= expected then
        error(
            string.format(
                "Assertion failed: %s\nExpected: %s\nActual: %s",
                message or "values should be equal",
                vim.inspect(expected),
                vim.inspect(actual)
            )
        )
    end
end

function M.assert.truthy(value, message)
    if not value then
        error(
            string.format(
                "Assertion failed: %s\nValue should be truthy but was: %s",
                message or "value should be truthy",
                vim.inspect(value)
            )
        )
    end
end

function M.assert.falsy(value, message)
    if value then
        error(
            string.format(
                "Assertion failed: %s\nValue should be falsy but was: %s",
                message or "value should be falsy",
                vim.inspect(value)
            )
        )
    end
end

function M.assert.contains(table_or_string, value, message)
    local contains = false

    if type(table_or_string) == "string" then
        -- For string searching
        contains = table_or_string:find(value, 1, true) ~= nil
    elseif type(table_or_string) == "table" then
        -- For table searching
        for _, v in ipairs(table_or_string) do
            if type(v) == "string" and v:find(value, 1, true) then
                contains = true
                break
            elseif v == value then
                contains = true
                break
            end
        end
    end

    if not contains then
        error(
            string.format(
                "Assertion failed: %s\nShould contain: %s\nActual: %s",
                message or "should contain value",
                vim.inspect(value),
                vim.inspect(table_or_string)
            )
        )
    end
end

-- Test runner
M.tests = {}
M.results = {}

function M.describe(name, func)
    local test_group = {
        name = name,
        tests = {},
        setup = nil,
        teardown = nil,
    }

    local old_it = M.it
    local old_setup = M.setup
    local old_teardown = M.teardown

    M.it = function(test_name, test_func)
        table.insert(test_group.tests, {
            name = test_name,
            func = test_func,
        })
    end

    M.setup = function(setup_func)
        test_group.setup = setup_func
    end

    M.teardown = function(teardown_func)
        test_group.teardown = teardown_func
    end

    local success, err = pcall(func)
    if not success then
        print("Error in describe block '" .. name .. "': " .. err)
    end

    M.it = old_it
    M.setup = old_setup
    M.teardown = old_teardown

    table.insert(M.tests, test_group)
end

function M.it(name, func)
    -- This is used outside of describe blocks
    table.insert(M.tests, {
        name = name,
        tests = { { name = name, func = func } },
        setup = nil,
        teardown = nil,
    })
end

function M.setup(func)
    -- Global setup function
    M.global_setup = func
end

function M.teardown(func)
    -- Global teardown function
    M.global_teardown = func
end

function M.run_tests()
    M.results = {
        passed = 0,
        failed = 0,
        errors = {},
    }

    print("Running tests...")

    -- Run global setup
    if M.global_setup then
        M.global_setup()
    end

    for _, test_group in ipairs(M.tests) do
        print(string.format("\n--- %s ---", test_group.name))

        for _, test in ipairs(test_group.tests) do
            local success, error_msg = pcall(function()
                -- Run group setup
                if test_group.setup then
                    test_group.setup()
                end

                -- Run the test
                test.func()

                -- Run group teardown
                if test_group.teardown then
                    test_group.teardown()
                end
            end)

            if success then
                print(string.format("✅ %s", test.name))
                M.results.passed = M.results.passed + 1
            else
                print(string.format("❌ %s", test.name))
                print(string.format("  Error: %s", error_msg))
                M.results.failed = M.results.failed + 1
                table.insert(M.results.errors, {
                    test = test.name,
                    group = test_group.name,
                    error = error_msg,
                })
            end
        end
    end

    -- Run global teardown
    if M.global_teardown then
        M.global_teardown()
    end

    print(string.format("\n--- Results ---"))
    print(string.format("✅ Passed: %d", M.results.passed))
    print(string.format("❌ Failed: %d", M.results.failed))
    print(string.format("Total: %d", M.results.passed + M.results.failed))

    if M.results.failed > 0 then
        print("\n❌ Failed tests:")
        for _, error_info in ipairs(M.results.errors) do
            print(string.format("  %s > %s: %s", error_info.group, error_info.test, error_info.error))
        end
    end

    return M.results.failed == 0
end

return M
