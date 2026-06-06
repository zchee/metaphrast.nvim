local textflow = require("metafrastis.textflow")

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
    local stripped = { "// note", "code()", "// tail" }
    local info = {
      { indent = "", has_comment = true },
      { indent = "", has_comment = false },
      { indent = "", has_comment = true },
    }
    -- The first stripped value already has its leader removed; emulate that.
    stripped = { "note", "code()", "tail" }
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

  it("keeps an over-wide unit on its own line instead of dropping it", function()
    local lines = textflow.wrap("supercalifragilistic word", 5)
    assert.equals("supercalifragilistic", lines[1])
  end)

  it("returns a single empty line for empty input", function()
    assert.same({ "" }, textflow.wrap("", 10))
  end)
end)
