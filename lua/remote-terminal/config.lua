-- Configuration for remote-terminal module
local M = {}

-- Default configuration
local defaults = {
    window = {
        height = 0.3, -- 30% of screen height
    },
    picker = {
        width = 25, -- Fixed width in columns
    },
    keymaps = {
        -- Terminal mode keybinds
        new_terminal = "<C-\\>n",
        close_terminal = "<C-\\>x",
        toggle_split = "<C-\\><C-\\>",
        next_terminal = "<C-\\>]",
        prev_terminal = "<C-\\>[",
    },
    picker_keymaps = {
        -- Picker sidebar keybinds (normal mode)
        select = "<CR>",
        rename = "r",
        delete = "d",
        new = "n",
        close = "q",
        navigate_down = "j",
        navigate_up = "k",
    },
    highlights = {
        TerminalPickerSelected = { bg = "#3e4451", bold = true },
        TerminalPickerNormal = { fg = "#abb2bf" },
        TerminalPickerHeader = { fg = "#61afef", bold = true },
        TerminalPickerId = { fg = "#d19a66" },
    },
}

-- Current configuration (merged with user options)
M.config = vim.deepcopy(defaults)

--- Setup configuration with user options
---@param opts table|nil User configuration options
function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_deep_extend("force", defaults, opts)

    -- Setup highlight groups
    M.setup_highlights()
end

--- Setup highlight groups for the picker
function M.setup_highlights()
    for name, hl in pairs(M.config.highlights) do
        vim.api.nvim_set_hl(0, name, hl)
    end
end

--- Get a configuration value by path
---@param ... string Path segments
---@return any
function M.get(...)
    local value = M.config
    for _, key in ipairs({ ... }) do
        if type(value) ~= "table" then
            return nil
        end
        value = value[key]
    end
    return value
end

return M
