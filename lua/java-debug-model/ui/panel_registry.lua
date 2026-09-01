-- Tracks every "utility" window this plugin's own panels create (Project Tree, Maven Lifecycle,
-- Dependency Tree, Session Manager's list+log) so file-opening code can tell them apart from a
-- REAL editor window when scanning "any other open window" as a fallback target.
--
-- Without this, project_tree.lua's get_or_create_target_win() (the only code here that actually
-- opens arbitrary files into "whatever other window is open") had no way to know a given window
-- belonged to, say, Session Manager's profile list rather than being a normal editor split - it
-- would happily pick THAT window as the file target, silently clobbering the panel with a file
-- buffer until the user closed and reopened it. Confirmed for real: opening a file from
-- :JavaProjectTree while <leader>jsm's Session Manager panel was open landed the file INSIDE the
-- profile list pane.
--
-- Every panel module registers its own window(s) right after creating them, and unregisters on
-- close - a stale/invalid winid left registered is harmless (is_known() checks would just never
-- match a live window again once Neovim recycles the number, and every consumer already
-- vim.api.nvim_win_is_valid()-checks whatever winid it gets back anyway).
local M = {}

local winids = {}

---@param winid integer
function M.register(winid)
  winids[winid] = true
end

---@param winid integer
function M.unregister(winid)
  winids[winid] = nil
end

---@param winid integer
---@return boolean
function M.is_known(winid)
  return winids[winid] == true
end

return M
