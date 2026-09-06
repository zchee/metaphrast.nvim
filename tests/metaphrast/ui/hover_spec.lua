if vim.fn.has("win32") == 1 then
  return -- Windows out of scope (decision 2026-09-02)
end

local config = require("metaphrast.config")
local hover = require("metaphrast.ui.hover")
local theme = require("metaphrast.ui.theme")

-- The user's real config table (acceptance 10 fixture).
local USER_WIN = {
  width = 150,
  border = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  padding = { top = 1, bottom = 1, left = 5, right = 5 },
  row = 2,
  col = 1,
  wo = { wrap = false },
}

local FORBIDDEN_SNACKS_KEYS = {
  "anchor",
  "bufpos",
  "win",
  "style",
  "zindex",
  "min_width",
  "min_height",
  "max_width",
  "max_height",
}

---Acceptance-7 defaults, overridable per case.
local function ctx(overrides)
  local c = vim.tbl_extend("force", {
    lines_above = 0,
    lines_below = 30,
    cursor_screen_col = 1,
    columns = 80,
    editor_lines = 22,
    anchor_delta = 0,
    border_rows = 2,
    border_cols = 2,
    virt_rows = 0,
  }, overrides or {})
  if c.cursor_screen_row == nil then
    c.cursor_screen_row = c.lines_above + 1
  end
  return c
end

local function win_cfg(overrides)
  return vim.tbl_deep_extend("force", config.defaults().ui.win, overrides or {})
end

local function ui_cfg(win_overrides, hover_overrides)
  local ui = config.defaults().ui
  ui.win = vim.tbl_deep_extend("force", ui.win, win_overrides or {})
  ui.hover = vim.tbl_deep_extend("force", ui.hover, hover_overrides or {})
  return ui
end

local function lines(count, width)
  local out = {}
  for i = 1, count do
    out[i] = string.rep("x", width or 10)
  end
  return out
end

local function assert_integers(geometry)
  for _, key in ipairs({ "row", "col", "width", "height" }) do
    assert.equals("number", type(geometry[key]), key)
    assert.equals(0, geometry[key] % 1, key .. " is not an integer")
  end
end

describe("hover.compute_geometry", function()
  it("opens below with the row offset when the content fits", function()
    local g = hover.compute_geometry(lines(3), win_cfg(), ctx({ lines_above = 5, lines_below = 30 }))

    assert.is_true(g.below)
    assert.equals(1, g.row)
    assert.equals(0, g.col)
    assert.equals(3, g.height)
    assert_integers(g)
  end)

  it("flips above as a negative row when there is no room below", function()
    local g = hover.compute_geometry(
      lines(5),
      win_cfg(),
      ctx({ lines_above = 30, lines_below = 2, cursor_screen_row = 31, editor_lines = 40 })
    )

    assert.is_false(g.below)
    assert.equals(-(5 + 2 + 0), g.row)
    assert.equals(5, g.height)
  end)

  it("moves the above row by the anchor delta of the first range row", function()
    local g = hover.compute_geometry(
      lines(5),
      win_cfg(),
      ctx({ lines_above = 30, lines_below = 2, cursor_screen_row = 31, editor_lines = 40, anchor_delta = -2 })
    )

    assert.is_false(g.below)
    assert.equals(-(5 + 2 + 0) - 2, g.row)
  end)

  it("subtracts the anchor delta from the space below", function()
    local g = hover.compute_geometry(lines(6), win_cfg(), ctx({ lines_below = 6, anchor_delta = 2 }))

    assert.is_true(g.below)
    assert.equals(2, g.height)
    assert.equals(1 + 2, g.row)
  end)

  it("keeps the top border on screen when there is no room at all", function()
    local g =
      hover.compute_geometry(lines(5), win_cfg(), ctx({ lines_above = 0, lines_below = 0, cursor_screen_row = 1 }))

    assert.equals(1, g.height)
    assert.is_true(g.row >= 0)
    assert.is_false(g.below)
  end)

  it("caps an explicit width at the screen and keeps the left border on screen", function()
    local g = hover.compute_geometry(lines(3), win_cfg({ width = 150 }), ctx({ columns = 80, cursor_screen_col = 1 }))

    assert.equals(78, g.width)
    assert.equals(0, g.col)
  end)

  it("slides the window left so the right border stays on screen", function()
    local g =
      hover.compute_geometry(lines(3), win_cfg({ width = 150 }), ctx({ columns = 200, cursor_screen_col = 120 }))

    assert.equals(150, g.width)
    assert.equals(200 - 120 - 150 - 2 + 1, g.col)
    assert.equals(-71, g.col)
  end)

  it("keeps a frozen side and collapses the height instead of flipping", function()
    local below = hover.compute_geometry(lines(10), win_cfg(), ctx({ lines_above = 30, lines_below = 2 }), true)
    assert.is_true(below.below)
    assert.equals(1, below.height)

    local above = hover.compute_geometry(lines(10), win_cfg(), ctx({ lines_above = 2, lines_below = 30 }), false)
    assert.is_false(above.below)
    assert.equals(1, above.height)
  end)

  it("bounds only the auto width with min_width/max_width in both forms", function()
    assert.equals(45, hover.compute_geometry(lines(3, 10), win_cfg({ min_width = 45 }), ctx()).width)
    assert.equals(40, hover.compute_geometry(lines(3, 60), win_cfg({ max_width = 40 }), ctx()).width)
    assert.equals(40, hover.compute_geometry(lines(3, 60), win_cfg({ max_width = 0.5 }), ctx({ columns = 80 })).width)
    assert.equals(
      150,
      hover.compute_geometry(lines(3), win_cfg({ width = 150, max_width = 0.6 }), ctx({ columns = 200 })).width
    )
  end)

  it("uses the auto width for narrow content with the default floor", function()
    local g = hover.compute_geometry(lines(2, 5), win_cfg(), ctx())

    assert.equals(30, g.width)
    assert.equals(30, g.inner_width)
  end)

  it("counts CJK display width when wrapping and honors wrap=false and virt_rows", function()
    local cjk = { string.rep("あ", 20), string.rep("あ", 20) }
    local cfg = win_cfg({ width = 21, padding = { top = 0, bottom = 0, left = 1, right = 0 } })

    local wrapped = hover.compute_geometry(cjk, cfg, ctx())
    assert.equals(20, wrapped.wrap_width)
    assert.equals(4, wrapped.height)

    local nowrap = hover.compute_geometry(cjk, win_cfg({ width = 21, wo = { wrap = false } }), ctx())
    assert.equals(2, nowrap.height)

    local padded = hover.compute_geometry(cjk, cfg, ctx({ virt_rows = 2 }))
    assert.equals(6, padded.height)
  end)

  it("prefers a measured text height over the estimate", function()
    local g = hover.compute_geometry(lines(3), win_cfg(), ctx({ measured_text_height = 7, virt_rows = 1 }))

    assert.equals(8, g.height)
  end)

  it("resolves ratio and absolute height forms against the usable rows", function()
    assert.equals(10, hover.compute_geometry(lines(30), win_cfg({ max_height = 10 }), ctx({ lines_below = 40 })).height)
    local half = hover.compute_geometry(lines(30), win_cfg({ max_height = 0.5 }), ctx({ lines_below = 40 }))
    assert.equals(11, half.height)
    assert.equals(
      4,
      hover.compute_geometry(lines(2), win_cfg({ min_height = 4 }), ctx({ lines_below = 40, editor_lines = 22 })).height
    )
    assert.equals(
      6,
      hover.compute_geometry(lines(2), win_cfg({ height = 6 }), ctx({ lines_below = 40, editor_lines = 22 })).height
    )
  end)

  it("never exceeds the usable rows minus the border", function()
    local g = hover.compute_geometry(lines(2), win_cfg({ height = 50 }), ctx({ lines_below = 100, editor_lines = 22 }))

    assert.equals(20, g.height)
  end)

  describe("with the user's config fixture", function()
    it("keeps row/col meaning below and mirrors them above", function()
      local below = hover.compute_geometry(lines(3), win_cfg(USER_WIN), ctx({ columns = 200, lines_below = 30 }))
      assert.is_true(below.below)
      assert.equals(2, below.row)
      assert.equals(1, below.col)
      assert.equals(150, below.width)

      local above = hover.compute_geometry(
        lines(3),
        win_cfg(USER_WIN),
        ctx({ columns = 200, lines_above = 30, lines_below = 1, cursor_screen_row = 31, editor_lines = 40 })
      )
      assert.is_false(above.below)
      assert.equals(-(above.height + 2 + 1), above.row)
    end)

    it("clamps horizontally against the screen", function()
      assert.equals(
        -71,
        hover.compute_geometry(lines(3), win_cfg(USER_WIN), ctx({ columns = 200, cursor_screen_col = 120 })).col
      )
      local narrow = hover.compute_geometry(lines(3), win_cfg(USER_WIN), ctx({ columns = 80, cursor_screen_col = 1 }))
      assert.equals(78, narrow.width)
      assert.equals(0, narrow.col)
    end)
  end)
end)

