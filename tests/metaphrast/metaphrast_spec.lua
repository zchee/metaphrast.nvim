local hover = require("metaphrast.ui.hover")
local metaphrast = require("metaphrast")
local registry = require("metaphrast.providers")

describe("setup", function()
  before_each(function()
    metaphrast._reset_for_tests()
  end)

  it("falls back to echo when provider credentials are missing", function()
    metaphrast.setup({
      provider = "openai",
      providers = {
        openai = { api_key = "" },
      },
    })
    assert.equals("echo", metaphrast.config.provider)
  end)

  it("keeps chosen provider when valid", function()
    metaphrast.setup({ provider = "echo" })
    assert.equals("echo", metaphrast.config.provider)
  end)
end)

describe("translation core", function()
  before_each(function()
    metaphrast._reset_for_tests()
  end)

  it("translates via echo provider", function()
    metaphrast.setup({ provider = "echo" })
    local out = metaphrast.translate("Hello", { target_lang = "es" })
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
    metaphrast.config.provider = "cr"
    metaphrast.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "stub" })

    local out = metaphrast.translate_range(bufnr, 0, 1, { target_lang = "en" })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    assert.equals("hello world", out)
    assert.equals(1, #lines)
    assert.equals("hello world", lines[1])
  end)

  it("retries OpenRouter fallback model for line-range upstream rate limits", function()
    local requested_models = {}
    metaphrast.setup({
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
    metaphrast.http = function(_, _, opts)
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

    local out = metaphrast.translate_range(bufnr, 0, 2, { target_lang = "ja" })

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
    metaphrast.config.provider = "count"
    local first = metaphrast.translate("hi", { target_lang = "fr" })
    local second = metaphrast.translate("hi", { target_lang = "fr" })
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
    metaphrast.config.provider = "expensive"
    metaphrast.config.cache.max_estimated_cost = 1
    assert.has_error(function()
      metaphrast.translate("hi", { target_lang = "fr" })
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
    metaphrast.config.provider = "needs_secret"
    metaphrast.config.providers.needs_secret = { secret = "ok" }

    local out = metaphrast.translate("ping", { target_lang = "en" })
    assert.equals("ping-ok", out)
  end)

  it("raises when the provider lacks credentials at call time", function()
    metaphrast.setup({ provider = "echo" })
    metaphrast.config.provider = "deepl"
    metaphrast.config.providers.deepl.api_key = ""

    assert.has_error(function()
      metaphrast.translate("Hello", { target_lang = "ja" })
    end)
    -- The failure is raised to the caller; the global provider is never rewritten.
    assert.equals("deepl", metaphrast.config.provider)
  end)
end)

describe("comment handling", function()
  before_each(function()
    metaphrast._reset_for_tests()
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
    metaphrast.config.provider = "capture"
    metaphrast.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "// anthropicLLM implements the adk [model.LLM] interface using the Anthropic SDK.",
    })

    metaphrast.translate_range(bufnr, 0, 1, { target_lang = "es" })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("// anthropicLLM implements the adk [model.LLM] interface using the Anthropic SDK. <t>", lines[1])
    assert.equals("anthropicLLM implements the adk [model.LLM] interface using the Anthropic SDK.", last_text)
  end)

  it("joins a soft-wrapped comment paragraph into one coherent translation unit", function()
    local last_text
    registry.register("capture_multiline", {
      translate = function(_, payload)
        last_text = payload.text
        return payload.text
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metaphrast.config.provider = "capture_multiline"
    metaphrast.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      '//   - inline: The "inline" option specifies that',
      "//     the JSON representable content of this field type is to be promoted",
      "//     as if they were specified in the parent struct.",
      "//     It is the JSON equivalent of Go struct embedding.",
    })

    metaphrast.translate_range(bufnr, 0, 4, { target_lang = "ja" })

    -- The provider must receive the whole paragraph as ONE line: the soft-wrap
    -- newlines that previously fragmented translation are collapsed to spaces.
    assert.is_nil(last_text:find("\n"), "paragraph must not contain intra-paragraph newline: " .. last_text)
    assert.equals(
      '- inline: The "inline" option specifies that the JSON representable content of this field '
        .. "type is to be promoted as if they were specified in the parent struct. It is the JSON "
        .. "equivalent of Go struct embedding.",
      last_text
    )
  end)

  it("lays a coherent CJK translation back into wrapped comment lines", function()
    -- End-to-end guard for the reported regression: a soft-wrapped // block is
    -- translated as one unit and reflowed into // lines within the source width.
    local ja = "inlineオプションは、このフィールド型のJSON表現可能な内容を、"
      .. "親構造体で指定されたかのように昇格させることを指定します。"
    registry.register("canned_ja", {
      translate = function()
        return ja
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metaphrast.config.provider = "canned_ja"
    metaphrast.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    local source = {
      '//   - inline: The "inline" option specifies that',
      "//     the JSON representable content of this field type is to be promoted",
      "//     as if they were specified in the parent struct.",
    }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, source)

    metaphrast.translate_range(bufnr, 0, 3, { target_lang = "ja" })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- Width budget = widest source content line (leader stripped).
    local budget = 0
    for _, l in ipairs(source) do
      budget = math.max(budget, vim.fn.strdisplaywidth((l:gsub("^//%s*", ""))))
    end
    local recovered = {}
    for _, line in ipairs(lines) do
      assert.truthy(line:match("^// "), "every output line keeps the // leader: " .. line)
      assert.is_true(
        vim.fn.strdisplaywidth(line) <= budget + vim.fn.strdisplaywidth("// "),
        "line stays within the comment width budget: " .. line
      )
      recovered[#recovered + 1] = (line:gsub("^//%s*", ""))
    end
    -- Reassembling the stripped output recovers the full coherent translation.
    assert.equals(ja, table.concat(recovered, ""))
  end)

  it("keeps distinct paragraphs separated when a blank comment line divides them", function()
    local last_text
    registry.register("capture_paras", {
      translate = function(_, payload)
        last_text = payload.text
        return payload.text
      end,
      estimate_cost = function()
        return 0
      end,
    })
    metaphrast.config.provider = "capture_paras"
    metaphrast.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "// First paragraph that wraps",
      "// across two lines.",
      "//",
      "// Second paragraph here.",
    })

    metaphrast.translate_range(bufnr, 0, 4, { target_lang = "ja" })

    -- Two paragraphs => exactly one separating newline; each paragraph joined.
    assert.equals("First paragraph that wraps across two lines.\nSecond paragraph here.", last_text)
    -- The blank comment line is preserved in the replaced buffer.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local blank_kept = false
    for _, line in ipairs(lines) do
      if line:match("^//%s*$") then
        blank_kept = true
      end
    end
    assert.is_true(blank_kept, "blank comment line should be preserved: " .. vim.inspect(lines))
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
    metaphrast.config.provider = "capture_block"
    metaphrast.config.replace = true

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "/* %s */"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "    /* Translate only the inner text */",
    })

    metaphrast.translate_range(bufnr, 0, 1, { target_lang = "en" })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("    /* Translate only the inner text <t> */", lines[1])
    assert.equals("Translate only the inner text", last_text)
  end)
