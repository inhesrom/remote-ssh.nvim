# Gitsigns.nvim SSH Remote Buffer Implementation Plan

## Executive Summary

This document outlines a comprehensive plan to extend gitsigns.nvim to support SSH remote buffers, enabling Git integration for files accessed over SSH connections. The implementation leverages the existing modular architecture while adding minimal complexity to the core codebase.

## Background

Currently, gitsigns.nvim only works with local Git repositories. When editing files over SSH (using plugins like remote-ssh.nvim or netrw), users lose all Git integration features like:
- Diff signs in the gutter
- Hunk staging/unstaging
- Blame information
- Branch status

This implementation enables full Git functionality for remote files while maintaining the plugin's performance and reliability characteristics.

## Architecture Overview

### Design Principles

1. **Minimal Invasiveness**: Leverage existing hooks and extension points
2. **Opt-in Feature**: Disabled by default to avoid breaking existing workflows
3. **Async by Default**: All SSH operations are non-blocking
4. **Fail Gracefully**: Degrade to no-op if SSH connections fail
5. **Consistent UX**: Same commands and behavior as local Git operations

### Key Components

The implementation extends four core areas:

1. **Context Detection** (attach.lua) - Identify SSH buffers
2. **Command Execution** (git/cmd.lua) - Execute Git commands over SSH
3. **File Operations** (git.lua, git/repo.lua) - Handle remote file access
4. **Configuration** (config.lua) - SSH-specific settings

## Implementation Phases

### Phase 1: Foundation & Detection (Week 1-2)

#### 1.1 Configuration Extension

```lua
-- Add to config.lua defaults
ssh = {
  enable = false,                    -- Opt-in feature
  connection_timeout = 5000,         -- 5 second timeout
  command_timeout = 10000,           -- 10 second timeout for git commands
  max_retries = 2,                   -- Retry failed commands
  keep_alive_interval = 30,          -- Keep SSH connections alive
  debug = false,                     -- Enable SSH debug logging
  -- Connection pooling
  connection_pool = {
    max_connections = 5,
    idle_timeout = 300,              -- 5 minutes
  },
}
```

#### 1.2 SSH Context Detection

```lua
-- Add to attach.lua
local function parse_ssh_buffer(bufname)
  -- Support multiple SSH buffer formats:
  -- ssh://user@host:port/path/to/file
  -- scp://user@host/path/to/file  
  -- /ssh:user@host:/path/to/file (netrw format)
  -- fugitive://ssh://user@host/.git//commit:path
  
  local patterns = {
    "^ssh://([^@]+)@([^:]+):?(%d*)(/.*)$",
    "^scp://([^@]+)@([^/]+)(/.*)$",
    "^/ssh:([^@]+)@([^:]+):(/.*)$",
  }
  
  for _, pattern in ipairs(patterns) do
    local user, host, port, path = bufname:match(pattern)
    if user and host and path then
      return {
        user = user,
        host = host,
        port = port ~= "" and tonumber(port) or 22,
        remote_path = path,
        connection_string = string.format("%s@%s", user, host),
      }
    end
  end
  
  return nil
end
```

#### 1.3 Attach Integration

```lua
-- Extend get_buf_context() in attach.lua
local function get_buf_context(bufnr)
  -- ... existing code ...
  
  local bufname = api.nvim_buf_get_name(bufnr)
  local ssh_context = config.ssh.enable and parse_ssh_buffer(bufname)
  
  if ssh_context then
    -- For SSH buffers, we need to discover the remote Git repo
    local gitdir_oap, toplevel_oap = on_attach_pre(bufnr)
    
    return {
      file = ssh_context.remote_path,
      ssh_context = ssh_context,
      gitdir = gitdir_oap,
      toplevel = toplevel_oap,
    }
  end
  
  -- ... rest of existing code ...
end
```

### Phase 2: SSH Command Execution (Week 3-4)

#### 2.1 SSH Command Builder

