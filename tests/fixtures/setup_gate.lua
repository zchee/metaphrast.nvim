-- Fixture for acceptance criterion 1: setup() must fail loudly when
-- snacks.nvim is missing, rather than degrading silently.
--
-- Run out of process, because the assertion is on the exit code:
--   nvim --headless --clean --cmd "set rtp^=$PWD" -l tests/fixtures/setup_gate.lua
-- An uncaught error under -l exits non-zero and writes the message to stderr;
-- the same error inside -c would still exit 0.
--
-- With the gate in place this exits 1 and names snacks.nvim on stderr.
require("metaphrast").setup({})
