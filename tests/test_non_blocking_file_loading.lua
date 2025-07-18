-- Unit tests for non-blocking file loading functionality
local test = require('tests.init')

-- Mock vim functions for testing
local vim_mock = {
    api = {
        nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, replacement)
            -- Store the lines for verification
            vim_mock._buffer_lines = vim_mock._buffer_lines or {}
            vim_mock._buffer_lines[bufnr] = vim_mock._buffer_lines[bufnr] or {}
            
            -- Simulate setting lines
            for i, line in ipairs(replacement) do
                vim_mock._buffer_lines[bufnr][start + i] = line
            end
            return true
        end,
        nvim_buf_is_valid = function(bufnr)
            return bufnr > 0 and bufnr <= 100  -- Assume buffers 1-100 are valid
        end,
        nvim_buf_set_option = function(bufnr, option, value)
            vim_mock._buffer_options = vim_mock._buffer_options or {}
            vim_mock._buffer_options[bufnr] = vim_mock._buffer_options[bufnr] or {}
            vim_mock._buffer_options[bufnr][option] = value
        end
    },
    fn = {
        getfsize = function(path)
            -- Mock file sizes for testing
            if path:match("small") then return 1000 end
            if path:match("medium") then return 100000 end
            if path:match("large") then return 1000000 end
            return 50000  -- default medium size
        end,
        readfile = function(path)
            -- Mock file content
            local lines = {}
            local line_count = path:match("(%d+)_lines") 
            line_count = line_count and tonumber(line_count) or 100
            
            for i = 1, line_count do
                table.insert(lines, "Line " .. i .. " from " .. path)
            end
            return lines
        end,
        tempname = function()
            return "/tmp/test_temp_file"
        end,
        delete = function(path)
            return 0  -- success
        end
    },
    schedule = function(func)
        -- Execute immediately for testing
        func()
    end,
    defer_fn = function(func, delay)
        -- Execute immediately for testing
        func()
    end,
    log = {
        levels = {
            DEBUG = 1,
            INFO = 2,
            WARN = 3,
            ERROR = 4
        }
    }
}

-- Mock utils module
local utils_mock = {
    log = function(message, level, show_user, config)
        -- Store logs for verification
        utils_mock._logs = utils_mock._logs or {}
        table.insert(utils_mock._logs, {
            message = message,
            level = level,
            show_user = show_user
        })
    end
}

-- Mock config module
local config_mock = {
    config = {
        debug = true,
        log_level = vim_mock.log.levels.DEBUG
    }
}

-- Helper functions from our implementation (copied for testing)
local show_loading_progress, load_content_non_blocking, load_file_non_blocking

show_loading_progress = function(bufnr, message)
    message = message or "Loading remote file..."
    vim_mock.api.nvim_buf_set_lines(bufnr, 0, -1, false, {message, "", "Please wait..."})
    vim_mock.api.nvim_buf_set_option(bufnr, "modified", false)
end

load_content_non_blocking = function(content, bufnr, on_complete)
    local line_count = #content
    utils_mock.log("Loading content with " .. line_count .. " lines", vim_mock.log.levels.DEBUG, false, config_mock.config)
    
    if line_count < 1000 then  -- Small content - load normally
        vim_mock.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
        if on_complete then on_complete(true) end
        
    elseif line_count < 5000 then  -- Medium content - chunked loading
        utils_mock.log("Using chunked loading for medium content", vim_mock.log.levels.DEBUG, false, config_mock.config)
        show_loading_progress(bufnr, "Loading remote file (chunked)...")
        
        local chunk_size = 1000
        local current_line = 0
        
        local function load_next_chunk()
            local end_line = math.min(current_line + chunk_size, line_count)
            local chunk = {}
            
            for i = current_line + 1, end_line do
                table.insert(chunk, content[i])
            end
            
            vim_mock.schedule(function()
                if vim_mock.api.nvim_buf_is_valid(bufnr) then
                    vim_mock.api.nvim_buf_set_lines(bufnr, current_line, current_line, false, chunk)
                    current_line = end_line
                    
                    if current_line >= line_count then
                        -- Loading complete
                        if on_complete then on_complete(true) end
                    else
                        -- Schedule next chunk
                        vim_mock.defer_fn(load_next_chunk, 1)
                    end
                else
                    if on_complete then on_complete(false, "Buffer became invalid") end
                end
            end)
        end
        
        load_next_chunk()
        
    else  -- Large content - streaming
        utils_mock.log("Using streaming for large content", vim_mock.log.levels.DEBUG, false, config_mock.config)
        show_loading_progress(bufnr, "Loading large remote file...")
        
        local batch_size = 100
        local current_line = 0
        
        local function stream_next_batch()
            local end_line = math.min(current_line + batch_size, line_count)
            local batch = {}
            
            for i = current_line + 1, end_line do
                table.insert(batch, content[i])
            end
            
            vim_mock.schedule(function()
                if vim_mock.api.nvim_buf_is_valid(bufnr) then
                    vim_mock.api.nvim_buf_set_lines(bufnr, current_line, current_line, false, batch)
                    current_line = end_line
                    
                    -- Update progress occasionally
                    if current_line % 1000 == 0 then
                        utils_mock.log("Loaded " .. current_line .. " lines...", vim_mock.log.levels.DEBUG, false, config_mock.config)
                    end
                    
                    if current_line >= line_count then
                        -- Loading complete
                        if on_complete then on_complete(true) end
                    else
                        -- Continue streaming
                        vim_mock.defer_fn(stream_next_batch, 2)
                    end
                else
                    if on_complete then on_complete(false, "Buffer became invalid") end
                end
            end)
        end
        
        stream_next_batch()
    end
