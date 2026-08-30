-- Multi-session registry: nvim-dap-ui focuses one active session by default,
-- this tracks every concurrently running java-debug-model session (module +
-- profile combination) so ui/session_picker.lua can switch focus between
-- them without disturbing the others.
local M = {}

---@class SessionEntry
---@field id integer
---@field name string
---@field module_path string
---@field profiles string[]
---@field status "starting"|"running"|"stopped"
---@field dap_session table|nil   -- the nvim-dap Session object, once started

---@type SessionEntry[]
local sessions = {}
local next_id = 1

---@param fields table { name, module_path, profiles }
---@return integer id
function M.register(fields)
  local id = next_id
  next_id = next_id + 1
  table.insert(sessions, {
    id = id,
    name = fields.name,
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

---Disconnects every tracked running session with terminateDebuggee=true,
---blocking (via vim.wait) until they've all actually closed or
---`timeout_ms` elapses - called on VimLeavePre so the target JVM(s) don't
---outlive Neovim. Safe to call with nothing running (no-op).
---@param timeout_ms integer?
function M.terminate_all_sync(timeout_ms)
  timeout_ms = timeout_ms or 3000
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
        M.mark_stopped(entry.id)
        pending = pending - 1
      end)
      if not ok then
        vim.schedule(function()
          vim.notify("java-debug-model: session.disconnect failed: " .. tostring(err), vim.log.levels.WARN)
        end)
        M.mark_stopped(entry.id)
        pending = pending - 1
      end
    end
  end
  if pending > 0 then
    vim.wait(timeout_ms, function() return pending <= 0 end, 50)
  end
end

return M
