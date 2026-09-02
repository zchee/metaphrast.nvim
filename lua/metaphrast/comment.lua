local util = require("metaphrast.util")

---@class MetaphrastCommentParts
---@field prefix string
---@field suffix string

---@class MetaphrastCommentLineInfo
---@field indent string
---@field has_comment boolean

local M = {}

---Parse a commentstring into prefix/suffix parts.
---@param commentstring string|nil
---@return MetaphrastCommentParts|nil
function M.parse(commentstring)
  if type(commentstring) ~= "string" then
    return nil
  end
  local prefix, suffix = commentstring:match("^(.*)%%s(.*)$")
  if not prefix then
    return nil
  end
  if prefix == "" and suffix == "" then
    return nil
  end
  return {
    prefix = prefix,
    suffix = suffix,
  }
end

---Strip comment leaders from lines using buffer commentstring.
---@param lines string[]
---@param commentstring string|nil
---@return string[] stripped_lines
---@return MetaphrastCommentLineInfo[]|nil info
---@return MetaphrastCommentParts|nil parts
function M.strip_lines(lines, commentstring)
  local parsed = M.parse(commentstring)
  if not parsed then
    return vim.deepcopy(lines), nil, nil
  end

  local prefix = parsed.prefix
  local suffix = parsed.suffix
  local prefix_trim = vim.trim(prefix)
  local suffix_trim = vim.trim(suffix)
  local prefix_pattern = prefix_trim ~= "" and "^%s*" .. vim.pesc(prefix_trim) .. "%s*" or nil
  local suffix_pattern = suffix_trim ~= "" and "%s*" .. vim.pesc(suffix_trim) .. "%s*$" or nil

  local stripped = {}
  local info = {}

  for i, line in ipairs(lines) do
    local indent, rest = line:match("^(%s*)(.*)$")
    local had_comment = false
    local content = rest

    if prefix_pattern then
      local candidate = content:gsub(prefix_pattern, "", 1)
      if candidate ~= content then
        had_comment = true
        content = candidate
      end
    end

    if suffix_pattern then
      local candidate = content:gsub(suffix_pattern, "", 1)
      if candidate ~= content then
        had_comment = true
        content = candidate
      end
    end

    if had_comment then
      content = vim.trim(content)
      stripped[i] = content
      info[i] = { indent = indent, has_comment = true }
    else
      stripped[i] = line
      info[i] = { indent = indent, has_comment = false }
    end
  end

  return stripped, info, parsed
end

---Reapply comment leaders to translated lines where they originally existed.
---@param translated string|string[]
---@param info MetaphrastCommentLineInfo[]|nil
---@param parts MetaphrastCommentParts|nil
---@return string[]
function M.reapply(translated, info, parts)
  if not info or not parts then
    if type(translated) == "table" then
      return translated
    end
    return util.split_lines(translated)
  end

  local lines = translated
  if type(lines) == "string" then
    lines = util.split_lines(lines)
  end
  ---@cast lines string[]
  local out = {}

  for i, line in ipairs(lines) do
    local meta = info[i]
    if meta and meta.has_comment then
      out[i] = (meta.indent or "") .. parts.prefix .. line .. parts.suffix
    else
      out[i] = line
    end
  end

  return out
end

return M
