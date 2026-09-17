-- Persisted "active Run/Debug Configuration" per project root - this is the name shown/selected
-- in ui/toolbar.lua's IntelliJ-style toolbar dropdown, mirroring IntelliJ's own top-right
-- configuration selector. Deliberately separate from config_store.lua's DebugConfig list itself
-- (that's the full CRUD'd set of saved profiles) and from maven_jdk.lua/jdtls_launcher's own JDK
-- selections - this module only remembers WHICH one of those saved profiles the toolbar's Run/
-- Debug buttons should act on, same JSON-file-per-root persistence pattern as maven_jdk.lua so it
-- survives a Neovim restart with no re-selection needed.
local M = {}

local function store_path(root)
  return root .. "/.nvim/java-debug-model/active-config.json"
end

---@type table<string, string|nil>  root -> active DebugConfig name
local cache = {}
---@type table<string, boolean>
local loaded = {}

local function load_from_disk(root)
  local path = store_path(root)
  if vim.fn.filereadable(path) == 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded.name
end

---@param root string
---@return string|nil  name of the active DebugConfig, or nil if none picked yet
function M.get(root)
  if not loaded[root] then
    cache[root] = load_from_disk(root)
    loaded[root] = true
  end
  return cache[root]
end

---@param root string
---@param name string|nil  pass nil to clear the active selection
function M.set(root, name)
  cache[root] = name
  loaded[root] = true
  local path = store_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, { name = name })
  if not ok then
    vim.notify("java-debug-model: failed to encode active-config.json: " .. encoded, vim.log.levels.ERROR)
    return
  end
  vim.fn.writefile(vim.split(encoded, "\n"), path)

  -- ui/toolbar.lua's own bar shows the active config's name too - picking a different profile
  -- from somewhere ELSE (e.g. ui/session_manager.lua's own edit flow) shouldn't leave that bar
  -- showing a stale name until something unrelated happens to trigger a re-render.
  local ok_toolbar, toolbar = pcall(require, "java-debug-model.ui.toolbar")
  if ok_toolbar then toolbar.refresh() end
end

---Resolves the active config, falling back to the first saved config (so a fresh project with no
---explicit pick yet still has something the toolbar's Run/Debug buttons can act on) - `nil` only
---when there are no saved configs at all.
---@param root string
---@param config_store table  the config_store module (passed in to avoid a require cycle)
---@return table|nil DebugConfig
function M.resolve(root, config_store)
  local configs = config_store.list(root)
  if #configs == 0 then return nil end
  local name = M.get(root)
  if name then
    for _, cfg in ipairs(configs) do
      if cfg.name == name then return cfg end
    end
  end
  return configs[1]
end

return M
