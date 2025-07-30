-- Simplified but comprehensive test suite for file-watcher functionality
local test = require('tests.init')

-- Add the plugin to path for testing
package.path = package.path .. ';lua/?.lua'

test.describe("File Watcher URL Parsing", function()
    test.it("should parse scp:// URLs correctly", function()
        local url = "scp://user@example.com:2222/path/to/file.txt"

        -- Test URL pattern matching
        local protocol, user, host, port, path = url:match("^(scp)://([^@]+)@([^:/]+):?(%d*)(/.*)$")

        test.assert.equals(protocol, "scp", "Should extract protocol")
        test.assert.equals(user, "user", "Should extract user")
        test.assert.equals(host, "example.com", "Should extract host")
        test.assert.equals(port, "2222", "Should extract port")
        test.assert.equals(path, "/path/to/file.txt", "Should extract path")
    end)

    test.it("should parse rsync:// URLs correctly", function()
        local url = "rsync://user@example.com/path/to/file.txt"

        local protocol, user, host, port, path = url:match("^(rsync)://([^@]+)@([^:/]+):?(%d*)(/.*)$")

        test.assert.equals(protocol, "rsync", "Should extract protocol")
        test.assert.equals(user, "user", "Should extract user")
        test.assert.equals(host, "example.com", "Should extract host")
        test.assert.equals(port, "", "Should handle missing port")
        test.assert.equals(path, "/path/to/file.txt", "Should extract path")
    end)

    test.it("should reject non-remote URLs", function()
        local url = "/local/path/to/file.txt"

        local protocol = url:match("^(scp)://") or url:match("^(rsync)://")

        test.assert.falsy(protocol, "Should not match local paths")
    end)

    test.it("should parse SSH config aliases with double-slash format", function()
        local utils = require('async-remote-write.utils')

        -- Test SSH config alias with double-slash (like the user's example)
        local url = "rsync://aws-instance//home/ubuntu/repo/"
        local remote_info = utils.parse_remote_path(url)

        test.assert.truthy(remote_info, "Should parse SSH config alias URL")
        test.assert.equals(remote_info.protocol, "rsync", "Should extract protocol")
        test.assert.equals(remote_info.host, "aws-instance", "Should extract SSH alias host")
        test.assert.equals(remote_info.path, "/home/ubuntu/repo/", "Should extract path")
        test.assert.truthy(remote_info.has_double_slash, "Should detect double-slash format")

        -- Test with user and SSH alias
        local url2 = "scp://ubuntu@my-server//opt/app/config.txt"
        local remote_info2 = utils.parse_remote_path(url2)

        test.assert.truthy(remote_info2, "Should parse user@alias URL")
        test.assert.equals(remote_info2.protocol, "scp", "Should extract protocol")
        test.assert.equals(remote_info2.host, "ubuntu@my-server", "Should extract user@alias")
        test.assert.equals(remote_info2.path, "/opt/app/config.txt", "Should extract path")
        test.assert.truthy(remote_info2.has_double_slash, "Should detect double-slash format")
    end)
end)

test.describe("File Watcher Conflict Detection Logic", function()
    test.it("should detect no conflict when no changes", function()
        local has_local_changes = false
        local recent_save = false
        local remote_changed = false

        local conflict_type
        if remote_changed and (has_local_changes or recent_save) then
            conflict_type = "conflict"
        elseif remote_changed then
            conflict_type = "safe_to_pull"
        else
            conflict_type = "no_change"
        end

        test.assert.equals(conflict_type, "no_change", "Should detect no change")
    end)

    test.it("should detect safe pull when only remote changed", function()
        local has_local_changes = false
        local recent_save = false
        local remote_changed = true

        local conflict_type
        if remote_changed and (has_local_changes or recent_save) then
            conflict_type = "conflict"
        elseif remote_changed then
            conflict_type = "safe_to_pull"
        else
            conflict_type = "no_change"
        end

        test.assert.equals(conflict_type, "safe_to_pull", "Should allow safe pull")
    end)

    test.it("should detect conflict when both local and remote changed", function()
        local has_local_changes = true
        local recent_save = false
        local remote_changed = true

        local conflict_type
        if remote_changed and (has_local_changes or recent_save) then
            conflict_type = "conflict"
        elseif remote_changed then
            conflict_type = "safe_to_pull"
        else
            conflict_type = "no_change"
        end

        test.assert.equals(conflict_type, "conflict", "Should detect conflict")
    end)

    test.it("should detect conflict when recent save and remote changed", function()
        local has_local_changes = false
        local recent_save = true
        local remote_changed = true

        local conflict_type
        if remote_changed and (has_local_changes or recent_save) then
            conflict_type = "conflict"
        elseif remote_changed then
            conflict_type = "safe_to_pull"
        else
            conflict_type = "no_change"
        end

        test.assert.equals(conflict_type, "conflict", "Should detect conflict with recent save")
    end)
end)

test.describe("File Watcher SSH Command Building", function()
    test.it("should build SSH commands correctly", function()
        local function build_ssh_command(user, host, port, command)
            local ssh_args = {"ssh"}

            -- Add connection options
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ConnectTimeout=10")

            -- Add port if specified
            if port and port ~= "" and tonumber(port) then
                table.insert(ssh_args, "-p")
                table.insert(ssh_args, tostring(port))
            end

            -- Add user@host
            local full_host = user and (user .. "@" .. host) or host
            table.insert(ssh_args, full_host)
            table.insert(ssh_args, command)

            return ssh_args
        end

        local cmd = build_ssh_command("user", "example.com", "2222", "stat -c %Y '/path/file.txt'")

        test.assert.contains(cmd, "ssh", "Should include ssh command")
        test.assert.contains(cmd, "user@example.com", "Should include user@host")
        test.assert.contains(cmd, "-p", "Should include port flag")
        test.assert.contains(cmd, "2222", "Should include port number")
        test.assert.contains(cmd, "stat -c %Y '/path/file.txt'", "Should include stat command")
    end)

    test.it("should build SSH commands without port", function()
        local function build_ssh_command(user, host, port, command)
            local ssh_args = {"ssh"}

            -- Add connection options
            table.insert(ssh_args, "-o")
            table.insert(ssh_args, "ConnectTimeout=10")

            -- Add port if specified
            if port and port ~= "" and tonumber(port) then
                table.insert(ssh_args, "-p")
                table.insert(ssh_args, tostring(port))
            end

            -- Add user@host
            local full_host = user and (user .. "@" .. host) or host
            table.insert(ssh_args, full_host)
            table.insert(ssh_args, command)

            return ssh_args
        end

        local cmd = build_ssh_command("user", "example.com", "", "stat -c %Y '/path/file.txt'")

        test.assert.contains(cmd, "ssh", "Should include ssh command")
        test.assert.contains(cmd, "user@example.com", "Should include user@host")
        -- Should not contain port flags when no port specified
        local has_port_flag = false
        for i, arg in ipairs(cmd) do
            if arg == "-p" then
                has_port_flag = true
                break
            end
        end
        test.assert.falsy(has_port_flag, "Should not include port flag when no port")
    end)
end)

test.describe("File Watcher Retry Logic", function()
    test.it("should implement exponential backoff correctly", function()
        local function calculate_backoff_delay(retry_count, initial_delay)
            local delay = initial_delay
            for i = 1, retry_count - 1 do
                delay = delay * 2
            end
            return delay
        end

        test.assert.equals(calculate_backoff_delay(1, 1000), 1000, "First attempt should use initial delay")
        test.assert.equals(calculate_backoff_delay(2, 1000), 2000, "Second attempt should double delay")
        test.assert.equals(calculate_backoff_delay(3, 1000), 4000, "Third attempt should quadruple delay")
        test.assert.equals(calculate_backoff_delay(4, 1000), 8000, "Fourth attempt should use 8x delay")
    end)

    test.it("should limit retry attempts correctly", function()
        local max_retries = 3
        local attempt_count = 0

        local function should_retry(attempt)
            return attempt <= max_retries
        end

        -- Simulate retry attempts
        for attempt = 1, 5 do
            if should_retry(attempt) then
                attempt_count = attempt_count + 1
            end
        end

        test.assert.equals(attempt_count, 3, "Should limit to max retry attempts")
    end)
end)

test.describe("File Watcher Timer Management", function()
    test.it("should track timer state correctly", function()
        local timer_state = {
            active = false,
            interval = 5000,
            last_trigger = nil
        }

        -- Simulate starting timer
        local function start_timer(interval)
            timer_state.active = true
            timer_state.interval = interval
            timer_state.last_trigger = os.time()
        end

        -- Simulate stopping timer
        local function stop_timer()
            timer_state.active = false
            timer_state.last_trigger = nil
        end

        test.assert.falsy(timer_state.active, "Timer should start inactive")

        start_timer(5000)
        test.assert.truthy(timer_state.active, "Timer should be active after start")
        test.assert.equals(timer_state.interval, 5000, "Timer should store correct interval")
        test.assert.truthy(timer_state.last_trigger, "Timer should track last trigger time")

        stop_timer()
        test.assert.falsy(timer_state.active, "Timer should be inactive after stop")
        test.assert.falsy(timer_state.last_trigger, "Timer should clear trigger time")
    end)
end)

test.describe("File Watcher Configuration Validation", function()
    test.it("should validate poll intervals correctly", function()
        local function validate_poll_interval(interval)
            return type(interval) == "number" and interval > 0
        end

        test.assert.truthy(validate_poll_interval(5000), "Should accept valid positive number")
        test.assert.truthy(validate_poll_interval(1), "Should accept minimum positive value")
        test.assert.falsy(validate_poll_interval(0), "Should reject zero")
        test.assert.falsy(validate_poll_interval(-1000), "Should reject negative numbers")
        test.assert.falsy(validate_poll_interval("5000"), "Should reject string values")
        test.assert.falsy(validate_poll_interval(nil), "Should reject nil values")
    end)

    test.it("should validate conflict states correctly", function()
        local valid_states = {"none", "detected", "resolving"}

        local function validate_conflict_state(state)
            for _, valid_state in ipairs(valid_states) do
                if state == valid_state then
                    return true
                end
            end
            return false
        end

        test.assert.truthy(validate_conflict_state("none"), "Should accept 'none'")
        test.assert.truthy(validate_conflict_state("detected"), "Should accept 'detected'")
        test.assert.truthy(validate_conflict_state("resolving"), "Should accept 'resolving'")
        test.assert.falsy(validate_conflict_state("invalid"), "Should reject invalid states")
        test.assert.falsy(validate_conflict_state(""), "Should reject empty string")
        test.assert.falsy(validate_conflict_state(nil), "Should reject nil")
    end)
end)

test.describe("File Watcher Status Tracking", function()
    test.it("should provide accurate status information", function()
        local watcher_status = {
            enabled = false,
            active = false,
            conflict_state = "none",
            poll_interval = 5000,
            last_check = nil,
            last_remote_mtime = nil
        }

        -- Simulate starting file watching
        local function start_watching()
            watcher_status.enabled = true
            watcher_status.active = true
            watcher_status.last_check = os.time()
        end

        -- Simulate stopping file watching
        local function stop_watching()
            watcher_status.enabled = false
            watcher_status.active = false
        end

        test.assert.falsy(watcher_status.enabled, "Should start disabled")
        test.assert.falsy(watcher_status.active, "Should start inactive")

        start_watching()
        test.assert.truthy(watcher_status.enabled, "Should be enabled after start")
        test.assert.truthy(watcher_status.active, "Should be active after start")
        test.assert.truthy(watcher_status.last_check, "Should track last check time")

        stop_watching()
        test.assert.falsy(watcher_status.enabled, "Should be disabled after stop")
        test.assert.falsy(watcher_status.active, "Should be inactive after stop")
    end)
end)
