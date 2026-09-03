-- End-to-end smoke test, run by `make smoke`.
--
-- Translates the fixture's comment block with the echo provider and fails when
-- the hover window does not open. Run under -l so that an uncaught error exits
-- 1; the same error under -c would be swallowed by the implicit qa!.
vim.cmd.edit("tests/fixtures/sample.go")

require("metaphrast").setup({ provider = "echo" })
vim.cmd("1,3MetaphrastTranslate ja")

local hover = require("metaphrast.ui.hover")
local opened = vim.wait(2000, function()
  return hover.is_open_for(0)
end)
if not opened then
  error("hover did not open")
end

-- A `$`-extended blockwise selection resolves every row to its own end. This is
-- the only case that runs through the real user command: `plugin/metaphrast.lua`
-- sourced, `detect_charwise_visual` matching the range against the marks, a real
-- window, and the async write-back path — rather than a direct API call.
--
-- It cannot run on `tests/fixtures/sample.go`, whose comment rows are all around
-- 75 columns with the longest last, so `'>` clamps to the longest row and the
-- bug never reproduces; shortening that row would break what the hover specs
-- depend on. So it runs on its own scratch buffer, driven with real keys because
-- the marks alone never establish the stored selection the probe reads.
local block_before = { "  // alpha beta gamma", "  // x", "func F() {}" }
local block_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(block_buf)
vim.api.nvim_set_option_value("commentstring", "// %s", { buf = block_buf })
vim.api.nvim_buf_set_lines(block_buf, 0, -1, false, block_before)
vim.api.nvim_win_set_cursor(0, { 1, 2 })
vim.api.nvim_feedkeys(vim.keycode("<C-v>1j$:MetaphrastTranslate! ja<CR>"), "x", false)

-- Compares the whole table so the wait returns as soon as anything changes
-- instead of burning its timeout on a write that never lands.
local written = vim.wait(2000, function()
  return not vim.deep_equal(block_before, vim.api.nvim_buf_get_lines(block_buf, 0, -1, false))
end)
local block_after = vim.api.nvim_buf_get_lines(block_buf, 0, -1, false)
-- Row 1 is byte-identical before and after the fix: the block widens from 4 to
-- 19 columns, the paragraph re-wraps to 16, and "alpha beta gamma" occupies
-- exactly 16 columns. What changes is row 2, which now carries the translation
-- instead of a spurious fourth line below the block.
local block_want = { "  // alpha beta gamma", "  // x [echo]->ja", "func F() {}" }
if not (written and vim.deep_equal(block_want, block_after)) then
  error(string.format("blockwise $: want %s, got %s", vim.inspect(block_want), vim.inspect(block_after)))
end
