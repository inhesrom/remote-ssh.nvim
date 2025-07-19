# Remote File Watching Implementation Approaches

## Problem Statement

The remote-ssh.nvim plugin currently supports one-way synchronization from local buffers to remote files. However, it lacks the ability to detect when remote files are modified by external processes, other users, or tools running on the remote server. This creates several issues:

1. **Stale local copies**: Local buffers may contain outdated content
2. **Overwrite conflicts**: Local saves may overwrite remote changes without warning
3. **No change notifications**: Users are unaware when remote files are modified
4. **Manual refresh requirement**: Users must manually refresh buffers to see remote changes

## Current Architecture Analysis

### Existing Buffer Management
- **Buffer lifecycle**: Comprehensive tracking via `async-remote-write/buffer.lua`
- **Async operations**: Non-blocking saves using `vim.fn.jobstart()`
- **LSP integration**: Proper coordination with language servers
- **Protocol support**: SCP and rsync protocols for file transfer

### Current Limitations
- **No remote monitoring**: Zero capability to detect remote file changes
- **One-way sync**: Changes only flow from local to remote
- **No conflict detection**: Cannot identify when local and remote versions diverge
- **No auto-refresh**: Manual intervention required for updates

## Suggested Implementation Approaches

### 1. Polling-Based File Monitoring (Recommended)

**Overview**: Periodically check remote file metadata to detect changes.

**Implementation Strategy**:
```lua
-- Pseudo-code structure
local function check_remote_file_changes(buffer_info)
    local remote_stat = ssh_execute(host, "stat -c '%Y %s' " .. file_path)
    local remote_mtime, remote_size = parse_stat_output(remote_stat)
    
    if remote_mtime > buffer_info.last_sync_time then
        handle_remote_change(buffer_info, remote_mtime, remote_size)
    end
end
```

**Per-Buffer Implementation**:
- **Timer-based**: Use `vim.defer_fn()` to schedule periodic checks
- **Adaptive intervals**: More frequent checks for recently modified files
- **Smart scheduling**: Only monitor buffers that are currently open
- **Batch operations**: Check multiple files in single SSH command

**Advantages**:
- Simple to implement and understand
- Works with any remote filesystem
- Low resource overhead when properly optimized
- Compatible with existing SSH infrastructure

**Disadvantages**:
- Inherent delay in change detection (polling interval)
- Additional SSH traffic
- May miss very rapid file changes

**Recommended Configuration**:
```lua
config = {
    file_watching = {
        enabled = true,
        poll_interval = 5000,        -- 5 seconds default
        adaptive_polling = true,     -- Increase frequency for active files
        max_poll_interval = 30000,   -- 30 seconds max
        min_poll_interval = 1000,    -- 1 second min
        batch_check = true           -- Check multiple files per SSH call
    }
}
```

### 2. SSH-Based Real-Time Monitoring

**Overview**: Leverage remote tools like `inotify` for real-time file change notifications.

**Implementation Strategy**:
```bash
# Remote monitoring script
#!/bin/bash
# monitor_files.sh on remote server
inotifywait -m -e modify,move,delete --format '%w%f:%e:%T' -t '%s' "$@" | while read event; do
    echo "FILE_EVENT:$event"
done
```

**Per-Buffer Implementation**:
- **Persistent SSH connection**: Maintain long-running SSH session per host
- **Event streaming**: Parse `inotify` output for file change events
- **Process management**: Handle SSH connection failures and reconnections
- **Event filtering**: Only process events for monitored files

**Advantages**:
- Near real-time change detection
- Efficient - only notified when changes occur
- Can detect various types of file operations
- Works well for actively developed projects

**Disadvantages**:
- Requires `inotify-tools` on remote server
- More complex error handling and reconnection logic
- Persistent connections may be terminated by network issues
- Platform-specific (Linux/Unix only)

**Implementation Considerations**:
```lua
-- Connection management
local function start_file_monitor(host, file_paths)
    local cmd = string.format("ssh %s 'inotifywait -m -e modify %s'", 
                             host, table.concat(file_paths, " "))
    
    return vim.fn.jobstart(cmd, {
        on_stdout = handle_file_events,
        on_stderr = handle_monitor_errors,
        on_exit = handle_monitor_exit
    })
end
```

### 3. Hybrid Polling + Event-Driven Approach

**Overview**: Combine polling fallback with real-time monitoring when available.

**Implementation Strategy**:
- **Capability detection**: Check if remote server supports `inotify`
- **Graceful degradation**: Fall back to polling if real-time monitoring unavailable
- **Dual monitoring**: Use both approaches for critical files

**Per-Buffer Implementation**:
```lua
local function setup_file_monitoring(buffer_info)
    if remote_supports_inotify(buffer_info.host) then
        return setup_realtime_monitoring(buffer_info)
    else
        return setup_polling_monitoring(buffer_info)
    end
end
```

### 4. Conflict Detection and Resolution

**Overview**: Detect when local and remote versions diverge and provide resolution options.

**Implementation Strategy**:
- **Pre-save validation**: Check remote file timestamp before saving
- **Conflict detection**: Compare local buffer timestamp with remote file
- **User prompts**: Offer resolution options when conflicts detected
- **Three-way merge**: Support merge tools for complex conflicts

