local M = {}

-- Global variables set by setup
local on_attach
local capabilities
local filetype_to_server
-- Global variable for custom root directory
local custom_root_dir = nil

function M.setup(opts)
    -- Pass in and set as global
    on_attach = opts.on_attach or function() end
    capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()
    filetype_to_server = opts.filetype_to_server or {}
end

-- Function to get the directory of the current Lua script
local function get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2) -- Remove '@' prefix from source path
    return vim.fn.fnamemodify(script_path, ":h") -- Get directory of the script
end

-- Function to start LSP client for a netrw buffer
function M.start_remote_lsp(bufnr)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not bufname:match("^scp://") then
        return
    end

    -- Extract host (user@remote) and path
    local host, path = bufname:match("^scp://([^/]+)/(.+)$")
    if not host or not path then
        vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
        return
    end

    -- Use custom_root_dir if set, otherwise derive from buffer path
    local root_dir
    if custom_root_dir then
        root_dir = custom_root_dir
    else
        local dir = vim.fn.fnamemodify(path, ":h")
        root_dir = "scp://" .. host .. "/" .. dir
    end

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

    -- Stop any existing client for this buffer to avoid duplicates
    for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr })) do
        if client.name == "remote_" .. server_name then
            vim.lsp.stop_client(client.id)
        end
    end

    local client_id = vim.lsp.start({
        name = "remote_" .. server_name,
        cmd = cmd,
        root_dir = root_dir,
        capabilities = capabilities,
        on_attach = on_attach,
    })
    if client_id then
        vim.lsp.buf_attach_client(bufnr, client_id)
        vim.notify("Attached remote " .. server_name .. " to buffer with root " .. root_dir, vim.log.levels.INFO)
    else
        vim.notify("Failed to start remote " .. server_name, vim.log.levels.ERROR)
    end
end

-- User command to set custom root directory and optionally restart LSP
vim.api.nvim_create_user_command(
    "SetRemoteLspRoot",
    function(opts)
        local bufnr = vim.api.nvim_get_current_buf()
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if not bufname:match("^scp://") then
            vim.notify("Not an scp:// buffer", vim.log.levels.ERROR)
            return
        end

        -- Extract host from current buffer
        local host = bufname:match("^scp://([^/]+)/(.+)$")
        if not host then
            vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
            return
        end

        -- Validate and set the custom root directory
        local user_input = opts.args
        if user_input == "" then
            custom_root_dir = nil -- Reset to default behavior
            vim.notify("Reset remote LSP root to buffer-derived directory", vim.log.levels.INFO)
        else
            -- Ensure the input is a valid path (relative or absolute)
            if not user_input:match("^/") then
                -- Convert relative path to absolute based on current buffer's directory
                local current_dir = vim.fn.fnamemodify(bufname:match("^scp://[^/]+/(.+)$"), ":h")
                user_input = current_dir .. "/" .. user_input
            end
            custom_root_dir = "scp://" .. host .. "/" .. vim.fn.substitute(user_input, "//+", "/", "g")
            vim.notify("Set remote LSP root to " .. custom_root_dir, vim.log.levels.INFO)
        end

        -- Restart LSP for the current buffer
        M.start_remote_lsp(bufnr)
    end,
    {
        nargs = "?", -- Optional argument for the root directory
        desc = "Set the root directory for the remote LSP server (e.g., '/path/to/project')",
    }
)

vim.api.nvim_create_autocmd("BufNew", {
    pattern = "scp://*",
    callback = function()
        M.start_remote_lsp(vim.api.nvim_get_current_buf())
    end,
})

return M
