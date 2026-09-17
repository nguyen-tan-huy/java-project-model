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
---@param opts table?  { open_j9_java_exec?: string, no_debug?: boolean }
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

  -- Which `java` binary launches the DEBUG TARGET (never jdtls's own JVM). Per-config
  -- `jdk_path` (picked in ui/config_form.lua from lua/jdk.lua's disk discovery) wins when set,
  -- since it's the more specific choice - falls back to opts.open_j9_java_exec (setup()-wide
  -- default, e.g. an OpenJ9 install) otherwise. Either way this is a drop-in `javaExec` swap:
  -- JDWP support is unaffected, so debugging works identically against any JDK/JVM vendor.
  if snapshot.jdk_path then
    dap_config.javaExec = snapshot.jdk_path .. "/bin/java"
  elseif opts.open_j9_java_exec then
    dap_config.javaExec = opts.open_j9_java_exec
  end

  -- "Run" vs "Debug" (toolbar's two buttons, or <leader>jr/<leader>jd) - same launch config either way, only this one
  -- DAP-level flag differs. java-debug honors `noDebug` the same way VS Code's own launch configs
  -- do: the JVM still starts through the SAME adapter/session machinery (so session.lua's
  -- tracking/terminate-by-marker below is unaffected), it just never installs breakpoints or
  -- stops on them - mirrors test.lua's own `variant == "run" and { noDebug = true }` convention
  -- for the test runner's Run vs Debug distinction.
  if opts.no_debug then
    dap_config.noDebug = true
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

  -- `dap.adapters.java` is registered by nvim-jdtls's own `jdtls.setup_dap()` - called from THIS
  -- plugin's jdtls_launcher.lua M.on_attach, which only ever runs once jdtls has actually
  -- ATTACHED to a real .java buffer (java-debug-model ships no ftplugin/java.lua of its own - see
  -- README's own note - so nothing forces that to happen just because a debug config gets run).
  -- Launching without it reaches nvim-dap's own generic "Config references missing adapter
  -- `java`. Available are: <whatever else you have>" error, which gives no hint about WHY - this
  -- catches it here with an actionable message instead (confirmed for real: running a config from
  -- the toolbar/global keymap/gutter while jdtls had never attached in this Neovim session hit
  -- exactly that generic error).
  if not dap.adapters.java then
    vim.notify(
      "java-debug-model: jdtls chưa attach (chưa sẵn sàng debug Java) - mở 1 file .java trong module "
        .. config.module_path .. " rồi thử lại (jdtls cần attach ít nhất 1 lần để đăng ký debug adapter).",
      vim.log.levels.ERROR)
    return
  end

  local session_id = session.register({
    name = dap_config.name,
    root = project.root,
    module_path = config.module_path,
    profiles = config.maven_profiles,
  })

  -- Tự gắn 1 marker DUY NHẤT (theo session_id) vào chính vmArgs của debuggee - session.lua's
  -- wait_release_then dùng `pgrep -f` trên marker này để tra ĐÚNG PID JVM thật khi terminate,
  -- không phụ thuộc port có bắt được từ console log hay không (xem session.lua's
  -- M.marker_for comment: java-debug adapter luôn stream qua OutputEvent, KHÔNG BAO GIỜ dùng
  -- runInTerminal, nên port-based tracking trước đây thực ra không bao giờ kích hoạt cho Java -
  -- đây là nguyên nhân thật của "stop session lúc được lúc mất").
  local marker = "-D" .. session.marker_for(session_id)
  dap_config.vmArgs = (dap_config.vmArgs and dap_config.vmArgs ~= "")
      and (dap_config.vmArgs .. " " .. marker) or marker

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

  -- Returned so callers (e.g. ui/toolbar.lua's M.run_active) can focus THIS specific launch in
  -- ui/session_manager.lua's panel (M.focus_entry(id)) instead of just opening the panel and
  -- leaving the user to find the right row themselves - session.register() above already ran
  -- synchronously, so the id is available immediately, well before the session itself finishes
  -- starting (mark_started happens later, asynchronously, once poll_for_new_session resolves).
  return session_id
end

return M
