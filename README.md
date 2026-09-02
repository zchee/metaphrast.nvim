# Metaphrast.nvim

Translate text inside Neovim through multiple backends with caching and simple cost guards. Designed to stay cheap at scale: default settings favor low-cost models, reuse cached results, and block unusually expensive calls.

## Features

- Range-aware command `:MetaphrastTranslate` with optional bang to replace buffer text.
- Pluggable providers with shared HTTP abstraction; drop in your own provider if needed.
- File-backed cache under `stdpath('cache')/metaphrast` to avoid paying twice.
- Cost estimation per provider with a configurable safety ceiling.
- Plenary job backend by default for faster, non-blocking HTTP; curl fallback when Plenary is unavailable.
- Async by default: `:MetaphrastTranslate` prompts for the target language when omitted, reports progress in a single Snacks notifier toast, and shows the result in an LSP-style hover window unless replacing.
- Hover keymaps to yank the translation, write it back to the buffer, show the original text next to it, and retranslate with another provider.

## Backends

- Google Translate/Cloud
- Google Cloud Translation LLM (`google_llm`)
- DeepL
- OpenAI
- Google Gemini
- OpenRouter

## Requirements

| Dependency | Status | Used for |
|---|---|---|
| Neovim nightly | required | The plugin targets nightly only and carries no compatibility guards. |
| `curl` | required | Every provider request shells out to it. |
| [folke/snacks.nvim](https://github.com/folke/snacks.nvim) >= 2.31.0 | required | Hover window, notifier toasts, target-language prompt. `setup()` raises an error when it is missing. |
| [nvim-lua/plenary.nvim](https://github.com/nvim-lua/plenary.nvim) | optional | Job-based async HTTP; without it translation falls back to a blocking request. |
| [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) | optional | Renders the hover body as markdown. |

`:checkhealth metaphrast` reports all of these, plus the current `vim.o.winborder`.

## Installation

Use your preferred plugin manager; examples:

```lua
-- lazy.nvim
{
  "zchee/metaphrast.nvim",
  dependencies = {
    "folke/snacks.nvim", -- required
    "nvim-lua/plenary.nvim", -- optional: async HTTP
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
  max_inserted_lines = 200, -- cap on lines a blockwise replace may add below the block
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
    google_llm = {
      -- Same ADC-first auth as `google`; falls back to an API key.
      api_key = os.getenv("GOOGLE_TRANSLATE_KEY") or os.getenv("GOOGLE_API_KEY"),
      adc_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
        or vim.fn.expand("~/.config/gcloud/application_default_credentials.json"),
      gcp_project_id = os.getenv("GOOGLE_CLOUD_PROJECT"), -- required: the model is a project resource
      location = "us-central1", -- or "global"
      model = "general/translation-llm",
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

If a configured provider is missing credentials, `setup()` warns and falls back to the built-in `echo` provider so you can test locally without making paid calls. A later request for a provider that is still unusable (for example after `p` in the hover) fails with an error toast instead of silently switching.

For the `google` and `google_llm` backends, prefer a Cloud Translation-specific
key in `GOOGLE_TRANSLATE_KEY`. `GOOGLE_API_KEY` remains a fallback, but it is often
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

The `google_llm` backend calls Cloud Translation's `general/translation-llm`
model instead of the NMT model. With ADC it uses Advanced v3
(`:translateText`); with an API key it uses Basic v2, which accepts the same
model parameter. Either way a project id is required, from
`providers.google_llm.gcp_project_id`, `GOOGLE_CLOUD_PROJECT`/`GCLOUD_PROJECT`,
or the ADC file's `quota_project_id`, because the model is addressed as
`projects/<project>/locations/<location>/models/general/translation-llm`.

The `location` must be one the Translation LLM supports — `us-central1` or
`global` — and the request's parent location must match the location inside
that model resource. Metaphrast builds both from `providers.google_llm.location`
so they cannot drift; a mismatch is rejected by the API as HTTP 400
INVALID_ARGUMENT.

OpenRouter upstream model providers can rate-limit independently from your
OpenRouter account. When `providers.openrouter.retry_on_upstream_rate_limit` is
enabled, Metaphrast retries a provider-originated HTTP 429 once through each
`providers.openrouter.fallback_models` entry, defaulting to `openrouter/auto`.
User/account rate-limit errors still fail immediately so quota and billing
problems stay visible.

### Hover window options

These are the defaults; every key is optional.

```lua
require("metaphrast").setup({
  ui = {
    win = {
      border = nil, -- nil follows vim.o.winborder ("rounded" when unset); string or 8-item table
      width = nil, -- columns, a 0<n<1 fraction of vim.o.columns, or nil for auto
      height = nil, -- rows, a 0<n<1 fraction of the usable rows, or nil for auto
      max_width = 0.6, -- bounds the auto width only
      max_height = 0.5, -- bounds the auto height only
      min_width = nil, -- bounds the auto width only
      min_height = nil, -- bounds the auto height only
      padding = { top = 0, bottom = 0, left = 1, right = 1 }, -- chrome, never buffer text
      row = 1, -- offset from the anchor line
      col = 0, -- offset from the anchor column
      winblend = 0, -- mapped to wo.winblend
      backdrop = false, -- a number (e.g. 40) re-enables the dimmed backdrop
      wo = {}, -- window-local options, merged last (your wrap = false wins)
      bo = {}, -- buffer-local options, merged last
    },
    hover = {
      show_original = false, -- open with the original text pane visible
      footer = true, -- key-hint footer
      render_markdown = true, -- filetype "markdown"; false uses "metaphrast" so no renderer attaches
      keys = {
        close = { "q", "<Esc>" },
        yank = "y",
        replace = "r",
        original = "o",
        provider = "p",
        help = "?",
      },
      theme = "link", -- "link" follows the colorscheme; "teal" is the legacy palette
    },
    notify = {
      icon = "󰊿",
      timeout = 3000, -- ms a finished toast stays up
    },
  },
})
```

`min_width`, `max_width`, `min_height` and `max_height` take two forms: a value
below `1` is a ratio (of `vim.o.columns` for widths, of the usable rows for
heights), a value of `1` or more is an absolute count. They bound the **auto**
size only — an explicit `width`/`height` ignores them and is capped only by the
screen.

`padding.left` is rendered through `wo.statuscolumn` and `padding.top`/`bottom`
through virtual lines, so none of it ends up in the buffer text. `padding.right`
is slack inside the window width and therefore only pads lines that are not
wrapped: Neovim wraps at `width - textoff`, so a wrapped line still reaches the
right border.

`row` and `col` are offsets from the anchor line. When the hover opens above the
range they are mirrored, so `row = 1` keeps one row of distance on whichever side
the window lands.

## Commands

- `:MetaphrastTranslate [source] [target]`
  - Operates on the given range (default current line).
  - Use `!` to replace buffer text; otherwise the translation opens in the hover window.
  - Replacing a blockwise (`<C-v>`) selection can produce more lines than the block has rows, because the selected comment rows are translated as one paragraph and re-wrapped. The extra lines are inserted directly below the block, aligned under its left edge, in the same undo step. A reply that would insert more than `max_inserted_lines` (default 200) is refused with an error toast rather than truncated.
  - Prompts for the target language when omitted (`snacks.input`).
  - Runs asynchronously; progress and the final message share one notifier toast.
  - Called without a range while a hover is already open for the current buffer, it focuses that hover instead of translating again.
  - Examples:
    - `:'<,'>MetaphrastTranslate en es!` (replace visual selection)
    - `:MetaphrastTranslate es` (auto-detect source, show Spanish translation)
- `:MetaphrastCacheClear` — purge on-disk cache.

## Hover window

The result window follows the `vim.lsp.buf.hover` model:

- It opens **unfocused**, anchored under the translated range — above it when there is more room above.
- Cursor movement in the source buffer closes it, as does entering insert mode or leaving the buffer.
- Invoking it again while it is open **focuses** it and enables the keymaps below. Three entry points do this: `require("metaphrast").hover()`, `<Plug>(MetaphrastHover)`, and `:MetaphrastTranslate` without a range.
- A focused hover closes on `q`, `<Esc>`, `r`, or when it loses focus.

No keymap is bound by default. Map `<Plug>(MetaphrastHover)` yourself:

```lua
vim.keymap.set("n", "<leader>k", "<Plug>(MetaphrastHover)")
```

With no hover open, `hover()` translates the current line, so one key both translates and focuses. It never writes into the buffer, even with `replace = true` in `setup()`; use `r` inside the hover or `:MetaphrastTranslate!` for that. `:MetaphrastTranslate!` without a range always translates and writes back, even while a hover is open.

### Keymaps inside the focused hover

| Key | Action |
|---|---|
| `q`, `<Esc>` | Close the hover. |
| `y` | Yank the translation into `"`, and into `+` when Neovim has clipboard support. Only the translation is yanked — never the original text, never the padding. |
| `r` | Replace the source range with the translation, re-applying the comment leaders, then close. Refused with an error toast when the source text changed since it was translated. Over a blockwise (`<C-v>`) selection, a translation that wraps to more lines than the block has rows inserts the extra lines below the block, aligned under its left edge; a reply that would insert more than `max_inserted_lines` (default 200) is refused with an error toast rather than truncated, and the hover stays open. |
| `o` | Toggle the original text (対訳) above the translation in the same window. |
| `p` | Pick another provider and retranslate; the result replaces the hover contents. When the retranslation fails, the progress toast is hidden, the error arrives as a separate toast, and the hover is focused again. Cancelling the picker also refocuses the hover. |
| `?` | Toggle the key-hint help window. |

Every key is configurable under `ui.hover.keys`; set one to `false` to disable it.

## Cost guidance (2026-09)

- Google Cloud Translate v2 text: ~$20 per million chars (first 500k chars/month free).  
- Google Cloud Translation LLM: ~$10 per million input chars + ~$10 per million output chars (billed on both directions, unlike NMT).  
- DeepL API Pro: ~$25 per million chars (+base fee).  
- OpenAI gpt-4o-mini: ~$0.15/M input tokens + $0.60/M output tokens (≈0.00075 USD per ~1k chars round trip).  
- Gemini 2.5 Flash: ~$0.30/M input tokens + $2.50/M output tokens.  
- OpenRouter adds ~5% platform fee on top of model rates.  
Use caching and the `max_estimated_cost` guard to stay within budget; at ~50 tokens/request and 50k requests, gpt-4o-mini stays well under $50/month with caching.

### Refreshing prices
- Edit `lua/metaphrast/config.lua` `pricing_last_review` and provider price fields when rates change.  
- Adjust `cache.max_estimated_cost` to your comfort ceiling; example for small snippets: `0.25` (25¢ per request), for large documents raise accordingly.  
- Tune `max_chars` to match typical request size; smaller values reduce worst-case cost and latency.

## Behavior changes

Upgrade notes for users of the pre-hover result window:

1. **snacks.nvim is required.** `setup()` raises an actionable error when it is
   missing; the `vim.notify` / `nvim_echo` / `vim.ui.input` fallbacks are gone.
2. **Changed defaults:** `ui.win.padding` is `{ top = 0, bottom = 0, left = 1, right = 1 }`
   (was all zeros), `ui.win.backdrop` is `false` (was `40`), and `ui.win.border`
   follows `vim.o.winborder` (was always `"rounded"`). Setting these keys
   explicitly is unaffected.
3. `row`/`col` keep their meaning below the anchor and are mirrored above it. The
   window now anchors to the last (or, above, the first) line of the translated
   range rather than to the cursor, when that line is visible.
4. Cursor movement still closes an unfocused hover. A focused hover closes on
   `q`, `<Esc>`, `r`, or when it loses focus.
5. `padding.right` pads unwrapped lines only (see the hover options above).
6. An explicit `ui.win.width` wider than the editor is reduced to fit instead of
   running off the screen; `min_*`/`max_*` bound the auto size only.
7. Per-call window overrides (`opts.win`) are gone; `ui.win` from `setup()` is the
   only source of window configuration.
8. This is the first tagged release (`v1.0.0`); the repository had no tags before
   it.

## Testing

```
make test   # headless Neovim + plenary.busted over tests/
make smoke  # end-to-end: opens a hover with the echo provider
make lint   # luacheck
```

`make test` git-clones plenary.nvim into `$PLENARY_DIR` (default
`/tmp/plenary.nvim`) and snacks.nvim into `$SNACKS_DIR` (default
`/tmp/snacks.nvim`), checking snacks out at the pinned `$SNACKS_REF`. Specs use
the built-in `echo` provider, so no test makes a network call.

Run a single spec with `PlenaryBustedDirectory`, which is what passes
`minimal_init.lua` to the child process (`PlenaryBustedFile` does not, so snacks
never loads there):

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/metaphrast/ui/hover_spec.lua { minimal_init = 'tests/minimal_init.lua' }"
```
