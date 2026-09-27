-- Type-aware resolution of a parsed EL reference chain (#{a.b.c.d}, #{a.items[0].x},
-- #{a.getB().c}, #{item.x} with item bound by <ui:repeat var=...>) to the Java member it names,
-- driven by jdtls - no hand-written Java type inference:
--   head     bean name -> class via jsf/bean_index.lua, or a page variable -> the type of the
--            expression it's bound to (element type for iterating tags)
--   segment  textDocument/documentSymbol on the current type's file (own members first, then up
--            the typeHierarchy/supertypes chain for inherited ones: getter, is-getter, field,
--            method), then the member's declared type = textDocument/definition on the type
--            token of its declaration (so library types - jdt:// class files - just work too)
-- Files are loaded as hidden buffers and attached to the running jdtls client directly; nothing
-- is shown until the final jump.
local el = require("java-debug-model.jsf.el")

local M = {}

local SymbolKind = vim.lsp.protocol.SymbolKind

-- ── coroutine plumbing ──────────────────────────────────────────────────────────────────────

local Failure = {}

---Aborts the running resolution with a user-facing message (caught by M.run).
function M.fail(msg)
  error(setmetatable({ msg = msg }, Failure), 0)
end

---Runs `fn` as a coroutine in which M.await-based helpers can be called synchronously-looking.
---@param fn fun()
---@param on_error fun(msg: string)
function M.run(fn, on_error)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, yielded = coroutine.resume(co, ...)
    if not ok then
      if getmetatable(yielded) == Failure then
        on_error(yielded.msg)
      else
        on_error("lỗi nội bộ: " .. debug.traceback(co, tostring(yielded)))
      end
    elseif coroutine.status(co) == "suspended" then
      yielded(vim.schedule_wrap(step))
    end
  end
  step()
end

---Suspends until `start(cb)` calls `cb(...)`; returns those values.
local function await(start)
  return coroutine.yield(start)
end

local function request(client, method, params, bufnr)
  return await(function(cb)
    local ok = client:request(method, params, function(err, result) cb(err, result) end, bufnr)
    if not ok then cb({ message = "jdtls không nhận request " .. method }, nil) end
  end)
end

-- ── symbols ─────────────────────────────────────────────────────────────────────────────────

---Bare member name from a jdtls symbol name: "getName()" / "setName(String)" / "BaseBean<T>" -> ...
local function bare_name(name)
  return (name:match("^([%w_$]+)") or name)
end

---Flattens a textDocument/documentSymbol result (hierarchical DocumentSymbol[] or flat
---SymbolInformation[]) into { name, kind, range, selection_range, container }.
function M.flatten_symbols(result)
  local out = {}
  local function walk(syms, container)
    for _, s in ipairs(syms or {}) do
      local range = s.range or (s.location and s.location.range)
      table.insert(out, { name = bare_name(s.name), raw_name = s.name, detail = s.detail, kind = s.kind,
        range = range, selection_range = s.selectionRange or range, container = container or s.containerName })
      if s.children then walk(s.children, bare_name(s.name)) end
    end
  end
  walk(result, nil)
  return out
end

local CLASS_KINDS = { [SymbolKind.Class] = true, [SymbolKind.Enum] = true, [SymbolKind.Interface] = true }

function M.class_symbol(symbols, class_name)
  for _, s in ipairs(symbols) do
    if CLASS_KINDS[s.kind] and s.name == class_name then return s end
  end
  return nil
end

---Member candidates for one EL segment, in lookup order.
---@param seg { name: string, call: boolean? }
---@return { name: string, kinds: table<integer, boolean> }[]
function M.member_candidates(seg)
  local method = { [SymbolKind.Method] = true }
  local field = { [SymbolKind.Field] = true, [SymbolKind.Property] = true, [SymbolKind.EnumMember] = true }
  local cap = el.capitalize(seg.name)
  local accessors = {
    { name = "get" .. cap, kinds = method },
    { name = "is" .. cap, kinds = method },
    { name = seg.name, kinds = field },
  }
  local as_method = { name = seg.name, kinds = method }
  if seg.call then
    return { as_method }
  end
  -- A property-shaped reference can still be a method expression (action="#{bean.save}").
  return vim.list_extend(accessors, { as_method, { name = "set" .. cap, kinds = method } })
end

---The symbol `seg` names among `symbols` of class `class_name` (own members only), or nil.
function M.pick_symbol(symbols, seg, class_name)
  local class_sym = M.class_symbol(symbols, class_name)
  for _, cand in ipairs(M.member_candidates(seg)) do
    for _, s in ipairs(symbols) do
      if s.name == cand.name and cand.kinds[s.kind] and (not class_sym or s.container == class_name) then
        return s
      end
    end
  end
  return nil
end

-- ── buffers ─────────────────────────────────────────────────────────────────────────────────

---jdtls client serving `root` (any jdtls client as a fallback), or nil.
function M.client_for(root)
  local clients = vim.lsp.get_clients({ name = "jdtls" })
  for _, c in ipairs(clients) do
    if c.config.root_dir == root then return c end
  end
  return clients[1]
end

---Loads `uri` (file:// or jdt://) into a hidden, unlisted buffer attached to `client`. jdt://
---contents are fetched synchronously by nvim-jdtls's own BufReadCmd.
function M.load_buf(client, uri)
  local name = vim.startswith(uri, "file:") and vim.uri_to_fname(uri) or uri
  local existed = vim.fn.bufexists(name) == 1
  local buf = vim.uri_to_bufnr(uri)
  if not existed then vim.bo[buf].buflisted = false end
  if not vim.api.nvim_buf_is_loaded(buf) then vim.fn.bufload(buf) end
  -- nvim-jdtls fills jdt:// buffers from its own BufReadCmd autocmd (plugin/jdtls.lua); if that
  -- never ran (plugin file not sourced), fetch the class contents through it directly.
  if vim.startswith(uri, "jdt://") and vim.api.nvim_buf_line_count(buf) <= 1
    and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == "" then
    local ok_jdtls, jdtls = pcall(require, "jdtls")
    if ok_jdtls then pcall(jdtls.open_classfile, buf, uri) end
  end
  if vim.bo[buf].filetype == "" then vim.bo[buf].filetype = "java" end
  if not vim.lsp.buf_is_attached(buf, client.id) then vim.lsp.buf_attach_client(buf, client.id) end
  return buf
end

local function symbols_of(ctx, buf)
  local err, result = request(ctx.client, "textDocument/documentSymbol",
    { textDocument = { uri = vim.uri_from_bufnr(buf) } }, buf)
  if err then M.fail("documentSymbol lỗi: " .. (err.message or vim.inspect(err))) end
  return M.flatten_symbols(result or {})
end

-- ── resolution ──────────────────────────────────────────────────────────────────────────────

---@class JsfTypeRef
---@field uri string
---@field class_name string

---Direct supertypes of class `class_name` declared in `buf` (java.lang.Object excluded).
---@return JsfTypeRef[]
local function supertypes_of(ctx, buf, symbols, class_name)
  local cls = M.class_symbol(symbols, class_name)
  if not cls then return {} end
  local err, items = request(ctx.client, "textDocument/prepareTypeHierarchy",
    { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = cls.selection_range.start }, buf)
  if err or not items or #items == 0 then return {} end
  local err2, supers = request(ctx.client, "typeHierarchy/supertypes", { item = items[1] }, buf)
  if err2 then return {} end
  local out = {}
  for _, item in ipairs(supers or {}) do
    local name = bare_name(item.name)
    if name ~= "Object" then table.insert(out, { uri = item.uri, class_name = name }) end
  end
  return out
end

---Finds `seg` on type `t`, walking up its supertypes for inherited members.
---@return { buf: integer, sym: table, type_ref: JsfTypeRef }|nil
local function find_member(ctx, t, seg, seen)
  seen = seen or {}
  if seen[t.uri] or vim.tbl_count(seen) > 10 then return nil end
  seen[t.uri] = true
  local buf = M.load_buf(ctx.client, t.uri)
  local symbols = symbols_of(ctx, buf)
  local sym = M.pick_symbol(symbols, seg, t.class_name)
  if sym then return { buf = buf, sym = sym, type_ref = t } end

  for _, super in ipairs(supertypes_of(ctx, buf, symbols, t.class_name)) do
    local found = find_member(ctx, super, seg, seen)
    if found then return found end
  end
  return nil
end

---Declared type of a found member (return type of a method, type of a field) - or with
---`element`, the element type of that collection/array type.
---@return JsfTypeRef
local function member_type(ctx, found, element)
  local enc = ctx.client.offset_encoding
  local start = found.sym.selection_range.start
  local line = vim.api.nvim_buf_get_lines(found.buf, start.line, start.line + 1, false)[1] or ""
  local name_byte = vim.str_byteindex(line, enc, start.character, false)
  local ts, te = el.type_token(line:sub(1, name_byte), element)
  if not ts then
    M.fail(string.format("không suy ra được %s của '%s'", element and "kiểu phần tử" or "kiểu",
      found.sym.name))
  end
  local err, result = request(ctx.client, "textDocument/definition", {
    textDocument = { uri = vim.uri_from_bufnr(found.buf) },
    position = { line = start.line, character = vim.str_utfindex(line, enc, ts - 1, false) },
  }, found.buf)
  local loc = result and (vim.islist(result) and result[1] or result)
  if err or not loc or vim.tbl_isempty(loc) then
    M.fail(string.format("không tìm thấy class '%s' (kiểu của '%s')", line:sub(ts, te), found.sym.name))
  end
  return { uri = loc.uri or loc.targetUri, class_name = line:sub(ts, te) }
end

---Applies segments 1..n starting from type `t`. Returns the last found member (its type not yet
---computed - the caller decides between its own type and its element type), or, when the walk
---ended on an `[index]` segment / n == 0, the resulting type.
local function walk(ctx, t, segs, n)
  local prev
  for i = 1, n do
    local seg = segs[i]
    if seg.element then
      if not prev then M.fail("không index được biểu thức ở vị trí này") end
      t = member_type(ctx, prev, true)
      prev = nil
    else
      if prev then
        t = member_type(ctx, prev, false)
        prev = nil
      end
      prev = find_member(ctx, t, seg)
      if not prev then M.fail(string.format("không tìm thấy '%s' trong %s", seg.name, t.class_name)) end
    end
  end
  return prev, t
end

local function type_after(ctx, t, segs, n, element)
  local prev, t2 = walk(ctx, t, segs, n)
  if prev then return member_type(ctx, prev, element) end
  if element then M.fail("không suy ra được kiểu phần tử") end
  return t2
end

local head_type

---Type of a whole parsed expression (see el.parse_expression); `element` = its element type.
local function expression_type(ctx, parsed, element, pos, depth)
  local t = head_type(ctx, parsed.bean, pos, depth)
  return type_after(ctx, t, parsed.chain, #parsed.chain, element)
end

---@return JsfTypeRef, table  the type + { bean = JsfBean } | { binding = ... }
head_type = function(ctx, name, pos, depth)
  local bean = require("java-debug-model.jsf.bean_index").pick(ctx.index, name, ctx.file)
  if bean then
    return { uri = vim.uri_from_fname(bean.file), class_name = bean.class_name }, { bean = bean }
  end
  if el.IMPLICIT_OBJECTS[name] then
    M.fail("'" .. name .. "' là implicit object của EL, không trỏ tới class Java của project.")
  end
  local binding = ctx.binding and ctx.binding(name, pos)
  if not binding then
    M.fail(string.format("không tìm thấy bean '%s' (@Named/@ManagedBean/@Component) hay biến var=\"%s\" "
      .. "trong trang. Thử :JavaJsfIndexReload.", name, name))
  end
  if depth > 8 then M.fail("biến '" .. name .. "' lồng nhau quá sâu") end
  local parsed = el.parse_expression(binding.expr)
  if not parsed then M.fail("không đọc được biểu thức gán cho '" .. name .. "': " .. binding.expr) end
  return expression_type(ctx, parsed, binding.iterate, binding.decl, depth + 1), { binding = binding }
end

---Type of the whole parsed chain (every segment applied) - what `.` completes on.
---Must run inside M.run.
---@return JsfTypeRef
function M.type_of(ctx, parsed, pos)
  return expression_type(ctx, parsed, false, pos, 0)
end

local MEMBER_KINDS = { [SymbolKind.Method] = true, [SymbolKind.Field] = true, [SymbolKind.Property] = true,
  [SymbolKind.EnumMember] = true }

---Every member of type `t` and of its supertypes (java.lang.Object excluded), own class first.
---Must run inside M.run.
---@return { sym: table, buf: integer, owner: string, depth: integer }[]
function M.members_of(ctx, t)
  local out, seen = {}, {}
  local function visit(type_ref, depth)
    if seen[type_ref.uri] or depth > 10 then return end
    seen[type_ref.uri] = true
    local buf = M.load_buf(ctx.client, type_ref.uri)
    local symbols = symbols_of(ctx, buf)
    for _, s in ipairs(symbols) do
      if MEMBER_KINDS[s.kind] and s.container == type_ref.class_name then
        table.insert(out, { sym = s, buf = buf, owner = type_ref.class_name, depth = depth })
      end
    end
    for _, super in ipairs(supertypes_of(ctx, buf, symbols, type_ref.class_name)) do
      visit(super, depth + 1)
    end
  end
  visit(t, 0)
  return out
end

---Resolves the segment the cursor is on (`parsed.target`) to where Ctrl+B should land.
---Must run inside M.run.
---@param ctx { client: table, index: table, binding: fun(name: string, pos: integer): table|nil }
---@param parsed table  from el.parse_el
---@param pos integer   offset of the cursor (scope for page variables)
---@return { kind: "member", buf: integer, sym: table, owner: string }
---     | { kind: "class", buf: integer, sym: table|nil }
---     | { kind: "binding", binding: table }
function M.resolve(ctx, parsed, pos)
  local t, origin = head_type(ctx, parsed.bean, pos, 0)
  if parsed.target == 0 then
    if origin.binding then return { kind = "binding", binding = origin.binding } end
    local buf = M.load_buf(ctx.client, t.uri)
    return { kind = "class", buf = buf, sym = M.class_symbol(symbols_of(ctx, buf), t.class_name) }
  end
  local owner = type_after(ctx, t, parsed.chain, parsed.target - 1, false)
  local seg = parsed.chain[parsed.target]
  local found = find_member(ctx, owner, seg)
  if not found then M.fail(string.format("không tìm thấy '%s' trong %s", seg.name, owner.class_name)) end
  return { kind = "member", buf = found.buf, sym = found.sym, owner = found.type_ref.class_name }
end

return M
