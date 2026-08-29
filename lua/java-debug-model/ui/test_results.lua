-- Small pass/fail/skip tree for unit test runs, replacing nvim-jdtls's
-- default quickfix dump: grouped by class, with an inline assertion/stack
-- trace excerpt on failure and a "rerun failed" action.
local M = {}

---@class TestCaseResult
---@field fq_class string
---@field method string|nil
---@field failed boolean
---@field traces string[]

---@type TestCaseResult[]
local last_tests = {}
---@type table[]   raw quickfix-shaped failure items from jdtls.junit's show()
local last_items = {}

local buf = nil

---@param items table[]   from jdtls.dap's after_test(items, tests)
---@param tests TestCaseResult[]
function M.record(items, tests)
  last_items = items or {}
  last_tests = tests or {}
  M.render()
end

---@return {file:string|nil, line:integer|nil, class_name:string, method_name:string}[]
function M.last_failed()
  local failed = {}
  for _, t in ipairs(last_tests) do
    if t.failed then
      -- best-effort file/line from the matching quickfix item (jdtls.junit
      -- only produces one when it could match a stack frame to the test).
      local file, line = nil, nil
      for _, item in ipairs(last_items) do
        if item.bufnr and item.text and t.method and item.text:find(t.method, 1, true) then
          file = vim.api.nvim_buf_get_name(item.bufnr)
          line = item.lnum
          break
        end
      end
      table.insert(failed, { file = file, line = line, class_name = t.fq_class, method_name = t.method })
    end
  end
  return failed
end

local function summary_line()
  local total, passed, failed = #last_tests, 0, 0
  for _, t in ipairs(last_tests) do
    if t.failed then failed = failed + 1 else passed = passed + 1 end
  end
  return string.format("%d total, %d passed, %d failed", total, passed, failed)
end

---Renders the last recorded run into a scratch buffer, grouped by class:
---  ClassName
---    ✓ methodA
---    ✗ methodB
---        <stack trace excerpt>
function M.render()
  local lines = { summary_line(), "" }

  local by_class = {}
  local class_order = {}
  for _, t in ipairs(last_tests) do
    if not by_class[t.fq_class] then
      by_class[t.fq_class] = {}
      table.insert(class_order, t.fq_class)
    end
    table.insert(by_class[t.fq_class], t)
  end

  for _, class_name in ipairs(class_order) do
    table.insert(lines, class_name)
    for _, t in ipairs(by_class[class_name]) do
      local mark = t.failed and "✗" or "✓"
      table.insert(lines, string.format("  %s %s", mark, t.method or "<init>"))
      if t.failed and t.traces and #t.traces > 0 then
        local excerpt = t.traces[1]
        if #excerpt > 160 then excerpt = excerpt:sub(1, 160) .. "..." end
        table.insert(lines, "      " .. excerpt)
      end
    end
  end

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(buf, "java-debug-model://test-results")
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---Opens the results buffer in a split (creating it if a run hasn't
---happened yet in this session).
function M.open()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    M.render()
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end

return M
