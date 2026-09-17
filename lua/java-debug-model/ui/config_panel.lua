-- IntelliJ "Edit Configurations" dialog equivalent, built with nui.nvim: a persistent LEFT list
-- (still select-only - <CR>/click to pick a config, 'a'/'d' to add/delete) of every saved
-- DebugConfig (config_store.list(root)), and a RIGHT form panel that's a REAL, directly editable
-- Neovim buffer - move the cursor to a field's value and edit it with normal Vim commands
-- (i/a/A/cw/...), <CR> in insert mode confirms (same as leaving insert mode) instead of inserting
-- a newline, and the field saves to config_store the moment you leave insert mode. This replaced
-- an earlier version of this panel that opened a separate floating nui.Input/nui.Menu box per
-- field - reported for real as feeling disconnected/unclear compared to just editing text
-- directly, an explicit ask for "bên phải để edit như buffer nvim" (make the right side edit like
-- a normal Neovim buffer). Module/JDK stay picker-only (nui.Menu, via open_menu below) since
-- those need to resolve to a real module/JDK path, not arbitrary typed text - "edit" is not a
-- content buffer field for them here (from the same explicit ask). Fixes the "settings profile
-- thực hiện trên panel" piece (profile settings done in a panel), replacing config_form.lua's
-- sequential vim.ui.input chain with a real always-visible panel. config_form.lua itself is left
-- untouched and still works (e.g. from :JavaDebugConfigAdd/:JavaDebugConfigFromFile) for anyone
-- who prefers the quick prompt flow - this is an additional, richer entry point over the SAME
-- config_store data, not a replacement.
--
-- nui.nvim is OPTIONAL - require_nui() below reports a clear error (falling back to nothing, the
-- caller keeps using config_form.lua/vim.ui prompts) if it isn't installed.
local config_store = require("java-debug-model.config_store")
local active_config = require("java-debug-model.active_config")
local panel_registry = require("java-debug-model.ui.panel_registry")

local M = {}

local state = {
  layout = nil,
  list_popup = nil,
  form_popup = nil,
  root = nil,
  project = nil,
  configs = nil,       -- config_store.list(root) snapshot as of last render
  selected_idx = nil,  -- index into state.configs, or nil for none/"+ New"
  -- form_popup line number -> field key, rebuilt every render
  field_line_map = {},
}

local FIELDS = {
  { key = "name", label = "Name" },
  { key = "module_path", label = "Module" },
  { key = "main_class", label = "Main class" },
  { key = "vm_args", label = "VM args" },
  { key = "program_args", label = "Program args" },
  { key = "env_vars", label = "Env vars" },
  { key = "working_directory", label = "Working directory" },
  { key = "maven_profiles", label = "Maven profiles" },
  { key = "jdk_path", label = "JDK" },
}

local function require_nui()
  local ok_layout, Layout = pcall(require, "nui.layout")
  local ok_split, Split = pcall(require, "nui.split")
  local ok_popup, Popup = pcall(require, "nui.popup")
  local ok_menu, Menu = pcall(require, "nui.menu")
  if not (ok_layout and ok_split and ok_popup and ok_menu) then
    vim.notify(
      "java-debug-model: Config Panel cần nui.nvim (MunifTanjim/nui.nvim) - thêm vào dependencies rồi thử lại.",
      vim.log.levels.ERROR)
    return nil
  end
  return { Layout = Layout, Split = Split, Popup = Popup, Menu = Menu }
end

