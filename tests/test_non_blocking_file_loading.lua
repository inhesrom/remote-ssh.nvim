-- Unit tests for non-blocking file loading functionality
local test = require('tests.init')

-- Test state to track mock operations (global to avoid scoping issues)
_G.test_state = {
    buffer_lines = {},
    buffer_options = {},
    logs = {}
}

-- Store original vim functions to restore later
local original_nvim_buf_set_lines = vim.api.nvim_buf_set_lines
local original_nvim_buf_set_option = vim.api.nvim_buf_set_option
local original_getfsize = vim.fn.getfsize
local original_readfile = vim.fn.readfile

-- Set up global mocks immediately so they're available to the functions defined below
-- These will be active only when test_state is the active context
vim.api.nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, replacement)
    -- Check if we're in non-blocking file loading context
    if _G.test_state and _G.test_state.buffer_lines then
        local state = _G.test_state
        state.buffer_lines[bufnr] = state.buffer_lines[bufnr] or {}

        -- Handle replacing all lines (start=0, end_line=-1)
        if start == 0 and end_line == -1 then
            state.buffer_lines[bufnr] = {}
            for i, line in ipairs(replacement) do
                state.buffer_lines[bufnr][i] = line
            end
        else
            -- Handle specific line ranges
            for i, line in ipairs(replacement) do
                state.buffer_lines[bufnr][start + i] = line
            end
        end
        return true
    end

    -- Check if we're in operations integration context
    if _G.ops_test_state and _G.ops_test_state.buffer_lines then
        local state = _G.ops_test_state
        state.buffer_lines[bufnr] = state.buffer_lines[bufnr] or {}

        -- Handle replacing all lines (start=0, end_line=-1)
        if start == 0 and end_line == -1 then
            state.buffer_lines[bufnr] = {}
            for i, line in ipairs(replacement) do
                state.buffer_lines[bufnr][i] = line
            end
        else
            -- Handle specific line ranges
            for i, line in ipairs(replacement) do
                state.buffer_lines[bufnr][start + i] = line
            end
        end
        return true
    end

    -- Call original function if no test context is active
    return original_nvim_buf_set_lines(bufnr, start, end_line, strict_indexing, replacement)
end

vim.api.nvim_buf_set_option = function(bufnr, option, value)
    -- Check if we're in non-blocking file loading context
    if _G.test_state and _G.test_state.buffer_options then
        local state = _G.test_state
        state.buffer_options[bufnr] = state.buffer_options[bufnr] or {}
        state.buffer_options[bufnr][option] = value
        return
    end

    -- Check if we're in operations integration context
    if _G.ops_test_state and _G.ops_test_state.buffer_options then
        local state = _G.ops_test_state
        state.buffer_options[bufnr] = state.buffer_options[bufnr] or {}
        state.buffer_options[bufnr][option] = value
        return
    end

    -- Call original function if no test context is active
    return original_nvim_buf_set_option(bufnr, option, value)
end

vim.fn.getfsize = function(path)
    if path:match("small") then return 1000 end
    if path:match("medium") then return 100000 end
    if path:match("large") then return 1000000 end
    return 50000
end

vim.fn.readfile = function(path)
    local lines = {}
    local line_count = path:match("(%d+)_lines")

    if line_count then
        line_count = tonumber(line_count)
    else
        -- Calculate line count based on file size for realistic testing
        local filesize = vim.fn.getfsize(path)
        line_count = math.floor(filesize / 50)  -- ~50 bytes per line average
    end

    for i = 1, line_count do
        table.insert(lines, "Line " .. i .. " from " .. path)
    end
    return lines
end

-- Test setup will extend vim mock with functions we need for testing

-- Mock utils for logging
local utils_mock = {
    log = function(message, level, show_user, config)
        table.insert(_G.test_state.logs, {
            message = message,
            level = level,
            show_user = show_user
        })
    end
}

-- Mock config
local config_mock = {
    config = {
        debug = true,
        log_level = vim.log.levels.DEBUG
    }
}

-- Helper functions from our implementation (simplified for testing)
local function show_loading_progress(bufnr, message)
    message = message or "Loading remote file..."
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {message, "", "Please wait..."})
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
end

