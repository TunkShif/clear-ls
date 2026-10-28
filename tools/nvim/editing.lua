-- Completion as Neovim's built-in client applies it (vim.lsp.completion):
-- each case types a prefix on the last line, completes, accepts the
-- first match of LABEL, and prints the resulting line.
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
vim.lsp.completion.enable(true, H.client.id, 0)
local last = vim.api.nvim_buf_line_count(0) - 1
local function accept(text, label)
  vim.api.nvim_buf_set_lines(0, last, last + 1, false, { text })
  vim.wait(300) -- didChange debounce
  local resp = H.req("textDocument/completion", { textDocument = H.td(), position = { line = last, character = #text } })
  -- Neovim's own conversion (vim.lsp.completion), then complete() and
  -- <C-y> in insert mode: the same path as accepting from the popup.
  local col = #text
  local start = col
  while start > 0 and text:sub(start, start):match("[%w_?!@]") do start = start - 1 end
  local matches, server_start = vim.lsp.completion._convert_results(text, last, col, H.client.id, start, nil, resp, "utf-16")
  local idx
  for i, m in ipairs(matches) do if m.abbr == label then idx = i break end end
  if not idx then
    local labels = {} for i, m in ipairs(matches) do if i <= 8 then labels[#labels + 1] = m.abbr end end
    return ("(no %s; menu: %s)"):format(label, table.concat(labels, " "))
  end
  -- What complete() does on accept: replace from the start column to
  -- the cursor with the item's word (non-snippet items; snippets are
  -- expanded by vim.snippet on CompleteDone).
  local m = matches[idx]
  local from = server_start or start
  local item = m.user_data.nvim.lsp.completion_item
  if item.insertTextFormat == 2 then
    -- Snippets: Neovim clears the word and expands with vim.snippet.
    vim.api.nvim_buf_set_lines(0, last, last + 1, false, { text:sub(1, from) })
    vim.api.nvim_win_set_cursor(0, { last + 1, from })
    vim.cmd("startinsert!")
    vim.snippet.expand(item.textEdit and item.textEdit.newText or item.insertText)
    local cur = vim.api.nvim_win_get_cursor(0)
    vim.snippet.stop()
    vim.cmd("stopinsert")
    local line = vim.api.nvim_buf_get_lines(0, last, last + 1, false)[1]
    return line .. ("  [cursor at col %d]"):format(cur[2])
  end
  local line = text:sub(1, from) .. m.word
  vim.api.nvim_buf_set_lines(0, last, last + 1, false, { line })
  return vim.api.nvim_buf_get_lines(0, last, last + 1, false)[1]
end
for _, c in ipairs({
  { "item.nam", "name" }, { "item.nam", "name=" }, { "items.each &.nam", "name=" },
  { "item.", "+" }, { "item.na", "name" }, { "pu", "puts" },
  { "items.ma", "map" }, { "items.selec", "select" },
}) do
  print(("%-18s accept %-6s -> %s"):format(c[1], c[2], vim.inspect(accept(c[1], c[2]))))
end
-- F1: references and rename from the setter use (line 17)
local function locs(r) local o = {} for _, l in ipairs(r or {}) do o[#o + 1] = (l.range.start.line + 1) .. ":" .. l.range.start.character end table.sort(o) return table.concat(o, " ") end
print("references name (from item.name =): " .. locs(H.req("textDocument/references", { textDocument = H.td(), position = { line = 16, character = 6 }, context = { includeDeclaration = true } })))
local edit = H.req("textDocument/rename", { textDocument = H.td(), position = { line = 16, character = 6 }, newName = "title" })
vim.lsp.util.apply_workspace_edit(edit, "utf-16")
vim.wait(400) -- didChange debounce
print("after rename -> title: " .. table.concat(vim.api.nvim_buf_get_lines(0, 3, 4, false), "") .. " | " .. table.concat(vim.api.nvim_buf_get_lines(0, 16, 17, false), "") .. " | " .. table.concat(vim.api.nvim_buf_get_lines(0, 18, 19, false), ""))
-- F6: alias in the inlay hint of `t = item.tags` (line 18)
local hints = H.req("textDocument/inlayHint", { textDocument = H.td(), range = { start = { line = 0, character = 0 }, ["end"] = { line = 30, character = 0 } } })
local hs = {} for _, h in ipairs(hints or {}) do hs[#hs + 1] = (h.position.line + 1) .. h.label end
print("inlay hints: " .. table.concat(hs, "  "))
-- F5: block form code action on line 19
vim.wait(400)
local acts = H.req("textDocument/codeAction", { textDocument = H.td(), range = { start = { line = 18, character = 20 }, ["end"] = { line = 18, character = 20 } }, context = { diagnostics = {}, only = { "refactor" } } })
local a = acts and acts[1]
if a and a.edit then
  vim.lsp.util.apply_workspace_edit(a.edit, "utf-16")
  print(a.title .. ": " .. table.concat(vim.api.nvim_buf_get_lines(0, 18, 21, false), " / "))
else
  print("block action: " .. vim.inspect(a))
end
H.finish()