local input_highlights_defined = false
---Distinct background/border colors for the Module/JDK nui.Menu picker (open_menu below) so it
---visually stands out from the list/form panels behind it instead of blending into the same
---static field text, making it unclear an input box was even there to click/type into. Linked to
---`Visual`/`Question`/`Title` (not hardcoded hex) so it still looks reasonable across different
---colorschemes; `default = true` lets a user override these in their own config.
local function setup_input_highlights()
  if input_highlights_defined then return end
  input_highlights_defined = true
  local hl = vim.api.nvim_set_hl
  hl(0, "JavaConfigPanelInputNormal", { link = "Visual", default = true })
  hl(0, "JavaConfigPanelInputBorder", { link = "Question", default = true })
  -- IncSearch (not CursorLine/Visual) - reported for real that plain `cursorline=true` alone was
  -- still too subtle to spot in this panel. IncSearch is deliberately the loudest, most
  -- attention-grabbing highlight group nearly every colorscheme defines distinctly (it's what
  -- jumps out at you mid-search), so linking the CURRENT LINE to it here (only inside this
  -- panel's own two windows, via winhighlight - the user's real CursorLine elsewhere is
  -- untouched) makes the cursor's row unmistakable regardless of theme.
  hl(0, "JavaConfigPanelCursorLine", { link = "IncSearch", default = true })
end

