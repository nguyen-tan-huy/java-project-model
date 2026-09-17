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
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) - optional, only needed for the
  IntelliJ-style Config Panel (`:JavaConfigPanel`) and toolbar (`:JavaToolbar`). Every other
  feature, including `:JavaDebugConfigAdd`'s plain prompt-based form, works without it.

## Installation (lazy.nvim)

```lua
{
  "nguyen-tan-huy/java-debug-model",
  dependencies = {
    "mfussenegger/nvim-jdtls",
    "mfussenegger/nvim-dap",
    "rcarriga/nvim-dap-ui",
    "MunifTanjim/nui.nvim", -- optional: powers :JavaConfigPanel and :JavaToolbar
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
      auto_attach = false,          -- true to attach jdtls immediately if cwd already resolves
                                     -- a Maven root (no need to open a .java file first), plus
                                     -- a FileType java autocmd as a fallback for when it doesn't
      bufferline_enabled = true,    -- adds an open-buffer tab-list row to the toolbar's own
                                     -- bar (see below) - plain text, no Config name repeated
                                     -- there. Set to false to drop that row, e.g. if you run a
                                     -- separate bufferline plugin instead.
      toolbar_auto_open = true,     -- open the toolbar - a single docked bar with "Config:
                                     -- <name>" on its own (taller) row, plus the tab-list row
                                     -- right below it when bufferline_enabled - on the first
                                     -- .java buffer per root; it's a real docked window, so it
                                     -- does NOT reopen itself across a restart on its own
                                     -- otherwise
      restore_layout_on_start = true, -- reopen whatever files/panels were open last time
                                       -- (see "Project layout persistence" below)
      run_debug_keymaps = { run = "<leader>jr", debug = "<leader>jd", select = "<leader>jc" },
        -- GLOBAL keymaps for Run/Debug/select-active-config, work from any window/buffer -
        -- not just while the toolbar's own split is focused (its r/d/c keymaps only fire
        -- while that specific window is current). Set any field (or the whole table) to false.
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

:JavaConfigPanel                            -- IntelliJ "Edit Configurations" equivalent: nui.nvim
                                             -- list+form panel over the same DebugConfig data,
                                             -- keyboard-only (list: a/d to add/delete, <CR> to
                                             -- select; form: a REAL editable buffer - move the
                                             -- cursor to a field and edit it with normal Vim
                                             -- commands, <CR> in insert mode confirms instead of
                                             -- inserting a newline; Module/JDK stay <CR> pickers)
:JavaToolbar                                -- toggle the docked bar: "Config: <name>",
                                             -- right-aligned, plus an open-buffer tab-list row
                                             -- right below it (opts.bufferline_enabled) - both in
                                             -- the SAME window, no gap between them. c/<CR> on the
                                             -- Config row opens the picker, or <leader>jc/
                                             -- :JavaConfigSelect from anywhere. No Run/Debug
                                             -- buttons here - use <leader>jr/<leader>jd (opts.
                                             -- run_debug_keymaps) or the commands below
:JavaToolbarRun                             -- run (no breakpoints) the active config directly
:JavaToolbarDebug                           -- debug the active config directly
:JavaConfigSelect [name]                    -- set the toolbar's active Run/Debug Configuration
                                             -- (prompts via vim.ui.select when name is omitted)
:JavaDebugMainUnderCursor                   -- debug the `main` method the cursor is on (see the
                                             -- ">" gutter sign) - auto-creates a DebugConfig the
                                             -- first time, reuses it after that

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

:JavaLayoutSave                                       -- save which files/panels are open right now
:JavaLayoutRestore                                     -- reopen whatever was last saved (bypasses
                                                        -- the once-per-session guard restore_layout_
                                                        -- on_start's automatic restore uses)
```

## Project layout persistence

With `restore_layout_on_start = true` (the default), `layout_state.lua` remembers, per project
root, which files were open (and which one was focused) and which of this plugin's own panels
(Project Tree, Maven Panel, Session Manager, Toolbar) were up - saved automatically on
`VimLeavePre`, restored automatically the first time that root is resolved in a new Neovim
session. This is scoped to what the plugin itself owns: the file *buffer list* and its own panel
layout, not exact per-tab/per-window geometry the way `:mksession` handles a whole session - pair
it with a session plugin (or `:mksession`) if you want that too. `:JavaLayoutSave`/
`:JavaLayoutRestore` trigger either half by hand.

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
