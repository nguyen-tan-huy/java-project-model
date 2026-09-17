package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
local jdm = require("java-debug-model")
jdm.setup({ open_j9_java_exec = "/opt/openj9/bin/java" })

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local mod_a_path = root .. "/module-a"

local config_store = jdm.config_store
local dap = require("java-debug-model.dap")

local base = {
  name = "App", module_path = mod_a_path, main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = mod_a_path, maven_profiles = {},
}

-- No jdk_path set -> falls back to the setup()-wide OpenJ9 default.
local cfg_default = vim.deepcopy(base)
cfg_default.name = "App-default-jdk"

-- jdk_path set -> must win over the setup()-wide default (more specific choice).
local cfg_custom = vim.deepcopy(base)
cfg_custom.name = "App-custom-jdk"
cfg_custom.jdk_path = "/usr/lib/jvm/java-21-openjdk"

config_store.add(root, cfg_default)
config_store.add(root, cfg_custom)

local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

local launch_default = dap.build_launch_config(project, cfg_default, { open_j9_java_exec = jdm.opts.open_j9_java_exec })
local launch_custom = dap.build_launch_config(project, cfg_custom, { open_j9_java_exec = jdm.opts.open_j9_java_exec })

print("default javaExec: " .. tostring(launch_default.javaExec))
print("custom javaExec: " .. tostring(launch_custom.javaExec))

assert(launch_default.javaExec == "/opt/openj9/bin/java",
  "a config with no jdk_path must fall back to opts.open_j9_java_exec")
assert(launch_custom.javaExec == "/usr/lib/jvm/java-21-openjdk/bin/java",
  "a config's own jdk_path must win over the setup()-wide open_j9_java_exec default")

print("debug config per-config JDK version smoke test: OK")
