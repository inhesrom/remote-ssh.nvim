#!/usr/bin/env lua

-- Test logging functionality
package.path = package.path .. ";./?.lua;./tests/?.lua;./lua/?.lua;./lua/?/init.lua"

-- Mock vim global
vim = vim or {}
vim.log = vim.log or {}
vim.log.levels = {
    DEBUG = 0,
    INFO = 1,
    WARN = 2,
    ERROR = 3,
}

vim.fn = vim.fn or {}
vim.fn.shellescape = function(str)
    return "'" .. str:gsub("'", "'\"'\"'") .. "'"
end

vim.api = vim.api or {}
vim.api.nvim_create_buf = function() return 1 end
vim.api.nvim_buf_is_valid = function() return true end
vim.api.nvim_win_is_valid = function() return true end
vim.api.nvim_buf_set_option = function() end
vim.api.nvim_win_set_option = function() end
vim.api.nvim_buf_set_lines = function() end
vim.api.nvim_buf_set_name = function() end
vim.api.nvim_buf_call = function(_, fn) fn() end
vim.api.nvim_get_current_win = function() return 1 end
vim.api.nvim_set_current_win = function() end
vim.api.nvim_win_set_buf = function() end
vim.api.nvim_win_set_cursor = function() end
vim.api.nvim_win_set_width = function() end
vim.api.nvim_win_close = function() end
vim.api.nvim_echo = function() end

vim.cmd = function() end
vim.schedule = function(fn) fn() end
vim.notify = function() end
vim.keymap = vim.keymap or {}
vim.keymap.set = function() end
vim.inspect = function(t) return tostring(t) end

-- Load the logging module
local logging = require("logging")

-- Test 1: Log storage
print("Test 1: Log storage and retrieval")
logging.clear_logs()

local config = {
    timeout = 30,
    log_level = vim.log.levels.DEBUG,
    debug = true,
}

-- Add some test logs
logging.log("Test error message", vim.log.levels.ERROR, false, config, { module = "test", operation = "test_op" })
logging.log("Test warning message", vim.log.levels.WARN, false, config, { module = "test", url = "scp://test" })
logging.log("Test info message", vim.log.levels.INFO, false, config)
logging.log("Test debug message", vim.log.levels.DEBUG, false, config)

local entries = logging.get_log_entries()
assert(#entries == 4, "Should have 4 log entries, got " .. #entries)
print("✅ Log storage works: " .. #entries .. " entries stored")

-- Test 2: Log filtering
print("\nTest 2: Log filtering")
local error_entries = logging.get_log_entries({ min_level = vim.log.levels.ERROR })
assert(#error_entries == 1, "Should have 1 error entry, got " .. #error_entries)
print("✅ Error filtering works: " .. #error_entries .. " error entries")

local warn_entries = logging.get_log_entries({ min_level = vim.log.levels.WARN })
assert(#warn_entries == 2, "Should have 2 warn+ entries, got " .. #warn_entries)
print("✅ Warning filtering works: " .. #warn_entries .. " warn+ entries")

-- Test 3: Log stats
print("\nTest 3: Log statistics")
local stats = logging.get_log_stats()
assert(stats.total == 4, "Total should be 4, got " .. stats.total)
assert(stats.error == 1, "Errors should be 1, got " .. stats.error)
assert(stats.warn == 1, "Warnings should be 1, got " .. stats.warn)
assert(stats.info == 1, "Info should be 1, got " .. stats.info)
assert(stats.debug == 1, "Debug should be 1, got " .. stats.debug)
print(
    "✅ Statistics work: ERROR="
        .. stats.error
        .. " WARN="
        .. stats.warn
        .. " INFO="
        .. stats.info
        .. " DEBUG="
        .. stats.debug
)

-- Test 4: Clear logs
print("\nTest 4: Clear logs")
logging.clear_logs()
entries = logging.get_log_entries()
assert(#entries == 0, "Should have 0 entries after clear, got " .. #entries)
print("✅ Clear logs works: " .. #entries .. " entries after clear")

-- Test 5: Ring buffer overflow
print("\nTest 5: Ring buffer overflow (max_entries limit)")
logging.buffer_config.max_entries = 10 -- Set small limit for testing

for i = 1, 15 do
    logging.log("Test message " .. i, vim.log.levels.INFO, false, config)
end

entries = logging.get_log_entries()
assert(#entries == 10, "Should have max 10 entries, got " .. #entries)
print("✅ Ring buffer works: " .. #entries .. " entries (capped at max_entries)")

-- Reset to default
logging.buffer_config.max_entries = 1000

-- Test 6: Context preservation
print("\nTest 6: Context preservation")
logging.clear_logs()
logging.log("Test with context", vim.log.levels.ERROR, false, config, {
    module = "tree_browser",
    url = "scp://test/path",
    operation = "list_directory",
    exit_code = 1,
})

entries = logging.get_log_entries()
assert(entries[1].module == "tree_browser", "Module should be preserved")
assert(entries[1].context.url == "scp://test/path", "URL should be preserved")
assert(entries[1].context.exit_code == 1, "Exit code should be preserved")
print("✅ Context preservation works")

print("\n=== All logging tests passed! ===")
