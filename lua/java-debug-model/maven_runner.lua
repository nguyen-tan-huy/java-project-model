-- Async mvn/mvnw invocation, scoped per module via -pl, streamed to a
-- terminal buffer (maven_output.lua). This is the explicit, user-triggered
-- build path - separate from the resolver's own internal mvn calls, and
-- never forces a project-model reload by itself (the watcher already reacts
-- if a pom.xml happens to change as a result).
local output = require("java-debug-model.maven_output")

local M = {}

M.skip_tests = false

local function mvn_cmd(root)
  local wrapper = root .. "/mvnw"
  if vim.fn.executable(wrapper) == 1 then return wrapper end
  return "mvn"
end

---Runs one or more Maven phases/goals scoped to `module_rel_path` (relative
---to the reactor root), streamed into a terminal split.
---@param root string   workspace/reactor root - NEVER `cd` into the module,
---                      that loses reactor-wide plugin config inherited from
---                      parent POMs.
---@param module_rel_path string   e.g. "module-a" - path relative to root
---@param goals string[]  phases/goals, e.g. {"clean", "install"}
---@param opts table?  { also_make?: boolean (default true, -am),
---                       also_make_dependents?: boolean (default false, -amd),
---                       profiles?: string[], extra_args?: string[] }
function M.run(root, module_rel_path, goals, opts)
  opts = opts or {}
  local cmd = { mvn_cmd(root) }
  vim.list_extend(cmd, goals)
  table.insert(cmd, "-pl")
  table.insert(cmd, module_rel_path)

  local also_make = opts.also_make
  if also_make == nil then also_make = true end
  if also_make then table.insert(cmd, "-am") end
  -- -amd ("also make dependents") is opt-in only: it can trigger a much
  -- bigger build than expected, so never default it on.
  if opts.also_make_dependents then table.insert(cmd, "-amd") end

  if opts.profiles and #opts.profiles > 0 then
    table.insert(cmd, "-P" .. table.concat(opts.profiles, ","))
  end
  if M.skip_tests then
    table.insert(cmd, "-DskipTests")
  end
  if opts.extra_args then
    vim.list_extend(cmd, opts.extra_args)
  end

  output.run_in_terminal(cmd, root, {
    title = string.format("mvn %s (%s)", table.concat(goals, " "), module_rel_path),
  })
end

---Runs an arbitrary one-off goal, non-interactive (for keymaps/scripts).
---@param root string
---@param module_rel_path string
---@param goal string
---@param opts table?
function M.run_goal(root, module_rel_path, goal, opts)
  M.run(root, module_rel_path, { goal }, opts)
end

---Toggles the "Skip Tests" flag applied to every subsequent M.run() call.
function M.toggle_skip_tests()
  M.skip_tests = not M.skip_tests
  vim.notify("java-debug-model: Skip Tests " .. (M.skip_tests and "ON" or "OFF"), vim.log.levels.INFO)
end

return M
