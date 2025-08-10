-- Mock implementations for testing remote-ssh.nvim
local M = {}

-- Mock filesystem for testing
M.mock_fs = {
    files = {},
    directories = {},
}

-- Add a file to the mock filesystem
function M.mock_fs.add_file(path, content)
    M.mock_fs.files[path] = content or ""
end

-- Add a directory to the mock filesystem
function M.mock_fs.add_directory(path)
    M.mock_fs.directories[path] = true
end

-- Check if file exists in mock filesystem
function M.mock_fs.file_exists(path)
    return M.mock_fs.files[path] ~= nil
end

-- Check if directory exists in mock filesystem
function M.mock_fs.directory_exists(path)
    return M.mock_fs.directories[path] ~= nil
end

-- Clear mock filesystem
function M.mock_fs.clear()
    M.mock_fs.files = {}
    M.mock_fs.directories = {}
end

-- Get file content from mock filesystem
function M.mock_fs.get_file_content(path)
    return M.mock_fs.files[path]
end

-- Mock SSH commands
M.ssh_mock = {
    responses = {},
    call_log = {},
}

-- Set a response for a specific SSH command pattern
function M.ssh_mock.set_response(pattern, response)
    M.ssh_mock.responses[pattern] = response
end

-- Clear SSH mock responses and logs
function M.ssh_mock.clear()
    M.ssh_mock.responses = {}
    M.ssh_mock.call_log = {}
end

-- Mock vim.fn.system to intercept SSH calls
local original_system = vim and vim.fn and vim.fn.system or function()
    return ""
end
function M.ssh_mock.enable()
    vim.fn.system = function(cmd)
        table.insert(M.ssh_mock.call_log, cmd)

        -- Check for SSH command patterns
        for pattern, response in pairs(M.ssh_mock.responses) do
            if cmd:match(pattern) then
                return response
            end
        end

        -- Default response for unmatched SSH commands
        return ""
    end
end

function M.ssh_mock.disable()
    vim.fn.system = original_system
end

-- Get the log of SSH calls made during testing
function M.ssh_mock.get_call_log()
    return M.ssh_mock.call_log
end

-- Mock vim.fn.shellescape (since it's used in SSH commands)
local original_shellescape = vim and vim.fn and vim.fn.shellescape or function(str)
    return "'" .. str .. "'"
end
function M.mock_shellescape()
    vim.fn.shellescape = function(str)
        -- Simple shell escaping for testing
        return "'" .. str:gsub("'", "'\"'\"'") .. "'"
    end
end

function M.restore_shellescape()
    vim.fn.shellescape = original_shellescape
end

-- Helper function to create project structures in mock filesystem
function M.create_project_structure(structure)
    M.mock_fs.clear()

    local function process_structure(base_path, items)
        for name, value in pairs(items) do
            local full_path = base_path .. "/" .. name

            if type(value) == "table" then
                -- It's a directory with contents
                M.mock_fs.add_directory(full_path)
                process_structure(full_path, value)
            elseif type(value) == "string" then
                -- It's a file with content
                M.mock_fs.add_file(full_path, value)
            else
                -- It's an empty directory or file
                if name:match("/$") then
                    M.mock_fs.add_directory(full_path:sub(1, -2))
                else
                    M.mock_fs.add_file(full_path, "")
                end
            end
        end
    end

    process_structure("", structure)
end

-- Helper to setup common project structures
M.project_fixtures = {}

-- Rust workspace fixture
M.project_fixtures.rust_workspace = {
    [".git"] = {},
    ["Cargo.toml"] = '[workspace]\nmembers = ["crate1", "crate2"]\n',
    ["crate1"] = {
        ["Cargo.toml"] = '[package]\nname = "crate1"\n',
        ["src"] = {
            ["lib.rs"] = "// lib.rs content\n",
            ["main.rs"] = "fn main() {}\n",
        },
    },
    ["crate2"] = {
        ["Cargo.toml"] = '[package]\nname = "crate2"\n',
        ["src"] = {
            ["lib.rs"] = "// lib.rs content\n",
        },
    },
}

-- C++ project with CMake
M.project_fixtures.cpp_cmake = {
    [".git"] = {},
    ["CMakeLists.txt"] = "cmake_minimum_required(VERSION 3.10)\nproject(MyProject)\n",
    ["compile_commands.json"] = "[]",
    ["src"] = {
        ["main.cpp"] = "#include <iostream>\nint main() { return 0; }\n",
        ["utils.cpp"] = "// utils implementation\n",
        ["utils.h"] = "// utils header\n",
    },
    ["include"] = {
        ["myproject.h"] = "// main header\n",
    },
}

-- Python project
M.project_fixtures.python_project = {
    [".git"] = {},
    ["pyproject.toml"] = '[tool.poetry]\nname = "myproject"\n',
    ["requirements.txt"] = "requests==2.25.1\n",
    ["src"] = {
        ["myproject"] = {
            ["__init__.py"] = "",
            ["main.py"] = "def main(): pass\n",
        },
    },
    ["tests"] = {
        ["test_main.py"] = "def test_main(): pass\n",
    },
}

-- JavaScript/TypeScript project
M.project_fixtures.js_project = {
    [".git"] = {},
    ["package.json"] = '{"name": "myproject", "version": "1.0.0"}',
    ["tsconfig.json"] = '{"compilerOptions": {"target": "es2020"}}',
    ["src"] = {
        ["index.ts"] = "console.log('hello world');\n",
        ["utils.js"] = "export function utils() {}\n",
    },
}

return M
