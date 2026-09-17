-- Persists "what was open" for a project root - which of this plugin's own panels (Project Tree,
-- Maven Panel, Session Manager, Toolbar) were up, and which files were open in the editing area -
-- so the NEXT time Neovim starts in that project it comes back the way you left it instead of a
-- blank slate. Same JSON-file-per-root persistence pattern as maven_jdk.lua/active_config.lua.
--
-- Scope, deliberately: this restores the file BUFFER LIST (which files are available to switch
-- to, with the one you had focused shown first) and this plugin's own panel layout - it does NOT
-- attempt exact per-tab/per-window geometry the way `:mksession` does for a whole Neovim session.
-- A dedicated session plugin (or `:mksession`) is the right tool for that; this one only owns what
-- IT manages (the panels) plus a practical "which files was I looking at" restore.
local M = {}

local function store_path(root)
  return root .. "/.nvim/java-debug-model/layout-state.json"
end

---@param root string
---@return table
local function capture(root)
  local project_tree = require("java-debug-model.ui.project_tree")
  local maven_panel = require("java-debug-model.ui.maven_panel")
  local session_manager_ui = require("java-debug-model.ui.session_manager")
  local toolbar = require("java-debug-model.ui.toolbar")

  local files, seen = {}, {}
  local current_file
  local current_bufnr = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted and vim.bo[bufnr].buftype == "" then
      local name = vim.api.nvim_buf_get_name(bufnr)
      -- root .. "/" prefix match (not just startswith root) so a sibling directory that happens
      -- to share root as a string prefix (e.g. root "foo" vs "foo-bar") is never included.
      if name ~= "" and vim.startswith(name, root .. "/") and not seen[name] then
        seen[name] = true
        table.insert(files, name)
        if bufnr == current_bufnr then current_file = name end
      end
    end
  end

  return {
    project_tree = project_tree.is_open(),
    maven_panel = maven_panel.is_open(),
    session_manager = session_manager_ui.is_open(),
    toolbar = toolbar.is_open(),
    files = files,
    current_file = current_file,
  }
end

---@param root string
function M.save(root)
  if not root then return end
  local ok, encoded = pcall(vim.json.encode, capture(root))
  if not ok then return end
  local path = store_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(encoded, "\n"), path)
end

---@param root string
---@return table|nil
local function load(root)
  local path = store_path(root)
  if vim.fn.filereadable(path) == 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

---@type table<string, boolean>  root -> already attempted a restore this Neovim session
local restored_for = {}

---Reopens whatever files/panels were saved for `root` - files first (so the editing area is
---populated before any panel docks around it, matching how a user would naturally open things by
---hand), then this plugin's own panels in the SAME fixed order init.lua's reset_layout() uses
---(tree, then session manager, then maven panel, then toolbar last) so their window geometry comes
---out the same way every time - see reset_layout's own comment for why that particular order
---matters (`topleft`/`botright`-style splits operate at the whole-tabpage level, so opening them
---in a different order can squash one into a sliver, and the toolbar specifically must dock LAST
---to span the full width - see ui/toolbar.lua's own M.redock comment). At most once per root per
---Neovim session unless `force` - safe to call from both a `FileType java` autocmd AND setup()'s
---own immediate cwd-based resolve without double-restoring.
---@param root string
---@param force boolean?  bypass the once-per-session guard (used by :JavaLayoutRestore)
function M.restore(root, force)
  if restored_for[root] and not force then return end
  restored_for[root] = true

  local state = load(root)
  if not state then return end

  for _, file in ipairs(state.files or {}) do
    if file ~= state.current_file and vim.fn.filereadable(file) == 1 then
      pcall(vim.cmd, "badd " .. vim.fn.fnameescape(file)) -- registers the buffer only, no window
    end
  end
  if state.current_file and vim.fn.filereadable(state.current_file) == 1 then
    -- `:edit` always targets the CURRENT window - if that happened to be one of this plugin's
    -- own panels (e.g. :JavaLayoutRestore run while focused on the Session Manager), the file
    -- landed INSIDE it (confirmed for real). Route through the same safe-window pick
    -- project_tree.lua's own file-opening already uses.
    local panel_registry = require("java-debug-model.ui.panel_registry")
    vim.api.nvim_set_current_win(panel_registry.safe_edit_win())
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(state.current_file))
  end

  local jdm = require("java-debug-model")
  local project_tree = require("java-debug-model.ui.project_tree")
  local maven_panel = require("java-debug-model.ui.maven_panel")
  local session_manager_ui = require("java-debug-model.ui.session_manager")
  local toolbar = require("java-debug-model.ui.toolbar")

  local function reopen_rest(project)
    if state.session_manager then session_manager_ui.open() end
    if state.maven_panel and project then maven_panel.open(root, project) end
    if state.toolbar then toolbar.open(root) end
  end

  if state.project_tree or state.maven_panel then
    jdm.get_project(root, function(project)
      if project and state.project_tree then project_tree.open(root, project) end
      reopen_rest(project)
    end)
  else
    reopen_rest(nil)
  end
end

return M
