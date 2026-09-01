-- Top-level API: setup(opts) and everything the plugin/ commands call into.
-- Wires model + resolver + watcher + jdtls + dap + maven + ui together.
local watcher = require("java-debug-model.watcher")
local jdtls_bridge = require("java-debug-model.jdtls")
local jdtls_launcher = require("java-debug-model.jdtls_launcher")
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
local dependency_tree_ui = require("java-debug-model.ui.dependency_tree")
local session_manager_ui = require("java-debug-model.ui.session_manager")

local M = {}

-- Prebuilt, already-patched jdtls 1.54.0 (2 real jdt.ls bugs fixed - stale "directories" field
-- across multiple scanned root paths, and a null parent pom for a module scanned in isolation
-- with an empty <relativePath/> - see eclipse.jdt.ls-build's local-patches branch commit log for
-- the full writeup) built via the project's own full Tycho product build and published as a
-- GitHub Release asset on THIS repo. Baked in as the DEFAULT here (not left for every caller to
-- fill in via opts, as an earlier version of this file did) so "install java-debug-model, call
-- setup()" is the whole Java setup story end to end - no separate step to go find/build/host a
-- working jdtls distribution. Override via opts.jdtls_prebuilt_url (a different release) or set
-- to `false` to skip entirely and fall through to jdtls_launcher.lua's Mason fallback instead.
local DEFAULT_JDTLS_PREBUILT_URL =
  "https://github.com/nguyen-tan-huy/eclipse.jdt.ls/releases/download/1.54.0/jdt-language-server-1.54.0-202609010342.tar.gz"

M.opts = {
  auto_attach = false,
  active_profiles = {},
  open_j9_java_exec = nil,
  jdtls_bundle_globs = {},
  -- Extra fields merged (force) on top of jdtls_launcher.build_config()'s own
  -- config - for overriding/adding to cmd/settings/capabilities/etc. without
  -- forking jdtls_launcher.lua itself.
  jdtls_config = nil,
  -- Path to JavaHello/spring-boot.nvim's language-server dir (application.yml/
  -- properties completion) - nil = auto-detect the nvim-java cache path this
  -- config was originally ported from (see bootstrap.lua). Set to false to
  -- skip spring-boot.nvim wiring entirely.
  spring_boot_ls_path = nil,
  -- URL of a prebuilt, already-patched jdtls .tar.gz GitHub Release asset (see
  -- DEFAULT_JDTLS_PREBUILT_URL above + bootstrap.lua's ensure_jdtls_prebuilt).
  -- nil (default) uses DEFAULT_JDTLS_PREBUILT_URL; pass a different URL to
  -- pull a different release, or `false` to skip this entirely and fall
  -- straight through to jdtls_launcher.lua's Mason fallback (a DIFFERENT,
  -- unpatched jdtls version) instead.
  jdtls_prebuilt_url = nil,
  -- Where to extract that release asset into - defaults to the exact path
  -- jdtls_launcher.lua's build_config looks up FIRST (see its own jdtls_path
  -- comment), so this needs no other wiring once set.
  jdtls_prebuilt_dest = nil,
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
  -- Buffer KHÔNG phải file thật trên đĩa - vd source jar jdt.ls tự decompile (URI dạng
  -- "jdt://contents/foo.jar/...=/maven.pomderived=/true=/..." - jdt.ls dùng "=/" làm separator
  -- riêng, tạo ra chuỗi có HÀNG CHỤC dấu "/" giả, không phải path thật). Đưa thẳng chuỗi này vào
  -- walk_up_for_reactor_root() (vim.fs.find upward=true) khiến nó đi ngược "từng cấp thư mục" của
  -- chuỗi dị dạng đó - đã xác nhận qua log (~/tmp/jdm_debug.log): đây chính là nguyên nhân Neovim
  -- đơ 1-2 phút mỗi lần debug nhảy vào code thư viện (breakpoint dừng, dap tự mở source jar cho
  -- frame đó). Bất kỳ scheme URI nào ("xxx://...") đều coi như KHÔNG phải file thật, dùng last_root.
  local is_uri_scheme = bufname:match("^%a[%w+.-]*://") ~= nil
  if bufname == "" or is_own_panel or is_uri_scheme then
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

