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

- `max_inserted_lines` (default 200): the most lines a blockwise replacement
  may insert below the block. The rendered line count comes from the provider's
  reply, so an overlong or malformed response could grow the buffer without
  bound. Exceeding it refuses the write-back with a message instead of
  truncating, reaching the caller as `applied == false` and an error toast.
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
  `true` when the source was written, `false` with a `reason` when nothing was
  written (the source text changed since it was translated, the rendered
  result exceeded `max_inserted_lines`, or the selection was blank), and `nil`
  when no write-back was requested and the translation was shown instead. A
  refused write-back raises an error notification; a blank selection raises a
  warning; `:MetaphrastTranslate` reports both on its progress toast.
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
- `providers.google.gcp_project_id` now defaults to `GOOGLE_CLOUD_PROJECT` or
  `GCLOUD_PROJECT`, as `google_llm` already did. **If you export either
  variable, the `google` backend now sends `x-goog-user-project` with it, so
  the project billed and charged for quota may change.** An explicit
  `providers.google.gcp_project_id` still wins, and setting it to the empty
  string still falls back to the ADC file's `quota_project_id`.
- A Google Cloud project id is now checked before it is used, whichever source
  it came from (`gcp_project_id`, `GOOGLE_CLOUD_PROJECT`/`GCLOUD_PROJECT`, or
  the ADC file's `quota_project_id`). It travels unencoded into the
  `x-goog-user-project` header and into `google_llm`'s request URL, so a value
  containing CR/LF, whitespace, `/`, `?` or `#` would have injected a header or
  re-targeted the request rather than named a project. Such a value is now
  refused with the source named; legacy domain-scoped ids
  (`example.com:project`) stay valid. The `google` backend now resolves the id
  before it exchanges the ADC refresh token, so a rejected value costs no
  request at all instead of one wasted OAuth round trip that also left an
  unusable access token in the shared cache, and `google.validate` reports it,
  so `setup()` warns and falls back to `echo` rather than accepting the
  provider and failing at the first translation.
- `providers.google_llm.location` is now checked the same way. It is another
  segment of the same v3 URL the project id feeds, so a value containing `/`,
  `?`, `#` or CR/LF would have re-targeted the request rather than named a
  region — and `/../` is not cosmetic, because curl normalises it before
  sending. Only letters, digits and `-` are accepted (`us-central1`, `global`,
  `europe-west1`); anything else is refused before the request is built, and
  `setup()` warns and falls back to `echo` instead of raising.
- `setup()` no longer resets the provider registry, so a provider registered
  through `register_provider()` survives it. A user registration wins over the
  built-in of the same name in either order, and `setup()` names any built-in
  it skipped at `debug`. `validate_provider` then validates the user's table,
  and a provider without a `validate` function is accepted, so the fall-back to
  `echo` does not fire for it.
- A `max_inserted_lines` that is not a number is now ignored, with one warning
  naming the value, and the default of 200 applies. It previously raised
  `attempt to compare string with number` from the write path, so the caller
  got a traceback instead of a refusal.
- The same check now covers the value, not only the type, and `max_chars` gets
  it too: both reject NaN and infinity (which silently removed the bound,
  because every comparison against them is false), `max_inserted_lines` rejects
  a negative value (which refused every write, including a reply that added no
  rows) and `max_chars` a non-positive one, and each falls back to its default
  with one warning naming the value. `setup()` re-arms both warnings, so a
  second bad value in the same session is still reported. A cached reply larger
  than four times `max_chars` is now refused on the cache hit as well, instead
  of being replayed for the rest of its TTL.
- Default `ui.win.padding` is now `{ top = 0, bottom = 0, left = 1, right = 1 }`
  (was `{ 0, 0, 0, 0 }`).
- Default `ui.win.backdrop` is now `false` (was `40`).
- Default `ui.win.border` now follows `vim.o.winborder`, falling back to
  `"rounded"` when it is unset (was always `"rounded"`).

Users who set any of these keys explicitly are unaffected.

- `textflow.wrap` applies 行頭禁則: no wrapped line opens with `。、，．・：；？！`, a
  closing bracket (`）」』】…`) or a closing quote, so a Japanese translation no
  longer leaves a full stop stranded at the head of a line. The break moves
  back over the run instead, letting those characters ride on the line before
  it (追い出し) -- hanging them past the last column was the alternative, but
  every caller wraps to a width it must not exceed (the hover to the columns
  the window has, the comment write-back to the source's budget), so the break
  moves rather than the margin. Two cases keep the plain break: nothing can
  stay behind (the run reaches the line's first unit), and what would move does
  not fit on one line, where shortening the line would buy nothing. The
  strict-mode-only characters (`ー`, small kana, iteration marks) stay
  breakable, matching CSS `line-break: normal`. `textflow.is_no_line_start()`
  exposes the predicate.

### Removed

- The `vim.notify` / `nvim_echo` / `vim.ui.input` fallbacks used when snacks.nvim
  was absent. Notifications, the target-language prompt and the result window are
  snacks-only.
- Per-call window overrides (`opts.win`); `ui.win` from `setup()` is the only
  source of window configuration.

### Fixed

- Provider errors no longer carry the Lua chunk position. Every
  user-facing `error()` under `lua/metaphrast/providers/` now raises at
  level 0, so the `setup()` fallback warning and the translation failure
  toasts read `google translate failed: ...` rather than
  `./lua/metaphrast/providers/google.lua:86: google translate failed: ...`.
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
- Widening a blockwise region to whole codepoints reopened a row the per-row
  clamp had just emptied, so a short last row deleted one character from every
  multibyte row of the block. Emptiness is now decided before either end moves.
- A charwise (`v`) selection ending on a multibyte character was cut one *byte*
  past the mark, handing the provider a broken UTF-8 sequence and splicing the
  reply into the middle of a character. Both ends of a charwise selection are
  now snapped to codepoint boundaries. Blockwise marks are deliberately left
  raw: their two columns are shared by every row, so snapping them against the
  start and end rows widened the block onto text the user never selected on all
  the others — the per-row resolver already snaps each row for itself.
- A blockwise selection that clamps to nothing on every row produced a payload
  of newlines only. It was still sent — billing a provider for nothing — and
  the reply was written into a line the user had not selected. A blank
  selection now returns without calling the provider, and reports the skip
  instead of finishing with "Translated via …" over an untouched buffer.
- A provider reply containing a newline crashed a linewise or range write-back
  with `'replacement string' item contains newlines`, leaving the progress
  toast hanging. The rendered lines are now flattened before the write, as the
  blockwise branch already did.
- The surplus line's indent was measured with `strdisplaywidth` against
  whichever buffer happened to be current (the hover float, on the `r` path),
  so a tab-indented block could be aligned to the wrong `'tabstop'`. It is now
  measured inside the buffer being written.
- A blank rendered surplus line was written as a run of pad spaces. Blank
  lines now stay empty, so a trim-on-save formatter has nothing to report.
- The hover no longer runs its translation past the right border. Text with no
  comment structure (markdown prose, plain text) reached the window in
  *source-shaped* lines — `util.reflow_lines` packs the reply into as many lines
  as the source had, and dumps whatever is left onto the last one — so a reply
  whose paragraphs did not line up with the source arrived as a mix of
  half-filled lines and lines far wider than the window. Neovim's soft wrap hid
  that only partly, and `wo.wrap = false` clipped the overshoot outright. The
  hover now reads the translation itself, one line per paragraph, and hard-wraps
  it to `hover.text_budget()` (the window's width ceiling minus
  `padding.left`/`padding.right`) on `textflow.wrap`'s CJK-aware break units, so
  every line fits whatever `wo.wrap` says. A ratio `width`/`max_width` moves the
  budget with the screen, so `VimResized` re-wraps before it refits.
  `result.display_lines` keeps mirroring the source structure for the write-back
  and echo paths.
- `util.reflow_lines` measured widths in bytes. A CJK reply counts three bytes
  per column there, so it broke after filling roughly a third of the columns its
  source line occupied. Widths are display columns now, as everywhere else in
  the plugin; the line count it returns is unchanged, so a write-back still
  never grows or shrinks the range it replaces.
