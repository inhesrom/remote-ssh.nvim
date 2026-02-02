-- Configuration module for remote-session
local M = {}

-- Default configuration
local defaults = {
    -- Auto-minimize active session when opening a new one
    auto_minimize = true,

    -- Confirm before closing sessions with unsaved buffers
    confirm_close = true,

    -- Confirm before closing sessions with running terminal processes
    confirm_terminal_close = true,

    -- Default window layout ratios (proportional 0.0-1.0)
    default_layout = {
        tree_browser_width_ratio = 0.2, -- 20% of editor width
        terminal_height_ratio = 0.3, -- 30% of editor height
    },

    -- Statusline component configuration
    statusline = {
        -- Show minimized session count
        show_minimized_count = true,
        -- Format string for active session display
        -- Available: {name}, {host}, {path}, {minimized_count}
        format = "SSH: {name}",
        -- Format when showing minimized count
        format_with_minimized = "SSH: {name} [+{minimized_count} minimized]",
        -- Text shown when no active session
        no_session_text = "",
    },

    -- Picker UI configuration
    picker = {
        -- Width of the picker window (percentage or absolute)
        width = 0.6,
        -- Maximum height of picker window
        max_height = 20,
        -- Show help hints in picker header
        show_hints = true,
    },

    -- Persistence configuration
    persistence = {
        -- Enable persistence across Neovim restarts
        enabled = true,
        -- Maximum number of persisted sessions to keep
        max_persisted = 50,
        -- Save expanded directories in tree browser
        save_expanded_dirs = true,
    },

    -- Terminal configuration
    terminal = {
        -- Auto-create terminal when opening a new session
        auto_create = true,
        -- Start directory for new terminals (relative to session path)
        start_in_session_path = true,
    },
}

-- Current configuration (merged with defaults)
M.config = vim.deepcopy(defaults)

--- Setup configuration with user options
---@param opts table|nil User configuration options
function M.setup(opts)
    if opts then
        M.config = vim.tbl_deep_extend("force", defaults, opts)
    else
        M.config = vim.deepcopy(defaults)
    end
end

--- Get a configuration value by path
--- Example: M.get("statusline", "format") returns config.statusline.format
---@vararg string Configuration path segments
---@return any value
function M.get(...)
    local path = { ... }
    local value = M.config

    for _, key in ipairs(path) do
        if type(value) ~= "table" then
            return nil
        end
        value = value[key]
    end

    return value
end

--- Set a configuration value by path
---@vararg any Path segments followed by value
function M.set(...)
    local args = { ... }
    if #args < 2 then
        return
    end

    local value = args[#args]
    local path = { unpack(args, 1, #args - 1) }

    local current = M.config
    for i = 1, #path - 1 do
        local key = path[i]
        if type(current[key]) ~= "table" then
            current[key] = {}
        end
        current = current[key]
    end

    current[path[#path]] = value
end

--- Reset configuration to defaults
function M.reset()
    M.config = vim.deepcopy(defaults)
end

--- Get all defaults
---@return table defaults
function M.get_defaults()
    return vim.deepcopy(defaults)
end

return M
