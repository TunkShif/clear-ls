-- Shared setup for headless checks (loaded with dofile from each script).
-- Starts clear-ls on CLEAR_LS_WORK/<file>, returns helpers.
local M = {}
M.root = assert(os.getenv("CLEAR_LS_ROOT"), "run via tools/nvim/run.sh")
M.work = assert(os.getenv("CLEAR_LS_WORK"))
M.log = os.getenv("CLEAR_LS_LOG") or (M.work .. "/clear-ls.log")
local t0 = vim.uv.hrtime()
function M.elapsed() return (vim.uv.hrtime() - t0) / 1e6 end

function M.start(file)
  local caps = vim.lsp.protocol.make_client_capabilities()
  vim.lsp.config("clear_ls", {
    capabilities = caps,
    cmd = { M.root .. "/bin/clear-ls", "lsp", "--log-file", M.log, "--log-level", "debug" },
    filetypes = { "crystal" }, root_markers = { "shard.yml" },
  })
  vim.lsp.enable("clear_ls")
  vim.cmd("edit " .. M.work .. "/" .. file)
  vim.wait(5000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
  M.client = assert(vim.lsp.get_clients({ bufnr = 0 })[1], "clear-ls did not attach")
  return M
end

function M.td() return { uri = vim.uri_from_bufnr(0) } end
function M.at(line, col) return { textDocument = M.td(), position = { line = line, character = col } } end

-- Synchronous request: result (or error), milliseconds.
function M.req(method, params, timeout)
  local t = vim.uv.hrtime()
  local r = M.client:request_sync(method, params, timeout or 15000, 0)
  return r and (r.result or r.err), (vim.uv.hrtime() - t) / 1e6
end

-- Hover text on one line, and milliseconds.
function M.hover(line, col)
  local r, ms = M.req("textDocument/hover", M.at(line, col))
  return (r and r.contents and r.contents.value or "nil"):gsub("\n", " | "), ms
end

-- Replace one line; waits past Neovim's 150 ms didChange debounce.
function M.set_line(line, text)
  vim.api.nvim_buf_set_lines(0, line, line + 1, false, { text })
  vim.wait(400)
end

function M.finish()
  M.client:stop()
  vim.wait(2000, function() return M.client:is_stopped() end)
  vim.cmd("qa!")
end

return M
