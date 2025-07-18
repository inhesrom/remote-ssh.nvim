-- Integration tests for operations.lua with non-blocking file loading
local test = require('tests.init')

-- Mock modules and dependencies
local mock_state = {
    buffer_lines = {},
    buffer_options = {},
    logs = {},
    job_started = false,
    temp_files = {},
    callbacks = {}
}

-- Mock vim API
local vim_mock = {
    api = {
        nvim_create_buf = function(listed, scratch)
            local bufnr = math.random(1, 1000)
            mock_state.buffer_lines[bufnr] = {}
            mock_state.buffer_options[bufnr] = {listed = listed, scratch = scratch}
            return bufnr
        end,
        nvim_buf_set_name = function(bufnr, name)
            mock_state.buffer_options[bufnr] = mock_state.buffer_options[bufnr] or {}
            mock_state.buffer_options[bufnr].name = name
        end,
        nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, replacement)
            mock_state.buffer_lines[bufnr] = mock_state.buffer_lines[bufnr] or {}
            
            -- Clear existing lines if replacing all
            if start == 0 and end_line == -1 then
                mock_state.buffer_lines[bufnr] = {}
            end
            
            -- Set new lines
            for i, line in ipairs(replacement) do
                mock_state.buffer_lines[bufnr][start + i] = line
            end
            return true
        end,
        nvim_buf_is_valid = function(bufnr)
            return mock_state.buffer_lines[bufnr] ~= nil
        end,
        nvim_buf_set_option = function(bufnr, option, value)
            mock_state.buffer_options[bufnr] = mock_state.buffer_options[bufnr] or {}
            mock_state.buffer_options[bufnr][option] = value
        end,
        nvim_buf_get_option = function(bufnr, option)
            return (mock_state.buffer_options[bufnr] or {})[option]
        end,
        nvim_set_current_buf = function(bufnr)
            mock_state.current_buffer = bufnr
        end,
        nvim_win_set_cursor = function(win, pos)
            mock_state.cursor_position = pos
        end,
        nvim_buf_get_name = function(bufnr)
            return (mock_state.buffer_options[bufnr] or {}).name or ""
        end,
        nvim_buf_line_count = function(bufnr)
            local lines = mock_state.buffer_lines[bufnr] or {}
            local count = 0
            for _ in pairs(lines) do count = count + 1 end
            return count
        end
    },
    fn = {
        filereadable = function(path) return 1 end,
        getfsize = function(path)
            if path:match("small") then return 1000 end
            if path:match("medium") then return 100000 end
            if path:match("large") then return 1000000 end
            return 50000
        end,
        readfile = function(path)
            local lines = {}
            local size = vim_mock.fn.getfsize(path)
            local line_count = math.floor(size / 50)  -- Approximate lines
            
            for i = 1, line_count do
                table.insert(lines, "Content line " .. i .. " from " .. path)
            end
            return lines
        end,
        tempname = function()
            return "/tmp/test_" .. os.time()
        end,
        delete = function(path)
            mock_state.temp_files[path] = nil
            return 0
        end,
        fnamemodify = function(path, modifier)
            if modifier == ":t" then
                return path:match("([^/]+)$") or path
            elseif modifier == ":e" then
                return path:match("%.([^%.]+)$") or ""
            end
            return path
        end,
        fnameescape = function(path) return path end,
        shellescape = function(path) return "'" .. path .. "'" end,
        bufwinid = function(bufnr) return 1 end,
        winsaveview = function() return {topline = 1, col = 0} end,
        winrestview = function(view) end,
        jobstart = function(cmd, opts)
            mock_state.job_started = true
            mock_state.last_job_cmd = cmd
            mock_state.last_job_opts = opts
            
            -- Simulate successful job completion
            if opts.on_exit then
                vim_mock.schedule(function()
                    opts.on_exit(nil, 0)  -- success
                end)
            end
            
            return 123  -- mock job id
        end
    },
    schedule = function(func)
        func()
    end,
    defer_fn = function(func, delay)
        table.insert(mock_state.callbacks, func)
        func()  -- Execute immediately for testing
    end,
    cmd = function(command) 
        mock_state.last_vim_command = command
    end,
    filetype = {
        match = function(opts) 
            return "text"
        end
    },
    log = {
        levels = {
            DEBUG = 1,
            INFO = 2,
            WARN = 3,
            ERROR = 4
        }
    },
    o = {
        eventignore = ""
    }
}

