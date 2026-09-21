-- Loaded via $VIM/sysinit.vim (before the user config, and independent of the
-- runtimepath that lazy.nvim resets).
-- The container has neither win32yank nor wl-copy/xclip, so copying goes to the
-- host's terminal via OSC 52; pasting returns the unnamed register so that p/P
-- keep working.
if vim.g.clipboard ~= nil then return end
if vim.fn.executable("wl-copy") == 1 or vim.fn.executable("xclip") == 1 then return end

local osc52 = require("vim.ui.clipboard.osc52")
local function paste()
  return { vim.fn.split(vim.fn.getreg('"'), "\n"), vim.fn.getregtype('"') }
end
vim.g.clipboard = {
  name = "devbox OSC 52",
  copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
  paste = { ["+"] = paste, ["*"] = paste },
}
