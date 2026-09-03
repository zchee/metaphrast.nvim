---@class MetaphrastHttp
---@field timeout integer
---@field backend string

local M = {}

local util = require("metaphrast.util")
local uv = vim.uv

local function build_request_url(url, query)
  if not query then
    return url
  end
  local qs = {}
  for k, v in pairs(query) do
    table.insert(qs, string.format("%s=%s", util.urlencode(k), util.urlencode(v)))
  end
  if #qs == 0 then
    return url
  end
  return url .. "?" .. table.concat(qs, "&")
end

---Escape a value for the double-quoted form of a curl `--config` document.
---@param value string
---@return string
local function escape_config_value(value)
  local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
  return escaped
end

---Build curl's argv and the config document that carries every credential.
---
---The URL (which may hold a `?key=` secret), the headers and the body are
---written to a document curl reads from stdin, so nothing secret reaches argv
---where any process on the machine can read it. The body is emitted as
---`data-raw`: `data` and `data-binary` read a leading `@` as a local filename,
---which would turn a hostile payload into a file-exfiltration primitive.
---@param method string
---@param url string
---@param opts table|nil
---@return string[] args
---@return string config
local function build_request(method, url, opts)
  local args = { "-sS", "-X", method, "-w", "\n%{http_code}", "--config", "-" }
  local request_url = build_request_url(url, opts and opts.query or nil)
  local lines = { string.format('url = "%s"', escape_config_value(request_url)) }
  if opts and opts.headers then
    for _, h in ipairs(opts.headers) do
      table.insert(lines, string.format('header = "%s"', escape_config_value(h)))
    end
  end
  if opts and opts.data then
    table.insert(lines, string.format('data-raw = "%s"', escape_config_value(opts.data)))
  end
  return args, table.concat(lines, "\n") .. "\n"
end

---@param raw_stdout string
---@return string body
---@return integer http_status
local function parse_response(raw_stdout)
  local status_str = raw_stdout:match("\n(%d+)$")
  local http_status = status_str and tonumber(status_str) or 0
  local body = status_str and raw_stdout:sub(1, -(#status_str + 2)) or raw_stdout
  return body, http_status
end

---@param args string[]
---@param config string
---@param timeout integer
---@return table|nil
local function run_with_job(args, config, timeout)
  local ok, Job = pcall(require, "plenary.job")
  if not ok then
    return nil
  end
  -- `interactive` is what allocates the stdin pipe the writer needs. It already
  -- defaults to true; setting it keeps the dependency visible here rather than
  -- in a pinned third party's default.
  local job = Job:new({
    command = "curl",
    args = args,
    writer = config,
    interactive = true,
  })
  local stdout, code = job:sync(timeout or 20000)
  local stderr = job:stderr_result()
  local raw = stdout and table.concat(stdout, "\n") or ""
  local body, http_status = parse_response(raw)
  return {
    code = code or 0,
    stdout = body,
    stderr = stderr and table.concat(stderr, "\n") or "",
    http_status = http_status,
  }
end

---@param args string[]
---@param config string
---@param timeout integer
---@return table
local function run_with_system(args, config, timeout)
  local handle = vim.system(vim.list_extend({ "curl" }, args), { text = true, timeout = timeout, stdin = config })
  local result = handle:wait()
  local raw = result.stdout or ""
  local body, http_status = parse_response(raw)
  return {
    code = result.code,
    stdout = body,
    stderr = result.stderr or "",
    http_status = http_status,
  }
end

---@param cfg MetaphrastHttp
---@return fun(method: string, url: string, opts: table): table
function M.build(cfg)
  return function(method, url, opts)
    local args, config = build_request(method, url, opts)
    if cfg.backend == "plenary" then
      local res = run_with_job(args, config, cfg.timeout or 20000)
      if res then
        return res
      end
      vim.notify("metaphrast: plenary.job unavailable, falling back to curl", vim.log.levels.WARN)
    end
    return run_with_system(args, config, cfg.timeout or 20000)
  end
end

---@param cfg MetaphrastHttp
---@return fun(method: string, url: string, opts: table): table
function M.build_async(cfg)
  local ok_job, Job = pcall(require, "plenary.job")
  local ok_async, async = pcall(require, "plenary.async")
  if not (ok_job and ok_async) then
    local sync = M.build(cfg)
    return function(method, url, opts)
      return sync(method, url, opts)
    end
  end

  local wrap = async.wrap

  return wrap(function(method, url, opts, cb)
    local args, config = build_request(method, url, opts)
    local timer
    local job
    job = Job:new({
      command = "curl",
      args = args,
      writer = config,
      interactive = true,
      enable_recording = true,
      on_exit = function(j, code, signal)
        if timer then
          timer:stop()
          timer:close()
        end
        local raw = j:result() and table.concat(j:result(), "\n") or ""
        local body, http_status = parse_response(raw)
        cb({
          code = code or signal or 0,
          stdout = body,
          stderr = j:stderr_result() and table.concat(j:stderr_result(), "\n") or "",
          http_status = http_status,
        })
      end,
    })
    local timeout = cfg.timeout or 20000
    if timeout and timeout > 0 then
      timer = uv.new_timer()
      timer:start(timeout, 0, function()
        if job and not job.is_shutdown then
          job:shutdown(1, 9)
        end
        if timer then
          timer:stop()
          timer:close()
        end
      end)
    end
    job:start()
  end, 4)
end

return M
