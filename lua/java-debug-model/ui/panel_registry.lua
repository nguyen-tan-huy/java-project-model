-- Tracks every "utility" window this plugin's own panels create (Project Tree, Maven Lifecycle,
-- Dependency Tree, Session Manager's list+log, Toolbar, Config Panel) - both so file-opening code
-- can tell a panel apart from a REAL editor window when scanning "any other open window" as a
-- fallback target (safe_edit_win below), and so a GLOBAL guard (install_guard) can catch a real
-- file buffer landing inside a panel by some path THIS plugin doesn't control at all - `gf`/`gd`/
-- a quickfix jump/manually running `:e` while focus happens to be on a panel. Reported for real
-- twice: once for this plugin's OWN `:edit` calls (layout_state.lua's file-restore, test.lua's
-- "rerun failed") - fixed by routing those through safe_edit_win - and again after that fix
-- ("tôi test mở file vẫn còn mở vào các panel chức năng" / "I tested opening a file, it still
-- opens into the functional panels"), which is what install_guard exists for: it doesn't matter
-- HOW the file got there, only that it did.
--
-- Every panel module registers its own window(s) right after creating them (passing that
-- window's OWN bufnr - the one that should ALWAYS be showing there), and unregisters on close - a
-- stale/invalid winid left registered is harmless (is_known()/the guard would just never match a
-- live window again once Neovim recycles the number, and every consumer already
-- vim.api.nvim_win_is_valid()-checks whatever winid it gets back anyway).
local M = {}

---@type table<integer, integer>  winid -> that window's own rightful bufnr
local winids = {}

---@param winid integer
local function blank_statusline(winid)
  if vim.api.nvim_win_is_valid(winid) then
    pcall(function() vim.wo[winid].statusline = " " end)
  end
end

---@param winid integer
---@param own_bufnr integer  the buffer this window should ALWAYS show - used by install_guard to
---                          detect and undo some OTHER buffer getting placed here instead.
function M.register(winid, own_bufnr)
  winids[winid] = own_bufnr
  blank_statusline(winid)

  -- Every panel calls this right after mounting its own window (nui.Split:mount(), a raw
  -- `vsplit`/`topleft Nvsplit`, ...) - but MOUNTING itself can already fire WinEnter/BufEnter
  -- synchronously, and ui/bufferline.lua's own M.refresh() (subscribed to those same events) reads
  -- `is_known(winid)` to decide whether a window gets the IntelliJ-style tab row's 'winbar'. Fired
  -- BEFORE this call runs, that check sees a not-yet-registered panel window as a plain editor
  -- window and sticks a tab row onto it - confirmed for real, on both ui/toolbar.lua's own bar and
  -- ui/project_tree.lua's tree, each showing a stray tab row instead of (or on top of) their own
  -- content. A `winbar` set this way never gets cleared again on its own once the window IS
  -- correctly registered a moment later - nothing re-runs refresh() for it - so re-triggering a
  -- refresh HERE, now that this winid is registered, is what actually undoes it. Lazy require -
  -- bufferline.lua requires this module at its own top level, so a top-level require back here
  -- would be a load-order cycle; by the time a panel actually calls M.register, every module is
  -- long since fully loaded (same pattern ui/toolbar.lua's own M.run_active uses for
  -- "java-debug-model").
  local ok, bufferline = pcall(require, "java-debug-model.ui.bufferline")
  if ok then bufferline.refresh() end
end

---@param winid integer
function M.unregister(winid)
  winids[winid] = nil
end

---@param winid integer
---@return boolean
function M.is_known(winid)
  return winids[winid] ~= nil
end

local statusline_guard_installed = false

---Keeps every registered panel's own window statusline blank FOREVER, not just once at
---M.register() time. Reported for real: "chỉ có panel editor mới có thanh bar ở cuối panel" (only
---the editor panel should have a status bar at its bottom) - a real (non-floating) window always
---draws a statusline row of its own below its content, and a statusline plugin (lualine.nvim,
---mini.statusline, ...) that manages the `'statusline'` option itself via its OWN WinEnter/
---BufEnter/... autocmds will happily overwrite whatever M.register's blank_statusline() set the
---moment focus moves anywhere - confirmed for real on BOTH ui/toolbar.lua's own bar (full
---mode/branch/location text showing through the orange bar) and ui/project_tree.lua's tree (its
---own "project-tree [-]  10:16" status text at the tree's own bottom edge instead of the editor's).
---Reacts to the SAME kind of events such a plugin would, deferred via `vim.schedule` so this runs
---AFTER whatever that other plugin's own callback already did in the SAME event-loop tick -
---running synchronously in the same autocmd group would leave the outcome dependent on which
---plugin registered its own autocmd first, which is exactly the kind of load-order fragility this
---sidesteps. Idempotent - safe to call every setup() without double-registering the autocmd.
function M.install_statusline_guard()
  if statusline_guard_installed then return end
  statusline_guard_installed = true
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "BufEnter", "VimResized" }, {
    callback = function()
      vim.schedule(function()
        for winid in pairs(winids) do
          blank_statusline(winid)
        end
      end)
    end,
  })
