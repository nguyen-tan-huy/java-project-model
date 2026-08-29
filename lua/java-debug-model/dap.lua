-- Generates dap.configurations.java entries from a saved DebugConfig,
-- resolving classpath/sourcepath via jdtls.lua's model-based resolution
-- (already covers cross-module debug through sibling coordinate matching).
local jdtls_bridge = require("java-debug-model.jdtls")
local session = require("java-debug-model.session")

local M = {}

---Requests a FRESH debug session/port from the java-debug bundle. Never
---cache/reuse a previously obtained port: vscode.java.startDebugSession
---returns a new one on every call, which is exactly what lets multiple
---concurrent debug sessions run independently.
---@param callback fun(ok: boolean, port: integer|nil)
function M.request_fresh_port(callback)
  local client = vim.lsp.get_clients({ name = "jdtls" })[1]
  if not client then
    callback(false, nil)
    return
  end
  client:request("workspace/executeCommand", { command = "vscode.java.startDebugSession" }, function(err, port)
    if err or not port then
      callback(false, nil)
      return
    end
    callback(true, port)
  end, 0)
end

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
    env = snapshot.env_vars,
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

---Launches a snapshot-built dap config through nvim-dap, always requesting a
---fresh session/port first, and registers it with session.lua's registry so
---concurrent sessions (different modules/profile combos) don't collide.
---@param project table
---@param config table DebugConfig
---@param opts table?
function M.launch(project, config, opts)
  opts = opts or {}
  local dap_config = M.build_launch_config(project, config, opts)

  M.request_fresh_port(function(ok, port)
    if not ok then
      vim.notify("java-debug-model: failed to obtain a fresh debug session/port", vim.log.levels.ERROR)
      return
    end
    dap_config.port = port
    dap_config.hostName = "127.0.0.1"

    local ok_dap, dap = pcall(require, "dap")
    if not ok_dap then
      vim.notify("java-debug-model: nvim-dap not found", vim.log.levels.ERROR)
      return
    end

    local session_id = session.register({
      name = dap_config.name,
      module_path = config.module_path,
      profiles = config.maven_profiles,
      port = port,
    })

    dap.run(dap_config, {
      before = function(conf) return conf end,
      after = function()
        session.mark_started(session_id, dap.session())
      end,
    })
  end)
end

return M
