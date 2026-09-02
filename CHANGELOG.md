# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The repository had no tags before this release, so the first published version
is `v1.0.0`.

## [Unreleased]

### Breaking

- snacks.nvim (>= 2.31.0) is a required dependency. `setup()` raises an
  actionable error when it is missing, and every snacks access goes through
  `require("metaphrast.ui").require_snacks()`.
- The plugin was renamed from `metafrastis` to `metaphrast` in the same release:
  the Lua namespace, the `:Metaphrast*` commands, the `Metaphrast*` highlight
  groups, the cache directory and the vimdoc all use the new name.

### Added

- LSP-hover-style result window (`lua/metaphrast/ui/hover.lua`): it opens
  unfocused under the translated range, closes on cursor movement, and is
  focused by invoking the hover again.
- Hover keymaps, all configurable under `ui.hover.keys`: `q`/`<Esc>` close, `y`
  yanks the translation (never the original text or the padding), `r` replaces
  the source range with the comment leaders re-applied, `o` toggles the original
  text pane, `p` retranslates with another provider, `?` toggles the help.
- `require("metaphrast").hover()` and the `<Plug>(MetaphrastHover)` mapping:
  translate the cursor line, or focus the hover already open for the buffer.
- `:checkhealth metaphrast` (`lua/metaphrast/health.lua`): snacks presence and
  version, `curl`, the optional plenary.nvim and render-markdown.nvim, and the
  current `vim.o.winborder`.
- `require("metaphrast").apply_result(source, translated)` and
  `require("metaphrast").retranslate(source, opts)`: the write-back and
  reprovider paths the hover keys use, exported for other callers.
- `translate_range`, `translate_selection` and `translate_selection_async` now
  report the write-back: after a `replace` they return (or yield to
  `on_success`) `applied` and `reason` alongside the translation. `applied` is
  `true` when the source was written, `false` when the write-back was refused
  because the source text changed since it was translated, and `nil` when no
  write-back was requested. A refused write-back raises an error notification
  instead of writing; `:MetaphrastTranslate` reports it on its progress toast.
- `ui.hover` and `ui.notify` configuration sections, plus `ui.win` bounds
  (`min_width`, `max_width`, `min_height`, `max_height`), `winblend` and
  `backdrop`. Unknown `ui.win` keys are reported once by name.

### Changed

- The result window was rebuilt around `snacks.win` (see README).
- Padding is chrome, not text: `padding.left` is rendered through
  `wo.statuscolumn` and `padding.top`/`padding.bottom` through virtual lines, so
  yanking the translation no longer yanks the indent.
- Progress and the finished message now share one notifier toast, updated in
  place by id, instead of stacking two toasts.
- A provider that fails validation now raises instead of silently rewriting the
  configured provider to `echo`. `setup()` keeps its own warn-and-fall-back to
  `echo` for the initial configuration.
- Default `ui.win.padding` is now `{ top = 0, bottom = 0, left = 1, right = 1 }`
  (was `{ 0, 0, 0, 0 }`).
- Default `ui.win.backdrop` is now `false` (was `40`).
- Default `ui.win.border` now follows `vim.o.winborder`, falling back to
  `"rounded"` when it is unset (was always `"rounded"`).

Users who set any of these keys explicitly are unaffected.

### Removed

- The `vim.notify` / `nvim_echo` / `vim.ui.input` fallbacks used when snacks.nvim
  was absent. Notifications, the target-language prompt and the result window are
  snacks-only.
- Per-call window overrides (`opts.win`); `ui.win` from `setup()` is the only
  source of window configuration.

### Fixed

- Blockwise (`<C-v>`) replacements no longer drop content. A block over the
  comment column merges into one paragraph and can re-wrap to more lines than
  the block has rows; those surplus lines were written past the end of the loop
  and lost, so an `echo`-provider run could report success with a byte-identical
  buffer. They are now inserted directly below the block in the same write —
  one undo step — indented to the block's left edge, with spaces rather than a
  copy of any code to the left of it.
- A blockwise selection whose last row is shorter than the block's start column
  yields `'>` before `'<`; the two slices then overlapped and re-emitted the
  bytes between them on every row. Both columns are now clamped per row.
- A block over multibyte text could cut a UTF-8 sequence in half, sending
  invalid bytes to the provider and writing them back. Both column ends are now
  widened to whole codepoints.
