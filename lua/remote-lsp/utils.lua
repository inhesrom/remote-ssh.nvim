local M = {}

local config = require('remote-lsp.config')
local log = require('logging').log

-- Function to get the directory of the current Lua script
function M.get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
end

-- Helper function to determine protocol from bufname
function M.get_protocol(bufname)
    if bufname:match("^scp://") then
        return "scp"
    elseif bufname:match("^rsync://") then
        return "rsync"
    else
        return nil
    end
end

-- Parse host and path from buffer name
function M.parse_remote_buffer(bufname)
    local protocol = M.get_protocol(bufname)
    if not protocol then
        return nil, nil, nil
    end

    local pattern = "^" .. protocol .. "://([^/]+)/+(.+)$"  -- Allow multiple slashes after host
    local host, path = bufname:match(pattern)
    if host and path then
        -- Ensure path doesn't start with slash to prevent double slashes
        path = path:gsub("^/+", "")
    end
    return host, path, protocol
end

-- Find root directory based on patterns
function M.find_project_root(host, path, root_patterns)
    if not root_patterns or #root_patterns == 0 then
        return vim.fn.fnamemodify(path, ":h")
    end

    -- Start from the directory containing the file
    local dir = vim.fn.fnamemodify(path, ":h")

    -- Check for root markers using a non-blocking job if possible
    local job_cmd = string.format(
        "ssh %s 'cd %s && find . -maxdepth 2 -name \".git\" -o -name \"compile_commands.json\" | head -n 1'",
        host, vim.fn.shellescape(dir)
    )

    local result = vim.fn.trim(vim.fn.system(job_cmd))
    if result ~= "" then
        -- Found a marker, get its directory
        local marker_dir = vim.fn.fnamemodify(result, ":h")
        if marker_dir == "." then
            return dir
        else
            return dir .. "/" .. marker_dir
        end
    end

    -- If no root markers found, just use the file's directory
    return dir
end

-- Get a unique server key based on server name and host
function M.get_server_key(server_name, host)
    return server_name .. "@" .. host
end

-- Function to debug LSP communications
function M.debug_lsp_traffic(enable)
    if enable then
        -- Enable logging of LSP traffic
        vim.lsp.set_log_level("debug")

        -- Log more details about LSP message exchanges
        if vim.fn.has('nvim-0.8') == 1 then
            -- For Neovim 0.8+
            local path = vim.fn.stdpath("cache") .. "/lsp.log"
            vim.lsp.set_log_level("debug")
            vim.cmd("let g:lsp_log_file = " .. vim.inspect(path))
            vim.cmd("lua vim.lsp.log.set_format_func(vim.inspect)")
            log("LSP logging enabled at: " .. path, vim.log.levels.INFO, true, config.config)
        else
            -- For older Neovim
            local path = vim.fn.stdpath("cache") .. "/lsp.log"
            vim.lsp.set_log_level("debug")
            vim.cmd("let g:lsp_log_file = " .. vim.inspect(path))
            log("LSP logging enabled at: " .. path, vim.log.levels.INFO, true, config.config)
        end
    else
        -- Disable verbose logging
        vim.lsp.set_log_level("warn")
        log("LSP debug logging disabled", vim.log.levels.INFO, true, config.config)
    end
end

return M
