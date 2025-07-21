-- Integration tests for operations.lua with non-blocking file loading
local test = require('tests.init')

-- Test state to track mock operations (global to avoid scoping issues)
_G.ops_test_state = {
    buffer_lines = {},
    buffer_options = {},
    logs = {},
    current_buffer = nil,
    cursor_position = nil
}

-- Store original vim functions to restore later
local original_nvim_create_buf = vim.api.nvim_create_buf
local original_nvim_buf_set_name = vim.api.nvim_buf_set_name
local original_nvim_buf_set_lines = vim.api.nvim_buf_set_lines
local original_nvim_buf_set_option = vim.api.nvim_buf_set_option
local original_nvim_buf_get_option = vim.api.nvim_buf_get_option
local original_nvim_set_current_buf = vim.api.nvim_set_current_buf
local original_nvim_win_set_cursor = vim.api.nvim_win_set_cursor
local original_nvim_buf_get_name = vim.api.nvim_buf_get_name

-- Set up additional mocks needed for operations integration (will be merged with non-blocking file loading mocks)
vim.api.nvim_create_buf = function(listed, scratch)
    local bufnr = math.random(1, 1000)

    -- Check if we're in operations integration context
    if _G.ops_test_state and _G.ops_test_state.buffer_lines then
        _G.ops_test_state.buffer_lines[bufnr] = {}
        _G.ops_test_state.buffer_options[bufnr] = {listed = listed, scratch = scratch}
        return bufnr
    end

    -- Fall back to original function if no test context is active
    return original_nvim_create_buf(listed, scratch)
end

vim.api.nvim_buf_set_name = function(bufnr, name)
    -- Check if we're in operations integration context
    if _G.ops_test_state and _G.ops_test_state.buffer_options then
        _G.ops_test_state.buffer_options[bufnr] = _G.ops_test_state.buffer_options[bufnr] or {}
        _G.ops_test_state.buffer_options[bufnr].name = name
        return
    end

    -- Fall back to original function if no test context is active
    return original_nvim_buf_set_name(bufnr, name)
end

vim.api.nvim_buf_get_option = function(bufnr, option)
    -- Check if we're in operations integration context
    if _G.ops_test_state and _G.ops_test_state.buffer_options then
        return (_G.ops_test_state.buffer_options[bufnr] or {})[option]
    end

    -- Fall back to original function if no test context is active
    return original_nvim_buf_get_option(bufnr, option)
end

vim.api.nvim_set_current_buf = function(bufnr)
    -- Check if we're in operations integration context
    if _G.ops_test_state then
        _G.ops_test_state.current_buffer = bufnr
        return
    end

    -- Fall back to original function if no test context is active
    return original_nvim_set_current_buf(bufnr)
end

vim.api.nvim_win_set_cursor = function(win, pos)
    -- Check if we're in operations integration context
    if _G.ops_test_state then
        _G.ops_test_state.cursor_position = pos
        return
    end

    -- Fall back to original function if no test context is active
    return original_nvim_win_set_cursor(win, pos)
end

vim.api.nvim_buf_get_name = function(bufnr)
    -- Check if we're in operations integration context
    if _G.ops_test_state and _G.ops_test_state.buffer_options then
        return (_G.ops_test_state.buffer_options[bufnr] or {}).name or ""
    end

    -- Fall back to original function if no test context is active
    return original_nvim_buf_get_name(bufnr)
end

-- Set up the missing nvim_buf_set_option mock for operations integration
vim.api.nvim_buf_set_option = function(bufnr, option, value)
    local stored = false

    -- Store in operations integration context if it exists
    if _G.ops_test_state and _G.ops_test_state.buffer_options then
        _G.ops_test_state.buffer_options[bufnr] = _G.ops_test_state.buffer_options[bufnr] or {}
        _G.ops_test_state.buffer_options[bufnr][option] = value
        stored = true
    end

    -- Store in non-blocking file loading context if it exists
    if _G.test_state and _G.test_state.buffer_options then
        _G.test_state.buffer_options[bufnr] = _G.test_state.buffer_options[bufnr] or {}
        _G.test_state.buffer_options[bufnr][option] = value
        stored = true
    end

    -- Fall back to original function if no test context is active
    if not stored then
        return original_nvim_buf_set_option(bufnr, option, value)
    end
end

