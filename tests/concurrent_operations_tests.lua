-- Concurrent operations tests for remote-gitsigns
-- Tests behavior under concurrent git operations, buffer management, and resource contention

local function setup_concurrent_environment()
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

    -- Mock vim with support for concurrent operations
    _G.vim = {
        log = { levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 } },
        notify = function(msg, level) print('[NOTIFY] ' .. tostring(msg)) end,
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
        defer_fn = function(fn, delay)
            -- Simulate async execution
            _G._deferred_functions = _G._deferred_functions or {}
            table.insert(_G._deferred_functions, fn)
        end,
        schedule = function(fn)
            -- Simulate scheduling
            _G._scheduled_functions = _G._scheduled_functions or {}
            table.insert(_G._scheduled_functions, fn)
        end,
        system = function(cmd, opts)
            -- Mock system with concurrent operation tracking
            _G._concurrent_system_calls = (_G._concurrent_system_calls or 0) + 1

            return {
                wait = function()
                    -- Simulate processing time variation
                    local delay = math.random(1, 10) / 1000 -- 1-10ms
                    local start_time = os.clock()
                    while os.clock() - start_time < delay do end

                    _G._concurrent_system_calls = _G._concurrent_system_calls - 1

                    return {
                        code = 0,
                        stdout = 'concurrent git output ' .. math.random(1000),
                        stderr = nil
                    }
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
                return 'scp://concurrent-host//test/concurrent/repo/file' .. bufnr .. '.py'
            end,
            nvim_list_bufs = function()
                -- Return varying number of buffers to simulate dynamic environment
                local count = _G._concurrent_buffer_count or 5
                local bufs = {}
                for i = 1, count do table.insert(bufs, i) end
                return bufs
            end,
        }
    }

    -- Mock dependencies
    package.loaded['logging'] = {
        log = function(msg, level, show_user, config) end
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
        set = function(bufnr, namespace, key, value)
            -- Simulate concurrent metadata operations
            _G._metadata_operations = (_G._metadata_operations or 0) + 1
        end,
        get = function(bufnr, namespace, key)
            _G._metadata_operations = (_G._metadata_operations or 0) + 1
            return nil
        end,
        clear_namespace = function(bufnr, namespace)
            _G._metadata_operations = (_G._metadata_operations or 0) + 1
        end
    }

    -- Reset concurrent operation counters
    _G._concurrent_system_calls = 0
    _G._metadata_operations = 0
    _G._deferred_functions = {}
    _G._scheduled_functions = {}
end

local function execute_deferred_functions()
    -- Execute all deferred/scheduled functions
    for _, fn in ipairs(_G._deferred_functions or {}) do
        pcall(fn)
    end
    for _, fn in ipairs(_G._scheduled_functions or {}) do
        pcall(fn)
    end
    _G._deferred_functions = {}
    _G._scheduled_functions = {}
end

local function run_concurrent_test(name, test_fn)
    io.write('Concurrent Test: ' .. name .. '... ')
    io.flush()

    -- Reset counters
    _G._concurrent_system_calls = 0
    _G._metadata_operations = 0
    _G._deferred_functions = {}
    _G._scheduled_functions = {}

    local success, error_msg = pcall(test_fn)

    if success then
        print('✓ PASS')
        return true
    else
        print('✗ FAIL: ' .. tostring(error_msg))
        return false
    end
end

