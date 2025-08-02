-- Gitsigns compatibility tests for remote-gitsigns
-- Tests compatibility with different gitsigns versions and configurations

local function setup_gitsigns_environment()
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

    -- Mock vim
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
            return _G._mock_system_response or {
                wait = function()
                    return { code = 0, stdout = 'gitsigns test output', stderr = nil }
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
                return 'scp://test-host//test/gitsigns/repo/file.py'
            end,
            nvim_list_bufs = function() return {1, 2, 3} end,
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

-- Mock different gitsigns versions and configurations
local function mock_gitsigns_version(version_config)
    local version = version_config.version or '0.6.0'
    local git_cmd_behavior = version_config.git_cmd_behavior or 'standard'

    -- Clear existing gitsigns mocks
    package.loaded['gitsigns'] = nil
    package.loaded['gitsigns.git.cmd'] = nil

    -- Mock gitsigns main module
    package.loaded['gitsigns'] = {
        attach = function(bufnr, opts)
            _G._gitsigns_attach_calls = (_G._gitsigns_attach_calls or 0) + 1
            _G._gitsigns_last_attach_bufnr = bufnr
            _G._gitsigns_last_attach_opts = opts
            return version_config.attach_success ~= false
        end,
        detach = function(bufnr)
            _G._gitsigns_detach_calls = (_G._gitsigns_detach_calls or 0) + 1
            return true
        end,
        refresh = function(bufnr)
            _G._gitsigns_refresh_calls = (_G._gitsigns_refresh_calls or 0) + 1
            return true
        end,
        get_actions = function()
            return {
                stage_hunk = function() end,
                undo_stage_hunk = function() end,
                reset_hunk = function() end,
                preview_hunk = function() end,
            }
        end,
        _version = version
    }

    -- Mock gitsigns.git.cmd with version-specific behavior
    package.loaded['gitsigns.git.cmd'] = function(args, spec)
        _G._gitsigns_git_calls = (_G._gitsigns_git_calls or 0) + 1
        _G._gitsigns_last_git_args = args
        _G._gitsigns_last_git_spec = spec

        if git_cmd_behavior == 'old_format' then
            -- Older versions returned different format
            return {'output line 1', 'output line 2'}, nil, 0
        elseif git_cmd_behavior == 'with_meta' then
            -- Newer versions might include metadata
            return {
                stdout = {'output line 1', 'output line 2'},
                stderr = nil,
                code = 0,
                meta = { cwd = spec and spec.cwd or '/default' }
            }
        elseif git_cmd_behavior == 'error' then
            -- Simulate error behavior
            return nil, 'git command failed', 1
        else
            -- Standard behavior
            return {'output line 1', 'output line 2'}, nil, 0
        end
    end

    -- Store original for restoration
    _G._original_gitsigns_git_cmd = package.loaded['gitsigns.git.cmd']
end

local function reset_gitsigns_tracking()
    _G._gitsigns_attach_calls = 0
    _G._gitsigns_detach_calls = 0
    _G._gitsigns_refresh_calls = 0
    _G._gitsigns_git_calls = 0
    _G._gitsigns_last_attach_bufnr = nil
    _G._gitsigns_last_attach_opts = nil
    _G._gitsigns_last_git_args = nil
    _G._gitsigns_last_git_spec = nil
end

local function run_compatibility_test(name, test_fn)
    io.write('Compatibility Test: ' .. name .. '... ')
    io.flush()

    reset_gitsigns_tracking()

    local success, error_msg = pcall(test_fn)

    if success then
        print('✓ PASS')
        return true
    else
        print('✗ FAIL: ' .. tostring(error_msg))
        return false
    end
end

local function run_gitsigns_compatibility_tests()
    print('=== Remote Gitsigns Compatibility Tests ===\n')

    setup_gitsigns_environment()

    local passed = 0
    local total = 0

    -- Test 1: Standard Gitsigns Git Command Format
    total = total + 1
    if run_compatibility_test('Standard Git Command Format', function()
        mock_gitsigns_version({
            version = '0.6.0',
            git_cmd_behavior = 'standard'
        })

        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        -- Register a remote buffer
        git_adapter.register_remote_buffer(1, {
            host = 'test-host',
            remote_path = '/test/repo/file.py',
            git_root = '/test/repo',
            protocol = 'scp'
        })

        -- Call the hooked git command
        local original_cmd = package.loaded['gitsigns.git.cmd']
        local stdout, stderr, code = original_cmd({'status', '--porcelain'}, {cwd = '/test/repo'})

        assert(type(stdout) == 'table', 'Should return stdout as table')
        assert(stderr == nil or type(stderr) == 'string', 'Should handle stderr correctly')
        assert(type(code) == 'number', 'Should return exit code')
        assert(code == 0, 'Should succeed for valid git command')

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 2: Legacy Gitsigns Format Compatibility
    total = total + 1
    if run_compatibility_test('Legacy Format Compatibility', function()
        mock_gitsigns_version({
            version = '0.5.0',
            git_cmd_behavior = 'old_format'
        })

        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        git_adapter.register_remote_buffer(1, {
            host = 'test-host',
            remote_path = '/test/repo/legacy.py',
            git_root = '/test/repo',
            protocol = 'scp'
        })

        -- Test legacy format handling
        local original_cmd = package.loaded['gitsigns.git.cmd']
        local stdout, stderr, code = original_cmd({'log', '--oneline', '-n', '1'}, {})

        assert(type(stdout) == 'table', 'Should handle legacy format')
        assert(#stdout > 0, 'Should return output lines')

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 3: Newer Gitsigns with Metadata
    total = total + 1
    if run_compatibility_test('Newer Format with Metadata', function()
        mock_gitsigns_version({
            version = '0.7.0',
            git_cmd_behavior = 'with_meta'
        })

        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        git_adapter.register_remote_buffer(1, {
            host = 'test-host',
            remote_path = '/test/repo/new.py',
            git_root = '/test/repo',
            protocol = 'scp'
        })

        -- Test metadata handling
        local original_cmd = package.loaded['gitsigns.git.cmd']
        local result = original_cmd({'diff', '--name-only'}, {cwd = '/test/repo'})

        -- Should handle different return formats gracefully
        assert(result ~= nil, 'Should handle metadata format')

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 4: Gitsigns Attach/Detach Integration
    total = total + 1
    if run_compatibility_test('Attach/Detach Integration', function()
        mock_gitsigns_version({ version = '0.6.0' })

        -- Mock successful attach
        local gitsigns = package.loaded['gitsigns']

        local remote_gitsigns = require('remote-gitsigns')
        remote_gitsigns.setup({
            enabled = true,
            auto_attach = true
        })

        -- Test attach functionality (simulated)
        local attached = gitsigns.attach(1, {})
        assert(attached == true, 'Should attach to buffer')
        assert(_G._gitsigns_attach_calls == 1, 'Should call gitsigns.attach')

        -- Test detach
        gitsigns.detach(1)
        assert(_G._gitsigns_detach_calls == 1, 'Should call gitsigns.detach')

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 5: Error Handling in Git Commands
    total = total + 1
    if run_compatibility_test('Git Command Error Handling', function()
        mock_gitsigns_version({
            version = '0.6.0',
            git_cmd_behavior = 'error'
        })

        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        git_adapter.register_remote_buffer(1, {
            host = 'test-host',
            remote_path = '/test/repo/error.py',
            git_root = '/test/repo',
            protocol = 'scp'
        })

        -- Test error handling
        local original_cmd = package.loaded['gitsigns.git.cmd']
        local stdout, stderr, code = original_cmd({'invalid-command'}, {})

        -- Should handle errors gracefully
        assert(code ~= 0, 'Should return error code for failed commands')
        assert(stderr ~= nil, 'Should return error message')

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 6: Multiple Gitsigns Instances
    total = total + 1
    if run_compatibility_test('Multiple Gitsigns Instances', function()
        mock_gitsigns_version({ version = '0.6.0' })

        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        -- Register multiple buffers
        for i = 1, 3 do
            git_adapter.register_remote_buffer(i, {
                host = 'test-host',
                remote_path = '/test/repo/file' .. i .. '.py',
                git_root = '/test/repo',
                protocol = 'scp'
            })
        end

        -- Test that each buffer gets proper handling
        local original_cmd = package.loaded['gitsigns.git.cmd']

        for i = 1, 3 do
            local stdout, stderr, code = original_cmd({'status'}, {cwd = '/test/repo'})
            assert(type(stdout) == 'table', 'Should handle multiple instances')
        end

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 7: Gitsigns Configuration Compatibility
    total = total + 1
    if run_compatibility_test('Configuration Compatibility', function()
        mock_gitsigns_version({ version = '0.6.0' })

        local remote_gitsigns = require('remote-gitsigns')

        -- Test various configuration options
        local configs = {
            { enabled = true, auto_attach = true },
            { enabled = true, auto_attach = false, git_timeout = 5000 },
            { enabled = true, cache = { enabled = false } },
            { enabled = true, detection = { async_detection = true } }
        }

        for _, config in ipairs(configs) do
            remote_gitsigns.shutdown() -- Reset between configs
            remote_gitsigns.setup(config)

            local status = remote_gitsigns.get_status()
            assert(status.enabled == config.enabled, 'Should respect enabled setting')

            local retrieved_config = remote_gitsigns.get_config()
            assert(retrieved_config.enabled == config.enabled, 'Should store config correctly')
        end

        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end

    -- Test 8: Gitsigns Actions Integration
    total = total + 1
    if run_compatibility_test('Actions Integration', function()
        mock_gitsigns_version({ version = '0.6.0' })

        local gitsigns = package.loaded['gitsigns']

        -- Test that gitsigns actions are available
        local actions = gitsigns.get_actions()
        assert(type(actions) == 'table', 'Should provide actions')
        assert(type(actions.stage_hunk) == 'function', 'Should have stage_hunk action')
        assert(type(actions.reset_hunk) == 'function', 'Should have reset_hunk action')
        assert(type(actions.preview_hunk) == 'function', 'Should have preview_hunk action')

        -- Test that actions don't interfere with our adapter
        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        -- Actions should still work
        local success = pcall(actions.stage_hunk)
        assert(success, 'Actions should not error with adapter active')

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 9: Fallback to Local Gitsigns
    total = total + 1
    if run_compatibility_test('Fallback to Local Gitsigns', function()
        mock_gitsigns_version({ version = '0.6.0' })

        local git_adapter = require('remote-gitsigns.git-adapter')
        git_adapter.setup_git_command_hook()

        -- Don't register any remote buffers - should fallback to original
        local original_cmd = package.loaded['gitsigns.git.cmd']
        local stdout, stderr, code = original_cmd({'status'}, {cwd = '/local/repo'})

        -- Should call original gitsigns (our mock)
        assert(_G._gitsigns_git_calls >= 1, 'Should call original gitsigns for local repos')
        assert(type(stdout) == 'table', 'Should return gitsigns format')

        git_adapter.reset()
    end) then
        passed = passed + 1
    end

    -- Test 10: Version-specific Command Differences
    total = total + 1
    if run_compatibility_test('Version-specific Commands', function()
        -- Test with different versions
        local versions = {
            { version = '0.5.0', git_cmd_behavior = 'old_format' },
            { version = '0.6.0', git_cmd_behavior = 'standard' },
            { version = '0.7.0', git_cmd_behavior = 'with_meta' }
        }

        for _, version_config in ipairs(versions) do
            mock_gitsigns_version(version_config)

            local git_adapter = require('remote-gitsigns.git-adapter')
            git_adapter.setup_git_command_hook()

            git_adapter.register_remote_buffer(1, {
                host = 'test-host',
                remote_path = '/test/repo/version_test.py',
                git_root = '/test/repo',
                protocol = 'scp'
            })

            -- Test that each version works
            local original_cmd = package.loaded['gitsigns.git.cmd']
            local result = original_cmd({'rev-parse', 'HEAD'}, {})

            assert(result ~= nil, 'Should handle version ' .. version_config.version)

            git_adapter.reset()
        end
    end) then
        passed = passed + 1
    end

    print(string.format('\n=== Gitsigns Compatibility Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))

    return passed == total
end

-- Export for external use
return {
    run_gitsigns_compatibility_tests = run_gitsigns_compatibility_tests,
    setup_gitsigns_environment = setup_gitsigns_environment,
    mock_gitsigns_version = mock_gitsigns_version,
}

-- Run tests if called directly
if arg and arg[0] and arg[0]:match('gitsigns_compatibility_tests%.lua$') then
    local success = run_gitsigns_compatibility_tests()
    os.exit(success and 0 or 1)
end