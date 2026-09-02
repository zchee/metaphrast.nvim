local metaphrast = require("metaphrast")

---Detect charwise/blockwise visual mode when command is invoked from a visual selection.
---Returns the visual mode string ("v" or "\22") if the command range matches
---the visual marks, nil otherwise.
---@param opts vim.api.keyset.create_user_command.command_args
---@return string|nil
local function detect_charwise_visual(opts)
  if opts.range ~= 2 then
    return nil
  end
  local vmode = vim.fn.visualmode()
  if vmode ~= "v" and vmode ~= "\22" and vmode ~= "" then
    return nil
  end
  -- Verify the command range matches the visual marks to confirm this was
  -- actually invoked from a visual selection (not a manual line range).
  local mark_start = vim.fn.line("'<")
  local mark_end = vim.fn.line("'>")
  if mark_start == opts.line1 and mark_end == opts.line2 then
    return vmode
  end
  return nil
end

---@param opts vim.api.keyset.create_user_command.command_args
vim.api.nvim_create_user_command("MetaphrastTranslate", function(opts)
  opts.visual_mode = detect_charwise_visual(opts)
  metaphrast.command(opts)
end, {
  range = true,
  nargs = "*",
  bang = true,
  desc = "Translate selection or buffer text using configured provider",
  complete = function()
    return { "en", "es", "fr", "de", "ja", "ko", "zh" }
  end,
})

vim.api.nvim_create_user_command("MetaphrastCacheClear", function()
  metaphrast.clear_cache()
  vim.notify("metaphrast: cache cleared", vim.log.levels.INFO)
end, { desc = "Clear translation cache" })
