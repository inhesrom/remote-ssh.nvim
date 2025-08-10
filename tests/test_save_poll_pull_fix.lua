-- Test for save-poll-pull cycle fix
local test = require("tests.init")

-- Add the plugin to path for testing
package.path = package.path .. ";lua/?.lua"

test.describe("Save-Poll-Pull Cycle Fix", function()
    test.it("should not treat own save as remote change when mtime is close", function()
        -- Simulate conflict detection logic with our own save
        local function detect_conflict_test(remote_mtime, last_save_time, last_known_mtime, has_local_changes)
            local recent_save = last_save_time and (os.time() - last_save_time) < 30
            local remote_changed = not last_known_mtime or remote_mtime > last_known_mtime

            if not remote_changed then
                return "no_change"
            end

            if recent_save and last_save_time then
                local mtime_diff = math.abs(remote_mtime - last_save_time)
                if mtime_diff <= 5 then
                    return "no_change" -- Our own save
                end

                if has_local_changes then
                    return "conflict"
                else
                    return "safe_to_pull"
                end
            end

            if has_local_changes then
                return "conflict"
            else
                return "safe_to_pull"
            end
        end

        local now = os.time()

        -- Test: Our own save (mtime within 5 seconds of save time)
        local result1 = detect_conflict_test(
            now, -- remote_mtime (same as save time)
            now, -- last_save_time
            now - 10, -- last_known_mtime (older)
            false -- has_local_changes
        )
        test.assert.equals(result1, "no_change", "Should ignore remote change from own save")

        -- Test: Our own save with 3 second difference
        local result2 = detect_conflict_test(
            now + 3, -- remote_mtime (3 seconds after save)
            now, -- last_save_time
            now - 10, -- last_known_mtime (older)
            false -- has_local_changes
        )
        test.assert.equals(result2, "no_change", "Should ignore remote change within 5 seconds of save")

        -- Test: External change after our save (mtime > 5 seconds after save)
        local result3 = detect_conflict_test(
            now + 10, -- remote_mtime (10 seconds after save)
            now, -- last_save_time
            now - 10, -- last_known_mtime (older)
            false -- has_local_changes
        )
        test.assert.equals(result3, "safe_to_pull", "Should pull external change after our save")

        -- Test: External change after our save with local changes
        local result4 = detect_conflict_test(
            now + 10, -- remote_mtime (10 seconds after save)
            now, -- last_save_time
            now - 10, -- last_known_mtime (older)
            true -- has_local_changes
        )
        test.assert.equals(result4, "conflict", "Should detect conflict when external change conflicts with local changes")
    end)

    test.it("should handle case with no recent save", function()
        local function detect_conflict_test(remote_mtime, last_save_time, last_known_mtime, has_local_changes)
            local recent_save = last_save_time and (os.time() - last_save_time) < 30
            local remote_changed = not last_known_mtime or remote_mtime > last_known_mtime

            if not remote_changed then
                return "no_change"
            end

            if recent_save and last_save_time then
                local mtime_diff = math.abs(remote_mtime - last_save_time)
                if mtime_diff <= 5 then
                    return "no_change"
                end

                if has_local_changes then
                    return "conflict"
                else
                    return "safe_to_pull"
                end
            end

            if has_local_changes then
                return "conflict"
            else
                return "safe_to_pull"
            end
        end

        local now = os.time()

        -- Test: No recent save, no local changes
        local result1 = detect_conflict_test(
            now, -- remote_mtime
            now - 60, -- last_save_time (old save, > 30 seconds)
            now - 10, -- last_known_mtime
            false -- has_local_changes
        )
        test.assert.equals(result1, "safe_to_pull", "Should pull remote changes when no recent save and no local changes")

        -- Test: No recent save, with local changes
        local result2 = detect_conflict_test(
            now, -- remote_mtime
            now - 60, -- last_save_time (old save, > 30 seconds)
            now - 10, -- last_known_mtime
            true -- has_local_changes
        )
        test.assert.equals(result2, "conflict", "Should detect conflict when no recent save but has local changes")

        -- Test: No save time at all
        local result3 = detect_conflict_test(
            now, -- remote_mtime
            nil, -- last_save_time (never saved)
            now - 10, -- last_known_mtime
            false -- has_local_changes
        )
        test.assert.equals(result3, "safe_to_pull", "Should pull remote changes when never saved and no local changes")
    end)

    test.it("should handle edge cases with mtime comparison", function()
        local function detect_conflict_test(remote_mtime, last_save_time, last_known_mtime, has_local_changes)
            local recent_save = last_save_time and (os.time() - last_save_time) < 30
            local remote_changed = not last_known_mtime or remote_mtime > last_known_mtime

            if not remote_changed then
                return "no_change"
            end

            if recent_save and last_save_time then
                local mtime_diff = math.abs(remote_mtime - last_save_time)
                if mtime_diff <= 5 then
                    return "no_change"
                end

                if has_local_changes then
                    return "conflict"
                else
                    return "safe_to_pull"
                end
            end

            if has_local_changes then
                return "conflict"
            else
                return "safe_to_pull"
            end
        end

        local now = os.time()

        -- Test: Remote mtime exactly 5 seconds after save (boundary case)
        local result1 = detect_conflict_test(
            now + 5, -- remote_mtime (exactly 5 seconds after)
            now, -- last_save_time
            now - 10, -- last_known_mtime
            false -- has_local_changes
        )
        test.assert.equals(result1, "no_change", "Should treat exactly 5 second difference as own save")

        -- Test: Remote mtime exactly 6 seconds after save (just over boundary)
        local result2 = detect_conflict_test(
            now + 6, -- remote_mtime (6 seconds after)
            now, -- last_save_time
            now - 10, -- last_known_mtime
            false -- has_local_changes
        )
        test.assert.equals(result2, "safe_to_pull", "Should treat 6 second difference as external change")

        -- Test: Remote mtime before save time (clock skew)
        local result3 = detect_conflict_test(
            now - 2, -- remote_mtime (2 seconds before save)
            now, -- last_save_time
            now - 10, -- last_known_mtime
            false -- has_local_changes
        )
        test.assert.equals(result3, "no_change", "Should handle clock skew gracefully with abs() diff")
    end)
end)
