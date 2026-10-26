local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/c.cr")
local c, td, req = H.client, H.td(), H.req
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local out = {}
local total = 0
for i, l in ipairs(lines) do
  local name = l:match("^  (%w+) = ")
  if name then
    local r, ms = req("textDocument/hover", { textDocument = td, position = { line = i - 1, character = 3 } })
    total = total + ms; if #out < 2 then print(("  %s: %.1fms"):format(name, ms)) end
    table.insert(out, name .. "=" .. (r and r.contents.value:match(": ([^\n]+)\n```") or "nil"))
  end
end
print(("hover %d locals in %.1fms total"):format(#out, total))
print(table.concat(out, "  "))
local h = req("textDocument/hover", { textDocument = td, position = { line = 5, character = 7 } })
print("hover def label: " .. h.contents.value:gsub("\n", " | "))
local hints = req("textDocument/inlayHint", { textDocument = td, range = { start = { line = 0, character = 0 }, ["end"] = { line = 12, character = 0 } } })
local hs = {} for _, x in ipairs(hints) do table.insert(hs, (x.position.line + 1) .. x.label) end
print("inlay hints (class): " .. table.concat(hs, "  "))
vim.api.nvim_buf_set_lines(0, 46, 47, false, { "  items.map(&.label).first." })
vim.wait(400)
local items, ms = req("textDocument/completion", { textDocument = td, position = { line = 46, character = 28 } })
local ls = {} for i, it in ipairs(items.items) do if i <= 6 then table.insert(ls, it.label) end end
print(("complete items.map(&.label).first. %.1fms: %s"):format(ms, table.concat(ls, " ")))
-- `&.|`: the block argument (Item), typed one character at a time
vim.api.nvim_buf_set_lines(0, 46, 47, false, { "  names = items.map(&)" })
vim.wait(400)
vim.api.nvim_buf_set_text(0, 46, 21, 46, 21, { "." })
vim.wait(400)
items, ms = req("textDocument/completion", { textDocument = td, position = { line = 46, character = 22 } })
ls = {} for i, it in ipairs(items.items) do if i <= 6 then table.insert(ls, it.label) end end
print(("complete items.map(&.| %.1fms: %s"):format(ms, table.concat(ls, " ")))
H.finish()
