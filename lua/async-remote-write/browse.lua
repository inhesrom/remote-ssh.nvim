local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local operations = require('async-remote-write.operations')

-- Function to browse a remote directory and show results in Telescope
function M.browse_remote_directory(url)
    -- Parse the remote URL
    local remote_info = utils.parse_remote_path(url)

    if not remote_info then
        utils.log("Invalid remote URL: " .. url, vim.log.levels.ERROR, true, config.config)
        return
    end

    local host = remote_info.host
    local path = remote_info.path

    -- Ensure path starts with a slash (absolute path)
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    -- Ensure path ends with a slash for consistency
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    -- Log the browsing operation
    utils.log("Browsing remote directory: " .. url, vim.log.levels.INFO, true, config.config)

    -- Use a bash script that's compatible with most systems
    local bash_cmd = [[
    cd %s && \
    find . -maxdepth 1 | sort | while read f; do
      if [ "$f" != "." ]; then
        if [ -d "$f" ]; then echo "d ${f#./}"; else echo "f ${f#./}"; fi
      fi
    done
    ]]

    local cmd = {"ssh", host, string.format(bash_cmd, vim.fn.shellescape(path))}

    -- Create job to execute command
    local output = {}
    local stderr_output = {}

    local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(stderr_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    utils.log("Error listing directory: " .. table.concat(stderr_output, "\n"),
                              vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            vim.schedule(function()
                -- Process output to get file list
                local files = M.parse_find_output(output, path, remote_info.protocol, host)

                -- Check if directory is empty
                if #files == 0 then
                    utils.log("Directory is empty", vim.log.levels.INFO, true, config.config)
                    return
                end

                -- Show files in Telescope
                M.show_files_in_telescope(files, url)
            end)
        end
    })

    if job_id <= 0 then
        utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to parse find output into a list of files
function M.parse_find_output(output, path, protocol, host)
    local files = {}

    for _, line in ipairs(output) do
        -- Parse the line (type, name format)
        local file_type, name = line:match("^([df])%s+(.+)$")

        if file_type and name and name ~= "." and name ~= ".." then
            -- Check if it's a directory or file
            local is_dir = (file_type == "d")

            -- Format the full path
            local full_path = path .. name

            -- Format the URL - ensure we have only one slash after the host
            local url_path = full_path
            if url_path:sub(1, 1) ~= "/" then
                url_path = "/" .. url_path
            end

            -- Construct the proper URL with double slash after host to ensure path is treated as absolute
            local file_url = protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

            table.insert(files, {
                name = name,
                path = full_path,
                url = file_url,
                is_dir = is_dir,
                type = file_type
            })
        end
    end

    -- Sort directories first, then files
    table.sort(files, function(a, b)
        if a.is_dir and not b.is_dir then
            return true
        elseif not a.is_dir and b.is_dir then
            return false
        else
            return a.name < b.name
        end
    end)

    -- Add a special entry for the parent directory
    local parent_url = M.get_parent_directory(protocol .. "://" .. host .. path)
    if parent_url then
        table.insert(files, 1, {
            name = "..",
            path = M.get_path_from_url(parent_url),
            url = parent_url,
            is_dir = true,
            type = "d" -- It's a directory
        })
    end

    return files
end

-- Extract path from URL
function M.get_path_from_url(url)
    local remote_info = utils.parse_remote_path(url)
    if remote_info then
        return remote_info.path
    end
    return nil
end

-- Function to show files in Telescope
function M.show_files_in_telescope(files, base_url)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim",
                  vim.log.levels.ERROR, true, config.config)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    -- Create a picker
    pickers.new({}, {
        prompt_title = "Remote Files: " .. base_url,
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local icon = entry.is_dir and "📁 " or "📄 "
                if entry.name == ".." then
                    icon = "⬆️ "
                end

                return {
                    value = entry,
                    display = icon .. entry.name,
                    ordinal = entry.name,
                    path = entry.path
                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- When an item is selected
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)

                if selection then
                    local file = selection.value

                    if file.is_dir then
                        -- If it's a directory, browse into it
                        M.browse_remote_directory(file.url)
                    else
                        -- If it's a file, open it
                        operations.simple_open_remote_file(file.url)
                    end
                end
            end)

            return true
        end
    }):find()
end

-- Function to get the parent directory of a URL
function M.get_parent_directory(url)
    local remote_info = utils.parse_remote_path(url)

    if not remote_info then
        return nil
    end

    local host = remote_info.host
    local path = remote_info.path
    local protocol = remote_info.protocol

    -- Remove trailing slash if present
    if path:sub(-1) == "/" then
        path = path:sub(1, -2)
    end

    -- Get parent path
    local parent_path = path:match("^(.+)/[^/]+$")

    if not parent_path then
        -- We're at the root or a direct child of root
        if path:match("^/[^/]*$") then
            -- At root or direct child of root, return root
            parent_path = "/"
        else
            return nil
        end
    end

    -- Ensure parent_path ends with a slash for consistency
    if parent_path:sub(-1) ~= "/" then
        parent_path = parent_path .. "/"
    end

    return protocol .. "://" .. host .. parent_path
end

return M
