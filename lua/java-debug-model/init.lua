-- Top-level API: setup(opts) and everything the plugin/ commands call into.
-- Wires model + resolver + watcher + jdtls + dap + maven + ui together.
local watcher = require("java-debug-model.watcher")
local jdtls_bridge = require("java-debug-model.jdtls")
local mainclass = require("java-debug-model.mainclass")
local config_store = require("java-debug-model.config_store")
local dap = require("java-debug-model.dap")
local session = require("java-debug-model.session")
local maven_runner = require("java-debug-model.maven_runner")
local test = require("java-debug-model.test")

local project_tree = require("java-debug-model.ui.project_tree")
local maven_panel = require("java-debug-model.ui.maven_panel")
local session_picker = require("java-debug-model.ui.session_picker")
local test_results = require("java-debug-model.ui.test_results")
local config_form = require("java-debug-model.ui.config_form")

local M = {}

M.opts = {
  auto_attach = false,
  active_profiles = {},
  open_j9_java_exec = nil,
  jdtls_bundle_globs = {},
}

-- The root most recently resolved (from a real file buffer, or from cwd at
-- startup/:cd - see resolve_root_from_cwd below). Falling back to
-- vim.fn.getcwd() UNCONDITIONALLY when the current buffer isn't inside any
-- project is wrong the moment the user runs a :Java* command while one of
-- this plugin's own scratch panels (project tree, Maven panel, test
-- results...) happens to be the focused window - those buffers are
-- unnamed/nofile, so find_root(0) would silently resolve to wherever Neovim
-- was launched from instead of the project the user is actually working in.
-- Remembering the last real root and falling back to THAT instead keeps
-- every :Java* command consistent regardless of which window has focus.
local last_root = nil

---Walks upward from `start_dir` for the outermost ancestor that still has a
---pom.xml (the reactor root), or nil if `start_dir` isn't inside a Maven
---project at all.
---@param start_dir string
---@return string|nil
local function walk_up_for_reactor_root(start_dir)
  local found = vim.fs.find("pom.xml", { path = start_dir, upward = true })[1]
  if not found then return nil end
  local dir = vim.fn.fnamemodify(found, ":h")
  while true do
    local parent = vim.fn.fnamemodify(dir, ":h")
    if vim.fn.filereadable(parent .. "/pom.xml") == 1 then
      dir = parent
    else
      break
    end
  end
  return dir
end

---Resolves a root from Neovim's current working directory alone, with no
---buffer involved - so root is known the moment you `cd`/launch nvim into a
---Maven project, before ever opening a .java file. Safe to call repeatedly
---(e.g. on VimEnter and DirChanged): it's just directory-walking, no `mvn`.
local function resolve_root_from_cwd()
  local dir = walk_up_for_reactor_root(vim.fn.getcwd())
  if dir then
    last_root = dir
  end
  return dir
end

---@return string root - the workspace root for the current buffer, found by
---walking up for a pom.xml, falling back to the last resolved root (which
---may already be set from cwd - see resolve_root_from_cwd) when the current
---buffer isn't a real file inside a project.
local function find_root(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
  local is_own_panel = bufname:match("^java%-debug%-model://") ~= nil
  if bufname == "" or is_own_panel then
    return last_root or resolve_root_from_cwd() or vim.fn.getcwd()
  end

  local dir = walk_up_for_reactor_root(vim.fn.fnamemodify(bufname, ":h"))
  if dir then
    last_root = dir
    return dir
  end
  return last_root or vim.fn.getcwd()
end

local function manifest_path(root)
  return root .. "/.nvim/java-debug-model/manifest.json"
end

---@return {added: string[], excluded: string[]}
local function load_manifest(root)
  local path = manifest_path(root)
  if vim.fn.filereadable(path) == 0 then return { added = {}, excluded = {} } end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then return { added = {}, excluded = {} } end
  decoded.added = decoded.added or {}
  decoded.excluded = decoded.excluded or {}
  return decoded
end

local function save_manifest(root, manifest)
  local path = manifest_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(vim.json.encode(manifest), "\n"), path)
end

---@type table<string, table>  root -> current Project
local projects_by_root = {}

local function build_opts(root)
  local manifest = load_manifest(root)
  return {
    active_profiles = M.opts.active_profiles,
    manually_added = manifest.added,
    excluded = manifest.excluded,
  }
end

---Filters a resolved Project's modules against the manifest's `excluded`
---list (a module removed via :JavaModelRemoveModule must not silently
---come back on the next filesystem-scan-based reload).
local function apply_manifest_exclusions(root, project)
  local manifest = load_manifest(root)
  local excluded = {}
  for _, p in ipairs(manifest.excluded) do excluded[p] = true end
  if next(excluded) == nil then return project end
  local kept = {}
  for _, mod in ipairs(project.modules) do
    if not excluded[mod.path] then table.insert(kept, mod) end
  end
  project.modules = kept
  return project
end

