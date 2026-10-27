local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/app.cr")
local req, td = H.req, H.td
local function loc(l) return vim.uri_to_fname(l.uri):gsub("^" .. vim.pesc(H.work) .. "/", "") .. ":" .. (l.range.start.line + 1) end
local function locs(r) local o = {} for _, l in ipairs(r or {}) do o[#o + 1] = loc(l) end table.sort(o) return table.concat(o, " ") end
-- references of Square#area from `sq.area` (line 8)
local r, ms = req("textDocument/references", { textDocument = td(), position = { line = 7, character = 9 }, context = { includeDeclaration = true } })
print(("references sq.area (%.0fms): %s"):format(ms, locs(r)))
r, ms = req("textDocument/references", { textDocument = td(), position = { line = 6, character = 6 }, context = { includeDeclaration = true } })
print(("references Square (%.0fms): %s"):format(ms, locs(r)))
-- definition of Square: not the nested project's
print("definition Square: " .. locs(req("textDocument/definition", { textDocument = td(), position = { line = 6, character = 6 } })))
-- incoming calls of Shape#area (abstract)
vim.cmd("edit " .. H.work .. "/src/shapes.cr")
local items = req("textDocument/prepareCallHierarchy", { textDocument = td(), position = { line = 1, character = 15 } })
local inc = req("callHierarchy/incomingCalls", { item = items[1] })
local names = {} for _, i in ipairs(inc or {}) do names[#names + 1] = i.from.name end
print("incoming calls Shape#area: " .. table.concat(names, " "))
-- type hierarchy: subtypes of Shape
local th = req("textDocument/prepareTypeHierarchy", { textDocument = td(), position = { line = 0, character = 16 } })
local subs = req("typeHierarchy/subtypes", { item = th[1] })
names = {} for _, i in ipairs(subs or {}) do names[#names + 1] = i.name end
table.sort(names)
print("subtypes Shape: " .. table.concat(names, " "))
-- ivar definition and rename
print("definition @side: " .. locs(req("textDocument/definition", { textDocument = td(), position = { line = 13, character = 5 } })))
local edit = req("textDocument/rename", { textDocument = td(), position = { line = 13, character = 5 }, newName = "@size" })
vim.lsp.util.apply_workspace_edit(edit, "utf-16")
print("after rename @side: " .. vim.api.nvim_buf_get_lines(0, 9, 10, false)[1] .. " | " .. vim.api.nvim_buf_get_lines(0, 13, 14, false)[1])
-- method rename: whole family, other project untouched
vim.cmd("buffer " .. H.work .. "/src/app.cr")
edit = req("textDocument/rename", { textDocument = td(), position = { line = 7, character = 9 }, newName = "size" })
local files = {} for uri, es in pairs(edit.changes or {}) do files[#files + 1] = vim.uri_to_fname(uri):gsub("^" .. vim.pesc(H.work) .. "/", "") .. "×" .. #es end
table.sort(files)
print("rename area -> size edits: " .. table.concat(files, " "))
local pr = req("textDocument/prepareRename", { textDocument = td(), position = { line = 7, character = 1 } })
print("prepareRename puts (stdlib): " .. (pr and (pr.message or pr.placeholder) or "nil"))
-- hover while a references search runs (async request, then sync hover)
vim.cmd("buffer " .. H.work .. "/src/app.cr")
local done_at, hover_at
local t0 = vim.uv.hrtime()
H.client:request("textDocument/references", { textDocument = td(), position = { line = 7, character = 9 }, context = { includeDeclaration = true } }, function() done_at = (vim.uv.hrtime() - t0) / 1e6 end, 0)
local hv = req("textDocument/hover", { textDocument = td(), position = { line = 6, character = 0 } })
hover_at = (vim.uv.hrtime() - t0) / 1e6
vim.wait(10000, function() return done_at ~= nil end)
print(("hover during references: answered at %.0fms, references at %.0fms, hover ok=%s"):format(hover_at, done_at or -1, tostring(hv ~= nil)))
-- cancel: Neovim drops the handler of a cancelled request; the server's
-- side shows in the log ("job ... (cancelled)").
local _, rid = H.client:request("textDocument/references", { textDocument = td(), position = { line = 7, character = 15 }, context = { includeDeclaration = true } }, function() end, 0)
H.client:cancel_request(rid)
vim.wait(500)
local log = table.concat(vim.fn.readfile(H.log), "\n")
print("cancel references: server log " .. (log:find("job textDocument/references " .. rid .. ": [%d.]+ms %(cancelled%)") and "shows cancelled job" or "has no cancelled job"))
-- spec DSL (`include Spec::Methods` / `Spec::Expectations` in the stdlib)
vim.cmd("edit " .. H.work .. "/spec/shapes_spec.cr")
local function hv(l, ch) local r = req("textDocument/hover", { textDocument = td(), position = { line = l, character = ch } }); return r and r.contents.value:match("```crystal\n([^\n]+)") or "nil" end
print("spec hover describe: " .. hv(2, 1) .. " | it: " .. hv(3, 3) .. " | eq: " .. hv(5, 19) .. " | sq: " .. hv(4, 5))
local dd = req("textDocument/definition", { textDocument = td(), position = { line = 5, character = 19 } })
print("spec definition eq -> " .. (dd and dd[1] and (vim.uri_to_fname(dd[1].uri):match("[^/]+/[^/]+$") .. ":" .. (dd[1].range.start.line + 1)) or "nil"))
vim.api.nvim_buf_set_lines(0, 6, 6, false, { "    sq.area.should be_" })
vim.wait(400)
local ci = req("textDocument/completion", { textDocument = td(), position = { line = 6, character = 22 } })
local cl = {} for i, it in ipairs(ci and ci.items or {}) do if i <= 5 then cl[#cl + 1] = it.label end end
print("spec complete be_: " .. table.concat(cl, " "))
-- code action: missing require in the script
vim.cmd("edit " .. H.work .. "/scripts/try.cr")
local diag = { range = { start = { line = 3, character = 4 }, ["end"] = { line = 3, character = 10 } }, severity = 1, source = "crystal", message = "undefined constant Widget" }
local acts = req("textDocument/codeAction", { textDocument = td(), range = diag.range, context = { diagnostics = { diag } } })
names = {} for _, a in ipairs(acts or {}) do names[#names + 1] = a.title end
print("code actions: " .. table.concat(names, " | "))
H.finish()
