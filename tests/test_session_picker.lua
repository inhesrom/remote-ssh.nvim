-- Test file for session picker functionality
local test = require("tests.init")
local mocks = require("tests.mocks")

test.describe("Session Picker", function()
    local session_picker
    local test_data_path = "/tmp/test_remote_sessions.json"

    -- Reset function to clear session data between tests
    local function reset_session_data()
        if session_picker then
            session_picker.clear_history()
            session_picker.clear_pinned()
        end
    end

    test.setup(function()
        -- Mock vim functions
        _G.vim = _G.vim or {}
        _G.vim.fn = _G.vim.fn or {}
        _G.vim.fn.stdpath = function(what)
            if what == "data" then
                return "/tmp"
            end
            return "/tmp"
        end

        _G.vim.json = _G.vim.json or {}
        _G.vim.json.encode = function(data)
            -- Simple JSON encoding for tests
            return vim.inspect(data)
        end
        _G.vim.json.decode = function(str)
            -- Simple JSON decoding for tests
            return loadstring("return " .. str)()
        end

        _G.vim.api = _G.vim.api or {}
        _G.vim.api.nvim_create_autocmd = function() end
        _G.vim.api.nvim_create_augroup = function()
            return 1
        end

        _G.vim.log = _G.vim.log or {}
        _G.vim.log.levels = _G.vim.log.levels or { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

        _G.vim.tbl_filter = function(func, tbl)
            local result = {}
            for _, v in ipairs(tbl) do
                if func(v) then
                    table.insert(result, v)
                end
            end
            return result
        end

        _G.vim.tbl_contains = function(tbl, value)
            for _, v in ipairs(tbl) do
                if v == value then
                    return true
                end
            end
            return false
        end

        _G.vim.tbl_map = function(func, tbl)
            local result = {}
            for i, v in ipairs(tbl) do
                result[i] = func(v)
            end
            return result
        end

        _G.vim.deepcopy = function(tbl)
            if type(tbl) ~= "table" then
                return tbl
            end
            local result = {}
            for k, v in pairs(tbl) do
                result[k] = vim.deepcopy(v)
            end
            return result
        end

        _G.vim.list_extend = function(dst, src)
            for _, v in ipairs(src) do
                table.insert(dst, v)
            end
            return dst
        end

        _G.vim.list_slice = function(tbl, start, finish)
            local result = {}
            finish = finish or #tbl
            for i = start, finish do
                table.insert(result, tbl[i])
            end
            return result
        end

        -- Mock time function
        _G.os.time = function()
            return 1609459200
        end -- Fixed timestamp for tests
        _G.os.date = function(fmt, time)
            time = time or 1609459200
            return "01/01 00:00"
        end

        -- Mock file operations
        _G.io.open = function(path, mode)
            if mode == "r" then
                return nil -- No existing file for clean tests
            elseif mode == "w" then
                return {
                    write = function() end,
                    close = function() end,
                }
            end
        end

        -- Load session picker module
        package.loaded["async-remote-write.utils"] = {
            log = function() end,
            parse_remote_path = function(url)
                local user, host, path = url:match("rsync://([^@]+)@([^/]+)//(.+)")
                if user and host and path then
                    return { user = user, host = host, path = "/" .. path, protocol = "rsync" }
                end
                local host2, path2 = url:match("rsync://([^/]+)//(.+)")
                if host2 and path2 then
                    return { host = host2, path = "/" .. path2, protocol = "rsync" }
                end
                return { host = "testhost", path = "/test/path", protocol = "rsync" }
            end,
        }

        package.loaded["async-remote-write.config"] = {
            config = { debug = false },
        }

        package.loaded["async-remote-write.operations"] = {
            simple_open_remote_file = function() end,
        }

        -- Override data path for testing
        local original_stdpath = _G.vim.fn.stdpath
        _G.vim.fn.stdpath = function(what)
            if what == "data" then
                return "/tmp"
            end
            return original_stdpath(what)
        end

        session_picker = require("lua.async-remote-write.session_picker")
    end)

    test.teardown(function()
        -- Clean up test files
        os.remove(test_data_path)

        -- Reset packages
        package.loaded["async-remote-write.session_picker"] = nil
        package.loaded["async-remote-write.utils"] = nil
        package.loaded["async-remote-write.config"] = nil
        package.loaded["async-remote-write.operations"] = nil
    end)

    test.it("should track file opens", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/test.py"
        local metadata = { display_name = "test.py", full_path = "/home/user/test.py" }

        session_picker.track_file_open(url, metadata)

        local history = session_picker.get_history()
        test.assert.equals(#history, 1, "Should have one history entry")
        test.assert.equals(history[1].url, url, "Should store correct URL")
        test.assert.equals(history[1].type, "file", "Should have correct type")
        test.assert.truthy(history[1].timestamp, "Should have timestamp")
    end)

    test.it("should track tree browser opens", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/project"
        local metadata = { display_name = "/home/user/project", host = "testhost" }

        session_picker.track_tree_browser_open(url, metadata)

        local history = session_picker.get_history()
        test.assert.equals(#history, 1, "Should have one history entry")
        test.assert.equals(history[1].url, url, "Should store correct URL")
        test.assert.equals(history[1].type, "tree_browser", "Should have correct type")
    end)

    test.it("should avoid duplicate entries", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/test.py"
        local metadata = { display_name = "test.py" }

        -- Add same URL twice
        session_picker.track_file_open(url, metadata)
        session_picker.track_file_open(url, metadata)

        local history = session_picker.get_history()
        test.assert.equals(#history, 1, "Should only have one entry for duplicate URLs")
    end)

    test.it("should manage pinned sessions", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/config.lua"
        local metadata = { display_name = "config.lua" }

        -- Add to history first
        session_picker.track_file_open(url, metadata)

        local history = session_picker.get_history()
        local pinned = session_picker.get_pinned()

        test.assert.equals(#history, 1, "Should have one history entry")
        test.assert.equals(#pinned, 0, "Should have no pinned entries initially")

        -- Note: Can't test the actual pin/unpin UI functions without mocking the entire UI system
        -- but we can test the core data structures
    end)

    test.it("should clear history", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/test.py"
        local metadata = { display_name = "test.py" }

        session_picker.track_file_open(url, metadata)
        test.assert.equals(#session_picker.get_history(), 1, "Should have history entry")

        session_picker.clear_history()
        test.assert.equals(#session_picker.get_history(), 0, "Should have no history after clear")
    end)

    test.it("should clear pinned sessions", function()
        reset_session_data()

        session_picker.clear_pinned()
        test.assert.equals(#session_picker.get_pinned(), 0, "Should have no pinned sessions after clear")
    end)

    test.it("should provide statistics", function()
        reset_session_data()

        local stats = session_picker.get_stats()

        test.assert.truthy(stats.history_count ~= nil, "Should provide history count")
        test.assert.truthy(stats.pinned_count ~= nil, "Should provide pinned count")
        test.assert.truthy(stats.max_history ~= nil, "Should provide max history")
        test.assert.truthy(stats.total_sessions ~= nil, "Should provide total sessions")
    end)

    test.it("should configure max history size", function()
        reset_session_data()

        local original_stats = session_picker.get_stats()
        local original_max = original_stats.max_history

        session_picker.set_max_history(50)

        local new_stats = session_picker.get_stats()
        test.assert.equals(new_stats.max_history, 50, "Should update max history size")

        -- Reset to original
        session_picker.set_max_history(original_max)
    end)

    test.it("should handle session entry creation", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/test.py"
        local metadata = { display_name = "test.py", full_path = "/home/user/test.py" }

        session_picker.track_file_open(url, metadata)

        local history = session_picker.get_history()
        local entry = history[1]

        test.assert.equals(entry.url, url, "Should store URL")
        test.assert.equals(entry.type, "file", "Should store type")
        test.assert.equals(entry.display_name, "test.py", "Should store display name")
        test.assert.truthy(entry.id, "Should generate unique ID")
        test.assert.truthy(entry.timestamp, "Should store timestamp")
        test.assert.truthy(entry.host, "Should extract host")
    end)

    test.it("should handle different URL formats", function()
        reset_session_data()

        local urls = {
            "rsync://user@testhost//home/user/test.py",
            "rsync://testhost//home/user/test.py",
            "scp://user@testhost/home/user/test.py",
        }

        for _, url in ipairs(urls) do
            session_picker.track_file_open(url, { display_name = "test.py" })
        end

        local history = session_picker.get_history()
        test.assert.equals(#history, 3, "Should handle different URL formats")
    end)

    test.it("should preserve metadata", function()
        reset_session_data()

        local url = "rsync://user@testhost//home/user/test.py"
        local metadata = {
            display_name = "test.py",
            full_path = "/home/user/test.py",
            custom_field = "test_value",
        }

        session_picker.track_file_open(url, metadata)

        local history = session_picker.get_history()
        local entry = history[1]

        test.assert.equals(entry.metadata.display_name, "test.py", "Should preserve display name")
        test.assert.equals(entry.metadata.full_path, "/home/user/test.py", "Should preserve full path")
        test.assert.equals(entry.metadata.custom_field, "test_value", "Should preserve custom metadata")
    end)
end)
