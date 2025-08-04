# Windows Compatibility Analysis for remote-ssh.nvim

This document analyzes the compatibility issues preventing the remote-ssh.nvim plugin from running on Windows nvim.exe while connecting to Linux/macOS servers.

## Overview

The remote-ssh.nvim plugin is currently designed for Unix-like systems and has several dependencies that need to be addressed for Windows compatibility. While the remote servers would remain Linux/macOS, the local Neovim client would run on Windows.

## Key Compatibility Issues

### 1. SSH Command Construction and Execution

**Current Implementation:**
- Uses Unix-style SSH commands with shell escaping
- Relies on Unix SSH client behavior and options

**Windows Issues:**
- Windows SSH client (`ssh.exe`) may have different option support
- Command escaping differs between Windows Command Prompt/PowerShell and Unix shells
- Path separators (backslash vs forward slash)

**Files Affected:**
- `lua/async-remote-write/ssh_utils.lua:33-75` - SSH command construction
- `lua/async-remote-write/tree_browser.lua:47-55` - SSH directory listing
- `lua/async-remote-write/browse.lua:1509,3768` - File browser SSH calls

**Required Changes:**
```lua
-- Detect Windows and adjust SSH command construction
local is_windows = vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1
if is_windows then
    -- Use Windows-compatible SSH options
    -- Handle Windows path escaping
    -- Use appropriate shell wrapper (cmd.exe or PowerShell)
end
```

### 2. Python Script Execution

**Current Implementation:**
- Hardcoded `python3` executable in proxy script invocation
- Unix-style shebang (`#!/usr/bin/env python3`)

**Windows Issues:**
- Python executable may be `python.exe` or `py.exe` instead of `python3`
- Shebang lines are not supported on Windows
- Different Python installation paths

**Files Affected:**
- `lua/remote-lsp/client.lua:213` - Python proxy invocation
- `lua/remote-lsp/proxy.py:1` - Shebang line

**Required Changes:**
```lua
-- Detect Python executable on Windows
local python_cmd = "python3"
if vim.fn.has('win32') == 1 then
    -- Try py.exe first (Python Launcher), then python.exe
    python_cmd = vim.fn.executable('py') == 1 and 'py' or 'python'
end
```

### 3. Process Spawning and Job Management

**Current Implementation:**
- Uses `vim.fn.jobstart()` with Unix shell assumptions
- Shell wrapper uses `{"sh", "-c", "command"}` format

**Windows Issues:**
- Windows doesn't have `sh` by default
- Different process spawning behavior
- Command-line length limitations

**Files Affected:**
- `lua/async-remote-write/ssh_utils.lua:67-75` - Shell wrapper
- `lua/async-remote-write/operations.lua` - SSH process spawning

**Required Changes:**
```lua
-- Use Windows-appropriate shell
local shell_cmd
if vim.fn.has('win32') == 1 then
    shell_cmd = {"cmd", "/c", full_command}
    -- Or for PowerShell: {"powershell", "-Command", full_command}
else
    shell_cmd = {"sh", "-c", full_command}
end
```

### 4. File Path Handling

**Current Implementation:**
- Unix-style path separators and conventions
- Assumes forward slashes in all paths

**Windows Issues:**
- Windows uses backslashes as path separators
- Drive letters (C:, D:, etc.)
- Different path resolution behavior

**Files Affected:**
- `lua/remote-lsp/utils.lua:145-151` - Path normalization
- `lua/async-remote-write/utils.lua` - File path utilities

**Required Changes:**
```lua
-- Normalize paths for cross-platform compatibility
local function normalize_path(path)
    if vim.fn.has('win32') == 1 then
        return path:gsub('/', '\\')
    end
    return path
end
```

### 5. Shell Script Dependencies

**Current Implementation:**
- Relies on Unix shell commands and utilities
- Uses shell-specific syntax and features

**Windows Issues:**
- No native support for shell scripts
- Different command-line tools and syntax

**Files Affected:**
- `lua/remote-lsp/proxy.py:250-268` - Shell command construction for environment setup

**Required Changes:**
- Replace shell script logic with Python or Lua equivalents
- Use cross-platform command construction

### 6. Environment Variable Handling

**Current Implementation:**
- Unix-style environment variable syntax (`$HOME`, `$PATH`)
- Bash-specific sourcing of configuration files

**Windows Issues:**
- Windows uses different environment variable syntax (`%HOME%`, `%PATH%`)
- No equivalent to `.bashrc` sourcing

**Files Affected:**
- `lua/remote-lsp/proxy.py:250-257` - Environment setup

## Implementation Strategy

### Phase 1: Core Infrastructure
1. **Platform Detection Module**
   - Create `lua/async-remote-write/platform.lua`
   - Centralize Windows/Unix detection logic
   - Provide platform-specific utilities

2. **SSH Command Abstraction**
   - Modify `ssh_utils.lua` to handle Windows SSH client
   - Implement Windows-compatible command escaping
   - Test with OpenSSH for Windows

### Phase 2: Process Management
1. **Python Executable Detection**
   - Auto-detect available Python executable
   - Fallback mechanisms for different Python installations
   - Error handling for missing Python

2. **Shell Wrapper Updates**
   - Replace `sh -c` with Windows equivalents
   - Implement PowerShell and cmd.exe support
   - Handle command-line length limitations

### Phase 3: Path and Environment
1. **Path Normalization**
   - Cross-platform path handling utilities
   - Windows drive letter support
   - URI conversion for Windows paths

2. **Environment Setup**
   - Replace bash sourcing with registry/environment queries
   - Windows-specific PATH handling
   - LSP server discovery on Windows

## Testing Requirements

### Test Environment Setup
- Windows 10/11 with nvim.exe
- OpenSSH for Windows installed
- Python 3.x available
- Remote Linux/macOS servers for testing

### Test Cases
1. **Basic SSH Connectivity**
   - Test SSH key authentication from Windows
   - Verify SSH command execution
   - Test file transfer operations

2. **LSP Server Communication**
   - Test Python proxy script execution
   - Verify LSP protocol forwarding
   - Test various LSP servers (rust-analyzer, pyright, etc.)

3. **File Browser Operations**
   - Test remote directory listing
   - Verify file operations (create, delete, move)
   - Test large directory handling

## Estimated Effort

### Development Time
- **Phase 1:** 2-3 days
- **Phase 2:** 3-4 days
- **Phase 3:** 2-3 days
- **Testing & Bug Fixes:** 3-5 days

**Total:** 10-15 days

### Complexity Rating
- **Medium-High:** Requires careful handling of platform differences
- **Risk Areas:** SSH client behavior, Python environment detection
- **Testing Intensive:** Multiple Windows configurations to validate

## Alternative Approaches

### 1. WSL Integration
- Use Windows Subsystem for Linux as execution environment
- Pros: Minimal code changes, Unix compatibility
- Cons: Requires WSL installation, additional complexity

### 2. Docker/Container Approach
- Run the plugin components in a Linux container
- Pros: Complete Unix environment, isolated
- Cons: Requires Docker, resource overhead

### 3. Native Windows Rewrite
- Reimplement core functionality using Windows-native tools
- Pros: Optimal Windows integration
- Cons: Significant development effort, maintenance burden

## Conclusion

Windows compatibility is achievable but requires systematic addressing of platform-specific differences. The main challenges involve SSH command construction, Python execution, and process management. A phased approach starting with core infrastructure changes would provide the best path forward.

The estimated 10-15 day development effort would enable the plugin to run on Windows nvim.exe while maintaining full compatibility with Linux/macOS remote servers.
