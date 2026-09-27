-- Project-wide EL bean name -> Java file index for jsf/nav.lua. Built from the plugin's own
-- resolved Project Model (every module's main java source roots - no second module scanner), by
-- grepping for the bean-defining annotations and then reading just the files that hit.
--
-- Cached per root, built lazily on first use; `:JavaJsfIndexReload` rebuilds. No fs-watcher: a
-- renamed bean/class goes stale until that reload - known, accepted limitation for now.
local el = require("java-debug-model.jsf.el")

local M = {}

-- CDI @Named, JSF @ManagedBean, Spring @Component + its stereotypes (same naming rule).
local ANNOTATIONS = { Named = "cdi", ManagedBean = "jsf", Component = "spring", Service = "spring",
  Controller = "spring", Repository = "spring" }
local GREP_PATTERN = "@(Named|ManagedBean|Component|Service|Controller|Repository)\\b"

---@class JsfBean
---@field name string
---@field class_name string
---@field fqcn string
---@field file string

---@type table<string, { beans: table<string, JsfBean>, by_file: table<string, JsfBean[]> }>
M.cache = {}
local pending = {} -- root -> callbacks waiting on an in-flight build

---Explicit bean name from an annotation's argument list: `("x")`, `(value = "x")`, `(name = "x")`.
local function explicit_name(args)
  if not args then return nil end
  return args:match("^%s*\"([^\"]*)\"") or args:match("name%s*=%s*\"([^\"]*)\"")
    or args:match("value%s*=%s*\"([^\"]*)\"")
end

---Parses one Java source file's lines into the bean it declares, or nil. Only annotations that
---come BEFORE the first class declaration count - `@Inject @Named("x") Foo foo;` on a field
---is an injection point, not a bean definition.
---@param lines string[]
---@param file string
---@return JsfBean|nil
function M.parse_bean_file(lines, file)
  local pkg, class_name, class_line
  for i, l in ipairs(lines) do
    pkg = pkg or l:match("^%s*package%s+([%w_.]+)%s*;")
    local c = l:match("%f[%w_]class%s+([%a_][%w_]*)")
    -- ignore "class" in a comment line (`// ...`, `/** ...`, ` * ...`)
    if c and not l:match("^%s*//") and not l:match("^%s*/?%*") then
      class_name, class_line = c, i
      break
    end
  end
  if not class_name then return nil end

  local header = table.concat(lines, "\n", 1, class_line)
  local best
  for ann, args in header:gmatch("@([%a_][%w_]*)%s*(%b())") do
    if ANNOTATIONS[ann] and not best then best = { ann = ann, args = args:sub(2, -2) } end
  end
  if not best then
    for ann in header:gmatch("@([%a_][%w_]*)") do
      if ANNOTATIONS[ann] then best = { ann = ann } break end
    end
  end
  if not best then return nil end

  local name = explicit_name(best.args)
  if not name or name == "" then
    name = el.decapitalize(class_name, ANNOTATIONS[best.ann] == "spring")
  end
  return { name = name, class_name = class_name, fqcn = pkg and (pkg .. "." .. class_name) or class_name, file = file }
end

---@param project table  Project
---@return string[]
local function java_source_dirs(project)
  local dirs = {}
  for _, mod in ipairs(project.modules) do
    for _, sr in ipairs(mod:main_source_roots()) do
      if sr.lang == "java" and vim.fn.isdirectory(sr.path) == 1 then table.insert(dirs, sr.path) end
    end
  end
  return dirs
end

---Prefers ripgrep when present (same "use the real tool" principle as the Maven resolver's `mvn`).
local function grep_cmd(dirs)
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "-l", "--no-messages", "-g", "*.java", "-e", GREP_PATTERN }
  else
    cmd = { "grep", "-rlE", "--include=*.java", GREP_PATTERN }
  end
  vim.list_extend(cmd, dirs)
  return cmd
end

---Builds the index for `project` from scratch (async), replacing any cached one.
---@param root string
---@param project table
---@param callback fun(index)
function M.build(root, project, callback)
  local dirs = java_source_dirs(project)
  local index = { beans = {}, by_file = {}, candidates = {} }
  if #dirs == 0 then
    M.cache[root] = index
    callback(index)
    return
  end
  vim.system(grep_cmd(dirs), { text = true }, vim.schedule_wrap(function(res)
    -- exit 1 = no matches (rg and grep both) - an empty index, not an error
    if res.code > 1 then
      vim.notify("java-debug-model: JSF bean index grep lỗi: " .. (res.stderr or ""), vim.log.levels.WARN)
    end
    for file in (res.stdout or ""):gmatch("[^\n]+") do
      local path = vim.fn.fnamemodify(file, ":p")
      local ok, lines = pcall(vim.fn.readfile, path)
      local bean = ok and M.parse_bean_file(lines, path) or nil
      if bean then
        -- Same bean name in several apps of one repo (each its own Spring context) is normal -
        -- keep them all; M.pick chooses the one closest to the page asking.
        index.candidates[bean.name] = index.candidates[bean.name] or {}
        table.insert(index.candidates[bean.name], bean)
        index.beans[bean.name] = index.beans[bean.name] or bean
        index.by_file[path] = index.by_file[path] or {}
        table.insert(index.by_file[path], bean)
      end
    end
    M.cache[root] = index
    callback(index)
  end))
end

---Bean `name` as seen from `near_file` (the .xhtml page): with several beans of that name (one
---per app/module of a multi-app repo), the one sharing the longest directory prefix with the page.
---@return JsfBean|nil
function M.pick(index, name, near_file)
  local cands = index and index.candidates and index.candidates[name]
  if not cands or #cands <= 1 or not near_file then return index and index.beans[name] or nil end
  local best, best_len = nil, -1
  for _, bean in ipairs(cands) do
    local n = 0
    for i = 1, math.min(#bean.file, #near_file) do
      if bean.file:byte(i) ~= near_file:byte(i) then break end
      n = i
    end
    if n > best_len then best, best_len = bean, n end
  end
  return best
end

---Cached index for `root`, building it (resolving the Project Model first) on first use.
---@param root string
---@param callback fun(index|nil)
function M.get(root, callback)
  if M.cache[root] then
    callback(M.cache[root])
    return
  end
  if pending[root] then
    table.insert(pending[root], callback)
    return
  end
  pending[root] = { callback }
  local function finish(index)
    local cbs = pending[root] or {}
    pending[root] = nil
    for _, cb in ipairs(cbs) do cb(index) end
  end
  require("java-debug-model").get_project(root, function(project)
    if not project then
      finish(nil)
      return
    end
    M.build(root, project, finish)
  end)
end

---Drops the cached index for `root` and rebuilds it (`:JavaJsfIndexReload`).
---@param root string
---@param callback fun(index|nil)?
function M.reload(root, callback)
  M.cache[root] = nil
  M.get(root, function(index)
    if index then
      vim.notify(string.format("java-debug-model: JSF bean index: %d bean(s).", vim.tbl_count(index.beans)))
    end
    if callback then callback(index) end
  end)
end

return M
