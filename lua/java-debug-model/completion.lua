-- Out-of-the-box code completion for jdtls (Java) and jsf-el (.xhtml EL) buffers on a machine that
-- has NO completion plugin: Neovim's own vim.lsp.completion (0.11+), popup opening as you type
-- like IntelliJ, <C-Space> to open it by hand, <CR> to accept the selected item.
--
-- opts.native_completion:
--   "auto" (default) - only when no completion plugin (nvim-cmp, blink.cmp, mini.completion,
--                      coq_nvim) is installed; with one, it already picks both servers up via LSP
--   true             - always (even alongside a completion plugin)
--   false            - never
local M = {}

local PLUGIN_MODULES = { "cmp", "blink.cmp", "mini.completion", "coq" }
local LAZY_NAMES = { "nvim-cmp", "blink.cmp", "mini.completion", "mini.nvim", "coq_nvim" }

---True when a completion plugin is installed - loaded already, registered with lazy.nvim (it
---may be lazy-loaded on InsertEnter, i.e. not loaded yet at LspAttach time), or on the runtimepath.
function M.plugin_present()
  for _, mod in ipairs(PLUGIN_MODULES) do
    if package.loaded[mod] then return true end
  end
  local ok, lazy_config = pcall(require, "lazy.core.config")
  if ok and type(lazy_config.plugins) == "table" then
    for _, name in ipairs(LAZY_NAMES) do
      local plugin = lazy_config.plugins[name]
      -- mini.nvim is a bundle: only counts when its completion module is actually set up
      if plugin and (name ~= "mini.nvim" or package.loaded["mini.completion"]) then return true end
    end
  end
  for _, file in ipairs({ "lua/cmp/init.lua", "lua/blink/cmp/init.lua" }) do
    if #vim.api.nvim_get_runtime_file(file, false) > 0 then return true end
  end
  return false
end

---@param mode "auto"|boolean|nil
function M.should_enable(mode)
  if mode == false or not (vim.lsp.completion and vim.lsp.completion.enable) then return false end
  if mode == true then return true end
  return not M.plugin_present()
end

---Turns on native LSP completion for `client_id` in `bufnr` (see module doc for when).
---@param client_id integer
---@param bufnr integer
---@param mode "auto"|boolean|nil  opts.native_completion
---@return boolean enabled
function M.attach(client_id, bufnr, mode)
  if not M.should_enable(mode) then return false end
  vim.lsp.completion.enable(true, client_id, bufnr, { autotrigger = true })

  -- Popup like IntelliJ's: always shown (even for one match), nothing inserted until chosen.
  local cot = vim.opt.completeopt:get()
  for _, flag in ipairs({ "menuone", "noselect", "popup" }) do
    if not vim.tbl_contains(cot, flag) then vim.opt.completeopt:append(flag) end
  end

  if not vim.b[bufnr].java_debug_model_native_completion_keys then
    vim.b[bufnr].java_debug_model_native_completion_keys = true
    vim.keymap.set("i", "<C-Space>", function() vim.lsp.completion.get() end,
      { buffer = bufnr, desc = "Code completion (IntelliJ Ctrl+Space)" })
    -- <CR>: accept the highlighted item; with nothing highlighted just close the menu + newline.
    vim.keymap.set("i", "<CR>", function()
      if vim.fn.pumvisible() == 1 then
        return vim.fn.complete_info({ "selected" }).selected ~= -1 and "<C-y>" or "<C-e><CR>"
      end
      return "<CR>"
    end, { buffer = bufnr, expr = true, desc = "Accept completion item" })
  end
  return true
end

return M
