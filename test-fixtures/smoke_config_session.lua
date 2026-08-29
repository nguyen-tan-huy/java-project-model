package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local jdtls_bridge = require("java-debug-model.jdtls")
local dap = require("java-debug-model.dap")
local config_store = require("java-debug-model.config_store")
local session = require("java-debug-model.session")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

local mod_a = project:find_module_by_ga("com.example:module-a")

-- config_store CRUD
local tmp_store_root = vim.fn.tempname()
vim.fn.mkdir(tmp_store_root, "p")
local cfg = config_store.default_from_main_class(mod_a, "com.example.modulea.App")
cfg.env_vars = { FOO = "bar" }
cfg.working_directory = mod_a.content_root
config_store.add(tmp_store_root, cfg)

local listed = config_store.list(tmp_store_root)
assert(#listed == 1, "expected 1 saved config")
assert(listed[1].name == "App", "default name should be simple class name")

local fetched = config_store.get(tmp_store_root, "App")
assert(fetched.env_vars.FOO == "bar", "env_vars should persist")

-- persists to disk: reload fresh (simulate new nvim session) by re-requiring
package.loaded["java-debug-model.config_store"] = nil
local config_store2 = require("java-debug-model.config_store")
local reloaded = config_store2.list(tmp_store_root)
assert(#reloaded == 1 and reloaded[1].env_vars.FOO == "bar", "config should survive JSON persistence round-trip")

local edited = config_store2.edit(tmp_store_root, "App", { vm_args = "-Xmx256m" })
assert(edited, "edit should find the config")
assert(config_store2.get(tmp_store_root, "App").vm_args == "-Xmx256m", "edit should update field")

-- snapshot semantics: build_launch_config should NOT be affected by a later edit
local launch_config = dap.build_launch_config(project, config_store2.get(tmp_store_root, "App"))
assert(launch_config.mainClass == "com.example.modulea.App", "mainClass should be set")
assert(#launch_config.classPaths > 0, "classPaths should be resolved via jdtls bridge")
config_store2.edit(tmp_store_root, "App", { main_class = "com.example.modulea.Other" })
assert(launch_config.mainClass == "com.example.modulea.App",
  "already-built launch config snapshot must NOT change after editing the saved config")

local removed = config_store2.remove(tmp_store_root, "App")
assert(removed, "remove should find and remove the config")
assert(#config_store2.list(tmp_store_root) == 0, "config list should be empty after remove")

-- session registry
local id1 = session.register({ name = "App", module_path = mod_a.path, profiles = {}, port = 5000 })
local id2 = session.register({ name = "App-dev", module_path = mod_a.path, profiles = { "profile-dev" }, port = 5001 })
assert(id1 ~= id2, "session ids must be unique")
assert(#session.list() == 2, "expected 2 registered sessions")
session.mark_started(id1, { fake = "dap-session-1" })
session.mark_started(id2, { fake = "dap-session-2" })
assert(#session.list_running() == 2, "both sessions should be running")
session.mark_stopped(id1)
assert(#session.list_running() == 1, "stopping session 1 should not affect session 2")
local still_running = session.list_running()[1]
assert(still_running.id == id2, "session 2 should remain running after session 1 stopped")

print("config_store.lua + dap.lua + session.lua smoke test: OK")
