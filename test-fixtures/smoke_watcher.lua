package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local watcher = require("java-debug-model.watcher")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

local first_project
local got_first = false
watcher.get(root, {}, function(p) first_project = p; got_first = true end)
vim.wait(60000, function() return got_first end, 100)
assert(first_project, "initial watcher.get should resolve a project")
print("initial build OK, modules=" .. #first_project.modules)

-- reload callback registration
local reload_count = 0
watcher.on_reload(root, function(_p) reload_count = reload_count + 1 end)

-- touch pom.xml of module-a to trigger the fs_event watcher + debounce
local pom = root .. "/module-a/pom.xml"
local lines = vim.fn.readfile(pom)
vim.fn.writefile(lines, pom) -- rewrite triggers mtime change on most filesystems
os.execute("sleep 1 && touch " .. vim.fn.shellescape(pom))

local reloaded = false
vim.wait(15000, function() return reload_count > 0 end, 200)
assert(reload_count > 0, "editing pom.xml should trigger a debounced rebuild via on_reload")
print("watcher fs_event debounced reload OK (count=" .. reload_count .. ")")

-- explicit :JavaModelReload equivalent: force ignoring cache
local forced_project, got_forced = nil, false
watcher.reload(root, {}, function(p) forced_project = p; got_forced = true end)
vim.wait(60000, function() return got_forced end, 100)
assert(forced_project, "watcher.reload should force a full re-resolve")
print("forced reload OK, modules=" .. #forced_project.modules)

print("watcher.lua smoke test: OK")
