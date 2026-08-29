-- Builds a Project model by shelling out to Maven itself and parsing its
-- output. Never hand-parse pom.xml for dependency/classpath info: property
-- interpolation, parent inheritance, profiles and transitive deps will break
-- any hand-rolled parser.
local model = require("java-debug-model.model")

local M = {}

---@type table<string, {project: table, at: integer}>
local cache = {}

local function cache_key(module_path, profiles)
  local sorted = vim.deepcopy(profiles or {})
  table.sort(sorted)
  return module_path .. "|" .. table.concat(sorted, ",")
end

---Finds the mvn executable to use: prefer ./mvnw at root, else "mvn" on PATH.
---@param root string
---@return string[]|nil cmd_prefix, string|nil error
function M._mvn_cmd(root)
  local wrapper = root .. "/mvnw"
  if vim.fn.executable(wrapper) == 1 then
    return { wrapper }
  end
  if vim.fn.executable("mvn") == 1 then
    return { "mvn" }
  end
  return nil, "Neither ./mvnw nor mvn found in PATH. Install Maven or add a wrapper."
end

---Runs `mvn` asynchronously via vim.system. Never blocks the UI thread.
---@param root string
---@param args string[]
---@param opts table  { offline?: boolean, profiles?: string[] }
---@param callback fun(ok: boolean, stdout: string, stderr: string)
function M._run_maven(root, args, opts, callback)
  opts = opts or {}
  local cmd, err = M._mvn_cmd(root)
  if not cmd then
    vim.schedule(function() callback(false, "", err) end)
    return
  end
  cmd = vim.deepcopy(cmd)
  vim.list_extend(cmd, args)
  if opts.profiles and #opts.profiles > 0 then
    table.insert(cmd, "-P" .. table.concat(opts.profiles, ","))
  end
  if opts.offline then
    table.insert(cmd, "-o")
  end
  table.insert(cmd, "-B") -- batch mode: no interactive prompts, cleaner output

  vim.system(cmd, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      callback(result.code == 0, result.stdout or "", result.stderr or "")
    end)
  end)
end

local function xml_unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&apos;", "'"))
end

---Extracts the text content of the first top-level (non-nested) occurrence of
---`tag` inside `xml`, scanning only at the given nesting depth markers passed
---via `stop_tags` to avoid descending into <dependencies>/<parent>/etc.
---This is a small, purpose-built extractor, not a general XML parser -
---effective-pom output is well-formed and predictable enough for this.
local function extract_tag(xml, tag)
  local pattern = "<" .. tag .. ">(.-)</" .. tag .. ">"
  local val = xml:match(pattern)
  return val and xml_unescape(vim.trim(val)) or nil
end

---Extracts every top-level <project>...</project> block from an
---effective-pom XML document (there is one per module when run at the
---aggregator root, or a single one when run inside a leaf module).
local function split_projects(xml)
  local projects = {}
  local pos = 1
  while true do
    local s = xml:find("<project[ >]", pos)
    if not s then break end
    -- find matching </project> by counting nested <project ...> occurrences
    local depth = 1
    local cursor = xml:find(">", s) + 1
    while depth > 0 do
      local open_s, open_e = xml:find("<project[ >]", cursor)
      local close_s, close_e = xml:find("</project>", cursor)
      if not close_s then break end
      if open_s and open_s < close_s then
        depth = depth + 1
        cursor = open_e + 1
      else
        depth = depth - 1
        cursor = close_e + 1
        if depth == 0 then
          table.insert(projects, xml:sub(s, close_e))
          pos = close_e + 1
        end
      end
    end
    if depth > 0 then break end
  end
  if #projects == 0 and xml:match("<project[ >]") then
    -- single-project document without nested modules
    table.insert(projects, xml)
  end
  return projects
end

