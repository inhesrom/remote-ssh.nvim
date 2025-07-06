#!/bin/bash

# Script to set up SSH keys for passwordless access to the remote LSP test container

set -e

# Configuration
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
CONTAINER_HOST="localhost"
CONTAINER_PORT="22"
CONTAINER_USER="testuser"
CONTAINER_PASSWORD="testpassword"

echo "Setting up SSH keys for remote LSP test container..."

# Check if SSH key exists, if not create one
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "SSH key not found. Generating new SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "remote-lsp-test-$(date +%Y%m%d)"
    echo "SSH key pair generated at $SSH_KEY_PATH"
else
    echo "SSH key already exists at $SSH_KEY_PATH"
fi

# Wait for container to be ready
echo "Waiting for container to be ready..."
max_attempts=30
attempt=0
while ! nc -z $CONTAINER_HOST $CONTAINER_PORT 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ $attempt -ge $max_attempts ]; then
        echo "Error: Container did not become ready within $max_attempts attempts"
        exit 1
    fi
    echo "Waiting for SSH service... (attempt $attempt/$max_attempts)"
    sleep 2
done

echo "Container is ready. Setting up SSH key..."

# Check if sshpass is available for automated password input
if command -v sshpass >/dev/null 2>&1; then
    echo "Using sshpass for automated key copying..."
    sshpass -p "$CONTAINER_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST
else
    echo "sshpass not found. Please install it or manually copy the SSH key."
    echo "Run: ssh-copy-id -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST"
    echo "Password: $CONTAINER_PASSWORD"
    
    # Try manual approach
    echo "Attempting manual key copy..."
    ssh-copy-id -o StrictHostKeyChecking=no -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST || {
        echo "Manual key copy failed. You may need to enter the password manually."
        echo "After the container is running, execute:"
        echo "ssh-copy-id -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST"
        exit 1
    }
fi

# Test the connection
echo "Testing passwordless SSH connection..."
if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST "echo 'SSH key setup successful!'" 2>/dev/null; then
    echo "✅ SSH key setup completed successfully!"
    echo "You can now connect without a password using:"
    echo "ssh -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST"
else
    echo "❌ SSH key setup may have failed. Please try manually:"
    echo "ssh-copy-id -p $CONTAINER_PORT $CONTAINER_USER@$CONTAINER_HOST"
fi