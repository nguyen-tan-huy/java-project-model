-- ONE single status bar for the whole Neovim window, living at the very BOTTOM of the screen -
-- not per-window like Vim's own default statusline, and not a separate statusline plugin
-- (lualine.nvim, ...) either. An explicit ask: "bỏ plugin statusline, java-project-model tự tạo
-- statusline riêng chỉ nằm dưới cùng của màn hình như intellij" (drop the statusline plugin,
-- java-debug-model builds its own status bar, living only at the very bottom of the screen, like
-- IntelliJ). IntelliJ's own bottom bar shows a breadcrumb of the CURRENT file's real location -
-- module, then every real folder from the module's own content root down to the file's own
-- directory, then the file's class name (no extension) - built here from the Project model (this
-- plugin's own module/source-root data), not guessed by splitting the raw path on its own.
--
-- `laststatus = 3` is Neovim's own "global statusline" mode - the reason this is ONE bar for the
-- whole tabpage instead of one per split window. `'statusline'` becomes a genuinely GLOBAL option
-- at that point (a window-local override, like ui/panel_registry.lua's own per-panel
-- blank_statusline(), simply has nothing left to attach to and is ignored) - which is also what
-- fixes the earlier "mọi panel đều có thanh trạng thái riêng" complaints for good, as a side
-- effect of switching to this bar rather than something this module has to separately enforce.
--
-- Content is a Lua expression statusline (`%!v:lua...`), re-evaluated by Neovim itself on
-- basically every redraw (cursor move, buffer switch, mode change, ...) - no autocmd-driven
-- re-render loop needed for the CONTENT itself, unlike ui/bufferline.lua's own 'winbar' (a
-- per-window option Neovim does not auto-refresh the value of on its own the same way).
local M = {}

---Escapes '%' for safe use inside a 'statusline' format string - a literal '%' in a class/package
---name (rare but possible) would otherwise be misparsed as a statusline item.
---@param s string
---@return string
local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

