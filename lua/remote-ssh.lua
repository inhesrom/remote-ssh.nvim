local M = {}

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

    -- Check if there's already a client for this root_dir
    -- Neovim's LSP client handles deduplication based on root_dir
    local client_id = vim.lsp.start({
        name = "remote_clangd",
        cmd = {"python3", vim.fn.stdpath("config") .. "/lua/remote-clangd/proxy.py", host},
        root_dir = root_dir,
        filetypes = {"c", "cpp", "cxx", "cc"},
        -- Additional configurations (optional)
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
