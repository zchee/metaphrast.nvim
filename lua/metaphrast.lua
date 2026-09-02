local cache = require("metaphrast.cache")
local cfg = require("metaphrast.config")
local comment = require("metaphrast.comment")
local http_builder = require("metaphrast.http")
local registry = require("metaphrast.providers")
local textflow = require("metaphrast.textflow")
local ui = require("metaphrast.ui")
local util = require("metaphrast.util")

local provider_deepl = require("metaphrast.providers.deepl")
local provider_echo = require("metaphrast.providers.echo")
local provider_gemini = require("metaphrast.providers.gemini")
local provider_google = require("metaphrast.providers.google")
local provider_openai = require("metaphrast.providers.openai")
local provider_openrouter = require("metaphrast.providers.openrouter")

---@class Metaphrast
---@field config MetaphrastConfig
---@field http fun(method: string, url: string, opts: table): table
---@field http_async fun(method: string, url: string, opts: table): table
local M = {
  config = cfg.defaults(),
}

M.http = http_builder.build(M.config.http)
M.http_async = http_builder.build_async(M.config.http)

local function register_builtin()
  registry.reset()
  registry.register(provider_echo.name, provider_echo)
  registry.register(provider_google.name, provider_google)
  registry.register(provider_deepl.name, provider_deepl)
  registry.register(provider_openai.name, provider_openai)
  registry.register(provider_gemini.name, provider_gemini)
  registry.register(provider_openrouter.name, provider_openrouter)
end

local function validate_provider(name, config_table)
  local provider = registry.get(name)
  if not provider then
    return false, "provider not found: " .. name
  end
  if provider.validate then
    return provider.validate(config_table.providers[name] or {})
  end
  return true
end

---@param opts table|nil
function M.setup(opts)
  register_builtin()
  local merged = cfg.merge(opts)
  local ok, err = validate_provider(merged.provider, merged)
  if not ok then
    vim.notify(string.format("metaphrast: %s; falling back to echo provider", err), vim.log.levels.WARN)
    merged.provider = "echo"
  end
  M.config = merged
  M.http = http_builder.build(merged.http)
  M.http_async = http_builder.build_async(merged.http)
  ui.set_defaults(merged.ui and merged.ui.win or {})
end

