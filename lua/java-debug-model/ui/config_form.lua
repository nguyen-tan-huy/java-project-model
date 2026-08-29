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

  pick_module(function(module)
    if not module then return end

    vim.ui.input({ prompt = "Config name: ", default = existing and existing.name or "" }, function(name)
      if not name or name == "" then return end

      vim.ui.input({
        prompt = "Main class: ",
        default = existing and existing.main_class or (opts.default_main_class or ""),
      }, function(main_class)
        if not main_class or main_class == "" then return end

        vim.ui.input({ prompt = "VM args: ", default = existing and existing.vm_args or "" }, function(vm_args)
          vim.ui.input({ prompt = "Program args: ", default = existing and existing.program_args or "" },
            function(program_args)
              vim.ui.input({
                prompt = "Env vars (KEY=val,KEY2=val2): ",
                default = existing and format_env_vars(existing.env_vars) or "",
              }, function(env_str)
                vim.ui.input({
                  prompt = "Working directory: ",
                  default = existing and existing.working_directory or module.content_root,
                }, function(cwd)
                  vim.ui.input({
                    prompt = "Maven profiles (comma-separated): ",
                    default = existing and table.concat(existing.maven_profiles, ",") or "",
                  }, function(profiles_str)
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
