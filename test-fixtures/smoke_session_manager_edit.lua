package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({})
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
vim.cmd("edit " .. root .. "/module-a/src/main/java/com/example/modulea/App.java")

jdm.config_store.add(root, {
  name = "App", module_path = root .. "/module-a", main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})
jdm.config_store.add(root, {
  name = "LongRunningApp", module_path = root .. "/module-a", main_class = "com.example.modulea.LongRunningApp",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})
jdm.active_config.set(root, "App") -- make sure it's NOT already "LongRunningApp"

local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)

jdm.session_manager_ui.open()
local session_win = jdm.session_manager_ui.is_open() and vim.fn.bufwinid(vim.fn.bufnr("java-debug-model://session-manager"))
assert(session_win and session_win ~= -1, "session manager should be open")

-- Move cursor to the "LongRunningApp" row and press 'e'.
local buf = vim.api.nvim_win_get_buf(session_win)
local target_line
for lnum = 1, vim.api.nvim_buf_line_count(buf) do
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  if line:match("LongRunningApp") then target_line = lnum end
end
assert(target_line, "could not find LongRunningApp row")
vim.api.nvim_set_current_win(session_win)
vim.api.nvim_win_set_cursor(session_win, { target_line, 0 })
vim.api.nvim_feedkeys("e", "mtx", false)
vim.wait(500)

assert(jdm.config_panel.is_open(), "'e' must open ui/config_panel.lua (Edit Configurations UI)")
assert(jdm.active_config.get(root) == "LongRunningApp",
  "'e' must select the ROW UNDER CURSOR's config, not whatever was active before")

print("session-manager edit->config_panel smoke test: OK")
