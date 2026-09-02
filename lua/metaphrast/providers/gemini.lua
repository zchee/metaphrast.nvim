local M = {}

M.name = "gemini"

function M.validate(cfg)
  if not cfg.api_key or cfg.api_key == "" then
    return false, "gemini provider requires api_key"
  end
  return true
end

---@param _http fun(method: string, url: string, opts: table): table
---@param payload table
---@return string
function M.translate(_http, payload)
  local cfg = payload.config.providers.gemini
  local url = string.format("%s/%s:generateContent", cfg.base_url, cfg.model)
  local body = {
    contents = {
      {
        role = "user",
        parts = {
          {
            text = string.format(
              "Translate the following text from %s to %s. Return only the translated text.\n\n%s",
              payload.source_lang or "auto",
              payload.target_lang or "en",
              payload.text
            ),
          },
        },
      },
    },
  }
  local res = _http("POST", url, {
    headers = {
      "Content-Type: application/json",
      "x-goog-api-key: " .. cfg.api_key,
    },
    data = vim.json.encode(body),
  })
  if res.code ~= 0 then
    error("gemini translate failed: " .. (res.stderr or "curl error code " .. res.code))
  end
  if res.http_status and res.http_status >= 400 then
    error("gemini translate failed (HTTP " .. res.http_status .. "): " .. (res.stdout or ""))
  end
  local parsed = vim.json.decode(res.stdout)
  local candidates = parsed and parsed.candidates
  if not candidates or not candidates[1] or not candidates[1].content or not candidates[1].content.parts then
    error("gemini translate returned unexpected payload")
  end
  return candidates[1].content.parts[1].text
end

function M.estimate_cost(payload)
  local cfg = payload.config.providers.gemini
  local chars = #payload.text
  local tokens = chars / 4
  local cost_in = (tokens / 1e6) * (cfg.input_per_million or 0.30)
  local cost_out = (tokens / 1e6) * (cfg.output_per_million or 2.50)
  return cost_in + cost_out
end

return M