```lua
-- Add new file: lua/gitsigns/ssh.lua
local M = {}

local function build_ssh_command(base_cmd, ssh_context, opts)
  opts = opts or {}
  
  local ssh_cmd = {
    "ssh",
    "-o", "ConnectTimeout=" .. math.floor(config.ssh.connection_timeout / 1000),
    "-o", "ServerAliveInterval=" .. config.ssh.keep_alive_interval,
    "-o", "BatchMode=yes",  -- Prevent password prompts
  }
  
  if ssh_context.port ~= 22 then
    table.insert(ssh_cmd, "-p")
    table.insert(ssh_cmd, tostring(ssh_context.port))
  end
  
  table.insert(ssh_cmd, ssh_context.connection_string)
  
  -- Change to remote directory and execute Git command
  local remote_cmd = string.format(
    "cd %s && %s",
    vim.fn.shellescape(opts.cwd or vim.fn.fnamemodify(ssh_context.remote_path, ":h")),
    table.concat(base_cmd, " ")
  )
  
  table.insert(ssh_cmd, remote_cmd)
  return ssh_cmd
end

-- Connection pooling
local connections = {}

function M.get_connection(ssh_context)
  local key = ssh_context.connection_string
  local conn = connections[key]
  
  if conn and conn.last_used + config.ssh.connection_pool.idle_timeout > os.time() then
    conn.last_used = os.time()
    return conn
  end
  
  -- Create new connection
  return M.create_connection(ssh_context)
end

return M
```

#### 2.2 Git Command Adapter

```lua
-- Modify git/cmd.lua git_command function
local function git_command(args, spec)
  spec = spec or {}
  
  -- SSH command execution
  if spec.ssh_context then
    local ssh = require('gitsigns.ssh')
    local base_cmd = flatten({
      'git',
      '--no-pager',
      '--no-optional-locks',
      '--literal-pathspecs',
      '-c', 'gc.auto=0',
      args,
    })
    
    local ssh_cmd = ssh.build_ssh_command(base_cmd, spec.ssh_context, {
      cwd = spec.remote_cwd
    })
    
    spec.timeout = config.ssh.command_timeout
    return asystem(ssh_cmd, spec)
  end
  
  -- ... existing local command logic ...
end
```

### Phase 3: Repository Operations (Week 5-6)

#### 3.1 Remote Repository Discovery

```lua
-- Extend git/repo.lua
function M.get_ssh(ssh_context, remote_path)
  local spec = {
    ssh_context = ssh_context,
    remote_cwd = vim.fn.fnamemodify(remote_path, ":h"),
  }
  
  -- Find .git directory on remote host
  local stdout, stderr = git_command({
    'rev-parse', '--show-toplevel', '--git-dir', '--show-superproject-working-tree'
  }, spec)
  
  if stderr then
    return nil, stderr
  end
  
  local toplevel = stdout[1]
  local gitdir = stdout[2]
  local superproject = stdout[3]
  
  -- Make paths absolute on remote host
  if not vim.startswith(gitdir, '/') then
    gitdir = toplevel .. '/' .. gitdir
  end
  
  return setmetatable({
    toplevel = toplevel,
    gitdir = gitdir,
    ssh_context = ssh_context,
    detached = superproject ~= "",
  }, { __index = M })
end
```

#### 3.2 Remote File Operations

```lua
-- Extend GitObj in git.lua
function Obj:get_show_text_ssh(revision, relpath)
  if not self.repo.ssh_context then
    return self:get_show_text(revision, relpath)
  end
  
  local spec = {
    ssh_context = self.repo.ssh_context,
    remote_cwd = self.repo.toplevel,
  }
  
  local object = revision and (revision .. ':' .. relpath) or self.object_name
  
  if not object then
    return { '' }
  end
  
  local stdout, stderr = self.repo:command({
    'show', object
  }, spec)
  
  return stdout, stderr
end
```

### Phase 4: Optimization & Polish (Week 7-8)

#### 4.1 Connection Management

```lua
-- Add connection pooling and keepalive
local function setup_ssh_keepalive()
  local timer = vim.loop.new_timer()
  timer:start(config.ssh.keep_alive_interval * 1000, 
              config.ssh.keep_alive_interval * 1000, 
              function()
    for key, conn in pairs(connections) do
      if os.time() - conn.last_used > config.ssh.connection_pool.idle_timeout then
        conn:close()
        connections[key] = nil
      end
    end
  end)
end
```

#### 4.2 Error Handling & Fallbacks

