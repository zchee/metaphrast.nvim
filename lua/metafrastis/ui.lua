local util = require("metafrastis.util")

local M = {}

local snacks_cache = nil
local autoclose_group = vim.api.nvim_create_augroup("MetafrastisSnacksWin", { clear = true })
local default_win_opts = {}
local active_win = nil
local highlights_defined = false

-- Modern teal/cyan palette for the translation popup. Border and title use a
-- bright teal; the footer hint uses a muted gray so it recedes. All groups are
-- registered with `default = true`, so any colorscheme or user override wins.
local highlight_defs = {
  MetafrastisWinBorder = { fg = "#2dd4bf", ctermfg = 80, default = true },
  MetafrastisWinTitle = { fg = "#2dd4bf", ctermfg = 80, bold = true, default = true },
  MetafrastisWinFooter = { fg = "#6b7280", ctermfg = 244, default = true },
}

-- winhighlight string for the popup window. This mirrors Snacks' default
-- `win.wo.winhighlight` baseline (so the body, winbar, and separators keep
-- their themed look) and substitutes only the border/title/footer groups with
-- the metafrastis teal palette defined above.
local win_highlight = table.concat({
  "Normal:SnacksNormal",
  "NormalNC:SnacksNormalNC",
  "WinBar:SnacksWinBar",
  "WinBarNC:SnacksWinBarNC",
  "FloatBorder:MetafrastisWinBorder",
  "FloatTitle:MetafrastisWinTitle",
  "FloatFooter:MetafrastisWinFooter",
  "WinSeparator:SnacksWinSeparator",
}, ",")

---Register the popup highlight groups once. Idempotent across calls.
local function ensure_highlights()
  if highlights_defined then
    return
  end
  highlights_defined = true
  for name, def in pairs(highlight_defs) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

local function get_snacks()
  if snacks_cache ~= nil then
    return snacks_cache
  end
  local ok, mod = pcall(require, "snacks")
  snacks_cache = ok and mod or false
  return snacks_cache
end

---Close the active window if one exists.
---@return boolean closed True when an active window was present.
local function close_active_win()
  local win = active_win
  active_win = nil
  if not win then
    return false
  end
  pcall(function()
    if type(win.close) == "function" then
      win:close()
    end
  end)
  return true
end

---Reports whether the currently in visual or select mode.
---@param mode string|nil Current mode from vim.fn.mode().
---@return boolean
local function is_visual_or_select_mode(mode)
  return mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
end

---Leave visual/select mode after cursor movement dismisses the popup.
local function leave_visual_or_select_mode()
  if not is_visual_or_select_mode(vim.fn.mode()) then
    return
  end
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
end

---Close the active window and normalize visual/select mode after cursor movement.
---@param event string Autocmd event name that dismissed the popup.
local function close_on_cursor_context_change(event)
  local closed = close_active_win()
  if closed and event == "CursorMoved" then
    leave_visual_or_select_mode()
  end
end

function M.has_snacks()
  return get_snacks() ~= false
end

local function to_log_level(level)
  if type(level) == "number" then
    return level
  end
  if not level then
    return vim.log.levels.INFO
  end
  local upper = string.upper(level)
  return vim.log.levels[upper] or vim.log.levels.INFO
end

---@param msg string|string[]
---@param level string|number|nil
---@param opts table|nil
function M.notify(msg, level, opts)
  local snacks = get_snacks()
  if snacks and snacks.notify then
    local lower = type(level) == "string" and string.lower(level) or "info"
    local fn = snacks.notify[lower] or snacks.notify.notify or snacks.notify.info
    fn(msg, opts)
    return
  end
  vim.notify(msg, to_log_level(level), opts)
end

---@param msg string
---@param opts table|nil
---@return fun(done_msg?:string, level?:string|number)
function M.progress(msg, opts)
  M.notify(msg, "info", opts)
  local finished = false
  return function(done_msg, level)
    if finished then
      return
    end
    finished = true
    if done_msg then
      M.notify(done_msg, level or "info", opts)
    end
  end
end

---Build the window title string.
---@param meta table|nil
---@param opts table|nil
---@return string
local function make_title(meta, opts)
  local parts = {}
  if meta and meta.icon then
    table.insert(parts, meta.icon)
  end
  local base = opts and opts.title
  if base then
    table.insert(parts, base)
  end
  if opts and opts.target_lang then
    table.insert(parts, opts.target_lang)
  end
  if meta and meta.provider then
    table.insert(parts, meta.provider)
  end
  if meta and meta.cached then
    table.insert(parts, "cache")
  end
  return table.concat(parts, " · ")
end

