package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ toolbar_auto_open = true })

assert(not jdm.toolbar.is_open(), "toolbar must not be open before any .java buffer is seen")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local java_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"
vim.cmd.edit(java_file)
-- `-u NONE` (used by every smoke test in this repo) disables Neovim's built-in filetype
-- detection along with the rest of the default runtime init, so `.java` buffers never get
-- ft=java on their own here - set it explicitly to fire the FileType autocmd this feature
-- actually hooks into (a normal Neovim startup detects it automatically).
vim.bo.filetype = "java"

assert(jdm.toolbar.is_open(), "opts.toolbar_auto_open=true must open the toolbar on the first .java buffer")
print("toolbar_auto_open smoke test: OK")
