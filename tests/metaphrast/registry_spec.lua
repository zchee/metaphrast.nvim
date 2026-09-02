local registry = require("metaphrast.providers")

describe("provider registry", function()
  before_each(function()
    registry.reset()
  end)

  it("registers and retrieves a provider", function()
    local provider = {
      translate = function()
        return "ok"
      end,
    }
    registry.register("test", provider)
    assert.equals(provider, registry.get("test"))
  end)

  it("returns nil for unregistered provider", function()
    assert.is_nil(registry.get("nonexistent"))
  end)

  it("lists registered provider names sorted", function()
    registry.register("beta", { translate = function() end })
    registry.register("alpha", { translate = function() end })
    registry.register("gamma", { translate = function() end })
    assert.same({ "alpha", "beta", "gamma" }, registry.names())
  end)

  it("rejects registration without name", function()
    assert.has_error(function()
      registry.register("", { translate = function() end })
    end)
  end)

  it("rejects registration without translate function", function()
    assert.has_error(function()
      registry.register("bad", {})
    end)
  end)

  it("translates via registered provider", function()
    registry.register("echo", {
      translate = function(_, payload)
        return payload.text .. "!"
      end,
    })
    local result = registry.translate("echo", function() end, { text = "hello", config = {} })
    assert.equals("hello!", result)
  end)

  it("errors on translate with unknown provider", function()
    assert.has_error(function()
      registry.translate("unknown", function() end, { text = "hi" })
    end)
  end)

  it("validates provider before translate", function()
    registry.register("strict", {
      validate = function(cfg)
        if not cfg.key then
          return false, "key required"
        end
        return true
      end,
      translate = function()
        return "ok"
      end,
    })
    assert.has_error(function()
      registry.translate("strict", function() end, {
        text = "hi",
        config = { providers = { strict = {} } },
      })
    end)
  end)

  it("passes validation when config is correct", function()
    registry.register("strict", {
      validate = function(cfg)
        if not cfg.key then
          return false, "key required"
        end
        return true
      end,
      translate = function()
        return "ok"
      end,
    })
    local result = registry.translate("strict", function() end, {
      text = "hi",
      config = { providers = { strict = { key = "abc" } } },
    })
    assert.equals("ok", result)
  end)

  it("estimates cost when provider supports it", function()
    registry.register("priced", {
      translate = function()
        return "ok"
      end,
      estimate_cost = function(payload)
        return #payload.text * 0.01
      end,
    })
    local cost = registry.estimate_cost("priced", { text = "hello" })
    assert.equals(0.05, cost)
  end)

  it("returns nil cost when provider has no estimate_cost", function()
    registry.register("free", {
      translate = function()
        return "ok"
      end,
    })
    assert.is_nil(registry.estimate_cost("free", { text = "hello" }))
  end)

  it("returns nil cost for unregistered provider", function()
    assert.is_nil(registry.estimate_cost("missing", { text = "hello" }))
  end)

  it("reset clears all providers", function()
    registry.register("a", { translate = function() end })
    registry.register("b", { translate = function() end })
    assert.equals(2, #registry.names())
    registry.reset()
    assert.equals(0, #registry.names())
  end)

  it("overwrites provider on re-register", function()
    registry.register("dup", {
      translate = function()
        return "v1"
      end,
    })
    registry.register("dup", {
      translate = function()
        return "v2"
      end,
    })
    local result = registry.translate("dup", function() end, { text = "", config = {} })
    assert.equals("v2", result)
  end)
end)
