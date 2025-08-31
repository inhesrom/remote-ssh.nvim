-- Dependency checker for remote-ssh.nvim plugin
local M = {}

local utils = require("async-remote-write.utils")
local config = require("async-remote-write.config")
local ssh_utils = require("async-remote-write.ssh_utils")

-- Status indicators
local STATUS = {
    OK = "✅",
    ERROR = "❌",
    WARNING = "⚠️",
    INFO = "ℹ️",
}

-- Dependency definitions
local LOCAL_DEPENDENCIES = {
    {
        name = "ssh",
        command = "ssh",
        version_flag = "-V",
        required = true,
        description = "OpenSSH client for remote connections",
    },
    {
        name = "scp",
        command = "scp",
        required = true,
        description = "Secure copy for file transfers",
    },
    {
        name = "rsync",
        command = "rsync",
        version_flag = "--version",
        required = true,
        description = "File synchronization tool",
    },
    {
        name = "python3",
        command = "python3",
        version_flag = "--version",
        required = true,
        description = "Python 3 for LSP proxy script",
    },
    {
        name = "stat",
        command = "stat",
        version_flag = "--version",
        required = true,
        description = "File status information",
    },
}

local REMOTE_DEPENDENCIES = {
    {
        name = "python3",
        command = "python3 --version",
        required = true,
        description = "Python 3 for LSP proxy",
    },
    {
        name = "rsync",
        command = "rsync --version",
        required = true,
        description = "File synchronization",
    },
    {
        name = "find",
        command = "find --version",
        required = true,
        description = "Directory traversal for tree browser",
    },
    {
        name = "grep",
        command = "grep --version",
        required = true,
        description = "Text searching in remote files",
    },
    {
        name = "stat",
        command = "stat --version",
        required = true,
        description = "File information and permissions",
    },
    {
        name = "ls",
        command = "ls --version",
        required = true,
        description = "Directory listing",
    },
}

local LUA_DEPENDENCIES = {
    {
        name = "plenary.nvim",
        module = "plenary.job",
        required = true,
        description = "Essential async operations library",
    },
    {
        name = "nvim-lspconfig",
        module = "lspconfig",
        required = true,
        description = "LSP configuration framework",
    },
    {
        name = "telescope.nvim",
        module = "telescope",
        required = false,
        description = "Fuzzy finder integration",
    },
    {
        name = "nvim-notify",
        module = "notify",
        required = false,
        description = "Enhanced notifications",
    },
}

-- Results storage
local results = {
    local_deps = {},
    remote_deps = {},
    lua_deps = {},
    neovim_version = {},
    ssh_hosts = {},
    overall_status = "unknown",
}

-- Helper function to run local command and capture output
local function run_local_command(cmd, timeout)
    timeout = timeout or 5000
    local output = {}
    local stderr = {}
    local success = false
    local exit_code = -1

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data then
                vim.list_extend(output, data)
            end
        end,
        on_stderr = function(_, data)
            if data then
                vim.list_extend(stderr, data)
            end
        end,
        on_exit = function(_, code)
            exit_code = code
            success = (code == 0)
        end,
    })

    if job_id <= 0 then
        return false, {}, { "Failed to start command" }
    end

    -- Wait for completion with timeout
    local wait_result = vim.fn.jobwait({ job_id }, timeout)
    if wait_result[1] == -1 then
        vim.fn.jobstop(job_id)
        return false, {}, { "Command timed out after " .. timeout .. "ms" }
    end

    return success, output, stderr
end

-- Helper function to run remote command via SSH
local function run_remote_command(host, cmd, timeout)
    timeout = timeout or 10000
    local ssh_cmd = ssh_utils.build_ssh_cmd(host, cmd)
    return run_local_command(ssh_cmd, timeout)
end

-- Check Neovim version
local function check_neovim_version()
    local version_info = vim.version()
    local version_string = version_info.major .. "." .. version_info.minor .. "." .. version_info.patch

    local required_major, required_minor = 0, 10
    local meets_requirement = (version_info.major > required_major)
        or (version_info.major == required_major and version_info.minor >= required_minor)

    results.neovim_version = {
        status = meets_requirement and STATUS.OK or STATUS.ERROR,
        version = version_string,
        required = required_major .. "." .. required_minor .. ".0+",
        meets_requirement = meets_requirement,
        details = meets_requirement and "Version requirement satisfied" or "Neovim version too old, please upgrade",
    }
