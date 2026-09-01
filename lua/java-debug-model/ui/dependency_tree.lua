-- Persistent panel showing `mvn dependency:tree` output for one module at a time - the same
-- "who pulled in library X, and which version actually won" tool IntelliJ's own Dependency
-- Tree/Diagram view provides for a Maven module, useful for debugging version-conflict bugs
-- (e.g. NoSuchMethodError/ClassNotFoundException from two libraries expecting different versions
-- of a shared transitive dependency). Backed by resolver/maven.lua's M.dependency_tree - see its
-- doc comment for why this re-invokes Maven instead of reusing the already-flattened classpath
-- the rest of this plugin (jdtls.lua's resolve_classpath) works off of.
--
-- Two things mvn's own raw tree text is bad at, that this module fixes:
--   1. Display width - mvn doesn't know (or care) how wide your terminal/split is, so a tree
--      with long GAVs truncates against a fixed-width split with wrap off. This sizes the panel
--      to the longest line actually printed, once per load, instead of a guessed fixed width.
--   2. Search - a tree with hundreds of transitive deps is not something `/pattern` alone makes
--      easy to navigate: a plain text search jumps to a match, but you're left staring at a bare
--      line with no idea which module/dependency chain pulled it in, because every ancestor line
--      above it may be scrolled off-screen. `f` here filters the WHOLE tree down to just the
--      matching lines plus their ancestor chain (computed from the tree's own indentation), so
--      the path to each match stays visible - same idea as IntelliJ's Dependency Analyzer search.
local maven = require("java-debug-model.resolver.maven")

local M = {}

local ns = vim.api.nvim_create_namespace("java_debug_model_dependency_tree")

local state = {
  bufnr = nil,
  winid = nil,
  module = nil,      -- Module currently shown
  profiles = nil,
  tree_lines = nil,  -- string[]  raw `mvn dependency:tree` output, unfiltered, no header
  query = nil,       -- string|nil  current filter (nil/"" = show everything)
}

---Computes a tree line's depth from its leading indentation, WITHOUT touching/reformatting the
---line itself (kept byte-for-byte as mvn printed it, so nothing about the GAV/conflict text can
---ever get corrupted by a parsing bug here). Each ancestor level is exactly one 3-char unit -
---either "|  " (an ancestor that still has later siblings) or "   " (one that doesn't) - followed
---by this line's own connector, "+- " or "\- " (also 3 chars). The root line has neither: depth 0.
---@param line string
---@return integer
local function line_depth(line)
  local depth = 0
  local rest = line
  while rest:sub(1, 3) == "|  " or rest:sub(1, 3) == "   " do
    rest = rest:sub(4)
    depth = depth + 1
  end
  if rest:sub(1, 3) == "+- " or rest:sub(1, 3) == "\\- " then
    depth = depth + 1
  end
  return depth
end

---Filters `tree_lines` down to every line matching `query` (case-insensitive substring) PLUS
---every ancestor of a match, computed via a running "last line seen at depth N" table scanned
---top-to-bottom - cheap (O(n * depth)) and needs no actual tree object, just the flat line list
---mvn already gives us.
---@param tree_lines string[]
---@param query string
---@return string[] kept lines, integer match_count
local function filtered_lines(tree_lines, query)
  local ql = query:lower()
  local depths, matched = {}, {}
  local match_count = 0
  for i, line in ipairs(tree_lines) do
    depths[i] = line_depth(line)
    if line:lower():find(ql, 1, true) then
      matched[i] = true
      match_count = match_count + 1
    end
  end

  local keep = {}
  local last_at_depth = {}
  for i, line in ipairs(tree_lines) do
    local d = depths[i]
    last_at_depth[d] = i
    for dd = d + 1, 64 do last_at_depth[dd] = nil end
    if matched[i] then
      keep[i] = true
      for dd = d - 1, 0, -1 do
        if last_at_depth[dd] then keep[last_at_depth[dd]] = true end
      end
    end
  end

  local out = {}
  for i, line in ipairs(tree_lines) do
    if keep[i] then table.insert(out, line) end
  end
  return out, match_count
end

---@param bufnr integer
---@param lines string[]
local function highlight(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for i, line in ipairs(lines) do
    if line:find("omitted for conflict", 1, true) then
      -- The version that LOST a conflict - exactly what a "why is the wrong version on my
      -- classpath" investigation is looking for, so it gets the loudest highlight.
      vim.api.nvim_buf_add_highlight(bufnr, ns, "DiagnosticError", i - 1, 0, -1)
    elseif line:find("omitted for duplicate", 1, true) then
      -- Harmless (same coordinate pulled in twice via different paths) - worth dimming so it
      -- doesn't compete visually with real conflicts above.
      vim.api.nvim_buf_add_highlight(bufnr, ns, "DiagnosticHint", i - 1, 0, -1)
    end
  end
end

---@param lines string[]
local function render_lines(lines)
  if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then return end
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  highlight(state.bufnr, lines)
end

---@return string
local function header(extra)
  local prof = (state.profiles and #state.profiles > 0)
      and (" [" .. table.concat(state.profiles, ",") .. "]") or ""
  local base = string.format("mvn dependency:tree -Dverbose - %s%s   (f: search, R: reload, q: đóng)",
    state.module:ga(), prof)
  return extra and (base .. "   " .. extra) or base
end

---Re-renders from state.tree_lines applying state.query (if any) - called after a fresh mvn
---result loads AND every time the filter itself changes, unlike the mvn call which only reruns
---on R/reopen.
local function apply_view()
  if not state.tree_lines then return end

  if not state.query or state.query == "" then
    local out = { header(), "" }
    vim.list_extend(out, state.tree_lines)
    render_lines(out)
    return
  end

  local kept, match_count = filtered_lines(state.tree_lines, state.query)
  local out = { header(string.format('lọc: "%s" (%d dòng khớp, x: xoá lọc)', state.query, match_count)), "" }
  if match_count == 0 then
    table.insert(out, "(không có dòng nào khớp)")
  else
    vim.list_extend(out, kept)
  end
  render_lines(out)

  -- Reuse Neovim's own search highlighting/navigation (n/N, hlsearch) on top of the filtered
  -- view instead of building custom "jump to next match" keymaps - the filter already narrowed
  -- the tree down to relevant branches, native search is enough to hop between the matches
  -- themselves within that.
  vim.fn.setreg("/", state.query)
  vim.o.hlsearch = true
end

---Prompts for a filter query and applies it. Empty input clears the filter (shows the full
---tree again) - pre-filled with the CURRENT filter so clearing it is just "select all, delete".
local function prompt_filter()
  vim.ui.input({ prompt = "Search dependency tree: ", default = state.query or "" }, function(input)
    if input == nil then return end -- cancelled (Esc) - leave filter as-is
    state.query = input ~= "" and input or nil
    apply_view()
  end)
end

local function clear_filter()
  if not state.query then return end
  state.query = nil
  apply_view()
end

---Sizes the panel to the longest line actually printed (capped so it never eats the whole
---screen) - fixes mvn's raw tree getting silently truncated against whatever fixed width a
---generic side panel would otherwise use. Computed once per fresh mvn result, not on every
---filter keystroke, so the window doesn't jump around while the user is typing a search.
---@param lines string[]
local function fit_width(lines)
  if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then return end
  local max_len = 60
  for _, line in ipairs(lines) do
    if #line > max_len then max_len = #line end
  end
  local width = math.min(max_len + 2, math.floor(vim.o.columns * 0.92))
  width = math.max(width, 80)
  vim.api.nvim_win_set_width(state.winid, width)
end

local function refresh()
  if not state.module then return end
  render_lines({ header(), "", "Đang chạy mvn dependency:tree ..." })
  local requested = state.module
  maven.dependency_tree(state.module.path, { profiles = state.profiles }, function(ok, lines, err)
    -- Panel may have been re-opened for a DIFFERENT module while this mvn call was still in
    -- flight - drop a stale result instead of overwriting what the user is now looking at.
    if state.module ~= requested then return end
    if not ok then
      render_lines({ header(), "", "Lỗi: " .. tostring(err) })
      vim.notify("java-debug-model: mvn dependency:tree thất bại - " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Drop trailing blank line(s) `vim.split` on a trailing "\n" leaves behind - would otherwise
    -- always inflate fit_width's scan (harmlessly) and show as visible empty lines at the tail.
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    state.tree_lines = lines
    state.query = nil
    fit_width(lines)
    apply_view()
  end)
end

---@return boolean
function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.winid, false)
  end
  state.winid = nil
end

---Opens (or re-focuses, re-running the command) the panel for `module`. Always re-runs
---dependency:tree on open - unlike the Project model's own resolver, there is no cache here:
---this is specifically a "check right now" debugging tool, and a stale conflict list would
---defeat the point.
---@param module table Module
---@param opts table?  { profiles?: string[] }
function M.open(module, opts)
  opts = opts or {}
  state.module = module
  state.profiles = opts.profiles

  if not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.api.nvim_buf_set_name(state.bufnr, "java-debug-model://dependency-tree")
    vim.keymap.set("n", "R", refresh, { buffer = state.bufnr, nowait = true, desc = "Reload dependency tree" })
    vim.keymap.set("n", "f", prompt_filter, { buffer = state.bufnr, nowait = true, desc = "Search dependency tree" })
    vim.keymap.set("n", "x", clear_filter, { buffer = state.bufnr, nowait = true, desc = "Clear search filter" })
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = state.bufnr, nowait = true })
  end

  if M.is_open() then
    vim.api.nvim_set_current_win(state.winid)
  else
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, state.bufnr)
    state.winid = vim.api.nvim_get_current_win()
    local wo = vim.wo[state.winid]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.wrap = false
    wo.cursorline = true
  end

  refresh()
end

return M
