# Docker Testing Environment for Remote LSP

This Docker container provides a complete testing environment for remote LSP functionality with multiple language servers and test projects.

## Quick Start

### Method 1: Using Docker Compose (Recommended)
```bash
# Build and start the container
docker-compose up -d --build

# Set up passwordless SSH access
./setup-ssh-keys.sh

# Connect to the container
ssh testuser@localhost
```

### Method 2: Using the Build Script
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

### Manual SSH Setup
If automated setup fails, you can configure SSH keys manually:

```bash
# Generate SSH key if you don't have one
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa

# Copy the key to the container (password: testpassword)
ssh-copy-id testuser@localhost

# Test the connection
ssh testuser@localhost
```

## Container Details

- **SSH User:** testuser
- **SSH Password:** testpassword (for initial setup)
- **SSH Port:** 22
- **Root Password:** rootpassword

### Available Tools
The container includes:
- **Language Servers:** rust-analyzer, clangd, pylsp
- **Development Tools:** git, cmake, build-essential
- **System Tools:** rsync, find, tree, htop, vim, nano
- **Network Tools:** netcat, telnet, ping

## Test Repositories

The container includes several real-world projects for comprehensive LSP testing:

### C++ Projects (`/home/testuser/repos/`)
- **llvm-project**: LLVM/Clang subset
- **Catch2**: Modern C++ testing framework
- **json**: nlohmann/json library

### Python Projects (`/home/testuser/repos/`)
- **django**: Web framework
- **flask**: Micro web framework
- **fastapi**: Async web framework
- **requests**: HTTP library

### Rust Projects (`/home/testuser/repos/`)
- **tokio**: Async runtime
- **serde**: Serialization framework
- **clap**: Command line parser
- **actix-web**: Web framework
- **Rocket**: Web framework

### Custom Test Files (`/home/testuser/test-files`)
- Minimal but complete projects for each language
- Designed to trigger specific LSP features
- Includes proper build configurations

## Neovim Remote Development

Once SSH keys are set up, you can use this container for remote development:

```lua
-- Example: Edit a complex Rust file
vim.cmd("edit scp://testuser@localhost//home/testuser/repos/tokio/tokio/src/lib.rs")

-- Example: Edit a Django model
vim.cmd("edit scp://testuser@localhost//home/testuser/repos/django/django/db/models/base.py")
```

### Test with Real-World Codebases

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

### SSH Connection Issues
- Ensure the container is running: `docker ps`
- Check container logs: `docker logs remote-lsp-test`
- Verify SSH service: `docker exec remote-lsp-test systemctl status ssh`

### Missing Tools
- Install additional tools: `docker exec remote-lsp-test apt update && apt install -y <package-name>`
- Or modify the Dockerfile and rebuild

### Port Conflicts
- If port 22 is in use, modify `docker-compose.yml` to use a different port:
  ```yaml
  ports:
    - "2222:22"
  ```

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
