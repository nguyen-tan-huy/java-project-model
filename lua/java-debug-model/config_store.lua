-- CRUD + JSON persistence for DebugConfig entries. IntelliJ "Edit
-- Configurations" parity: name, module, main class, VM/program args, env
-- vars, working directory, Maven profiles.
local M = {}

---@class DebugConfig
---@field name string
---@field module_path string
---@field main_class string
---@field vm_args string
---@field program_args string
---@field env_vars table<string, string>
---@field working_directory string
---@field maven_profiles string[]

local function store_path(root)
  return root .. "/.nvim/java-debug-model/debug-configs.json"
end

---@type table<string, DebugConfig[]>
local cache = {}

local function load_from_disk(root)
  local path = store_path(root)
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then return {} end
  return decoded
end

local function save_to_disk(root, configs)
  local path = store_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, configs)
  if not ok then
    vim.notify("java-debug-model: failed to encode debug configs: " .. encoded, vim.log.levels.ERROR)
    return
  end
  vim.fn.writefile(vim.split(encoded, "\n"), path)
end

---@param root string
---@return DebugConfig[]
function M.list(root)
  if not cache[root] then
    cache[root] = load_from_disk(root)
  end
  return cache[root]
end

---@param root string
---@param name string
---@return DebugConfig|nil
function M.get(root, name)
  for _, cfg in ipairs(M.list(root)) do
    if cfg.name == name then return cfg end
  end
  return nil
end

---Adds a new config, or overwrites an existing one with the same name.
---@param root string
---@param config DebugConfig
function M.add(root, config)
  local configs = M.list(root)
  for i, cfg in ipairs(configs) do
    if cfg.name == config.name then
      configs[i] = config
      save_to_disk(root, configs)
      return
    end
  end
  table.insert(configs, config)
  save_to_disk(root, configs)
end

---@param root string
---@param name string
---@param fields table  partial DebugConfig fields to merge in
---@return boolean found
function M.edit(root, name, fields)
  local configs = M.list(root)
  for _, cfg in ipairs(configs) do
    if cfg.name == name then
      for k, v in pairs(fields) do
        cfg[k] = v
      end
      save_to_disk(root, configs)
      return true
    end
  end
  return false
end

---@param root string
---@param name string
---@return boolean removed
function M.remove(root, name)
  local configs = M.list(root)
  for i, cfg in ipairs(configs) do
    if cfg.name == name then
      table.remove(configs, i)
      save_to_disk(root, configs)
      return true
    end
  end
  return false
end

---Builds a DebugConfig with sane defaults from an auto-detected main class.
---@param module table Module
---@param main_class string
---@return DebugConfig
function M.default_from_main_class(module, main_class)
  local simple_name = main_class:match("([^.]+)$") or main_class
  return {
    name = simple_name,
    module_path = module.path,
    main_class = main_class,
    vm_args = "",
    program_args = "",
    env_vars = {},
    working_directory = module.content_root,
    maven_profiles = {},
  }
end

return M
