local M = {}

-- Default configuration
M.defaults = {
    window = {
        type = "float", -- "float" or "split"
        width = 0.9, -- percentage of screen width (for float)
        height = 0.9, -- percentage of screen height (for float)
        border = "rounded", -- border style for floating windows
    },
    picker = {
        width = 0.6, -- percentage of screen width
        height = 0.6, -- percentage of screen height
    },
    keymaps = {
        hide_session = "<C-h>", -- Keymap to hide TUI session (terminal mode)
    },
    -- Color scheme for the TUI session picker
    highlights = {
        -- Header and UI elements
        TuiPickerHeader = { fg = "#61afef", bold = true }, -- Blue header
        TuiPickerHelp = { fg = "#98c379" }, -- Green help text
        TuiPickerWarning = { fg = "#e06c75", bold = true }, -- Red warning
        TuiPickerBorder = { fg = "#5c6370" }, -- Gray border

        -- Session entries
        TuiPickerSelected = { bg = "#3e4451", fg = "#abb2bf" }, -- Highlighted selection
        TuiPickerTimeStamp = { fg = "#d19a66" }, -- Orange timestamp
        TuiPickerAppName = { fg = "#e5c07b", bold = true }, -- Yellow app name
        TuiPickerHost = { fg = "#56b6c2" }, -- Cyan host
        TuiPickerSelector = { fg = "#c678dd", bold = true }, -- Purple selector arrow
        TuiPickerDirectory = { fg = "#98c379" }, -- Green directory path

        -- Special states
        TuiPickerEmpty = { fg = "#5c6370", italic = true }, -- Gray empty state
    },
}

-- Current configuration (merged with user options)
M.config = {}

-- Initialize configuration with user options
function M.setup(user_config)
    M.config = vim.tbl_deep_extend("force", M.defaults, user_config or {})
end

-- Get current configuration
function M.get()
    return M.config
end

-- Get specific configuration section
function M.get_window_config()
    return M.config.window
end

function M.get_picker_config()
    return M.config.picker
end

function M.get_highlights()
    return M.config.highlights
end

function M.get_keymaps()
    return M.config.keymaps
end

-- Initialize with defaults if not already set up
if not next(M.config) then
    M.setup()
end

return M
