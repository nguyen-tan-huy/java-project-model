-- Isolation check: confirm the LongRunningApp JVM actually dies BECAUSE of
-- session.terminate_all_sync's disconnect request, not merely because
-- Neovim/jdtls happen to exit around the same time. This script never calls
-- qa!, and jdtls stays fully alive and connected for the entire run - if the
-- debuggee still dies, that's unambiguous proof the DAP disconnect request
-- itself is what does it.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-dap"))

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local jdtls_bin = vim.fn.expand("~/.local/share/nvim/nvim-java/packages/jdtls/1.54.0/bin/jdtls")
local debug_jar = vim.fn.glob(vim.fn.expand(
  "~/.local/share/nvim/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar"),
  false, true)[1]

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")

local jdtls_client = require("jdtls")
local attached = false
vim.cmd("edit " .. root .. "/module-a/src/main/java/com/example/modulea/App.java")
jdtls_client.start_or_attach({
  cmd = { jdtls_bin, "-data", workspace },
  root_dir = root,
  init_options = { bundles = { debug_jar } },
  on_attach = function()
    jdtls_client.setup_dap({ hotcodereplace = "manual" })
    attached = true
  end,
})
vim.wait(120000, function() return attached end, 200)
assert(attached, "jdtls did not attach")
vim.wait(15000, function() return false end, 1000)

local watcher = require("java-debug-model.watcher")
local dap = require("java-debug-model.dap")
local session = require("java-debug-model.session")
local config_store = require("java-debug-model.config_store")

local project
watcher.get(root, {}, function(p) project = p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project model build failed")

local mod_a = project:find_module_by_ga("com.example:module-a")
local cfg = config_store.default_from_main_class(mod_a, "com.example.modulea.LongRunningApp")
config_store.add(root, cfg)

dap.launch(project, cfg, {})
vim.wait(30000, function()
  for _, e in ipairs(session.list()) do
    if e.dap_session then return true end
  end
  return false
end, 200)

vim.wait(2000, function() return false end, 200)
assert(vim.trim(vim.fn.system("pgrep -f LongRunningApp")) ~= "", "LongRunningApp should be running before cleanup")
print("jdtls still alive: " .. tostring(vim.fn.filereadable(jdtls_bin) == 1 and #vim.lsp.get_clients({name="jdtls"}) > 0))
print("nvim/jdtls both alive, about to terminate the debuggee only")

session.setup_listeners()
session.terminate_all_sync(5000)

-- jdtls and this Neovim process are STILL fully running right now (no qa!,
-- no VimLeavePre fired) - if the JVM still dies, only the disconnect
-- request can be responsible.
local process_gone = vim.wait(120000, function()
  return vim.trim(vim.fn.system("pgrep -f LongRunningApp")) == ""
end, 500)

-- prove jdtls is STILL alive right now, at the moment the debuggee died
local jdtls_alive_now = #vim.lsp.get_clients({ name = "jdtls" }) > 0
print("process_gone=" .. tostring(process_gone) .. " jdtls_still_alive=" .. tostring(jdtls_alive_now))
assert(jdtls_alive_now, "jdtls must still be alive/connected for this isolation check to mean anything")
assert(process_gone,
  "LongRunningApp must die from the disconnect request alone, with Neovim and jdtls both still fully running")

print("ISOLATION CHECK PASSED: disconnect(terminateDebuggee=true) alone kills the debuggee, independent of any Neovim/jdtls exit")
vim.cmd("qa!")