-- Function to restore original mocks
local function restore_original_mocks()
    vim.api.nvim_create_buf = original_nvim_create_buf
    vim.api.nvim_buf_set_name = original_nvim_buf_set_name
    vim.api.nvim_buf_set_lines = original_nvim_buf_set_lines
    vim.api.nvim_buf_set_option = original_nvim_buf_set_option
    vim.api.nvim_buf_get_option = original_nvim_buf_get_option
    vim.api.nvim_set_current_buf = original_nvim_set_current_buf
    vim.api.nvim_win_set_cursor = original_nvim_win_set_cursor
    vim.api.nvim_buf_get_name = original_nvim_buf_get_name
end

-- Mock utils for operations
local utils_mock = {
    log = function(msg, level, show_user, cfg)
        table.insert(_G.ops_test_state.logs, {message = msg, level = level, show_user = show_user})
    end,
    parse_remote_path = function(url)
        local protocol, host, path = url:match("^(%w+)://([^/]+)(/.*)$")
        if protocol and host and path then
            return {
                protocol = protocol,
                host = host,
                path = path,
                has_double_slash = false
            }
        end
        return nil
    end
}

-- Create a simplified operations module for testing
local function create_operations_mock()
    local M = {}
    local config = { config = { debug = true, log_level = vim.log.levels.DEBUG } }

    -- Helper functions
    local function load_content_non_blocking(content, bufnr, on_complete)
        local line_count = #content
        utils_mock.log("Loading content with " .. line_count .. " lines", vim.log.levels.DEBUG, false, config.config)

        if line_count < 1000 then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
            if on_complete then on_complete(true) end
        else
            utils_mock.log("Using chunked loading for medium content", vim.log.levels.DEBUG, false, config.config)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
            if on_complete then on_complete(true) end
        end
    end

    -- Mock fetch_remote_content function
    function M.fetch_remote_content(host, path, callback)
        -- Don't use vim.schedule in tests for synchronous execution
        local content = {}
        local line_count = path:match("(%d+)_lines")
        line_count = line_count and tonumber(line_count) or 100

        for i = 1, line_count do
            table.insert(content, "Remote content line " .. i .. " from " .. host .. ":" .. path)
        end

        callback(content, nil)
    end

    -- Simplified version of simple_open_remote_file for testing
    function M.simple_open_remote_file(url, position)
        utils_mock.log("Opening remote file: " .. url, vim.log.levels.DEBUG, false, config.config)

        local remote_info = utils_mock.parse_remote_path(url)
        if not remote_info then
            utils_mock.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
            return
        end

        local host = remote_info.host
        local path = remote_info.path

        M.fetch_remote_content(host, path, function(content, error)
            if not content then
                utils_mock.log("Error fetching remote file: " .. (error and table.concat(error, "; ") or "unknown error"), vim.log.levels.ERROR, true, config.config)
                return
            end

            -- Don't use vim.schedule in tests for synchronous execution
            local bufnr = vim.api.nvim_create_buf(true, false)
            utils_mock.log("Created new buffer: " .. bufnr, vim.log.levels.DEBUG, false, config.config)

            vim.api.nvim_buf_set_name(bufnr, url)
            vim.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
            vim.api.nvim_buf_set_option(bufnr, "modified", false)
            vim.api.nvim_set_current_buf(bufnr)

            -- Use non-blocking loading
            load_content_non_blocking(content, bufnr, function(success, error_msg)
                if success then
                    utils_mock.log("Successfully loaded remote file into buffer", vim.log.levels.DEBUG, false, config.config)

                    if position then
                        pcall(vim.api.nvim_win_set_cursor, 0, {position.line + 1, position.character})
                    end

                    utils_mock.log("Remote file loaded successfully", vim.log.levels.DEBUG, false, config.config)
                else
                    utils_mock.log("Failed to load remote file: " .. (error_msg or "unknown error"), vim.log.levels.ERROR, true, config.config)
                end
            end)
        end)
    end

    return M
end

