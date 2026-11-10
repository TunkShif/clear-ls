-- Phase 17: annotation completion and hover in Neovim's built-in client.
-- Typing `@[` in insert mode must open the menu through the `[` trigger
-- character (autotrigger); the rest asks explicitly.
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
local triggers = H.client.server_capabilities.completionProvider.triggerCharacters
print("triggers: " .. table.concat(triggers, " "))
vim.lsp.completion.enable(true, H.client.id, 0, { autotrigger = true })
local last = vim.api.nvim_buf_line_count(0) -- `x = 1`

-- Explicit requests and hovers first (synchronous), then typed input:
-- headless Neovim reads queued keys only once the script has returned,
-- so typing runs as a chain of deferred steps.
-- Explicit requests on the scratch line.
local function ask(text)
  vim.api.nvim_buf_set_lines(0, last - 1, last, false, { text })
  vim.wait(400)
  local r = H.req("textDocument/completion", { textDocument = H.td(), position = { line = last - 1, character = #text } })
  local labels = {}
  for i, it in ipairs(r.items or {}) do if i <= 8 then labels[#labels + 1] = it.label end end
  table.sort(labels)
  return ("n=%d: %s"):format(#(r.items or {}), table.concat(labels, " "))
end
print("ask @[JSON::            -> " .. ask("@[JSON::"))
print("ask @[Link(\"m\", pk     -> " .. ask('@[Link("m", pk'))
print("ask @[JSON::Field(ke    -> " .. ask("@[JSON::Field(ke"))
vim.api.nvim_buf_set_lines(0, last - 1, last, false, { "x = 1" })
vim.wait(400)

print("hover Raises (5):     " .. H.hover(4, 4):sub(1, 90))
print("hover \"m\" (3):        " .. H.hover(2, 7):sub(1, 90))
print("hover ldflags (3):    " .. H.hover(2, 13):sub(1, 90))
print("hover emit_null (12): " .. H.hover(11, 30):sub(1, 110))

-- Type TEXT at the start of the last line in insert mode (real input, so
-- InsertCharPre fires and autotrigger asks the server); report the menu.
-- Autotrigger fires on trigger characters only: `@[` and `@[JSON::`
-- open the menu; `xs = [` (the same `[`) opens nothing.
local cases = { "@[", "@[JSON::", "xs = [" }
local function step(i)
  if i > #cases then
    vim.api.nvim_buf_set_lines(0, last - 1, last, false, { "x = 1" })
    H.finish()
    return
  end
  vim.api.nvim_buf_set_lines(0, last - 1, last, false, { "" })
  vim.api.nvim_win_set_cursor(0, { last, 0 })
  vim.api.nvim_input("i" .. cases[i])
  vim.defer_fn(function()
    local info = vim.fn.complete_info({ "items" })
    local labels = {}
    for k, it in ipairs(info.items) do if k <= 8 then labels[#labels + 1] = it.word end end
    print(("\ntyped %-8s -> n=%d: %s"):format(cases[i], #info.items, table.concat(labels, " ")))
    vim.api.nvim_input("<C-e><Esc>")
    vim.defer_fn(function() step(i + 1) end, 300)
  end, 1500)
end
vim.defer_fn(function() step(1) end, 400)
