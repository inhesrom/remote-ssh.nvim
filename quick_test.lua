-- Quick test to verify module loading
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

-- Mock vim APIs for basic testing
vim = {
    log = { levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 } },
    tbl_deep_extend = function(behavior, ...) 
        local result = {}
        for _, t in ipairs({...}) do
            for k, v in pairs(t or {}) do
                result[k] = v
            end
        end
        return result
    end,
    deepcopy = function(t) return t end,
    split = function(s, sep) 
        local result = {}
        for part in string.gmatch(s, '([^' .. sep .. ']+)') do
            table.insert(result, part)
        end
        return result
    end,
    trim = function(s) return s:match('^%s*(.-)%s*$') end,
    startswith = function(s, prefix) return s:sub(1, #prefix) == prefix end,
    fs = { dirname = function(path) return path:match('(.*/)[^/]*$') or '.' end },
    loop = { new_timer = function() return { start = function() end, stop = function() end } end },
    fn = { shellescape = function(s) return "'" .. s .. "'" end },
    defer_fn = function(fn, delay) fn() end,
    schedule = function(fn) fn() end,
}

print('Testing remote-gitsigns module loading...')

-- Test loading cache module
local ok, cache = pcall(require, 'remote-gitsigns.cache')
if ok then
    print('✓ cache module loaded')
    -- Test basic cache operations
    cache.set("test", "key1")
    local value = cache.get("key1")
    if value == "test" then
        print('✓ cache operations work')
    else
        print('✗ cache operations failed')
    end
else
    print('✗ cache module failed: ' .. tostring(cache))
end

print('Module loading test complete!')