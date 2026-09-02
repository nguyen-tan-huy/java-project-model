-- Async mvn/mvnw invocation, scoped per module via -pl, streamed to a
-- terminal buffer (maven_output.lua). This is the explicit, user-triggered
-- build path - separate from the resolver's own internal mvn calls, and
-- never forces a project-model reload by itself (the watcher already reacts
-- if a pom.xml happens to change as a result).
local output = require("java-debug-model.maven_output")
local maven_jdk = require("java-debug-model.maven_jdk")

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
---                      parent POMs. Ignored (only used for cosmetics) when
---                      opts.standalone is true - see below.
---@param module_rel_path string   e.g. "module-a" - path relative to root
---@param goals string[]  phases/goals, e.g. {"clean", "install"}
---@param opts table?  { also_make?: boolean (default true, -am),
---                       also_make_dependents?: boolean (default false, -amd),
---                       profiles?: string[], extra_args?: string[],
---                       standalone?: boolean, cwd?: string, whole_reactor?: boolean }
---
---opts.standalone (pass true for a Module whose `in_reactor` field is false -
---an "independent pom" java-debug-model found via filesystem scan, not via
---root's own <modules>): `-pl <path> -am` run from `root` fails for these
---with "Could not find the selected project in the reactor: X" - Maven has
---no reactor relationship through which to select a module it doesn't even
---know about. Skip -pl/-am entirely and just run mvn standalone INSIDE the
---module's own directory (opts.cwd, normally the Module's own `path`)
---instead - each independent pom is its own, unrelated reactor of one.
---
---opts.whole_reactor (pass true for the SYNTHETIC "reactor root" node's own
---Lifecycle in ui/maven_panel.lua - there's no Module object for the parent
---aggregator pom itself): run from `root` with NO `-pl` scoping at all, so
---Maven builds every declared module in the reactor together, in dependency
---order - the normal "build everything" action for the parent.
function M.run(root, module_rel_path, goals, opts)
  opts = opts or {}
  local cwd = root
  local cmd

  if opts.standalone then
    cwd = opts.cwd or (root .. "/" .. module_rel_path)
    cmd = { mvn_cmd(cwd) }
    vim.list_extend(cmd, goals)
  elseif opts.whole_reactor then
    cmd = { mvn_cmd(root) }
    vim.list_extend(cmd, goals)
  else
    cmd = { mvn_cmd(root) }
    vim.list_extend(cmd, goals)
    table.insert(cmd, "-pl")
    table.insert(cmd, module_rel_path)

    local also_make = opts.also_make
    if also_make == nil then also_make = true end
    if also_make then table.insert(cmd, "-am") end
    -- -amd ("also make dependents") is opt-in only: it can trigger a much
    -- bigger build than expected, so never default it on.
    if opts.also_make_dependents then table.insert(cmd, "-amd") end
  end

  if opts.profiles and #opts.profiles > 0 then
    table.insert(cmd, "-P" .. table.concat(opts.profiles, ","))
  end
  if M.skip_tests then
    table.insert(cmd, "-DskipTests")
  end
  if opts.extra_args then
    vim.list_extend(cmd, opts.extra_args)
  end

  local scope_label = opts.whole_reactor and "whole reactor" or module_rel_path
  output.run_in_terminal(cmd, cwd, {
    title = string.format("mvn %s (%s)", table.concat(goals, " "), scope_label),
    -- Persisted per-root JDK selection (maven_jdk.lua) - nil when none was ever picked, in which
    -- case termopen inherits Neovim's own JAVA_HOME/PATH unchanged, exactly as before.
    env = maven_jdk.env_for(root),
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
