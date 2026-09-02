local M = {}

M.name = "echo"

---@param _http any
---@param payload table
---@return string
function M.translate(_http, payload)
  local suffix = payload.config.providers.echo.suffix or "[echo]"
  local target = payload.target_lang or "auto"
  return string.format("%s %s->%s", payload.text, suffix, target)
end

function M.validate()
  return true
end

---@param payload table
function M.estimate_cost(payload)
  if not payload or not payload.text then
    return 0
  end
  local chars = #payload.text
  return chars / 1e6 * 0.001
end

return M
