-- Pure Lua data structures for the Project Model. No I/O here: resolver/maven.lua
-- builds these from real `mvn` output, but this module doesn't know that.
local M = {}

---@class Library
---@field group_id string
---@field artifact_id string
---@field version string
---@field jar_path string|nil    -- absolute path to the .m2 jar, nil if unresolved
---@field sources_jar_path string|nil

---@class SourceRoot
---@field path string   -- absolute path
---@field kind "main"|"test"
---@field lang "java"|"resources"

---@class Dependency
---@field group_id string
---@field artifact_id string
---@field version string
---@field scope string          -- compile/test/provided/runtime/system/import
---@field is_sibling boolean    -- true if coordinate-matched to another Module in the Project
---@field sibling_module_path string|nil   -- Module.path this resolves to, when is_sibling
---@field library Library|nil   -- set when NOT a sibling (external jar)

---@class Module
---@field path string             -- absolute path to the module's directory (pom.xml parent dir)
---@field group_id string
---@field artifact_id string
---@field version string
---@field packaging string        -- jar/war/pom/...
---@field content_root string     -- usually == path
---@field source_roots SourceRoot[]
---@field dependencies Dependency[]
---@field profiles string[]       -- active profiles this module was resolved with
---@field in_reactor boolean      -- true if reachable via an aggregator's <modules>, false if
---                                   only found via filesystem scan (independent pom)
local Module = {}
Module.__index = Module

function Module.new(fields)
  local self = setmetatable({}, Module)
  self.path = fields.path
  self.group_id = fields.group_id
  self.artifact_id = fields.artifact_id
  self.version = fields.version
  self.packaging = fields.packaging or "jar"
  self.content_root = fields.content_root or fields.path
  self.source_roots = fields.source_roots or {}
  self.dependencies = fields.dependencies or {}
  self.profiles = fields.profiles or {}
  self.in_reactor = fields.in_reactor or false
  return self
end

function Module:coordinates()
  return string.format("%s:%s:%s", self.group_id, self.artifact_id, self.version)
end

function Module:ga()
  return string.format("%s:%s", self.group_id, self.artifact_id)
end

function Module:main_source_roots()
  return vim.tbl_filter(function(sr) return sr.kind == "main" end, self.source_roots)
end

function Module:test_source_roots()
  return vim.tbl_filter(function(sr) return sr.kind == "test" end, self.source_roots)
end

---@class Project
---@field root string
---@field modules Module[]
local Project = {}
Project.__index = Project

function Project.new(root)
  local self = setmetatable({}, Project)
  self.root = root
  self.modules = {}
  return self
end

function Project:add_module(module)
  table.insert(self.modules, module)
end

---@param ga string "groupId:artifactId"
function Project:find_module_by_ga(ga)
  for _, mod in ipairs(self.modules) do
    if mod:ga() == ga then return mod end
  end
  return nil
end

function Project:find_module_by_path(path)
  for _, mod in ipairs(self.modules) do
    if mod.path == path then return mod end
  end
  return nil
end

---Finds which module owns a given absolute file path, by longest source-root
---(then content-root) prefix match.
---@param file_path string
---@return Module|nil
function Project:find_module_for_file(file_path)
  local best, best_len = nil, -1
  for _, mod in ipairs(self.modules) do
    for _, sr in ipairs(mod.source_roots) do
      if vim.startswith(file_path, sr.path) and #sr.path > best_len then
        best, best_len = mod, #sr.path
      end
    end
    if not best and vim.startswith(file_path, mod.content_root .. "/") and #mod.content_root > best_len then
      best, best_len = mod, #mod.content_root
    end
  end
  return best
end

---@return SourceRoot[]
function Project:get_source_roots()
  local roots = {}
  for _, mod in ipairs(self.modules) do
    vim.list_extend(roots, mod.source_roots)
  end
  return roots
end

M.Module = Module
M.Project = Project

return M