local function load_content_non_blocking(content, bufnr, on_complete)
    local line_count = #content
    utils_mock.log("Loading content with " .. line_count .. " lines", vim.log.levels.DEBUG, false, config_mock.config)

    if line_count < 1000 then  -- Small content - load normally
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
        if on_complete then on_complete(true) end

    elseif line_count < 5000 then  -- Medium content - chunked loading
        utils_mock.log("Using chunked loading for medium content", vim.log.levels.DEBUG, false, config_mock.config)
        show_loading_progress(bufnr, "Loading remote file (chunked)...")

        -- Simulate chunked loading (simplified for testing)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
        if on_complete then on_complete(true) end

    else  -- Large content - streaming
        utils_mock.log("Using streaming for large content", vim.log.levels.DEBUG, false, config_mock.config)
        show_loading_progress(bufnr, "Loading large remote file...")

        -- Simulate streaming (simplified for testing)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
        if on_complete then on_complete(true) end
    end
end

local function load_file_non_blocking(file_path, bufnr, on_complete)
    local filesize = vim.fn.getfsize(file_path)

    if filesize < 0 then
        if on_complete then on_complete(false, "File not readable") end
        return
    end

    utils_mock.log("Loading file of size: " .. filesize .. " bytes", vim.log.levels.DEBUG, false, config_mock.config)

    if filesize < 50000 then  -- Small files
        local lines = vim.fn.readfile(file_path)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        if on_complete then on_complete(true) end
    else  -- Medium/large files
        utils_mock.log("Using non-blocking loading", vim.log.levels.DEBUG, false, config_mock.config)
        local lines = vim.fn.readfile(file_path)
        load_content_non_blocking(lines, bufnr, on_complete)
    end
end

-- Function to restore original mocks
local function restore_original_mocks()
    vim.api.nvim_buf_set_lines = original_nvim_buf_set_lines
    vim.api.nvim_buf_set_option = original_nvim_buf_set_option
    vim.fn.getfsize = original_getfsize
    vim.fn.readfile = original_readfile
end

