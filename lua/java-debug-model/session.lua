-- Multi-session registry: nvim-dap-ui focuses one active session by default,
-- this tracks every concurrently running java-debug-model session (module +
-- profile combination) so ui/session_picker.lua can switch focus between
-- them without disturbing the others.
local M = {}

---@class SessionEntry
---@field id integer
---@field name string
---@field root string           -- project root this session's DebugConfig lives under (config_store key) - needed by M.restart to re-run debug_config_run(root, name)
---@field module_path string
---@field profiles string[]
---@field status "starting"|"running"|"stopped"
---@field dap_session table|nil   -- the nvim-dap Session object, once started

---@type SessionEntry[]
local sessions = {}
local next_id = 1

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

---Đợi tối đa `max_wait` ms xem debuggee (theo port lua/dap_status.lua đã bắt được từ log console
---- xem plugins/dap.lua's terminal_win_cmd, hook CHUNG cho MỌI dap session bất kể khởi động qua
---đường nào) đã thoát thật chưa, rồi mới gọi cb(). BẮT BUỘC phải làm vậy: đã xác nhận qua log
---TRACE (xem comment ở plugins/dap.lua) - java-debug adapter của jdtls trả lời
---disconnect(terminateDebuggee=true) là success=true, bắn event "terminated", nhưng JVM thật
---KHÔNG thoát (bug/giới hạn thật của adapter, không phải lỗi cấu hình) - :JavaSessionStop dùng
---thẳng disconnect() nên dính đúng bug này nếu không có bước tự tra-PID-rồi-kill này. Không có
---port đã bắt được (vd chưa kịp bắt log, hoặc app không in "started on port") thì tin theo DAP
---protocol coi như đã tắt, không có cách nào tự tra PID khác an toàn hơn.
---@param name string
---@param cb fun()
---@param max_wait integer?
local function wait_release_then(name, cb, max_wait)
  max_wait = max_wait or 5000
  local ok_status, dap_status = pcall(require, "dap_status")
  local port = ok_status and dap_status.ports[name]
  if not port then
    cb()
    return
  end
  local uv = vim.uv or vim.loop
  local elapsed = 0
  local interval = 500
  local function check()
    local pids = pids_listening_on_port(port)
    if #pids == 0 then
      dap_status.ports[name] = nil
      cb()
      return
    end
    elapsed = elapsed + interval
    if elapsed >= max_wait then
      for _, pid in ipairs(pids) do uv.kill(pid, 9) end -- SIGKILL
      dap_status.ports[name] = nil
      vim.notify(
        string.format("java-debug-model: '%s' không tự tắt sau terminate - đã force-kill PID %s.",
          name, table.concat(pids, ", ")),
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
        wait_release_then(entry.name, function()
          M.mark_stopped(id)
          if on_stopped then on_stopped() end
        end)
      end)
      if not ok then
        vim.notify("java-debug-model: session.terminate failed: " .. tostring(err), vim.log.levels.WARN)
        -- disconnect() request itself never went through - vẫn thử tra PID theo port (không phụ
        -- thuộc việc disconnect có thành công hay không) trước khi coi như xong.
        wait_release_then(entry.name, function()
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
  if not entry.root then
    vim.notify("java-debug-model: session '" .. entry.name .. "' has no known root - cannot restart.",
      vim.log.levels.WARN)
    return
  end
  vim.notify("java-debug-model: restarting '" .. entry.name .. "'...", vim.log.levels.INFO)
  M.terminate(id, function()
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

---Switches nvim-dap-ui's focus to the given session's dap Session, without
---affecting the state of any other running session.
---@param id integer
function M.focus(id)
  for _, entry in ipairs(sessions) do
    if entry.id == id and entry.dap_session then
      local ok, dap = pcall(require, "dap")
      if ok then
        dap.set_session(entry.dap_session)
      end
      local ok_ui, dapui = pcall(require, "dapui")
      if ok_ui then
        dapui.open()
      end
      return true
    end
  end
  return false
end

---Wires nvim-dap's global listeners once, so every session this registry
---tracks gets marked stopped on its own `terminated`/`exit` event, without
---touching other sessions.
function M.setup_listeners()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
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
        wait_release_then(entry.name, function()
          M.mark_stopped(entry.id)
          pending = pending - 1
        end)
      end)
      if not ok then
        vim.schedule(function()
          vim.notify("java-debug-model: session.disconnect failed: " .. tostring(err), vim.log.levels.WARN)
        end)
        wait_release_then(entry.name, function()
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
