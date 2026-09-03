---Abort the whole Neovim process with a message on stderr.
---`error()` here would only unwind this file: the harness then runs
---`PlenaryBustedDirectory` as an unknown command (E492) and headless Neovim
---hangs with nothing to quit on, so CI burns its job timeout instead of
---reporting the failure.
---@param msg string
local function die(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

---Clone a test dependency into `dir` when it is not already there.
---
---The clone tracks whatever the default branch points at: plenary.nvim and
---snacks.nvim follow upstream HEAD rather than a pin, so an existing checkout
---is used exactly as it stands and a breaking change upstream surfaces here
---instead of hiding behind a fixed commit.
---@param dir string Checkout path.
---@param url string Repository to clone from.
---@param var string Environment variable that points at the checkout.
local function ensure_clone(dir, url, var)
  if vim.fn.isdirectory(dir) == 1 then
    return
  end
  vim.fn.system({ "git", "clone", url, dir })
  if vim.v.shell_error ~= 0 or vim.fn.isdirectory(dir) == 0 then
    die(string.format("tests: could not clone %s into %s (%s)", url, dir, var))
  end
end

local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
ensure_clone(plenary_dir, "https://github.com/nvim-lua/plenary.nvim", "PLENARY_DIR")

local snacks_dir = os.getenv("SNACKS_DIR") or "/tmp/snacks.nvim"
ensure_clone(snacks_dir, "https://github.com/folke/snacks.nvim", "SNACKS_DIR")

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)
vim.opt.rtp:append(snacks_dir)

-- The e2e job clones render-markdown.nvim and points RENDER_MARKDOWN_DIR at it,
-- so the post-render height correction can be asserted against a real renderer.
local render_markdown_dir = os.getenv("RENDER_MARKDOWN_DIR")
if render_markdown_dir and vim.fn.isdirectory(render_markdown_dir) == 1 then
  vim.opt.rtp:append(render_markdown_dir)
end

local ok, snacks = pcall(require, "snacks")
if not ok then
  die("tests: snacks.nvim could not be loaded from " .. snacks_dir .. ": " .. tostring(snacks))
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
if render_markdown_dir and vim.fn.isdirectory(render_markdown_dir) == 1 then
  local rm_ok, render_markdown = pcall(require, "render-markdown")
  if not rm_ok then
    die("tests: render-markdown.nvim could not be loaded from " .. render_markdown_dir)
  end
  render_markdown.setup({})
end
