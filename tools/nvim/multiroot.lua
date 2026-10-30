-- Multi-root (Phase 14): one client over two projects that each need their
-- own `lib/dep`. Starts with the folder `app`, adds `tool` with
-- `vim.lsp.buf.add_workspace_folder`, then removes it.
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua")
local work = H.work
local ms = H.elapsed

-- One client for both projects: root `app`, reused for `tool` buffers
-- (Neovim would start a second client for another root_marker match).
vim.lsp.config("clear_ls", {
  capabilities = vim.lsp.protocol.make_client_capabilities(),
  cmd = { H.root .. "/bin/clear-ls", "lsp", "--log-file", H.log, "--log-level", "debug" },
  filetypes = { "crystal" },
  root_dir = work .. "/app",
  workspace_folders = { { uri = vim.uri_from_fname(work .. "/app"), name = work .. "/app" } },
  reuse_client = function() return true end,
})
vim.lsp.enable("clear_ls")
vim.cmd("edit " .. work .. "/app/src/app.cr")
vim.wait(5000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
local client = assert(vim.lsp.get_clients({ bufnr = 0 })[1], "clear-ls did not attach")
H.client = client

local app_buf = vim.api.nvim_get_current_buf()
local function errors(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do out[#out + 1] = (d.lnum + 1) .. ": " .. d.message end
  return #out == 0 and "none" or table.concat(out, "; ")
end
local function def_at(buf, line, col)
  local r = client:request_sync("textDocument/definition",
    { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = line, character = col } }, 10000, buf)
  local loc = r and r.result and r.result[1]
  return loc and vim.uri_to_fname(loc.uri):sub(#work + 2) or "nil"
end
local function hover_at(buf, line, col)
  local r = client:request_sync("textDocument/hover",
    { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = line, character = col } }, 10000, buf)
  local v = r and r.result and r.result.contents.value or "nil"
  return (v:gsub("\n", " | "))
end
local function log_has(pat)
  local f = io.open(H.log); if not f then return false end
  local s = f:read("a"); f:close()
  return s:find(pat) ~= nil
end

-- 1. app alone
vim.wait(20000, function() return #vim.diagnostic.get(app_buf) > 0 end)
print(("[%.0fms] app diagnostics: %s"):format(ms(), errors(app_buf)))
print("app Dep.v1 -> " .. def_at(app_buf, 4, 9))

-- 2. a tool buffer before its folder is added: a loose file of app's index
vim.cmd("edit " .. work .. "/tool/src/tool.cr")
local tool_buf = vim.api.nvim_get_current_buf()
vim.wait(1000)
print("before add: tool Dep.v2 -> " .. def_at(tool_buf, 4, 9))

-- 3. add the folder
local t = vim.uv.hrtime()
vim.lsp.buf.add_workspace_folder(work .. "/tool")
vim.wait(10000, function() return log_has("index ready: [^\n]*/tool:") end)
print(("[%.0fms] added tool (%.0fms)"):format(ms(), (vim.uv.hrtime() - t) / 1e6))
print("after add: tool Dep.v2 -> " .. def_at(tool_buf, 4, 9) .. ", hover v2: " .. hover_at(tool_buf, 4, 9))
vim.wait(20000, function() return #vim.diagnostic.get(tool_buf) > 0 end)
print("tool diagnostics: " .. errors(tool_buf))
print("app still: Dep.v1 -> " .. def_at(app_buf, 4, 9) .. ", diagnostics: " .. errors(app_buf))
local syms = client:request_sync("workspace/symbol", { query = "Widget" }, 10000, 0)
local where = {}
for _, s in ipairs(syms and syms.result or {}) do
  if s.name == "Widget" then where[#where + 1] = vim.uri_to_fname(s.location.uri):sub(#work + 2) end
end
table.sort(where)
print("symbols Widget: " .. table.concat(where, ", "))

-- 4. remove it (Neovim also prints "... is not currently part of the
-- workspace" whatever happened)
vim.lsp.buf.remove_workspace_folder(work .. "/tool")
vim.wait(5000, function() return #vim.diagnostic.get(tool_buf) == 0 end)
print("after remove: tool diagnostics: " .. errors(tool_buf) .. ", Dep.v2 -> " .. def_at(tool_buf, 4, 9))
print("app after remove: diagnostics: " .. errors(app_buf))

H.finish()
