-- Restart of the ACTIVE config's running session (ui/toolbar.lua's M.restart_active, <leader>js /
-- :JavaToolbarRestart) and run_active's "already running -> restart, never a duplicate JVM" -
-- against a real jdtls + java-debug + nvim-dap, with real LongRunningApp JVMs. Verifies:
--   * restart replaces the tracked entry (old id gone, exactly one live session for the config)
--   * the OLD JVM is really dead (its per-session -D marker no longer matches any process)
--   * Run (noDebug) vs Debug mode is preserved across restart, and overridable via run_active
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-dap"))
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

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

local jdm = require("java-debug-model")
local session = require("java-debug-model.session")
local toolbar = require("java-debug-model.ui.toolbar")
local config_store = require("java-debug-model.config_store")
local active_config = require("java-debug-model.active_config")
session.setup_listeners()

local project
jdm.get_project(root, function(p) project = p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project model build failed")

local name = "restart-me"
local cfg = config_store.default_from_main_class(project:find_module_by_ga("com.example:module-a"),
  "com.example.modulea.LongRunningApp")
cfg.name = name
config_store.add(root, cfg)
active_config.set(root, name)

local function live_entries()
  return vim.tbl_filter(function(e) return e.name == name and e.status ~= "stopped" end, session.list())
end

local function jvm_alive(id)
  return vim.trim(vim.fn.system({ "pgrep", "-f", session.marker_for(id) })) ~= ""
end

---Waits for a RUNNING entry for `name` whose id isn't `old_id`.
local function wait_new_running(old_id, label)
  local entry
  local ok = vim.wait(150000, function()
    for _, e in ipairs(session.list()) do
      if e.name == name and e.id ~= old_id and e.status == "running" and e.dap_session then entry = e end
    end
    return entry ~= nil
  end, 200)
  assert(ok, label .. ": no new running session appeared")
  return entry
end

---Common assertions after a restart away from `old`.
local function check_replaced(old, new, want_no_debug, label)
  for _, e in ipairs(session.list()) do
    assert(e.id ~= old.id, label .. ": old entry " .. old.id .. " should be removed from the registry")
  end
  assert(#live_entries() == 1, label .. ": expected exactly 1 live session for the config, got " .. #live_entries())
  assert(not jvm_alive(old.id), label .. ": old JVM (marker " .. session.marker_for(old.id) .. ") must be dead")
  assert(jvm_alive(new.id), label .. ": new JVM must be running")
  assert(new.no_debug == want_no_debug,
    string.format("%s: expected no_debug=%s, got %s", label, tostring(want_no_debug), tostring(new.no_debug)))
  print(string.format("%s: OK (id %d -> %d, no_debug=%s)", label, old.id, new.id, tostring(new.no_debug)))
end

-- 1) restart_active with nothing running -> plain launch (Debug mode by default)
toolbar.restart_active(root)
local s1 = wait_new_running(nil, "restart_active (not running)")
assert(s1.no_debug == false, "a never-run config restarts in Debug mode")
assert(jvm_alive(s1.id), "JVM for the first launch must be running")
print("restart_active (not running -> launch): OK")

-- 2) Run pressed while it's running in Debug -> restart in Run mode, no duplicate JVM
toolbar.run_active(root, true)
local s2 = wait_new_running(s1.id, "run_active while running")
check_replaced(s1, s2, true, "run_active while running (Debug -> Run)")

-- 3) restart_active keeps the current (Run) mode
toolbar.restart_active(root)
local s3 = wait_new_running(s2.id, "restart_active")
check_replaced(s2, s3, true, "restart_active (keeps Run mode)")

-- 4) restart as DEBUG while running in Run mode -> Debug session
toolbar.restart_active(root, { no_debug = false })
local s4 = wait_new_running(s3.id, "restart_active debug")
check_replaced(s3, s4, false, "restart_active { no_debug = false } (Run -> Debug)")

-- 5) restart as DEBUG again keeps Debug
toolbar.restart_active(root, { no_debug = false })
local s5 = wait_new_running(s4.id, "restart_active debug again")
check_replaced(s4, s5, false, "restart_active { no_debug = false } (Debug -> Debug)")

-- cleanup
pcall(session.terminate_all_sync, 5000)
vim.wait(20000, function() return vim.trim(vim.fn.system("pgrep -f LongRunningApp")) == "" end, 300)
config_store.remove(root, name)

print("restart active config smoke test: OK")
vim.cmd("qa!")
