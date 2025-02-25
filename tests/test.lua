vim.notify("Starting test...")

local cmd = 'ssh -o BatchMode=yes ianhersom@raspi0 echo test'
local success, reason, code = os.execute(cmd)

vim.notify("Command completed with success: " .. tostring(success) .. 
          ", reason: " .. tostring(reason) .. 
          ", code: " .. tostring(code))

vim.cmd([[sleep 2000m]])
vim.cmd([[quit]])
