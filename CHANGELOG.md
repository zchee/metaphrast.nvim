# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The repository had no tags before this release, so the first published version
is `v1.0.0`.

## [Unreleased]

### Changed

- **Breaking:** snacks.nvim is now a required dependency; the result window was
  rebuilt as an LSP-hover-style popup (see README). `setup()` raises an
  actionable error when snacks.nvim is not installed, and the previous
  `vim.notify` / `nvim_echo` / `vim.ui.input` fallbacks are gone.
- Default `ui.win.padding` is now `{ top = 0, bottom = 0, left = 1, right = 1 }`
  (was `{ 0, 0, 0, 0 }`). Padding is chrome: it no longer enters the buffer
  text, so yanking the translation no longer yanks the indent.
- Default `ui.win.backdrop` is now `false` (was `40`).
- Default `ui.win.border` now follows `vim.o.winborder`, falling back to
  `"rounded"` when it is unset (was always `"rounded"`).

Users who set any of these keys explicitly are unaffected.
