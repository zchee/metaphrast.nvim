local metafrastis = require("metafrastis")
local registry = require("metafrastis.providers")

describe("setup", function()
  before_each(function()
    metafrastis._reset_for_tests()
  end)

  it("falls back to echo when provider credentials are missing", function()
    metafrastis.setup({
      provider = "openai",
      providers = {
        openai = { api_key = "" },
      },
    })
    assert.equals("echo", metafrastis.config.provider)
  end)

  it("keeps chosen provider when valid", function()
    metafrastis.setup({ provider = "echo" })
    assert.equals("echo", metafrastis.config.provider)
  end)
end)

describe("translation core", function()
  before_each(function()
    metafrastis._reset_for_tests()
  end)

  it("translates via echo provider", function()
    metafrastis.setup({ provider = "echo" })
    local out = metafrastis.translate("Hello", { target_lang = "es" })
    assert.equals("Hello [echo]->es", out)
  end)

  it("normalizes carriage returns from providers", function()
    registry.register("cr", {
      translate = function()
        return "hello\r\nworld\r"
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metafrastis.config.provider = "cr"
    metafrastis.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "stub" })

    local out = metafrastis.translate_range(bufnr, 0, 1, { target_lang = "en" })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.equals("hello world", out)
    assert.equals(1, #lines)
    assert.equals("hello world", lines[1])
  end)

  it("retries OpenRouter fallback model for line-range upstream rate limits", function()
    local requested_models = {}
    metafrastis.setup({
      provider = "openrouter",
      cache = { enabled = false },
      providers = {
        openrouter = {
          api_key = "or-k",
          model = "deepseek/deepseek-v4-flash",
          base_url = "https://or.test",
          fallback_models = { "openrouter/auto" },
        },
      },
    })
    metafrastis.http = function(_, _, opts)
      local body = vim.json.decode(opts.data)
      table.insert(requested_models, body.model)
      assert.truthy(body.messages[2].content:find("first line\nsecond line", 1, true))
      if #requested_models == 1 then
        return {
          code = 0,
          http_status = 429,
          stdout = vim.json.encode({
            error = {
              message = "Provider returned error",
              code = 429,
              metadata = {
                raw = "deepseek/deepseek-v4-flash is temporarily rate-limited upstream",
                provider_name = "DeepInfra",
                is_byok = false,
              },
            },
          }),
        }
      end
      return {
        code = 0,
        stdout = vim.json.encode({
          choices = { { message = { content = "fallback translation\nsecond translated" } } },
        }),
      }
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "first line", "second line" })

    local out = metafrastis.translate_range(bufnr, 0, 2, { target_lang = "ja" })

    assert.equals("fallback translation\nsecond translated", out)
    assert.same({ "deepseek/deepseek-v4-flash", "openrouter/auto" }, requested_models)
  end)

  it("caches repeated calls", function()
    local calls = 0
    registry.register("count", {
      translate = function(_, payload)
        calls = calls + 1
        return payload.text .. " #" .. calls
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metafrastis.config.provider = "count"
    local first = metafrastis.translate("hi", { target_lang = "fr" })
    local second = metafrastis.translate("hi", { target_lang = "fr" })
    assert.equals("hi #1", first)
    assert.equals("hi #1", second)
    assert.equals(1, calls)
  end)

  it("rejects calls that exceed cost guard", function()
    registry.register("expensive", {
      estimate_cost = function()
        return 2
      end,
      translate = function()
        return "should-not-run"
      end,
    })
    metafrastis.config.provider = "expensive"
    metafrastis.config.cache.max_estimated_cost = 1
    assert.has_error(function()
      metafrastis.translate("hi", { target_lang = "fr" })
    end)
  end)

  it("uses provider-specific config during validation", function()
    registry.register("needs_secret", {
      validate = function(cfg)
        if cfg.secret ~= "ok" then
          return false, "secret missing"
        end
        return true
      end,
      translate = function(_, payload)
        local cfg = payload.config.providers.needs_secret
        return string.format("%s-%s", payload.text, cfg.secret)
      end,
    })
    metafrastis.config.provider = "needs_secret"
    metafrastis.config.providers.needs_secret = { secret = "ok" }

    local out = metafrastis.translate("ping", { target_lang = "en" })
    assert.equals("ping-ok", out)
  end)

  it("falls back to echo when provider lacks credentials at call time", function()
    metafrastis.setup({
      provider = "deepl",
      providers = {
        deepl = { api_key = "" },
      },
    })

    local out, meta = metafrastis.translate("Hello", { target_lang = "ja" })
    assert.equals("Hello [echo]->ja", out)
    assert.is_table(meta)
    assert.equals("echo", meta.provider)
    assert.is_false(meta.cached)
  end)
end)

describe("comment handling", function()
  before_each(function()
    metafrastis._reset_for_tests()
  end)

  it("strips line comments before translation and reapplies on replace", function()
    local last_text
    registry.register("capture", {
      translate = function(_, payload)
        last_text = payload.text
        return payload.text .. " <t>"
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metafrastis.config.provider = "capture"
    metafrastis.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "// anthropicLLM implements the adk [model.LLM] interface using the Anthropic SDK.",
    })

    metafrastis.translate_range(bufnr, 0, 1, { target_lang = "es" })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("// anthropicLLM implements the adk [model.LLM] interface using the Anthropic SDK. <t>", lines[1])
    assert.equals("anthropicLLM implements the adk [model.LLM] interface using the Anthropic SDK.", last_text)
  end)

  it("strips block comments before translation and reapplies with suffix", function()
    local last_text
    registry.register("capture_block", {
      translate = function(_, payload)
        last_text = payload.text
        return payload.text .. " <t>"
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metafrastis.config.provider = "capture_block"
    metafrastis.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "/* %s */"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "    /* Translate only the inner text */",
    })

    metafrastis.translate_range(bufnr, 0, 1, { target_lang = "en" })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("    /* Translate only the inner text <t> */", lines[1])
    assert.equals("Translate only the inner text", last_text)
  end)

  it("omits comment leaders in show_window output", function()
    local last_text
    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }

    registry.register("capture_window", {
      translate = function(_, payload)
        last_text = payload.text
        return payload.text .. " <t>"
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metafrastis.config.provider = "capture_window"
    metafrastis.config.replace = false

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "// hello world" })

    metafrastis.translate_range(bufnr, 0, 1, { target_lang = "de", show_window = true })

    assert.equals("hello world", last_text)
    assert.truthy(win_opts)
    assert.equals("hello world <t>", win_opts.text[1])

    package.loaded["snacks"] = nil
    require("metafrastis.ui")._reset_for_tests()
  end)
end)

