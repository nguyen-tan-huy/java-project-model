package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local model = require("java-debug-model.model")

local project = model.Project.new("/tmp/fake-root")

local mod_b = model.Module.new({
  path = "/tmp/fake-root/module-b",
  group_id = "com.example",
  artifact_id = "module-b",
  version = "1.0.0",
  in_reactor = false,
  source_roots = {
    { path = "/tmp/fake-root/module-b/src/main/java", kind = "main", lang = "java" },
  },
})

local mod_a = model.Module.new({
  path = "/tmp/fake-root/module-a",
  group_id = "com.example",
  artifact_id = "module-a",
  version = "1.0.0",
  in_reactor = true,
  source_roots = {
    { path = "/tmp/fake-root/module-a/src/main/java", kind = "main", lang = "java" },
    { path = "/tmp/fake-root/module-a/src/test/java", kind = "test", lang = "java" },
  },
  dependencies = {
    { group_id = "com.example", artifact_id = "module-b", version = "1.0.0", scope = "compile",
      is_sibling = true, sibling_module_path = mod_b.path },
  },
})

project:add_module(mod_a)
project:add_module(mod_b)

assert(project:find_module_by_ga("com.example:module-a") == mod_a, "find_module_by_ga failed")
assert(project:find_module_by_path(mod_b.path) == mod_b, "find_module_by_path failed")

local owner = project:find_module_for_file("/tmp/fake-root/module-a/src/main/java/com/example/modulea/App.java")
assert(owner == mod_a, "find_module_for_file should resolve to module-a")

local test_owner = project:find_module_for_file("/tmp/fake-root/module-a/src/test/java/com/example/modulea/AppTest.java")
assert(test_owner == mod_a, "find_module_for_file should resolve test file to module-a")

local roots = project:get_source_roots()
assert(#roots == 3, "expected 3 total source roots, got " .. #roots)

assert(#mod_a:main_source_roots() == 1, "module-a should have 1 main source root")
assert(#mod_a:test_source_roots() == 1, "module-a should have 1 test source root")

assert(mod_a:coordinates() == "com.example:module-a:1.0.0", "coordinates() mismatch")
assert(mod_a:ga() == "com.example:module-a", "ga() mismatch")

print("model.lua smoke test: OK")