---Ensures jdtls's live workspace folders include every module the resolved
---Project knows about (reactor-declared AND independent/"orphan" poms found
---by maven.lua's own recursive filesystem scan) - the Project model is
---already the single source of truth for "what modules make up this
---project", so there's no need for a separate hand-rolled scan (e.g. a
---regex over the root pom.xml's own <modules> plus a ONE-level-deep
---directory listing) to decide what jdtls should import; this is a strict
---superset (recursive, and covers modules NOT even a direct child of root).
---Called automatically every time the model is fetched below, so it stays
---in sync as new modules are discovered without any separate hook.
---@param project table
local function sync_jdtls_workspace(project)
  local ok, added = pcall(jdtls_bridge.sync_workspace_folders, project)
  if ok and added and #added > 0 then
    local names = vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ":t") end, added)
    vim.notify("java-debug-model: imported into jdtls workspace: " .. table.concat(names, ", "),
      vim.log.levels.INFO)
  end
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
      if project then
        project = apply_manifest_exclusions(root, project)
        sync_jdtls_workspace(project)
      end
      callback(project)
    end, build_opts(root))
    return
  end
  watcher.get(root, build_opts(root), function(project)
    if project then
      project = apply_manifest_exclusions(root, project)
      projects_by_root[root] = project
      sync_jdtls_workspace(project)
    end
    callback(project)
  end)
end

---Closes then reopens every currently-open "IDE layout" panel (Project Tree, Maven Lifecycle,
---Session Manager) in a FIXED order (tree first, then session manager, then maven panel) so
---their window geometry comes out the same every time, regardless of what order they happened to
---be opened in originally. Neovim's plain window-split model has no notion of "docking zones"
---like IntelliJ's tool windows do - `topleft`/`botright` splits each just carve out a slice of
---the WHOLE tab, so opening/closing several of these independently-positioned panels in different
---orders can squash one into a sliver (confirmed for real: reopening Project Tree while Session
---Manager's bottom band was already open left Session Manager's own list column squeezed down to
---~10 characters wide). This is the "fix the layout" escape hatch for when that happens - a
---from-scratch relayout is simpler and more robust than trying to detect/correct a squashed
---window after the fact.
---
---Doesn't touch Dependency Tree: that panel is a "look something up right now" tool by design
---(see its own doc comment - always re-runs `mvn dependency:tree` fresh on open, no cache), not
---part of the persistent IDE-like layout the other three panels form together.
---@param root string
function M.reset_layout(root)
  local was_tree_open = project_tree.is_open()
  local was_maven_open = maven_panel.is_open()
  local was_session_open = session_manager_ui.is_open()

  project_tree.close()
  maven_panel.close()
  session_manager_ui.close()

  if not (was_tree_open or was_maven_open or was_session_open) then
    vim.notify("java-debug-model: không có panel nào đang mở để sắp xếp lại.", vim.log.levels.INFO)
    return
  end

  local function reopen_session_then_maven(project)
    if was_session_open then session_manager_ui.open() end
    if was_maven_open and project then maven_panel.open(root, project) end
  end

  if was_tree_open or was_maven_open then
    M.get_project(root, function(project)
      if project and was_tree_open then project_tree.open(root, project) end
      reopen_session_then_maven(project)
    end)
  else
    reopen_session_then_maven(nil)
  end
end

---Starts/attaches jdtls for `bufnr` - the WHOLE launch (Mason paths, ASM
---version pinning, bundles, workspace_dir naming, editor keymaps) lives in
---jdtls_launcher.lua now; this just wires it to this plugin's own opts.
---Called from setup(opts.auto_attach) or directly by the user.
---@param bufnr integer
function M.start_or_attach(bufnr)
  jdtls_launcher.start_or_attach(bufnr, {
    jdtls_config = M.opts.jdtls_config,
    jdtls_bundle_globs = M.opts.jdtls_bundle_globs,
  })
end

