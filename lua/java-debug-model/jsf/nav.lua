-- IntelliJ Ctrl+B for JSF Facelets views: `.xhtml` has no LSP server in this setup, so unlike
-- ../nav.lua (a thin keymap layer over jdtls) this is a self-contained navigation layer:
--   * EL reference -> the Java member it names, at ANY depth and through page variables:
--     #{bean.prop}, #{bean.action()}, #{bean.address.country.name}, #{bean.getAddress().city},
--     #{bean['prop']}, #{bean.items[0].label}, #{item.label} inside <ui:repeat var="item">,
--     inherited members (see jsf/resolve.lua). Cursor on a page variable itself -> its var=
--     declaration; on a bean name -> the bean class.
--   * `<ui:include src>` / `<ui:composition|ui:decorate template>` / `<c:import url>` -> that file
--   * `<cc:tag` of a composite-component namespace -> resources/<library>/<tag>.xhtml
--   * reverse: Java member under the cursor -> every `.xhtml` EL usage, in the quickfix list
-- Expressions and tags may span several lines.
local el = require("java-debug-model.jsf.el")
local bean_index = require("java-debug-model.jsf.bean_index")
local resolve = require("java-debug-model.jsf.resolve")

local M = {}


local function jdm()
  return require("java-debug-model")
end

local function notify(msg, level)
  vim.notify("java-debug-model: " .. msg, level or vim.log.levels.WARN)
end

local function jdtls_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })[1]
end

---Resolved Project for `root` - the cached one when available (no `mvn` round-trip), else a
---fresh resolve.
local function with_project(root, callback)
  local project = jdm().get_cached_project(root)
  if project then
    callback(project)
  else
    jdm().get_project(root, callback)
  end
end

---Directories a module's Facelets views are served from: the WAR layout's src/main/webapp and
---the JAR layout's META-INF/resources (Servlet 3.0 resources-in-jar - what JoinFaces/Spring Boot
---JSF projects use). Only the ones that actually exist.
---@param mod table  Module
---@return string[]
function M.webapp_roots(mod)
  local roots = {}
  for _, rel in ipairs({ "/src/main/webapp", "/src/main/resources/META-INF/resources" }) do
    local dir = mod.content_root .. rel
    if vim.fn.isdirectory(dir) == 1 then table.insert(roots, dir) end
  end
  return roots
end

---Webapp roots of the module owning `file` first, then every other module's.
local function ordered_webapp_roots(project, file)
  local owner = project and project:find_module_for_file(file)
  local roots, seen = {}, {}
  local function add(mod)
    for _, r in ipairs(M.webapp_roots(mod)) do
      if not seen[r] then seen[r] = true table.insert(roots, r) end
    end
  end
  if owner then add(owner) end
  for _, mod in ipairs(project and project.modules or {}) do add(mod) end
  return roots
end

