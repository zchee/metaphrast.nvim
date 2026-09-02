local util = require("metaphrast.util")

local M = {}

local OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"

---Access token cache shared by every Google Cloud provider so a single ADC
---refresh serves all of them for the lifetime of the token.
local token_cache = {
  access_token = nil,
  adc_path = nil,
  expires_at = 0,
}

---Report whether an ADC credentials file is present at the given path.
---@param path string|nil
---@return boolean
function M.file_exists(path)
  if not path or path == "" then
    return false
  end
  return vim.uv.fs_stat(path) ~= nil
end

---Read and validate an authorized-user ADC credentials file.
---@param path string
---@param provider string|nil Provider name used to label errors (default "google").
---@return table credentials
function M.load_adc_credentials(path, provider)
  local label = provider or "google"
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    error(label .. " ADC credentials could not be read: " .. path)
  end
  local raw = table.concat(lines, "\n")
  local decoded_ok, credentials = pcall(vim.json.decode, raw)
  if not decoded_ok or type(credentials) ~= "table" then
    error(label .. " ADC credentials are not valid JSON: " .. path)
  end
  if credentials.type ~= "authorized_user" then
    error(label .. " ADC credentials have unsupported type: " .. tostring(credentials.type))
  end
  if not credentials.client_id or not credentials.client_secret or not credentials.refresh_token then
    error(label .. " ADC credentials are missing required authorized_user fields")
  end
  return credentials
end

---Exchange the ADC refresh token for an access token, reusing the cached one
---until 60 seconds before it expires.
---@param _http fun(method: string, url: string, opts: table): table
---@param adc_path string
---@param provider string|nil Provider name used to label errors (default "google").
---@return string access_token
function M.refresh_access_token(_http, adc_path, provider)
  local label = provider or "google"
  local now = os.time()
  if token_cache.access_token and token_cache.adc_path == adc_path and now < (token_cache.expires_at - 60) then
    return token_cache.access_token
  end

  local credentials = M.load_adc_credentials(adc_path, label)
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
    error(label .. " ADC token refresh failed: " .. (res.stderr or "curl error code " .. res.code))
  end
  if res.http_status and res.http_status >= 400 then
    error(label .. " ADC token refresh failed (HTTP " .. res.http_status .. "): " .. (res.stdout or ""))
  end

  local parsed = vim.json.decode(res.stdout)
  if not parsed or not parsed.access_token then
    error(label .. " ADC token refresh returned unexpected payload")
  end

  token_cache.access_token = parsed.access_token
  token_cache.adc_path = adc_path
  token_cache.expires_at = now + tonumber(parsed.expires_in or 3600)
  return token_cache.access_token
end

---Resolve the Google Cloud project to bill and attribute quota to.
---@param cfg table
---@param credentials table|nil
---@return string|nil project_id
function M.resolve_project_id(cfg, credentials)
  local project_id = cfg.gcp_project_id
  if (not project_id or project_id == "") and credentials then
    project_id = credentials.quota_project_id
  end
  if not project_id or project_id == "" then
    return nil
  end
  return project_id
end

---Explain a Cloud Translation 403 that means the key or project is blocked
---from the Translation API, so users do not chase the wrong credential.
---@param body string|nil HTTP response body.
---@return string|nil hint Appended to the error message, or nil when unrelated.
function M.blocked_method_hint(body)
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

---Drop the cached access token so tests never leak one into another spec.
function M._reset_for_tests()
  token_cache.access_token = nil
  token_cache.adc_path = nil
  token_cache.expires_at = 0
end

return M
