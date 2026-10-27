-- Persistent cache: run twice on one fixture copy (run.sh: CLEAR_LS_PASS
-- 1, then 2). Pass 1 waits for a compiler check (facts); pass 2 hovers
-- before any check, so `w` is typed only through the cached facts.
local H = dofile(os.getenv("CLEAR_LS_ROOT") .. "/tools/nvim/common.lua").start("src/demo.cr")
local pass = os.getenv("CLEAR_LS_PASS")
local function log_line(pat)
  local f = io.open(H.log) if not f then return nil end
  local found
  for l in f:lines() do if l:find(pat) then found = l end end
  f:close()
  return found
end
vim.wait(10000, function() return log_line("index ready") ~= nil end)
print(("pass %s %s"):format(pass, (log_line("index ready") or "no index line"):gsub("^.-index ready", "index ready")))
if pass == "1" then
  vim.wait(30000, function() return log_line("compiler facts: [1-9]") ~= nil end)
  print("facts after check: " .. ((log_line("compiler facts: %d+ methods") or "none"):gsub("^.-compiler facts", "compiler facts")))
else
  print("facts before check: " .. ((log_line("compiler facts: %d+ methods") or "none"):gsub("^.-compiler facts", "compiler facts")))
  print("hover w: " .. H.hover(3, 0))
end
H.finish()
