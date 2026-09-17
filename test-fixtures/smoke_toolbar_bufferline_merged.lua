-- Regression test for "toolbar hiển thị rời không dính vào tabbar, tabbar nằm trên editor chính"
-- (the toolbar displayed disconnected from the tabbar, [and] the tabbar sat right on top of the
-- main editor) - ui/bufferline.lua's tab-list row used to be a SEPARATE docked window from
-- ui/toolbar.lua's own bar, stacked via a redock() chain; that got the ORDER right, but every
-- real split window draws its own per-window statusline row below its content, and that extra
-- row sat visibly between the two bars, reading as a gap/seam. Folding the tab list into
-- toolbar.lua's OWN buffer as an extra content line (see toolbar.lua's own tabs_shown()/
-- bar_height()) removes that inter-panel boundary entirely - there is now only ONE window, so
-- there is nothing left to visually disconnect.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ bufferline_enabled = true, toolbar_auto_open = false })
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

jdm.toolbar.open(root)
assert(jdm.toolbar.is_open(), "toolbar should be open")

local wins = vim.api.nvim_tabpage_list_wins(0)
local top_row_wins = {}
for _, w in ipairs(wins) do
  if vim.api.nvim_win_get_position(w)[1] == 0 then table.insert(top_row_wins, w) end
end
assert(#top_row_wins == 1, "there must be exactly ONE window docked at row 0 (the combined bar) - got " .. #top_row_wins)
assert(vim.api.nvim_win_get_height(top_row_wins[1]) == 3, "the combined bar must be 3 rows tall (blank + Config + tab list) with bufferline_enabled")

-- Whatever window comes right after the combined bar must be the REAL editor (or another real
-- panel) starting immediately at row 3 - no extra blank/gap window in between.
local next_row = 3 + 1 -- +1 for the bar's own (blanked) per-window statusline row
local found_next = false
for _, w in ipairs(wins) do
  if vim.api.nvim_win_get_position(w)[1] == next_row then found_next = true end
end
assert(found_next, "the editor must start immediately after the combined bar's statusline row (row " .. next_row .. "), no extra gap window")

jdm.toolbar.close()

-- With bufferline_enabled = false, the bar drops back to 2 rows (no tab-list row at all).
jdm.opts.bufferline_enabled = false
jdm.toolbar.open(root)
local bar2_win
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_position(w)[1] == 0 then bar2_win = w end
end
assert(bar2_win, "toolbar window not found")
assert(vim.api.nvim_win_get_height(bar2_win) == 2, "bufferline_enabled=false must drop the bar back to 2 rows (no tab-list row)")

print("toolbar/bufferline merged-bar smoke test: OK")
