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

  it("does not mutate defaults", function()
    local before = config.defaults()
    config.merge({ provider = "deepl", max_chars = 1 })
    local after = config.defaults()
    assert.equals(before.provider, after.provider)
    assert.equals(before.max_chars, after.max_chars)
  end)
end)
