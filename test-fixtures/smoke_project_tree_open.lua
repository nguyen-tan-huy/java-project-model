package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local tree = require("java-debug-model.ui.project_tree")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local java_file = root .. "/module-a/src/main/java/com/example/modulea/App.java"
local other_file = root .. "/module-b/src/main/java/com/example/moduleb/Greeter.java"

local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

-- 1. open a real editing buffer first (this must become the "target" window)
vim.cmd("edit " .. java_file)
local editing_win = vim.api.nvim_get_current_win()

-- 2. open the tree: should split off a NEW window for the tree, target
-- stays pointed at the editing window.
tree.open(root, project)
local tree_win = vim.api.nvim_get_current_win()
assert(tree_win ~= editing_win, "tree should open in its own window, not replace the editing window")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(tree_win)):find("project%-tree"),
  "current window after tree.open() should show the tree buffer")

-- 3. find the App.java file node and "press <CR>" on it
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local app_line
for i, l in ipairs(lines) do
  if l:find("App%.java") then app_line = i break end
end
if not app_line then
  -- lazily expand module-a -> [main] source root -> package dirs until App.java is visible
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
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find("App%.java") then app_line = i break end
  end
end
assert(app_line, "should find App.java in the (expanded) tree")

vim.api.nvim_win_set_cursor(0, { app_line, 0 })
vim.cmd("normal \r")

-- 4. the editing window must now show App.java, and the tree window must
-- still be showing the tree buffer (NOT replaced by App.java)
local current_win_after_enter = vim.api.nvim_get_current_win()
assert(current_win_after_enter == editing_win,
  "<CR> should switch focus to the remembered target/editing window")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editing_win)) == java_file,
  "editing window should now show App.java")
assert(vim.api.nvim_win_is_valid(tree_win), "tree window must still exist")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(tree_win)):find("project%-tree"),
  "tree window must STILL show the tree buffer, not have been replaced by App.java")

print("project_tree.lua open-file-into-target-window smoke test: OK")
