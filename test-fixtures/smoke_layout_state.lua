-- layout_state.lua: save() captures which files were open + which of this plugin's own panels
-- were open, restore() brings them back. Confirms a round-trip: open some files + the toolbar,
-- save, close everything, restore, and check both the file buffer list and the toolbar come back.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
-- restore_layout_on_start/toolbar_auto_open both OFF - this test drives save()/restore() itself,
-- doesn't want setup()'s own automatic triggers interfering. bufferline_enabled OFF too - with it
-- on (the default), layout_state.lua deliberately skips restoring the toolbar panel at all (its
-- "Config: <name>" text would otherwise duplicate the tabline's own identical text), which is
-- exactly what this test is trying to verify the OPPOSITE of (that a saved-open toolbar comes
-- back) - isolate from that here the same way smoke_toolbar_layout.lua etc. already do.
jdm.setup({ restore_layout_on_start = false, toolbar_auto_open = false, bufferline_enabled = false })

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local app_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"
local greeter_file = root .. "/module-b/src/main/java/com/example/moduleb/Greeter.java"

vim.cmd("edit " .. app_file)
vim.cmd("edit " .. greeter_file) -- current/focused file when we save

jdm.toolbar.open(root)
assert(jdm.toolbar.is_open(), "toolbar should be open before saving")

jdm.layout_state.save(root)

-- Close everything, simulating "Neovim restarted".
jdm.toolbar.close()
vim.cmd("silent! bwipeout " .. vim.fn.bufnr(app_file))
vim.cmd("silent! bwipeout " .. vim.fn.bufnr(greeter_file))
assert(vim.fn.bufnr(app_file) == -1, "App.java buffer should be gone before restore")
assert(vim.fn.bufnr(greeter_file) == -1, "Greeter.java buffer should be gone before restore")
assert(not jdm.toolbar.is_open(), "toolbar should be closed before restore")

jdm.layout_state.restore(root, true)
vim.wait(2000, function() return jdm.toolbar.is_open() end, 50)

assert(vim.fn.bufnr(app_file) ~= -1, "App.java should be back on the buffer list after restore")
assert(vim.fn.bufnr(greeter_file) ~= -1, "Greeter.java should be back on the buffer list after restore")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) == greeter_file,
  "the file that was CURRENT when saved must be the one actually shown after restore")
assert(jdm.toolbar.is_open(), "toolbar should be reopened after restore")

-- restore() is a once-per-root no-op unless forced - a second unforced call must not error and
-- must not undo anything (e.g. by closing what the first restore just opened).
jdm.layout_state.restore(root)
assert(jdm.toolbar.is_open(), "an unforced second restore() call must be a no-op, not close things")

print("layout_state smoke test: OK")