---A real floating nui.Menu (bordered, `relative = "editor"`) for a selection-style field (Module,
---JDK) - replaces `vim.ui.select`; Module/JDK stay picker-only (see this file's own top comment),
---everything else is edited directly in the form buffer now.
---@param nui table
---@param label string
---@param items {label: string, value: any}[]
---@param on_submit fun(value: any)
local function open_menu(nui, label, items, on_submit)
  setup_input_highlights()
  local menu_items = {}
  for _, item in ipairs(items) do
    table.insert(menu_items, nui.Menu.item(item.label, { value = item.value }))
  end
  local menu = nui.Menu({
    relative = "editor",
    position = "50%",
    size = { width = 50, height = math.min(#menu_items, 14) },
    border = { style = "rounded", text = { top = " " .. label .. " ", top_align = "center" } },
    win_options = { winhighlight = "Normal:JavaConfigPanelInputNormal,FloatBorder:JavaConfigPanelInputBorder,CursorLine:PmenuSel" },
  }, {
    lines = menu_items,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "<C-c>", "q" },
      submit = { "<CR>", "<Space>" },
    },
    on_submit = function(item) on_submit(item.value) end,
  })
  menu:mount()
  vim.cmd("redraw")
end

local function parse_env_vars(text)
  local env = {}
  if not text or text == "" then return env end
  for pair in text:gmatch("[^,]+") do
    local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then env[k] = v end
  end
  return env
end

local function format_env_vars(env)
  local parts = {}
  for k, v in pairs(env or {}) do
    table.insert(parts, k .. "=" .. v)
  end
  return table.concat(parts, ",")
end

local function module_label(project, module_path)
  local mod = project:find_module_by_path(module_path)
  return mod and mod:ga() or module_path
end

local function jdk_label(jdk_path)
  if not jdk_path then return "(mặc định - JAVA_HOME/PATH hiện tại)" end
  local ok_jdk, jdk = pcall(require, "jdk")
  if not ok_jdk then return jdk_path end
  return jdk.ee_name(jdk.major_version(jdk_path)) .. " :: " .. jdk_path
end

local function field_display(project, cfg, key)
  if key == "module_path" then return module_label(project, cfg.module_path) end
  if key == "env_vars" then return format_env_vars(cfg.env_vars) end
  if key == "maven_profiles" then return table.concat(cfg.maven_profiles or {}, ",") end
  if key == "jdk_path" then return jdk_label(cfg.jdk_path) end
  return tostring(cfg[key] or "")
end

local function render_list()
  if not (state.list_popup and state.configs) then return end
  local bufnr = state.list_popup.bufnr
  local lines = {}
  for i, cfg in ipairs(state.configs) do
    local marker = (i == state.selected_idx) and "> " or "  "
    table.insert(lines, marker .. cfg.name)
  end
  table.insert(lines, "")
  table.insert(lines, "  + New config  (a)")
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

---Rebuilds the form buffer from `state.configs[state.selected_idx]` - this is the SINGLE source
---of truth the buffer always gets reset back to (called after every save, so a field's on-screen
---text can never drift from what's actually in config_store). `state.field_line_map[lnum]` records
---`{ key, prefix_len }` for each field row - `prefix_len` is the byte offset where that row's
---EDITABLE value starts (right after "  <label>: "), used by save_line() below to know which part
---of the line is the actual value vs. just the label prefix.
local function render_form()
  if not state.form_popup then return end
  local bufnr = state.form_popup.bufnr
  local cfg = state.selected_idx and state.configs[state.selected_idx]
  state.field_line_map = {}

  local lines = {}
  if not cfg then
    lines = { "", "  Chọn 1 config bên trái (hoặc 'a' để tạo mới)." }
  else
    table.insert(lines, "")
    for _, field in ipairs(FIELDS) do
      local lnum = #lines + 1
      local prefix = string.format("  %-18s ", field.label .. ":")
      state.field_line_map[lnum] = { key = field.key, prefix_len = #prefix }
      table.insert(lines, prefix .. field_display(state.project, cfg, field.key))
    end
    table.insert(lines, "")
    table.insert(lines, "  Gõ trực tiếp để sửa field (i/a/cw/...) - Module/JDK: <CR> để chọn")
    table.insert(lines, "  Tab/S-Tab: sang danh sách config   d: xoá config này   q: đóng panel")
  end

  -- Left as `modifiable = true` (NOT toggled back off like list_popup) - this pane is meant to be
  -- edited directly like a normal buffer, per the explicit ask.
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function refresh()
  state.configs = config_store.list(state.root)
  if state.selected_idx and not state.configs[state.selected_idx] then
    state.selected_idx = #state.configs > 0 and 1 or nil
  end
  render_list()
  render_form()
end

---@return table|nil DebugConfig currently shown in the form
local function current_config()
  return state.selected_idx and state.configs[state.selected_idx]
end

local function save_current(fields)
  local cfg = current_config()
  if not cfg then return end
  for k, v in pairs(fields) do cfg[k] = v end
  config_store.add(state.root, cfg)
  refresh()
  local ok_toolbar, toolbar = pcall(require, "java-debug-model.ui.toolbar")
  if ok_toolbar then toolbar.refresh() end
end

---Module/JDK are the only two fields still picker-only (see this file's own top comment for why)
---- <CR>/click on either opens a nui.Menu the same way it always has.
local function edit_field(key)
  local cfg = current_config()
  if not cfg then return end
  local nui = require_nui()
  if not nui then return end

  if key == "module_path" then
    local items = {}
    for _, mod in ipairs(state.project.modules) do
      table.insert(items, { label = mod:ga(), value = mod.path })
    end
    open_menu(nui, "Module", items, function(path) save_current({ module_path = path }) end)
    return
  end

  if key == "jdk_path" then
    local ok_jdk, jdk = pcall(require, "jdk")
    if not ok_jdk then
      vim.notify("java-debug-model: lua/jdk.lua not available", vim.log.levels.ERROR)
      return
    end
    local items = { { label = "(mặc định - JAVA_HOME/PATH hiện tại)", value = nil } }
    for _, path in ipairs(jdk.list()) do
      table.insert(items, { label = jdk.ee_name(jdk.major_version(path)) .. " :: " .. path, value = path })
    end
    open_menu(nui, "JDK", items, function(path) save_current({ jdk_path = path }) end)
    return
  end
end

---Called on InsertLeave for the form buffer - reads back whatever the user just typed on the
---CURRENT line and saves it to config_store. Module/JDK are picker-only (see edit_field above),
---so an edit there is discarded and the row is just redrawn back to its real value - this is the
---only guard against free-typing into those two rows; every other field's typed text is trusted
---and saved as-is, same as editing any other normal buffer.
---@param lnum integer 1-based line the cursor was on when insert mode ended
local function save_line(lnum)
  local info = state.field_line_map[lnum]
  if not info then return end
  if info.key == "module_path" or info.key == "jdk_path" then
    render_form()
    return
  end
  local line = vim.api.nvim_buf_get_lines(state.form_popup.bufnr, lnum - 1, lnum, false)[1] or ""
  local value = line:sub(info.prefix_len + 1)
  if info.key == "env_vars" then
    save_current({ env_vars = parse_env_vars(value) })
  elseif info.key == "maven_profiles" then
    save_current({ maven_profiles = (value ~= "" and vim.split(value, ",")) or {} })
  else
    save_current({ [info.key] = value })
  end
end

local function delete_selected()
  local cfg = current_config()
  if not cfg then return end
  local nui = require_nui()
  if not nui then return end
  open_menu(nui, "Xoá '" .. cfg.name .. "'?", { { label = "Huỷ", value = false }, { label = "Xoá", value = true } },
    function(confirmed)
      if confirmed then
        config_store.remove(state.root, cfg.name)
        refresh()
      end
    end)
end

---Creates a new config with a default unique name and selects it - no separate "name?" prompt
---needed since the Name field is directly editable now: this just lands the cursor there,
---already in insert mode, ready to type the real name immediately.
local function add_new()
  if #state.project.modules == 0 then
    vim.notify("java-debug-model: no modules in the project model", vim.log.levels.WARN)
    return
  end
  local existing_names = {}
  for _, c in ipairs(state.configs) do existing_names[c.name] = true end
  local name, n = "NewConfig", 1
  while existing_names[name] do
    n = n + 1
    name = "NewConfig" .. n
  end
  local cfg = {
    name = name,
    module_path = state.project.modules[1].path,
    main_class = "",
    vm_args = "",
    program_args = "",
    env_vars = {},
    working_directory = state.project.modules[1].content_root,
    maven_profiles = {},
    jdk_path = nil,
  }
  config_store.add(state.root, cfg)
  refresh()
  for i, c in ipairs(state.configs) do
    if c.name == name then state.selected_idx = i end
  end
  render_list()
  render_form()

  for lnum, info in pairs(state.field_line_map) do
    if info.key == "name" then
      vim.api.nvim_set_current_win(state.form_popup.winid)
      vim.api.nvim_win_set_cursor(state.form_popup.winid, { lnum, info.prefix_len })
      -- "C" (change-to-end-of-line) clears the generated default name and drops straight into
      -- insert mode at that position - types over it immediately instead of having to select/
      -- delete the placeholder first.
      vim.cmd("normal! C")
    end
  end
end

---True only if the panel's window is ACTUALLY still there - not just whether `state.layout` is
---non-nil. A user closing the popup some way other than the 'q'/'<Esc>' keymaps this module sets
---(`<C-w>c`, `:close`, `:bd`, ...) leaves `state.layout`/`state.list_popup` sitting in module state
---with a winid that no longer points at a live window - checked for real here instead of trusting
---that state (confirmed for real: opening the panel again afterward crashed inside
---`nvim_set_current_win` with "Invalid 'win': Expected Lua number", because `state.list_popup`
---was a stale table whose `.winid` had already gone away).
---@return boolean
function M.is_open()
  return state.list_popup ~= nil and state.list_popup.winid ~= nil
    and vim.api.nvim_win_is_valid(state.list_popup.winid)
end

function M.close()
  if not state.layout then return end
  if state.list_popup and state.list_popup.winid then panel_registry.unregister(state.list_popup.winid) end
  if state.form_popup and state.form_popup.winid then panel_registry.unregister(state.form_popup.winid) end
  pcall(function() state.layout:unmount() end)
  state.layout, state.list_popup, state.form_popup = nil, nil, nil
  state.root, state.project, state.configs, state.selected_idx = nil, nil, nil, nil
end

---Opens (or focuses, if already open for a different root) the Config Panel.
---@param root string
---@param project table Project
function M.open(root, project)
  local nui = require_nui()
  if not nui then return end

  if M.is_open() and state.root ~= root then M.close() end
  if M.is_open() then
    vim.api.nvim_set_current_win(state.list_popup.winid)
    return
  end
  -- Stale state left behind by a window closed some other way than this module's own 'q'/'<Esc>'
  -- (see M.is_open's own comment) - tear it down before rebuilding from scratch.
  if state.layout then M.close() end

  state.root, state.project = root, project

  -- A custom, guaranteed-visible CursorLine color (JavaConfigPanelCursorLine, defined in
  -- setup_input_highlights below) - reported for real as still very hard to spot with plain
  -- `cursorline = true` alone, since that just uses the user's OWN colorscheme's CursorLine
  -- group, which can be too subtle in a floating window. Overriding CursorLine specifically here
  -- (via winhighlight, not touching the user's actual CursorLine group anywhere else) guarantees
  -- it stands out in this panel regardless of theme.
  setup_input_highlights()
  state.list_popup = nui.Popup({
    border = { style = "rounded", text = { top = " Run/Debug Configurations ", top_align = "center" } },
    buf_options = { modifiable = false },
    win_options = { cursorline = true, winhighlight = "CursorLine:JavaConfigPanelCursorLine" },
  })
  state.form_popup = nui.Popup({
    border = { style = "rounded", text = { top = " Settings ", top_align = "center" } },
    -- modifiable=true (unlike list_popup) - this pane is a real editable buffer now, per the
    -- explicit ask to make it "edit như buffer nvim" instead of opening separate popups per field.
    buf_options = { modifiable = true },
    win_options = { cursorline = true, winhighlight = "CursorLine:JavaConfigPanelCursorLine" },
  })

  -- nui.Layout defaults `relative` to "win" (see nui/layout/init.lua's own `defaults(options.relative,
  -- "win")`) - i.e. "80%"/"60%" size relative to whatever window happens to be CURRENT at mount
  -- time, not the whole editor. This panel is opened from ui/toolbar.lua's config-select menu
  -- (itself a small floating window) via the "Edit Configurations..." entry, and from a nui.Menu
  -- that's still focused when this runs - confirmed for real: without an explicit `relative =
  -- "editor"` here, the whole panel collapsed down to that menu's own tiny window size instead of
  -- covering 80%/60% of the actual editor.
  state.layout = nui.Layout(
    { relative = "editor", position = "50%", size = { width = "80%", height = "60%" } },
    nui.Layout.Box({
      nui.Layout.Box(state.list_popup, { size = "30%" }),
      nui.Layout.Box(state.form_popup, { size = "70%" }),
    }, { dir = "row" })
  )
  state.layout:mount()
  panel_registry.register(state.list_popup.winid, state.list_popup.bufnr)
  panel_registry.register(state.form_popup.winid, state.form_popup.bufnr)

  -- Mounting the Layout does NOT move focus into either child Popup on its own - confirmed for
  -- real: opening this panel left the cursor/keyboard input in whatever window (often the
  -- toolbar's own docked split) was current before the call, with the panel just floating on top
  -- looking focused but not actually receiving keys. Focus the list explicitly instead of relying
  -- on nui.Popup's own default.
  vim.api.nvim_set_current_win(state.list_popup.winid)

  -- Wraps every keymap callback below in pcall - an uncaught error inside a floating window's
  -- own keymap drops Neovim into the blocking "Press ENTER or type command to continue" cmdline
  -- prompt, which THIS panel's own popups (mounted on top, zindex-wise) then visually cover -
  -- Neovim isn't actually frozen, it's just waiting on an error prompt the user can't see behind
  -- the panel, which looks and feels exactly like a hang. Every path below now reports failures
  -- through vim.notify instead, so a bug surfaces as a visible message, never a silent freeze.
  local function safe(fn)
    return function()
      local ok, err = pcall(fn)
      if not ok then
        vim.notify("java-debug-model: config panel error: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  local function map_both(key, fn)
    state.list_popup:map("n", key, safe(fn), { noremap = true, nowait = true })
    state.form_popup:map("n", key, safe(fn), { noremap = true, nowait = true })
  end
  map_both("q", M.close)
  map_both("<Esc>", M.close)

  -- Switch focus back and forth between the two panes - reported for real that after <CR>
  -- selecting a config moves focus into the form (to start editing right away), there was no
  -- obvious way back to the list to pick a DIFFERENT config (Neovim's own <C-w>w still cycles
  -- windows including floats, but that's not discoverable without knowing to look for it).
  -- Normal-mode only (Tab in insert mode still does its normal thing inside a field's value).
  state.list_popup:map("n", "<Tab>", safe(function()
    vim.api.nvim_set_current_win(state.form_popup.winid)
  end), { noremap = true, nowait = true })
  state.form_popup:map("n", "<Tab>", safe(function()
    vim.api.nvim_set_current_win(state.list_popup.winid)
  end), { noremap = true, nowait = true })
  state.form_popup:map("n", "<S-Tab>", safe(function()
    vim.api.nvim_set_current_win(state.list_popup.winid)
  end), { noremap = true, nowait = true })

  local function select_at_line(lnum)
    if state.configs[lnum] then
      state.selected_idx = lnum
      render_list()
      render_form()
      vim.api.nvim_set_current_win(state.form_popup.winid)
    elseif lnum > #state.configs then
      add_new()
    end
  end

  local function delete_at_line(lnum)
    if state.configs[lnum] then
      state.selected_idx = lnum
      delete_selected()
    end
  end

  local function edit_at_line(lnum)
    local info = state.field_line_map[lnum]
    if info then edit_field(info.key) end
  end

  state.list_popup:map("n", "<CR>", safe(function()
    select_at_line(vim.api.nvim_win_get_cursor(state.list_popup.winid)[1])
  end), { noremap = true, nowait = true })
  state.list_popup:map("n", "a", safe(add_new), { noremap = true, nowait = true })
  state.list_popup:map("n", "d", safe(function()
    delete_at_line(vim.api.nvim_win_get_cursor(state.list_popup.winid)[1])
  end), { noremap = true, nowait = true })

  -- Module/JDK are picker-only (edit_at_line -> edit_field no-ops for every other field, since
  -- those are meant to be typed directly instead - see this file's own top comment). <CR> in
  -- NORMAL mode still opens the picker for those two rows; every other field is edited by moving
  -- the cursor there and typing normally (i/a/cw/...), no special key needed to "start".
  state.form_popup:map("n", "<CR>", safe(function()
    edit_at_line(vim.api.nvim_win_get_cursor(state.form_popup.winid)[1])
  end), { noremap = true, nowait = true })
  state.form_popup:map("n", "d", safe(function() delete_selected() end), { noremap = true, nowait = true })

  -- <CR> while typing a field's value CONFIRMS it (leaves insert mode, triggering the InsertLeave
  -- save below) instead of inserting a literal newline - a newline would silently corrupt the
  -- fixed one-line-per-field layout field_line_map depends on.
  state.form_popup:map("i", "<CR>", "<Esc>", { noremap = true })

  -- The actual "save" moment: whatever the cursor's line was when insert mode ended gets written
  -- back to config_store. Tied to this buffer specifically (not a global augroup) - a fresh
  -- buffer is created every M.open(), so there is nothing to clean up on M.close() beyond what
  -- unmounting the popup already does.
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = state.form_popup.bufnr,
    callback = safe(function()
      save_line(vim.api.nvim_win_get_cursor(state.form_popup.winid)[1])
    end),
  })

  -- Opens straight to whatever ui/toolbar.lua currently has as the active config (if any) rather
  -- than always defaulting to index 1 - the "toolbar cho ... hiển thị popup UI update" flow (its
  -- "Edit Configurations..." menu entry) opens THIS panel specifically to update the config the
  -- user is already looking at/running, not an arbitrary first one.
  local configs = config_store.list(root)
  local active_name = active_config.get(root)
  state.selected_idx = #configs == 0 and nil or 1
  if active_name then
    for i, cfg in ipairs(configs) do
      if cfg.name == active_name then state.selected_idx = i end
    end
  end
  refresh()
end

return M
