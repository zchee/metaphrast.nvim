local config = require("metaphrast.config")

describe("config.defaults", function()
  after_each(function()
    vim.env.GOOGLE_API_KEY = nil
    vim.env.GOOGLE_TRANSLATE_KEY = nil
    vim.env.GOOGLE_APPLICATION_CREDENTIALS = nil
  end)

  it("returns a table", function()
    local d = config.defaults()
    assert.is_table(d)
  end)

  it("has required top-level fields", function()
    local d = config.defaults()
    assert.is_string(d.provider)
    assert.is_string(d.icon)
    assert.is_string(d.target_lang)
    assert.is_boolean(d.replace)
    assert.is_number(d.max_chars)
  end)

  it("has cache config", function()
    local d = config.defaults()
    assert.is_table(d.cache)
    assert.is_boolean(d.cache.enabled)
    assert.is_number(d.cache.ttl)
    assert.is_string(d.cache.dir)
    assert.is_number(d.cache.max_estimated_cost)
    assert.is_boolean(d.cache.memory_enabled)
    assert.is_number(d.cache.memory_max_entries)
    assert.is_number(d.cache.memory_skip_disk_ttl)
  end)

  it("has http config", function()
    local d = config.defaults()
    assert.is_table(d.http)
    assert.is_number(d.http.timeout)
    assert.is_string(d.http.backend)
  end)

  it("has provider configs", function()
    local d = config.defaults()
    assert.is_table(d.providers)
    assert.is_table(d.providers.echo)
    assert.is_table(d.providers.google)
    assert.is_table(d.providers.deepl)
    assert.is_table(d.providers.openai)
    assert.is_table(d.providers.gemini)
    assert.is_table(d.providers.openrouter)
  end)

  it("has ui config", function()
    local d = config.defaults()
    assert.is_table(d.ui)
    assert.is_table(d.ui.win)
  end)

  it("has hover window defaults", function()
    local w = config.defaults().ui.win

    assert.is_nil(w.border)
    assert.is_nil(w.width)
    assert.is_nil(w.height)
    assert.equals(0.6, w.max_width)
    assert.equals(0.5, w.max_height)
    assert.is_nil(w.min_width)
    assert.is_nil(w.min_height)
    assert.same({ top = 0, bottom = 0, left = 1, right = 1 }, w.padding)
    assert.equals(1, w.row)
    assert.equals(0, w.col)
    assert.equals(0, w.winblend)
    assert.is_false(w.backdrop)
    assert.same({}, w.wo)
    assert.same({}, w.bo)
  end)

  it("has hover behavior defaults", function()
    local h = config.defaults().ui.hover

    assert.is_false(h.show_original)
    assert.is_true(h.footer)
    assert.is_true(h.render_markdown)
    assert.equals("link", h.theme)
    assert.same({ "q", "<Esc>" }, h.keys.close)
    assert.equals("y", h.keys.yank)
    assert.equals("r", h.keys.replace)
    assert.equals("o", h.keys.original)
    assert.equals("p", h.keys.provider)
    assert.equals("?", h.keys.help)
  end)

  it("has notification defaults", function()
    local n = config.defaults().ui.notify

    assert.equals("󰊿", n.icon)
    assert.equals(3000, n.timeout)
  end)

  it("returns independent copies", function()
    local a = config.defaults()
    local b = config.defaults()
    a.provider = "changed"
    assert.not_equals(a.provider, b.provider)
  end)

  it("prefers GOOGLE_TRANSLATE_KEY over generic GOOGLE_API_KEY for google backend", function()
    vim.env.GOOGLE_API_KEY = "generic-google-key"
    vim.env.GOOGLE_TRANSLATE_KEY = "translate-specific-key"

    local d = config.defaults()

    assert.equals("translate-specific-key", d.providers.google.api_key)
  end)

  it("falls back to GOOGLE_API_KEY when GOOGLE_TRANSLATE_KEY is unset", function()
    vim.env.GOOGLE_TRANSLATE_KEY = nil
    vim.env.GOOGLE_API_KEY = "generic-google-key"

    local d = config.defaults()

    assert.equals("generic-google-key", d.providers.google.api_key)
  end)

  it("uses GOOGLE_APPLICATION_CREDENTIALS for google ADC path override", function()
    vim.env.GOOGLE_APPLICATION_CREDENTIALS = "/tmp/metaphrast-google-adc.json"

    local d = config.defaults()

    assert.equals("/tmp/metaphrast-google-adc.json", d.providers.google.adc_path)
  end)

  it("preserves explicit google gcp_project_id through merge", function()
    local merged = config.merge({
      providers = {
        google = {
          gcp_project_id = "explicit-project",
        },
      },
    })

    assert.equals("explicit-project", merged.providers.google.gcp_project_id)
  end)

  it("enables OpenRouter upstream rate-limit fallback by default", function()
    local d = config.defaults()

    assert.is_true(d.providers.openrouter.retry_on_upstream_rate_limit)
    assert.same({ "openrouter/auto" }, d.providers.openrouter.fallback_models)
  end)
end)

