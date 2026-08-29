package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven_runner = require("java-debug-model.maven_runner")
local maven_output = require("java-debug-model.maven_output")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

-- capture the cmd actually passed to the terminal, without spawning a real
-- long-running job for the flag-shape assertions
local captured_cmd, captured_cwd
local orig_run_in_terminal = maven_output.run_in_terminal
maven_output.run_in_terminal = function(cmd, cwd, opts)
  captured_cmd, captured_cwd = cmd, cwd
  if opts.on_exit then opts.on_exit(0) end
end

maven_runner.skip_tests = false
maven_runner.run(root, "module-a", { "install" })
assert(vim.tbl_contains(captured_cmd, "-pl"), "should scope via -pl")
assert(vim.tbl_contains(captured_cmd, "module-a"), "should scope to module-a")
assert(vim.tbl_contains(captured_cmd, "-am"), "-am should default ON")
assert(not vim.tbl_contains(captured_cmd, "-amd"), "-amd should default OFF (opt-in only)")
assert(not vim.tbl_contains(captured_cmd, "-DskipTests"), "skipTests off by default")
assert(captured_cwd == root, "must run from workspace root, never cd into the module")

maven_runner.toggle_skip_tests()
maven_runner.run(root, "module-a", { "install" })
assert(vim.tbl_contains(captured_cmd, "-DskipTests"), "-DskipTests should apply after toggling Skip Tests")

maven_runner.run(root, "module-a", { "test" }, { also_make_dependents = true, profiles = { "profile-dev" } })
assert(vim.tbl_contains(captured_cmd, "-amd"), "-amd should apply when explicitly requested")
assert(vim.tbl_contains(captured_cmd, "-Pprofile-dev"), "profiles should be forwarded as -P")

maven_output.run_in_terminal = orig_run_in_terminal
print("maven_runner.lua flag-shape smoke test: OK")

-- real execution smoke test through maven_output's terminal buffer
local root_esc = root
maven_runner.skip_tests = true
local exited = false
local exit_code
vim.api.nvim_create_autocmd("TermClose", {
  once = true,
  callback = function()
    exited = true
  end,
})
maven_output.run_in_terminal({ "mvn", "-pl", "module-a", "-am", "install", "-DskipTests" }, root, {
  title = "real-mvn-install",
  on_exit = function(code) exit_code = code; exited = true end,
})

vim.wait(60000, function() return exited end, 200)
assert(exited, "real mvn run via maven_output should complete")
assert(exit_code == 0, "real mvn -pl module-a -am install -DskipTests should succeed, got exit " .. tostring(exit_code))

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text = table.concat(lines, "\n")
assert(text:find("BUILD SUCCESS"), "terminal buffer should contain streamed Maven output")

print("maven_output.lua real terminal-run smoke test: OK")