---Forces a full re-resolve for `root`, ignoring cache. The manual "Reload
---Maven" equivalent. Refreshes any open UI panels afterward.
---@param root string
function M.reload(root)
  watcher.reload(root, build_opts(root), function(project)
    if not project then return end
    project = apply_manifest_exclusions(root, project)
    projects_by_root[root] = project
    sync_jdtls_workspace(project)
    pcall(project_tree.refresh, project)
    pcall(maven_panel.refresh, project)
    local pom_paths = vim.tbl_map(function(mod) return mod.path .. "/pom.xml" end, project.modules)
    jdtls_bridge.update_projects_configuration(pom_paths)
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
    local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
    -- Module lookup here goes through find_module_for_file (source-root
    -- prefix match on the buffer's OWN real path) rather than trusting
    -- mainclass.lua's entry.module - so this still finds the right module
    -- even if that projectName->artifactId attribution ever mismatches.
    local module = project:find_module_for_file(file)

    -- jdtls's own resolve_classname() (package regex + filename, NOT a
    -- "detect main method" scan - it just names the class this file
    -- declares) gives a match that's independent of mainclass.lua's
    -- reconstructed file path ever lining up byte-for-byte with the
    -- buffer's real name (symlinks, relative vs absolute, etc.) - prefer it
    -- whenever available, falling back to the file-path match otherwise.
    local ok_util, jdtls_util = pcall(require, "jdtls.util")
    local current_class = nil
    if ok_util then
      local ok_call, result = pcall(jdtls_util.resolve_classname)
      if ok_call then current_class = result end
    end

    mainclass.find_main_classes(project, function(entries)
      for _, e in ipairs(entries) do
        local matches_class = current_class and e.main_class == current_class
        local matches_file = e.file and vim.fn.fnamemodify(e.file, ":p") == file
        if matches_class or matches_file then
          local cfg = config_store.default_from_main_class(e.module or module, e.main_class)
          config_store.add(root, cfg)
          vim.notify("java-debug-model: created debug config '" .. cfg.name .. "' from current file",
            vim.log.levels.INFO)
          return
        end
      end
      vim.notify(
        string.format(
          "java-debug-model: no main method detected in the current file (jdtls reported %d main class(es) project-wide)",
          #entries),
        vim.log.levels.WARN)
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

---Opens the Dependency Tree panel (`mvn dependency:tree -Dverbose`, with version-conflict lines
---highlighted) for a module the user picks - the "why is the wrong version of this jar on my
---classpath" debugging tool, same idea as IntelliJ's Dependency Tree/Diagram view. Uses
---M.opts.active_profiles (same profile set the rest of the plugin resolves against), NOT a
---per-config profile list - there's no DebugConfig involved here, just "this module, current
---profiles".
---@param root string
function M.dependency_tree(root)
  M.get_project(root, function(project)
    if not project then return end
    vim.ui.select(project.modules, {
      prompt = "Module: xem dependency tree",
      format_item = function(m) return m:ga() end,
    }, function(mod)
      if not mod then return end
      dependency_tree_ui.open(mod, { profiles = M.opts.active_profiles })
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

  -- Cài Mason packages (jdtls/java-debug-adapter/java-test) + wire spring-boot.nvim nếu có -
  -- gộp vào đây để "cấu hình java-debug-model" một chỗ là đủ chạy hết tính năng Java, không
  -- cần người dùng tự lặp lại phần này ở plugins/lsp.lua hay tự viết config spring-boot.nvim
  -- riêng (xem bootstrap.lua).
  local bootstrap = require("java-debug-model.bootstrap")
  -- Chạy TRƯỚC ensure_mason_packages: nếu tải/giải nén thành công, dest đã có sẵn trước khi
  -- jdtls_launcher.lua's build_config tìm tới nó, nên không bao giờ rơi vào nhánh fallback
  -- Mason. jdtls_prebuilt_url = nil (mặc định) dùng DEFAULT_JDTLS_PREBUILT_URL; = false thì
  -- bỏ qua hẳn bước này (hàm no-op ngay dòng đầu).
  if M.opts.jdtls_prebuilt_url ~= false then
    bootstrap.ensure_jdtls_prebuilt({
      url = M.opts.jdtls_prebuilt_url or DEFAULT_JDTLS_PREBUILT_URL,
      dest = M.opts.jdtls_prebuilt_dest,
    })
  end
  bootstrap.ensure_mason_packages()
  if M.opts.spring_boot_ls_path ~= false then
    bootstrap.setup_spring_boot({ ls_path = M.opts.spring_boot_ls_path })
  end

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

---Resolves the workspace/reactor root for `bufnr` (walks up for the
---outermost ancestor with a pom.xml - see find_root above), falling back to
---the last resolved root when the buffer isn't a real file in a project.
---Public so callers outside this plugin (e.g. the user's own
---ftplugin/java.lua) can point jdtls's own root_dir at the SAME root this
---plugin resolves the Project model against, instead of running a second,
---independently-behaving marker search (mvnw/gradlew/.git) that can
---disagree with it in edge cases.
---@param bufnr integer?
---@return string
M.find_root = find_root
M._find_root = find_root -- kept for plugin/java-debug-model.lua's internal use
M.project_tree = project_tree
M.maven_panel = maven_panel
M.session_picker = session_picker
M.test_results = test_results
M.maven_runner = maven_runner
M.test = test
M.config_store = config_store
M.dependency_tree_ui = dependency_tree_ui
M.session_manager_ui = session_manager_ui

---Short "⏳ ..." string while a Maven resolve, a Maven Lifecycle run, or a
---debug launch is in flight, empty otherwise - wire into a statusline
---component (e.g. lualine_x) to see what's running instead of Neovim
---appearing frozen during a slow `mvn` call.
---@return string
function M.statusline()
  return require("java-debug-model.status").text()
end

return M
