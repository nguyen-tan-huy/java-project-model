-- ui/toolbar.lua's final shape: a 2-row bar (taller than the 1-row tabbar above it, on purpose -
-- see toolbar.lua's own BAR_HEIGHT comment). Matches IntelliJ's own toolbar layout: project name
-- at the LEFT edge, "Config: <name>" right-aligned at the RIGHT edge, on the bottom row. No
-- Run/Debug text and no own tab list (ui/bufferline.lua's own separate tabbar panel shows open
-- buffers).
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ bufferline_enabled = false }) -- isolate from the tabline occupying row 0, this test cares about the toolbar's OWN window position
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
jdm.config_store.add(root, {
  name = "App", module_path = root .. "/module-a", main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})
jdm.active_config.set(root, "App")

jdm.toolbar.open(root)

local toolbar_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local pos = vim.api.nvim_win_get_position(w)
  if pos[1] == 0 and vim.api.nvim_win_get_height(w) == 2 then toolbar_win = w end
end
assert(toolbar_win, "could not find the toolbar's window")
local buf = vim.api.nvim_win_get_buf(toolbar_win)
local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] -- bottom row carries the text, top row is blank padding
print("toolbar line: " .. vim.inspect(line))

assert(not line:match("Run") and not line:match("Debug"), "Run/Debug text must be gone")
assert(line:match("^%s*sample%-project"), "project name must be at the LEFT edge, matching IntelliJ's own module selector position")
assert(line:match("Config: App%s*$"), "Config text must be right-aligned (trailing at end of line)")
local config_col = line:find("Config:")
assert(config_col > 40, "Config text must start well to the RIGHT, not at column 1")

print("toolbar right-aligned smoke test: OK")