end)

describe("commands", function()
  local test_ui = require("metaphrast.ui")
  local original_prompt = test_ui.prompt_target

  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
    vim.cmd("runtime plugin/metaphrast.lua")
  end)

  after_each(function()
    test_ui.prompt_target = original_prompt
  end)

  local function open_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function wait_for_replacement(bufnr, original)
    return vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= original
    end)
  end

  it("replaces selected lines when bang is used", function()
    local bufnr = open_buffer({ "Hello world" })

    vim.cmd("1,1MetaphrastTranslate! en es")

    assert.is_true(wait_for_replacement(bufnr, "Hello world"))
    assert.equals("Hello world [echo]->es", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)

  it("uses configured target_lang without prompting when args are omitted", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", target_lang = "fr", source_lang = "en" })
    local prompted = false
    test_ui.prompt_target = function()
      prompted = true
    end
    local bufnr = open_buffer({ "Hello world" })

    vim.cmd("1,1MetaphrastTranslate!")

    assert.is_true(wait_for_replacement(bufnr, "Hello world"))
    assert.equals("Hello world [echo]->fr", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.is_false(prompted)
  end)

  it("prefers explicit args over configured languages", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", target_lang = "fr", source_lang = "en" })
    local bufnr = open_buffer({ "Hello world" })

    vim.cmd("1,1MetaphrastTranslate! es")

    assert.is_true(wait_for_replacement(bufnr, "Hello world"))
    assert.equals("Hello world [echo]->es", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)

  it("prompts for the target language when none is configured", function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo", target_lang = "" })
    local prompted_default
    test_ui.prompt_target = function(default, on_confirm)
      prompted_default = default
      on_confirm("de")
    end
    local bufnr = open_buffer({ "Hello world" })

    vim.cmd("1,1MetaphrastTranslate!")

    assert.is_true(wait_for_replacement(bufnr, "Hello world"))
    assert.equals("", prompted_default)
    assert.equals("Hello world [echo]->de", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
  end)

  it("opens the hover without a bang and leaves the buffer untouched", function()
    local bufnr = open_buffer({ "Hello world" })

    vim.cmd("1,1MetaphrastTranslate es")

    assert.is_true(vim.wait(1000, function()
      return hover.is_open_for(bufnr)
    end))
    assert.equals("Hello world", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
    assert.same({ "Hello world [echo]->es" }, hover.debug().result.display_lines)
  end)
end)

describe("async translation", function()
  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
  end)

  it("translates via async path", function()
    local result
    local done = false
    metaphrast.translate_async("Hello", { target_lang = "fr" }, {
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
    metaphrast.config.provider = "count_async"
    local results = {}
    local done = 0
    for i = 1, 2 do
      metaphrast.translate_async("ping", { target_lang = "en" }, {
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
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
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

    local result = metaphrast.translate_selection(bufnr, "V", { target_lang = "es", replace = true })

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

    local result = metaphrast.translate_selection(bufnr, "V", { target_lang = "ja", replace = true })

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

    local result = metaphrast.translate_selection(bufnr, "v", { target_lang = "fr", replace = true })

    assert.equals("world [echo]->fr", result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Hello world [echo]->fr", lines[1])
  end)

  it("returns empty string for empty selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    set_visual_marks(bufnr, 1, 0, 1, 0)

    local result = metaphrast.translate_selection(bufnr, "V", { target_lang = "de", replace = true })

    assert.equals("", result)
  end)

  it("async translates and replaces visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Async test" })
    set_visual_marks(bufnr, 1, 0, 1, 9)

    local done = false
    local result
    metaphrast.translate_selection_async(bufnr, "V", { target_lang = "ko", replace = true }, {
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
    metaphrast.translate_selection_async(bufnr, "V", { target_lang = "zh" }, {
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

    local result = metaphrast.translate_selection(bufnr, "v", { target_lang = "de", replace = true })

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

    local result = metaphrast.translate_selection(bufnr, "V", { target_lang = "es", replace = true })

    -- Translated payload must not contain the comment leader.
    assert.is_nil(result:find("//"), "translated text should not contain comment leader: " .. result)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- The non-selected code line is preserved as the final buffer line.
    assert.equals("code()", lines[#lines])
    -- Every reapplied comment line keeps the // leader; the soft-wrapped
    -- comment is translated as one coherent paragraph (it may re-wrap across a
    -- different number of lines than the source).
    for i = 1, #lines - 1 do
      assert.truthy(lines[i]:match("^// "), "comment line should keep // prefix: " .. lines[i])
    end
    assert.is_true(#lines >= 2, "selection should produce at least one comment line: " .. vim.inspect(lines))
  end)

  it("preserves indentation when reapplying comment leader on visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "    // indented comment" })
    set_visual_marks(bufnr, 1, 0, 1, 23)

    metaphrast.translate_selection(bufnr, "V", { target_lang = "ja", replace = true })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.truthy(lines[1]:match("^    // "), "indent and // prefix should be restored: " .. lines[1])
  end)

  it("strips and reapplies block comments on linewise visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "/* %s */"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/* block text */" })
    set_visual_marks(bufnr, 1, 0, 1, 16)

    local result = metaphrast.translate_selection(bufnr, "V", { target_lang = "fr", replace = true })

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

    local result = metaphrast.translate_selection(bufnr, "V", { target_lang = "de", replace = true })

    assert.equals("// not actually a comment [echo]->de", result)
  end)

  it("async strips and reapplies line comments on linewise visual selection", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = "// %s"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "// async commented line" })
    set_visual_marks(bufnr, 1, 0, 1, 23)

    local done = false
    local result
    metaphrast.translate_selection_async(bufnr, "V", { target_lang = "ko", replace = true }, {
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

---Open a scratch buffer holding `buf_lines` with the visual marks a
---selection reads.
---@param buf_lines string[]
---@param commentstring string
---@param start_row integer 1-indexed
---@param start_col integer 0-indexed
---@param end_row integer 1-indexed
---@param end_col integer 0-indexed, inclusive
---@return integer bufnr
local function block_buffer(buf_lines, commentstring, start_row, start_col, end_row, end_col)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].commentstring = commentstring
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines)
  vim.api.nvim_buf_set_mark(bufnr, "<", start_row, start_col, {})
  vim.api.nvim_buf_set_mark(bufnr, ">", end_row, end_col, {})
  return bufnr
end

---Register a provider that records the text it was handed.
---@param name string
---@param reply fun(text: string): string
---@return fun(): string|nil captured
local function capturing_provider(name, reply)
  local captured
  registry.register(name, {
    translate = function(_, payload)
      captured = payload.text
      return reply(payload.text)
    end,
    estimate_cost = function()
      return 0
    end,
  })
  metaphrast.config.provider = name
  return function()
    return captured
  end
end

describe("blockwise replace", function()
  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
  end)

  it("AC1: inserts the surplus wrapped line under the block instead of dropping it", function()
    local original = { "  // hello there  TAIL1", "  // second line  TAIL2", "x := 1" }
    local bufnr = block_buffer(original, "// %s", 1, 2, 2, 15)
    -- Headless Neovim never returns to the main loop between the seed and the
    -- write, so both would land in one undo block; this breaks the sequence the
    -- way returning for input does, making the undo assertion meaningful.
    vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels
    local seq_before = vim.fn.undotree().seq_cur

    local translated, applied = metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    assert.equals("hello there second line [echo]->es", translated)
    assert.is_true(applied)
    assert.same({
      "  // hello there  TAIL1",
      "  // second line  TAIL2",
      "  // [echo]->es",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    -- The whole replacement is one undo step, surplus line included.
    assert.equals(seq_before + 1, vim.fn.undotree().seq_cur)
    vim.cmd("silent undo")
    assert.same(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC3: pads the surplus line with spaces when code sits left of the block", function()
    local bufnr = block_buffer({ "foo(); // alpha beta", "bar(); // gamma delta", "baz();" }, "// %s", 1, 7, 2, 20)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- Seven spaces, not a second `bar();`: copying the left part verbatim would
    -- inject a duplicate statement into the user's code.
    assert.same({
      "foo(); // alpha beta",
      "bar(); // gamma delta",
      "       // [echo]->es",
      "baz();",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC4: clamps the columns when the block ends on a row shorter than its start", function()
    local captured = capturing_provider("block_short_row", function(text)
      return text .. " [cap]"
    end)
    local bufnr = block_buffer({ "    // alpha beta gamma", "ab" }, "// %s", 1, 4, 2, 22)

    local translated, applied, reason =
      metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- `'>` lands before `'<` on the short last row, so both slices are empty
    -- and the payload would be newlines only. That is nothing to translate, so
    -- the provider is never reached and the buffer is left alone.
    assert.equals("", translated)
    assert.is_nil(captured())
    assert.same({ "    // alpha beta gamma", "ab" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    -- A requested write-back that never happened is not a success: `nil` would
    -- read as "no write-back was requested" and let callers report one.
    assert.is_false(applied)
    assert.equals("metaphrast: nothing to translate in the selection", reason)
  end)

  it("AC4b: keeps the clamped-empty region empty on a multibyte row", function()
    local captured = capturing_provider("block_short_row_cjk", function(text)
      return text .. " [cap]"
    end)
    -- Column 4 falls inside the 3-byte `日`; the short last row gives `ec < sc`.
    local original = { "  日本語アイウ", "ab" }
    local bufnr = block_buffer(original, "// %s", 1, 4, 2, 22)

    local translated, applied, reason =
      metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- Snapping `cstart` back and `cend` forward around the same codepoint would
    -- reopen the emptied region and delete that character from the row.
    assert.equals("", translated)
    assert.is_nil(captured())
    assert.same(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.is_false(applied)
    assert.equals("metaphrast: nothing to translate in the selection", reason)
    local cstart, cend = metaphrast._block_columns(original[1], 4, 2)
    assert.equals(cstart, cend)
  end)

  it("AC5: keeps a multibyte block on codepoint boundaries", function()
    local captured = capturing_provider("block_multibyte", function(text)
      return text .. " [echo]->es"
    end)
    -- Column 16 falls inside the third byte of `の`.
    local bufnr = block_buffer({ "  // 日本語のテスト", "  // second line", "x := 1" }, "// %s", 1, 2, 2, 15)

    local translated = metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    assert.equals("日本語の second line", captured())
    assert.is_nil(
      translated:find("\239\191\189", 1, true),
      "translation carries a replacement character: " .. translated
    )
    assert.same({
      "  // 日本語のテスト",
      "  // second line",
      "  // [echo]->es",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC6: clamps a $-extended block to each row", function()
    local bufnr =
      block_buffer({ "  // hello there", "  // second line longer", "x := 1" }, "// %s", 1, 2, 2, 2147483646)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    assert.same({
      "  // hello there second",
      "  // line longer",
      "  // [echo]->es",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC7: blanks the block region on rows the rendered lines do not reach", function()
    capturing_provider("block_one_word", function()
      return "uno"
    end)
    local rows = { "  // aaa bbb  T1", "  // ccc ddd  T2", "  // eee fff  T3", "z()" }
    local bufnr = block_buffer(rows, "// %s", 1, 2, 3, 12)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- Frozen behavior: content moves up and rows 2-3 lose their leaders, keeping
    -- only the text right of the block. Asserted so the trade-off stays visible.
    assert.same({ "  // uno T1", "   T2", "   T3", "z()" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC8: never grows a leaderless block", function()
    local bufnr = block_buffer({ "  hello there", "  second line", "x := 1" }, "", 1, 2, 2, 12)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- Without comment structure the layout path is skipped and reflow_lines
    -- always returns exactly as many lines as it was given, so no line is added.
    assert.same(
      { "  hello there", "  second line [echo]->es", "x := 1" },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
  end)

  it("AC10: refuses a reply that would insert more than max_inserted_lines", function()
    capturing_provider("block_flood", function()
      return string.rep("x\n", 300)
    end)
    local original = { "  // hello there  TAIL1", "  // second line  TAIL2", "x := 1" }
    local bufnr = block_buffer(original, "// %s", 1, 2, 2, 15)

    local _, applied, reason = metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- The rendered line count is the provider's to choose; refusing keeps a
    -- runaway reply out of the buffer instead of silently truncating it.
    assert.is_false(applied)
    assert.truthy(reason:find("max_inserted_lines", 1, true), reason)
    assert.truthy(reason:find("200", 1, true), reason)
    assert.same(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC11: measures the surplus pad with the source buffer's tabstop", function()
    local bufnr =
      block_buffer({ "\tfoo(); // alpha beta", "\tbar(); // gamma delta", "\tbaz();" }, "// %s", 1, 8, 2, 21)
    vim.bo[bufnr].tabstop = 2
    -- `strdisplaywidth` reads 'tabstop' from the *current* buffer, and the
    -- hover float (or any other buffer) can be current when the write lands.
    local elsewhere = vim.api.nvim_create_buf(false, true)
    vim.bo[elsewhere].tabstop = 8
    vim.api.nvim_set_current_buf(elsewhere)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- Nine columns: `\tfoo(); ` under tabstop 2, not the 15 tabstop 8 would give.
    assert.same({
      "\tfoo(); // alpha beta",
      "\tbar(); // gamma delta",
      "         // [echo]->es",
      "\tbaz();",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC12: keeps the leader on a blank surplus line instead of emptying it", function()
    capturing_provider("block_blank_surplus", function()
      return "alpha beta gamma delta epsilon\n\nzeta"
    end)
    local bufnr = block_buffer({ "  // hello there  TAIL1", "  // second line  TAIL2", "x := 1" }, "// %s", 1, 2, 2, 15)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- The paragraph break the provider sent is a blank *comment* line, not a
    -- hole in the comment block: emitting it bare uncommented the file and cost
    -- a line, since the reply was flattened into one wrapped block first.
    assert.same({
      "  // alpha beta  TAIL1",
      "  // gamma delta  TAIL2",
      "  // epsilon",
      "  // ",
      "  // zeta",
      "x := 1",
    }, lines)
    for i, line in ipairs(lines) do
      assert.is_falsy(line:match("^%s+$"), string.format("line %d is whitespace only: %q", i, line))
    end
  end)

  it("AC14: resolves the block columns at every boundary", function()
    -- `abc日本語`: `日` is bytes 4-6, `本` 7-9, `語` 10-12.
    local line = "abc日本語"
    local cases = {
      { "sc inside a codepoint snaps back", line, 4, 12, 3, 12 },
      { "sc on the codepoint's last byte snaps back", line, 5, 12, 3, 12 },
      { "ec inside a codepoint snaps forward", line, 0, 4, 0, 6 },
      { "ec on the codepoint's last byte snaps forward", line, 0, 5, 0, 6 },
      { "cstart clamped to the row end stays there", "ab", 6, 20, 2, 2 },
      { "cend of zero is left alone", "日本語", 0, 0, 0, 0 },
      { "an empty row yields an empty region", "", 4, 9, 0, 0 },
      { "an ASCII block is untouched", "  // hello", 2, 10, 2, 10 },
    }
    for _, case in ipairs(cases) do
      local label, subject, sc, ec, want_start, want_end = unpack(case)
      local cstart, cend = metaphrast._block_columns(subject, sc, ec)
      assert.equals(want_start, cstart, label .. " (cstart)")
      assert.equals(want_end, cend, label .. " (cend)")
    end
  end)

  it("AC15: snaps the start column back on a row that is not the block's first", function()
    local captured = capturing_provider("block_mid_codepoint", function(text)
      return text .. " [cap]"
    end)
    -- `sc = 2` is a codepoint boundary on row 1 but the second byte of `日` on
    -- row 2, so only the per-row snap keeps that slice whole.
    local bufnr = block_buffer({ "  hello there", " 日本語のテスト" }, "", 1, 2, 2, 21)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    assert.equals("hello there\n日本語のテスト", captured())
    assert.same({ "  hello there", " 日本語のテスト [cap]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC16: keeps a tab indent verbatim on the surplus line", function()
    local bufnr = block_buffer({ "\t// hello there  TAIL1", "\t// second line  TAIL2", "x := 1" }, "// %s", 1, 1, 2, 14)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- The text left of the block is whitespace, so it is copied as-is and the
    -- inserted line keeps the file's indent style rather than expanding it.
    assert.same({
      "\t// hello there  TAIL1",
      "\t// second line  TAIL2",
      "\t// [echo]->es",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC17: leaves the block's marks raw so one row's codepoints cannot widen another", function()
    local captured = capturing_provider("block_mark_widening", function(text)
      return text .. " [cap]"
    end)
    -- `'>` holds the first byte of `本` on the CJK end row. Snapping it forward
    -- there — as charwise does — would move the block's shared end column two
    -- bytes right, widening the ASCII row above onto text the user never
    -- selected. `block_columns` re-snaps per row, so the CJK row is whole
    -- either way and the entire difference lands on the other row.
    local bufnr = block_buffer({ "  // abcdefgh", "  // 日本語" }, "// %s", 1, 2, 2, 8)

    metaphrast.translate_selection(bufnr, "\22", { target_lang = "es" })

    assert.equals("abcd 日本", captured())
  end)

  it("AC-B2: keeps the leader on a block line the provider split with a newline", function()
    capturing_provider("block_newline_leader", function()
      return "uno\ndos"
    end)
    local bufnr = block_buffer({ "  // hello there  T1", "  // second line  T2", "x := 1" }, "// %s", 1, 2, 2, 15)

    metaphrast.translate_selection(bufnr, "\22", { replace = true, target_lang = "es" })

    -- The reply's newline is discovered after `comment.reapply` has already run,
    -- so a single wrapped block leaves the split-off row bare: the layout layer
    -- has to split the reply into paragraphs before the leaders are applied.
    assert.same({
      "  // uno  T1",
      "  // dos  T2",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)

describe("charwise replace", function()
  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
  end)

  it("AC13: snaps a charwise end column to the end of its codepoint", function()
    local captured = capturing_provider("charwise_multibyte", function(text)
      return text .. " [cap]"
    end)
    -- `'<` lands mid-`日` and `'>` holds the *first* byte of `語`, so making the
    -- end exclusive by one byte would hand the provider two thirds of that
    -- character, and an unsnapped start would sever the first one.
    local bufnr = block_buffer({ "abc 日本語 def" }, "// %s", 1, 5, 1, 10)

    metaphrast.translate_selection(bufnr, "v", { replace = true, target_lang = "es" })

    assert.equals("日本語", captured())
    assert.same({ "abc 日本語 [cap] def" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC-B2: keeps the leader on a charwise line the provider split with a newline", function()
    capturing_provider("charwise_newline_leader", function()
      return "uno\ndos"
    end)
    local bufnr = block_buffer({ "  // hello there", "x := 1" }, "// %s", 1, 2, 1, 15)

    metaphrast.translate_selection(bufnr, "v", { replace = true, target_lang = "es" })

    -- `nvim_buf_set_text` starts the split-off line at column 0, so its indent
    -- is an asserted known residual; the leader itself is not, and losing it
    -- uncomments the line.
    assert.same({
      "  // uno",
      "// dos",
      "x := 1",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC-B5: refuses a charwise reply that would insert more than max_inserted_lines", function()
    capturing_provider("charwise_flood", function()
      return string.rep("x\n", 300)
    end)
    local original = { "  // hello there  TAIL1", "  // second line  TAIL2", "x := 1" }
    local bufnr = block_buffer(original, "// %s", 1, 2, 2, 15)

    local _, applied, reason = metaphrast.translate_selection(bufnr, "v", { replace = true, target_lang = "es" })

    -- The cap belongs to the write, not to one selection shape: a runaway reply
    -- floods a charwise buffer exactly as it floods a blockwise one.
    assert.is_false(applied)
    assert.truthy(reason:find("max_inserted_lines", 1, true), reason)
    assert.truthy(reason:find("200", 1, true), reason)
    assert.same(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)

describe("linewise replace", function()
  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
  end)

  it("AC18: splits a rendered line carrying provider newlines before writing it back", function()
    capturing_provider("linewise_newline", function()
      return "uno\ndos"
    end)
    local bufnr = block_buffer({ "  // hello there", "x := 1" }, "// %s", 1, 0, 1, 0)

    local _, applied = metaphrast.translate_range(bufnr, 0, 1, { replace = true, target_lang = "es" })

    -- `nvim_buf_set_lines` rejects an item containing a newline, so handing it
    -- the rendered table raised `'replacement string' item contains newlines`
    -- and left the caller with a traceback instead of a write. The line the
    -- provider split off now keeps its leader too: the layout layer splits the
    -- reply into paragraphs before `comment.reapply` runs.
    assert.is_true(applied)
    assert.same({ "  // uno", "  // dos", "x := 1" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("AC-B1: keeps the leader on every line a provider newline split off", function()
    capturing_provider("linewise_leader_ja", function()
      return "行1\n行2"
    end)
    local bufnr = block_buffer({ "// Foo does a thing.", "func Foo() {}" }, "// %s", 1, 0, 1, 0)

    local _, applied = metaphrast.translate_range(bufnr, 0, 1, { replace = true, target_lang = "ja" })

    assert.is_true(applied)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "// 行1", "// 行2", "func Foo() {}" }, lines)
    -- A bare split-off line is not a layout nicety: it uncomments source, so
    -- every line the translation produced has to carry the leader.
    for i = 1, 2 do
      assert.truthy(lines[i]:match("^%s*// "), string.format("line %d lost its leader: %q", i, lines[i]))
    end
  end)

  it("AC-B5: refuses a linewise reply that would insert more than max_inserted_lines", function()
    capturing_provider("linewise_flood", function()
      return string.rep("x\n", 300)
    end)
    local original = { "  // hello there", "  // second line", "x := 1" }
    local bufnr = block_buffer(original, "// %s", 1, 0, 2, 0)

    local _, applied, reason = metaphrast.translate_range(bufnr, 0, 1, { replace = true, target_lang = "es" })

    -- The linewise path wrote the flood unbounded, so the cap has to guard the
    -- write itself rather than the blockwise branch it happened to live in.
    assert.is_false(applied)
    assert.truthy(reason:find("max_inserted_lines", 1, true), reason)
    assert.truthy(reason:find("200", 1, true), reason)
    assert.same(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)

describe("ui helper", function()
  local ui = require("metaphrast.ui")
  local notifier

  local function stamp(entry)
    return entry and (entry.updated or entry.added) or 0
  end

  local function newest()
    local entries = notifier.get_history()
    table.sort(entries, function(a, b)
      return stamp(a) < stamp(b)
    end)
    return entries[#entries]
  end

  local function progress_entry()
    return vim.tbl_filter(function(entry)
      return entry.id == ui.PROGRESS_ID
    end, notifier.get_history())[1]
  end

  before_each(function()
    metaphrast._reset_for_tests()
    metaphrast.setup({ provider = "echo" })
    notifier = ui.require_snacks().notifier
  end)

  it("loads the real snacks module through the single access point", function()
    local snacks = ui.require_snacks()

    assert.is_table(snacks)
    assert.truthy(snacks.win)
    assert.truthy(snacks.notifier)
    assert.equals(snacks, ui.require_snacks())
  end)

  it("adds a fresh history entry per notify with the requested level", function()
    local before = stamp(newest())

    ui.notify("hi", "warn")

    local entry = newest()
    assert.is_true(stamp(entry) > before)
    assert.equals("hi", entry.msg)
    assert.equals("warn", entry.level)
    assert.equals("Metaphrast", entry.title)
    assert.not_equals(ui.PROGRESS_ID, entry.id)
  end)

  it("updates one progress toast in place by id", function()
    local before = stamp(progress_entry())

    local done = ui.progress("Translating...")

    local entry = progress_entry()
    assert.is_true(stamp(entry) > before)
    assert.equals("Translating...", entry.msg)
    assert.equals(0, entry.timeout)
    local count = #notifier.get_history()

    done("Translated via echo", "info")

    entry = progress_entry()
    assert.equals("Translated via echo", entry.msg)
    assert.equals("info", entry.level)
    assert.equals(metaphrast.config.ui.notify.timeout, entry.timeout)
    assert.equals(count, #notifier.get_history())

    done("ignored", "error")
    assert.equals("Translated via echo", progress_entry().msg)
  end)

  it("keeps a failed progress toast on screen", function()
    local done = ui.progress("Translating...")

    done("Translation failed: boom", "error")

    local entry = progress_entry()
    assert.equals("error", entry.level)
    assert.equals(0, entry.timeout)
  end)

  it("prompts through snacks input with the configured default", function()
    ui.prompt_target("es", function() end)

    local input_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_input" then
        input_win = win
      end
    end
    assert.truthy(input_win, "snacks input window not opened")
    assert.same({ "es" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(input_win), 0, -1, false))
    vim.api.nvim_win_close(input_win, true)
  end)
end)
