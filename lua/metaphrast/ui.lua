local config = require("metaphrast.config")
local hover = require("metaphrast.ui.hover")

local M = {}

-- Notification id shared by every progress toast, so "Translating..." and its
-- result are one toast updated in place instead of two.
M.PROGRESS_ID = "metaphrast.progress"

local INSTALL_HINT =
  "metaphrast: snacks.nvim (folke/snacks.nvim) is required; install it and load it before metaphrast.setup()"

local snacks_cache = nil

---Load snacks.nvim. The only place in the plugin that requires it.
---Raises an actionable error when it is not installed; the module is cached
---until `_reset_for_tests`.
---@return table snacks The `snacks` module.
function M.require_snacks()
  if snacks_cache then
    return snacks_cache
  end
  local ok, mod = pcall(require, "snacks")
  if not ok or type(mod) ~= "table" then
    error(INSTALL_HINT, 0)
  end
  snacks_cache = mod
  return mod
end

---@return MetaphrastNotifyConfig
local function notify_config()
  local ok, core = pcall(require, "metaphrast")
  local ui = ok and type(core) == "table" and core.config and core.config.ui or nil
  return (ui and ui.notify) or config.defaults().ui.notify
end

---Normalize a level to the lowercase name snacks' notifier accepts.
---@param level string|number|nil
---@return string|number level
local function normalize_level(level)
  if type(level) == "number" then
    return level
  end
  if type(level) ~= "string" or level == "" then
    return "info"
  end
  return string.lower(level)
end

---Build the notifier options shared by toasts: title and icon from config,
---user `opts` on top.
---@param opts table|nil
---@return table opts
local function toast_opts(opts)
  return vim.tbl_extend("force", { title = "Metaphrast", icon = notify_config().icon }, opts or {})
end

---Show a toast with a fresh id (never the progress id).
---@param msg string|string[]
---@param level string|number|nil
---@param opts table|nil Extra `snacks.notifier` options.
---@return number|string id
function M.notify(msg, level, opts)
  local notifier = M.require_snacks().notifier
  if type(msg) == "table" then
    msg = table.concat(msg, "\n")
  end
  local o = toast_opts(opts)
  o.id = nil
  return notifier.notify(msg, normalize_level(level), o)
end

---Show a progress toast that stays up until finished.
---The returned function finishes it in place: with a message it re-notifies
---the same id (errors keep it on screen, everything else expires after
---`ui.notify.timeout`); without one it hides the toast.
---@param msg string
---@param opts table|nil Extra `snacks.notifier` options.
---@return fun(done_msg?: string, level?: string|number) done
function M.progress(msg, opts)
  local notifier = M.require_snacks().notifier
  local base = toast_opts(opts)
  notifier.notify(msg, "info", vim.tbl_extend("force", base, { id = M.PROGRESS_ID, timeout = false }))
  local finished = false
  return function(done_msg, level)
    if finished then
      return
    end
    finished = true
    if not done_msg then
      notifier.hide(M.PROGRESS_ID)
      return
    end
    local lvl = normalize_level(level)
    local timeout = notify_config().timeout
    if lvl == "error" then
      timeout = false
    end
    notifier.notify(done_msg, lvl, vim.tbl_extend("force", base, { id = M.PROGRESS_ID, timeout = timeout }))
  end
end

---Ask for the target language through `snacks.input`.
---@param default string|nil
---@param on_confirm fun(value?: string)
function M.prompt_target(default, on_confirm)
  local cb = on_confirm or function() end
  M.require_snacks().input({ prompt = "Target language", default = default }, cb)
end

---Show a translation in the hover window.
---@param source MetaphrastHoverSource
---@param result MetaphrastHoverResult
---@param opts { focus?: boolean, ui?: MetaphrastUiConfig }|nil
---@return boolean shown
function M.show(source, result, opts)
  return hover.show(source, result, opts)
end

---Focus the open hover window.
---@return boolean focused
function M.focus()
  return hover.focus()
end

---Close the hover window.
---@return boolean closed
function M.close()
  return hover.close()
end

---Forget the cached snacks module and reset the hover.
function M._reset_for_tests()
  snacks_cache = nil
  hover._reset_for_tests()
end

return M