describe("commands", function()
  before_each(function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
    vim.cmd("runtime plugin/metafrastis.lua")
  end)

  it("replaces selected lines when bang is used", function()
    package.loaded["snacks"] = false
    local test_ui = require("metafrastis.ui")
    test_ui._reset_for_tests()
    local original_progress = test_ui.progress
    local original_notify = test_ui.notify
    local done = false
    test_ui.progress = function()
      return function()
        done = true
      end
    end
    test_ui.notify = function() end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })
    vim.cmd("1,1MetafrastisTranslate! en es")

    vim.wait(1000, function()
      return done
    end)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Hello world [echo]->es", lines[1])

    test_ui.progress = original_progress
    test_ui.notify = original_notify
  end)

  it("uses configured target_lang without prompting when args are omitted", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo", target_lang = "fr", source_lang = "en" })
    vim.cmd("runtime plugin/metafrastis.lua")

    package.loaded["snacks"] = false
    local test_ui = require("metafrastis.ui")
    test_ui._reset_for_tests()
    local original_prompt = test_ui.prompt_target
    local original_progress = test_ui.progress
    local original_notify = test_ui.notify
    local prompted = false
    local done = false
    test_ui.prompt_target = function()
      prompted = true
    end
    test_ui.progress = function()
      return function()
        done = true
      end
    end
    test_ui.notify = function() end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })

    vim.cmd("1,1MetafrastisTranslate!")

    vim.wait(1000, function()
      return done
    end)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Hello world [echo]->fr", lines[1])
    assert.is_false(prompted)

    test_ui.prompt_target = original_prompt
    test_ui.progress = original_progress
    test_ui.notify = original_notify
  end)

  it("prefers explicit args over configured languages", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo", target_lang = "fr", source_lang = "en" })
    vim.cmd("runtime plugin/metafrastis.lua")

    package.loaded["snacks"] = false
    local test_ui = require("metafrastis.ui")
    test_ui._reset_for_tests()
    local original_progress = test_ui.progress
    local original_notify = test_ui.notify
    local done = false
    test_ui.progress = function()
      return function()
        done = true
      end
    end
    test_ui.notify = function() end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })

    vim.cmd("1,1MetafrastisTranslate! es")

    vim.wait(1000, function()
      return done
    end)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Hello world [echo]->es", lines[1])

    test_ui.progress = original_progress
    test_ui.notify = original_notify
  end)
