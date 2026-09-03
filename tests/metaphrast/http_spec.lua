local http = require("metaphrast.http")

-- Fake credentials only: nothing here reaches an external endpoint. The wire
-- specs talk to a loopback listener started inside the spec, which AGENTS.md
-- allows for transport specs.
local QUERY_KEY = "SECRET_QUERY_KEY"
local BEARER = "SECRET_BEARER_TOKEN"
local GOOG_KEY = "SECRET_GOOG_API_KEY"
local DEEPL_KEY = "SECRET_DEEPL_KEY"
local CLIENT_SECRET = "SECRET_CLIENT_SECRET"
local REFRESH_TOKEN = "SECRET_REFRESH_TOKEN"

-- Every character class the config-document escaper has to survive: a double
-- quote, a backslash, a newline, a carriage return and a multibyte codepoint.
local WIRE_BODY = '{"q":"a \\ b \n c \r d 日本語"}'

---Start a loopback HTTP listener that captures one request and answers 200.
---@return userdata server
---@return integer port
---@return table captured
local function start_listener()
  local server = vim.uv.new_tcp()
  local captured = {}
  server:bind("127.0.0.1", 0)
  local port = server:getsockname().port
  server:listen(16, function(listen_err)
    assert(not listen_err, listen_err)
    local client = vim.uv.new_tcp()
    server:accept(client)
    local chunks = {}
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        pcall(function()
          client:read_stop()
          client:close()
        end)
        return
      end
      table.insert(chunks, chunk)
      local raw = table.concat(chunks)
      local head, body = raw:match("^(.-\r\n\r\n)(.*)$")
      if not head then
        return
      end
      local want = tonumber(head:match("[Cc]ontent%-[Ll]ength: (%d+)")) or 0
      if #body < want then
        return
      end
      captured.head = head
      captured.body = body:sub(1, want)
      client:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok", function()
        pcall(function()
          client:close()
        end)
      end)
    end)
  end)
  return server, port, captured
end

