local util = require("metaphrast.util")

local M = {}

M.name = "google"

local uv = vim.uv or vim.loop
local OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"

local token_cache = {
  access_token = nil,
  adc_path = nil,
  expires_at = 0,
}

---@param path string|nil
---@return boolean
local function file_exists(path)
  if not path or path == "" then
    return false
  end
  return uv.fs_stat(path) ~= nil
end

---@param path string
---@return table
local function load_adc_credentials(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    error("google ADC credentials could not be read: " .. path)
  end
  local raw = table.concat(lines, "\n")
  local decoded_ok, credentials = pcall(vim.json.decode, raw)
  if not decoded_ok or type(credentials) ~= "table" then
    error("google ADC credentials are not valid JSON: " .. path)
  end
  if credentials.type ~= "authorized_user" then
    error("google ADC credentials have unsupported type: " .. tostring(credentials.type))
  end
  if not credentials.client_id or not credentials.client_secret or not credentials.refresh_token then
    error("google ADC credentials are missing required authorized_user fields")
  end
  return credentials
end

---@param _http fun(method: string, url: string, opts: table): table
---@param adc_path string
---@return string
local function refresh_adc_access_token(_http, adc_path)
  local now = os.time()
  if token_cache.access_token and token_cache.adc_path == adc_path and now < (token_cache.expires_at - 60) then
    return token_cache.access_token
  end

  local credentials = load_adc_credentials(adc_path)
  local body = table.concat({
    "client_id=" .. util.urlencode(credentials.client_id),
    "client_secret=" .. util.urlencode(credentials.client_secret),
    "refresh_token=" .. util.urlencode(credentials.refresh_token),
    "grant_type=refresh_token",
  }, "&")
  local res = _http("POST", OAUTH_TOKEN_URL, {
    headers = { "Content-Type: application/x-www-form-urlencoded" },
    data = body,
  })
  if res.code ~= 0 then
    error("google ADC token refresh failed: " .. (res.stderr or "curl error code " .. res.code))
  end
  if res.http_status and res.http_status >= 400 then
    error("google ADC token refresh failed (HTTP " .. res.http_status .. "): " .. (res.stdout or ""))
  end

  local parsed = vim.json.decode(res.stdout)
  if not parsed or not parsed.access_token then
    error("google ADC token refresh returned unexpected payload")
  end

  token_cache.access_token = parsed.access_token
  token_cache.adc_path = adc_path
  token_cache.expires_at = now + tonumber(parsed.expires_in or 3600)
  return token_cache.access_token
end

---@param cfg table
---@param _http fun(method: string, url: string, opts: table): table
---@return string
---@return string[]
local function resolve_google_auth(cfg, _http)
  if file_exists(cfg.adc_path) then
    local credentials = load_adc_credentials(cfg.adc_path)
    local access_token = refresh_adc_access_token(_http, cfg.adc_path)
    local headers = {
      "Authorization: Bearer " .. access_token,
      "Content-Type: application/json",
    }
    local project_id = cfg.gcp_project_id or credentials.quota_project_id
    if project_id and project_id ~= "" then
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

---@param body string|nil
---@return string|nil
local function blocked_method_hint(body)
  if not body or body == "" then
    return nil
  end
  if not body:find("TranslateService.TranslateText are blocked", 1, true) then
    return nil
  end
  return table.concat({
    " Hint: Cloud Translation Basic v2 still accepts a Google Cloud API key,",
    " but this project/key is blocked from calling the Translation API.",
    " Metaphrast prefers ADC automatically when",
    " ~/.config/gcloud/application_default_credentials.json exists;",
    " otherwise use a Cloud Translation-enabled key (prefer",
    " GOOGLE_TRANSLATE_KEY for this provider) and verify the API, billing,",
    " and key restrictions are correct.",
  })
end

function M.validate(cfg)
  if file_exists(cfg.adc_path) then
    local ok, credentials = pcall(load_adc_credentials, cfg.adc_path)
    if not ok then
      return false, credentials
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
    local hint = res.http_status == 403 and blocked_method_hint(res.stdout) or nil
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
  token_cache.access_token = nil
  token_cache.adc_path = nil
  token_cache.expires_at = 0
end

return M
