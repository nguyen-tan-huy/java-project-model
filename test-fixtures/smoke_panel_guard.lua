-- Regression test for "tôi test mở file vẫn còn mở vào các panel chức năng" (opening a file
-- still sometimes lands inside a functional panel) - reported AFTER the earlier safe_edit_win
-- fix (which only covers this plugin's OWN `:edit` call sites, e.g. layout_state.lua's restore).
-- This proves the GENERAL case: opening a file by ANY means (simulated here as a raw
-- `nvim_win_set_buf`, standing in for `gf`/`gd`/a quickfix jump/plain `:e` - none of which route
-- through this plugin's own code at all) while the current window is a panel gets caught by
-- ui/panel_registry.lua's global BufWinEnter guard and relocated to a real editor window, with
-- the panel's own buffer restored in its place.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({})
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
vim.cmd("edit " .. root .. "/module-a/src/main/java/com/example/modulea/App.java")
local original_win = vim.api.nvim_get_current_win()

local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

jdm.project_tree.open(root, project)
assert(jdm.project_tree.is_open(), "project tree should be open")

-- Find the tree's own window/bufnr via panel_registry-adjacent introspection: it's the OTHER
-- window besides `original_win` right now.
local tree_win
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if w ~= original_win then tree_win = w end
end
assert(tree_win, "could not find the project tree's own window")
local tree_bufnr = vim.api.nvim_win_get_buf(tree_win)

-- Simulate SOME OTHER mechanism (gf/gd/quickfix/plain :e - not this plugin's own code) placing a
-- real file buffer into the tree's window.
local intruder_file = root .. "/module-b/src/main/java/com/example/moduleb/Greeter.java"
-- Focus the panel FIRST (gf/gd/plain :e all act on whatever window is CURRENT) - the guard reads
-- `nvim_get_current_win()`, so without this the test wouldn't be simulating the real scenario at
-- all (it would fire for whatever window actually happened to be current instead of the tree's).
-- Plain `:edit` (what gf/gd ultimately do for a file not yet open, and exactly what a bare `:e`
-- run by hand does) - a low-level `nvim_win_set_buf`/`bufadd()` combo does NOT set 'buflisted'
-- the way actually opening a file always does, so it wouldn't reproduce the real scenario the
-- guard is supposed to catch.
vim.api.nvim_set_current_win(tree_win)
vim.cmd("edit " .. intruder_file)
local intruder_buf = vim.api.nvim_get_current_buf()
vim.wait(500)

print("tree window now shows buf: " .. vim.api.nvim_win_get_buf(tree_win) .. " (tree's own: " .. tree_bufnr .. ")")
assert(vim.api.nvim_win_get_buf(tree_win) == tree_bufnr,
  "the tree's own window must have its rightful buffer restored, not the intruding file")

local found_elsewhere = false
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_buf(w) == intruder_buf then found_elsewhere = true end
end
assert(found_elsewhere, "the intruding file buffer must have been relocated to a REAL window, not just discarded")

print("panel_registry global guard smoke test: OK")
