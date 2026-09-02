local health = require("metaphrast.health")

describe("health", function()
  local recorded
  local originals = {}
  local KINDS = { "start", "ok", "warn", "error", "info" }

  ---Every report of one kind whose message contains `needle`.
  local function matching(kind, needle)
    return vim.tbl_filter(function(entry)
      return entry.kind == kind and entry.msg:find(needle, 1, true) ~= nil
    end, recorded)
  end

  before_each(function()
    recorded = {}
    for _, kind in ipairs(KINDS) do
      originals[kind] = vim.health[kind]
      vim.health[kind] = function(msg, extra)
        recorded[#recorded + 1] = { kind = kind, msg = tostring(msg), extra = extra }
      end
    end
  end)

  after_each(function()
    for _, kind in ipairs(KINDS) do
      vim.health[kind] = originals[kind]
    end
  end)

  it("pins the snacks.nvim version the hover was built against", function()
    assert.equals("2.31.0", health.MIN_SNACKS_VERSION)
  end)

  it("reports the required dependencies as ok", function()
    health.check()

    assert.equals(1, #matching("start", "metaphrast"))
    assert.equals(1, #matching("ok", "snacks.nvim"))
    assert.equals(1, #matching("ok", "curl"))
    assert.equals(0, #vim.tbl_filter(function(entry)
      return entry.kind == "error"
    end, recorded))
  end)

  it("reports the winborder used when ui.win.border is unset", function()
    health.check()

    assert.equals(1, #matching("info", "vim.o.winborder"))
  end)
end)
