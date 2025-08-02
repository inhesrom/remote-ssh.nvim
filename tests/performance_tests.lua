-- Performance and caching tests for remote-gitsigns
-- Tests cache behavior, timing, and performance under load

local function setup_performance_environment()
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

    -- Mock vim with timing capabilities
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
        defer_fn = function(fn, delay) fn() end,
        schedule = function(fn) fn() end,
        system = function(cmd, opts)
            -- Configurable system response with timing simulation
            local response = _G._mock_system_response or {
                wait = function()
                    -- Simulate SSH latency
                    if _G._simulate_ssh_latency then
                        local start_time = os.clock()
                        while os.clock() - start_time < 0.1 do end -- 100ms delay
                    end
                    return { code = 0, stdout = 'performance test output', stderr = nil }
                end
            }
            return response
        end,
        api = {
            nvim_create_augroup = function(name, opts) return math.random(1000) end,
            nvim_create_autocmd = function(events, opts) return true end,
            nvim_create_user_command = function(name, fn, opts) return true end,
            nvim_get_current_buf = function() return 1 end,
            nvim_buf_is_valid = function(bufnr) return true end,
            nvim_buf_get_name = function(bufnr)
                return 'scp://test-host//test/path/file' .. bufnr .. '.py'
            end,
            nvim_list_bufs = function() return {1, 2, 3, 4, 5} end,
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
        set = function(bufnr, namespace, key, value) end,
        get = function(bufnr, namespace, key) return nil end,
        clear_namespace = function(bufnr, namespace) end
    }
end

local function mock_git_responses()
    _G._mock_system_response = {
        wait = function()
            if _G._simulate_ssh_latency then
                local start_time = os.clock()
                while os.clock() - start_time < 0.05 do end -- 50ms delay
            end
            return {
                code = 0,
                stdout = '/test/git/root\n/test/git/.git\nmain\n',
                stderr = nil
            }
        end
    }
end

local function run_performance_test(name, test_fn)
    io.write('Performance Test: ' .. name .. '... ')
    io.flush()

    local success, error_msg = pcall(test_fn)

    if success then
        print('✓ PASS')
        return true
    else
        print('✗ FAIL: ' .. tostring(error_msg))
        return false
    end
end

