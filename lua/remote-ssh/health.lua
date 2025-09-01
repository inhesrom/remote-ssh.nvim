-- Health check module for remote-ssh.nvim plugin
-- This integrates with Neovim's :checkhealth command

local M = {}

-- Import the existing dependency checker
local dependency_checker = require("async-remote-write.dependency_checker")
local utils = require("async-remote-write.utils")
local config = require("async-remote-write.config")

-- Health reporting functions with backward compatibility
local health = vim.health or require("health")
local report_start = health.start or health.report_start
local report_ok = health.ok or health.report_ok
local report_warn = health.warn or health.report_warn
local report_error = health.error or health.report_error
local report_info = health.info or health.report_info

-- Map status symbols to health report functions
local function report_status(status, message)
    if status == "✅" then
        report_ok(message)
    elseif status == "⚠️" then
        report_warn(message)
    elseif status == "❌" then
        report_error(message)
    else
        report_info(message)
    end
end

-- Check Neovim version compatibility
local function check_neovim_version()
    report_start("Neovim Version")

    local version_info = vim.version()
    local version_string = version_info.major .. "." .. version_info.minor .. "." .. version_info.patch

    local required_major, required_minor = 0, 10
    local meets_requirement = (version_info.major > required_major)
        or (version_info.major == required_major and version_info.minor >= required_minor)

    if meets_requirement then
        report_ok("Neovim " .. version_string .. " (meets requirement: " .. required_major .. "." .. required_minor .. ".0+)")
    else
        report_error("Neovim " .. version_string .. " is too old (requires: " .. required_major .. "." .. required_minor .. ".0+)")
    end
end

-- Check local system dependencies
local function check_local_deps()
    report_start("Local System Dependencies")

    -- Run the dependency check but only get local results
    local _, results = dependency_checker.check_dependencies({})

    local all_good = true
    for _, dep in ipairs(results.local_deps) do
        local message = dep.name .. " (" .. dep.description .. ") - " .. dep.details

        if dep.version and dep.version ~= "unknown" then
            message = message .. " [" .. dep.version .. "]"
        end

        if dep.required and dep.status == "❌" then
            report_error(message)
            all_good = false
        elseif dep.status == "⚠️" then
            report_warn(message)
        elseif dep.status == "✅" then
            report_ok(message)
        else
            report_info(message)
        end
    end

    if all_good then
        report_ok("All required local dependencies are available")
    end
end

-- Check Lua module dependencies
local function check_lua_deps()
    report_start("Lua Module Dependencies")

    -- Run the dependency check but only get Lua results
    local _, results = dependency_checker.check_dependencies({})

    local all_good = true
    for _, dep in ipairs(results.lua_deps) do
        local message = dep.name .. " (module: " .. dep.module .. ") - " .. dep.details

        if dep.required and dep.status == "❌" then
            report_error(message)
            all_good = false
        elseif dep.status == "⚠️" then
            report_warn(message)
        elseif dep.status == "✅" then
            report_ok(message)
        else
            report_info(message)
        end
    end

    if all_good then
        report_ok("All required Lua dependencies are available")
    end
end

-- Check plugin configuration
local function check_configuration()
    report_start("Plugin Configuration")

    -- Check if the plugin is properly loaded
    local remote_ssh_loaded, remote_ssh = pcall(require, "remote-ssh")
    if remote_ssh_loaded then
        report_ok("remote-ssh.nvim plugin is loaded")
    else
        report_error("remote-ssh.nvim plugin failed to load: " .. tostring(remote_ssh))
        return
    end

    -- Check configuration
    local cfg = config.config
    if cfg then
        report_ok("Plugin configuration is loaded")

        -- Report key configuration settings
        if cfg.debug then
            report_info("Debug mode: enabled (log level: " .. (cfg.log_level or "unknown") .. ")")
        else
            report_info("Debug mode: disabled")
        end

        if cfg.auto_save ~= nil then
            report_info("Auto save: " .. (cfg.auto_save and "enabled" or "disabled"))
        end

        if cfg.file_watcher and cfg.file_watcher.enabled ~= nil then
            report_info("File watcher: " .. (cfg.file_watcher.enabled and "enabled" or "disabled"))
        end
    else
        report_warn("Plugin configuration not found, using defaults")
    end