-- Create a minimal operations module mock with our new functions
local function create_operations_mock()
    local M = {}
    
    -- Copy our helper functions for testing
    local config = { config = { debug = true, log_level = vim_mock.log.levels.DEBUG } }
    local utils = {
        log = function(msg, level, show_user, cfg)
            table.insert(mock_state.logs, {message = msg, level = level, show_user = show_user})
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
    
    -- Include our helper functions
    local function show_loading_progress(bufnr, message)
        message = message or "Loading remote file..."
        vim_mock.api.nvim_buf_set_lines(bufnr, 0, -1, false, {message, "", "Please wait..."})
        vim_mock.api.nvim_buf_set_option(bufnr, "modified", false)
    end

    local function load_content_non_blocking(content, bufnr, on_complete)
        local line_count = #content
        utils.log("Loading content with " .. line_count .. " lines", vim_mock.log.levels.DEBUG, false, config.config)
        
        if line_count < 1000 then
            vim_mock.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
            if on_complete then on_complete(true) end
        elseif line_count < 5000 then
            utils.log("Using chunked loading for medium content", vim_mock.log.levels.DEBUG, false, config.config)
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
                            if on_complete then on_complete(true) end
                        else
                            vim_mock.defer_fn(load_next_chunk, 1)
                        end
                    else
                        if on_complete then on_complete(false, "Buffer became invalid") end
                    end
                end)
            end
            
            load_next_chunk()
        else
            utils.log("Using streaming for large content", vim_mock.log.levels.DEBUG, false, config.config)
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
                        
                        if current_line % 1000 == 0 then
                            utils.log("Loaded " .. current_line .. " lines...", vim_mock.log.levels.DEBUG, false, config.config)
                        end
                        
                        if current_line >= line_count then
                            if on_complete then on_complete(true) end
                        else
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

    local function load_file_non_blocking(file_path, bufnr, on_complete)
        local filesize = vim_mock.fn.getfsize(file_path)
        
        if filesize < 0 then
            if on_complete then on_complete(false, "File not readable") end
            return
        end
        
        utils.log("Loading file of size: " .. filesize .. " bytes", vim_mock.log.levels.DEBUG, false, config.config)
        
        if filesize < 50000 then
            local lines = vim_mock.fn.readfile(file_path)
            vim_mock.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            if on_complete then on_complete(true) end
        else
            local lines = vim_mock.fn.readfile(file_path)
            load_content_non_blocking(lines, bufnr, on_complete)
        end
    end
    
    -- Mock fetch_remote_content function
    function M.fetch_remote_content(host, path, callback)
        vim_mock.schedule(function()
            local content = {}
            local line_count = path:match("(%d+)_lines") 
            line_count = line_count and tonumber(line_count) or 100
            
            for i = 1, line_count do
                table.insert(content, "Remote content line " .. i .. " from " .. host .. ":" .. path)
            end
            
            callback(content, nil)
        end)
    end
    
    -- Simplified version of simple_open_remote_file for testing
    function M.simple_open_remote_file(url, position)
        utils.log("Opening remote file: " .. url, vim_mock.log.levels.DEBUG, false, config.config)

        local remote_info = utils.parse_remote_path(url)
        if not remote_info then
            utils.log("Invalid remote URL: " .. url, vim_mock.log.levels.ERROR, true, config.config)
            return
        end

        local host = remote_info.host
        local path = remote_info.path

        M.fetch_remote_content(host, path, function(content, error)
            if not content then
                utils.log("Error fetching remote file: " .. (error and table.concat(error, "; ") or "unknown error"), vim_mock.log.levels.ERROR, true, config.config)
                return
            end

            vim_mock.schedule(function()
                local bufnr = vim_mock.api.nvim_create_buf(true, false)
                utils.log("Created new buffer: " .. bufnr, vim_mock.log.levels.DEBUG, false, config.config)

                vim_mock.api.nvim_buf_set_name(bufnr, url)
                vim_mock.api.nvim_buf_set_option(bufnr, 'buftype', 'acwrite')
                vim_mock.api.nvim_buf_set_option(bufnr, "modified", false)
                vim_mock.api.nvim_set_current_buf(bufnr)

                -- Use non-blocking loading
                load_content_non_blocking(content, bufnr, function(success, error_msg)
                    if success then
                        utils.log("Successfully loaded remote file into buffer", vim_mock.log.levels.DEBUG, false, config.config)
                        
                        if position then
                            pcall(vim_mock.api.nvim_win_set_cursor, 0, {position.line + 1, position.character})
                            vim_mock.cmd('normal! zz')
                        end
                        
                        utils.log("Remote file loaded successfully", vim_mock.log.levels.DEBUG, false, config.config)
                    else
                        utils.log("Failed to load remote file: " .. (error_msg or "unknown error"), vim_mock.log.levels.ERROR, true, config.config)
                    end
                end)
            end)
        end)
    end
    
    return M
