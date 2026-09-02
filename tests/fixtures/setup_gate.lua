-- Fixture for acceptance criterion 1: setup() must fail loudly when
-- snacks.nvim is missing, rather than degrading silently.
--
-- Run out of process, because the assertion is on the exit code:
--   nvim --headless --clean --cmd "set rtp^=$PWD" -l tests/fixtures/setup_gate.lua
-- An uncaught error under -l exits non-zero and writes the message to stderr;
-- the same error inside -c would still exit 0.
--
-- Until the dependency gate lands (implementation step 6) this exits 0.
require("metaphrast").setup({})
