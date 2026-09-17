-- ui/bufferline.lua is a pure rendering helper now, reused as line 3 of ui/toolbar.lua's OWN
-- window (opts.bufferline_enabled) - NOT a separate docked panel/window anymore (that used to
-- leave a visible gap/seam between the two bars - "toolbar hiển thị rời không dính vào tabbar").
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ toolbar_auto_open = false }) -- bufferline_enabled default true; drive toolbar.open() by hand
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

local app_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"
vim.cmd("edit " .. app_file)

jdm.toolbar.open(root)
assert(jdm.toolbar.is_open(), "toolbar should be open")

local toolbar_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local pos = vim.api.nvim_win_get_position(w)
  if pos[1] == 0 and vim.api.nvim_win_get_height(w) == 3 then toolbar_win = w end
end
assert(toolbar_win, "with bufferline_enabled (default true), the toolbar's window must be 3 rows tall (blank + Config + tab list)")

local buf = vim.api.nvim_win_get_buf(toolbar_win)
local lines = vim.api.nvim_buf_get_lines(buf, 0, 3, false)
print("toolbar lines: " .. vim.inspect(lines))
assert(lines[1] == "", "line 1 is blank padding")
assert(lines[2]:match("Config:"), "line 2 carries the Config text")
assert(lines[3]:match("App%.java"), "line 3 (the tab-list row) must show the open file's name")
assert(not lines[3]:match("Config:"), "the tab-list row must NOT also show \"Config:\" text")

print("bufferline smoke test: OK")
