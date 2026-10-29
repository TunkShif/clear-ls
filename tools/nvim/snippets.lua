-- Phase 13 completions as Neovim's built-in client applies them: do-end,
-- exhaustive case, definition snippets (enabled here), require paths.
-- Each case writes TEXT on the scratch line (the last), completes at its
-- end, accepts the first item with LABEL (and KIND when given), and
-- prints the lines it produced.
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
vim.lsp.completion.enable(true, H.client.id, 0)
H.client:notify("workspace/didChangeConfiguration", { settings = { clearLs = { completion = { definitionSnippets = true } } } })
local last = vim.api.nvim_buf_line_count(0) - 1
local base = vim.api.nvim_buf_get_lines(0, 0, -1, false)
-- BEFORE lines go above the cursor line, AFTER below it (replacing the
-- scratch line `x = 1`).
local times = {}
local function accept(before, text, after, label, kind)
  local lines = {}
  for i = 1, last do lines[#lines + 1] = base[i] end
  for _, l in ipairs(before) do lines[#lines + 1] = l end
  local row = #lines
  lines[#lines + 1] = text
  for _, l in ipairs(after) do lines[#lines + 1] = l end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.wait(400) -- didChange debounce
  local resp, ms = H.req("textDocument/completion", { textDocument = H.td(), position = { line = row, character = #text } })
  times[#times + 1] = ms
  local col = #text
  local start = col
  while start > 0 and text:sub(start, start):match("[%w_?!@]") do start = start - 1 end
  local matches, server_start = vim.lsp.completion._convert_results(text, row, col, H.client.id, start, nil, resp, "utf-16")
  local m
  for _, x in ipairs(matches) do
    local item = x.user_data.nvim.lsp.completion_item
    if x.abbr == label and (not kind or item.kind == kind) then m = x break end
  end
  if not m then
    local labels = {} for i, x in ipairs(matches) do if i <= 10 then labels[#labels + 1] = x.abbr end end
    return ("(no %s; menu: %s)"):format(label, table.concat(labels, " "))
  end
  local item = m.user_data.nvim.lsp.completion_item
  local edit = item.textEdit
  local from = edit and edit.range.start.character or (server_start or start)
  local to = edit and edit.range["end"].character or col
  local new = edit and edit.newText or item.insertText or item.label
  if item.insertTextFormat == 2 then
    -- What Neovim does on accept: remove the typed word, expand the
    -- snippet at the cursor with vim.snippet (insert mode).
    local rest = text:sub(to + 1)
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { text:sub(1, from) .. rest })
    vim.api.nvim_win_set_cursor(0, { row + 1, from })
    if rest == "" then vim.cmd("startinsert!") else vim.cmd("startinsert") end
    vim.snippet.expand(new)
    vim.snippet.stop()
    vim.cmd("stopinsert")
  else
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { text:sub(1, from) .. new .. text:sub(to + 1) })
  end
  local out = vim.api.nvim_buf_get_lines(0, row - #before, vim.api.nvim_buf_line_count(0), false)
  return table.concat(out, " / ")
end
local SNIPPET, FILE = 15, 17
for _, c in ipairs({
  { {}, "each_pair d", {}, "do", SNIPPET },
  { { "def t(v : Int32 | String | Nil, c : Color)", "  case c" }, "  i", { "  end", "end" }, "in … (2 missing)" },
  { { "def t(v : Int32 | String | Nil)", "  case v" }, "  i", { "  end", "end" }, "in … (3 missing)" },
  { {}, "cla", {}, "class", SNIPPET },
  -- Refused by the compiler ("can't declare class dynamically"): only
  -- the keyword is offered (expect "no class").
  { { "if true" }, "  cla", { "end" }, "class", SNIPPET },
  { {}, 'require "./mo', {}, "models/" },
  { {}, 'require "./models/po', {}, "post", FILE },
  -- demo.cr already requires ./models/user: not offered (expect "no user").
  { {}, 'require "./models/us', {}, "user", FILE },
  { {}, 'require "js', {}, "json" },
  { {}, 'require "http/cl', {}, "client" },
}) do
  print(("%-24s accept %-18s -> %s"):format(c[2], c[4], vim.inspect(accept(c[1], c[2], c[3], c[4], c[5]))))
end
local ts = {} for _, t in ipairs(times) do ts[#ts + 1] = ("%.0f"):format(t) end
print("completion ms: " .. table.concat(ts, " "))
H.finish()
