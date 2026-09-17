-- ui/config_panel.lua's form pane is a REAL editable buffer now (not per-field popups) - move the
-- cursor to a field and edit it with normal Vim editing, <CR> in insert mode confirms instead of
-- inserting a newline, and the value saves to config_store on InsertLeave. Module/JDK stay
-- picker-only (typed text there is discarded, re-rendered back to the real value).
--
-- Headless `:startinsert`/`:stopinsert` don't reliably transition real Insert mode in THIS
-- environment (confirmed with a minimal repro: nvim_get_mode() stayed "n" even after
-- vim.cmd("startinsert") + vim.schedule, so simulating actual keystrokes isn't reliable here) -
-- instead this fires the SAME InsertLeave event a real <Esc>/<CR> would via
-- `nvim_exec_autocmds`, against buffer content set as if the user had just typed it, exercising
-- the real save_line() callback end-to-end (buffer text -> config_store).
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({})
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
jdm.config_store.add(root, {
  name = "InlineEditApp", module_path = root .. "/module-a", main_class = "com.example.modulea.App",
  vm_args = "", program_args = "", env_vars = {}, working_directory = root .. "/module-a", maven_profiles = {},
})

local project
jdm.get_project(root, function(p) project = p end, {})
vim.wait(60000, function() return project ~= nil end, 100)
assert(project, "project resolve failed")

-- This fixture's sample-project dir accumulates DebugConfigs saved by other smoke tests sharing
-- it - M.open() defaults `state.selected_idx` to the ACTIVE config (falling back to index 1 only
-- if none is set), so pin it explicitly rather than assuming "InlineEditApp" lands at index 1.
jdm.active_config.set(root, "InlineEditApp")

jdm.config_panel.open(root, project)
assert(jdm.config_panel.is_open(), "panel should be open")

-- Find the FORM popup's content window - wider of the two windows with keymaps (the border
-- windows have none of their own - see smoke_nui_ui.lua-adjacent tests for the same technique).
local candidates = {}
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local buf = vim.api.nvim_win_get_buf(w)
  if #vim.api.nvim_buf_get_keymap(buf, "n") > 0 then table.insert(candidates, w) end
end
table.sort(candidates, function(a, b) return vim.api.nvim_win_get_width(a) > vim.api.nvim_win_get_width(b) end)
local form_win = candidates[1]
assert(form_win, "could not find the form popup's content window")
local form_buf = vim.api.nvim_win_get_buf(form_win)

local function find_line(pattern)
  for lnum = 1, vim.api.nvim_buf_line_count(form_buf) do
    local line = vim.api.nvim_buf_get_lines(form_buf, lnum - 1, lnum, false)[1]
    if line:match(pattern) then return lnum end
  end
end

-- 1) Typing into a plain text field (VM args) and "leaving insert mode" must save it.
local vm_args_line = find_line("^  VM args:")
assert(vm_args_line, "could not find the VM args field line")
vim.api.nvim_set_current_win(form_win)
vim.api.nvim_win_set_cursor(form_win, { vm_args_line, 0 })
local original = vim.api.nvim_buf_get_lines(form_buf, vm_args_line - 1, vm_args_line, false)[1]
vim.api.nvim_buf_set_lines(form_buf, vm_args_line - 1, vm_args_line, false, { original .. "-Xmx512m" })
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = form_buf })
vim.wait(300)

local cfg
for _, c in ipairs(jdm.config_store.list(root)) do
  if c.name == "InlineEditApp" then cfg = c end
end
print("vm_args after inline edit: " .. vim.inspect(cfg.vm_args))
assert(cfg.vm_args == "-Xmx512m", "InsertLeave on the VM args line must save its typed value")

-- 2) Module/JDK are picker-only - free-typed text on those rows must NOT be saved; the row just
-- gets redrawn back to the real (picker-selected) value.
local module_line = find_line("^  Module:")
assert(module_line, "could not find the Module field line")
local before_module = cfg.module_path
local mline = vim.api.nvim_buf_get_lines(form_buf, module_line - 1, module_line, false)[1]
vim.api.nvim_buf_set_lines(form_buf, module_line - 1, module_line, false, { mline .. "garbage-typed-text" })
vim.api.nvim_win_set_cursor(form_win, { module_line, 0 })
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = form_buf })
vim.wait(300)
for _, c in ipairs(jdm.config_store.list(root)) do
  if c.name == "InlineEditApp" then cfg = c end
end
assert(cfg.module_path == before_module, "Module row must NOT be overwritten by free-typed text - it's picker-only")

print("config_panel inline edit smoke test: OK")
vim.cmd("qa!")
