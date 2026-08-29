-- Wraps jdtls.test_nearest_method()/test_class() directly - the java-test
-- bundle already finds @Test methods (JUnit 4/5, parameterized, TestNG)
-- correctly, so this module never reimplements discovery. Cross-module
-- classpath correctness comes for free from jdtls.lua's resolution.
local results = require("java-debug-model.ui.test_results")

local M = {}

---@param variant "run"|"debug"
---@param scope "nearest_method"|"class"
local function invoke(variant, scope)
  local ok_jdtls, jdtls_dap = pcall(require, "jdtls.dap")
  if not ok_jdtls then
    vim.notify("java-debug-model: nvim-jdtls not available", vim.log.levels.ERROR)
    return
  end

  local config_overrides = variant == "run" and { noDebug = true } or nil
  local invoke_opts = {
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
