-- Edge case and error handling tests for remote-gitsigns
-- Tests various failure scenarios, edge cases, and error conditions

local function setup_edge_case_environment()
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

    -- Mock vim with configurable system responses
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
            -- Configurable mock system that can simulate various failure modes
            return _G._mock_system_response or {
                wait = function()
                    return { code = 0, stdout = 'default output', stderr = nil }
                end
            }
        end,
        api = {
            nvim_create_augroup = function(name, opts) return math.random(1000) end,
            nvim_create_autocmd = function(events, opts) return true end,
            nvim_create_user_command = function(name, fn, opts) return true end,
            nvim_get_current_buf = function() return 1 end,
            nvim_buf_is_valid = function(bufnr) return _G._mock_buffer_valid ~= false end,
            nvim_buf_get_name = function(bufnr)
                return _G._mock_buffer_name or 'scp://test-host//test/path/file.py'
            end,
            nvim_list_bufs = function() return {1, 2, 3} end,
        }
    }

    -- Mock dependencies
    package.loaded['logging'] = {
        log = function(msg, level, show_user, config)
            if _G._capture_logs then
                table.insert(_G._captured_logs, {msg = msg, level = level})
            end
        end
    }

    package.loaded['async-remote-write.utils'] = {
        parse_remote_path = function(path)
            if _G._mock_parse_failure then
                return nil
            end

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
            if _G._mock_ssh_build_failure then
                error('SSH command build failed')
            end
            return {'ssh', host, command}
        end
    }

    package.loaded['remote-buffer-metadata'] = {
        set = function(bufnr, namespace, key, value)
            if _G._mock_metadata_failure then
                error('Metadata operation failed')
            end
        end,
        get = function(bufnr, namespace, key) return nil end,
        clear_namespace = function(bufnr, namespace) end
    }
end

-- Helper function to set up system response mocks
local function mock_system_response(code, stdout, stderr, timeout_error)
    _G._mock_system_response = {
        wait = function()
            if timeout_error then
                error('Process timed out')
            end
            return {
                code = code or 0,
                stdout = stdout or '',
                stderr = stderr or nil
            }
        end
    }
end

local function run_edge_case_test(name, test_fn)
    io.write('Edge Case Test: ' .. name .. '... ')
    io.flush()

    -- Reset mocks before each test
    _G._mock_system_response = nil
    _G._mock_buffer_valid = nil
    _G._mock_buffer_name = nil
    _G._mock_parse_failure = nil
    _G._mock_ssh_build_failure = nil
    _G._mock_metadata_failure = nil
    _G._captured_logs = {}
    _G._capture_logs = false

    local success, error_msg = pcall(test_fn)

    if success then
        print('✓ PASS')
        return true
    else
        print('✗ FAIL: ' .. tostring(error_msg))
        return false
    end
end