---Pulls a top-level (not inside <dependencies>/<parent>/<build>) child tag
---value directly beneath <project>, by stripping known nested blocks first.
local function top_level_tag(project_xml, tag)
  local stripped = project_xml
  for _, nested in ipairs({ "parent", "dependencies", "build", "profiles", "properties", "dependencyManagement" }) do
    stripped = stripped:gsub("<" .. nested .. ">.-</" .. nested .. ">", "")
  end
  return extract_tag(stripped, tag)
end

---@param xml_str string   effective-pom XML for ONE <project> block
---@return table   { group_id, artifact_id, version, packaging, source_dir, test_source_dir, modules }
function M._parse_effective_pom_single(xml_str)
  local group_id = top_level_tag(xml_str, "groupId")
  if not group_id then
    -- inherited from <parent>, still resolved in effective-pom's build block usually,
    -- fall back to parent's groupId
    local parent = xml_str:match("<parent>(.-)</parent>")
    group_id = parent and extract_tag(parent, "groupId")
  end
  local artifact_id = top_level_tag(xml_str, "artifactId")
  local version = top_level_tag(xml_str, "version")
  if not version then
    local parent = xml_str:match("<parent>(.-)</parent>")
    version = parent and extract_tag(parent, "version")
  end
  local packaging = top_level_tag(xml_str, "packaging") or "jar"

  local build_block = xml_str:match("<build>(.-)</build>")
  local source_dir = build_block and extract_tag(build_block, "sourceDirectory") or nil
  local test_source_dir = build_block and extract_tag(build_block, "testSourceDirectory") or nil

  local modules = {}
  local modules_block = xml_str:match("<modules>(.-)</modules>")
  if modules_block then
    for m in modules_block:gmatch("<module>%s*(.-)%s*</module>") do
      table.insert(modules, m)
    end
  end

  local dependencies = {}
  local deps_block = xml_str:match("<dependencies>(.-)</dependencies>")
  if deps_block then
    for dep_xml in deps_block:gmatch("<dependency>(.-)</dependency>") do
      table.insert(dependencies, {
        group_id = extract_tag(dep_xml, "groupId"),
        artifact_id = extract_tag(dep_xml, "artifactId"),
        version = extract_tag(dep_xml, "version"),
        scope = extract_tag(dep_xml, "scope") or "compile",
      })
    end
  end

  return {
    group_id = group_id,
    artifact_id = artifact_id,
    version = version,
    packaging = packaging,
    source_dir = source_dir,
    test_source_dir = test_source_dir,
    modules = modules,
    dependencies = dependencies,
  }
end

---Parses possibly-multiple concatenated <project> blocks (mvn help:effective-pom
---prints one per reactor module when run at an aggregator root).
---@param xml_str string
---@return table[] one entry per <project> block, shape as _parse_effective_pom_single
function M._parse_effective_pom(xml_str)
  local out = {}
  for _, block in ipairs(split_projects(xml_str)) do
    table.insert(out, M._parse_effective_pom_single(block))
  end
  return out
end

---Parses `mvn dependency:build-classpath` output into ordered jar paths.
---@param txt string
---@return string[]
function M._parse_classpath(txt)
  local line = vim.trim(txt)
  -- the file may have interleaved plugin log lines if -q wasn't fully quiet;
  -- pick the longest line containing a path separator as the actual classpath.
  local sep = package.config:sub(1, 1) == "\\" and ";" or ":"
  local best = line
  for candidate in txt:gmatch("[^\r\n]+") do
    if candidate:find(sep, 1, true) and #candidate > #best then
      best = candidate
    end
  end
  if best == "" then return {} end
  return vim.split(best, sep, { plain = true, trimempty = true })
end

---Turns a jar path from the classpath into a Library, guessing coordinates
---from the .m2 repository layout: .../<group/path>/<artifact>/<version>/<artifact>-<version>.jar
---@param jar_path string
---@return Library
local function library_from_jar_path(jar_path)
  local artifact, version = jar_path:match("([^/\\]+)/([^/\\]+)/[^/\\]+%.jar$")
  local sources_jar = jar_path:gsub("%.jar$", "-sources.jar")
  return {
    group_id = "",
    artifact_id = artifact or vim.fn.fnamemodify(jar_path, ":t:r"),
    version = version or "",
    jar_path = jar_path,
    sources_jar_path = vim.fn.filereadable(sources_jar) == 1 and sources_jar or nil,
  }