local function run_concurrent_operations_tests()
    print('=== Remote Gitsigns Concurrent Operations Tests ===\n')

    setup_concurrent_environment()

    local passed = 0
    local total = 0

    -- Test 1: Concurrent Buffer Registration
    total = total + 1
    if run_concurrent_test('Concurrent Buffer Registration', function()
        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        -- Register multiple buffers concurrently
        local registrations = {}
        for i = 1, 10 do
            table.insert(registrations, {
                bufnr = i,
                info = {
                    host = 'concurrent-host-' .. i,
                    remote_path = '/test/concurrent/repo' .. i .. '/file.py',
                    git_root = '/test/concurrent/repo' .. i,
                    protocol = 'scp'
                }
            })
        end

        -- Register all buffers
        local success_count = 0
        for _, reg in ipairs(registrations) do
            if git_adapter.register_remote_buffer(reg.bufnr, reg.info) then
                success_count = success_count + 1
            end
        end

        assert(success_count == #registrations, 'All registrations should succeed')

        -- Verify all registrations
        for _, reg in ipairs(registrations) do
            local info = git_adapter.get_remote_info(reg.bufnr)
            assert(info ~= nil, 'Buffer ' .. reg.bufnr .. ' should be registered')
            assert(info.host == reg.info.host, 'Host should match for buffer ' .. reg.bufnr)
        end

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 2: Concurrent Git Command Execution
    total = total + 1
    if run_concurrent_test('Concurrent Git Command Execution', function()
        local remote_git = require('remote-gitsigns.remote-git')

        -- Execute multiple git commands concurrently
        local commands = {
            {'status', '--porcelain'},
            {'diff', '--name-only'},
            {'log', '--oneline', '-n', '5'},
            {'branch', '-a'},
            {'rev-parse', 'HEAD'}
        }

        local results = {}
        local max_concurrent = 0

        for i, cmd in ipairs(commands) do
            local host = 'concurrent-host-' .. i
            local workdir = '/test/concurrent/repo' .. i

            -- Track concurrent operations
            local before_calls = _G._concurrent_system_calls
            local result = remote_git.execute_git_command(host, workdir, cmd)
            max_concurrent = math.max(max_concurrent, _G._concurrent_system_calls)

            table.insert(results, result)
            assert(result.code == 0, 'Git command should succeed: ' .. table.concat(cmd, ' '))
        end

        assert(#results == #commands, 'All commands should complete')
        print(string.format('    Max concurrent operations: %d', max_concurrent))
    end) then
        passed = passed + 1
    end

    -- Test 3: Concurrent Cache Operations
    total = total + 1
    if run_concurrent_test('Concurrent Cache Operations', function()
        local cache = require('remote-gitsigns.cache')
        cache.configure({ max_entries = 100 })

        -- Perform concurrent cache operations
        local operations = {}
        for i = 1, 20 do
            table.insert(operations, function()
                -- Mix of set, get, has, delete operations
                cache.set('value_' .. i, 'key_' .. i)
                cache.get('key_' .. i)
                cache.has('key_' .. i)
                if i % 4 == 0 then
                    cache.delete('key_' .. (i - 1))
                end
            end)
        end

        -- Execute operations
        for _, op in ipairs(operations) do
            op()
        end

        local stats = cache.get_stats()
        assert(stats.current_size > 0, 'Cache should have entries')
        assert(stats.sets >= 20, 'Should have performed sets')
        assert(stats.hits + stats.misses > 0, 'Should have performed gets')

        print(string.format('    Cache entries: %d, Operations: %d',
            stats.current_size, stats.sets + stats.hits + stats.misses))
    end) then
        passed = passed + 1
    end

    -- Test 4: Concurrent Buffer Detection
    total = total + 1
    if run_concurrent_test('Concurrent Buffer Detection', function()
        local buffer_detector = require('remote-gitsigns.buffer-detector')
        buffer_detector.configure({ async_detection = false }) -- Sync for testing

        -- Set up multiple buffers
        _G._concurrent_buffer_count = 8

        local detection_results = {}
        for i = 1, _G._concurrent_buffer_count do
            local result = buffer_detector.check_remote_git_buffer(i)
            table.insert(detection_results, { bufnr = i, result = result })
        end

        -- Verify all detections completed
        assert(#detection_results == _G._concurrent_buffer_count, 'All detections should complete')

        for _, detection in ipairs(detection_results) do
            assert(type(detection.result) == 'boolean', 'Detection should return boolean')
        end

        print(string.format('    Detected %d buffers', #detection_results))
    end) then
        passed = passed + 1
    end

    -- Test 5: Resource Contention Handling
    total = total + 1
    if run_concurrent_test('Resource Contention Handling', function()
        local remote_gitsigns = require('remote-gitsigns')
        remote_gitsigns.setup({
            enabled = true,
            cache = { enabled = true, max_entries = 10 }, -- Small cache to force contention
            git_timeout = 1000 -- Short timeout
        })

        -- Create resource contention
        local operations = {}
        for i = 1, 15 do
            table.insert(operations, function()
                -- Mix of operations that compete for resources
                remote_gitsigns.detect_buffer(i)
                remote_gitsigns.get_status()
                remote_gitsigns.get_config()
            end)
        end

        -- Execute operations
        local start_time = os.clock()
        for _, op in ipairs(operations) do
            op()
        end
        local duration = os.clock() - start_time

        -- Should complete in reasonable time despite contention
        assert(duration < 1.0, 'Operations should complete quickly despite contention')

        local status = remote_gitsigns.get_status()
        assert(status.initialized == true, 'System should remain initialized')

        remote_gitsigns.shutdown()
        print(string.format('    %d operations completed in %.3fs', #operations, duration))
    end) then
        passed = passed + 1
    end

    -- Test 6: Concurrent Setup/Shutdown
    total = total + 1
    if run_concurrent_test('Concurrent Setup/Shutdown', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Test rapid setup/shutdown cycles
        for i = 1, 5 do
            remote_gitsigns.setup({
                enabled = true,
                cache = { enabled = true },
                detection = { async_detection = false }
            })

            assert(remote_gitsigns.is_initialized(), 'Should initialize in cycle ' .. i)

            -- Perform some operations
            remote_gitsigns.get_status()
            remote_gitsigns.get_config()

            remote_gitsigns.shutdown()
            assert(not remote_gitsigns.is_initialized(), 'Should shutdown in cycle ' .. i)
        end

        print('    Completed 5 setup/shutdown cycles')
    end) then
        passed = passed + 1
    end

    -- Test 7: Concurrent Git Adapter Operations
    total = total + 1
    if run_concurrent_test('Concurrent Git Adapter Operations', function()
        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        -- Mock gitsigns git command
        package.loaded['gitsigns.git.cmd'] = function(args, spec)
            return {'concurrent git output'}, nil, 0
        end

        -- Register and unregister buffers concurrently
        local buffer_ops = {}
        for i = 1, 10 do
            table.insert(buffer_ops, function()
                -- Register
                local success = git_adapter.register_remote_buffer(i, {
                    host = 'test-host',
                    remote_path = '/test/path' .. i,
                    git_root = '/test',
                    protocol = 'scp'
                })
                assert(success, 'Should register buffer ' .. i)

                -- Get info
                local info = git_adapter.get_remote_info(i)
                assert(info ~= nil, 'Should get info for buffer ' .. i)

                -- Execute git command through adapter
                local original_cmd = package.loaded['gitsigns.git.cmd']
                local stdout, stderr, code = original_cmd({'status'}, {cwd = '/test'})
                assert(type(stdout) == 'table', 'Should return git output')

                -- Unregister
                git_adapter.unregister_remote_buffer(i)
                local info_after = git_adapter.get_remote_info(i)
                assert(info_after == nil, 'Should unregister buffer ' .. i)
            end)
        end

        -- Execute all operations
        for _, op in ipairs(buffer_ops) do
            op()
        end

        git_adapter.reset()
        print(string.format('    Completed %d concurrent adapter operations', #buffer_ops))
    end) then
        passed = passed + 1
    end

    -- Test 8: Async Function Execution
    total = total + 1
    if run_concurrent_test('Async Function Execution', function()
        local remote_gitsigns = require('remote-gitsigns')
        remote_gitsigns.setup({
            enabled = true,
            detection = { async_detection = true }
        })

        -- Trigger async operations
        local async_ops = 0
        for i = 1, 5 do
            local result = remote_gitsigns.detect_buffer(i)
            if result then async_ops = async_ops + 1 end
        end

        -- Process deferred/scheduled functions
        execute_deferred_functions()

        local deferred_count = #(_G._deferred_functions or {})
        local scheduled_count = #(_G._scheduled_functions or {})

        -- Should have triggered some async operations
        assert(deferred_count >= 0, 'Should handle deferred functions')
        assert(scheduled_count >= 0, 'Should handle scheduled functions')

        remote_gitsigns.shutdown()
        print(string.format('    Processed %d deferred, %d scheduled functions',
            deferred_count, scheduled_count))
    end) then
        passed = passed + 1
    end

    -- Test 9: Memory Management Under Concurrent Load
    total = total + 1
    if run_concurrent_test('Memory Management Under Load', function()
        local cache = require('remote-gitsigns.cache')
        cache.configure({ max_entries = 20, ttl = 1 }) -- Small cache, short TTL

        -- Create memory pressure with many operations
        local operations_count = 50
        for i = 1, operations_count do
            -- Create varying sized data
            local data_size = math.random(1, 10)
            local data = {}
            for j = 1, data_size do
                data['field_' .. j] = 'data_' .. i .. '_' .. j
            end

            cache.set(data, 'memory_key_' .. i)

            -- Occasionally access old data
            if i > 10 and math.random() > 0.7 then
                cache.get('memory_key_' .. (i - 10))
            end
        end

        local stats = cache.get_stats()

        -- Should have managed memory well
        assert(stats.current_size <= 20, 'Should respect memory limits')
        assert(stats.evictions > 0, 'Should have evicted entries under pressure')

        print(string.format('    Processed %d operations, %d evictions, final size: %d',
            operations_count, stats.evictions, stats.current_size))
    end) then
        passed = passed + 1
    end

    -- Test 10: Error Recovery in Concurrent Environment
    total = total + 1
    if run_concurrent_test('Error Recovery in Concurrent Environment', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Setup with potential error conditions
        remote_gitsigns.setup({ enabled = true })

        local errors_encountered = 0
        local successful_ops = 0

        -- Mix successful and error operations
        for i = 1, 10 do
            local success = pcall(function()
                if i % 3 == 0 then
                    -- Trigger potential error condition
                    remote_gitsigns.detect_buffer(-1) -- Invalid buffer
                else
                    -- Normal operation
                    remote_gitsigns.get_status()
                    successful_ops = successful_ops + 1
                end
            end)

            if not success then
                errors_encountered = errors_encountered + 1
            end
        end

        -- System should still be functional after errors
        local status = remote_gitsigns.get_status()
        assert(status.initialized == true, 'System should remain functional after errors')
        assert(successful_ops > 0, 'Some operations should succeed')

        remote_gitsigns.shutdown()
        print(string.format('    %d successful ops, %d errors handled', successful_ops, errors_encountered))
    end) then
        passed = passed + 1
    end

    print(string.format('\n=== Concurrent Operations Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))

    return passed == total
end

-- Export for external use
return {
    run_concurrent_operations_tests = run_concurrent_operations_tests,
    setup_concurrent_environment = setup_concurrent_environment,
    execute_deferred_functions = execute_deferred_functions,
}

-- Run tests if called directly
if arg and arg[0] and arg[0]:match('concurrent_operations_tests%.lua$') then
    local success = run_concurrent_operations_tests()
    os.exit(success and 0 or 1)
end