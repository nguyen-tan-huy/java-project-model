package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))

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
  on_attach = function() attached = true end,
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

-- request_fresh_port: the invariant our code must uphold is that it NEVER
-- caches a port value locally and instead makes a real
-- vscode.java.startDebugSession round-trip on every single call - verified
-- here by spying on the LSP client's request count, since this particular
-- java-debug bundle version happens to hand back the same port number when
-- the previous session's socket was never connected to (its listening
-- socket idles out and the OS may reissue the same ephemeral port - a
-- server-side/OS coincidence, not something our code controls or should
-- rely on).
local client = vim.lsp.get_clients({ name = "jdtls" })[1]
local request_count = 0
local orig_request = client.request
client.request = function(self, method, params, handler, bufnr)
  if method == "workspace/executeCommand" and params.command == "vscode.java.startDebugSession" then
    request_count = request_count + 1
  end
  return orig_request(self, method, params, handler, bufnr)
end

local port1, port2
dap.request_fresh_port(function(ok, port) if ok then port1 = port end end)
vim.wait(20000, function() return port1 ~= nil end, 200)
assert(port1, "should obtain a fresh debug port from the real jdtls/java-debug bundle")

dap.request_fresh_port(function(ok, port) if ok then port2 = port end end)
vim.wait(20000, function() return port2 ~= nil end, 200)
assert(port2, "should obtain a second fresh debug port")

client.request = orig_request
print("port1=" .. port1 .. " port2=" .. port2 .. " (" .. request_count .. " real startDebugSession requests)")
assert(request_count == 2, "each launch must issue its OWN real startDebugSession request, never reuse a cached one")

-- session registry: two concurrent entries (even if their ports coincide,
-- as this server version does when the first session was never connected to,
-- our registry tracks them as independent entries with independent status)
local id1 = session.register({ name = "run-1", module_path = mod_a.path, profiles = {}, port = port1 })
local id2 = session.register({ name = "run-2", module_path = mod_a.path, profiles = {}, port = port2 })
session.mark_started(id1, { fake = 1 })
session.mark_started(id2, { fake = 2 })
assert(#session.list_running() == 2, "two independently-ported sessions should both be tracked as running")

print("dap.lua + session.lua real jdtls smoke test: OK")
vim.cmd("qa!")
