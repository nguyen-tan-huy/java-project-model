-- Everything a fresh Neovim config needs to get Java working end to end,
-- besides `require("java-debug-model").setup({...})` itself: Mason package
-- installs (jdtls/java-debug-adapter/java-test - jdtls_launcher.lua only
-- LOOKS UP their install paths, it never triggers the install) and wiring
-- JavaHello/spring-boot.nvim (application.yml/properties completion) - both
-- previously lived as hand-written config in the USER's own plugins/*.lua,
-- meaning "configure java-debug-model" alone wasn't actually enough to get
-- every Java feature working. Called once from M.setup() below.
local M = {}

---Installs (if missing) the Mason packages jdtls_launcher.lua's build_config
---looks up by name: jdtls itself (LSP server jdt.ls), java-debug-adapter
---(DAP bundle) and java-test (JUnit/TestNG bundle). Safe to call every
---startup - checked+skipped instantly once installed, mason-registry itself
---dedupes concurrent installs.
---
---Calls require("mason").setup() itself first (pcall'd, idempotent - safe even if some OTHER
---config file already called it with its own options, e.g. a custom install root) rather than
---assuming the consuming config's own plugins/lsp.lua (or equivalent) already did: mason.nvim is
---now a listed `dependencies` entry of this plugin's own lazy.nvim spec, but lazy.nvim only
---INSTALLS/loads a listed dependency - it never calls that plugin's own setup() for you.
---mason-registry works with reasonable defaults even without an explicit setup() call in
---practice, but calling it here removes the implicit "some other file already did this" assumption
---entirely - "install java-debug-model" alone is then really enough.
---@param on_bundles_installed fun()?  called once after java-debug-adapter/java-test got newly
---installed this session - jdtls only loads bundles at startup, so a jdtls that is already
---running needs a restart to pick them up (init.lua passes jdtls_launcher.restart_all).
function M.ensure_mason_packages(on_bundles_installed)
  pcall(function() require("mason").setup() end)
  local ok_registry, registry = pcall(require, "mason-registry")
  if not ok_registry then return end

  local function install_missing()
    local pending, bundle_installed = 0, false
    local function finished(name, success)
      if success then
        vim.notify("java-debug-model: đã cài " .. name, vim.log.levels.INFO)
        if name ~= "jdtls" then bundle_installed = true end
      else
        vim.notify("java-debug-model: cài " .. name .. " qua Mason thất bại - thử :MasonInstall " .. name,
          vim.log.levels.WARN)
      end
      pending = pending - 1
      if pending == 0 and bundle_installed and on_bundles_installed then on_bundles_installed() end
    end
    for _, name in ipairs({ "jdtls", "java-debug-adapter", "java-test" }) do
      local ok_pkg, pkg = pcall(registry.get_package, name)
      if ok_pkg and not pkg:is_installed() and not pkg:is_installing() then
        pending = pending + 1
        vim.notify("java-debug-model: đang cài " .. name .. " qua Mason...", vim.log.levels.INFO)
        local done = false
        local function once(success)
          if done then return end
          done = true
          vim.schedule(function() finished(name, success) end)
        end
        -- mason 2.x: install(opts, callback); 1.x: returns a handle emitting "closed" - both.
        local handle = pkg:install({}, function(success) once(success) end)
        if handle and handle.once then
          pcall(handle.once, handle, "closed", function() once(pkg:is_installed()) end)
        end
      end
    end
  end

  -- A FRESH Mason has no registry downloaded yet: get_package() fails ("Cannot find package")
  -- until it's refreshed once - which silently skipped every install on a brand-new machine.
  if pcall(registry.get_package, "java-test") then
    install_missing()
  else
    registry.refresh(vim.schedule_wrap(function() install_missing() end))
  end
end

