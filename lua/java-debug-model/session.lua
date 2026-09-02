-- Multi-session registry: nvim-dap-ui focuses one active session by default,
-- this tracks every concurrently running java-debug-model session (module +
-- profile combination) so ui/session_picker.lua can switch focus between
-- them without disturbing the others.
local M = {}

---@class SessionEntry
---@field id integer
---@field name string
---@field kind "debug"|"test"    -- "test" = an ephemeral JUnit run (test.lua) - not backed by a
---saved config_store DebugConfig, so ui/session_manager.lua shows it as a TEMPORARY profile row
---(like IntelliJ's own auto-generated temporary Run Configurations for a test run) and M.restart
---doesn't apply to it the same way (see M.restart's own guard).
---@field root string           -- project root this session's DebugConfig lives under (config_store key) - needed by M.restart to re-run debug_config_run(root, name)
---@field module_path string
---@field profiles string[]
---@field status "starting"|"running"|"stopped"
---@field dap_session table|nil   -- the nvim-dap Session object, once started

---@type SessionEntry[]
local sessions = {}
local next_id = 1

---@type table<table, integer>  raw nvim-dap Session object -> bufnr, WEAK on the key so a session
---that never gets linked (see comment on setup_output_capture below) doesn't pin it in memory
---forever. Holds output captured for a dap Session BEFORE M.mark_started has linked it to one of
---our own SessionEntry rows.
local pending_output_bufs = setmetatable({}, { __mode = "k" })