describe("hover.estimate_height", function()
  it("wraps CJK lines by display width", function()
    assert.equals(2, hover.estimate_height({ string.rep("漢", 20) }, 20, true))
    assert.equals(1, hover.estimate_height({ string.rep("漢", 20) }, 20, false))
    assert.equals(1, hover.estimate_height({ string.rep("漢", 20) }, 40, true))
  end)

  it("never returns zero", function()
    assert.equals(1, hover.estimate_height({}, 20, true))
  end)

  it("sums rows across lines", function()
    assert.equals(6, hover.estimate_height({ string.rep("x", 45), "short", string.rep("x", 21) }, 20, true))
  end)
end)

describe("hover.text_budget", function()
  it("takes the configured width minus the horizontal padding", function()
    assert.equals(140, hover.text_budget(win_cfg({ width = 150, padding = { left = 5, right = 5 } }), 200, 2))
  end)

  it("resolves a ratio max_width against the screen", function()
    assert.equals(46, hover.text_budget(win_cfg({ max_width = 0.6 }), 80, 2))
  end)

  it("caps the budget at the screen the border leaves", function()
    assert.equals(76, hover.text_budget(win_cfg({ width = 300 }), 80, 2))
  end)

  it("falls back to the whole screen without a width or max_width", function()
    local cfg = win_cfg()
    cfg.max_width = nil
    assert.equals(76, hover.text_budget(cfg, 80, 2))
  end)

  it("never drops below one column", function()
    assert.equals(1, hover.text_budget(win_cfg({ width = 2, padding = { left = 5, right = 5 } }), 80, 2))
  end)

  it("stays within the columns compute_geometry leaves to text", function()
    local cfg = win_cfg({ width = 150, padding = { left = 5, right = 5 } })
    local budget = hover.text_budget(cfg, 200, 2)
    local g = hover.compute_geometry({ string.rep("x", budget) }, cfg, ctx({ columns = 200 }))

    assert.is_true(budget <= g.wrap_width, budget .. " > " .. g.wrap_width)
  end)
end)

