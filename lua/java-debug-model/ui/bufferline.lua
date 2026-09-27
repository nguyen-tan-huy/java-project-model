-- IntelliJ-style tab row, scoped to just the editor window(s) - NOT the full tabpage width like
-- ui/toolbar.lua's own docked Config row above it. Built on Neovim's per-window 'winbar' option
-- (Neovim >= 0.8): a real per-window title bar that sits above ONE window's own content and stops
-- at that window's own edges - exactly what IntelliJ's own editor tab strip does (it stops where
-- the Project sidebar starts, it doesn't run underneath it).
--
-- This tab row used to live INSIDE ui/toolbar.lua's own combined docked nui.Split buffer (see that
-- module's own doc comment for the history of why THAT merge happened - fixing a visible seam
-- between two separately-docked windows). But a docked `nui.Split(position="top")` always spans
-- the FULL width of the tabpage (that's what `wincmd K` does), sidebar panels included - reported
-- for real: "phần tab bar chỉ nằm trên panel editor giống intellij" (the tab bar should sit only
-- above the editor panel, like IntelliJ). No amount of re-docking fixes that; only a genuinely
-- per-window bar does, which is what 'winbar' is for. ui/toolbar.lua's OWN Config row stays a
-- full-width docked split on purpose - IntelliJ's own top toolbar strip (module/branch/run-config
-- selectors) spans the WHOLE window width too, over the sidebar included, so that part was never
-- the problem.
--
-- 'winbar' is a plain STRING option, not a buffer nui can render Text/Line extmarks into, so tabs
-- here are built as classic 'statusline'-style markup instead: `%#HLGROUP#` switches highlight,
-- and `%{minwid}@FuncName@...text...%X` opens a clickable region carrying `minwid` (here, a
-- buffer number) through to the click handler. `%@` requires a plain Vimscript-visible function
-- name, not a Lua closure, so two tiny Vimscript shims (installed once by M.enable) bridge that
-- syntax into this module's own M.on_switch_click/M.on_close_click.
local panel_registry = require("java-debug-model.ui.panel_registry")

local M = {}

local enabled = false
local AUGROUP = "JavaDebugModelWinbarTabs"

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

