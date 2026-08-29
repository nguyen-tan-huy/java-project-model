package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local tree = require("java-debug-model.ui.project_tree")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

tree.open(root, project)
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text = table.concat(lines, "\n")
assert(text:find("Project"), "tree should show a Project root")
assert(text:find("module%-a"), "tree should list module-a")
assert(text:find("module%-b"), "tree should list module-b")
assert(text:find("independent pom"), "module-b should be flagged as an independent pom")

-- expand module-a: find its line, toggle, check source roots appear (lazy load)
local mod_a_line
for i, l in ipairs(lines) do
  if l:find("module%-a") then mod_a_line = i break end
end
assert(mod_a_line, "should find module-a's line")
vim.api.nvim_win_set_cursor(0, { mod_a_line, 0 })
vim.cmd("normal o")

local lines2 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text2 = table.concat(lines2, "\n")
assert(text2:find("%[main%]"), "expanding module-a should lazily show its main source root")
assert(text2:find("Dependencies"), "expanding module-a should show a Dependencies node")

print("ui/project_tree.lua smoke test: OK")
