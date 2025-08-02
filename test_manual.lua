#!/usr/bin/env lua
-- Manual test script for remote-gitsigns functionality
-- Run with: lua test_manual.lua

local function setup_test_environment()
    -- Set up package path
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
    
    -- Mock vim global with comprehensive APIs
    _G.vim = {
        log = { 
            levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
        },
        notify = function(msg, level, opts) 
            local level_name = {'DEBUG', 'INFO', 'WARN', 'ERROR'}[level] or 'INFO'
            print('[' .. level_name .. '] ' .. tostring(msg))
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
            for k, v in pairs(t) do
                copy[k] = vim.deepcopy(v)
            end
            return copy
        end,
        split = function(s, sep)
            local result = {}
            local pattern = '([^' .. sep .. ']*)'
            for part in string.gmatch(s .. sep, pattern .. sep) do
                if part ~= '' then
                    table.insert(result, part)
                end
            end
            return result
        end,
        trim = function(s)
            return s:match('^%s*(.-)%s*$')
        end,
        startswith = function(s, prefix)
            return s:sub(1, #prefix) == prefix
        end,
        list_extend = function(dst, src)
            for _, item in ipairs(src) do
                table.insert(dst, item)
            end
            return dst
        end,
        fs = {
            dirname = function(path)
                return path:match('(.*/)[^/]*$') or '.'
            end
        },
        loop = {
            new_timer = function()
                return {
                    start = function(self, delay, repeat_delay, callback)
                        return true
                    end,
                    stop = function(self)
                        return true
                    end
                }
            end
        },
        fn = {
            shellescape = function(s)
                return "'" .. s:gsub("'", "'\"'\"'") .. "'"
            end
        },
        defer_fn = function(fn, delay)
            -- Execute immediately in tests
            fn()
        end,
        schedule = function(fn)
            -- Execute immediately in tests  
            fn()
        end,
        system = function(cmd, opts)
            -- Mock system call
            local mock_responses = {
                ['.*git.*rev-parse.*'] = {
                    code = 0,
                    stdout = '/mock/git/root\n/mock/.git\nmain\n',
                    stderr = nil
                },
                ['.*git.*status.*'] = {
                    code = 0,
                    stdout = ' M file.py\n',
                    stderr = nil
                },
                ['.*test.*-d.*%.git.*'] = {
                    code = 0,
                    stdout = 'found',
                    stderr = nil
                }
            }
            
            return {
                wait = function()
                    local cmd_str = table.concat(cmd, ' ')
                    for pattern, response in pairs(mock_responses) do
                        if cmd_str:match(pattern) then
                            return response
                        end
                    end
                    -- Default response
                    return {
                        code = 0,
                        stdout = 'mock output',
                        stderr = nil
                    }
                end
            }
        end,
        api = {
            nvim_create_augroup = function(name, opts) 
                return math.random(1000)
            end,
            nvim_create_autocmd = function(events, opts) 
                return true 
            end,
            nvim_create_user_command = function(name, fn, opts) 
                return true 
            end,
            nvim_get_current_buf = function() 
                return 1 
            end,
            nvim_buf_is_valid = function(bufnr) 
                return true 
            end,
            nvim_buf_get_name = function(bufnr) 
                local names = {
                    [1] = 'scp://test-host//home/user/project/src/main.py',
                    [2] = 'scp://dev-server//opt/app/git-repo/file.js',
                    [3] = '/local/file.txt'
                }
                return names[bufnr] or 'scp://test-host//test/path/file.py'
            end,
            nvim_list_bufs = function() 
                return {1, 2, 3} 
            end,
        }
    }
    
    -- Mock os.time to return consistent values
    _G.os.time = function() return 1609459200 end -- 2021-01-01
    
    -- Mock dependencies
    package.loaded['logging'] = {
        log = function(msg, level, show_user, config) 
            if show_user then
                local level_names = {[1] = 'DEBUG', [2] = 'INFO', [3] = 'WARN', [4] = 'ERROR'}
                print('[LOG ' .. (level_names[level] or 'INFO') .. '] ' .. tostring(msg))
            end
        end
    }
    
    package.loaded['async-remote-write.utils'] = {
        parse_remote_path = function(path)
            if path:match('^scp://') then
                local host, remote_path = path:match('^scp://([^/]+)//(.+)$')
                if host and remote_path then
                    return {
                        protocol = 'scp',
                        host = host,
                        path = '/' .. remote_path
                    }
                end
            elseif path:match('^rsync://') then
                local host, remote_path = path:match('^rsync://([^/]+)//(.+)$')
                if host and remote_path then
                    return {
                        protocol = 'rsync', 
                        host = host,
                        path = '/' .. remote_path
                    }
                end
            end
            return nil
        end
    }
    
    package.loaded['async-remote-write.ssh_utils'] = {
        build_ssh_cmd = function(host, command)
            return {'ssh', '-o', 'ConnectTimeout=10', host, command}
        end
    }
    
    package.loaded['remote-buffer-metadata'] = {
        set = function(bufnr, namespace, key, value) 
            -- Store in a mock registry
            _G._mock_metadata = _G._mock_metadata or {}
            _G._mock_metadata[bufnr] = _G._mock_metadata[bufnr] or {}
            _G._mock_metadata[bufnr][namespace] = _G._mock_metadata[bufnr][namespace] or {}
            _G._mock_metadata[bufnr][namespace][key] = value
        end,
        get = function(bufnr, namespace, key) 
            if _G._mock_metadata and _G._mock_metadata[bufnr] and 
               _G._mock_metadata[bufnr][namespace] then
                return _G._mock_metadata[bufnr][namespace][key]
            end
            return nil
        end,
        clear_namespace = function(bufnr, namespace) 
            if _G._mock_metadata and _G._mock_metadata[bufnr] then
                _G._mock_metadata[bufnr][namespace] = nil
            end
        end
    }
    
    -- Mock gitsigns for integration tests
    package.loaded['gitsigns'] = {
        attach = function(bufnr) 
            print('Mock gitsigns attached to buffer ' .. bufnr)
            return true 
        end,
        refresh = function(bufnr)
            print('Mock gitsigns refreshed buffer ' .. bufnr)
            return true
        end
    }
    
    package.loaded['gitsigns.git.cmd'] = function(args, spec)
        print('Mock gitsigns git command: ' .. table.concat(args, ' '))
        return {'mock git output line 1', 'mock git output line 2'}, nil, 0
    end
end

local function run_test(name, test_fn)
    io.write('Running ' .. name .. '... ')
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

local function run_tests()
    print('Setting up test environment...')
    setup_test_environment()
    
    local passed = 0
    local total = 0
    
    print('\n=== Remote Gitsigns Manual Tests ===\n')
    
    -- Test 1: Module Loading
    total = total + 1
    if run_test('Module Loading', function()
        local cache = require('remote-gitsigns.cache')
        local remote_git = require('remote-gitsigns.remote-git')
        local git_adapter = require('remote-gitsigns.git-adapter')
        local buffer_detector = require('remote-gitsigns.buffer-detector')
        local remote_gitsigns = require('remote-gitsigns')
        
        assert(cache ~= nil, 'cache module should load')
        assert(remote_git ~= nil, 'remote_git module should load')
        assert(git_adapter ~= nil, 'git_adapter module should load')
        assert(buffer_detector ~= nil, 'buffer_detector module should load')
        assert(remote_gitsigns ~= nil, 'remote_gitsigns module should load')
    end) then
        passed = passed + 1
    end
    
    -- Test 2: Cache Functionality
    total = total + 1
    if run_test('Cache Functionality', function()
        local cache = require('remote-gitsigns.cache')
        
        -- Test basic set/get
        cache.set('test_value', 'test_key')
        local value = cache.get('test_key')
        assert(value == 'test_value', 'cache should store and retrieve values')
        
        -- Test multi-key
        cache.set('multi_value', 'key1', 'key2', 'key3')
        local multi_value = cache.get('key1', 'key2', 'key3')
        assert(multi_value == 'multi_value', 'cache should handle multiple key components')
        
        -- Test has()
        assert(cache.has('test_key') == true, 'cache should report existing keys')
        assert(cache.has('nonexistent') == false, 'cache should report non-existing keys')
        
        -- Test delete
        cache.delete('test_key')
        assert(cache.get('test_key') == nil, 'cache should delete values')
        
        -- Test convenience functions
        cache.cache_repo_info('host', 'workdir', {branch = 'main'})
        local repo_info = cache.get_repo_info('host', 'workdir')
        assert(repo_info.branch == 'main', 'cache should store repo info')
    end) then
        passed = passed + 1
    end
    
    -- Test 3: Remote Git Operations
    total = total + 1  
    if run_test('Remote Git Operations', function()
        local remote_git = require('remote-gitsigns.remote-git')
        
        -- Test git root finding
        local git_root = remote_git.find_git_root('test-host', '/home/user/project/file.py')
        assert(git_root ~= nil, 'should find git root')
        
        -- Test repo info
        local repo_info = remote_git.get_repo_info('test-host', '/home/user/project')
        assert(repo_info ~= nil, 'should get repo info')
        
        -- Test git command execution
        local cmd_result = remote_git.execute_git_command('test-host', '/workdir', {'status'})
        assert(cmd_result.code == 0, 'git command should succeed')
        assert(type(cmd_result.stdout) == 'table', 'should return stdout as table')
        
        -- Test is_git_repo
        local is_repo, root = remote_git.is_git_repo('test-host', '/home/user/project/file.py')
        assert(type(is_repo) == 'boolean', 'is_git_repo should return boolean')
    end) then
        passed = passed + 1
    end
    
    -- Test 4: Git Adapter
    total = total + 1
    if run_test('Git Adapter', function()
        local git_adapter = require('remote-gitsigns.git-adapter')
        
        -- Test hook setup
        local hook_success = git_adapter.setup_git_command_hook()
        assert(hook_success == true, 'should setup git command hook')
        assert(git_adapter.is_active() == true, 'adapter should be active after setup')
        
        -- Test buffer registration
        local reg_success = git_adapter.register_remote_buffer(1, {
            host = 'test-host',
            remote_path = '/test/path',
            git_root = '/test',
            protocol = 'scp'
        })
        assert(reg_success == true, 'should register remote buffer')
        
        local remote_info = git_adapter.get_remote_info(1)
        assert(remote_info ~= nil, 'should get remote info for registered buffer')
        assert(remote_info.host == 'test-host', 'should store correct host')
        
        -- Test unregistration
        git_adapter.unregister_remote_buffer(1)
        local info_after = git_adapter.get_remote_info(1)
        assert(info_after == nil, 'should unregister buffer')
        
        -- Test reset
        git_adapter.reset()
        assert(git_adapter.is_active() == false, 'should reset adapter')
    end) then
        passed = passed + 1
    end
    
    -- Test 5: Buffer Detector
    total = total + 1
    if run_test('Buffer Detector', function()
        local buffer_detector = require('remote-gitsigns.buffer-detector')
        
        -- Test configuration
        local config = buffer_detector.get_config()
        assert(config ~= nil, 'should have configuration')
        assert(type(config.exclude_patterns) == 'table', 'should have exclude patterns')
        
        buffer_detector.configure({async_detection = false})
        local new_config = buffer_detector.get_config()
        assert(new_config.async_detection == false, 'should update configuration')
        
        -- Test buffer detection (will return false for non-git paths in our mock)
        local is_git = buffer_detector.check_remote_git_buffer(3) -- Local file
        assert(is_git == false, 'should reject local files')
        
        -- Test setup detection (should not error)
        buffer_detector.setup_detection()
        
        -- Test reset
        buffer_detector.reset()
    end) then
        passed = passed + 1
    end
    
    -- Test 6: Main Module Integration
    total = total + 1
    if run_test('Main Module Integration', function()
        local remote_gitsigns = require('remote-gitsigns')
        
        -- Test setup
        remote_gitsigns.setup({
            enabled = true,
            cache = {enabled = true, ttl = 60},
            detection = {async_detection = false},
            auto_attach = false
        })
        
        assert(remote_gitsigns.is_initialized() == true, 'should initialize successfully')
        
        -- Test status
        local status = remote_gitsigns.get_status()
        assert(status ~= nil, 'should provide status')
        assert(status.initialized == true, 'status should show initialized')
        assert(status.enabled == true, 'status should show enabled')
        
        -- Test configuration retrieval
        local config = remote_gitsigns.get_config()
        assert(config ~= nil, 'should provide configuration')
        assert(config.enabled == true, 'config should show enabled')
        
        -- Test buffer operations
        local detected = remote_gitsigns.detect_buffer(1) -- Remote buffer
        -- Note: May return nil for async operations, that's OK
        
        -- Test shutdown
        remote_gitsigns.shutdown()
        assert(remote_gitsigns.is_initialized() == false, 'should shutdown successfully')
    end) then
        passed = passed + 1
    end
    
    -- Test 7: Error Handling
    total = total + 1
    if run_test('Error Handling', function()
        local remote_gitsigns = require('remote-gitsigns')
        
        -- Test disabled setup
        remote_gitsigns.setup({enabled = false})
        assert(remote_gitsigns.is_initialized() == false, 'should not initialize when disabled')
        
        -- Test operations on uninitialized module
        local status = remote_gitsigns.get_status()
        assert(status.initialized == false, 'status should show not initialized')
        
        -- Test double shutdown (should not error)
        remote_gitsigns.shutdown()
        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end
    
    -- Test 8: Full Workflow Simulation
    total = total + 1
    if run_test('Full Workflow Simulation', function()
        -- Start fresh
        for k, v in pairs(package.loaded) do
            if k:match('^remote%-gitsigns') then
                package.loaded[k] = nil
            end
        end
        
        local remote_gitsigns = require('remote-gitsigns')
        
        -- Setup with full configuration
        remote_gitsigns.setup({
            enabled = true,
            git_timeout = 15000,
            cache = {
                enabled = true,
                ttl = 300,
                max_entries = 100
            },
            detection = {
                async_detection = false,
                exclude_patterns = {'*/%.git/*'}
            },
            auto_attach = true
        })
        
        assert(remote_gitsigns.is_initialized(), 'should initialize with full config')
        
        -- Simulate opening remote files
        local results = remote_gitsigns.detect_all_buffers(function(detection_results)
            -- This callback might be called async
            print('Detection completed for ' .. #vim.api.nvim_list_bufs() .. ' buffers')
        end)
        
        -- Test refresh
        local refresh_success = remote_gitsigns.refresh_buffer(1)
        
        -- Final cleanup
        remote_gitsigns.shutdown()
    end) then
        passed = passed + 1
    end
    
    -- Summary
    print(string.format('\n=== Test Summary ==='))
    print(string.format('Passed: %d/%d tests', passed, total))
    
    if passed == total then
        print('🎉 All tests passed! Remote gitsigns implementation is working correctly.')
        return true
    else
        print('❌ Some tests failed. Please check the implementation.')
        return false
    end
end

-- Run the tests
local success = run_tests()

if success then
    print('\n✅ Remote gitsigns is ready for use!')
    print('\nTo use it in your Neovim config:')
    print([[
require('remote-ssh').setup({
    -- ... your existing remote-ssh config ...
    
    gitsigns = {
        enabled = true,
        auto_attach = true,
        cache = {
            enabled = true,
            ttl = 300, -- 5 minutes
        }
    }
})
    ]])
    print('\nThen open remote files like: :e scp://your-host//path/to/git/repo/file.py')
    os.exit(0)
else
    print('\n❌ Tests failed. Implementation needs fixes.')
    os.exit(1)
end