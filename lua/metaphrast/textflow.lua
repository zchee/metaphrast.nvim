---@diagnostic disable: undefined-global
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
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(1, math.floor(width or 80))
  local chars = vim.fn.split(text, "\\zs")
  local units = {}
  local word = ""
  local space_before = false

  local function flush_word()
    if word ~= "" then
      units[#units + 1] = { text = word, space_before = space_before }
      word = ""
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
      word = word .. ch
    end
  end
  flush_word()

  if #units == 0 then
    return { "" }
  end

  local lines = {}
  local line = ""
  local line_w = 0
  for _, unit in ipairs(units) do
    local uw = display_width(unit.text)
    local sep = (line_w > 0 and unit.space_before) and 1 or 0
    if line_w > 0 and line_w + sep + uw > width then
      lines[#lines + 1] = line
      line = unit.text
      line_w = uw
    else
      line = line .. (sep == 1 and " " or "") .. unit.text
      line_w = line_w + sep + uw
    end
  end
  lines[#lines + 1] = line
  return lines
end

return M
