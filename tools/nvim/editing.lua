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
  local word = m.word
  if item.insertTextFormat == 2 then
    word = vim.lsp._snippet_grammar and tostring(vim.lsp._snippet_grammar.parse(item.textEdit and item.textEdit.newText or item.insertText)) or word
  end
  local line = text:sub(1, from) .. word
  vim.api.nvim_buf_set_lines(0, last, last + 1, false, { line })
  return vim.api.nvim_buf_get_lines(0, last, last + 1, false)[1]
end
for _, c in ipairs({
  { "item.nam", "name" }, { "item.nam", "name=" }, { "items.each &.nam", "name=" },
  { "item.", "+" }, { "item.na", "name" }, { "pu", "puts" },
}) do
  print(("%-18s accept %-6s -> %s"):format(c[1], c[2], vim.inspect(accept(c[1], c[2]))))
end
H.finish()
