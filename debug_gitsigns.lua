-- Debug script for remote gitsigns functionality
-- Run this in Neovim with :luafile debug_gitsigns.lua

print("=== Remote Gitsigns Debug Information ===")

-- Check if remote-gitsigns is loaded
local remote_gitsigns_ok, remote_gitsigns = pcall(require, 'remote-gitsigns')
print("Remote gitsigns module loaded:", remote_gitsigns_ok)
if not remote_gitsigns_ok then
    print("Error loading remote-gitsigns:", remote_gitsigns)
    return
end

-- Check if it's initialized
local initialized = remote_gitsigns.is_initialized()
print("Remote gitsigns initialized:", initialized)

if initialized then
    -- Get status
    local status = remote_gitsigns.get_status()
    print("Status:", vim.inspect(status))
    
    -- Get config
    local config = remote_gitsigns.get_config()
    print("Config:", vim.inspect(config))
end

-- Check current buffer (safely)
local bufnr, buf_name
local ok = pcall(function()
    bufnr = vim.api.nvim_get_current_buf()
    buf_name = vim.api.nvim_buf_get_name(bufnr)
end)
if ok then
    print("Current buffer:", bufnr, "Name:", buf_name)
else
    print("Could not get current buffer (fast event context)")
    -- Get the first buffer instead
    local bufs = vim.api.nvim_list_bufs()
    if #bufs > 0 then
        bufnr = bufs[1]
        buf_name = vim.api.nvim_buf_get_name(bufnr)
        print("Using first buffer:", bufnr, "Name:", buf_name)
    end
end

-- Check if it's a remote buffer
local utils_ok, utils = pcall(require, 'async-remote-write.utils')
if utils_ok then
    local remote_info = utils.parse_remote_path(buf_name)
    print("Remote path info:", vim.inspect(remote_info))
else
    print("Could not load async-remote-write.utils:", utils)
end

-- Check if gitsigns is available
local gitsigns_ok, gitsigns = pcall(require, 'gitsigns')
print("Gitsigns available:", gitsigns_ok)
if gitsigns_ok then
    print("Gitsigns version:", gitsigns._version or "unknown")
end

-- Check git adapter status
if initialized then
    local git_adapter_ok, git_adapter = pcall(require, 'remote-gitsigns.git-adapter')
    if git_adapter_ok then
        print("Git adapter active:", git_adapter.is_active())
        local remote_info = git_adapter.get_remote_info(bufnr)
        print("Buffer remote info:", vim.inspect(remote_info))
    end
end

-- Check git adapter details
if initialized then
    local git_adapter_ok, git_adapter = pcall(require, 'remote-gitsigns.git-adapter')
    if git_adapter_ok then
        print("Git adapter active:", git_adapter.is_active())
        
        local debug_info = git_adapter.get_debug_info()
        print("Git adapter debug info:")
        print("  Hooked:", debug_info.is_hooked)
        print("  Has original function:", debug_info.has_original)
        print("  Registered buffers:", vim.tbl_count(debug_info.buffer_remote_info))
        print("  Registered cwds:", vim.tbl_count(debug_info.cwd_remote_info))
        
        if bufnr then
            local remote_info = git_adapter.get_remote_info(bufnr)
            print("Current buffer remote info:", vim.inspect(remote_info))
        end
        
        -- Show working directory mappings
        print("Working directory mappings:")
        for cwd, info in pairs(debug_info.cwd_remote_info) do
            print("  " .. cwd .. " -> " .. (info.host or "unknown"))
        end
    end
end

-- Try manual detection if initialized
if initialized and bufnr then
    print("Attempting manual buffer detection...")
    local detection_result = remote_gitsigns.detect_buffer(bufnr)
    print("Detection result:", detection_result)
end

print("=== End Debug Information ===")