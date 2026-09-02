local uv = vim.uv or vim.loop

---@class MetaphrastCache
---@field enabled boolean
---@field dir string
---@field ttl integer
---@field memory_enabled boolean
---@field memory_max_entries integer
---@field memory_skip_disk_ttl integer

local M = {}

-- simple FIFO in-memory cache to avoid disk writes for short-lived entries
local mem_store = {}
local mem_queue = {}
local mem_size = 0

---@param path string
---@return string|nil
local function dirname(path)
  if not path or path == "" then
    return nil
  end
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end
  return path:match("^(.*)[/\\][^/\\]+$")
end

---@param dir string
---@return boolean
local function ensure_dir(dir)
  if not dir or dir == "" then
    return false
  end

  local stat = uv.fs_stat(dir)
  if stat and stat.type == "directory" then
    return true
  end

  local parent = dirname(dir)
  if parent and parent ~= "" and parent ~= dir then
    local ok_parent = ensure_dir(parent)
    if not ok_parent then
      return false
    end
  end

  local ok, err = uv.fs_mkdir(dir, 448) -- 0700
  if ok or err == "EEXIST" or err == "EISDIR" then
    return true
  end

  return false
end

local function mem_clear()
  mem_store = {}
  mem_queue = {}
  mem_size = 0
end

---@param max_entries integer
local function mem_evict_overflow(max_entries)
  if not max_entries or max_entries <= 0 then
    return
  end
  while mem_size > max_entries do
    local key = table.remove(mem_queue, 1)
    if key and mem_store[key] then
      mem_store[key] = nil
      mem_size = mem_size - 1
    end
  end
end

---@param cache MetaphrastCache
---@param key string
---@param value string
---@param saved_at integer
local function mem_put(cache, key, value, saved_at)
  if not cache.memory_enabled then
    return
  end
  if not mem_store[key] then
    mem_size = mem_size + 1
    table.insert(mem_queue, key)
  end
  mem_store[key] = { value = value, saved_at = saved_at }
  mem_evict_overflow(cache.memory_max_entries or 512)
end

---@param cache MetaphrastCache
---@param key string
---@param now integer
---@return string|nil
local function mem_get(cache, key, now)
  if not cache.memory_enabled then
    return nil
  end
  local entry = mem_store[key]
  if not entry then
    return nil
  end
  if cache.ttl and cache.ttl > 0 and entry.saved_at and now - entry.saved_at > cache.ttl then
    mem_store[key] = nil
    mem_size = math.max(0, mem_size - 1)
    return nil
  end
  return entry.value
end

---@param path string
---@return string|nil
local function read_file(path)
  local fd = uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end

  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

---@param path string
---@param payload string
---@return boolean
local function write_atomic(path, payload)
  local tmp = path .. ".tmp"

  local fd = uv.fs_open(tmp, "w", 420)
  if not fd then
    return false
  end

  local bytes = uv.fs_write(fd, payload, 0)
  uv.fs_close(fd)
  if not bytes then
    uv.fs_unlink(tmp)
    return false
  end

  local ok = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    return false
  end

  return true
end

---@param provider string
---@param source string|nil
---@param target string|nil
---@param text string
---@return string
function M.make_key(provider, source, target, text)
  local raw = table.concat({ provider or "?", source or "", target or "", text }, "\n")
  return vim.fn.sha256(raw)
end

---@param cache MetaphrastCache
---@param key string
---@return string|nil
function M.get(cache, key)
  if not cache or not cache.enabled or not cache.dir then
    return nil
  end
  local now = os.time()
  local in_mem = mem_get(cache, key, now)
  if in_mem then
    return in_mem
  end

  if not ensure_dir(cache.dir) then
    return nil
  end
  local path = cache.dir .. "/" .. key .. ".json"
  local stat = uv.fs_stat(path)
  if not stat then
    return nil
  end
  if cache.ttl and cache.ttl > 0 and stat.mtime and stat.mtime.sec and now - stat.mtime.sec > cache.ttl then
    uv.fs_unlink(path)
    return nil
  end
  local data = read_file(path)
  if not data or data == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or not decoded or not decoded.value then
    return nil
  end
  return decoded.value
end

---@param cache MetaphrastCache
---@param key string
---@param value string
function M.put(cache, key, value)
  if not cache or not cache.enabled or not cache.dir then
    return
  end
  local saved_at = os.time()
  mem_put(cache, key, value, saved_at)

  local skip_disk_ttl = cache.memory_skip_disk_ttl or 0
  if skip_disk_ttl > 0 and cache.ttl and cache.ttl <= skip_disk_ttl then
    return
  end

  if not ensure_dir(cache.dir) then
    return
  end
  local path = string.format("%s/%s.json", cache.dir, key)
  local payload = vim.json.encode({ value = value, saved_at = saved_at })
  write_atomic(path, payload)
end

---@param cache MetaphrastCache
function M.clear(cache)
  if not cache or not cache.enabled or not cache.dir then
    mem_clear()
    return
  end
  mem_clear()
  local dir = cache.dir
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    uv.fs_unlink(dir .. "/" .. name)
  end
end

return M
