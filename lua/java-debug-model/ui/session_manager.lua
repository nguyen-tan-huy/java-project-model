-- Persistent 2-pane panel (debug PROFILES on the left, live console on the right) - mirrors
-- IntelliJ's own "Services" tool window: the left list is every SAVED Run Configuration for the
-- current project (config_store.list(root)) - shown whether it's running or not, exactly one row
-- per profile - not a transient log of session instances. Selecting a profile shows its live
-- console on the right if it's running; running/restarting/stopping acts on the profile under the
-- cursor directly, no extra "which one?" picker needed since the picker IS the list itself.
local session = require("java-debug-model.session")
local panel_registry = require("java-debug-model.ui.panel_registry")

local M = {}

local ns = vim.api.nvim_create_namespace("java_debug_model_session_manager")

local state = {
  bufnr = nil,        -- the profile LIST buffer (left pane)
  winid = nil,         -- left pane window
  log_winid = nil,      -- right pane window - buffer shown in it changes as the cursor moves
  placeholder_bufnr = nil, -- shown in the right pane when the selected profile has no log yet
  root = nil,           -- project root the list was last built for (pinned until 'R' reload)
  configs = nil,        -- config_store.list(root) as of the last render
  -- line number -> DebugConfig, rebuilt on every render (same pattern as project_tree.lua)
  line_map = {},
}

local STATUS_ICON = {
  starting = "⏳",
  running = "▶",
  stopped = "■",
}
local NOT_STARTED_ICON = "○"

---@return table|nil DebugConfig
local function config_at_cursor()
  if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.winid)[1]
  return state.line_map[lnum]
end

---The MOST RECENT tracked session entry (if any) for a profile name - "most recent" only
---matters if session.lua's restart-in-place cleanup (see its own M.restart comment) somehow
---still left more than one around; picking the last one keeps this showing the freshest state.
---@param name string
---@return table|nil session.SessionEntry
local function session_for(name)
  local found
  for _, e in ipairs(session.list()) do
    if e.name == name then found = e end
  end
  return found
end

---Buffer showing session `name`'s console output - the SAME per-session terminal buffer
---plugins/dap.lua's terminal_win_cmd creates (shared via dap_status.term_bufs, see its own
---comment for why: java-debug-model doesn't own console capture itself, the user's dap.lua
---config does, for every dap session regardless of launch path). Falls back to the shared DAP
---REPL buffer for adapters that send output via OutputEvent instead of a real terminal (jdtls's
---own java-debug adapter does this - term_bufs never gets populated for it).
---@param name string
---@return integer|nil bufnr
local function log_buf_for(name)
  local ok_status, dap_status = pcall(require, "dap_status")
  local buf = ok_status and dap_status.term_bufs[name]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buftype == "prompt" and vim.api.nvim_buf_get_name(b):match("dap%-repl%-%d+") then
      return b
    end
  end
  return nil
end

local function ensure_placeholder_buf()
  if state.placeholder_bufnr and vim.api.nvim_buf_is_valid(state.placeholder_bufnr) then
    return state.placeholder_bufnr
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  state.placeholder_bufnr = buf
  return buf
end

---Points the right pane at the log for whatever profile the cursor is CURRENTLY on - called on
---every cursor move in the list AND after every render() (a session's own log buffer can appear
---for the first time - "starting" -> "running" - well after the panel itself was already open).
local function sync_log_to_cursor()
  if not (state.log_winid and vim.api.nvim_win_is_valid(state.log_winid)) then return end
  local cfg = config_at_cursor()
  local entry = cfg and session_for(cfg.name)
  local buf = entry and log_buf_for(entry.name)
  if not buf then
    buf = ensure_placeholder_buf()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "", "",
      "  " .. (cfg and ("'" .. cfg.name .. "' chưa chạy - bấm <CR> để chạy") or "Chọn 1 profile bên trái"),
    })
    vim.bo[buf].modifiable = false
  end
  if vim.api.nvim_win_get_buf(state.log_winid) ~= buf then
    vim.api.nvim_win_set_buf(state.log_winid, buf)
    local wo = vim.wo[state.log_winid]
    wo.number = false
    wo.relativenumber = false
    -- Jump to the end so a live-streaming console/REPL buffer opens already scrolled to the
    -- latest output, matching what re-opening plugins/dap.lua's own float used to feel like.
    if buf ~= state.placeholder_bufnr then
      local last = vim.api.nvim_buf_line_count(buf)
      pcall(vim.api.nvim_win_set_cursor, state.log_winid, { last, 0 })
    end
  end
end

