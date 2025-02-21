local M = {}

-- Function to get the directory of the current Lua script
local function get_script_dir()
    -- Use debug.getinfo to get the source file path
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2) -- Remove '@' prefix from source path
    return vim.fn.fnamemodify(script_path, ":h") -- Get directory of the script
end

-- Function to start LSP client for a netrw buffer
function M.start_remote_lsp(bufnr)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    -- Check if it's a netrw buffer with scp protocol
    if not bufname:match("^scp://") then
        return
    end

    -- Extract host (user@remote) and path
    local host, path = bufname:match("^scp://([^/]+)/(.+)$")
    if not host or not path then
        vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
        return
    end

    -- Get the directory of the file for root_dir
    local dir = vim.fn.fnamemodify(path, ":h")
    local root_dir = "scp://" .. host .. "/" .. dir

    -- Construct path to proxy.py relative to this Lua script
    local script_dir = get_script_dir()
    local proxy_path = script_dir .. "/proxy.py"

    -- Debugging: Print paths to verify
    print("Script directory: " .. script_dir)
    print("Proxy path: " .. proxy_path)

    -- Command to start the LSP client
    local cmd = {"python3", "-u", proxy_path, host} -- -u for unbuffered output

    -- Start the LSP client
    local client_id = vim.lsp.start({
        name = "remote_clangd",
        cmd = cmd,
        root_dir = root_dir,
        filetypes = {"c", "cpp", "cxx", "cc"},
        init_options = {
            clangdFileStatus = true,
        },
        capabilities = vim.lsp.protocol.make_client_capabilities(),
    })

    if client_id then
        vim.lsp.buf_attach_client(bufnr, client_id)
        vim.notify("Attached remote clangd to buffer", vim.log.levels.INFO)
    else
        vim.notify("Failed to start remote clangd client", vim.log.levels.ERROR)
    end
end

-- Set up autocommand for netrw buffers
vim.api.nvim_create_autocmd("BufEnter", {
    pattern = "scp://*",
    callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        local filetype = vim.bo[bufnr].filetype
        -- Only attach for C/C++ filetypes
        if vim.tbl_contains({"c", "cpp", "cxx", "cc"}, filetype) then
            M.start_remote_lsp(bufnr)
        end
    end,
})

return M
