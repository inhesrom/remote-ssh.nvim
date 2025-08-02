-- Configuration validation tests for remote-gitsigns
-- Tests various configuration scenarios, validation, and edge cases

local function setup_config_environment()
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

    -- Mock vim
    _G.vim = {
        log = { levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 } },
        notify = function(msg, level)
            _G._vim_notifications = _G._vim_notifications or {}
            table.insert(_G._vim_notifications, {msg = msg, level = level})
            print('[NOTIFY] ' .. tostring(msg))
        end,
        tbl_deep_extend = function(behavior, ...)
            local result = {}
            for _, t in ipairs({...}) do
                if type(t) == 'table' then
                    for k, v in pairs(t) do
                        if type(v) == 'table' and type(result[k]) == 'table' and behavior == 'force' then
                            result[k] = vim.tbl_deep_extend(behavior, result[k], v)
                        else
                            result[k] = v
                        end
                    end
                end
            end
            return result
        end,
        deepcopy = function(t)
            if type(t) ~= 'table' then return t end
            local copy = {}
            for k, v in pairs(t) do copy[k] = vim.deepcopy(v) end
            return copy
        end,
        split = function(s, sep)
            local result = {}
            for part in string.gmatch(s .. sep, '([^' .. sep .. ']*)' .. sep) do
                if part ~= '' then table.insert(result, part) end
            end
            return result
        end,
        trim = function(s) return s:match('^%s*(.-)%s*$') end,
        startswith = function(s, prefix) return s:sub(1, #prefix) == prefix end,
        list_extend = function(dst, src)
            for _, item in ipairs(src) do table.insert(dst, item) end
            return dst
        end,
        fs = { dirname = function(path) return path:match('(.*/)[^/]*$') or '.' end },
        loop = { new_timer = function() return { start = function() end, stop = function() end } end },
        fn = { shellescape = function(s) return "'" .. s:gsub("'", "'\"'\"'") .. "'" end },
        defer_fn = function(fn, delay) fn() end,
        schedule = function(fn) fn() end,
        system = function(cmd, opts)
            return {
                wait = function()
                    return { code = 0, stdout = 'config test output', stderr = nil }
                end
            }
        end,
        api = {
            nvim_create_augroup = function(name, opts) return math.random(1000) end,
            nvim_create_autocmd = function(events, opts) return true end,
            nvim_create_user_command = function(name, fn, opts) return true end,
            nvim_get_current_buf = function() return 1 end,
            nvim_buf_is_valid = function(bufnr) return true end,
            nvim_buf_get_name = function(bufnr)
                return 'scp://config-test-host//test/config/repo/file.py'
            end,
            nvim_list_bufs = function() return {1, 2, 3} end,
        }
    }

    -- Mock dependencies
    package.loaded['logging'] = {
        log = function(msg, level, show_user, config)
            _G._log_messages = _G._log_messages or {}
            table.insert(_G._log_messages, {msg = msg, level = level, show_user = show_user})
        end
    }

    package.loaded['async-remote-write.utils'] = {
        parse_remote_path = function(path)
            if path:match('^scp://') then
                local host, remote_path = path:match('^scp://([^/]+)//(.+)$')
                if host and remote_path then
                    return { protocol = 'scp', host = host, path = '/' .. remote_path }
                end
            end
            return nil
        end
    }

    package.loaded['async-remote-write.ssh_utils'] = {
        build_ssh_cmd = function(host, command)
            return {'ssh', host, command}
        end
    }

    package.loaded['remote-buffer-metadata'] = {
        set = function(bufnr, namespace, key, value) end,
        get = function(bufnr, namespace, key) return nil end,
        clear_namespace = function(bufnr, namespace) end
    }

    -- Reset tracking variables
    _G._vim_notifications = {}
    _G._log_messages = {}
end

local function run_config_test(name, test_fn)
    io.write('Config Test: ' .. name .. '... ')
    io.flush()

    -- Reset tracking
    _G._vim_notifications = {}
    _G._log_messages = {}

    local success, error_msg = pcall(test_fn)

    if success then
        print('✓ PASS')
        return true
    else
        print('✗ FAIL: ' .. tostring(error_msg))
        return false
    end
