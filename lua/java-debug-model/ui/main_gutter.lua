-- IntelliJ-style gutter "run" icons next to a `main` method AND a `@Test`-annotated method -
-- Neovim's legacy `sign_*` API, not extmarks, since signs are what actually render in the
-- gutter/sign column, the Neovim surface an IntelliJ gutter icon maps onto.
--
-- CLICKABLE (an explicit ask: "thêm icon nhấn để chạy debug ở main method và method @test" - add a
-- clickable icon to run-debug at a main method and an @Test method), reversing an EARLIER ask that
-- had dropped click-driven interaction across this plugin's UI in favor of keyboard-only use - see
-- ui/toolbar.lua's own doc comment, which went through the same reversal for its own Config/module
-- dropdowns. Via a per-window `'statuscolumn'` click region (see STATUSCOLUMN/apply_statuscolumn
-- near the bottom), NOT a global `<LeftMouse>` mapping - an earlier version of this used one, which
-- broke window-border mouse-drag resize entirely ("không resize panel bằng chuột được") by
-- intercepting the click before Neovim's own resize machinery ever saw it; see M.on_gutter_click's
-- own comment for the full story. `:JavaDebugMainUnderCursor` (M.run_under_cursor) remains as the
-- keyboard entry point.
-- Auto-creates (main method) / auto-saves (test method) a run profile the first time this exact
-- entry point is used, reusing it after that - IntelliJ's own gutter arrow does the same (main:
-- config_store.lua's DebugConfig via M.run_at_line below; test: test_profile_store.lua via
-- test.lua's own invoke(), already unconditionally persisted on every run/debug - "test cũng tạo
-- profile lưu lại luôn" was already true there before this file changed at all).
--
-- Per-buffer only (not whole-project) by design - IntelliJ's own gutter icons likewise only show
-- for currently open editor tabs, not files you haven't looked at yet. Main-method discovery is
-- `textDocument/documentSymbol` on the buffer's own jdtls client + this module's own module/file
-- -> FQCN mapping (mainclass.lua's own find_main_classes is workspace-wide and returns no line
-- number - not reusable here for gutter placement). Test-method discovery reuses the exact same
-- AST-backed command mainclass.lua's own find_test_methods uses
-- (`vscode.java.test.search.codelens`, falling back to `vscode.java.test.findTestTypesAndMethods`)
-- but scoped to JUST this buffer's own URI - one request per buffer, not mainclass.lua's own
-- whole-project multi-file walk, which would be far too expensive to run on every BufEnter/
-- BufWritePost.
local config_store = require("java-debug-model.config_store")
local active_config = require("java-debug-model.active_config")

local M = {}

local SIGN_GROUP = "java_debug_model_main_gutter"
local SIGN_MAIN = "JavaDebugModelMainRun"
local SIGN_TEST = "JavaDebugModelTestRun"
local sign_defined = false

---@type table<integer, table<integer, table>>  bufnr -> 1-based line -> entry
---entry is either { kind = "main", module: table, main_class: string }
---or { kind = "test", scope: "nearest_method"|"class" }
local entries_by_buf = {}

local function jdtls_client_for(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })[1]
end

local function supports_command(client, command)
  local provider = client.server_capabilities.executeCommandProvider
  local commands = type(provider) == "table" and provider.commands or {}
  return vim.list_contains(commands, command)
end