local function perform_translate(http_fn, text, opts)
  assert(type(text) == "string", "text must be a string")
  if text == "" then
    return "", { cached = false, provider = M.config.provider, icon = M.config.icon }
  end
  local options = opts or {}
  local config_table = M.config
  local provider_name = options.provider or config_table.provider
  local provider_icon = options.icon or config_table.icon
  local ok, err = validate_provider(provider_name, config_table)
  if not ok then
    vim.notify(string.format("metaphrast: %s; using echo provider", err), vim.log.levels.WARN)
    provider_name = "echo"
    config_table.provider = provider_name
  end
  local target_lang = options.target_lang or config_table.target_lang
  local source_lang = options.source_lang or config_table.source_lang
  local max_chars = config_table.max_chars or 8000
  if #text > max_chars then
    error(string.format("text too long (%d chars > %d)", #text, max_chars))
  end
  local payload = {
    text = text,
    target_lang = target_lang,
    source_lang = source_lang,
    config = config_table,
  }
  local estimated = registry.estimate_cost(provider_name, payload)
  if estimated and config_table.cache.max_estimated_cost and estimated > config_table.cache.max_estimated_cost then
    error(
      string.format(
        "estimated cost %.4f USD exceeds limit %.2f; shorten text or adjust config.cache.max_estimated_cost",
        estimated,
        config_table.cache.max_estimated_cost
      )
    )
  end

  local key = cache.make_key(provider_name, source_lang, target_lang, text)
  local cached = cache.get(config_table.cache, key)
  if cached then
    local cleaned_cached = util.normalize_newlines(cached)
    if cleaned_cached ~= cached then
      cache.put(config_table.cache, key, cleaned_cached)
    end
    return cleaned_cached, { cached = true, provider = provider_name, icon = provider_icon }
  end

  local translated = registry.translate(provider_name, http_fn, payload)
  translated = util.normalize_newlines(translated)
  cache.put(config_table.cache, key, translated)
  return translated, { cached = false, provider = provider_name, icon = provider_icon }
end

---Build the coherent translation input for a comment selection.
---
---Returns the text to send to the provider (paragraphs joined by newlines, with
---intra-paragraph soft wraps collapsed to spaces) plus a layout describing how
---to lay the translation back out. Returns nil when the lines carry no comment
---structure, signalling callers to use the legacy line-preserving path.
---@param stripped string[]
---@param info MetaphrastCommentLineInfo[]|nil
---@param parts MetaphrastCommentParts|nil
---@return string|nil input
---@return table|nil layout
local function build_comment_input(stripped, info, parts)
  if not (info and parts) then
    return nil, nil
  end
  local segments, para_count = textflow.segment(stripped, info)
  if para_count == 0 then
    return nil, nil
  end
  local paragraphs = {}
  for _, seg in ipairs(segments) do
    if seg.kind == "para" then
      paragraphs[#paragraphs + 1] = seg.text
    end
  end
  return table.concat(paragraphs, "\n"), { segments = segments, para_count = para_count }
end

---Lay a coherent translation back into commented buffer lines.
---
---Each translated paragraph is re-wrapped to its source column budget (single-
---source-line paragraphs are kept on one line), raw passthrough lines are
---preserved, and comment leaders are reapplied per output line. On a paragraph
---count mismatch (a provider that reformatted the newlines) the whole
---translation is wrapped as a single block so output is never silently dropped.
---@param translated string
---@param layout table
---@param parts MetaphrastCommentParts
---@return string[]
local function assemble_comment_lines(translated, layout, parts)
  -- Drop any spurious trailing newline a provider appended so the paragraph
  -- count still matches and well-behaved multi-paragraph mapping is preserved.
  local translated_paras = util.split_lines((translated:gsub("\n+$", "")))
  local content_lines = {}
  local out_info = {}

  if #translated_paras ~= layout.para_count then
    -- A provider reformatted the paragraph newlines so we can no longer map
    -- each paragraph back. Preserve raw passthrough lines in place and emit the
    -- whole translation as one wrapped block at the first paragraph slot, so no
    -- content (translation or surrounding code) is ever silently dropped.
    local emitted = false
    for _, seg in ipairs(layout.segments) do
      if seg.kind == "raw" then
        content_lines[#content_lines + 1] = seg.content
        out_info[#out_info + 1] = { indent = seg.indent, has_comment = seg.has_comment }
      elseif not emitted then
        emitted = true
        for _, line in ipairs(textflow.wrap(translated, seg.width)) do
          content_lines[#content_lines + 1] = line
          out_info[#out_info + 1] = { indent = seg.indent, has_comment = true }
        end
      end
    end
    return comment.reapply(content_lines, out_info, parts)
  end

  local idx = 0
  for _, seg in ipairs(layout.segments) do
    if seg.kind == "raw" then
      content_lines[#content_lines + 1] = seg.content
      out_info[#out_info + 1] = { indent = seg.indent, has_comment = seg.has_comment }
    else
      idx = idx + 1
      local para_text = translated_paras[idx] or ""
      local wrapped
      if (seg.source_count or 1) <= 1 then
        wrapped = { para_text }
      else
        wrapped = textflow.wrap(para_text, seg.width)
      end
      for _, line in ipairs(wrapped) do
        content_lines[#content_lines + 1] = line
        out_info[#out_info + 1] = { indent = seg.indent, has_comment = true }
      end
    end
  end

  return comment.reapply(content_lines, out_info, parts)
end

local function apply_translation_output(
  buffer,
  start_line,
  end_line,
  translated,
  opts,
  meta,
  info,
  parts,
  original_lines,
  layout
)
  local should_replace = opts and opts.replace or M.config.replace
  local translated_lines
  if original_lines and #original_lines > 0 then
    translated_lines = util.reflow_lines(translated, original_lines)
  else
    translated_lines = util.split_lines(translated)
  end
  local rendered = table.concat(translated_lines, "\n")
  local config_win = (M.config.ui and M.config.ui.win) or {}
  local user_win = (opts and opts.win) or {}
  local merged_win = vim.tbl_deep_extend("force", {}, config_win, user_win)

  if should_replace then
    local new_lines
    if layout then
      new_lines = assemble_comment_lines(translated, layout, parts)
      rendered = translated
    else
      if parts and info then
        translated_lines = comment.reapply(translated_lines, info, parts)
      end
      new_lines = translated_lines
    end
    if #new_lines == 0 then
      new_lines = { "" }
    end
    vim.api.nvim_buf_set_lines(buffer, start_line, end_line, false, new_lines)
    return rendered
  end

  if layout then
    rendered = translated
  end

  if opts and opts.show_window then
    ui.show_window(rendered, meta, {
      target_lang = opts.target_lang or M.config.target_lang,
      source_lang = opts.source_lang or M.config.source_lang,
      win = merged_win,
      padding = merged_win and merged_win.padding or nil,
    })
    return rendered
  end

  vim.api.nvim_echo({ { rendered, "Normal" } }, false, {})
  return rendered
end

---@param text string
---@param opts table|nil
---@return string, table|nil
function M.translate(text, opts)
  local translated, meta = perform_translate(M.http, text, opts)
  return translated, meta
end

---@param bufnr integer|nil
---@param start_line integer
---@param end_line integer
---@param opts table|nil
---@return string
function M.translate_range(bufnr, start_line, end_line, opts)
  local buffer = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buffer, start_line, end_line, false)
  local stripped, info, parts = comment.strip_lines(lines, vim.bo[buffer] and vim.bo[buffer].commentstring or nil)
  local input, layout = build_comment_input(stripped, info, parts)
  local joined = input or table.concat(stripped, "\n")
  local translated, meta = M.translate(joined, opts)
  local rendered =
    apply_translation_output(buffer, start_line, end_line, translated, opts, meta, info, parts, stripped, layout)
  return rendered or translated
end

---Get visual selection positions from marks.
---@param bufnr integer
---@param mode string Visual mode character: "v", "V", or "\22" (blockwise).
---@return integer start_row 0-indexed
---@return integer start_col 0-indexed
---@return integer end_row 0-indexed
---@return integer end_col 0-indexed (exclusive)
local function get_visual_positions(bufnr, mode)
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
  local sr = start_pos[1] - 1
  local sc = start_pos[2]
  local er = end_pos[1] - 1
  local ec = end_pos[2]

  if mode == "V" then
    sc = 0
    local end_line_text = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ""
    ec = #end_line_text
  else
    -- For charwise and blockwise, end col from mark is inclusive; make it exclusive.
    local end_line_text = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ""
    if ec >= #end_line_text then
      ec = #end_line_text
    else
      ec = ec + 1
    end
  end

  return sr, sc, er, ec
end

---Extract selected lines from a buffer based on visual mode and positions.
---Returns the lines as an array so callers can perform per-line processing
---(e.g. commentstring stripping) before joining.
---@param bufnr integer
---@param mode string
---@param sr integer 0-indexed start row.
---@param sc integer 0-indexed start col.
---@param er integer 0-indexed end row.
---@param ec integer 0-indexed end col (exclusive).
---@return string[] selected_lines
local function extract_selection_lines(bufnr, mode, sr, sc, er, ec)
  local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
  if #lines == 0 then
    return {}
  end

  if mode == "V" then
    return lines
  end

  local block = (mode == "\22" or mode == "")
  if block then
    local parts = {}
    for _, line in ipairs(lines) do
      local cstart = math.min(sc, #line)
      local cend = math.min(ec, #line)
      table.insert(parts, line:sub(cstart + 1, cend))
    end
    return parts
  end

  -- Charwise
  if sr == er then
    return { lines[1]:sub(sc + 1, ec) }
  end
  local parts = {}
  table.insert(parts, lines[1]:sub(sc + 1))
  for i = 2, #lines - 1 do
    table.insert(parts, lines[i])
  end
  table.insert(parts, lines[#lines]:sub(1, ec))
  return parts
end

---Replace the selected text in a buffer.
---@param bufnr integer
---@param mode string
---@param sr integer 0-indexed start row.
---@param sc integer 0-indexed start col.
---@param er integer 0-indexed end row.
---@param ec integer 0-indexed end col (exclusive).
---@param replacement string
local function replace_selection_text(bufnr, mode, sr, sc, er, ec, replacement)
  local rep_lines = util.split_lines(replacement)

  if mode == "V" then
    vim.api.nvim_buf_set_lines(bufnr, sr, er + 1, false, rep_lines)
    return
  end

  local block = (mode == "\22" or mode == "")
  if block then
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
    for i, line in ipairs(buf_lines) do
      local cstart = math.min(sc, #line)
      local cend = math.min(ec, #line)
      local rep = rep_lines[i] or ""
      buf_lines[i] = line:sub(1, cstart) .. rep .. line:sub(cend + 1)
    end
    vim.api.nvim_buf_set_lines(bufnr, sr, er + 1, false, buf_lines)
    return
  end

  -- Charwise: use nvim_buf_set_text for precise replacement.
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, rep_lines)
end

---Translate visually selected text.
---@param bufnr integer|nil
---@param mode string Visual mode: "v", "V", or "\22".
---@param opts table|nil
---@return string
function M.translate_selection(bufnr, mode, opts)
  local buffer = bufnr or vim.api.nvim_get_current_buf()
  local sr, sc, er, ec = get_visual_positions(buffer, mode)
  local selected_lines = extract_selection_lines(buffer, mode, sr, sc, er, ec)
  local commentstring = vim.bo[buffer] and vim.bo[buffer].commentstring or nil
  local stripped_lines, info, parts = comment.strip_lines(selected_lines, commentstring)
  local input, layout = build_comment_input(stripped_lines, info, parts)
  local text = input or table.concat(stripped_lines, "\n")
  if text == "" then
    return ""
  end

  local translated, meta = M.translate(text, opts)
  local should_replace = opts and opts.replace or M.config.replace

  if should_replace then
    local out_lines
    if layout then
      out_lines = assemble_comment_lines(translated, layout, parts)
    else
      out_lines = util.reflow_lines(translated, stripped_lines)
      if info and parts then
        out_lines = comment.reapply(out_lines, info, parts)
      end
    end
    replace_selection_text(buffer, mode, sr, sc, er, ec, table.concat(out_lines, "\n"))
    return translated
  end

  if opts and opts.show_window then
    local config_win = (M.config.ui and M.config.ui.win) or {}
    local user_win = (opts and opts.win) or {}
    local merged_win = vim.tbl_deep_extend("force", {}, config_win, user_win)
    ui.show_window(translated, meta, {
      target_lang = opts.target_lang or M.config.target_lang,
      source_lang = opts.source_lang or M.config.source_lang,
      win = merged_win,
      padding = merged_win and merged_win.padding or nil,
    })
    return translated
  end

  vim.api.nvim_echo({ { translated, "Normal" } }, false, {})
  return translated
end

---Translate visually selected text asynchronously.
---@param bufnr integer|nil
---@param mode string Visual mode: "v", "V", or "\22".
---@param opts table|nil
---@param callbacks {on_success?:fun(result:string, meta:table), on_error?:fun(err:any)}|nil
function M.translate_selection_async(bufnr, mode, opts, callbacks)
  local buffer = bufnr or vim.api.nvim_get_current_buf()
  local sr, sc, er, ec = get_visual_positions(buffer, mode)
  local selected_lines = extract_selection_lines(buffer, mode, sr, sc, er, ec)
  local commentstring = vim.bo[buffer] and vim.bo[buffer].commentstring or nil
  local stripped_lines, info, parts = comment.strip_lines(selected_lines, commentstring)
  local input, layout = build_comment_input(stripped_lines, info, parts)
  local text = input or table.concat(stripped_lines, "\n")
  if text == "" then
    if callbacks and callbacks.on_success then
      vim.schedule(function()
        callbacks.on_success("", { cached = false, provider = M.config.provider, icon = M.config.icon })
      end)
    end
    return
  end

  local cb = callbacks or {}
  M.translate_async(text, opts, {
    on_success = function(translated, meta)
      local should_replace = opts and opts.replace or M.config.replace
      if should_replace then
        local out_lines
        if layout then
          out_lines = assemble_comment_lines(translated, layout, parts)
        else
          out_lines = util.reflow_lines(translated, stripped_lines)
          if info and parts then
            out_lines = comment.reapply(out_lines, info, parts)
          end
        end
        replace_selection_text(buffer, mode, sr, sc, er, ec, table.concat(out_lines, "\n"))
      elseif opts and opts.show_window then
        local config_win = (M.config.ui and M.config.ui.win) or {}
        local user_win = (opts and opts.win) or {}
        local merged_win = vim.tbl_deep_extend("force", {}, config_win, user_win)
        ui.show_window(translated, meta, {
          target_lang = opts.target_lang or M.config.target_lang,
          source_lang = opts.source_lang or M.config.source_lang,
          win = merged_win,
          padding = merged_win and merged_win.padding or nil,
        })
      else
        vim.api.nvim_echo({ { translated, "Normal" } }, false, {})
      end
      if cb.on_success then
        cb.on_success(translated, meta)
      end
    end,
    on_error = function(err)
      if cb.on_error then
        cb.on_error(err)
      end
    end,
  })
end

---@param opts table command opts
function M.command(opts)
  local args = opts.fargs or {}
  local source
  local target
  if #args == 1 then
    target = args[1]
  elseif #args >= 2 then
    source = args[1]
    target = args[2]
  end

  local replace = opts.bang or M.config.replace
  local vmode = opts.visual_mode
  local start_line = (opts.line1 or 1) - 1
  local end_line = opts.line2 or vim.api.nvim_buf_line_count(0)

  local function run_with_target(target_lang)
    if not target_lang or target_lang == "" then
      ui.notify("metaphrast: target language required", "warn", { title = "Metaphrast" })
      return
    end
    local done = ui.progress("Translating...", { title = "Metaphrast" })
    local translate_opts = {
      source_lang = source,
      target_lang = target_lang,
      replace = replace,
      show_window = not replace,
    }
    local callbacks = {
      on_success = function(_, meta)
        local provider = meta and meta.provider or M.config.provider
        local suffix = meta and meta.cached and " (cache)" or ""
        done(string.format("Translated via %s%s", provider, suffix), "info")
      end,
      on_error = function(err)
        done("Translation failed: " .. tostring(err), "error")
      end,
    }

    if vmode and (vmode == "v" or vmode == "\22" or vmode == "") then
      M.translate_selection_async(0, vmode, translate_opts, callbacks)
    else
      M.translate_range_async(0, start_line, end_line, translate_opts, callbacks)
    end
  end

  local effective_target = target or M.config.target_lang
  if effective_target and effective_target ~= "" then
    run_with_target(effective_target)
    return
  end

  ui.prompt_target(M.config.target_lang, function(value)
    if value and value ~= "" then
      run_with_target(value)
    else
      ui.notify("metaphrast: target language required", "warn", { title = "Metaphrast" })
    end
  end)
end

---@param text string
---@param opts table|nil
---@param callbacks {on_success?:fun(result:string, meta:table), on_error?:fun(err:any)}|nil
function M.translate_async(text, opts, callbacks)
  local cb = callbacks or {}
  local ok_async, async = pcall(require, "plenary.async")
  if not ok_async then
    local ok_sync, res, meta = pcall(perform_translate, M.http, text, opts)
    if ok_sync then
      if cb.on_success then
        vim.schedule(function()
          cb.on_success(res, meta)
        end)
      end
    elseif cb.on_error then
      vim.schedule(function()
        cb.on_error(res)
      end)
    end
    return
  end
  local http_fn = M.http_async or M.http
  async.void(function()
    local ok, result_or_err, meta = pcall(perform_translate, http_fn, text, opts)
    if ok then
      if cb.on_success then
        vim.schedule(function()
          cb.on_success(result_or_err, meta)
        end)
      end
    else
      if cb.on_error then
        vim.schedule(function()
          cb.on_error(result_or_err)
        end)
      end
    end
  end)()
end

---@param bufnr integer|nil
---@param start_line integer
---@param end_line integer
---@param opts table|nil
---@param callbacks {on_success?:fun(result:string, meta:table), on_error?:fun(err:any)}|nil
function M.translate_range_async(bufnr, start_line, end_line, opts, callbacks)
  local buffer = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buffer, start_line, end_line, false)
  local stripped, info, parts = comment.strip_lines(lines, vim.bo[buffer] and vim.bo[buffer].commentstring or nil)
  local input, layout = build_comment_input(stripped, info, parts)
  local joined = input or table.concat(stripped, "\n")
  local cb = callbacks or {}
  M.translate_async(joined, opts, {
    on_success = function(translated, meta)
      local rendered =
        apply_translation_output(buffer, start_line, end_line, translated, opts, meta, info, parts, stripped, layout)
      if cb.on_success then
        cb.on_success(rendered or translated, meta)
      end
    end,
    on_error = function(err)
      if cb.on_error then
        cb.on_error(err)
      end
    end,
  })
end

---@param name string
---@param provider table
function M.register_provider(name, provider)
  registry.register(name, provider)
end

function M.clear_cache()
  cache.clear(M.config.cache)
end

-- Test helper
function M._reset_for_tests()
  M.config = cfg.defaults()
  register_builtin()
  M.http = http_builder.build(M.config.http)
  M.http_async = http_builder.build_async(M.config.http)
  cache.clear(M.config.cache)
end

return M
