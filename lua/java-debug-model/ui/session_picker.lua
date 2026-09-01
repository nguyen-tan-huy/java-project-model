-- vim.ui.select picker + status list for concurrent debug sessions, since
-- nvim-dap-ui only focuses one active session by default.
local session = require("java-debug-model.session")

local M = {}

local function format_entry(entry)
  local profile_str = #entry.profiles > 0 and (" [" .. table.concat(entry.profiles, ",") .. "]") or ""
  return string.format("%s%s - %s", entry.name, profile_str, entry.status)
end

---Opens a vim.ui.select picker over every tracked session (running or
---recently stopped) and switches nvim-dap-ui's focus to the chosen one.
function M.pick()
  local entries = session.list()
  if #entries == 0 then
    vim.notify("java-debug-model: no debug sessions tracked", vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = "Switch focus to debug session:",
    format_item = format_entry,
  }, function(choice)
    if not choice then return end
    if choice.status == "stopped" then
      vim.notify("java-debug-model: session '" .. choice.name .. "' has already stopped", vim.log.levels.WARN)
      return
    end
    session.focus(choice.id)
  end)
end

---Prints a lightweight running/paused/stopped status list to the command
---line - a persistent floating window isn't required for this and would
---just be one more thing to keep in sync with the registry.
function M.status()
  local entries = session.list()
  if #entries == 0 then
    print("java-debug-model: no debug sessions tracked")
    return
  end
  print("java-debug-model sessions:")
  for _, entry in ipairs(entries) do
    print("  " .. format_entry(entry))
  end
end

---Opens a picker over every RUNNING/STARTING session and stops (disconnects
---with terminateDebuggee=true) the chosen one, without disturbing any other
---concurrently running session.
function M.stop()
  local running = session.list_running()
  if #running == 0 then
    vim.notify("java-debug-model: no running debug sessions to stop", vim.log.levels.INFO)
    return
  end
  vim.ui.select(running, {
    prompt = "Stop debug session:",
    format_item = format_entry,
  }, function(choice)
    if not choice then return end
    session.terminate(choice.id)
    vim.notify("java-debug-model: stopping session '" .. choice.name .. "'...", vim.log.levels.INFO)
  end)
end

---Opens a picker over every tracked session (running or stopped) and restarts the chosen one:
---terminate + re-run its DebugConfig from scratch (fresh classPaths/sourcePaths), see
---session.restart. A stopped entry just re-launches directly (nothing to terminate first).
function M.restart()
  local entries = session.list()
  if #entries == 0 then
    vim.notify("java-debug-model: no debug sessions tracked", vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = "Restart debug session:",
    format_item = format_entry,
  }, function(choice)
    if not choice then return end
    session.restart(choice.id)
  end)
end

---Opens a picker over EVERY tracked session (running or stopped) and
---removes the chosen one from the registry entirely - stops it first if
---still running (see session.remove). Use this to clear out old finished
---sessions one at a time instead of waiting for prune_stopped.
function M.remove()
  local entries = session.list()
  if #entries == 0 then
    vim.notify("java-debug-model: no debug sessions tracked", vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = "Remove session from the list (stops it first if still running):",
    format_item = format_entry,
  }, function(choice)
    if not choice then return end
    session.remove(choice.id)
    vim.notify("java-debug-model: removed session '" .. choice.name .. "' from the list", vim.log.levels.INFO)
  end)
end

---One-stop management menu: pick a session, then pick what to do with it
---(focus/stop/remove) - covers list+act in a single command instead of
---remembering 3 separate ones.
function M.manage()
  local entries = session.list()
  if #entries == 0 then
    vim.notify("java-debug-model: no debug sessions tracked", vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = "Manage debug session:",
    format_item = format_entry,
  }, function(choice)
    if not choice then return end
    local actions = choice.status == "stopped"
        and { "Restart", "Remove from list" }
        or { "Focus", "Restart", "Stop", "Remove from list" }
    vim.ui.select(actions, {
      prompt = string.format("%s [%s] - action:", choice.name, choice.status),
    }, function(action)
      if action == "Focus" then
        session.focus(choice.id)
      elseif action == "Restart" then
        session.restart(choice.id)
      elseif action == "Stop" then
        session.terminate(choice.id)
        vim.notify("java-debug-model: stopping session '" .. choice.name .. "'...", vim.log.levels.INFO)
      elseif action == "Remove from list" then
        session.remove(choice.id)
        vim.notify("java-debug-model: removed session '" .. choice.name .. "' from the list", vim.log.levels.INFO)
      end
    end)
  end)
end

return M
