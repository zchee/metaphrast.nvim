local M = {}

---@param s string
---@return string
function M.urlencode(s)
  if not s then
    return ""
  end
  s = s:gsub("\n", "\r\n")
  s = s:gsub("([^%w%-%.%_%~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return (s:gsub(" ", "+"))
end

---@param lines string
---@return string[]
function M.split_lines(lines)
  local result = {}
  local text = lines or ""
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(result, line)
  end
  return result
end

---Reflow translated text to match original line structure as closely as possible.
---@param translated string
---@param original_lines string[]
---@return string[]
function M.reflow_lines(translated, original_lines)
  local target_count = #original_lines
  local lines = M.split_lines(translated)
  if target_count == 0 then
    return lines
  end
  if #lines == target_count then
    return lines
  end

  local tokens = {}
  for token in translated:gmatch("%S+") do
    table.insert(tokens, token)
  end
  if #tokens == 0 then
    local empty = {}
    for i = 1, target_count do
      empty[i] = ""
    end
    return empty
  end

  local lengths = {}
  local total = 0
  for i, l in ipairs(original_lines) do
    lengths[i] = math.max(#l, 1)
    total = total + lengths[i]
  end
  local res = {}
  local idx = 1
  for i = 1, target_count do
    local target_len = lengths[i] or math.max(1, math.floor(total / target_count))
    local line_tokens = {}
    local current = 0
    while idx <= #tokens do
      local token = tokens[idx]
      local next_len = current == 0 and #token or current + 1 + #token
      local remaining_lines = target_count - i
      local remaining_tokens = #tokens - idx
      if remaining_lines > 0 and remaining_tokens <= remaining_lines then
        break
      end
      table.insert(line_tokens, token)
      idx = idx + 1
      current = next_len
      if current >= target_len then
        break
      end
    end
    res[i] = table.concat(line_tokens, " ")
  end

  if idx <= #tokens then
    local rest = table.concat(tokens, " ", idx)
    res[#res] = res[#res] ~= "" and (res[#res] .. " " .. rest) or rest
  end

  return res
end

---@param text string|nil
---@return string
function M.normalize_newlines(text)
  if not text then
    return ""
  end
  return (text:gsub("\r\n", "\n"):gsub("\r", ""))
end

return M
