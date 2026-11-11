-- Phase 18: C bindings through vim.lsp.buf and the built-in completion.
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")

-- Hover on (line, col), 1-based line; first line of the code block and
-- the next non-empty text line.
local function hover(line, col)
  local text = H.hover(line - 1, col)
  return text:sub(1, 100)
end

-- Runs a vim.lsp.buf jump and reports file:line of the result.
local function jump(fn, line, col, refs)
  vim.fn.setqflist({})
  vim.api.nvim_win_set_cursor(0, { line, col })
  local opts = { on_list = function(o) vim.fn.setqflist({}, " ", o) end }
  if refs then fn({ includeDeclaration = true }, opts) else fn(opts) end
  vim.wait(3000, function() return #vim.fn.getqflist() > 0 end)
  local out = {}
  for _, it in ipairs(vim.fn.getqflist()) do
    out[#out + 1] = ("%s:%d"):format(vim.fn.bufname(it.bufnr):match("[^/]+$"), it.lnum)
  end
  return #out > 0 and table.concat(out, ", ") or "(none)"
end

print("hover cos (17):     " .. hover(17, 14))
print("hover cos decl (6): " .. hover(6, 7))
print("hover strlen (18):  " .. hover(18, 17))
print("hover len (18):     " .. hover(18, 3))
print("hover raw (19):     " .. hover(19, 3))
print("hover Void (19):    " .. hover(19, 17))
print("hover y= (21):      " .. hover(21, 6))
print("hover sizeof (21):  " .. hover(21, 10))
print("hover errno (8):    " .. hover(8, 4))
print("definition cos (17):    " .. jump(vim.lsp.buf.definition, 17, 14))
print("definition strlen (18): " .. jump(vim.lsp.buf.definition, 18, 17))
print("references y (12):      " .. jump(vim.lsp.buf.references, 12, 4, true))

local last = vim.api.nvim_buf_line_count(0)
local function ask(text)
  vim.api.nvim_buf_set_lines(0, last - 1, last, false, { text })
  vim.wait(400)
  local r = H.req("textDocument/completion", { textDocument = H.td(), position = { line = last - 1, character = #text } })
  local labels = {}
  for _, it in ipairs(r.items or {}) do labels[#labels + 1] = it.label end
  table.sort(labels)
  return ("n=%d: %s"):format(#labels, table.concat(labels, " "):sub(1, 90))
end
print("complete LibDemo.  -> " .. ask("LibDemo."))
print("complete LibC.strl -> " .. ask("LibC.strl"))

vim.api.nvim_buf_set_lines(0, last - 1, last, false, { 'LibDemo.printf("x", ' })
vim.wait(400)
local sh = H.req("textDocument/signatureHelp", { textDocument = H.td(), position = { line = last - 1, character = 20 } })
print("signature printf: " .. ((sh and sh.signatures and sh.signatures[1] and sh.signatures[1].label) or "nil"))
vim.api.nvim_buf_set_lines(0, last - 1, last, false, { "x = 1" })
H.finish()
