local M = {}

-- Oldest snacks.nvim whose `snacks.win` option surface the hover was built against.
M.MIN_SNACKS_VERSION = "2.31.0"

local function check_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    vim.health.error("snacks.nvim not found", {
      "Install folke/snacks.nvim and load it before metaphrast.setup()",
    })
    return
  end
  local version = type(snacks.version) == "string" and snacks.version or nil
  local parsed = version and vim.version.parse(version) or nil
  if not parsed then
    vim.health.warn("snacks.nvim found, but its version could not be read")
    return
  end
  if vim.version.ge(parsed, M.MIN_SNACKS_VERSION) then
    vim.health.ok("snacks.nvim " .. version)
  else
    vim.health.error(
      string.format("snacks.nvim %s is older than the required %s", version, M.MIN_SNACKS_VERSION),
      { "Update folke/snacks.nvim" }
    )
  end
end

local function check_curl()
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found: " .. vim.fn.exepath("curl"))
  else
    vim.health.error("curl not found", { "Install curl; every provider request shells out to it" })
  end
end

local function check_optional(module, label, when_missing)
  local ok = pcall(require, module)
  if ok then
    vim.health.ok(label .. " found")
  else
    vim.health.info(label .. " not found (" .. when_missing .. ")")
  end
end

---Run `:checkhealth metaphrast`.
function M.check()
  vim.health.start("metaphrast")
  check_snacks()
  check_curl()
  check_optional("plenary.async", "plenary.nvim", "optional; async translation falls back to a blocking request")
  check_optional("render-markdown", "render-markdown.nvim", "optional; the hover body renders as plain markdown")
  vim.health.info(string.format("vim.o.winborder = %q (used when ui.win.border is unset)", vim.o.winborder))
end

return M
