package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local jdtls_bin = vim.fn.expand("~/.local/share/nvim/nvim-java/packages/jdtls/1.54.0/bin/jdtls")
local debug_jar = vim.fn.glob(vim.fn.expand(
  "~/.local/share/nvim/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar"),
  false, true)[1]
local test_jars = vim.fn.glob(
  vim.fn.expand("~/.local/share/nvim/nvim-java/packages/java-test/0.43.2/extension/server/*.jar"), false, true)

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")

local bundles = { debug_jar }
vim.list_extend(bundles, test_jars)

local jdtls = require("jdtls")
local attached = false

vim.cmd("edit " .. root .. "/module-a/src/main/java/com/example/modulea/App.java")

jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", workspace },
  root_dir = root,
  init_options = { bundles = bundles },
  on_attach = function() attached = true end,
})

vim.wait(120000, function() return attached end, 200)
assert(attached, "jdtls did not attach within timeout")
print("jdtls attached")

-- give jdt.ls a moment to finish initial project import/indexing
vim.wait(20000, function() return false end, 1000)

local maven = require("java-debug-model.resolver.maven")
local watcher = require("java-debug-model.watcher")
local mainclass = require("java-debug-model.mainclass")

local project
watcher.get(root, {}, function(p) project = p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project model build failed")

local main_entries
mainclass.find_main_classes(project, function(entries) main_entries = entries end)
vim.wait(30000, function() return main_entries ~= nil end, 200)
print("main classes found: " .. vim.inspect(main_entries))
assert(main_entries and #main_entries >= 1, "should find App's main method")
local found_app = false
for _, e in ipairs(main_entries) do
  if e.main_class == "com.example.modulea.App" then found_app = true end
end
assert(found_app, "should identify com.example.modulea.App as a main class")

local test_entries
mainclass.find_test_methods(project, function(entries) test_entries = entries end)
vim.wait(30000, function() return test_entries ~= nil end, 200)
print("test methods found: " .. vim.inspect(test_entries))
assert(test_entries, "find_test_methods should not error")

print("mainclass.lua smoke test: OK")
vim.cmd("qa!")
