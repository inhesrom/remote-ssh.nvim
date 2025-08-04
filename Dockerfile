FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install system dependencies
RUN apt-get update && apt-get install -y \
    # SSH server
    openssh-server \
    # Build tools and development packages
    build-essential \
    cmake \
    pkg-config \
    # Python and pip
    python3 \
    python3-pip \
    python3-venv \
    # Rust dependencies
    curl \
    # C++ development
    clang \
    clangd \
    # Version control
    git \
    # Network tools
    wget \
    # Text processing
    jq \
    # Process management
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# Install common Linux tools separately to ensure they get installed
RUN apt-get update && apt-get install -y \
    rsync \
    openssh-client \
    findutils \
    grep \
    sed \
    gawk \
    tar \
    gzip \
    unzip \
    zip \
    less \
    util-linux \
    nano \
    vim \
    tree \
    htop \
    procps \
    net-tools \
    iputils-ping \
    telnet \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install Rust and Cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install rust-analyzer (detect architecture)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        RUST_ANALYZER_ARCH="x86_64-unknown-linux-gnu"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        RUST_ANALYZER_ARCH="aarch64-unknown-linux-gnu"; \
    else \
        echo "Unsupported architecture: $ARCH"; exit 1; \
    fi && \
    curl -L "https://github.com/rust-analyzer/rust-analyzer/releases/latest/download/rust-analyzer-${RUST_ANALYZER_ARCH}.gz" | gunzip -c > /usr/local/bin/rust-analyzer && \
    chmod +x /usr/local/bin/rust-analyzer

# Install Python LSP Server
RUN pip3 install python-lsp-server[all] python-lsp-black python-lsp-isort

# Create SSH user and setup
RUN useradd -rm -d /home/testuser -s /bin/bash -g root -G sudo -u 1000 testuser
RUN echo 'testuser:testpassword' | chpasswd
RUN echo 'root:rootpassword' | chpasswd
RUN mkdir -p /home/testuser/.ssh && \
    chown testuser:root /home/testuser/.ssh && \
    chmod 700 /home/testuser/.ssh

# Configure SSH
RUN mkdir /var/run/sshd && \
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
    echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config && \
    echo 'Port 22' >> /etc/ssh/sshd_config && \
    sed -i 's/#X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config

# Create workspace directories
RUN mkdir -p /home/testuser/repos
WORKDIR /home/testuser/repos

# Clone popular, complex test repositories for comprehensive LSP testing

# C++ Projects - Large, real-world codebases
# LLVM Project (subset) - Excellent for testing clangd
RUN git clone --depth 1 --filter=blob:none --sparse https://github.com/llvm/llvm-project.git && \
    cd llvm-project && \
    git sparse-checkout set clang/lib/Basic clang/include/clang/Basic llvm/include/llvm/Support && \
    mkdir -p build && \
    cd build && \
    cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON ../llvm && \
    make -j2 || true  # May fail but will generate compile_commands.json

# Catch2 - Modern C++ testing framework
RUN git clone --depth 1 https://github.com/catchorg/Catch2.git && \
    cd Catch2 && \
    mkdir build && \
    cd build && \
    cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON .. && \
    make -j2

# nlohmann/json - Header-only JSON library
RUN git clone --depth 1 https://github.com/nlohmann/json.git && \
    cd json && \
    mkdir build && \
    cd build && \
    cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON .. && \
    make -j2

# Python Projects - Large, well-structured Python codebases
# Django - Web framework with complex architecture
RUN git clone --depth 1 https://github.com/django/django.git && \
    cd django && \
    python3 -m pip install -e . && \
    python3 -m pip install -r requirements/py3.txt || true

# Flask - Micro web framework
RUN git clone --depth 1 https://github.com/pallets/flask.git && \
    cd flask && \
    python3 -m pip install -e .

# FastAPI - Modern async web framework
RUN git clone --depth 1 https://github.com/tiangolo/fastapi.git && \
    cd fastapi && \
    python3 -m pip install -e .

# Requests - HTTP library
RUN git clone --depth 1 https://github.com/psf/requests.git && \
    cd requests && \
    python3 -m pip install -e .

# Rust Projects - Complex Rust ecosystems
# Tokio - Async runtime
RUN git clone --depth 1 https://github.com/tokio-rs/tokio.git && \
    cd tokio && \
    cargo build || true  # May take a while, continue even if it times out

# Serde - Serialization framework
RUN git clone --depth 1 https://github.com/serde-rs/serde.git && \
    cd serde && \
    cargo build

# Clap - Command line parser
RUN git clone --depth 1 https://github.com/clap-rs/clap.git && \
    cd clap && \
    cargo build

# Actix-web - Web framework
RUN git clone --depth 1 https://github.com/actix/actix-web.git && \
    cd actix-web && \
    cargo build || true

# Rocket - Web framework
RUN git clone --depth 1 https://github.com/rwf2/Rocket.git && \
    cd Rocket && \
    cargo build || true

# Set ownership of all files to testuser
RUN chown -R testuser:root /home/testuser

# Create a startup script that runs both SSH and keeps container alive
RUN printf '#!/bin/bash\n# Start SSH daemon\n/usr/sbin/sshd -D &\n\n# Keep container running\ntail -f /dev/null' > /start.sh && \
    chmod +x /start.sh

# Create helpful README
RUN printf '# Remote LSP Testing Container\n\nThis container is set up for testing remote LSP functionality with multiple language servers and real-world codebases.\n\n## Connection Information\n- SSH User: testuser\n- SSH Password: testpassword\n- SSH Port: 22\n\n## Available Language Servers\n- **clangd**: C/C++ language server\n- **pylsp**: Python LSP server  \n- **rust-analyzer**: Rust language server\n\n## Test Repositories (Large, Real-World Projects)\n\n### C++ Projects (`/home/testuser/repos/`)\n- **llvm-project**: LLVM/Clang subset - excellent for clangd testing\n- **Catch2**: Modern C++ testing framework\n- **json**: nlohmann/json header-only library\n\n### Python Projects (`/home/testuser/repos/`)\n- **django**: Full web framework with complex architecture\n- **flask**: Micro web framework\n- **fastapi**: Modern async web framework\n- **requests**: HTTP library\n\n### Rust Projects (`/home/testuser/repos/`)\n- **tokio**: Async runtime ecosystem\n- **serde**: Serialization framework\n- **clap**: Command line argument parser\n- **actix-web**: Actor-based web framework\n- **Rocket**: Type-safe web framework\n\n## Neovim Remote Testing\n```lua\n-- Large C++ file with complex includes\nvim.cmd("edit rsync://testuser@localhost:2222/home/testuser/repos/llvm-project/clang/lib/Basic/Targets.cpp")\n\n-- Django model with complex inheritance  \nvim.cmd("edit rsync://testuser@localhost:2222/home/testuser/repos/django/django/db/models/base.py")\n\n-- Tokio async runtime code\nvim.cmd("edit rsync://testuser@localhost:2222/home/testuser/repos/tokio/tokio/src/lib.rs")\n```' > /home/testuser/README.md

# Expose SSH port
EXPOSE 22

# Set working directory
WORKDIR /home/testuser

# Start SSH daemon and keep container running
CMD ["/start.sh"]
