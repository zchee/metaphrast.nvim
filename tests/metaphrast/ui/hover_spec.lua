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
