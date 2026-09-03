local config = require("metaphrast.config")

local deepl = require("metaphrast.providers.deepl")
local echo = require("metaphrast.providers.echo")
local gemini = require("metaphrast.providers.gemini")
local google = require("metaphrast.providers.google")
local google_llm = require("metaphrast.providers.google_llm")
local openai = require("metaphrast.providers.openai")
local openrouter = require("metaphrast.providers.openrouter")

---Helper: build a payload with the given text and provider config.
---@param text string
---@param provider_name string
---@param provider_cfg table|nil
---@return table
local function make_payload(text, provider_name, provider_cfg)
  local defaults = config.defaults()
  if provider_cfg then
    defaults.providers[provider_name] =
      vim.tbl_deep_extend("force", defaults.providers[provider_name] or {}, provider_cfg)
  end
  return {
    text = text,
    target_lang = "en",
    source_lang = "ja",
    config = defaults,
  }
end

-- ── echo ────────────────────────────────────────────────────────────────

describe("echo provider", function()
  it("has correct name", function()
    assert.equals("echo", echo.name)
  end)

  it("validates always", function()
    local ok = echo.validate({})
    assert.is_true(ok)
  end)

  it("translates by appending suffix and target", function()
    local payload = make_payload("hello", "echo", { suffix = "[echo]" })
    local result = echo.translate(nil, payload)
    assert.equals("hello [echo]->en", result)
  end)

  it("uses default suffix", function()
    local payload = make_payload("hi", "echo", {})
    payload.config.providers.echo.suffix = nil
    local result = echo.translate(nil, payload)
    assert.equals("hi [echo]->en", result)
  end)

  it("estimates cost near zero", function()
    local payload = make_payload("hello", "echo")
    local cost = echo.estimate_cost(payload)
    assert.is_number(cost)
    assert.truthy(cost < 0.001)
  end)

  it("estimate_cost handles nil payload", function()
    assert.equals(0, echo.estimate_cost(nil))
  end)
end)

-- ── google ──────────────────────────────────────────────────────────────

