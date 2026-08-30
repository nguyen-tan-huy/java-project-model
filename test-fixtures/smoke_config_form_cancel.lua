package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local config_store = require("java-debug-model.config_store")
local config_form = require("java-debug-model.ui.config_form")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

local mod_a = project:find_module_by_ga("com.example:module-a")

local existing = config_store.default_from_main_class(mod_a, "com.example.modulea.App")
existing.env_vars = { FOO = "bar" }
config_store.add(root, existing)

-- simulate the user cancelling (Esc) exactly on the "Env vars" prompt,
-- meaning to leave it untouched - vim.ui.input calls its callback with nil
-- in this case (see :h vim.ui.input). The saved config must be completely
-- unaffected: no partial save with env_vars wiped out.
local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level) table.insert(notified, msg) end

local orig_ui_input = vim.ui.input
vim.ui.input = function(opts, on_confirm)
  if opts.prompt:find("^Env vars") then
    on_confirm(nil) -- simulate Esc/cancel
  else
    on_confirm(opts.default)
  end
end

config_form.open(root, project, { existing = existing })

vim.ui.input = orig_ui_input
vim.notify = orig_notify

local after = config_store.get(root, existing.name)
assert(after, "config should still exist after a cancelled edit")
assert(after.env_vars.FOO == "bar", "cancelling the env-vars prompt must NOT wipe existing env vars, got "
  .. vim.inspect(after.env_vars))

local saw_cancel_notice = false
for _, m in ipairs(notified) do
  if m:find("cancelled") then saw_cancel_notice = true end
end
assert(saw_cancel_notice, "user should be notified the edit was cancelled, not have it silently no-op/partial-save")

print("config_form.lua cancel-preserves-existing-config smoke test: OK")