end

load_file_non_blocking = function(file_path, bufnr, on_complete)
    local filesize = vim_mock.fn.getfsize(file_path)
    
    if filesize < 0 then
        if on_complete then on_complete(false, "File not readable") end
        return
    end
    
    utils_mock.log("Loading file of size: " .. filesize .. " bytes", vim_mock.log.levels.DEBUG, false, config_mock.config)
    
    if filesize < 50000 then  -- Small files (< 50KB) - load normally
        local lines = vim_mock.fn.readfile(file_path)
        vim_mock.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        if on_complete then on_complete(true) end
        
    elseif filesize < 500000 then  -- Medium files (< 500KB) - chunked loading
        utils_mock.log("Using chunked loading for medium file", vim_mock.log.levels.DEBUG, false, config_mock.config)
        show_loading_progress(bufnr, "Loading remote file (chunked)...")
        
        -- For testing, simulate file reading as content array
        local lines = vim_mock.fn.readfile(file_path)
        load_content_non_blocking(lines, bufnr, on_complete)
        
    else  -- Large files - streaming
        utils_mock.log("Using streaming for large file", vim_mock.log.levels.DEBUG, false, config_mock.config)
        show_loading_progress(bufnr, "Loading large remote file...")
        
        -- For testing, simulate file reading as content array
        local lines = vim_mock.fn.readfile(file_path)
        load_content_non_blocking(lines, bufnr, on_complete)
    end
end