end

-- Check local system dependencies
local function check_local_dependencies()
    utils.log("Checking local system dependencies...", vim.log.levels.DEBUG, false, config.config)

    for _, dep in ipairs(LOCAL_DEPENDENCIES) do
        local cmd = dep.version_flag and { dep.command, dep.version_flag } or { "which", dep.command }
        local success, output, stderr = run_local_command(cmd, 3000)

        local result = {
            name = dep.name,
            required = dep.required,
            description = dep.description,
            status = STATUS.ERROR,
            details = "Not found",
            version = "unknown",
        }

        if success and #output > 0 then
            result.status = STATUS.OK
            result.details = "Available"

            -- Extract version if available
            if dep.version_flag and output[1] then
                result.version = output[1]:match("(%d+%.%d+[%.%d]*)") or output[1]:sub(1, 50)
            else
                result.version = "installed"
            end
        else
            result.details = #stderr > 0 and table.concat(stderr, " ") or "Command not found"
        end

        table.insert(results.local_deps, result)
        utils.log("Local dependency " .. dep.name .. ": " .. result.status, vim.log.levels.DEBUG, false, config.config)
    end
end

-- Check Lua dependencies
local function check_lua_dependencies()
    utils.log("Checking Lua module dependencies...", vim.log.levels.DEBUG, false, config.config)

    for _, dep in ipairs(LUA_DEPENDENCIES) do
        local result = {
            name = dep.name,
            module = dep.module,
            required = dep.required,
            description = dep.description,
            status = STATUS.ERROR,
            details = "Module not found",
        }

        local success, module_or_error = pcall(require, dep.module)
        if success then
            result.status = STATUS.OK
            result.details = "Loaded successfully"

            -- Try to get version info if available
            if type(module_or_error) == "table" and module_or_error.version then
                result.version = module_or_error.version
            elseif type(module_or_error) == "table" and module_or_error._VERSION then
                result.version = module_or_error._VERSION
            else
                result.version = "available"
            end
        else
            result.details = "Cannot require '" .. dep.module .. "': " .. tostring(module_or_error)

            if not dep.required then
                result.status = STATUS.WARNING
                result.details = result.details .. " (optional)"
            end
        end

        table.insert(results.lua_deps, result)
        utils.log("Lua dependency " .. dep.name .. ": " .. result.status, vim.log.levels.DEBUG, false, config.config)
    end
end