end)

describe("async translation", function()
  before_each(function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
  end)

  it("translates via async path", function()
    local result
    local done = false
    metafrastis.translate_async("Hello", { target_lang = "fr" }, {
      on_success = function(out)
        result = out
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })
    vim.wait(1000, function()
      return done
    end)
    assert.equals("Hello [echo]->fr", result)
  end)

  it("caches in async path", function()
    local calls = 0
    registry.register("count_async", {
      translate = function(_, payload)
        calls = calls + 1
        return payload.text .. "#" .. calls
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metafrastis.config.provider = "count_async"
    local results = {}
    local done = 0
    for i = 1, 2 do
      metafrastis.translate_async("ping", { target_lang = "en" }, {
        on_success = function(out)
          results[i] = out
          done = done + 1
        end,
      })
      vim.wait(1000, function()
        return done >= i
      end)
    end
    assert.equals("ping#1", results[1])
    assert.equals("ping#1", results[2])
    assert.equals(1, calls)
  end)
end)

describe("visual selection translation", function()
  before_each(function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
  end)

  ---Helper: set visual marks on a buffer.
  ---@param bufnr integer
  ---@param start_row integer 1-indexed
  ---@param start_col integer 0-indexed
  ---@param end_row integer 1-indexed
  ---@param end_col integer 0-indexed
  local function set_visual_marks(bufnr, start_row, start_col, end_row, end_col)
    vim.api.nvim_buf_set_mark(bufnr, "<", start_row, start_col, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", end_row, end_col, {})
  end

  it("translates linewise visual selection and replaces", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world", "second line" })
    set_visual_marks(bufnr, 1, 0, 1, 10)

    local result = metafrastis.translate_selection(bufnr, "V", { target_lang = "es", replace = true })

    assert.equals("Hello world [echo]->es", result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Hello world [echo]->es", lines[1])
    assert.equals("second line", lines[2])
  end)

  it("translates linewise selection spanning multiple lines", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "first", "second", "third" })
    set_visual_marks(bufnr, 1, 0, 2, 5)

    local result = metafrastis.translate_selection(bufnr, "V", { target_lang = "ja", replace = true })

    assert.is_string(result)
    assert.truthy(result:len() > 0)
    -- Echo provider appends "[echo]->ja" to the joined text.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local found = false
    for _, line in ipairs(lines) do
      if line:find("%[echo%]") then
        found = true
        break
      end
    end
    assert.is_true(found, "expected [echo] in buffer lines: " .. vim.inspect(lines))
    assert.equals("third", lines[#lines])
  end)

  it("translates charwise visual selection and replaces", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })
    -- Select "world" (col 6..10 inclusive in mark, which becomes 6..11 exclusive)
    set_visual_marks(bufnr, 1, 6, 1, 10)

    local result = metafrastis.translate_selection(bufnr, "v", { target_lang = "fr", replace = true })

    assert.equals("world [echo]->fr", result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Hello world [echo]->fr", lines[1])
  end)

  it("returns empty string for empty selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    set_visual_marks(bufnr, 1, 0, 1, 0)

    local result = metafrastis.translate_selection(bufnr, "V", { target_lang = "de", replace = true })

    assert.equals("", result)
  end)

  it("shows window instead of replacing when replace is false", function()
    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })
    set_visual_marks(bufnr, 1, 0, 1, 10)

    metafrastis.translate_selection(bufnr, "V", {
      target_lang = "es",
      replace = false,
      show_window = true,
    })

    assert.truthy(win_opts)
    assert.equals("Hello world [echo]->es", win_opts.text[1])

    package.loaded["snacks"] = nil
    require("metafrastis.ui")._reset_for_tests()
  end)

  it("async translates and replaces visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Async test" })
    set_visual_marks(bufnr, 1, 0, 1, 9)

    local done = false
    local result
    metafrastis.translate_selection_async(bufnr, "V", { target_lang = "ko", replace = true }, {
      on_success = function(out)
        result = out
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    assert.is_true(done)
    assert.equals("Async test [echo]->ko", result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Async test [echo]->ko", lines[1])
  end)

  it("async returns empty for empty selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    set_visual_marks(bufnr, 1, 0, 1, 0)

    local done = false
    local result
    metafrastis.translate_selection_async(bufnr, "V", { target_lang = "zh" }, {
      on_success = function(out)
        result = out
        done = true
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    assert.is_true(done)
    assert.equals("", result)
  end)

  it("translates charwise selection spanning multiple lines", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world", "foo bar" })
    -- Select from "world" on line 1 to "foo" on line 2 (charwise)
    set_visual_marks(bufnr, 1, 6, 2, 2)

    local result = metafrastis.translate_selection(bufnr, "v", { target_lang = "de", replace = true })

    assert.is_string(result)
    assert.truthy(result:len() > 0)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- The prefix "Hello " and suffix " bar" should be preserved.
    local all = table.concat(lines, "\n")
    assert.truthy(all:find("Hello"), "expected 'Hello' prefix preserved: " .. vim.inspect(lines))
    assert.truthy(all:find("bar"), "expected 'bar' suffix preserved: " .. vim.inspect(lines))
  end)

  it("strips and reapplies line comments on linewise visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "// diagnose common mistake",
      "// not the worst",
      "code()",
    })
    set_visual_marks(bufnr, 1, 0, 2, 14)

    local result = metafrastis.translate_selection(bufnr, "V", { target_lang = "es", replace = true })

    -- Translated payload must not contain the comment leader.
    assert.is_nil(result:find("//"), "translated text should not contain comment leader: " .. result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.truthy(lines[1]:match("^// "), "first line should keep // prefix: " .. lines[1])
    assert.truthy(lines[2]:match("^// "), "second line should keep // prefix: " .. lines[2])
    assert.equals("code()", lines[3])
  end)

  it("preserves indentation when reapplying comment leader on visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "    // indented comment" })
    set_visual_marks(bufnr, 1, 0, 1, 23)

    metafrastis.translate_selection(bufnr, "V", { target_lang = "ja", replace = true })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.truthy(lines[1]:match("^    // "), "indent and // prefix should be restored: " .. lines[1])
  end)

  it("strips and reapplies block comments on linewise visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "/* %s */"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/* block text */" })
    set_visual_marks(bufnr, 1, 0, 1, 16)

    local result = metafrastis.translate_selection(bufnr, "V", { target_lang = "fr", replace = true })

    assert.is_nil(result:find("/%*"), "translated text should not contain block comment open: " .. result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.truthy(lines[1]:match("^/%* .* %*/$"), "block comment should be reapplied: " .. lines[1])
  end)

  it("leaves selection alone when commentstring is unset", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = ""
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "// not actually a comment" })
    set_visual_marks(bufnr, 1, 0, 1, 25)

    local result = metafrastis.translate_selection(bufnr, "V", { target_lang = "de", replace = true })

    assert.equals("// not actually a comment [echo]->de", result)
  end)

  it("strips comment leader in show_window output", function()
    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "// comment payload" })
    set_visual_marks(bufnr, 1, 0, 1, 18)

    metafrastis.translate_selection(bufnr, "V", {
      target_lang = "es",
      replace = false,
      show_window = true,
    })

    assert.truthy(win_opts)
    assert.is_nil(win_opts.text[1]:find("//"), "show_window output should not contain // : " .. win_opts.text[1])

    package.loaded["snacks"] = nil
    require("metafrastis.ui")._reset_for_tests()
  end)

  it("async strips and reapplies line comments on linewise visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "// async commented line" })
    set_visual_marks(bufnr, 1, 0, 1, 23)

    local done = false
    local result
    metafrastis.translate_selection_async(bufnr, "V", { target_lang = "ko", replace = true }, {
      on_success = function(out)
        result = out
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    assert.is_true(done)
    assert.is_nil(result:find("//"), "async translated text should not contain comment leader: " .. result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.truthy(lines[1]:match("^// "), "async result should keep // prefix: " .. lines[1])
  end)
end)

describe("Snacks.win result window", function()
  local original_mode = vim.fn.mode
  local original_feedkeys = vim.api.nvim_feedkeys

  after_each(function()
    vim.fn.mode = original_mode
    vim.api.nvim_feedkeys = original_feedkeys
    package.loaded["snacks"] = nil
    require("metafrastis.ui")._reset_for_tests()
  end)

  it("uses snacks.win when show_window is enabled", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })

    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })

    local echoed = false
    local original_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function()
      echoed = true
    end

    local done = false
    metafrastis.translate_range_async(bufnr, 0, 1, {
      target_lang = "es",
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    vim.api.nvim_echo = original_echo

    assert.is_true(done)
    assert.truthy(win_opts)
    assert.equals("Hello world [echo]->es", win_opts.text[1])
    assert.equals("cursor", win_opts.relative)
    assert.equals(1, win_opts.row)
    assert.equals(0, win_opts.col)
    assert.equals("rounded", win_opts.border)
    assert.equals("center", win_opts.title_pos)
    assert.equals("q/Esc: close · y: yank · move cursor to dismiss", win_opts.footer)
    assert.equals("center", win_opts.footer_pos)
    assert.is_true(win_opts.wo.wrap)
    assert.is_true(win_opts.wo.linebreak)
    assert.equals("markdown", win_opts.bo.filetype)
    assert.is_false(echoed)
  end)

  it("applies ui.win defaults from setup", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo", ui = { win = { width = 55, border = "single" } } })

    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello" })

    local done = false
    metafrastis.translate_range_async(bufnr, 0, 1, {
      target_lang = "es",
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    assert.truthy(win_opts)
    assert.equals(55, win_opts.width)
    assert.equals("single", win_opts.border)
  end)

  it("allows call-specific win opts to override setup defaults", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo", ui = { win = { width = 80, border = "single" } } })

    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello" })

    local done = false
    metafrastis.translate_range_async(bufnr, 0, 1, {
      target_lang = "es",
      show_window = true,
      replace = false,
      win = { width = 30, border = "double" },
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    assert.truthy(win_opts)
    assert.equals(30, win_opts.width)
    assert.equals("double", win_opts.border)
  end)

  it("applies padding from setup defaults", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({
      provider = "echo",
      ui = {
        win = {
          padding = { top = 1, bottom = 1, left = 2, right = 2 },
        },
      },
    })

    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello" })

    local done = false
    metafrastis.translate_range_async(bufnr, 0, 1, {
      target_lang = "es",
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)

    assert.truthy(win_opts)
    assert.equals("    ", win_opts.text[1])
    assert.equals("  Hello [echo]->es  ", win_opts.text[2])
    assert.equals("    ", win_opts.text[3])

    package.loaded["snacks"] = nil
    require("metafrastis.ui")._reset_for_tests()
  end)

  local function install_mock_snacks_win(win_id)
    local state = { closed = 0, win_opts = nil }
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        state.win_opts = opts
        return {
          win = win_id,
          show = function() end,
          close = function()
            state.closed = state.closed + 1
          end,
        }
      end,
    }
    require("metafrastis.ui")._reset_for_tests()
    return state
  end

  local function show_echo_window(target_lang)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Hello world" })

    local done = false
    metafrastis.translate_range_async(bufnr, 0, 1, {
      target_lang = target_lang,
      show_window = true,
      replace = false,
    }, {
      on_success = function()
        done = true
      end,
      on_error = function(err)
        done = true
        error(err)
      end,
    })

    vim.wait(1000, function()
      return done
    end)
    assert.is_true(done)
  end

  it("closes snacks.win on CursorMoved", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
    local state = install_mock_snacks_win(1000)

    show_echo_window("es")
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })

    assert.equals(1, state.closed)
  end)

  it("leaves visual mode when CursorMoved closes snacks.win", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
    local state = install_mock_snacks_win(1001)
    local feedkeys_calls = {}
    vim.fn.mode = function()
      return "v"
    end
    vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
      table.insert(feedkeys_calls, { keys = keys, mode = mode, escape_ks = escape_ks })
    end

    show_echo_window("es")
    feedkeys_calls = {}
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })

    local expected_esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    assert.equals(1, state.closed)
    assert.equals(1, #feedkeys_calls)
    assert.equals(expected_esc, feedkeys_calls[1].keys)
    assert.equals("nx", feedkeys_calls[1].mode)
    assert.is_false(feedkeys_calls[1].escape_ks)
  end)

  it("does not leave insert mode when CursorMovedI closes snacks.win", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
    local state = install_mock_snacks_win(1002)
    local feedkeys_calls = {}
    vim.fn.mode = function()
      return "i"
    end
    vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
      table.insert(feedkeys_calls, { keys = keys, mode = mode, escape_ks = escape_ks })
    end

    show_echo_window("es")
    feedkeys_calls = {}
    vim.api.nvim_exec_autocmds("CursorMovedI", { modeline = false })

    assert.equals(1, state.closed)
    assert.equals(0, #feedkeys_calls)
  end)

  it("does not feed escape for stale CursorMoved autocmds after a newer window already closed", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })
    local state = install_mock_snacks_win(1003)
    local feedkeys_calls = {}
    vim.fn.mode = function()
      return "v"
    end
    vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
      table.insert(feedkeys_calls, { keys = keys, mode = mode, escape_ks = escape_ks })
    end

    show_echo_window("es")
    show_echo_window("de")
    feedkeys_calls = {}
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })

    assert.equals(2, state.closed)
    assert.equals(1, #feedkeys_calls)
  end)
