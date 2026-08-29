-- Persistent Maven Lifecycle tool-window equivalent:
--   Maven Projects
--    +- module-a
--    |   +- Lifecycle
--    |       +- clean ... validate ... compile ... test ... package ... verify ... install ... site ... deploy
--   A "Skip Tests" toggle (T) shown in the header, applying -DskipTests to
--   subsequent runs via maven_runner.skip_tests.
local maven_runner = require("java-debug-model.maven_runner")

local M = {}

local PHASES = { "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy" }

local state = {
  bufnr = nil,
  win = nil,
  root = nil,
  project = nil,
  -- line number -> { module = Module, phase = string|nil }
  line_map = {},
}

local function header_lines()
  return {
    "Maven Projects" .. (maven_runner.skip_tests and "  [Skip Tests: ON]" or "  [Skip Tests: OFF]"),
    "(T: toggle skip tests, <CR>: run phase scoped to module, R: refresh)",
    "",
  }
end

local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
  local lines = header_lines()
  state.line_map = {}

  for _, mod in ipairs(state.project.modules) do
    table.insert(lines, mod:ga())
    table.insert(lines, "  Lifecycle")
    for _, phase in ipairs(PHASES) do
      table.insert(lines, "    " .. phase)
      state.line_map[#lines] = { module = mod, phase = phase }
    end
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
end

local function module_rel_path(mod)
  return vim.fn.fnamemodify(mod.path, ":." )
end

local function run_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state.line_map[lnum]
  if not entry then return end
  -- Maven's own lifecycle semantics already run every earlier phase in
  -- order, so <CR> on a phase never needs manual chaining.
  maven_runner.run(state.root, module_rel_path(entry.module), { entry.phase })
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
  end

  vim.cmd("topleft 40vsplit")
  vim.api.nvim_win_set_buf(0, state.bufnr)
  render()
end

---Refreshes the panel with the latest Project model (call after :JavaModelReload).
---@param project table? defaults to the last one passed to open()
function M.refresh(project)
  state.project = project or state.project
  render()
end

return M
