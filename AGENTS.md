# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test          # headless Neovim + plenary.busted over tests/
make fmt           # stylua .
make lint          # luacheck lua/ plugin/ tests/
stylua --check lua # what CI runs (only lua/ is checked in CI)
```

Tests git-clone plenary.nvim into `$PLENARY_DIR` (default `/tmp/plenary.nvim`) on first run. Run a single spec with:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/metaphrast/textflow_spec.lua"
```

## Naming

The Lua namespace, user commands, highlight groups, cache directory, vimdoc, and README all use `metaphrast` (renamed from `metafrastis` on 2026-09-02). Never reintroduce `metafrastis`; `rg -i metafrastis` outside `.omc/drafts` must stay empty.

## Target platform

- Neovim nightly only. Do not add compatibility guards (`if vim.system`, `vim.uv or vim.loop`); remove them when you touch code that has them.
- `curl` is a hard runtime dependency (`http.lua` shells out to it). plenary.nvim and snacks.nvim are optional and must stay behind `pcall(require, ...)` with the existing fallbacks.

## Docs are generated

`doc/metaphrast.txt` is regenerated from `README.md` by `.github/workflows/docs.yaml` (panvimdoc) on push to main. Edit `README.md`, never the `.txt`.

Known README vs code mismatches (code is canonical until the user says otherwise):
- DeepL key env var: code reads `DEEPL_AUTH_KEY`; README says `DEEPL_API_KEY`.
- Gemini key env var: code reads `GOOGLE_API_KEY` then `GEMINI_API_KEY`; README says `GOOGLE_GENAI_KEY`.
- `:MetaphrastTranslateUI` is documented but does not exist; its behavior lives in `:MetaphrastTranslate` (async, popup unless `!`).

## Style

- StyLua enforced (`.stylua.toml`): 2-space indent, 120 columns, double quotes, `call_parentheses = "Always"`, and `sort_requires` (top-of-file `require` blocks are alphabetized; do not hand-order them).
- Module pattern `local M = {} ... return M`; LuaCATS annotations (`---@class`, `---@param`, `---@return`) on every public function; doc comments end with a period.
- Stateful modules expose `_reset_for_tests()`; add one when you introduce module-level state.
- Commit messages: Conventional Commits, `type(scope): description` (e.g. `feat(textflow): wrap CJK output`).

## Testing

- Framework is plenary.busted; specs live in `tests/metaphrast/<module>_spec.lua`.
- No network in tests: use `setup({ provider = "echo" })`, or pass a fake `_http` function to a provider's `translate()`.
- Mock snacks with `package.loaded["snacks"] = {...}` (or `= false` to test fallbacks) and clear it in `after_each`.
- Call `_reset_for_tests()` on `metaphrast`, `metaphrast.ui`, and `metaphrast.providers.google` in `before_each` as needed.
- Keep `cache.ttl <= 5` in cache tests so entries stay memory-only and never write to disk.

## Architecture notes that are easy to get wrong

- Translation flow: `command → comment.strip_lines → textflow.segment → cache.get → registry.translate → cache.put → textflow.wrap / reapply leaders → buffer replace or ui popup`.
- `textflow.segment` merges consecutive comment lines into one paragraph so soft-wrapped sentences translate as a unit; blank comment lines and list markers (`- `, `* `, `1. `) break paragraphs; non-comment lines pass through untranslated.
- Widths are always display columns (`vim.fn.strdisplaywidth`), never `#s`. CJK characters (width >= 2) are their own wrap units.
- If a provider returns a different paragraph count than sent, the whole output is placed at the first paragraph slot rather than dropped. Single-source-line paragraphs are not re-wrapped.
- Cost guard runs before the cache lookup, so an over-budget request errors even on a cache hit.
- Provider errors must stay diagnosable: distinct messages for curl failure (`res.code ~= 0`, include stderr) and HTTP >= 400 (include body).
- Price changes: bump `pricing_last_review` and the provider price fields in `lua/metaphrast/config.lua`.