describe("google provider", function()
  local adc_path

  before_each(function()
    google._reset_for_tests()
    adc_path = vim.fn.tempname()
    -- `gcp_project_id` now defaults to the gcloud environment, so a developer
    -- with either variable exported would see the ADC fixtures below resolve a
    -- different project than they assert.
    vim.env.GOOGLE_CLOUD_PROJECT = nil
    vim.env.GCLOUD_PROJECT = nil
  end)

  after_each(function()
    google._reset_for_tests()
    vim.env.GOOGLE_CLOUD_PROJECT = nil
    vim.env.GCLOUD_PROJECT = nil
    if adc_path and vim.uv.fs_stat(adc_path) then
      vim.fn.delete(adc_path)
    end
  end)

  it("has correct name", function()
    assert.equals("google", google.name)
  end)

  it("rejects empty api_key", function()
    local ok, err = google.validate({ api_key = "", adc_path = adc_path })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("rejects nil api_key", function()
    local ok, err = google.validate({ adc_path = adc_path })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("accepts valid api_key", function()
    local ok = google.validate({ api_key = "test-key", adc_path = adc_path })
    assert.is_true(ok)
  end)

  it("accepts ADC credentials without api_key", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
      }),
    }, adc_path)

    local ok = google.validate({ adc_path = adc_path })

    assert.is_true(ok)
  end)

  it("rejects malformed ADC credentials", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "service_account",
      }),
    }, adc_path)

    local ok, err = google.validate({ adc_path = adc_path })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("unsupported type", 1, true))
  end)

  it("estimates cost based on character count", function()
    local payload = make_payload(string.rep("a", 1000), "google", { price_per_million_chars = 20 })
    local cost = google.estimate_cost(payload)
    assert.is_number(cost)
    -- 1000 chars at $20/million = $0.02
    assert.are.near(0.02, cost, 0.001)
  end)

  it("translates with mock http", function()
    local captured_method, captured_url
    local mock_http = function(method, url)
      captured_method = method
      captured_url = url
      return {
        code = 0,
        stdout = vim.json.encode({
          data = { translations = { { translatedText = "translated" } } },
        }),
      }
    end
    local payload = make_payload("hello", "google", {
      api_key = "k",
      adc_path = adc_path,
      base_url = "https://example.com",
    })
    local result = google.translate(mock_http, payload)
    assert.equals("translated", result)
    assert.equals("POST", captured_method)
    assert.truthy(captured_url:find("example.com"))
    assert.truthy(captured_url:find("key=k"))
  end)

  it("prefers ADC bearer auth over api_key when ADC credentials exist", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
        quota_project_id = "quota-project",
      }),
    }, adc_path)

    local calls = {}
    local mock_http = function(method, url, opts)
      table.insert(calls, {
        method = method,
        url = url,
        opts = opts,
      })
      if url == "https://oauth2.googleapis.com/token" then
        return {
          code = 0,
          stdout = vim.json.encode({
            access_token = "adc-access-token",
            expires_in = 3600,
            token_type = "Bearer",
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          data = { translations = { { translatedText = "translated-with-adc" } } },
        }),
      }
    end

    local payload = make_payload("hello", "google", {
      api_key = "fallback-key",
      adc_path = adc_path,
      base_url = "https://example.com",
    })
    local result = google.translate(mock_http, payload)

    assert.equals("translated-with-adc", result)
    assert.equals(2, #calls)
    assert.equals("https://oauth2.googleapis.com/token", calls[1].url)
    assert.truthy(calls[1].opts.data:find("refresh_token=refresh", 1, true))
    assert.equals("https://example.com", calls[2].url)
    assert.falsy(calls[2].url:find("key=", 1, true))
    assert.equals("Authorization: Bearer adc-access-token", calls[2].opts.headers[1])
    assert.equals("x-goog-user-project: quota-project", calls[2].opts.headers[3])
  end)

  it("prefers explicit gcp_project_id over ADC quota_project_id", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
        quota_project_id = "adc-project",
      }),
    }, adc_path)

    local calls = {}
    local mock_http = function(method, url, opts)
      table.insert(calls, {
        method = method,
        url = url,
        opts = opts,
      })
      if url == "https://oauth2.googleapis.com/token" then
        return {
          code = 0,
          stdout = vim.json.encode({
            access_token = "adc-access-token",
            expires_in = 3600,
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          data = { translations = { { translatedText = "translated-with-project-override" } } },
        }),
      }
    end

    local payload = make_payload("hello", "google", {
      api_key = "fallback-key",
      adc_path = adc_path,
      gcp_project_id = "explicit-project",
      base_url = "https://example.com",
    })
    local result = google.translate(mock_http, payload)

    assert.equals("translated-with-project-override", result)
    assert.equals("x-goog-user-project: explicit-project", calls[2].opts.headers[3])
  end)

  ---Write an authorized_user ADC file carrying `quota_project_id`.
  ---@param quota_project string
  local function write_google_adc(quota_project)
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
        quota_project_id = quota_project,
      }),
    }, adc_path)
  end

  ---An `_http` stub that answers the token refresh and then the translation.
  ---@param calls table[] Collector for every request.
  ---@return fun(method: string, url: string, opts: table): table
  local function google_adc_http(calls)
    return function(method, url, opts)
      table.insert(calls, { method = method, url = url, opts = opts })
      if url == "https://oauth2.googleapis.com/token" then
        return {
          code = 0,
          stdout = vim.json.encode({ access_token = "adc-access-token", expires_in = 3600 }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({ data = { translations = { { translatedText = "translated" } } } }),
      }
    end
  end

  it("AC-H2: bills the project named by GOOGLE_CLOUD_PROJECT", function()
    write_google_adc("quota-project")
    vim.env.GOOGLE_CLOUD_PROJECT = "env-project"

    local calls = {}
    local payload = make_payload("hello", "google", { adc_path = adc_path, base_url = "https://example.com" })
    google.translate(google_adc_http(calls), payload)

    -- Behaviour change: a user with the variable exported now attributes
    -- google's quota and billing to it, where google_llm already did.
    assert.equals("x-goog-user-project: env-project", calls[2].opts.headers[3])
  end)

  it("AC-H2: falls back to GCLOUD_PROJECT when GOOGLE_CLOUD_PROJECT is unset", function()
    write_google_adc("quota-project")
    vim.env.GCLOUD_PROJECT = "gcloud-project"

    local calls = {}
    local payload = make_payload("hello", "google", { adc_path = adc_path, base_url = "https://example.com" })
    google.translate(google_adc_http(calls), payload)

    assert.equals("x-goog-user-project: gcloud-project", calls[2].opts.headers[3])
  end)

  it("AC-H2: prefers an explicit gcp_project_id over the environment", function()
    write_google_adc("quota-project")
    vim.env.GOOGLE_CLOUD_PROJECT = "env-project"

    local calls = {}
    local payload = make_payload("hello", "google", {
      adc_path = adc_path,
      gcp_project_id = "explicit-project",
      base_url = "https://example.com",
    })
    google.translate(google_adc_http(calls), payload)

    assert.equals("x-goog-user-project: explicit-project", calls[2].opts.headers[3])
  end)

  it("AC-H2: falls back to the ADC quota project when gcp_project_id is empty", function()
    write_google_adc("quota-project")
    vim.env.GOOGLE_CLOUD_PROJECT = "env-project"

    local calls = {}
    local payload = make_payload("hello", "google", {
      adc_path = adc_path,
      gcp_project_id = "",
      base_url = "https://example.com",
    })
    google.translate(google_adc_http(calls), payload)

    -- An explicit empty string is a deliberate "use the ADC file's project",
    -- and the environment must not reinstate itself behind it.
    assert.equals("x-goog-user-project: quota-project", calls[2].opts.headers[3])
  end)

  ---Translate with `overrides` merged over the ADC fixture's provider config.
  ---@param overrides table
  ---@return boolean ok
  ---@return string result Translation, or the raised message.
  ---@return table[] calls
  local function translate_with(overrides)
    local calls = {}
    local cfg = vim.tbl_extend("force", { adc_path = adc_path, base_url = "https://example.com" }, overrides)
    local ok, result = pcall(google.translate, google_adc_http(calls), make_payload("hello", "google", cfg))
    return ok, tostring(result), calls
  end

  it("rejects a project id that is unsafe in a URL or a header", function()
    write_google_adc("quota-project")

    -- The value goes into `x-goog-user-project` unencoded, and into a URL path
    -- segment for google_llm. A CR/LF splits the header (curl's config parser
    -- unescapes it back), and `/`, `?` or `#` re-target the request -- on a
    -- call that carries the ADC Bearer token.
    for _, value in ipairs({
      "proj\r\nX-Injected: yes",
      "proj with space",
      "proj/../other",
      "proj?alt=json",
      "proj#frag",
      "-leading-dash",
    }) do
      local ok, err = translate_with({ gcp_project_id = value })
      assert.is_false(ok, value)
      assert.truthy(err:find("google provider", 1, true), err)
      assert.truthy(err:find("gcp_project_id", 1, true), err)
      assert.truthy(err:find("not a usable project id", 1, true), err)
    end
  end)

  it("names GOOGLE_CLOUD_PROJECT when the unsafe value came from the environment", function()
    write_google_adc("quota-project")
    vim.env.GOOGLE_CLOUD_PROJECT = "proj\r\nX-Injected: yes"

    -- `config.defaults()` seeds `gcp_project_id` from the environment, so the
    -- error has to name the variable, not the config key the user never set.
    local ok, err = translate_with({})

    assert.is_false(ok)
    assert.truthy(err:find("GOOGLE_CLOUD_PROJECT", 1, true), err)
  end)

  it("accepts a legacy domain-scoped project id", function()
    write_google_adc("quota-project")

    -- `domain.com:project` is a real, still-valid GCP id shape, so `.` and `:`
    -- have to survive the check.
    local ok, result, calls = translate_with({ gcp_project_id = "example.com:legacy" })

    assert.is_true(ok, result)
    assert.equals("x-goog-user-project: example.com:legacy", calls[2].opts.headers[3])
  end)

  it("surfaces blocked method guidance for HTTP 403 responses", function()
    local mock_http = function()
      return {
        code = 0,
        http_status = 403,
        stdout = vim.json.encode({
          error = {
            code = 403,
            message = "Requests to this API translate method "
              .. "google.cloud.translate.v2.TranslateService.TranslateText are blocked.",
          },
        }),
      }
    end
    local payload = make_payload("hi", "google", {
      api_key = "k",
      adc_path = adc_path,
      base_url = "https://x.com",
    })
    local ok, err = pcall(google.translate, mock_http, payload)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("google translate failed %(HTTP 403%)", 1, false))
    assert.is_truthy(tostring(err):find("GOOGLE_TRANSLATE_KEY", 1, true))
    assert.is_truthy(tostring(err):find("application_default_credentials.json", 1, true))
  end)

  it("errors clearly when ADC token refresh fails", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
      }),
    }, adc_path)

    local mock_http = function()
      return {
        code = 0,
        http_status = 401,
        stdout = [[{"error":"invalid_grant"}]],
      }
    end
    local payload = make_payload("hi", "google", {
      api_key = "fallback-key",
      adc_path = adc_path,
      base_url = "https://x.com",
    })
    local ok, err = pcall(google.translate, mock_http, payload)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("google ADC token refresh failed %(HTTP 401%)", 1, false))
    assert.is_truthy(tostring(err):find("invalid_grant", 1, true))
  end)

  it("uses explicit gcp_project_id even when ADC lacks quota_project_id", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
      }),
    }, adc_path)

    local calls = {}
    local mock_http = function(method, url, opts)
      table.insert(calls, {
        method = method,
        url = url,
        opts = opts,
      })
      if url == "https://oauth2.googleapis.com/token" then
        return {
          code = 0,
          stdout = vim.json.encode({
            access_token = "adc-access-token",
            expires_in = 3600,
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          data = { translations = { { translatedText = "translated-with-explicit-project" } } },
        }),
      }
    end

    local payload = make_payload("hello", "google", {
      adc_path = adc_path,
      gcp_project_id = "explicit-project",
      base_url = "https://example.com",
    })
    local result = google.translate(mock_http, payload)

    assert.equals("translated-with-explicit-project", result)
    assert.equals("x-goog-user-project: explicit-project", calls[2].opts.headers[3])
  end)

  it("errors on non-zero exit code", function()
    local mock_http = function()
      return { code = 1, stderr = "timeout" }
    end
    local payload = make_payload("hi", "google", { api_key = "k", adc_path = adc_path, base_url = "https://x.com" })
    assert.has_error(function()
      google.translate(mock_http, payload)
    end)
  end)

  it("errors on unexpected response", function()
    local mock_http = function()
      return { code = 0, stdout = "{}" }
    end
    local payload = make_payload("hi", "google", { api_key = "k", adc_path = adc_path, base_url = "https://x.com" })
    assert.has_error(function()
      google.translate(mock_http, payload)
    end)
  end)

  it("falls back to the ADC quota project when gcp_project_id is an empty string", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
        quota_project_id = "quota-proj",
      }),
    }, adc_path)
    local captured_headers
    local mock_http = function(_, url, opts)
      if url == "https://oauth2.googleapis.com/token" then
        return {
          code = 0,
          stdout = vim.json.encode({ access_token = "adc-access-token", expires_in = 3600 }),
        }
      end
      captured_headers = opts.headers
      return {
        code = 0,
        stdout = vim.json.encode({ data = { translations = { { translatedText = "translated" } } } }),
      }
    end
    local payload = make_payload("hello", "google", {
      adc_path = adc_path,
      gcp_project_id = "",
      base_url = "https://example.com",
    })

    google.translate(mock_http, payload)

    assert.is_truthy(vim.tbl_contains(captured_headers, "x-goog-user-project: quota-proj"))
  end)

  it("caches the ADC access token and drops it on reset", function()
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
        quota_project_id = "quota-project",
      }),
    }, adc_path)

    local token_calls = 0
    local mock_http = function(_, url)
      if url == "https://oauth2.googleapis.com/token" then
        token_calls = token_calls + 1
        return {
          code = 0,
          stdout = vim.json.encode({ access_token = "adc-access-token", expires_in = 3600 }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({ data = { translations = { { translatedText = "translated" } } } }),
      }
    end
    local payload = make_payload("hello", "google", { adc_path = adc_path, base_url = "https://example.com" })

    google.translate(mock_http, payload)
    google.translate(mock_http, payload)
    assert.equals(1, token_calls)

    google._reset_for_tests()
    google.translate(mock_http, payload)
    assert.equals(2, token_calls)
  end)
