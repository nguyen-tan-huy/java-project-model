-- Add/edit form for a DebugConfig. Keeps to vim.ui.input/vim.ui.select so it
-- works with whatever UI picker/input provider the user has configured
-- (dressing.nvim, snacks, telescope, or plain vim.ui).
local config_store = require("java-debug-model.config_store")

local M = {}

local function parse_env_vars(text)
  local env = {}
  if not text or text == "" then return env end
  for pair in text:gmatch("[^,]+") do
    local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then env[k] = v end
  end
  return env
end

local function format_env_vars(env)
  local parts = {}
  for k, v in pairs(env or {}) do
    table.insert(parts, k .. "=" .. v)
  end
  return table.concat(parts, ",")
end

---Opens a sequence of vim.ui.input/vim.ui.select prompts to create or edit a
---DebugConfig, then persists it via config_store.
---@param root string
---@param project table Project
---@param opts table?  { existing?: DebugConfig, default_module?: table, default_main_class?: string }
function M.open(root, project, opts)
  opts = opts or {}
  local existing = opts.existing

  local modules = project.modules
  if #modules == 0 then
    vim.notify("java-debug-model: no modules in the project model", vim.log.levels.WARN)
    return
  end

  local function pick_module(cb)
    if existing then
      cb(project:find_module_by_path(existing.module_path))
      return
    end
    if opts.default_module then
      cb(opts.default_module)
      return
    end
    vim.ui.select(modules, {
      prompt = "Module:",
      format_item = function(m) return m:ga() end,
    }, cb)
  end

  -- vim.ui.input distinguishes "cancelled" (Esc/Ctrl-C) from "confirmed
  -- empty string" by passing nil vs "" to its callback (see :h vim.ui.input,
  -- and the `_canceled`/cancelreturn handling in the default implementation).
  -- Every step below must therefore treat nil as "abort the whole edit",
  -- never as "leave this field blank" - otherwise cancelling partway
  -- through (a natural instinct when you don't want to change THIS
  -- particular field, e.g. to leave env vars untouched) silently falls
  -- through as an empty value instead, which for env_vars means wiping
  -- every previously-saved variable with no warning at all.
  local function cancelled()
    vim.notify("java-debug-model: debug config edit cancelled, nothing was changed", vim.log.levels.INFO)
  end

  pick_module(function(module)
    if not module then return end

    vim.ui.input({ prompt = "Config name: ", default = existing and existing.name or "" }, function(name)
      if name == nil then cancelled() return end
      if name == "" then return end

      vim.ui.input({
        prompt = "Main class: ",
        default = existing and existing.main_class or (opts.default_main_class or ""),
      }, function(main_class)
        if main_class == nil then cancelled() return end
        if main_class == "" then return end

        vim.ui.input({ prompt = "VM args: ", default = existing and existing.vm_args or "" }, function(vm_args)
          if vm_args == nil then cancelled() return end
          vim.ui.input({ prompt = "Program args: ", default = existing and existing.program_args or "" },
            function(program_args)
              if program_args == nil then cancelled() return end
              vim.ui.input({
                prompt = "Env vars (KEY=val,KEY2=val2): ",
                default = existing and format_env_vars(existing.env_vars) or "",
              }, function(env_str)
                if env_str == nil then cancelled() return end
                vim.ui.input({
                  prompt = "Working directory: ",
                  default = existing and existing.working_directory or module.content_root,
                }, function(cwd)
                  if cwd == nil then cancelled() return end
                  vim.ui.input({
                    prompt = "Maven profiles (comma-separated): ",
                    default = existing and table.concat(existing.maven_profiles, ",") or "",
                  }, function(profiles_str)
                    if profiles_str == nil then cancelled() return end
                    local config = {
                      name = name,
                      module_path = module.path,
                      main_class = main_class,
                      vm_args = vm_args or "",
                      program_args = program_args or "",
                      env_vars = parse_env_vars(env_str),
                      working_directory = (cwd ~= "" and cwd) or module.content_root,
                      maven_profiles = profiles_str and profiles_str ~= "" and vim.split(profiles_str, ",") or {},
                    }
                    config_store.add(root, config)
                    vim.notify("java-debug-model: saved debug config '" .. name .. "'", vim.log.levels.INFO)
                  end)
                end)
              end)
            end)
        end)
      end)
    end)
  end)
end

return M
