package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

local done, ok, project, err = false, nil, nil, nil
maven.build(root, { active_profiles = {} }, function(_ok, _project, _err)
  ok, project, err = _ok, _project, _err
  done = true
end)

vim.wait(60000, function() return done end, 100)
assert(done, "maven.build timed out")
assert(ok, "maven.build failed: " .. tostring(err))

print("modules found: " .. #project.modules)
for _, mod in ipairs(project.modules) do
  print(string.format("  - %s (in_reactor=%s) path=%s", mod:coordinates(), tostring(mod.in_reactor), mod.path))
  for _, sr in ipairs(mod.source_roots) do
    print(string.format("      source_root[%s]: %s", sr.kind, sr.path))
  end
  for _, dep in ipairs(mod.dependencies) do
    print(string.format("      dep %s:%s is_sibling=%s lib=%s", dep.group_id, dep.artifact_id,
      tostring(dep.is_sibling), dep.library and dep.library.jar_path or "nil"))
  end
end

local mod_a = project:find_module_by_ga("com.example:module-a")
local mod_b = project:find_module_by_ga("com.example:module-b")
assert(mod_a, "module-a should be discovered (via aggregator)")
assert(mod_b, "module-b should be discovered (via filesystem scan, independent pom)")
assert(mod_a.in_reactor == true, "module-a should be in_reactor")
assert(mod_b.in_reactor == false, "module-b should NOT be in_reactor (independent pom)")

local found_sibling_dep = false
for _, dep in ipairs(mod_a.dependencies) do
  if dep.artifact_id == "module-b" then
    assert(dep.is_sibling, "module-a's dependency on module-b must be coordinate-matched as sibling")
    assert(dep.sibling_module_path == mod_b.path, "sibling_module_path should point to module-b's dir")
    found_sibling_dep = true
  end
end
assert(found_sibling_dep, "module-a should declare a dependency on module-b")

print("resolver/maven.lua smoke test: OK")