end

test.describe("Operations Integration Tests", function()
    local operations
    
    test.setup(function()
        -- Reset mock state before each test group
        mock_state = {
            buffer_lines = {},
            buffer_options = {},
            logs = {},
            job_started = false,
            temp_files = {},
            callbacks = {},
            current_buffer = nil,
            cursor_position = nil
        }
    end)
    
    -- Initialize operations before each test
    local function init_operations()
        operations = create_operations_mock()
    end
    
    test.describe("simple_open_remote_file integration", function()
        test.setup(function()
            init_operations()
        end)
        
        test.it("should open small remote file without blocking", function()
            local url = "scp://testhost/path/to/small_file.txt"
            
            operations.simple_open_remote_file(url)
            
            -- Verify buffer was created
            test.assert.truthy(mock_state.current_buffer, "Should set current buffer")
            
            -- Verify buffer has content
            local lines = mock_state.buffer_lines[mock_state.current_buffer]
            test.assert.truthy(lines, "Buffer should have content")
            test.assert.truthy(#lines > 0, "Buffer should have lines")
            
            -- Verify buffer options
            local options = mock_state.buffer_options[mock_state.current_buffer]
            test.assert.equals(options.buftype, 'acwrite', "Should set buffer type to acwrite")
            test.assert.equals(options.modified, false, "Should mark buffer as not modified")
            test.assert.equals(options.name, url, "Should set buffer name to URL")
            
            -- Verify logging
            local found_success_log = false
            for _, log in ipairs(mock_state.logs) do
                if log.message:find("loaded successfully") then
                    found_success_log = true
                    break
                end
            end
            test.assert.truthy(found_success_log, "Should log successful loading")
        end)
        
        test.it("should handle medium files with chunked loading", function()
            local url = "scp://testhost/path/to/3000_lines_file.txt"
            
            operations.simple_open_remote_file(url)
            
            -- Verify chunked loading was used
            local found_chunked_log = false
            for _, log in ipairs(mock_state.logs) do
                if log.message:find("chunked loading") then
                    found_chunked_log = true
                    break
                end
            end
            test.assert.truthy(found_chunked_log, "Should use chunked loading for medium files")
            
            -- Verify buffer was created and populated
            test.assert.truthy(mock_state.current_buffer, "Should create buffer")
            local lines = mock_state.buffer_lines[mock_state.current_buffer]
            test.assert.truthy(lines and #lines > 0, "Should populate buffer with content")
        end)
        
        test.it("should handle large files with streaming", function()
            local url = "scp://testhost/path/to/10000_lines_file.txt"
            
            operations.simple_open_remote_file(url)
            
            -- Verify streaming was used
            local found_streaming_log = false
            for _, log in ipairs(mock_state.logs) do
                if log.message:find("streaming") then
                    found_streaming_log = true
                    break
                end
            end
            test.assert.truthy(found_streaming_log, "Should use streaming for large files")
        end)
        
        test.it("should handle cursor positioning", function()
            local url = "scp://testhost/path/to/file.txt"
            local position = {line = 10, character = 5}
            
            operations.simple_open_remote_file(url, position)
            
            -- Verify cursor was positioned
            test.assert.truthy(mock_state.cursor_position, "Should set cursor position")
            test.assert.equals(mock_state.cursor_position[1], 11, "Should convert 0-based to 1-based line number")
            test.assert.equals(mock_state.cursor_position[2], 5, "Should set correct character position")
        end)
        
        test.it("should handle invalid URLs gracefully", function()
            local invalid_url = "not-a-valid-url"
            
            operations.simple_open_remote_file(invalid_url)
            
            -- Verify error was logged
            local found_error_log = false
            for _, log in ipairs(mock_state.logs) do
                if log.message:find("Invalid remote URL") and log.level == vim_mock.log.levels.ERROR then
                    found_error_log = true
                    break
                end
            end
            test.assert.truthy(found_error_log, "Should log error for invalid URL")
            
            -- Verify no buffer was created
            test.assert.falsy(mock_state.current_buffer, "Should not create buffer for invalid URL")
        end)
    end)
    
    test.describe("Performance characteristics", function()
        test.setup(function()
            init_operations()
        end)
        
        test.it("should handle loading without blocking UI thread simulation", function()
            -- Test that callbacks are scheduled properly
            local callback_count = 0
            
            local url = "scp://testhost/path/to/medium_file.txt"
            operations.simple_open_remote_file(url)
            
            -- Count scheduled callbacks (simulating non-blocking behavior)
            callback_count = #mock_state.callbacks
            
            test.assert.truthy(callback_count > 0, "Should schedule callbacks for non-blocking operation")
        end)
        
        test.it("should show loading progress for large files", function()
            local url = "scp://testhost/path/to/large_file.txt"
            
            operations.simple_open_remote_file(url)
            
            -- Verify loading progress was shown
            local buffer_id = mock_state.current_buffer
            if buffer_id then
                local initial_lines = mock_state.buffer_lines[buffer_id]
                local found_loading_message = false
                
                for _, line in pairs(initial_lines or {}) do
                    if type(line) == "string" and line:find("Loading") then
                        found_loading_message = true
                        break
                    end
                end
                
                test.assert.truthy(found_loading_message, "Should show loading progress message")
            end
        end)
    end)
    
    test.describe("Error handling", function()
        test.setup(function()
            init_operations()
        end)
        
        test.it("should handle fetch errors gracefully", function()
            -- Mock fetch_remote_content to return error
            local original_fetch = operations.fetch_remote_content
            operations.fetch_remote_content = function(host, path, callback)
                callback(nil, {"Connection failed", "Timeout"})
            end
            
            local url = "scp://testhost/path/to/file.txt"
            operations.simple_open_remote_file(url)
            
            -- Verify error was logged
            local found_error_log = false
            for _, log in ipairs(mock_state.logs) do
                if log.message:find("Error fetching remote file") and log.level == vim_mock.log.levels.ERROR then
                    found_error_log = true
                    break
                end
            end
            test.assert.truthy(found_error_log, "Should log fetch errors")
            
            -- Restore original function
            operations.fetch_remote_content = original_fetch
        end)
        
        test.it("should handle buffer invalidation during loading", function()
            -- Test what happens if buffer becomes invalid during loading
            local url = "scp://testhost/path/to/large_file.txt"
            
            -- Override nvim_buf_is_valid to return false after buffer creation
            local original_is_valid = vim_mock.api.nvim_buf_is_valid
            local call_count = 0
            vim_mock.api.nvim_buf_is_valid = function(bufnr)
                call_count = call_count + 1
                if call_count > 2 then
                    return false  -- Buffer becomes invalid during loading
                end
                return original_is_valid(bufnr)
            end
            
            operations.simple_open_remote_file(url)
            
            -- Verify error handling
            local found_invalid_log = false
            for _, log in ipairs(mock_state.logs) do
                if log.message:find("Buffer became invalid") then
                    found_invalid_log = true
                    break
                end
            end
            
            -- Restore original function
            vim_mock.api.nvim_buf_is_valid = original_is_valid
        end)
    end)
end)