**Conflict Resolution Options**:
```lua
local conflict_resolution = {
    OVERWRITE_REMOTE = "overwrite",     -- Save local changes, ignore remote
    OVERWRITE_LOCAL = "reload",         -- Discard local changes, reload remote
    SHOW_DIFF = "diff",                 -- Open diff view for manual resolution
    THREE_WAY_MERGE = "merge",          -- Attempt automatic merge
    SAVE_BACKUP = "backup"              -- Save conflicted version with suffix
}
```

### 5. Buffer State Synchronization

**Overview**: Maintain metadata about each remote buffer to track synchronization state.

**Per-Buffer Tracking**:
```lua
local buffer_state = {
    buffer_id = 123,
    remote_path = "/path/to/file",
    host = "user@server",
    last_sync_time = 1634567890,        -- Unix timestamp
    remote_mtime = 1634567890,          -- Last known remote modification time
    local_mtime = 1634567890,           -- Local buffer modification time
    watching_enabled = true,
    watch_job_id = 456,                 -- Job ID for monitoring process
    conflict_state = "none",            -- none, detected, resolving
    sync_strategy = "polling"           -- polling, inotify, hybrid
}
```

## Recommended Implementation Plan

### Phase 1: Basic Polling Infrastructure
1. **Buffer registry**: Extend existing buffer tracking to include sync metadata
2. **Polling engine**: Implement timer-based remote file checking
3. **Change detection**: Compare remote and local timestamps
4. **User notifications**: Alert users when remote changes detected

### Phase 2: Conflict Detection and Resolution
1. **Pre-save validation**: Check for remote changes before saving
2. **Conflict UI**: Implement user prompts for conflict resolution
3. **Backup creation**: Save conflicted versions with suffixes
4. **Auto-refresh option**: Automatically reload when no local changes

### Phase 3: Advanced Monitoring
1. **Real-time monitoring**: Implement `inotify`-based watching
2. **Hybrid approach**: Combine polling and real-time as appropriate
3. **Batch optimization**: Efficient checking of multiple files
4. **Connection management**: Robust handling of SSH connection issues

### Phase 4: Integration and Polish
1. **LSP coordination**: Ensure proper LSP notifications during refreshes
2. **Configuration options**: Comprehensive user configuration
3. **Performance optimization**: Minimize overhead and SSH traffic
4. **Error handling**: Graceful degradation and error recovery

## Configuration Design

```lua
require('remote-ssh').setup({
    file_watching = {
        -- Global enable/disable
        enabled = true,
        
        -- Default monitoring strategy
        default_strategy = "auto",  -- auto, polling, inotify, hybrid
        
        -- Polling configuration
        polling = {
            interval = 5000,           -- Default poll interval (ms)
            adaptive = true,           -- Adjust frequency based on activity
            max_interval = 30000,      -- Maximum interval for inactive files
            min_interval = 1000,       -- Minimum interval for active files
            batch_size = 10            -- Files to check per SSH command
        },
        
        -- Real-time monitoring
        realtime = {
            enable_inotify = true,     -- Try to use inotify when available
            connection_timeout = 30,   -- SSH connection timeout
            reconnect_attempts = 3,    -- Reconnection attempts
            reconnect_delay = 5000     -- Delay between reconnection attempts
        },
        
        -- Conflict handling
        conflicts = {
            auto_resolve = false,      -- Automatically resolve conflicts
            default_action = "prompt", -- prompt, overwrite, reload, diff
            backup_conflicts = true,   -- Create backup files for conflicts
            backup_suffix = ".conflict" -- Suffix for conflict backups
        },
        
        -- User interface
        notifications = {
            show_changes = true,       -- Notify when remote changes detected
            show_conflicts = true,     -- Notify when conflicts detected
            show_sync_status = false   -- Show sync status in statusline
        }
    }
})
```

## Technical Considerations

### SSH Connection Management
- **Connection reuse**: Share SSH connections between monitoring and file operations
- **Connection pooling**: Maintain connection pools per host
- **Timeout handling**: Graceful handling of network timeouts
- **Authentication**: Ensure monitoring works with key-based and password auth

### Performance Optimization
- **Intelligent scheduling**: Avoid overwhelming remote servers with requests
- **Network efficiency**: Batch operations and minimize SSH overhead
- **Resource management**: Clean up monitoring processes for closed buffers
- **Caching**: Cache remote file metadata to reduce redundant checks

### Error Handling
- **Network failures**: Graceful degradation when SSH connections fail
- **Permission issues**: Handle cases where file monitoring isn't permitted
- **Tool availability**: Fallback when `inotify` or other tools unavailable
- **Partial failures**: Continue monitoring other files when individual checks fail

### Security Considerations
- **Command injection**: Properly escape all file paths and SSH commands
- **Access control**: Respect remote file permissions and access restrictions
- **Credential management**: Secure handling of SSH credentials and keys
- **Audit logging**: Optional logging of file monitoring activities

## Integration Points

### LSP Integration
- **Save coordination**: Ensure LSP is notified of automatic refreshes
- **Change notifications**: Send appropriate LSP events for file changes
- **Diagnostics refresh**: Trigger re-analysis when files change externally

### Existing Plugin Features
- **Browse functionality**: Coordinate with remote file browser
- **Process management**: Integrate with existing async job infrastructure
- **Configuration system**: Extend existing configuration framework
- **Logging system**: Use existing logging infrastructure for debugging

This comprehensive approach would provide robust remote file watching capabilities while maintaining compatibility with the existing plugin architecture and ensuring a smooth user experience.