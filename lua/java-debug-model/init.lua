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

---@return string root - the workspace root for the current buffer, found by
---walking up for a pom.xml, falling back to cwd.
local function find_root(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
  local start = bufname ~= "" and vim.fn.fnamemodify(bufname, ":h") or vim.fn.getcwd()
  local found = vim.fs.find("pom.xml", { path = start, upward = true })[1]
  if found then
    -- walk further up while a parent pom.xml exists (find the reactor root)
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
  return vim.fn.getcwd()
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
function M.get_project(root, callback)
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

function M.inspect(root)
  local project = projects_by_root[root]
  if not project then
    vim.notify("java-debug-model: no model resolved yet for " .. root, vim.log.levels.WARN)
    return
  end
  print(vim.inspect(project))
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
  M.get_project(root, function(project)
    if not project then return end
    local cfg = config_store.get(root, name)
    if not cfg then
      vim.notify("java-debug-model: no debug config named '" .. name .. "'", vim.log.levels.ERROR)
      return
    end
    dap.launch(project, cfg, { open_j9_java_exec = M.opts.open_j9_java_exec })
  end)
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
