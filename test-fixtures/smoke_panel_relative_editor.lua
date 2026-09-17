-- Regression test for the squished-popup bug reported for real: opening ui/config_panel.lua's
-- panel (via ui/toolbar.lua's "✎ Edit Configurations..." menu entry) while the CURRENT window was
-- the toolbar's own small docked split collapsed the whole "80%"x"60%" panel down to that
-- window's own tiny size instead of the actual editor - because nui.Popup/nui.Layout both default
-- `relative` to "win" (current window), not "editor" (see config_panel.lua's/toolbar.lua's own
-- comments on their `relative = "editor"` fix). Reproduces the exact trigger: focus the toolbar's
-- own window, THEN open the config panel, and asserts the popup is sized off the real editor.
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

local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

-- Open the toolbar (a real small docked split) and focus it, matching what "current window" was
-- when the bug was reported: the user had just interacted with the toolbar.
jdm.toolbar.open(root)
vim.api.nvim_set_current_win(vim.api.nvim_tabpage_list_wins(0)[1])
local toolbar_height = vim.api.nvim_win_get_height(vim.api.nvim_get_current_win())
assert(toolbar_height == 3, "sanity check: current window must be the toolbar for this repro")

jdm.config_panel.open(root, project)
assert(jdm.config_panel.is_open(), "config panel should have opened")

local editor_lines = vim.o.lines
local total_panel_height = 0
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local cfg = vim.api.nvim_win_get_config(w)
  if cfg.relative ~= "" then -- one of the panel's own floating windows
    total_panel_height = math.max(total_panel_height, vim.api.nvim_win_get_height(w))
  end
end
print("editor lines: " .. editor_lines .. ", tallest panel window height: " .. total_panel_height)
assert(total_panel_height >= editor_lines * 0.4,
  "config panel must be sized relative to the EDITOR (~60% of " .. editor_lines ..
  " lines), not the small toolbar window it was opened from - got height " .. total_panel_height)

jdm.config_panel.close()
jdm.toolbar.close()
print("panel relative-editor smoke test: OK")
