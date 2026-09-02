if vim.fn.has("win32") == 1 then
  return -- Windows out of scope (decision 2026-09-02)
end

describe("setup dependency gate", function()
  it("AC1: exits non-zero and names snacks.nvim when it is missing", function()
    local cwd = vim.fn.getcwd()

    -- Out of process, because the assertion is on the exit code: --clean keeps
    -- snacks.nvim off the runtimepath, and an uncaught error under -l exits 1
    -- (the same error under -c would still exit 0).
    local result = vim
      .system({
        vim.v.progpath,
        "--headless",
        "--clean",
        "--cmd",
        "set rtp^=" .. cwd,
        "-l",
        "tests/fixtures/setup_gate.lua",
      }, { cwd = cwd })
      :wait()

    assert.is_true(result.code ~= 0, "setup() exited 0 without snacks.nvim")
    assert.truthy((result.stderr or ""):find("snacks.nvim", 1, true))
  end)
end)