---Gets (building if needed) the Project model for `root`, applying manifest
---exclusions.
---@param root string
---@param callback fun(project: table|nil)
---@param profiles string[]? resolve with these Maven profiles active instead
---of M.opts.active_profiles - pass a DebugConfig's own `maven_profiles` here
---to run/debug it with the profile combination it was saved with, resolved
---independently of the plugin-wide default project view (watcher.lua's
---single-project-per-root cache has no notion of "which profiles" it
---holds, so this bypasses it via watcher.get_scoped rather than risk
---silently returning a project resolved with a different profile set).
function M.get_project(root, callback, profiles)
  if profiles and #profiles > 0 then
    watcher.get_scoped(root, profiles, function(project)
      if project then project = apply_manifest_exclusions(root, project) end
      callback(project)
    end)
    return
  end
  watcher.get(root, build_opts(root), function(project)
    if project then
      project = apply_manifest_exclusions(root, project)
      projects_by_root[root] = project
    end
    callback(project)
  end)
end

---Registers the jdtls FileType hook. Called from setup(opts.auto_attach) or
---directly by the user's own ftplugin/java.lua.
---@param bufnr integer
function M.start_or_attach(bufnr)
  local root = find_root(bufnr)
  M.get_project(root, function(project)
    if not project then return end
    local ok_jdtls, jdtls = pcall(require, "jdtls")
    if not ok_jdtls then
      vim.notify("java-debug-model: nvim-jdtls not found", vim.log.levels.ERROR)
      return
    end
    local module = jdtls_bridge.root_dir_for_buffer(project, bufnr) or project.modules[1]
    local bundles = jdtls_bridge.collect_bundles(M.opts.jdtls_bundle_globs)
    jdtls.start_or_attach(vim.tbl_deep_extend("force", M.opts.jdtls_config or {}, {
      root_dir = module and module.path or root,
      init_options = { bundles = bundles },
    }))
  end)
end

