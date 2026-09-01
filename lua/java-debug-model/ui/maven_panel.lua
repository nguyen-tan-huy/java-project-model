-- Persistent Maven Lifecycle tool-window equivalent, cùng phong cách cây (đường kẻ, icon màu)
-- với ui/project_tree.lua:
--   Maven Projects
--    +- <reactor root>              (module cha - chứa các module KHAI trong <modules> của nó)
--    |   +- module-a
--    |   |   +- Lifecycle -> clean...deploy
--    |   +- module-b
--    |       +- Lifecycle -> clean...deploy
--    +- module-doc-lap [independent]  (không nằm trong reactor nào - anh em ngang hàng, không
--        +- Lifecycle -> clean...deploy   lồng dưới module cha vì chúng vốn KHÔNG thuộc reactor đó)
-- A "Skip Tests" toggle (T) shown in the header, applying -DskipTests to
-- subsequent runs via maven_runner.skip_tests.
local maven_runner = require("java-debug-model.maven_runner")

local M = {}

local PHASES = { "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy" }

local state = {
  bufnr = nil,
  win = nil,
  root = nil,
  project = nil,
  tree = nil,
  header_line_count = 0,
  -- line number -> TreeNode
  line_map = {},
}

local ICONS = { reactor = "󰉖", module = "󰏗", lifecycle = "", phase = "" }

local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "MavenPanelReactorIcon", { link = "Title", default = true })
  hl(0, "MavenPanelModuleIcon", { link = "Function", default = true })
  hl(0, "MavenPanelLifecycleIcon", { link = "Special", default = true })
  hl(0, "MavenPanelPhaseIcon", { link = "String", default = true })
  hl(0, "MavenPanelTag", { link = "Comment", default = true })
  hl(0, "MavenPanelPrefix", { link = "Comment", default = true })
  hl(0, "MavenPanelMarker", { link = "Comment", default = true })
end

local ICON_HL = {
  reactor = "MavenPanelReactorIcon",
  module = "MavenPanelModuleIcon",
  lifecycle = "MavenPanelLifecycleIcon",
  phase = "MavenPanelPhaseIcon",
}

local function build_module_node(mod)
  local phases = {}
  for _, phase in ipairs(PHASES) do
    table.insert(phases, { kind = "phase", label = phase, module = mod, phase = phase, expanded = false })
  end
  return {
    kind = "module",
    label = mod.artifact_id .. (mod.in_reactor and "" or "  [independent]"),
    module = mod,
    expanded = false,
    children = {
      { kind = "lifecycle", label = "Lifecycle", module = mod, expanded = true, children = phases },
    },
  }
end

---Lifecycle riêng cho CHÍNH module cha (reactor root) - build TOÀN BỘ reactor cùng lúc, không
---scope theo module nào (không "-pl", chạy thẳng ở root). Không gắn `module` (java-debug-model
---không giữ parent aggregator pom như 1 Module thật) - đánh dấu bằng `whole_reactor = true` để
---run_at_cursor biết chạy mvn kiểu nào.
local function build_reactor_lifecycle_node()
  local phases = {}
  for _, phase in ipairs(PHASES) do
    table.insert(phases, { kind = "phase", label = phase, whole_reactor = true, phase = phase, expanded = false })
  end
  return { kind = "lifecycle", label = "Lifecycle (toàn bộ reactor)", whole_reactor = true, expanded = false, children = phases }
end

