---
name: check
description: Run the full local quality gate for this plugin (stylua --check, luacheck, and the plenary test suite) and report a concise pass/fail summary with the failing spec names and assertion messages. Use before committing, after finishing a change, or when asked to verify, check, or run the tests.
---

Run the three gates in order and stop at the first failure only if it makes later steps meaningless (a stylua failure does not; run everything).

```bash
stylua --check lua plugin tests
make lint
make test 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
```

Notes:
- `make test` runs `PlenaryBustedDirectory tests/`; it prints one `Success/Failed/Errors` block per spec file, so count the blocks (there is one per `tests/metaphrast/*_spec.lua`) and confirm none reports `Failed` or `Errors` above zero. A zero exit with a missing block means a spec file crashed while loading.
- First run clones plenary.nvim into `$PLENARY_DIR` (default `/tmp/plenary.nvim`); a network failure there is an environment problem, not a test failure.
- To re-run one spec while iterating:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/metaphrast/<module>_spec.lua"
```

Report format: one line per gate (`stylua: ok`, `luacheck: 0 warnings`, `tests: N/N specs, X passed`), then for any failure the spec file, `it(...)` name, and the assertion message verbatim in a code block. Do not fix anything unless the user asked for fixes.
