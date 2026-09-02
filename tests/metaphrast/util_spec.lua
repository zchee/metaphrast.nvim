local util = require("metaphrast.util")

describe("util.split_lines", function()
  it("splits single line", function()
    local result = util.split_lines("hello")
    assert.same({ "hello" }, result)
  end)

  it("splits multiple lines", function()
    local result = util.split_lines("a\nb\nc")
    assert.same({ "a", "b", "c" }, result)
  end)

  it("handles trailing newline", function()
    local result = util.split_lines("a\nb\n")
    assert.same({ "a", "b", "" }, result)
  end)

  it("handles empty string", function()
    local result = util.split_lines("")
    assert.same({ "" }, result)
  end)

  it("handles nil", function()
    local result = util.split_lines(nil)
    assert.same({ "" }, result)
  end)

  it("preserves empty lines in the middle", function()
    local result = util.split_lines("a\n\nb")
    assert.same({ "a", "", "b" }, result)
  end)
end)

describe("util.normalize_newlines", function()
  it("converts CRLF to LF", function()
    assert.equals("a\nb", util.normalize_newlines("a\r\nb"))
  end)

  it("converts bare CR to nothing", function()
    assert.equals("ab", util.normalize_newlines("a\rb"))
  end)

  it("handles mixed line endings", function()
    -- \r\n becomes \n, bare \r is removed (not converted to \n).
    assert.equals("a\nbc", util.normalize_newlines("a\r\nb\rc"))
  end)

  it("handles nil", function()
    assert.equals("", util.normalize_newlines(nil))
  end)

  it("passes through pure LF", function()
    assert.equals("a\nb\nc", util.normalize_newlines("a\nb\nc"))
  end)
end)

describe("util.urlencode", function()
  it("encodes spaces as plus", function()
    assert.equals("hello+world", util.urlencode("hello world"))
  end)

  it("encodes special characters", function()
    local result = util.urlencode("a&b=c")
    assert.equals("a%26b%3Dc", result)
  end)

  it("preserves alphanumeric and safe chars", function()
    assert.equals("abc123-._~", util.urlencode("abc123-._~"))
  end)

  it("handles nil", function()
    assert.equals("", util.urlencode(nil))
  end)

  it("handles empty string", function()
    assert.equals("", util.urlencode(""))
  end)

  it("encodes newlines as CRLF then percent-encoded", function()
    local result = util.urlencode("a\nb")
    assert.equals("a%0D%0Ab", result)
  end)
end)

describe("util.reflow_lines", function()
  it("returns as-is when line counts match", function()
    local result = util.reflow_lines("hello\nworld", { "foo", "bar" })
    assert.same({ "hello", "world" }, result)
  end)

  it("distributes tokens across target line count", function()
    local result = util.reflow_lines("one two three four", { "aaaa", "bbbb" })
    assert.equals(2, #result)
    -- All tokens should appear somewhere.
    local joined = table.concat(result, " ")
    assert.truthy(joined:find("one"))
    assert.truthy(joined:find("four"))
  end)

  it("handles fewer tokens than target lines", function()
    local result = util.reflow_lines("a b", { "xxx", "yyy", "zzz" })
    assert.equals(3, #result)
    -- All tokens must appear in the output.
    local joined = table.concat(result, " ")
    assert.truthy(joined:find("a"))
    assert.truthy(joined:find("b"))
  end)

  it("returns empty lines for whitespace-only text", function()
    local result = util.reflow_lines("   ", { "a", "b" })
    assert.equals(2, #result)
    assert.equals("", result[1])
    assert.equals("", result[2])
  end)

  it("handles zero original lines", function()
    local result = util.reflow_lines("hello world", {})
    assert.is_table(result)
  end)

  it("handles single token onto multiple lines", function()
    local result = util.reflow_lines("word", { "aa", "bb", "cc" })
    assert.equals(3, #result)
    local joined = table.concat(result, " ")
    assert.truthy(joined:find("word"))
  end)
end)