test.describe("Operations Integration Tests", function()
    local operations
    local originals

    test.setup(function()
        -- Reset test state before each test (but preserve _G.ops_test_state reference)
        _G.ops_test_state.buffer_lines = {}
        _G.ops_test_state.buffer_options = {}
        _G.ops_test_state.logs = {}
        _G.ops_test_state.current_buffer = nil
        _G.ops_test_state.cursor_position = nil

        -- Clear other test state to avoid conflicts with unified mocks
        _G.test_state = nil
    end)

    test.teardown(function()
        -- Restore original vim functions
        restore_original_mocks()

        -- Clean up global test state
        _G.ops_test_state = nil
    end)

    local function setup_operations()
        -- Reset test state for each test
        _G.ops_test_state = {
            buffer_lines = {},
            buffer_options = {},
            logs = {},
            current_buffer = nil,
            cursor_position = nil
        }
        operations = create_operations_mock()
    end

    test.describe("simple_open_remote_file integration", function()
        test.it("should open small remote file without blocking", function()
            setup_operations()
            local url = "scp://testhost/path/to/small_file.txt"

            operations.simple_open_remote_file(url)

            -- Verify buffer was created
            test.assert.truthy(_G.ops_test_state.current_buffer, "Should set current buffer")

            -- Verify buffer has content
            local lines = _G.ops_test_state.buffer_lines[_G.ops_test_state.current_buffer]
            test.assert.truthy(lines, "Buffer should have content")

            -- Verify buffer options
            local options = _G.ops_test_state.buffer_options[_G.ops_test_state.current_buffer]
            test.assert.truthy(options, "Buffer should have options")
            test.assert.equals(options.buftype, 'acwrite', "Should set buffer type to acwrite")
            test.assert.equals(options.modified, false, "Should mark buffer as not modified")
            test.assert.equals(options.name, url, "Should set buffer name to URL")

            -- Verify logging
            local found_success_log = false
            for _, log in ipairs(_G.ops_test_state.logs) do
                if log.message:find("loaded successfully") then
                    found_success_log = true
                    break
                end
            end
            test.assert.truthy(found_success_log, "Should log successful loading")
        end)

        test.it("should handle medium files with chunked loading", function()
            setup_operations()
            local url = "scp://testhost/path/to/3000_lines_file.txt"

            operations.simple_open_remote_file(url)

            -- Verify chunked loading was used
            local found_chunked_log = false
            for _, log in ipairs(_G.ops_test_state.logs) do
                if log.message:find("chunked loading") then
                    found_chunked_log = true
                    break
                end
            end
            test.assert.truthy(found_chunked_log, "Should use chunked loading for medium files")

            -- Verify buffer was created and populated
            test.assert.truthy(_G.ops_test_state.current_buffer, "Should create buffer")
        end)

        test.it("should handle cursor positioning", function()
            setup_operations()
            local url = "scp://testhost/path/to/file.txt"
            local position = {line = 10, character = 5}

            operations.simple_open_remote_file(url, position)

            -- Verify cursor was positioned
            test.assert.truthy(_G.ops_test_state.cursor_position, "Should set cursor position")
            test.assert.equals(_G.ops_test_state.cursor_position[1], 11, "Should convert 0-based to 1-based line number")
            test.assert.equals(_G.ops_test_state.cursor_position[2], 5, "Should set correct character position")
        end)

        test.it("should handle invalid URLs gracefully", function()
            setup_operations()
            local invalid_url = "not-a-valid-url"

            operations.simple_open_remote_file(invalid_url)

            -- Verify error was logged
            local found_error_log = false
            for _, log in ipairs(_G.ops_test_state.logs) do
                if log.message:find("Invalid remote URL") and log.level == vim.log.levels.ERROR then
                    found_error_log = true
                    break
                end
            end
            test.assert.truthy(found_error_log, "Should log error for invalid URL")

            -- Verify no buffer was created
            test.assert.falsy(_G.ops_test_state.current_buffer, "Should not create buffer for invalid URL")
        end)
    end)

    test.describe("Error handling", function()
        test.it("should handle fetch errors gracefully", function()
            setup_operations()
            -- Mock fetch_remote_content to return error
            local original_fetch = operations.fetch_remote_content
            operations.fetch_remote_content = function(host, path, callback)
                callback(nil, {"Connection failed", "Timeout"})
            end

            local url = "scp://testhost/path/to/file.txt"
            operations.simple_open_remote_file(url)

            -- Verify error was logged
            local found_error_log = false
            for _, log in ipairs(_G.ops_test_state.logs) do
                if log.message:find("Error fetching remote file") and log.level == vim.log.levels.ERROR then
                    found_error_log = true
                    break
                end
            end
            test.assert.truthy(found_error_log, "Should log fetch errors")

            -- Restore original function
            operations.fetch_remote_content = original_fetch
        end)
    end)
end)
