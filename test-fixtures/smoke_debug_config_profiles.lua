package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
local jdm = require("java-debug-model")
jdm.setup({}) -- global active_profiles left EMPTY on purpose

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local mod_a_path = root .. "/module-a"

local config_store = jdm.config_store
local dap = require("java-debug-model.dap")

-- Two saved DebugConfigs, same module/main class, differing ONLY in
-- maven_profiles - this is exactly the "run with a dev profile" workflow
-- (:JavaDebugConfigAdd, filling "profile-dev" into the Maven profiles
-- prompt) the user is asking how to set up.
local cfg_noprofile = {
  name = "App-default", module_path = mod_a_path, main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = mod_a_path, maven_profiles = {},
}
local cfg_dev = {
  name = "App-dev", module_path = mod_a_path, main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = mod_a_path,
  maven_profiles = { "profile-dev" },
}
config_store.add(root, cfg_noprofile)
config_store.add(root, cfg_dev)

-- build_launch_config for each, going through the SAME path
-- :JavaDebugConfigRun uses (M.get_project(root, cb, cfg.maven_profiles)),
-- to prove the per-config profile actually changes the resolved classpath.
local project_default, project_dev
jdm.get_project(root, function(p) project_default = p end, cfg_noprofile.maven_profiles)
vim.wait(60000, function() return project_default ~= nil end, 100)
assert(project_default, "default-profile project resolve failed")

jdm.get_project(root, function(p) project_dev = p end, cfg_dev.maven_profiles)
vim.wait(60000, function() return project_dev ~= nil end, 100)
assert(project_dev, "profile-dev project resolve failed")

local launch_default = dap.build_launch_config(project_default, cfg_noprofile)
local launch_dev = dap.build_launch_config(project_dev, cfg_dev)

local function has_commons_lang3(classpaths)
  for _, p in ipairs(classpaths) do
    if p:find("commons%-lang3") then return true end
  end
  return false
end

print("default classpath has commons-lang3: " .. tostring(has_commons_lang3(launch_default.classPaths)))
print("profile-dev classpath has commons-lang3: " .. tostring(has_commons_lang3(launch_dev.classPaths)))

assert(not has_commons_lang3(launch_default.classPaths),
  "the config with NO maven_profiles must NOT get profile-dev's commons-lang3 dependency")
assert(has_commons_lang3(launch_dev.classPaths),
  "the config saved with maven_profiles={'profile-dev'} MUST get commons-lang3 in its launch classpath - "
  .. "this is the actual bug: DebugConfig.maven_profiles was saved but never applied when resolving the project")

print("debug config per-profile classpath smoke test: OK")
