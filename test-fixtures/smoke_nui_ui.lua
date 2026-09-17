package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({})

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local mod_a_path = root .. "/module-a"
jdm.config_store.add(root, {
  name = "App", module_path = mod_a_path, main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = mod_a_path, maven_profiles = {},
})

-- ui/toolbar.lua: the IntelliJ-style Run/Debug/active-config bar mounts and unmounts cleanly.
jdm.toolbar.toggle(root)
assert(jdm.toolbar.is_open(), "toolbar should be open")
print("toolbar open: OK")
jdm.toolbar.toggle(root)
assert(not jdm.toolbar.is_open(), "toolbar should be closed")
print("toolbar close: OK")

-- ui/config_panel.lua: the list+form settings panel mounts and unmounts cleanly.
local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

jdm.config_panel.open(root, project)
assert(jdm.config_panel.is_open(), "config panel should be open")
print("config panel open: OK")
jdm.config_panel.close()
assert(not jdm.config_panel.is_open(), "config panel should be closed")
print("config panel close: OK")

-- active_config.lua: persists per-root, falls back to the first saved config when unset. This
-- fixture's sample-project dir accumulates DebugConfigs (and now active-config.json) saved by
-- other smoke tests / previous runs that share it (see e.g. smoke_debug_config_profiles.lua) -
-- explicitly clear it back to "unset" first rather than assuming a pristine disk, and don't
-- assume "App" (added above) lands at index 1.
jdm.active_config.set(root, nil)
local first_name = jdm.config_store.list(root)[1].name
local resolved = jdm.active_config.resolve(root, jdm.config_store)
assert(resolved and resolved.name == first_name,
  "resolve() must fall back to the first saved config when nothing was explicitly picked")
jdm.active_config.set(root, "App")
assert(jdm.active_config.get(root) == "App", "active config must persist after set()")
local resolved_app = jdm.active_config.resolve(root, jdm.config_store)
assert(resolved_app and resolved_app.name == "App", "resolve() must honor an explicitly set active config")

print("nui UI smoke test: OK")
