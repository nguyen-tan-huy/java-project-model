-- Wraps jdtls.test_nearest_method()/test_class() directly - the java-test
-- bundle already finds @Test methods (JUnit 4/5, parameterized, TestNG)
-- correctly, so this module never reimplements discovery. Cross-module
-- classpath correctness comes for free from jdtls.lua's resolution.
--
-- Also registers every test run into session.lua's registry (kind="test") - same as regular
-- debug launches - so it shows up as a profile row in ui/session_manager.lua, exactly like
-- IntelliJ auto-generates a temporary Run Configuration the moment you run a single test: same
-- console-log capture (session.lua's OutputEvent listener already works for ANY tracked session
-- regardless of how it was launched), same stop/focus/RESTART actions (M.rerun_profile below), no
-- config_store.DebugConfig needed - and <leader>jtm/jtc auto-open+focus ui/session_manager.lua on
-- the row that just started, same as pressing "Run" in IntelliJ pops the Services panel open.
--
-- UNLIKE session.lua's own in-memory registry (wiped every Neovim restart), test_profile_store.lua
-- persists the "which file/scope/line" side of a test run to disk (mirrors config_store.lua's own
-- DebugConfig persistence) - so a test profile's ROW survives quitting Neovim the same way a saved
-- DebugConfig's row does, even though its live session obviously doesn't (nothing is still running
-- after Neovim exits - session.terminate_all_sync already handles that, see session.lua).
local results = require("java-debug-model.ui.test_results")
local session = require("java-debug-model.session")
local test_profile_store = require("java-debug-model.test_profile_store")

local M = {}

---@class TestReplay
---@field variant "run"|"debug"
---@field scope "nearest_method"|"class"
---@field bufnr integer
---@field lnum integer  only meaningful for scope=="nearest_method"

---session.SessionEntry.id -> TestReplay, so ui/session_manager.lua's "run"/"restart" actions on a
---"test" row can re-invoke the EXACT same test (M.rerun_profile below) - jdtls.dap's test_nearest_method/
---test_class both accept an explicit opts.bufnr/opts.lnum instead of always reading the CURRENT
---window's cursor, so replaying one doesn't require jumping back to the original source file/line
---first.
---@type table<integer, TestReplay>
local replays = {}

---Best-effort display name for the test about to run: jdtls itself only resolves and reports
---which method actually ran AFTER it's done (inside after_test), so this can't know the exact
---method name up front for "nearest_method" - the short class name plus a scope tag is close
---enough for a list label; the real per-method pass/fail detail still shows up in
---ui/test_results.lua as usual.
---
---IMPORTANT: this MUST resolve purely from `bufnr`'s own content, never the CURRENTLY focused
---buffer/window. jdtls.util's own resolve_classname() ignores whatever bufnr you think you're
---passing it and always reads `vim.api.nvim_get_current_buf()`/`vim.fn.expand("%")` instead - fine
---for a fresh run (current buffer == bufnr there), but M.rerun_profile() below calls this from
---ui/session_manager.lua's panel buffer (a DIFFERENT current buffer than the original test file),
---so calling into resolve_classname() there silently computes the panel's own name instead of the
---test's, the by-name match in invoke() below then fails to find the old session, and a rerun ends
---up piling up a brand-new temporary profile row next to the stale one instead of replacing it.
---@param bufnr integer
---@param scope "nearest_method"|"class"
---@return string
local function display_name(bufnr, scope)
  local short = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
  return scope == "class" and short or (short .. " (nearest test)")
end

---Opens ui/session_manager.lua (if not already) and moves its cursor to the row tracking `id` -
---best-effort: the panel module is required lazily (avoids a require cycle - session_manager.lua
---itself doesn't require test.lua, but keeping the direction consistent with how the rest of this
---plugin lazily requires "java-debug-model" to avoid init.lua cycles) and silently no-ops if
---unavailable for any reason, since this is a "nice to have" UX touch, not core functionality.
---@param id integer
local function focus_in_session_manager(id)
  local ok, ui = pcall(require, "java-debug-model.ui.session_manager")
  if ok then ui.focus_entry(id) end
end

