-- Shared state between whatever config sets up nvim-dap's terminal_win_cmd/port-sniffing (a
-- generic, NOT Java-specific concern - handles Rust/codelldb sessions too, so it's expected to
-- live in the consuming nvim config's own dap.lua, not be owned by this plugin) and
-- java-debug-model's own session.lua/ui/session_manager.lua, which read from it.
--
-- Bundled here (top-level lua/, NOT namespaced under java-debug-model/) as a DEFAULT so
-- `require("dap_status")` resolves even on a fresh machine that installed only this one plugin -
-- a config that already ships its OWN dap_status.lua (e.g. this repo's own author's config) keeps
-- using that instead: Neovim's runtimepath always searches the user's own ~/.config/nvim/lua/
-- before any lazy-managed plugin's lua/ dir, so a same-named local module wins automatically, no
-- conflict. Only used if the consuming config doesn't provide its own.
local M = {}

--- config.name (debug profile name) -> port (string) sniffed from the program's console output.
M.ports = {}

--- config.name -> systemProcessId (from DAP event "process") of the actual debuggee JVM/process.
--- Used to force-kill (SIGKILL) if terminate/disconnect reports success but the process lingers.
M.pids = {}

--- config.name -> bufnr of that session's own console TERMINAL buffer (one per session, created
--- by dap.defaults.fallback.terminal_win_cmd in the consuming config's dap.lua). Read by
--- java-debug-model/ui/session_manager.lua to show a session's log without depending on that
--- config's own private closure locals.
M.term_bufs = {}

return M
