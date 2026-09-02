local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

-- snacks.nvim is a hard dependency; specs run against the real plugin pinned
-- to the commit the hover was built against (CI caches the clone by this ref).
local snacks_dir = os.getenv("SNACKS_DIR") or "/tmp/snacks.nvim"
local snacks_ref = os.getenv("SNACKS_REF") or "882c996cf28183f4d63640de0b4c02ec886d01f2"
if vim.fn.isdirectory(snacks_dir) == 0 then
  vim.fn.system({ "git", "clone", "https://github.com/folke/snacks.nvim", snacks_dir })
end
vim.fn.system({ "git", "-C", snacks_dir, "checkout", "--quiet", snacks_ref })

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)
vim.opt.rtp:append(snacks_dir)

local ok, snacks = pcall(require, "snacks")
if not ok then
  error("tests: snacks.nvim could not be loaded from " .. snacks_dir .. ": " .. tostring(snacks))
end
-- Keep vim.notify / vim.ui.input untouched so specs observe the notifier
-- through its own history and never block on a prompt.
if not vim.g.metaphrast_snacks_setup then
  snacks.setup({ notifier = { enabled = false }, input = { enabled = false } })
  vim.api.nvim_set_var("metaphrast_snacks_setup", true)
end

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
-- plenary spawns specs with --noplugin, so the user commands and <Plug> mapping
-- only exist when the plugin file is sourced explicitly.
vim.cmd("runtime plugin/metaphrast.lua")
