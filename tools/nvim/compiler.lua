local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/app.cr")
local c, td, req = H.client, H.td(), H.req
local ms = H.elapsed
local function hover(line, col) local r, t = req("textDocument/hover", { textDocument = td, position = { line = line, character = col } }); return (r and r.contents.value or "nil"):gsub("\n", " | "), t end

-- 1. hover answers while the first check runs
local h, t = hover(11, 0)
print(("[%.0fms] hover w before check (%.1fms): %s"):format(ms(), t, h))
-- 1b. an undeclared ivar is typed from its assignment before any check
local su0 = vim.uri_from_fname(H.work .. "/src/shapes.cr")
local sh0 = req("textDocument/hover", { textDocument = { uri = su0 }, position = { line = 18, character = 5 } })
print("hover @label before check: " .. (sh0 and sh0.contents.value or "nil"):gsub("\n", " | "))
-- 2. diagnostics arrive asynchronously
vim.lsp.inlay_hint.enable(true, { bufnr = 0 })
vim.wait(15000, function() return #vim.diagnostic.get(0) > 0 end)
for _, d in ipairs(vim.diagnostic.get(0)) do print(("[%.0fms] diagnostic %d:%d sev=%d %s"):format(ms(), d.lnum + 1, d.col + 1, d.severity, d.message)) end
vim.wait(500)
-- 2b. facts made `w`/`p` typed: the server asked Neovim to refresh hints
local shown = {}
for _, ih in ipairs(vim.lsp.inlay_hint.get({ bufnr = 0 })) do shown[#shown + 1] = (ih.inlay_hint.position.line + 1) .. ih.inlay_hint.label end
print("inlay hints after check (refreshed): " .. table.concat(shown, " "))
-- 2c. `:e` (didClose + didOpen) keeps the diagnostic
vim.cmd("edit")
vim.wait(1000)
print("diagnostics after :e: " .. #vim.diagnostic.get(0))
-- 3. compiler facts: generated methods and ivar types
print("hover w after check: " .. hover(11, 0))
print("hover p after check: " .. hover(12, 0))
local def = req("textDocument/definition", { textDocument = td, position = { line = 11, character = 7 } })
print("definition s.width -> " .. (def and def[1] and (vim.uri_to_fname(def[1].uri):match("[^/]+$") .. ":" .. (def[1].range.start.line + 1)) or "nil"))
-- 7. fix + save clears the error
vim.api.nvim_buf_set_lines(0, 14, 15, false, { "puts s.area" })
vim.cmd("write")
vim.wait(15000, function() return #vim.diagnostic.get(0) == 0 end)
print(("[%.0fms] diagnostics after fix+save: %d"):format(ms(), #vim.diagnostic.get(0)))
vim.wait(1000)
vim.cmd("edit " .. H.work .. "/src/shapes.cr")
local sh = req("textDocument/hover", { textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 18, character = 5 } })
print("hover @label after compiling check: " .. (sh and sh.contents.value or "nil"):gsub("\n", " | "))
vim.cmd("buffer " .. H.work .. "/src/app.cr")
-- 4. compiler-confirmed types
hover(4, 2)
vim.wait(3000)
print("hover y (twice): " .. hover(4, 2))
-- 5. macro expansion of `getter` in shapes.cr
local su = vim.uri_from_fname(H.work .. "/src/shapes.cr")
local ex, et = req("clearLs/expandMacro", { textDocument = { uri = su }, position = { line = 11, character = 3 } })
print(("expand getter (%.0fms): %s / %s"):format(et, ex and ex.status, ex and ex.expansions[1] and ex.expansions[1].original or "nil"))
-- 6. formatting of unsaved buffer text
vim.api.nvim_buf_set_lines(0, 2, 3, false, { "def twice( x )" })
vim.wait(300)
local edits, ft = req("textDocument/formatting", { textDocument = td, options = { tabSize = 2, insertSpaces = true } })
print(("format (%.0fms): %d edit(s) %s"):format(ft, edits and #edits or -1, edits and edits[1] and vim.inspect(edits[1].newText) or ""))
vim.lsp.util.apply_text_edits(edits, vim.api.nvim_get_current_buf(), "utf-16")
print("line 3 after format: " .. vim.api.nvim_buf_get_lines(0, 2, 3, false)[1])
H.finish()
