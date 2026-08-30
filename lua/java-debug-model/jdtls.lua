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

---Resolves the full compile/runtime classpath for `module`.
---
---Source of truth is module._classpath_jars alone - Maven's own,
---already-mediated classpath for THIS module (resolved with
----DincludeScope=runtime by resolver/maven.lua), which already accounts
---for every sibling module's own transitive dependencies correctly,
---exactly the way a real `mvn install` + normal run would: when
---computing-manager depends on sibling computing-connector, Maven resolves
---computing-connector as a regular dependency and pulls its OWN
---transitive graph in already, mediated against computing-manager's own
---constraints into ONE single version per artifact.
---
---What must NOT happen is separately resolving each sibling's own
---classpath in isolation and unioning the results together: two sibling
---modules can each independently (and each correctly, in isolation)
---mediate a shared transitive library to a DIFFERENT version - merging
---both raw results back in then puts two conflicting versions of the same
---library on one classpath at once (observed for real: computing-manager
---mediates cashbook-core to 1.0.0, its sibling computing-connector
---mediates the same artifact to 3.5.4 - unioning both, as an earlier
---version of this function did, put both jars on the classpath together,
---causing Spring's component scan to find two same-named-but-different
---beans and fail with ConflictingBeanDefinitionException). Substituting
---jar-for-jar within module's own single resolved list avoids this
---entirely, and still gets cross-module debug for free: any jar in that
---list that happens to BE one of this project's own modules (found by
---artifactId, at whatever transitive depth) is swapped for that module's
---live output directory instead of the possibly-stale .m2 jar - no manual
---`mvn install` needed as long as that module is loaded in the same jdtls
---workspace.
---@param project table Project
---@param module table Module
---@param opts table?  { include_test?: boolean }
---@return string[] absolute paths (jars and/or output dirs)
function M.resolve_classpath(project, module, opts)
  opts = opts or {}
  local paths = { module.path .. "/target/classes" }
  if opts.include_test then
    table.insert(paths, module.path .. "/target/test-classes")
  end

  for _, jar in ipairs(module._classpath_jars or {}) do
    local artifact = jar:match("([^/\\]+)/[^/\\]+/[^/\\]+%.jar$")
    local sibling_module = artifact and project:find_module_by_artifact_id(artifact)
    if sibling_module and sibling_module.path ~= module.path then
      table.insert(paths, sibling_module.path .. "/target/classes")
    else
      table.insert(paths, jar)
    end
  end

  -- Two different sibling substitutions (or a jar Maven's own resolution
  -- happened to list twice) can still coincide - dedupe defensively.
  local deduped, seen_path = {}, {}
  for _, p in ipairs(paths) do
    if not seen_path[p] then
      seen_path[p] = true
      table.insert(deduped, p)
    end
  end
  return deduped
end

---Resolves source roots the same way resolve_classpath does: any jar on
---module's own flat classpath that turns out to be one of this project's
---own modules (by artifactId) contributes that module's real main source
---directory, so stepping into a dependency module's code during debug
---resolves to its actual file, not a decompiled jar. Scanning the flat,
---already-transitively-complete classpath (rather than recursing through
---module.dependencies) means a sibling that's only a TRANSITIVE dependency
---(never declared directly on `module`) still gets its source path added.
---@param project table Project
---@param module table Module
---@param opts table?  { include_test?: boolean }
---@return string[]
function M.resolve_sourcepaths(project, module, opts)
  opts = opts or {}
  local paths = {}
  for _, sr in ipairs(module.source_roots) do
    if sr.kind == "main" or opts.include_test then
      table.insert(paths, sr.path)
    end
  end

  local seen_module = { [module.path] = true }
  for _, jar in ipairs(module._classpath_jars or {}) do
    local artifact = jar:match("([^/\\]+)/[^/\\]+/[^/\\]+%.jar$")
    local sibling_module = artifact and project:find_module_by_artifact_id(artifact)
    if sibling_module and not seen_module[sibling_module.path] then
      seen_module[sibling_module.path] = true
      for _, sr in ipairs(sibling_module:main_source_roots()) do
        table.insert(paths, sr.path)
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
