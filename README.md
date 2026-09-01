# java-debug-model

A single Neovim plugin that recreates IntelliJ's **Project Model**,
**Run/Debug Configurations**, **Maven Lifecycle** tool window, and **JUnit
test runner** for Java/Maven projects - all in one installable plugin.

Unlike plugins that guess the project root from the nearest marker file,
`java-debug-model` resolves a real Module/SourceRoot/Dependency graph by
shelling out to Maven itself (`mvn help:effective-pom`,
`mvn dependency:build-classpath`) and parsing its output - property
interpolation, parent POM inheritance, profiles, and transitive dependencies
are Maven's job, never a hand-rolled parser's.

## Features

- Multi-module discovery via both the aggregator's `<modules>` **and** a
  filesystem scan, so independent/non-reactor sibling poms are found too,
  with coordinate-matching (`groupId:artifactId`) resolving sibling
  dependencies to live compiled output instead of a stale `.m2` jar.
- jdtls integration: correct `root_dir`/workspace folders per module,
  `java-debug` + `java-test` bundle wiring, incremental
  `java.projectConfiguration.update` reloads (no jdtls restart).
- Persisted, full-CRUD debug run configurations (name, VM/program args, env
  vars, working directory, Maven profiles), auto-created from any file with
  a detected `main` method.
- Multiple concurrent debug sessions (different modules/profiles) with a
  session picker for nvim-dap-ui focus switching.
- An OpenJ9 debug-target-JVM option, scoped to the debug target only.
- A persistent Maven-Lifecycle-style panel, scoped `-pl`/`-am`/`-amd` runs,
  a Skip Tests toggle, streamed into a real terminal buffer.
- Run/debug individual unit tests by method or class, with a pass/fail
  results panel and "rerun failed".
- A module-tree UI (`Project -> Module -> SourceRoot -> files`) with
  add/remove module commands, replacing a raw filesystem tree.

## Requirements

- Neovim >= 0.10
- [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls)
- [nvim-dap](https://github.com/mfussenegger/nvim-dap)
- [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui)
- Maven on `PATH` (or a `./mvnw` wrapper in the project root)
- The `java-debug` and `java-test` jdtls bundle jars (e.g. via Mason's
  `java-debug-adapter` and `java-test` packages)

## Installation (lazy.nvim)

```lua
{
  "nguyen-tan-huy/java-debug-model",
  dependencies = {
    "mfussenegger/nvim-jdtls",
    "mfussenegger/nvim-dap",
    "rcarriga/nvim-dap-ui",
  },
  config = function()
    require("java-debug-model").setup({
      -- Absolute paths/globs to the java-debug and java-test bundle jars,
      -- e.g. from Mason:
      jdtls_bundle_globs = {
        vim.fn.stdpath("data") .. "/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar",
        vim.fn.stdpath("data") .. "/mason/packages/java-test/extension/server/*.jar",
      },
      -- jdtls launch config merged into every start_or_attach() call
      -- (cmd, capabilities, on_attach, settings, etc. - see :h jdtls.start_or_attach)
      jdtls_config = {
        cmd = { "jdtls" },
      },
      active_profiles = {},       -- Maven profiles applied to every resolve
      -- open_j9_java_exec = "/path/to/openj9/bin/java",  -- optional, debug target only
      auto_attach = false,        -- true to auto-wire a FileType java autocmd
    })
  end,
}
```

`java-debug-model` does **not** ship its own `ftplugin/java.lua`. Either set
`opts.auto_attach = true`, or call it yourself:

```lua
-- ftplugin/java.lua
require("java-debug-model").start_or_attach(vim.api.nvim_get_current_buf())
```

## Commands

```
:JavaModelReload                    -- force full re-resolve, ignore cache
:JavaModelInspect                    -- print/inspect the current Project model
:JavaModelAddModule <path>            -- register a module manually
:JavaModelRemoveModule <name>          -- unregister a module (never deletes files)

:JavaDebugConfigList                    -- list saved DebugConfig entries
:JavaDebugConfigAdd                      -- create one via form
:JavaDebugConfigEdit <name>
:JavaDebugConfigRemove <name>
:JavaDebugConfigRun <name>
:JavaDebugConfigFromFile                  -- auto-create from current buffer's main method
:JavaDebugConfigScan                       -- whole-project main-method scan -> picker

:TestNearestMethod                          -- run test under cursor
:TestClass                                   -- run all tests in current class

:JavaMavenPanel                               -- open persistent Maven Lifecycle tree
:JavaMavenLifecycle                            -- one-off module+phase picker
:JavaMavenGoal <goal>                           -- run an arbitrary goal, module picker
:JavaMavenRun <goal> [module]                    -- non-interactive form for keymaps/scripts

:JavaSessionPicker                                -- switch focus between concurrent debug sessions
:JavaSessionStatus                                 -- print running/paused/stopped status
:JavaTestResults                                    -- open the last test run's pass/fail panel
:JavaProjectTree                                     -- open the module tree UI
```

## Architecture

```
lua/java-debug-model/
  init.lua               -- setup(opts), top-level API
  model.lua                -- Project/Module/SourceRoot/Dependency/Library structs
  resolver/maven.lua          -- mvn-backed resolution + discovery + coordinate matching
  watcher.lua                    -- pom.xml fs_event watch, debounce, cache, :JavaModelReload
  jdtls.lua                        -- root_dir/workspaceFolders/classpath feed into nvim-jdtls
  mainclass.lua                       -- LSP/bundle-based main-method + test-method discovery
  dap.lua                                -- dap.configurations.java generation, fresh port per launch
  config_store.lua                          -- CRUD + JSON persistence for DebugConfig
  session.lua                                  -- multi-session registry
  test.lua                                        -- wraps jdtls.dap test_nearest_method/test_class
  maven_runner.lua                                   -- async mvn/mvnw, -pl/-am/-amd scoping
  maven_output.lua                                      -- terminal-buffer output streaming
  ui/
    project_tree.lua, maven_panel.lua, session_picker.lua,
    test_results.lua, config_form.lua
plugin/java-debug-model.lua  -- user commands
```

## License

MIT
