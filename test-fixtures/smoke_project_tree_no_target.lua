package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local tree = require("java-debug-model.ui.project_tree")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local java_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"

local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

vim.cmd("edit " .. java_file)
tree.open(root, project)
local tree_win = vim.api.nvim_get_current_win()

-- close every other window, leaving ONLY the tree window
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if win ~= tree_win then
    pcall(vim.api.nvim_win_close, win, true)
  end
end
assert(#vim.api.nvim_list_wins() == 1, "expected only the tree window to remain")

-- expand to find App.java, then press <CR> - target window is gone, must
-- create a new split rather than replacing the tree's own window
local function find_and_expand(label_pattern)
  local ls = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, l in ipairs(ls) do
    if l:find(label_pattern) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal o")
      return true
    end
  end
  return false
end
find_and_expand("module%-a")
find_and_expand("%[main%]")
find_and_expand("com$")
find_and_expand("example$")
find_and_expand("modulea$")

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local app_line
for i, l in ipairs(lines) do
  if l:find("App%.java") then app_line = i break end
end
assert(app_line, "should find App.java in the expanded tree")
vim.api.nvim_win_set_cursor(0, { app_line, 0 })
vim.cmd("normal \r")

assert(#vim.api.nvim_list_wins() == 2, "should have created a NEW split for the file, total 2 windows now")
assert(vim.api.nvim_win_is_valid(tree_win), "the original tree window must still exist")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(tree_win)):find("project%-tree"),
  "tree window must still show the tree buffer, never replaced")

local other_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if w ~= tree_win then other_win = w end
end
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(other_win)) == java_file,
  "the newly created split should show App.java")

print("project_tree.lua no-target-window fallback smoke test: OK")