describe("http transport", function()
  describe("argv hygiene", function()
    local calls
    local original_system

    before_each(function()
      calls = {}
      original_system = vim.system
      vim.system = function(cmd, opts)
        table.insert(calls, { cmd = vim.deepcopy(cmd), stdin = opts and opts.stdin })
        return {
          wait = function()
            return { code = 0, stdout = "{}\n200", stderr = "" }
          end,
        }
      end
    end)

    after_each(function()
      vim.system = original_system
    end)

    ---Drive one request through the sync client and return the single call.
    ---@param url string
    ---@param opts table
    ---@return table
    local function request(url, opts)
      local client = http.build({ backend = "curl", timeout = 5000 })
      client("POST", url, opts)
      assert.equals(1, #calls)
      return calls[1]
    end

    ---Assert a secret is absent from argv and present in the config document.
    ---@param call table
    ---@param secret string
    local function assert_off_argv(call, secret)
      local argv = table.concat(call.cmd, " ")
      assert.is_nil(argv:find(secret, 1, true))
      assert.is_string(call.stdin)
      assert.is_not_nil(call.stdin:find(secret, 1, true))
    end

    it("AC-F3: keeps a Bearer token off argv", function()
      local call = request("https://translation.googleapis.com/language/translate/v2", {
        headers = { "Authorization: Bearer " .. BEARER, "Content-Type: application/json" },
        data = '{"q":"hi"}',
      })
      assert_off_argv(call, BEARER)
    end)

    it("AC-F3: keeps an x-goog-api-key header off argv", function()
      local call = request("https://generativelanguage.googleapis.com/v1beta/models/x:generateContent", {
        headers = { "Content-Type: application/json", "x-goog-api-key: " .. GOOG_KEY },
        data = '{"contents":[]}',
      })
      assert_off_argv(call, GOOG_KEY)
    end)

    it("AC-F3: keeps a DeepL-Auth-Key header off argv", function()
      local call = request("https://api-free.deepl.com/v2/translate", {
        headers = {
          "Authorization: DeepL-Auth-Key " .. DEEPL_KEY,
          "Content-Type: application/x-www-form-urlencoded",
        },
        data = "text=hi&target_lang=EN",
      })
      assert_off_argv(call, DEEPL_KEY)
    end)

    it("AC-F3: keeps the google ?key= query off argv", function()
      local call = request("https://translation.googleapis.com/language/translate/v2?key=" .. QUERY_KEY, {
        headers = { "Content-Type: application/json" },
        data = '{"q":"hi"}',
      })
      assert_off_argv(call, QUERY_KEY)
    end)

    it("AC-F3: keeps the google_llm ?key= query off argv", function()
      local call = request("https://translation.googleapis.com/language/translate/v2?key=" .. QUERY_KEY, {
        headers = { "Content-Type: application/json; charset=utf-8" },
        data = '{"q":["hi"],"model":"projects/p/locations/l/models/general/translation-llm"}',
      })
      assert_off_argv(call, QUERY_KEY)
    end)

    it("AC-F3: keeps the ADC refresh client_secret and refresh_token off argv", function()
      local call = request("https://oauth2.googleapis.com/token", {
        headers = { "Content-Type: application/x-www-form-urlencoded" },
        data = table.concat({
          "client_id=an-id.apps.googleusercontent.com",
          "client_secret=" .. CLIENT_SECRET,
          "refresh_token=" .. REFRESH_TOKEN,
          "grant_type=refresh_token",
        }, "&"),
      })
      assert_off_argv(call, CLIENT_SECRET)
      assert_off_argv(call, REFRESH_TOKEN)
    end)

    it("AC-F3: puts a query-bearing url and every header in the config document", function()
      local call = request("https://translation.googleapis.com/language/translate/v2?key=" .. QUERY_KEY, {
        headers = { "Authorization: Bearer " .. BEARER, "x-goog-user-project: a-project" },
        data = '{"q":"hi"}',
      })
      assert.is_not_nil(call.stdin:find('url = "https://translation.googleapis.com', 1, true))
      assert.is_not_nil(call.stdin:find('header = "Authorization: Bearer ' .. BEARER .. '"', 1, true))
      assert.is_not_nil(call.stdin:find('header = "x-goog-user-project: a-project"', 1, true))
      -- `data` and `data-binary` read a leading @ as a local filename.
      assert.is_not_nil(call.stdin:find('data-raw = "', 1, true))
      assert.is_nil(call.stdin:find("\ndata =", 1, true))
      assert.is_nil(call.stdin:find("\ndata-binary =", 1, true))
    end)

    it("AC-F2: issues exactly one vim.system call and no shell string", function()
      local call = request("https://example.invalid/v2", { headers = {}, data = "x" })
      assert.equals("curl", call.cmd[1])
      assert.is_not_nil(vim.tbl_contains(call.cmd, "--config"))
      assert.is_true(vim.tbl_contains(call.cmd, "-"))
    end)

    it("escapes backslash, quote, newline and carriage return in the config document", function()
      local call = request("https://example.invalid/v2?note=a%22b", {
        headers = { 'X-Note: quote " and backslash \\' },
        data = 'a\\b"c\nd\re',
      })
      assert.is_not_nil(call.stdin:find('data-raw = "a\\\\b\\"c\\nd\\re"', 1, true))
      assert.is_not_nil(call.stdin:find('header = "X-Note: quote \\" and backslash \\\\"', 1, true))
      -- One line per directive: an unescaped newline would end the directive.
      assert.equals(3, #vim.split(vim.trim(call.stdin), "\n"))
    end)

    it("AC-F3: sends a literal @-prefixed body instead of reading that file", function()
      local call = request("https://example.invalid/v2", { headers = {}, data = "@/etc/passwd" })
      assert.is_not_nil(call.stdin:find('data-raw = "@/etc/passwd"', 1, true))
    end)
  end)

  describe("plenary fallback warning", function()
    local server
    local loaded_job
    local preload_job

    before_each(function()
      -- `package.loaded[...] = false` does not stop `require`; a preload that
      -- raises is what makes `pcall(require, "plenary.job")` fail.
      loaded_job = package.loaded["plenary.job"]
      preload_job = package.preload["plenary.job"]
      package.loaded["plenary.job"] = nil
      package.preload["plenary.job"] = function()
        error("forced: plenary.job unavailable")
      end
    end)

    after_each(function()
      package.loaded["plenary.job"] = loaded_job
      package.preload["plenary.job"] = preload_job
      if server and not server:is_closing() then
        server:close()
      end
      server = nil
      http._reset_for_tests()
    end)

    it("AC-G2: warns once per built client and still completes every request", function()
      local seen = {}
      http._reset_for_tests()
      http.notify = function(msg, level)
        table.insert(seen, { msg = msg, level = level })
      end
      local port
      server, port = start_listener()
      local url = string.format("http://127.0.0.1:%d/v2", port)
      local client = http.build({ backend = "plenary", timeout = 10000 })

      for _ = 1, 3 do
        local res = client("POST", url, { headers = { "Content-Type: application/json" }, data = "{}" })
        assert.equals(0, res.code)
        assert.equals(200, res.http_status)
      end

      -- The warning used to fire on every request, and plenary is optional, so
      -- the default backend made it a toast per translation.
      assert.equals(1, #seen)
      assert.truthy(seen[1].msg:find("plenary.job unavailable", 1, true), seen[1].msg)

      -- The flag belongs to the client, not the session: a rebuilt client (a
      -- second `setup()`) reports the condition again.
      local rebuilt = http.build({ backend = "plenary", timeout = 10000 })
      local res = rebuilt("POST", url, { headers = {}, data = "{}" })
      assert.equals(0, res.code)
      assert.equals(2, #seen)
    end)
  end)

  describe("notifier wiring", function()
    after_each(function()
      require("metaphrast")._reset_for_tests()
    end)

    it("AC-G3: defaults to vim.notify at module load, without reaching snacks", function()
      local loaded_http = package.loaded["metaphrast.http"]
      local loaded_root = package.loaded["metaphrast"]
      package.loaded["metaphrast.http"] = nil
      package.loaded["metaphrast"] = nil

      local ok, fresh = pcall(require, "metaphrast")
      local fresh_http = package.loaded["metaphrast.http"]
      package.loaded["metaphrast.http"] = loaded_http
      package.loaded["metaphrast"] = loaded_root

      -- `M.build` runs at load, before `setup()` calls `require_snacks()`, so
      -- wiring `ui.notify` there would raise for a user without snacks.
      assert.is_true(ok)
      assert.is_table(fresh)
      assert.equals(vim.notify, fresh_http.notify)
    end)

    it("AC-G3: setup() repoints the notifier and a reset restores the default", function()
      local metaphrast = require("metaphrast")
      local ui = require("metaphrast.ui")
      http._reset_for_tests()
      assert.equals(vim.notify, http.notify)

      metaphrast.setup({ provider = "echo" })
      assert.equals(ui.notify, http.notify)

      metaphrast._reset_for_tests()
      assert.equals(vim.notify, http.notify)
    end)
  end)

  describe("wire round-trip", function()
    local server

    after_each(function()
      if server and not server:is_closing() then
        server:close()
      end
      server = nil
    end)

    it("AC-F4: delivers the query, the header and a byte-exact body through vim.system", function()
      local port, captured
      server, port, captured = start_listener()
      local client = http.build({ backend = "curl", timeout = 10000 })
      local res = client("POST", string.format("http://127.0.0.1:%d/v2?key=%s", port, QUERY_KEY), {
        headers = { "Authorization: Bearer " .. BEARER, "Content-Type: application/json" },
        data = WIRE_BODY,
      })

      assert.equals(0, res.code)
      assert.equals(200, res.http_status)
      assert.is_not_nil(captured.head)
      assert.is_not_nil(captured.head:find("POST /v2?key=" .. QUERY_KEY .. " HTTP/1.1", 1, true))
      assert.is_not_nil(captured.head:find("Authorization: Bearer " .. BEARER, 1, true))
      assert.equals(WIRE_BODY, captured.body)
    end)

    it("AC-F4b: delivers the same bytes through the real plenary Job path", function()
      local port, captured
      server, port, captured = start_listener()
      local client = http.build({ backend = "plenary", timeout = 10000 })
      local res = client("POST", string.format("http://127.0.0.1:%d/v2?key=%s", port, QUERY_KEY), {
        headers = { "Authorization: Bearer " .. BEARER, "Content-Type: application/json" },
        data = WIRE_BODY,
      })

      assert.equals(0, res.code)
      assert.equals(200, res.http_status)
      assert.is_not_nil(captured.head)
      assert.is_not_nil(captured.head:find("POST /v2?key=" .. QUERY_KEY .. " HTTP/1.1", 1, true))
      assert.is_not_nil(captured.head:find("Authorization: Bearer " .. BEARER, 1, true))
      assert.equals(WIRE_BODY, captured.body)
    end)
  end)
end)