describe("hover.wrap_display", function()
  local CJK = "本書は参考用の機能一覧であり、ロードマップではありません。"

  it("keeps a line that already fits byte for byte", function()
    assert.same({ "short line" }, hover.wrap_display({ "short line" }, 20))
  end)

  it("wraps an over-wide CJK line inside the budget", function()
    local out = hover.wrap_display({ CJK }, 20)

    assert.is_true(#out > 1)
    for _, line in ipairs(out) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 20, line)
    end
    assert.equals(CJK, table.concat(out, ""))
  end)

  it("repeats the leading indent on every continuation", function()
    local out = hover.wrap_display({ "  - " .. CJK }, 20)

    assert.is_true(#out > 1)
    for _, line in ipairs(out) do
      assert.equals("  ", line:sub(1, 2))
      assert.is_true(vim.fn.strdisplaywidth(line) <= 20, line)
    end
  end)

  it("wraps nothing without a budget", function()
    assert.same({ CJK }, hover.wrap_display({ CJK }, nil))
  end)
end)

describe("hover.build_lines", function()
  local result = {
    translated = "one\ntwo",
    display_lines = { "one", "two" },
    opts = { source_lang = "en", target_lang = "ja" },
  }
  local source = {
    buf = 0,
    win = 0,
    sr = 0,
    er = 2,
    commentstring = "// %s",
    lines = { "// alpha", "// beta", "// gamma" },
  }

  it("uses exactly the display lines and pads with virtual lines only", function()
    local content = hover.build_lines(result, source, false, { top = 1, bottom = 2, left = 5, right = 5 })

    assert.same({ "one", "two" }, content.lines)
    assert.equals(3, #content.extmarks)
    assert.equals(3, content.virt_rows)
    assert.equals(0, content.original_count)
    for _, mark in ipairs(content.extmarks) do
      assert.equals(theme.ns_layout, mark.ns)
      assert.is_true(mark.opts.virt_lines ~= nil)
    end
    assert.is_true(content.extmarks[1].opts.virt_lines_above)
    assert.equals(0, content.extmarks[1].row)
    assert.equals(1, content.extmarks[2].row)
    assert.is_nil(content.extmarks[2].opts.virt_lines_above)
  end)

  it("prepends the stripped original with a separator and a highlight mark", function()
    local content = hover.build_lines(result, source, true, { top = 0, bottom = 0, left = 1, right = 1 })

    assert.same({ "alpha", "beta", "gamma", "one", "two" }, content.lines)
    assert.equals(3, content.original_count)
    assert.equals(1, content.virt_rows)
    assert.equals(2, #content.extmarks)

    local separator, hl = content.extmarks[1], content.extmarks[2]
    assert.equals(theme.ns_layout, separator.ns)
    assert.equals(2, separator.row)
    assert.same({ { { "── en → ja ──", "MetaphrastHoverSeparator" } } }, separator.opts.virt_lines)
    assert.equals(theme.ns_hl, hl.ns)
    assert.equals(0, hl.row)
    assert.equals(2, hl.opts.end_row)
    assert.equals("MetaphrastHoverOriginal", hl.opts.line_hl_group)
  end)

  it("applies to a real buffer without changing its text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local content = hover.build_lines(result, source, true, { top = 1, bottom = 1, left = 5, right = 5 })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
    for _, mark in ipairs(content.extmarks) do
      vim.api.nvim_buf_set_extmark(buf, mark.ns, mark.row, mark.col, mark.opts)
    end

    assert.same(content.lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals(3, #vim.api.nvim_buf_get_extmarks(buf, theme.ns_layout, 0, -1, {}))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf, theme.ns_hl, 0, -1, {}))
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      assert.is_nil(line:match("^%s"), "padding leaked into the buffer text")
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("wraps the translation to the budget and leaves the original verbatim", function()
    local long = string.rep("あ", 40)
    local content = hover.build_lines(
      { translated = long, display_lines = { long } },
      source,
      true,
      { left = 1, right = 1 },
      20
    )

    assert.same({ "alpha", "beta", "gamma" }, { content.lines[1], content.lines[2], content.lines[3] })
    assert.is_true(#content.lines > 4, vim.inspect(content.lines))
    for i = 4, #content.lines do
      assert.is_true(vim.fn.strdisplaywidth(content.lines[i]) <= 20, content.lines[i])
    end
    assert.equals(long, table.concat(content.lines, "", 4))
  end)

  it("reads the translation, not the source-shaped display lines", function()
    local content = hover.build_lines({ translated = "alpha beta", display_lines = { "alpha", "beta" } }, nil, false)

    assert.same({ "alpha beta" }, content.lines)
  end)

  it("drops a trailing newline a provider appended", function()
    local content = hover.build_lines({ translated = "one\ntwo\n", display_lines = {} }, nil, false)

    assert.same({ "one", "two" }, content.lines)
  end)

  it("falls back to one empty line for an empty result", function()
    local content = hover.build_lines({ translated = "", display_lines = {} }, nil, false, nil)

    assert.same({ "" }, content.lines)
    assert.same({}, content.extmarks)
  end)
end)

describe("hover.snacks_opts", function()
  local geometry = { below = true, row = 1, col = 0, width = 40, height = 3, inner_width = 40, wrap_width = 39 }
  local saved_winborder

  before_each(function()
    saved_winborder = vim.o.winborder
  end)

  after_each(function()
    vim.o.winborder = saved_winborder
  end)

  it("emits only allowlisted keys and forces cursor-relative, non-resizing placement", function()
    local opts = hover.snacks_opts(ui_cfg(), geometry, { text = { "x" } })

    for _, key in ipairs(FORBIDDEN_SNACKS_KEYS) do
      assert.is_nil(opts[key], key .. " must never reach snacks")
    end
    assert.equals("cursor", opts.relative)
    assert.is_false(opts.resize)
    assert.is_false(opts.enter)
    assert.is_true(opts.show)
    assert.equals(1, opts.row)
    assert.equals(0, opts.col)
    assert.equals(40, opts.width)
    assert.equals(3, opts.height)
    assert.equals("center", opts.title_pos)
    assert.equals("center", opts.footer_pos)
    assert.is_false(opts.backdrop)
    assert.same({ "x" }, opts.text)
  end)

  it("themes the border through winhighlight and pads through the statuscolumn", function()
    local opts = hover.snacks_opts(ui_cfg({ padding = { left = 5 } }), geometry, {})

    assert.is_truthy(opts.wo.winhighlight:find("FloatBorder:MetaphrastHoverBorder", 1, true))
    assert.equals("     ", opts.wo.statuscolumn)
    assert.is_true(opts.wo.wrap)
    assert.is_true(opts.wo.linebreak)
    assert.is_true(opts.wo.breakindent)
    assert.equals(3, opts.wo.conceallevel)
  end)

  it("lets the user's wo win and maps winblend into wo", function()
    local opts = hover.snacks_opts(ui_cfg({ winblend = 15, wo = { wrap = false, conceallevel = 0 } }), geometry, {})

    assert.is_false(opts.wo.wrap)
    assert.equals(0, opts.wo.conceallevel)
    assert.equals(15, opts.wo.winblend)
    assert.is_truthy(opts.wo.winhighlight:find("FloatBorder:MetaphrastHoverBorder", 1, true))
  end)

  it("selects the filetype from hover.render_markdown and merges user bo", function()
    assert.equals("markdown", hover.snacks_opts(ui_cfg(), geometry, {}).bo.filetype)
    local plain = hover.snacks_opts(ui_cfg({ bo = { textwidth = 72 } }, { render_markdown = false }), geometry, {})
    assert.equals("metaphrast", plain.bo.filetype)
    assert.equals(72, plain.bo.textwidth)
  end)

  it("passes an explicit border and backdrop through", function()
    local opts = hover.snacks_opts(ui_cfg({ border = USER_WIN.border, backdrop = 40 }), geometry, {})

    assert.same(USER_WIN.border, opts.border)
    assert.equals(40, opts.backdrop)
  end)

  it("falls back to vim.o.winborder, splitting a comma list into eight cells", function()
    vim.o.winborder = "single"
    assert.equals("single", hover.snacks_opts(ui_cfg(), geometry, {}).border)

    vim.o.winborder = "+,-,+,|,+,-,+,|"
    assert.same({ "+", "-", "+", "|", "+", "-", "+", "|" }, hover.snacks_opts(ui_cfg(), geometry, {}).border)

    vim.o.winborder = ""
    assert.equals("rounded", hover.snacks_opts(ui_cfg(), geometry, {}).border)
  end)

  it("forwards the chrome callbacks and tables", function()
    local on_close = function() end
    local opts = hover.snacks_opts(ui_cfg(), geometry, {
      title = { { " Translate ", "MetaphrastHoverTitle" } },
      footer = { { " press again to focus ", "MetaphrastHoverFooter" } },
      keys = { q = "close" },
      actions = { close = { action = function() end } },
      on_close = on_close,
    })

    assert.same({ { " Translate ", "MetaphrastHoverTitle" } }, opts.title)
    assert.same({ { " press again to focus ", "MetaphrastHoverFooter" } }, opts.footer)
    assert.same({ q = "close" }, opts.keys)
    assert.is_function(opts.actions.close.action)
    assert.equals(on_close, opts.on_close)
  end)
end)

describe("hover.border_size", function()
  it("measures named, empty and table borders", function()
    assert.same({ rows = 2, cols = 2 }, hover.border_size("rounded"))
    assert.same({ rows = 0, cols = 0 }, hover.border_size("none"))
    assert.same({ rows = 0, cols = 0 }, hover.border_size(nil))
    assert.same({ rows = 2, cols = 0 }, hover.border_size("top_bottom"))
    assert.same({ rows = 0, cols = 2 }, hover.border_size("hpad"))
    assert.same({ rows = 2, cols = 2 }, hover.border_size(USER_WIN.border))
    assert.same({ rows = 2, cols = 0 }, hover.border_size({ "", "─", "", "", "", "─", "", "" }))
    assert.same({ rows = 2, cols = 2 }, hover.border_size({ { "x", "FloatBorder" } }))
  end)
end)

describe("hover.resolve_keys", function()
  it("maps every lhs of a list to the same action and disables snacks' q default", function()
    local keys = hover.resolve_keys(config.defaults().ui.hover.keys)

    assert.equals("close", keys.q)
    assert.equals("close", keys["<Esc>"])
    assert.equals("yank", keys.y)
    assert.equals("replace", keys.r)
    assert.equals("original", keys.o)
    assert.equals("provider", keys.p)
    assert.equals("help", keys["?"])
  end)

  it("disables an entry set to false", function()
    local keys =
      hover.resolve_keys(vim.tbl_extend("force", config.defaults().ui.hover.keys, { close = false, replace = false }))

    for lhs, action in pairs(keys) do
      assert.not_equals("close", action, lhs)
      assert.not_equals("replace", action, lhs)
    end
    assert.is_false(keys.q)
    assert.equals("yank", keys.y)
  end)

  it("accepts a single string per action", function()
    assert.same({ q = false, x = "close" }, hover.resolve_keys({ close = "x" }))
  end)
end)

describe("hover.in_source", function()
  it("refuses a missing, closed, or swapped source window", function()
    local calls = 0
    local fn = function()
      calls = calls + 1
    end

    assert.is_false(hover.in_source(nil, fn))
    assert.is_false(hover.in_source({ buf = 1, win = 99999 }, fn))

    local buf = vim.api.nvim_create_buf(false, true)
    local other = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
    assert.is_false(hover.in_source({ buf = other, win = win }, fn))
    assert.equals(0, calls)

    assert.is_true(hover.in_source({ buf = buf, win = win }, fn))
    assert.equals(1, calls)
    vim.api.nvim_win_close(win, true)
  end)

  it("runs the callback with the source window current and restores the caller", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
    local before = vim.api.nvim_get_current_win()
    local seen

    hover.in_source({ buf = buf, win = win }, function()
      seen = vim.api.nvim_get_current_win()
    end)

    assert.equals(win, seen)
    assert.equals(before, vim.api.nvim_get_current_win())
    vim.api.nvim_win_close(win, true)
  end)
end)

describe("hover state when hidden", function()
  before_each(function()
    hover._reset_for_tests()
  end)

  it("is not open for the current buffer", function()
    assert.is_false(hover.is_open_for(0))
    assert.is_false(hover.is_open_for(nil))
    assert.is_false(hover.is_open_for(vim.api.nvim_get_current_buf()))
  end)

  it("reports a hidden state with no source", function()
    local state = hover.debug()

    assert.equals("hidden", state.state)
    assert.is_nil(state.source)
    assert.equals(0, state.close_count)
    assert.is_nil(state.last_error)
  end)

  it("ignores focus, close, toggle and provider requests", function()
    assert.is_false(hover.focus())
    assert.is_false(hover.close())
    assert.is_false(hover.toggle_original())
    assert.is_false(hover.request_provider())
    assert.is_false(hover.yank())
  end)
end)

describe("hover integration", function()
  local metaphrast = require("metaphrast")
  local original_mode = vim.fn.mode
  local original_feedkeys = vim.api.nvim_feedkeys

  local function count_floats()
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local is_float = vim.api.nvim_win_get_config(win).relative ~= ""
      if is_float and vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "snacks_notif" then
        count = count + 1
      end
    end
    return count
  end

  local function open_buffer(buf_lines, commentstring)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    if commentstring then
      vim.bo[bufnr].commentstring = commentstring
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    return bufnr
  end

  local function translate_open(bufnr, target_lang, last_line)
    local done = false
    metaphrast.translate_range_async(bufnr, 0, last_line or 1, {
      target_lang = target_lang,
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    assert.equals("shown", hover.debug().state)
  end

  ---Set the visual marks a selection translation reads.
  ---@param bufnr integer
  ---@param start_row integer 1-indexed
  ---@param start_col integer 0-indexed
  ---@param end_row integer 1-indexed
  ---@param end_col integer 0-indexed, inclusive
  local function set_visual_marks(bufnr, start_row, start_col, end_row, end_col)
    vim.api.nvim_buf_set_mark(bufnr, "<", start_row, start_col, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", end_row, end_col, {})
  end

  local function translate_selection_open(bufnr, mode, target_lang)
    local done = false
    metaphrast.translate_selection_async(bufnr, mode, {
      target_lang = target_lang,
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    assert.equals("shown", hover.debug().state)
  end

  local function capture_feedkeys()
    local calls = {}
    vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
      calls[#calls + 1] = { keys = keys, mode = mode, escape_ks = escape_ks }
    end
    return calls
  end

  local ui_mod = require("metaphrast.ui")
  local original_select = vim.ui.select
  local original_columns = vim.o.columns

  ---Screen row (1-based) of a 1-based source line, after the mandatory redraw.
  local function screen_row(win, line)
    vim.cmd("redraw")
    return vim.fn.screenpos(win, line, 1).row
  end

  local function outer_pos(win)
    vim.cmd("redraw")
    return vim.api.nvim_win_get_position(win)
  end

  local function translate_range_open(bufnr, target_lang, first_line, last_line)
    local done = false
    metaphrast.translate_range_async(bufnr, first_line, last_line, {
      target_lang = target_lang,
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    assert.equals("shown", hover.debug().state)
  end

  local function notifier_api()
    return ui_mod.require_snacks().notifier
  end

  ---Notifier entries are updated in place, so every history assertion compares
  ---this stamp before and after the action instead of counting entries.
  local function stamp(entry)
    return entry and (entry.updated or entry.added) or 0
  end

  local function progress_entry()
    local found
    for _, entry in ipairs(notifier_api().get_history()) do
      if entry.id == ui_mod.PROGRESS_ID then
        found = entry
      end
    end
    return found
  end

  local function newest_entry()
    local newest
    for _, entry in ipairs(notifier_api().get_history()) do
      if not newest or stamp(entry) >= stamp(newest) then
        newest = entry
      end
    end
    return newest
  end

  ---Put the cursor on the last visible line of the source window and translate
  ---that line, so the hover has no room below and flips above it.
  local function open_above_case()
    local buf_lines = {}
    for i = 1, 200 do
      buf_lines[i] = "// comment " .. i
    end
    local bufnr = open_buffer(buf_lines, "// %s")
    local win = vim.api.nvim_get_current_win()
    local last = vim.api.nvim_win_get_height(win)
    vim.api.nvim_win_set_cursor(win, { last, 0 })
    vim.cmd("redraw")
    assert.equals(last, vim.fn.winline())

    translate_range_open(bufnr, "es", last - 1, last)
    assert.is_false(hover.debug().geometry.below)
    return bufnr, win, last
  end

  ---Our own hover window, told apart from the notifier's toasts (which the
  ---notifier renders on its own timer, from whatever window is current).
  local function is_hover_window(win)
    local wo = win.opts and win.opts.wo
    return type(wo) == "table"
      and type(wo.winhighlight) == "string"
      and wo.winhighlight:find("MetaphrastHoverBorder", 1, true) ~= nil
  end

  ---Record every snacks.win show/update on the hover with the window that was
  ---current at the time, so the `in_source` discipline can be asserted
  ---(acceptance 16).
  local function spy_on_window_writes()
    local win_class = ui_mod.require_snacks().win
    local calls = {}
    local originals = { show = win_class.show, update = win_class.update }
    for _, name in ipairs({ "show", "update" }) do
      win_class[name] = function(self, ...)
        if is_hover_window(self) then
          calls[#calls + 1] = { fn = name, current = vim.api.nvim_get_current_win() }
        end
        return originals[name](self, ...)
      end
    end
    return calls, function()
      win_class.show, win_class.update = originals.show, originals.update
    end
  end

  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
  end)

  after_each(function()
    vim.fn.mode = original_mode
    vim.api.nvim_feedkeys = original_feedkeys
    vim.ui.select = original_select
    vim.o.columns = original_columns
    hover._reset_for_tests()
  end)

  it("opens an unfocused hover whose text is exactly the translation", function()
    local bufnr = open_buffer({ "Hello world" })
    local source_win = vim.api.nvim_get_current_win()

    translate_open(bufnr, "es")

    local state = hover.debug()
    assert.same({ "Hello world [echo]->es" }, state.result.display_lines)
    assert.same({ "Hello world [echo]->es" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
    assert.equals(source_win, vim.api.nvim_get_current_win())
    assert.equals(1, count_floats())
    local win_config = vim.api.nvim_win_get_config(state.win)
    assert.equals("win", win_config.relative)
    assert.equals(source_win, win_config.win)
    assert.same(theme.footer_chips(metaphrast.config.ui.hover.keys, false), win_config.footer)
    assert.is_true(hover.is_open_for(bufnr))
  end)

  it("applies ui.win width and border from setup", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", ui = { win = { width = 55, border = "single" } } })
    local bufnr = open_buffer({ "Hello" })

    translate_open(bufnr, "es")

    local state = hover.debug()
    assert.equals(55, state.geometry.width)
    local win_config = vim.api.nvim_win_get_config(state.win)
    assert.equals(55, win_config.width)
    assert.equals(8, #win_config.border)
    assert.equals("┌", win_config.border[1][1] or win_config.border[1])
  end)

  it("AC6: pads through virtual lines and the statuscolumn, never the text", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", ui = { win = { padding = { top = 1, bottom = 1, left = 2, right = 2 } } } })
    local bufnr = open_buffer({ "Hello" })

    translate_open(bufnr, "es")

    local state = hover.debug()
    assert.same({ "Hello [echo]->es" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
    assert.equals("  ", vim.wo[state.win].statuscolumn)
    assert.equals(2, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_layout, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_hl, 0, -1, {}))
    assert.equals(3, vim.api.nvim_win_get_height(state.win))
  end)

  ---Open a hover over prose with no comment structure whose reply is one long
  ---CJK paragraph: the shape that used to run past the right border.
  ---@param win table|nil `ui.win` overrides.
  ---@return string translated, string[] shown
  local function open_cjk_paragraph(win)
    local ja = "**本書は参考用の機能一覧であり、ロードマップではありません。"
      .. "ここに記載されたすべての機能が移植されるわけではありません。** ganja の目的は "
      .. "opencode v1.18.22 との動作上の同等性を確保することにあります。一方、Claude Code は独立した製品であり、"
      .. "ここでは比較目的でのみ取り上げています。"
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", ui = { win = win or {} } })
    metaphrast.register_provider("canned_ja", {
      translate = function()
        return ja
      end,
    })
    metaphrast.config.provider = "canned_ja"
    vim.o.columns = 200
    local bufnr = open_buffer({
      "> This document is a reference inventory, not a roadmap. Not every feature",
      "> listed here will be ported. ganja's charter is behavioral parity with",
      "> opencode v1.18.22; Claude Code is a separate product, catalogued here.",
    })

    translate_open(bufnr, "ja", 3)

    return ja, vim.api.nvim_buf_get_lines(hover.debug().buf, 0, -1, false)
  end

  it("wraps a CJK translation inside the window even with wrap off", function()
    -- Reported regression: prose with no comment leaders reaches the hover in
    -- source-shaped lines, so a Japanese reply ran past the right border, and
    -- `wo.wrap = false` clipped it outright instead of wrapping.
    local ja, shown = open_cjk_paragraph({
      width = 150,
      padding = { top = 0, bottom = 0, left = 5, right = 5 },
      wo = { wrap = false },
    })

    local state = hover.debug()
    assert.is_false(vim.wo[state.win].wrap)
    assert.is_true(#shown > 1, "one paragraph should wrap onto several lines")
    for _, line in ipairs(shown) do
      assert.is_true(
        vim.fn.strdisplaywidth(line) <= state.geometry.wrap_width,
        string.format("%d > %d: %s", vim.fn.strdisplaywidth(line), state.geometry.wrap_width, line)
      )
    end
    -- Wrapping only moves break points: no character of the reply is dropped.
    assert.equals((ja:gsub("%s+", "")), (table.concat(shown, ""):gsub("%s+", "")))
  end)

  it("leaves nothing for Neovim to soft-wrap in the hover", function()
    local _, shown = open_cjk_paragraph(nil)

    local state = hover.debug()
    assert.is_true(vim.wo[state.win].wrap)
    assert.is_true(#shown > 1, "one paragraph should wrap onto several lines")
    -- Screen rows equal buffer lines (default padding adds no virtual rows), so
    -- every line already fits the text width as written.
    assert.equals(#shown, vim.api.nvim_win_text_height(state.win, {}).all)
  end)

  it("AC3: closes on CursorMoved in the source buffer", function()
    local bufnr = open_buffer({ "Hello world", "second" })
    translate_open(bufnr, "es")

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })

    local state = hover.debug()
    assert.equals("hidden", state.state)
    assert.equals(1, state.close_count)
    assert.equals(0, count_floats())
    assert.is_false(hover.is_open_for(bufnr))
  end)

  it("AC3: closes on InsertEnter in the source buffer", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")

    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = bufnr, modeline = false })

    assert.equals("hidden", hover.debug().state)
    assert.equals(1, hover.debug().close_count)
  end)

  it("leaves visual mode when CursorMoved closes the hover", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    vim.fn.mode = function()
      return "v"
    end
    local calls = capture_feedkeys()

    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })

    local expected_esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    assert.equals("hidden", hover.debug().state)
    assert.equals(1, #calls)
    assert.equals(expected_esc, calls[1].keys)
    assert.equals("nx", calls[1].mode)
    assert.is_false(calls[1].escape_ks)
  end)

  it("does not feed Escape when CursorMovedI closes it in insert mode", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    vim.fn.mode = function()
      return "i"
    end
    local calls = capture_feedkeys()

    vim.api.nvim_exec_autocmds("CursorMovedI", { buffer = bufnr, modeline = false })

    assert.equals("hidden", hover.debug().state)
    assert.equals(0, #calls)
  end)

  it("counts one close per window when a newer hover replaces the old one", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    translate_open(bufnr, "de")
    assert.equals(1, hover.debug().close_count)
    vim.fn.mode = function()
      return "v"
    end
    local calls = capture_feedkeys()

    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })

    assert.equals(2, hover.debug().close_count)
    assert.equals(1, #calls)
  end)

  it("AC4: focuses on the second invocation without moving and closes with q", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    local state = hover.debug()
    vim.cmd("redraw")
    local pos = vim.api.nvim_win_get_position(state.win)

    metaphrast.hover()

    assert.equals("focused", hover.debug().state)
    assert.equals(state.win, vim.api.nvim_get_current_win())
    vim.cmd("redraw")
    assert.same(pos, vim.api.nvim_win_get_position(state.win))
    assert.same(
      theme.footer_chips(metaphrast.config.ui.hover.keys, true),
      vim.api.nvim_win_get_config(state.win).footer
    )
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf, modeline = false })
    assert.equals("focused", hover.debug().state)

    -- Calling hover() from inside the hover is a no-op.
    metaphrast.hover()
    assert.equals("focused", hover.debug().state)

    vim.api.nvim_feedkeys("q", "x", false)

    assert.equals("hidden", hover.debug().state)
    assert.equals(0, count_floats())
  end)

  it("AC5: replaces the source through r, keeping comment leaders", function()
    local bufnr = open_buffer({ "// hello there", "code()" }, "// %s")
    translate_open(bufnr, "es")
    metaphrast.hover()
    assert.equals("focused", hover.debug().state)

    vim.api.nvim_feedkeys("r", "x", false)

    assert.equals("hidden", hover.debug().state)
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("// hello there [echo]->es", buf_lines[1])
    assert.equals("code()", buf_lines[2])
  end)

  it("AC5: refuses to replace when the source changed and stays focused", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    metaphrast.hover()
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Hello edited" })
    local before = stamp(newest_entry())

    assert.is_false(hover.replace())

    assert.equals("focused", hover.debug().state)
    assert.equals("Hello edited", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    local entry = newest_entry()
    assert.is_true(stamp(entry) > before)
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:find("not applied", 1, true))
  end)

  it("AC5: replaces a charwise selection through r exactly like the sync path", function()
    local input = { "// hello there", "code()" }
    local reference = open_buffer(input, "// %s")
    set_visual_marks(reference, 1, 0, 1, 13)
    metaphrast.translate_selection(reference, "v", { target_lang = "es", replace = true })
    local expected = vim.api.nvim_buf_get_lines(reference, 0, -1, false)
    assert.equals("// hello there [echo]->es", expected[1])

    local bufnr = open_buffer(input, "// %s")
    set_visual_marks(bufnr, 1, 0, 1, 13)
    translate_selection_open(bufnr, "v", "es")
    metaphrast.hover()

    vim.api.nvim_feedkeys("r", "x", false)

    assert.equals("hidden", hover.debug().state)
    assert.same(expected, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC5: replaces a blockwise selection through r exactly like the sync path", function()
    -- Columns 2-6 of the first two lines; the `x ` prefix and `code()` stay.
    local input = { "x aa bb", "x cc dd", "code()" }
    local reference = open_buffer(input)
    set_visual_marks(reference, 1, 2, 2, 6)
    metaphrast.translate_selection(reference, "\22", { target_lang = "es", replace = true })
    local expected = vim.api.nvim_buf_get_lines(reference, 0, -1, false)
    assert.not_same(input, expected)
    assert.equals("code()", expected[3])
    assert.truthy(expected[1]:match("^x "))
    assert.truthy(table.concat(expected, "\n"):find("[echo]->es", 1, true))

    local bufnr = open_buffer(input)
    set_visual_marks(bufnr, 1, 2, 2, 6)
    translate_selection_open(bufnr, "\22", "es")
    metaphrast.hover()

    vim.api.nvim_feedkeys("r", "x", false)

    assert.equals("hidden", hover.debug().state)
    assert.same(expected, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("blockwise AC2: keeps the wrapped surplus line when r replaces a blockwise comment selection", function()
    -- The block covers the `// ` column, so the two rows merge into one
    -- paragraph and re-wrap to three lines — one more than the block has rows.
    local bufnr = open_buffer({ "  // hello there  TAIL1", "  // second line  TAIL2", "x := 1" }, "// %s")
    set_visual_marks(bufnr, 1, 2, 2, 15)
    translate_selection_open(bufnr, "\22", "es")
    metaphrast.hover()

    vim.api.nvim_feedkeys("r", "x", false)

    assert.equals("hidden", hover.debug().state)
    assert.same({
      "  // hello there  TAIL1",
      "  // second line  TAIL2",
      "  // [echo]->es",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC8: reports a refused write-back as an error on the progress id", function()
    local bufnr = open_buffer({ "Hello world" })
    local before = stamp(progress_entry())

    metaphrast.command({ range = 1, line1 = 1, line2 = 1, fargs = { "es" }, bang = true })
    -- The result lands on the main loop; edit the line while it is in flight.
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Hello edited" })

    assert.is_true(vim.wait(1000, function()
      local current = progress_entry()
      return stamp(current) > before and current.msg ~= "Translating..."
    end))
    local entry = progress_entry()
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:find("not applied", 1, true))
    assert.equals("Hello edited", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.equals("hidden", hover.debug().state)
    -- The command path reports through the progress id only; a fresh error
    -- toast on top of it would double-report the same refusal.
    assert.equals(ui_mod.PROGRESS_ID, newest_entry().id)
  end)

  it("AC17: warns that a blank selection had nothing to translate instead of reporting a success", function()
    -- `'>` lands before `'<` on the short last row, so every row of the block
    -- clamps to nothing and the provider is never called.
    local original = { "    // alpha beta gamma", "ab" }
    local bufnr = open_buffer(original, "// %s")
    set_visual_marks(bufnr, 1, 4, 2, 22)
    local before = stamp(progress_entry())

    metaphrast.command({ fargs = { "es" }, bang = true, visual_mode = "\22" })

    assert.is_true(vim.wait(1000, function()
      local current = progress_entry()
      return stamp(current) > before and current.msg ~= "Translating..."
    end))
    local entry = progress_entry()
    -- A no-op is not a failure, so it warns; only a refused write-back errors.
    assert.equals("warn", entry.level)
    assert.equals("metaphrast: nothing to translate in the selection", entry.msg)
    assert.same(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    -- Nothing was translated, so nothing may claim it was.
    assert.equals(ui_mod.PROGRESS_ID, newest_entry().id)
    assert.is_nil(entry.msg:find("Translated via", 1, true))
  end)

  it("returns applied = true from the sync API when the source is unchanged", function()
    local bufnr = open_buffer({ "Hello world" })
    local translated_before, applied_before = metaphrast.translate_range(bufnr, 0, 1, { target_lang = "es" })
    assert.equals("Hello world [echo]->es", translated_before)
    assert.is_nil(applied_before)

    local _, applied = metaphrast.translate_range(bufnr, 0, 1, { target_lang = "es", replace = true })

    assert.is_true(applied)
    assert.equals("Hello world [echo]->es", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)

  it("returns applied = false and toasts once when the sync write-back is refused", function()
    local bufnr = open_buffer({ "Hello sync refusal" })
    -- Edit the range from inside the provider, so the write-back re-reads text
    -- other than the lines it was handed and has to refuse.
    metaphrast.register_provider("mutating", {
      translate = function(_, payload)
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Hello CHANGED" })
        return payload.text .. " [mutating]"
      end,
    })
    local notifier = notifier_api()
    local before = #notifier.get_history()

    local _, applied, reason =
      metaphrast.translate_range(bufnr, 0, 1, { provider = "mutating", target_lang = "es", replace = true })

    assert.is_false(applied)
    assert.truthy(reason:find("not applied", 1, true))
    assert.equals("Hello CHANGED", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    local history = notifier.get_history()
    assert.equals(before + 1, #history)
    assert.equals("error", history[#history].level)
    assert.equals(reason, history[#history].msg)
  end)

  it("keeps hover() read-only when config.replace is true", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", replace = true })
    local bufnr = open_buffer({ "Hello world" })

    metaphrast.hover()

    assert.is_true(vim.wait(1000, function()
      return hover.debug().state == "shown"
    end))
    assert.equals("Hello world", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.same({ "Hello world [echo]->en" }, hover.debug().result.display_lines)
    assert.equals(1, count_floats())
  end)

  it("acts on the bang without a range instead of focusing the open hover", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    local source_win = vim.api.nvim_get_current_win()

    metaphrast.command({ range = 0, line1 = 1, line2 = 1, fargs = { "es" }, bang = true })

    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= "Hello world"
    end))
    assert.equals("Hello world [echo]->es", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.equals(source_win, vim.api.nvim_get_current_win())
    -- The bang overwrote the lines that hover translated, so it is closed
    -- rather than left showing a translation of text that is gone.
    assert.equals("hidden", hover.debug().state)
    assert.equals(0, count_floats())
  end)

  it("sets the hover buffer filetype once across focus, o and VimResized", function()
    local seen = {}
    local group = vim.api.nvim_create_augroup("metaphrast_spec_filetype", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      callback = function(args)
        seen[args.buf] = (seen[args.buf] or 0) + 1
      end,
    })
    local bufnr = open_buffer({ "// hello there" }, "// %s")

    translate_open(bufnr, "es")
    metaphrast.hover()
    assert.is_true(hover.toggle_original())
    vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
    -- `show()` queues two post-render corrections (one scheduled, one deferred
    -- by 100 ms) and the resize queues a third. Wait for all three rather than
    -- sleeping, so a slow runner cannot make the count below vacuous.
    assert.is_true(vim.wait(1000, function()
      return hover.debug().corrections >= 3
    end))

    local state = hover.debug()
    assert.equals("markdown", vim.bo[state.buf].filetype)
    assert.equals(1, seen[state.buf])
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("AC3: closes with its source window", function()
    vim.cmd("vsplit")
    local source_win = vim.api.nvim_get_current_win()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")

    vim.api.nvim_win_close(source_win, true)

    assert.equals("hidden", hover.debug().state)
    assert.equals(1, hover.debug().close_count)
    assert.equals(0, count_floats())
  end)

  it("keeps its position through the CursorHold correction", function()
    local bufnr = open_buffer({ "// hello there" }, "// %s")
    translate_open(bufnr, "es")
    metaphrast.hover()
    local state = hover.debug()
    -- A float's screen position is only final once it has been laid out, and
    -- the post-render corrections can still move it; sample it after two reads
    -- agree, so the comparison below is about CursorHold and nothing else.
    local pos = outer_pos(state.win)
    assert.is_true(vim.wait(1000, function()
      local now = outer_pos(state.win)
      local settled = now[1] == pos[1] and now[2] == pos[2]
      pos = now
      return settled
    end))

    vim.api.nvim_exec_autocmds("CursorHold", { buffer = state.buf, modeline = false })

    assert.equals("focused", hover.debug().state)
    assert.same(pos, outer_pos(state.win))
    assert.is_nil(hover.debug().last_error)
  end)

  it("ignores VimResized while a provider pick is pending", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    metaphrast.hover()
    vim.ui.select = function() end -- never calls back: the pick stays open
    assert.is_true(hover.request_provider())
    assert.equals("pending", hover.debug().state)

    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
    end)

    assert.equals("pending", hover.debug().state)
    assert.is_true(vim.api.nvim_win_is_valid(hover.debug().win))
  end)

  it("AC13: warns when no other provider is registered and stays focused", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    metaphrast.hover()
    local registry = require("metaphrast.providers")
    registry.reset()
    registry.register("echo", require("metaphrast.providers.echo"))
    local hover_win = hover.debug().win
    local before = stamp(newest_entry())

    assert.is_false(hover.request_provider())

    assert.equals("focused", hover.debug().state)
    assert.equals(hover_win, vim.api.nvim_get_current_win())
    local entry = newest_entry()
    assert.is_true(stamp(entry) > before)
    assert.equals("warn", entry.level)
    assert.truthy(entry.msg:find("no other provider", 1, true))
  end)

  it("AC13: hides the progress toast, raises a fresh error and refocuses on a failed retranslation", function()
    metaphrast.register_provider("boom", {
      translate = function()
        error("transport down")
      end,
    })
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    metaphrast.hover()
    local hover_win = hover.debug().win
    local notifier = notifier_api()
    local hidden = {}
    local original_hide = notifier.hide
    notifier.hide = function(id)
      hidden[#hidden + 1] = id
      return original_hide(id)
    end
    local before = stamp(newest_entry())
    vim.ui.select = function(_, _, on_choice)
      on_choice("boom")
    end

    local ok, err = pcall(function()
      assert.is_true(hover.request_provider())

      assert.is_true(vim.wait(1000, function()
        local newest = newest_entry()
        return hover.debug().state == "focused" and stamp(newest) > before and newest.level == "error"
      end))
      local entry = newest_entry()
      assert.truthy(entry.msg:find("transport down", 1, true))
      assert.not_equals(ui_mod.PROGRESS_ID, entry.id)
      assert.is_true(vim.tbl_contains(hidden, ui_mod.PROGRESS_ID))
      -- The progress id was hidden, never finished with the error.
      assert.equals("Translating...", progress_entry().msg)
      assert.equals(hover_win, vim.api.nvim_get_current_win())
    end)

    notifier.hide = original_hide
    assert.is_true(ok, tostring(err))
  end)

  it("AC9: applies the teal theme to a live window after the link theme was used", function()
    theme.ensure_highlights("link")
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", ui = { hover = { theme = "teal" } } })
    local bufnr = open_buffer({ "Hello world" })

    translate_open(bufnr, "es")

    local state = hover.debug()
    assert.truthy(vim.wo[state.win].winhighlight:find("FloatBorder:MetaphrastHoverBorder", 1, true))
    assert.equals(0x2dd4bf, vim.api.nvim_get_hl(0, { name = "MetaphrastHoverBorder", link = false }).fg)
    theme._reset_for_tests()
  end)

  it("AC5: toggles the original text with o and yanks only the translation", function()
    local bufnr = open_buffer({ "// hello there" }, "// %s")
    translate_open(bufnr, "es")
    metaphrast.hover()
    local state = hover.debug()

    vim.api.nvim_feedkeys("o", "x", false)

    assert.same({ "hello there", "hello there [echo]->es" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_hl, 0, -1, {}))

    vim.fn.setreg('"', "")
    vim.api.nvim_feedkeys("y", "x", false)
    assert.equals("hello there [echo]->es", vim.fn.getreg('"'))

    vim.api.nvim_feedkeys("o", "x", false)
    assert.same({ "hello there [echo]->es" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
  end)

  it("AC15: refuses to open when the source window is not current", function()
    local bufnr = open_buffer({ "Hello world" })
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    local notifier = require("metaphrast.ui").require_snacks().notifier
    local before = #notifier.get_history()

    local shown = require("metaphrast.ui").show(
      { buf = bufnr, win = source_win, sr = 0, er = 0, lines = { "Hello world" } },
      { translated = "hola", display_lines = { "hola" }, meta = {}, opts = {} }
    )

    assert.is_false(shown)
    assert.equals("hidden", hover.debug().state)
    assert.equals(0, count_floats())
    local history = notifier.get_history()
    assert.equals(before + 1, #history)
    local entry = history[#history]
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:find("hola", 1, true))
    vim.api.nvim_win_close(other_win, true)
  end)

  it("forgets the source and the result when the geometry is refused", function()
    local bufnr = open_buffer({ "Hello world" })
    local source_win = vim.api.nvim_get_current_win()
    -- `compute()` gives up when it cannot run inside the source window.
    local original_in_source = hover.in_source
    hover.in_source = function()
      return false
    end

    local ok, shown = pcall(
      ui_mod.show,
      { buf = bufnr, win = source_win, sr = 0, er = 0, lines = { "Hello world" } },
      { translated = "hola", display_lines = { "hola" }, meta = {}, opts = {} }
    )
    hover.in_source = original_in_source

    assert.is_true(ok, tostring(shown))
    assert.is_false(shown)
    local state = hover.debug()
    assert.equals("hidden", state.state)
    assert.is_nil(state.source)
    assert.is_nil(state.result)
    assert.equals("source window changed", state.last_error)
    assert.equals(0, count_floats())
  end)

  it("forgets the source and the result when the window constructor refuses", function()
    local bufnr = open_buffer({ "Hello world" })
    local source_win = vim.api.nvim_get_current_win()
    local snacks = ui_mod.require_snacks()
    local original_win = snacks.win
    snacks.win = function()
      return nil
    end

    local ok, shown = pcall(
      ui_mod.show,
      { buf = bufnr, win = source_win, sr = 0, er = 0, lines = { "Hello world" } },
      { translated = "hola", display_lines = { "hola" }, meta = {}, opts = {} }
    )
    snacks.win = original_win

    assert.is_true(ok, tostring(shown))
    assert.is_false(shown)
    local state = hover.debug()
    assert.equals("hidden", state.state)
    assert.is_nil(state.source)
    assert.is_nil(state.result)
    assert.equals("window not created", state.last_error)
    assert.equals(0, count_floats())
  end)

  it("re-arms the unknown ui.win key warning on reset", function()
    local warns = 0
    local function notify()
      warns = warns + 1
    end

    metaphrast._reset_for_tests()
    config.warn_unknown_win_keys({ bogus = true }, notify)
    assert.equals(1, warns)
    -- Warn-once: the same key stays silent for the rest of the session.
    config.warn_unknown_win_keys({ bogus = true }, notify)
    assert.equals(1, warns)

    -- The reset re-arms it, so one spec's warning cannot silence the next.
    metaphrast._reset_for_tests()
    config.warn_unknown_win_keys({ bogus = true }, notify)
    assert.equals(2, warns)
  end)
  it("AC2: opens one non-toast float anchored under the translated range", function()
    local bufnr = open_buffer({ "line one", "line two", "line three", "line four" })
    local source_win = vim.api.nvim_get_current_win()

    translate_range_open(bufnr, "ja", 0, 3)

    local state = hover.debug()
    assert.equals(1, count_floats())
    local win_config = vim.api.nvim_win_get_config(state.win)
    assert.equals("win", win_config.relative)
    assert.equals(source_win, win_config.win)
    assert.equals(source_win, vim.api.nvim_get_current_win())
    -- Outer top-left is 0-based, screenpos is 1-based; the anchor is the last
    -- line of the range, offset by the configured row.
    assert.equals(screen_row(source_win, 3) - 1 + metaphrast.config.ui.win.row, outer_pos(state.win)[1])
  end)

  it("AC9: themes the border through winhighlight on the live window", function()
    local bufnr = open_buffer({ "Hello world" })

    translate_open(bufnr, "es")

    local state = hover.debug()
    assert.truthy(vim.wo[state.win].winhighlight:find("FloatBorder:MetaphrastHoverBorder", 1, true))
    for _, group in ipairs({ "MetaphrastHoverBorder", "MetaphrastHoverTitle", "MetaphrastHoverChip" }) do
      assert.is_true(next(vim.api.nvim_get_hl(0, { name = group })) ~= nil, group .. " is undefined")
    end
  end)

  it("AC4: leaves a pending provider pick alone", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    metaphrast.hover()
    vim.ui.select = function() end -- never calls back: the pick stays open

    assert.is_true(hover.request_provider())
    assert.equals("pending", hover.debug().state)

    metaphrast.hover()
    assert.equals("pending", hover.debug().state)
    assert.is_false(hover.focus())
    assert.equals("pending", hover.debug().state)
  end)

  it("AC5: yanks the translation into the unnamed and clipboard registers", function()
    local bufnr = open_buffer({ "// hello there" }, "// %s")
    translate_open(bufnr, "es")
    metaphrast.hover()
    vim.fn.setreg('"', "")

    assert.is_true(hover.yank())

    local expected = hover.debug().result.translated
    assert.equals(expected, vim.fn.getreg('"'))
    if vim.fn.has("clipboard") == 1 then
      assert.equals(expected, vim.fn.getreg("+"))
    end
  end)

  it("AC5: grows downward on o and restores the window when toggled back", function()
    local bufnr = open_buffer({ "// hello there" }, "// %s")
    translate_open(bufnr, "es")
    metaphrast.hover()
    local state = hover.debug()
    local pos = outer_pos(state.win)
    local height = vim.api.nvim_win_get_height(state.win)
    local original_count = 1

    assert.is_true(hover.toggle_original())

    assert.equals(height + original_count + 1, vim.api.nvim_win_get_height(state.win))
    assert.same(pos, outer_pos(state.win))

    assert.is_true(hover.toggle_original())

    assert.equals(height, vim.api.nvim_win_get_height(state.win))
    assert.same(pos, outer_pos(state.win))
    assert.same({ "hello there [echo]->es" }, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
  end)

  it("AC5: grows upward on o above the range, keeping the bottom border fixed", function()
    local _, source_win, _ = open_above_case()
    metaphrast.hover()
    local state = hover.debug()
    local pos = outer_pos(state.win)
    local height = vim.api.nvim_win_get_height(state.win)
    assert.equals(source_win, vim.api.nvim_win_get_config(state.win).win)

    assert.is_true(hover.toggle_original())

    local grown = vim.api.nvim_win_get_height(state.win)
    local moved = outer_pos(state.win)
    assert.equals(height + 1 + 1, grown)
    assert.equals(pos[1] - (1 + 1), moved[1])
    assert.equals(pos[1] + height, moved[1] + grown)
  end)

  it("AC7: places the bottom border above the anchor line in the above case", function()
    local _, source_win, last = open_above_case()

    local state = hover.debug()
    local pos = outer_pos(state.win)
    local height = vim.api.nvim_win_get_height(state.win)
    local border_rows = 2

    assert.equals(screen_row(source_win, last) - 1 - (metaphrast.config.ui.win.row - 1), pos[1] + height + border_rows)
  end)

  it("AC6: keeps the buffer text equal to display_lines and chrome in extmarks", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({
      provider = "echo",
      ui = { win = { padding = { top = 1, bottom = 1, left = 3, right = 1 } } },
    })
    local bufnr = open_buffer({ "// hello there" }, "// %s")

    translate_open(bufnr, "es")

    local state = hover.debug()
    assert.same(state.result.display_lines, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
    assert.equals(string.rep(" ", 3), vim.wo[state.win].statuscolumn)
    assert.equals(2, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_layout, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_hl, 0, -1, {}))

    metaphrast.hover()
    assert.is_true(hover.toggle_original())

    -- The separator is one more layout extmark; the original block is one
    -- highlight extmark spanning it.
    assert.equals(3, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_layout, 0, -1, {}))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_hl, 0, -1, {}))
  end)

  it("AC8: advances the progress toast in place on success", function()
    local bufnr = open_buffer({ "Hello world" })
    local before = stamp(progress_entry())

    metaphrast.command({ range = 1, line1 = 1, line2 = 1, fargs = { "es" }, bang = false })

    -- The same id carries "Translating..." first, so wait for the result to
    -- replace it in place rather than for the first update.
    assert.is_true(vim.wait(1000, function()
      local current = progress_entry()
      return stamp(current) > before and current.msg ~= "Translating..."
    end))
    local entry = progress_entry()
    assert.equals("info", entry.level)
    assert.truthy(entry.msg:find("echo", 1, true))
    assert.equals(bufnr, vim.api.nvim_get_current_buf())
  end)

  it("AC8: reports a failed translation on the same progress id", function()
    -- setup() re-registers the built-in providers, so the stub is registered
    -- after it and selected by writing the resolved config directly.
    metaphrast.register_provider("boom", {
      translate = function()
        error("provider exploded")
      end,
    })
    metaphrast.config.provider = "boom"
    open_buffer({ "Hello world" })
    local before = stamp(progress_entry())

    metaphrast.command({ range = 1, line1 = 1, line2 = 1, fargs = { "es" }, bang = false })

    assert.is_true(vim.wait(1000, function()
      local current = progress_entry()
      return stamp(current) > before and current.msg ~= "Translating..."
    end))
    local entry = progress_entry()
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:find("provider exploded", 1, true))
    assert.equals("hidden", hover.debug().state)
  end)

  it("AC10: honors the user's real ui.win table", function()
    vim.o.columns = 200
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", ui = { win = USER_WIN } })
    local bufnr = open_buffer({ "// hello there", "code()" }, "// %s")
    local source_win = vim.api.nvim_get_current_win()

    translate_open(bufnr, "es")

    local state = hover.debug()
    local win_config = vim.api.nvim_win_get_config(state.win)
    assert.equals(150, win_config.width)
    assert.equals(8, #win_config.border)
    for i, cell in ipairs(win_config.border) do
      assert.equals(USER_WIN.border[i], type(cell) == "table" and cell[1] or cell)
    end
    assert.is_false(vim.wo[state.win].wrap)
    assert.equals(string.rep(" ", 5), vim.wo[state.win].statuscolumn)
    assert.equals(2, #vim.api.nvim_buf_get_extmarks(state.buf, theme.ns_layout, 0, -1, {}))
    assert.equals(#state.result.display_lines + 2, vim.api.nvim_win_get_height(state.win))
    assert.equals(screen_row(source_win, 1) - 1 + 2, outer_pos(state.win)[1])

    vim.o.columns = original_columns
  end)

  it("AC13: retranslates through p and keeps the hover focused", function()
    metaphrast.register_provider("stub", {
      translate = function(_, payload)
        return payload.text .. " [stub]"
      end,
    })
    local bufnr = open_buffer({ "// hello there" }, "// %s")
    translate_open(bufnr, "es")
    metaphrast.hover()
    local hover_win = hover.debug().win
    vim.ui.select = function(items, _, on_choice)
      assert.is_false(vim.tbl_contains(items, "echo"))
      on_choice("stub")
    end

    assert.is_true(hover.request_provider())

    assert.is_true(vim.wait(1000, function()
      return hover.debug().state == "focused"
    end))
    local state = hover.debug()
    assert.equals("stub", state.result.meta.provider)
    assert.same({ "hello there [stub]" }, state.result.display_lines)
    assert.equals(state.win, vim.api.nvim_get_current_win())
    assert.equals("echo", metaphrast.config.provider)

    assert.is_true(hover.replace())
    assert.equals("// hello there [stub]", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.is_not.equals(hover_win, nil)
  end)

  it("AC13: reports an unconfigured provider and stays focused", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")
    metaphrast.hover()
    local before = stamp(newest_entry())
    vim.ui.select = function(_, _, on_choice)
      on_choice("deepl")
    end

    assert.is_true(hover.request_provider())

    assert.is_true(vim.wait(1000, function()
      return hover.debug().state == "focused"
    end))
    local entry = newest_entry()
    assert.is_true(stamp(entry) > before)
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:lower():find("deepl", 1, true))
    assert.equals(hover.debug().win, vim.api.nvim_get_current_win())
  end)

  it("AC13: re-enters the hover when the provider pick is cancelled", function()
    local bufnr = open_buffer({ "Hello world" })
    local source_win = vim.api.nvim_get_current_win()
    translate_open(bufnr, "es")
    metaphrast.hover()
    vim.ui.select = function(_, _, on_choice)
      -- A floating picker restores the source window before calling back.
      vim.api.nvim_set_current_win(source_win)
      on_choice(nil)
    end

    assert.is_true(hover.request_provider())

    assert.is_true(vim.wait(1000, function()
      return hover.debug().state == "focused"
    end))
    assert.equals(hover.debug().win, vim.api.nvim_get_current_win())
  end)

  it("AC15: refuses to open when the source window was closed", function()
    local bufnr = open_buffer({ "Hello world" })
    vim.cmd("vsplit")
    local doomed = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(doomed, true)
    local before = stamp(newest_entry())

    local shown = ui_mod.show(
      { buf = bufnr, win = doomed, sr = 0, er = 0, lines = { "Hello world" } },
      { translated = "hola", display_lines = { "hola" }, meta = {}, opts = {} }
    )

    assert.is_false(shown)
    assert.equals("hidden", hover.debug().state)
    assert.equals(0, count_floats())
    local entry = newest_entry()
    assert.is_true(stamp(entry) > before)
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:find("hola", 1, true))
  end)

  it("AC15: refuses to open when the source window shows another buffer", function()
    local bufnr = open_buffer({ "Hello world" })
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_win, vim.api.nvim_create_buf(false, true))
    local before = stamp(newest_entry())

    local shown = ui_mod.show(
      { buf = bufnr, win = source_win, sr = 0, er = 0, lines = { "Hello world" } },
      { translated = "hola", display_lines = { "hola" }, meta = {}, opts = {} }
    )

    assert.is_false(shown)
    assert.equals("hidden", hover.debug().state)
    assert.equals(0, count_floats())
    local entry = newest_entry()
    assert.is_true(stamp(entry) > before)
    assert.equals("error", entry.level)
    assert.truthy(entry.msg:find("hola", 1, true))
  end)

  it("AC15: closes an open hover when the source window swaps buffers", function()
    local bufnr = open_buffer({ "Hello world" })
    translate_open(bufnr, "es")

    vim.cmd("enew")

    assert.equals("hidden", hover.debug().state)
    assert.equals(1, hover.debug().close_count)
    assert.equals(0, count_floats())
  end)

  it("AC14: still fits its content after render-markdown renders it", function()
    if vim.env.RENDER_MARKDOWN ~= "1" then
      return -- only the e2e job puts render-markdown.nvim on the runtimepath
    end
    assert.is_true(pcall(require, "render-markdown"))
    local bufnr = open_buffer({
      "# Heading",
      "",
      "- one item",
      "- another item",
    })

    translate_range_open(bufnr, "es", 0, 4)

    local state = hover.debug()
    assert.equals("markdown", vim.bo[state.buf].filetype)
    -- Conceal and virtual lines change the rendered height after the window was
    -- sized; the post-render correction has to catch up with them.
    assert.is_true(
      vim.wait(1000, function()
        return vim.api.nvim_win_text_height(state.win, {}).all <= vim.api.nvim_win_get_height(state.win)
      end),
      "rendered height overflows the window"
    )
  end)

  it("AC16: writes the window only while the source window is current", function()
    local bufnr = open_buffer({ "// hello there" }, "// %s")
    local source_win = vim.api.nvim_get_current_win()
    local calls, restore = spy_on_window_writes()

    local ok, err = pcall(function()
      translate_open(bufnr, "es")
      assert.is_true(#calls > 0)

      metaphrast.hover()
      assert.is_true(hover.toggle_original())
      -- Let the scheduled and deferred post-render corrections run.
      vim.wait(200)

      local state = hover.debug()
      local pos = outer_pos(state.win)
      vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
      vim.wait(50)
      assert.same(pos, outer_pos(state.win))

      for _, call in ipairs(calls) do
        assert.equals(source_win, call.current, call.fn .. " ran outside the source window")
      end
    end)

    restore()
    assert.is_true(ok, tostring(err))
  end)
end)
