-- CRUD + JSON persistence for test "profiles" - the SAME persistence pattern config_store.lua
-- uses for a saved DebugConfig, applied to a test run (test.lua's own <leader>jtm/jtc). Without
-- this, a test run only ever lived in session.lua's in-memory registry (kind="test") - gone the
-- moment Neovim quits, unlike a saved DebugConfig which already survives restarts. This gives a
-- test run's IntelliJ-style "temporary Run Configuration" (see test.lua's own comment on this) the
-- same durability a saved one gets: close Neovim, reopen, the profile row is still there in
-- ui/session_manager.lua (just not "running" any more, exactly like a config row that hasn't been
-- launched yet this session).
local M = {}

---@class TestProfile
---@field name string             -- display name, e.g. "ProductControllerTest (nearest test)"
---@field file string             -- absolute path to the source file
---@field scope "nearest_method"|"class"
---@field lnum integer|nil        -- cursor line at the time it was run - only meaningful for
---                                  scope=="nearest_method" (identifies WHICH method), unused for
---                                  scope=="class" (jdtls resolves the whole file regardless)
---@field variant "run"|"debug"   -- last variant it was launched with - reused as the default on
---                                  a later `s`/`r`/<CR> in ui/session_manager.lua

local function store_path(root)
  return root .. "/.nvim/java-debug-model/test-profiles.json"
end

---@type table<string, TestProfile[]>
local cache = {}

local function load_from_disk(root)
  local path = store_path(root)
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then return {} end
  return decoded
end

local function save_to_disk(root, profiles)
  local path = store_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, profiles)
  if not ok then
    vim.notify("java-debug-model: failed to encode test profiles: " .. encoded, vim.log.levels.ERROR)
    return
  end
  vim.fn.writefile(vim.split(encoded, "\n"), path)
end

---@param root string
---@return TestProfile[]
function M.list(root)
  if not cache[root] then
    cache[root] = load_from_disk(root)
  end
  return cache[root]
end

---@param root string
---@param name string
---@return TestProfile|nil
function M.get(root, name)
  for _, p in ipairs(M.list(root)) do
    if p.name == name then return p end
  end
  return nil
end

---Adds a new profile, or overwrites an existing one with the same name - matches
---config_store.lua's own M.add, and mirrors test.lua's pre-existing "rerun replaces the previous
---temporary entry instead of piling up a new one" behavior, now carried over to disk too.
---@param root string
---@param profile TestProfile
function M.add(root, profile)
  local profiles = M.list(root)
  for i, p in ipairs(profiles) do
    if p.name == profile.name then
      profiles[i] = profile
      save_to_disk(root, profiles)
      return
    end
  end
  table.insert(profiles, profile)
  save_to_disk(root, profiles)
end

---@param root string
---@param name string
---@return boolean removed
function M.remove(root, name)
  local profiles = M.list(root)
  for i, p in ipairs(profiles) do
    if p.name == name then
      table.remove(profiles, i)
      save_to_disk(root, profiles)
      return true
    end
  end
  return false
end

return M