---Inverse of mainclass.lua's own fqcn_to_relpath - maps an absolute .java file back to its FQCN by
---stripping whichever of the module's main source roots it lives under. Self-contained (doesn't
---need the file's actual package declaration parsed) as long as the file sits under a real source
---root, which any file jdtls resolved a module for necessarily does.
---@param module table Module
---@param file string
---@return string|nil
local function fqcn_for_file(module, file)
  for _, sr in ipairs(module:main_source_roots()) do
    local prefix = sr.path .. "/"
    if vim.startswith(file, prefix) then
      local rel = file:sub(#prefix + 1):gsub("%.java$", "")
      return (rel:gsub("/", "."))
    end
  end
  return nil
end

---Recursively walks a hierarchical (DocumentSymbol, with `.children`) or flat (SymbolInformation,
---with `.location`) response looking for a method literally named "main" - name-only match (no
---modifier/param-type check against `public static void main(String[])`), same tradeoff
---mainclass.lua's own callers already accept elsewhere in this plugin for a per-buffer scan; the
---real validation happens server-side when java-debug actually launches it.
---
---jdtls's own documentSymbol response names a method symbol by its full signature, e.g.
---`"main(String[])"`, never the bare identifier `"main"` (confirmed for real against a live
---jdtls: `{ kind = 6, name = "main(String[])", ... }` - an exact `sym.name == "main"` check never
---matched anything, which is why no gutter sign ever appeared) - matched here with a `^main%(`
---prefix pattern instead.
---@param symbols table[]
---@param out {[integer]: true}  line (0-based) -> true, filled in place
local function collect_main_lines(symbols, out)
  for _, sym in ipairs(symbols or {}) do
    if sym.kind == 6 and sym.name:match("^main%(") then -- SymbolKind.Method
      local range = sym.selectionRange or sym.range or (sym.location and sym.location.range)
      if range then out[range.start.line] = true end
    end
    if sym.children then collect_main_lines(sym.children, out) end
  end
end

---Finds every @Test-annotated method (or the class itself, for a class-level lens) in JUST this
---one buffer, via the java-test bundle's own AST-backed codelens command - the exact command
---mainclass.lua's own find_test_methods uses, but a single request scoped to `bufnr`'s own URI
---instead of a whole-project multi-file walk (far cheaper - safe to run on every BufWritePost/
---BufEnter/LspAttach the way the main-method scan already does).
---
---A lens's `fullName` is `"pkg.Class"` for a class-level lens or `"pkg.Class#method"` for a
---method-level one (mirrors mainclass.lua's own name_parts split) - which of the two determines
---whether M.run_at_line below should invoke test.lua's "nearest_method" or "class" variant.
---
---The response is a TREE, not a flat list - a class-level lens carries its own methods nested
---under `.children` (confirmed against nvim-jdtls's OWN jdtls/dap.lua, whose
---get_method_lens_above_cursor recurses into `lens.children` the exact same way) - iterating only
---the top-level array here would silently miss every method-level lens, which is why NO test
---gutter sign ever appeared for an individual `@Test` method ("các method test chưa có icon chạy
---debug" - confirmed for real, together with the range-shape fallback below).
---@param lenses table[]
---@param out {[integer]: table}  0-based line -> { kind="test", scope=... }, filled in place
local function collect_test_lens_lines(lenses, out)
  for _, lens in ipairs(lenses or {}) do
    -- A lens's range lives at a DIFFERENT path depending on which of the two API shapes this
    -- jdtls/java-test bundle version returns (see vscode-java-test#1257) - `lens.location.range`
    -- for the legacy shape, `lens.range` directly for the newer one. nvim-jdtls's own
    -- `best_match_line` computation checks both the exact same way.
    local range = lens.location and lens.location.range or lens.range
    if range then
      local name_parts = vim.split(lens.fullName or "", "#")
      out[range.start.line] = {
        kind = "test",
        scope = name_parts[2] and "nearest_method" or "class",
      }
    end
    if lens.children then collect_test_lens_lines(lens.children, out) end
  end
end

---@param bufnr integer
---@param callback fun(out: {[integer]: table})  0-based line -> { kind="test", scope=... }
local function collect_test_lines(bufnr, callback)
  local client, command
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })) do
    if supports_command(c, "vscode.java.test.search.codelens") then
      client, command = c, "vscode.java.test.search.codelens"
      break
    elseif supports_command(c, "vscode.java.test.findTestTypesAndMethods") then
      client, command = c, "vscode.java.test.findTestTypesAndMethods"
      break
    end
  end
  if not client then callback({}) return end

  local uri = vim.uri_from_bufnr(bufnr)
  client:request("workspace/executeCommand", { command = command, arguments = { uri } }, function(err, result)
    if err or not result then callback({}) return end
    local out = {}
    collect_test_lens_lines(result, out)
    callback(out)
  end, bufnr)
end

local function clear_signs(bufnr)
  if entries_by_buf[bufnr] then
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
    entries_by_buf[bufnr] = nil
  end
end

---@param bufnr integer
---@param entries_by_line table<integer, table>  0-based line -> entry (kind="main"|"test")
local function place_signs(bufnr, entries_by_line)
  clear_signs(bufnr)
  local by_line1 = {}
  for lnum0, entry in pairs(entries_by_line) do
    local lnum1 = lnum0 + 1
    by_line1[lnum1] = entry
    local sign_name = entry.kind == "test" and SIGN_TEST or SIGN_MAIN
    pcall(vim.fn.sign_place, 0, SIGN_GROUP, sign_name, bufnr, { lnum = lnum1, priority = 20 })
  end
  entries_by_buf[bufnr] = by_line1
end

---Re-scans `bufnr` for `main` methods AND `@Test` methods, then (re)places gutter signs - safe to
---call repeatedly (on BufEnter/LspAttach/BufWritePost); a no-op while the Project model isn't
---resolved yet (first `mvn` run still in flight) rather than blocking or erroring.
---@param bufnr integer
function M.scan_buffer(bufnr)
  if vim.bo[bufnr].filetype ~= "java" then return end
  local client = jdtls_client_for(bufnr)
  if not client then return end

  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return end

  -- Lazy require to avoid a load-order cycle (init.lua requires this module at its own top
  -- level) - see toolbar.lua's own M.run_active for the same pattern/reasoning.
  local jdm = require("java-debug-model")
  local root = jdm.find_root(bufnr)
  jdm.get_project(root, function(project)
    if not project then return end
    local module = project:find_module_for_file(file)

    local main_entries = {}
    local test_entries = {}
    local pending = 2
    local function done()
      pending = pending - 1
      if pending == 0 and vim.api.nvim_buf_is_valid(bufnr) then
        local merged = {}
        for lnum0, e in pairs(main_entries) do merged[lnum0] = e end
        -- A test method's own line never coincides with a main method's own line in practice, but
        -- if it ever did, prefer whichever was already there rather than picking an order.
        for lnum0, e in pairs(test_entries) do
          if not merged[lnum0] then merged[lnum0] = e end
        end
        place_signs(bufnr, merged)
      end
    end

    if module then
      client:request("textDocument/documentSymbol",
        { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
        function(err, result)
          if not err and result then
            local main_lines = {}
            collect_main_lines(result, main_lines)
            for lnum0 in pairs(main_lines) do
              local main_class = fqcn_for_file(module, file)
              if main_class then
                main_entries[lnum0] = { kind = "main", module = module, main_class = main_class }
              end
            end
          end
          done()
        end, bufnr)
    else
      done()
    end

    collect_test_lines(bufnr, function(out)
      test_entries = out
      done()
    end)
  end)
end

---@param bufnr integer
---@param lnum integer  1-based
---@return table|nil
function M.entry_at(bufnr, lnum)
  local by_line = entries_by_buf[bufnr]
  return by_line and by_line[lnum]
end

---Runs (always via the debug adapter, matching IntelliJ's gutter arrow which also launches
---through the debugger's own machinery even for a plain "Run") the entry registered at
---`bufnr`/`lnum` - a main method creates a DebugConfig from mainclass defaults the first time this
---exact module+main_class combo is used, reuses the existing one after that (matching IntelliJ's
---own "creates a Run Configuration on first use, reuses it after" gutter behavior); a test method
---delegates straight to test.lua (which already unconditionally persists a test profile on every
---invocation - test_profile_store.lua, no separate "first time" branch needed there). Also marks a
---main entry's (possibly newly-created) config as the toolbar's active one and refreshes it.
---@param bufnr integer
---@param lnum integer  1-based
function M.run_at_line(bufnr, lnum)
  local entry = M.entry_at(bufnr, lnum)
  if not entry then return end

  if entry.kind == "test" then
    local test = require("java-debug-model.test")
    if entry.scope == "class" then
      test.debug_class()
    else
      test.debug_nearest_method()
    end
    return
  end

  local jdm = require("java-debug-model")
  local root = jdm.find_root(bufnr)

  local existing
  for _, cfg in ipairs(config_store.list(root)) do
    if cfg.module_path == entry.module.path and cfg.main_class == entry.main_class then
      existing = cfg
      break
    end
  end

  local cfg = existing
  if not cfg then
    cfg = config_store.default_from_main_class(entry.module, entry.main_class)
    config_store.add(root, cfg)
    vim.notify("java-debug-model: đã tạo debug config '" .. cfg.name .. "' từ main method", vim.log.levels.INFO)
  end

  active_config.set(root, cfg.name)
  local ok_toolbar, toolbar = pcall(require, "java-debug-model.ui.toolbar")
  if ok_toolbar then toolbar.refresh() end

  jdm.get_project(root, function(project)
    if not project then return end
    local dap = require("java-debug-model.dap")
    local session_id = dap.launch(project, cfg, { open_j9_java_exec = jdm.opts.open_j9_java_exec })
    -- "khi chạy mở panel session và focus vào session đang chạy" (running should open the Session
    -- Manager panel and focus the just-launched session) - same behavior ui/toolbar.lua's own
    -- M.run_active already gives <leader>jr/jd, now also true for a gutter-icon launch. dap.launch
    -- returns nil (after its own vim.notify) if the launch never actually happened - e.g. jdtls
    -- hasn't attached yet - nothing to focus in that case.
    if not session_id then return end
    local ok_session_ui, session_manager_ui = pcall(require, "java-debug-model.ui.session_manager")
    if ok_session_ui then session_manager_ui.focus_entry(session_id) end
  end, cfg.maven_profiles)
end

---Runs the entry (if any) registered at the CURRENT cursor line of `bufnr` - the keyboard entry
---point (`:JavaDebugMainUnderCursor`); M.on_gutter_click below shares the same "read the current
---cursor position back" shape for its own statuscolumn-click case, but calls M.run_at_line
---directly rather than through this - the difference only matters for the notify-on-miss below,
---which a real click on a placed sign obviously can't hit. No-op with a clear notify if the cursor
---isn't on a line with a registered entry.
---@param bufnr integer?  defaults to the current buffer
function M.run_under_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not M.entry_at(bufnr, lnum) then
    vim.notify(
      "java-debug-model: dòng hiện tại không có icon run/debug (▶ main hoặc ⏵ test ở sign column)",
      vim.log.levels.WARN)
    return
  end
  M.run_at_line(bufnr, lnum)
end

---Click handler for the gutter icon - invoked via a per-window `'statuscolumn'` click region (see
---STATUSCOLUMN/apply_statuscolumn below), NOT a global `<LeftMouse>` mapping. A `'statuscolumn'`
---click ALSO moves the cursor to the clicked line in the clicked window before Neovim calls this
---(same convention `'statusline'`/`'winbar'` click regions use), so reading it straight back via
---the current window/buffer/cursor is enough - no `getmousepos()` needed at all.
---
---An EARLIER version of this mapped `<LeftMouse>` globally instead - reported for real, TWICE:
---first "sao h chuyển con trỏ sang các panel bị chậm ấy" (switching focus to panels feels slow,
---from `getmousepos()`/`getwininfo()` running on literally every click in the editor), and then,
---worse, "không resize panel bằng chuột được" (can't resize panels with the mouse anymore) -
---mapping `<LeftMouse>` intercepts the click BEFORE Neovim's own window-BORDER drag-resize
---machinery gets to recognize "this click started on a separator", breaking mouse-drag resize
---entirely for every window, not just Java ones. `'statuscolumn'` click regions are a completely
---separate mechanism (same family as `'statusline'`/`'winbar'` `%@Func@` regions) that only ever
---fires for a click inside that specific column - it doesn't touch `<LeftMouse>` as a key at all,
---so window-border dragging is completely unaffected by it existing.
function M.on_gutter_click()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if M.entry_at(bufnr, lnum) then
    M.run_at_line(bufnr, lnum)
  end
end

local click_shim_installed = false

---Installs the Vimscript click shim once - `%@` needs a plain global function name it can call
---directly; `v:lua.require(...)` inside it is what actually reaches back into M.on_gutter_click.
local function install_click_shim()
  if click_shim_installed then return end
  click_shim_installed = true
  vim.cmd([[
    function! JavaDebugModelGutterClick(minwid, clicks, button, mods)
      call v:lua.require('java-debug-model.ui.main_gutter').on_gutter_click()
    endfunction
  ]])
end

-- Reproduces Neovim's OWN default gutter layout/appearance exactly (`:help 'statuscolumn'`'s own
-- documented expansion for when the option is empty: `%s%C%=%{v:relnum?v:relnum:v:lnum} `) - sign
-- column, fold column, right-aligned number - with just the sign portion (`%s`) wrapped in a click
-- region. This is what keeps every OTHER sign (gitsigns, diagnostics, ...), 'number'/
-- 'relativenumber', and 'foldcolumn' looking and behaving completely unchanged; only clicking
-- exactly on a sign now does something extra.
local STATUSCOLUMN = "%@JavaDebugModelGutterClick@%s%X%C%=%{v:relnum?v:relnum:v:lnum} "

---Applies (or clears) the custom statuscolumn for ONE window, based on whether it's CURRENTLY
---showing a java buffer - never touched for any other filetype, so this feature's blast radius is
---exactly "java buffers", not "every window in Neovim".
---@param winid integer
local function apply_statuscolumn(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local want = vim.bo[bufnr].filetype == "java" and STATUSCOLUMN or ""
  if vim.wo[winid].statuscolumn ~= want then
    vim.wo[winid].statuscolumn = want
  end
end

---Registers the autocmds that keep gutter signs in sync (LspAttach/BufWritePost) and the
---per-window statuscolumn click region - idempotent, safe to call from setup() more than once
---(e.g. across a `:luafile` reload in dev).
function M.setup()
  if not sign_defined then
    -- Bold + an explicit, vivid color (not just linked to a generic syntax group like the
    -- earlier "String"/"Function" links, which read as too subtle/easy to miss against a normal
    -- colorscheme) - an explicit ask: "icon cần làm to và đậm hơn nổi bật hơn" (the icon should be
    -- bigger and bolder, more prominent) - matching IntelliJ's own solid green run arrow / distinct
    -- test-runner icon rather than a plain thin ASCII character. `default = true` still lets a
    -- colorscheme or the user's own `:highlight` override win, same as every other highlight group
    -- in this plugin. A terminal cell's actual SIZE can't change per-glyph (no such thing as a
    -- bigger font just for one character) - "to hơn" is achieved by swapping the thin ">"/"T" for
    -- solid block glyphs ("▶"/"⏵") that fill more of their cell and read as heavier at a glance.
    vim.api.nvim_set_hl(0, "JavaDebugModelMainRun", { fg = "#50fa7b", bold = true, default = true })
    vim.api.nvim_set_hl(0, "JavaDebugModelTestRun", { fg = "#8be9fd", bold = true, default = true })
    vim.fn.sign_define(SIGN_MAIN, { text = "▶", texthl = "JavaDebugModelMainRun" })
    vim.fn.sign_define(SIGN_TEST, { text = "⏵", texthl = "JavaDebugModelTestRun" })
    sign_defined = true
  end

  local group = vim.api.nvim_create_augroup("JavaDebugModelMainGutter", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == "jdtls" then M.scan_buffer(args.buf) end
    end,
  })
  -- `pattern = "*.java"` matches on the buffer's FILE NAME, independent of whether 'filetype' has
  -- actually been assigned yet at the moment the event fires - relying on `vim.bo[bufnr].filetype`
  -- alone in scan_buffer would race BufEnter (ft detection can run after it) for a freshly opened
  -- buffer; FileType is included here as a third, race-free trigger for exactly that case.
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "FileType" }, {
    group = group,
    pattern = "*.java",
    callback = function(args) M.scan_buffer(args.buf) end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.java",
    callback = function(args) clear_signs(args.buf) end,
  })

  install_click_shim()
  -- Keeps the custom statuscolumn scoped to exactly the window(s) currently showing a java
  -- buffer - WinEnter/BufWinEnter covers switching into one, FileType covers ft detection
  -- finishing late on a freshly opened buffer, BufLeave covers switching AWAY (so the previous
  -- buffer's window falls back to Neovim's own default gutter instead of staying stuck on this
  -- one, e.g. after opening a non-java file in the same window).
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "FileType", "BufLeave" }, {
    group = group,
    callback = function() apply_statuscolumn(vim.api.nvim_get_current_win()) end,
  })

  -- setup() commonly runs from a `ft = "java"`-lazy-loaded plugin spec's own config() - i.e.
  -- exactly when the FIRST java buffer's FileType/BufEnter/LspAttach events have ALREADY fired,
  -- before this module's own autocmds existed to catch them (confirmed for real: a file opened
  -- directly on the command line, or already current when setup() ran, never got a gutter sign
  -- until manually re-entering the buffer). Scan every currently loaded .java buffer once, right
  -- now, to cover that case - scan_buffer itself is a safe no-op for one with no jdtls client yet.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "java" then
      M.scan_buffer(bufnr)
    end
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    apply_statuscolumn(winid)
  end
end

return M
