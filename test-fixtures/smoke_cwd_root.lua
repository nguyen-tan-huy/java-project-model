package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

-- simulate "opened nvim inside the project" BEFORE touching any java file
vim.cmd("cd " .. vim.fn.fnameescape(root))

local jdm = require("java-debug-model")
jdm.setup({})

-- current buffer is still the default empty/unnamed buffer - no .java file
-- was ever opened. find_root must already know the project from cwd alone.
local resolved = jdm._find_root(0)
assert(resolved == root, "expected setup() to resolve root from cwd immediately, got " .. tostring(resolved))
print("root resolved from cwd at setup(), no java buffer needed: " .. resolved)

-- simulate `:cd` into module-a specifically (still no java buffer opened):
-- DirChanged should re-resolve and still find the same reactor root.
vim.cmd("cd " .. vim.fn.fnameescape(root .. "/module-a"))
local resolved2 = jdm._find_root(0)
assert(resolved2 == root, "expected DirChanged to re-resolve root, got " .. tostring(resolved2))
print("root re-resolved correctly after :cd into a submodule: " .. resolved2)

print("cwd-based root resolution smoke test: OK")