local function edit(file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
end

-- ── include / template / composite component ────────────────────────────────────────────────

---@param rel_path string  as written in the attribute
---@param file string      the .xhtml being edited
local function resolve_include(rel_path, file)
  if rel_path:find("[#$]{") then
    notify("đường dẫn include là biểu thức EL (" .. rel_path .. "), không resolve tĩnh được.")
    return
  end
  local path = rel_path:gsub("[?#].*$", "")
  if not vim.startswith(path, "/") then
    local candidate = vim.fs.normalize(vim.fn.fnamemodify(file, ":h") .. "/" .. path)
    if vim.fn.filereadable(candidate) == 1 then
      edit(candidate)
      return
    end
  end
  with_project(jdm().find_root(0), function(project)
    for _, root in ipairs(ordered_webapp_roots(project, file)) do
      local candidate = vim.fs.normalize(root .. "/" .. path:gsub("^/", ""))
      if vim.fn.filereadable(candidate) == 1 then
        edit(candidate)
        return
      end
    end
    notify("không tìm thấy file: " .. rel_path)
  end)
end

local function resolve_composite(ref, file)
  with_project(jdm().find_root(0), function(project)
    for _, root in ipairs(ordered_webapp_roots(project, file)) do
      local candidate = string.format("%s/resources/%s/%s.xhtml", root, ref.library, ref.tag)
      if vim.fn.filereadable(candidate) == 1 then
        edit(candidate)
        return
      end
    end
    notify(string.format("không tìm thấy composite component resources/%s/%s.xhtml", ref.library, ref.tag))
  end)
end

-- ── jumping to Java ─────────────────────────────────────────────────────────────────────────

---Polls (non-blocking) until jdtls attaches to `bufnr`; callback(client|nil) after `timeout_ms`.
---Only used when no jdtls client runs yet at all: opening the bean file is what starts it (the
---FileType java autocmd - opts.auto_attach / the user's own ftplugin).
local function wait_for_jdtls(bufnr, timeout_ms, callback)
  local waited = 0
  local timer = vim.uv.new_timer()
  timer:start(0, 100, vim.schedule_wrap(function()
    local client = vim.api.nvim_buf_is_valid(bufnr) and jdtls_client(bufnr) or nil
    waited = waited + 100
    if client or waited >= timeout_ms or not vim.api.nvim_buf_is_valid(bufnr) then
      if not timer:is_closing() then
        timer:stop()
        timer:close()
        callback(client)
      end
    end
  end))
end

---Vim regex matching the DECLARATION of member `name` (cursor lands on the name) - a line that
---starts with annotations/modifiers/a type, then whitespace, then the name. Never a call site
---(`getComputing().getName()`, `return getX()`, `x = y`), which is what a bare `\<getX\s*(`
---used to land on first.
---@param name string
---@param is_method boolean
function M.declaration_pattern(name, is_method)
  local decl = [[^\s*\%(\%(return\|throw\|new\|else\|case\)\>\)\@!\%(@\w\+\%(([^)]*)\)\=\s\+\)*]]
    .. [=[[A-Za-z_][A-Za-z0-9_<>,.?[\] ]*\s\zs]=]
  return decl .. name .. (is_method and [[\s*(]] or [[\s*\%([;=,]\|$\)]])
end

---Last-resort fallback with no jdtls at all: plain regex search for a direct member of the bean
---class, in the (now current) bean buffer. Only meaningful for #{bean.member}.
local function text_search(parsed, class_name)
  local patterns = {}
  if parsed.target == 0 then
    table.insert(patterns, [[\<class\s\+\zs]] .. class_name .. [[\>]])
  else
    for _, cand in ipairs(resolve.member_candidates(parsed.chain[parsed.target])) do
      table.insert(patterns, M.declaration_pattern(cand.name, cand.kinds[vim.lsp.protocol.SymbolKind.Method]))
    end
  end
  for _, pat in ipairs(patterns) do
    vim.fn.cursor(1, 1)
    if vim.fn.search(pat, "cW") > 0 then return true end
  end
  return false
end

-- "jdtls" | "text" | "page": how the last EL jump was resolved (type-aware via jdtls, the no-jdtls
-- text-search fallback, or a page variable's own declaration) - lets smoke_jsf_nav.lua assert
-- the LSP path was really taken.
M.last_jump_via = nil

-- How long to wait for jdtls to attach when no jdtls client runs at all yet. Generous since a
-- cold jdtls can take a while.
M.jdtls_wait_ms = 10000

---@param ctx table    resolve ctx minus `client`
---@param client table jdtls client
---@param parsed table from el.parse_el
---@param pos integer  cursor offset in ctx.text
---@param xhtml_win integer  window the .xhtml page is shown in (page-variable jumps stay there)
local function resolve_and_jump(ctx, client, parsed, pos, xhtml_win)
  ctx.client = client
  resolve.run(function()
    local target = resolve.resolve(ctx, parsed, pos)
    if target.kind == "binding" then
      local row, col = el.offset_to_pos(ctx.text, target.binding.decl)
      if vim.api.nvim_win_is_valid(xhtml_win) then vim.api.nvim_set_current_win(xhtml_win) end
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { row, col })
      M.last_jump_via = "page"
      return
    end
    local range = target.sym and target.sym.selection_range
      or { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }
    M.last_jump_via = "jdtls"
    vim.lsp.util.show_document({ uri = vim.uri_from_bufnr(target.buf), range = range },
      client.offset_encoding, { focus = true })
  end, function(msg) notify(msg) end)
end

-- ── Ctrl+B entry point ──────────────────────────────────────────────────────────────────────

---IntelliJ Ctrl+B on an .xhtml buffer.
function M.go_to_declaration_xhtml()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local text, pos = el.buffer_text(bufnr, row, col)
  local file = vim.api.nvim_buf_get_name(bufnr)

  local include = el.parse_include_path(text, pos)
  if include then
    resolve_include(include.path, file)
    return
  end

  local composite = el.parse_composite_tag(text, pos, el.composite_namespaces(text))
  if composite then
    resolve_composite(composite, file)
    return
  end

  local parsed = el.parse_el(text, pos)
  if not parsed then
    -- Nothing JSF-specific here - defer to whatever LSP might be attached (lemminx/html), if any.
    local others = vim.tbl_filter(function(c) return c.name ~= "jsf-el" end,
      vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }))
    if #others > 0 then
      vim.lsp.buf.definition()
    else
      notify("con trỏ không nằm trên biểu thức EL / include / composite tag.", vim.log.levels.INFO)
    end
    return
  end

  local root = jdm().find_root(bufnr)
  bean_index.get(root, function(index)
    local ctx = {
      index = index,
      text = text,
      file = file,
      binding = function(name, at) return el.find_var_binding(text, at, name) end,
    }
    local client = resolve.client_for(root)
    if client then
      resolve_and_jump(ctx, client, parsed, pos, win)
      return
    end
    -- No jdtls running yet: opening the bean class is what starts it.
    local bean = bean_index.pick(index, parsed.bean, file)
    if not bean then
      notify(string.format("không tìm thấy bean '%s' và jdtls chưa chạy (cần jdtls để suy luận biến var=).",
        parsed.bean))
      return
    end
    edit(bean.file)
    local bean_buf = vim.api.nvim_get_current_buf()
    wait_for_jdtls(bean_buf, M.jdtls_wait_ms, function(c)
      if c then
        resolve_and_jump(ctx, c, parsed, pos, win)
      elseif parsed.target <= 1 then
        M.last_jump_via = "text"
        if not text_search(parsed, bean.class_name) then
          notify(string.format("không tìm thấy '%s' trong %s.", parsed.member or parsed.bean, bean.fqcn))
        end
      else
        notify("jdtls chưa attach - cần jdtls để đi theo chuỗi " .. parsed.bean .. "." .. parsed.member .. ".")
      end
    end)
  end)
