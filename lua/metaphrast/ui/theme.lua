local M = {}

-- Extmark namespaces shared by hover.lua and its specs. Layout extmarks
-- (padding virtual lines, the 対訳 separator) and pure highlight extmarks live
-- apart so each can be counted and cleared independently.
M.ns_layout = vim.api.nvim_create_namespace("metaphrast.hover.layout")
M.ns_hl = vim.api.nvim_create_namespace("metaphrast.hover.hl")

-- Every highlight group this plugin defines, in the order they are applied.
local GROUPS = {
  "MetaphrastHoverBorder",
  "MetaphrastHoverTitle",
  "MetaphrastHoverIcon",
  "MetaphrastHoverChip",
  "MetaphrastHoverChipCache",
  "MetaphrastHoverFooter",
  "MetaphrastHoverOriginal",
  "MetaphrastHoverSeparator",
}

-- Default theme: every group links to a colorscheme group, so the hover
-- inherits the user's palette. A plain link is used for the title because
-- attributes such as `bold` are not applied through a link.
local LINK_THEME = {
  MetaphrastHoverBorder = { link = "FloatBorder" },
  MetaphrastHoverTitle = { link = "FloatTitle" },
  MetaphrastHoverIcon = { link = "Special" },
  MetaphrastHoverChip = { link = "Visual" },
  MetaphrastHoverChipCache = { link = "DiagnosticOk" },
  MetaphrastHoverFooter = { link = "Comment" },
  MetaphrastHoverOriginal = { link = "Comment" },
  MetaphrastHoverSeparator = { link = "WinSeparator" },
}

-- Opt-in preset reproducing the pre-redesign teal palette: a bright teal for
-- the border and title, a muted gray for the footer. Everything else keeps the
-- colorscheme links.
local TEAL_OVERRIDES = {
  MetaphrastHoverBorder = { fg = "#2dd4bf", ctermfg = 80 },
  MetaphrastHoverTitle = { fg = "#2dd4bf", ctermfg = 80, bold = true },
  MetaphrastHoverFooter = { fg = "#6b7280", ctermfg = 244 },
}

local THEMES = {
  link = LINK_THEME,
  teal = vim.tbl_extend("force", LINK_THEME, TEAL_OVERRIDES),
}

-- Order of the footer key hints, with the label shown next to each key.
local FOOTER_ORDER = {
  { name = "close", desc = "close" },
  { name = "yank", desc = "yank" },
  { name = "replace", desc = "replace" },
  { name = "original", desc = "original" },
  { name = "provider", desc = "provider" },
  { name = "help", desc = "help" },
}

local applied_theme = nil

---Define every `MetaphrastHover*` highlight group for the given theme.
---All groups are registered with `default = true`, so a colorscheme or user
---override always wins. Idempotent for a theme already applied.
---@param theme string|nil "link" (default) or "teal".
---@return string theme The theme actually applied.
function M.ensure_highlights(theme)
  theme = THEMES[theme] and theme or "link"
  if applied_theme == theme then
    return theme
  end
  applied_theme = theme
  for _, name in ipairs(GROUPS) do
    local def = vim.tbl_extend("force", THEMES[theme][name], { default = true })
    vim.api.nvim_set_hl(0, name, def)
  end
  return theme
end

---Build the `winhighlight` value for the hover window.
---Snacks' own default maps no `FloatBorder`, so the border color can only be
---themed from here.
---@return string winhighlight Comma-separated `from:to` pairs.
function M.winhighlight()
  return table.concat({
    "Normal:SnacksNormal",
    "NormalNC:SnacksNormalNC",
    "WinBar:SnacksWinBar",
    "WinBarNC:SnacksWinBarNC",
    "FloatBorder:MetaphrastHoverBorder",
    "FloatTitle:MetaphrastHoverTitle",
    "FloatFooter:MetaphrastHoverFooter",
    "WinSeparator:SnacksWinSeparator",
  }, ",")
end

---Build the title chips for the hover window.
---Each chip carries its own leading and trailing spaces, because snacks pads
---string titles but never chip tables.
---@param meta table|nil Translation metadata (`icon`, `provider`, `cached`).
---@param opts table|nil Language context (`source_lang`, `target_lang`).
---@return { [1]: string, [2]: string }[] chips Text/highlight pairs.
function M.title_chips(meta, opts)
  meta = meta or {}
  opts = opts or {}
  local chips = {}
  if meta.icon and meta.icon ~= "" then
    chips[#chips + 1] = { " " .. meta.icon .. " ", "MetaphrastHoverIcon" }
  end
  chips[#chips + 1] = { " Translate ", "MetaphrastHoverTitle" }
  if meta.provider and meta.provider ~= "" then
    chips[#chips + 1] = { " " .. meta.provider .. " ", "MetaphrastHoverChip" }
  end
  chips[#chips + 1] = {
    string.format(" %s → %s ", opts.source_lang or "auto", opts.target_lang or "auto"),
    "MetaphrastHoverChip",
  }
  if meta.cached then
    chips[#chips + 1] = { " cache ", "MetaphrastHoverChipCache" }
  end
  return chips
end

---Build the footer chips for the hover window.
---A focused hover advertises its keymaps in the snacks footer shape; an
---unfocused one only says how to focus it. Keys set to `false` are skipped and
---a key list is advertised by its first entry.
---@param keys MetaphrastHoverKeys|nil Configured hover keys.
---@param focused boolean Whether the hover currently has focus.
---@return { [1]: string, [2]: string }[] chips Text/highlight pairs.
function M.footer_chips(keys, focused)
  if not focused then
    return { { " press again to focus ", "MetaphrastHoverFooter" } }
  end
  keys = keys or {}
  local chips = {}
  for _, entry in ipairs(FOOTER_ORDER) do
    local key = keys[entry.name]
    if type(key) == "table" then
      key = key[1]
    end
    if type(key) == "string" and key ~= "" then
      chips[#chips + 1] = { " ", "SnacksFooter" }
      chips[#chips + 1] = { " " .. key .. " ", "SnacksFooterKey" }
      chips[#chips + 1] = { " " .. entry.desc .. " ", "SnacksFooterDesc" }
    end
  end
  if #chips > 0 then
    chips[#chips + 1] = { " ", "SnacksFooter" }
  end
  return chips
end

---Build the separator drawn between the original text and its translation.
---@param opts table|nil Language context (`source_lang`, `target_lang`).
---@return string text The separator line.
function M.separator_text(opts)
  opts = opts or {}
  return string.format("── %s → %s ──", opts.source_lang or "auto", opts.target_lang or "auto")
end

---Undefine every `MetaphrastHover*` group so `default = true` re-arms.
---`nvim_set_hl` ignores `default = true` once a group exists, so tests that
---switch themes must clear the groups first.
function M._reset_for_tests()
  applied_theme = nil
  for _, name in ipairs(GROUPS) do
    vim.cmd("hi clear " .. name)
  end
end

return M
