package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-dap"))
local session = require("java-debug-model.session")

-- fake nvim-dap Session objects, mimicking the real async
-- Session:disconnect(opts, cb) contract (callback fires later, not
-- synchronously, just like a real socket round-trip would).
local function make_fake_dap_session(delay_ms)
  local calls = {}
  local fake = { calls = calls }
  function fake:disconnect(opts, cb)
    table.insert(calls, opts)
    vim.defer_fn(function() cb(nil, {}) end, delay_ms or 10)
  end
  return fake
end

local dap1 = make_fake_dap_session(20)
local dap2 = make_fake_dap_session(50)

local id1 = session.register({ name = "App-1", module_path = "/mod-a", profiles = {}, port = 1 })
local id2 = session.register({ name = "App-2", module_path = "/mod-b", profiles = {}, port = 2 })
session.mark_started(id1, dap1)
session.mark_started(id2, dap2)
assert(#session.list_running() == 2, "expected 2 running sessions before cleanup")

local start = vim.loop.now()
session.terminate_all_sync(3000)
local elapsed = vim.loop.now() - start

assert(#dap1.calls == 1, "session 1 should have been disconnected exactly once")
assert(dap1.calls[1].terminateDebuggee == true, "disconnect must request terminateDebuggee=true")
assert(#dap2.calls == 1, "session 2 should have been disconnected exactly once")
assert(dap2.calls[1].terminateDebuggee == true, "disconnect must request terminateDebuggee=true")
assert(elapsed >= 45, "terminate_all_sync should have BLOCKED until the slower (50ms) disconnect finished, took "
  .. elapsed .. "ms")
assert(elapsed < 3000, "terminate_all_sync should return promptly once both disconnects finish, not wait for the full timeout")
assert(#session.list_running() == 0,
  "both sessions should be marked stopped in the registry once terminate_all_sync returns")

print("terminate_all_sync direct call: OK (waited " .. elapsed .. "ms for both sessions)")

-- a session with NO dap_session (never got past "starting") must not error
local id3 = session.register({ name = "App-3", module_path = "/mod-c", profiles = {}, port = 3 })
local ok = pcall(session.terminate_all_sync, 500)
assert(ok, "terminate_all_sync must not error on a session with no dap_session yet")

-- VimLeavePre wiring: setup_listeners() must register an autocmd that calls
-- terminate_all_sync automatically.
local ok_dap = pcall(require, "dap")
if ok_dap then
  session.setup_listeners()
  local dap3 = make_fake_dap_session(10)
  local id4 = session.register({ name = "App-4", module_path = "/mod-d", profiles = {}, port = 4 })
  session.mark_started(id4, dap3)
  vim.cmd("doautocmd VimLeavePre")
  vim.wait(500, function() return #dap3.calls > 0 end, 20)
  assert(#dap3.calls == 1, "VimLeavePre should have triggered a real disconnect on the running session")
  print("VimLeavePre autocmd wiring: OK")
else
  print("(nvim-dap not on runtimepath in this headless script - skipped VimLeavePre wiring check)")
end

print("session.lua cleanup-on-exit smoke test: OK")
