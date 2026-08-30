-- Generates dap.configurations.java entries from a saved DebugConfig,
-- resolving classpath/sourcepath via jdtls.lua's model-based resolution
-- (already covers cross-module debug through sibling coordinate matching).
local jdtls_bridge = require("java-debug-model.jdtls")
local session = require("java-debug-model.session")

local M = {}

---Builds one nvim-dap `dap.configurations.java` entry from a saved
---DebugConfig, snapshotting the config at launch time (editing/removing the
---saved config afterwards must not affect an already-running session).
---@param project table Project
---@param config table DebugConfig (see config_store.lua)
---@param opts table?  { open_j9_java_exec?: string }
---@return table dap config
function M.build_launch_config(project, config, opts)
  opts = opts or {}
  local snapshot = vim.deepcopy(config)
  local module = project:find_module_by_path(snapshot.module_path)
  if not module then
    error("java-debug-model: module not found for path " .. snapshot.module_path)
  end

  local classpaths = jdtls_bridge.resolve_classpath(project, module, { include_test = false })
  local sourcepaths = jdtls_bridge.resolve_sourcepaths(project, module, { include_test = false })

  -- `env` must serialize as a JSON OBJECT (java-debug/Gson deserializes it as
  -- Map<String,String>) - but vim.json.encode has no way to tell an empty
  -- Lua table was meant as a map rather than a list, and always emits `[]`
  -- for it. A config with no env vars set at all (the common case) would
  -- then fail at launch with a JSON deserialization error on the server
  -- side. vim.empty_dict() is the documented escape hatch: it forces `{}`.
  local env = snapshot.env_vars
  if not env or next(env) == nil then
    env = vim.empty_dict()
  end

  local dap_config = {
    type = "java",
    request = "launch",
    name = snapshot.name,
    mainClass = snapshot.main_class,
    projectName = module.artifact_id,
    modulePaths = {},
    classPaths = classpaths,
    sourcePaths = sourcepaths,
    vmArgs = snapshot.vm_args,
    args = snapshot.program_args,
    env = env,
    cwd = snapshot.working_directory,
  }

  -- OpenJ9 debug-target JVM: scoped to the DEBUG TARGET only, not jdtls's own
  -- JVM. A drop-in swap over the default HotSpot resolved from JAVA_HOME/PATH
  -- - JDWP support is unaffected, so debugging works identically, while
  -- lowering the target JVM's memory footprint (useful with several
  -- concurrent debug sessions).
  if opts.open_j9_java_exec then
    dap_config.javaExec = opts.open_j9_java_exec
  end

  return dap_config
end

---Launches a snapshot-built dap config through nvim-dap, and registers it
---with session.lua's registry so concurrent sessions (different
---modules/profile combos) don't collide.
---
---Note on "fresh port per launch": nvim-jdtls's own `dap.adapters.java`
---(start_debug_adapter in jdtls/dap.lua) already calls
---`vscode.java.startDebugSession` itself, fresh, every single time dap.run()
---resolves the "java" adapter - it's a function-type adapter, never cached
---by nvim-dap. Any port WE set on the config here would be silently ignored
---anyway (dap.attach() reads it off the resolved adapter, not the config),
---so this module doesn't fetch or set one at all.
---@param project table
---@param config table DebugConfig
---@param opts table?
function M.launch(project, config, opts)
  opts = opts or {}
  local dap_config = M.build_launch_config(project, config, opts)

  local ok_dap, dap = pcall(require, "dap")
  if not ok_dap then
    vim.notify("java-debug-model: nvim-dap not found", vim.log.levels.ERROR)
    return
  end

  local session_id = session.register({
    name = dap_config.name,
    module_path = config.module_path,
    profiles = config.maven_profiles,
  })

  -- nvim-dap's dap.run(config, opts) only supports opts.before/opts.new -
  -- there is no "after" hook, dap.run() doesn't return the Session it
  -- creates (session creation happens asynchronously, after the adapter
  -- function's own startDebugSession round-trip resolves), and Session
  -- objects don't store their launch config anywhere - so there's no direct
  -- way to correlate a freshly-created Session back to this specific
  -- launch. What dap.run() DOES do synchronously, the moment the Session
  -- object is constructed (well before its DAP handshake completes), is
  -- call dap.set_session() - so polling dap.session() for a NEW object
  -- (different from whatever was focused right before this call) is the
  -- reliable signal available.
  local session_before = dap.session()
  local attempts = 0
  local function poll_for_new_session()
    attempts = attempts + 1
    local current = dap.session()
    if current and current ~= session_before then
      session.mark_started(session_id, current)
    elseif attempts < 150 then -- ~30s at 200ms - covers a slow JVM cold start
      vim.defer_fn(poll_for_new_session, 200)
    else
      vim.notify(
        "java-debug-model: timed out waiting for debug session '" .. dap_config.name .. "' to start",
        vim.log.levels.WARN)
    end
  end
  vim.defer_fn(poll_for_new_session, 100)

  dap.run(dap_config, {
    before = function(conf) return conf end,
  })
end

return M
