local M = {}

---Compute the display width of a string (handles multibyte/CJK correctly).
---@param s string
---@return integer
local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end
M.display_width = display_width

---Reports whether trimmed comment content begins with a list/bullet marker.
---A marker line starts a new paragraph so distinct list items are not merged
---into one another when consecutive comment lines are joined.
---@param s string
---@return boolean
function M.is_list_marker(s)
  if s:match("^[%-%*%+]%s") then
    return true
  end
  if s:match("^%d+[%.%)]%s") then
    return true
  end
  return false
end

-- Characters that may not open a line (行頭禁則). Closing brackets, closing
-- quotes and the punctuation that binds to the text before it: Unicode line
-- break classes CL, CP, EX and IS, which every mode of CSS `line-break`
-- prohibits at a line start. The strict-mode extras are deliberately absent —
-- small kana (っゃゅょ…), the prolonged sound mark ー and the iteration marks
-- (々ゝヽ) are breakable under `line-break: normal`, and forcing them onto the
-- previous line only buys shorter lines. ASCII punctuation is absent too: it
-- binds to the word before it without a space, so it never opens a break
-- unit as punctuation — a unit that does start with `.` or `)` is a path or
-- an identifier (`.gitignore`, `.tool_input.file_path`), which may open a
-- line like any other word.
local NO_LINE_START_CHARS =
  "、。，．・：；？！‼⁇⁈⁉゛゜）］｝〕〉》」』】〗〙〟｠｣”’"
local NO_LINE_START = {}
for _, ch in ipairs(vim.fn.split(NO_LINE_START_CHARS, "\\zs")) do
  NO_LINE_START[ch] = true
end

---Reports whether `s` starts with a character that may not open a line.
---Matched on the first character, so a Latin break unit is judged by the
---punctuation it leads with and a wide character by itself.
---@param s string
---@return boolean
function M.is_no_line_start(s)
  if s == "" then
    return false
  end
  return NO_LINE_START[vim.fn.strcharpart(s, 0, 1)] == true
end

---@class MetaphrastFlowSegment
---@field kind "para"|"raw"
---@field text string|nil Paragraph content with intra-paragraph newlines collapsed to spaces.
---@field content string|nil Raw passthrough line content (no comment leader).
---@field indent string Pre-leader indentation captured during stripping.
---@field has_comment boolean Whether the segment originated from comment lines.
---@field width integer|nil Paragraph wrap budget in display columns.
---@field source_count integer|nil Number of source lines merged into the paragraph.

