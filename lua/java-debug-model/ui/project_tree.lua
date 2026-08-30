-- Project -> Module -> SourceRoot -> files tree, replacing a raw filesystem
-- tree like neo-tree. Lazy-loaded per expand via vim.loop.fs_scandir, never
-- an eager full walk.
local M = {}

---@class TreeNode
---@field kind "project"|"module"|"deps"|"source_root"|"dir"|"file"
---@field label string
---@field path string|nil
---@field depth integer
---@field expanded boolean
---@field children TreeNode[]|nil   -- nil until first expand (lazy)
---@field data table|nil            -- e.g. the Module, for a "module" node

local state = {
  bufnr = nil,
  root = nil,
  project = nil,
  tree = nil,
  -- line number -> TreeNode, rebuilt on every render
  line_map = {},
  tree_winid = nil,    -- the tree's own window - files must NEVER open here
  target_winid = nil,  -- the window files open into, like neo-tree/nvim-tree
}

local function scandir_children(dir, depth)
  local entries = {}
  local handle = vim.loop.fs_scandir(dir)
  if not handle then return entries end
  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then break end
    if name ~= "target" and name ~= ".git" then
      table.insert(entries, {
        kind = ftype == "directory" and "dir" or "file",
        label = name,
        path = dir .. "/" .. name,
        depth = depth,
        expanded = false,
        children = nil,
      })
    end
  end
  table.sort(entries, function(a, b)
    if a.kind ~= b.kind then return a.kind == "dir" end
    return a.label < b.label
  end)
  return entries
end

local function build_module_node(mod, depth)
  local node = {
    kind = "module",
    label = mod:ga() .. (mod.in_reactor and "" or "  [independent pom]"),
    path = mod.path,
    depth = depth,
    expanded = false,
    data = mod,
    children = nil,
  }
  return node
end

local function build_tree(project)
  local root_node = {
    kind = "project", label = "Project", depth = 0, expanded = true, children = {},
  }
  for _, mod in ipairs(project.modules) do
    table.insert(root_node.children, build_module_node(mod, 1))
  end
  return root_node
end

---Lazily expands `node` in place, populating its `children` the first time.
local function ensure_children(node)
  if node.children ~= nil then return end
  if node.kind == "module" then
    local mod = node.data
    node.children = {}
    for _, sr in ipairs(mod.source_roots) do
      table.insert(node.children, {
        kind = "source_root",
        label = string.format("[%s] %s", sr.kind, vim.fn.fnamemodify(sr.path, ":t")),
        path = sr.path,
        depth = node.depth + 1,
        expanded = false,
        children = nil,
      })
    end
    table.insert(node.children, {
      kind = "deps",
      label = "Dependencies",
      depth = node.depth + 1,
      expanded = false,
      children = nil,
      data = mod,
    })
  elseif node.kind == "deps" then
    node.children = {}
    for _, dep in ipairs(node.data.dependencies) do
      local label
      if dep.is_sibling then
        label = string.format("%s:%s (sibling module)", dep.group_id, dep.artifact_id)
      else
        label = string.format("%s:%s:%s [%s]", dep.group_id, dep.artifact_id, dep.version, dep.scope)
      end
      table.insert(node.children, {
        kind = "file", label = label, depth = node.depth + 1, expanded = false, children = {},
      })
    end
  elseif node.kind == "source_root" or node.kind == "dir" then
    node.children = scandir_children(node.path, node.depth + 1)
  end
end

local ICONS = { project = "", module = "󰏗", deps = "", source_root = "", dir = "", file = "" }