end

---Recursively scans `dir` for pom.xml files, skipping target/ and .git/,
---returning absolute directories that contain a pom.xml.
---@param dir string
---@return string[]
function M._scan_for_poms(dir)
  local found = {}
  local function walk(d)
    if vim.fn.filereadable(d .. "/pom.xml") == 1 then
      table.insert(found, (vim.fn.fnamemodify(d, ":p"):gsub("/$", "")))
    end
    local handle = vim.loop.fs_scandir(d)
    if not handle then return end
    while true do
      local name, ftype = vim.loop.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" and name ~= "target" and name ~= ".git" and name ~= "node_modules" then
        walk(d .. "/" .. name)
      end
    end
  end
  walk(dir)
  return found
end

---Builds a Project for the module tree rooted at `root`, combining
---aggregator <modules> discovery with a filesystem scan (for independent,
---non-reactor poms), merged and deduped by resolved absolute path.
---@param root string
---@param opts table   { active_profiles?: string[], offline?: boolean, on_progress?: fun(msg:string) }
---@param callback fun(ok: boolean, project: table|nil, err: string|nil)
function M.build(root, opts, callback)
  opts = opts or {}
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local key = cache_key(root, opts.active_profiles)
  if not opts.force and cache[key] then
    vim.schedule(function() callback(true, cache[key].project) end)
    return
  end

  if opts.on_progress then opts.on_progress("java-debug-model: resolving Maven project (mvn)...") end

  local all_pom_dirs = M._scan_for_poms(root)
  -- effective-pom at the (aggregator) root gives us all reactor modules in one shot
  M._run_maven(root, { "help:effective-pom" }, { profiles = opts.active_profiles, offline = opts.offline },
    function(ok, stdout, stderr)
      if not ok then
        callback(false, nil, "mvn help:effective-pom failed: " .. stderr)
        return
      end
      local parsed_list = M._parse_effective_pom(stdout)

      local project = model.Project.new(root)
      local reactor_by_path = {}
      local true_reactor_path = {}

      for _, parsed in ipairs(parsed_list) do
        if parsed.packaging ~= "pom" and parsed.group_id and parsed.artifact_id then
          -- effective-pom doesn't print each module's own directory; match by
          -- artifactId against the filesystem scan (unique enough in practice,
          -- and the scan already gives us the real directory to resolve
          -- source roots against).
          local match_dir = nil
          for _, dir in ipairs(all_pom_dirs) do
            if vim.fn.fnamemodify(dir, ":t") == parsed.artifact_id then
              match_dir = dir
              break
            end
          end
          match_dir = match_dir or root
          reactor_by_path[match_dir] = parsed
          true_reactor_path[match_dir] = true
        end
      end

      -- Independent poms found by filesystem scan but not part of the
      -- aggregator's effective-pom output need their own resolve.
      local independent_dirs = {}
      for _, dir in ipairs(all_pom_dirs) do
        if not reactor_by_path[dir] then
          table.insert(independent_dirs, dir)
        end
      end

      local pending = #independent_dirs
      local function finalize()
        for dir, parsed in pairs(reactor_by_path) do
          project:add_module(M._build_module(dir, parsed, opts.active_profiles or {}, true_reactor_path[dir] == true))
        end
        M._resolve_classpaths(project, all_pom_dirs, opts, function()
          M._mark_sibling_dependencies(project)
          cache[key] = { project = project, at = vim.loop.now() }
          callback(true, project)
        end)
      end

      if pending == 0 then
        finalize()
        return
      end

      for _, dir in ipairs(independent_dirs) do
        M._run_maven(dir, { "help:effective-pom" }, { profiles = opts.active_profiles, offline = opts.offline },
          function(ok2, stdout2)
            if ok2 then
              local sub_parsed = M._parse_effective_pom(stdout2)
              if sub_parsed[1] and sub_parsed[1].packaging ~= "pom" then
                reactor_by_path[dir] = sub_parsed[1]
              end
            end
            pending = pending - 1
            if pending == 0 then finalize() end
          end)
      end
    end)
