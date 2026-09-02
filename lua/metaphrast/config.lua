---@class MetaphrastCacheConfig
---@field enabled boolean
---@field ttl number
---@field dir string
---@field max_estimated_cost number
---@field memory_enabled boolean
---@field memory_max_entries integer
---@field memory_skip_disk_ttl integer

---@class MetaphrastHttpConfig
---@field timeout integer
---@field backend string? "curl"|"plenary"

---@class MetaphrastProviderConfig
---@field api_key string?
---@field adc_path string?
---@field gcp_project_id string?
---@field model string?
---@field base_url string?
---@field glossary_id string?
---@field referer string?
---@field fallback_models string[]?
---@field retry_on_upstream_rate_limit boolean?

---@class MetaphrastConfig
---@field provider string
---@field icon string
---@field target_lang string
---@field source_lang string|nil
---@field replace boolean
---@field max_chars integer
---@field cache MetaphrastCacheConfig
---@field http MetaphrastHttpConfig
---@field providers table<string, MetaphrastProviderConfig>
---@field ui { win?: { padding?: { top?: integer, bottom?: integer, left?: integer, right?: integer }, width?: integer|nil, height?: integer|nil } }
---@field pricing_last_review string

---@class MetaphrastUiConfig
---@field win table|nil

local M = {}

local function default_cache_dir()
  return vim.fn.stdpath("cache") .. "/metaphrast"
end

---@return MetaphrastConfig
function M.defaults()
  return {
    provider = "openai",
    icon = "󰊿",
    target_lang = "en",
    source_lang = nil,
    replace = false,
    max_chars = 8000,
    cache = {
      enabled = true,
      ttl = 7 * 24 * 3600,
      dir = default_cache_dir(),
      max_estimated_cost = 1.0,
      memory_enabled = true,
      memory_max_entries = 512,
      memory_skip_disk_ttl = 5,
    },
    pricing_last_review = "2025-12-03",
    http = {
      timeout = 20000, -- milliseconds
      backend = "plenary",
    },
    providers = {
      echo = {
        suffix = "[echo]",
      },
      google = {
        api_key = vim.env.GOOGLE_TRANSLATE_KEY or vim.env.GOOGLE_API_KEY,
        adc_path = vim.env.GOOGLE_APPLICATION_CREDENTIALS
          or vim.fn.expand("~/.config/gcloud/application_default_credentials.json"),
        gcp_project_id = nil,
        model = "v2",
        base_url = "https://translation.googleapis.com/language/translate/v2",
        price_per_million_chars = 20.0,
      },
      deepl = {
        api_key = vim.env.DEEPL_AUTH_KEY,
        base_url = "https://api.deepl.com/v2/translate",
        price_per_million_chars = 25.0,
      },
      openai = {
        api_key = vim.env.OPENAI_API_KEY,
        model = "gpt-4o-mini",
        base_url = "https://api.openai.com/v1/chat/completions",
        input_per_million = 0.15,
        output_per_million = 0.60,
      },
      gemini = {
        api_key = vim.env.GOOGLE_API_KEY or vim.env.GEMINI_API_KEY,
        model = "gemini-2.5-flash",
        base_url = "https://generativelanguage.googleapis.com/v1beta/models",
        input_per_million = 0.30,
        output_per_million = 2.50,
      },
      openrouter = {
        api_key = vim.env.OPENROUTER_API_KEY,
        model = "openrouter/auto",
        base_url = "https://openrouter.ai/api/v1/chat/completions",
        input_per_million = 0.15,
        output_per_million = 0.60,
        referer = "https://github.com/zchee/metaphrast.nvim",
        fallback_models = { "openrouter/auto" },
        retry_on_upstream_rate_limit = true,
      },
    },
    ui = {
      win = {
        padding = { top = 0, bottom = 0, left = 0, right = 0 },
        width = nil,
        height = nil,
      },
    },
  }
end

---@param opts table|nil
---@return MetaphrastConfig
function M.merge(opts)
  return vim.tbl_deep_extend("force", M.defaults(), opts or {})
end

return M