---Group comment-stripped lines into paragraph and raw passthrough segments.
---
---Consecutive non-blank comment lines join into a single paragraph so a soft-
---wrapped sentence is translated as one coherent unit. Blank comment lines and
---list-marker lines break paragraphs, and non-comment lines pass through
---untouched (never merged or translated as prose).
---@param stripped string[]
---@param info MetaphrastCommentLineInfo[]
---@return MetaphrastFlowSegment[] segments
---@return integer para_count
function M.segment(stripped, info)
  local segments = {}
  local para_count = 0
  local current = nil

  local function flush()
    if current then
      para_count = para_count + 1
      segments[#segments + 1] = {
        kind = "para",
        text = table.concat(current.lines, " "),
        indent = current.indent,
        has_comment = true,
        width = current.width,
        source_count = #current.lines,
      }
      current = nil
    end
  end

  for i, content in ipairs(stripped) do
    local meta = info[i] or {}
    local is_comment = meta.has_comment == true
    if not is_comment then
      flush()
      segments[#segments + 1] = {
        kind = "raw",
        content = content,
        indent = meta.indent or "",
        has_comment = false,
      }
    elseif content == "" then
      -- Blank comment line: preserved verbatim and treated as a paragraph break.
      flush()
      segments[#segments + 1] = {
        kind = "raw",
        content = "",
        indent = meta.indent or "",
        has_comment = true,
      }
    else
      if current and M.is_list_marker(content) then
        flush()
      end
      if not current then
        current = { lines = {}, indent = meta.indent or "", width = 0 }
      end
      current.lines[#current.lines + 1] = content
      current.width = math.max(current.width, display_width(content))
    end
  end
  flush()

  return segments, para_count
end

---Wrap text to a target display width.
---
---Latin words break on whitespace; wide (CJK) characters break on character
---boundaries since they carry no inter-word spaces. Widths are measured with
---`strdisplaywidth` so double-width glyphs occupy two columns. Original spacing
---between break units is preserved; runs of whitespace collapse to one space.
---
---A line never opens with a 行頭禁則 character (`is_no_line_start`): the break
---moves back over the offending run so those characters ride on the line
---before it (追い出し). Hanging them past the last column would have been the
---other way out, but every caller wraps to a width it must not exceed — the
---hover to the columns the window has, the comment write-back to the source's
---budget — so the break moves instead of the margin. That is only possible
---while a unit is left behind: when the run reaches back to the line's first
---unit, the plain break stands and the line does open with it, which is the
---best the width allows.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(1, math.floor(width or 80))
  local chars = vim.fn.split(text, "\\zs")
  local units = {}
  -- Collect a word's characters in a table and concatenate once. Appending to
  -- a string instead copies the whole word on every character, which is
  -- quadratic in the word's length: a single 200 KB word cost 1155 ms that way
  -- against 58 ms for prose of the same size.
  local word = {}
  local space_before = false

  local function flush_word()
    if #word > 0 then
      units[#units + 1] = { text = table.concat(word), space_before = space_before }
      word = {}
      space_before = false
    end
  end

  for _, ch in ipairs(chars) do
    if ch == " " or ch == "\t" then
      flush_word()
      space_before = true
    elseif display_width(ch) >= 2 then
      flush_word()
      units[#units + 1] = { text = ch, space_before = space_before }
      space_before = false
    else
      word[#word + 1] = ch
    end
  end
  flush_word()

  if #units == 0 then
    return { "" }
  end

  ---Concatenate `units[from..to]`, restoring one space where one was dropped.
  ---@param from integer
  ---@param to integer
  ---@return string
  local function join(from, to)
    local parts = {}
    for i = from, to do
      if i > from and units[i].space_before then
        parts[#parts + 1] = " "
      end
      parts[#parts + 1] = units[i].text
    end
    return table.concat(parts)
  end

  ---Display width of `units[from..to]` as one line.
  ---@param from integer
  ---@param to integer
  ---@return integer
  local function span_width(from, to)
    local w = 0
    for i = from, to do
      w = w + ((i > from and units[i].space_before) and 1 or 0) + display_width(units[i].text)
    end
    return w
  end

  local lines = {}
  local start = 1
  while start <= #units do
    -- Greedy fill: the last unit that still fits, and always at least one, so
    -- a unit wider than the whole width lands alone rather than never.
    local stop = start
    local line_w = display_width(units[start].text)
    for i = start + 1, #units do
      local sep = units[i].space_before and 1 or 0
      local uw = display_width(units[i].text)
      if line_w + sep + uw > width then
        break
      end
      line_w = line_w + sep + uw
      stop = i
    end
    if stop < #units and M.is_no_line_start(units[stop + 1].text) then
      -- `run_end` is the last unit that may not open a line, `k` the last one
      -- that can stay behind. Moving [k+1, run_end] down only helps while it
      -- fits on one line: otherwise the next line breaks inside the run and
      -- opens with it anyway, and this line was shortened for nothing.
      local run_end = stop + 1
      while run_end < #units and M.is_no_line_start(units[run_end + 1].text) do
        run_end = run_end + 1
      end
      local k = stop
      while k > start and M.is_no_line_start(units[k + 1].text) do
        k = k - 1
      end
      if k > start and span_width(k + 1, run_end) <= width then
        stop = k
      end
    end
    lines[#lines + 1] = join(start, stop)
    start = stop + 1
  end
  return lines
end

return M
