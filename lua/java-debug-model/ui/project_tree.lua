-- Project -> Module -> SourceRoot -> files tree, replacing a raw filesystem
-- tree like neo-tree. Lazy-loaded per expand via vim.loop.fs_scandir, never
-- an eager full walk.
local panel_registry = require("java-debug-model.ui.panel_registry")

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

-- Chụp lại option soạn thảo "bình thường" NGAY LÚC MODULE NÀY ĐƯỢC NẠP (chạy đúng 1 lần, tại
-- đây - trước khi M.open() từng chạy nên trước khi cửa sổ tree có thể tồn tại) - KHÔNG được đọc
-- qua vim.o.xxx ở bên trong 1 hàm chạy khi cửa sổ TREE đang là cửa sổ hiện tại: với option
-- window-local (number/relativenumber/signcolumn/wrap/cursorline), vim.o đọc theo cửa sổ ĐANG
-- ACTIVE lúc gọi, không phải 1 "giá trị mặc định toàn cục" cố định - bug ban đầu chính là do đọc
-- vim.o.number ngay TRONG get_or_create_target_win(), lúc đó cửa sổ hiện tại chính là tree (vừa
-- bấm <CR> từ trong đó), nên đọc lại đúng false của tree rồi tự chép cái sai vào cái sai.
local DEFAULT_WINDOW_OPTS = {
  number = vim.o.number,
  relativenumber = vim.o.relativenumber,
  signcolumn = vim.o.signcolumn,
  foldcolumn = vim.o.foldcolumn,
  wrap = vim.o.wrap,
  cursorline = vim.o.cursorline,
}

local function scandir_children(dir, depth, parent)
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
        parent = parent, -- dùng để refresh đúng chỗ sau khi thêm/xoá (a/d)
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
  -- Chỉ hiện tên module (artifactId) - groupId đầy đủ (vn.longvan.computing:...) làm nhãn quá
  -- dài, mà mọi module trong project này đều CHUNG groupId nên nó chẳng phân biệt được gì thêm;
  -- groupId đầy đủ vẫn xem được qua tooltip hover hoặc mở rộng module (path hiện trong status).
  local node = {
    kind = "module",
    label = mod.artifact_id .. (mod.in_reactor and "" or "  [independent]"),
    path = mod.path,
    depth = depth,
    expanded = false,
    data = mod,
    children = nil,
  }
  return node
end

-- Highlight groups, linked to common built-ins so they follow whatever
-- colorscheme is active (gruvbox etc.) instead of hardcoding colors.
-- `default = true` lets a colorscheme/user override them without this
-- silently winning on every re-open.
local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "JavaTreeProjectIcon", { link = "Title", default = true })
  hl(0, "JavaTreeModuleIcon", { link = "Function", default = true })
  hl(0, "JavaTreeDepsIcon", { link = "Special", default = true })
  hl(0, "JavaTreeSourceRootIcon", { link = "String", default = true })
  hl(0, "JavaTreeSourceRootTestIcon", { link = "DiagnosticWarn", default = true })
  hl(0, "JavaTreeDirIcon", { link = "Directory", default = true })
  hl(0, "JavaTreeFileIcon", { link = "NonText", default = true })
  hl(0, "JavaTreeSiblingIcon", { link = "@keyword", default = true })
  hl(0, "JavaTreeTag", { link = "Comment", default = true })
  hl(0, "JavaTreePrefix", { link = "Comment", default = true })
  hl(0, "JavaTreeMarker", { link = "Comment", default = true })
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
        sr_kind = sr.kind, -- "main"|"test", used to pick the icon highlight
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
        kind = "file",
        is_sibling = dep.is_sibling,
        label = label,
        depth = node.depth + 1,
        expanded = false,
        children = {},
      })
    end
  elseif node.kind == "source_root" or node.kind == "dir" then
    node.children = scandir_children(node.path, node.depth + 1, node)
  end
end

local ICONS = { project = "", module = "󰏗", deps = "", source_root = "", dir = "", file = "" }

