local util = require("metaphrast.util")

local M = {}

M.name = "deepl"

function M.validate(cfg)
  if not cfg.api_key or cfg.api_key == "" then
    return false, "deepl provider requires api_key"
  end
  return true
end

---@param _http fun(method: string, url: string, opts: table): table
---@param payload table
---@return string
function M.translate(_http, payload)
  local cfg = payload.config.providers.deepl
  local params = {
    "text=" .. util.urlencode(payload.text),
    "target_lang=" .. util.urlencode((payload.target_lang or ""):upper()),
  }
  if payload.source_lang then
    table.insert(params, "source_lang=" .. util.urlencode(payload.source_lang:upper()))
  end
  local body = table.concat(params, "&")
  local res = _http("POST", cfg.base_url, {
    headers = {
      "Authorization: DeepL-Auth-Key " .. cfg.api_key,
      "Content-Type: application/x-www-form-urlencoded",
    },
    data = body,
  })
  if res.code ~= 0 then
    error("deepl translate failed: " .. (res.stderr or "curl error code " .. res.code), 0)
  end
  if res.http_status and res.http_status >= 400 then
    error("deepl translate failed (HTTP " .. res.http_status .. "): " .. (res.stdout or ""), 0)
  end
  local parsed = vim.json.decode(res.stdout)
  if not parsed or not parsed.translations or not parsed.translations[1] then
    error("deepl translate returned unexpected payload", 0)
  end
  return parsed.translations[1].text
end

function M.estimate_cost(payload)
  local cfg = payload.config.providers.deepl
  local chars = #payload.text
  local price = cfg.price_per_million_chars or 25
  return (chars / 1e6) * price
end

return M