---A file opened from inside a jar (gd/references into a library) has a buffer name like
---`jdt://contents/<jar-or-project-ref>/<package>/<Class>.class?<query>` - the raw name (or a
---plain `fnamemodify(..., ":t")` basename) is a long, unreadable URL-encoded mess. Parses out
---just the class name plus a short "artifactId:version" label, matching IntelliJ's own
---"ClassName (library-1.2.3.jar)" tab for a decompiled dependency source - ported from this
---plugin's own earlier external bufferline.nvim config so removing that plugin (an explicit ask)
---didn't regress this.
---@param path string  raw buffer name
---@return string|nil  nil if `path` isn't a jdt:// URI at all
function M.jdt_class_label(path)
  if not path or not path:match("^jdt://") then return nil end
  local jar, _pkg, classfile = path:match("contents/([^/]+)/([%a%d._%-]+)/([^?]+)")
  if not classfile then
    jar, classfile = path:match("contents/([^/]+)/([^?]+)")
  end
  if not classfile then return nil end
  classfile = url_decode(classfile):gsub("%.class$", ""):gsub("%.java$", "")
  local class_name = classfile:match("([^/]+)$") or classfile
  if not jar then return class_name end
  local lib_label = url_decode(jar):gsub("^<", ""):gsub(">$", "")
  -- Shortens "maven:groupId:artifactId:version" -> "artifactId:version".
  local parts = {}
  for p in lib_label:gmatch("[^:]+") do table.insert(parts, p) end
  if #parts >= 2 then
    lib_label = parts[#parts - 1] .. ":" .. parts[#parts]
  end
  return class_name .. " [" .. lib_label .. "]"
end

---Reads one resolved color attribute ("fg"/"bg") from a highlight group, following links.
---@return integer|nil
local function hl_color(name, attr)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not h then return nil end
  return h[attr]
end

---Blends two 24-bit colors - `t` = 0 gives `a`, 1 gives `b`. Used to derive the tab strip's
---background shades from the colorscheme's own Normal bg instead of hard-coding a palette.
local function blend(a, b, t)
  if not a then return b end
  if not b then return a end
  local function ch(c, shift) return math.floor(c / 2 ^ shift) % 256 end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local v = math.floor(ch(a, shift) * (1 - t) + ch(b, shift) * t + 0.5)
    out = out + v * 2 ^ shift
  end
  return out
end

-- Resolved backgrounds, reused by icon_hl() to give devicon glyphs the same bg as their tab.
local colors = {}

---bufferline.nvim-style palette derived from the active colorscheme: the active tab shares the
---editor's own Normal bg (so it visually "opens into" the buffer below), inactive tabs and the
---empty fill sit on progressively darker shades, and a thin accent bar marks the selected tab.
---Re-run on ColorScheme so switching themes doesn't leave stale colors behind.
function M.setup_highlights()
  local hl = vim.api.nvim_set_hl
  local normal_bg = hl_color("Normal", "bg") or 0x1e1e2e
  local normal_fg = hl_color("Normal", "fg") or 0xcdd6f4
  local dim_fg = hl_color("Comment", "fg") or blend(normal_fg, normal_bg, 0.5)
  local accent = hl_color("Function", "fg") or hl_color("Directory", "fg") or normal_fg
  local modified = hl_color("DiagnosticWarn", "fg") or hl_color("WarningMsg", "fg") or accent
  local fill_bg = blend(normal_bg, 0x000000, 0.35)
  local inactive_bg = blend(normal_bg, 0x000000, 0.18)
  colors = { active = normal_bg, inactive = inactive_bg }

  hl(0, "JavaTabbarFill", { bg = fill_bg })
  hl(0, "JavaTabbarActive", { fg = normal_fg, bg = normal_bg, bold = true })
  hl(0, "JavaTabbarInactive", { fg = dim_fg, bg = inactive_bg })
  hl(0, "JavaTabbarIndicator", { fg = accent, bg = normal_bg })
  hl(0, "JavaTabbarIndicatorInactive", { fg = inactive_bg, bg = inactive_bg })
  hl(0, "JavaTabbarModifiedActive", { fg = modified, bg = normal_bg })
  hl(0, "JavaTabbarModifiedInactive", { fg = modified, bg = inactive_bg })
  hl(0, "JavaTabbarCloseActive", { fg = normal_fg, bg = normal_bg })
  hl(0, "JavaTabbarCloseInactive", { fg = dim_fg, bg = inactive_bg })
  hl(0, "JavaTabbarLib", { fg = dim_fg, bg = normal_bg, italic = true })
  hl(0, "JavaTabbarLibInactive", { fg = dim_fg, bg = inactive_bg, italic = true })
  hl(0, "JavaTabbarSep", { fg = fill_bg, bg = fill_bg })
end

local icon_hl_cache = {}

---Devicon highlight groups carry their own bg (usually none), which would punch a hole in the
---tab's background - derive a per-(icon, state) group with the icon's fg on the tab's own bg.
---@param base string|nil  devicons highlight group
---@param active boolean
---@return string
local function icon_hl(base, active)
  local fallback = active and "JavaTabbarActive" or "JavaTabbarInactive"
  if not base then return fallback end
  local name = "JavaTabbarIcon" .. base:gsub("[^%w]", "") .. (active and "Active" or "Inactive")
  if not icon_hl_cache[name] then
    vim.api.nvim_set_hl(0, name, {
      fg = hl_color(base, "fg"),
      bg = active and colors.active or colors.inactive,
    })
    icon_hl_cache[name] = true
  end
  return name
end

---nvim-web-devicons is OPTIONAL (same stance as nui.nvim in ui/toolbar.lua) - a missing/absent
---dependency just means no icon is drawn, never an error.
---@param name string  raw buffer name (path)
---@return string|nil icon, string|nil hl_group
local function get_icon(name)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then return nil, nil end
  local ext = name:match("%.([%w_]+)$")
  local basename = vim.fn.fnamemodify(name, ":t")
  if name:match("^jdt://") then ext, basename = "java", "x.java" end
  local icon, hl_group = devicons.get_icon(basename, ext, { default = true })
  return icon, hl_group
end

---Escapes '%' for safe use inside a 'winbar'/'statusline' format string - a literal '%' in a
---filename (rare but possible) would otherwise be misparsed as a statusline item.
---@param s string
---@return string
local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

---Builds the 'winbar' value for one specific editor window - "active" tab highlighting is keyed
---off THAT window's own displayed buffer (`nvim_win_get_buf(winid)`), not whatever the globally
---current window happens to be, so two editor splits each correctly highlight their OWN open file
---(matching IntelliJ, where each split's own tab strip highlights its own selected tab).
---Each tab renders as `▎ <icon> Name [lib]  ●/󰅖 ` - an accent bar on the selected tab, a dot for
---unsaved changes in place of the close button (bufferline.nvim's convention).
---@param winid integer
---@return string
function M.winbar_string(winid)
  if not vim.api.nvim_win_is_valid(winid) then return "" end
  local current = vim.api.nvim_win_get_buf(winid)
  local out = {}
  local any = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted and vim.bo[bufnr].buftype == "" then
      any = true
      local active = bufnr == current
      local sfx = active and "Active" or "Inactive"
      local name = vim.api.nvim_buf_get_name(bufnr)
      local label = M.jdt_class_label(name) or (name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]")
      local lib
      label, lib = label:match("^(.-) (%[.+%])$") or label, label:match(" (%[.+%])$")
      local tab_hl = "JavaTabbar" .. sfx
      local icon, base_icon_hl = get_icon(name)

      table.insert(out, string.format("%%%d@JavaDebugModelTabSwitchClick@", bufnr))
      table.insert(out, string.format("%%#JavaTabbarIndicator%s#▎",
        active and "" or "Inactive"))
      table.insert(out, string.format("%%#%s# ", tab_hl))
      if icon then
        table.insert(out, string.format("%%#%s#%s %%#%s#", icon_hl(base_icon_hl, active), esc(icon), tab_hl))
      end
      table.insert(out, esc(label))
      if lib then
        table.insert(out, string.format(" %%#JavaTabbarLib%s#%s%%#%s#", active and "" or "Inactive", esc(lib), tab_hl))
      end
      table.insert(out, "  %X")
      if vim.bo[bufnr].modified then
        table.insert(out, string.format("%%#JavaTabbarModified%s#●", sfx))
      else
        table.insert(out, string.format("%%#JavaTabbarClose%s#%%%d@JavaDebugModelTabCloseClick@󰅖%%X", sfx, bufnr))
      end
      table.insert(out, string.format("%%#%s#  ", tab_hl))
      table.insert(out, "%#JavaTabbarSep#▕")
    end
  end
  if not any then
    table.insert(out, "%#JavaTabbarInactive# (no open buffers) ")
  end
  table.insert(out, "%#JavaTabbarFill#")
  return table.concat(out)
end

---Click-to-switch, invoked (via the Vimscript shim) with `minwid` = the clicked tab's bufnr.
---Neovim moves focus to the clicked window BEFORE running the click handler, same as a normal
---`<LeftMouse>` click would, so `nvim_get_current_win()` here is already the right editor window.
---@param minwid string|integer  Vimscript passes this through as a Number, Lua sees it either way
function M.on_switch_click(minwid)
  local bufnr = tonumber(minwid)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
end

---Click-to-close (the tab row's own "x" glyph). Refuses on an unsaved buffer rather than silently
---discarding changes - matches IntelliJ's own tab-close prompt in spirit, just as a plain warning
---instead of a save/discard/cancel dialog (this plugin has no modal-dialog UI to reuse here, and a
---hard refusal is the safer default of the two).
---@param minwid string|integer
function M.on_close_click(minwid)
  local bufnr = tonumber(minwid)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].modified then
    vim.notify("java-debug-model: buffer còn thay đổi chưa lưu - lưu (:w) trước khi đóng tab.",
      vim.log.levels.WARN)
    return
  end
  -- Move every window still showing this buffer onto another listed buffer first - a plain
  -- buffer delete would otherwise close the editor window itself (or leave a stale tab behind).
  local alt
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= bufnr and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and vim.bo[b].buftype == "" then
      alt = b
      if b > bufnr then break end
    end
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if alt then
      vim.api.nvim_win_set_buf(winid, alt)
    else
      vim.api.nvim_win_call(winid, function() vim.cmd("enew") end)
    end
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
  M.refresh()
end

---True for a window this row should actually attach to: a real (non-floating) window that isn't
---one of this plugin's own panels (Project Tree/Maven Panel/Session Manager/the toolbar's own
---docked split) - panel_registry.lua is the single source of truth for "which windows are ours"
---already used by safe_edit_win()/install_guard() for the same distinction.
---@param winid integer
---@return boolean
local function is_editor_win(winid)
  return not panel_registry.is_known(winid) and vim.api.nvim_win_get_config(winid).relative == ""
end

---Recomputes and reassigns 'winbar' on every current real editor window - cheap enough (string
---formatting only) to call from every relevant autocmd rather than diffing what actually changed.
---Also actively CLEARS 'winbar' on any window that ISN'T (or no longer is) a real editor window -
---a panel's own window can briefly look like a plain editor window to is_editor_win() for the
---couple of ticks between it being created and panel_registry.register() actually running (that
---call itself now also triggers a refresh - see panel_registry.lua's own M.register comment for
---the confirmed repro), and without this else-branch a tab row set during that gap would never
---get cleared again on its own afterward.
function M.refresh()
  if not enabled then return end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      if is_editor_win(winid) then
        vim.wo[winid].winbar = M.winbar_string(winid)
      elseif vim.wo[winid].winbar ~= "" then
        pcall(function() vim.wo[winid].winbar = "" end)
      end
    end
  end
end

local shims_installed = false

---Installs the two Vimscript click shims once - `%@` needs a plain global function name it can
---call directly; `v:lua.require(...)` inside them is what actually reaches back into this
---module's own Lua click handlers.
local function install_click_shims()
  if shims_installed then return end
  shims_installed = true
  vim.cmd([[
    function! JavaDebugModelTabSwitchClick(minwid, clicks, button, mods)
      call v:lua.require('java-debug-model.ui.bufferline').on_switch_click(a:minwid)
    endfunction
    function! JavaDebugModelTabCloseClick(minwid, clicks, button, mods)
      call v:lua.require('java-debug-model.ui.bufferline').on_close_click(a:minwid)
    endfunction
  ]])
end

---Turns the tab row on for the rest of the session - called once from init.lua's setup() when
---opts.bufferline_enabled is true. Idempotent.
function M.enable()
  if enabled then return end
  enabled = true
  M.setup_highlights()
  install_click_shims()
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufAdd", "BufDelete", "BufWipeout", "BufModifiedSet", "WinEnter", "WinNew", "VimResized" },
    {
      group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
      -- BufDelete/BufWipeout fire while the buffer is still listed, so a synchronous refresh
      -- would still draw the tab being closed - defer until the deletion has finished.
      callback = function() vim.schedule(M.refresh) end,
    })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    callback = function()
      icon_hl_cache = {}
      M.setup_highlights()
      M.refresh()
    end,
  })
  M.refresh()
end

---Turns the tab row off and blanks 'winbar' on every window it had set - opts.bufferline_enabled
---= false, or a user running a separate bufferline plugin instead.
function M.disable()
  if not enabled then return end
  enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      pcall(function() vim.wo[winid].winbar = "" end)
    end
  end
end

---@return boolean
function M.is_enabled()
  return enabled
end

return M
