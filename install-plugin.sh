#!/bin/bash -e

# Detect OS and set appropriate Neovim data directory
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    NVIM_DATA_DIR="$HOME/.local/share/nvim"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    if [[ -n "$XDG_DATA_HOME" ]]; then
        NVIM_DATA_DIR="$XDG_DATA_HOME/nvim"
    else
        NVIM_DATA_DIR="$HOME/.local/share/nvim"
    fi
else
    echo "Unsupported OS: $OSTYPE"
    exit 1
fi

PLUGIN_DIR="$NVIM_DATA_DIR/lazy/remote-ssh.nvim"

# Create plugin directory if it doesn't exist
mkdir -p "$PLUGIN_DIR"

# Remove existing plugin files
if [[ -d "$PLUGIN_DIR" ]]; then
    echo "Removing existing plugin files from $PLUGIN_DIR"
    rm -rf "$PLUGIN_DIR"/*
else
    echo "Creating plugin directory: $PLUGIN_DIR"
fi

# Copy all files except hidden ones and the install script itself
echo "Installing plugin to $PLUGIN_DIR"
find . -maxdepth 1 -type f ! -name ".*" ! -name "install-plugin.sh" -exec cp {} "$PLUGIN_DIR/" \;

# Copy directories
for dir in lua tests docs images; do
    if [[ -d "$dir" ]]; then
        echo "Copying $dir directory"
        cp -r "$dir" "$PLUGIN_DIR/"
    fi
done

echo "Plugin installation complete!"
