local cache = require("metaphrast.cache")
local cfg = require("metaphrast.config")
local comment = require("metaphrast.comment")
local hover = require("metaphrast.ui.hover")
local http_builder = require("metaphrast.http")
local registry = require("metaphrast.providers")
local textflow = require("metaphrast.textflow")
local ui = require("metaphrast.ui")
local util = require("metaphrast.util")

local provider_deepl = require("metaphrast.providers.deepl")
local provider_echo = require("metaphrast.providers.echo")
local provider_gemini = require("metaphrast.providers.gemini")
local provider_google = require("metaphrast.providers.google")
local provider_google_llm = require("metaphrast.providers.google_llm")
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

local BUILTIN_PROVIDERS = {
  provider_echo,
  provider_google,
  provider_google_llm,
  provider_deepl,
  provider_openai,
  provider_gemini,
  provider_openrouter,
}

---Fill in the built-in providers without disturbing what a user registered.
---
---`setup()` used to reset the registry first, which discarded every provider
---registered through `M.register_provider` -- so whether a user's provider
---survived depended on whether they registered it before or after `setup()`.
---A user registration now wins over a built-in of the same name in either
---order, and the skip report compares tables by identity so a second
---`setup()` (a lazy-loader reload, a re-sourced config) finds the seven
---built-ins already present and says nothing about them.
local function register_builtin()
  local shadowed = {}
  for _, provider in ipairs(BUILTIN_PROVIDERS) do
    local existing = registry.get(provider.name)
    if existing == nil then
      registry.register(provider.name, provider)
    elseif existing ~= provider then
      table.insert(shadowed, provider.name)
    end
  end
  if #shadowed > 0 then
    ui.notify(
      string.format("metaphrast: user registration shadows the built-in provider(s): %s", table.concat(shadowed, ", ")),
      "debug"
    )
  end
end

local DEFAULT_MAX_INSERTED_LINES = 200
local warned_max_inserted_lines = false