-- Test SSH connectivity to a host
local function test_ssh_connectivity(host)
    utils.log("Testing SSH connectivity to " .. host, vim.log.levels.DEBUG, false, config.config)

    local result = {
        host = host,
        status = STATUS.ERROR,
        details = "Connection failed",
        response_time = 0,
    }

    local start_time = vim.loop.hrtime()
    local success, output, stderr = run_remote_command(host, "echo 'connectivity_test'", 10000)
    local end_time = vim.loop.hrtime()

    result.response_time = math.floor((end_time - start_time) / 1000000) -- Convert to milliseconds

    if success and #output > 0 and output[1]:match("connectivity_test") then
        result.status = STATUS.OK
        result.details = "Connected (" .. result.response_time .. "ms)"
    else
        result.details = "SSH failed: " .. (#stderr > 0 and table.concat(stderr, " ") or "unknown error")
    end

    return result
end

-- Check remote dependencies for a specific host
local function check_remote_dependencies(host)
    utils.log("Checking remote dependencies on " .. host, vim.log.levels.DEBUG, false, config.config)

    local host_results = {
        host = host,
        connectivity = test_ssh_connectivity(host),
        dependencies = {},
    }

    -- Only check dependencies if connectivity works
    if host_results.connectivity.status == STATUS.OK then
        for _, dep in ipairs(REMOTE_DEPENDENCIES) do
            local result = {
                name = dep.name,
                required = dep.required,
                description = dep.description,
                status = STATUS.ERROR,
                details = "Not available",
                version = "unknown",
            }

            local success, output, stderr = run_remote_command(host, dep.command, 8000)

            if success and #output > 0 then
                result.status = STATUS.OK
                result.details = "Available"
                result.version = output[1]:match("(%d+%.%d+[%.%d]*)") or output[1]:sub(1, 50)
            else
                local error_msg = #stderr > 0 and table.concat(stderr, " ") or "command failed"
                result.details = "Not available: " .. error_msg
            end

            table.insert(host_results.dependencies, result)
            utils.log(
                "Remote dependency " .. dep.name .. " on " .. host .. ": " .. result.status,
                vim.log.levels.DEBUG,
                false,
                config.config
            )
        end
    else
        utils.log("Skipping remote dependency checks due to connectivity failure", vim.log.levels.WARN, false, config.config)
    end

    return host_results
end

-- Discover SSH hosts from config
local function discover_ssh_hosts()
    local hosts = {}

    -- Try to read SSH config
    local ssh_config_file = os.getenv("HOME") .. "/.ssh/config"
    local file = io.open(ssh_config_file, "r")

    if file then
        for line in file:lines() do
            local host = line:match("^%s*Host%s+([%w%.%-_]+)%s*$")
            if host and host ~= "*" then
                table.insert(hosts, host)
            end
        end
        file:close()
    end

    -- Add localhost as default
    if not vim.tbl_contains(hosts, "localhost") then
        table.insert(hosts, "localhost")
    end

    return hosts
end

-- Calculate overall status
local function calculate_overall_status()
    local has_errors = false
    local has_warnings = false

    -- Check Neovim version
    if not results.neovim_version.meets_requirement then
        has_errors = true
    end

    -- Check local dependencies
    for _, dep in ipairs(results.local_deps) do
        if dep.required and dep.status == STATUS.ERROR then
            has_errors = true
        elseif dep.status == STATUS.WARNING then
            has_warnings = true
        end
    end

    -- Check Lua dependencies
    for _, dep in ipairs(results.lua_deps) do
        if dep.required and dep.status == STATUS.ERROR then
            has_errors = true
        elseif dep.status == STATUS.WARNING then
            has_warnings = true
        end
    end

    -- Check remote dependencies (at least one host should work)
    local any_remote_working = false
    for _, host_result in ipairs(results.remote_deps) do
        if host_result.connectivity.status == STATUS.OK then
            any_remote_working = true

            -- Check if all required remote deps are ok
            for _, dep in ipairs(host_result.dependencies) do
                if dep.required and dep.status == STATUS.ERROR then
                    has_warnings = true -- Remote issues are warnings, not errors
                end
            end
        end
    end

    if not any_remote_working and #results.remote_deps > 0 then
        has_warnings = true
    end

    if has_errors then
        results.overall_status = "error"
    elseif has_warnings then
        results.overall_status = "warning"
    else
        results.overall_status = "ok"
    end
end

-- Generate formatted report
local function generate_report()
    local lines = {}

    -- Header with overall status
    local status_icon = results.overall_status == "ok" and STATUS.OK
        or results.overall_status == "warning" and STATUS.WARNING
        or STATUS.ERROR

    table.insert(lines, "")
    table.insert(lines, "=== Remote SSH Plugin Dependency Check ===")
    table.insert(lines, "Overall Status: " .. status_icon .. " " .. string.upper(results.overall_status))
    table.insert(lines, "")

    -- Neovim version
    table.insert(lines, "🔸 Neovim Version:")
    table.insert(
        lines,
        "  "
            .. results.neovim_version.status
            .. " Version "
            .. results.neovim_version.version
            .. " (required: "
            .. results.neovim_version.required
            .. ")"
    )
    table.insert(lines, "    " .. results.neovim_version.details)
    table.insert(lines, "")

    -- Local dependencies
    table.insert(lines, "🔸 Local System Dependencies:")
    for _, dep in ipairs(results.local_deps) do
        local required_text = dep.required and " (required)" or " (optional)"
        table.insert(lines, "  " .. dep.status .. " " .. dep.name .. required_text)
        table.insert(lines, "    " .. dep.description)
        table.insert(lines, "    Version: " .. dep.version .. " | " .. dep.details)
    end
    table.insert(lines, "")

    -- Lua dependencies
    table.insert(lines, "🔸 Lua Module Dependencies:")
    for _, dep in ipairs(results.lua_deps) do
        local required_text = dep.required and " (required)" or " (optional)"
        table.insert(lines, "  " .. dep.status .. " " .. dep.name .. required_text)
        table.insert(lines, "    Module: " .. dep.module .. " | " .. dep.description)
        table.insert(lines, "    " .. dep.details)
    end
    table.insert(lines, "")

    -- Remote dependencies
    if #results.remote_deps > 0 then
        table.insert(lines, "🔸 Remote Host Dependencies:")
        for _, host_result in ipairs(results.remote_deps) do
            table.insert(lines, "")
            table.insert(lines, "  📡 Host: " .. host_result.host)
            table.insert(
                lines,
                "    " .. host_result.connectivity.status .. " SSH Connectivity: " .. host_result.connectivity.details
            )

            if host_result.connectivity.status == STATUS.OK then
                for _, dep in ipairs(host_result.dependencies) do
                    local required_text = dep.required and " (required)" or " (optional)"
                    table.insert(lines, "    " .. dep.status .. " " .. dep.name .. required_text)
                    table.insert(lines, "      " .. dep.description)
                    table.insert(lines, "      Version: " .. dep.version .. " | " .. dep.details)
                end
            end
        end
        table.insert(lines, "")
    end

    -- Recommendations
    if results.overall_status ~= "ok" then
        table.insert(lines, "🔸 Recommendations:")

        if not results.neovim_version.meets_requirement then
            table.insert(lines, "  • Upgrade Neovim to version " .. results.neovim_version.required .. " or higher")
        end

        for _, dep in ipairs(results.local_deps) do
            if dep.required and dep.status == STATUS.ERROR then
                table.insert(lines, "  • Install " .. dep.name .. ": " .. dep.description)
            end
        end

        for _, dep in ipairs(results.lua_deps) do
            if dep.required and dep.status == STATUS.ERROR then
                table.insert(lines, "  • Install " .. dep.name .. " plugin")
            end
        end

        local all_hosts_failed = true
        for _, host_result in ipairs(results.remote_deps) do
            if host_result.connectivity.status == STATUS.OK then
                all_hosts_failed = false
                break
            end
        end

        if all_hosts_failed and #results.remote_deps > 0 then
            table.insert(lines, "  • Setup SSH key authentication for remote hosts")
            table.insert(lines, "  • Verify SSH server is running on remote hosts")
        end

        table.insert(lines, "")
    end

    table.insert(lines, "=== End of Dependency Check ===")
    table.insert(lines, "")

    return table.concat(lines, "\n")
end

-- Main check function
function M.check_dependencies(target_hosts)
    -- Reset results
    results = {
        local_deps = {},
        remote_deps = {},
        lua_deps = {},
        neovim_version = {},
        ssh_hosts = {},
        overall_status = "unknown",
    }

    utils.log("Starting dependency check...", vim.log.levels.INFO, true, config.config)

    -- Check Neovim version
    check_neovim_version()

    -- Check local dependencies
    check_local_dependencies()

    -- Check Lua dependencies
    check_lua_dependencies()

    -- Check remote dependencies
    if target_hosts then
        -- Use provided hosts
        if type(target_hosts) == "string" then
            target_hosts = { target_hosts }
        end
        results.ssh_hosts = target_hosts
    else
        -- Auto-discover from SSH config
        results.ssh_hosts = discover_ssh_hosts()
    end

    utils.log(
        "Checking " .. #results.ssh_hosts .. " SSH hosts: " .. table.concat(results.ssh_hosts, ", "),
        vim.log.levels.DEBUG,
        false,
        config.config
    )

    for _, host in ipairs(results.ssh_hosts) do
        local host_result = check_remote_dependencies(host)
        table.insert(results.remote_deps, host_result)
    end

    -- Calculate overall status
    calculate_overall_status()

    -- Generate and return report
    local report = generate_report()

    utils.log("Dependency check completed with status: " .. results.overall_status, vim.log.levels.INFO, true, config.config)

    return report, results
end

-- Quick check function (just return status)
function M.quick_check(target_hosts)
    local _, results_data = M.check_dependencies(target_hosts)
    return results_data.overall_status, results_data
end

-- Get results (for programmatic access)
function M.get_last_results()
    return results
end

return M