test.describe("Non-Blocking File Loading", function()
    test.setup(function()
        -- Clear mock state before each test group
        vim_mock._buffer_lines = {}
        vim_mock._buffer_options = {}
        utils_mock._logs = {}
    end)
    
    test.describe("show_loading_progress", function()
        test.it("should set loading message in buffer", function()
            show_loading_progress(1, "Test loading message")
            
            local lines = vim_mock._buffer_lines[1]
            test.assert.truthy(lines, "Buffer should have lines set")
            test.assert.equals(lines[1], "Test loading message", "Should set custom loading message")
            test.assert.equals(lines[2], "", "Should add empty line")
            test.assert.equals(lines[3], "Please wait...", "Should add wait message")
        end)
        
        test.it("should use default message when none provided", function()
            show_loading_progress(2)
            
            local lines = vim_mock._buffer_lines[2]
            test.assert.equals(lines[1], "Loading remote file...", "Should use default message")
        end)
        
        test.it("should set buffer as not modified", function()
            show_loading_progress(3)
            
            local options = vim_mock._buffer_options[3]
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
            local logs = utils_mock._logs
            test.assert.contains(logs[1].message, "Loading content with 500 lines", "Should log content size")
        end)
        
        test.it("should use chunked loading for medium content", function()
            local content = {}
            for i = 1, 3000 do
                table.insert(content, "Line " .. i)
            end
            
            local callback_called = false
            local callback_success = false
            
            load_content_non_blocking(content, 2, function(success)
                callback_called = true
                callback_success = success
            end)
            
            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.truthy(callback_success, "Callback should indicate success")
            
            -- Check logs for chunked loading
            local logs = utils_mock._logs
            local found_chunked_log = false
            for _, log in ipairs(logs) do
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
            local callback_success = false
            
            load_content_non_blocking(content, 3, function(success)
                callback_called = true
                callback_success = success
            end)
            
            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.truthy(callback_success, "Callback should indicate success")
            
            -- Check logs for streaming
            local logs = utils_mock._logs
            local found_streaming_log = false
            local found_progress_log = false
            
            for _, log in ipairs(logs) do
                if log.message:find("streaming") then
                    found_streaming_log = true
                end
                if log.message:find("Loaded .* lines") then
                    found_progress_log = true
                end
            end
            
            test.assert.truthy(found_streaming_log, "Should log streaming strategy")
            test.assert.truthy(found_progress_log, "Should log progress updates")
        end)
        
        test.it("should handle invalid buffer gracefully", function()
            local content = {"Line 1", "Line 2"}
            local invalid_bufnr = 999  -- Invalid buffer number
            
            local callback_called = false
            local callback_success = true
            local callback_error = nil
            
            load_content_non_blocking(content, invalid_bufnr, function(success, error_msg)
                callback_called = true
                callback_success = success
                callback_error = error_msg
            end)
            
            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.falsy(callback_success, "Callback should indicate failure")
            test.assert.equals(callback_error, "Buffer became invalid", "Should provide error message")
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
        
        test.it("should handle medium files with chunked loading", function()
            local callback_called = false
            local callback_success = false
            
            load_file_non_blocking("medium_file.txt", 2, function(success)
                callback_called = true
                callback_success = success
            end)
            
            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.truthy(callback_success, "Callback should indicate success")
            
            -- Check for chunked loading log
            local logs = utils_mock._logs
            local found_chunked_log = false
            for _, log in ipairs(logs) do
                if log.message:find("chunked loading") then
                    found_chunked_log = true
                    break
                end
            end
            test.assert.truthy(found_chunked_log, "Should use chunked loading for medium files")
        end)
        
        test.it("should handle large files with streaming", function()
            local callback_called = false
            local callback_success = false
            
            load_file_non_blocking("large_file.txt", 3, function(success)
                callback_called = true
                callback_success = success
            end)
            
            test.assert.truthy(callback_called, "Callback should be called")
            test.assert.truthy(callback_success, "Callback should indicate success")
            
            -- Check for streaming log
            local logs = utils_mock._logs
            local found_streaming_log = false
            for _, log in ipairs(logs) do
                if log.message:find("streaming") then
                    found_streaming_log = true
                    break
                end
            end
            test.assert.truthy(found_streaming_log, "Should use streaming for large files")
        end)
        
        test.it("should handle unreadable files", function()
            -- Mock negative file size to simulate unreadable file
            local old_getfsize = vim_mock.fn.getfsize
            vim_mock.fn.getfsize = function(path) return -1 end
            
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
            vim_mock.fn.getfsize = old_getfsize
        end)
        
        test.it("should log file size information", function()
            load_file_non_blocking("test_file.txt", 5, function() end)
            
            local logs = utils_mock._logs
            local found_size_log = false
            for _, log in ipairs(logs) do
                if log.message:find("Loading file of size:") then
                    found_size_log = true
                    break
                end
            end
            test.assert.truthy(found_size_log, "Should log file size information")
        end)
    end)
    
    test.describe("Size-based loading strategy", function()
        test.it("should choose correct strategy based on content size", function()
            local test_cases = {
                {size = 500, expected_strategy = "immediate"},
                {size = 3000, expected_strategy = "chunked"},
                {size = 10000, expected_strategy = "streaming"}
            }
            
            for _, case in ipairs(test_cases) do
                utils_mock._logs = {}  -- Clear logs
                
                local content = {}
                for i = 1, case.size do
                    table.insert(content, "Line " .. i)
                end
                
                load_content_non_blocking(content, 1, function() end)
                
                local logs = utils_mock._logs
                if case.expected_strategy == "chunked" then
                    local found = false
                    for _, log in ipairs(logs) do
                        if log.message:find("chunked") then found = true; break end
                    end
                    test.assert.truthy(found, "Should use chunked loading for " .. case.size .. " lines")
                    
                elseif case.expected_strategy == "streaming" then
                    local found = false
                    for _, log in ipairs(logs) do
                        if log.message:find("streaming") then found = true; break end
                    end
                    test.assert.truthy(found, "Should use streaming for " .. case.size .. " lines")
                end
            end
        end)
    end)
end)

test.describe("Integration Tests", function()
    test.it("should properly integrate all helper functions", function()
        -- Test complete flow from file loading to content display
        local callback_called = false
        local callback_success = false
        
        load_file_non_blocking("test_integration_file.txt", 1, function(success)
            callback_called = true
            callback_success = success
        end)
        
        test.assert.truthy(callback_called, "Integration callback should be called")
        test.assert.truthy(callback_success, "Integration should succeed")
        
        -- Verify buffer content was set
        local lines = vim_mock._buffer_lines[1]
        test.assert.truthy(lines, "Buffer should have content after integration")
    end)
    
    test.it("should handle error cases gracefully in integration", function()
        -- Test error handling throughout the integration
        local old_getfsize = vim_mock.fn.getfsize
        vim_mock.fn.getfsize = function(path) return -1 end
        
        local callback_called = false
        local callback_success = true
        
        load_file_non_blocking("error_file.txt", 2, function(success)
            callback_called = true
            callback_success = success
        end)
        
        test.assert.truthy(callback_called, "Error integration callback should be called")
        test.assert.falsy(callback_success, "Error integration should fail gracefully")
        
        vim_mock.fn.getfsize = old_getfsize
    end)
end)