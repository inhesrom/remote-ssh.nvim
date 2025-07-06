# Docker Testing Environment for Remote LSP

This Docker container provides a complete testing environment for remote LSP functionality with multiple language servers and test projects.

## Quick Start

### Using the Build Script (Recommended)
```bash
# Make script executable (first time only)
chmod +x build-docker.sh

# Build and run everything
./build-docker.sh full

# Or just start (if already built)
./build-docker.sh run

# Connect via SSH
./build-docker.sh connect

# Show status
./build-docker.sh status

# View logs
./build-docker.sh logs

# Clean everything
./build-docker.sh clean
```

### Manual Docker Commands
```bash
# Build and start the container manually
docker-compose up -d --build

# Check if container is running
docker ps

# View logs
docker-compose logs -f
```

### Add publickey
```bash
ssh-copy-id testuser@localhost
# Password: testpassword
```

### Connect via SSH
```bash
# Connect to the container
ssh testuser@localhost
# Password: testpassword
```

## Container Contents

### Language Servers Installed
- **clangd**: C/C++ language server
- **pylsp**: Python LSP server with full feature support
- **rust-analyzer**: Rust language server

### Test Projects

#### Large, Real-World Repositories (`/home/testuser/repos/`)

**C++ Projects:**
- **llvm-project**: LLVM/Clang subset with complex C++ patterns
- **Catch2**: Modern C++ testing framework with heavy templating
- **json**: nlohmann/json header-only library with C++17 features

**Python Projects:**
- **django**: Full web framework with complex ORM and class hierarchies
- **flask**: Micro framework with decorator patterns
- **fastapi**: Modern async framework with type hints
- **requests**: Well-designed HTTP library

**Rust Projects:**
- **tokio**: Async runtime with complex futures and macros
- **serde**: Serialization with procedural macros
- **clap**: CLI parser with builder patterns
- **actix-web**: Actor-based web framework
- **Rocket**: Type-safe web framework

#### Custom Test Files (`/home/testuser/test-files`)
- Minimal but complete projects for each language
- Designed to trigger specific LSP features
- Includes proper build configurations

## Testing Remote LSP Plugin

### Configure Neovim
Test with real-world, complex codebases:

```lua
-- Large C++ files with complex dependencies
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/llvm-project/clang/lib/Basic/Targets.cpp')
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/Catch2/src/catch2/catch_test_macros.hpp')

-- Complex Python frameworks
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/django/django/db/models/base.py')
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/fastapi/fastapi/main.py')

-- Advanced Rust async and macro code
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/tokio/tokio/src/lib.rs')
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/serde/serde/src/lib.rs')

-- Or use the simple test files
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/test-files/main.cpp')
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/test-files/main.py')
vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/test-files/main.rs')
```

### Test Features
Once connected, you can test:
- **Go-to-definition**: Jump to function/variable definitions
- **Hover**: Get type information and documentation
- **Code completion**: IntelliSense-style completions
- **Diagnostics**: Syntax errors and warnings
- **Workspace symbols**: Search for symbols across the project
- **File watching**: Changes detected across the workspace

### SSH Configuration
Add to your `~/.ssh/config`:
```
Host docker-lsp-test
    HostName localhost
    Port 2222
    User testuser
    PasswordAuthentication yes
```

Then connect with: `ssh docker-lsp-test`

## Test Scenarios

### C++ with clangd
```bash
# Connect and test
ssh -p 2222 testuser@localhost
cd /home/testuser/test-files
clangd --version
```

Test files include:
- `main.cpp` - Main application with includes
- `utils.cpp` - Implementation file
- `include/utils.h` - Header file
- `CMakeLists.txt` - Build configuration
- `build/compile_commands.json` - Clangd database

### Python with pylsp
```bash
cd /home/testuser/test-files
pylsp --version
python3 main.py
```

Test files include:
- `main.py` - Main script with type hints
- `utils.py` - Utility module with classes
- Full type annotation support

### Rust with rust-analyzer
```bash
cd /home/testuser/test-files
rust-analyzer --version
cargo build
cargo run
```

Test files include:
- `main.rs` - Main application
- `utils.rs` - Utility module
- `Cargo.toml` - Project configuration
- Built dependencies in `target/`

## Troubleshooting

### Container Management
```bash
# Stop container
docker-compose down

# Rebuild container
docker-compose up -d --build --force-recreate

# Access container shell
docker exec -it remote-lsp-test bash

# View container logs
docker-compose logs -f remote-lsp-test
```

### SSH Issues
```bash
# Test SSH connection
ssh -p 2222 -v testuser@localhost

# Check if SSH service is running in container
docker exec remote-lsp-test systemctl status ssh
```

### Language Server Issues
```bash
# Test language servers directly
docker exec -it remote-lsp-test bash
su - testuser
clangd --version
pylsp --version
rust-analyzer --version
```

## Advanced Usage

### Custom Test Files
You can mount additional test files:
```bash
# Create local test directory
mkdir -p test-workspace

# Mount it in docker-compose.yml (already configured)
# Files will appear at /home/testuser/workspace in the container
```

### Network Configuration
The container uses a custom bridge network. You can inspect it:
```bash
docker network inspect remote-ssh-nvim_lsp-network
```

### Performance Testing
For performance testing, you can:
1. Create large projects in the container
2. Test with multiple simultaneous connections
3. Monitor resource usage with `docker stats`

## Cleanup
```bash
# Stop and remove container
docker-compose down

# Remove built image
docker rmi remote-ssh-nvim_remote-lsp-test

# Remove volumes (if any)
docker volume prune
```
