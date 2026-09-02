local comment = require("metaphrast.comment")

describe("comment.parse", function()
  it("parses line comment style", function()
    local result = comment.parse("// %s")
    assert.is_table(result)
    assert.equals("// ", result.prefix)
    assert.equals("", result.suffix)
  end)

  it("parses block comment style", function()
    local result = comment.parse("/* %s */")
    assert.is_table(result)
    assert.equals("/* ", result.prefix)
    assert.equals(" */", result.suffix)
  end)

  it("parses hash comment style", function()
    local result = comment.parse("# %s")
    assert.is_table(result)
    assert.equals("# ", result.prefix)
    assert.equals("", result.suffix)
  end)

  it("parses Lua comment style", function()
    local result = comment.parse("-- %s")
    assert.is_table(result)
    assert.equals("-- ", result.prefix)
    assert.equals("", result.suffix)
  end)

  it("returns nil for nil input", function()
    assert.is_nil(comment.parse(nil))
  end)

  it("returns nil for non-string input", function()
    assert.is_nil(comment.parse(42))
  end)

  it("returns nil for empty prefix and suffix", function()
    assert.is_nil(comment.parse("%s"))
  end)

  it("returns nil for string without %s", function()
    assert.is_nil(comment.parse("no placeholder"))
  end)
end)

describe("comment.strip_lines", function()
  it("strips C++ style line comments", function()
    local stripped, info, parts = comment.strip_lines({ "// hello world" }, "// %s")
    assert.equals("hello world", stripped[1])
    assert.is_true(info[1].has_comment)
    assert.equals("// ", parts.prefix)
  end)

  it("preserves indentation info", function()
    local stripped, info = comment.strip_lines({ "    // indented" }, "// %s")
    assert.equals("indented", stripped[1])
    assert.equals("    ", info[1].indent)
    assert.is_true(info[1].has_comment)
  end)

  it("strips block comments with suffix", function()
    local stripped, info, parts = comment.strip_lines({ "/* block text */" }, "/* %s */")
    assert.equals("block text", stripped[1])
    assert.is_true(info[1].has_comment)
    assert.equals("/* ", parts.prefix)
    assert.equals(" */", parts.suffix)
  end)

  it("leaves non-comment lines untouched", function()
    local stripped, info = comment.strip_lines({ "no comment here" }, "// %s")
    assert.equals("no comment here", stripped[1])
    assert.is_false(info[1].has_comment)
  end)

  it("handles multiple lines with mixed comments", function()
    local lines = { "// commented", "plain text", "// also commented" }
    local stripped, info = comment.strip_lines(lines, "// %s")
    assert.equals("commented", stripped[1])
    assert.equals("plain text", stripped[2])
    assert.equals("also commented", stripped[3])
    assert.is_true(info[1].has_comment)
    assert.is_false(info[2].has_comment)
    assert.is_true(info[3].has_comment)
  end)

  it("returns copies when commentstring is nil", function()
    local original = { "hello", "world" }
    local stripped, info, parts = comment.strip_lines(original, nil)
    assert.same({ "hello", "world" }, stripped)
    assert.is_nil(info)
    assert.is_nil(parts)
    -- Verify it's a deep copy.
    stripped[1] = "changed"
    assert.equals("hello", original[1])
  end)

  it("handles indented block comments", function()
    local stripped, info = comment.strip_lines({ "    /* inner text */" }, "/* %s */")
    assert.equals("inner text", stripped[1])
    assert.equals("    ", info[1].indent)
    assert.is_true(info[1].has_comment)
  end)
end)

describe("comment.reapply", function()
  it("reapplies line comment prefix", function()
    local info = { { indent = "", has_comment = true } }
    local parts = { prefix = "// ", suffix = "" }
    local result = comment.reapply({ "translated" }, info, parts)
    assert.equals("// translated", result[1])
  end)

  it("reapplies with indentation", function()
    local info = { { indent = "    ", has_comment = true } }
    local parts = { prefix = "// ", suffix = "" }
    local result = comment.reapply({ "translated" }, info, parts)
    assert.equals("    // translated", result[1])
  end)

  it("reapplies block comments with suffix", function()
    local info = { { indent = "", has_comment = true } }
    local parts = { prefix = "/* ", suffix = " */" }
    local result = comment.reapply({ "translated" }, info, parts)
    assert.equals("/* translated */", result[1])
  end)

  it("leaves lines without comment info untouched", function()
    local info = { { indent = "", has_comment = false } }
    local parts = { prefix = "// ", suffix = "" }
    local result = comment.reapply({ "plain text" }, info, parts)
    assert.equals("plain text", result[1])
  end)

  it("handles mixed lines", function()
    local info = {
      { indent = "", has_comment = true },
      { indent = "", has_comment = false },
      { indent = "  ", has_comment = true },
    }
    local parts = { prefix = "# ", suffix = "" }
    local result = comment.reapply({ "first", "second", "third" }, info, parts)
    assert.equals("# first", result[1])
    assert.equals("second", result[2])
    assert.equals("  # third", result[3])
  end)

  it("returns lines as-is when info is nil", function()
    local result = comment.reapply({ "hello" }, nil, nil)
    assert.same({ "hello" }, result)
  end)

  it("handles string input", function()
    local result = comment.reapply("hello\nworld", nil, nil)
    assert.same({ "hello", "world" }, result)
  end)
end)

describe("comment round-trip", function()
  it("strip then reapply preserves C++ comments", function()
    local original = { "// hello world" }
    local stripped, info, parts = comment.strip_lines(original, "// %s")
    local restored = comment.reapply(stripped, info, parts)
    assert.equals("// hello world", restored[1])
  end)

  it("strip then reapply preserves block comments", function()
    local original = { "    /* block text */" }
    local stripped, info, parts = comment.strip_lines(original, "/* %s */")
    local restored = comment.reapply(stripped, info, parts)
    assert.equals("    /* block text */", restored[1])
  end)

  it("strip then reapply preserves mixed lines", function()
    local original = { "// commented", "plain text", "  // indented comment" }
    local stripped, info, parts = comment.strip_lines(original, "// %s")
    local restored = comment.reapply(stripped, info, parts)
    assert.equals("// commented", restored[1])
    assert.equals("plain text", restored[2])
    assert.equals("  // indented comment", restored[3])
  end)
end)
