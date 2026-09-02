-- Persisted "Java version for Maven" per project root - part of the Project Model, alongside
-- config_store.lua's DebugConfig persistence, but scoped to ONLY the JVM that runs `mvn`/`mvnw`
-- itself (maven_runner.lua). Deliberately separate from jdtls_launcher.lua's own <leader>jv
-- ("Project SDK" for jdtls's compiler/debug JVM) - picking a JDK there only changes
-- java.configuration.runtimes for THAT jdtls client and is never persisted, so it resets on every
-- Neovim restart and never affects a Maven process spawned from a terminal/job. This module gives
-- Maven its own, independently-persisted JDK choice that every subsequent `mvn` invocation for
-- this root picks up automatically, with no re-selection needed per session.
local M = {}

local function store_path(root)
  return root .. "/.nvim/java-debug-model/maven-jdk.json"
end

---@type table<string, string|nil>  root -> selected JDK install path
local cache = {}
---@type table<string, boolean>  root -> already attempted a disk load this session
local loaded = {}

local function load_from_disk(root)
  local path = store_path(root)
  if vim.fn.filereadable(path) == 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded.jdk_path
end

---@param root string
---@return string|nil  absolute path to a JDK install, or nil meaning "no override - let
---                     mvn/mvnw resolve JAVA_HOME/PATH the normal way"
function M.get(root)
  if not loaded[root] then
    cache[root] = load_from_disk(root)
    loaded[root] = true
  end
  return cache[root]
end

---@param root string
---@param jdk_path string|nil  pass nil to clear back to "no override"
function M.set(root, jdk_path)
  cache[root] = jdk_path
  loaded[root] = true
  local path = store_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, { jdk_path = jdk_path })
  if not ok then
    vim.notify("java-debug-model: failed to encode maven-jdk.json: " .. encoded, vim.log.levels.ERROR)
    return
  end
  vim.fn.writefile(vim.split(encoded, "\n"), path)
end

---Env overrides to apply to a spawned `mvn`/`mvnw` job for `root` - nil (inherit Neovim's own
---environment untouched) when no JDK has been explicitly selected for this root yet.
---@param root string
---@return table<string, string>|nil
function M.env_for(root)
  local jdk_path = M.get(root)
  if not jdk_path then return nil end
  local old_path = vim.env.PATH or ""
  return {
    JAVA_HOME = jdk_path,
    PATH = jdk_path .. "/bin:" .. old_path,
  }
end

---Interactive picker (reuses lua/jdk.lua's disk discovery - same JDKs offered by jdtls_launcher's
---<leader>jv) that persists the choice for `root`. `on_done` (optional) is called after the pick
---completes (or is cancelled, with no args) - lets a caller (e.g. ui/maven_panel.lua) re-render.
---@param root string
---@param on_done fun()?
function M.select(root, on_done)
  local ok_jdk, jdk = pcall(require, "jdk")
  if not ok_jdk then
    vim.notify("java-debug-model: lua/jdk.lua not available", vim.log.levels.ERROR)
    return
  end
  local paths = jdk.list()
  if #paths == 0 then
    vim.notify("java-debug-model: không tìm thấy JDK nào trên máy.", vim.log.levels.WARN)
    return
  end
  local items = { { path = nil, label = "(mặc định - dùng JAVA_HOME/PATH hiện tại)" } }
  for _, path in ipairs(paths) do
    table.insert(items, { path = path, label = jdk.ee_name(jdk.major_version(path)) .. " :: " .. path })
  end
  vim.ui.select(items, {
    prompt = "Chọn JDK cho Maven (persist cho root này):",
    format_item = function(item) return item.label end,
  }, function(choice)
    if choice then
      M.set(root, choice.path)
      vim.notify("java-debug-model: Maven JDK cho " .. root .. " -> " .. (choice.path or "(mặc định)"),
        vim.log.levels.INFO)
    end
    if on_done then on_done() end
  end)
end

return M
