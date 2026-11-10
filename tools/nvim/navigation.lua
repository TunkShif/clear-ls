-- Phase 16: type definition and declaration through vim.lsp.buf, and
-- range formatting through vim.lsp.buf.format({range}) (no conform).
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
local caps = H.client.server_capabilities
print(("caps: typeDefinition=%s declaration=%s rangeFormatting=%s"):format(
  tostring(caps.typeDefinitionProvider), tostring(caps.declarationProvider), tostring(caps.documentRangeFormattingProvider)))

-- Runs a vim.lsp.buf jump from (line, col) (1-based line) and reports
-- where the cursor lands, or the quickfix list for several locations.
local function jump(fn, line, col)
  vim.fn.setqflist({})
  vim.api.nvim_win_set_cursor(0, { line, col })
  local name = vim.api.nvim_buf_get_name(0)
  fn({ on_list = function(o)
    vim.fn.setqflist({}, " ", o)
  end })
  vim.wait(3000, function() return #vim.fn.getqflist() > 0 end)
  local out = {}
  for _, it in ipairs(vim.fn.getqflist()) do
    out[#out + 1] = ("%s:%d"):format(vim.fn.bufname(it.bufnr):match("[^/]+$"), it.lnum)
  end
  return #out > 0 and table.concat(out, ", ") or "(none)"
end

print("typeDefinition p (line 14): " .. jump(vim.lsp.buf.type_definition, 14, 0))
print("typeDefinition maybe (line 15): " .. jump(vim.lsp.buf.type_definition, 15, 0))
print("typeDefinition label (line 16): " .. jump(vim.lsp.buf.type_definition, 16, 0))
print("declaration find (line 15): " .. jump(vim.lsp.buf.declaration, 15, 8))

-- Linewise visual selection of `x   =   1` only (line 20).
local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
vim.api.nvim_win_set_cursor(0, { 20, 0 })
vim.cmd("normal! V")
vim.lsp.buf.format({ range = { start = { 20, 0 }, ["end"] = { 20, 0 } }, async = false })
vim.cmd("normal! \27")
local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local changed = {}
for i = 1, math.max(#before, #after) do
  if before[i] ~= after[i] then changed[#changed + 1] = ("%d:%q"):format(i, after[i] or "") end
end
print("range format line 20 changed: " .. table.concat(changed, " "))
print("def b untouched: line 24 " .. ("%q"):format(after[24]))
vim.lsp.buf.format({ async = false })
print("whole format then: line 24 " .. ("%q"):format(vim.api.nvim_buf_get_lines(0, 23, 24, false)[1]))
H.finish()
