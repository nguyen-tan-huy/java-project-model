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

return M
