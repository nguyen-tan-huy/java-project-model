-- Watches every pom.xml in a module tree, debounces rebuilds, and caches the
-- resolved Project in memory for the session.
local maven = require("java-debug-model.resolver.maven")

local M = {}

---@type table<string, {project: table|nil, mtimes: table<string, integer>, handles: table[], on_reload: fun()[]}>
local state_by_root = {}

local DEBOUNCE_MS = 500

local function pom_paths_for(project)
  local paths = {}
  for _, mod in ipairs(project.modules) do
    table.insert(paths, mod.path .. "/pom.xml")
  end
  return paths
end

local function mtime(path)
  local stat = vim.loop.fs_stat(path)
  return stat and stat.mtime.sec or nil
end

---@param root string
---@param opts table
local function rebuild(root, opts, callback)
  -- mvn can easily take 10-60s on a real multi-module project (several
  -- effective-pom + dependency:build-classpath calls). Without an explicit
  -- "in progress" notification this reads as Neovim being frozen, since
  -- nothing else prints while it's running.
  local notify_timer = vim.loop.new_timer()
  local notified = false
  notify_timer:start(1500, 0, vim.schedule_wrap(function()
    notify_timer:close()
    notified = true
    vim.notify("java-debug-model: resolving Maven project (this can take a while on first run)...",
      vim.log.levels.INFO)
  end))

  maven.build(root, opts, function(ok, project, err)
    if not notify_timer:is_closing() then notify_timer:stop(); notify_timer:close() end

    if not ok then
      vim.notify("java-debug-model: Maven resolve failed: " .. tostring(err), vim.log.levels.ERROR)
      if callback then callback(false, nil) end
      return
    end
    local state = state_by_root[root]
    state.project = project
    state.mtimes = {}
    for _, p in ipairs(pom_paths_for(project)) do
      state.mtimes[p] = mtime(p)
    end
    M._rewatch(root)
    for _, cb in ipairs(state.on_reload) do
      pcall(cb, project)
    end
    if notified then
      vim.notify("java-debug-model: Maven project resolved (" .. #project.modules .. " modules)",
        vim.log.levels.INFO)
    end
    if callback then callback(true, project) end
  end)
end

---(Re)installs fs_event watches for every pom.xml the current project knows
---about. Called after each successful build since the module set can change.
function M._rewatch(root)
  local state = state_by_root[root]
  if not state then return end
  for _, h in ipairs(state.handles) do
    pcall(function() h:stop(); h:close() end)
  end
  state.handles = {}

  local timer = nil
  local function debounced_reload()
    if timer then timer:stop(); timer:close() end
    timer = vim.loop.new_timer()
    timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      timer:close()
      timer = nil
      -- only rebuild if an mtime actually changed - fs_event can fire on
      -- unrelated metadata touches, and we never want to rebuild on every save
      -- of an unrelated file.
      local changed = false
      for p, cached_mtime in pairs(state.mtimes) do
        if mtime(p) ~= cached_mtime then changed = true break end
      end
      if changed then
        rebuild(root, state.opts)
      end
    end))
  end

  if state.project then
    for _, pom_path in ipairs(pom_paths_for(state.project)) do
      local dir = vim.fn.fnamemodify(pom_path, ":h")
      local handle = vim.loop.new_fs_event()
      handle:start(dir, {}, vim.schedule_wrap(function(_, filename)
        if filename == "pom.xml" then debounced_reload() end
      end))
      table.insert(state.handles, handle)
    end
  end
end

---Gets the cached Project for `root`, building it the first time (or when
---forced). Async: calls `callback(project)` once available.
---@param root string
---@param opts table  { active_profiles?: string[], force?: boolean }
---@param callback fun(project: table|nil)
function M.get(root, opts, callback)
  opts = opts or {}
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local state = state_by_root[root]
  if not state then
    state = { project = nil, mtimes = {}, handles = {}, on_reload = {}, opts = opts }
    state_by_root[root] = state
  end
  state.opts = opts

  if state.project and not opts.force then
    callback(state.project)
    return
  end

  rebuild(root, opts, function(ok, project)
    callback(ok and project or nil)
  end)
end

---Forces a full re-resolve, ignoring cache/mtime, for a whole module tree.
---This is the manual "Reload Maven" equivalent behind :JavaModelReload.
---@param root string
---@param opts table
---@param callback fun(project: table|nil)
function M.reload(root, opts, callback)
  opts = vim.tbl_extend("force", opts or {}, { force = true })
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  require("java-debug-model.resolver.maven").clear_cache(root)
  M.get(root, opts, callback)
end

---Registers a callback invoked with the new Project every time `root`'s
---model is successfully rebuilt (from a watcher-triggered rebuild or an
---explicit reload). Used so stale dap.configurations.java can regenerate.
---@param root string
---@param callback fun(project: table)
function M.on_reload(root, callback)
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local state = state_by_root[root]
  if not state then
    state = { project = nil, mtimes = {}, handles = {}, on_reload = {}, opts = {} }
    state_by_root[root] = state
  end
  table.insert(state.on_reload, callback)
end

function M.get_cached(root)
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local state = state_by_root[root]
  return state and state.project or nil
end

return M
