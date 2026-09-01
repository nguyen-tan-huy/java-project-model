if vim.g.loaded_java_debug_model then return end
vim.g.loaded_java_debug_model = true

local function jdm()
  return require("java-debug-model")
end

local function current_root()
  return jdm()._find_root(0)
end

local command = vim.api.nvim_create_user_command

command("JavaModelReload", function() jdm().reload(current_root()) end, {})
command("JavaModelInspect", function() jdm().inspect(current_root()) end, {})
command("JavaModelAddModule", function(args) jdm().add_module(current_root(), args.args) end,
  { nargs = 1, complete = "dir" })
command("JavaModelRemoveModule", function(args) jdm().remove_module(current_root(), args.args) end,
  { nargs = 1, complete = function()
    local root = current_root()
    local m = jdm()
    local names = {}
    m.get_project(root, function(project)
      if project then
        for _, mod in ipairs(project.modules) do table.insert(names, mod.artifact_id) end
      end
    end)
    return names
  end })

local function config_names()
  local root = current_root()
  local names = {}
  for _, cfg in ipairs(jdm().config_store.list(root)) do
    table.insert(names, cfg.name)
  end
  return names
end

command("JavaDebugConfigList", function()
  for _, cfg in ipairs(jdm().config_store.list(current_root())) do
    print(string.format("%s -> %s (module=%s)", cfg.name, cfg.main_class, cfg.module_path))
  end
end, {})
command("JavaDebugConfigAdd", function() jdm().debug_config_add(current_root()) end, {})
command("JavaDebugConfigEdit", function(args) jdm().debug_config_edit(current_root(), args.args) end,
  { nargs = 1, complete = config_names })
command("JavaDebugConfigRemove", function(args)
  jdm().config_store.remove(current_root(), args.args)
end, { nargs = 1, complete = config_names })
command("JavaDebugConfigRun", function(args) jdm().debug_config_run(current_root(), args.args) end,
  { nargs = 1, complete = config_names })
command("JavaDebugConfigFromFile", function() jdm().debug_config_from_file(current_root()) end, {})
command("JavaDebugConfigScan", function() jdm().debug_config_scan(current_root()) end, {})

command("TestNearestMethod", function() jdm().test.run_nearest_method() end, {})
command("TestClass", function() jdm().test.run_class() end, {})
command("TestDebugNearestMethod", function() jdm().test.debug_nearest_method() end, {})
command("TestDebugClass", function() jdm().test.debug_class() end, {})

command("JavaMavenPanel", function()
  if jdm().maven_panel.is_open() then
    jdm().maven_panel.close()
    return
  end
  jdm().get_project(current_root(), function(project)
    if project then jdm().maven_panel.open(current_root(), project) end
  end)
end, {})

command("JavaMavenLifecycle", function()
  local root = current_root()
  jdm().get_project(root, function(project)
    if not project then return end
    vim.ui.select(project.modules, {
      prompt = "Module:",
      format_item = function(m) return m:ga() end,
    }, function(mod)
      if not mod then return end
      vim.ui.select(
        { "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy" },
        { prompt = "Phase:" },
        function(phase)
          if not phase then return end
          jdm().maven_runner.run(root, vim.fn.fnamemodify(mod.path, ":."), { phase }, {
            standalone = not mod.in_reactor,
            cwd = mod.path,
          })
        end)
    end)
  end)
end, {})

command("JavaDependencyTree", function()
  if jdm().dependency_tree_ui.is_open() then
    jdm().dependency_tree_ui.close()
    return
  end
  jdm().dependency_tree(current_root())
end, {})

command("JavaMavenGoal", function(args)
  local root = current_root()
  jdm().get_project(root, function(project)
    if not project then return end
    vim.ui.select(project.modules, {
      prompt = "Module:",
      format_item = function(m) return m:ga() end,
    }, function(mod)
      if not mod then return end
      jdm().maven_runner.run_goal(root, vim.fn.fnamemodify(mod.path, ":."), args.args, {
        standalone = not mod.in_reactor,
        cwd = mod.path,
      })
    end)
  end)
end, { nargs = 1 })

command("JavaMavenRun", function(args)
  local parts = vim.split(args.args, "%s+")
  local goal = parts[1]
  local module_rel = parts[2] or "."
  jdm().maven_runner.run_goal(current_root(), module_rel, goal)
end, { nargs = "+" })

command("JavaSessionPicker", function() jdm().session_picker.pick() end, {})
command("JavaSessionStatus", function() jdm().session_picker.status() end, {})
command("JavaSessionStop", function() jdm().session_picker.stop() end, {})
command("JavaSessionRestart", function() jdm().session_picker.restart() end, {})
command("JavaSessionRemove", function() jdm().session_picker.remove() end, {})
command("JavaSessionManage", function() jdm().session_picker.manage() end, {})
command("JavaSessionUI", function()
  if jdm().session_manager_ui.is_open() then
    jdm().session_manager_ui.close()
    return
  end
  jdm().session_manager_ui.open()
end, {})
command("JavaTestResults", function() jdm().test_results.open() end, {})
command("JavaProjectTree", function()
  jdm().get_project(current_root(), function(project)
    if project then jdm().project_tree.open(current_root(), project) end
  end)
end, {})
