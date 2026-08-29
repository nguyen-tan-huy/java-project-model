package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local jdtls = require("java-debug-model.jdtls")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil or ok == false end, 100)
assert(ok, "maven.build failed")

local mod_a = project:find_module_by_ga("com.example:module-a")
local mod_b = project:find_module_by_ga("com.example:module-b")

local classpath = jdtls.resolve_classpath(project, mod_a)
print("module-a classpath:")
for _, p in ipairs(classpath) do print("  " .. p) end

local found_b_output = false
for _, p in ipairs(classpath) do
  if p == mod_b.path .. "/target/classes" then found_b_output = true end
end
assert(found_b_output, "module-a's classpath should include module-b's LIVE target/classes, not a .m2 jar")

for _, p in ipairs(classpath) do
  assert(not p:find("module%-b.*%.m2"), "should never resolve sibling module-b via .m2 jar path")
end

local sourcepaths = jdtls.resolve_sourcepaths(project, mod_a)
print("module-a sourcepaths:")
for _, p in ipairs(sourcepaths) do print("  " .. p) end

local found_b_src = false
for _, p in ipairs(sourcepaths) do
  if p == mod_b.path .. "/src/main/java" then found_b_src = true end
end
assert(found_b_src, "module-a's sourcepaths should include module-b's real source directory")

-- root_dir_for_buffer: fake a buffer name and confirm module resolution
vim.cmd("edit " .. mod_a.path .. "/src/main/java/com/example/modulea/App.java")
local resolved_mod = jdtls.root_dir_for_buffer(project, 0)
assert(resolved_mod and resolved_mod.path == mod_a.path, "root_dir_for_buffer should resolve to module-a")

print("jdtls.lua smoke test: OK")