---Builds the static tree: reactor-declared modules nested under a synthetic
---"reactor root" node (named after the root folder - java-debug-model's own
---model never keeps the parent aggregator pom as a Module, it only carries
---actual buildable modules, so there's no real Module object for this node),
---independent/"orphan" modules as flat top-level siblings next to it - they
---were never part of that reactor to begin with, so nesting them under it
---would misrepresent the actual Maven structure. The reactor node's own
---Lifecycle (build_reactor_lifecycle_node) builds everything at once.
---@param project table Project
local function build_tree(project)
  local reactor_children, independent_children = {}, {}
  for _, mod in ipairs(project.modules) do
    if mod.in_reactor then
      table.insert(reactor_children, build_module_node(mod))
    else
      table.insert(independent_children, build_module_node(mod))
    end
  end
  table.sort(reactor_children, function(a, b) return a.module.artifact_id < b.module.artifact_id end)
  table.sort(independent_children, function(a, b) return a.module.artifact_id < b.module.artifact_id end)

  local top = {}
  if #reactor_children > 0 then
    local node = {
      kind = "reactor",
      label = vim.fn.fnamemodify(state.root, ":t"),
      expanded = true,
      children = { build_reactor_lifecycle_node() },
    }
    vim.list_extend(node.children, reactor_children)
    table.insert(top, node)
  end
  vim.list_extend(top, independent_children)
  return top
end

local function header_lines()
  return {
    "Maven Projects" .. (maven_runner.skip_tests and "  [Skip Tests: ON]" or "  [Skip Tests: OFF]"),
    "(<CR>: chạy phase / mở-đóng node, T: bật-tắt skip tests, R: refresh, q: đóng)",
    "",
  }
end

local ns = vim.api.nvim_create_namespace("java_debug_model_maven_panel")

local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
  setup_highlights()

  local lines = header_lines()
  state.header_line_count = #lines
  state.line_map = {}
  local highlights = {}

  ---@param node table
  ---@param prefix string
  ---@param is_last boolean
  local function walk(node, prefix, is_last)
    local connector = is_last and "└─ " or "├─ "
    local expandable = node.children ~= nil and #node.children > 0
    local marker = node.kind == "phase" and "  " or ((node.expanded and "▾ ") or "▸ ")
    local icon = ICONS[node.kind] or ""
    local head = prefix .. connector
    local line = head .. marker .. icon .. " " .. node.label
    table.insert(lines, line)
    local lnum = #lines
    state.line_map[lnum] = node

    local row = lnum - 1
    table.insert(highlights, { row, 0, #head, "MavenPanelPrefix" })
    table.insert(highlights, { row, #head, #head + #marker, "MavenPanelMarker" })
    local icon_start = #head + #marker
    table.insert(highlights, { row, icon_start, icon_start + #icon, ICON_HL[node.kind] or "MavenPanelModuleIcon" })
    local label_start = icon_start + #icon + 1
    local tag_at = node.label:find("%s*%[")
    if tag_at then
      table.insert(highlights, { row, label_start + tag_at - 1, #line, "MavenPanelTag" })
    end

    if expandable and node.expanded then
      local child_prefix = prefix .. (is_last and "   " or "│  ")
      for i, child in ipairs(node.children) do
        walk(child, child_prefix, i == #node.children)
      end
    end
  end

  for i, top_node in ipairs(state.tree) do
    walk(top_node, "", i == #state.tree)
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

local function module_rel_path(mod)
  return vim.fn.fnamemodify(mod.path, ":.")
end

local function run_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state.line_map[lnum]
  if not entry then return end
  if entry.kind ~= "phase" then
    entry.expanded = not entry.expanded
    render()
    return
  end
  -- Maven's own lifecycle semantics already run every earlier phase in
  -- order, so <CR> on a phase never needs manual chaining.
  if entry.whole_reactor then
    -- Phase thuộc Lifecycle của CHÍNH module cha - build cả reactor, không "-pl" module nào cả.
    maven_runner.run(state.root, ".", { entry.phase }, { whole_reactor = true })
    return
  end
  local mod = entry.module
  maven_runner.run(state.root, module_rel_path(mod), { entry.phase }, {
    standalone = not mod.in_reactor,
    cwd = mod.path,
  })
end

local function toggle_skip_tests()
  maven_runner.toggle_skip_tests()
  render()
end

---Opens (or focuses, if already open) the persistent Maven Lifecycle panel
---for `root`'s current Project model.
---@param root string
---@param project table Project
function M.open(root, project)
  state.root = root
  state.project = project
  state.tree = build_tree(project)

  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    local winid = vim.fn.bufwinid(state.bufnr)
    if winid ~= -1 then
      vim.api.nvim_set_current_win(winid)
      render()
      return
    end
  else
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.api.nvim_buf_set_name(state.bufnr, "java-debug-model://maven-panel")
    vim.keymap.set("n", "<CR>", run_at_cursor, { buffer = state.bufnr, nowait = true })
    vim.keymap.set("n", "T", toggle_skip_tests, { buffer = state.bufnr, nowait = true })
    vim.keymap.set("n", "R", function() M.refresh() end, { buffer = state.bufnr, nowait = true })
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = state.bufnr, nowait = true })
  end

  vim.cmd("botright 40vsplit")
  vim.api.nvim_win_set_buf(0, state.bufnr)
  local wo = vim.wo[0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.cursorline = true
  wo.winfixwidth = true
  render()
end

---True if the panel's window is currently visible (not just its buffer
---existing - the buffer stays loaded, `bufhidden = "hide"`, after closing).
---@return boolean
function M.is_open()
  return state.bufnr ~= nil and vim.api.nvim_buf_is_valid(state.bufnr)
    and vim.fn.bufwinid(state.bufnr) ~= -1
end

---Closes the panel's window if open - the buffer/tree state stays intact
---(bufhidden = "hide"), so reopening via M.open() picks up right where it
---was, same as project_tree.lua's own window (not buffer) lifecycle.
function M.close()
  if not M.is_open() then return end
  vim.api.nvim_win_close(vim.fn.bufwinid(state.bufnr), false)
end

---Refreshes the panel with the latest Project model (call after :JavaModelReload),
---preserving which nodes were expanded where possible.
---@param project table? defaults to the last one passed to open()
function M.refresh(project)
  state.project = project or state.project
  if not state.project then return end

  local was_expanded = {}
  local function collect(nodes)
    for _, n in ipairs(nodes) do
      if n.module then was_expanded[n.kind .. ":" .. n.module.path] = n.expanded end
      if n.kind == "reactor" then was_expanded.reactor = n.expanded end
      if n.children then collect(n.children) end
    end
  end
  if state.tree then collect(state.tree) end

  state.tree = build_tree(state.project)

  local function restore(nodes)
    for _, n in ipairs(nodes) do
      if n.kind == "reactor" and was_expanded.reactor ~= nil then n.expanded = was_expanded.reactor end
      if n.module and was_expanded[n.kind .. ":" .. n.module.path] ~= nil then
        n.expanded = was_expanded[n.kind .. ":" .. n.module.path]
      end
      if n.children then restore(n.children) end
    end
  end
  restore(state.tree)

  render()
end

return M
