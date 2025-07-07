# Test Framework for remote-ssh.nvim

This directory contains a comprehensive test framework for the remote-ssh.nvim plugin, with a focus on testing root directory detection and mock SSH operations.

## Running Tests

### Run all tests
```bash
lua tests/run_tests.lua
```

### Run specific test file
```bash
lua tests/run_tests.lua test_root_detection
```

### Run from Neovim
```lua
:lua require('tests.run_tests')
```

## Test Structure

### Core Files

- `init.lua` - Test framework with assertion library and test runner
- `mocks.lua` - Mock implementations for SSH calls and filesystem operations
- `run_tests.lua` - Test runner script that can be executed standalone
- `README.md` - This file

### Test Files

- `test_root_detection.lua` - Comprehensive tests for project root directory detection
- `test_proxy.lua` - Core LSP proxy URI translation and message processing tests
- `test_proxy_integration.lua` - Real-world LSP scenarios and protocol handling tests  
- `test_proxy_script.lua` - Tests that simulate the actual proxy.py script behavior
- `test_client_integration.lua` - End-to-end client lifecycle and server management tests
- `test_buffer_management.lua` - Buffer tracking, attachment, and lifecycle management tests

## Test Framework Features

### Assertion Library
```lua
local test = require('tests.init')

test.assert.equals(actual, expected, message)
test.assert.truthy(value, message)
test.assert.falsy(value, message)
test.assert.contains(table, value, message)
```

### Test Structure
```lua
test.describe("Feature Name", function()
    test.setup(function()
        -- Setup code run before each test in this group
    end)

    test.teardown(function()
        -- Cleanup code run after each test in this group
    end)

    test.it("should do something", function()
        -- Test implementation
        test.assert.equals(1 + 1, 2)
    end)
end)
```

### Mocking System

#### SSH Command Mocking
```lua
local mocks = require('tests.mocks')

-- Enable SSH mocking
mocks.ssh_mock.enable()

-- Set response for SSH command pattern
mocks.ssh_mock.set_response("ssh .* 'ls %-la %.git'", "drwxr-xr-x .git")

-- Disable mocking
mocks.ssh_mock.disable()
```

#### Filesystem Mocking
```lua
-- Create a mock project structure
mocks.create_project_structure({
    [".git"] = {},
    ["Cargo.toml"] = "[package]\nname = \"test\"\n",
    ["src"] = {
        ["main.rs"] = "fn main() {}\n"
    }
})

-- Or use pre-defined fixtures
mocks.create_project_structure(mocks.project_fixtures.rust_workspace)
```

## Available Project Fixtures

### Rust Workspace
- Complete Cargo workspace with multiple crates
- Includes `.git`, `Cargo.toml`, and source files
- Tests workspace-aware root detection

### C++ CMake Project
- CMake-based C++ project structure
- Includes `compile_commands.json` for clangd testing
- Tests prioritized pattern detection

### Python Project
- Modern Python project with `pyproject.toml`
- Includes package structure and tests
- Tests Python-specific root detection

### JavaScript/TypeScript Project
- Node.js project with `package.json` and `tsconfig.json`
- Tests JS/TS server root detection

## Test Coverage

The test suite covers:

1. **Root Directory Detection**
   - Standard pattern-based detection
   - Rust workspace-specific detection
   - Clangd compile_commands.json prioritization
   - Path normalization and cleanup
   - Cache functionality
   - Server-specific configuration overrides

2. **Fast Mode Detection**
   - Performance-optimized detection
   - Fallback behavior

3. **LSP Proxy Functionality**
   - URI translation between local and remote formats
   - Complex nested object handling (workspace edits, diagnostics)
   - LSP message protocol (Content-Length headers)
   - Process management and lifecycle
   - Error handling and edge cases

4. **Real-world LSP Scenarios**
   - rust-analyzer initialization and workspace detection
   - clangd compilation database workflow
   - Workspace symbol search and go-to-definition
   - File watching and change notifications
   - Code actions and workspace edits
   - Diagnostic publishing

5. **Protocol Simulation**
   - Full LSP initialization handshake
   - textDocument operations (open, close, change)
   - Bidirectional message translation
   - SSH process management

6. **Error Handling**
   - Missing root markers
   - Filesystem boundary conditions
   - SSH command failures
   - LSP server startup failures
   - Malformed messages and protocol errors

7. **Client Integration & Lifecycle**
   - Complete LSP client startup and initialization
   - Server reuse across multiple buffers
   - Multi-host and multi-server scenarios
   - Filetype detection and server selection
   - Client shutdown and cleanup

8. **Buffer Management**
   - Buffer tracking and attachment to LSP clients
   - Multiple buffers sharing the same server
   - Buffer cleanup when files are closed
   - Save notifications and synchronization
   - Error handling for invalid buffers

9. **Configuration**
   - Global vs server-specific settings
   - Cache configuration
   - Search depth limits

## Adding New Tests

1. Create a new test file in the `tests/` directory
2. Require the test framework: `local test = require('tests.init')`
3. Add your test file to the `test_files` list in `run_tests.lua`
4. Use the mock system to simulate SSH calls and filesystem structures

Example test structure:
```lua
local test = require('tests.init')
local mocks = require('tests.mocks')

test.describe("Your Feature", function()
    test.setup(function()
        mocks.ssh_mock.enable()
        -- Setup mocks
    end)

    test.teardown(function()
        mocks.ssh_mock.disable()
        mocks.ssh_mock.clear()
    end)

    test.it("should work correctly", function()
        -- Your test code
        test.assert.equals(actual, expected)
    end)
end)
```

## Integration with CI/CD

The test runner exits with appropriate codes:
- Exit code 0: All tests passed
- Exit code 1: One or more tests failed

This makes it suitable for CI/CD integration where test failure should fail the build.
