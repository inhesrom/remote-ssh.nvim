#!/usr/bin/env lua

-- Test runner for remote-ssh.nvim
-- Usage: lua tests/run_tests.lua [test_file]

-- Add current directory to Lua path for require statements
package.path = package.path .. ';./?.lua;./tests/?.lua;./lua/?.lua;./lua/?/init.lua'

-- Mock vim global for testing
vim = {
    fn = {
        fnamemodify = function(path, modifier)
            if modifier == ":h" then
                -- Return directory part
                local dir = path:match("^(.*/)")
                if dir then
                    return dir:sub(1, -2) -- Remove trailing slash
                else
                    return "."
                end
            elseif modifier == ":t" then
                -- Return filename part
                return path:match("([^/]+)$") or path
            elseif modifier == ":e" then
                -- Return extension
                return path:match("%.([^./]+)$") or ""
            end
            return path
        end,
        shellescape = function(str, special)
            if special == 1 then
                -- Enhanced shell escaping for special characters
                return "'" .. str:gsub("'", "'\"'\"'") .. "'"
            else
                return "'" .. str:gsub("'", "'\"'\"'") .. "'"
            end
        end,
        trim = function(str)
            return str:match("^%s*(.-)%s*$")
        end,
        system = function(cmd)
            -- Default system implementation (will be mocked during tests)
            return ""
        end,
        filereadable = function(path)
            return 1  -- Mock as readable for testing
        end,
        getfsize = function(path)
            return 50000  -- Default file size for testing
        end,
        readfile = function(path)
            return {"Line 1", "Line 2", "Line 3"}  -- Default content for testing
        end
    },
    tbl_contains = function(table, value)
        for _, v in ipairs(table) do
            if v == value then
                return true
            end
        end
        return false
    end,
    tbl_count = function(table)
        local count = 0
        for _ in pairs(table) do
            count = count + 1
        end
        return count
    end,
    tbl_isempty = function(table)
        return next(table) == nil
    end,
    list_extend = function(dst, src)
        for _, item in ipairs(src) do
            table.insert(dst, item)
        end
        return dst
    end,
    deepcopy = function(table)
        local function copy(obj)
            if type(obj) ~= 'table' then return obj end
            local res = {}
            for k, v in pairs(obj) do
                res[copy(k)] = copy(v)
            end
            return res
        end
        return copy(table)
    end,
    inspect = function(obj)
        local function serialize(o)
            if type(o) == "number" then
                return tostring(o)
            elseif type(o) == "string" then
                return string.format("%q", o)
            elseif type(o) == "table" then
                local result = "{"
                local first = true
                for k, v in pairs(o) do
                    if not first then result = result .. ", " end
                    first = false
                    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                        result = result .. k .. " = " .. serialize(v)
                    else
                        result = result .. "[" .. serialize(k) .. "] = " .. serialize(v)
                    end
                end
                return result .. "}"
            else
                return tostring(o)
            end
        end
        return serialize(obj)
    end,
    log = {
        levels = {
            DEBUG = 0,
            INFO = 1,
            WARN = 2,
            ERROR = 3
        }
    }
}

-- Set up vim global before loading any plugin code
vim.cmd = function() end  -- Mock vim.cmd
vim.api = {
    nvim_buf_get_name = function() return "" end,
    nvim_buf_is_valid = function(bufnr) return bufnr and bufnr <= 100 end, -- Mock: only buffers 1-100 are valid
    nvim_create_augroup = function(name, opts) return name end,
    nvim_create_autocmd = function(events, opts) end,
    nvim_clear_autocmds = function(opts) end,
    nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, replacement) return true end,
    nvim_buf_set_option = function(bufnr, option, value) end,
    nvim_buf_get_option = function(bufnr, option) return nil end,
    nvim_create_buf = function(listed, scratch) return math.random(1, 1000) end,
    nvim_buf_set_name = function(bufnr, name) end,
    nvim_set_current_buf = function(bufnr) end,
    nvim_win_set_cursor = function(win, pos) end,
    nvim_list_bufs = function() return {1, 2, 3, 4, 5} end  -- Mock: return some valid buffer numbers
}
vim.bo = {}
-- Buffer-local variables for metadata system
vim.b = setmetatable({}, {
    __index = function(t, bufnr)
        if not rawget(t, bufnr) then
            rawset(t, bufnr, {})
        end
        return rawget(t, bufnr)
    end
})
vim.schedule = function(fn) fn() end
vim.defer_fn = function(fn, delay) fn() end

-- Mock logging properly
local logging = {
    log = function(message, level, force, config)
        -- Simple mock logging that doesn't fail
        local config_obj = config or { log_level = 1, debug = false }
        level = level or 1
        -- Just return without doing anything complex
    end
}

-- Mock lspconfig
local lspconfig = {
    rust_analyzer = {
        document_config = {
            default_config = {
                cmd = { "rust-analyzer" }
            }
        }
    },
    clangd = {
        document_config = {
            default_config = {
                cmd = { "clangd" }
            }
        }
    },
    pyright = {
        document_config = {
            default_config = {
                cmd = { "pyright-langserver", "--stdio" }
            }
        }
    },
    cmake = {
        document_config = {
            default_config = {
                cmd = { "cmake-language-server" }
            }
        }
    }
}

-- Replace require for logging and lspconfig modules
local original_require = require
_G.require = function(name)
    if name == 'logging' then
        return logging
    elseif name == 'lspconfig' then
        return lspconfig
    end
    return original_require(name)
end

-- Load test framework (ensure consistent module path)
local test = require('tests.init')

-- Get command line arguments
local args = {...}
local test_file = args[1]

if test_file then
    -- Run specific test file
    print("Running test file: " .. test_file)
    local success, err = pcall(function() require('tests.' .. test_file) end)
    if not success then
        print("Error loading test file " .. test_file .. ": " .. err)
    else
        print("Successfully loaded test file. Test count: " .. #test.tests)
    end
else
    -- Run all test files
    print("Running all tests...")

    -- Load all test files
    local test_files = {
        'test_simple',
        'test_root_simple',
        'test_proxy',
        'test_proxy_integration',
        'test_proxy_script',
        'test_client_integration',
        'test_buffer_management',
        'test_hover_uri_translation',
        'test_ssh_command_escaping',
        'test_file_browser_ssh',
        'test_file_browser_debug',
        'test_ssh_user_host',
        'test_ssh_robust_connection',
        'test_non_blocking_file_loading',
        'test_operations_integration',
        'test_lsp_core',
        'test_lsp_proxy_advanced',
        'test_lsp_language_servers',
        'test_lsp_file_watcher_prep',
        'test_deprecated_api',
        'test_deprecated_api_detection',
    }

    for _, file in ipairs(test_files) do
        print("\nLoading test file: " .. file)
        local success, err = pcall(function() require('tests.' .. file) end)
        if not success then
            print("Error loading test file " .. file .. ": " .. err)
        else
            print("Test count after loading " .. file .. ": " .. #test.tests)
        end
    end
end

-- Run the tests
local success = test.run_tests()

-- Exit with appropriate code
if success then
    print("\n✅ All tests passed!")
    os.exit(0)
else
    print("\n❌ Some tests failed!")
    os.exit(1)
end
