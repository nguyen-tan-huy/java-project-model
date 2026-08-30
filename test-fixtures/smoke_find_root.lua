package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local jdm = require("java-debug-model")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local java_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"

-- 1. open a real java file inside the project: root resolves correctly
vim.cmd("edit " .. java_file)
local resolved1 = jdm._find_root(0)
assert(resolved1 == root, "expected root=" .. root .. " got " .. tostring(resolved1))
print("real java buffer -> root resolved correctly: " .. resolved1)

-- 2. switch to one of the plugin's own scratch UI buffers (e.g. what
-- :JavaMavenPanel/:JavaProjectTree leave focused) - find_root must NOT fall
-- back to cwd, it must remember the last real root.
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(scratch, "java-debug-model://maven-panel")
vim.api.nvim_set_current_buf(scratch)
local resolved2 = jdm._find_root(0)
assert(resolved2 == root,
  "expected root to fall back to last real root (" .. root .. "), got " .. tostring(resolved2))
print("scratch UI panel buffer -> correctly falls back to last real root: " .. resolved2)

-- 3. a completely unnamed/empty buffer (e.g. `:enew`) behaves the same way
vim.cmd("enew")
local resolved3 = jdm._find_root(0)
assert(resolved3 == root, "expected unnamed buffer to also fall back to last real root, got " .. tostring(resolved3))
print("unnamed buffer -> correctly falls back to last real root: " .. resolved3)

print("find_root scratch-buffer fallback smoke test: OK")