---@param variant "run"|"debug"
---@param scope "nearest_method"|"class"
---@param opts table?  { bufnr?: integer, lnum?: integer }  defaults to the CURRENT buffer/cursor
---- pass these explicitly to replay a PREVIOUSLY started test (M.rerun_profile) without needing to
---jump back to its source location first.
local function invoke(variant, scope, opts)
  opts = opts or {}
  local ok_jdtls, jdtls_dap = pcall(require, "jdtls.dap")
  if not ok_jdtls then
    vim.notify("java-debug-model: nvim-jdtls not available", vim.log.levels.ERROR)
    return
  end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]

  -- <leader>jtm/jtc (init.lua) are bound GLOBALLY, not scoped to java buffers - pressing them
  -- while focus happens to be on ui/session_manager.lua's own panel (or the Maven panel, project
  -- tree, ...) instead of the actual test file would otherwise silently pass THAT scratch buffer
  -- through as `bufnr` here (opts.bufnr is nil on a fresh run, only M.rerun ever supplies it), and
  -- jdtls has no test method to find in it - the run gets stuck forever at "starting (test)" with
  -- no console output, showing up as a bogus profile named after the panel's own buffer instead of
  -- the class under test. Refuse early with a clear hint instead of registering that broken entry.
  if opts.bufnr == nil and vim.bo[bufnr].filetype ~= "java" then
    vim.notify(
      "java-debug-model: con trỏ không ở trong file Java (buffer hiện tại: '"
      .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t") .. "') - đứng trong file test "
      .. "rồi bấm <leader>jtm/jtc lại.", vim.log.levels.WARN)
    return
  end

  local jdm = require("java-debug-model")
  local name = display_name(bufnr, scope)
  local root = jdm._find_root(bufnr)

  -- Persist this profile (file/scope/line) to disk BEFORE registering the live session below, so
  -- that by the time focus_in_session_manager()'s render() runs, ui/session_manager.lua's profile
  -- list (test_profile_store.list(root)) already includes it and can attach the fresh session
  -- entry to the right row - see test_profile_store.lua's own comment on why this exists (a saved
  -- DebugConfig's row already survives a Neovim restart, a test run's row now does too).
  test_profile_store.add(root, {
    name = name,
    file = vim.api.nvim_buf_get_name(bufnr),
    scope = scope,
    lnum = scope == "nearest_method" and lnum or nil,
    variant = variant,
  })

  -- Re-running the SAME test replaces its previous temporary entry instead of piling up a new
  -- row every time - matches IntelliJ reusing one temporary Run Configuration per test rerun.
  for _, e in ipairs(session.list()) do
    if e.kind == "test" and e.name == name then
      session.remove(e.id)
      replays[e.id] = nil
    end
  end

  local session_id = session.register({
    name = name,
    kind = "test",
    root = root,
  })
  replays[session_id] = { variant = variant, scope = scope, bufnr = bufnr, lnum = lnum }
  focus_in_session_manager(session_id)

  -- jdtls.dap's test runner calls dap.run() internally (opaque to us), never returns the Session
  -- it creates, and Session objects don't record their own launch config - so there's no direct
  -- way to correlate the session THIS invoke() call is about to start back to session_id. PRIMARY
  -- path: hook the DAP "initialized" event, which always arrives BEFORE the debuggee actually
  -- starts running (session.lua's own event_initialized handler only sends `configurationDone` -
  -- the request that makes a launch-type debuggee actually start executing/printing - AFTER this
  -- event, see nvim-dap's dap/session.lua) - so linking here, instead of polling AFTER the fact,
  -- reliably beats the very first OutputEvent the debuggee can possibly send (a @SpringBootTest's
  -- whole context-startup log included), rather than losing it to the same race
  -- session.lua's pending-buffer fallback exists to soften (see session.lua's
  -- setup_output_capture) but can't fully close on its own when linking itself arrives too late.
  local ok_dap, dap = pcall(require, "dap")
  local linked = false
  local listener_key = "java-debug-model-test-link-" .. session_id
  local function try_link(dap_session)
    if linked then return end
    linked = true
    if ok_dap then dap.listeners.after.event_initialized[listener_key] = nil end
    session.mark_started(session_id, dap_session)
  end
  if ok_dap then
    dap.listeners.after.event_initialized[listener_key] = function(dap_session) try_link(dap_session) end
  end

  -- FALLBACK: same "poll dap.session() for a NEW object" technique dap.lua's own M.launch uses -
  -- covers any adapter/scenario that skips "initialized" entirely, and is also what finally marks
  -- the entry stopped if nothing ever actually started (compile error, no test found...).
  local session_before = ok_dap and dap.session()
  local attempts = 0
  local function poll_for_new_session()
    if linked then return end
    attempts = attempts + 1
    local current = ok_dap and dap.session()
    if current and current ~= session_before then
      try_link(current)
    elseif attempts < 150 then -- ~30s at 200ms
      vim.defer_fn(poll_for_new_session, 200)
    else
      if ok_dap then dap.listeners.after.event_initialized[listener_key] = nil end
      if not linked then session.mark_stopped(session_id) end
    end
  end
  if ok_dap then vim.defer_fn(poll_for_new_session, 100) end

  local config_overrides = variant == "run" and { noDebug = true } or nil
  local invoke_opts = {
    bufnr = bufnr,
    lnum = scope == "nearest_method" and lnum or nil,
    config_overrides = config_overrides,
    -- Reuses the fresh-port/session-per-launch mechanics from dap.lua/session.lua:
    -- nvim-jdtls's test runner goes through the same vscode.java.startDebugSession
    -- flow, so a test-debug session doesn't block other concurrent sessions.
    -- jdtls.dap's own runner calls after_test(items, tests): items are
    -- quickfix-shaped failure entries, tests are the full pass+fail list
    -- parsed from the JUnit reporter protocol.
    after_test = function(items, tests)
      results.record(items, tests)
    end,
  }

  if scope == "nearest_method" then
    jdtls_dap.test_nearest_method(invoke_opts)
  else
    jdtls_dap.test_class(invoke_opts)
  end