local function render()
  if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then return end
  local ok_status, dap_status = pcall(require, "dap_status")

  local lines = {
    "Debug profiles   (<CR>/s: run, r: restart, x: stop, f: focus, e: sửa, a: thêm, d: xoá, l: sang log, R: reload, q: đóng)",
    "",
  }
  state.line_map = {}

  if not state.configs or #state.configs == 0 then
    table.insert(lines, "(chưa có debug config nào cho project này - bấm 'a' để thêm)")
  else
    for _, cfg in ipairs(state.configs) do
      local entry = session_for(cfg.name)
      local icon = entry and (STATUS_ICON[entry.status] or "?") or NOT_STARTED_ICON
      local status = entry and entry.status or "chưa chạy"
      local prof = (#cfg.maven_profiles > 0) and (" [" .. table.concat(cfg.maven_profiles, ",") .. "]") or ""
      local port = (entry and ok_status and dap_status.ports[entry.name]) and (" :" .. dap_status.ports[entry.name]) or ""
      local module_name = vim.fn.fnamemodify(cfg.module_path, ":t")
      table.insert(lines, string.format("%s %-30s %-9s %s%s%s",
        icon, cfg.name, status, module_name, prof, port))
      state.line_map[#lines] = cfg
    end
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for lnum, cfg in pairs(state.line_map) do
    local entry = session_for(cfg.name)
    local hl = entry and entry.status == "running" and "DiagnosticOk"
        or entry and entry.status == "starting" and "DiagnosticWarn"
        or "Comment"
    vim.api.nvim_buf_add_highlight(state.bufnr, ns, hl, lnum - 1, 0, -1)
  end

  sync_log_to_cursor()
end

---Refetches config_store's profile list for state.root and re-renders - called on open/'R', and
---after add/edit/delete so the list reflects the change immediately.
local function reload_configs()
  if not state.root then return end
  local jdm = require("java-debug-model")
  state.configs = jdm.config_store.list(state.root)
  render()
end

---Moves editor focus INTO the log pane (to scroll/search/yank the console itself) - the pane's
---content already follows the cursor automatically, this is only for when you want to actually
---interact with the log rather than keep browsing the profile list.
local function goto_log()
  if state.log_winid and vim.api.nvim_win_is_valid(state.log_winid) then
    vim.api.nvim_set_current_win(state.log_winid)
  end
end

---Runs the profile under the cursor - REUSES the existing tracked session for it if one already
---exists (running, starting, OR stopped), via session.restart (terminates first only if actually
---still running), instead of always registering a brand new row: re-running/pressing Enter on a
---profile is expected to behave like IntelliJ's "run this configuration" button, not add a
---duplicate entry every time.
local function run_selected()
  local cfg = config_at_cursor()
  if not cfg then return end
  local jdm = require("java-debug-model")
  local existing = session_for(cfg.name)
  if existing then
    session.restart(existing.id)
  else
    jdm.debug_config_run(state.root, cfg.name)
  end
  -- debug_config_run/session.restart resolve the Project model first (may be async - a cache
  -- miss re-runs Maven), so session.register()/mark_started() don't necessarily happen before
  -- this call returns. This is just a quick best-effort refresh for the common case (model
  -- already cached, resolves near-instantly); ensure_auto_refresh's event_initialized listener
  -- is the reliable fallback once the session actually starts, however long that takes.
  vim.defer_fn(render, 300)
end

local function focus_selected()
  local cfg = config_at_cursor()
  local entry = cfg and session_for(cfg.name)
  if not entry then
    vim.notify("java-debug-model: '" .. (cfg and cfg.name or "?") .. "' chưa chạy.", vim.log.levels.WARN)
    return
  end
  if not session.focus(entry.id) then
    vim.notify("java-debug-model: session '" .. entry.name .. "' chưa có dap session để focus.", vim.log.levels.WARN)
  end
end

local function stop_selected()
  local cfg = config_at_cursor()
  local entry = cfg and session_for(cfg.name)
  if not entry or entry.status == "stopped" then
    vim.notify("java-debug-model: '" .. (cfg and cfg.name or "?") .. "' chưa chạy.", vim.log.levels.INFO)
    return
  end
  session.terminate(entry.id, render)
  vim.notify("java-debug-model: đang tắt '" .. entry.name .. "'...", vim.log.levels.INFO)
end

---Deletes the profile itself (config_store.remove) - a real destructive action (unlike the old
---session-registry "remove from list"), so this confirms first. Stops any running session for it
---beforehand so the debuggee doesn't end up orphaned/untracked.
local function delete_selected()
  local cfg = config_at_cursor()
  if not cfg then return end
  vim.ui.select({ "Huỷ", "Xoá config '" .. cfg.name .. "'" }, {
    prompt = "Xoá debug config '" .. cfg.name .. "' ?",
  }, function(choice)
    if not choice or choice == "Huỷ" then return end
    local entry = session_for(cfg.name)
    if entry and entry.status ~= "stopped" then
      session.terminate(entry.id, function() end)
    end
    require("java-debug-model").config_store.remove(state.root, cfg.name)
    reload_configs()
  end)
end

local function add_new()
  if not state.root then return end
  require("java-debug-model").debug_config_add(state.root)
  vim.defer_fn(reload_configs, 300) -- config_form.open's own save happens async (get_project first)
end

local function edit_selected()
  local cfg = config_at_cursor()
  if not cfg or not state.root then return end
  require("java-debug-model").debug_config_edit(state.root, cfg.name)
  vim.defer_fn(reload_configs, 300)
end

---@return boolean
function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

function M.close()
  if state.log_winid and vim.api.nvim_win_is_valid(state.log_winid) then
    vim.api.nvim_win_close(state.log_winid, false)
  end
  if M.is_open() then
    vim.api.nvim_win_close(state.winid, false)
  end
  state.winid = nil
  state.log_winid = nil
end

local listeners_registered = false
---Auto-refreshes the panel (when open) on every session lifecycle event - separate listener
---keys from session.lua's own (dap.listeners lets multiple callbacks share one event), so this
---stays a pure "redraw if visible" concern with no risk of clobbering session.lua's own
---status-tracking listeners.
local function ensure_auto_refresh()
  if listeners_registered then return end
  listeners_registered = true
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  local key = "java_debug_model_session_manager_ui"
  local function on_event()
    vim.schedule(function()
      if M.is_open() then render() end
    end)
  end
  dap.listeners.after.event_initialized[key] = on_event
  dap.listeners.after.event_terminated[key] = on_event
  dap.listeners.after.event_exited[key] = on_event
end

---Opens (or focuses) the persistent session manager panel: debug PROFILES on the left (narrow,
---one row per saved DebugConfig - running or not), live console for whatever line the cursor is
---on shown on the right (wide) - like IntelliJ's Services tool window.
function M.open()
  ensure_auto_refresh()

  local jdm = require("java-debug-model")
  state.root = jdm._find_root(0)

  local first_time = not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr))
  if first_time then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.api.nvim_buf_set_name(state.bufnr, "java-debug-model://session-manager")
    vim.keymap.set("n", "s", run_selected, { buffer = state.bufnr, nowait = true, desc = "Run profile" })
    vim.keymap.set("n", "<CR>", run_selected, { buffer = state.bufnr, nowait = true, desc = "Run profile" })
    vim.keymap.set("n", "r", run_selected, { buffer = state.bufnr, nowait = true, desc = "Restart profile" })
    vim.keymap.set("n", "f", focus_selected, { buffer = state.bufnr, nowait = true, desc = "Focus session" })
    vim.keymap.set("n", "x", stop_selected, { buffer = state.bufnr, nowait = true, desc = "Stop session" })
    vim.keymap.set("n", "e", edit_selected, { buffer = state.bufnr, nowait = true, desc = "Edit debug config" })
    vim.keymap.set("n", "a", add_new, { buffer = state.bufnr, nowait = true, desc = "Add new debug config" })
    vim.keymap.set("n", "d", delete_selected, { buffer = state.bufnr, nowait = true, desc = "Delete debug config" })
    vim.keymap.set("n", "l", goto_log, { buffer = state.bufnr, nowait = true, desc = "Go to log pane" })
    vim.keymap.set("n", "R", reload_configs, { buffer = state.bufnr, nowait = true, desc = "Reload" })
    vim.keymap.set("n", "q", function() M.close() end, { buffer = state.bufnr, nowait = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = state.bufnr,
      callback = sync_log_to_cursor,
    })
  end

  if M.is_open() then
    vim.api.nvim_set_current_win(state.winid)
  else
    -- Log pane FIRST (fills the whole bottom band), THEN carve the list out of its left edge -
    -- ends up with list (narrow, left) + log (wide, right) side by side, matching IntelliJ's own
    -- Services layout.
    vim.cmd("botright 20split")
    local log_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(log_win, ensure_placeholder_buf())
    state.log_winid = log_win

    vim.cmd("leftabove 45vsplit")
    state.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.winid, state.bufnr)
    local wo = vim.wo[state.winid]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.wrap = false
    wo.cursorline = true
    wo.winfixwidth = true

    panel_registry.register(state.log_winid)
    panel_registry.register(state.winid)
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(state.log_winid),
      once = true,
      callback = function() panel_registry.unregister(state.log_winid) end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(state.winid),
      once = true,
      callback = function() panel_registry.unregister(state.winid) end,
    })
  end

  reload_configs()
end

return M
