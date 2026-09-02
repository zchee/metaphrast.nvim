local comment = require("metaphrast.comment")
local theme = require("metaphrast.ui.theme")

local M = {}

---@class MetaphrastHoverSource
---@field buf integer Source buffer.
---@field win integer Source window; every geometry read and window write runs inside it.
---@field mode string|nil Selection mode the translation came from ("v", "V", "\22") or nil for a range.
---@field sr integer 0-based first row of the translated range.
---@field sc integer|nil 0-based start column for charwise/blockwise selections.
---@field er integer 0-based last row of the translated range.
---@field ec integer|nil Exclusive end column for charwise/blockwise selections.
---@field commentstring string|nil `commentstring` of the source buffer.
---@field lines string[] Exactly the lines that were translated.

---@class MetaphrastHoverResult
---@field translated string The translation as returned by the pipeline.
---@field display_lines string[] Layout-rendered, leader-free lines shown in the hover.
---@field meta table|nil Provider metadata (`provider`, `cached`, `icon`).
---@field opts table|nil Language context (`source_lang`, `target_lang`, `provider`).

---@class MetaphrastHoverExtmark
---@field ns integer Namespace the mark belongs to (`theme.ns_layout` or `theme.ns_hl`).
---@field row integer 0-based row.
---@field col integer 0-based column.
---@field opts table `nvim_buf_set_extmark` options.

---@class MetaphrastHoverContent
---@field lines string[] Buffer text, exactly the display lines (plus the original when visible).
---@field extmarks MetaphrastHoverExtmark[] Padding, separator and highlight marks.
---@field original_count integer Number of original lines at the top of the buffer.
---@field virt_rows integer Rows added by virtual lines (padding and separator).

---@class MetaphrastHoverGeometryCtx
---@field lines_above integer Window-relative rows above the cursor line.
---@field lines_below integer Window-relative rows below the cursor line.
---@field cursor_screen_row integer 1-based screen row of the cursor.
---@field cursor_screen_col integer 1-based screen column of the cursor.
---@field columns integer `vim.o.columns`.
---@field editor_lines integer Usable rows (`vim.o.lines - vim.o.cmdheight - 2`).
---@field anchor_delta integer Screen-row delta from the cursor to the anchored range row.
---@field border_rows integer Rows taken by the border.
---@field border_cols integer Columns taken by the border.
---@field virt_rows integer Rows added by virtual lines.
---@field measured_text_height integer|nil Post-render text height, already without `virt_rows`.

---@class MetaphrastHoverGeometry
---@field below boolean Whether the hover opens below the anchor line.
---@field row integer Row offset from the cursor (negative above).
---@field col integer Column offset from the cursor.
---@field width integer Window width including the statuscolumn padding.
---@field height integer Window height including virtual padding rows.
---@field inner_width integer Requested width before the screen cap.
---@field wrap_width integer Columns available to text (`width - padding.left`).

-- Hover key names in footer order; each maps to a snacks action of the same name.
local KEY_NAMES = { "close", "yank", "replace", "original", "provider", "help" }

-- Rows/columns drawn by snacks' partial border presets.
local PARTIAL_BORDERS = {
  left = { 0, 1 },
  right = { 0, 1 },
  top = { 1, 0 },
  bottom = { 1, 0 },
  top_bottom = { 2, 0 },
  hpad = { 0, 2 },
  vpad = { 2, 0 },
}

local function clamp(n, lo, hi)
  return math.max(lo, math.min(n, hi))
end

---Resolve a size that is either absolute (`n >= 1`) or a ratio of `basis` (`0 < n < 1`).
local function resolve_size(n, basis)
  if n > 0 and n < 1 then
    return math.floor(n * basis)
  end
  return math.floor(n)
end

local function max_display_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

-- Pure builders -------------------------------------------------------------

---Resolve the border spec: the configured value, else `vim.o.winborder`.
---A comma list becomes the 8-item table Neovim expects; an empty value means "rounded".
---@param border string|string[]|nil Configured `ui.win.border`.
---@return string|string[] border
function M.resolve_border(border)
  if border == nil then
    border = vim.o.winborder
  end
  if border == "" then
    return "rounded"
  end
  if type(border) == "string" and border:find(",", 1, true) then
    return vim.split(border, ",", { plain = true })
  end
  return border
end