end

function M.run_nearest_method() invoke("run", "nearest_method") end
function M.debug_nearest_method() invoke("debug", "nearest_method") end
function M.run_class() invoke("run", "class") end
function M.debug_class() invoke("debug", "class") end

---@param root string
---@return TestProfile[]
function M.list_profiles(root)
  return test_profile_store.list(root)
end

---Re-invokes a test profile by name - what ui/session_manager.lua's run/restart actions call for
---a "test" row, the same way they call session.restart() for a "config" row. Prefers a LIVE replay
---from THIS Neovim session (replays{}, keyed by session id - exact bufnr/lnum, no reopening
---needed) when one is still around; falls back to the persisted profile
---(test_profile_store.lua) otherwise, opening its source file fresh - this is what lets a profile
---be re-run after a Neovim restart, when replays{} is empty and no "test" session.SessionEntry
---exists yet either.
---@param root string
---@param name string
function M.rerun_profile(root, name)
  local live_id
  for _, e in ipairs(session.list()) do
    if e.kind == "test" and e.name == name then live_id = e.id end
  end
  local replay = live_id and replays[live_id]
  if replay and vim.api.nvim_buf_is_valid(replay.bufnr) then
    invoke(replay.variant, replay.scope, { bufnr = replay.bufnr, lnum = replay.lnum })
    return
  end

  local profile = test_profile_store.get(root, name)
  if not profile then
    vim.notify("java-debug-model: không tìm thấy profile test '" .. name .. "'.", vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(profile.file) == 0 then
    vim.notify("java-debug-model: file gốc của profile '" .. name .. "' không còn tồn tại: " .. profile.file,
      vim.log.levels.WARN)
    return
  end
  local buf = vim.fn.bufadd(profile.file)
  vim.fn.bufload(buf)
  invoke(profile.variant or "debug", profile.scope, { bufnr = buf, lnum = profile.lnum })
end

---Removes a test profile entirely: stops/removes any live session tracking it, then deletes it
---from disk (test_profile_store.lua) - the "test" row equivalent of config_store.remove for a
---"config" row (both are real, persisted deletions now, so ui/session_manager.lua's delete
---confirms first for both the same way).
---@param root string
---@param name string
function M.remove_profile(root, name)
  for _, e in ipairs(session.list()) do
    if e.kind == "test" and e.name == name then
      if e.status ~= "stopped" then
        session.terminate(e.id, function() end)
      end
      session.remove(e.id)
      replays[e.id] = nil
    end
  end
  test_profile_store.remove(root, name)
end

---Re-invokes the run for just the failed methods' locations from the last
---result set, rather than the whole class/method again.
---@param variant "run"|"debug"
function M.rerun_failed(variant)
  local failed = results.last_failed()
  if #failed == 0 then
    vim.notify("java-debug-model: no failed tests to rerun", vim.log.levels.INFO)
    return
  end
  local ok_jdtls, jdtls_dap = pcall(require, "jdtls.dap")
  if not ok_jdtls then return end

  local config_overrides = variant == "run" and { noDebug = true } or nil
  for _, failure in ipairs(failed) do
    if failure.file then
      vim.cmd("edit " .. vim.fn.fnameescape(failure.file))
      vim.api.nvim_win_set_cursor(0, { failure.line or 1, 0 })
      jdtls_dap.test_nearest_method({
        config_overrides = config_overrides,
        after_test = function(items, tests) results.record(items, tests) end,
      })
    end
  end
end

return M