---@param node TreeNode
---@return string hl_group  icon highlight for this node
local function icon_hl(node)
  if node.kind == "source_root" and node.sr_kind == "test" then
    return "JavaTreeSourceRootTestIcon"
  end
  if node.kind == "file" and node.is_sibling then
    return "JavaTreeSiblingIcon"
  end
  return ({
    project = "JavaTreeProjectIcon",
    module = "JavaTreeModuleIcon",
    deps = "JavaTreeDepsIcon",
    source_root = "JavaTreeSourceRootIcon",
    dir = "JavaTreeDirIcon",
    file = "JavaTreeFileIcon",
  })[node.kind] or "JavaTreeFileIcon"
end

local ns = vim.api.nvim_create_namespace("java_debug_model_project_tree")

local function render()
  setup_highlights()
  local lines = {}
  state.line_map = {}
  -- {lnum (0-indexed), start_col, end_col, hl_group}
  local highlights = {}

  ---@param node TreeNode
  ---@param prefix string        accumulated "│  "/"   " from ancestors, "" for the root
  ---@param is_last boolean      is this the last child among its siblings
  local function walk(node, prefix, is_last)
    local is_root = node.depth == 0
    -- Tree connector, giống cấu trúc nvim-tree/neo-tree - không có cho node gốc "Project".
    local connector = is_root and "" or (is_last and "└─ " or "├─ ")

    local expandable = node.children ~= nil or node.kind == "module" or node.kind == "deps"
      or node.kind == "source_root" or node.kind == "dir"
    local marker
    if expandable then
      marker = node.expanded and "▾ " or "▸ "
    else
      marker = "  "
    end

    local icon = ICONS[node.kind] or ""
    local head = prefix .. connector
    local line = head .. marker .. icon .. " " .. node.label
    table.insert(lines, line)
    local lnum = #lines
    state.line_map[lnum] = node

    local row = lnum - 1
    if #head > 0 then
      table.insert(highlights, { row, 0, #head, "JavaTreePrefix" })
    end
    table.insert(highlights, { row, #head, #head + #marker, "JavaTreeMarker" })
    local icon_start = #head + #marker
    table.insert(highlights, { row, icon_start, icon_start + #icon, icon_hl(node) })

    -- Làm mờ phần tag cuối nhãn - "[independent pom]", "[compile]", "(sibling module)"...
    local label_start = icon_start + #icon + 1
    local tag_at = node.label:find("%s*[%[%(]")
    if tag_at then
      table.insert(highlights, { row, label_start + tag_at - 1, #line, "JavaTreeTag" })
    end

    if node.expanded and node.children then
      local child_prefix = prefix
      if not is_root then
        child_prefix = prefix .. (is_last and "   " or "│  ")
      end
      for i, child in ipairs(node.children) do
        walk(child, child_prefix, i == #node.children)
      end
    end
  end

  walk(state.tree, "", true)

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

---Mở liên tiếp qua chuỗi thư mục chỉ có ĐÚNG 1 thư mục con (không có gì khác) - kiểu cấu trúc
---package Java rất sâu (src/main/java/vn/longvan/computing/...) mà bấm "o" từng cấp một rất mất
---thời gian. Tự dừng lại ngay khi gặp: nhiều hơn 1 mục con, có file, hoặc thư mục rỗng.
---@param node TreeNode
local function auto_expand_chain(node)
  -- Luôn mở CHÍNH node đang bấm trước (module/deps/dir/source_root đều như nhau ở bước này) -
  -- chuỗi tự-mở-tiếp bên dưới chỉ áp dụng riêng cho dir/source_root, không được bỏ sót bước này.
  ensure_children(node)
  node.expanded = true

  local current = node
  while (current.kind == "dir" or current.kind == "source_root")
    and current.children and #current.children == 1 and current.children[1].kind == "dir" do
    current = current.children[1]
    ensure_children(current)
    current.expanded = true
  end
end

local function toggle_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local node = state.line_map[lnum]
  if not node then return end
  if node.kind == "file" then return end
  if node.expanded then
    node.expanded = false
  else
    auto_expand_chain(node)
  end
  render()
end

local function node_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[lnum]
end

---Buộc cửa sổ EDITING (không phải cửa sổ tree) về đúng option soạn thảo bình thường - giống
---hệt 1 cửa sổ neo-tree mở file ra, KHÔNG mang theo bất kỳ tinh chỉnh nào của riêng cửa sổ tree
---(number/signcolumn/foldcolumn tắt, xem M.open bên dưới). Gọi lại ở MỌI nhánh trả về của
---get_or_create_target_win() - kể cả khi TÁI SỬ DỤNG 1 cửa sổ đã có sẵn - để tự "chữa lành" liên
---tục thay vì chỉ vá đúng 1 lần lúc tạo mới: cửa sổ có thể đã bị nhiễm option từ TRƯỚC (vd tách
---split ngay từ trong cửa sổ tree ở 1 lần gọi trước đó, trước khi có hàm này), và session_target
---nhớ lại winid đó xuyên suốt phiên Neovim nên tự nó không bao giờ "khỏi" nếu chỉ vá lúc tạo.
---@param winid integer
local function restore_editor_window_options(winid)
  local wo = vim.wo[winid]
  wo.number = DEFAULT_WINDOW_OPTS.number
  wo.relativenumber = DEFAULT_WINDOW_OPTS.relativenumber
  wo.signcolumn = DEFAULT_WINDOW_OPTS.signcolumn
  wo.foldcolumn = DEFAULT_WINDOW_OPTS.foldcolumn
  wo.wrap = DEFAULT_WINDOW_OPTS.wrap
  wo.cursorline = DEFAULT_WINDOW_OPTS.cursorline
  wo.winfixwidth = false
end

---Finds (or creates) the window files should open into: a fixed "target"
---window, remembered across calls - not Vim's transient "previous window"
---(`wincmd p`), which drifts as soon as the user moves focus around and can
---end up pointing back at the tree's own window, silently replacing it.
---@return integer winid
local function get_or_create_target_win()
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid)
    and state.target_winid ~= state.tree_winid then
    restore_editor_window_options(state.target_winid)
    return state.target_winid
  end

  -- Fall back to any other non-floating window that isn't the tree itself OR one of this
  -- plugin's own OTHER utility panels (Maven Lifecycle, Dependency Tree, Session Manager...) -
  -- without the panel_registry check, a file opened from the tree could land INSIDE one of
  -- those instead of a real editor window (confirmed for real: it picked Session Manager's
  -- profile list).
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.tree_winid and not panel_registry.is_known(win)
        and vim.api.nvim_win_get_config(win).relative == "" then
      state.target_winid = win
      restore_editor_window_options(win)
      return win
    end
  end

  -- No other window exists (tree is the only one open): split one off.
  if state.tree_winid and vim.api.nvim_win_is_valid(state.tree_winid) then
    vim.api.nvim_set_current_win(state.tree_winid)
  end
  vim.cmd("vsplit")
  state.target_winid = vim.api.nvim_get_current_win()

  -- `:vsplit` from INSIDE the tree window inherits ALL of its window-local options - including
  -- number/signcolumn/foldcolumn/wrap turned off for the tree itself (see M.open below) - so
  -- without this, every file this window ever shows afterward (gd/Ctrl+B jumps included, since
  -- they land in whatever window is current, which by then is this one) would be silently
  -- missing line numbers too.
  restore_editor_window_options(state.target_winid)

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

---Thư mục thật (SourceRoot hoặc dir) sẽ chứa file/thư mục MỚI được tạo tại node đang đứng:
---đứng trên chính 1 dir/source_root thì tạo NGAY trong đó, đứng trên 1 file thì tạo cạnh nó
---(trong thư mục cha của file đó).
---@param node TreeNode
---@return TreeNode|nil
local function containing_dir_node(node)
  if node.kind == "dir" or node.kind == "source_root" then return node end
  if node.kind == "file" and node.parent then return node.parent end
  return nil
end

---Tạo path (mkdir -p thư mục cha nếu cần) và trả về đường dẫn tuyệt đối + có phải thư mục không.
---Tên kết thúc bằng "/" -> tạo thư mục, ngược lại tạo file rỗng.
---@param dir_path string
---@param name string
---@return string full_path
---@return boolean is_dir
local function create_entry(dir_path, name)
  local is_dir = name:sub(-1) == "/"
  local rel = is_dir and name:sub(1, -2) or name
  local full = dir_path .. "/" .. rel
  if is_dir then
    vim.fn.mkdir(full, "p")
  else
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    if vim.fn.filereadable(full) == 0 then
      vim.fn.writefile({}, full)
    end
  end
  return full, is_dir
end

local function refresh_dir_node(dir_node)
  dir_node.children = nil
  dir_node.expanded = true
  ensure_children(dir_node)
end

---Thêm file/thư mục mới, con của node đang đứng (hoặc cạnh file đang đứng - xem
---containing_dir_node). Kết thúc tên bằng "/" để tạo thư mục thay vì file.
local function add_at_cursor()
  local node = node_at_cursor()
  if not node then return end
  local dir_node = containing_dir_node(node)
  if not dir_node then
    vim.notify("java-debug-model: chỉ thêm được file/thư mục bên trong 1 source root/thư mục.",
      vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Tên mới (kết thúc bằng / để tạo thư mục): " }, function(name)
    if not name or name == "" then return end
    local full, is_dir = create_entry(dir_node.path, name)
    refresh_dir_node(dir_node)
    render()
    if not is_dir then
      local winid = get_or_create_target_win()
      vim.api.nvim_set_current_win(winid)
      vim.cmd("edit " .. vim.fn.fnameescape(full))
    end
  end)
end

---Xoá file/thư mục đang đứng (có xác nhận trước - hành động không thể hoàn tác).
local function delete_at_cursor()
  local node = node_at_cursor()
  if not node or (node.kind ~= "file" and node.kind ~= "dir") then
    vim.notify("java-debug-model: chỉ xoá được file/thư mục thật trên đĩa.", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Huỷ", "Xoá " .. node.label }, {
    prompt = "Xoá " .. (node.kind == "dir" and "thư mục" or "file") .. " " .. node.path .. " ?",
  }, function(choice)
    if not choice or choice == "Huỷ" then return end
    local ok = vim.fn.delete(node.path, node.kind == "dir" and "rf" or "") == 0
    if not ok then
      vim.notify("java-debug-model: xoá " .. node.path .. " thất bại.", vim.log.levels.ERROR)
      return
    end
    if node.parent then
      refresh_dir_node(node.parent)
    end
    render()
  end)
end

---@return boolean
function M.is_open()
  return state.tree_winid ~= nil and vim.api.nvim_win_is_valid(state.tree_winid)
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.tree_winid, false)
  end
  state.tree_winid = nil
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
    vim.keymap.set("n", "a", add_at_cursor, { buffer = state.bufnr, nowait = true, desc = "Thêm file/thư mục mới" })
    vim.keymap.set("n", "d", delete_at_cursor, { buffer = state.bufnr, nowait = true, desc = "Xoá file/thư mục" })
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = state.bufnr, nowait = true })
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
    if previous_win ~= state.tree_winid and not panel_registry.is_known(previous_win)
        and vim.api.nvim_win_get_config(previous_win).relative == "" then
      state.target_winid = previous_win
    end

    vim.cmd("topleft 40vsplit")
    vim.api.nvim_win_set_buf(0, state.bufnr)
    state.tree_winid = vim.api.nvim_get_current_win()
    local wo = vim.wo[state.tree_winid]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.wrap = false
    wo.cursorline = true
    wo.winfixwidth = true

    panel_registry.register(state.tree_winid)
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(state.tree_winid),
      once = true,
      callback = function() panel_registry.unregister(state.tree_winid) end,
    })
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
