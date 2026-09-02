local M = {}

local registry = {}

---@param name string
---@param provider table
function M.register(name, provider)
  assert(type(name) == "string" and name ~= "", "provider name required")
  assert(type(provider.translate) == "function", "provider.translate required")
  registry[name] = provider
end

---@param name string
---@return table|nil
function M.get(name)
  return registry[name]
end

function M.names()
  local keys = {}
  for k, _ in pairs(registry) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

---@param name string
---@param http fun(method: string, url: string, opts: table): table
---@param payload table
---@return string, table|nil
function M.translate(name, http, payload)
  local provider = registry[name]
  assert(provider, "unknown provider: " .. name)
  if provider.validate then
    local provider_cfg = (payload.config and payload.config.providers and payload.config.providers[name]) or {}
    local ok, err = provider.validate(provider_cfg)
    if not ok then
      error(err)
    end
  end
  return provider.translate(http, payload)
end

---@param name string
---@param payload table
---@return number|nil
function M.estimate_cost(name, payload)
  local provider = registry[name]
  if provider and provider.estimate_cost then
    return provider.estimate_cost(payload)
  end
  return nil
end

function M.reset()
  registry = {}
end

return M
