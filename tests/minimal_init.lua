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

-- plenary.nvim is the test runner, and upstream announced that the repository
-- will be archived in Q2 2026, so an unpinned clone is a moving target that can
-- change under the suite at any time. The pin is also what currently protects
-- plenary `Job`'s `interactive` default of true, which is what allocates the
-- stdin pipe the http transport writes its curl config document to.
local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local plenary_ref = os.getenv("PLENARY_REF") or "74b06c6c75e4eeb3108ec01852001636d85a932b"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

---Whether the plenary checkout sits at `plenary_ref` (a commit, tag or branch).
---@return boolean
local function plenary_at_ref()
  local head = vim.trim(vim.fn.system({ "git", "-C", plenary_dir, "rev-parse", "--verify", "HEAD" }))
  local want =
    vim.trim(vim.fn.system({ "git", "-C", plenary_dir, "rev-parse", "--verify", plenary_ref .. "^{commit}" }))
  return vim.v.shell_error == 0 and head == want
end

-- A pre-existing clone may predate the pinned ref or sit on another one; a
-- silent checkout failure would run the suite against the wrong plenary.
vim.fn.system({ "git", "-C", plenary_dir, "checkout", "--quiet", plenary_ref })
if not plenary_at_ref() then
  vim.fn.system({ "git", "-C", plenary_dir, "fetch", "--quiet", "origin" })
  vim.fn.system({ "git", "-C", plenary_dir, "checkout", "--quiet", plenary_ref })
  if not plenary_at_ref() then
    die(string.format("tests: %s is not at PLENARY_REF %s after fetch and checkout", plenary_dir, plenary_ref))
  end
end

-- snacks.nvim is a hard dependency; specs run against the real plugin pinned
-- to the commit the hover was built against (CI caches the clone by this ref).
local snacks_dir = os.getenv("SNACKS_DIR") or "/tmp/snacks.nvim"
local snacks_ref = os.getenv("SNACKS_REF") or "882c996cf28183f4d63640de0b4c02ec886d01f2"
if vim.fn.isdirectory(snacks_dir) == 0 then
  vim.fn.system({ "git", "clone", "https://github.com/folke/snacks.nvim", snacks_dir })
end

---Whether the snacks checkout sits at `snacks_ref` (a commit, tag or branch).
---@return boolean
local function snacks_at_ref()
  local head = vim.trim(vim.fn.system({ "git", "-C", snacks_dir, "rev-parse", "--verify", "HEAD" }))
  local want = vim.trim(vim.fn.system({ "git", "-C", snacks_dir, "rev-parse", "--verify", snacks_ref .. "^{commit}" }))
  return vim.v.shell_error == 0 and head == want
end

-- A pre-existing clone may predate the pinned ref or sit on another one; a
-- silent checkout failure would run the suite against the wrong snacks.
vim.fn.system({ "git", "-C", snacks_dir, "checkout", "--quiet", snacks_ref })
if not snacks_at_ref() then
  vim.fn.system({ "git", "-C", snacks_dir, "fetch", "--quiet", "origin" })
  vim.fn.system({ "git", "-C", snacks_dir, "checkout", "--quiet", snacks_ref })
  if not snacks_at_ref() then
    die(string.format("tests: %s is not at SNACKS_REF %s after fetch and checkout", snacks_dir, snacks_ref))
  end
end

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