end)

-- ── google_llm ──────────────────────────────────────────────────────────

describe("google_llm provider", function()
  local adc_path

  ---Find the first header carrying the given prefix.
  ---@param headers string[]
  ---@param prefix string
  ---@return string|nil
  local function find_header(headers, prefix)
    for _, header in ipairs(headers) do
      if header:sub(1, #prefix) == prefix then
        return header
      end
    end
    return nil
  end

  ---Write an authorized-user ADC file at `adc_path`.
  ---@param quota_project_id string|nil
  local function write_adc(quota_project_id)
    vim.fn.writefile({
      vim.json.encode({
        type = "authorized_user",
        client_id = "cid",
        client_secret = "secret",
        refresh_token = "refresh",
        quota_project_id = quota_project_id,
      }),
    }, adc_path)
  end

  ---Build a fake HTTP function answering the OAuth token endpoint first and
  ---the translateText call second, recording both into `calls`.
  ---@param calls table[]
  ---@param response table
  ---@return fun(method: string, url: string, opts: table): table
  local function adc_http(calls, response)
    return function(method, url, opts)
      calls[#calls + 1] = { method = method, url = url, opts = opts }
      if url == "https://oauth2.googleapis.com/token" then
        return {
          code = 0,
          stdout = vim.json.encode({ access_token = "adc-access-token", expires_in = 3600 }),
        }
      end
      return response
    end
  end

  local v3_ok = {
    code = 0,
    http_status = 200,
    stdout = vim.json.encode({
      translations = { { translatedText = "hola", model = "general/translation-llm" } },
    }),
  }

  before_each(function()
    google_llm._reset_for_tests()
    adc_path = vim.fn.tempname()
    vim.env.GOOGLE_CLOUD_PROJECT = nil
    vim.env.GCLOUD_PROJECT = nil
  end)

  after_each(function()
    google_llm._reset_for_tests()
    vim.env.GOOGLE_CLOUD_PROJECT = nil
    vim.env.GCLOUD_PROJECT = nil
    if adc_path and vim.uv.fs_stat(adc_path) then
      vim.fn.delete(adc_path)
    end
  end)

  it("has correct name", function()
    assert.equals("google_llm", google_llm.name)
  end)

  it("rejects a missing api_key when no ADC file exists", function()
    local ok, err = google_llm.validate({ adc_path = adc_path, gcp_project_id = "proj" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("api_key", 1, true))
  end)

  it("rejects ADC credentials without a project id", function()
    write_adc(nil)

    local ok, err = google_llm.validate({ adc_path = adc_path })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("gcp_project_id", 1, true))
  end)

  it("accepts ADC credentials carrying a quota_project_id", function()
    write_adc("quota-project")

    assert.is_true(google_llm.validate({ adc_path = adc_path }))
  end)

  it("accepts an api_key with an explicit gcp_project_id", function()
    assert.is_true(google_llm.validate({ api_key = "k", adc_path = adc_path, gcp_project_id = "proj" }))
  end)

  it("reports an unsafe gcp_project_id instead of raising out of validate", function()
    write_adc("quota-project")

    -- The id is interpolated into `projects/%s/locations/...`, so a `/` or a
    -- `..` re-targets the request. validate() has to keep reporting rather
    -- than raising, or setup()'s fall-back to echo turns into a traceback.
    local ok, err = google_llm.validate({ adc_path = adc_path, gcp_project_id = "proj/../other" })

    assert.is_false(ok)
    err = tostring(err)
    assert.truthy(err:find("google_llm provider", 1, true), err)
    assert.truthy(err:find("gcp_project_id", 1, true), err)
  end)

  it("names the ADC quota_project_id when that is the unsafe value", function()
    write_adc("quota project")

    local ok, err = google_llm.validate({ adc_path = adc_path })

    assert.is_false(ok)
    assert.truthy(tostring(err):find("ADC quota_project_id", 1, true), tostring(err))
  end)

  it("accepts a legacy domain-scoped project id in the v3 URL", function()
    write_adc("quota-project")

    local calls = {}
    local payload = make_payload("hello", "google_llm", { adc_path = adc_path, gcp_project_id = "example.com:legacy" })

    assert.equals("hola", google_llm.translate(adc_http(calls, v3_ok), payload))
    assert.equals(
      "https://translation.googleapis.com/v3/projects/example.com:legacy/locations/us-central1:translateText",
      calls[2].url
    )
  end)

  it("translates through Advanced v3 with ADC credentials", function()
    write_adc("quota-project")

    local calls = {}
    local payload = make_payload("hello", "google_llm", { adc_path = adc_path, gcp_project_id = "proj" })
    local result = google_llm.translate(adc_http(calls, v3_ok), payload)

    assert.equals("hola", result)
    assert.equals(2, #calls)
    assert.equals("https://oauth2.googleapis.com/token", calls[1].url)
    assert.equals("POST", calls[2].method)
    assert.equals(
      "https://translation.googleapis.com/v3/projects/proj/locations/us-central1:translateText",
      calls[2].url
    )
    assert.equals("Authorization: Bearer adc-access-token", find_header(calls[2].opts.headers, "Authorization:"))
    assert.equals("x-goog-user-project: proj", find_header(calls[2].opts.headers, "x-goog-user-project:"))

    local body = vim.json.decode(calls[2].opts.data)
    assert.same({ "hello" }, body.contents)
    assert.equals("text/plain", body.mimeType)
    assert.equals("en", body.targetLanguageCode)
    assert.equals("ja", body.sourceLanguageCode)
    assert.equals("projects/proj/locations/us-central1/models/general/translation-llm", body.model)
  end)

  it("omits the source language when it is unset", function()
    write_adc("quota-project")

    local calls = {}
    local payload = make_payload("hello", "google_llm", { adc_path = adc_path, gcp_project_id = "proj" })
    payload.source_lang = nil
    google_llm.translate(adc_http(calls, v3_ok), payload)

    local body = vim.json.decode(calls[2].opts.data)
    assert.is_nil(body.sourceLanguageCode)
  end)

  it("honors a non-default location in both the URL and the model path", function()
    write_adc("quota-project")

    local calls = {}
    local payload = make_payload("hello", "google_llm", {
      adc_path = adc_path,
      gcp_project_id = "proj",
      location = "global",
    })
    google_llm.translate(adc_http(calls, v3_ok), payload)

    assert.equals("https://translation.googleapis.com/v3/projects/proj/locations/global:translateText", calls[2].url)
    local body = vim.json.decode(calls[2].opts.data)
    assert.equals("projects/proj/locations/global/models/general/translation-llm", body.model)
  end)

  it("rejects a location that is unsafe in the request URL", function()
    write_adc("quota-project")

    -- `location` is the third interpolant of the same v3 URL the project id
    -- feeds, and it was left unchecked when the id was hardened. curl
    -- normalises `..` before sending, so a `/` re-targets the path of an
    -- ADC-Bearer-authenticated request; `?` and `#` truncate it; CR/LF is
    -- rejected by curl only after the value has already been built in.
    for _, value in ipairs({
      "proj/../other",
      "us-central1?x=1",
      "us#1",
      "us\r\nX-Injected: yes",
    }) do
      google_llm._reset_for_tests()
      local calls = {}
      local payload = make_payload("hello", "google_llm", {
        adc_path = adc_path,
        gcp_project_id = "proj",
        location = value,
      })

      local ok, err = pcall(google_llm.translate, adc_http(calls, v3_ok), payload)

      assert.is_false(ok, value)
      err = tostring(err)
      assert.truthy(err:find("google_llm provider", 1, true), err)
      assert.truthy(err:find("location", 1, true), err)
      -- Refused before anything is spent: not even the token refresh runs.
      assert.equals(0, #calls, value)
    end
  end)

  it("reports an unsafe location instead of raising out of validate", function()
    write_adc("quota-project")

    -- Same contract as the project id: setup()'s fall-back to echo has to stay
    -- a warning, not a traceback.
    local ok, err = google_llm.validate({ adc_path = adc_path, location = "us-central1/../v2" })

    assert.is_false(ok)
    err = tostring(err)
    assert.truthy(err:find("google_llm provider", 1, true), err)
    assert.truthy(err:find("location", 1, true), err)
  end)

  it("accepts the location ids Cloud Translation actually serves", function()
    write_adc("quota-project")

    -- `global` and the regional shape both have to survive the check.
    for _, value in ipairs({ "global", "europe-west1" }) do
      google_llm._reset_for_tests()
      local calls = {}
      local payload = make_payload("hello", "google_llm", {
        adc_path = adc_path,
        gcp_project_id = "proj",
        location = value,
      })

      assert.equals("hola", google_llm.translate(adc_http(calls, v3_ok), payload))
      assert.equals(
        "https://translation.googleapis.com/v3/projects/proj/locations/" .. value .. ":translateText",
        calls[2].url
      )
      local body = vim.json.decode(calls[2].opts.data)
      assert.equals("projects/proj/locations/" .. value .. "/models/general/translation-llm", body.model)
    end
  end)

  it("translates through Basic v2 with an api_key", function()
    local captured_url, captured_opts
    local mock_http = function(_, url, opts)
      captured_url = url
      captured_opts = opts
      return {
        code = 0,
        http_status = 200,
        stdout = vim.json.encode({ data = { translations = { { translatedText = "hola-basic" } } } }),
      }
    end
    local payload = make_payload("hello", "google_llm", {
      api_key = "k",
      adc_path = adc_path,
      gcp_project_id = "proj",
    })
    local result = google_llm.translate(mock_http, payload)

    assert.equals("hola-basic", result)
    assert.truthy(captured_url:find("language/translate/v2?key=k", 1, true))
    local body = vim.json.decode(captured_opts.data)
    assert.same({ "hello" }, body.q)
    assert.equals("en", body.target)
    assert.equals("ja", body.source)
    assert.equals("projects/proj/locations/us-central1/models/general/translation-llm", body.model)
  end)

  it("errors on non-zero exit code with the curl stderr", function()
    local mock_http = function()
      return { code = 7, stderr = "connection refused" }
    end
    local payload = make_payload("hi", "google_llm", {
      api_key = "k",
      adc_path = adc_path,
      gcp_project_id = "proj",
    })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("connection refused", 1, true))
    assert.is_nil(tostring(err):find("HTTP", 1, true))
  end)

  it("errors on HTTP 400 with the response body", function()
    local mock_http = function()
      return {
        code = 0,
        http_status = 400,
        stdout = [[{"error":{"message":"Location must match the model location"}}]],
      }
    end
    local payload = make_payload("hi", "google_llm", {
      api_key = "k",
      adc_path = adc_path,
      gcp_project_id = "proj",
    })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("HTTP 400", 1, true))
    assert.is_truthy(tostring(err):find("Location must match the model location", 1, true))
  end)

  it("errors on an unexpected payload", function()
    local mock_http = function()
      return { code = 0, http_status = 200, stdout = "{}" }
    end
    local payload = make_payload("hi", "google_llm", {
      api_key = "k",
      adc_path = adc_path,
      gcp_project_id = "proj",
    })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("unexpected payload", 1, true))
  end)

  it("errors on an unexpected v3 payload", function()
    write_adc("quota-project")
    local calls = {}
    local mock_http = adc_http(calls, { code = 0, http_status = 200, stdout = "{}" })
    local payload = make_payload("hi", "google_llm", { adc_path = adc_path, gcp_project_id = "proj" })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("unexpected payload", 1, true))
  end)

  it("errors on invalid JSON instead of raising a decode error", function()
    local mock_http = function()
      return { code = 0, http_status = 200, stdout = "not json" }
    end
    local payload = make_payload("hi", "google_llm", {
      api_key = "k",
      adc_path = adc_path,
      gcp_project_id = "proj",
    })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("invalid JSON", 1, true))
  end)

  it("labels ADC failures with its own provider name", function()
    write_adc("quota-project")
    local mock_http = function(_, url)
      if url == "https://oauth2.googleapis.com/token" then
        return { code = 0, http_status = 401, stdout = "unauthorized" }
      end
      return v3_ok
    end
    local payload = make_payload("hi", "google_llm", { adc_path = adc_path, gcp_project_id = "proj" })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("google_llm ADC token refresh failed (HTTP 401)", 1, true))
    assert.is_nil(tostring(err):find("google ADC", 1, true))
  end)

  it("appends the blocked-method hint on the v2 403 the google backend explains", function()
    local mock_http = function()
      return {
        code = 0,
        http_status = 403,
        stdout = '{"error":{"message":"Requests to this API translate method '
          .. 'google.cloud.translate.v2.TranslateService.TranslateText are blocked."}}',
      }
    end
    local payload = make_payload("hi", "google_llm", {
      api_key = "k",
      adc_path = adc_path,
      gcp_project_id = "proj",
    })

    local ok, err = pcall(google_llm.translate, mock_http, payload)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("HTTP 403", 1, true))
    assert.is_truthy(tostring(err):find("Hint: Cloud Translation Basic v2", 1, true))
  end)

  it("shares the ADC access token with the google backend", function()
    write_adc("quota-project")
    local token_calls = 0
    local mock_http = function(_, url)
      if url == "https://oauth2.googleapis.com/token" then
        token_calls = token_calls + 1
        return {
          code = 0,
          stdout = vim.json.encode({ access_token = "adc-access-token", expires_in = 3600 }),
        }
      end
      if url:find("/v3/", 1, true) then
        return v3_ok
      end
      return {
        code = 0,
        http_status = 200,
        stdout = vim.json.encode({ data = { translations = { { translatedText = "translated" } } } }),
      }
    end
    local llm_payload = make_payload("hello", "google_llm", { adc_path = adc_path, gcp_project_id = "proj" })
    local nmt_payload = make_payload("hello", "google", { adc_path = adc_path, base_url = "https://example.com" })

    google.translate(mock_http, nmt_payload)
    google_llm.translate(mock_http, llm_payload)
    assert.equals(1, token_calls)

    google_llm._reset_for_tests()
    google.translate(mock_http, nmt_payload)
    assert.equals(2, token_calls)
  end)

  it("estimates cost from input plus estimated output characters", function()
    local payload = make_payload(string.rep("a", 1000), "google_llm", {})
    -- 1000 chars at $10/M input + $10/M estimated output = $0.02.
    assert.are.near(0.02, google_llm.estimate_cost(payload), 1e-6)
  end)

  it("honors custom per-million prices", function()
    local payload = make_payload(string.rep("a", 1000), "google_llm", {
      input_per_million = 4.0,
      output_per_million = 6.0,
    })
    assert.are.near(0.01, google_llm.estimate_cost(payload), 1e-6)
  end)
