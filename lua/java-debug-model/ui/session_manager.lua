-- Persistent panel listing every tracked debug session (session.lua's registry) with inline
-- actions - replaces the old vim.ui.select-based flow (JavaSessionPicker/Stop/Remove/Manage:
-- pick a session from a dropdown, THEN pick an action from a SECOND dropdown, repeat for every
-- single operation) with a normal buffer you keep open: one line per session, one keypress per
-- action, auto-refreshing as sessions start/stop.
local session = require("java-debug-model.session")

local M = {}

local ns = vim.api.nvim_create_namespace("java_debug_model_session_manager")

local state = {
  bufnr = nil,
  winid = nil,
  -- line number -> SessionEntry, rebuilt on every render (same pattern as project_tree.lua)
  line_map = {},
}

local STATUS_ICON = {
  starting = "⏳",
  running = "▶",
  stopped = "■",
}

---@return table|nil session.SessionEntry
local function entry_at_cursor()
  if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.winid)[1]
  return state.line_map[lnum]
end

local function render()
  if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then return end
  local entries = session.list()
  local ok_status, dap_status = pcall(require, "dap_status")

  local lines = {
    "Debug sessions   (s: start mới, f: focus, l: xem log, r: restart, x: stop, d: xoá, R: reload, q: đóng)",
    "",
  }
  state.line_map = {}

  if #entries == 0 then
    table.insert(lines, "(chưa có session nào - bấm 's' để chạy 1 debug config)")
  else
    for _, e in ipairs(entries) do
      local icon = STATUS_ICON[e.status] or "?"
      local prof = (#e.profiles > 0) and (" [" .. table.concat(e.profiles, ",") .. "]") or ""
      local port = (ok_status and dap_status.ports[e.name]) and (" :" .. dap_status.ports[e.name]) or ""
      local module_name = e.module_path and vim.fn.fnamemodify(e.module_path, ":t") or "?"
      table.insert(lines, string.format("%s #%-3d %-30s %-8s %s%s%s",
        icon, e.id, e.name, e.status, module_name, prof, port))
      state.line_map[#lines] = e
    end
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for lnum, e in pairs(state.line_map) do
    local hl = e.status == "running" and "DiagnosticOk"
        or e.status == "starting" and "DiagnosticWarn"
        or "Comment"
    vim.api.nvim_buf_add_highlight(state.bufnr, ns, hl, lnum - 1, 0, -1)
  end
end

---Buffer showing session `name`'s console output - the SAME per-session terminal buffer
---plugins/dap.lua's terminal_win_cmd creates (shared via dap_status.term_bufs, see its own
---comment for why: java-debug-model doesn't own console capture itself, the user's dap.lua
---config does, for every dap session regardless of launch path). Falls back to the shared DAP
---REPL buffer for adapters that send output via OutputEvent instead of a real terminal (jdtls's
---own java-debug adapter does this - term_bufs never gets populated for it).
---@param name string
---@return integer|nil bufnr, boolean is_repl_fallback
local function log_buf_for(name)
  local ok_status, dap_status = pcall(require, "dap_status")
  local buf = ok_status and dap_status.term_bufs[name]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf, false
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buftype == "prompt" and vim.api.nvim_buf_get_name(b):match("dap%-repl%-%d+") then
      return b, true
    end
  end
  return nil, false
end

local function view_log()
  local e = entry_at_cursor()
  if not e then return end
  local buf, is_repl = log_buf_for(e.name)
  if not buf then
    vim.notify("java-debug-model: chưa có log cho '" .. e.name .. "'.", vim.log.levels.WARN)
    return
  end
  local width = math.floor(vim.o.columns * 0.85)
  local height = math.floor(vim.o.lines * 0.75)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = is_repl and " REPL (dùng chung mọi session) " or (" Console: " .. e.name .. " "),
    title_pos = "center",
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, nowait = true })
end

