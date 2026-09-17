-- ui/bufferline.lua's jdt_class_label - ported from a user's own external bufferline.nvim config
-- when removing that plugin in favor of java-debug-model's own tab-list row, so a `jdt://`
-- decompiled dependency source still shows a readable "ClassName [artifactId:version]" tab
-- (matching IntelliJ's own "ClassName (library-1.2.3.jar)") instead of the raw URL-encoded buffer
-- name. Verified end to end by mounting ui/toolbar.lua's own bar and reading back its rendered
-- tab-list line (line 3), the same way smoke_bufferline.lua does.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ toolbar_auto_open = false })
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
jdm.toolbar.open(root)

-- fabricate a buffer with a jdt:// name (can't easily open a REAL one without a live jdtls) - just
-- verify the label-parsing helper end to end via a synthetic buffer name.
local scratch = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(scratch, "jdt://contents/<maven:org.springframework:spring-core:5.3.20>/org.springframework.util/Assert.class?=/maven.pomderived=/true=/")
vim.bo[scratch].buflisted = true
vim.api.nvim_set_current_buf(scratch)

local toolbar_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local pos = vim.api.nvim_win_get_position(w)
  if pos[1] == 0 and vim.api.nvim_win_get_height(w) == 3 then toolbar_win = w end
end
assert(toolbar_win, "could not find the toolbar's window")
local buf = vim.api.nvim_win_get_buf(toolbar_win)
local line = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
print("tab-list line: " .. vim.inspect(line))
assert(line:match("Assert"), "must show the class name, not the raw URI")
assert(line:match("spring%-core:5.3.20"), "must show a short artifactId:version label")
assert(not line:match("jdt://"), "must NOT show the raw unreadable jdt:// URI")

print("jdt class label smoke test: OK")