---Sets up JavaHello/spring-boot.nvim (completion for application.yml/
---properties) if its language server is installed - silently skips
---(no warning spam) when it isn't, since this is optional on top of jdtls.
---@param opts table? { ls_path?: string }  ls_path defaults to the nvim-java
---cache path this config was originally ported from.
function M.setup_spring_boot(opts)
  opts = opts or {}
  local ok_spring, spring_boot = pcall(require, "spring_boot")
  if not ok_spring then return end

  local ls_path = opts.ls_path or
      (vim.fn.stdpath("data") .. "/nvim-java/packages/spring-boot-tools/1.55.1/extension/language-server")
  if vim.fn.isdirectory(ls_path) ~= 1 then
    -- Optional extra on top of jdtls: only complain when the user pointed at a path explicitly
    -- (then it's a real misconfiguration) - a fresh install must start without warnings.
    if opts.ls_path then
      vim.notify("java-debug-model: không thấy spring-boot-tools language-server tại " .. ls_path ..
        " -> autocomplete application.yml/properties sẽ không hoạt động.", vim.log.levels.WARN)
    end
    return
  end

  spring_boot.setup({ ls_path = ls_path })
  spring_boot.init_lsp_commands()
end

---Fetches+extracts a prebuilt, ALREADY-PATCHED jdtls distribution from a GitHub Release asset
---(a .tar.gz built via the full `./mvnw clean verify` in eclipse.jdt.ls-build, see that repo's
---local-patches branch) if `dest` doesn't already look populated - lets a machine that never ran
---the Tycho build (which needs JDK 21 + a large p2 target-platform download, tens of minutes) get
---the SAME patched jdtls jdtls_launcher.lua expects, with zero build step. This is NOT a Mason
---registry package (writing/hosting a real mason-registry entry is a lot of machinery for a
---single personal patched build) - just a plain HTTP download + tar extraction, run ONCE, the
---same way Mason's own installers ultimately GET their packages.
---
---Deliberately BLOCKING (vim.fn.system, not vim.system+callback): this only ever runs the very
---FIRST time on a fresh machine (every later startup, the dest-populated check below skips it in
---a single stat call) - a one-time 10-60s wait during that first startup is a better trade-off
---than a background download racing the very first jdtls launch this Neovim session might trigger.
---@param opts table  { url: string  (release asset .tar.gz URL - REQUIRED, no default: depends on
---                      which fork/release the caller published), dest?: string  (defaults to the
---                      path jdtls_launcher.lua looks up first, see its own jdtls_path comment) }
function M.ensure_jdtls_prebuilt(opts)
  opts = opts or {}
  if not opts.url or opts.url == "" then return end
  local dest = opts.dest or (vim.fn.stdpath("data") .. "/nvim-java/packages/jdtls/1.54.0")

  -- "Populated" = has its own launcher script, not just an empty/partial dir from a previously
  -- interrupted download - re-attempts on next startup if a prior download got cut off partway.
  if vim.fn.filereadable(dest .. "/bin/jdtls") == 1 then return end

  if vim.fn.executable("curl") == 0 or vim.fn.executable("tar") == 0 then
    vim.notify("java-debug-model: cần 'curl' và 'tar' để tự tải jdtls đã patch sẵn - không thấy trong PATH.",
      vim.log.levels.WARN)
    return
  end

  vim.notify("java-debug-model: chưa có jdtls đã patch tại " .. dest .. " - đang tải từ " .. opts.url ..
    " (lần đầu, có thể mất 10-60s tuỳ mạng)...", vim.log.levels.INFO)

  local tmp = vim.fn.tempname() .. ".tar.gz"
  local download = vim.fn.system({ "curl", "-fsSL", opts.url, "-o", tmp })
  if vim.v.shell_error ~= 0 then
    pcall(vim.fn.delete, tmp)
    vim.notify("java-debug-model: tải jdtls thất bại - " .. vim.trim(download), vim.log.levels.ERROR)
    return
  end

  vim.fn.mkdir(dest, "p")
  local extract = vim.fn.system({ "tar", "xzf", tmp, "-C", dest })
  pcall(vim.fn.delete, tmp)
  if vim.v.shell_error ~= 0 then
    vim.notify("java-debug-model: giải nén jdtls thất bại - " .. vim.trim(extract), vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(dest .. "/bin/jdtls") == 1 then
    vim.notify("java-debug-model: đã tải+giải nén jdtls (đã patch) vào " .. dest, vim.log.levels.INFO)
  else
    vim.notify(
      "java-debug-model: đã giải nén nhưng không thấy bin/jdtls tại " .. dest ..
      " - kiểm tra lại URL/cấu trúc file tar.gz (asset có nên có thư mục con bọc ngoài không?).",
      vim.log.levels.WARN)
  end
end

-- ── Lombok ──────────────────────────────────────────────────────────────────────────────────

-- Where ensure_lombok() downloads lombok.jar when no copy exists anywhere else on the machine.
M.lombok_download_path = vim.fn.stdpath("data") .. "/java-debug-model/lombok.jar"
M.lombok_url = "https://projectlombok.org/downloads/lombok.jar"

---First lombok.jar found: next to the jdtls in use, Mason's jdtls package (ships one), the
---nvim-java cache, this plugin's own download, or the newest one in ~/.m2. nil if none.
---jdtls needs it as a -javaagent, otherwise every @Getter/@Data/@Builder project is a sea of
---"method getX() is undefined" errors.
---@param jdtls_path string?
---@return string|nil
function M.find_lombok(jdtls_path)
  local data = vim.fn.stdpath("data")
  -- Built with table.insert, NOT a literal with a possibly-nil first entry: ipairs stops at the
  -- first nil, which silently skipped every candidate whenever jdtls_path wasn't given.
  local candidates = {}
  if jdtls_path then table.insert(candidates, jdtls_path .. "/lombok.jar") end
  vim.list_extend(candidates, {
    data .. "/mason/packages/jdtls/lombok.jar",
    data .. "/nvim-java/packages/lombok/1.18.42/lombok-1.18.42.jar",
    M.lombok_download_path,
  })
  for _, c in ipairs(candidates) do
    if vim.fn.filereadable(c) == 1 then return c end
  end
  -- glob() with list=true (expand() on a wildcard returns ONE "\n"-joined string instead)
  local m2 = vim.fn.glob(vim.fn.expand("~") .. "/.m2/repository/org/projectlombok/lombok/*/lombok-*.jar", false, true)
  m2 = vim.tbl_filter(function(f) return not f:match("%-sources%.jar$") and not f:match("%-javadoc%.jar$") end, m2)
  table.sort(m2, function(a, b)
    local va, vb = a:match("/lombok/([^/]+)/"), b:match("/lombok/([^/]+)/")
    return vim.version.lt(vim.version.parse(va) or "0", vim.version.parse(vb) or "0")
  end)
  return m2[#m2]
end

---Downloads lombok.jar once (blocking, first run only - same trade-off as ensure_jdtls_prebuilt)
---when find_lombok() comes up empty.
function M.ensure_lombok()
  if M.find_lombok() then return end
  if vim.fn.executable("curl") == 0 then return end
  vim.fn.mkdir(vim.fs.dirname(M.lombok_download_path), "p")
  vim.notify("java-debug-model: đang tải lombok.jar (lần đầu)...", vim.log.levels.INFO)
  local out = vim.fn.system({ "curl", "-fsSL", M.lombok_url, "-o", M.lombok_download_path })
  if vim.v.shell_error ~= 0 then
    pcall(vim.fn.delete, M.lombok_download_path)
    vim.notify("java-debug-model: tải lombok.jar thất bại - " .. vim.trim(out), vim.log.levels.WARN)
  end
end

return M
