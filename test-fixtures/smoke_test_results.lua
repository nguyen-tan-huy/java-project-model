package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local results = require("java-debug-model.ui.test_results")

vim.cmd("edit /tmp/AppTest.java")
local bufnr = vim.api.nvim_get_current_buf()

local tests = {
  { fq_class = "com.example.modulea.AppTest", method = "greetsWithName", failed = false, traces = {} },
  { fq_class = "com.example.modulea.AppTest", method = "intentionallyFailingTest", failed = true,
    traces = { "org.opentest4j.AssertionFailedError: expected: <Hello, Neovim!> but was: <Hello, Vim!>" } },
}
local items = {
  { bufnr = bufnr, lnum = 17, text = "intentionallyFailingTest some trace" },
}

results.record(items, tests)

local failed = results.last_failed()
assert(#failed == 1, "expected 1 failed test, got " .. #failed)
assert(failed[1].method_name == "intentionallyFailingTest", "failed method name mismatch")
assert(failed[1].line == 17, "failed test line should come from the matching quickfix item")

results.open()
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text = table.concat(lines, "\n")
assert(text:find("2 total, 1 passed, 1 failed"), "summary line missing/incorrect: " .. text)
assert(text:find("✓ greetsWithName"), "passing test should show a checkmark")
assert(text:find("✗ intentionallyFailingTest"), "failing test should show an X mark")
assert(text:find("AssertionFailedError"), "failure trace excerpt should be shown")

print("ui/test_results.lua smoke test: OK")