---@param id integer
---@return string  a fixed, unique-per-session marker string - dap.lua's M.launch injects this as
---`-D<marker>` into the debuggee's OWN vmArgs, so wait_release_then below can find the ACTUAL JVM
---process by grepping its command line, regardless of console mode. THE PORT-BASED CHECK THIS
---REPLACED NEVER ACTUALLY WORKED for Java: dap_status.ports only gets populated by
---plugins/dap.lua's terminal_win_cmd, which nvim-dap only calls for adapters using runInTerminal -
---java-debug (jdtls's own DAP adapter) never requests that, it always streams output via
---OutputEvent straight to the REPL instead (see plugins/dap.lua's own comment on this) - so
---dap_status.ports[name] was always nil for every Java session, meaning "no port -> trust the DAP
---protocol immediately" was silently the ONLY path ever taken, on every single stop, regardless of
---whether the JVM actually exited - hence "works sometimes, doesn't others" reported by a real
---user: whatever made the JVM actually die was pure luck/unrelated to this fallback, not this
---fallback engaging correctly.
function M.marker_for(id)
  return "java-debug-model.session-id=" .. id
end

---@param marker string
---@return integer[]
local function pids_matching_marker(marker)
  if vim.fn.executable("pgrep") == 0 then return {} end
  local out = vim.fn.systemlist({ "pgrep", "-f", marker })
  local pids = {}
  for _, line in ipairs(out) do
    local pid = tonumber(vim.trim(line))
    if pid then table.insert(pids, pid) end
  end
  return pids
end

---@param port string|integer
---@return integer[]
local function pids_listening_on_port(port)
  if vim.fn.executable("lsof") == 0 then return {} end
  local out = vim.fn.systemlist({ "lsof", "-ti", ":" .. tostring(port) })
  local pids = {}
  for _, line in ipairs(out) do
    local pid = tonumber(vim.trim(line))
    if pid then table.insert(pids, pid) end
  end
  return pids
end

---Đợi tối đa `max_wait` ms xem debuggee đã thoát thật chưa (qua `pgrep -f` trên vmArgs marker
---của CHÍNH session này - luôn có, không phụ thuộc console mode/port có bắt được hay không; kết
---hợp thêm port-based lsof check nếu dap_status.ports[entry.name] tình cờ có, làm tín hiệu phụ)
---rồi mới gọi cb(). BẮT BUỘC phải làm vậy: đã xác nhận qua log TRACE (xem comment ở
---plugins/dap.lua) - java-debug adapter của jdtls trả lời disconnect(terminateDebuggee=true) là
---success=true, bắn event "terminated", nhưng JVM thật KHÔNG thoát (bug/giới hạn thật của
---adapter, không phải lỗi cấu hình). Chỉ "tin theo DAP protocol" ngay khi KHÔNG signal nào tra
---được cả (pgrep không có sẵn VÀ không có port) - trường hợp cực hiếm, không có cách nào khác.
---@param entry SessionEntry
---@param cb fun()
---@param max_wait integer?
local function wait_release_then(entry, cb, max_wait)
  max_wait = max_wait or 5000
  local ok_status, dap_status = pcall(require, "dap_status")
  local marker = M.marker_for(entry.id)

  local function alive_pids()
    local pids = {}
    for _, pid in ipairs(pids_matching_marker(marker)) do pids[pid] = true end
    local port = ok_status and dap_status.ports[entry.name]
    if port then
      for _, pid in ipairs(pids_listening_on_port(port)) do pids[pid] = true end
    end
    return pids
  end

  if not next(alive_pids()) then
    -- Either already gone, or neither signal is available at all (pgrep missing AND no port
    -- captured) - nothing left to poll for, trust the DAP protocol.
    cb()
    return
  end

  local uv = vim.uv or vim.loop
  local elapsed = 0
  local interval = 500
  local function check()
    local pids = alive_pids()
    if not next(pids) then
      if ok_status then dap_status.ports[entry.name] = nil end
      cb()
      return
    end
    elapsed = elapsed + interval
    if elapsed >= max_wait then
      for pid in pairs(pids) do uv.kill(pid, 9) end -- SIGKILL
      if ok_status then dap_status.ports[entry.name] = nil end
      local pid_list = vim.tbl_keys(pids)
      table.sort(pid_list)
      vim.notify(
        string.format("java-debug-model: '%s' không tự tắt sau terminate - đã force-kill PID %s.",
          entry.name, table.concat(pid_list, ", ")),
        vim.log.levels.WARN)
      cb()
      return
    end
    vim.defer_fn(check, interval)
  end
  vim.defer_fn(check, interval)
end

---@param fields table { name, root, module_path, profiles }
---@return integer id
function M.register(fields)
  local id = next_id
  next_id = next_id + 1
  table.insert(sessions, {
    id = id,
    name = fields.name,
    kind = fields.kind or "debug",
    root = fields.root,
    module_path = fields.module_path,
    profiles = fields.profiles or {},
    status = "starting",
    dap_session = nil,
  })
  return id
end

---@param id integer
---@param dap_session table  the nvim-dap Session
function M.mark_started(id, dap_session)
  for _, entry in ipairs(sessions) do
    if entry.id == id then
      entry.status = "running"
      entry.dap_session = dap_session
      -- Reclaim any output setup_output_capture already buffered for this RAW dap_session before
      -- this link existed (see that function's own comment - test.lua's M.rerun/invoke() only
      -- calls this AFTER polling dap.session() into existence, well after the debuggee JVM was
      -- actually launched, so early OutputEvents - e.g. a @SpringBootTest's whole context-startup
      -- log - would otherwise be silently dropped instead of ending up in this entry's own log).
      local pending = pending_output_bufs[dap_session]
      if pending and vim.api.nvim_buf_is_valid(pending) then
        local ok_status, dap_status = pcall(require, "dap_status")
        if ok_status then dap_status.term_bufs[entry.name] = pending end
        pending_output_bufs[dap_session] = nil
      end
      return
    end
  end
end

---@param id integer
function M.mark_stopped(id)
  for _, entry in ipairs(sessions) do
    if entry.id == id then
      entry.status = "stopped"
      return
    end
  end
end

---@return SessionEntry[]
function M.list()
  return sessions
end

---@return SessionEntry[]
function M.list_running()
  return vim.tbl_filter(function(e) return e.status ~= "stopped" end, sessions)
end

---Prunes stopped sessions older than the current dap session list, keeping
---the registry from growing unbounded across a long Neovim session.
function M.prune_stopped()
  local kept = {}
  for _, entry in ipairs(sessions) do
    if entry.status ~= "stopped" then
      table.insert(kept, entry)
    end
  end
  sessions = kept
end

---Terminates one tracked session's debuggee: disconnect(terminateDebuggee=true), THEN wait for
---the debuggee's own port to actually free up and force-kill by PID if it doesn't (see
---wait_release_then above - disconnect() alone is known to report success without the JVM
---actually exiting). Used by ui/session_picker.lua's "stop" action. No-op if the entry is
---already stopped or never got a dap Session (still "starting" - nothing to disconnect from yet).
---@param id integer
---@param on_stopped fun()? called once the debuggee is actually confirmed gone (after
---wait_release_then's port-poll/force-kill, not just after the disconnect request) - e.g.
---M.restart uses this to only re-launch once the old JVM has truly released its port.
function M.terminate(id, on_stopped)
  for _, entry in ipairs(sessions) do
    if entry.id == id then
      if entry.status == "stopped" or not entry.dap_session then
        M.mark_stopped(id)
        if on_stopped then on_stopped() end
        return
      end
      local ok, err = pcall(entry.dap_session.disconnect, entry.dap_session, { terminateDebuggee = true }, function()
        wait_release_then(entry, function()
          M.mark_stopped(id)
          if on_stopped then on_stopped() end
        end)
      end)
      if not ok then
        vim.notify("java-debug-model: session.terminate failed: " .. tostring(err), vim.log.levels.WARN)
        -- disconnect() request itself never went through - vẫn thử tra PID theo port (không phụ
        -- thuộc việc disconnect có thành công hay không) trước khi coi như xong.
        wait_release_then(entry, function()
          M.mark_stopped(id)
          if on_stopped then on_stopped() end
        end)
      end
      return
    end
  end
end

---Restarts one tracked session: terminate the current debuggee, wait for its port to actually
---free up (same fallback-kill as M.terminate), THEN re-run the DebugConfig from scratch via
---java-debug-model.debug_config_run(entry.root, entry.name) - NOT dap.run(old_session.config,
---{new=true}) (what the user's own former <leader>dR did): that reused a config snapshotted at
---the ORIGINAL launch time, so classPaths/sourcePaths never picked up anything resolved since
---(a sibling module recompiled, a manifest module added/removed, a pom.xml dependency change).
---Going through debug_config_run re-resolves the Project model + classpath fresh, every time.
---No-op (just notifies) if config_store no longer has a config named `entry.name` (removed since
---this session was launched) - required lazily to avoid a require cycle with init.lua, which
---itself requires this module.
---@param id integer
function M.restart(id)
  local entry
  for _, e in ipairs(sessions) do
    if e.id == id then
      entry = e
      break
    end
  end
  if not entry then return end
  if entry.kind == "test" then
    vim.notify(
      "java-debug-model: '" .. entry.name .. "' là 1 lần chạy test tạm (không có config lưu sẵn) - " ..
      "dùng lại <leader>jtm/<leader>jtc tại đúng test đó để chạy lại.", vim.log.levels.WARN)
    return
  end
  if not entry.root then
    vim.notify("java-debug-model: session '" .. entry.name .. "' has no known root - cannot restart.",
      vim.log.levels.WARN)
    return
  end
  vim.notify("java-debug-model: restarting '" .. entry.name .. "'...", vim.log.levels.INFO)
  M.terminate(id, function()
    -- Drop the OLD entry now that its debuggee is confirmed gone - debug_config_run below always
    -- registers a FRESH entry with its own new id (an nvim-dap Session object can't be relaunched
    -- in place, dap.launch always creates a new one), so without this the old row would linger
    -- forever as its own separate "stopped" entry sitting next to the new one instead of the
    -- restart actually replacing it - which is the whole point callers (e.g.
    -- ui/session_manager.lua's "run this profile" reusing the existing row instead of piling up
    -- a new one every run) rely on this function for.
    local kept = {}
    for _, e in ipairs(sessions) do
      if e.id ~= id then table.insert(kept, e) end
    end
    sessions = kept
    require("java-debug-model").debug_config_run(entry.root, entry.name)
  end)
end

---Removes one tracked session entry from the registry entirely (not just
---marking it stopped) - e.g. to clean up a long list of finished sessions
---one at a time. Terminates it first if it's still running, so the
---debuggee JVM doesn't end up orphaned/untracked (never reachable by
---VimLeavePre's terminate_all_sync again once removed from `sessions`).
---@param id integer
function M.remove(id)
  for _, entry in ipairs(sessions) do
    if entry.id == id and entry.status ~= "stopped" then
      M.terminate(id)
      break
    end
  end
  local kept = {}
  for _, entry in ipairs(sessions) do
    if entry.id ~= id then table.insert(kept, entry) end
  end
  sessions = kept
end

---@return boolean  true if some dapui element (Scopes/Watches/Stacks/Breakpoints/REPL) is
---currently showing in a window of the current tab - dapui itself exposes no public "is open"
---check, so this looks for a window whose buffer filetype starts with "dapui" (every element
---buffer is named that way, e.g. "dapui_scopes" - see nvim-dap-ui/lua/dapui/elements/*.lua).
local function dapui_is_open()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if ft:match("^dapui") then return true end
  end
  return false
end

---Switches nvim-dap-ui's focus to the given session's dap Session, without
---affecting the state of any other running session. Only re-opens dapui if it's ALREADY visible
---(keeping it in sync with whichever session you just switched to) - doesn't force it open from
---closed: java-debug-model no longer auto-pops dapui on every debug launch (see plugins/dap.lua's
---own comment on this), so focusing a session from ui/session_manager.lua's 'f' key shouldn't
---silently undo that and pop it open either.
---@param id integer
function M.focus(id)
  for _, entry in ipairs(sessions) do
    if entry.id == id and entry.dap_session then
      local ok, dap = pcall(require, "dap")
      if ok then
        dap.set_session(entry.dap_session)
      end
      if dapui_is_open() then
        local ok_ui, dapui = pcall(require, "dapui")
        if ok_ui then dapui.open() end
      end
      return true
    end
  end
  return false
end

---Captures each tracked session's OWN `OutputEvent` stream into its OWN dedicated buffer
---(dap_status.term_bufs[entry.name], the SAME shared table plugins/dap.lua's terminal_win_cmd
---populates for runInTerminal-based adapters) - java-debug (jdtls's own DAP adapter) never uses
---runInTerminal, it ALWAYS streams output via OutputEvent straight into nvim-dap's ONE GLOBAL
---REPL buffer instead (see nvim-dap's own Session:event_output - no per-session routing at all).
---Without this, EVERY Java session's "log" in ui/session_manager.lua fell back to that SAME
---shared REPL buffer, indistinguishable from one another - confirmed for real: running a SECOND
---profile made the FIRST profile's row in the panel show the SECOND one's log instead (whichever
---was actively streaming to the shared REPL), while the actively-running one's own row showed
---nothing new (the log pane's buffer was already set to that REPL buf from a previous selection,
---so the "only update on buffer change" check silently skipped refreshing the view).
---@param dap table  the nvim-dap module (passed in so callers already holding a reference reuse it)
local function setup_output_capture(dap)
  dap.listeners.after.event_output["java-debug-model-log"] = function(dap_session, body)
    if body.category == "telemetry" then return end
    local entry
    for _, e in ipairs(sessions) do
      if e.dap_session == dap_session then
        entry = e
        break
      end
    end

    local ok_status, dap_status = pcall(require, "dap_status")
    if not ok_status then return end

    local buf
    if entry then
      buf = dap_status.term_bufs[entry.name]
    else
      -- Not yet linked to a tracked SessionEntry - either a session.lua never registered at all
      -- (e.g. a Rust/codelldb session; harmless, this pending buffer just sits unclaimed and gets
      -- garbage-collected once nvim-dap drops the Session object, since pending_output_bufs keys
      -- weakly) or test.lua's M.rerun/invoke() only calls
      -- M.mark_started AFTER polling dap.session() into existence (jdtls's test runner never
      -- returns the Session object directly - see its own comment), well after the debuggee JVM
      -- was actually launched. A slow-starting debuggee (e.g. a @SpringBootTest booting a full
      -- ApplicationContext) can easily emit its entire startup log in that gap - buffer it under
      -- the RAW dap_session object itself so M.mark_started can reclaim it once linked, instead of
      -- silently dropping it (leaving ui/session_manager.lua's log pane falling back to the shared
      -- REPL, which never had this output either).
      buf = pending_output_bufs[dap_session]
    end
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "hide"
      if entry then
        dap_status.term_bufs[entry.name] = buf
      else
        pending_output_bufs[dap_session] = buf
      end
    end

    -- Append body.output the same way nvim-dap's own REPL does: text may contain embedded
    -- newlines and doesn't arrive pre-split into "lines" - continue the LAST existing line
    -- rather than always starting a fresh one, so output split across multiple OutputEvents
    -- mid-line doesn't get torn onto separate lines.
    local pieces = vim.split(body.output, "\n", { plain = true })
    local last_idx = vim.api.nvim_buf_line_count(buf)
    local last_line = vim.api.nvim_buf_get_lines(buf, last_idx - 1, last_idx, false)[1] or ""
    vim.api.nvim_buf_set_lines(buf, last_idx - 1, last_idx, false, { last_line .. pieces[1] })
    if #pieces > 1 then
      vim.api.nvim_buf_set_lines(buf, last_idx, last_idx, false, { unpack(pieces, 2) })
    end
  end
end

---Wires nvim-dap's global listeners once, so every session this registry
---tracks gets marked stopped on its own `terminated`/`exit` event, without
---touching other sessions.
function M.setup_listeners()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  setup_output_capture(dap)
  dap.listeners.after.event_terminated["java-debug-model"] = function(dap_session)
    for _, entry in ipairs(sessions) do
      if entry.dap_session == dap_session then
        M.mark_stopped(entry.id)
      end
    end
  end
  dap.listeners.after.event_exited["java-debug-model"] = function(dap_session)
    for _, entry in ipairs(sessions) do
      if entry.dap_session == dap_session then
        M.mark_stopped(entry.id)
      end
    end
  end

  -- nvim-dap never terminates a running session's debuggee on its own when
  -- Neovim exits - a session is a JDWP/socket connection to a target JVM
  -- that jdtls spawned, not a child process of Neovim, so it isn't touched
  -- by quitting the editor. Without this, closing Neovim leaves the
  -- launched application (e.g. a Spring Boot app under debug) running in
  -- the background indefinitely.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() M.terminate_all_sync() end,
  })
end

---Disconnects every tracked running session with terminateDebuggee=true, THEN waits for each
---one's debuggee port to actually free up (force-kill by PID if it doesn't - see
---wait_release_then above), blocking (via vim.wait) until they've all actually closed or
---`timeout_ms` elapses - called on VimLeavePre so the target JVM(s) don't outlive Neovim. Safe to
---call with nothing running (no-op).
---@param timeout_ms integer?  default 6000 - covers disconnect's own round-trip PLUS
---                             wait_release_then's up-to-5s poll-then-kill window; too short a
---                             value here would make Neovim exit before the force-kill fallback
---                             even gets a chance to run.
function M.terminate_all_sync(timeout_ms)
  timeout_ms = timeout_ms or 6000
  local running = M.list_running()
  local pending = 0
  for _, entry in ipairs(running) do
    if entry.dap_session then
      pending = pending + 1
      -- Also mark the entry stopped here directly, rather than relying
      -- solely on nvim-dap's own terminated/exited DAP EVENT to do it:
      -- that event fires independently of (and with no ordering guarantee
      -- against) this disconnect REQUEST's response, so waiting only on
      -- `pending` above could leave the registry saying "running" for a
      -- session whose JVM is already dead.
      local ok, err = pcall(entry.dap_session.disconnect, entry.dap_session, { terminateDebuggee = true }, function()
        wait_release_then(entry, function()
          M.mark_stopped(entry.id)
          pending = pending - 1
        end)
      end)
      if not ok then
        vim.schedule(function()
          vim.notify("java-debug-model: session.disconnect failed: " .. tostring(err), vim.log.levels.WARN)
        end)
        wait_release_then(entry, function()
          M.mark_stopped(entry.id)
          pending = pending - 1
        end)
      end
    end
  end
  if pending > 0 then
    vim.wait(timeout_ms, function() return pending <= 0 end, 50)
  end
end

return M