---Forces a full re-resolve for `root`, ignoring cache. The manual "Reload
---Maven" equivalent. Refreshes any open UI panels afterward.
---@param root string
function M.reload(root)
  watcher.reload(root, build_opts(root), function(project)
    if not project then return end
    project = apply_manifest_exclusions(root, project)
    projects_by_root[root] = project
    pcall(project_tree.refresh, project)
    pcall(maven_panel.refresh, project)
    for _, mod in ipairs(project.modules) do
      jdtls_bridge.update_project_configuration(mod.path .. "/pom.xml")
    end
    vim.notify("java-debug-model: model reloaded (" .. #project.modules .. " modules)", vim.log.levels.INFO)
  end)
end

-- `print(vim.inspect(project))` on a real multi-module project can dump
-- thousands of lines (every classpath jar, every source root...) into
-- Neovim's message history, which triggers the blocking "-- More --" pager
-- and looks exactly like a frozen editor. A scratch buffer/split has no such
-- limit and stays interactive (search, fold, etc.).
local inspect_bufnr = nil

function M.inspect(root)
  local project = projects_by_root[root]
  if not project then
    vim.notify("java-debug-model: no model resolved yet for " .. root .. " (try :JavaModelReload first)",
      vim.log.levels.WARN)
    return
  end
  if not inspect_bufnr or not vim.api.nvim_buf_is_valid(inspect_bufnr) then
    inspect_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[inspect_bufnr].buftype = "nofile"
    vim.bo[inspect_bufnr].bufhidden = "hide"
    vim.bo[inspect_bufnr].filetype = "lua"
    vim.api.nvim_buf_set_name(inspect_bufnr, "java-debug-model://inspect")
  end
  local lines = vim.split(vim.inspect(project), "\n")
  vim.bo[inspect_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(inspect_bufnr, 0, -1, false, lines)
  vim.bo[inspect_bufnr].modifiable = false

  local winid = vim.fn.bufwinid(inspect_bufnr)
  if winid ~= -1 then
    vim.api.nvim_set_current_win(winid)
  else
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, inspect_bufnr)
  end
end

---Registers a module manually (independent pom outside the scanned tree, or
---simply not auto-discovered), persists it to the manifest, and imports it
---into the live jdtls workspace without a restart.
---@param root string
---@param module_path string
function M.add_module(root, module_path)
  module_path = vim.fn.fnamemodify(module_path, ":p"):gsub("/$", "")
  if vim.fn.filereadable(module_path .. "/pom.xml") == 0 then
    vim.notify("java-debug-model: no pom.xml found at " .. module_path, vim.log.levels.ERROR)
    return
  end
  local manifest = load_manifest(root)
  manifest.excluded = vim.tbl_filter(function(p) return p ~= module_path end, manifest.excluded)
  if not vim.tbl_contains(manifest.added, module_path) then
    table.insert(manifest.added, module_path)
  end
  save_manifest(root, manifest)

  jdtls_bridge.notify_workspace_folder_change(module_path, "added")
  M.reload(root)
end

---Unregisters a module from the model and jdtls workspace ONLY - this never
---touches files on disk. Adds it to the manifest's excluded list so the
---filesystem-scan discovery doesn't silently re-add it on the next reload.
---@param root string
---@param name string  module artifactId or ga to remove
function M.remove_module(root, name)
  local project = projects_by_root[root]
  if not project then
    vim.notify("java-debug-model: no model resolved yet for " .. root, vim.log.levels.WARN)
    return
  end
  local target = nil
  for _, mod in ipairs(project.modules) do
    if mod.artifact_id == name or mod:ga() == name then
      target = mod
      break
    end
  end
  if not target then
    vim.notify("java-debug-model: module not found: " .. name, vim.log.levels.ERROR)
    return
  end

  local manifest = load_manifest(root)
  manifest.added = vim.tbl_filter(function(p) return p ~= target.path end, manifest.added)
  if not vim.tbl_contains(manifest.excluded, target.path) then
    table.insert(manifest.excluded, target.path)
  end
  save_manifest(root, manifest)

  jdtls_bridge.notify_workspace_folder_change(target.path, "removed")

  -- Unregisters from the model/jdtls workspace ONLY; NEVER deletes files on disk.
  vim.notify(
    "java-debug-model: removed module '" .. name .. "' from the model/jdtls workspace. "
    .. "Files on disk are untouched. Open buffers from it may lose LSP features until re-added.",
    vim.log.levels.WARN)

  M.reload(root)
end

---Auto-creates a DebugConfig from the current buffer's detected main method.
---@param root string
function M.debug_config_from_file(root)
  M.get_project(root, function(project)
    if not project then return end
    local bufnr = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(bufnr)
    mainclass.find_main_classes(project, function(entries)
      for _, e in ipairs(entries) do
        if e.file == file then
          local cfg = config_store.default_from_main_class(e.module, e.main_class)
          config_store.add(root, cfg)
          vim.notify("java-debug-model: created debug config '" .. cfg.name .. "' from current file",
            vim.log.levels.INFO)
          return
        end
      end
      vim.notify("java-debug-model: no main method detected in the current file", vim.log.levels.WARN)
    end)
  end)
end

---Whole-project main-method scan -> picker -> generate configs for the
---selected main classes.
---@param root string
function M.debug_config_scan(root)
  M.get_project(root, function(project)
    if not project then return end
    mainclass.find_main_classes(project, function(entries)
      if #entries == 0 then
        vim.notify("java-debug-model: no main classes found in the project", vim.log.levels.WARN)
        return
      end
      vim.ui.select(entries, {
        prompt = "Create a debug config for:",
        format_item = function(e) return e.main_class end,
      }, function(choice)
        if not choice then return end
        local cfg = config_store.default_from_main_class(choice.module, choice.main_class)
        config_store.add(root, cfg)
        vim.notify("java-debug-model: created debug config '" .. cfg.name .. "'", vim.log.levels.INFO)
      end)
    end)
  end)
end

function M.debug_config_run(root, name)
  local cfg = config_store.get(root, name)
  if not cfg then
    vim.notify("java-debug-model: no debug config named '" .. name .. "'", vim.log.levels.ERROR)
    return
  end
  -- Resolve with THIS config's own maven_profiles, not the plugin-wide
  -- default - otherwise a config saved with e.g. profile "dev" would
  -- silently launch against whatever profile set setup() was given
  -- instead, defeating the point of the per-config field entirely.
  M.get_project(root, function(project)
    if not project then return end
    dap.launch(project, cfg, { open_j9_java_exec = M.opts.open_j9_java_exec })
  end, cfg.maven_profiles)
end

function M.debug_config_add(root)
  M.get_project(root, function(project)
    if project then config_form.open(root, project) end
  end)
end

function M.debug_config_edit(root, name)
  M.get_project(root, function(project)
    if not project then return end
    local existing = config_store.get(root, name)
    if not existing then
      vim.notify("java-debug-model: no debug config named '" .. name .. "'", vim.log.levels.ERROR)
      return
    end
    config_form.open(root, project, { existing = existing })
  end)
end

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  session.setup_listeners()

  -- Resolve root from cwd immediately - this is cheap directory-walking
  -- only (no `mvn`), so it's fine to run unconditionally even outside a
  -- Maven project. Means :Java* commands know the right project the moment
  -- Neovim opens in it, without requiring a .java buffer first.
  resolve_root_from_cwd()
  vim.api.nvim_create_autocmd("DirChanged", {
    callback = function() resolve_root_from_cwd() end,
  })

  if M.opts.auto_attach then
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "java",
      callback = function(args) M.start_or_attach(args.buf) end,
    })
  end
end

M._find_root = find_root
M.project_tree = project_tree
M.maven_panel = maven_panel
M.session_picker = session_picker
M.test_results = test_results
M.maven_runner = maven_runner
M.test = test
M.config_store = config_store

return M
