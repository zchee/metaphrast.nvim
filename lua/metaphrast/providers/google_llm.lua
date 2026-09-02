local gcp_auth = require("metaphrast.providers.gcp_auth")

local M = {}

M.name = "google_llm"

local DEFAULT_LOCATION = "us-central1"
local DEFAULT_MODEL = "general/translation-llm"

---Build the fully qualified model resource the Translation LLM expects.
---
---The location embedded here must match the `parent` location in the v3 URL,
---otherwise the API answers 400 INVALID_ARGUMENT.
---@param project_id string
---@param location string
---@param model string
---@return string
local function model_path(project_id, location, model)
  return string.format("projects/%s/locations/%s/models/%s", project_id, location, model)
end

---@param cfg table
---@return string
local function resolve_location(cfg)
  local location = cfg.location
  if not location or location == "" then
    return DEFAULT_LOCATION
  end
  return location
end

---@param cfg table
---@return string
local function resolve_model(cfg)
  local model = cfg.model
  if not model or model == "" then
    return DEFAULT_MODEL
  end
  return model
end

---Validate provider config from config.providers.google_llm.
---
---ADC is preferred; an API key falls back to the Basic v2 endpoint. Both paths
---need a project id because the model is addressed as a project resource.
---@param cfg table
---@return boolean ok
---@return string|nil err
function M.validate(cfg)
  local credentials
  if gcp_auth.file_exists(cfg.adc_path) then
    local ok, loaded = pcall(gcp_auth.load_adc_credentials, cfg.adc_path)
    if not ok then
      return false, tostring(loaded)
    end
    credentials = loaded
  elseif not cfg.api_key or cfg.api_key == "" then
    return false, "google_llm provider requires api_key or ADC credentials"
  end
  if not gcp_auth.resolve_project_id(cfg, credentials) then
    return false, "google_llm provider requires gcp_project_id (or an ADC quota_project_id)"
  end
  return true
end

---Translate through Cloud Translation's `general/translation-llm` model.
---
---With ADC the request goes to Advanced v3 `:translateText`; with an API key it
---goes to Basic v2, which accepts the same model resource.
---@param _http fun(method: string, url: string, opts: table): table
---@param payload { text: string, target_lang: string, source_lang: string|nil, config: table }
---@return string translated
function M.translate(_http, payload)
  local cfg = payload.config.providers.google_llm
  local location = resolve_location(cfg)
  local model = resolve_model(cfg)

  local url, headers, body, use_adc
  if gcp_auth.file_exists(cfg.adc_path) then
    use_adc = true
    local credentials = gcp_auth.load_adc_credentials(cfg.adc_path)
    local project_id = gcp_auth.resolve_project_id(cfg, credentials)
    if not project_id then
      error("google_llm provider requires gcp_project_id (or an ADC quota_project_id)")
    end
    local access_token = gcp_auth.refresh_access_token(_http, cfg.adc_path)
    url = string.format("%s/projects/%s/locations/%s:translateText", cfg.base_url, project_id, location)
    headers = {
      "Authorization: Bearer " .. access_token,
      "Content-Type: application/json; charset=utf-8",
      "x-goog-user-project: " .. project_id,
    }
    body = {
      contents = { payload.text },
      mimeType = "text/plain",
      targetLanguageCode = payload.target_lang,
      model = model_path(project_id, location, model),
    }
    if payload.source_lang and payload.source_lang ~= "" then
      body.sourceLanguageCode = payload.source_lang
    end
  else
    if not cfg.api_key or cfg.api_key == "" then
      error("google_llm provider requires api_key or ADC credentials")
    end
    local project_id = gcp_auth.resolve_project_id(cfg, nil)
    if not project_id then
      error("google_llm provider requires gcp_project_id (or an ADC quota_project_id)")
    end
    url = cfg.basic_base_url .. "?key=" .. cfg.api_key
    headers = { "Content-Type: application/json; charset=utf-8" }
    body = {
      q = { payload.text },
      target = payload.target_lang,
      format = "text",
      model = model_path(project_id, location, model),
    }
    if payload.source_lang and payload.source_lang ~= "" then
      body.source = payload.source_lang
    end
  end

  local res = _http("POST", url, {
    headers = headers,
    data = vim.json.encode(body),
  })
  if res.code ~= 0 then
    error("google_llm translate failed: " .. (res.stderr or "curl error code " .. res.code))
  end
  if res.http_status and res.http_status >= 400 then
    error("google_llm translate failed (HTTP " .. res.http_status .. "): " .. (res.stdout or ""))
  end

  local ok, parsed = pcall(vim.json.decode, res.stdout)
  if not ok then
    error("google_llm translate returned invalid JSON")
  end
  local translations
  if use_adc then
    translations = parsed and parsed.translations
  else
    translations = parsed and parsed.data and parsed.data.translations
  end
  if not translations or not translations[1] or not translations[1].translatedText then
    error("google_llm translate returned unexpected payload")
  end
  return translations[1].translatedText
end

---Estimate USD cost for the request.
---
---Translation LLM bills input and output characters separately at the same
---rate; the output length is unknown up front, so it is estimated as the input
---length.
---@param payload table
---@return number
function M.estimate_cost(payload)
  local cfg = payload.config.providers.google_llm
  local chars = #payload.text
  local cost_in = (chars / 1e6) * (cfg.input_per_million or 10.0)
  local cost_out = (chars / 1e6) * (cfg.output_per_million or 10.0)
  return cost_in + cost_out
end

---Drop the ADC access token shared with the other Google Cloud providers.
function M._reset_for_tests()
  gcp_auth._reset_for_tests()
end

return M
