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

-- start from an existing config that ALREADY has one env var, simulating
-- a real saved profile the user is about to edit.
local existing = config_store.default_from_main_class(mod_a, "com.example.modulea.App")
existing.env_vars = { FOO = "bar" }
config_store.add(root, existing)

-- simulate the user opening :JavaDebugConfigEdit and changing ONLY the env
-- vars field (keeping every other prompt's default by returning it as-is,
-- exactly like pressing Enter on a pre-filled vim.ui.input in real usage).
local responses_in_order = {}
local call_index = 0
local orig_ui_input = vim.ui.input
vim.ui.input = function(opts, on_confirm)
  call_index = call_index + 1
  table.insert(responses_in_order, opts.prompt .. " [default=" .. tostring(opts.default) .. "]")
  if opts.prompt:find("^Env vars") then
    on_confirm("FOO=baz,NEW=1")  -- user changes FOO and adds NEW
  else
    on_confirm(opts.default)  -- keep everything else unchanged
  end
end

config_form.open(root, project, { existing = existing })

vim.ui.input = orig_ui_input

print("prompts shown, in order:")
for _, p in ipairs(responses_in_order) do print("  " .. p) end

local reloaded = config_store.get(root, existing.name)
assert(reloaded, "edited config should still exist under the same name")
print("saved env_vars: " .. vim.inspect(reloaded.env_vars))
assert(reloaded.env_vars.FOO == "baz", "FOO should be updated to 'baz', got " .. tostring(reloaded.env_vars.FOO))
assert(reloaded.env_vars.NEW == "1", "NEW=1 should have been added, got " .. tostring(reloaded.env_vars.NEW))

print("config_form.lua edit-env smoke test: OK")