---Compute the display width of a string (handles multibyte/CJK correctly).
---@param s string
---@return integer
local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end

function M.set_defaults(win_opts)
  default_win_opts = win_opts or {}
end

---Apply padding to lines by prepending/appending spaces and blank lines.
---@param lines string[]
---@param padding table|nil
---@return string[]
local function apply_padding(lines, padding)
  if not padding then
    return lines
  end
  local top = padding.top or 0
  local bottom = padding.bottom or 0
  local left = padding.left or 0
  local right = padding.right or 0
  local pad_left = left > 0 and string.rep(" ", left) or ""
  local pad_right = right > 0 and string.rep(" ", right) or ""

  local padded = {}
  for _ = 1, top do
    table.insert(padded, pad_left .. pad_right)
  end
  for _, line in ipairs(lines) do
    table.insert(padded, pad_left .. line .. pad_right)
  end
  for _ = 1, bottom do
    table.insert(padded, pad_left .. pad_right)
  end
  return padded
end

---@param text string|string[]
---@param meta table|nil
---@param opts table|nil
function M.show_window(text, meta, opts)
  -- Close any previously open translation window.
  close_active_win()

  local snacks = get_snacks()
  local lines = type(text) == "table" and text or util.split_lines(text or "")
  if #lines == 0 then
    lines = { "" }
  end
  local merged_win = vim.tbl_deep_extend("force", {}, default_win_opts or {}, opts and opts.win or {})
  local padding = merged_win.padding or (opts and opts.padding) or nil
  if not padding then
    local ok, core = pcall(require, "metafrastis")
    if ok and core.config and core.config.ui and core.config.ui.win then
      padding = core.config.ui.win.padding
    end
  end

  lines = apply_padding(lines, padding)

  local title = make_title(meta, opts)

  if snacks and snacks.win then
    ensure_highlights()
    local win_opts = vim.tbl_deep_extend("force", {
      text = lines,
      title = title,
      minimal = true,
      enter = false,
      keys = {
        q = "close",
        ["<Esc>"] = "close",
        y = {
          function(self)
            local buf_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
            local content = table.concat(buf_lines, "\n")
            vim.fn.setreg("+", content)
            vim.fn.setreg('"', content)
            M.notify("Copied to clipboard", "info")
          end,
          desc = "yank",
        },
      },
      border = "rounded",
      title_pos = "center",
      footer = "q/Esc: close · y: yank · move cursor to dismiss",
      footer_pos = "center",
      wo = {
        wrap = true,
        linebreak = true,
        conceallevel = 2,
        winhighlight = win_highlight,
      },
      bo = {
        filetype = "markdown",
      },
      backdrop = 40,
      relative = "cursor",
    }, merged_win)

    if win_opts.relative == "cursor" then
      win_opts.row = win_opts.row or 1
      win_opts.col = win_opts.col or 0
    end

    if not win_opts.width then
      local max_w = 0
      for _, line in ipairs(lines) do
        max_w = math.max(max_w, display_width(line))
      end
      local editor_w = vim.o.columns
      win_opts.width = math.min(math.floor(editor_w * 0.8), math.max(30, max_w + 2))
    end
    if not win_opts.height then
      local editor_h = vim.o.lines - vim.o.cmdheight - 2
      local wrap_enabled = not (win_opts.wo and win_opts.wo.wrap == false)
      local inner_w = math.max(1, win_opts.width)
      local visual_lines = 0
      for _, line in ipairs(lines) do
        local w = display_width(line)
        if wrap_enabled and w > inner_w then
          visual_lines = visual_lines + math.ceil(w / inner_w)
        else
          visual_lines = visual_lines + 1
        end
      end
      if visual_lines == 0 then
        visual_lines = 1
      end
      win_opts.height = math.min(visual_lines, math.floor(editor_h * 0.6))
    end

    local win = snacks.win(win_opts)
    if win then
      active_win = win
      vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
        group = autoclose_group,
        once = true,
        desc = "metafrastis: close translation window",
        callback = function(args)
          close_on_cursor_context_change(args.event)
        end,
      })
      if win.show then
        win:show()
      end
    end
    return win
  end

  vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
end

---@param default string|nil
---@param on_confirm fun(value?:string)
function M.prompt_target(default, on_confirm)
  local cb = on_confirm or function() end
  local snacks = get_snacks()
  if snacks and snacks.input then
    snacks.input({ prompt = "Target language", default = default }, cb)
    return
  end
  vim.ui.input({ prompt = "Target language: ", default = default }, cb)
end

-- Test helper
function M._reset_for_tests()
  snacks_cache = nil
  default_win_opts = {}
  active_win = nil
  highlights_defined = false
end

return M
