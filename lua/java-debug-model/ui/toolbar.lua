-- IntelliJ-style toolbar: ONE docked bar, full tabpage width, carrying the project-name/module
-- selector (left) and "Config: <active config name>" Run/Debug Configuration selector (right) on
-- one row. This is deliberately the ONLY thing left in this bar - the open-buffer TAB row used to
-- render as an extra line in this same buffer, but that made it span the full tabpage width too,
-- including OVER the Project Tree/Maven Panel sidebars - reported for real: "phần tab bar chỉ nằm
-- trên panel editor giống intellij" (the tab bar should sit only above the editor panel, like
-- IntelliJ). It now lives in ui/bufferline.lua instead, attached per-window via Neovim's 'winbar'
-- option to just the real editor window(s) - see that module's own doc comment for why a docked
-- nui.Split (this bar's own mechanism) can never do that (`wincmd K` is inherently full-width).
-- This bar's own full-tabpage width is intentional and NOT the same bug: IntelliJ's own top
-- toolbar strip (module/branch/run-config selectors) spans the whole window width too, sidebar
-- included - it's specifically the TAB row that's scoped to the editor in real IntelliJ.
--
-- Earlier history: this used to be two separate nui.Split windows (this one, plus
-- ui/bufferline.lua's own OWN docked tabbar), stacked via a mutual `redock()` call chain - which
-- got the order right but left a visible seam (every real split draws its own per-window
-- statusline row below its content). Folding the tab row into THIS buffer as an extra line fixed
-- that seam, at the cost of the full-width-over-sidebar problem described above; moving tabs to
-- 'winbar' is what fixes both at once. Before either of those, ui/bufferline.lua used Neovim's
-- global `'tabline'` option, which can never be pushed below any window at all.
--
-- No Run/Debug buttons (running/debugging is keyboard/command-driven: <leader>jr/<leader>jd,
-- :JavaToolbarRun/:JavaToolbarDebug) - a deliberate, still-standing decision. The bar's OWN content
-- is exactly 1 buffer line (the project-name/Config text) - an explicit ask ("chiều cao toolbar 1
-- dòng thay vì 2 dòng như hiện tại", the toolbar's height should be 1 line instead of 2)
-- superseding an EARLIER ask that had wanted 2 ("toolbar cao 2 dòng thôi"). This is a clean 1-row
-- window now, not "1 content line + a free statusline row" the way an even earlier version of
-- this briefly relied on before ui/statusline.lua's own `laststatus = 3` (global-statusline mode)
-- removed per-window statuslines entirely.
--
-- Mouse support (re-added per a later explicit ask, reversing an EARLIER ask that had dropped it):
-- the project-name text opens a module-selector dropdown ('m' key or click - see open_module_menu
-- below), "Config: <name>" opens the Run/Debug Configuration dropdown ('c'/<CR> or click).
-- `getmousepos()` inside the `<LeftRelease>` handler (not `<LeftMouse>` - see M.open's own comment
-- on why) is what makes this possible in a normal (non-floating) buffer at all - no per-cell click
-- callback exists in Neovim, so every click is matched by column range against the hit table
-- recorded at the last render() call.
--
-- This is a DOCKED window (nui.Split, position="top", full width) that becomes part of
-- the actual tiled window layout - like IntelliJ's own toolbar row, it sits ABOVE the editor and
-- pushes every other window down, rather than floating on top of/overlapping buffer text. It's
-- wired into init.lua's reset_layout() alongside Project Tree/Maven Panel/Session Manager so the
-- four form one coherent IDE-style layout that can be closed and restored together - see
-- init.lua's own reset_layout comment for why Dependency Tree is the one panel deliberately left
-- out of that set. The active-config picker itself (open_config_menu) stays a floating nui.Menu -
-- a dropdown popping up over the editor when invoked, then disappearing, is exactly how
-- IntelliJ's own configuration selector behaves too.
--
-- Built on top of the existing config_store.lua/active_config.lua/dap.lua plumbing.
--
-- nui.nvim is an OPTIONAL dependency - every entry point below checks for it first and reports a
-- clear error instead of throwing, so a user who hasn't installed it yet still has every other
-- java-debug-model feature (including config_form.lua's plain vim.ui prompts) working normally.
local config_store = require("java-debug-model.config_store")
local active_config = require("java-debug-model.active_config")
local panel_registry = require("java-debug-model.ui.panel_registry")

local M = {}

local state = {
  split = nil,
  root = nil,
  -- Column ranges (0-indexed, end EXCLUSIVE) for the last render's clickable regions - matched
  -- against `getmousepos().column` by the `<LeftRelease>` handler in M.open below. Both live on
  -- line 1, the bar's only content line.
  project_hit = nil,
  config_hit = nil,
}

local function require_nui()
  local ok_split, Split = pcall(require, "nui.split")
  local ok_menu, Menu = pcall(require, "nui.menu")
  local ok_line, Line = pcall(require, "nui.line")
  local ok_text, Text = pcall(require, "nui.text")
  if not (ok_split and ok_menu and ok_line and ok_text) then
    vim.notify(
      "java-debug-model: toolbar cần nui.nvim (MunifTanjim/nui.nvim) - thêm vào dependencies rồi thử lại.",
      vim.log.levels.ERROR)
    return nil
  end
  return { Split = Split, Menu = Menu, Line = Line, Text = Text }
end

---Solid orange background for the whole bar (an explicit ask: "toolbar chuyển thành màu cam làm
---màu nền" - the toolbar's background should be orange) - JavaToolbarBg is what win_options.
---winhighlight below maps Normal/StatusLine/StatusLineNC to, so it covers the window's own blanked
---statusline row AND any padding space around the text, not just the text segments themselves.
---`default = true` on
---every group here still lets a colorscheme or the user's own `:highlight` override win instead of
---this, same as every other highlight group in this plugin.
local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "JavaToolbarBg", { bg = "#d97706", fg = "#1e1e1e", default = true })
  hl(0, "JavaToolbarConfig", { bg = "#d97706", fg = "#1e1e1e", bold = true, default = true })
  hl(0, "JavaToolbarSep", { bg = "#d97706", fg = "#d97706", default = true })
  hl(0, "JavaToolbarProject", { bg = "#d97706", fg = "#1e1e1e", bold = true, default = true })
end

---True only if the bar's window is ACTUALLY still there - see ui/config_panel.lua's own
---M.is_open comment for why this checks the real window instead of trusting `state.split ~= nil`
---(same stale-state class of bug: closing the bar some way other than 'q'/'<Esc>' would otherwise
---leave a dead winid around for M.open to crash on later).
---@return boolean
function M.is_open()
  return state.split ~= nil and state.split.winid ~= nil and vim.api.nvim_win_is_valid(state.split.winid)
end

---Bar height: 1 REAL buffer line (the project-name/Config text) - an explicit ask ("chiều cao
---toolbar 1 dòng thay vì 2 dòng như hiện tại", the toolbar's height should be 1 line instead of
---the 2 it was) superseding the earlier "toolbar cao 2 dòng thôi" ask.
---@return integer
local function bar_height()
  return 1
end

local function render(nui)
  if not state.split then return end
  -- Belt-and-suspenders alongside M.redock()'s own height fix - render() runs on every
  -- VimResized/WinResized too (see the autocmd in M.open), any of which could just as easily be
  -- the moment something else's layout change nudges this window's height away from
  -- bar_height() despite `winfixheight`.
  if state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
    pcall(vim.api.nvim_win_set_height, state.split.winid, bar_height())
  end
  local cfg = active_config.resolve(state.root, config_store)
  local name = cfg and cfg.name or "(chưa có config)"

  -- Project/module name at the LEFT edge, "Config: <name>" at the RIGHT edge - matching
  -- IntelliJ's own toolbar layout (module selector on the left, Run/Debug Configuration selector
  -- on the right), instead of a bare row with only the right side ever filled in.
  local project_text = "  " .. vim.fn.fnamemodify(state.root or "", ":t") .. "  "
  local config_text = "Config: " .. name .. "  "
  local win_width = state.split.winid and vim.api.nvim_win_get_width(state.split.winid) or 80
  local pad_width = math.max(win_width - #project_text - #config_text, 0)

  -- Hit regions for the `<LeftRelease>` handler in M.open - byte-column ranges (0-indexed, end
  -- EXCLUSIVE) matching `getmousepos().column`'s own byte-index convention, hence plain `#text`
  -- lengths below rather than display width.
  state.project_hit = { start_col = 0, end_col = #project_text }
  state.config_hit = { start_col = #project_text + pad_width, end_col = #project_text + pad_width + #config_text }

  local config_line = nui.Line({
    nui.Text(project_text, "JavaToolbarProject"),
    nui.Text(string.rep(" ", pad_width), "JavaToolbarSep"),
    nui.Text(config_text, "JavaToolbarConfig"),
  })

  vim.api.nvim_buf_set_option(state.split.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.split.bufnr, 0, -1, false, { "" })
  -- NuiLine:render(bufnr, ns_id, linenr_start) - `linenr_start` is 1-indexed; ns_id=-1 lets nui
  -- create its own anonymous highlight namespace each call.
  config_line:render(state.split.bufnr, -1, 1)
  vim.api.nvim_buf_set_option(state.split.bufnr, "modifiable", false)
end

---Runs (no breakpoints) or debugs the currently active config - the shared implementation behind
---<leader>jr/<leader>jd (opts.run_debug_keymaps) and :JavaToolbarRun/:JavaToolbarDebug. No longer
---bound to a keymap on the bar's own window - it has no Run/Debug buttons anymore.
---@param root string
---@param no_debug boolean
function M.run_active(root, no_debug)
  local cfg = active_config.resolve(root, config_store)
  if not cfg then
    vim.notify("java-debug-model: chưa có Run/Debug Configuration nào - dùng :JavaDebugConfigAdd trước.",
      vim.log.levels.WARN)
    return
  end
  -- Lazy require - init.lua requires this module at its own top level, so a top-level require
  -- here back into "java-debug-model" would be a load-order cycle; by the time this function
  -- actually RUNS (a user pressed a key / ran a command), setup() has long since finished and the
  -- module is fully cached, same pattern session.lua/test.lua/session_manager.lua already use.
  local jdm = require("java-debug-model")
  jdm.get_project(root, function(project)
    if not project then return end
    local dap = require("java-debug-model.dap")
    local session_id = dap.launch(project, cfg, {
      open_j9_java_exec = jdm.opts.open_j9_java_exec,
      no_debug = no_debug,
    })
    -- dap.launch returns nil (after its own vim.notify) if the launch never actually happened -
    -- e.g. jdtls hasn't attached yet, so `dap.adapters.java` isn't registered - nothing to focus.
    if not session_id then return end
    -- "khi chạy profile từ toolbar thì panel session cũng hiển thị theo" (launching from the
    -- toolbar should bring the Session Manager panel up too), "nhưng không focus đúng profile
    -- đang chạy" (but it wasn't focusing the row for the profile that was actually launched) -
    -- M.open() alone just opens/keeps the panel without moving the cursor anywhere in particular,
    -- so with several saved configs the launched one could be scrolled off-screen. focus_entry(id)
    -- does both: opens the panel (it calls M.open() itself first) AND scrolls/moves the cursor to
    -- THIS launch's own row, matched by the session_id dap.launch just returned - not by config
    -- name, so two DIFFERENT launches of the SAME config (e.g. restarted) each still resolve to
    -- their own distinct row rather than an ambiguous name lookup picking the wrong one.
    local ok_session_ui, session_manager_ui = pcall(require, "java-debug-model.ui.session_manager")
    if ok_session_ui then session_manager_ui.focus_entry(session_id) end
  end, cfg.maven_profiles)
end

---Selecting/updating a profile from ONE dropdown - matches IntelliJ's own configuration selector,
---which lists every Run/Debug Configuration AND an "Edit Configurations..." entry in the same
---menu. Picking a config sets it active (toolbar re-renders); picking "Edit Configurations..."
---opens ui/config_panel.lua's popup form instead - the "toolbar cho chọn update profile và hiển
---thị popup UI update" piece.
---@param nui table
---@param root string
---@param item table  the node nui.Menu passes to on_submit - `Menu.item(text, data)` merges
---                    `data`'s own fields (here `cfg` or `edit`) directly onto that node, see
---                    nui/menu/init.lua's own Menu.item.
local function apply_menu_choice(nui, root, item)
  if item.edit then
    local jdm = require("java-debug-model")
    jdm.config_panel_open(root)
    return
  end
  active_config.set(root, item.cfg.name)
  render(nui)
  vim.notify("java-debug-model: active config -> " .. item.cfg.name, vim.log.levels.INFO)
end

local function open_config_menu(nui, root)
  local configs = config_store.list(root)
  local items = {}
  for _, cfg in ipairs(configs) do
    table.insert(items, nui.Menu.item(cfg.name, { cfg = cfg }))
  end
  table.insert(items, nui.Menu.separator("", { char = "─", text_align = "left" }))
  table.insert(items, nui.Menu.item("Edit Configurations...", { edit = true }))

  -- `relative = "editor"` explicitly - nui.Popup (which Menu is built on) defaults `relative` to
  -- "win", i.e. "50%" position/size relative to whatever window is CURRENT at mount time. This
  -- menu is opened from the toolbar's own docked split (a real 1-row window, not a floating one),
  -- so without this override the menu would size itself relative to that 1-row window instead of
  -- the actual editor - the same class of bug ui/config_panel.lua's own Layout had (see its own
  -- comment) for the same underlying reason.
  local menu = nui.Menu({
    relative = "editor",
    position = "50%",
    size = { width = 40, height = math.min(#items, 14) },
    border = {
      style = "rounded",
      text = { top = " Run/Debug Configuration ", top_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    lines = items,
    max_width = 40,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "<C-c>", "q" },
      submit = { "<CR>", "<Space>" },
    },
    on_submit = function(item) apply_menu_choice(nui, root, item) end,
  })
  menu:mount()
end

---Module-selector dropdown (IntelliJ's own module dropdown, re-added at the project-name/left
---side of the Config row per an explicit ask). This plugin has no per-module "active module"
---state to switch TO - every DebugConfig already carries its own `module_path`
---(config_store.lua) - so picking a module here does the other IntelliJ-equivalent thing: opens
---(or focuses) the Project Tree and scrolls straight to that module's own node
---(ui/project_tree.lua's M.locate_module), the same as clicking a module in IntelliJ's dropdown
---reveals/selects it in the Project view.
---@param nui table
---@param root string
local function open_module_menu(nui, root)
  local jdm = require("java-debug-model")
  jdm.get_project(root, function(project)
    if not project or #project.modules == 0 then
      vim.notify("java-debug-model: chưa resolve được module nào cho " .. root .. ".", vim.log.levels.WARN)
      return
    end
    local items = {}
    for _, mod in ipairs(project.modules) do
      local label = mod:ga() .. (mod.in_reactor and "" or "  [independent]")
      table.insert(items, nui.Menu.item(label, { mod = mod }))
    end
    local menu = nui.Menu({
      relative = "editor",
      position = "50%",
      size = { width = 50, height = math.min(#items, 14) },
      border = {
        style = "rounded",
        text = { top = " Modules ", top_align = "center" },
      },
      win_options = { winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
    }, {
      lines = items,
      max_width = 50,
      keymap = {
        focus_next = { "j", "<Down>", "<Tab>" },
        focus_prev = { "k", "<Up>", "<S-Tab>" },
        close = { "<Esc>", "<C-c>", "q" },
        submit = { "<CR>", "<Space>" },
      },
      on_submit = function(item)
        local project_tree = require("java-debug-model.ui.project_tree")
        project_tree.locate_module(root, project, item.mod)
      end,
    })
    menu:mount()
  end)
end

---Opens the active-config picker menu (same one the toolbar's own 'c'/<CR> keys or clicking
---"Config: <name>" would) WITHOUT needing the toolbar's own split to exist or be focused first -
---the global-keymap counterpart to r/d's own M.run_active, for <leader>jc (opts.run_debug_keymaps.
---select) to call from any window.
---@param root string
function M.select_config(root)
  local nui = require_nui()
  if not nui then return end
  open_config_menu(nui, root)
end

---Opens the module-selector dropdown (same one the toolbar's own 'm' key or clicking the
---project-name text would) WITHOUT needing the toolbar's own split to exist or be focused first -
---counterpart to M.select_config above.
---@param root string
function M.select_module(root)
  local nui = require_nui()
  if not nui then return end
  open_module_menu(nui, root)
end

---Opens (or re-docks, if already open for a different root) the toolbar for `root` as a real
---split window pinned to the top of the editor - NOT a floating overlay - so it takes its place
---in the tiled layout the same way ui/project_tree.lua's `topleft 40vsplit` does for the Project
---panel. Safe to call while other panels (Project Tree/Maven Panel/Session Manager) are open or
---being (re)opened - `wincmd K` (used internally by nui.Split for position="top") always pins to
---the very top of the CURRENT tab's window tree regardless of what's already split below it.
---@param root string
function M.open(root)
  local nui = require_nui()
  if not nui then return end
  setup_highlights()

  if M.is_open() and state.root ~= root then
    M.close()
  end
  if M.is_open() then
    vim.api.nvim_set_current_win(state.split.winid)
    return
  end
  if state.split then M.close() end -- stale state from a window closed some other way

  state.root = root
  state.split = nui.Split({
    relative = "editor",
    position = "top",
    size = bar_height(),
    enter = false, -- opening the bar shouldn't steal focus from whatever buffer/panel is active
    win_options = {
      winfixheight = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      cursorline = false,
      -- These two are effectively INERT now that ui/statusline.lua turns on `laststatus = 3`
      -- (Neovim's global-statusline mode) - a window-local `'statusline'`/its StatusLine highlight
      -- has nothing left to attach to once there's no more per-window statusline row at all. Kept
      -- anyway as the correct fallback if statusline_enabled is ever turned off (back to Neovim's
      -- default per-window statuslines, where this bar would otherwise show its own raw ruler -
      -- "[No Name] [-]", "1:1" - right below its content, a real, confirmed-for-real bug on its
      -- own before global-statusline mode existed).
      statusline = " ",
      -- Normal:JavaToolbarBg (not NormalFloat) is what actually paints the bar's own orange
      -- background - see setup_highlights() above; StatusLine/StatusLineNC point at the same
      -- group so the blanked statusline row blends into it instead of showing through as a
      -- different color.
      winhighlight = "Normal:JavaToolbarBg,StatusLine:JavaToolbarBg,StatusLineNC:JavaToolbarBg",
    },
    -- bufhidden = "hide" (NOT "wipe", unlike an earlier version of this) - "wipe" destroys this
    -- buffer the INSTANT it stops being displayed anywhere, which is exactly what happens for a
    -- moment when some other buffer takes over this window (e.g. selecting a different tab while
    -- the toolbar happens to be the current window) - by the time ui/panel_registry.lua's global
    -- guard tries to restore this buffer into this window, it was already wiped out from under
    -- it, so restoration silently failed and the intruder was left in place for good (confirmed
    -- for real - every OTHER panel already used "hide" for exactly this reason, this one didn't).
    buf_options = { modifiable = false, buftype = "nofile", swapfile = false, bufhidden = "hide" },
  })
  state.split:mount()
  panel_registry.register(state.split.winid, state.split.bufnr)

  local function map(key, fn)
    state.split:map("n", key, fn, { noremap = true, nowait = true })
  end
  map("c", function() open_config_menu(nui, root) end)
  map("<CR>", function() open_config_menu(nui, root) end)
  map("m", function() open_module_menu(nui, root) end)
  map("q", function() M.close() end)

  -- Mouse support (click-to-open on the project-name/Config text) - dropped in an earlier pass and
  -- now re-added per a later explicit ask. `getmousepos()` reports the ACTUAL click, not wherever
  -- the cursor ends up after Neovim's own default click-handling runs first (moving focus/cursor
  -- into this window) - the guard on `pos.winid` below drops any stray event that isn't actually
  -- on this bar's own window.
  --
  -- `<LeftRelease>`, NOT `<LeftMouse>` - confirmed for real (ui/project_tree.lua hit the exact same
  -- bug first: "lại không resize các panel được nữa rồi") that even a BUFFER/WINDOW-LOCAL mapping
  -- for `<LeftMouse>` breaks mouse-drag border resize for that window, because `<LeftMouse>` is the
  -- PRESS event Neovim itself needs unobstructed to recognize "this click started on a border" in
  -- the first place. `<LeftRelease>` only fires after any actual drag-resize already ran its own
  -- internal `<LeftMouse>`+`<LeftDrag>` handling, so it never gets in the way of that - and for a
  -- plain click (no drag), press and release land on the same spot, so this bar's own click
  -- behavior is unchanged.
  map("<LeftRelease>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= state.split.winid then return end
    local col = pos.column - 1
    if pos.line ~= 1 then return end
    if state.project_hit and col >= state.project_hit.start_col and col < state.project_hit.end_col then
      open_module_menu(nui, root)
    elseif state.config_hit and col >= state.config_hit.start_col and col < state.config_hit.end_col then
      open_config_menu(nui, root)
    end
  end)

  render(nui)

  -- Re-render on resize (VimResized, or the toolbar's own window width changing as other panels
  -- open/close beside it) so the right-aligned text's padding stays correct instead of drifting
  -- once computed for a width that no longer applies.
  vim.api.nvim_create_autocmd(
    { "VimResized", "WinResized" },
    {
      group = vim.api.nvim_create_augroup("JavaDebugModelToolbarResize", { clear = true }),
      callback = function() if M.is_open() then render(nui) end end,
    })

  M.redock()
end

---Re-pins the bar to the full-width top edge of the tabpage - call this after opening/resizing
---any OTHER docked panel (Project Tree's `topleft 40vsplit`, Maven Panel, Session Manager). Those
---panels' own `topleft`-style splits operate at the whole-tabpage level too, so one opened AFTER
---the toolbar visually "steals" the top-left corner from it (confirmed for real: the toolbar's
---row shrinks to whatever's left of the new split's column instead of spanning full width) - a
---cheap `wincmd K` on the toolbar's own window fixes that up again immediately. No-op if the
---toolbar isn't open.
function M.redock()
  if not M.is_open() then return end
  vim.api.nvim_win_call(state.split.winid, function() vim.cmd("wincmd K") end)
  -- `wincmd K` is a window MOVE, but Neovim's default 'equalalways' redistributes every window's
  -- size whenever the layout changes shape this way - `winfixheight` (set on this window at mount
  -- time) is supposed to exempt it from that, but confirmed for real: the bar still ended up
  -- taller than its own configured `size` after redock (an extra "~" end-of-buffer line appearing
  -- below the 1 real content line - "toolbar vẫn cao lắm", the toolbar is still too tall). Forcing
  -- the height back explicitly here is what actually holds it at bar_height() regardless of
  -- whatever internal resize `wincmd K`/'equalalways' just did.
  pcall(vim.api.nvim_win_set_height, state.split.winid, bar_height())
end

function M.close()
  if not state.split then return end
  if state.split.winid then panel_registry.unregister(state.split.winid) end
  pcall(function() state.split:unmount() end)
  state.split = nil
  state.root = nil
end

---@param root string
function M.toggle(root)
  if M.is_open() then
    M.close()
  else
    M.open(root)
  end
end

---Re-renders the bar (e.g. after a config was added/removed/edited elsewhere) - no-op if the
---toolbar isn't currently open.
function M.refresh()
  if not state.split then return end
  local nui = require_nui()
  if nui then render(nui) end
end

return M
