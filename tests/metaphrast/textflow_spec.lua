local textflow = require("metaphrast.textflow")

describe("textflow.is_list_marker", function()
  it("detects dash, star, and plus bullets", function()
    assert.is_true(textflow.is_list_marker("- inline: option"))
    assert.is_true(textflow.is_list_marker("* item"))
    assert.is_true(textflow.is_list_marker("+ item"))
  end)

  it("detects ordered list markers", function()
    assert.is_true(textflow.is_list_marker("1. first"))
    assert.is_true(textflow.is_list_marker("2) second"))
  end)

  it("rejects prose that merely starts with a dash word", function()
    assert.is_false(textflow.is_list_marker("-inline without space"))
    assert.is_false(textflow.is_list_marker("the JSON content"))
  end)
end)

describe("textflow.segment", function()
  ---Build matching info entries for a list of comment contents.
  local function comment_info(n)
    local info = {}
    for i = 1, n do
      info[i] = { indent = "", has_comment = true }
    end
    return info
  end

  it("merges soft-wrapped continuation lines into one paragraph", function()
    local stripped = {
      "The inline option specifies that",
      "the content is promoted as if",
      "specified in the parent struct.",
    }
    local segments, count = textflow.segment(stripped, comment_info(3))
    assert.equals(1, count)
    assert.equals(1, #segments)
    assert.equals("para", segments[1].kind)
    assert.equals(3, segments[1].source_count)
    assert.equals(
      "The inline option specifies that the content is promoted as if specified in the parent struct.",
      segments[1].text
    )
  end)

  it("breaks paragraphs on blank comment lines and preserves them", function()
    local stripped = { "First paragraph here.", "", "Second paragraph here." }
    local info = comment_info(3)
    local segments, count = textflow.segment(stripped, info)
    assert.equals(2, count)
    assert.equals(3, #segments)
    assert.equals("para", segments[1].kind)
    assert.equals("raw", segments[2].kind)
    assert.equals("", segments[2].content)
    assert.is_true(segments[2].has_comment)
    assert.equals("para", segments[3].kind)
  end)

  it("starts a new paragraph at each list marker", function()
    local stripped = { "- first item", "continues here", "- second item" }
    local segments, count = textflow.segment(stripped, comment_info(3))
    assert.equals(2, count)
    assert.equals("- first item continues here", segments[1].text)
    assert.equals("- second item", segments[2].text)
  end)

  it("passes non-comment lines through without merging", function()
    -- Leaders are already removed from comment lines; non-comment lines stay verbatim.
    local stripped = { "note", "code()", "tail" }
    local info = {
      { indent = "", has_comment = true },
      { indent = "", has_comment = false },
      { indent = "", has_comment = true },
    }
    local segments, count = textflow.segment(stripped, info)
    assert.equals(2, count)
    assert.equals("para", segments[1].kind)
    assert.equals("raw", segments[2].kind)
    assert.is_false(segments[2].has_comment)
    assert.equals("code()", segments[2].content)
    assert.equals("para", segments[3].kind)
  end)

  it("records the widest source line as the paragraph budget", function()
    local stripped = { "short", "a much longer continuation line" }
    local segments = textflow.segment(stripped, comment_info(2))
    assert.equals(#"a much longer continuation line", segments[1].width)
  end)
end)

describe("textflow.is_no_line_start", function()
  it("matches closing punctuation and brackets", function()
    for _, ch in ipairs({ "。", "、", "）", "」", "！", "：", "”" }) do
      assert.is_true(textflow.is_no_line_start(ch), ch)
    end
  end)

  it("lets a path or an identifier open a line", function()
    -- ASCII punctuation binds to the word before it without a space, so a unit
    -- that starts with it is a name, not punctuation.
    for _, unit in ipairs({ ".gitignore", ".tool_input.file_path", ")", "," }) do
      assert.is_false(textflow.is_no_line_start(unit), unit)
    end
  end)

  it("judges a break unit by its first character", function()
    assert.is_true(textflow.is_no_line_start("」という"))
    assert.is_false(textflow.is_no_line_start("という」"))
  end)

  it("leaves the strict-mode-only characters breakable", function()
    -- `line-break: normal` allows a line to open with these; forcing them onto
    -- the previous line only buys shorter lines.
    for _, ch in ipairs({ "ー", "っ", "ゃ", "々", "ゝ" }) do
      assert.is_false(textflow.is_no_line_start(ch), ch)
    end
  end)

  it("reports false for ordinary text and for nothing", function()
    assert.is_false(textflow.is_no_line_start("あ"))
    assert.is_false(textflow.is_no_line_start("word"))
    assert.is_false(textflow.is_no_line_start(""))
  end)
end)

describe("textflow.wrap", function()
  it("wraps latin words on whitespace within the target width", function()
    local lines = textflow.wrap("the quick brown fox jumps", 10)
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 10, "line exceeds width: " .. line)
    end
    assert.equals("the quick brown fox jumps", table.concat(lines, " "))
  end)

  it("breaks CJK text on character boundaries by display width", function()
    -- Each kana is two display columns; width 6 fits three per line.
    local lines = textflow.wrap("あいうえおか", 6)
    assert.equals(2, #lines)
    assert.equals("あいう", lines[1])
    assert.equals("えおか", lines[2])
  end)

  it("handles mixed Japanese and Latin without losing characters", function()
    local text = "inline は JSON の埋め込みに相当します and works"
    local lines = textflow.wrap(text, 12)
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 12, "line exceeds width: " .. line)
    end
    -- Reconstructing the wrapped output collapses wrap points but keeps content.
    local rejoined = table.concat(lines, "")
    assert.truthy(rejoined:find("JSON", 1, true))
    assert.truthy(rejoined:find("埋め込み", 1, true))
    assert.truthy(rejoined:find("works", 1, true))
  end)

  it("never opens a line with a full stop", function()
    -- The greedy fill would break right before 。, so the break moves back one
    -- character and 。 rides on the line before it (追い出し).
    assert.same({ "あい", "う。え", "お" }, textflow.wrap("あいう。えお", 6))
  end)

  it("moves a run of no-start characters down together", function()
    assert.same({ "あい", "う。」", "えお" }, textflow.wrap("あいう。」えお", 6))
  end)

  it("keeps a closing bracket off the line head", function()
    assert.same({ "テス", "ト」あ", "い" }, textflow.wrap("テスト」あい", 6))
  end)

  it("accepts the plain break when no unit can stay behind", function()
    -- Two columns leave the line a single character, so pulling 。 up would
    -- empty it. The break stands instead of dropping content or looping.
    assert.same({ "あ", "。", "い" }, textflow.wrap("あ。い", 2))
  end)

  it("keeps the fill when what would move cannot fit on one line", function()
    -- "abcdefg。」」" needs 13 columns, so the next line would break inside
    -- the run and open with it anyway: the greedy break stays.
    assert.same({ "a b abcdefg", "。」」" }, textflow.wrap("a b abcdefg。」」", 12))
  end)

  it("does not pull a word back for a path that follows it", function()
    assert.same(
      { "Reads the hook JSON on stdin, pulls", ".tool_input.file_path out of it" },
      textflow.wrap("Reads the hook JSON on stdin, pulls .tool_input.file_path out of it", 36)
    )
  end)

  it("honors the line-head rule without exceeding the width", function()
    local text =
      "**本書は参考用の機能一覧であり、ロードマップではありません。**次の段落へ続きます。"
    local lines = textflow.wrap(text, 20)

    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 20, "line exceeds width: " .. line)
      assert.is_false(textflow.is_no_line_start(line), "line opens with a kinsoku character: " .. line)
    end
    assert.equals(text, table.concat(lines, ""))
  end)

  it("keeps an over-wide unit on its own line instead of dropping it", function()
    local lines = textflow.wrap("supercalifragilistic word", 5)
    assert.equals("supercalifragilistic", lines[1])
  end)

  it("returns a single empty line for empty input", function()
    assert.same({ "" }, textflow.wrap("", 10))
  end)

  it("AC-C2a: returns one unbroken line for a single enormous word", function()
    local lines = textflow.wrap(string.rep("a", 200000), 80)
    assert.equals(1, #lines)
    assert.equals(200000, #lines[1])
  end)

  it("AC-C2b: wraps a single enormous word without a quadratic stall", function()
    -- A character-at-a-time string accumulator reallocates the whole word on
    -- every append, so one long word costs O(n^2) while prose of the same size
    -- costs O(n). Timing alone cannot tell a slow runner from a wrong result,
    -- so AC-C2a asserts the output and this asserts only the cost: an absolute
    -- ceiling, plus a ratio against same-size prose measured in this process.
    local word = string.rep("a", 200000)
    local prose = string.rep("hello world ", 16000)

    local t0 = vim.uv.hrtime()
    textflow.wrap(prose, 80)
    local prose_ms = (vim.uv.hrtime() - t0) / 1e6

    t0 = vim.uv.hrtime()
    textflow.wrap(word, 80)
    local word_ms = (vim.uv.hrtime() - t0) / 1e6

    local measured = string.format("word %.1f ms, prose %.1f ms", word_ms, prose_ms)
    assert.is_true(word_ms < 400, "one 200000-char word took too long: " .. measured)
    assert.is_true(word_ms < 5 * prose_ms, "one word costs more than 5x same-size prose: " .. measured)
  end)
end)