end

local function run_configuration_validation_tests()
    print('=== Remote Gitsigns Configuration Validation Tests ===\n')

    setup_config_environment()

    local passed = 0
    local total = 0

    -- Test 1: Default Configuration
    total = total + 1
    if run_config_test('Default Configuration', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Setup with minimal config
        remote_gitsigns.setup({})

        local config = remote_gitsigns.get_config()

        -- Check default values
        assert(config.enabled == false, 'Should default to disabled')
        assert(type(config.git_timeout) == 'number', 'Should have default git timeout')
        assert(type(config.cache) == 'table', 'Should have cache config')
        assert(type(config.detection) == 'table', 'Should have detection config')
        assert(type(config.cache.enabled) == 'boolean', 'Cache enabled should be boolean')
        assert(type(config.cache.ttl) == 'number', 'Cache TTL should be number')
        assert(type(config.cache.max_entries) == 'number', 'Cache max_entries should be number')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 2: Valid Complete Configuration
    total = total + 1
    if run_config_test('Valid Complete Configuration', function()
        local remote_gitsigns = require('remote-gitsigns')

        local valid_config = {
            enabled = true,
            git_timeout = 15000,
            debug = true,
            auto_attach = true,
            cache = {
                enabled = true,
                ttl = 600,
                max_entries = 500,
                cleanup_interval = 120
            },
            detection = {
                async_detection = true,
                exclude_patterns = {
                    '*/%.git/*',
                    '*/node_modules/*',
                    '*/build/*'
                }
            }
        }

        remote_gitsigns.setup(valid_config)

        local config = remote_gitsigns.get_config()

        -- Verify all settings were applied
        assert(config.enabled == true, 'Should set enabled')
        assert(config.git_timeout == 15000, 'Should set git timeout')
        assert(config.debug == true, 'Should set debug')
        assert(config.auto_attach == true, 'Should set auto_attach')
        assert(config.cache.enabled == true, 'Should set cache enabled')
        assert(config.cache.ttl == 600, 'Should set cache TTL')
        assert(config.cache.max_entries == 500, 'Should set cache max entries')
        assert(config.detection.async_detection == true, 'Should set async detection')
        assert(#config.detection.exclude_patterns == 3, 'Should set exclude patterns')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 3: Invalid Configuration Types
    total = total + 1
    if run_config_test('Invalid Configuration Types', function()
        local remote_gitsigns = require('remote-gitsigns')

        local invalid_configs = {
            { enabled = 'not-boolean' },
            { git_timeout = 'not-number' },
            { debug = 123 },
            { auto_attach = 'yes' },
            { cache = 'not-table' },
            { detection = 'not-table' },
            { cache = { enabled = 'not-boolean' } },
            { cache = { ttl = 'not-number' } },
            { cache = { max_entries = 'not-number' } },
            { detection = { async_detection = 'not-boolean' } },
            { detection = { exclude_patterns = 'not-array' } }
        }

        for i, config in ipairs(invalid_configs) do
            -- Should either handle gracefully or provide warning
            local success = pcall(function()
                remote_gitsigns.setup(config)
                remote_gitsigns.shutdown()
            end)

            -- Should not crash on invalid config
            assert(success, 'Should handle invalid config gracefully (' .. i .. ')')
        end
    end) then
        passed = passed + 1
    end

    -- Test 4: Boundary Value Testing
    total = total + 1
    if run_config_test('Boundary Value Testing', function()
        local remote_gitsigns = require('remote-gitsigns')

        local boundary_configs = {
            { git_timeout = 0 }, -- Zero timeout
            { git_timeout = 1 }, -- Minimum timeout
            { git_timeout = 300000 }, -- Very large timeout
            { cache = { ttl = 0 } }, -- Zero TTL
            { cache = { ttl = 1 } }, -- Minimum TTL
            { cache = { ttl = 86400 } }, -- Large TTL (1 day)
            { cache = { max_entries = 0 } }, -- Zero entries
            { cache = { max_entries = 1 } }, -- Minimum entries
            { cache = { max_entries = 10000 } }, -- Large number of entries
            { detection = { exclude_patterns = {} } }, -- Empty patterns
            { detection = { exclude_patterns = { string.rep('x', 1000) } } } -- Very long pattern
        }

        for i, config in ipairs(boundary_configs) do
            local success = pcall(function()
                remote_gitsigns.setup(config)

                local applied_config = remote_gitsigns.get_config()
                assert(applied_config ~= nil, 'Should have configuration')

                remote_gitsigns.shutdown()
            end)

            assert(success, 'Should handle boundary values (' .. i .. ')')
        end
    end) then
        passed = passed + 1
    end

    -- Test 5: Configuration Merging
    total = total + 1
    if run_config_test('Configuration Merging', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Setup with partial config
        remote_gitsigns.setup({
            enabled = true,
            cache = {
                ttl = 300 -- Only override TTL
            }
        })

        local config = remote_gitsigns.get_config()

        -- Should merge with defaults
        assert(config.enabled == true, 'Should override enabled')
        assert(config.cache.ttl == 300, 'Should override cache TTL')
        assert(type(config.cache.enabled) == 'boolean', 'Should keep default cache enabled')
        assert(type(config.cache.max_entries) == 'number', 'Should keep default max entries')
        assert(type(config.git_timeout) == 'number', 'Should keep default git timeout')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 6: Dynamic Configuration Updates
    total = total + 1
    if run_config_test('Dynamic Configuration Updates', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Initial setup
        remote_gitsigns.setup({
            enabled = true,
            cache = { ttl = 300 }
        })

        local initial_config = remote_gitsigns.get_config()
        assert(initial_config.cache.ttl == 300, 'Initial TTL should be 300')

        -- Update configuration
        remote_gitsigns.setup({
            enabled = true,
            cache = { ttl = 600 }
        })

        local updated_config = remote_gitsigns.get_config()
        assert(updated_config.cache.ttl == 600, 'Updated TTL should be 600')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 7: Cache Configuration Validation
    total = total + 1
    if run_config_test('Cache Configuration Validation', function()
        local cache = require('remote-gitsigns.cache')

        -- Test various cache configurations
        local cache_configs = {
            { enabled = true, ttl = 300, max_entries = 100 },
            { enabled = false },
            { ttl = 0, max_entries = 0 }, -- Disabled-like config
            { ttl = 1, max_entries = 1 }, -- Minimal config
            { ttl = 3600, max_entries = 1000, cleanup_interval = 60 } -- Full config
        }

        for i, config in ipairs(cache_configs) do
            local success = pcall(function()
                cache.configure(config)

                -- Test basic operations work with config
                cache.set('test_value', 'test_key')
                local value = cache.get('test_key')
                cache.has('test_key')
                cache.delete('test_key')

                local stats = cache.get_stats()
                assert(type(stats) == 'table', 'Should provide stats')
            end)

            assert(success, 'Cache config should work (' .. i .. ')')
        end
    end) then
        passed = passed + 1
    end

    -- Test 8: Detection Configuration Validation
    total = total + 1
    if run_config_test('Detection Configuration Validation', function()
        local buffer_detector = require('remote-gitsigns.buffer-detector')

        local detection_configs = {
            { async_detection = true },
            { async_detection = false },
            { exclude_patterns = { '*/%.git/*' } },
            { exclude_patterns = {} },
            {
                async_detection = true,
                exclude_patterns = {
                    '*/%.git/*',
                    '*/node_modules/*',
                    '*/target/*',
                    '*/build/*'
                }
            }
        }

        for i, config in ipairs(detection_configs) do
            local success = pcall(function()
                buffer_detector.configure(config)

                local applied_config = buffer_detector.get_config()
                assert(type(applied_config) == 'table', 'Should have detection config')

                -- Test detection still works
                local result = buffer_detector.check_remote_git_buffer(1)
                assert(type(result) == 'boolean', 'Detection should return boolean')
            end)

            assert(success, 'Detection config should work (' .. i .. ')')
        end
    end) then
        passed = passed + 1
    end

    -- Test 9: Configuration Persistence
    total = total + 1
    if run_config_test('Configuration Persistence', function()
        local remote_gitsigns = require('remote-gitsigns')

        local test_config = {
            enabled = true,
            git_timeout = 25000,
            cache = { ttl = 450, max_entries = 75 },
            detection = { async_detection = false }
        }

        -- Setup with config
        remote_gitsigns.setup(test_config)
        local config1 = remote_gitsigns.get_config()

        -- Shutdown and restart
        remote_gitsigns.shutdown()
        remote_gitsigns.setup(test_config)
        local config2 = remote_gitsigns.get_config()

        -- Configuration should be consistent
        assert(config1.enabled == config2.enabled, 'Enabled should persist')
        assert(config1.git_timeout == config2.git_timeout, 'Git timeout should persist')
        assert(config1.cache.ttl == config2.cache.ttl, 'Cache TTL should persist')
        assert(config1.cache.max_entries == config2.cache.max_entries, 'Cache max entries should persist')
        assert(config1.detection.async_detection == config2.detection.async_detection, 'Detection config should persist')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 10: Configuration Error Handling
    total = total + 1
    if run_config_test('Configuration Error Handling', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Test nil config
        local success1 = pcall(function() remote_gitsigns.setup(nil) end)
        assert(success1, 'Should handle nil config')

        -- Test empty config
        local success2 = pcall(function() remote_gitsigns.setup({}) end)
        assert(success2, 'Should handle empty config')

        -- Test malformed nested config
        local success3 = pcall(function()
            remote_gitsigns.setup({
                cache = {
                    enabled = true,
                    nested = {
                        deep = {
                            invalid = 'structure'
                        }
                    }
                }
            })
        end)
        assert(success3, 'Should handle malformed nested config')

        -- System should still be usable after errors
        local status = remote_gitsigns.get_status()
        assert(type(status) == 'table', 'Should provide status after config errors')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 11: Configuration Warnings and Notifications
    total = total + 1
    if run_config_test('Configuration Warnings', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Setup with potentially problematic values
        remote_gitsigns.setup({
            enabled = true,
            git_timeout = 1, -- Very short timeout
            cache = {
                ttl = 0, -- Zero TTL might be problematic
                max_entries = 0 -- Zero entries might be problematic
            }
        })

        -- Check if any warnings were issued
        local notifications = _G._vim_notifications or {}
        local log_messages = _G._log_messages or {}

        -- System should still work despite warnings
        local status = remote_gitsigns.get_status()
        assert(status.initialized ~= nil, 'Should initialize despite warnings')

        remote_gitsigns.shutdown()

        print(string.format('    Generated %d notifications, %d log messages',
            #notifications, #log_messages))
    end) then
        passed = passed + 1
    end

    -- Test 12: Environment-specific Configuration
    total = total + 1
    if run_config_test('Environment-specific Configuration', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Simulate different environments
        local environments = {
            { name = 'development', debug = true, cache = { ttl = 60 } },
            { name = 'production', debug = false, cache = { ttl = 3600 } },
            { name = 'testing', enabled = false, cache = { enabled = false } }
        }

        for _, env in ipairs(environments) do
            remote_gitsigns.setup(vim.tbl_deep_extend('force', { enabled = true }, env))

            local config = remote_gitsigns.get_config()

            if env.debug ~= nil then
                assert(config.debug == env.debug, 'Should set debug for ' .. env.name)
            end
            if env.cache then
                if env.cache.ttl then
                    assert(config.cache.ttl == env.cache.ttl, 'Should set cache TTL for ' .. env.name)
                end
                if env.cache.enabled ~= nil then
                    assert(config.cache.enabled == env.cache.enabled, 'Should set cache enabled for ' .. env.name)
                end
            end

            remote_gitsigns.shutdown()
        end
    end) then
        passed = passed + 1
    end

    print(string.format('\n=== Configuration Validation Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))

    return passed == total
end

-- Export for external use
return {
    run_configuration_validation_tests = run_configuration_validation_tests,
    setup_config_environment = setup_config_environment,
}

-- Run tests if called directly
if arg and arg[0] and arg[0]:match('configuration_validation_tests%.lua$') then
    local success = run_configuration_validation_tests()
    os.exit(success and 0 or 1)
end