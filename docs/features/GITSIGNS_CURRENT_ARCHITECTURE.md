# Gitsigns.nvim Architecture

This document explains how gitsigns.nvim works internally, covering the core components, data flow, and key architectural decisions.

## Overview

Gitsigns.nvim is a Neovim plugin that provides deep Git integration for buffers, showing Git diff information in the sign column, enabling staging/unstaging of hunks, and providing blame information. The plugin is built around an asynchronous, event-driven architecture that efficiently tracks Git state changes.

## Core Components

### 1. Main Entry Point (`gitsigns.lua`)

The main module handles plugin initialization and global state management:

- **Setup**: Initializes the plugin, creates autocommands, and sets up global watchers
- **CWD Watching**: Monitors the current working directory for Git repository changes (`.git/HEAD`)
- **Auto-attach**: Automatically attaches to buffers when they're opened/modified

Key functions:
- `M.setup()` - Plugin initialization
- `update_cwd_head()` - Updates global Git HEAD state
- `setup_cwd_watcher()` - Watches for branch changes

### 2. Attachment System (`attach.lua`)

Manages the lifecycle of Git integration for individual buffers:

- **Buffer Detection**: Determines if a buffer should have Git integration
- **Context Resolution**: Resolves Git repository context (gitdir, toplevel, file path)
- **Lifecycle Management**: Handles attach/detach operations

Key functions:
- `M.attach()` - Attaches Git integration to a buffer
- `get_buf_context()` - Determines Git context for a buffer
- `on_attach_pre()` - Hook for custom attachment logic

### 3. Cache System (`cache.lua`)

Central state management for each buffer's Git information:

- **CacheEntry**: Per-buffer state container
- **Hunk Storage**: Stores computed diff hunks
- **Blame Cache**: Caches Git blame information
- **Staged Hunks**: Tracks staged changes separately

Key components:
- `CacheEntry` class - Stores all buffer-related Git state
- `cache` table - Global buffer ID → CacheEntry mapping
- Invalidation logic for handling content changes

### 4. Git Operations (`git/`)

Low-level Git command execution and repository management:

#### `git/cmd.lua`
- **Command Execution**: Executes Git commands asynchronously
- **Working Directory**: Sets proper `cwd` for Git operations
- **Error Handling**: Manages Git command failures

#### `git/repo.lua`
- **Repository Discovery**: Finds Git repositories for files
- **Repository State**: Tracks repository metadata (gitdir, toplevel, HEAD)
- **File Operations**: Git operations on specific files

#### `git.lua`
- **GitObj**: Represents a file within a Git repository
- **Content Retrieval**: Gets file content from specific revisions
- **Staging Operations**: Handles staging/unstaging of changes

### 5. Manager (`manager.lua`)

Orchestrates updates and coordinates between components:

- **Update Pipeline**: Manages the async update process
- **Sign Application**: Places signs in the sign column
- **Decoration Provider**: Integrates with Neovim's decoration system
- **Word Diff**: Handles inline word-level diff highlighting

Key functions:
- `M.update()` - Main update function (throttled)
- `apply_win_signs()` - Places signs in visible window area
- `on_lines()` - Handles buffer content changes

### 6. Diff Engine (`diff.lua`, `diff_int.lua`, `diff_ext.lua`)

Computes differences between file versions:

- **Internal Diff**: Pure Lua implementation using Myers algorithm
- **External Diff**: Uses external `git diff` command
- **Hunk Generation**: Creates structured diff hunks
- **Word Diff**: Character-level diff within lines

### 7. Actions (`actions.lua`)

Provides user-facing commands and operations:

- **Hunk Operations**: Stage, unstage, reset hunks
- **Navigation**: Move between hunks
- **Blame**: Show Git blame information
- **Preview**: Show hunk previews

### 8. Signs System (`signs.lua`)

Manages Neovim signs for visual indicators:

- **Sign Placement**: Places/removes signs efficiently
- **Highlight Groups**: Manages different sign types (add, change, delete)
- **Staged Signs**: Separate signs for staged changes
- **Sign Configuration**: Handles user sign customization

### 9. Watcher (`watcher.lua`)

Monitors Git directory changes:

- **File System Watching**: Watches `.git` directory for changes
- **Event Handling**: Responds to Git operations (commits, branch changes)
- **Moved File Detection**: Handles renamed/moved files

## Data Flow

### 1. Buffer Attachment Flow

```
Buffer Open/Change
      ↓
   attach.lua → get_buf_context()
      ↓
   Git repository discovery
      ↓
   Create GitObj and CacheEntry
      ↓
   Initial update via manager.lua
```

### 2. Update Pipeline

```
Buffer Change Event
      ↓
   manager.on_lines() → debounced update
      ↓
   manager.update() → async execution
      ↓
   1. Get current buffer content
   2. Get Git file content (compare_text)
   3. Run diff algorithm
   4. Generate hunks
   5. Apply signs to window
   6. Update status
```

### 3. Git Operations Flow

```
User Action (stage hunk)
      ↓
   actions.lua → stage_hunk()
      ↓
   GitObj:stage_hunks()
      ↓
   git/cmd.git_command() → 'git apply --cached'
      ↓
   Trigger update pipeline
```

## Key Architectural Decisions

### Asynchronous Design

All Git operations are asynchronous to prevent blocking the UI:
- Uses custom async/await library (`async.lua`)
- Throttling and debouncing prevent excessive Git calls
- Scheduling ensures UI updates happen on main thread

### Caching Strategy

Aggressive caching minimizes Git operations:
- Per-buffer cache stores computed hunks
- Compare text cached until file/repo changes
- Blame information cached with invalidation logic

### Incremental Updates

Only visible signs are computed/updated:
- Decoration provider integration for lazy evaluation
- Window-based sign placement
- On-demand word diff computation

### Event-Driven Updates

Responds to multiple trigger sources:
- Buffer content changes (`on_lines`)
- File system events (Git directory watcher)
- Buffer lifecycle events (attach/detach)
- User commands and actions

### Modularity

Clean separation of concerns:
- Git operations isolated in `git/` modules
- Sign management separated from diff computation
- Actions layer provides stable user API
- Cache system provides centralized state management

## Performance Optimizations

1. **Throttling**: Prevents excessive updates during rapid typing
2. **Debouncing**: Batches rapid file changes
3. **Lazy Loading**: Many modules loaded on demand
4. **Efficient Diffing**: Choice between internal/external diff algorithms
5. **Window-based Updates**: Only compute signs for visible area
6. **Smart Invalidation**: Minimal cache invalidation on changes

## Error Handling

- Git command failures are logged but don't crash plugin
- Buffer validation prevents operations on invalid buffers
- Graceful degradation when Git repository is unavailable
- Lock mechanisms prevent concurrent operations

## Extension Points

- **on_attach_pre**: Hook for custom attachment logic
- **Custom diff algorithms**: Pluggable diff implementations
- **Sign customization**: Full control over sign appearance
- **Command extensions**: Actions can be extended/overridden

This architecture enables gitsigns.nvim to provide responsive Git integration while handling the complexity of asynchronous Git operations, efficient diff computation, and Neovim's event-driven model.