---IntelliJ-style breadcrumb for the CURRENT buffer: root project dir name, then the owning
---Module's own dir name (only if it differs - a single-module "project" would otherwise show the
---same name twice), then every real folder from the module's content root down to the file's own
---directory, then the file's own name with its extension stripped (matching IntelliJ's own
---navigation bar, which shows a class by its class name, not its filename).
---
---Reads the project model SYNCHRONOUSLY from whatever's already cached
---(`java-debug-model.get_cached_project`) rather than resolving it fresh - a statusline expression
---runs on every redraw, far too often to kick off an async `mvn` resolution from. Degrades to just
---the bare filename if no root/project/module is resolved yet (e.g. right after opening Neovim,
---before the watcher's first resolve completes).
---@return string
function M.breadcrumb()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or vim.bo[bufnr].buftype ~= "" then return "" end

  local ok_jdm, jdm = pcall(require, "java-debug-model")
  if not ok_jdm then return esc(vim.fn.fnamemodify(path, ":t")) end

  local root = jdm.find_root(bufnr)
  local project = root and jdm.get_cached_project(root)
  local mod = project and project:find_module_for_file(path)
  if not root or not project or not mod then
    return esc(vim.fn.fnamemodify(path, ":t"))
  end

  local crumbs = { vim.fn.fnamemodify(root, ":t") }
  local mod_name = vim.fn.fnamemodify(mod.path, ":t")
  if mod_name ~= crumbs[1] then
    table.insert(crumbs, mod_name)
  end

  if vim.startswith(path, mod.content_root .. "/") then
    local rel_dir = vim.fn.fnamemodify(path:sub(#mod.content_root + 2), ":h")
    if rel_dir ~= "." then
      for seg in rel_dir:gmatch("[^/]+") do
        table.insert(crumbs, seg)
      end
    end
  end

  table.insert(crumbs, vim.fn.fnamemodify(path, ":t:r"))

  local escaped = {}
  for _, c in ipairs(crumbs) do table.insert(escaped, esc(c)) end
  return table.concat(escaped, " %#JavaStatuslineSep#>%#JavaStatuslineBreadcrumb# ")
end

---Right-aligned status signals - the same two this plugin's own info used to feed lualine.nvim's
---`lualine_x` section (see ~/.config/nvim/lua/plugins/ui.lua's own now-disabled lualine spec):
---this plugin's own "something is running" text (status.lua - Maven resolving, jdtls starting, a
---Maven Lifecycle job, a launching debug session) and, separately, which DAP sessions are
---currently live (+ port, once dap_status.lua's own log-scraping has caught it) - both real time
---signals worth keeping even though the bar itself moved from lualine into this plugin.
---@return string
function M.right()
  local parts = {}

  local ok_jdm, jdm = pcall(require, "java-debug-model")
  if ok_jdm then
    local ok_call, text = pcall(jdm.statusline)
    if ok_call and text ~= "" then table.insert(parts, esc(text)) end
  end

  local ok_dap, dap = pcall(require, "dap")
  if ok_dap then
    local ok_status, dap_status = pcall(require, "dap_status")
    local names = {}
    for _, s in pairs(dap.sessions()) do
      local nm = s.config.name:match("^[^:]+") or s.config.name
      local port = ok_status and dap_status.ports[s.config.name]
      if port then nm = nm .. ":" .. port end
      table.insert(names, nm)
    end
    if #names > 0 then table.insert(parts, esc("🐛 " .. table.concat(names, ", "))) end
  end

  return table.concat(parts, "  ")
end

---The full `'statusline'` expression value - `%=` is what pushes M.right()'s own content to the
---bar's right edge, the same way IntelliJ's own bottom bar keeps VCS/encoding icons pinned right
---while the breadcrumb grows from the left.
---@return string
function M.render()
  local ok, result = pcall(function()
    return " %#JavaStatuslineBreadcrumb#" .. M.breadcrumb() .. "%=%#JavaStatuslineRight#" .. M.right() .. " "
  end)
  return ok and result or ""
end

function M.setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "JavaStatuslineBreadcrumb", { link = "StatusLine", default = true })
  hl(0, "JavaStatuslineSep", { link = "Comment", default = true })
  hl(0, "JavaStatuslineRight", { link = "StatusLine", default = true })
end

local STATUSLINE_EXPR = "%!v:lua.require('java-debug-model.ui.statusline').render()"
local AUGROUP = "JavaDebugModelStatusline"

---Turns this bar on for the rest of the session: `laststatus = 3` (Neovim's own global-statusline
---mode) plus pointing `'statusline'` at M.render(). Also re-asserts both on a handful of events a
---statusline plugin's own setup would react to - "bỏ plugin statusline" (drop the statusline
---plugin) is something this module can't do FOR the user (lualine.nvim's own `require("lualine").
---setup(...)` call lives in the user's own Neovim config, a different repo entirely - see
---~/.config/nvim/lua/plugins/ui.lua, now disabled via `enabled = false` rather than deleted, so
---it's a one-line revert if ever wanted back), but re-asserting here means even if some OTHER
---plugin still messes with `&laststatus`/`&statusline` later, this bar wins back the very next
---redraw-worthy event instead of silently staying lost.
function M.enable()
  M.setup_highlights()
  vim.o.laststatus = 3
  vim.o.statusline = STATUSLINE_EXPR

  vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "WinEnter", "ColorScheme" }, {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
    callback = function()
      if vim.o.laststatus ~= 3 then vim.o.laststatus = 3 end
      if vim.o.statusline ~= STATUSLINE_EXPR then vim.o.statusline = STATUSLINE_EXPR end
      M.setup_highlights()
    end,
  })
end

---Turns this bar off - restores Neovim's own per-window statusline default (`laststatus = 2`) and
---clears the custom `'statusline'` expression, e.g. for a user who wants a different statusline
---plugin managing the global bar instead.
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  vim.o.statusline = ""
  vim.o.laststatus = 2
end

return M