local function render()
  local lines = {}
  state.line_map = {}

  local function walk(node)
    local indent = string.rep("  ", node.depth)
    local marker = ""
    if node.children ~= nil or node.kind == "module" or node.kind == "deps" or node.kind == "source_root"
      or node.kind == "dir" then
      marker = node.expanded and "v " or "> "
    end
    if node.kind == "file" then marker = "  " end
    table.insert(lines, indent .. marker .. (ICONS[node.kind] or "") .. " " .. node.label)
    state.line_map[#lines] = node

    if node.expanded and node.children then
      for _, child in ipairs(node.children) do
        walk(child)
      end
    end
  end

  walk(state.tree)

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
end

local function toggle_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local node = state.line_map[lnum]
  if not node then return end
  if node.kind == "file" then return end
  ensure_children(node)
  node.expanded = not node.expanded
  render()
end

local function node_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[lnum]
end

---Finds (or creates) the window files should open into: a fixed "target"
---window, remembered across calls - not Vim's transient "previous window"
---(`wincmd p`), which drifts as soon as the user moves focus around and can
---end up pointing back at the tree's own window, silently replacing it.
---@return integer winid
local function get_or_create_target_win()
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid)
    and state.target_winid ~= state.tree_winid then
    return state.target_winid
  end

  -- Fall back to any other non-floating window that isn't the tree itself.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.tree_winid and vim.api.nvim_win_get_config(win).relative == "" then
      state.target_winid = win
      return win
    end
  end

  -- No other window exists (tree is the only one open): split one off.
  if state.tree_winid and vim.api.nvim_win_is_valid(state.tree_winid) then
    vim.api.nvim_set_current_win(state.tree_winid)
  end
  vim.cmd("vsplit")
  state.target_winid = vim.api.nvim_get_current_win()
  return state.target_winid
end

local function open_file_at_cursor()
  local node = node_at_cursor()
  if node and node.kind == "file" and node.path then
    local winid = get_or_create_target_win()
    vim.api.nvim_set_current_win(winid)
    vim.cmd("edit " .. vim.fn.fnameescape(node.path))
  elseif node then
    toggle_at_cursor()
  end
end

---Opens (or focuses) the project tree window for `root`'s Project model.
---@param root string
---@param project table Project
function M.open(root, project)
  state.root = root
  state.project = project
  state.tree = build_tree(project)

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.api.nvim_buf_set_name(state.bufnr, "java-debug-model://project-tree")
    vim.keymap.set("n", "<CR>", open_file_at_cursor, { buffer = state.bufnr, nowait = true })
    vim.keymap.set("n", "o", toggle_at_cursor, { buffer = state.bufnr, nowait = true })
  end

  local winid = vim.fn.bufwinid(state.bufnr)
  if winid ~= -1 then
    state.tree_winid = winid
    vim.api.nvim_set_current_win(winid)
  else
    -- Remember whatever window was active before opening the tree as the
    -- "target" files should open into - this is what makes <CR> reliably
    -- reuse that same editing window instead of Vim's transient "previous
    -- window" (`wincmd p`), which drifts as focus moves around and can end
    -- up pointing back at the tree itself.
    local previous_win = vim.api.nvim_get_current_win()
    if previous_win ~= state.tree_winid and vim.api.nvim_win_get_config(previous_win).relative == "" then
      state.target_winid = previous_win
    end

    vim.cmd("topleft 40vsplit")
    vim.api.nvim_win_set_buf(0, state.bufnr)
    state.tree_winid = vim.api.nvim_get_current_win()
  end
  render()
end

---Refreshes the tree after a model reload / add / remove module, preserving
---which nodes were expanded where possible (matched by path).
---@param project table
function M.refresh(project)
  local was_expanded = {}
  local function collect(node)
    if node.path then was_expanded[node.path] = node.expanded end
    if node.children then
      for _, c in ipairs(node.children) do collect(c) end
    end
  end
  if state.tree then collect(state.tree) end

  state.project = project
  state.tree = build_tree(project)

  local function restore(node)
    if node.path and was_expanded[node.path] then
      ensure_children(node)
      node.expanded = true
    end
    if node.children then
      for _, c in ipairs(node.children) do restore(c) end
    end
  end
  restore(state.tree)

  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    render()
  end
end

return M
