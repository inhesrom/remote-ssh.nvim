-- Test script for remote gitsigns functionality
-- Run this with: nvim --headless -c "luafile test_remote_gitsigns.lua"

local function test_remote_gitsigns()
    print("Testing Remote Gitsigns Integration...")
    
    -- Test 1: Check if modules load correctly
    print("\n1. Testing module loading...")
    
    local modules = {
        'remote-gitsigns',
        'remote-gitsigns.git-adapter',
        'remote-gitsigns.remote-git',
        'remote-gitsigns.buffer-detector',
        'remote-gitsigns.cache',
    }
    
    for _, module in ipairs(modules) do
        local ok, mod = pcall(require, module)
        if ok then
            print("  ✓ " .. module .. " loaded successfully")
        else
            print("  ✗ " .. module .. " failed to load: " .. tostring(mod))
            return false
        end
    end
    
    -- Test 2: Check configuration
    print("\n2. Testing configuration...")
    
    local remote_gitsigns = require('remote-gitsigns')
    
    -- Test setup with minimal config
    local setup_ok, setup_err = pcall(function()
        remote_gitsigns.setup({
            enabled = true,
            cache = { enabled = false }, -- Disable cache for testing
            detection = { async_detection = false }, -- Sync for testing
            auto_attach = false, -- Don't auto-attach during tests
        })
    end)
    
    if setup_ok then
        print("  ✓ Setup completed successfully")
    else
        print("  ✗ Setup failed: " .. tostring(setup_err))
        return false
    end
    
    -- Test 3: Check if initialized
    print("\n3. Testing initialization...")
    
    if remote_gitsigns.is_initialized() then
        print("  ✓ Remote gitsigns initialized")
    else
        print("  ✗ Remote gitsigns not initialized")
        return false
    end
    
    -- Test 4: Check git adapter
    print("\n4. Testing git adapter...")
    
    local git_adapter = require('remote-gitsigns.git-adapter')
    
    if git_adapter.is_active() then
        print("  ✓ Git adapter is active")
    else
        print("  ✗ Git adapter is not active")
        return false
    end
    
    -- Test 5: Test cache functionality
    print("\n5. Testing cache...")
    
    local cache = require('remote-gitsigns.cache')
    
    -- Test cache operations
    cache.set("test_value", "test_key", "component")
    local cached_value = cache.get("test_key", "component")
    
    if cached_value == "test_value" then
        print("  ✓ Cache set/get works")
    else
        print("  ✗ Cache set/get failed")
        return false
    end
    
    -- Test cache statistics
    local stats = cache.get_stats()
    if stats and stats.hits and stats.misses then
        print("  ✓ Cache statistics available")
    else
        print("  ✗ Cache statistics not available")
        return false
    end
    
    -- Test 6: Test remote git functions
    print("\n6. Testing remote git functions...")
    
    local remote_git = require('remote-gitsigns.remote-git')
    
    -- Test cache functions
    remote_git.cache_git_root("test-host", "/test/path", "/test/git/root")
    local cached_root = remote_git.get_git_root("test-host", "/test/path")
    
    if cached_root == "/test/git/root" then
        print("  ✓ Remote git caching works")
    else
        print("  ✗ Remote git caching failed")
        return false
    end
    
    -- Test 7: Test buffer detector
    print("\n7. Testing buffer detector...")
    
    local buffer_detector = require('remote-gitsigns.buffer-detector')
    
    -- Test configuration
    local config = buffer_detector.get_config()
    if config and config.exclude_patterns then
        print("  ✓ Buffer detector configuration available")
    else
        print("  ✗ Buffer detector configuration not available")
        return false
    end
    
    -- Test 8: Test status information
    print("\n8. Testing status information...")
    
    local status = remote_gitsigns.get_status()
    if status and status.initialized and status.enabled then
        print("  ✓ Status information available")
        print("    - Initialized: " .. tostring(status.initialized))
        print("    - Enabled: " .. tostring(status.enabled))
        print("    - Git adapter active: " .. tostring(status.git_adapter_active))
        print("    - Cache enabled: " .. tostring(status.cache_enabled))
    else
        print("  ✗ Status information not available")
        return false
    end
    
    -- Test 9: Test user commands (if in full Neovim)
    if vim.api then
        print("\n9. Testing user commands...")
        
        local commands = {
            'RemoteGitsignsDetect',
            'RemoteGitsignsStats',
            'RemoteGitsignsClearCache',
            'RemoteGitsignsStatus',
        }
        
        for _, cmd in ipairs(commands) do
            local cmd_exists = vim.fn.exists(':' .. cmd) == 2
            if cmd_exists then
                print("  ✓ Command :" .. cmd .. " exists")
            else
                print("  ✗ Command :" .. cmd .. " does not exist")
                return false
            end
        end
    end
    
    -- Test 10: Cleanup
    print("\n10. Testing cleanup...")
    
    local cleanup_ok, cleanup_err = pcall(function()
        remote_gitsigns.shutdown()
    end)
    
    if cleanup_ok then
        print("  ✓ Cleanup completed successfully")
    else
        print("  ✗ Cleanup failed: " .. tostring(cleanup_err))
        return false
    end
    
    -- Verify shutdown
    if not remote_gitsigns.is_initialized() then
        print("  ✓ Successfully shut down")
    else
        print("  ✗ Shutdown did not complete properly")
        return false
    end
    
    print("\n✅ All tests passed! Remote gitsigns integration is working correctly.")
    return true
end

-- Run the test
local success = test_remote_gitsigns()

if success then
    print("\n🎉 Remote gitsigns implementation is ready to use!")
    print("\nTo use it, add this to your config:")
    print([[
require('remote-ssh').setup({
    -- ... your existing config ...
    gitsigns = {
        enabled = true,
        auto_attach = true,
    }
})
    ]])
else
    print("\n❌ Some tests failed. Please check the implementation.")
    os.exit(1)
end