-- Regression test for "khi để con trỏ ở toolbar, chọn buffer ở tab nó mở file vào toolbar"
-- (leaving the cursor in the toolbar, then picking a buffer from the tabline opens the file
-- INTO the toolbar) - root cause was toolbar.lua's own Split using `bufhidden = "wipe"` (every
-- OTHER panel already used "hide"): the instant something else takes over that window, "wipe"
-- destroys the toolbar's own buffer right then, so by the time panel_registry.lua's global guard
-- tried to restore it, the buffer was already gone and restoration silently failed, leaving the
-- intruding file stuck in the toolbar's 1-row window for good.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ bufferline_enabled = false }) -- isolate from the tabline occupying row 0, this test cares about the toolbar's OWN window position
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

local pom = root .. "/pom.xml"
local app = root .. "/module-a/src/main/java/com/example/modulea/App.java"
vim.cmd("edit " .. pom)
vim.cmd("edit " .. app) -- App.java now loaded as a buffer, current window shows it

jdm.toolbar.open(root)
local toolbar_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local pos = vim.api.nvim_win_get_position(w)
  if pos[1] == 0 and vim.api.nvim_win_get_height(w) == 2 then toolbar_win = w end
end
assert(toolbar_win, "could not find the toolbar window")
local toolbar_bufnr = vim.api.nvim_win_get_buf(toolbar_win)

-- Simulate: cursor is left in the toolbar, then the user selects a DIFFERENT already-open buffer
-- via the tabline (pom.xml -> switch to it) - this is exactly `:buffer <n>` under the hood.
vim.api.nvim_set_current_win(toolbar_win)
local pom_buf = vim.fn.bufnr(pom)
vim.cmd("buffer " .. pom_buf)

print("toolbar window now shows: " .. vim.api.nvim_win_get_buf(toolbar_win) .. " (own: " .. toolbar_bufnr .. ")")
assert(vim.api.nvim_win_get_buf(toolbar_win) == toolbar_bufnr,
  "the toolbar's own window must keep its own buffer, never a real file, even synchronously with no flash")

local found_elsewhere = false
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_buf(w) == pom_buf then found_elsewhere = true end
end
assert(found_elsewhere, "pom.xml must have landed in a REAL editor window, not vanished")

print("toolbar tab-switch intrusion smoke test: OK")
