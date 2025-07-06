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

# Install Rust and Cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install rust-analyzer
RUN curl -L https://github.com/rust-analyzer/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-unknown-linux-gnu.gz | gunzip -c > /usr/local/bin/rust-analyzer && \
    chmod +x /usr/local/bin/rust-analyzer

# Install Python LSP Server
RUN pip3 install python-lsp-server[all] python-lsp-black python-lsp-isort

# Create SSH user and setup
RUN useradd -rm -d /home/testuser -s /bin/bash -g root -G sudo -u 1000 testuser
RUN echo 'testuser:testpassword' | chpasswd
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

# Create additional test files for better LSP testing
RUN mkdir -p /home/testuser/test-files

# Create a C++ test file with CMakeLists.txt
RUN echo 'cmake_minimum_required(VERSION 3.10)' > /home/testuser/test-files/CMakeLists.txt && \
    echo 'project(TestProject)' >> /home/testuser/test-files/CMakeLists.txt && \
    echo '' >> /home/testuser/test-files/CMakeLists.txt && \
    echo 'set(CMAKE_CXX_STANDARD 17)' >> /home/testuser/test-files/CMakeLists.txt && \
    echo 'set(CMAKE_EXPORT_COMPILE_COMMANDS ON)' >> /home/testuser/test-files/CMakeLists.txt && \
    echo '' >> /home/testuser/test-files/CMakeLists.txt && \
    echo 'add_executable(test_app main.cpp utils.cpp)' >> /home/testuser/test-files/CMakeLists.txt && \
    echo 'target_include_directories(test_app PRIVATE include)' >> /home/testuser/test-files/CMakeLists.txt

# Create C++ files
RUN printf '#include <iostream>\n#include <vector>\n#include <string>\n#include "utils.h"\n\nint main() {\n    std::vector<std::string> items = {"hello", "world", "test"};\n    \n    for (const auto& item : items) {\n        std::cout << process_string(item) << std::endl;\n    }\n    \n    return 0;\n}' > /home/testuser/test-files/main.cpp

RUN printf '#include "utils.h"\n#include <algorithm>\n#include <cctype>\n\nstd::string process_string(const std::string& input) {\n    std::string result = input;\n    std::transform(result.begin(), result.end(), result.begin(), ::toupper);\n    return result;\n}' > /home/testuser/test-files/utils.cpp

RUN mkdir -p /home/testuser/test-files/include && \
    printf '#pragma once\n#include <string>\n\nstd::string process_string(const std::string& input);' > /home/testuser/test-files/include/utils.h

# Create Python test files
RUN printf '#!/usr/bin/env python3\n"""\nTest Python file for LSP testing\n"""\n\nimport json\nimport sys\nfrom typing import List, Dict, Optional\nfrom utils import process_data, DataProcessor\n\ndef main():\n    """Main function to demonstrate Python LSP features"""\n    data = [\n        {"name": "Alice", "age": 30, "city": "New York"},\n        {"name": "Bob", "age": 25, "city": "San Francisco"},\n        {"name": "Charlie", "age": 35, "city": "Chicago"}\n    ]\n    \n    processor = DataProcessor()\n    results = processor.process_multiple(data)\n    \n    for result in results:\n        print(json.dumps(result, indent=2))\n\nif __name__ == "__main__":\n    main()' > /home/testuser/test-files/main.py

RUN printf '"""\nUtility functions for data processing\n"""\n\nfrom typing import List, Dict, Any, Optional\nimport json\n\ndef process_data(data: Dict[str, Any]) -> Dict[str, Any]:\n    """Process a single data item"""\n    result = data.copy()\n    result["processed"] = True\n    result["name_upper"] = data.get("name", "").upper()\n    return result\n\nclass DataProcessor:\n    """Class for processing data items"""\n    \n    def __init__(self):\n        self.processed_count = 0\n    \n    def process_single(self, item: Dict[str, Any]) -> Dict[str, Any]:\n        """Process a single item"""\n        result = process_data(item)\n        self.processed_count += 1\n        return result\n    \n    def process_multiple(self, items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:\n        """Process multiple items"""\n        return [self.process_single(item) for item in items]\n    \n    def get_stats(self) -> Dict[str, int]:\n        """Get processing statistics"""\n        return {"processed_count": self.processed_count}' > /home/testuser/test-files/utils.py

# Create Rust test files
RUN printf '[package]\nname = "test-rust-project"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nserde = { version = "1.0", features = ["derive"] }\nserde_json = "1.0"' > /home/testuser/test-files/Cargo.toml