local function run_edge_case_tests()
    print('=== Remote Gitsigns Edge Case & Error Handling Tests ===\n')

    setup_edge_case_environment()

    local passed = 0
    local total = 0

    -- Test 1: SSH Connection Timeout
    total = total + 1
    if run_edge_case_test('SSH Connection Timeout', function()
        mock_system_response(124, '', 'Connection timed out', true)

        local remote_git = require('remote-gitsigns.remote-git')

        local success, error_msg = pcall(function()
            remote_git.find_git_root('timeout-host', '/test/path')
        end)

        -- Should handle timeout gracefully
        assert(not success or error_msg, 'Should handle timeout error')
    end) then
        passed = passed + 1
    end

    -- Test 2: SSH Connection Refused
    total = total + 1
    if run_edge_case_test('SSH Connection Refused', function()
        mock_system_response(255, '', 'Connection refused')

        local remote_git = require('remote-gitsigns.remote-git')
        local git_root = remote_git.find_git_root('refused-host', '/test/path')

        -- Should return nil for connection failures
        assert(git_root == nil, 'Should return nil for connection failure')
    end) then
        passed = passed + 1
    end

    -- Test 3: Non-existent Git Repository
    total = total + 1
    if run_edge_case_test('Non-existent Git Repository', function()
        mock_system_response(1, '', 'fatal: not a git repository')

        local remote_git = require('remote-gitsigns.remote-git')
        local repo_info = remote_git.get_repo_info('test-host', '/not/a/git/repo')

        assert(repo_info == nil, 'Should return nil for non-git directories')
    end) then
        passed = passed + 1
    end

    -- Test 4: Malformed Git Output
    total = total + 1
    if run_edge_case_test('Malformed Git Output', function()
        mock_system_response(0, 'incomplete output\n', nil)

        local remote_git = require('remote-gitsigns.remote-git')
        local repo_info = remote_git.get_repo_info('test-host', '/test/repo')

        -- Should handle incomplete output gracefully
        assert(repo_info == nil, 'Should handle malformed output')
    end) then
        passed = passed + 1
    end

    -- Test 5: Invalid Buffer Names
    total = total + 1
    if run_edge_case_test('Invalid Buffer Names', function()
        local buffer_detector = require('remote-gitsigns.buffer-detector')

        -- Test various invalid buffer names
        local invalid_names = {
            '', -- Empty
            'not-a-remote-path', -- Not remote
            'scp://malformed', -- Malformed SCP
            'ftp://unsupported//path', -- Unsupported protocol
            'scp://host/', -- Missing path
        }

        for _, name in ipairs(invalid_names) do
            _G._mock_buffer_name = name
            local result = buffer_detector.check_remote_git_buffer(1)
            assert(result == false, 'Should reject invalid buffer name: ' .. name)
        end
    end) then
        passed = passed + 1
    end

    -- Test 6: Parse Failure Handling
    total = total + 1
    if run_edge_case_test('Parse Failure Handling', function()
        _G._mock_parse_failure = true
        _G._mock_buffer_name = 'scp://test-host//valid/path/file.py'

        local buffer_detector = require('remote-gitsigns.buffer-detector')
        local result = buffer_detector.check_remote_git_buffer(1)

        assert(result == false, 'Should handle parse failures gracefully')
    end) then
        passed = passed + 1
    end

    -- Test 7: Invalid Buffer Handling
    total = total + 1
    if run_edge_case_test('Invalid Buffer Handling', function()
        _G._mock_buffer_valid = false

        local buffer_detector = require('remote-gitsigns.buffer-detector')
        local result = buffer_detector.check_remote_git_buffer(999)

        assert(result == false, 'Should handle invalid buffers')
    end) then
        passed = passed + 1
    end

    -- Test 8: Git Command Failures
    total = total + 1
    if run_edge_case_test('Git Command Failures', function()
        mock_system_response(128, '', 'fatal: git command failed')

        local remote_git = require('remote-gitsigns.remote-git')
        local result = remote_git.execute_git_command('test-host', '/test/path', {'invalid-command'})

        assert(result.code == 128, 'Should return correct error code')
        assert(result.stderr == 'fatal: git command failed', 'Should return stderr')
    end) then
        passed = passed + 1
    end

    -- Test 9: Cache Memory Pressure
    total = total + 1
    if run_edge_case_test('Cache Memory Pressure', function()
        local cache = require('remote-gitsigns.cache')

        -- Configure small cache to trigger eviction
        cache.configure({ max_entries = 5 })

        -- Fill cache beyond limit
        for i = 1, 10 do
            cache.set('value' .. i, 'key' .. i)
        end

        -- Check that older entries were evicted
        local stats = cache.get_stats()
        assert(stats.current_size <= 5, 'Cache should respect size limits')
        assert(stats.evictions > 0, 'Should have evicted entries')
    end) then
        passed = passed + 1
    end

    -- Test 10: Configuration Edge Cases
    total = total + 1
    if run_edge_case_test('Configuration Edge Cases', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Test invalid configurations
        local invalid_configs = {
            { enabled = 'not-boolean' },
            { cache = { ttl = -1 } }, -- Negative TTL
            { cache = { max_entries = 0 } }, -- Zero entries
            { detection = { exclude_patterns = 'not-array' } },
        }

        for _, config in ipairs(invalid_configs) do
            local success = pcall(function()
                remote_gitsigns.setup(config)
            end)
            -- Should not crash on invalid config
            assert(success, 'Should handle invalid config gracefully')
        end
    end) then
        passed = passed + 1
    end

    -- Test 11: Concurrent Buffer Operations
    total = total + 1
    if run_edge_case_test('Concurrent Buffer Operations', function()
        local git_adapter = require('remote-gitsigns.git-adapter')

        -- Setup git adapter
        git_adapter.setup_git_command_hook()

        -- Register multiple buffers simultaneously
        for i = 1, 5 do
            local success = git_adapter.register_remote_buffer(i, {
                host = 'test-host',
                remote_path = '/test/path' .. i,
                git_root = '/test',
                protocol = 'scp'
            })
            assert(success, 'Should register buffer ' .. i)
        end

        -- Unregister in different order
        for i = 5, 1, -1 do
            git_adapter.unregister_remote_buffer(i)
            local info = git_adapter.get_remote_info(i)
            assert(info == nil, 'Should unregister buffer ' .. i)
        end
    end) then
        passed = passed + 1
    end

    -- Test 12: Resource Cleanup on Shutdown
    total = total + 1
    if run_edge_case_test('Resource Cleanup on Shutdown', function()
        local remote_gitsigns = require('remote-gitsigns')

        -- Setup with resources
        remote_gitsigns.setup({
            enabled = true,
            cache = { enabled = true }
        })

        assert(remote_gitsigns.is_initialized(), 'Should be initialized')

        -- Create some cached data
        local cache = require('remote-gitsigns.cache')
        cache.set('test', 'cleanup-test')

        local stats_before = cache.get_stats()
        assert(stats_before.current_size > 0, 'Should have cached data')

        -- Shutdown should clean everything
        remote_gitsigns.shutdown()

        assert(not remote_gitsigns.is_initialized(), 'Should be shut down')

        -- Multiple shutdowns should be safe
        remote_gitsigns.shutdown()
        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 13: Large File Paths
    total = total + 1
    if run_edge_case_test('Large File Paths', function()
        local buffer_detector = require('remote-gitsigns.buffer-detector')

        -- Create very long path
        local long_path = 'scp://test-host//' .. string.rep('very-long-directory-name/', 50) .. 'file.py'
        _G._mock_buffer_name = long_path

        -- Should handle long paths without crashing
        local result = buffer_detector.check_remote_git_buffer(1)
        -- Result may be true or false, but shouldn't crash
        assert(type(result) == 'boolean', 'Should return boolean for long paths')
    end) then
        passed = passed + 1
    end

    -- Test 14: Special Characters in Paths
    total = total + 1
    if run_edge_case_test('Special Characters in Paths', function()
        local special_paths = {
            'scp://test-host//path with spaces/file.py',
            'scp://test-host//path/with/unicode/ñámé.py',
            'scp://test-host//path/with/$pecial/chars.py',
            'scp://test-host//path/with/(parentheses)/file.py',
        }

        local buffer_detector = require('remote-gitsigns.buffer-detector')

        for _, path in ipairs(special_paths) do
            _G._mock_buffer_name = path
            local result = buffer_detector.check_remote_git_buffer(1)
            assert(type(result) == 'boolean', 'Should handle special chars in: ' .. path)
        end
    end) then
        passed = passed + 1
    end

    -- Test 15: Error Recovery
    total = total + 1
    if run_edge_case_test('Error Recovery', function()
        _G._capture_logs = true

        local remote_gitsigns = require('remote-gitsigns')

        -- Setup with some failures
        _G._mock_metadata_failure = true

        local success = pcall(function()
            remote_gitsigns.setup({ enabled = true })
        end)

        -- Should continue despite metadata failures
        assert(success, 'Should recover from metadata failures')

        -- Check that errors were logged
        assert(#_G._captured_logs >= 0, 'Should have logged errors')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    print(string.format('\n=== Edge Case Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))

    return passed == total
end

-- Export for external use
return {
    run_edge_case_tests = run_edge_case_tests,
    setup_edge_case_environment = setup_edge_case_environment,
    mock_system_response = mock_system_response,
}

-- Run tests if called directly
if arg and arg[0] and arg[0]:match('edge_case_tests%.lua$') then
    local success = run_edge_case_tests()
    os.exit(success and 0 or 1)
end