end

---Finds a window safe to open a REAL file into - the current window if it's not one of this
---plugin's own panels, otherwise any other suitable window in the tab, or a fresh vsplit as a
---last resort. Any code in this plugin that's about to run `:edit`/`vim.cmd("edit ...")` etc.
---should call this FIRST and `nvim_set_current_win()` the result, the same way
---project_tree.lua's own get_or_create_target_win() already does for its `<CR>`-driven opens.
---@return integer winid
function M.safe_edit_win()
  local current = vim.api.nvim_get_current_win()
  if not M.is_known(current) and vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not M.is_known(win) and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  -- No safe window exists anywhere in this tab (every window is one of our own panels) - split
  -- one off from wherever we are now rather than clobbering a panel.
  vim.cmd("vsplit")
  return vim.api.nvim_get_current_win()
end

local guard_installed = false

---Installs a GLOBAL, one-time BufWinEnter guard: whenever a real, listed file buffer (buftype ==
---"", has a real path, buflisted) ends up displayed in one of THIS plugin's registered panel
---windows - by ANY means, not just this plugin's own code (`gf`, `gd`, a quickfix jump, the user
---running `:e` while focus happens to be on a panel, ...) - it gets moved OUT to a normal editor
---window (or a fresh vsplit if none exists) and the panel's own rightful buffer is restored in
---its place. Deliberately buftype-gated: a panel's own LEGITIMATE dynamic content changes (e.g.
---ui/session_manager.lua's log pane switching between different sessions' output as the cursor
---moves) are always either `nofile` (a placeholder) or `terminal` (dap-terminal output) - never a
---real listed file buffer - so this never fights normal panel operation, only an actual intruder.
---
---Acts SYNCHRONOUSLY inside the BufWinEnter callback (not deferred via `vim.schedule` like an
---earlier version of this did) - deferring left a brief but real visible flash (reported for
---real: switching tabs while the toolbar's 1-row window happened to be current visibly showed
---the file squeezed into that one row before snapping back a tick later), objectionable enough
---on its own to be worth fixing. Restoring `own_bufnr` into `winid` below DOES itself re-trigger
---this very callback (nvim_win_set_buf fires BufWinEnter same as `:buffer`/`:edit` do) - but that
---nested call immediately hits the `bufnr == own_bufnr` early-return above, so this can't recurse
---any further; there's no separate re-entrancy guard needed for that reason alone.
---Idempotent - safe to call every setup() without double-registering the autocmd.
function M.install_guard()
  if guard_installed then return end
  guard_installed = true
  vim.api.nvim_create_autocmd("BufWinEnter", {
    callback = function(args)
      local winid = vim.api.nvim_get_current_win()
      local own_bufnr = winids[winid]
      if not own_bufnr then return end
      local bufnr = args.buf
      if bufnr == own_bufnr then return end
      if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].buflisted then return end
      if vim.api.nvim_buf_get_name(bufnr) == "" then return end
      if not vim.api.nvim_buf_is_valid(own_bufnr) then return end -- the panel itself is gone

      local target
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= winid and not winids[win] and vim.api.nvim_win_get_config(win).relative == "" then
          target = win
          break
        end
      end

      vim.api.nvim_win_set_buf(winid, own_bufnr)
      if not target then
        vim.api.nvim_set_current_win(winid)
        vim.cmd("vsplit")
        target = vim.api.nvim_get_current_win()
      end
      vim.api.nvim_win_set_buf(target, bufnr)
      vim.api.nvim_set_current_win(target)
    end,
  })
end

return M