RUN printf 'use serde::{Deserialize, Serialize};\nuse std::collections::HashMap;\n\nmod utils;\nuse utils::{process_data, DataProcessor};\n\n#[derive(Debug, Serialize, Deserialize)]\nstruct Person {\n    name: String,\n    age: u32,\n    city: String,\n}\n\n#[derive(Debug, Serialize, Deserialize)]\nstruct ProcessedPerson {\n    name: String,\n    age: u32,\n    city: String,\n    processed: bool,\n    name_upper: String,\n}\n\nfn main() -> Result<(), Box<dyn std::error::Error>> {\n    let people = vec![\n        Person {\n            name: "Alice".to_string(),\n            age: 30,\n            city: "New York".to_string(),\n        },\n        Person {\n            name: "Bob".to_string(),\n            age: 25,\n            city: "San Francisco".to_string(),\n        },\n        Person {\n            name: "Charlie".to_string(),\n            age: 35,\n            city: "Chicago".to_string(),\n        },\n    ];\n    \n    let mut processor = DataProcessor::new();\n    let results = processor.process_multiple(people);\n    \n    for result in results {\n        println!("{}", serde_json::to_string_pretty(&result)?);\n    }\n    \n    println!("Stats: {:?}", processor.get_stats());\n    \n    Ok(())\n}' > /home/testuser/test-files/main.rs

RUN printf 'use serde::{Deserialize, Serialize};\n\n#[derive(Debug, Serialize, Deserialize)]\npub struct Person {\n    pub name: String,\n    pub age: u32,\n    pub city: String,\n}\n\n#[derive(Debug, Serialize, Deserialize)]\npub struct ProcessedPerson {\n    pub name: String,\n    pub age: u32,\n    pub city: String,\n    pub processed: bool,\n    pub name_upper: String,\n}\n\npub fn process_data(person: Person) -> ProcessedPerson {\n    ProcessedPerson {\n        name: person.name.clone(),\n        age: person.age,\n        city: person.city,\n        processed: true,\n        name_upper: person.name.to_uppercase(),\n    }\n}\n\npub struct DataProcessor {\n    pub processed_count: u32,\n}\n\nimpl DataProcessor {\n    pub fn new() -> Self {\n        Self { processed_count: 0 }\n    }\n    \n    pub fn process_single(&mut self, person: Person) -> ProcessedPerson {\n        let result = process_data(person);\n        self.processed_count += 1;\n        result\n    }\n    \n    pub fn process_multiple(&mut self, people: Vec<Person>) -> Vec<ProcessedPerson> {\n        people.into_iter()\n            .map(|person| self.process_single(person))\n            .collect()\n    }\n    \n    pub fn get_stats(&self) -> std::collections::HashMap<String, u32> {\n        let mut stats = std::collections::HashMap::new();\n        stats.insert("processed_count".to_string(), self.processed_count);\n        stats\n    }\n}' > /home/testuser/test-files/utils.rs

# Generate compile_commands.json for C++ project
RUN cd /home/testuser/test-files && \
    mkdir -p build && \
    cd build && \
    cmake .. && \
    make

# Build the Rust project to generate Cargo.lock and target directory
RUN cd /home/testuser/test-files && \
    cargo build

# Set ownership of all files to testuser
RUN chown -R testuser:root /home/testuser

# Create a startup script that runs both SSH and keeps container alive
RUN printf '#!/bin/bash\n# Start SSH daemon\n/usr/sbin/sshd -D &\n\n# Keep container running\ntail -f /dev/null' > /start.sh && \
    chmod +x /start.sh

# Create helpful README
RUN printf '# Remote LSP Testing Container\n\nThis container is set up for testing remote LSP functionality with multiple language servers and real-world codebases.\n\n## Connection Information\n- SSH User: testuser\n- SSH Password: testpassword\n- SSH Port: 22\n\n## Available Language Servers\n- **clangd**: C/C++ language server\n- **pylsp**: Python LSP server  \n- **rust-analyzer**: Rust language server\n\n## Test Repositories (Large, Real-World Projects)\n\n### C++ Projects (`/home/testuser/repos/`)\n- **llvm-project**: LLVM/Clang subset - excellent for clangd testing\n- **Catch2**: Modern C++ testing framework\n- **json**: nlohmann/json header-only library\n\n### Python Projects (`/home/testuser/repos/`)\n- **django**: Full web framework with complex architecture\n- **flask**: Micro web framework\n- **fastapi**: Modern async web framework\n- **requests**: HTTP library\n\n### Rust Projects (`/home/testuser/repos/`)\n- **tokio**: Async runtime ecosystem\n- **serde**: Serialization framework\n- **clap**: Command line argument parser\n- **actix-web**: Actor-based web framework\n- **Rocket**: Type-safe web framework\n\n### Custom Test Files (`/home/testuser/test-files/`)\n- Minimal but complete projects for each language\n- Designed to trigger specific LSP features\n\n## Neovim Remote Testing\n```lua\n-- Large C++ file with complex includes\nvim.cmd("edit rsync://testuser@localhost:2222/home/testuser/repos/llvm-project/clang/lib/Basic/Targets.cpp")\n\n-- Django model with complex inheritance  \nvim.cmd("edit rsync://testuser@localhost:2222/home/testuser/repos/django/django/db/models/base.py")\n\n-- Tokio async runtime code\nvim.cmd("edit rsync://testuser@localhost:2222/home/testuser/repos/tokio/tokio/src/lib.rs")\n```' > /home/testuser/README.md

# Expose SSH port
EXPOSE 22

# Set working directory
WORKDIR /home/testuser

# Start SSH daemon and keep container running
CMD ["/start.sh"]