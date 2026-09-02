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
---@field location string?
---@field model string?
---@field base_url string?
---@field basic_base_url string?
---@field glossary_id string?
---@field referer string?
---@field fallback_models string[]?
---@field retry_on_upstream_rate_limit boolean?
---@field price_per_million_chars number?
---@field input_per_million number?
---@field output_per_million number?

---@class MetaphrastWinPadding
---@field top integer Blank rows above the body (rendered as virtual lines).
---@field bottom integer Blank rows below the body (rendered as virtual lines).
---@field left integer Left inset, rendered through `wo.statuscolumn`.
---@field right integer Right inset, slack inside the window width.

---@class MetaphrastWinConfig
---@field border string|string[]|nil Border spec; nil falls back to `vim.o.winborder`.
---@field width integer|number|nil Columns, a 0<n<1 fraction of `vim.o.columns`, or nil for auto.
---@field height integer|number|nil Rows, a 0<n<1 fraction of the usable rows, or nil for auto.
---@field max_width integer|number|nil Upper bound for the auto width only.
---@field max_height integer|number|nil Upper bound for the auto height only.
---@field min_width integer|number|nil Lower bound for the auto width only.
---@field min_height integer|number|nil Lower bound for the auto height only.
---@field padding MetaphrastWinPadding
---@field row integer Row offset from the anchor line.
---@field col integer Column offset from the anchor column.
---@field winblend integer Pseudo-transparency, mapped to `wo.winblend`.
---@field backdrop boolean|integer `false` disables the backdrop; a number sets its blend.
---@field wo table<string, any> Window-local options merged last.
---@field bo table<string, any> Buffer-local options merged last.

---@class MetaphrastHoverKeys
---@field close string|string[]|false Close the focused hover.
---@field yank string|string[]|false Yank the translation.
---@field replace string|string[]|false Replace the source range.
---@field original string|string[]|false Toggle the original text pane.
---@field provider string|string[]|false Retranslate with another provider.
---@field help string|string[]|false Toggle the key-hint help window.

---@class MetaphrastHoverConfig
---@field show_original boolean Open with the original text pane visible.
---@field footer boolean Render the key-hint footer.
---@field render_markdown boolean Use filetype "markdown" so markdown renderers attach.
---@field keys MetaphrastHoverKeys
---@field theme string "link" (colorscheme links) or "teal" (legacy palette).

---@class MetaphrastNotifyConfig
---@field icon string Icon shown on progress and result toasts.
---@field timeout integer Milliseconds a finished toast stays up.

---@class MetaphrastUiConfig
---@field win MetaphrastWinConfig
---@field hover MetaphrastHoverConfig
---@field notify MetaphrastNotifyConfig

---@class MetaphrastConfig
---@field provider string
---@field icon string
---@field target_lang string
---@field source_lang string|nil
---@field replace boolean
---@field max_chars integer
---@field max_inserted_lines integer Cap on lines a blockwise replace may add below the block.
---@field cache MetaphrastCacheConfig
---@field http MetaphrastHttpConfig
---@field providers table<string, MetaphrastProviderConfig>
---@field ui MetaphrastUiConfig
---@field pricing_last_review string

local M = {}

-- Every key `ui.win` accepts. Anything else is a typo or a snacks option we
-- deliberately do not forward, so `warn_unknown_win_keys` reports it once.
local KNOWN_WIN_KEYS = {
  backdrop = true,
  bo = true,
  border = true,
  col = true,
  height = true,
  max_height = true,
  max_width = true,
  min_height = true,
  min_width = true,
  padding = true,
  row = true,
  width = true,
  winblend = true,
  wo = true,
}

local warned_win_keys = {}

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
    max_inserted_lines = 200,
    cache = {
      enabled = true,
      ttl = 7 * 24 * 3600,
      dir = default_cache_dir(),
      max_estimated_cost = 1.0,
      memory_enabled = true,
      memory_max_entries = 512,
      memory_skip_disk_ttl = 5,
    },
    pricing_last_review = "2026-09-03",
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
      google_llm = {
        api_key = vim.env.GOOGLE_TRANSLATE_KEY or vim.env.GOOGLE_API_KEY,
        adc_path = vim.env.GOOGLE_APPLICATION_CREDENTIALS
          or vim.fn.expand("~/.config/gcloud/application_default_credentials.json"),
        gcp_project_id = vim.env.GOOGLE_CLOUD_PROJECT or vim.env.GCLOUD_PROJECT,
        location = "us-central1",
        model = "general/translation-llm",
        base_url = "https://translation.googleapis.com/v3",
        basic_base_url = "https://translation.googleapis.com/language/translate/v2",
        input_per_million = 10.0,
        output_per_million = 10.0,
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
        border = nil,
        width = nil,
        height = nil,
        max_width = 0.6,
        max_height = 0.5,
        min_width = nil,
        min_height = nil,
        padding = { top = 0, bottom = 0, left = 1, right = 1 },
        row = 1,
        col = 0,
        winblend = 0,
        backdrop = false,
        wo = {},
        bo = {},
      },
      hover = {
        show_original = false,
        footer = true,
        render_markdown = true,
        keys = {
          close = { "q", "<Esc>" },
          yank = "y",
          replace = "r",
          original = "o",
          provider = "p",
          help = "?",
        },
        theme = "link",
      },
      notify = {
        icon = "󰊿",
        timeout = 3000,
      },
    },
  }
end

---Report unknown `ui.win` keys through `notify_fn`, at most once per key.
---Pure: it never requires snacks and never mutates the passed table.
---@param win table|nil The user's `ui.win` table.
---@param notify_fn fun(msg: string, level: string) Notification sink.
---@return string[] reported Key names reported by this call, sorted.
function M.warn_unknown_win_keys(win, notify_fn)
  local reported = {}
  if type(win) ~= "table" then
    return reported
  end
  for key in pairs(win) do
    local name = type(key) == "string" and key or tostring(key)
    if not KNOWN_WIN_KEYS[key] and not warned_win_keys[name] then
      reported[#reported + 1] = name
    end
  end
  table.sort(reported)
  for _, name in ipairs(reported) do
    warned_win_keys[name] = true
    notify_fn(string.format("metaphrast: unknown ui.win key %q (ignored)", name), "warn")
  end
  return reported
end

---Forget which unknown keys were already reported.
function M._reset_for_tests()
  warned_win_keys = {}
end

---@param opts table|nil
---@return MetaphrastConfig
function M.merge(opts)
  return vim.tbl_deep_extend("force", M.defaults(), opts or {})
end

return M