describe("config.merge", function()
  it("returns defaults when no opts", function()
    local m = config.merge(nil)
    local d = config.defaults()
    assert.equals(d.provider, m.provider)
    assert.equals(d.target_lang, m.target_lang)
  end)

  it("overrides top-level fields", function()
    local m = config.merge({ provider = "echo", target_lang = "ja" })
    assert.equals("echo", m.provider)
    assert.equals("ja", m.target_lang)
  end)

  it("deep merges nested tables", function()
    local m = config.merge({ cache = { ttl = 999 } })
    assert.equals(999, m.cache.ttl)
    -- Other cache fields should remain from defaults.
    assert.is_boolean(m.cache.enabled)
    assert.is_number(m.cache.memory_max_entries)
  end)

  it("deep merges provider config", function()
    local m = config.merge({ providers = { openai = { model = "gpt-4o" } } })
    assert.equals("gpt-4o", m.providers.openai.model)
    -- Other provider configs should still exist.
    assert.is_table(m.providers.google)
    assert.is_table(m.providers.deepl)
  end)

  it("merges the user's real ui.win table without loss", function()
    local border = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }

    local m = config.merge({
      ui = {
        win = {
          width = 150,
          border = border,
          padding = { top = 1, bottom = 1, left = 5, right = 5 },
          row = 2,
          col = 1,
          wo = { wrap = false },
        },
      },
    })

    assert.equals(150, m.ui.win.width)
    assert.same(border, m.ui.win.border)
    assert.same({ top = 1, bottom = 1, left = 5, right = 5 }, m.ui.win.padding)
    assert.equals(2, m.ui.win.row)
    assert.equals(1, m.ui.win.col)
    assert.is_false(m.ui.win.wo.wrap)
    -- Untouched defaults survive the merge.
    assert.equals(0.6, m.ui.win.max_width)
    assert.is_false(m.ui.win.backdrop)
    assert.equals("link", m.ui.hover.theme)
    assert.equals(3000, m.ui.notify.timeout)
  end)

  it("does not mutate defaults", function()
    local before = config.defaults()
    config.merge({ provider = "deepl", max_chars = 1 })
    local after = config.defaults()
    assert.equals(before.provider, after.provider)
    assert.equals(before.max_chars, after.max_chars)
  end)
end)

describe("config.warn_unknown_win_keys", function()
  local function collector()
    local seen = {}
    return seen, function(msg, level)
      seen[#seen + 1] = { msg = msg, level = level }
    end
  end

  before_each(function()
    config._reset_for_tests()
  end)

  after_each(function()
    config._reset_for_tests()
  end)

  it("reports each unknown key exactly once", function()
    local seen, notify = collector()
    local win = { width = 150, zindex = 90, style = "minimal" }

    local first = config.warn_unknown_win_keys(win, notify)
    local second = config.warn_unknown_win_keys(win, notify)

    assert.same({ "style", "zindex" }, first)
    assert.same({}, second)
    assert.equals(2, #seen)
    assert.equals("warn", seen[1].level)
    assert.is_true(seen[1].msg:find("style", 1, true) ~= nil)
    assert.is_true(seen[2].msg:find("zindex", 1, true) ~= nil)
  end)

  it("stays silent for the documented keys", function()
    local seen, notify = collector()

    local reported = config.warn_unknown_win_keys(config.defaults().ui.win, notify)

    assert.same({}, reported)
    assert.equals(0, #seen)
  end)

  it("ignores a missing ui.win table", function()
    local seen, notify = collector()

    assert.same({}, config.warn_unknown_win_keys(nil, notify))
    assert.equals(0, #seen)
  end)
end)
