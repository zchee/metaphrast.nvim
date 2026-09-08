# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test          # headless Neovim + plenary.busted over tests/
make fmt           # stylua .
make lint          # luacheck lua/ plugin/ tests/
stylua --check lua # what CI runs (only lua/ is checked in CI)
```

Tests git-clone plenary.nvim into `$PLENARY_DIR` (default `/tmp/plenary.nvim`) and snacks.nvim into `$SNACKS_DIR` (default `/tmp/snacks.nvim`) on first run; both clones track upstream HEAD, and an existing checkout is used as it stands. `make smoke` runs the end-to-end hover fixture. Run a single spec with:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/metaphrast/textflow_spec.lua { minimal_init = 'tests/minimal_init.lua' }"
```

`PlenaryBustedFile` spawns the child without `-u`, so snacks never loads and
every `setup()` in the spec errors; always use the `PlenaryBustedDirectory`
form above, even for a single file.

## Naming

The Lua namespace, user commands, highlight groups, cache directory, vimdoc, and README all use `metaphrast` (renamed from `metafrastis` on 2026-09-02). Never reintroduce `metafrastis`; `rg -i metafrastis lua/ plugin/ tests/ doc/ README.md` must stay empty (this rule and the CHANGELOG rename note are the only places the old name may appear).

## Target platform

- Neovim nightly only. Do not add compatibility guards (`if vim.system`, `vim.uv or vim.loop`); remove them when you touch code that has them.
- `curl` is a hard runtime dependency (`http.lua` shells out to it). plenary.nvim is optional and must stay behind `pcall(require, ...)`.
- snacks.nvim (>= 2.31.0) is a hard dependency, reached only through `require("metaphrast.ui").require_snacks()`; never reference the `Snacks` global (`.luacheckrc` allows only `vim`, and `rg "Snacks\." lua/ plugin/` must stay empty). No fallback path may come back.
- Every window write goes through `hover.in_source` (`nvim_win_call(source.win, ...)`), because a `relative="cursor"` float re-anchors to whatever window is current. `snacks_opts` always emits `resize = false` so snacks' own `VimResized` handler never writes behind our back, and `compute_geometry` is the only producer of `row`/`col`/`width`/`height`.

## Docs are generated

`doc/metaphrast.txt` is regenerated from `README.md` by `.github/workflows/docs.yaml` (panvimdoc) on push to main. Edit `README.md`, never the `.txt`.

## Style

- StyLua enforced (`.stylua.toml`): 2-space indent, 120 columns, double quotes, `call_parentheses = "Always"`, and `sort_requires` (top-of-file `require` blocks are alphabetized; do not hand-order them).
- Module pattern `local M = {} ... return M`; LuaCATS annotations (`---@class`, `---@param`, `---@return`) on every public function; doc comments end with a period.
- Stateful modules expose `_reset_for_tests()`; add one when you introduce module-level state.
- Commit messages: Conventional Commits, `type(scope): description` (e.g. `feat(textflow): wrap CJK output`).

## Testing

- Framework is plenary.busted; specs live in `tests/metaphrast/<module>_spec.lua`.
- No network in tests: use `setup({ provider = "echo" })`, or pass a fake `_http` function to a provider's `translate()`. What is forbidden is an external endpoint, not a socket to this process: a loopback `vim.uv` listener driven by a real `curl` is allowed for transport specs, and `curl` is a hard dependency so such a spec has no skip path.
- Specs run against real snacks, cloned by `tests/minimal_init.lua` at upstream HEAD; never assign `package.loaded["snacks"]`. Fake `vim.ui.select` in specs that exercise the provider key — the default implementation blocks headless Neovim.
- Call `_reset_for_tests()` on `metaphrast`, `metaphrast.ui`, and `metaphrast.providers.google` in `before_each` as needed.
- Keep `cache.ttl <= 5` in cache tests so entries stay memory-only and never write to disk.

## Architecture notes that are easy to get wrong

- Translation flow: `command → comment.strip_lines → textflow.segment → cache.get → registry.translate → cache.put → textflow.wrap / reapply leaders → buffer replace or ui popup`.
- `textflow.segment` merges consecutive comment lines into one paragraph so soft-wrapped sentences translate as a unit; blank comment lines and list markers (`- `, `* `, `1. `) break paragraphs; non-comment lines pass through untranslated.
- Widths are always display columns (`vim.fn.strdisplaywidth`), never `#s`. CJK characters (width >= 2) are their own wrap units.
- `textflow.wrap` keeps 行頭禁則 characters (`textflow.is_no_line_start`) off a line head by moving the break back (追い出し), never by hanging them past `width`: every caller wraps to a width it must not exceed. It gives up — plain break — when nothing can stay behind, or when what would move does not fit on one line. Never trade the `<= width` guarantee for a nicer break. The set is wide punctuation only: ASCII `.`/`)` at the head of a break unit is a path or identifier (`.gitignore`), not punctuation, and must stay breakable.
- `result.display_lines` is the translation laid out like the source for the hover: one entry per paragraph, blank comment lines as `""`, non-comment lines verbatim, unwrapped. `lay_out` in `lua/metaphrast.lua` is the only place that maps reply paragraphs onto layout segments (including the count-mismatch fallback); the write-back and the hover both go through it. The echo/return text (`echo_lines`) is a separate rendering that mirrors the source's *line* count for the non-comment path; never derive one from the other.
- The hover hard-wraps each `display_lines` entry to `hover.text_budget` (the window's width ceiling minus `padding.left`/`padding.right`). Anything that can move the budget must re-render (`render_content`), because a ratio `width`/`max_width` follows `vim.o.columns`.
- If a provider returns a different paragraph count than sent, the whole output is placed at the first paragraph slot rather than dropped. Single-source-line paragraphs are not re-wrapped.
- Cost guard runs before the cache lookup, so an over-budget request errors even on a cache hit.
- Provider errors must stay diagnosable: distinct messages for curl failure (`res.code ~= 0`, include stderr) and HTTP >= 400 (include body).
- Price changes: bump `pricing_last_review` and the provider price fields in `lua/metaphrast/config.lua`.
