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
---@field port integer
---@field status "starting"|"running"|"stopped"
---@field dap_session table|nil   -- the nvim-dap Session object, once started

---@type SessionEntry[]
local sessions = {}
local next_id = 1

---@param fields table { name, module_path, profiles, port }
---@return integer id
function M.register(fields)
  local id = next_id
  next_id = next_id + 1
  table.insert(sessions, {
    id = id,
    name = fields.name,
    module_path = fields.module_path,
    profiles = fields.profiles or {},
    port = fields.port,
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
end

return M
