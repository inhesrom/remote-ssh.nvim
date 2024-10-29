-- lua/remote_ssh/init.lua
local Path = require('plenary.path')
local ssh_core = require('remote_ssh.core')

local M = {}

-- Plugin state
M.state = {
    active_connection = nil,
    current_dir = nil,
    explorer_buf = nil,
    explorer_win = nil
}

-- Explorer buffer handling
local function create_explorer_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    vim.api.nvim_buf_set_name(buf, 'Remote SSH Explorer')
    return buf
end

local function create_explorer_window(buf)
    -- Calculate dimensions (30% of window width)
    local width = math.floor(vim.o.columns * 0.3)
    local height = vim.o.lines - 4

    -- Create the window
    local opts = {
        relative = 'editor',
        width = width,
        height = height,
        col = 0,
        row = 0,
        anchor = 'NW',
        style = 'minimal',
        border = 'single'
    }

    local win = vim.api.nvim_open_win(buf, true, opts)

    -- Set window options
    vim.api.nvim_win_set_option(win, 'wrap', false)
    vim.api.nvim_win_set_option(win, 'cursorline', true)

    return win
end

-- File explorer functionality
local function update_explorer_content(files)
    if not M.state.explorer_buf then return end

    local lines = {}
    local highlights = {}

    -- Add current directory
    table.insert(lines, '# ' .. M.state.current_dir)
    table.insert(lines, '')

    -- Add parent directory entry if not at root
    if M.state.current_dir ~= '/' then
        table.insert(lines, '../')
        table.insert(highlights, {'Directory', #lines - 1, 0, -1})
    end

    -- Sort files: directories first, then regular files
    local dirs = {}
    local regular_files = {}

    for _, file in ipairs(files) do
        if file.type == 'directory' then
            table.insert(dirs, file)
        else
            table.insert(regular_files, file)
        end
    end

    -- Add directories
    for _, dir in ipairs(dirs) do
        table.insert(lines, dir.name .. '/')
        table.insert(highlights, {'Directory', #lines, 0, -1})
    end

    -- Add files
    for _, file in ipairs(regular_files) do
        table.insert(lines, file.name)
    end

    -- Update buffer content
    vim.api.nvim_buf_set_option(M.state.explorer_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(M.state.explorer_buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(M.state.explorer_buf, 'modifiable', false)

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(M.state.explorer_buf, -1, 0, -1)
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(M.state.explorer_buf, 0, hl[1], hl[2], hl[3], hl[4])
    end
end

local function refresh_explorer()
    if not M.state.active_connection or not M.state.current_dir then
        return
    end

    M.state.active_connection:list_directory(M.state.current_dir, function(files, err)
        if err then
            vim.notify('Failed to list directory: ' .. err, vim.log.levels.ERROR)
            return
        end

        vim.schedule(function()
            update_explorer_content(files)
        end)
    end)
end

local function handle_explorer_selection()
    local line = vim.api.nvim_get_current_line()
    if line:match('^#') or line == '' then return end

    local name = line:gsub('/$', '')
    if name == '..' then
        -- Handle parent directory
        M.state.current_dir = vim.fn.fnamemodify(M.state.current_dir, ':h')
        if M.state.current_dir == '' then M.state.current_dir = '/' end
        refresh_explorer()
    else
        local path = Path:new(M.state.current_dir, name):absolute()

        if line:match('/$') then
            -- Handle directory
            M.state.current_dir = path
            refresh_explorer()
        else
            -- Handle file
            M.state.active_connection:create_remote_buffer(path)
            -- Focus the newly created buffer
            vim.cmd('wincmd l')
        end
    end
end

local function setup_explorer_mappings()
    local buf = M.state.explorer_buf

    -- Basic navigation
    vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', '', {
        callback = handle_explorer_selection,
        noremap = true,
        silent = true
    })

    -- Refresh
    vim.api.nvim_buf_set_keymap(buf, 'n', 'R', '', {
        callback = refresh_explorer,
        noremap = true,
        silent = true
    })

    -- Close
    vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
        callback = function()
            vim.api.nvim_win_close(M.state.explorer_win, true)
            M.state.explorer_win = nil
        end,
        noremap = true,
        silent = true
    })
end

-- Command implementation
function M.start_remote_session(host, initial_path)
    -- Clean up any existing session
    if M.state.active_connection then
        M.state.active_connection:cleanup()
    end

    -- Create new connection
    M.state.active_connection = ssh_core.new(host)

    -- Test connection
    if M.state.active_connection:test_connection() ~= 0 then
        vim.notify('Failed to connect to ' .. host, vim.log.levels.ERROR)
        M.state.active_connection = nil
        return
    end

    -- Set up explorer
    M.state.current_dir = initial_path or '/'
    M.state.explorer_buf = create_explorer_buffer()
    M.state.explorer_win = create_explorer_window(M.state.explorer_buf)

    -- Set up mappings
    setup_explorer_mappings()

    -- Initial content load
    refresh_explorer()
end

-- Plugin setup
function M.setup()
    -- Register the command
    vim.api.nvim_create_user_command('RemoteSSHStart', function(opts)
        local args = vim.split(opts.args, ' ')
        if #args < 1 then
            vim.notify('Usage: RemoteSSHStart <host> [initial_path]', vim.log.levels.ERROR)
            return
        end

        local host = args[1]
        local path = args[2] or '/'

        M.start_remote_session(host, path)
    end, {
        nargs = '+',
        complete = function(ArgLead, CmdLine, CursorPos)
            -- TODO: Implement completion from SSH config
            return {'example.com', 'localhost'}
        end,
    })
end

return M
