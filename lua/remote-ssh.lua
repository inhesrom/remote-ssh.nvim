local M = {}

function M.setup(opts)
    --pass in and set as global
    on_attach = opts.on_attach or function() end
    capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()
    filetype_to_server = opts.filetype_to_server or {}
end

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

    local dir = vim.fn.fnamemodify(path, ":h")
    local root_dir = "scp://" .. host .. "/" .. dir
    local filetype = vim.bo[bufnr].filetype
    local server_name = filetype_to_server[filetype]
    if not server_name then
        vim.notify("No LSP server for filetype: " .. filetype, vim.log.levels.WARN)
        return
    end

    local lsp_cmd = require('lspconfig')[server_name].document_config.default_config.cmd
    if not lsp_cmd then
        vim.notify("No cmd for server: " .. server_name, vim.log.levels.ERROR)
        return
    end
    local proxy_path = get_script_dir() .. "/proxy.py"
    local cmd = { "python3", "-u", proxy_path, host }
    vim.list_extend(cmd, lsp_cmd)

    local client_id = vim.lsp.start({
        name = "remote_" .. server_name,
        cmd = cmd,
        root_dir = root_dir,
        capabilities = capabilities,
        on_attach = on_attach,
    })
    if client_id then
        vim.lsp.buf_attach_client(bufnr, client_id)
        vim.notify("Attached remote " .. server_name .. " to buffer", vim.log.levels.INFO)
    else
        vim.notify("Failed to start remote " .. server_name, vim.log.levels.ERROR)
    end
end

vim.api.nvim_create_autocmd("BufEnter", {
    pattern = "scp://*",
    callback = function()
        M.start_remote_lsp(vim.api.nvim_get_current_buf())
    end,
})

return M
