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
-- code action: missing require in the script
vim.cmd("edit " .. H.work .. "/scripts/try.cr")
local diag = { range = { start = { line = 3, character = 4 }, ["end"] = { line = 3, character = 10 } }, severity = 1, source = "crystal", message = "undefined constant Widget" }
local acts = req("textDocument/codeAction", { textDocument = td(), range = diag.range, context = { diagnostics = { diag } } })
names = {} for _, a in ipairs(acts or {}) do names[#names + 1] = a.title end
print("code actions: " .. table.concat(names, " | "))
H.finish()