local function focus_selected()
  local e = entry_at_cursor()
  if not e then return end
  if not session.focus(e.id) then
    vim.notify("java-debug-model: session '" .. e.name .. "' chưa có dap session để focus.", vim.log.levels.WARN)
  end
end

local function restart_selected()
  local e = entry_at_cursor()
  if not e then return end
  session.restart(e.id)
  render()
end

local function stop_selected()
  local e = entry_at_cursor()
  if not e then return end
  if e.status == "stopped" then
    vim.notify("java-debug-model: '" .. e.name .. "' đã tắt rồi.", vim.log.levels.INFO)
    return
  end
  session.terminate(e.id, render)
  vim.notify("java-debug-model: đang tắt '" .. e.name .. "'...", vim.log.levels.INFO)
end

local function remove_selected()
  local e = entry_at_cursor()
  if not e then return end
  session.remove(e.id)
  render()
end

---Starts a NEW session: picks a project root (java-debug-model's own current-root resolution)
---then a saved DebugConfig, same underlying path F5/:JavaDebugConfigRun use - so a session
---started from here gets the same fresh classPaths/sourcePaths resolution as everywhere else.
local function start_new()
  local jdm = require("java-debug-model")
  local root = jdm._find_root(0)
  if not root then
    vim.notify("java-debug-model: không tìm thấy project root (pom.xml) cho buffer hiện tại.", vim.log.levels.WARN)
    return
  end
  local configs = jdm.config_store.list(root)
  if #configs == 0 then
    vim.notify("java-debug-model: chưa có debug config nào. Dùng :JavaDebugConfigScan hoặc :JavaDebugConfigFromFile trước.",
      vim.log.levels.WARN)
    return
  end
  vim.ui.select(configs, {
    prompt = "Chạy debug config mới:",
    format_item = function(c) return c.name .. " (" .. c.main_class .. ")" end,
  }, function(choice)
    if not choice then return end
    jdm.debug_config_run(root, choice.name)
    -- debug_config_run resolves the Project model first (may be async - a cache miss re-runs
    -- Maven), so session.register() (inside jdm.dap.launch) doesn't necessarily happen before
    -- this call returns. This is just a quick best-effort refresh for the common case (model
    -- already cached, resolves near-instantly); ensure_auto_refresh's event_initialized listener
    -- is the reliable fallback once the session actually starts, however long that takes.
    vim.defer_fn(render, 300)
  end)
end

---@return boolean
function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.winid, false)
  end
  state.winid = nil
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

---Opens (or focuses) the persistent session manager panel.
function M.open()
  ensure_auto_refresh()

  if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.api.nvim_buf_set_name(state.bufnr, "java-debug-model://session-manager")
    vim.keymap.set("n", "s", start_new, { buffer = state.bufnr, nowait = true, desc = "Start new session" })
    vim.keymap.set("n", "f", focus_selected, { buffer = state.bufnr, nowait = true, desc = "Focus session" })
    vim.keymap.set("n", "l", view_log, { buffer = state.bufnr, nowait = true, desc = "View log" })
    vim.keymap.set("n", "<CR>", view_log, { buffer = state.bufnr, nowait = true, desc = "View log" })
    vim.keymap.set("n", "r", restart_selected, { buffer = state.bufnr, nowait = true, desc = "Restart session" })
    vim.keymap.set("n", "x", stop_selected, { buffer = state.bufnr, nowait = true, desc = "Stop session" })
    vim.keymap.set("n", "d", remove_selected, { buffer = state.bufnr, nowait = true, desc = "Remove from list" })
    vim.keymap.set("n", "R", render, { buffer = state.bufnr, nowait = true, desc = "Reload" })
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = state.bufnr, nowait = true })
  end

  if M.is_open() then
    vim.api.nvim_set_current_win(state.winid)
  else
    vim.cmd("botright 15split")
    vim.api.nvim_win_set_buf(0, state.bufnr)
    state.winid = vim.api.nvim_get_current_win()
    local wo = vim.wo[state.winid]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.wrap = false
    wo.cursorline = true
  end

  render()
end

return M
