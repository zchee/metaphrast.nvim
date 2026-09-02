if vim.fn.has("win32") == 1 then
  return -- Windows out of scope (decision 2026-09-02)
end

local theme = require("metaphrast.ui.theme")

local TEAL = 0x2dd4bf

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

local DEFAULT_KEYS = {
  close = { "q", "<Esc>" },
  yank = "y",
  replace = "r",
  original = "o",
  provider = "p",
  help = "?",
}

describe("theme.title_chips", function()
  it("builds icon, title, provider, language and cache chips", function()
    local chips = theme.title_chips(
      { icon = "󰊿", provider = "deepl", cached = true },
      { source_lang = "en", target_lang = "ja" }
    )

    assert.same({
      { " 󰊿 ", "MetaphrastHoverIcon" },
      { " Translate ", "MetaphrastHoverTitle" },
      { " deepl ", "MetaphrastHoverChip" },
      { " en → ja ", "MetaphrastHoverChip" },
      { " cache ", "MetaphrastHoverChipCache" },
    }, chips)
  end)

  it("omits the cache chip when the result was not cached", function()
    local chips = theme.title_chips({ provider = "echo" }, { source_lang = "en", target_lang = "ja" })

    for _, chip in ipairs(chips) do
      assert.not_equals("MetaphrastHoverChipCache", chip[2])
    end
    assert.same({ " echo ", "MetaphrastHoverChip" }, chips[2])
  end)

  it("labels an unknown source language as auto", function()
    local chips = theme.title_chips({ provider = "echo" }, { target_lang = "ja" })

    assert.same({ " auto → ja ", "MetaphrastHoverChip" }, chips[3])
  end)

  it("gives every chip its own surrounding spaces", function()
    local chips = theme.title_chips({ icon = "󰊿", provider = "deepl" }, { source_lang = "en", target_lang = "ja" })

    for _, chip in ipairs(chips) do
      assert.equals(" ", chip[1]:sub(1, 1))
      assert.equals(" ", chip[1]:sub(-1))
    end
  end)
end)

describe("theme.footer_chips", function()
  it("advertises every key in order when focused", function()
    local chips = theme.footer_chips(DEFAULT_KEYS, true)

    assert.same({
      { " ", "SnacksFooter" },
      { " q ", "SnacksFooterKey" },
      { " close ", "SnacksFooterDesc" },
      { " ", "SnacksFooter" },
      { " y ", "SnacksFooterKey" },
      { " yank ", "SnacksFooterDesc" },
      { " ", "SnacksFooter" },
      { " r ", "SnacksFooterKey" },
      { " replace ", "SnacksFooterDesc" },
      { " ", "SnacksFooter" },
      { " o ", "SnacksFooterKey" },
      { " original ", "SnacksFooterDesc" },
      { " ", "SnacksFooter" },
      { " p ", "SnacksFooterKey" },
      { " provider ", "SnacksFooterDesc" },
      { " ", "SnacksFooter" },
      { " ? ", "SnacksFooterKey" },
      { " help ", "SnacksFooterDesc" },
      { " ", "SnacksFooter" },
    }, chips)
  end)

  it("skips a key disabled with false", function()
    local keys = vim.tbl_extend("force", DEFAULT_KEYS, { replace = false })

    local chips = theme.footer_chips(keys, true)

    for _, chip in ipairs(chips) do
      assert.not_equals(" replace ", chip[1])
      assert.not_equals(" r ", chip[1])
    end
  end)

  it("tells the user how to focus when unfocused", function()
    assert.same({ { " press again to focus ", "MetaphrastHoverFooter" } }, theme.footer_chips(DEFAULT_KEYS, false))
  end)
end)

describe("theme.separator_text", function()
  it("renders the language pair", function()
    assert.equals("── en → ja ──", theme.separator_text({ source_lang = "en", target_lang = "ja" }))
  end)

  it("falls back to auto for an unknown source language", function()
    assert.equals("── auto → ja ──", theme.separator_text({ target_lang = "ja" }))
  end)
end)

describe("theme.winhighlight", function()
  it("maps FloatBorder, which snacks' own default leaves out", function()
    assert.equals(
      "Normal:SnacksNormal,NormalNC:SnacksNormalNC,WinBar:SnacksWinBar,WinBarNC:SnacksWinBarNC,"
        .. "FloatBorder:MetaphrastHoverBorder,FloatTitle:MetaphrastHoverTitle,"
        .. "FloatFooter:MetaphrastHoverFooter,WinSeparator:SnacksWinSeparator",
      theme.winhighlight()
    )
  end)
end)

describe("theme.ensure_highlights", function()
  before_each(function()
    theme._reset_for_tests()
  end)

  after_each(function()
    theme._reset_for_tests()
  end)

  it("defines every group as a colorscheme link under the link theme", function()
    theme.ensure_highlights("link")

    for _, name in ipairs(GROUPS) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.is_true(hl.link ~= nil, name .. " is not linked")
      assert.not_equals(TEAL, vim.api.nvim_get_hl(0, { name = name, link = false }).fg)
    end
  end)

  it("applies the legacy palette under the teal theme", function()
    theme.ensure_highlights("teal")

    assert.equals(TEAL, vim.api.nvim_get_hl(0, { name = "MetaphrastHoverBorder", link = false }).fg)
    assert.equals(TEAL, vim.api.nvim_get_hl(0, { name = "MetaphrastHoverTitle", link = false }).fg)
    assert.equals(0x6b7280, vim.api.nvim_get_hl(0, { name = "MetaphrastHoverFooter", link = false }).fg)
    assert.is_true(vim.api.nvim_get_hl(0, { name = "MetaphrastHoverChip" }).link ~= nil)
  end)

  it("re-arms the defaults after a reset so a theme switch takes effect", function()
    theme.ensure_highlights("link")
    assert.not_equals(TEAL, vim.api.nvim_get_hl(0, { name = "MetaphrastHoverBorder", link = false }).fg)

    theme._reset_for_tests()
    theme.ensure_highlights("teal")

    assert.equals(TEAL, vim.api.nvim_get_hl(0, { name = "MetaphrastHoverBorder", link = false }).fg)
  end)

  it("falls back to the link theme for an unknown name", function()
    assert.equals("link", theme.ensure_highlights("nope"))
  end)
end)