end

---@param dir string
---@param parsed table
---@param profiles string[]
---@param in_reactor boolean
function M._build_module(dir, parsed, profiles, in_reactor)
  local source_roots = {}
  local main_dir = parsed.source_dir or (dir .. "/src/main/java")
  local test_dir = parsed.test_source_dir or (dir .. "/src/test/java")
  if vim.fn.isdirectory(main_dir) == 1 then
    table.insert(source_roots, { path = main_dir, kind = "main", lang = "java" })
  end
  if vim.fn.isdirectory(test_dir) == 1 then
    table.insert(source_roots, { path = test_dir, kind = "test", lang = "java" })
  end

  local dependencies = {}
  for _, dep in ipairs(parsed.dependencies) do
    table.insert(dependencies, {
      group_id = dep.group_id,
      artifact_id = dep.artifact_id,
      version = dep.version,
      scope = dep.scope,
      is_sibling = false,
    })
  end

  return require("java-debug-model.model").Module.new({
    path = dir,
    group_id = parsed.group_id,
    artifact_id = parsed.artifact_id,
    version = parsed.version,
    packaging = parsed.packaging,
    content_root = dir,
    source_roots = source_roots,
    dependencies = dependencies,
    profiles = profiles,
    in_reactor = in_reactor,
  })
end

---Runs `mvn dependency:build-classpath` for every module and attaches
---resolved Library entries onto each non-sibling Dependency.
function M._resolve_classpaths(project, _all_pom_dirs, opts, done)
  local pending = #project.modules
  if pending == 0 then done() return end
  for _, mod in ipairs(project.modules) do
    local outfile = vim.fn.tempname()
    M._run_maven(mod.path, { "dependency:build-classpath", "-Dmdep.outputFile=" .. outfile },
      { profiles = opts.active_profiles, offline = opts.offline },
      function(ok)
        if ok and vim.fn.filereadable(outfile) == 1 then
          local content = table.concat(vim.fn.readfile(outfile), "\n")
          local jars = M._parse_classpath(content)
          mod._classpath_jars = jars
          for _, jar in ipairs(jars) do
            for _, dep in ipairs(mod.dependencies) do
              if not dep.library and not dep.is_sibling then
                local artifact, version = jar:match("([^/\\]+)/([^/\\]+)/[^/\\]+%.jar$")
                if artifact == dep.artifact_id and (not version or version == dep.version) then
                  dep.library = library_from_jar_path(jar)
                end
              end
            end
          end
          pcall(vim.fn.delete, outfile)
        end
        pending = pending - 1
        if pending == 0 then done() end
      end)
  end
end

---Marks dependencies whose groupId:artifactId matches another discovered
---module as sibling references instead of external jars - this is what lets
---cross-module debug prefer live compiled output over a stale .m2 jar.
function M._mark_sibling_dependencies(project)
  for _, mod in ipairs(project.modules) do
    for _, dep in ipairs(mod.dependencies) do
      local ga = dep.group_id .. ":" .. dep.artifact_id
      local sibling = project:find_module_by_ga(ga)
      if sibling and sibling.path ~= mod.path then
        dep.is_sibling = true
        dep.sibling_module_path = sibling.path
        dep.library = nil
      end
    end
  end
end

function M.detect(root)
  return vim.fn.filereadable(root .. "/pom.xml") == 1
end

function M.clear_cache(root)
  for k in pairs(cache) do
    if root == nil or vim.startswith(k, root) then
      cache[k] = nil
    end
  end
end

return M
