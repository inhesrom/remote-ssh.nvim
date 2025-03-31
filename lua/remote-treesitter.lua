local M = {}

local async_write = require('async-remote-write')
local log = async_write.log

-- Setup TreeSitter highlighting for remote buffers
function M.setup_treesitter_highlighting()
    local ts_remote_group = vim.api.nvim_create_augroup("RemoteLspTreeSitter", { clear = true })

    vim.api.nvim_create_autocmd("BufReadPost", {
        pattern = {"scp://*", "rsync://*"},
        group = ts_remote_group,
        callback = function(ev)
            local bufnr = ev.buf

            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then
                    local filetype = vim.bo[bufnr].filetype

                    if not filetype or filetype == "" then
                        local bufname = vim.api.nvim_buf_get_name(bufnr)
                        local ext = vim.fn.fnamemodify(bufname, ":e")

                        if ext and ext ~= "" then
                            vim.filetype.match({ filename = bufname })
                        end

                        filetype = vim.bo[bufnr].filetype
                    end

                    if filetype and filetype ~= "" then
                        vim.defer_fn(function()
                            if vim.api.nvim_buf_is_valid(bufnr) then
                                pcall(vim.cmd, "TSBufEnable highlight")

                                if vim.treesitter then
                                    local has_lang = pcall(function()
                                        return vim.treesitter.language.get_lang(filetype) ~= nil
                                    end)

                                    if has_lang then
                                        pcall(vim.treesitter.start, bufnr, filetype)
                                    end
                                end
                            end
                        end, 200)
                    end
                end
            end)
        end,
    })

    vim.api.nvim_create_user_command("TSRemoteHighlight", function()
        local bufnr = vim.api.nvim_get_current_buf()
        local filetype = vim.bo[bufnr].filetype

        if not filetype or filetype == "" then
            log("No filetype detected for buffer", vim.log.levels.WARN, true)
            return
        end

        local success = pcall(vim.cmd, "TSBufEnable highlight")

        if not success and vim.treesitter then
            local has_lang = pcall(function()
                return vim.treesitter.language.get_lang(filetype) ~= nil
            end)

            if has_lang then
                log("Manually attaching TreeSitter for " .. filetype, vim.log.levels.INFO, true)
                pcall(vim.treesitter.start, bufnr, filetype)
            else
                log("No TreeSitter parser found for " .. filetype, vim.log.levels.WARN, true)
            end
        else
            log("TreeSitter highlighting enabled", vim.log.levels.INFO, true)
        end
    end, {
        desc = "Manually enable TreeSitter highlighting for remote buffers"
    })
end

function M.setup()
    M.setup_treesitter_highlighting()
end

return M