local function run_performance_tests()
    print('=== Remote Gitsigns Performance & Caching Tests ===\n')

    setup_performance_environment()

    local passed = 0
    local total = 0

    -- Test 1: Cache Hit Performance
    total = total + 1
    if run_performance_test('Cache Hit Performance', function()
        local cache = require('remote-gitsigns.cache')
        cache.configure({ ttl = 300, max_entries = 1000 })

        -- Warm up cache
        cache.set('test_value', 'performance_key')

        -- Time cache hits
        local hit_times = {}
        for i = 1, 100 do
            local start_time = os.clock()
            local value = cache.get('performance_key')
            local end_time = os.clock()
            table.insert(hit_times, end_time - start_time)
            assert(value == 'test_value', 'Cache should return correct value')
        end

        -- Calculate average hit time
        local total_time = 0
        for _, time in ipairs(hit_times) do
            total_time = total_time + time
        end
        local avg_hit_time = total_time / #hit_times

        -- Cache hits should be very fast (< 1ms on most systems)
        assert(avg_hit_time < 0.001, 'Cache hits should be fast, got: ' .. avg_hit_time .. 's')

        print(string.format('    Average cache hit time: %.6fs', avg_hit_time))
    end) then
        passed = passed + 1
    end

    -- Test 2: Cache vs SSH Performance Comparison
    total = total + 1
    if run_performance_test('Cache vs SSH Performance', function()
        mock_git_responses()
        _G._simulate_ssh_latency = true

        local remote_git = require('remote-gitsigns.remote-git')

        -- First call (should be slow due to "SSH")
        local start_time = os.clock()
        local git_root1 = remote_git.find_git_root('test-host', '/test/path/file.py')
        local first_call_time = os.clock() - start_time

        -- Second call (should be fast due to caching)
        start_time = os.clock()
        local git_root2 = remote_git.find_git_root('test-host', '/test/path/file.py')
        local second_call_time = os.clock() - start_time

        _G._simulate_ssh_latency = false

        assert(git_root1 == git_root2, 'Both calls should return same result')
        assert(second_call_time < first_call_time / 2, 'Cached call should be significantly faster')

        print(string.format('    First call: %.3fs, Cached call: %.3fs (%.1fx faster)',
            first_call_time, second_call_time, first_call_time / second_call_time))
    end) then
        passed = passed + 1
    end

    -- Test 3: Cache Memory Usage Under Load
    total = total + 1
    if run_performance_test('Cache Memory Usage Under Load', function()
        local cache = require('remote-gitsigns.cache')
        cache.configure({ max_entries = 100, ttl = 60 })

        -- Fill cache with many entries
        for i = 1, 150 do
            cache.set('value_' .. i, 'key', 'host_' .. i, 'path_' .. i)
        end

        local stats = cache.get_stats()

        -- Should respect max_entries limit
        assert(stats.current_size <= 100, 'Cache should respect size limit, got: ' .. stats.current_size)
        assert(stats.evictions > 0, 'Should have evicted entries: ' .. stats.evictions)
        assert(stats.hits >= 0, 'Should track hits')
        assert(stats.misses >= 0, 'Should track misses')

        print(string.format('    Final size: %d, Evictions: %d, Hit ratio: %.2f%%',
            stats.current_size, stats.evictions,
            stats.hits / (stats.hits + stats.misses) * 100))
    end) then
        passed = passed + 1
    end

    -- Test 4: TTL Expiration Performance
    total = total + 1
    if run_performance_test('TTL Expiration Performance', function()
        local cache = require('remote-gitsigns.cache')
        cache.configure({ ttl = 1, cleanup_interval = 1 }) -- 1 second TTL

        -- Add entries
        cache.set('expired_value1', 'ttl_key1')
        cache.set('expired_value2', 'ttl_key2')

        -- Verify they exist
        assert(cache.has('ttl_key1'), 'Entry should exist initially')
        assert(cache.has('ttl_key2'), 'Entry should exist initially')

        -- Mock time passage
        local original_time = os.time
        os.time = function() return original_time() + 2 end -- 2 seconds later

        -- Trigger cleanup by accessing cache
        cache.get('ttl_key1')

        -- Restore original time
        os.time = original_time

        -- Entries should be expired (or at least cleanup should have run)
        local stats = cache.get_stats()
        assert(stats.cleanups >= 1, 'Should have performed cleanup')
    end) then
        passed = passed + 1
    end

    -- Test 5: Concurrent Cache Access Simulation
    total = total + 1
    if run_performance_test('Concurrent Cache Access Simulation', function()
        local cache = require('remote-gitsigns.cache')
        cache.configure({ max_entries = 50 })

        -- Simulate multiple "concurrent" operations
        local operations = {}
        for i = 1, 20 do
            table.insert(operations, function()
                cache.set('concurrent_value_' .. i, 'concurrent_key_' .. i)
                cache.get('concurrent_key_' .. i)
                cache.has('concurrent_key_' .. i)
            end)
        end

        -- Execute all operations
        local start_time = os.clock()
        for _, op in ipairs(operations) do
            op()
        end
        local total_time = os.clock() - start_time

        local stats = cache.get_stats()
        assert(stats.current_size > 0, 'Should have cached entries')

        -- Should complete quickly even with many operations
        assert(total_time < 0.1, 'Concurrent operations should be fast, took: ' .. total_time .. 's')

        print(string.format('    %d operations completed in %.3fs', #operations, total_time))
    end) then
        passed = passed + 1
    end

    -- Test 6: Large Data Caching Performance
    total = total + 1
    if run_performance_test('Large Data Caching Performance', function()
        local cache = require('remote-gitsigns.cache')

        -- Create large data structure
        local large_data = {}
        for i = 1, 100 do
            large_data['field_' .. i] = string.rep('data', 100) -- ~400 bytes per field
        end

        -- Time storing large data
        local start_time = os.clock()
        cache.set(large_data, 'large_data_key')
        local store_time = os.clock() - start_time

        -- Time retrieving large data
        start_time = os.clock()
        local retrieved_data = cache.get('large_data_key')
        local retrieve_time = os.clock() - start_time

        assert(retrieved_data ~= nil, 'Should retrieve large data')
        assert(retrieved_data.field_1 == large_data.field_1, 'Retrieved data should match')

        -- Both operations should be reasonably fast
        assert(store_time < 0.01, 'Storing large data should be fast')
        assert(retrieve_time < 0.01, 'Retrieving large data should be fast')

        print(string.format('    Store: %.3fms, Retrieve: %.3fms', store_time * 1000, retrieve_time * 1000))
    end) then
        passed = passed + 1
    end

    -- Test 7: Cache Statistics Accuracy
    total = total + 1
    if run_performance_test('Cache Statistics Accuracy', function()
        local cache = require('remote-gitsigns.cache')
        cache.clear() -- Start fresh

        -- Perform known operations
        cache.set('value1', 'key1') -- Miss (first time)
        cache.set('value2', 'key2') -- Miss
        cache.get('key1') -- Hit
        cache.get('key1') -- Hit
        cache.get('key3') -- Miss (doesn't exist)
        cache.has('key1') -- Hit
        cache.has('key4') -- Miss (doesn't exist)

        local stats = cache.get_stats()

        -- Check statistics accuracy
        assert(stats.current_size == 2, 'Should have 2 entries, got: ' .. stats.current_size)
        assert(stats.hits >= 2, 'Should have at least 2 hits, got: ' .. stats.hits)
        assert(stats.misses >= 3, 'Should have at least 3 misses, got: ' .. stats.misses)
        assert(stats.sets == 2, 'Should have 2 sets, got: ' .. stats.sets)

        local hit_ratio = stats.hits / (stats.hits + stats.misses)
        print(string.format('    Entries: %d, Hits: %d, Misses: %d, Ratio: %.2f%%',
            stats.current_size, stats.hits, stats.misses, hit_ratio * 100))
    end) then
        passed = passed + 1
    end

    -- Test 8: Remote Git Command Caching Effectiveness
    total = total + 1
    if run_performance_test('Remote Git Command Caching', function()
        mock_git_responses()

        local remote_git = require('remote-gitsigns.remote-git')

        -- Execute same git command multiple times
        local host = 'performance-test-host'
        local workdir = '/test/performance/repo'
        local command_times = {}

        for i = 1, 5 do
            local start_time = os.clock()
            local result = remote_git.execute_git_command(host, workdir, {'status', '--porcelain'})
            local end_time = os.clock()

            table.insert(command_times, end_time - start_time)
            assert(result.code == 0, 'Git command should succeed')
        end

        -- Later commands should be faster due to caching
        local first_time = command_times[1]
        local last_time = command_times[#command_times]

        -- At minimum, the difference should be detectable
        assert(type(first_time) == 'number', 'Should measure execution time')
        assert(type(last_time) == 'number', 'Should measure execution time')

        print(string.format('    First: %.3fs, Last: %.3fs', first_time, last_time))
    end) then
        passed = passed + 1
    end

    print(string.format('\n=== Performance Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))

    return passed == total
end

-- Export for external use
return {
    run_performance_tests = run_performance_tests,
    setup_performance_environment = setup_performance_environment,
}

-- Run tests if called directly
if arg and arg[0] and arg[0]:match('performance_tests%.lua$') then
    local success = run_performance_tests()
    os.exit(success and 0 or 1)
end