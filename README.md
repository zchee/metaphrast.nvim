# Metaphrast.nvim

Translate text inside Neovim through multiple backends with caching and simple cost guards. Designed to stay cheap at scale: default settings favor low-cost models, reuse cached results, and block unusually expensive calls.

## Features

- Range-aware command `:MetaphrastTranslate` with optional bang to replace buffer text.
- Pluggable providers with shared HTTP abstraction; drop in your own provider if needed.
- File-backed cache under `stdpath('cache')/metaphrast` to avoid paying twice.
- Cost estimation per provider with a configurable safety ceiling.
- Plenary job backend by default for faster, non-blocking HTTP; curl fallback when Plenary is unavailable.
- Async by default: `:MetaphrastTranslate` prompts for the target language when omitted, reports progress via Snacks, and shows results in a Snacks.win floating window unless replacing (falls back to `vim.ui.input`/`vim.notify` + echo when Snacks is missing).

## Backends

- Google Translate/Cloud
- DeepL
- OpenAI
- Google Gemini
- OpenRouter

## Installation

Use your preferred plugin manager; examples:

```lua
-- lazy.nvim
{
  "zchee/metaphrast.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    -- Optional but recommended for richer UI
    "folke/snacks.nvim",
  },
  config = function()
    require("metaphrast").setup()
  end,
}
```

## Configuration

```lua
require("metaphrast").setup({
  provider = "openai", -- auto-falls back to echo if missing API key
  target_lang = "en",
  max_chars = 8000,
  cache = {
    enabled = true,
    ttl = 7 * 24 * 3600,
    max_estimated_cost = 1.0, -- USD per call guard
  },
  http = {
    backend = "plenary", -- default: Plenary job-based curl; set to "curl" to force vim.system
  },
  providers = {
    openai = {
      api_key = os.getenv("OPENAI_API_KEY"),
      model = "gpt-4o-mini",
    },
    google = {
      -- Preferred auth path: ADC from gcloud / GOOGLE_APPLICATION_CREDENTIALS.
      api_key = os.getenv("GOOGLE_TRANSLATE_KEY") or os.getenv("GOOGLE_API_KEY"),
      adc_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
        or vim.fn.expand("~/.config/gcloud/application_default_credentials.json"),
      gcp_project_id = "your-billing-or-quota-project", -- optional override for x-goog-user-project
    },
    deepl = {
      api_key = os.getenv("DEEPL_AUTH_KEY"),
    },
    gemini = {
      api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY"),
      model = "gemini-2.5-flash",
    },
    openrouter = {
      api_key = os.getenv("OPENROUTER_API_KEY"),
      model = "openrouter/auto",
      fallback_models = { "openrouter/auto" },
      retry_on_upstream_rate_limit = true,
    },
    echo = {
      suffix = "[echo]",
    },
  },
})
```

If a configured provider is missing credentials, Metaphrast falls back to the built-in `echo` provider so you can test locally without making paid calls.

For the `google` backend, prefer a Cloud Translation-specific key in
`GOOGLE_TRANSLATE_KEY`. `GOOGLE_API_KEY` remains a fallback, but it is often
shared with other Google services in local setups and may be restricted in ways
that block Cloud Translation.

If Google Application Default Credentials exist at
`~/.config/gcloud/application_default_credentials.json` (or
`GOOGLE_APPLICATION_CREDENTIALS` points to a credentials file), Metaphrast now
prefers ADC bearer-token auth for the Google backend instead of using an API
key. This matches Google Cloud's ADC flow and helps when your project is set up
for OAuth/ADC-based access.

The current implementation is aimed at the authorized-user ADC file written by
`gcloud auth application-default login`. If you point
`GOOGLE_APPLICATION_CREDENTIALS` at another credential type, such as a raw
service-account JSON key, Metaphrast will reject it instead of silently
falling back to the API key path.

Set `providers.google.gcp_project_id` when you want to force a specific
`x-goog-user-project` header. This value overrides any `quota_project_id`
embedded in the ADC file and is useful when billing or quota should be charged
to a different Google Cloud project.

OpenRouter upstream model providers can rate-limit independently from your
OpenRouter account. When `providers.openrouter.retry_on_upstream_rate_limit` is
enabled, Metaphrast retries a provider-originated HTTP 429 once through each
`providers.openrouter.fallback_models` entry, defaulting to `openrouter/auto`.
User/account rate-limit errors still fail immediately so quota and billing
problems stay visible.

## Commands

- `:MetaphrastTranslate [source] [target]`  
  - Operates on the given range (default current line).  
  - Use `!` to replace buffer text; otherwise it shows the translation in a Snacks.win floating window (falls back to `vim.notify` + echo when Snacks is missing).  
  - Prompts for the target language when omitted (uses Snacks.input if available, otherwise `vim.ui.input`).  
  - Runs asynchronously and reports progress via Snacks.notify.  
  - Examples:  
    - `:'<,'>MetaphrastTranslate en es!` (replace visual selection)  
    - `:MetaphrastTranslate es` (auto-detect source, show Spanish translation)
- `:MetaphrastCacheClear` — purge on-disk cache.

## Cost guidance (2025-12)

- Google Cloud Translate v2 text: ~$20 per million chars (first 500k chars/month free).  
- DeepL API Pro: ~$25 per million chars (+base fee).  
- OpenAI gpt-4o-mini: ~$0.15/M input tokens + $0.60/M output tokens (≈0.00075 USD per ~1k chars round trip).  
- Gemini 2.5 Flash: ~$0.30/M input tokens + $2.50/M output tokens.  
- OpenRouter adds ~5% platform fee on top of model rates.  
Use caching and the `max_estimated_cost` guard to stay within budget; at ~50 tokens/request and 50k requests, gpt-4o-mini stays well under $50/month with caching.

### Refreshing prices
- Edit `lua/metaphrast/config.lua` `pricing_last_review` and provider price fields when rates change.  
- Adjust `cache.max_estimated_cost` to your comfort ceiling; example for small snippets: `0.25` (25¢ per request), for large documents raise accordingly.  
- Tune `max_chars` to match typical request size; smaller values reduce worst-case cost and latency.

## Testing

```
make test
```

Tests run in headless Neovim with Plenary and use the built-in `echo` provider to avoid external network calls.
