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

- Neovim >= 0.10 (0.11+ for completion without a completion plugin)
- JDK 21+ and Maven on `PATH` (or a `./mvnw` wrapper in the project root)
- `curl` + `tar` for the one-time jdtls / lombok download

Plugin dependencies and the jdtls / java-debug / java-test bundles are installed automatically
(see Installation) - `:checkhealth java-debug-model` verifies all of it.

## Installation

Requirements on the machine: **JDK 21+** (jdtls itself runs on it - your projects can still
target older Java) and **Maven** (or a `mvnw` in the project). Everything else is automatic.

### lazy.nvim - one line

```lua
{ "nguyen-tan-huy/java-project-model" }
```

That's the whole spec. Open Neovim inside a Maven project and it works like IntelliJ:

- dependencies (nvim-jdtls, nvim-dap, nvim-dap-ui, nvim-nio, nui.nvim, mason.nvim,
  spring-boot.nvim) come from the plugin's own `lazy.lua`
- `setup()` runs by itself with the defaults
- the patched jdtls is downloaded once; java-debug-adapter + java-test are installed through
  Mason, and jdtls restarts on its own to pick them up; `lombok.jar` is found (Mason, `~/.m2`)
  or downloaded
- jdtls starts as soon as Neovim opens in a Maven project (`auto_attach`)
- code completion works even without a completion plugin (Neovim's own, popup while typing,
  `<C-Space>`/`<CR>`); with nvim-cmp / blink.cmp it simply shows up there
- JSF `.xhtml` files get Ctrl+B navigation and EL completion

Something missing? `:checkhealth java-debug-model` lists every requirement with the fix.

### Changing options

Only when you want something different from the defaults:

```lua
{
  "nguyen-tan-huy/java-project-model",
  opts = {
    active_profiles = { "dev" },          -- Maven profiles for every resolve
    -- open_j9_java_exec = "/path/to/openj9/bin/java",
    run_debug_keymaps = { run = "<leader>jr", debug = "<leader>jd" },
    native_completion = "auto",           -- true / false to force on / off
    bufferline_enabled = true,
    statusline_enabled = true,
    jsf_nav_enabled = true,
    jsf_completion_enabled = true,
  },
}
```

Every option is documented in `lua/java-debug-model/init.lua` (`M.opts`). To call `setup()`
yourself at a later point instead, set `vim.g.java_debug_model_auto_setup = false`.

Other plugin managers: install this repo plus the dependencies listed in `lazy.lua`;
`setup()` still runs by itself.

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
