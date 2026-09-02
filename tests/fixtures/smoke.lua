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
