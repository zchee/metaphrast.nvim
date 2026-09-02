if vim.fn.has("win32") == 1 then
  return -- Windows out of scope (decision 2026-09-02)
end

local hover = require("metaphrast.ui.hover")
local metaphrast = require("metaphrast")
local registry = require("metaphrast.providers")
local ui = require("metaphrast.ui")

-- Core paths that open a real hover window. They live here, not in
-- metaphrast_spec.lua, so the Windows job skips every window-opening spec.
describe("core hover presentation", function()
  ---Set the visual marks a selection translation reads.
  ---@param bufnr integer
  ---@param start_row integer 1-indexed
  ---@param start_col integer 0-indexed
  ---@param end_row integer 1-indexed
  ---@param end_col integer 0-indexed
  local function set_visual_marks(bufnr, start_row, start_col, end_row, end_col)
    vim.api.nvim_buf_set_mark(bufnr, "<", start_row, start_col, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", end_row, end_col, {})
  end

  local function open_buffer(buf_lines, commentstring)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    if commentstring then
      vim.bo[bufnr].commentstring = commentstring
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines)
    return bufnr
  end

  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
  end)

  after_each(function()
    hover._reset_for_tests()
  end)

  it("omits comment leaders in the hover output", function()
    local last_text
    registry.register("capture_window", {
      translate = function(_, payload)
        last_text = payload.text
        return payload.text .. " <t>"
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metaphrast.config.provider = "capture_window"
    metaphrast.config.replace = false
    local bufnr = open_buffer({ "// hello world" }, "// %s")

    metaphrast.translate_range(bufnr, 0, 1, { target_lang = "de", show_window = true })

    assert.equals("hello world", last_text)
    local state = hover.debug()
    assert.equals("shown", state.state)
    assert.same({ "hello world <t>" }, state.result.display_lines)
    assert.is_true(hover.is_open_for(bufnr))
  end)

  it("shows the hover instead of replacing when replace is false", function()
    local bufnr = open_buffer({ "Hello world" })
    set_visual_marks(bufnr, 1, 0, 1, 10)

    metaphrast.translate_selection(bufnr, "V", {
      target_lang = "es",
      replace = false,
      show_window = true,
    })

    local state = hover.debug()
    assert.equals("shown", state.state)
    assert.same({ "Hello world [echo]->es" }, state.result.display_lines)
    assert.equals("Hello world", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.equals(bufnr, state.source.buf)
  end)

  it("strips the comment leader in the hover output", function()
    local bufnr = open_buffer({ "// comment payload" }, "// %s")
    set_visual_marks(bufnr, 1, 0, 1, 18)

    metaphrast.translate_selection(bufnr, "V", {
      target_lang = "es",
      replace = false,
      show_window = true,
    })

    local display = hover.debug().result.display_lines
    assert.is_nil(display[1]:find("//"), "hover output should not contain // : " .. display[1])
  end)

  it("delegates show, focus and close to the hover", function()
    local bufnr = open_buffer({ "hello" })
    local source = {
      buf = bufnr,
      win = vim.api.nvim_get_current_win(),
      sr = 0,
      er = 0,
      lines = { "hello" },
    }
    local result = { translated = "ciao", display_lines = { "ciao" }, meta = { provider = "echo" }, opts = {} }

    assert.is_true(ui.show(source, result))
    assert.equals("shown", hover.debug().state)
    assert.is_true(ui.focus())
    assert.equals("focused", hover.debug().state)
    assert.is_true(ui.close())
    assert.equals("hidden", hover.debug().state)
  end)
end)
