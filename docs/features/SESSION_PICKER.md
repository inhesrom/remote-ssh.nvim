# Remote SSH Session Picker Feature

The Remote SSH Session Picker provides a floating window interface for managing and accessing your remote SSH session history, including the ability to pin frequently used sessions.

## Features

- **Session History**: Automatically tracks all remote files and tree browser sessions
- **Pinning**: Pin frequently used sessions for quick access
- **Filtering**: Filter sessions by name or host
- **Mixed Content**: Supports both individual file opens and RemoteTreeBrowser sessions
- **Floating Window**: Clean, intuitive interface with keyboard navigation

## Usage

### Opening the Session Picker

```vim
:RemoteSession
```

This opens a floating window showing your remote session history.

### Keyboard Controls

- `j` / `k` or `↑` / `↓` - Navigate through sessions
- `<Enter>` or `<Space>` - Open selected session
- `p` - Pin/unpin the selected session
- `/` - Enter filter mode
- `<Esc>` - Exit filter mode or close picker
- `<C-c>` - Clear current filter
- `q` or `<C-q>` - Close the picker

### Filter Mode

Press `/` to enter filter mode, then type to filter sessions by:
- File/directory name
- Host name

### Session Types

The picker displays two types of sessions:

1. **📄 File Sessions**: Individual remote files opened with `RemoteOpen` or similar commands
2. **📁 Tree Browser Sessions**: Remote directory browsing sessions opened with `RemoteTreeBrowser`

### Pinned Sessions

Pinned sessions appear at the top of the list with a 📌 icon and are preserved even when the history limit is reached.

## Commands

### Core Commands

- `:RemoteSession` - Open the session picker
- `:RemoteSessionStats` - Show session statistics
- `:RemoteSessionClearHistory` - Clear session history
- `:RemoteSessionClearPinned` - Clear pinned sessions

### Session Tracking

Sessions are automatically tracked when you:
- Open remote files using `RemoteOpen`, `Scp`, `Rsync`, or any remote file operations
- Open remote directories using `RemoteTreeBrowser`

## Configuration

The session picker uses the following default settings:
- Maximum history entries: 100
- Automatic tracking of all remote file operations
- Floating window with rounded borders

## Display Format

Each session entry shows:
```
[PIN] [TYPE] [TIME] [NAME] @[HOST] [(pinned)]
```

Where:
- `[PIN]`: 📌 for pinned items, empty for regular history
- `[TYPE]`: 📄 for files, 📁 for tree browser sessions
- `[TIME]`: Date and time in MM/DD HH:MM format
- `[NAME]`: File name or directory path
- `[HOST]`: Remote host name
- `[(pinned)]`: Additional indicator for pinned items

## Examples

### Opening a Session Picker
```vim
:RemoteSession
```

### Typical Session List
```
╭─ Remote SSH Session Picker ─────────────────────────╮
│ Select a session to open or pin/unpin entries      │
│ <Enter>:Open <p>:Pin/Unpin </>:Filter <q>:Quit     │
╰─────────────────────────────────────────────────────╯

Filter: 

▶ 📌 📄 12/04 14:30 config.lua @myserver (pinned)
  📁 12/04 14:25 /home/user/project @myserver
  📄 12/04 14:20 main.py @devbox
  📄 12/04 14:15 README.md @myserver
  📁 12/04 14:10 /var/log @logserver
```

### Filtering Sessions
Press `/` and type "config" to show only sessions containing "config":
```
Filter: config█

▶ 📌 📄 12/04 14:30 config.lua @myserver (pinned)
  📄 12/03 10:15 nginx.conf @webserver
```

## Integration

The session picker integrates seamlessly with existing remote-ssh.nvim functionality:

- Automatically tracks file opens through `operations.simple_open_remote_file()`
- Automatically tracks tree browser sessions through `tree_browser.open_tree()`
- Works with all existing remote commands (`RemoteOpen`, `RemoteTreeBrowser`, etc.)
- Preserves all remote file functionality (LSP, syntax highlighting, etc.)

## Technical Details

- Session data is stored in memory and persists for the current Neovim session
- Each session entry includes metadata like timestamps, display names, and host information
- Pinned sessions are stored separately from history to prevent accidental removal
- The picker uses a floating window with Neovim's native window API
- All remote operations continue to work normally with automatic session tracking

## Troubleshooting

### Sessions Not Appearing
- Ensure you're opening files/directories with remote protocols (`scp://`, `rsync://`)
- Check that the session picker module is properly loaded
- Verify commands like `RemoteOpen` and `RemoteTreeBrowser` are working

### Keyboard Navigation Issues
- Make sure you're in normal mode within the picker
- The picker creates its own buffer with specific keymaps
- If keys don't work, try closing and reopening the picker

### Performance
- Large session histories are automatically trimmed to the configured limit
- Filtering is performed in real-time and should be responsive
- The floating window is lightweight and shouldn't impact Neovim performance