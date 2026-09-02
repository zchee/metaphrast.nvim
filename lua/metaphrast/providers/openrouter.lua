local M = {}

M.name = "openrouter"

function M.validate(cfg)
  if not cfg.api_key or cfg.api_key == "" then
    return false, "openrouter provider requires api_key"
  end
  return true
end

---@param payload table
---@return string
local function build_user_prompt(payload)
  return string.format(
    "Translate from %s to %s. Return only the translated text.\n\n%s",
    payload.source_lang or "auto",
    payload.target_lang or "en",
    payload.text
  )
end

---@param model string
---@param payload table
---@return table
local function build_body(model, payload)
  return {
    model = model,
    messages = {
      { role = "system", content = "You are a careful translator. Preserve markup and code fences." },
      { role = "user", content = build_user_prompt(payload) },
    },
    temperature = 0,
  }
end

---@param cfg table
---@return string[]
local function build_headers(cfg)
  local headers = {
    "Content-Type: application/json",
    "Authorization: Bearer " .. cfg.api_key,
  }
  if cfg.referer then
    table.insert(headers, "HTTP-Referer: " .. cfg.referer)
  end
  return headers
end

---@param stdout string|nil
---@return boolean
local function is_upstream_rate_limit(stdout)
  if not stdout or stdout == "" then
    return false
  end
  local ok, parsed = pcall(vim.json.decode, stdout)
  if not ok or not parsed or not parsed.error then
    return false
  end

  local metadata = parsed.error.metadata or {}
  return type(metadata.provider_name) == "string" and metadata.provider_name ~= "" and metadata.is_byok == false
end

---@param cfg table
---@param primary_model string
---@return string[]
local function retry_models(cfg, primary_model)
  if cfg.retry_on_upstream_rate_limit == false then
    return {}
  end
  if type(cfg.fallback_models) ~= "table" then
    return {}
  end

  local models = {}
  local seen = {}
  for _, model in ipairs(cfg.fallback_models) do
    local duplicates_primary = model == primary_model and primary_model ~= "openrouter/auto"
    if type(model) == "string" and model ~= "" and not duplicates_primary and not seen[model] then
      table.insert(models, model)
      seen[model] = true
    end
  end
  return models
end

---@param _http fun(method: string, url: string, opts: table): table
---@param cfg table
---@param payload table
---@param headers string[]
---@param model string
---@return table
local function request_translation(_http, cfg, payload, headers, model)
  return _http("POST", cfg.base_url, {
    headers = headers,
    data = vim.json.encode(build_body(model, payload)),
  })
end

---@param res table
---@return string
local function format_http_error(res)
  return "openrouter translate failed (HTTP " .. res.http_status .. "): " .. (res.stdout or "")
end

---@param res table
---@return string
local function decode_translation(res)
  local parsed = vim.json.decode(res.stdout)
  local choice = parsed and parsed.choices and parsed.choices[1]
  if not choice or not choice.message or not choice.message.content then
    error("openrouter translate returned unexpected payload")
  end
  return choice.message.content
end

---@param _http fun(method: string, url: string, opts: table): table
---@param payload table
---@return string
function M.translate(_http, payload)
  local cfg = payload.config.providers.openrouter
  local headers = build_headers(cfg)
  local primary_model = cfg.model or "openrouter/auto"
  local attempts = { primary_model }
  vim.list_extend(attempts, retry_models(cfg, primary_model))

  for index, model in ipairs(attempts) do
    local res = request_translation(_http, cfg, payload, headers, model)
    if res.code ~= 0 then
      error("openrouter translate failed: " .. (res.stderr or "curl error code " .. res.code))
    end
    if res.http_status and res.http_status >= 400 then
      local message = format_http_error(res)
      if not (res.http_status == 429 and is_upstream_rate_limit(res.stdout) and index < #attempts) then
        error(message)
      end
    else
      return decode_translation(res)
    end
  end

  error("openrouter translate failed")
end

function M.estimate_cost(payload)
  local cfg = payload.config.providers.openrouter
  local chars = #payload.text
  local tokens = chars / 4
  local cost_in = (tokens / 1e6) * (cfg.input_per_million or 0.15)
  local cost_out = (tokens / 1e6) * (cfg.output_per_million or 0.60)
  return cost_in + cost_out
end

return M
