local M = {}

M.name = "openai"

function M.validate(cfg)
  if not cfg.api_key or cfg.api_key == "" then
    return false, "openai provider requires api_key"
  end
  return true
end

---@param _http fun(method: string, url: string, opts: table): table
---@param payload table
---@return string
function M.translate(_http, payload)
  local cfg = payload.config.providers.openai
  local system_prompt = "You are a professional translator. Keep formatting and code fences."
  local user_prompt = string.format(
    "Translate the following text from %s to %s. Only return the translated text without commentary.\n\n%s",
    payload.source_lang or "auto",
    payload.target_lang or "en",
    payload.text
  )
  local body = {
    model = cfg.model,
    temperature = 0,
    messages = {
      { role = "system", content = system_prompt },
      { role = "user", content = user_prompt },
    },
  }
  local res = _http("POST", cfg.base_url, {
    headers = {
      "Content-Type: application/json",
      "Authorization: Bearer " .. cfg.api_key,
    },
    data = vim.json.encode(body),
  })
  if res.code ~= 0 then
    error("openai translate failed: " .. (res.stderr or "curl error code " .. res.code))
  end
  if res.http_status and res.http_status >= 400 then
    error("openai translate failed (HTTP " .. res.http_status .. "): " .. (res.stdout or ""))
  end
  local parsed = vim.json.decode(res.stdout)
  local choice = parsed and parsed.choices and parsed.choices[1]
  if not choice or not choice.message or not choice.message.content then
    error("openai translate returned unexpected payload")
  end
  return choice.message.content
end

function M.estimate_cost(payload)
  local cfg = payload.config.providers.openai
  local chars = #payload.text
  local tokens_in = chars / 4
  local tokens_out = tokens_in
  local cost_in = (tokens_in / 1e6) * (cfg.input_per_million or 0.15)
  local cost_out = (tokens_out / 1e6) * (cfg.output_per_million or 0.60)
  return cost_in + cost_out
end

return M
