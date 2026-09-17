-- Confirms ui/toolbar.lua actually docks like IntelliJ's toolbar row - full tab width, pinned at
-- row 0, pushing every other panel down - REGARDLESS of whether it was opened before or after
-- Project Tree's own `topleft 40vsplit`. Opening the toolbar AFTER other docked panels works by
-- construction (nui.Split's position="top" always promotes to the full-width top edge); opening
-- it BEFORE them relies on toolbar.redock() being called from project_tree.lua's own M.open() -
-- this is the scenario that was actually broken before that call was added (confirmed for real:
-- the toolbar's row shrank down to whatever was left of Project Tree's new column).
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))

local jdm = require("java-debug-model")
jdm.setup({ bufferline_enabled = false }) -- isolate from the tabline occupying row 0, this test cares about the toolbar's OWN window position
local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"

local function toolbar_width()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for _, w in ipairs(wins) do
    local pos = vim.api.nvim_win_get_position(w)
    if pos[1] == 0 and vim.api.nvim_win_get_height(w) == 2 then
      return vim.api.nvim_win_get_width(w)
    end
  end
  return nil
end

local total_width = vim.o.columns

-- Toolbar opened FIRST, then Project Tree - the ordering that used to break full-width docking.
jdm.toolbar.open(root)
vim.cmd("topleft 40vsplit") -- stand-in for project_tree.lua's own split, same tabpage-level modifier
vim.cmd("wincmd p")
local ok_toolbar_mod = require("java-debug-model.ui.toolbar")
ok_toolbar_mod.redock() -- what project_tree.open()/maven_panel.open()/session_manager.open() call internally

local w = toolbar_width()
print("toolbar width after redock: " .. tostring(w) .. " (tab width: " .. total_width .. ")")
assert(w == total_width, "toolbar must span the FULL tab width after redock(), got " .. tostring(w))

print("toolbar layout smoke test: OK")
