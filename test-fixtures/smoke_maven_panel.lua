package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local maven_output = require("java-debug-model.maven_output")
local maven_runner = require("java-debug-model.maven_runner")
local maven_panel = require("java-debug-model.ui.maven_panel")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

maven_panel.open(root, project)
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text = table.concat(lines, "\n")
assert(text:find("Maven Projects"), "panel should have a header")
assert(text:find("com.example:module%-a"), "panel should list module-a")
assert(text:find("com.example:module%-b"), "panel should list module-b")
assert(text:find("Lifecycle"), "panel should show a Lifecycle node per module")
for _, phase in ipairs({ "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy" }) do
  assert(text:find(phase), "panel should list phase: " .. phase)
end
assert(text:find("Skip Tests: OFF"), "header should show Skip Tests OFF initially")

-- <CR> on a phase line should scope mvn to that module via -pl
local captured_cmd
local orig = maven_output.run_in_terminal
maven_output.run_in_terminal = function(cmd) captured_cmd = cmd end

-- find the line number for module-a's "install" phase
local install_line = nil
for i, l in ipairs(lines) do
  if l:match("^%s*install$") then install_line = i break end
end
assert(install_line, "should find an 'install' phase line")
vim.api.nvim_win_set_cursor(0, { install_line, 0 })
vim.cmd("normal \r")
assert(captured_cmd, "pressing <CR> should trigger a maven_runner.run")
assert(vim.tbl_contains(captured_cmd, "-pl"), "<CR>-triggered run should scope via -pl")
assert(vim.tbl_contains(captured_cmd, "install"), "<CR> on 'install' line should run the install phase")

-- T toggles skip tests and re-renders header
vim.cmd("normal T")
local lines2 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(table.concat(lines2, "\n"):find("Skip Tests: ON"), "T should toggle header to Skip Tests ON")

maven_output.run_in_terminal = orig
print("ui/maven_panel.lua smoke test: OK")