end)

-- ── deepl ───────────────────────────────────────────────────────────────

describe("deepl provider", function()
  it("has correct name", function()
    assert.equals("deepl", deepl.name)
  end)

  it("rejects empty api_key", function()
    local ok, err = deepl.validate({ api_key = "" })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("accepts valid api_key", function()
    assert.is_true(deepl.validate({ api_key = "key" }))
  end)

  it("estimates cost based on character count", function()
    local payload = make_payload(string.rep("a", 1000), "deepl", { price_per_million_chars = 25 })
    local cost = deepl.estimate_cost(payload)
    assert.are.near(0.025, cost, 0.001)
  end)

  it("translates with mock http", function()
    local captured_opts
    local mock_http = function(_, _, opts)
      captured_opts = opts
      return {
        code = 0,
        stdout = vim.json.encode({
          translations = { { text = "hola" } },
        }),
      }
    end
    local payload = make_payload("hello", "deepl", { api_key = "dk", base_url = "https://api.deepl.test" })
    local result = deepl.translate(mock_http, payload)
    assert.equals("hola", result)
    local found_auth = false
    for _, header in ipairs(captured_opts.headers or {}) do
      if header == "Authorization: DeepL-Auth-Key dk" then
        found_auth = true
        break
      end
    end
    assert.is_true(found_auth)
    assert.falsy(captured_opts.data:find("auth_key=", 1, true))
    assert.truthy(captured_opts.data:find("text="))
    assert.truthy(captured_opts.data:find("target_lang="))
    assert.truthy(captured_opts.data:find("source_lang="))
  end)

  it("surfaces HTTP API failures with response details", function()
    local mock_http = function()
      return {
        code = 0,
        http_status = 403,
        stdout = [[{"message":"legacy auth rejected"}]],
      }
    end
    local payload = make_payload("hi", "deepl", { api_key = "k", base_url = "https://x.com" })
    local ok, err = pcall(deepl.translate, mock_http, payload)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("deepl translate failed %(HTTP 403%)", 1, false))
    assert.is_truthy(tostring(err):find("legacy auth rejected", 1, true))
  end)

  it("errors on unexpected response", function()
    local mock_http = function()
      return { code = 0, stdout = "{}" }
    end
    local payload = make_payload("hi", "deepl", { api_key = "k", base_url = "https://x.com" })
    assert.has_error(function()
      deepl.translate(mock_http, payload)
    end)
  end)
end)

