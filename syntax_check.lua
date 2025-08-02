-- Simple syntax check for our modules
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

print('Checking module syntax...')

local modules = {
    'remote-gitsigns.cache',
    'remote-gitsigns.remote-git', 
    'remote-gitsigns.git-adapter',
    'remote-gitsigns.buffer-detector',
    'remote-gitsigns.init'
}

for _, module in ipairs(modules) do
    local ok, err = pcall(function()
        local f = loadfile('./lua/' .. module:gsub('%.', '/') .. '.lua')
        if f then
            -- File loaded successfully (syntax OK)
        else
            error('Failed to load file')
        end
    end)
    
    if ok then
        print('✓ ' .. module .. ' - syntax OK')
    else
        print('✗ ' .. module .. ' - syntax error: ' .. tostring(err))
    end
end

print('Syntax check complete.')