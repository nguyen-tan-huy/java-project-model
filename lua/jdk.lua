-- Multi-JDK discovery/switching utility (Arch: /usr/lib/jvm, SDKMAN: ~/.sdkman/candidates/java).
-- Used by jdtls_launcher.lua for the JDK switcher keymap (<leader>jv) and to populate
-- java.configuration.runtimes for jdtls.
--
-- Bundled here (top-level lua/, NOT namespaced under java-debug-model/) as a DEFAULT so
-- `require("jdk")` resolves even on a fresh machine that installed only this one plugin - a
-- config that already ships its OWN jdk.lua (e.g. one that needs to set JAVA_HOME very early at
-- init.lua's top, before lazy.nvim even loads plugins) keeps using that instead: Neovim's
-- runtimepath always searches the user's own ~/.config/nvim/lua/ before any lazy-managed plugin's
-- lua/ dir, so a same-named local module wins automatically, no conflict.
local M = {}

--- Every JDK install path found on disk.
function M.list()
  local dirs = {}
  vim.list_extend(dirs, vim.fn.glob("/usr/lib/jvm/*", false, true))
  vim.list_extend(dirs, vim.fn.glob(vim.fn.expand("~/.sdkman/candidates/java/*"), false, true))

  local jdks, seen = {}, {}
  for _, dir in ipairs(dirs) do
    -- Resolve symlinks (e.g. /usr/lib/jvm/default pointing at another java-*-openjdk) to avoid
    -- listing the same install twice under two different paths.
    local real = vim.fn.resolve(dir)
    if not seen[real] and vim.fn.executable(real .. "/bin/java") == 1 then
      seen[real] = true
      table.insert(jdks, real)
    end
  end
  table.sort(jdks)
  return jdks
end

--- Major version (8, 11, 17, 21, ...) parsed from the directory name, falling back to reading
--- the JDK's own "release" file.
function M.major_version(path)
  local name = vim.fn.fnamemodify(path, ":t")
  local v = name:match("java%-(%d+)") or name:match("^(%d+)")
  if v then return tonumber(v) end

  local release = path .. "/release"
  if vim.fn.filereadable(release) == 1 then
    for _, line in ipairs(vim.fn.readfile(release)) do
      local ver = line:match('JAVA_VERSION="(%d+)')
      if ver then return tonumber(ver) end
    end
  end
  return nil
end

--- Eclipse-style Execution Environment name (jdtls's java.configuration.runtimes expects this).
function M.ee_name(major)
  if not major then return "JavaSE" end
  if major <= 8 then return "JavaSE-1.8" end
  return "JavaSE-" .. major
end

--- Builds the "java.configuration.runtimes" list for jdtls - the JDK matching the current
--- JAVA_HOME becomes the default.
function M.runtimes_for_jdtls()
  local runtimes = {}
  for _, path in ipairs(M.list()) do
    table.insert(runtimes, {
      name = M.ee_name(M.major_version(path)),
      path = path,
      default = (path == vim.env.JAVA_HOME) or nil,
    })
  end
  return runtimes
end

--- Changes JAVA_HOME/PATH for terminals/processes spawned AFTER this call (mvn, gradle, java...)
--- - doesn't affect a terminal already open.
function M.set_java_home(path)
  local old_bin = vim.env.JAVA_HOME and (vim.env.JAVA_HOME .. "/bin") or nil
  local parts = {}
  for p in vim.env.PATH:gmatch("[^:]+") do
    if p ~= old_bin then table.insert(parts, p) end
  end
  vim.env.JAVA_HOME = path
  vim.env.PATH = path .. "/bin:" .. table.concat(parts, ":")
end

return M
