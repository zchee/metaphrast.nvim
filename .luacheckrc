std = "luajit"
max_line_length = 120
max_comment_line_length = false
codes = true
self = false

read_globals = { "vim" }

-- Provider modules take the HTTP function as `_http` by convention even though
-- it is used; silence the "used variable with unused hint" warning.
ignore = { "214" }

files["tests/**/*_spec.lua"] = {
  -- Specs monkeypatch vim.* (bo, fn, api, notify) and restore them afterwards.
  globals = { "vim" },
  read_globals = { "describe", "it", "before_each", "after_each", "assert", "pending", "setup", "teardown" },
}

exclude_files = { "vendor/", ".agent/" }
