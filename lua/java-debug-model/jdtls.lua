-- Feeds the Project model into nvim-jdtls: root_dir, workspace folders,
-- classpath/sourcepath resolution, and bundle wiring (java-debug + java-test).
local M = {}

---Finds the nearest module (by content_root, longest match) that owns
---`bufnr`'s file, used to pick jdtls's root_dir instead of jdtls's own
---marker-file guess (root_pattern), which doesn't know about the real
---module graph.
---@param project table Project
---@param bufnr integer
---@return table|nil Module
function M.root_dir_for_buffer(project, bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return nil end
  path = vim.fn.fnamemodify(path, ":p")
  return project:find_module_for_file(path)
end

---Builds the java-debug + java-test bundle jar list from paths the user's
---mason install already provides. Callers pass explicit search globs since
---mason install locations vary by machine; this module doesn't guess them.
---@param glob_patterns string[]  e.g. { "<mason>/java-debug-adapter/**/com.microsoft.java.debug.plugin-*.jar" }
---@return string[]
function M.collect_bundles(glob_patterns)
  local bundles = {}
  for _, pattern in ipairs(glob_patterns) do
    for _, jar in ipairs(vim.split(vim.fn.glob(pattern, false, false), "\n")) do
      if jar ~= "" then table.insert(bundles, jar) end
    end
  end
  return bundles
end

---Resolves the full compile/runtime classpath for `module`, recursively:
---sibling-module dependencies resolve to that sibling's live output
---directory (target/classes) instead of a possibly-stale .m2 jar, so
---cross-module debug reflects live source edits with no manual `mvn
---install`, as long as the sibling is loaded in the same jdtls workspace.
---@param project table Project
---@param module table Module
---@param opts table?  { include_test?: boolean, _seen?: table }
---@return string[] absolute paths (jars and/or output dirs)
function M.resolve_classpath(project, module, opts)
  opts = opts or {}
  local seen = opts._seen or {}
  if seen[module.path] then return {} end
  seen[module.path] = true

  local paths = {}
  table.insert(paths, module.path .. "/target/classes")
  if opts.include_test then
    table.insert(paths, module.path .. "/target/test-classes")
  end

  -- Sibling modules resolve to their LIVE output (never a jar, even if
  -- Maven also resolved a .m2 one for the same coordinates) - recurse so
  -- a sibling's own transitive classpath (including further siblings)
  -- comes along too, and remember its artifactId to exclude the matching
  -- .m2 jar below.
  local exclude_artifact_ids = {}
  for _, dep in ipairs(module.dependencies) do
    if dep.is_sibling and dep.sibling_module_path then
      local sibling = project:find_module_by_path(dep.sibling_module_path)
      if sibling then
        exclude_artifact_ids[sibling.artifact_id] = true
        vim.list_extend(paths, M.resolve_classpath(project, sibling, { include_test = false, _seen = seen }))
      end
    end
  end

  -- Everything else comes from Maven's OWN fully-resolved classpath
  -- (module._classpath_jars, resolved with -DincludeScope=runtime by
  -- resolver/maven.lua's _resolve_classpaths - i.e. already test-scope-free,
  -- transitives included), never reconstructed from this module's own
  -- directly-declared <dependency> entries. A transitive dependency (pulled
  -- in by another dependency, not declared directly here) would never
  -- appear in module.dependencies - reconstructing from it silently drops
  -- such jars from the launch classpath, which is exactly what produces a
  -- NoClassDefFoundError at runtime for a class that's genuinely on the
  -- real Maven classpath. (opts.include_test has no extra jars to add here
  -- since it's currently only used to add target/test-classes above - no
  -- caller resolves a test-inclusive external classpath today.)
  for _, jar in ipairs(module._classpath_jars or {}) do
    local artifact = jar:match("([^/\\]+)/[^/\\]+/[^/\\]+%.jar$")
    if not (artifact and exclude_artifact_ids[artifact]) then
      table.insert(paths, jar)
    end
  end

  -- A dependency shared between this module and a sibling (or between
  -- multiple siblings) legitimately shows up in more than one of the
  -- _classpath_jars lists merged above - dedupe rather than hand the
  -- debug adapter a classpath with repeated entries.
  local deduped, seen_path = {}, {}
  for _, p in ipairs(paths) do
    if not seen_path[p] then
      seen_path[p] = true
      table.insert(deduped, p)
    end
  end
  return deduped
end

---Resolves source roots the same way: sibling modules contribute their real
---source directories so stepping into a dependency module's code during
---debug resolves to its actual file, not a decompiled jar.
---@param project table Project
---@param module table Module
---@param opts table?  { include_test?: boolean, _seen?: table }
---@return string[]
function M.resolve_sourcepaths(project, module, opts)
  opts = opts or {}
  local seen = opts._seen or {}
  if seen[module.path] then return {} end
  seen[module.path] = true

  local paths = {}
  for _, sr in ipairs(module.source_roots) do
    if sr.kind == "main" or opts.include_test then
      table.insert(paths, sr.path)
    end
  end

  for _, dep in ipairs(module.dependencies) do
    if dep.is_sibling and dep.sibling_module_path then
      local sibling = project:find_module_by_path(dep.sibling_module_path)
      if sibling then
        vim.list_extend(paths, M.resolve_sourcepaths(project, sibling, { include_test = false, _seen = seen }))
      end
    end
  end

  return paths
end

---Sends workspace/didChangeWorkspaceFolders to every attached jdtls client so
---a module discovered outside the originally-scanned root (or manually added
---via :JavaModelAddModule) gets imported without restarting jdtls.
---@param module_path string
---@param action "added"|"removed"
function M.notify_workspace_folder_change(module_path, action)
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then return end
  local uri = vim.uri_from_fname(module_path)
  local name = vim.fn.fnamemodify(module_path, ":t")
  for _, client in ipairs(clients) do
    if action == "added" then
      client:notify("workspace/didChangeWorkspaceFolders", {
        event = { added = { { uri = uri, name = name } }, removed = {} },
      })
    else
      client:notify("workspace/didChangeWorkspaceFolders", {
        event = { added = {}, removed = { { uri = uri, name = name } } },
      })
    end
  end
end

---Triggers jdtls's incremental "reload maven project" for a single pom.xml
---change: java.projectConfiguration.update, NOT a jdtls restart - the JVM
---stays alive, only the affected project's import is refreshed.
---@param pom_path string absolute path to the changed pom.xml
function M.update_project_configuration(pom_path)
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    vim.notify("java-debug-model: no jdtls client attached, cannot update project configuration", vim.log.levels.WARN)
    return
  end
  local uri = vim.uri_from_fname(pom_path)
  for _, client in ipairs(clients) do
    client:exec_cmd({
      command = "java.projectConfiguration.update",
      arguments = { { uri = uri } },
    }, { bufnr = 0 })
  end
end

return M
