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
function M.ensure_mason_packages()
  local ok_registry, registry = pcall(require, "mason-registry")
  if not ok_registry then return end
  for _, name in ipairs({ "jdtls", "java-debug-adapter", "java-test" }) do
    local ok_pkg, pkg = pcall(registry.get_package, name)
    if ok_pkg and not pkg:is_installed() then
      vim.notify("java-debug-model: đang cài " .. name .. " qua Mason...", vim.log.levels.INFO)
      pkg:install()
    end
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
    vim.notify(
      "java-debug-model: không thấy spring-boot-tools language-server tại " .. ls_path ..
      " -> autocomplete application.yml/properties sẽ không hoạt động. Truyền " ..
      "opts.spring_boot_ls_path vào setup() nếu install ở đường dẫn khác.",
      vim.log.levels.WARN)
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

return M
