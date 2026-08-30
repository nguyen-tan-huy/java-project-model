package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local cache_file = root .. "/.nvim/java-debug-model/model-cache.json"

-- start from a clean slate: no disk cache, no in-memory cache (fresh process)
pcall(vim.fn.delete, cache_file)

local t1 = vim.loop.now()
local ok1, project1
maven.build(root, {}, function(ok, p) ok1, project1 = ok, p end)
vim.wait(60000, function() return ok1 ~= nil end, 100)
assert(ok1, "first build should succeed")
local first_ms = vim.loop.now() - t1
print("first build (real mvn) took " .. first_ms .. "ms")
assert(vim.fn.filereadable(cache_file) == 1, "model-cache.json should be written to disk after a successful build")

-- simulate a fresh `nvim` session: reload the module so its in-memory cache is gone
package.loaded["java-debug-model.resolver.maven"] = nil
package.loaded["java-debug-model.model"] = nil
local maven2 = require("java-debug-model.resolver.maven")

-- spy on mvn invocation: a disk-cache hit must call it ZERO times
local mvn_calls = 0
local orig_run_maven = maven2._run_maven
maven2._run_maven = function(...)
  mvn_calls = mvn_calls + 1
  return orig_run_maven(...)
end

local t2 = vim.loop.now()
local ok2, project2
maven2.build(root, {}, function(ok, p) ok2, project2 = ok, p end)
vim.wait(10000, function() return ok2 ~= nil end, 50)
local second_ms = vim.loop.now() - t2
print("second build (fresh process, disk cache) took " .. second_ms .. "ms, mvn invocations=" .. mvn_calls)

assert(ok2, "second build should succeed from disk cache")
assert(mvn_calls == 0, "a disk-cache hit must never invoke mvn, got " .. mvn_calls .. " calls")
assert(second_ms < 2000, "disk-cache load should be near-instant, took " .. second_ms .. "ms")
assert(#project2.modules == #project1.modules, "module count should match after disk-cache reload")

local mod_a1 = project1:find_module_by_ga("com.example:module-a")
local mod_a2 = project2:find_module_by_ga("com.example:module-a")
assert(mod_a2, "module-a should be present after disk-cache reload")
assert(mod_a2:coordinates() == mod_a1:coordinates(), "coordinates should match")
assert(#mod_a2.source_roots == #mod_a1.source_roots, "source_roots should round-trip through disk cache")
local found_sibling = false
for _, dep in ipairs(mod_a2.dependencies) do
  if dep.artifact_id == "module-b" then
    assert(dep.is_sibling, "sibling flag should survive disk-cache round-trip")
    found_sibling = true
  end
end
assert(found_sibling, "module-a's dependency on module-b should survive disk-cache round-trip")

-- now touch module-a's pom.xml (mtime changes) and confirm the cache is
-- correctly invalidated (mvn IS invoked again)
local pom = root .. "/module-a/pom.xml"
os.execute("sleep 1 && touch " .. vim.fn.shellescape(pom))

local ok3, project3
maven2.build(root, {}, function(ok, p) ok3, project3 = ok, p end)
vim.wait(60000, function() return ok3 ~= nil end, 100)
assert(ok3, "third build should succeed")
assert(mvn_calls > 0, "changing a pom.xml's mtime must invalidate the disk cache and re-invoke mvn")

print("disk cache smoke test: OK")
