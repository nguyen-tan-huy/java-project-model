-- ui/toolbar.lua's M.run_active launches via dap.launch(...) then focuses the Session Manager
-- panel on THAT specific launch's row (session_manager_ui.focus_entry(id)), not just M.open()
-- (which opens/keeps the panel without moving the cursor anywhere - reported for real as "opens
-- the session panel but doesn't focus the profile that's actually running", easy to miss among
-- several saved configs). dap.lua's M.launch now RETURNS the session_id (session.register() runs
-- synchronously at the top of it, well before the async dap.run() handshake) specifically so the
-- caller can do this.
--
-- Doesn't need a real jdtls/dap session - session.register() (what M.launch calls internally,
-- simulated directly here) is synchronous and all focus_entry needs is a registered entry with a
-- matching id, regardless of whether it ever actually finishes starting.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({})
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
-- A real buffer under `root` so session_manager_ui.open()'s own `jdm._find_root(0)` resolves the
-- SAME root the configs/session below are registered against (it has no explicit root
-- parameter - it always resolves from the CURRENT buffer, same as in real usage where the user
-- is in a java buffer for the project they just launched something in).
vim.cmd("edit " .. root .. "/module-a/src/main/java/com/example/modulea/App.java")

jdm.config_store.add(root, {
  name = "App", module_path = root .. "/module-a", main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})
jdm.config_store.add(root, {
  name = "LongRunningApp", module_path = root .. "/module-a", main_class = "com.example.modulea.LongRunningApp",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})

local session = require("java-debug-model.session")
local id = session.register({ name = "LongRunningApp", root = root, module_path = root .. "/module-a", profiles = {} })

local session_manager_ui = require("java-debug-model.ui.session_manager")
session_manager_ui.focus_entry(id)

assert(session_manager_ui.is_open(), "focus_entry must open the panel")
local winid = vim.fn.bufwinid(vim.fn.bufnr("java-debug-model://session-manager"))
assert(winid ~= -1, "session manager window must be visible")
local lnum = vim.api.nvim_win_get_cursor(winid)[1]
local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), lnum - 1, lnum, false)[1]
print("cursor landed on line: " .. vim.inspect(line))
assert(line:match("LongRunningApp"),
  "cursor must land on the row for the JUST-launched entry (LongRunningApp, id=" .. id .. "), not some other row")

print("toolbar session-focus smoke test: OK")