-- ── openai ──────────────────────────────────────────────────────────────

describe("openai provider", function()
  it("has correct name", function()
    assert.equals("openai", openai.name)
  end)

  it("rejects empty api_key", function()
    local ok, err = openai.validate({ api_key = "" })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("accepts valid api_key", function()
    assert.is_true(openai.validate({ api_key = "sk-test" }))
  end)

  it("estimates cost with token approximation", function()
    local payload = make_payload(string.rep("a", 400), "openai", {
      input_per_million = 0.15,
      output_per_million = 0.60,
    })
    local cost = openai.estimate_cost(payload)
    assert.is_number(cost)
    -- 400 chars / 4 = 100 tokens in+out
    -- (100/1e6)*0.15 + (100/1e6)*0.60 = 0.000075
    assert.truthy(cost > 0)
    assert.truthy(cost < 0.001)
  end)

  it("translates with mock http", function()
    local captured_opts
    local mock_http = function(_, _, opts)
      captured_opts = opts
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "bonjour" } } },
        }),
      }
    end
    local payload = make_payload("hello", "openai", {
      api_key = "sk-x",
      model = "gpt-4o-mini",
      base_url = "https://api.openai.test",
    })
    local result = openai.translate(mock_http, payload)
    assert.equals("bonjour", result)
    -- Authorization header should be present.
    local found_auth = false
    for _, h in ipairs(captured_opts.headers) do
      if h:find("Authorization: Bearer sk%-x") then
        found_auth = true
      end
    end
    assert.is_true(found_auth)
  end)

  it("errors on unexpected response", function()
    local mock_http = function()
      return { code = 0, stdout = "{}" }
    end
    local payload = make_payload("hi", "openai", { api_key = "k", model = "m", base_url = "https://x.com" })
    assert.has_error(function()
      openai.translate(mock_http, payload)
    end)
  end)