```lua
-- Graceful degradation
local function safe_ssh_operation(operation, fallback)
  local ok, result = pcall(operation)
  if ok then
    return result
  else
    log.dprintf("SSH operation failed: %s", result)
    if fallback then
      return fallback()
    end
    return nil
  end
end
```

#### 4.3 Performance Optimizations

- **Command Batching**: Combine multiple Git operations into single SSH calls
- **Intelligent Caching**: Cache remote file contents with SSH-aware invalidation
- **Background Prefetch**: Proactively fetch likely-needed Git data
- **Compression**: Enable SSH compression for large file transfers

## Testing Strategy

### Unit Tests

```lua
-- tests/ssh_spec.lua
describe('SSH operations', function()
  it('parses SSH buffer names correctly', function()
    local context = parse_ssh_buffer('ssh://user@example.com:2222/path/to/file.lua')
    assert.are.equal('user', context.user)
    assert.are.equal('example.com', context.host)
    assert.are.equal(2222, context.port)
    assert.are.equal('/path/to/file.lua', context.remote_path)
  end)
  
  it('builds SSH commands correctly', function()
    local cmd = build_ssh_command({'git', 'status'}, ssh_context)
    assert.matches('ssh.*user@host.*git status', table.concat(cmd, ' '))
  end)
end)
```

### Integration Tests

```lua
-- tests/ssh_integration_spec.lua  
describe('SSH Git integration', function()
  before_each(function()
    setup_test_ssh_server()
  end)
  
  it('attaches to SSH buffers', function()
    local bufnr = create_ssh_buffer('ssh://test@localhost/repo/file.lua')
    gitsigns.attach(bufnr)
    assert.is_not_nil(cache[bufnr])
  end)
  
  it('shows diff signs for remote files', function()
    -- Test with known modified file on test server
  end)
end)
```

### Manual Testing Scenarios

1. **Basic Functionality**
   - Open SSH buffer → verify signs appear
   - Make changes → verify signs update
   - Stage hunks → verify staging works

2. **Connection Handling**
   - Network interruption → verify graceful degradation
   - SSH key issues → verify error messages
   - Timeout scenarios → verify non-blocking behavior

3. **Performance**
   - Large files → verify responsive UI
   - Many SSH buffers → verify connection pooling
   - Rapid changes → verify debouncing works

## Risk Mitigation

### Technical Risks

1. **SSH Connection Failures**
   - Mitigation: Robust error handling, connection pooling, graceful degradation

2. **Performance Impact**
   - Mitigation: Aggressive caching, background operations, connection reuse

3. **Security Concerns**
   - Mitigation: Use existing SSH configurations, no credential storage

### Compatibility Risks

1. **Existing Workflow Disruption**
   - Mitigation: Opt-in feature, extensive testing, clear documentation

2. **Plugin Conflicts**
   - Mitigation: Test with popular SSH plugins, coordinate with maintainers

## Rollout Plan

### Phase 1: Alpha Release (Internal Testing)
- Core functionality working
- Basic error handling
- Limited to development team

### Phase 2: Beta Release (Community Testing)
- Feature-complete implementation
- Comprehensive testing
- Documentation and examples
- Feedback collection

### Phase 3: Stable Release
- Production-ready
- Performance optimized
- Full documentation
- Integration guides

## Success Metrics

1. **Functionality**: All core gitsigns features work over SSH
2. **Performance**: <500ms latency for typical operations
3. **Reliability**: <1% failure rate for SSH operations
4. **Adoption**: Used by >10% of gitsigns users within 6 months
5. **Community**: Positive feedback, minimal bug reports

## Future Enhancements

1. **Other Remote Protocols**: Support for other remote access methods
2. **Multiplexing**: SSH connection multiplexing for better performance  
3. **Caching Strategies**: More sophisticated caching with conflict resolution
4. **UI Improvements**: SSH-specific status indicators and error messages
5. **Integration**: Deep integration with SSH-based development workflows

## Conclusion

This implementation plan provides a clear path to extend gitsigns.nvim with SSH remote buffer support while maintaining the plugin's core principles of performance, reliability, and user experience. The phased approach allows for iterative development and testing, ensuring a robust final implementation that benefits the entire Neovim community.

The plan leverages existing architectural patterns and extension points, minimizing risk while maximizing functionality. The opt-in nature and graceful degradation ensure that existing users are not impacted while new capabilities are available to those who need them.