-- Pure JSF/Facelets text parsing for jsf/nav.lua's Ctrl+B - no I/O, no LSP, so it's unit-testable
-- with `nvim --headless -u NONE` alone (test-fixtures/smoke_jsf_el_parse.lua).
--
-- Everything works on the WHOLE buffer text plus a 1-based byte offset (not one line), so EL
-- expressions and tags split over several lines are handled like single-line ones.
local M = {}

local KEYWORDS = { empty = true, ["not"] = true, ["and"] = true, ["or"] = true, eq = true, ne = true,
  lt = true, gt = true, le = true, ge = true, div = true, mod = true, ["true"] = true, ["false"] = true,
  null = true, instanceof = true, new = true }

-- EL implicit objects - never beans, never resolvable to a Java class of the project.
M.IMPLICIT_OBJECTS = { cc = true, param = true, paramValues = true, header = true, headerValues = true,
  cookie = true, initParam = true, request = true, session = true, application = true, flash = true,
  facesContext = true, view = true, component = true, resource = true, requestScope = true,
  sessionScope = true, applicationScope = true, viewScope = true, flowScope = true }

---Whole buffer text + the 1-based byte offset of the cursor inside it.
---@param bufnr integer
---@param row integer  1-based (nvim_win_get_cursor)
---@param col integer  0-based byte column (nvim_win_get_cursor)
---@return string text, integer offset
function M.buffer_text(bufnr, row, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local offset = 0
  for i = 1, row - 1 do offset = offset + #lines[i] + 1 end
  return table.concat(lines, "\n"), offset + col + 1
end

---Inverse of buffer_text's offset: 1-based offset -> 1-based row, 0-based byte col.
function M.offset_to_pos(text, offset)
  local row, line_start = 1, 1
  for nl in text:sub(1, offset - 1):gmatch("()\n") do
    row = row + 1
    line_start = nl + 1
  end
  return row, offset - line_start
end

---Every `#{...}`/`${...}` span in `text`, as { start, finish, body_start } (1-based, inclusive;
---`body_start` is the first character after the opening brace). Tracks quoted strings so a `}`
---inside `'...'`/`"..."` (e.g. `#{bean.label('}')}`) doesn't end the expression early.
---@param text string
---@return { start: integer, finish: integer, body_start: integer }[]
function M.el_spans(text)
  local spans = {}
  local i = 1
  while true do
    local s = text:find("[#$]{", i)
    if not s then break end
    local j, quote, finish = s + 2, nil, nil
    while j <= #text do
      local ch = text:sub(j, j)
      if quote then
        if ch == quote then quote = nil end
      elseif ch == "'" or ch == '"' then
        quote = ch
      elseif ch == "}" then
        finish = j
        break
      end
      j = j + 1
    end
    if not finish then break end -- unterminated expression
    table.insert(spans, { start = s, finish = finish, body_start = s + 2 })
    i = finish + 1
  end
  return spans
end

local scan -- forward declaration (parse_chain and scan recurse into each other)

---Parses one reference chain starting at the identifier at `s`:
---  head ( .name | .name(args) | ['name'] | [index] )*
---Call arguments / index expressions are scanned for chains of their own (appended to `out`),
---so `#{bean.save(item.id)}` with the cursor on `id` resolves `item.id`.
local function parse_chain(text, s, limit, out)
  local _, e = text:find("^[%a_][%w_]*", s)
  local chain = { head = { name = text:sub(s, e), s = s, e = e }, segments = {}, s = s }
  local pos = e + 1
  while pos <= limit do
    local _, de, name = text:find("^%s*%.%s*([%a_][%w_]*)", pos)
    if de and de <= limit then
      local seg = { name = name, s = de - #name + 1, e = de }
      pos = de + 1
      local ps, pe = text:find("^%s*%b()", pos)
      if ps and pe <= limit then
        seg.call = true
        scan(text, text:find("(", pos, true) + 1, pe - 1, out)
        pos = pe + 1
      end
      table.insert(chain.segments, seg)
    else
      local bs, be = text:find("^%s*%b[]", pos)
      if not bs or be > limit then break end
      local open = text:find("[", pos, true)
      local inner = text:sub(open + 1, be - 1)
      local lead, _, key = inner:match("^(%s*)(['\"])([%a_][%w_]*)%2%s*$")
      if key then
        local ks = open + #lead + 2
        table.insert(chain.segments, { name = key, s = ks, e = ks + #key - 1, bracket = true })
      else
        table.insert(chain.segments, { element = true, s = open, e = be })
        scan(text, open + 1, be - 1, out)
      end
      pos = be + 1
    end
  end
  chain.e = pos - 1
  return chain, pos
end

---Collects every reference chain between `pos` and `limit` into `out`.
scan = function(text, pos, limit, out)
  while pos <= limit do
    local c = text:sub(pos, pos)
    if c == "'" or c == '"' then
      local close = text:find(c, pos + 1, true)
      pos = (close and close <= limit and close or limit) + 1
    elseif c:match("[%a_]") then
      local _, e = text:find("^[%a_][%w_]*", pos)
      local word = text:sub(pos, e)
      local prev = pos > 1 and text:sub(pos - 1, pos - 1) or ""
      local prev2 = pos > 2 and text:sub(pos - 2, pos - 2) or ""
      local is_fn_prefix = text:sub(e + 1, e + 1) == ":" and text:sub(e + 2, e + 2):match("[%a_]")
      local is_fn_name = prev == ":" and prev2:match("[%w_]")
      if prev:match("[%w_.]") or KEYWORDS[word] or is_fn_prefix or is_fn_name then
        pos = e + 1 -- operator keyword, `fn:length(...)` EL function, digits of a number, ...
      else
        local chain, np = parse_chain(text, pos, limit, out)
        table.insert(out, chain)
        pos = np
      end
    else
      pos = pos + 1
    end
  end
end

---Parses the EL reference at 1-based offset `pos` of `text`. Returns nil when `pos` isn't inside
---an EL expression, else:
---  bean     the chain's head identifier (a bean name or a `var` bound in the page)
---  chain    the segments after the head: { name, call?, bracket?, element? } - `element` is an
---           `[index]` access (the element type of the previous segment's collection/array)
---  target   index into `chain` of the segment the cursor is on (0 = the head itself)
---  kind     "bean" (target 0) | "method" (`name(...)`) | "property"
---  member   name of the target segment (nil for target 0)
---Inside a larger expression (`#{empty a.list ? b.x : c.y}`) the innermost chain the cursor sits
---on wins; with the cursor on an operator/whitespace instead, the first chain's last segment.
---@param text string
---@param pos integer
function M.parse_el(text, pos)
  local span
  for _, sp in ipairs(M.el_spans(text)) do
    if pos >= sp.start and pos <= sp.finish then span = sp break end
  end
  if not span then return nil end

  local chains = {}
  scan(text, span.body_start, span.finish - 1, chains)
  if #chains == 0 then return nil end

  local hit
  for _, ch in ipairs(chains) do
    if pos >= ch.s and pos <= ch.e and (not hit or ch.e - ch.s < hit.e - hit.s) then hit = ch end
  end
  local target = 0
  if hit then
    if pos > hit.head.e then
      for i, seg in ipairs(hit.segments) do
        if not seg.element and pos >= seg.s then target = i end
      end
    end
  else
    hit = chains[1]
    for i, seg in ipairs(hit.segments) do
      if not seg.element then target = i end
    end
  end

  local chain = {}
  for _, seg in ipairs(hit.segments) do
    table.insert(chain, { name = seg.name, call = seg.call or nil, bracket = seg.bracket or nil,
      element = seg.element or nil })
  end
  local seg = chain[target]
  return {
    bean = hit.head.name,
    chain = chain,
    target = target,
    kind = target == 0 and "bean" or (seg.call and "method" or "property"),
    member = seg and seg.name or nil,
  }
end

---The full reference of a standalone expression attribute value like "#{helloBean.items}" -
---target = its last named segment. nil for a literal / an expression with no reference.
---@param expr string
function M.parse_expression(expr)
  local sp = M.el_spans(expr)[1]
  if not sp then return nil end
  return M.parse_el(expr, sp.finish)
end

---@param bufnr integer
---@param row integer  1-based line (as nvim_win_get_cursor returns)
---@param col integer  0-based byte column (as nvim_win_get_cursor returns)
function M.parse_el_at_cursor(bufnr, row, col)
  return M.parse_el(M.buffer_text(bufnr, row, col))
end

-- ── tags ────────────────────────────────────────────────────────────────────────────────────

---Parses the start tag whose `<` is at `ts`. Attribute values are scanned quote-aware, so a `>`
---inside one (`rendered="#{a > b}"`) doesn't end the tag; a tag may span any number of lines.
---@return { name: string, s: integer, e: integer, name_s: integer, name_e: integer,
---  self_closing: boolean?, attrs: table<string, { value: string, vs: integer, ve: integer }> }|nil
function M.parse_tag(text, ts)
  local _, ne, name = text:find("^<([%a_][%w_%-%.]*:?[%w_%-%.]*)", ts)
  if not name then return nil end
  local tag = { name = name, s = ts, name_s = ts + 1, name_e = ne, attrs = {} }
  local pos = ne + 1
  while true do
    local ws = text:find("%S", pos)
    if not ws then return nil end
    if text:sub(ws, ws) == ">" then
      tag.e = ws
      return tag
    end
    if text:sub(ws, ws + 1) == "/>" then
      tag.e, tag.self_closing = ws + 1, true
      return tag
    end
    local _, ae, aname = text:find("^([%w_:%-%.]+)%s*=%s*", ws)
    if not ae then return nil end
    local q = text:sub(ae + 1, ae + 1)
    if q ~= '"' and q ~= "'" then return nil end
    local close = text:find(q, ae + 2, true)
    if not close then return nil end
    tag.attrs[aname] = { value = text:sub(ae + 2, close - 1), vs = ae + 2, ve = close - 1 }
    pos = close + 1
  end
end

---Every start tag beginning before `upto` (default: whole text), in document order.
function M.tags(text, upto)
  local out = {}
  for ts in text:gmatch("()<[%a_]") do
    if upto and ts >= upto then break end
    local tag = M.parse_tag(text, ts)
    if tag then table.insert(out, tag) end
  end
  return out
end

---The start tag `pos` is inside of (between its `<` and `>`), or nil.
function M.tag_at(text, pos)
  local found
  for _, tag in ipairs(M.tags(text, pos + 1)) do
    if pos >= tag.s and pos <= tag.e then found = tag end
  end
  return found
end

-- Tag -> the attribute(s) holding a Facelets/JSP path on it.
local INCLUDE_ATTRS = {
  ["ui:include"] = { src = true },
  ["ui:composition"] = { template = true },
  ["ui:decorate"] = { template = true },
  ["c:import"] = { url = true },
}

---Path under the cursor when it's inside the value of `src="..."` on `<ui:include`,
---`template="..."` on `<ui:composition`/`<ui:decorate`, or `url="..."` on `<c:import`.
---@param text string
---@param pos integer  1-based offset
---@return { path: string }|nil
function M.parse_include_path(text, pos)
  local tag = M.tag_at(text, pos)
  local attrs = tag and INCLUDE_ATTRS[tag.name]
  if not attrs then return nil end
  for name, a in pairs(tag.attrs) do
    if attrs[name] and pos >= a.vs and pos <= a.ve then return { path = a.value } end
  end
  return nil
end

---@param bufnr integer
---@param row integer  1-based
---@param col integer  0-based
function M.parse_include_path_at_cursor(bufnr, row, col)
  return M.parse_include_path(M.buffer_text(bufnr, row, col))
end

---Composite-component library for every `xmlns:prefix=".../composite/<library>"` declared in
---`text` (any of the three namespace spellings: java.sun.com/jsf/composite,
---xmlns.jcp.org/jsf/composite, jakarta.faces.composite).
---@param text string|string[]
---@return table<string, string>  prefix -> library
function M.composite_namespaces(text)
  if type(text) == "table" then text = table.concat(text, "\n") end
  local map = {}
  for prefix, uri in text:gmatch("xmlns:([%w_]+)%s*=%s*[\"']([^\"']+)[\"']") do
    local lib = uri:match("/jsf/composite/(.+)$") or uri:match("^jakarta%.faces%.composite/(.+)$")
    if lib then map[prefix] = lib end
  end
  return map
end

---`<prefix:tag` (or `</prefix:tag`) under the cursor, cursor anywhere on the `prefix:tag` name,
---when `prefix` is a composite-component namespace -> resources/<library>/<tag>.xhtml.
---@param text string
---@param pos integer
---@param namespaces table<string, string>  from composite_namespaces()
---@return { library: string, tag: string }|nil
function M.parse_composite_tag(text, pos, namespaces)
  for ts, prefix, tag, te in text:gmatch("</?()([%w_]+):([%w_%-]+)()") do
    if ts > pos then break end
    if pos >= ts and pos < te and namespaces[prefix] then
      return { library = namespaces[prefix], tag = tag }
    end
  end
  return nil
end

-- ── page-scoped variables ───────────────────────────────────────────────────────────────────

---The declaration in scope at `pos` for page variable `name`:
---  * `var="name"` on an iterating tag (ui:repeat, h:dataTable, c:forEach, p:dataTable, ...) whose
---    body `pos` is still inside -> bound to the ELEMENT type of its value/items expression
---  * `<c:set var="name" value=...>` / `<ui:param name="name" value=...>` before `pos` -> bound to
---    the expression's own type
---The nearest such declaration before `pos` wins. ui:param passed in from a template client in a
---DIFFERENT file isn't visible here.
---@return { tag: string, expr: string, iterate: boolean, decl: integer }|nil  decl = offset of the name
function M.find_var_binding(text, pos, name)
  local best
  for _, tag in ipairs(M.tags(text, pos)) do
    local decl, expr, iterate
    if tag.name == "ui:param" and tag.attrs.name and tag.attrs.name.value == name then
      decl, expr, iterate = tag.attrs.name, tag.attrs.value, false
    elseif tag.attrs.var and tag.attrs.var.value == name then
      decl, expr = tag.attrs.var, tag.attrs.value or tag.attrs.items
      iterate = tag.name ~= "c:set"
    end
    if expr and tag.e < pos then
      local in_scope = true
      if iterate then
        local close = text:find("</" .. vim.pesc(tag.name) .. "%s*>", tag.e + 1)
        in_scope = not tag.self_closing and not (close and close < pos)
      end
      if in_scope then
        best = { tag = tag.name, expr = expr.value, iterate = iterate, decl = decl.vs }
      end
    end
  end
  return best
end

---Every page variable name in scope at `pos` (see find_var_binding), in document order.
---@return { name: string, binding: table }[]
function M.page_variables(text, pos)
  local out, seen = {}, {}
  for _, tag in ipairs(M.tags(text, pos)) do
    local name = (tag.name == "ui:param" and tag.attrs.name and tag.attrs.name.value)
      or (tag.attrs.var and tag.attrs.var.value)
    if name and not seen[name] then
      local binding = M.find_var_binding(text, pos, name)
      if binding then
        seen[name] = true
        table.insert(out, { name = name, binding = binding })
      end
    end
  end
  return out
end

-- ── completion context ──────────────────────────────────────────────────────────────────────

---Start offset of an EL expression opened before the end of `before` and not closed yet (the one
---being typed), or nil. Quote-aware, like el_spans.
local function open_el_start(before)
  local i = 1
  while true do
    local s = before:find("[#$]{", i)
    if not s then return nil end
    local j, quote, finish = s + 2, nil, nil
    while j <= #before do
      local ch = before:sub(j, j)
      if quote then
        if ch == quote then quote = nil end
      elseif ch == "'" or ch == '"' then
        quote = ch
      elseif ch == "}" then
        finish = j
        break
      end
      j = j + 1
    end
    if not finish then return s end
    i = finish + 1
  end
end

-- Longest EL expression still considered "being typed" - anything longer is far more likely an
-- unrelated stray `#{` (in a comment, JS, ...) than a real in-progress expression.
local MAX_OPEN_EL = 2000

---What completion at 1-based offset `pos` should offer (text typed so far = `typed`, which
---starts at offset `typed_s` and ends right before `pos`):
---  { kind = "member", parsed, typed, typed_s }  after `chain.` or `chain['` - members of the type
---                                               of `parsed` (el.parse_el result, full chain)
---  { kind = "head", typed, typed_s }            start of a reference: beans, page variables,
---                                               implicit objects
---  { kind = "include", typed, typed_s }         inside ui:include src / ui:composition|decorate
---                                               template / c:import url - .xhtml paths
---  { kind = "composite", prefix, typed, typed_s } `<prefix:` of a composite namespace - tag names
---or nil when there's nothing JSF-specific to complete.
---@param text string
---@param pos integer
function M.completion_context(text, pos)
  local before = text:sub(1, pos - 1)

  local el_start = open_el_start(before)
  if el_start and #before - el_start < MAX_OPEN_EL then
    local body = before:sub(el_start + 2)
    local typed = body:match("[%a_][%w_]*$") or ""
    local rest = body:sub(1, #body - #typed)
    local typed_s = pos - #typed
    local chain_text = rest:match("^(.-)%s*%.%s*$") or rest:match("^(.-)%[%s*['\"]$")
    if chain_text then
      if not chain_text:match("[%w_%)%]]$") then return nil end -- e.g. the "1." of a number
      local synthetic = "#{" .. chain_text .. "}"
      local parsed = M.parse_el(synthetic, #synthetic - 1)
      if not parsed then return nil end
      return { kind = "member", parsed = parsed, typed = typed, typed_s = typed_s }
    end
    if rest:match("[%w_]$") or rest:match("[%w_]:$") or rest:match("['\"]$") then
      return nil -- inside a number / after an EL function namespace (fn:) / inside a string
    end
    return { kind = "head", typed = typed, typed_s = typed_s }
  end

  local lt = before:match(".*()<")
  if lt then
    local frag = before:sub(lt)
    if not frag:find(">", 1, true) then
      local tag = frag:match("^<([%w_%-]+:[%w_%-]+)%s")
      local attrs = tag and INCLUDE_ATTRS[tag]
      if attrs then
        local attr, typed = frag:match("([%w_:]+)%s*=%s*[\"']([^\"']*)$")
        if attr and attrs[attr] then
          return { kind = "include", typed = typed, typed_s = pos - #typed }
        end
      end
      local prefix, typed = frag:match("^<([%w_]+):([%w_%-]*)$")
      if prefix then
        return { kind = "composite", prefix = prefix, typed = typed, typed_s = pos - #typed }
      end
    end
  end
  return nil
end

-- ── Java-side naming / type helpers ─────────────────────────────────────────────────────────

---Java bean naming: CDI/JSF lower-case just the first character; Spring (and JavaBeans property
---names, i.e. what EL uses for `getURL()` -> `URL`) keep a name whose first TWO characters are
---both upper-case as-is (java.beans.Introspector.decapitalize).
---@param name string
---@param introspector boolean?
function M.decapitalize(name, introspector)
  if name == "" then return name end
  if introspector and #name > 1 and name:sub(2, 2):match("%u") and name:sub(1, 1):match("%u") then
    return name
  end
  return name:sub(1, 1):lower() .. name:sub(2)
end

function M.capitalize(name)
  return name:sub(1, 1):upper() .. name:sub(2)
end

---EL property name a Java member corresponds to: getFoo()/isFoo()/setFoo(..) -> "foo", anything
---else (a field, an action method) -> its own name unchanged.
---@param member string  bare member name, no parens
---@return string name, boolean is_accessor
function M.property_name_for(member)
  local rest = member:match("^get(%u[%w_]*)$") or member:match("^is(%u[%w_]*)$") or member:match("^set(%u[%w_]*)$")
  if rest then return M.decapitalize(rest, true), true end
  return member, false
end

---Last identifier (the simple name of a possibly dotted type name) at the end of `s`.
---@return integer|nil start, integer|nil finish  1-based, inclusive
local function last_ident(s)
  s = s:gsub("[%s%[%]]+$", "")
  local st = s:match("()[%a_$][%w_$]*$")
  if not st then return nil end
  return st, #s
end

---Given the text of a Java declaration line up to (not including) a member's name - e.g.
---"    public List<Item> " / "private Address " / "public Item[] " - locates the type identifier
---to resolve: the declared type itself, or with `element` the type of its elements (array
---component type, or the LAST type argument: List<Item> -> Item, Map<K, V> -> V).
---@param prefix string
---@param element boolean?
---@return integer|nil start, integer|nil finish  1-based, inclusive, within `prefix`
function M.type_token(prefix, element)
  local s = prefix:gsub("%s+$", "")
  local array = false
  while s:match("%[%s*%]$") do
    s = s:gsub("%s*%[%s*%]$", "")
    array = true
  end
  local args_s, args_e, outer = nil, nil, s
  if s:sub(-1) == ">" then
    local depth = 0
    for i = #s, 1, -1 do
      local ch = s:sub(i, i)
      if ch == ">" then depth = depth + 1 elseif ch == "<" then depth = depth - 1 end
      if depth == 0 then
        args_s, args_e, outer = i + 1, #s - 1, s:sub(1, i - 1)
        break
      end
    end
    if not args_s then return nil end
  end
  if not element or array then
    return last_ident(outer)
  end
  if not args_s then return nil end
  -- last top-level type argument
  local depth, last_start = 0, args_s
  for i = args_s, args_e do
    local ch = s:sub(i, i)
    if ch == "<" then depth = depth + 1
    elseif ch == ">" then depth = depth - 1
    elseif ch == "," and depth == 0 then last_start = i + 1 end
  end
  local arg = s:sub(last_start, args_e)
  local generic = arg:find("<", 1, true)
  local head = generic and arg:sub(1, generic - 1) or arg
  local st, fin = last_ident(head)
  if not st or head:sub(st, fin) == "extends" or head:sub(st, fin) == "super" then return nil end
  return last_start + st - 1, last_start + fin - 1
end

return M