---Resolve the write cap, ignoring a value that is not a number.
---
---The cap is compared against a row count, so a string here raised
---`attempt to compare string with number` and the write failed with a
---traceback instead of a refusal. The ignored value is reported once.
---@return integer
local function resolve_max_inserted_lines()
  local configured = M.config.max_inserted_lines
  if type(configured) == "number" then
    return configured
  end
  if configured ~= nil and not warned_max_inserted_lines then
    warned_max_inserted_lines = true
    ui.notify(
      string.format(
        "metaphrast: max_inserted_lines must be a number, got %s; using %d",
        vim.inspect(configured),
        DEFAULT_MAX_INSERTED_LINES
      ),
      "warn"
    )
  end
  return DEFAULT_MAX_INSERTED_LINES
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
  ui.require_snacks()
  register_builtin()
  local merged = cfg.merge(opts)
  local ok, err = validate_provider(merged.provider, merged)
  if not ok then
    ui.notify(string.format("metaphrast: %s; falling back to echo provider", err), "warn")
    merged.provider = "echo"
  end
  M.config = merged
  M.http = http_builder.build(merged.http)
  M.http_async = http_builder.build_async(merged.http)
  cfg.warn_unknown_win_keys(opts and opts.ui and opts.ui.win, ui.notify)
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
    error(string.format("provider %s is not usable: %s", provider_name, err), 0)
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
  -- The request is already bounded by `max_chars`, so a reply orders of
  -- magnitude larger is a provider fault rather than a translation, and every
  -- downstream consumer (wrap, layout, the buffer write) pays for it. Refuse
  -- before `cache.put`, or the fault outlives the call.
  local max_reply = max_chars * 4
  if #translated > max_reply then
    error(
      string.format(
        "provider reply too long (%d chars for a %d-char request > %d); translation discarded",
        #translated,
        #text,
        max_reply
      ),
      0
    )
  end
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
---count mismatch (a provider that reformatted the newlines) every reply
---paragraph is wrapped in turn at the first paragraph slot, so output is never
---silently dropped and no line reaches the buffer without its leader.
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
    -- whole translation at the first paragraph slot, so no content (translation
    -- or surrounding code) is ever silently dropped. Wrap the reply one
    -- paragraph at a time rather than in one block: `textflow.wrap` treats a
    -- newline as an ordinary break unit and hands it back inside a line, and
    -- `try_apply` only discovers it after `comment.reapply` has run, so a
    -- single-block wrap writes the split-off lines with no leader at all.
    local emitted = false
    for _, seg in ipairs(layout.segments) do
      if seg.kind == "raw" then
        content_lines[#content_lines + 1] = seg.content
        out_info[#out_info + 1] = { indent = seg.indent, has_comment = seg.has_comment }
      elseif not emitted then
        emitted = true
        for _, para in ipairs(translated_paras) do
          for _, line in ipairs(textflow.wrap(para, seg.width)) do
            content_lines[#content_lines + 1] = line
            out_info[#out_info + 1] = { indent = seg.indent, has_comment = true }
          end
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

---Analyze the lines that will be translated: leader-stripped text, the
---provider input and the comment layout.
---@param lines string[]
---@param commentstring string|nil
---@return { stripped: string[], info: table|nil, parts: table|nil, layout: table|nil, text: string } analysis
local function analyze_lines(lines, commentstring)
  local stripped, info, parts = comment.strip_lines(lines, commentstring)
  local input, layout = build_comment_input(stripped, info, parts)
  return {
    stripped = stripped,
    info = info,
    parts = parts,
    layout = layout,
    text = input or table.concat(stripped, "\n"),
  }
end

---Render a translation back into buffer lines that carry the source's comment
---leaders and indentation. The single implementation behind every replace.
---@param analysis table Output of `analyze_lines` for the source lines.
---@param translated string
---@return string[] lines
local function render_replacement(analysis, translated)
  local out_lines
  if analysis.layout then
    out_lines = assemble_comment_lines(translated, analysis.layout, analysis.parts)
  else
    out_lines = util.reflow_lines(translated, analysis.stripped)
    if analysis.info and analysis.parts then
      out_lines = comment.reapply(out_lines, analysis.info, analysis.parts)
    end
  end
  if #out_lines == 0 then
    out_lines = { "" }
  end
  return out_lines
end

---Build the hover payload for a translation.
---@param translated string
---@param meta table|nil
---@param analysis table Output of `analyze_lines`.
---@param opts table|nil Translation options (`source_lang`, `target_lang`).
---@return MetaphrastHoverResult result
local function build_result(translated, meta, analysis, opts)
  local display_lines
  if analysis.layout then
    display_lines = util.split_lines(translated)
  else
    display_lines = util.reflow_lines(translated, analysis.stripped)
  end
  return {
    translated = translated,
    display_lines = display_lines,
    meta = meta,
    opts = {
      source_lang = opts and opts.source_lang or M.config.source_lang,
      target_lang = opts and opts.target_lang or M.config.target_lang,
      provider = meta and meta.provider or M.config.provider,
    },
  }
end

---Resolve a buffer argument: nil or 0 means the current buffer.
---@param bufnr integer|nil
---@return integer buffer
local function resolve_buffer(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

---The window that shows `buffer`: the current one when it does, else the first.
---@param buffer integer
---@return integer win
local function window_for(buffer)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == buffer then
    return current
  end
  local win = vim.fn.bufwinid(buffer)
  return win ~= -1 and win or current
end

---Describe a translated buffer region so the hover can replace or
---retranslate exactly what was sent.
---@param buffer integer
---@param mode string|nil Visual mode, nil for a line range.
---@param sr integer 0-based first row.
---@param sc integer|nil
---@param er integer 0-based last row.
---@param ec integer|nil
---@param lines string[] The translated input lines.
---@param to_eol boolean|nil True when a blockwise block runs to every row's own end.
---@return MetaphrastHoverSource source
local function capture_source(buffer, mode, sr, sc, er, ec, lines, to_eol)
  return {
    buf = buffer,
    win = window_for(buffer),
    mode = mode,
    sr = sr,
    sc = sc,
    er = er,
    ec = ec,
    to_eol = to_eol,
    commentstring = vim.bo[buffer] and vim.bo[buffer].commentstring or nil,
    lines = lines,
  }
end

---The only function that turns a translation into a hover window.
---When the hover itself is current (the provider-switch path), the source
---window is re-entered first so the cursor-relative placement sees it.
---@param source MetaphrastHoverSource
---@param result MetaphrastHoverResult
---@param show_opts { focus?: boolean }|nil
---@return boolean shown
local function present(source, result, show_opts)
  local state = hover.debug()
  if state.win and vim.api.nvim_get_current_win() == state.win and vim.api.nvim_win_is_valid(source.win) then
    vim.api.nvim_set_current_win(source.win)
  end
  return ui.show(source, result, show_opts)
end

---Whether a blockwise selection was extended to every row's own end with `$`.
---
---The `'<`/`'>` marks cannot answer this on their own: a fixed-width block wider
---than its end row clamps `'>` to that row's length exactly as `$` does, and
---`curswant` — the one value that separates them — is not carried by the marks
---and has already been reset by the time a `-range` command body runs. So the
---selection is re-entered with `gv` and `winsaveview().curswant` is read, behind
---a guard chain that falls back to the plain clamp (`false`) whenever any link
---fails: the caller's mode is blockwise, the target buffer is current, the
---editor is in normal mode, `gv` succeeds and restores blockwise, the restored
---region spans the same rows, `curswant` is `v:maxcol`, and the raw end-mark
---column reaches the end row's length.
---
---`ec` must be the *raw* `'>` column, read before this runs: `gv` normalises an
---out-of-range end mark to the row end, exactly as Vim's own `check_cursor()`
---does, so a value read afterwards would no longer be the caller's.
---
---Side effects are two `ModeChanged` events (`n:\22` then `\22:n`) per blockwise
---resolution and nothing else — no `CursorMoved`, `WinScrolled` or
---`TextChanged` — so an open hover, which listens on `CursorMoved`,
---`CursorMovedI`, `BufLeave`, `InsertEnter` and `BufWinLeave`, cannot be closed
---by the probe. The mode guard keeps those two events off the charwise and
---linewise paths entirely. The probe is skipped, and the plain clamp used, when
---the target buffer is not current or the editor is not exactly in normal mode;
---the latter includes a `<Cmd>` mapping invoked straight from visual mode.
---
---Residual (risk R11): a caller that sets `'<`/`'>` programmatically with a raw
---end column at or past the end row's byte length, in a buffer whose last real
---visual selection was a `$` block, still resolves `true` here — `gv` reports
---blockwise with a stale `curswant` and the last guard cannot separate it from a
---genuine `$`. Its failure mode is a silent wrong write, not a refusal: every
---row longer than the end row loses its tail. No interactive path reaches it,
---because a real `<Esc>` refreshes the marks and the stored selection together,
---and a row cross-check does not help — `gv` restores the region from the marks,
---so the rows always agree.
---@param bufnr integer
---@param mode string Visual mode the caller resolved.
---@param sr integer 0-indexed first row.
---@param er integer 0-indexed last row.
---@param ec integer 0-indexed raw `'>` column, before any clamping.
---@param end_line string Text of the end row.
---@return boolean to_eol
local function block_is_to_eol(bufnr, mode, sr, er, ec, end_line)
  if mode ~= "\22" and mode ~= "" then
    return false
  end
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end
  if vim.fn.mode() ~= "n" then
    return false
  end
  local view = vim.fn.winsaveview()
  local to_eol = false
  if pcall(vim.cmd, "normal! gv") and vim.fn.mode() == "\22" then
    -- The row cross-check is defensive only: `gv` restores the region from the
    -- marks, so today the rows always agree. It costs nothing and would catch a
    -- future `gv` that restored the region from the stored selection instead.
    local anchor, cursor = vim.fn.line("v"), vim.fn.line(".")
    local rows_match = math.min(anchor, cursor) - 1 == sr and math.max(anchor, cursor) - 1 == er
    to_eol = rows_match and vim.fn.winsaveview().curswant == vim.v.maxcol and ec >= #end_line
  end
  if vim.fn.mode() ~= "n" then
    vim.cmd("normal! \27")
  end
  vim.fn.winrestview(view)
  return to_eol
end

---Get visual selection positions from marks.
---@param bufnr integer
---@param mode string Visual mode character: "v", "V", or "\22" (blockwise).
---@return integer start_row 0-indexed
---@return integer start_col 0-indexed
---@return integer end_row 0-indexed
---@return integer end_col 0-indexed (exclusive)
---@return boolean to_eol True when a blockwise block was `$`-extended to every row's own end.
local function get_visual_positions(bufnr, mode)
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
  local sr = start_pos[1] - 1
  local sc = start_pos[2]
  local er = end_pos[1] - 1
  local ec = end_pos[2]
  local to_eol = false

  if mode == "V" then
    sc = 0
    local end_line_text = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ""
    ec = #end_line_text
  elseif mode == "\22" or mode == "" then
    -- Blockwise: `sc`/`ec` are shared by every row and `block_columns` snaps
    -- both ends against the row it is resolving, so widening them here against
    -- the start and end rows would move the block's edges on all the others.
    -- End col from the mark is inclusive; make it exclusive and leave it raw.
    local end_line_text = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ""
    -- Probed with the marks as read above and before `ec` is clamped, because
    -- `gv` normalises an out-of-range end mark to the row end.
    to_eol = block_is_to_eol(bufnr, mode, sr, er, ec, end_line_text)
    if ec >= #end_line_text then
      ec = #end_line_text
    else
      ec = ec + 1
    end
  else
    -- For charwise, end col from mark is inclusive; make it exclusive. The
    -- mark holds the *first* byte of the last selected character, so `ec + 1`
    -- alone would cut a multibyte sequence apart; widen to the end of that
    -- codepoint instead. `sc` is snapped back the same way so the start of the
    -- selection is never mid-sequence either. Only one row is sliced by these
    -- two columns, so there is no other row for them to widen.
    local start_line_text = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ""
    if sc > 0 and sc < #start_line_text then
      sc = sc + vim.str_utf_start(start_line_text, sc + 1)
    end
    local end_line_text = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ""
    if ec >= #end_line_text then
      ec = #end_line_text
    else
      ec = ec + 1 + vim.str_utf_end(end_line_text, ec + 1)
    end
  end

  return sr, sc, er, ec, to_eol
end

---Resolve a blockwise selection's columns against one row.
---
---`sc`/`ec` come from the visual marks, so on a row shorter than the block they
---point past the end, and a block whose last row is short yields `ec < sc` —
---which would make `sub(1, cstart)` and `sub(cend + 1)` overlap and duplicate
---the bytes between them. Both ends are clamped to the row, and whether the row
---clamped to nothing is decided *before* either end is widened to a whole
---codepoint: an emptied region returns `cstart, cstart` (only `cstart` moves,
---because it is still an insertion point), since letting `cend` widen past it
---would pull a codepoint back into the region and delete it from the row. A row
---with content has both ends widened, so a block over multibyte text never
---sends a split UTF-8 sequence to the provider nor writes one back.
---
---A `$`-extended block has no shared end column at all: every row runs to its
---own end, which is what `to_eol` asks for. It replaces the clamp on `ec` and
---nothing else — the emptiness test and both codepoint snaps still run, so a row
---the start column already clamps to nothing stays empty.
---@param line string
---@param sc integer 0-indexed start col.
---@param ec integer 0-indexed end col (exclusive).
---@param to_eol boolean|nil When true the block runs to this row's own end (`$`).
---@return integer cstart 0-indexed byte offset where the block starts.
---@return integer cend 0-indexed byte offset just past the block's last byte.
local function block_columns(line, sc, ec, to_eol)
  local cstart = math.min(sc, #line)
  local cend = to_eol and #line or math.min(ec, #line)
  -- Whether the row clamped to nothing is decided before either end moves:
  -- widening `cstart` back and `cend` forward pulls a whole codepoint into a
  -- region the clamp had just emptied, deleting it from the row.
  local empty = cend <= cstart
  if cstart > 0 and cstart < #line then
    cstart = cstart + vim.str_utf_start(line, cstart + 1)
  end
  if empty then
    return cstart, cstart
  end
  if cend > 0 and cend < #line then
    cend = cend + vim.str_utf_end(line, cend)
  end
  return cstart, cend
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
---@param to_eol boolean|nil True when a blockwise block runs to every row's own end.
---@return string[] selected_lines
local function extract_selection_lines(bufnr, mode, sr, sc, er, ec, to_eol)
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
      local cstart, cend = block_columns(line, sc, ec, to_eol)
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
---
---A blockwise replacement can render more lines than the block has rows: the
---comment layout re-wraps the merged paragraph to the block's width. Those
---surplus lines are appended to the same `nvim_buf_set_lines` call, so they land
---directly under the block in one undo step instead of being dropped. Each one
---is indented to the block's left edge: verbatim when the text left of the block
---is whitespace (tabs and indent style survive), otherwise spaces of the same
---display width, because copying code from the left would duplicate a statement.
---@param bufnr integer
---@param mode string
---@param sr integer 0-indexed start row.
---@param sc integer 0-indexed start col.
---@param er integer 0-indexed end row.
---@param ec integer 0-indexed end col (exclusive).
---@param replacement string
---@param to_eol boolean|nil True when a blockwise block runs to every row's own end.
local function replace_selection_text(bufnr, mode, sr, sc, er, ec, replacement, to_eol)
  local rep_lines = util.split_lines(replacement)

  if mode == "V" then
    vim.api.nvim_buf_set_lines(bufnr, sr, er + 1, false, rep_lines)
    return
  end

  local block = (mode == "\22" or mode == "")
  if block then
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
    local rows = #buf_lines
    -- Captured before the loop rewrites it, so the pad reflects the source row.
    local last_line = buf_lines[rows] or ""
    for i, line in ipairs(buf_lines) do
      local cstart, cend = block_columns(line, sc, ec, to_eol)
      local rep = rep_lines[i] or ""
      buf_lines[i] = line:sub(1, cstart) .. rep .. line:sub(cend + 1)
    end
    if #rep_lines > rows then
      local cstart = block_columns(last_line, sc, ec, to_eol)
      local left = last_line:sub(1, cstart)
      local pad = left
      if left:match("%S") then
        -- `strdisplaywidth` resolves tabs against the *current* buffer's
        -- 'tabstop', and `bufnr` need not be current (the hover float is, on
        -- the `r` path), so measure the left part inside the target buffer.
        local width = vim.api.nvim_buf_call(bufnr, function()
          return vim.fn.strdisplaywidth(left)
        end)
        pad = string.rep(" ", width)
      end
      for i = rows + 1, #rep_lines do
        -- A blank rendered line stays blank: there is nothing to align under,
        -- and a pad-only line is trailing whitespace the user did not write.
        buf_lines[#buf_lines + 1] = rep_lines[i] ~= "" and (pad .. rep_lines[i]) or ""
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, sr, er + 1, false, buf_lines)
    return
  end

  -- Charwise: use nvim_buf_set_text for precise replacement.
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, rep_lines)
end

---Whether `source` describes a partial-line (charwise or blockwise) selection.
---@param source MetaphrastHoverSource
---@return boolean
local function is_partial_selection(source)
  return source.mode ~= nil and source.mode ~= "V"
end

---Write a translation back over the region described by `source`, or explain
---why not. The region is re-read and compared with the lines that were
---translated; on a mismatch nothing is written.
---@param source MetaphrastHoverSource
---@param translated string
---@return boolean replaced
---@return string|nil reason User-facing message when nothing was written.
local function try_apply(source, translated)
  local buffer = source and source.buf
  if not (buffer and vim.api.nvim_buf_is_valid(buffer)) then
    return false, "metaphrast: source buffer is gone; translation not applied"
  end
  local current
  if is_partial_selection(source) then
    current = extract_selection_lines(buffer, source.mode, source.sr, source.sc, source.er, source.ec, source.to_eol)
  else
    current = vim.api.nvim_buf_get_lines(buffer, source.sr, source.er + 1, false)
  end
  if not vim.deep_equal(current, source.lines) then
    return false, "metaphrast: source text changed since it was translated; translation not applied"
  end
  local out_lines = render_replacement(analyze_lines(source.lines, source.commentstring), translated)
  -- A rendered entry can itself carry newlines a provider put there, so flatten
  -- the whole reply once here: `nvim_buf_set_lines` rejects an item containing
  -- one, and the blockwise cap below has to count the lines that really land.
  local rendered = table.concat(out_lines, "\n")
  local flat_lines = util.split_lines(rendered)
  -- Every write path inserts the rendered lines past the source's row count,
  -- and that count comes from the provider's reply, so bound it here rather
  -- than inside one selection shape: a runaway reply floods a linewise or
  -- charwise write exactly as it floods a blockwise one. Refusing beats
  -- truncating: no content is dropped without saying so.
  local rendered_rows = #flat_lines
  local rows = #source.lines
  local limit = resolve_max_inserted_lines()
  if rendered_rows - rows > limit then
    return false,
      string.format(
        "metaphrast: translation rendered %d lines for %d source lines, over "
          .. "max_inserted_lines (%d); translation not applied",
        rendered_rows,
        rows,
        limit
      )
  end
  if is_partial_selection(source) then
    replace_selection_text(buffer, source.mode, source.sr, source.sc, source.er, source.ec, rendered, source.to_eol)
  else
    vim.api.nvim_buf_set_lines(buffer, source.sr, source.er + 1, false, flat_lines)
  end
  return true
end

---Write a translation back over the region described by `source`.
---The region is re-read and compared with the lines that were translated;
---on a mismatch nothing is written and an error toast explains why.
---@param source MetaphrastHoverSource
---@param translated string
---@return boolean replaced
function M.apply_result(source, translated)
  local ok, reason = try_apply(source, translated)
  if not ok then
    ---@cast reason string
    ui.notify(reason, "error")
  end
  return ok
end

---Deliver a finished translation: replace the source, show the hover, or
---echo it, depending on `opts`. A refused write-back is toasted here so the
---public API paths stay diagnosable; `opts.quiet` suppresses that toast for
---callers that report the reason themselves (`command()` finishes its own
---progress toast with it, and a second toast would double-report).
---@param source MetaphrastHoverSource
---@param translated string
---@param meta table|nil
---@param analysis table
---@param opts table|nil
---@return string rendered
---@return boolean|nil applied True when written back, false when refused, nil when no write-back was requested.
---@return string|nil reason Why the write-back was refused.
local function deliver(source, translated, meta, analysis, opts)
  local should_replace = opts and opts.replace
  if should_replace == nil then
    should_replace = M.config.replace
  end
  local result = build_result(translated, meta, analysis, opts)
  local rendered = table.concat(result.display_lines, "\n")
  if should_replace then
    local applied, reason = try_apply(source, translated)
    if applied == false and not (opts and opts.quiet) then
      ---@cast reason string
      ui.notify(reason, "error")
    end
    return analysis.layout and translated or rendered, applied, reason
  end
  if opts and opts.show_window then
    present(source, result, {})
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
---@return string rendered
---@return boolean|nil applied False when a requested write-back was refused.
---@return string|nil reason Why the write-back was refused.
function M.translate_range(bufnr, start_line, end_line, opts)
  local buffer = resolve_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(buffer, start_line, end_line, false)
  local source = capture_source(buffer, nil, start_line, nil, start_line + #lines - 1, nil, lines)
  local analysis = analyze_lines(lines, source.commentstring)
  local translated, meta = M.translate(analysis.text, opts)
  local rendered, applied, reason = deliver(source, translated, meta, analysis, opts)
  return rendered or translated, applied, reason
end

-- Reported when the selection holds nothing translatable. It travels the same
-- `applied == false` + reason channel a refused write-back uses, so callers do
-- not mistake the skip for a success; `command()` tells the two apart by this
-- exact string and warns rather than errors, because a no-op is not a failure.
local NOTHING_TO_TRANSLATE = "metaphrast: nothing to translate in the selection"

---Translate visually selected text.
---@param bufnr integer|nil
---@param mode string Visual mode: "v", "V", or "\22".
---@param opts table|nil
---@return string translated
---@return boolean|nil applied False when the write-back was refused or the selection was blank.
---@return string|nil reason Why nothing was written.
function M.translate_selection(bufnr, mode, opts)
  local buffer = resolve_buffer(bufnr)
  local sr, sc, er, ec, to_eol = get_visual_positions(buffer, mode)
  local selected_lines = extract_selection_lines(buffer, mode, sr, sc, er, ec, to_eol)
  local source = capture_source(buffer, mode, sr, sc, er, ec, selected_lines, to_eol)
  local analysis = analyze_lines(selected_lines, source.commentstring)
  -- A block clamped to nothing on every row leaves only newlines, which is not
  -- `""`; sending it would bill a provider for nothing and write the reply
  -- into a line the user never selected.
  if analysis.text:match("^%s*$") then
    return "", false, NOTHING_TO_TRANSLATE
  end

  local translated, meta = M.translate(analysis.text, opts)
  local _, applied, reason = deliver(source, translated, meta, analysis, opts)
  return translated, applied, reason
end

---Translate visually selected text asynchronously.
---`on_success` receives `applied = false` and the reason when a requested
---write-back was refused or when the selection contained nothing to translate.
---@param bufnr integer|nil
---@param mode string Visual mode: "v", "V", or "\22".
---@param opts table|nil
---@param callbacks {on_success?:fun(result:string, meta:table, applied?:boolean, reason?:string), on_error?:fun(err:any)}|nil
function M.translate_selection_async(bufnr, mode, opts, callbacks)
  local buffer = resolve_buffer(bufnr)
  local sr, sc, er, ec, to_eol = get_visual_positions(buffer, mode)
  local selected_lines = extract_selection_lines(buffer, mode, sr, sc, er, ec, to_eol)
  local source = capture_source(buffer, mode, sr, sc, er, ec, selected_lines, to_eol)
  local analysis = analyze_lines(selected_lines, source.commentstring)
  local cb = callbacks or {}
  if analysis.text:match("^%s*$") then
    if cb.on_success then
      vim.schedule(function()
        local meta = { cached = false, provider = M.config.provider, icon = M.config.icon }
        cb.on_success("", meta, false, NOTHING_TO_TRANSLATE)
      end)
    end
    return
  end

  M.translate_async(analysis.text, opts, {
    on_success = function(translated, meta)
      local _, applied, reason = deliver(source, translated, meta, analysis, opts)
      if cb.on_success then
        cb.on_success(translated, meta, applied, reason)
      end
    end,
    on_error = function(err)
      if cb.on_error then
        cb.on_error(err)
      end
    end,
  })
end

---Translate `source.lines` again, typically with another provider, and show
---the result focused. Used by the hover's provider key.
---@param source MetaphrastHoverSource
---@param opts { provider?: string, source_lang?: string, target_lang?: string }|nil
function M.retranslate(source, opts)
  opts = opts or {}
  local provider_name = opts.provider or M.config.provider
  local ok, err = validate_provider(provider_name, M.config)
  if not ok then
    ui.notify(string.format("metaphrast: %s", err), "error")
    hover.refocus()
    return
  end
  local previous = hover.debug().result
  local previous_opts = previous and previous.opts or {}
  local translate_opts = {
    provider = provider_name,
    source_lang = opts.source_lang or previous_opts.source_lang,
    target_lang = opts.target_lang or previous_opts.target_lang or M.config.target_lang,
  }
  local analysis = analyze_lines(source.lines, source.commentstring)
  local done = ui.progress("Translating...")
  M.translate_async(analysis.text, translate_opts, {
    on_success = function(translated, meta)
      local suffix = meta and meta.cached and " (cache)" or ""
      done(string.format("Translated via %s%s", meta and meta.provider or provider_name, suffix), "info")
      present(source, build_result(translated, meta, analysis, translate_opts), { focus = true })
    end,
    on_error = function(e)
      done()
      ui.notify("Translation failed: " .. tostring(e), "error")
      hover.refocus()
    end,
  })
end

---LSP-hover style entry point: focus the hover open for this buffer, or
---translate the cursor line into a new one. A no-op from inside the hover.
function M.hover()
  local state = hover.debug()
  if state.win and vim.api.nvim_get_current_win() == state.win then
    return
  end
  if hover.is_open_for(0) then
    hover.focus()
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  -- A hover key never writes into the buffer, whatever `config.replace` says.
  M.command({ range = 0, line1 = line, line2 = line, fargs = {}, bang = false, replace = false })
end

---Run a translation from `:MetaphrastTranslate` or `hover()`.
---Without a range and with a hover already open for the buffer it focuses
---that hover; the bang instead closes it and writes back. `opts.replace`,
---when given, overrides both the bang and `config.replace`.
---@param opts table Command opts (`range`, `line1`, `line2`, `fargs`, `bang`, `visual_mode`) plus `replace`.
function M.command(opts)
  if (opts.range or 0) == 0 and hover.is_open_for(0) then
    if not opts.bang then
      hover.focus()
      return
    end
    -- The bang overwrites the very lines the open hover translated, so its
    -- source is about to go stale; close it rather than leave it showing a
    -- translation of text that is no longer in the buffer.
    hover.close()
  end
  local args = opts.fargs or {}
  local source
  local target
  if #args == 1 then
    target = args[1]
  elseif #args >= 2 then
    source = args[1]
    target = args[2]
  end

  local replace = opts.replace
  if replace == nil then
    replace = opts.bang or M.config.replace
  end
  local vmode = opts.visual_mode
  local start_line = (opts.line1 or 1) - 1
  local end_line = opts.line2 or vim.api.nvim_buf_line_count(0)

  local function run_with_target(target_lang)
    if not target_lang or target_lang == "" then
      ui.notify("metaphrast: target language required", "warn")
      return
    end
    local done = ui.progress("Translating...")
    local translate_opts = {
      source_lang = source,
      target_lang = target_lang,
      replace = replace,
      show_window = not replace,
      -- A refusal is reported on the progress id below, not as a second toast.
      quiet = true,
    }
    local callbacks = {
      on_success = function(_, meta, applied, reason)
        if applied == false then
          -- A blank selection is a no-op, not a failure: nothing was refused
          -- and nothing was lost, so it warns where a refused write errors.
          done(reason, reason == NOTHING_TO_TRANSLATE and "warn" or "error")
          return
        end
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
      ui.notify("metaphrast: target language required", "warn")
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

---Translate a line range asynchronously. `on_success` receives
---`applied = false` and the reason when a requested write-back was refused.
---@param bufnr integer|nil
---@param start_line integer
---@param end_line integer
---@param opts table|nil
---@param callbacks {on_success?:fun(result:string, meta:table, applied?:boolean, reason?:string), on_error?:fun(err:any)}|nil
function M.translate_range_async(bufnr, start_line, end_line, opts, callbacks)
  local buffer = resolve_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(buffer, start_line, end_line, false)
  local source = capture_source(buffer, nil, start_line, nil, start_line + #lines - 1, nil, lines)
  local analysis = analyze_lines(lines, source.commentstring)
  local cb = callbacks or {}
  M.translate_async(analysis.text, opts, {
    on_success = function(translated, meta)
      local rendered, applied, reason = deliver(source, translated, meta, analysis, opts)
      if cb.on_success then
        cb.on_success(rendered or translated, meta, applied, reason)
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

-- Test helper: the blockwise column resolver, exposed so its boundary cases
-- (clamped-empty rows, codepoint snapping at both ends) can be asserted
-- directly instead of only end to end.
M._block_columns = block_columns

-- Test helper
function M._reset_for_tests()
  M.config = cfg.defaults()
  cfg._reset_for_tests()
  warned_max_inserted_lines = false
  -- The isolation boundary between specs: `register_builtin` no longer resets,
  -- so a provider one spec registered would otherwise leak into the next.
  registry.reset()
  register_builtin()
  M.http = http_builder.build(M.config.http)
  M.http_async = http_builder.build_async(M.config.http)
  cache.clear(M.config.cache)
  ui._reset_for_tests()
end

return M
