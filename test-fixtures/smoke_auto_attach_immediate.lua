-- "mở neovim là chạy như vào file java, không phải mở file java nữa" (opening Neovim should
-- already act like being in a java file, not require actually opening one first) - with
-- opts.auto_attach = true, init.lua's M.setup() now calls jdtls_launcher.start_or_attach()
-- IMMEDIATELY if cwd already resolves a Maven root (resolve_root_from_cwd() runs earlier in the
-- same setup() call), instead of only ever firing from the FileType java autocmd - which
-- previously meant jdtls never started until the user actually opened a .java file by hand.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
vim.cmd("cd " .. root) -- cwd resolves to a Maven root BEFORE setup() runs, no .java file opened

local jdtls_launcher = require("java-debug-model.jdtls_launcher")
local called_with_bufnr
local orig = jdtls_launcher.start_or_attach
jdtls_launcher.start_or_attach = function(bufnr, opts) called_with_bufnr = bufnr end

local jdm = require("java-debug-model")
jdm.setup({ auto_attach = true })

print("called_with_bufnr: " .. tostring(called_with_bufnr))
assert(called_with_bufnr ~= nil,
  "auto_attach=true must call start_or_attach IMMEDIATELY at setup() when cwd already resolves a root, without needing a .java FileType event first")

jdtls_launcher.start_or_attach = orig
print("immediate auto_attach smoke test: OK")
