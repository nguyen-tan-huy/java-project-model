-- Real-jdtls smoke test for ui/main_gutter.lua's gutter-icon flow: `textDocument/documentSymbol`
-- based `main` method discovery + line-accurate FQCN mapping, and the "auto-create a DebugConfig
-- the first time, reuse it after that" behavior M.run_under_cursor relies on. Modeled on
-- smoke_mainclass.lua's own real-jdtls bootstrap.
--
-- Deliberately does NOT put nvim-dap on the runtimepath - M.run_at_line's own create-or-reuse
-- config_store logic runs BEFORE it ever reaches dap.launch's `pcall(require, "dap")` (which just
-- notifies and returns if nvim-dap isn't available), so this test exercises exactly the
-- gutter-specific behavior without spawning a real debuggee JVM (that path - launch, concurrent
-- sessions, terminate-cleanup - is already covered by smoke_dap_session.lua).
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local jdtls_bin = vim.fn.expand("~/.local/share/nvim/nvim-java/packages/jdtls/1.54.0/bin/jdtls")
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")

local jdm = require("java-debug-model")
jdm.setup({})

local app_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"
vim.cmd("edit " .. app_file)
local bufnr = vim.api.nvim_get_current_buf()
-- `-u NONE` (every smoke test in this repo uses it) disables Neovim's built-in filetype
-- detection - main_gutter.scan_buffer's own first guard requires ft=="java", so without this it
-- silently no-ops on every call and no entry ever gets placed (a normal Neovim startup detects
-- `.java` automatically - see smoke_toolbar_auto_open.lua's own identical note).
vim.bo[bufnr].filetype = "java"

local jdtls = require("jdtls")
local attached = false
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", workspace },
  root_dir = root,
  on_attach = function() attached = true end,
})
vim.wait(120000, function() return attached end, 200)
assert(attached, "jdtls did not attach within timeout")
print("jdtls attached")
vim.wait(20000, function() return false end, 1000) -- let jdt.ls finish initial import/indexing

local main_gutter = require("java-debug-model.ui.main_gutter")
local config_store = require("java-debug-model.config_store")
local active_config = require("java-debug-model.active_config")

local scanned = false
-- scan_buffer is fire-and-forget (async project resolve + LSP request) - poll entry_at instead
-- of hooking a callback, matching how ui/main_gutter.lua itself is driven (autocmds, no callback).
main_gutter.scan_buffer(bufnr)
local found_line
vim.wait(60000, function()
  for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
    if main_gutter.entry_at(bufnr, lnum) then
      found_line = lnum
      return true
    end
  end
  return false
end, 200)
assert(found_line, "main_gutter should have placed an entry at App.java's main method line")

local entry = main_gutter.entry_at(bufnr, found_line)
print("found main entry at line " .. found_line .. ": " .. vim.inspect({ main_class = entry.main_class }))
assert(entry.main_class == "com.example.modulea.App",
  "gutter entry's FQCN must match the real main class, got " .. tostring(entry.main_class))
assert(entry.module and entry.module.artifact_id == "module-a", "gutter entry must resolve to module-a")

-- This fixture's sample-project dir accumulates DebugConfigs saved by OTHER smoke tests that
-- share it (see e.g. smoke_debug_config_profiles.lua / smoke_debug_config_jdk.lua, which both save
-- one named "App" with this EXACT module_path+main_class) - remove any leftover match first so
-- "first run creates exactly one new config" is actually testing a first run, not silently
-- reusing a config a DIFFERENT test left behind.
local to_remove = {}
for _, cfg in ipairs(config_store.list(root)) do
  if cfg.module_path == entry.module.path and cfg.main_class == entry.main_class then
    table.insert(to_remove, cfg.name)
  end
end
for _, name in ipairs(to_remove) do config_store.remove(root, name) end

local before_count = #config_store.list(root)
main_gutter.run_at_line(bufnr, found_line)

local created
for _, cfg in ipairs(config_store.list(root)) do
  if cfg.module_path == entry.module.path and cfg.main_class == entry.main_class then created = cfg end
end
assert(created, "first run must auto-create a DebugConfig for this module+main_class")
assert(#config_store.list(root) == before_count + 1, "first run must add exactly ONE new config")
assert(active_config.get(root) == created.name, "first run must mark the (new) config as active")

-- Running the SAME line again must REUSE the config, not create a duplicate.
main_gutter.run_at_line(bufnr, found_line)
assert(#config_store.list(root) == before_count + 1,
  "running the SAME main method again must reuse the existing config, not create a second one")

print("main_gutter.lua smoke test: OK")
vim.cmd("qa!")
