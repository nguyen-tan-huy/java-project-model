package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local maven = require("java-debug-model.resolver.maven")
local dap = require("java-debug-model.dap")
local config_store = require("java-debug-model.config_store")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local ok, project
maven.build(root, {}, function(_ok, _p) ok, project = _ok, _p end)
vim.wait(60000, function() return project ~= nil end, 100)
assert(ok, "maven.build failed")

local mod_a = project:find_module_by_ga("com.example:module-a")

-- The exact real-world reproduction: a saved config with NO env vars set
-- (config_store.default_from_main_class leaves env_vars = {}), which is the
-- common case for any auto-created config.
local cfg = config_store.default_from_main_class(mod_a, "com.example.modulea.App")
assert(next(cfg.env_vars) == nil, "default config should have empty env_vars")

local launch_config = dap.build_launch_config(project, cfg)

-- This is what nvim-dap actually sends over the wire (dap/session.lua uses
-- vim.json.encode on the whole launch request). `env` MUST serialize as a
-- JSON object ({}), never an array ([]) - java-debug/Gson expects
-- Map<String,String> and throws a deserialization error on an array.
local encoded = vim.json.encode(launch_config)
print("encoded env field: " .. encoded:match('"env":%[?%{?%]?%}?'))
assert(encoded:find('"env":{}', 1, true), "env must encode as a JSON object, got: " .. encoded)
assert(not encoded:find('"env":[]', 1, true), "env must NEVER encode as a JSON array")

-- sanity: a config WITH env vars still round-trips correctly as an object
local cfg2 = config_store.default_from_main_class(mod_a, "com.example.modulea.App")
cfg2.env_vars = { FOO = "bar" }
local launch_config2 = dap.build_launch_config(project, cfg2)
local encoded2 = vim.json.encode(launch_config2)
assert(encoded2:find('"env":{"FOO":"bar"}', 1, true), "non-empty env_vars should encode correctly: " .. encoded2)

print("dap.lua env-encoding smoke test: OK")
