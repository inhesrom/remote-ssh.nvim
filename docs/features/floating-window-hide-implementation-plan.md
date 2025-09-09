# Hide vs Close Floating Windows Implementation

## Current State Analysis

Looking at the codebase, I found three main places where floating windows are used:

1. **`remote-tui/commands.lua`** - Creates floating terminal windows with `termopen()` (lines 70-87)
2. **`session_picker.lua`** - Creates a session picker with proper window management (lines 879-893) 
3. **`tree_browser.lua`** - Uses buffer-based approach with window closing (lines 1299, 1354)

Currently, all implementations use `vim.api.nvim_win_close(win_id, false)` to close windows while preserving buffers.

## Available Options for Hiding Floating Buffers

For hiding a floating buffer instead of closing it, you have these options:

1. **`vim.api.nvim_win_hide(win_id)`** - Hide the window (buffer stays loaded)
2. **`vim.api.nvim_win_close(win_id, false)`** - Close window but keep buffer
3. **Set window height to 0** - `vim.api.nvim_win_set_height(win_id, 0)`
4. **Move window off-screen** - `vim.api.nvim_win_set_config(win_id, {row = -1000})`
5. **Store win_id and recreate later** - Save window config, close window, recreate when needed

Most common: Use `nvim_win_hide()` or `nvim_win_close(win_id, false)` then track the buffer number to reopen it later.

## Implementation Strategy

### Phase 1: Add Window State Management
1. Create a global window state tracker in each module
2. Store window configurations and buffer IDs for later restoration
3. Add helper functions for hide/show operations

### Phase 2: Implement Hide Functionality
1. Replace `nvim_win_close()` calls with `nvim_win_hide()` where appropriate
2. Add logic to store window configuration before hiding
3. Implement restoration function to recreate window with saved config

### Phase 3: Add Toggle/Show Functions
1. Create public APIs to show hidden windows
2. Add keybindings for toggle functionality
3. Handle edge cases (buffer still valid, window recreation)

## Key Changes Needed

- **`remote-tui/commands.lua`**: Modify the termopen on_exit handler (line 77)
- **`session_picker.lua`**: Update close_picker() function (line 881)  
- **`tree_browser.lua`**: Update close functions (lines 1299, 1354)

## Implementation Details

### For RemoteTui Commands
```lua
-- Current implementation (commented out):
-- vim.api.nvim_win_close(win, true)

-- Proposed implementation:
vim.api.nvim_win_hide(win)
-- Store window config for restoration
M.hidden_windows[win] = {
    buf = buf,
    config = vim.api.nvim_win_get_config(win)
}
```

### For Session Picker
```lua
-- Current implementation:
function M.close_picker()
    if SessionPicker.win_id and vim.api.nvim_win_is_valid(SessionPicker.win_id) then
        vim.api.nvim_win_close(SessionPicker.win_id, false)
    end
    -- ...
end

-- Proposed implementation:
function M.hide_picker()
    if SessionPicker.win_id and vim.api.nvim_win_is_valid(SessionPicker.win_id) then
        -- Store config before hiding
        SessionPicker.saved_config = vim.api.nvim_win_get_config(SessionPicker.win_id)
        vim.api.nvim_win_hide(SessionPicker.win_id)
    end
end

function M.show_picker()
    if SessionPicker.bufnr and vim.api.nvim_buf_is_valid(SessionPicker.bufnr) then
        -- Recreate window with saved config
        SessionPicker.win_id = vim.api.nvim_open_win(SessionPicker.bufnr, true, SessionPicker.saved_config)
    else
        -- Create new picker if buffer is invalid
        M.create_new_picker()
    end
end
```

### For Tree Browser
```lua
-- Current implementation:
vim.api.nvim_win_close(TreeBrowser.win_id, false)

-- Proposed implementation:
function M.hide_tree()
    if TreeBrowser.win_id and vim.api.nvim_win_is_valid(TreeBrowser.win_id) then
        TreeBrowser.saved_config = vim.api.nvim_win_get_config(TreeBrowser.win_id)
        vim.api.nvim_win_hide(TreeBrowser.win_id)
    end
end
```

## Benefits

- **Faster reopening** of complex floating windows
- **Preserve terminal state** in RemoteTui
- **Better user experience** with instant window restoration
- **Memory efficiency** - buffers stay loaded, avoiding reload costs
- **State preservation** - cursor position, folding, etc. maintained

## Considerations

- **Memory usage**: Hidden windows still consume memory
- **Window ID management**: Need to track valid window IDs
- **Buffer lifecycle**: Ensure buffers are properly cleaned up when no longer needed
- **User expectations**: Users might expect windows to be fully closed