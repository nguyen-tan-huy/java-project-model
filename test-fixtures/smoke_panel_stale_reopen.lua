-- Regression test for the crash reported for real: closing ui/config_panel.lua's popup (or
-- ui/toolbar.lua's bar) some way OTHER than their own 'q'/'<Esc>' keymaps - e.g. `<C-w>c` -
-- leaves module state (`state.layout`/`state.list_popup`, `state.split`) pointing at a winid that
-- no longer exists. Reopening afterward used to crash inside `nvim_set_current_win` with
-- "Invalid 'win': Expected Lua number" because `is_open()` only checked "is this state non-nil",
-- not "is the window actually still there". Simulates that external close with a raw
-- `nvim_win_close` (bypassing this module's own M.close()) and confirms a second M.open() rebuilds
-- cleanly instead of crashing.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({})
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
jdm.config_store.add(root, {
  name = "App", module_path = root .. "/module-a", main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})

-- toolbar.lua
jdm.toolbar.open(root)
assert(jdm.toolbar.is_open(), "toolbar should report open right after M.open()")
vim.api.nvim_win_close(vim.api.nvim_tabpage_list_wins(0)[1], true) -- external close, bypasses M.close()
assert(not jdm.toolbar.is_open(), "is_open() must notice the window is actually gone")
local ok = pcall(jdm.toolbar.open, root) -- must NOT crash
assert(ok, "reopening the toolbar after an external close must not error")
assert(jdm.toolbar.is_open(), "toolbar should be open again after the rebuild")
jdm.toolbar.close()
print("toolbar stale-reopen: OK")

-- config_panel.lua
local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

jdm.config_panel.open(root, project)
assert(jdm.config_panel.is_open(), "config panel should report open right after M.open()")
-- close the LIST pane's window externally (the one M.open()'s crash actually indexed)
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
end
assert(not jdm.config_panel.is_open(), "is_open() must notice the window is actually gone")
local ok2 = pcall(jdm.config_panel.open, root, project) -- must NOT crash
assert(ok2, "reopening the config panel after an external close must not error")
assert(jdm.config_panel.is_open(), "config panel should be open again after the rebuild")
jdm.config_panel.close()
print("config_panel stale-reopen: OK")

print("panel stale-reopen smoke test: OK")
