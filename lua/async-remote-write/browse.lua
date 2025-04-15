local M = {}

local config = require('async-remote-write.config')
local utils = require('async-remote-write.utils')
local operations = require('async-remote-write.operations')

local selected_files = {}
local files_to_delete = {}
local files_to_create = {}
local MAX_FILES = 50000 -- Limit the total number of files

-- Map to track the status of each file for visual feedback
local file_status = {}

-- Function to browse a remote directory and show results in Telescope
function M.browse_remote_directory(url, reset_selections)
    -- Reset selected files only if explicitly requested
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        utils.log("Reset file selections", vim.log.levels.DEBUG, false, config.config)
    end

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
                    utils.log("Error listing directory: " .. table.concat(stderr_output, "\n"), vim.log.levels.ERROR, true, config.config)
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

-- Function to browse all files recursively in a remote directory and show results in Telescope
function M.browse_remote_files(url, reset_selections)
    -- Reset selected files only if explicitly requested
    if reset_selections then
        selected_files = {}
        files_to_delete = {}
        files_to_create = {}
        file_status = {}
        utils.log("Reset file selections", vim.log.levels.DEBUG, false, config.config)
    end

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
    utils.log("Browsing remote files recursively: " .. url, vim.log.levels.INFO, true, config.config)
    utils.log("Searching for up to " .. MAX_FILES .. " files...", vim.log.levels.INFO, true, config.config)

    -- First, verify the directory exists and is accessible
    local check_dir_cmd = {"ssh", host, "ls -la " .. vim.fn.shellescape(path) .. " 2>&1"}

    -- Progress indicator timer
    local progress_count = 0
    local progress_chars = {"-", "\\", "|", "/"}
    local progress_timer = vim.loop.new_timer()
    local searching = false

    progress_timer:start(200, 200, vim.schedule_wrap(function()
        if searching then
            progress_count = (progress_count % 4) + 1
            utils.log("Searching files " .. progress_chars[progress_count], vim.log.levels.INFO, true, config.config)
        end
    end))

    -- Create job to execute directory check command
    local check_output = {}

    local check_job_id = vim.fn.jobstart(check_dir_cmd, {
        on_stdout = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(check_output, line)
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                for _, line in ipairs(data) do
                    if line and line ~= "" then
                        table.insert(check_output, line)
                    end
                end
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                progress_timer:close()
                vim.schedule(function()
                    utils.log("Error accessing directory: " .. table.concat(check_output, "\n"),
                              vim.log.levels.ERROR, true, config.config)
                end)
                return
            end

            -- Directory exists, proceed with file listing
            vim.schedule(function()
                utils.log("Directory exists, searching for files...", vim.log.levels.INFO, true, config.config)
                searching = true

                -- Use an optimized find command
                local bash_cmd = [[
                cd %s 2>/dev/null && \
                find . -type f -not -path "*/\\.git/*" -not -path "*/node_modules/*" \
                -not -path "*/build/*" -not -path "*/target/*" -not -path "*/dist/*" \
                -not -path "*/\\.*" -maxdepth 10 | head -n %d
                ]]

                -- Log the command for debugging
                local formatted_cmd = string.format(bash_cmd, vim.fn.shellescape(path), MAX_FILES)
                utils.log("SSH command: " .. formatted_cmd, vim.log.levels.DEBUG, true, config.config)

                local cmd = {"ssh", host, formatted_cmd}

                -- Create job to execute command
                local output = {}
                local stderr_output = {}

                -- Set a timeout for long-running commands
                local timeout_timer = vim.loop.new_timer()
                local has_completed = false

                timeout_timer:start(30000, 0, vim.schedule_wrap(function()
                    if not has_completed then
                        searching = false
                        progress_timer:close()
                        utils.log("SSH command timed out after 30 seconds", vim.log.levels.ERROR, true, config.config)
                        pcall(vim.fn.jobstop, job_id)
                        timeout_timer:close()
                    end
                end))

                local job_id = vim.fn.jobstart(cmd, {
                    on_stdout = function(_, data)
                        if data and #data > 0 then
                            for _, line in ipairs(data) do
                                if line and line ~= "" then
                                    -- Store raw file paths
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
                        has_completed = true
                        searching = false
                        pcall(function() timeout_timer:close() end)
                        pcall(function() progress_timer:close() end)

                        if exit_code ~= 0 then
                            vim.schedule(function()
                                utils.log("Error listing files (exit code " .. exit_code .. "): " ..
                                          table.concat(stderr_output, "\n"),
                                          vim.log.levels.ERROR, true, config.config)
                            end)
                            return
                        end

                        vim.schedule(function()
                            utils.log("SSH command completed, processing results...",
                                      vim.log.levels.INFO, true, config.config)

                            -- Create file entries directly here
                            local files = {}
                            local seen_paths = {}

                            for _, file_path in ipairs(output) do
                                -- Limit total files processed
                                if #files >= MAX_FILES then
                                    break
                                end

                                -- Remove leading ./ if present
                                local rel_path = file_path:gsub("^%./", "")

                                -- Skip if we've already seen this path
                                if seen_paths[rel_path] then
                                    goto continue
                                end

                                -- Mark as seen
                                seen_paths[rel_path] = true

                                -- Get just the filename for search purposes
                                local filename = vim.fn.fnamemodify(rel_path, ":t")

                                -- Format the full path
                                local full_path = path .. rel_path

                                -- Format the URL - ensure we have only one slash after the host
                                local url_path = full_path
                                if url_path:sub(1, 1) ~= "/" then
                                    url_path = "/" .. url_path
                                end

                                -- Construct the proper URL
                                local file_url = remote_info.protocol .. "://" .. host .. "/" .. url_path:gsub("^/", "")

                                table.insert(files, {
                                    name = filename,       -- Just the filename for filtering
                                    rel_path = rel_path,   -- Relative path for display
                                    path = full_path,      -- Full path
                                    url = file_url,        -- Complete URL
                                    is_dir = false,        -- Always false for files
                                    type = "f"             -- Always "f" for files
                                })

                                ::continue::
                            end

                            -- Check if directory is empty
                            if #files == 0 then
                                utils.log("No files found in " .. path, vim.log.levels.INFO, true, config.config)
                                return
                            end

                            local truncated = #output > MAX_FILES
                            utils.log("Found " .. #files .. " files" .. (truncated and " (results limited)" or ""),
                                      vim.log.levels.INFO, true, config.config)

                            -- Show files in Telescope with custom filename-only filtering
                            M.show_files_in_telescope_with_filename_filter(files, url)
                        end)
                    end
                })

                if job_id <= 0 then
                    searching = false
                    progress_timer:close()
                    utils.log("Failed to start SSH job", vim.log.levels.ERROR, true, config.config)
                    pcall(function() timeout_timer:close() end)
                else
                    utils.log("Started SSH job with ID: " .. job_id, vim.log.levels.DEBUG, true, config.config)
                end
            end)
        end
    })

    if check_job_id <= 0 then
        progress_timer:close()
        utils.log("Failed to start directory check job", vim.log.levels.ERROR, true, config.config)
    end
