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

local jdtls = require("jdtls")
local attached = false
vim.cmd("edit " .. root .. "/module-a/src/main/java/com/example/modulea/App.java")
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", workspace },
  root_dir = root,
  init_options = { bundles = { debug_jar } },
  on_attach = function()
    jdtls.setup_dap({ hotcodereplace = "manual" })
    attached = true
  end,
})
vim.wait(120000, function() return attached end, 200)
assert(attached, "jdtls did not attach")
vim.wait(15000, function() return false end, 1000)

local maven = require("java-debug-model.resolver.maven")
local watcher = require("java-debug-model.watcher")
local dap = require("java-debug-model.dap")
local session = require("java-debug-model.session")
local config_store = require("java-debug-model.config_store")

local project
watcher.get(root, {}, function(p) project = p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project model build failed")

local mod_a = project:find_module_by_ga("com.example:module-a")
local cfg = config_store.default_from_main_class(mod_a, "com.example.modulea.App")

-- build_launch_config: verify classPaths include module-b's live output (cross-module)
local launch_config = dap.build_launch_config(project, cfg)
local mod_b = project:find_module_by_ga("com.example:module-b")
local has_sibling_output = false
for _, p in ipairs(launch_config.classPaths) do
  if p == mod_b.path .. "/target/classes" then has_sibling_output = true end
end
assert(has_sibling_output, "generated launch config's classpath should include module-b's live target/classes")

-- "fresh session per launch": nvim-jdtls's own dap.adapters.java function
-- (registered by jdtls.setup_dap()) calls vscode.java.startDebugSession
-- itself, fresh, every time dap.run() resolves the "java" adapter - never
-- cached. Verify that invariant end-to-end via two REAL, sequential
-- M.launch() calls, spied on at the LSP client level, and that
-- session.lua's poll-based tracking (dap.lua no longer relies on a
-- nonexistent dap.run() "after" hook, nor on Session.config, which
-- nvim-dap never actually sets) correctly attaches a real, DISTINCT
-- dap_session object to each one.
local client = vim.lsp.get_clients({ name = "jdtls" })[1]
local request_count = 0
local orig_request = client.request
client.request = function(self, method, params, handler, bufnr)
  if method == "workspace/executeCommand" and params.command == "vscode.java.startDebugSession" then
    request_count = request_count + 1
  end
  return orig_request(self, method, params, handler, bufnr)
end

local cfg_long = config_store.default_from_main_class(mod_a, "com.example.modulea.LongRunningApp")
cfg_long.name = "run-1"
config_store.add(root, cfg_long)
local cfg_long2 = vim.deepcopy(cfg_long)
cfg_long2.name = "run-2"
config_store.add(root, cfg_long2)

local before_ids = {}
for _, e in ipairs(session.list()) do before_ids[e.id] = true end

dap.launch(project, cfg_long, {})
vim.wait(30000, function()
  for _, e in ipairs(session.list()) do
    if not before_ids[e.id] and e.name == "run-1" and e.dap_session then return true end
  end
  return false
end, 200)

dap.launch(project, cfg_long2, {})
vim.wait(30000, function()
  for _, e in ipairs(session.list()) do
    if not before_ids[e.id] and e.name == "run-2" and e.dap_session then return true end
  end
  return false
end, 200)

client.request = orig_request
print(request_count .. " real startDebugSession requests for 2 launches")
assert(request_count == 2, "each launch must trigger its OWN real startDebugSession request")

local entry1, entry2
for _, e in ipairs(session.list()) do
  if e.name == "run-1" then entry1 = e end
  if e.name == "run-2" then entry2 = e end
end
assert(entry1 and entry1.dap_session, "run-1 should have a real dap_session attached (not stuck on 'starting')")
assert(entry2 and entry2.dap_session, "run-2 should have a real dap_session attached (not stuck on 'starting')")
assert(entry1.dap_session ~= entry2.dap_session, "two concurrent launches must never share the same Session object")
assert(#session.list_running() >= 2, "both launches should be tracked as running")

-- cleanup: send the terminate request for both LongRunningApp JVMs this
-- test spawned. Actual OS-level death latency for a Thread.sleep()-stuck
-- process is jdtls/java-debug's own JDI termination latency (observed
-- anywhere from ~15s to 90s+ elsewhere) - not something this plugin's code
-- controls, so it's reported rather than hard-asserted here; the isolation
-- test (smoke_terminate_isolation.lua) is what proves the mechanism itself
-- is responsible for the eventual kill.
session.setup_listeners()
local ok_term = pcall(session.terminate_all_sync, 5000)
assert(ok_term, "terminate_all_sync must not error for either session")
local both_dead = vim.wait(20000, function()
  return vim.trim(vim.fn.system("pgrep -f LongRunningApp")) == ""
end, 300)
print("both LongRunningApp JVMs cleaned up within 20s: " .. tostring(both_dead))

print("dap.lua + session.lua real jdtls smoke test: OK")
vim.cmd("qa!")