end

-- ── Java -> .xhtml usages ───────────────────────────────────────────────────────────────────

---Search directories for .xhtml files: every module's webapp roots; when the project has none
---at all, every module's content root (target/ excluded by the grep itself).
local function xhtml_search_dirs(project)
  local dirs, seen = {}, {}
  for _, mod in ipairs(project.modules) do
    for _, r in ipairs(M.webapp_roots(mod)) do
      if not seen[r] then seen[r] = true table.insert(dirs, r) end
    end
  end
  if #dirs == 0 then
    for _, mod in ipairs(project.modules) do
      if not seen[mod.content_root] then
        seen[mod.content_root] = true
        table.insert(dirs, mod.content_root)
      end
    end
  end
  return dirs
end

---EL-usage regex (rg / GNU grep -E compatible) for a bean member (`bean` given) or for a
---property/method name reached through ANY chain (`bean` nil - members of non-bean classes like
---Address.getCity(), only reachable as #{x.address.city}), or a whole bean (`prop` nil).
---Both `.prop` and `['prop']` notations match.
function M.usage_regex(bean, prop)
  local member = prop and ([=[(\.]=] .. prop .. [=[\b|\[['"]]=] .. prop .. [=[['"]\])]=]) or ""
  if bean then
    return [=[[#$]\{[^}]*\b]=] .. bean .. (prop and member or [=[\b]=])
  end
  return [=[[#$]\{[^}]*]=] .. member
end

local function grep_xhtml(dirs, regex, needle, callback)
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "-n", "--no-heading", "--no-messages", "--with-filename", "-g", "*.xhtml", "-g", "!target/", "-e", regex }
  else
    cmd = { "grep", "-rnHE", "--include=*.xhtml", "--exclude-dir=target", regex }
  end
  vim.list_extend(cmd, dirs)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
    local items, seen = {}, {}
    for l in (res.stdout or ""):gmatch("[^\n]+") do
      local f, lnum, text = l:match("^(.-):(%d+):(.*)$")
      if f then
        f = vim.fn.fnamemodify(f, ":p")
        local key = f .. ":" .. lnum
        if not seen[key] then
          seen[key] = true
          table.insert(items, { filename = f, lnum = tonumber(lnum), col = (text:find(needle, 1, true) or 1),
            text = vim.trim(text) })
        end
      end
    end
    callback(items)
  end))
end

---Innermost method/field symbol containing `pos` (LSP position), or nil when the cursor is only
---inside the class itself.
local function member_at(symbols, pos)
  local best
  local SymbolKind = vim.lsp.protocol.SymbolKind
  local member_kinds = { [SymbolKind.Method] = true, [SymbolKind.Field] = true, [SymbolKind.Property] = true }
  for _, s in ipairs(symbols) do
    local r = s.range
    if member_kinds[s.kind] and r
      and (pos.line > r.start.line or (pos.line == r.start.line and pos.character >= r.start.character))
      and (pos.line < r["end"].line or (pos.line == r["end"].line and pos.character <= r["end"].character)) then
      if not best or r.start.line >= best.range.start.line then best = s end
    end
  end
  return best and best.name or nil
end

---Every `.xhtml` EL usage of the Java member under the cursor -> quickfix list (IntelliJ's Find
---Usages, for the Facelets side):
---  * member of a bean class      exact:  #{bean.prop} / #{bean['prop']}
---  * member of any other class   by name: #{anything.prop} - e.g. Address.getCity() is only ever
---    reached as #{x.address.city}; matched by property name, not type-checked
---  * cursor outside any member of a bean class -> every #{bean...} usage
---@param on_done fun(items: table[])?  test hook
function M.find_xhtml_usages(on_done)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local root = jdm().find_root(bufnr)

  local function search(beans, member)
    local searches = {}
    local prop = member and el.property_name_for(member) or nil
    if beans and #beans > 0 then
      for _, bean in ipairs(beans) do
        table.insert(searches, { label = bean.name .. (prop and ("." .. prop) or ""),
          regex = M.usage_regex(bean.name, prop), needle = prop or bean.name })
      end
    elseif prop then
      table.insert(searches, { label = "*." .. prop .. " (theo tên)", regex = M.usage_regex(nil, prop), needle = prop })
    else
      notify("con trỏ không nằm trên member nào, và class này không phải bean (@Named/@ManagedBean/@Component).")
      return
    end
    with_project(root, function(project)
      if not project then
        notify("chưa resolve được Project Model.")
        return
      end
      local all, remaining = {}, #searches
      local labels = vim.tbl_map(function(s) return s.label end, searches)
      for _, s in ipairs(searches) do
        grep_xhtml(xhtml_search_dirs(project), s.regex, s.needle, function(items)
          vim.list_extend(all, items)
          remaining = remaining - 1
          if remaining > 0 then return end
          vim.fn.setqflist({}, " ", { title = "XHTML usages: " .. table.concat(labels, ", "), items = all })
          if #all == 0 then
            notify("không có usage nào trong .xhtml cho " .. table.concat(labels, ", "), vim.log.levels.INFO)
          else
            vim.cmd("copen")
          end
          if on_done then on_done(all) end
        end)
      end
    end)
  end

  bean_index.get(root, function(index)
    local beans = index and index.by_file[file]
    local client = jdtls_client(bufnr)
    if not client then
      local word = vim.fn.expand("<cword>")
      local is_class = beans and beans[1] and word == beans[1].class_name
      search(beans, (word ~= "" and not is_class) and word or nil)
      return
    end
    local pos = vim.lsp.util.make_position_params(0, client.offset_encoding).position
    client:request("textDocument/documentSymbol", { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
      function(err, result)
        search(beans, not err and result and member_at(resolve.flatten_symbols(result), pos) or nil)
      end, bufnr)
  end)
end

-- ── wiring ──────────────────────────────────────────────────────────────────────────────────

---Buffer-local keymaps for one .xhtml buffer.
function M.attach(bufnr)
  if vim.b[bufnr].java_debug_model_jsf_nav then return end
  vim.b[bufnr].java_debug_model_jsf_nav = true
  local opts = { buffer = bufnr }
  vim.keymap.set("n", "<C-b>", M.go_to_declaration_xhtml,
    vim.tbl_extend("force", opts, { desc = "JSF: go to bean member / included file (IntelliJ Ctrl+B)" }))
  vim.keymap.set("n", "<leader>jgd", M.go_to_declaration_xhtml,
    vim.tbl_extend("force", opts, { desc = "JSF: go to declaration" }))
  -- EL completion/hover/definition via the in-process "jsf-el" LSP server (jsf/server.lua).
  local ok, opts_all = pcall(function() return jdm().opts end)
  if not ok or opts_all.jsf_completion_enabled ~= false then
    require("java-debug-model.jsf.server").attach(bufnr)
  end
end

local function is_xhtml(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):match("%.xhtml$") ~= nil
end

---Neovim's own filetype detection maps .xhtml to "html" (or "xhtml"/"xml" with other configs) -
---hook every one of those and check the extension, so plain .html files are never touched.
function M.setup()
  local group = vim.api.nvim_create_augroup("java_debug_model_jsf_nav", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "html", "xhtml", "xml" },
    callback = function(args)
      if is_xhtml(args.buf) then M.attach(args.buf) end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and is_xhtml(b) then M.attach(b) end
  end
end

return M
