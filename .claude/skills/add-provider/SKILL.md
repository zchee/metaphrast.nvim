---
name: add-provider
description: Add a new translation provider backend (validate/translate/estimate_cost interface, registry registration, config defaults, env-var key resolution, and network-free tests). Use when asked to add, wire up, or scaffold a provider such as a new LLM or translation API.
---

Add a provider named `$ARGUMENTS` (or the name the user gave). Follow the existing providers exactly; `lua/metaphrast/providers/openai.lua` is the reference for chat-style APIs and `deepl.lua` for plain translation APIs.

## 1. Provider module `lua/metaphrast/providers/<name>.lua`

Required interface. Keep the parameter name `_http` for the HTTP function (codebase convention; luacheck already ignores the unused-hint warning).

```lua
local util = require("metaphrast.util")

local M = {}

M.name = "<name>"

---Validate provider config from config.providers.<name>.
---@param cfg table
---@return boolean ok
---@return string|nil err
function M.validate(cfg)
  if not cfg.api_key or cfg.api_key == "" then
    return false, "<name> requires api_key"
  end
  return true
end

---@param _http fun(method: string, url: string, opts: table): table
---@param payload { text: string, target_lang: string, source_lang: string|nil, config: table }
---@return string translated
function M.translate(_http, payload)
  local cfg = payload.config.providers["<name>"]
  local res = _http("POST", cfg.base_url, {
    headers = {
      "Content-Type: application/json",
      "Authorization: Bearer " .. cfg.api_key,
    },
    data = vim.json.encode({ --[[ request ]] }),
  })
  -- Two distinct, diagnosable failures. Never collapse them.
  if res.code ~= 0 then
    error(string.format("<name>: curl failed (%d): %s", res.code, res.stderr or ""))
  end
  if res.http_status and res.http_status >= 400 then
    error(string.format("<name>: HTTP %d: %s", res.http_status, res.stdout or ""))
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout)
  if not ok then
    error("<name>: invalid JSON response")
  end
  local text = --[[ extract from decoded ]]
  return util.normalize_newlines(text)
end

---Estimate USD cost for the request; nil if unknown.
---@param payload table
---@return number|nil
function M.estimate_cost(payload)
  local cfg = payload.config.providers["<name>"]
  return #payload.text / 1e6 * (cfg.price_per_million_chars or 0)
end

return M
```

Use `input_per_million` / `output_per_million` instead of `price_per_million_chars` for token-priced LLM APIs (see `openai.lua`). For LLM providers, copy the system/user prompt wording from `openai.lua` verbatim so all LLM backends behave the same; there is no shared prompt helper.

## 2. Register and configure

- `lua/metaphrast.lua`: add `local provider_<name> = require("metaphrast.providers.<name>")` to the top require block (stylua `sort_requires` will alphabetize it) and a `registry.register(provider_<name>.name, provider_<name>)` line in `register_builtin()`.
- `lua/metaphrast/config.lua`: add `providers.<name>` defaults with `api_key = vim.env.<NAME>_API_KEY`, `base_url`, `model` if applicable, and price fields. Add the `---@class` fields alongside the other provider classes. Bump `pricing_last_review` to today.
- `README.md` (not `doc/*.txt`, which is generated): document the env var and pricing under the provider list.

## 3. Tests in `tests/metaphrast/providers_spec.lua`

Copy the `make_payload` helper pattern already in the file. Cover, with no network:

- `validate` rejects a missing key and accepts a present one.
- `translate` with a fake `_http` that captures `method`/`url`/`opts` and returns `{ code = 0, http_status = 200, stdout = vim.json.encode(...) }`: assert the request shape and the extracted text.
- `translate` raises on `code ~= 0` and on `http_status >= 400`, with the two messages distinguishable.
- `estimate_cost` returns the expected USD for a known char/token count.

## 4. Verify

```bash
make fmt && make lint && make test
```
