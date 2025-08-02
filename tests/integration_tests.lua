-- Integration tests for remote-gitsigns with real SSH scenarios
-- These tests require actual SSH access to test hosts

local function setup_real_environment()
    -- Set up package path
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

    -- Real vim APIs (minimal mocking for integration tests)
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
        split = vim.split or function(s, sep)
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
        system = vim.system, -- Use real system calls for integration tests
        api = {
            nvim_create_augroup = function(name, opts) return math.random(1000) end,
            nvim_create_autocmd = function(events, opts) return true end,
            nvim_create_user_command = function(name, fn, opts) return true end,
            nvim_get_current_buf = function() return 1 end,
            nvim_buf_is_valid = function(bufnr) return true end,
            nvim_buf_get_name = function(bufnr)
                return 'scp://localhost//tmp/test-repo/test-file.txt'
            end,
            nvim_list_bufs = function() return {1, 2, 3} end,
        }
    }

    -- Mock dependencies with real-like behavior
    package.loaded['logging'] = {
        log = function(msg, level, show_user, config)
            if show_user or (config and config.debug) then
                print('[LOG] ' .. tostring(msg))
            end
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
            return {'ssh', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', host, command}
        end
    }

    package.loaded['remote-buffer-metadata'] = {
        set = function(bufnr, namespace, key, value) end,
        get = function(bufnr, namespace, key) return nil end,
        clear_namespace = function(bufnr, namespace) end
    }
end

-- Test configuration
local TEST_CONFIG = {
    -- Set to true to run tests that require SSH access
    ENABLE_SSH_TESTS = os.getenv('REMOTE_GITSIGNS_ENABLE_SSH_TESTS') == '1',

    -- Test hosts (these need to be accessible via SSH)
    TEST_HOSTS = {
        'localhost', -- Most systems can SSH to localhost
        -- Add other test hosts as needed
    },

    -- Test repositories (these should exist on test hosts)
    TEST_REPOS = {
        '/tmp/test-git-repo', -- Will be created if needed
    }
}

local function run_integration_test(name, test_fn)
    io.write('Integration Test: ' .. name .. '... ')
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

local function setup_test_repo(host, repo_path)
    -- Create a test git repository on the remote host
    local commands = {
        'rm -rf ' .. repo_path,
        'mkdir -p ' .. repo_path,
        'cd ' .. repo_path .. ' && git init',
        'cd ' .. repo_path .. ' && echo "Test file content" > test-file.txt',
        'cd ' .. repo_path .. ' && git add test-file.txt',
        'cd ' .. repo_path .. ' && git config user.email "test@example.com"',
        'cd ' .. repo_path .. ' && git config user.name "Test User"',
        'cd ' .. repo_path .. ' && git commit -m "Initial commit"',
        'cd ' .. repo_path .. ' && echo "Modified content" >> test-file.txt',
    }

    for _, cmd in ipairs(commands) do
        local ssh_cmd = {'ssh', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', host, cmd}
        local result = vim.system(ssh_cmd, { timeout = 10000 }):wait()
        if result.code ~= 0 then
            error('Failed to setup test repo: ' .. (result.stderr or 'unknown error'))
        end
    end
end

local function cleanup_test_repo(host, repo_path)
    local ssh_cmd = {'ssh', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', host, 'rm -rf ' .. repo_path}
    vim.system(ssh_cmd, { timeout = 5000 }):wait()
end

local function can_ssh_to_host(host)
    local ssh_cmd = {'ssh', '-o', 'ConnectTimeout=2', '-o', 'BatchMode=yes', host, 'echo "test"'}
    local result = vim.system(ssh_cmd, { timeout = 3000 }):wait()
    return result.code == 0
end

local function run_integration_tests()
    print('=== Remote Gitsigns Integration Tests ===\n')

    if not TEST_CONFIG.ENABLE_SSH_TESTS then
        print('SSH integration tests disabled. Set REMOTE_GITSIGNS_ENABLE_SSH_TESTS=1 to enable.')
        print('These tests require SSH access to test hosts.\n')
        return true
    end

    setup_real_environment()

    local passed = 0
    local total = 0
    local available_hosts = {}

    -- Check which test hosts are available
    print('Checking SSH connectivity to test hosts...')
    for _, host in ipairs(TEST_CONFIG.TEST_HOSTS) do
        if can_ssh_to_host(host) then
            table.insert(available_hosts, host)
            print('✓ ' .. host .. ' - SSH accessible')
        else
            print('✗ ' .. host .. ' - SSH not accessible')
        end
    end

    if #available_hosts == 0 then
        print('\nNo SSH-accessible hosts found. Skipping integration tests.')
        return true
    end

    local test_host = available_hosts[1]
    local test_repo = TEST_CONFIG.TEST_REPOS[1]

    print('\nUsing test host: ' .. test_host)
    print('Using test repo: ' .. test_repo .. '\n')

    -- Test 1: Real SSH Git Root Detection
    total = total + 1
    if run_integration_test('Real SSH Git Root Detection', function()
        setup_test_repo(test_host, test_repo)

        local remote_git = require('remote-gitsigns.remote-git')
        local git_root = remote_git.find_git_root(test_host, test_repo .. '/test-file.txt')

        assert(git_root == test_repo, 'Should find correct git root: expected ' .. test_repo .. ', got ' .. tostring(git_root))

        cleanup_test_repo(test_host, test_repo)
    end) then
        passed = passed + 1
    end

    -- Test 2: Real SSH Repo Info
    total = total + 1
    if run_integration_test('Real SSH Repo Info', function()
        setup_test_repo(test_host, test_repo)

        local remote_git = require('remote-gitsigns.remote-git')
        local repo_info = remote_git.get_repo_info(test_host, test_repo)

        assert(repo_info ~= nil, 'Should get repo info')
        assert(repo_info.toplevel == test_repo, 'Should have correct toplevel')
        assert(repo_info.head ~= nil, 'Should have head branch')

        cleanup_test_repo(test_host, test_repo)
    end) then
        passed = passed + 1
    end

    -- Test 3: Real SSH Git Commands
    total = total + 1
    if run_integration_test('Real SSH Git Commands', function()
        setup_test_repo(test_host, test_repo)

        local remote_git = require('remote-gitsigns.remote-git')

        -- Test git status
        local status_result = remote_git.execute_git_command(test_host, test_repo, {'status', '--porcelain'})
        assert(status_result.code == 0, 'Git status should succeed')
        assert(#status_result.stdout > 0, 'Should have status output for modified file')

        -- Test git log
        local log_result = remote_git.execute_git_command(test_host, test_repo, {'log', '--oneline', '-n', '1'})
        assert(log_result.code == 0, 'Git log should succeed')
        assert(#log_result.stdout > 0, 'Should have log output')

        cleanup_test_repo(test_host, test_repo)
    end) then
        passed = passed + 1
    end

    -- Test 4: Full Integration with Git Adapter
    total = total + 1
    if run_integration_test('Full Integration with Git Adapter', function()
        -- Mock gitsigns
        package.loaded['gitsigns.git.cmd'] = function(args, spec)
            return {'original git output'}, nil, 0
        end

        setup_test_repo(test_host, test_repo)

        local git_adapter = require('remote-gitsigns.git-adapter')
        local buffer_detector = require('remote-gitsigns.buffer-detector')

        -- Setup git adapter
        git_adapter.setup_git_command_hook()
        assert(git_adapter.is_active(), 'Git adapter should be active')

        -- Register a buffer for the test repo
        local success = git_adapter.register_remote_buffer(1, {
            host = test_host,
            remote_path = test_repo .. '/test-file.txt',
            git_root = test_repo,
            protocol = 'scp'
        })
        assert(success, 'Should register remote buffer')

        -- The git command should now be intercepted
        local original_git_cmd = package.loaded['gitsigns.git.cmd']
        local stdout, stderr, code = original_git_cmd({'status', '--porcelain'}, {cwd = test_repo})

        -- Should get real git output, not mock output
        assert(type(stdout) == 'table', 'Should return table of lines')
        assert(code == 0, 'Should succeed')

        cleanup_test_repo(test_host, test_repo)
        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 5: Buffer Detection Integration
    total = total + 1
    if run_integration_test('Buffer Detection Integration', function()
        setup_test_repo(test_host, test_repo)

        -- Mock buffer name to point to our test repo
        vim.api.nvim_buf_get_name = function(bufnr)
            return 'scp://' .. test_host .. '//' .. test_repo:sub(2) .. '/test-file.txt'
        end

        local buffer_detector = require('remote-gitsigns.buffer-detector')
        buffer_detector.configure({async_detection = false}) -- Sync for testing

        local is_git = buffer_detector.check_remote_git_buffer(1)
        assert(is_git == true, 'Should detect git repository')

        local status = buffer_detector.get_buffer_status(1)
        assert(status ~= nil, 'Should have buffer status')
        assert(status.is_git == true, 'Status should show git repository')
        assert(status.git_root == test_repo, 'Should have correct git root')

        cleanup_test_repo(test_host, test_repo)
    end) then
        passed = passed + 1
    end

    -- Test 6: Performance with Real SSH
    total = total + 1
    if run_integration_test('Performance with Real SSH', function()
        setup_test_repo(test_host, test_repo)

        local remote_git = require('remote-gitsigns.remote-git')

        -- Time multiple calls to the same repository
        local start_time = os.clock()

        -- First call (should be slow due to SSH)
        local git_root1 = remote_git.find_git_root(test_host, test_repo .. '/test-file.txt')
        local first_call_time = os.clock() - start_time

        -- Second call (should be fast due to caching)
        start_time = os.clock()
        local git_root2 = remote_git.find_git_root(test_host, test_repo .. '/test-file.txt')
        local second_call_time = os.clock() - start_time

        assert(git_root1 == git_root2, 'Both calls should return same result')
        assert(second_call_time < first_call_time, 'Second call should be faster (cached)')

        print(string.format('    First call: %.3fs, Second call: %.3fs', first_call_time, second_call_time))

        cleanup_test_repo(test_host, test_repo)
    end) then
        passed = passed + 1
    end

    print(string.format('\n=== Integration Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))

    return passed == total
end

-- Export functions for external testing
return {
    run_integration_tests = run_integration_tests,
    setup_real_environment = setup_real_environment,
    TEST_CONFIG = TEST_CONFIG,
}

-- Run tests if called directly
if arg and arg[0] and arg[0]:match('integration_tests%.lua$') then
    local success = run_integration_tests()
    os.exit(success and 0 or 1)
end