end

-- Check remote connectivity (sample a few hosts)
local function check_remote_connectivity()
    report_start("Remote Connectivity")

    -- Get a quick status from dependency checker
    local status, results = dependency_checker.quick_check()

    if status == "ok" then
        report_ok("Remote SSH connectivity check passed")
    elseif status == "warning" then
        report_warn("Remote SSH connectivity has some issues (run :RemoteDependencyCheck for details)")
    else
        report_error("Remote SSH connectivity failed (run :RemoteDependencyCheck for details)")
    end

    -- If we have detailed results, show some summary info
    if results and results.remote_deps then
        local working_hosts = 0
        local total_hosts = #results.remote_deps

        for _, host_result in ipairs(results.remote_deps) do
            if host_result.connectivity.status == "✅" then
                working_hosts = working_hosts + 1
            end
        end

        if total_hosts > 0 then
            if working_hosts == total_hosts then
                report_ok("All " .. total_hosts .. " discovered SSH hosts are reachable")
            elseif working_hosts > 0 then
                report_warn(working_hosts .. "/" .. total_hosts .. " SSH hosts are reachable")
            else
                report_error("None of the " .. total_hosts .. " SSH hosts are reachable")
            end
        else
            report_info("No SSH hosts configured for testing")
        end
    end
end

-- Check active remote buffers and sessions
local function check_active_sessions()
    report_start("Active Remote Sessions")

    -- Count remote buffers
    local remote_buffers = {}
    local remote_lsp_clients = 0

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
            local bufname = vim.api.nvim_buf_get_name(buf)
            if bufname:match("^scp://") or bufname:match("^rsync://") then
                table.insert(remote_buffers, bufname)
            end
        end
    end

    -- Count LSP clients that might be remote
    local clients = vim.lsp.get_clients()
    for _, client in ipairs(clients) do
        if client.name and (client.name:match("remote") or client.config and client.config.cmd and type(client.config.cmd) == "table" and client.config.cmd[1] and client.config.cmd[1]:match("python")) then
            remote_lsp_clients = remote_lsp_clients + 1
        end
    end

    if #remote_buffers > 0 then
        report_ok(#remote_buffers .. " remote buffers are currently open")
        -- Show first few buffer names as examples
        for i = 1, math.min(3, #remote_buffers) do
            report_info("  • " .. vim.fn.fnamemodify(remote_buffers[i], ':t') .. " (" .. remote_buffers[i]:match("^[^:]+://[^/]+") .. ")")
        end
        if #remote_buffers > 3 then
            report_info("  ... and " .. (#remote_buffers - 3) .. " more")
        end
    else
        report_info("No remote buffers currently open")
    end

    if remote_lsp_clients > 0 then
        report_ok(remote_lsp_clients .. " remote LSP clients are active")
    else
        report_info("No remote LSP clients currently active")
    end
end

-- Main health check function (called by :checkhealth remote-ssh)
function M.check()
    report_start("remote-ssh.nvim Health Check")

    -- Quick overall status
    local status, _ = dependency_checker.quick_check()
    if status == "ok" then
        report_ok("Overall status: All systems operational")
    elseif status == "warning" then
        report_warn("Overall status: Some issues detected")
    else
        report_error("Overall status: Critical issues found")
    end

    -- Detailed checks
    check_neovim_version()
    check_configuration()
    check_local_deps()
    check_lua_deps()
    check_remote_connectivity()
    check_active_sessions()

    -- Provide helpful commands
    report_start("Available Commands")
    report_info("Use :RemoteDependencyCheck for detailed dependency analysis")
    report_info("Use :RemoteDependencyQuickCheck for quick status check")
    report_info("Use :RemoteOpen rsync://user@host//path/to/file to open remote files")
    report_info("Use :RemoteTreeBrowser rsync://user@host//path/ to browse remote directories")
end

return M
