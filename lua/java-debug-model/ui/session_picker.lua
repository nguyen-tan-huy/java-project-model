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

return M