end)

describe("ui helper", function()
  local original_notify

  before_each(function()
    original_notify = vim.notify
  end)

  after_each(function()
    vim.notify = original_notify
    package.loaded["snacks"] = nil
    package.loaded["metafrastis.ui"] = nil
  end)

  it("falls back to vim.notify when snacks missing", function()
    local messages = {}
    vim.notify = function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end
    package.loaded["snacks"] = false
    local ui = require("metafrastis.ui")
    ui.notify("hello", "info", { title = "t" })
    assert.equals("hello", messages[1].msg)
  end)

  it("uses snacks when available", function()
    local notified = {}
    package.loaded["snacks"] = {
      notify = {
        info = function(msg, opts)
          table.insert(notified, { msg = msg, opts = opts, level = "info" })
        end,
        warn = function(msg, opts)
          table.insert(notified, { msg = msg, opts = opts, level = "warn" })
        end,
        notify = function(msg, opts)
          table.insert(notified, { msg = msg, opts = opts, level = "notify" })
        end,
      },
    }
    local ui = require("metafrastis.ui")
    ui.notify("hi", "warn", { title = "x" })
    assert.equals("hi", notified[1].msg)
    assert.equals("warn", notified[1].level)
  end)

  it("prompts with snacks input when available", function()
    local received_default
    local confirmed
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
      },
      input = function(opts, cb)
        received_default = opts.default
        cb("ja")
      end,
    }
    local ui = require("metafrastis.ui")
    ui.prompt_target("es", function(value)
      confirmed = value
    end)
    assert.equals("es", received_default)
    assert.equals("ja", confirmed)
  end)

  it("renders translation in snacks.win when available", function()
    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    local ui = require("metafrastis.ui")
    ui._reset_for_tests()
    ui.show_window("ciao", { provider = "echo", cached = true }, { target_lang = "es" })
    assert.truthy(win_opts)
    assert.equals("es · echo · cache", win_opts.title)
    assert.equals("ciao", win_opts.text[1])
    assert.equals("cursor", win_opts.relative)
    assert.equals(1, win_opts.row)
    assert.equals(0, win_opts.col)
    assert.equals("rounded", win_opts.border)
    assert.equals("center", win_opts.title_pos)
    assert.equals("q/Esc: close · y: yank · move cursor to dismiss", win_opts.footer)
    assert.equals("center", win_opts.footer_pos)
    assert.is_true(win_opts.wo.wrap)
    assert.is_true(win_opts.wo.linebreak)
    assert.equals("markdown", win_opts.bo.filetype)
  end)

  it("falls back to vim.echo when snacks missing", function()
    package.loaded["snacks"] = nil
    local ui = require("metafrastis.ui")
    ui._reset_for_tests()
    local original_echo = vim.api.nvim_echo
    local echoed
    vim.api.nvim_echo = function(chunks)
      echoed = chunks
    end
    ui.show_window("hello", nil, { target_lang = "fr" })
    vim.api.nvim_echo = original_echo
    assert.truthy(echoed)
    assert.equals("hello", echoed[1][1])
  end)

  it("allows overriding cursor positioning defaults", function()
    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    local ui = require("metafrastis.ui")
    ui._reset_for_tests()
    ui.show_window(
      "hola",
      nil,
      { win = { relative = "editor", row = 5, col = 10, border = "double", wo = { wrap = false } } }
    )
    assert.truthy(win_opts)
    assert.equals("editor", win_opts.relative)
    assert.equals(5, win_opts.row)
    assert.equals(10, win_opts.col)
    assert.equals("double", win_opts.border)
    assert.is_false(win_opts.wo.wrap)
  end)

  it("applies padding from config when showing window", function()
    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    local ui = require("metafrastis.ui")
    ui._reset_for_tests()

    metafrastis._reset_for_tests()
    metafrastis.setup({
      provider = "echo",
      ui = {
        win = {
          padding = { top = 1, bottom = 1, left = 2, right = 2 },
        },
      },
    })

    ui.show_window("ciao", { provider = "echo" }, { win = {} })

    assert.truthy(win_opts)
    assert.equals("    ", win_opts.text[1])
    assert.equals("  ciao  ", win_opts.text[2])
    assert.equals("    ", win_opts.text[3])

    package.loaded["snacks"] = nil
    ui._reset_for_tests()
  end)

  it("sizes window height for wrapped long lines", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })

    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    local ui = require("metafrastis.ui")
    ui._reset_for_tests()
    ui.set_defaults({})

    local original_lines = vim.o.lines
    vim.o.lines = 60
    local long = string.rep("a", 400)
    ui.show_window(long, nil, { win = { width = 40 } })
    vim.o.lines = original_lines

    assert.truthy(win_opts)
    assert.equals(40, win_opts.width)
    assert.is_true(
      win_opts.height >= 10,
      "expected height >= 10 for a 400-char line wrapped at 40, got " .. tostring(win_opts.height)
    )

    package.loaded["snacks"] = nil
    ui._reset_for_tests()
  end)

  it("does not multiply height when wrap is disabled", function()
    metafrastis._reset_for_tests()
    metafrastis.setup({ provider = "echo" })

    local win_opts
    package.loaded["snacks"] = {
      notify = {
        info = function() end,
        warn = function() end,
        notify = function() end,
      },
      win = function(opts)
        win_opts = opts
        return { show = function() end }
      end,
    }
    local ui = require("metafrastis.ui")
    ui._reset_for_tests()
    ui.set_defaults({})

    local long = string.rep("a", 400)
    ui.show_window(long, nil, { win = { width = 40, wo = { wrap = false } } })

    assert.truthy(win_opts)
    assert.equals(1, win_opts.height)

    package.loaded["snacks"] = nil
    ui._reset_for_tests()
  end)
end)
