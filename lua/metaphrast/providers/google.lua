local gcp_auth = require("metaphrast.providers.gcp_auth")

local M = {}

M.name = "google"

---@param cfg table
---@param _http fun(method: string, url: string, opts: table): table
---@return string
---@return string[]
local function resolve_google_auth(cfg, _http)
  if gcp_auth.file_exists(cfg.adc_path) then
    local credentials = gcp_auth.load_adc_credentials(cfg.adc_path)
    -- Resolve before the refresh: an unusable id refuses the request anyway,
    -- and exchanging the refresh token first spends a credential on a call
    -- that cannot be made, leaving a minted access token in the cache the
    -- other Google providers share.
    local project_id = gcp_auth.resolve_project_id(cfg, credentials, M.name)
    local access_token = gcp_auth.refresh_access_token(_http, cfg.adc_path)
    local headers = {
      "Authorization: Bearer " .. access_token,
      "Content-Type: application/json",
    }
    if project_id then
      table.insert(headers, "x-goog-user-project: " .. project_id)
    end
    return cfg.base_url, headers
  end
  if not cfg.api_key or cfg.api_key == "" then
    error("google provider requires api_key or ADC credentials")
  end
  return cfg.base_url .. "?key=" .. cfg.api_key, {
    "Content-Type: application/json",
  }
end

---Validate provider config from config.providers.google.
---
---ADC is preferred; an API key falls back to the same v2 endpoint. A project id
---is optional here -- it only adds `x-goog-user-project` -- but an unusable one
---has to be reported now, or `setup()` accepts the provider and the value
---surfaces at the first translate instead.
---@param cfg table
---@return boolean ok
---@return string|nil err
function M.validate(cfg)
  if gcp_auth.file_exists(cfg.adc_path) then
    local ok, credentials = pcall(gcp_auth.load_adc_credentials, cfg.adc_path)
    if not ok then
      return false, tostring(credentials)
    end
    -- The resolver raises on a value that cannot name a project; validate()
    -- reports instead, so `setup()` falls back to echo with one warning rather
    -- than handing the user a traceback. google_llm already does this.
    local resolved, project_id = pcall(gcp_auth.resolve_project_id, cfg, credentials, M.name)
    if not resolved then
      return false, tostring(project_id)
    end
    return credentials ~= nil
  end
  if not cfg.api_key or cfg.api_key == "" then
    return false, "google provider requires api_key or ADC credentials"
  end
  return true
end

---@param _http fun(method: string, url: string, opts: table): table
---@param payload table
---@return string
function M.translate(_http, payload)
  local cfg = payload.config.providers.google
  local url, headers = resolve_google_auth(cfg, _http)
  local body = {
    q = payload.text,
    target = payload.target_lang,
    format = "text",
  }
  if payload.source_lang and payload.source_lang ~= "" then
    body.source = payload.source_lang
  end
  local res = _http("POST", url, {
    headers = headers,
    data = vim.json.encode(body),
  })
  if res.code ~= 0 then
    error("google translate failed: " .. (res.stderr or "curl error code " .. res.code))
  end
  if res.http_status and res.http_status >= 400 then
    local message = "google translate failed (HTTP " .. res.http_status .. "): " .. (res.stdout or "")
    local hint = res.http_status == 403 and gcp_auth.blocked_method_hint(res.stdout) or nil
    error(message .. (hint or ""))
  end
  local parsed = vim.json.decode(res.stdout)
  local translations = parsed and parsed.data and parsed.data.translations
  if not translations or not translations[1] or not translations[1].translatedText then
    error("google translate returned unexpected payload")
  end
  return translations[1].translatedText
end

function M.estimate_cost(payload)
  local cfg = payload.config.providers.google
  local chars = #payload.text
  local price = cfg.price_per_million_chars or 20
  return (chars / 1e6) * price
end

function M._reset_for_tests()
  gcp_auth._reset_for_tests()
end

return M
