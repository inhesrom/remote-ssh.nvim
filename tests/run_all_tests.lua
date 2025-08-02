#!/usr/bin/env lua
-- Comprehensive test runner for remote-gitsigns
-- Runs all test suites and provides summary

local function run_test_suite(name, module_path)
    io.write(string.format('Running %s... ', name))
    io.flush()

    local start_time = os.clock()
    local success, test_module = pcall(require, module_path)

    if not success then
        print('✗ FAIL: Could not load test module: ' .. tostring(test_module))
        return false, 0
    end

    -- Find the main test function
    local test_function_name = 'run_' .. module_path:gsub('tests%.', ''):gsub('_tests', '_tests')
    local test_function = test_module[test_function_name]

    if not test_function then
        -- Try alternative naming patterns
        for k, v in pairs(test_module) do
            if type(v) == 'function' and k:match('run.*test') then
                test_function = v
                break
            end
        end
    end

    if not test_function then
        print('✗ FAIL: Could not find test function')
        return false, 0
    end

    local test_success, result = pcall(test_function)
    local duration = os.clock() - start_time

    if test_success and result then
        print(string.format('✓ PASS (%.2fs)', duration))
        return true, duration
    else
        print(string.format('✗ FAIL (%.2fs): %s', duration, tostring(result)))
        return false, duration
    end
end

local function run_all_tests()
    print('=== Remote Gitsigns Comprehensive Test Suite ===\n')

    local test_suites = {
        { name = 'Unit Tests', module = 'tests.remote_gitsigns_spec' },
        { name = 'Edge Cases & Error Handling', module = 'tests.edge_case_tests' },
        { name = 'Performance & Caching', module = 'tests.performance_tests' },
        { name = 'Gitsigns Compatibility', module = 'tests.gitsigns_compatibility_tests' },
        { name = 'Concurrent Operations', module = 'tests.concurrent_operations_tests' },
        { name = 'Configuration Validation', module = 'tests.configuration_validation_tests' }
    }

    -- Integration tests require special handling
    local integration_available = os.getenv('REMOTE_GITSIGNS_ENABLE_SSH_TESTS') == '1'
    if integration_available then
        table.insert(test_suites, 2, { name = 'Integration Tests (SSH)', module = 'tests.integration_tests' })
    end

    local results = {}
    local total_duration = 0
    local passed_count = 0

    for _, suite in ipairs(test_suites) do
        local success, duration = run_test_suite(suite.name, suite.module)
        table.insert(results, {
            name = suite.name,
            success = success,
            duration = duration
        })
        total_duration = total_duration + duration
        if success then
            passed_count = passed_count + 1
        end
    end

    print('\n=== Test Results Summary ===')

    for _, result in ipairs(results) do
        local status = result.success and '✓ PASS' or '✗ FAIL'
        print(string.format('%-30s %s (%.2fs)', result.name, status, result.duration))
    end

    print(string.format('\nOverall: %d/%d test suites passed', passed_count, #test_suites))
    print(string.format('Total time: %.2fs', total_duration))

    if not integration_available then
        print('\nNote: Integration tests skipped. Set REMOTE_GITSIGNS_ENABLE_SSH_TESTS=1 to run them.')
    end

    local all_passed = passed_count == #test_suites

    if all_passed then
        print('\n🎉 All test suites passed! Remote gitsigns is ready for production use.')
        print('\nTest Coverage:')
        print('  ✓ Unit functionality and module integration')
        print('  ✓ Edge cases and error handling')
        print('  ✓ Performance and caching behavior')
        print('  ✓ Gitsigns compatibility across versions')
        print('  ✓ Concurrent operations and resource management')
        print('  ✓ Configuration validation and edge cases')
        if integration_available then
            print('  ✓ Real SSH integration scenarios')
        end

        print('\nYour remote-ssh.nvim plugin now has comprehensive gitsigns support!')
        return true
    else
        print(string.format('\n❌ %d test suite(s) failed. Please review the failures above.', #test_suites - passed_count))
        return false
    end
end

-- Check if we're running with the required package path
local function setup_test_environment()
    -- Ensure we can find our modules
    package.path = './lua/?.lua;./lua/?/init.lua;./tests/?.lua;' .. package.path

    -- Check if core modules are accessible
    local test_modules = {
        'remote-gitsigns.cache',
        'remote-gitsigns.remote-git',
        'remote-gitsigns.git-adapter',
        'remote-gitsigns.buffer-detector',
        'remote-gitsigns.init'
    }

    for _, module in ipairs(test_modules) do
        local ok = pcall(function()
            local f = loadfile('./lua/' .. module:gsub('%.', '/') .. '.lua')
            if not f then error('Module not found') end
        end)

        if not ok then
            print('ERROR: Cannot find module: ' .. module)
            print('Please run this script from the remote-ssh.nvim root directory.')
            return false
        end
    end

    return true
end

-- Main execution
if not setup_test_environment() then
    os.exit(1)
end

local success = run_all_tests()
os.exit(success and 0 or 1)