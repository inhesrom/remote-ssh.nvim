#!/bin/bash

# Build and run script for Remote LSP Docker testing environment
# Usage: ./build-docker.sh [command]
# Commands: build, run, stop, restart, connect, logs, clean

set -e

CONTAINER_NAME="remote-lsp-test"
IMAGE_NAME="remote-ssh-nvim_remote-lsp-test"
SSH_PORT="2222"
SSH_USER="testuser"
SSH_HOST="localhost"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running. Please start Docker first."
        exit 1
    fi
}

# Check if port is available
check_port() {
    if lsof -Pi :$SSH_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        warn "Port $SSH_PORT is already in use. The container might already be running."
        return 1
    fi
    return 0
}

# Build the Docker image
build_image() {
    log "Building Docker image..."
    
    if docker-compose build --no-cache; then
        log "Docker image built successfully!"
    else
        error "Failed to build Docker image"
        exit 1
    fi
}

# Start the container
start_container() {
    log "Starting Docker container..."
    
    # Check if container is already running
    if docker ps -q -f name=$CONTAINER_NAME | grep -q .; then
        warn "Container $CONTAINER_NAME is already running"
        return 0
    fi
    
    # Check if container exists but is stopped
    if docker ps -aq -f name=$CONTAINER_NAME | grep -q .; then
        log "Starting existing container..."
        docker start $CONTAINER_NAME
    else
        log "Creating and starting new container..."
        docker-compose up -d
    fi
    
    # Wait for container to be ready
    log "Waiting for container to be ready..."
    sleep 5
    
    # Test SSH connection
    if wait_for_ssh; then
        log "Container is ready for SSH connections!"
        show_connection_info
    else
        error "Container started but SSH is not accessible"
        exit 1
    fi
}

# Stop the container
stop_container() {
    log "Stopping Docker container..."
    
    if docker-compose down; then
        log "Container stopped successfully!"
    else
        warn "Failed to stop container or container was not running"
    fi
}

# Restart the container
restart_container() {
    log "Restarting Docker container..."
    stop_container
    start_container
}

# Connect to container via SSH
connect_ssh() {
    log "Connecting to container via SSH..."
    info "Password: testpassword"
    
    # Add SSH key to known hosts to avoid prompt
    ssh-keyscan -p $SSH_PORT $SSH_HOST >> ~/.ssh/known_hosts 2>/dev/null || true
    
    ssh -p $SSH_PORT $SSH_USER@$SSH_HOST
}

# Wait for SSH to be ready
wait_for_ssh() {
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -p $SSH_PORT -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $SSH_USER@$SSH_HOST echo "SSH Ready" 2>/dev/null; then
            return 0
        fi
        
        info "Waiting for SSH (attempt $attempt/$max_attempts)..."
        sleep 2
        ((attempt++))
    done
    
    return 1
}

# Show logs
show_logs() {
    log "Showing container logs..."
    docker-compose logs -f
}

# Clean up everything
clean_all() {
    log "Cleaning up Docker resources..."
    
    # Stop and remove container
    docker-compose down 2>/dev/null || true
    
    # Remove image
    docker rmi $IMAGE_NAME 2>/dev/null || true
    
    # Remove volumes
    docker volume prune -f
    
    # Remove networks
    docker network prune -f
    
    log "Cleanup complete!"
}

# Show connection information
show_connection_info() {
    echo ""
    echo "============================================="
    echo "🚀 Remote LSP Docker Container is Ready!"
    echo "============================================="
    echo ""
    echo "SSH Connection:"
    echo "  Host: $SSH_HOST"
    echo "  Port: $SSH_PORT"
    echo "  User: $SSH_USER"
    echo "  Pass: testpassword"
    echo ""
    echo "Quick Connect:"
    echo "  ssh -p $SSH_PORT $SSH_USER@$SSH_HOST"
    echo ""
    echo "Test Repositories:"
    echo "  C++:    /home/testuser/repos/*/  (LLVM, Catch2, JSON)"
    echo "  Python: /home/testuser/repos/*/  (Django, Flask, FastAPI)"
    echo "  Rust:   /home/testuser/repos/*/  (Tokio, Serde, Clap)"
    echo ""
    echo "Language Servers:"
    echo "  clangd --version"
    echo "  pylsp --version"
    echo "  rust-analyzer --version"
    echo ""
    echo "Neovim Testing:"
    echo "  vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/llvm-project/clang/lib/Basic/Targets.cpp')"
    echo "  vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/django/django/core/management/base.py')"
    echo "  vim.cmd('edit rsync://testuser@localhost:2222/home/testuser/repos/tokio/tokio/src/lib.rs')"
    echo ""
    echo "============================================="
}

# Show status
show_status() {
    echo ""
    echo "============================================="
    echo "📊 Container Status"
    echo "============================================="
    
    if docker ps -q -f name=$CONTAINER_NAME | grep -q .; then
        echo "✅ Container Status: RUNNING"
        echo "🔗 SSH Port: $SSH_PORT"
        
        # Test SSH connectivity
        if ssh -p $SSH_PORT -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $SSH_USER@$SSH_HOST echo "SSH Ready" 2>/dev/null; then
            echo "✅ SSH Status: ACCESSIBLE"
        else
            echo "❌ SSH Status: NOT ACCESSIBLE"
        fi
        
        # Show container resources
        echo ""
        echo "📈 Resource Usage:"
        docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" $CONTAINER_NAME 2>/dev/null || echo "Could not get stats"
        
    elif docker ps -aq -f name=$CONTAINER_NAME | grep -q .; then
        echo "⏸️  Container Status: STOPPED"
    else
        echo "❌ Container Status: NOT FOUND"
    fi
    
    echo ""
    echo "🏠 Available Commands:"
    echo "  ./build-docker.sh build     - Build the Docker image"
    echo "  ./build-docker.sh run       - Start the container"
    echo "  ./build-docker.sh stop      - Stop the container"
    echo "  ./build-docker.sh restart   - Restart the container"
    echo "  ./build-docker.sh connect   - Connect via SSH"
    echo "  ./build-docker.sh logs      - Show container logs"
    echo "  ./build-docker.sh status    - Show this status"
    echo "  ./build-docker.sh clean     - Clean up everything"
    echo "============================================="
}

# Main script logic
main() {
    check_docker
    
    case "${1:-run}" in
        "build")
            build_image
            ;;
        "run")
            start_container
            ;;
        "stop")
            stop_container
            ;;
        "restart")
            restart_container
            ;;
        "connect")
            connect_ssh
            ;;
        "logs")
            show_logs
            ;;
        "clean")
            clean_all
            ;;
        "status")
            show_status
            ;;
        "full")
            log "Full build and run..."
            build_image
            start_container
            ;;
        "help"|"-h"|"--help")
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  build     - Build the Docker image"
            echo "  run       - Start the container (default)"
            echo "  stop      - Stop the container"
            echo "  restart   - Restart the container"
            echo "  connect   - Connect to container via SSH"
            echo "  logs      - Show container logs"
            echo "  status    - Show container status"
            echo "  clean     - Clean up all Docker resources"
            echo "  full      - Build and run (clean setup)"
            echo "  help      - Show this help message"
            ;;
        *)
            error "Unknown command: $1"
            echo "Use '$0 help' for available commands"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"