end

-- Function to reset state variables
function M.reset_state()
    selected_files = {}
    files_to_delete = {}
    files_to_create = {}
    file_status = {}
    utils.log("Reset file picker state", vim.log.levels.DEBUG, false, config.config)
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

-- Function to show files in Telescope with filename-only filtering
function M.show_files_in_telescope_with_filename_filter(files, base_url)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    utils.log("Setting up Telescope picker...", vim.log.levels.INFO, true, config.config)

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local sorters = require('telescope.sorters')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Use Telescope's built-in generic sorter but customize it for filename-only matching
    local filename_sorter = sorters.get_generic_fuzzy_sorter()

    -- Create a picker with standard sorting but customized display
    pickers.new({}, {
        prompt_title = "Remote Files: " .. base_url .. " (Tab:cycle status, d:delete, n:new, <C-o>:process, <C-x>:clear)",
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local icon, icon_hl
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                local prefix = ""
                
                if is_selected then
                    prefix = "+ " -- Plus sign for open
                elseif is_to_delete then
                    prefix = "- " -- Minus sign for deletion
                else
                    prefix = "  "
                end

                -- Always a file in this view
                if has_devicons then
                    local ext = entry.name:match("%.([^%.]+)$") or ""
                    local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                    if dev_icon then
                        icon = dev_icon .. " "

                        -- Try to use devicons highlight group if available
                        local filetype = vim.filetype.match({ filename = entry.name }) or ext
                        icon_hl = "DevIcon" .. filetype:upper()

                        -- Create highlight group if it doesn't exist
                        if dev_color and not vim.fn.hlexists(icon_hl) then
                            vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                else
                    icon = "📄 "
                    icon_hl = "Normal"
                end

                -- Display relative path but search by filename only
                return {
                    value = entry,
                    display = function()
                        local display_text = prefix .. icon .. entry.rel_path
                        local highlights = {
                            { { 0, #prefix }, is_selected and "diffAdded" or (is_to_delete and "diffRemoved" or "Comment") },
                            { { #prefix, #prefix + #icon }, icon_hl }
                        }
                        return display_text, highlights
                    end,
                    ordinal = entry.name, -- Use only filename for searching
                    path = entry.path
                }
            end
        }),
        sorter = filename_sorter,
        attach_mappings = function(prompt_bufnr, map)
            -- Toggle selection action
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if selection then
                    local file = selection.value
                    local url = file.url
                    
                    -- Get current status
                    local status = file_status[url] or "none"
                    
                    -- Cycle through statuses: none -> open -> delete -> none
                    if status == "none" then
                        -- Mark for opening
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        -- Mark for deletion
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        -- Clear status
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    
                    -- Update the visual selection in Telescope
                    if status == "none" or status == "open" then
                        -- For "none" -> "open" or "open" -> "delete", select the item
                        actions.toggle_selection(prompt_bufnr)
                    else
                        -- For "delete" -> "none", unselect the item
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end
            
            -- Add a function to mark a file for deletion
            local mark_for_deletion = function()
                local selection = action_state.get_selected_entry()
                if selection then
                    local file = selection.value
                    local url = file.url
                    
                    -- Toggle deletion status
                    if file_status[url] == "delete" then
                        -- Unmark for deletion
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Unmarked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual selection (unselect)
                        if action_state.is_selected(selection) then
                            actions.toggle_selection(prompt_bufnr)
                        end
                    else
                        -- Mark for deletion and unmark for opening
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual selection (ensure it's selected)
                        if not action_state.is_selected(selection) then
                            actions.toggle_selection(prompt_bufnr)
                        end
                    end
                end
            end
            
            -- Add a 'Reset all and refresh' function
            local reset_all_and_refresh = function()
                -- Store current URL
                local current_url = base_url
                
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Clear visual selections
                actions.clear_all(prompt_bufnr)
                
                -- Close current picker and reopen with reset selections
                actions.close(prompt_bufnr)
                M.browse_remote_files(current_url, true)
                
                utils.log("Reset all selections and refreshed view", vim.log.levels.INFO, true, config.config)
            end
            
            -- Add function to create a new file
            local create_new_file = function()
                -- Prompt for filename
                local current_dir = vim.fn.fnamemodify(base_url, ":h")
                if current_dir:sub(-1) ~= "/" then
                    current_dir = current_dir .. "/"
                end
                
                actions.close(prompt_bufnr)
                
                vim.ui.input({prompt = "Enter new filename: "}, function(filename)
                    if not filename or filename == "" then
                        utils.log("File creation cancelled", vim.log.levels.INFO, true, config.config)
                        -- Reopen the browser
                        M.browse_remote_files(base_url, false)
                        return
                    end
                    
                    -- Construct the full file path and URL
                    local remote_info = utils.parse_remote_path(base_url)
                    if not remote_info then
                        utils.log("Invalid remote URL: " .. base_url, vim.log.levels.ERROR, true, config.config)
                        return
                    end
                    
                    local host = remote_info.host
                    local path = remote_info.path
                    
                    -- Ensure path is a directory
                    if path:sub(-1) ~= "/" then
                        path = vim.fn.fnamemodify(path, ":h") .. "/"
                    end
                    
                    local file_path = path .. filename
                    local file_url = remote_info.protocol .. "://" .. host .. "/" .. file_path:gsub("^/", "")
                    
                    -- Add to files to create
                    local new_file = {
                        name = filename,
                        rel_path = filename,
                        path = file_path,
                        url = file_url,
                        is_dir = false,
                        type = "f"
                    }
                    
                    files_to_create[file_url] = new_file
                    file_status[file_url] = "create"
                    utils.log("Added file to create: " .. filename, vim.log.levels.INFO, true, config.config)
                    
                    -- Reopen the browser
                    M.browse_remote_files(base_url, false)
                end)
            end

            -- Modify default select action
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()

                if selection then
                    -- For files, toggle our persistent selection
                    toggle_selection()
                end
            end)

            -- Add mapping to toggle selection
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)
            
            -- Add mapping for deletion marking
            map("i", "d", mark_for_deletion)
            map("n", "d", mark_for_deletion)
            
            -- Add mapping for file creation
            map("i", "n", create_new_file)
            map("n", "n", create_new_file)
            
            -- Add mapping for reset and refresh (R key)
            map("i", "R", reset_all_and_refresh)
            map("n", "R", reset_all_and_refresh)

            -- Add custom key mapping to open all selected files, create new files and delete marked files
            map("i", "<C-o>", function()
                actions.close(prompt_bufnr)
                
                -- Process deletions first
                local delete_count = 0
                for url, file in pairs(files_to_delete) do
                    delete_count = delete_count + 1
                end
                
                if delete_count > 0 then
                    local confirm = vim.fn.confirm("Delete " .. delete_count .. " file(s)?", "&Yes\n&No", 2)
                    
                    if confirm == 1 then
                        -- User confirmed, so perform deletions
                        for url, file in pairs(files_to_delete) do
                            -- Parse the remote URL
                            local remote_info = utils.parse_remote_path(url)
                            if remote_info then
                                local host = remote_info.host
                                local path = remote_info.path
                                
                                -- Ensure path has leading slash
                                if path:sub(1, 1) ~= "/" then
                                    path = "/" .. path
                                end
                                
                                -- Run SSH command to delete the file
                                local cmd = {"ssh", host, "rm -f " .. vim.fn.shellescape(path)}
                                local job_id = vim.fn.jobstart(cmd, {
                                    on_exit = function(_, exit_code)
                                        if exit_code ~= 0 then
                                            utils.log("Failed to delete file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                        else
                                            utils.log("Deleted file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                        end
                                    end
                                })
                                
                                if job_id <= 0 then
                                    utils.log("Failed to start deletion job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                end
                            end
                        end
                    else
                        utils.log("Deletion cancelled", vim.log.levels.INFO, true, config.config)
                    end
                end
                
                -- Process file creations
                local create_count = 0
                for url, file in pairs(files_to_create) do
                    create_count = create_count + 1
                end
                
                if create_count > 0 then
                    utils.log("Creating " .. create_count .. " new file(s)", vim.log.levels.INFO, true, config.config)
                    
                    for url, file in pairs(files_to_create) do
                        -- Create an empty file via SSH touch command
                        local remote_info = utils.parse_remote_path(url)
                        if remote_info then
                            local host = remote_info.host
                            local path = remote_info.path
                            
                            -- Ensure path has leading slash
                            if path:sub(1, 1) ~= "/" then
                                path = "/" .. path
                            end
                            
                            local cmd = {"ssh", host, "touch " .. vim.fn.shellescape(path)}
                            local job_id = vim.fn.jobstart(cmd, {
                                on_exit = function(_, exit_code)
                                    if exit_code ~= 0 then
                                        utils.log("Failed to create file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                    else
                                        utils.log("Created file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                        
                                        -- Open the newly created file
                                        operations.simple_open_remote_file(url)
                                    end
                                end
                            })
                            
                            if job_id <= 0 then
                                utils.log("Failed to start creation job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                            end
                        end
                    end
                end

                -- Now proceed with opening selected files
                local open_count = 0
                for _, _ in pairs(selected_files) do
                    open_count = open_count + 1
                end

                if open_count == 0 then
                    -- If no files are explicitly selected but we have a current selection
                    local current = action_state.get_selected_entry()
                    if current then
                        utils.log("Opening file: " .. current.value.rel_path, vim.log.levels.INFO, true, config.config)
                        operations.simple_open_remote_file(current.value.url)
                    else
                        utils.log("No files selected to open", vim.log.levels.INFO, true, config.config)
                    end
                else
                    -- Open all selected files
                    utils.log("Opening " .. open_count .. " selected files", vim.log.levels.INFO, true, config.config)
                    for url, file in pairs(selected_files) do
                        operations.simple_open_remote_file(url)
                    end
                end
                
                -- Reset tracking tables
                files_to_delete = {}
                files_to_create = {}
            end)

            -- Add mapping to clear all selections and marks
            map("i", "<C-x>", function()
                -- Store URLs we need to unselect visually
                local to_unselect = {}
                for url, _ in pairs(file_status) do
                    if file_status[url] ~= "none" then
                        table.insert(to_unselect, url)
                    end
                end
                
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Update visual selection state by clearing all selections
                actions.clear_all(prompt_bufnr)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)

            return true
        end,
        -- Enable multi-selection mode
        multi_selection = true,
    }):find()
end

-- Function to show files in Telescope with multi-select support and persistent selection
function M.show_files_in_telescope(files, base_url)
    -- Check if Telescope is available
    local has_telescope, telescope = pcall(require, 'telescope')
    if not has_telescope then
        utils.log("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR, true, config.config)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    -- Check if nvim-web-devicons is available for prettier icons
    local has_devicons, devicons = pcall(require, 'nvim-web-devicons')

    -- Create a picker with multi-select enabled
    pickers.new({}, {
        prompt_title = "Remote Files: " .. base_url .. " (Tab:cycle status, d:delete, n:new, <C-o>:process, <C-x>:clear)",
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local icon, icon_hl
                local is_selected = selected_files[entry.url] ~= nil
                local is_to_delete = files_to_delete[entry.url] ~= nil
                local prefix = ""
                
                if is_selected then
                    prefix = "+ " -- Plus sign for open
                elseif is_to_delete then
                    prefix = "- " -- Minus sign for deletion
                else
                    prefix = "  "
                end

                if entry.name == ".." then
                    -- Parent directory
                    icon = "⬆️ "
                    icon_hl = "Special"
                elseif entry.is_dir then
                    -- Directory
                    icon = "📁 "
                    icon_hl = "Directory"
                else
                    -- File - try to use devicons if available
                    if has_devicons then
                        local ext = entry.name:match("%.([^%.]+)$") or ""
                        local dev_icon, dev_color = devicons.get_icon_color(entry.name, ext, { default = true })

                        if dev_icon then
                            icon = dev_icon .. " "

                            -- Try to use devicons highlight group if available
                            local filetype = vim.filetype.match({ filename = entry.name }) or ext
                            icon_hl = "DevIcon" .. filetype:upper()

                            -- Create highlight group if it doesn't exist
                            if dev_color and not vim.fn.hlexists(icon_hl) then
                                vim.api.nvim_set_hl(0, icon_hl, { fg = dev_color, default = true })
                            end
                        else
                            icon = "📄 "
                            icon_hl = "Normal"
                        end
                    else
                        icon = "📄 "
                        icon_hl = "Normal"
                    end
                end

                -- Use Telescope's highlighting capabilities with selection indicator
                return {
                    value = entry,
                    display = function()
                        local display_text = prefix .. icon .. entry.name
                        local highlights = {
                            { { 0, #prefix }, is_selected and "diffAdded" or (is_to_delete and "diffRemoved" or "Comment") },
                            { { #prefix, #prefix + #icon }, icon_hl }
                        }
                        return display_text, highlights
                    end,
                    ordinal = entry.name,
                    path = entry.path
                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- Toggle selection action
            local toggle_selection = function()
                local selection = action_state.get_selected_entry()
                if selection and not selection.value.is_dir then
                    local file = selection.value
                    local url = file.url
                    
                    -- Get current status
                    local status = file_status[url] or "none"
                    
                    -- Cycle through statuses: none -> open -> delete -> none
                    if status == "none" then
                        -- Mark for opening
                        selected_files[url] = file
                        files_to_delete[url] = nil
                        file_status[url] = "open"
                        utils.log("Added file to selection: " .. file.name, vim.log.levels.INFO, true, config.config)
                    elseif status == "open" then
                        -- Mark for deletion
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                    else
                        -- Clear status
                        selected_files[url] = nil
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Cleared selection for file: " .. file.name, vim.log.levels.INFO, true, config.config)
                    end
                    
                    -- Update the visual selection in Telescope
                    if status == "none" || status == "open" then
                        -- For "none" -> "open" or "open" -> "delete", select the item
                        actions.toggle_selection(prompt_bufnr)
                    else
                        -- For "delete" -> "none", unselect the item
                        actions.toggle_selection(prompt_bufnr)
                    end
                end
            end

            -- Modify default select action
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()

                if selection and selection.value.is_dir then
                    -- If it's a directory, browse into it while preserving selections
                    actions.close(prompt_bufnr)
                    M.browse_remote_directory(selection.value.url, false) -- false = don't reset selections
                else
                    -- For files, toggle our persistent selection
                    toggle_selection()
                end
            end)
            
            -- Add a function to mark a file for deletion
            local mark_for_deletion = function()
                local selection = action_state.get_selected_entry()
                if selection and not selection.value.is_dir then
                    local file = selection.value
                    local url = file.url
                    
                    -- Toggle deletion status
                    if file_status[url] == "delete" then
                        -- Unmark for deletion
                        files_to_delete[url] = nil
                        file_status[url] = "none"
                        utils.log("Unmarked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual selection (unselect)
                        if action_state.is_selected(selection) then
                            actions.toggle_selection(prompt_bufnr)
                        end
                    else
                        -- Mark for deletion and unmark for opening
                        selected_files[url] = nil
                        files_to_delete[url] = file
                        file_status[url] = "delete"
                        utils.log("Marked file for deletion: " .. file.name, vim.log.levels.INFO, true, config.config)
                        
                        -- Update visual selection (ensure it's selected)
                        if not action_state.is_selected(selection) then
                            actions.toggle_selection(prompt_bufnr)
                        end
                    end
                elseif selection and selection.value.is_dir then
                    utils.log("Cannot mark directories for deletion", vim.log.levels.WARN, true, config.config)
                end
            end
            
            -- Add a 'Reset all and refresh' function
            local reset_all_and_refresh = function()
                -- Store current URL
                local current_url = base_url
                
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Clear visual selections
                actions.clear_all(prompt_bufnr)
                
                -- Close current picker and reopen with reset selections
                actions.close(prompt_bufnr)
                M.browse_remote_directory(current_url, true)
                
                utils.log("Reset all selections and refreshed view", vim.log.levels.INFO, true, config.config)
            end
            
            -- Add function to create a new file
            local create_new_file = function()
                -- Prompt for filename
                local current_dir = vim.fn.fnamemodify(base_url, ":h")
                if current_dir:sub(-1) ~= "/" then
                    current_dir = current_dir .. "/"
                end
                
                actions.close(prompt_bufnr)
                
                vim.ui.input({prompt = "Enter new filename: "}, function(filename)
                    if not filename or filename == "" then
                        utils.log("File creation cancelled", vim.log.levels.INFO, true, config.config)
                        -- Reopen the browser
                        M.browse_remote_directory(base_url, false)
                        return
                    end
                    
                    -- Construct the full file path and URL
                    local remote_info = utils.parse_remote_path(base_url)
                    if not remote_info then
                        utils.log("Invalid remote URL: " .. base_url, vim.log.levels.ERROR, true, config.config)
                        return
                    end
                    
                    local host = remote_info.host
                    local path = remote_info.path
                    
                    -- Ensure path is a directory
                    if path:sub(-1) ~= "/" then
                        path = vim.fn.fnamemodify(path, ":h") .. "/"
                    end
                    
                    local file_path = path .. filename
                    local file_url = remote_info.protocol .. "://" .. host .. "/" .. file_path:gsub("^/", "")
                    
                    -- Add to files to create
                    local new_file = {
                        name = filename,
                        path = file_path,
                        url = file_url,
                        is_dir = false,
                        type = "f"
                    }
                    
                    files_to_create[file_url] = new_file
                    file_status[file_url] = "create"
                    utils.log("Added file to create: " .. filename, vim.log.levels.INFO, true, config.config)
                    
                    -- Reopen the browser
                    M.browse_remote_directory(base_url, false)
                end)
            end
            
            -- Add mapping for deletion marking
            map("i", "d", mark_for_deletion)
            map("n", "d", mark_for_deletion)
            
            -- Add mapping for file creation
            map("i", "n", create_new_file)
            map("n", "n", create_new_file)
            
            -- Add mapping for reset and refresh (R key)
            map("i", "R", reset_all_and_refresh)
            map("n", "R", reset_all_and_refresh)

            -- Add mapping to toggle selection
            map("i", "<Tab>", toggle_selection)
            map("n", "<Tab>", toggle_selection)

            -- Add custom key mapping to open all selected files, create new files, and delete marked files
            map("i", "<C-o>", function()
                actions.close(prompt_bufnr)
                
                -- Process deletions first
                local delete_count = 0
                for url, file in pairs(files_to_delete) do
                    delete_count = delete_count + 1
                end
                
                if delete_count > 0 then
                    local confirm = vim.fn.confirm("Delete " .. delete_count .. " file(s)?", "&Yes\n&No", 2)
                    
                    if confirm == 1 then
                        -- User confirmed, so perform deletions
                        for url, file in pairs(files_to_delete) do
                            -- Parse the remote URL
                            local remote_info = utils.parse_remote_path(url)
                            if remote_info then
                                local host = remote_info.host
                                local path = remote_info.path
                                
                                -- Ensure path has leading slash
                                if path:sub(1, 1) ~= "/" then
                                    path = "/" .. path
                                end
                                
                                -- Run SSH command to delete the file
                                local cmd = {"ssh", host, "rm -f " .. vim.fn.shellescape(path)}
                                local job_id = vim.fn.jobstart(cmd, {
                                    on_exit = function(_, exit_code)
                                        if exit_code ~= 0 then
                                            utils.log("Failed to delete file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                        else
                                            utils.log("Deleted file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                        end
                                    end
                                })
                                
                                if job_id <= 0 then
                                    utils.log("Failed to start deletion job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                end
                            end
                        end
                    else
                        utils.log("Deletion cancelled", vim.log.levels.INFO, true, config.config)
                    end
                end
                
                -- Process file creations
                local create_count = 0
                for url, file in pairs(files_to_create) do
                    create_count = create_count + 1
                end
                
                if create_count > 0 then
                    utils.log("Creating " .. create_count .. " new file(s)", vim.log.levels.INFO, true, config.config)
                    
                    for url, file in pairs(files_to_create) do
                        -- Create an empty file via SSH touch command
                        local remote_info = utils.parse_remote_path(url)
                        if remote_info then
                            local host = remote_info.host
                            local path = remote_info.path
                            
                            -- Ensure path has leading slash
                            if path:sub(1, 1) ~= "/" then
                                path = "/" .. path
                            end
                            
                            local cmd = {"ssh", host, "touch " .. vim.fn.shellescape(path)}
                            local job_id = vim.fn.jobstart(cmd, {
                                on_exit = function(_, exit_code)
                                    if exit_code ~= 0 then
                                        utils.log("Failed to create file: " .. file.name, vim.log.levels.ERROR, true, config.config)
                                    else
                                        utils.log("Created file: " .. file.name, vim.log.levels.INFO, true, config.config)
                                        
                                        -- Open the newly created file
                                        operations.simple_open_remote_file(url)
                                    end
                                end
                            })
                            
                            if job_id <= 0 then
                                utils.log("Failed to start creation job for: " .. file.name, vim.log.levels.ERROR, true, config.config)
                            end
                        end
                    end
                end
                
                -- Now proceed with opening selected files
                local open_count = 0
                for _, _ in pairs(selected_files) do
                    open_count = open_count + 1
                end

                if open_count == 0 then
                    -- If no files are explicitly selected but we have a current selection
                    -- that's a file, use that one
                    local current = action_state.get_selected_entry()
                    if current and not current.value.is_dir then
                        utils.log("Opening file: " .. current.value.name, vim.log.levels.INFO, true, config.config)
                        operations.simple_open_remote_file(current.value.url)
                    else
                        utils.log("No files selected to open", vim.log.levels.INFO, true, config.config)
                    end
                else
                    -- Open all selected files
                    utils.log("Opening " .. open_count .. " selected files", vim.log.levels.INFO, true, config.config)
                    for url, file in pairs(selected_files) do
                        operations.simple_open_remote_file(url)
                    end
                end
                
                -- Reset tracking tables
                files_to_delete = {}
                files_to_create = {}
            end)

            -- Add mapping to clear all selections and marks
            map("i", "<C-x>", function()
                -- Store URLs we need to unselect visually
                local to_unselect = {}
                for url, _ in pairs(file_status) do
                    if file_status[url] ~= "none" then
                        table.insert(to_unselect, url)
                    end
                end
                
                -- Reset all tracking tables
                selected_files = {}
                files_to_delete = {}
                files_to_create = {}
                file_status = {}
                
                -- Update visual selection state by clearing all selections
                actions.clear_all(prompt_bufnr)
                
                utils.log("Cleared all selections and marks", vim.log.levels.INFO, true, config.config)
            end)

            return true
        end,
        -- Enable multi-selection mode
        multi_selection = true,
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

    -- Construct URL with proper format to avoid hostname concatenation issues
    -- Make sure we properly format with double-slash after host for absolute paths
    return protocol .. "://" .. host .. "/" .. parent_path:gsub("^/", "")
end

return M