---Rows and columns a border occupies, mirroring snacks' `border_size()`.
---@param border string|string[]|false|nil Resolved border spec.
---@return { rows: integer, cols: integer } size
function M.border_size(border)
  if border == nil or border == false or border == "" or border == "none" then
    return { rows = 0, cols = 0 }
  end
  if type(border) == "string" then
    local partial = PARTIAL_BORDERS[border]
    if partial then
      return { rows = partial[1], cols = partial[2] }
    end
    return { rows = 2, cols = 2 }
  end
  local cells = {}
  for i, cell in ipairs(border) do
    cells[i] = type(cell) == "table" and cell[1] or cell
  end
  if #cells == 0 then
    return { rows = 0, cols = 0 }
  end
  while #cells < 8 do
    cells = vim.list_extend(cells, vim.deepcopy(cells))
  end
  local function drawn(from, to)
    for i = from, to do
      if cells[i] ~= "" then
        return 1
      end
    end
    return 0
  end
  return {
    rows = drawn(1, 3) + drawn(5, 7),
    cols = math.max(drawn(7, 8), drawn(1, 1)) + drawn(3, 5),
  }
end

---Build the hover buffer text and the extmarks that dress it.
---The buffer text is exactly `result.display_lines`, preceded by the
---leader-stripped source lines when `original_visible`. Padding and the
---対訳 separator are virtual lines, so they never enter the text.
---@param result MetaphrastHoverResult
---@param source MetaphrastHoverSource|nil
---@param original_visible boolean
---@param padding MetaphrastWinPadding|nil Only `top`/`bottom` are used here.
---@return MetaphrastHoverContent content
function M.build_lines(result, source, original_visible, padding)
  padding = padding or {}
  local top = padding.top or 0
  local bottom = padding.bottom or 0
  local original = {}
  if original_visible and source and source.lines then
    original = comment.strip_lines(source.lines, source.commentstring)
  end
  local lines = {}
  vim.list_extend(lines, original)
  vim.list_extend(lines, result.display_lines or {})
  if #lines == 0 then
    lines = { "" }
  end

  local extmarks = {}
  for _ = 1, top do
    extmarks[#extmarks + 1] = {
      ns = theme.ns_layout,
      row = 0,
      col = 0,
      opts = { virt_lines = { { { "", "" } } }, virt_lines_above = true },
    }
  end
  if #original > 0 then
    extmarks[#extmarks + 1] = {
      ns = theme.ns_layout,
      row = #original - 1,
      col = 0,
      opts = { virt_lines = { { { theme.separator_text(result.opts), "MetaphrastHoverSeparator" } } } },
    }
    extmarks[#extmarks + 1] = {
      ns = theme.ns_hl,
      row = 0,
      col = 0,
      opts = { end_row = #original - 1, line_hl_group = "MetaphrastHoverOriginal" },
    }
  end
  for _ = 1, bottom do
    extmarks[#extmarks + 1] = {
      ns = theme.ns_layout,
      row = #lines - 1,
      col = 0,
      opts = { virt_lines = { { { "", "" } } } },
    }
  end

  return {
    lines = lines,
    extmarks = extmarks,
    original_count = #original,
    virt_rows = top + bottom + (#original > 0 and 1 or 0),
  }
end

---Estimate the rows `lines` take at `wrap_width`, in display columns.
---CJK characters count by display width, so a 40-column line wraps to two rows at 20.
---@param lines string[]
---@param wrap_width integer Columns available to text.
---@param wrap boolean|nil `false` disables wrapping; anything else wraps.
---@return integer rows Never below 1.
function M.estimate_height(lines, wrap_width, wrap)
  wrap_width = math.max(1, wrap_width or 1)
  local rows = 0
  for _, line in ipairs(lines) do
    local width = vim.fn.strdisplaywidth(line)
    if wrap ~= false and width > wrap_width then
      rows = rows + math.ceil(width / wrap_width)
    else
      rows = rows + 1
    end
  end
  return math.max(rows, 1)
end

---Compute the hover placement; the only producer of `row`/`col`/`width`/`height`.
---Widths and heights are screen-capped here so snacks' `dim()` clamp is a no-op,
---and the above/below flip is a negative `row`, never an `anchor`.
---@param lines string[] Buffer lines (used for the auto width/height).
---@param cfg MetaphrastWinConfig `ui.win` config.
---@param ctx MetaphrastHoverGeometryCtx
---@param frozen_below boolean|nil Side chosen when the hover opened, if any.
---@return MetaphrastHoverGeometry geometry
function M.compute_geometry(lines, cfg, ctx, frozen_below)
  local padding = cfg.padding or {}
  local pad_left = padding.left or 0
  local pad_right = padding.right or 0
  local columns = ctx.columns
  local editor_lines = ctx.editor_lines
  local border_rows = ctx.border_rows or 0
  local border_cols = ctx.border_cols or 0
  local lines_above = ctx.lines_above or 0
  local lines_below = ctx.lines_below or 0
  local anchor_delta = ctx.anchor_delta or 0
  local cursor_screen_row = ctx.cursor_screen_row or (lines_above + 1)
  local cursor_screen_col = ctx.cursor_screen_col or 1
  local cfg_row = cfg.row or 1
  local cfg_col = cfg.col or 0

  local inner_width
  if cfg.width then
    inner_width = resolve_size(cfg.width, columns)
  else
    local want = max_display_width(lines) + pad_left + pad_right
    local lo = cfg.min_width and resolve_size(cfg.min_width, columns) or 30
    local hi = cfg.max_width and resolve_size(cfg.max_width, columns) or math.huge
    inner_width = math.max(math.min(want, hi), lo)
  end
  local width = math.max(1, math.min(inner_width, columns - border_cols))

  local wrap = not (cfg.wo and cfg.wo.wrap == false)
  local wrap_width = math.max(1, width - pad_left)
  local virt_rows = ctx.virt_rows or 0
  local text_height = ctx.measured_text_height or M.estimate_height(lines, wrap_width, wrap)
  local max_rows = math.max(1, editor_lines - border_rows)
  local height
  if cfg.height then
    height = resolve_size(cfg.height, editor_lines)
  else
    local lo = cfg.min_height and resolve_size(cfg.min_height, editor_lines) or 1
    local hi = cfg.max_height and resolve_size(cfg.max_height, editor_lines) or math.huge
    height = math.max(math.min(text_height + virt_rows, hi), lo)
  end
  height = clamp(height, 1, max_rows)

  local avail_below = lines_below - math.max(anchor_delta, 0) - (cfg_row - 1) - border_rows
  local avail_above = lines_above + math.min(anchor_delta, 0) - (cfg_row - 1) - border_rows
  local below
  if frozen_below ~= nil then
    below = frozen_below
  else
    below = height <= avail_below or avail_below > avail_above
  end
  height = clamp(math.min(height, below and avail_below or avail_above), 1, max_rows)

  local row
  if below then
    row = cfg_row + anchor_delta
  else
    row = -(height + border_rows + (cfg_row - 1)) + anchor_delta
  end
  local top_limit = 1 - cursor_screen_row
  if row < top_limit then
    height = math.max(1, height - (top_limit - row))
    row = top_limit
  end

  local col = math.min(cfg_col, columns - cursor_screen_col - width - border_cols + 1)
  col = math.max(col, 1 - cursor_screen_col)

  return {
    below = below,
    row = row,
    col = col,
    width = width,
    height = height,
    inner_width = inner_width,
    wrap_width = wrap_width,
  }
end

---Map the hover config and geometry onto `snacks.win.Config` through an allowlist.
---`relative` is always "cursor" (the only snacks mode that forwards `row`/`col`
---verbatim), `resize` is always false (we own `VimResized`), and the size bounds
---are never forwarded because `compute_geometry` already applied them.
---@param cfg MetaphrastUiConfig The `ui` config (`win` and `hover`).
---@param geometry MetaphrastHoverGeometry
---@param chrome table|nil `title`, `footer`, `keys`, `actions`, `text`, `on_win`, `on_close`.
---@return table opts
function M.snacks_opts(cfg, geometry, chrome)
  chrome = chrome or {}
  local win = cfg.win or {}
  local hover = cfg.hover or {}
  local padding = win.padding or {}
  local wo = vim.tbl_extend("force", {
    wrap = true,
    linebreak = true,
    breakindent = true,
    conceallevel = 3,
    winblend = win.winblend or 0,
    statuscolumn = string.rep(" ", padding.left or 0),
    winhighlight = theme.winhighlight(),
  }, win.wo or {})
  local bo = vim.tbl_extend("force", {
    filetype = hover.render_markdown ~= false and "markdown" or "metaphrast",
  }, win.bo or {})
  local backdrop = win.backdrop
  if backdrop == nil then
    backdrop = false
  end
  return {
    relative = "cursor",
    row = geometry.row,
    col = geometry.col,
    width = geometry.width,
    height = geometry.height,
    border = M.resolve_border(win.border),
    title = chrome.title,
    title_pos = "center",
    footer = chrome.footer,
    footer_pos = "center",
    keys = chrome.keys,
    actions = chrome.actions,
    wo = wo,
    bo = bo,
    backdrop = backdrop,
    enter = false,
    show = true,
    text = chrome.text,
    resize = false,
    on_win = chrome.on_win,
    on_close = chrome.on_close,
  }
end

---Translate `ui.hover.keys` into the snacks `keys` table.
---Every lhs maps to the action of the same name; `false` disables the entry.
---`q` is disabled up front so snacks' own `q = "close"` default never leaks in.
---@param keys MetaphrastHoverKeys|table<string, string|string[]|false>|nil
---@return table<string, string|false> keys
function M.resolve_keys(keys)
  ---@type table<string, string|false>
  local out = { q = false }
  keys = keys or {}
  for _, name in ipairs(KEY_NAMES) do
    local lhs = keys[name]
    if type(lhs) == "string" and lhs ~= "" then
      out[lhs] = name
    elseif type(lhs) == "table" then
      for _, entry in ipairs(lhs) do
        if type(entry) == "string" and entry ~= "" then
          out[entry] = name
        end
      end
    end
  end
  return out
end

---Run `fn` with the source window current, so cursor-relative reads and
---writes see the right cursor. Refuses when the window is gone or shows
---another buffer. Never use it for focus changes: `nvim_win_call` restores
---the previous window on return.
---@param source { buf: integer, win: integer }|nil Source handles (a `MetaphrastHoverSource` works).
---@param fn fun()
---@return boolean ok False when the source window is unusable.
function M.in_source(source, fn)
  if not (source and source.win and vim.api.nvim_win_is_valid(source.win)) then
    return false
  end
  if vim.api.nvim_win_get_buf(source.win) ~= source.buf then
    return false
  end
  vim.api.nvim_win_call(source.win, fn)
  return true
end

---Read the geometry inputs from the source window. Call it inside `in_source`.
---One `screenpos()` call yields the screen-absolute cursor position; the
---anchor delta uses the last range row below and the first range row above,
---and collapses to 0 when either line is off screen.
---@param source MetaphrastHoverSource
---@param extra table|nil `below` (side, default true), `border` (resolved spec), `virt_rows`, `measured_text_height`.
---@return MetaphrastHoverGeometryCtx ctx
function M.geometry_ctx(source, extra)
  extra = extra or {}
  local win = source.win
  local cursor = vim.api.nvim_win_get_cursor(win)
  local winline = vim.fn.winline()
  local win_height = vim.api.nvim_win_get_height(win)
  local sp = vim.fn.screenpos(win, cursor[1], cursor[2] + 1)
  local screen_row, screen_col = sp.row, sp.col
  if screen_row == 0 or screen_col == 0 then
    local pos = vim.api.nvim_win_get_position(win)
    screen_row = pos[1] + winline
    screen_col = pos[2] + vim.fn.wincol()
  end

  local anchor_delta = 0
  local anchor_row = extra.below ~= false and source.er or source.sr
  if anchor_row and sp.row ~= 0 then
    local anchor = vim.fn.screenpos(win, anchor_row + 1, 1)
    if anchor.row ~= 0 then
      anchor_delta = anchor.row - sp.row
    end
  end

  local border = M.border_size(extra.border ~= nil and extra.border or M.resolve_border(nil))
  return {
    lines_above = winline - 1,
    lines_below = win_height - winline,
    cursor_screen_row = screen_row,
    cursor_screen_col = screen_col,
    columns = vim.o.columns,
    editor_lines = vim.o.lines - vim.o.cmdheight - 2,
    anchor_delta = anchor_delta,
    border_rows = border.rows,
    border_cols = border.cols,
    virt_rows = extra.virt_rows or 0,
    measured_text_height = extra.measured_text_height,
  }
end

return M
