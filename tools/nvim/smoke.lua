local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
local c, td, req = H.client, H.td(), H.req
local function hover(l, ch) local r, ms = req("textDocument/hover", { textDocument = td, position = { line = l, character = ch } }); return r and r.contents.value:gsub("\n", " "):sub(1, 90) or "nil", ms end
for _, q in ipairs({ {11, 3, "titles"}, {12, 3, "longest"}, {13, 3, "counts"}, {15, 25, "tag"}, {17, 3, "line"}, {19, 5, "stripped"}, {11, 25, "i.title"} }) do
  local s, ms = hover(q[1], q[2]); print(string.format("hover %-9s %5.1fms %s", q[3], ms, s))
end
-- before the completions below edit the def's last line
local hints = req("textDocument/inlayHint", { textDocument = td, range = { start = { line = 0, character = 0 }, ["end"] = { line = 30, character = 0 } } })
local hs = {} for _, h in ipairs(hints) do table.insert(hs, (h.position.line + 1) .. ":" .. h.position.character .. h.label) end
print("inlay hints (line:col): " .. table.concat(hs, "  "))
local function complete(text)
  vim.api.nvim_buf_set_lines(0, 21, 22, false, { "  " .. text })
  vim.wait(150)
  local items, ms = req("textDocument/completion", { textDocument = td, position = { line = 21, character = 2 + #text } })
  local ls = {} for i, it in ipairs(items.items) do if i <= 8 then table.insert(ls, it.label) end end
  return #items.items, table.concat(ls, " "), ms
end
for _, t in ipairs({ "titles.", "longest.", "counts.", "line.str", "items.first.", "Item.", "JSON::", "io.", "co" }) do
  local n, ls, ms = complete(t); print(string.format("complete %-13s %5.1fms %3d: %s", t, ms, n, ls))
end
local d = req("textDocument/definition", { textDocument = td, position = { line = 19, character = 21 } })
print("definition line.strip -> " .. (d[1] and (d[1].uri:match("[^/]+$") .. ":" .. (d[1].range.start.line + 1)) or "nil"))
-- glob require: hover lists every matched file
vim.fn.mkdir(H.work .. "/src/parts", "p")
vim.fn.writefile({ "" }, H.work .. "/src/parts/a.cr")
vim.fn.writefile({ "" }, H.work .. "/src/parts/b.cr")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'require "./parts/*"' })
vim.wait(400)
local gh = req("textDocument/hover", { textDocument = td, position = { line = 0, character = 11 } })
print("hover require ./parts/*: " .. (gh and gh.contents.value:gsub("\n", " ") or "nil"))
H.finish()
