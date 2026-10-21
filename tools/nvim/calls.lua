local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
local c, td, req = H.client, H.td(), H.req
local function at(l, ch) return { textDocument = td, position = { line = l, character = ch } } end
print("caps: signatureHelp=" .. tostring(c.server_capabilities.signatureHelpProvider ~= nil) .. " implementation=" .. tostring(c.server_capabilities.implementationProvider) .. " callHierarchy=" .. tostring(c.server_capabilities.callHierarchyProvider))
local h, ms = req("textDocument/hover", at(14, 9)); print(string.format("hover gets(10) %.1fms: %s", ms, h.contents.value:gsub("\n", " | "):sub(1, 140)))
h, ms = req("textDocument/hover", at(15, 9)); local n = select(2, h.contents.value:gsub("def IO#gets", "")); print(string.format("hover gets(value) %.1fms: %d overloads", ms, n))
local d, ms2 = req("textDocument/definition", at(14, 9)); print(string.format("definition gets(10) %.1fms: %d -> %s:%d", ms2, #d, d[1].uri:match("[^/]+$"), d[1].range.start.line + 1))
d = req("textDocument/definition", at(15, 9)); print("definition gets(value): " .. #d .. " locations")
for _, q in ipairs({ {16, 3, "c"}, {17, 3, "d"}, {18, 3, "total"} }) do
  local r = req("textDocument/hover", at(q[1], q[2])); print("hover " .. q[3] .. ": " .. (r and r.contents.value:match("```crystal\n(.-)\n```") or "nil"))
end
local items2 = req("textDocument/prepareCallHierarchy", at(13, 5))
local out, ms5 = req("callHierarchy/outgoingCalls", { item = items2[1] })
local names = {} for _, o in ipairs(out) do table.insert(names, o.to.detail:sub(1, 40)) end
print(string.format("outgoing calls of run %.1fms: %s", ms5, table.concat(names, "; ")))
local s, ms3 = req("textDocument/signatureHelp", at(19, 10))
local ls = {} for _, sg in ipairs(s.signatures) do table.insert(ls, sg.label) end
print(string.format("signatureHelp io.gets( %.1fms: %d sigs, active param %s; first: %s", ms3, #s.signatures, tostring(s.activeParameter), ls[1]))
vim.api.nvim_buf_set_lines(0, 19, 20, false, { "  io.gets('x', " })
vim.wait(400)
s = req("textDocument/signatureHelp", at(19, 15))
local sg = s.signatures[1]; local p = sg.parameters[sg.activeParameter + 1]
print("signatureHelp io.gets('x', : " .. sg.label .. " active=" .. sg.label:sub(p.label[1] + 1, p.label[2]))
vim.api.nvim_buf_set_lines(0, 19, 20, false, { "  io.gets(li" })
vim.wait(400)
local items = req("textDocument/completion", at(19, 12))
print("complete io.gets(li: " .. items.items[1].label .. " (" .. (items.items[1].detail or "") .. ")")
local impl, ms4 = req("textDocument/implementation", at(1, 16))
print(string.format("implementation Shape#area %.1fms: %d -> line %d", ms4, #impl, impl[1].range.start.line + 1))
H.finish()
