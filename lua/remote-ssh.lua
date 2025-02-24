local M = {}

-- Global variables set by setup
local on_attach
local capabilities
local filetype_to_server
local custom_root_dir = nil

function M.setup(opts)
    on_attach = opts.on_attach or function(_, bufnr)
        vim.notify("LSP attached to buffer " .. bufnr, vim.log.levels.INFO)
    end
    capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()
    filetype_to_server = opts.filetype_to_server or {}
end

-- Function to get the directory of the current Lua script
local function get_script_dir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:sub(2)
    return vim.fn.fnamemodify(script_path, ":h")
end

-- Function to start LSP client for a netrw buffer
function M.start_remote_lsp(bufnr)

    vim.notify("Attempting to start remote LSP...", vim.log.levels.INFO)

    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("Invalid buffer: " .. bufnr, vim.log.levels.ERROR)
        return
    end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not bufname:match("^scp://") then
        return
    end

    local host, path = bufname:match("^scp://([^/]+)/(.+)$")
    if not host or not path then
        vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
        return
    end

    local root_dir
    if custom_root_dir then
        root_dir = custom_root_dir
    else
        local dir = vim.fn.fnamemodify(path, ":h")
        root_dir = "scp://" .. host .. "/" .. dir
    end

    local filetype = vim.bo[bufnr].filetype
    if not filetype or filetype == "" then
        vim.notify("No filetype detected for buffer " .. bufnr, vim.log.levels.WARN)
        return
    end

    local server_name = filetype_to_server[filetype]
    if not server_name then
        vim.notify("No LSP server for filetype: " .. filetype, vim.log.levels.WARN)
        return
    end

    local lsp_config = require('lspconfig')[server_name]
    local lsp_cmd = lsp_config.document_config.default_config.cmd
    if not lsp_cmd then
        vim.notify("No cmd defined for server: " .. server_name, vim.log.levels.ERROR)
        return
    end

    -- Extract just the binary name and arguments, not the full local path
    local binary_name = lsp_cmd[1]:match("([^/]+)$") -- Get the basename (e.g., "clangd")
    local lsp_args = { binary_name }
    for i = 2, #lsp_cmd do
        vim.notify("LSP args and command: " .. lsp_args .. " , " .. lsp_cmd[i], vim.log.levels.DEBUG)
        table.insert(lsp_args, lsp_cmd[i]) -- Add any additional arguments
    end

    local proxy_path = get_script_dir() .. "/proxy.py"
    local cmd = { "python3", "-u", proxy_path, host }
    vim.list_extend(cmd, lsp_args)

    vim.notify("Starting LSP with cmd: " .. table.concat(cmd, " "), vim.log.levels.INFO)

    for _, client in pairs(vim.lsp.get_active_clients({ bufnr = bufnr })) do
        if client.name == "remote_" .. server_name then
            vim.notify("Stopping existing client " .. client.id, vim.log.levels.DEBUG)
            vim.lsp.stop_client(client.id)
        end
    end

    local client_id = vim.lsp.start({
        name = "remote_" .. server_name,
        cmd = cmd,
        root_dir = root_dir,
        capabilities = capabilities,
        on_attach = function(client, attached_bufnr)
            on_attach(client, attached_bufnr)
            vim.notify("LSP client started successfully", vim.log.levels.INFO)
        end,
        filetypes = { filetype },
    })

    if client_id ~= nil then
        vim.notify("LSP client " .. client_id .. " initiated for buffer " .. bufnr, vim.log.levels.DEBUG)
        vim.lsp.buf_attach_client(bufnr, client_id)
    else
        vim.notify("Failed to start LSP client for " .. server_name, vim.log.levels.ERROR)
    end
end

-- User command to set custom root directory and restart LSP
vim.api.nvim_create_user_command(
    "SetRemoteLspRoot",
    function(opts)
        local bufnr = vim.api.nvim_get_current_buf()
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if not bufname:match("^scp://") then
            vim.notify("Not an scp:// buffer", vim.log.levels.ERROR)
            return
        end

        local host = bufname:match("^scp://([^/]+)/(.+)$")
        if not host then
            vim.notify("Invalid scp URL: " .. bufname, vim.log.levels.ERROR)
            return
        end

        local user_input = opts.args
        if user_input == "" then
            custom_root_dir = nil
            vim.notify("Reset remote LSP root to buffer-derived directory", vim.log.levels.INFO)
        else
            if not user_input:match("^/") then
                local current_dir = vim.fn.fnamemodify(bufname:match("^scp://[^/]+/(.+)$"), ":h")
                user_input = current_dir .. "/" .. user_input
            end
            custom_root_dir = "scp://" .. host .. "/" .. vim.fn.substitute(user_input, "//+", "/", "g")
            vim.notify("Set remote LSP root to " .. custom_root_dir, vim.log.levels.INFO)
        end

        M.start_remote_lsp(bufnr)
    end,
    {
        nargs = "?",
        desc = "Set the root directory for the remote LSP server (e.g., '/path/to/project')",
    }
)

vim.api.nvim_create_autocmd("BufNew", { --BufEnter
    pattern = "scp://*",
    callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        local filetype = vim.bo[bufnr].filetype

        -- If no filetype is detected, infer it from the extension
        if not filetype or filetype == "" then
            local ext = vim.fn.fnamemodify(bufname, ":e")
            local ext_to_ft = {
                c = "c",
                cpp = "cpp",
                cxx = "cpp",
                cc = "cpp",
                h = "c",
                hpp = "cpp",
                py = "python",
                rs = "rust",
            }
            filetype = ext_to_ft[ext] or ""
            if filetype ~= "" then
                vim.bo[bufnr].filetype = filetype
                vim.notify("Set filetype to " .. filetype .. " for buffer " .. bufnr, vim.log.levels.INFO)
            else
                vim.notify("No filetype detected or inferred for buffer " .. bufnr, vim.log.levels.WARN)
                return
            end
        end

        M.start_remote_lsp(bufnr)
    end,
})

return M
