-- Regression test for the real error reported: "Config references missing adapter `java`.
-- Available are: codelldb" - nvim-dap's own generic message when `dap.adapters.java` was never
-- registered. That happens whenever jdtls hasn't actually ATTACHED to a real .java buffer yet in
-- this Neovim session (`jdtls.setup_dap()`, which registers it, only runs from
-- jdtls_launcher.lua's own M.on_attach) - launching a debug config from the toolbar/global
-- keymap/gutter without ever having opened a .java file hits exactly that. dap.lua's M.launch now
-- checks for `dap.adapters.java` itself first and reports a clear, actionable message instead of
-- letting nvim-dap's own cryptic one through, and doesn't register a session entry for a launch
-- that never actually happened.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-dap"))

local jdm = require("java-debug-model")
jdm.setup({})
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local cfg = {
  name = "App", module_path = root .. "/module-a", main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
}

local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

-- nvim-dap loaded, but NO adapter registered for "java" - exactly the reported scenario.
local dap = require("java-debug-model.dap")
local session = require("java-debug-model.session")
local before_count = #session.list()

local notified
local orig_notify = vim.notify
vim.notify = function(msg, level) notified = { msg = msg, level = level } end
local result = dap.launch(project, cfg, {})
vim.notify = orig_notify

print("notified: " .. vim.inspect(notified))
assert(result == nil, "dap.launch must return nil when the java adapter isn't registered")
assert(notified and notified.msg:match("jdtls chưa attach"),
  "must show a clear, actionable error instead of nvim-dap's own cryptic one")
assert(#session.list() == before_count,
  "must NOT register a session entry for a launch that never actually happened")

print("missing-adapter guard test: OK")
