-- User command registration for remote-session
local M = {}

--- Register all user commands
function M.register()
    -- :RemoteSession [url] - Open session by URL or show picker
    vim.api.nvim_create_user_command("RemoteSession", function(opts)
        local session = require("remote-session.session")

        local url = opts.args ~= "" and opts.args or nil
        session.open(url)
    end, {
        nargs = "?",
        desc = "Open a remote session by URL or show session picker",
        complete = function(arglead, cmdline, cursorpos)
            -- Provide completion from session history
            local session_manager = require("remote-session.session_manager")
            local sessions = session_manager.get_all_for_picker()

            local completions = {}
            for _, s in ipairs(sessions) do
                -- Strip rsync:// for cleaner completion
                local url = s.url:gsub("^rsync://", "")
                if url:find(arglead, 1, true) then
                    table.insert(completions, url)
                end
            end

            return completions
        end,
    })

    -- :RemoteSessionClose [id] - Close session
    vim.api.nvim_create_user_command("RemoteSessionClose", function(opts)
        local session = require("remote-session.session")
        local session_manager = require("remote-session.session_manager")

        local session_id = opts.args ~= "" and opts.args or session_manager.get_active_session_id()

        if not session_id then
            vim.notify("[remote-session] No active session to close", vim.log.levels.WARN)
            return
        end

        session.close(session_id)
    end, {
        nargs = "?",
        desc = "Close the current or specified remote session",
        complete = function(arglead, cmdline, cursorpos)
            local session_manager = require("remote-session.session_manager")
            local sessions = session_manager.get_all_for_picker()

            local completions = {}
            for _, s in ipairs(sessions) do
                if s.id:find(arglead, 1, true) or s.name:find(arglead, 1, true) then
                    table.insert(completions, s.id)
                end
            end

            return completions
        end,
    })

    -- :RemoteSessionMinimize - Minimize current session
    vim.api.nvim_create_user_command("RemoteSessionMinimize", function(opts)
        local session = require("remote-session.session")
        local session_manager = require("remote-session.session_manager")

        local active_id = session_manager.get_active_session_id()
        if not active_id then
            vim.notify("[remote-session] No active session to minimize", vim.log.levels.WARN)
            return
        end

        session.minimize(active_id)
    end, {
        desc = "Minimize the current remote session",
    })

    -- :RemoteSessionRename [name] - Rename current session
    vim.api.nvim_create_user_command("RemoteSessionRename", function(opts)
        local session = require("remote-session.session")

        local new_name = opts.args ~= "" and opts.args or nil
        session.rename(nil, new_name)
    end, {
        nargs = "?",
        desc = "Rename the current remote session",
    })

    -- :RemoteSessionList - List all sessions (for debugging)
    vim.api.nvim_create_user_command("RemoteSessionList", function(opts)
        local session_manager = require("remote-session.session_manager")
        local sessions = session_manager.get_all_for_picker()

        if #sessions == 0 then
            vim.notify("[remote-session] No sessions", vim.log.levels.INFO)
            return
        end

        local active_id = session_manager.get_active_session_id()
        local lines = { "Remote Sessions:" }

        for _, s in ipairs(sessions) do
            local marker = s.id == active_id and " * " or "   "
            local state_str = s.state or "persisted"
            table.insert(lines, string.format("%s[%s] %s (%s)", marker, state_str:upper(), s.name, s.host))
        end

        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end, {
        desc = "List all remote sessions",
    })

    -- :RemoteSessionPicker - Show session picker explicitly
    vim.api.nvim_create_user_command("RemoteSessionPicker", function(opts)
        local picker = require("remote-session.picker")
        picker.show()
    end, {
        desc = "Show the remote session picker",
    })

    -- :RemoteSessionRestore [id] - Restore a specific session
    vim.api.nvim_create_user_command("RemoteSessionRestore", function(opts)
        local session = require("remote-session.session")
        local session_manager = require("remote-session.session_manager")

        if opts.args == "" then
            -- Show picker
            local picker = require("remote-session.picker")
            picker.show()
            return
        end

        -- Try to find session by ID or name
        local sessions = session_manager.get_all_for_picker()
        local target = nil

        for _, s in ipairs(sessions) do
            if s.id == opts.args or s.name == opts.args then
                target = s
                break
            end
        end

        if not target then
            vim.notify("[remote-session] Session not found: " .. opts.args, vim.log.levels.ERROR)
            return
        end

        session.restore(target.id)
    end, {
        nargs = "?",
        desc = "Restore a minimized or persisted session",
        complete = function(arglead, cmdline, cursorpos)
            local session_manager = require("remote-session.session_manager")
            local sessions = session_manager.get_all_for_picker()

            local completions = {}
            for _, s in ipairs(sessions) do
                if s.state ~= "active" then
                    if s.name:find(arglead, 1, true) then
                        table.insert(completions, s.name)
                    end
                end
            end

            return completions
        end,
    })
end

return M