end)

-- ── gemini ──────────────────────────────────────────────────────────────

describe("gemini provider", function()
  it("has correct name", function()
    assert.equals("gemini", gemini.name)
  end)

  it("rejects empty api_key", function()
    local ok, err = gemini.validate({ api_key = "" })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("accepts valid api_key", function()
    assert.is_true(gemini.validate({ api_key = "AIza-test" }))
  end)

  it("estimates cost with token approximation", function()
    local payload = make_payload(string.rep("a", 400), "gemini", {
      input_per_million = 0.30,
      output_per_million = 2.50,
    })
    local cost = gemini.estimate_cost(payload)
    assert.is_number(cost)
    assert.truthy(cost > 0)
    assert.truthy(cost < 0.01)
  end)

  it("translates with mock http", function()
    local captured_url
    local mock_http = function(_, url)
      captured_url = url
      return {
        code = 0,
        stdout = vim.json.encode({
          candidates = { { content = { parts = { { text = "konnichiwa" } } } } },
        }),
      }
    end
    local payload = make_payload("hello", "gemini", {
      api_key = "AIza",
      model = "gemini-2.5-flash",
      base_url = "https://gen.test/v1beta/models",
    })
    local result = gemini.translate(mock_http, payload)
    assert.equals("konnichiwa", result)
    assert.truthy(captured_url:find("gemini%-2%.5%-flash:generateContent"))
  end)

  it("errors on unexpected response", function()
    local mock_http = function()
      return { code = 0, stdout = "{}" }
    end
    local payload = make_payload("hi", "gemini", { api_key = "k", model = "m", base_url = "https://x.com" })
    assert.has_error(function()
      gemini.translate(mock_http, payload)
    end)
  end)
end)

-- ── openrouter ──────────────────────────────────────────────────────────

describe("openrouter provider", function()
  it("has correct name", function()
    assert.equals("openrouter", openrouter.name)
  end)

  it("rejects empty api_key", function()
    local ok, err = openrouter.validate({ api_key = "" })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("accepts valid api_key", function()
    assert.is_true(openrouter.validate({ api_key = "or-test" }))
  end)

  it("estimates cost with token approximation", function()
    local payload = make_payload(string.rep("a", 400), "openrouter", {
      input_per_million = 0.15,
      output_per_million = 0.60,
    })
    local cost = openrouter.estimate_cost(payload)
    assert.is_number(cost)
    assert.truthy(cost > 0)
  end)

  it("translates with mock http", function()
    local captured_headers
    local mock_http = function(_, _, opts)
      captured_headers = opts.headers
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "hallo" } } },
        }),
      }
    end
    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "openrouter/auto",
      base_url = "https://or.test",
      referer = "https://github.com/test",
    })
    local result = openrouter.translate(mock_http, payload)
    assert.equals("hallo", result)
    -- Should include HTTP-Referer header.
    local found_referer = false
    for _, h in ipairs(captured_headers) do
      if h:find("HTTP%-Referer:") then
        found_referer = true
      end
    end
    assert.is_true(found_referer)
  end)

  it("omits referer header when not configured", function()
    local captured_headers
    local mock_http = function(_, _, opts)
      captured_headers = opts.headers
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "ok" } } },
        }),
      }
    end
    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "openrouter/auto",
      base_url = "https://or.test",
      referer = nil,
    })
    -- Explicitly clear referer.
    payload.config.providers.openrouter.referer = nil
    openrouter.translate(mock_http, payload)
    for _, h in ipairs(captured_headers) do
      assert.is_falsy(h:find("HTTP%-Referer:"))
    end
  end)

  it("errors on unexpected response", function()
    local mock_http = function()
      return { code = 0, stdout = "{}" }
    end
    local payload = make_payload("hi", "openrouter", {
      api_key = "k",
      model = "m",
      base_url = "https://x.com",
    })
    assert.has_error(function()
      openrouter.translate(mock_http, payload)
    end)
  end)

  it("retries configured fallback model when upstream provider is rate-limited", function()
    local requested_models = {}
    local mock_http = function(_, _, opts)
      local body = vim.json.decode(opts.data)
      table.insert(requested_models, body.model)
      if #requested_models == 1 then
        return {
          code = 0,
          http_status = 429,
          stdout = vim.json.encode({
            error = {
              message = "Provider returned error",
              code = 429,
              metadata = {
                raw = "deepseek/deepseek-v4-flash is temporarily rate-limited upstream",
                provider_name = "DeepInfra",
                is_byok = false,
              },
            },
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "fallback ok" } } },
        }),
      }
    end

    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "deepseek/deepseek-v4-flash",
      base_url = "https://or.test",
      fallback_models = { "openrouter/auto" },
    })

    local result = openrouter.translate(mock_http, payload)

    assert.equals("fallback ok", result)
    assert.same({ "deepseek/deepseek-v4-flash", "openrouter/auto" }, requested_models)
  end)

  it("retries openrouter auto once when the auto-selected upstream is rate-limited", function()
    local requested_models = {}
    local mock_http = function(_, _, opts)
      local body = vim.json.decode(opts.data)
      table.insert(requested_models, body.model)
      if #requested_models == 1 then
        return {
          code = 0,
          http_status = 429,
          stdout = vim.json.encode({
            error = {
              message = "Provider returned error",
              code = 429,
              metadata = {
                raw = "deepseek/deepseek-v4-flash is temporarily rate-limited upstream",
                provider_name = "DeepInfra",
                is_byok = false,
              },
            },
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "auto retry ok" } } },
        }),
      }
    end

    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "openrouter/auto",
      base_url = "https://or.test",
      fallback_models = { "openrouter/auto" },
    })

    local result = openrouter.translate(mock_http, payload)

    assert.equals("auto retry ok", result)
    assert.same({ "openrouter/auto", "openrouter/auto" }, requested_models)
  end)

  it("skips duplicate non-auto fallback models", function()
    local requested_models = {}
    local mock_http = function(_, _, opts)
      local body = vim.json.decode(opts.data)
      table.insert(requested_models, body.model)
      if #requested_models == 1 then
        return {
          code = 0,
          http_status = 429,
          stdout = vim.json.encode({
            error = {
              message = "Provider returned error",
              code = 429,
              metadata = {
                raw = "deepseek/deepseek-v4-flash is temporarily rate-limited upstream",
                provider_name = "DeepInfra",
                is_byok = false,
              },
            },
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "fallback without duplicate primary" } } },
        }),
      }
    end

    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "deepseek/deepseek-v4-flash",
      base_url = "https://or.test",
      fallback_models = {
        "deepseek/deepseek-v4-flash",
        "openrouter/auto",
        "openrouter/auto",
      },
    })

    local result = openrouter.translate(mock_http, payload)

    assert.equals("fallback without duplicate primary", result)
    assert.same({ "deepseek/deepseek-v4-flash", "openrouter/auto" }, requested_models)
  end)

  it("does not retry user or account rate-limit errors", function()
    local calls = 0
    local mock_http = function()
      calls = calls + 1
      return {
        code = 0,
        http_status = 429,
        stdout = vim.json.encode({
          error = {
            message = "Rate limit exceeded",
            code = 429,
          },
        }),
      }
    end

    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "deepseek/deepseek-v4-flash",
      base_url = "https://or.test",
      fallback_models = { "openrouter/auto" },
    })

    local ok, err = pcall(function()
      openrouter.translate(mock_http, payload)
    end)
    assert.is_false(ok)
    assert.truthy(err:find("openrouter translate failed %(HTTP 429%)"))
    assert.equals(1, calls)
  end)

  it("does not retry upstream rate-limit errors when disabled", function()
    local calls = 0
    local mock_http = function()
      calls = calls + 1
      return {
        code = 0,
        http_status = 429,
        stdout = vim.json.encode({
          error = {
            message = "Provider returned error",
            code = 429,
            metadata = {
              raw = "deepseek/deepseek-v4-flash is temporarily rate-limited upstream",
              provider_name = "DeepInfra",
              is_byok = false,
            },
          },
        }),
      }
    end

    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "deepseek/deepseek-v4-flash",
      base_url = "https://or.test",
      fallback_models = { "openrouter/auto" },
      retry_on_upstream_rate_limit = false,
    })

    local ok, err = pcall(function()
      openrouter.translate(mock_http, payload)
    end)
    assert.is_false(ok)
    assert.truthy(err:find("openrouter translate failed %(HTTP 429%)"))
    assert.equals(1, calls)
  end)

  it("reports fallback model HTTP failure after retrying an upstream rate limit", function()
    local requested_models = {}
    local mock_http = function(_, _, opts)
      local body = vim.json.decode(opts.data)
      table.insert(requested_models, body.model)
      if #requested_models == 1 then
        return {
          code = 0,
          http_status = 429,
          stdout = vim.json.encode({
            error = {
              message = "Provider returned error",
              code = 429,
              metadata = {
                raw = "deepseek/deepseek-v4-flash is temporarily rate-limited upstream",
                provider_name = "DeepInfra",
                is_byok = false,
              },
            },
          }),
        }
      end

      return {
        code = 0,
        http_status = 401,
        stdout = vim.json.encode({
          error = {
            message = "No auth credentials found",
            code = 401,
          },
        }),
      }
    end

    local payload = make_payload("hello", "openrouter", {
      api_key = "or-k",
      model = "deepseek/deepseek-v4-flash",
      base_url = "https://or.test",
      fallback_models = { "openrouter/auto" },
    })

    local ok, err = pcall(function()
      openrouter.translate(mock_http, payload)
    end)
    assert.is_false(ok)
    assert.truthy(err:find("openrouter translate failed %(HTTP 401%)"))
    assert.same({ "deepseek/deepseek-v4-flash", "openrouter/auto" }, requested_models)
  end)
end)