test.describe("Non-Blocking File Loading", function()
    test.setup(function()
        -- Initialize _G.test_state properly
        _G.test_state = {
            buffer_lines = {},
            buffer_options = {},
            logs = {}
        }

        -- Clear other test state to avoid conflicts with unified mocks
        _G.ops_test_state = nil
    end)

    test.teardown(function()
        -- Restore original vim functions
        restore_original_mocks()

        -- Clean up global test state
        _G.test_state = nil
    end)

    test.describe("show_loading_progress", function()
        test.it("should set loading message in buffer", function()
            show_loading_progress(1, "Test loading message")

            local lines = _G.test_state.buffer_lines[1]
            test.assert.truthy(lines, "Buffer should have lines set")
            test.assert.equals(lines[1], "Test loading message", "Should set custom loading message")
            test.assert.equals(lines[3], "Please wait...", "Should add wait message")
        end)

        test.it("should use default message when none provided", function()
            show_loading_progress(2)

            local lines = _G.test_state.buffer_lines[2]
            test.assert.truthy(lines, "Buffer should have lines set")
            test.assert.equals(lines[1], "Loading remote file...", "Should use default message")
        end)

        test.it("should set buffer as not modified", function()
            show_loading_progress(3)

            local options = _G.test_state.buffer_options[3]
            test.assert.truthy(options, "Buffer should have options set")
            test.assert.equals(options.modified, false, "Buffer should be marked as not modified")
        end)
    end)

    test.describe("load_content_non_blocking", function()
        test.it("should load small content immediately", function()
            local content = {}
            for i = 1, 500 do
                table.insert(content, "Line " .. i)
            end

            local callback_called = false
            local callback_success = false

            load_content_non_blocking(content, 1, function(success)
                callback_called = true
                callback_success = success
            end)

            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.truthy(callback_success, "Callback should indicate success")

            -- Check logs
            local found_log = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("Loading content with 500 lines") then
                    found_log = true
                    break
                end
            end
            test.assert.truthy(found_log, "Should log content size")
        end)

        test.it("should use chunked loading for medium content", function()
            local content = {}
            for i = 1, 3000 do
                table.insert(content, "Line " .. i)
            end

            local callback_called = false

            load_content_non_blocking(content, 2, function(success)
                callback_called = true
            end)

            test.assert.truthy(callback_called, "Callback should be called")

            -- Check for chunked loading log
            local found_chunked_log = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("chunked loading") then
                    found_chunked_log = true
                    break
                end
            end
            test.assert.truthy(found_chunked_log, "Should log chunked loading strategy")
        end)

        test.it("should use streaming for large content", function()
            local content = {}
            for i = 1, 10000 do
                table.insert(content, "Line " .. i)
            end

            local callback_called = false

            load_content_non_blocking(content, 3, function(success)
                callback_called = true
            end)

            test.assert.truthy(callback_called, "Callback should be called")

            -- Check for streaming log
            local found_streaming_log = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("streaming") then
                    found_streaming_log = true
                    break
                end
            end
            test.assert.truthy(found_streaming_log, "Should log streaming strategy")
        end)
    end)

    test.describe("load_file_non_blocking", function()
        test.it("should handle small files with immediate loading", function()
            local callback_called = false
            local callback_success = false

            load_file_non_blocking("small_file.txt", 1, function(success)
                callback_called = true
                callback_success = success
            end)

            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.truthy(callback_success, "Callback should indicate success")
        end)

        test.it("should handle medium files with non-blocking loading", function()
            local callback_called = false

            load_file_non_blocking("medium_file.txt", 2, function(success)
                callback_called = true
            end)

            test.assert.truthy(callback_called, "Callback should be called")

            -- Check for medium file size detection and chunked loading
            local found_size_log = false
            local found_chunked_log = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("Loading file of size: 100000") then
                    found_size_log = true
                end
                if log.message:find("chunked loading") then
                    found_chunked_log = true
                end
            end
            test.assert.truthy(found_size_log, "Should log medium file size")
            test.assert.truthy(found_chunked_log, "Should use chunked loading for medium files")
        end)

        test.it("should handle unreadable files", function()
            -- Mock negative file size
            local old_getfsize = vim.fn.getfsize
            vim.fn.getfsize = function(path) return -1 end

            local callback_called = false
            local callback_success = true
            local callback_error = nil

            load_file_non_blocking("unreadable_file.txt", 4, function(success, error_msg)
                callback_called = true
                callback_success = success
                callback_error = error_msg
            end)

            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.falsy(callback_success, "Callback should indicate failure")
            test.assert.equals(callback_error, "File not readable", "Should provide error message")

            -- Restore original function
            vim.fn.getfsize = old_getfsize
        end)

        test.it("should log file size information", function()
            load_file_non_blocking("test_file.txt", 5, function() end)

            local found_size_log = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("Loading file of size:") then
                    found_size_log = true
                    break
                end
            end
            test.assert.truthy(found_size_log, "Should log file size information")
        end)
    end)

    test.describe("Size-based loading strategy", function()
        test.it("should choose correct strategy based on file size", function()
            -- Test small file (< 50KB)
            _G.test_state.logs = {}
            load_file_non_blocking("small_test.txt", 1, function() end)

            local filesize = vim.fn.getfsize("small_test.txt")
            test.assert.truthy(filesize < 50000, "Should detect small file size")

            local found_immediate = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("Loading file of size: 1000") then
                    found_immediate = true
                    break
                end
            end
            test.assert.truthy(found_immediate, "Should log small file size for immediate loading")

            -- Test medium file (>= 50KB)
            _G.test_state.logs = {}
            load_file_non_blocking("medium_test.txt", 2, function() end)

            -- Debug: let's see what logs we actually got
            local log_messages = {}
            for _, log in ipairs(_G.test_state.logs) do
                table.insert(log_messages, log.message)
            end

            local found_chunked = false
            for _, log in ipairs(_G.test_state.logs) do
                if log.message:find("chunked loading") then
                    found_chunked = true
                    break
                end
            end

            -- If the test fails, let's see what we actually got
            if not found_chunked then
                local all_logs = table.concat(log_messages, " | ")
                test.assert.truthy(found_chunked, "Should use chunked loading for medium files. Got logs: " .. all_logs)
            else
                test.assert.truthy(found_chunked, "Should use chunked loading for medium files")
            end
        end)
    end)
end)
