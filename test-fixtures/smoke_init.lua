package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())

local jdm = require("java-debug-model")
jdm.setup({})

-- source plugin/java-debug-model.lua to confirm all commands register cleanly
vim.cmd("source " .. vim.fn.getcwd() .. "/plugin/java-debug-model.lua")
assert(vim.fn.exists(":JavaModelReload") == 2, "JavaModelReload command should be registered")
assert(vim.fn.exists(":JavaMavenPanel") == 2, "JavaMavenPanel command should be registered")
assert(vim.fn.exists(":TestNearestMethod") == 2, "TestNearestMethod command should be registered")
assert(vim.fn.exists(":JavaDebugConfigScan") == 2, "JavaDebugConfigScan command should be registered")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

-- manifest starts clean for this test run
local manifest_file = root .. "/.nvim/java-debug-model/manifest.json"
pcall(vim.fn.delete, manifest_file)

local project1
jdm.get_project(root, function(p) project1 = p end)
vim.wait(60000, function() return project1 ~= nil end, 100)
assert(#project1.modules == 2, "expected 2 modules before removal")

---Polls get_project (async) repeatedly until it returns a Project whose
---module count matches `expected_count`, or times out.
local function wait_for_module_count(expected_count, timeout_ms)
  local last
  local ok = vim.wait(timeout_ms, function()
    local done = false
    jdm.get_project(root, function(p) last = p; done = true end)
    -- get_project's callback may fire async; give this tick a chance
    vim.wait(50, function() return done end, 10)
    return last ~= nil and #last.modules == expected_count
  end, 500)
  return ok, last
end

jdm.remove_module(root, "module-b")
local ok2, project2 = wait_for_module_count(1, 60000)
assert(ok2, "expected 1 module after removing module-b, got " .. (project2 and #project2.modules or -1))
assert(project2.modules[1].artifact_id == "module-a", "remaining module should be module-a")

-- force a reload: excluded module must NOT silently come back
jdm.reload(root)
local ok3, project3 = wait_for_module_count(1, 60000)
assert(ok3, "module-b must stay excluded across a forced reload, got " .. (project3 and #project3.modules or -1))

-- add it back
local mod_b_path = root .. "/module-b"
jdm.add_module(root, mod_b_path)
local ok4, project4 = wait_for_module_count(2, 60000)
assert(ok4, "module-b should be back after :JavaModelAddModule, got " .. (project4 and #project4.modules or -1))

print("init.lua + plugin/java-debug-model.lua smoke test: OK")
