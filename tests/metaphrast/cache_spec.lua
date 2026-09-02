local uv = vim.uv or vim.loop
local cache = require("metaphrast.cache")

---@return string
local function tmpdir()
  local template = string.format("%s/metaphrast-cache-XXXXXX", uv.os_tmpdir() or "/tmp")
  local dir, err = uv.fs_mkdtemp(template)
  assert(dir, err)
  return dir
end

---@param dir string|nil
local function cleanup(dir)
  if not dir then
    return
  end
  local handle = uv.fs_scandir(dir)
  if handle then
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      uv.fs_unlink(dir .. "/" .. name)
    end
  end
  uv.fs_rmdir(dir)
end

describe("cache module", function()
  local dir
  local cfg

  after_each(function()
    cleanup(dir)
    dir = nil
    cfg = nil
  end)

  it("writes and reads values", function()
    dir = tmpdir()
    cfg = { enabled = true, ttl = 3600, dir = dir, memory_enabled = true }
    local key = cache.make_key("echo", "en", "ja", "hello")
    cache.put(cfg, key, "konnichiwa")
    assert.equals("konnichiwa", cache.get(cfg, key))
  end)

  it("evicts expired entries using ttl", function()
    dir = tmpdir()
    cfg = { enabled = true, ttl = 1, dir = dir, memory_enabled = true }
    local key = cache.make_key("echo", "en", "ja", "bye")
    cache.put(cfg, key, "sayonara")
    vim.wait(2200, function()
      return false
    end)
    assert.is_nil(cache.get(cfg, key))
    local path = string.format("%s/%s.json", dir, key)
    assert.is_nil(uv.fs_stat(path))
  end)

  it("allows put from fast-event callbacks", function()
    dir = tmpdir()
    cfg = { enabled = true, ttl = 3600, dir = dir, memory_enabled = true }
    local key = cache.make_key("echo", "en", "ja", "fast")
    local done, err
    local timer = uv.new_timer()
    timer:start(0, 0, function()
      done, err = pcall(cache.put, cfg, key, "speed")
      timer:stop()
      timer:close()
    end)
    vim.wait(1000, function()
      return done ~= nil
    end)
    assert.is_true(done, err or "cache.put failed in fast event")
    assert.equals("speed", cache.get(cfg, key))
  end)

  it("skips disk when ttl below skip threshold", function()
    dir = tmpdir()
    cfg = {
      enabled = true,
      ttl = 2,
      dir = dir,
      memory_enabled = true,
      memory_skip_disk_ttl = 5,
      memory_max_entries = 16,
    }
    local key = cache.make_key("echo", "en", "ja", "temp")
    cache.put(cfg, key, "v1")
    local path = string.format("%s/%s.json", dir, key)
    assert.is_nil(uv.fs_stat(path))
    assert.equals("v1", cache.get(cfg, key))
  end)

  it("writes to disk when ttl above skip threshold", function()
    dir = tmpdir()
    cfg = {
      enabled = true,
      ttl = 10,
      dir = dir,
      memory_enabled = true,
      memory_skip_disk_ttl = 5,
    }
    local key = cache.make_key("echo", "en", "ja", "persist")
    cache.put(cfg, key, "v2")
    local path = string.format("%s/%s.json", dir, key)
    local stat = uv.fs_stat(path)
    assert.is_not_nil(stat)
    assert.equals("v2", cache.get(cfg, key))
  end)

  it("evicts oldest entries when memory is full", function()
    dir = tmpdir()
    cfg = {
      enabled = true,
      ttl = 3600,
      dir = dir,
      memory_enabled = true,
      memory_max_entries = 2,
      memory_skip_disk_ttl = 4000,
    }
    local k1 = cache.make_key("echo", "en", "ja", "a")
    local k2 = cache.make_key("echo", "en", "ja", "b")
    local k3 = cache.make_key("echo", "en", "ja", "c")
    cache.put(cfg, k1, "one")
    cache.put(cfg, k2, "two")
    cache.put(cfg, k3, "three")

    local mem_only_cfg = {
      enabled = true,
      ttl = 3600,
      dir = dir,
      memory_enabled = true,
      memory_max_entries = 2,
      memory_skip_disk_ttl = 4000,
    }
    assert.is_nil(cache.get(mem_only_cfg, k1))
    assert.equals("two", cache.get(mem_only_cfg, k2))
    assert.equals("three", cache.get(mem_only_cfg, k3))
  end)
end)
