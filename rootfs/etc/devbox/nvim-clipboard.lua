-- Wird über $VIM/sysinit.vim geladen (vor der Nutzer-Config, unabhängig vom
-- Runtimepath, den lazy.nvim zurücksetzt).
-- Im Container gibt es weder win32yank noch wl-copy/xclip. Kopieren läuft
-- deshalb über OSC 52 an das Terminal des Hosts; Einfügen liefert das
-- unbenannte Register zurück, damit p/P weiter funktionieren.
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
