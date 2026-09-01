-- Aggregates every "something is running" signal this plugin produces into
-- one short string a statusline component can poll - Maven resolves can take
-- 10-60s (watcher.lua) and Maven Lifecycle runs/debug launches also take
-- real time, so without this the editor looks frozen with no feedback other
-- than a transient vim.notify that's easy to miss and doesn't persist.
local maven_resolver = require("java-debug-model.resolver.maven")
local maven_output = require("java-debug-model.maven_output")
local session = require("java-debug-model.session")
local jdtls_launcher = require("java-debug-model.jdtls_launcher")

local M = {}

---@return string  empty when nothing is running
function M.text()
  local parts = {}

  if maven_resolver.is_busy() then
    table.insert(parts, "resolving Maven project")
  end

  -- jdtls_launcher.starting[root] stays true từ lúc resolve model bắt đầu tới lúc jdt.ls tự báo
  -- ServiceReady (đã import/index xong) - khoảng này Ctrl+B/gd có thể chưa dùng được, nên báo rõ
  -- thay vì để trông như treo.
  local starting_roots = {}
  for root in pairs(jdtls_launcher.starting) do
    table.insert(starting_roots, vim.fn.fnamemodify(root, ":t"))
  end
  if #starting_roots > 0 then
    table.sort(starting_roots)
    table.insert(parts, "khởi động jdtls: " .. table.concat(starting_roots, ", "))
  end

  local jobs = maven_output.active_titles()
  if #jobs > 0 then
    table.insert(parts, table.concat(jobs, ", "))
  end

  local starting = {}
  for _, entry in ipairs(session.list()) do
    if entry.status == "starting" then
      table.insert(starting, entry.name)
    end
  end
  if #starting > 0 then
    table.sort(starting)
    table.insert(parts, "launching " .. table.concat(starting, ", "))
  end

  if #parts == 0 then return "" end
  return "⏳ " .. table.concat(parts, " | ")
end

---@return boolean
function M.is_busy()
  return M.text() ~= ""
end

return M
