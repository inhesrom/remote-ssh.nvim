-- Comprehensive tests for remote-gitsigns functionality
-- Run with: busted tests/remote_gitsigns_spec.lua

local function setup_vim_mocks()
    -- Mock vim global with all necessary APIs
    _G.vim = {
        log = {
            levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
        },
        notify = function(msg, level)
            print('[NOTIFY] ' .. tostring(msg))
        end,
        tbl_deep_extend = function(behavior, ...)
            local result = {}
            for _, t in ipairs({...}) do
                if type(t) == 'table' then
                    for k, v in pairs(t) do
                        if type(v) == 'table' and type(result[k]) == 'table' then
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
        fs = {
            dirname = function(path)
                return path:match('(.*/)[^/]*$') or '.'
            end
        },
        loop = {
            new_timer = function()
                return {
                    start = function() end,
                    stop = function() end
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
            -- Mock system call that returns immediately
            return {
                wait = function()
                    return {
                        code = 0,
                        stdout = 'mock output',
                        stderr = nil
                    }
                end
            }
        end,
        api = {
            nvim_create_augroup = function(name, opts) return 1 end,
            nvim_create_autocmd = function(events, opts) return true end,
            nvim_create_user_command = function(name, fn, opts) return true end,
            nvim_get_current_buf = function() return 1 end,
            nvim_buf_is_valid = function(bufnr) return true end,
            nvim_buf_get_name = function(bufnr) return 'scp://test-host//test/path/file.py' end,
            nvim_list_bufs = function() return {1, 2, 3} end,
        }
    }

    -- Mock os functions
    _G.os.time = function() return 1000000 end

    -- Set up package path
    package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
end

describe('Remote Gitsigns', function()
    local remote_gitsigns, cache, git_adapter, buffer_detector, remote_git

    before_each(function()
        setup_vim_mocks()

        -- Clear package cache
        package.loaded['remote-gitsigns'] = nil
        package.loaded['remote-gitsigns.cache'] = nil
        package.loaded['remote-gitsigns.git-adapter'] = nil
        package.loaded['remote-gitsigns.buffer-detector'] = nil
        package.loaded['remote-gitsigns.remote-git'] = nil
        package.loaded['logging'] = nil
        package.loaded['async-remote-write.utils'] = nil
        package.loaded['async-remote-write.ssh_utils'] = nil
        package.loaded['remote-buffer-metadata'] = nil

        -- Mock dependencies
        package.loaded['logging'] = {
            log = function(msg, level, show_user, config)
                -- Silent in tests unless explicitly needed
            end
        }

        package.loaded['async-remote-write.utils'] = {
            parse_remote_path = function(path)
                if path:match('^scp://') or path:match('^rsync://') then
                    return {
                        protocol = 'scp',
                        host = 'test-host',
                        path = '/test/path/file.py'
                    }
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
    end)

    describe('Cache Module', function()
        before_each(function()
            cache = require('remote-gitsigns.cache')
        end)

        it('should load without errors', function()
            assert.is_not_nil(cache)
            assert.is_function(cache.get)
            assert.is_function(cache.set)
            assert.is_function(cache.has)
            assert.is_function(cache.delete)
            assert.is_function(cache.clear)
        end)

        it('should store and retrieve values', function()
            cache.set('test_value', 'test_key')
            local value = cache.get('test_key')
            assert.equals('test_value', value)
        end)

        it('should handle multiple key components', function()
            cache.set('multi_value', 'key1', 'key2', 'key3')
            local value = cache.get('key1', 'key2', 'key3')
            assert.equals('multi_value', value)
        end)

        it('should return nil for non-existent keys', function()
            local value = cache.get('non_existent_key')
            assert.is_nil(value)
        end)

        it('should support has() checking', function()
            cache.set('test', 'exists')
            assert.is_true(cache.has('exists'))
            assert.is_false(cache.has('does_not_exist'))
        end)

        it('should support deletion', function()
            cache.set('to_delete', 'delete_key')
            assert.is_true(cache.has('delete_key'))
            cache.delete('delete_key')
            assert.is_false(cache.has('delete_key'))
        end)

        it('should provide statistics', function()
            local stats = cache.get_stats()
            assert.is_table(stats)
            assert.is_number(stats.hits)
            assert.is_number(stats.misses)
            assert.is_number(stats.sets)
        end)

        it('should support configuration', function()
            local old_config = cache.get_config()
            cache.configure({ ttl = 600 })
            local new_config = cache.get_config()
            assert.equals(600, new_config.ttl)
        end)

        it('should provide convenience functions for git data', function()
            -- Test repo info caching
            cache.cache_repo_info('host', 'workdir', { branch = 'main' })
            local info = cache.get_repo_info('host', 'workdir')
            assert.equals('main', info.branch)

            -- Test git root caching
            cache.cache_git_root('host', '/path/file', '/path')
            local root = cache.get_git_root('host', '/path/file')
            assert.equals('/path', root)
        end)
    end)

    describe('Remote Git Module', function()
        before_each(function()
            remote_git = require('remote-gitsigns.remote-git')
        end)

        it('should load without errors', function()
            assert.is_not_nil(remote_git)
            assert.is_function(remote_git.find_git_root)
            assert.is_function(remote_git.get_repo_info)
            assert.is_function(remote_git.execute_git_command)
            assert.is_function(remote_git.is_git_repo)
        end)

        it('should cache git root lookups', function()
            -- Mock successful git root discovery
            vim.system = function(cmd, opts)
                return {
                    wait = function()
                        return {
                            code = 0,
                            stdout = 'found',
                            stderr = nil
                        }
                    end
                }
            end

            local root1 = remote_git.find_git_root('test-host', '/test/path/file.py')
            local root2 = remote_git.find_git_root('test-host', '/test/path/file.py')

            -- Should return the same result (cached)
            assert.equals(root1, root2)
        end)

        it('should handle git command execution', function()
            vim.system = function(cmd, opts)
                return {
                    wait = function()
                        return {
                            code = 0,
                            stdout = 'line1\nline2\nline3\n',
                            stderr = nil
                        }
                    end
                }
            end

            local result = remote_git.execute_git_command('test-host', '/workdir', {'status'})
            assert.is_table(result)
            assert.equals(0, result.code)
            assert.is_table(result.stdout)
            assert.equals(3, #result.stdout)
        end)

        it('should provide cache statistics', function()
            local stats = remote_git.get_cache_stats()
            assert.is_table(stats)
            assert.is_number(stats.total)
            assert.is_number(stats.expired)
            assert.is_number(stats.ttl)
        end)

        it('should support cache clearing', function()
            -- Add some cached data
            remote_git.find_git_root('test-host', '/test/path')

            local stats_before = remote_git.get_cache_stats()
            remote_git.clear_cache()
            local stats_after = remote_git.get_cache_stats()

            assert.equals(0, stats_after.total)
        end)
    end)

    describe('Git Adapter Module', function()
        before_each(function()
            -- Mock gitsigns module
            package.loaded['gitsigns.git.cmd'] = function(args, spec)
                return {'mock_output'}, nil, 0
            end

            git_adapter = require('remote-gitsigns.git-adapter')
        end)

        it('should load without errors', function()
            assert.is_not_nil(git_adapter)
            assert.is_function(git_adapter.setup_git_command_hook)
            assert.is_function(git_adapter.register_remote_buffer)
            assert.is_function(git_adapter.unregister_remote_buffer)
        end)

        it('should setup git command hook', function()
            local success = git_adapter.setup_git_command_hook()
            assert.is_true(success)
            assert.is_true(git_adapter.is_active())
        end)

        it('should register and unregister remote buffers', function()
            local success = git_adapter.register_remote_buffer(1, {
                host = 'test-host',
                remote_path = '/test/path',
                git_root = '/test',
                protocol = 'scp'
            })
            assert.is_true(success)

            local info = git_adapter.get_remote_info(1)
            assert.is_table(info)
            assert.equals('test-host', info.host)

            git_adapter.unregister_remote_buffer(1)
            local info_after = git_adapter.get_remote_info(1)
            assert.is_nil(info_after)
        end)

        it('should support resetting', function()
            git_adapter.setup_git_command_hook()
            assert.is_true(git_adapter.is_active())

            git_adapter.reset()
            assert.is_false(git_adapter.is_active())
        end)
    end)

    describe('Buffer Detector Module', function()
        before_each(function()
            -- Mock git adapter
            package.loaded['remote-gitsigns.git-adapter'] = {
                register_remote_buffer = function() return true end,
                unregister_remote_buffer = function() end
            }

            -- Mock remote git
            package.loaded['remote-gitsigns.remote-git'] = {
                find_git_root = function(host, path)
                    if path:match('/git/') then
                        return '/git/root'
                    end
                    return nil
                end
            }

            buffer_detector = require('remote-gitsigns.buffer-detector')
        end)

        it('should load without errors', function()
            assert.is_not_nil(buffer_detector)
            assert.is_function(buffer_detector.check_remote_git_buffer)
            assert.is_function(buffer_detector.setup_detection)
            assert.is_function(buffer_detector.detect_buffer)
        end)

        it('should detect git repositories in remote buffers', function()
            -- Mock buffer name to include 'git' so our mock returns a git root
            vim.api.nvim_buf_get_name = function(bufnr)
                return 'scp://test-host//git/project/file.py'
            end

            local result = buffer_detector.check_remote_git_buffer(1)
            assert.is_true(result)
        end)

        it('should reject non-remote buffers', function()
            vim.api.nvim_buf_get_name = function(bufnr)
                return '/local/file.py'
            end

            local result = buffer_detector.check_remote_git_buffer(1)
            assert.is_false(result)
        end)

        it('should support configuration', function()
            local config = buffer_detector.get_config()
            assert.is_table(config)
            assert.is_table(config.exclude_patterns)

            buffer_detector.configure({ async_detection = false })
            local new_config = buffer_detector.get_config()
            assert.is_false(new_config.async_detection)
        end)

        it('should provide buffer status', function()
            -- First check the buffer
            vim.api.nvim_buf_get_name = function(bufnr)
                return 'scp://test-host//git/project/file.py'
            end

            buffer_detector.check_remote_git_buffer(1)
            local status = buffer_detector.get_buffer_status(1)
            assert.is_table(status)
        end)

        it('should support reset', function()
            vim.api.nvim_buf_get_name = function(bufnr)
                return 'scp://test-host//git/project/file.py'
            end

            buffer_detector.check_remote_git_buffer(1)
            local status_before = buffer_detector.get_buffer_status(1)
            assert.is_not_nil(status_before)

            buffer_detector.reset()
            local status_after = buffer_detector.get_buffer_status(1)
            assert.is_nil(status_after)
        end)
    end)

    describe('Main Remote Gitsigns Module', function()
        before_each(function()
            -- Mock gitsigns availability
            package.loaded['gitsigns'] = {
                attach = function(bufnr) return true end
            }

            remote_gitsigns = require('remote-gitsigns')
        end)

        it('should load without errors', function()
            assert.is_not_nil(remote_gitsigns)
            assert.is_function(remote_gitsigns.setup)
            assert.is_function(remote_gitsigns.is_initialized)
            assert.is_function(remote_gitsigns.get_status)
        end)

        it('should setup successfully', function()
            local success = pcall(function()
                remote_gitsigns.setup({
                    enabled = true,
                    cache = { enabled = false },
                    auto_attach = false
                })
            end)
            assert.is_true(success)
            assert.is_true(remote_gitsigns.is_initialized())
        end)

        it('should provide status information', function()
            remote_gitsigns.setup({ enabled = true })
            local status = remote_gitsigns.get_status()
            assert.is_table(status)
            assert.is_boolean(status.initialized)
            assert.is_boolean(status.enabled)
        end)

        it('should support configuration retrieval', function()
            remote_gitsigns.setup({
                enabled = true,
                git_timeout = 15000
            })
            local config = remote_gitsigns.get_config()
            assert.is_table(config)
            assert.equals(15000, config.git_timeout)
        end)

        it('should handle shutdown', function()
            remote_gitsigns.setup({ enabled = true })
            assert.is_true(remote_gitsigns.is_initialized())

            remote_gitsigns.shutdown()
            assert.is_false(remote_gitsigns.is_initialized())
        end)

        it('should handle disabled configuration', function()
            local success = pcall(function()
                remote_gitsigns.setup({ enabled = false })
            end)
            assert.is_true(success)
            -- Should not initialize when disabled
            assert.is_false(remote_gitsigns.is_initialized())
        end)
    end)

    describe('Integration Tests', function()
        it('should handle complete workflow', function()
            -- Setup all components
            setup_vim_mocks()

            -- Mock gitsigns
            package.loaded['gitsigns'] = {
                attach = function(bufnr) return true end
            }

            -- Load and setup remote gitsigns
            local remote_gitsigns = require('remote-gitsigns')
            remote_gitsigns.setup({
                enabled = true,
                cache = { enabled = true, ttl = 60 },
                detection = { async_detection = false },
                auto_attach = false
            })

            assert.is_true(remote_gitsigns.is_initialized())

            -- Test buffer detection
            vim.api.nvim_buf_get_name = function(bufnr)
                return 'scp://test-host//git/project/file.py'
            end

            local detected = remote_gitsigns.detect_buffer(1)
            -- Note: May be nil for async detection, that's OK

            -- Test status
            local status = remote_gitsigns.get_status()
            assert.is_table(status)
            assert.is_true(status.initialized)

            -- Test shutdown
            remote_gitsigns.shutdown()
            assert.is_false(remote_gitsigns.is_initialized())
        end)
    end)
end)