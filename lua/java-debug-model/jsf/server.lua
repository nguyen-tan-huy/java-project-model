-- "jsf-el": a tiny in-process LSP server (vim.lsp.start with a Lua `cmd` function - no external
-- process) attached to .xhtml buffers, so EL support plugs into whatever completion UI the user
-- already runs (nvim-cmp's `nvim_lsp` source, blink.cmp, native vim.lsp.completion) with no
-- per-plugin wiring:
--   textDocument/completion  #{  -> beans, page variables (var=/ui:param), EL implicit objects
--                            #{chain.  / chain['  -> properties (getX/isX, Lombok fields) and
--                                         public methods of the chain's type, inherited included
--                            <ui:include src="  (template=/url=)  -> .xhtml paths of the webapp
--                            <cc:  of a composite namespace   -> composite component tags
--   textDocument/hover       declaration of the Java member / bean class / page variable
--   textDocument/definition  same target as Ctrl+B (jsf/nav.lua), for `gd`/pickers
-- Type knowledge comes from jsf/resolve.lua (jdtls-driven); this file is only protocol + items.
local el = require("java-debug-model.jsf.el")
local bean_index = require("java-debug-model.jsf.bean_index")
local resolve = require("java-debug-model.jsf.resolve")

local M = {}

M.name = "jsf-el"

local SymbolKind = vim.lsp.protocol.SymbolKind
local ItemKind = vim.lsp.protocol.CompletionItemKind
local ENCODING = "utf-16" -- this server's positionEncoding (the LSP default)

local function jdm()
  return require("java-debug-model")
end

local EMPTY = { isIncomplete = false, items = {} }

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────

local function buf_line(buf, lnum0)
  return vim.api.nvim_buf_get_lines(buf, lnum0, lnum0 + 1, false)[1] or ""
end

---(buffer, full text, cursor offset) for an LSP TextDocumentPositionParams.
local function locate(params)
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  local line = buf_line(buf, params.position.line)
  local col = vim.str_byteindex(line, ENCODING, params.position.character, false)
  local text, pos = el.buffer_text(buf, params.position.line + 1, col)
  return buf, text, pos
end

---1-based offset in `text` -> LSP Position.
local function offset_to_position(text, offset)
  local row, col = el.offset_to_pos(text, offset)
  local line = vim.split(text, "\n", { plain = true })[row] or ""
  return { line = row - 1, character = vim.str_utfindex(line, ENCODING, col, false) }
end

local function with_project(root, callback)
  local project = jdm().get_cached_project(root)
  if project then callback(project) else jdm().get_project(root, callback) end
end

local MODIFIERS = { "public", "protected", "private", "static", "final", "abstract", "synchronized",
  "default", "native", "transient", "volatile", "strictfp" }

---Modifiers + declared type of a member, read from its declaration line.
local function decl_info(buf, sym)
  local start = sym.selection_range.start
  local line = buf_line(buf, start.line)
  local prefix = line:sub(1, vim.str_byteindex(line, ENCODING, start.character, false))
  local words = {}
  for w in prefix:gmatch("[%a_]+") do words[w] = true end
  local type_text = prefix:gsub("@[%w_.]+%s*%b()", ""):gsub("@[%w_.]+", "")
  for _, m in ipairs(MODIFIERS) do type_text = type_text:gsub("%f[%w_]" .. m .. "%f[^%w_]", "") end
  return {
    private = words.private, protected = words.protected, static = words.static,
    type = vim.trim((type_text:gsub("%s+", " "))),
    decl = vim.trim(line),
  }
end

local lombok_cache = {}
local function uses_lombok(buf)
  local tick = vim.b[buf].changedtick
  local hit = lombok_cache[buf]
  if hit and hit.tick == tick then return hit.value end
  local value = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, math.min(80, vim.api.nvim_buf_line_count(buf)), false)) do
    if l:find("lombok", 1, true) then value = true break end
  end
  lombok_cache[buf] = { tick = tick, value = value }
  return value
end

-- ── completion items ────────────────────────────────────────────────────────────────────────

---EL-visible members -> completion items. Properties (getX()/isX(), and fields of Lombok classes)
---first, then public non-accessor methods; setters are left out (they only back a property).
---Own class before superclasses; a name defined on both only once (the subclass one).
function M.member_items(members)
  local items, seen = {}, {}
  local function add(label, kind, detail, sort_group, m, insert)
    if seen[label] then return end
    seen[label] = true
    table.insert(items, {
      label = label,
      kind = kind,
      detail = detail,
      labelDetails = { description = m.owner },
      insertText = insert or label,
      filterText = insert or label,
      sortText = string.format("%d%02d%s", sort_group, m.depth, label),
    })
  end
  for _, m in ipairs(members) do
    local s = m.sym
    local info = decl_info(m.buf, s)
    if s.kind == SymbolKind.Method and not info.private and not info.protected and not info.static then
      local params = (s.raw_name or ""):match("%((.*)%)")
      local prop, is_accessor = el.property_name_for(s.name)
      if is_accessor and not s.name:match("^set") and (params == nil or params == "") then
        add(prop, ItemKind.Property, info.type, 0, m)
      elseif not is_accessor then
        add(s.name .. "(" .. (params or "") .. ")", ItemKind.Method, info.type, 1, m, s.name)
      end
    elseif (s.kind == SymbolKind.Field or s.kind == SymbolKind.Property) and not info.static
      and uses_lombok(m.buf) then
      add(s.name, ItemKind.Property, info.type, 0, m)
    end
  end
  return items
end

---Beans, page variables in scope, implicit objects.
function M.head_items(index, text, pos)
  local items = {}
  for name, bean in pairs(index and index.beans or {}) do
    table.insert(items, { label = name, kind = ItemKind.Class, detail = bean.fqcn,
      labelDetails = { description = "bean" }, sortText = "1" .. name })
  end
  for _, v in ipairs(el.page_variables(text, pos)) do
    table.insert(items, { label = v.name, kind = ItemKind.Variable,
      detail = (v.binding.iterate and "phần tử của " or "= ") .. v.binding.expr,
      labelDetails = { description = v.binding.tag }, sortText = "0" .. v.name })
  end
  for name in pairs(el.IMPLICIT_OBJECTS) do
    table.insert(items, { label = name, kind = ItemKind.Keyword, detail = "EL implicit object",
      sortText = "2" .. name })
  end
  return items
end

local function webapp_roots_of(project, file)
  local nav = require("java-debug-model.jsf.nav")
  local roots, seen = {}, {}
  local owner = project:find_module_for_file(file)
  local mods = owner and { owner } or {}
  vim.list_extend(mods, project.modules)
  for _, mod in ipairs(mods) do
    for _, r in ipairs(nav.webapp_roots(mod)) do
      if not seen[r] then seen[r] = true table.insert(roots, r) end
    end
  end
  return roots
end

---.xhtml paths for an include/template attribute: webapp-root-absolute ("/WEB-INF/x.xhtml")
---always, plus paths relative to the current file for files below its own directory.
local function include_items(project, file, text, cc)
  local range = { start = offset_to_position(text, cc.typed_s), ["end"] = offset_to_position(text, cc.typed_s + #cc.typed) }
  local items, seen = {}, {}
  local here = vim.fs.dirname(file)
  for _, root in ipairs(webapp_roots_of(project, file)) do
    for _, f in ipairs(vim.fn.globpath(root, "**/*.xhtml", false, true)) do
      f = vim.fs.normalize(f)
      if f ~= file then
        local paths = { "/" .. f:sub(#root + 2) }
        if vim.startswith(f, here .. "/") then table.insert(paths, f:sub(#here + 2)) end
        for _, p in ipairs(paths) do
          if not seen[p] then
            seen[p] = true
            table.insert(items, { label = p, kind = ItemKind.File, filterText = p,
              textEdit = { range = range, newText = p }, sortText = (p:sub(1, 1) == "/" and "1" or "0") .. p })
          end
        end
      end
    end
  end
  return items
end

local function composite_items(project, file, text, cc)
  local lib = el.composite_namespaces(text)[cc.prefix]
  if not lib then return {} end
  local items, seen = {}, {}
  for _, root in ipairs(webapp_roots_of(project, file)) do
    for _, f in ipairs(vim.fn.globpath(root .. "/resources/" .. lib, "*.xhtml", false, true)) do
      local tag = vim.fn.fnamemodify(f, ":t:r")
      if not seen[tag] then
        seen[tag] = true
        table.insert(items, { label = tag, kind = ItemKind.Module, detail = "resources/" .. lib .. "/" .. tag .. ".xhtml" })
      end
    end
  end
  return items
end

-- ── handlers ────────────────────────────────────────────────────────────────────────────────

---Runs `fn(ctx)` inside resolve.run with a jdtls-backed ctx; `fallback(msg?)` when there's no
---jdtls client or resolution fails.
local function with_ctx(buf, text, fn, fallback)
  local root = jdm().find_root(buf)
  bean_index.get(root, function(index)
    local client = resolve.client_for(root)
    if not client then
      fallback("jdtls chưa chạy", index)
      return
    end
    local ctx = { client = client, index = index, text = text, file = vim.api.nvim_buf_get_name(buf),
      binding = function(name, at) return el.find_var_binding(text, at, name) end }
    resolve.run(function() fn(ctx) end, function(msg) fallback(msg, index) end)
  end)
end

local handlers = {}

function handlers.initialize(_, reply)
  reply(nil, {
    capabilities = {
      positionEncoding = ENCODING,
      textDocumentSync = 0, -- buffers are read directly (same process), nothing to sync
      completionProvider = { triggerCharacters = { ".", "{", "[", "'", "\"", "/", ":" } },
      hoverProvider = true,
      definitionProvider = true,
    },
    serverInfo = { name = M.name },
  })
end

function handlers.shutdown(_, reply)
  reply(nil, vim.NIL)
end

handlers["textDocument/completion"] = function(params, reply)
  local buf, text, pos = locate(params)
  local cc = el.completion_context(text, pos)
  if not cc then return reply(nil, EMPTY) end
  local file = vim.api.nvim_buf_get_name(buf)

  if cc.kind == "include" or cc.kind == "composite" then
    with_project(jdm().find_root(buf), function(project)
      if not project then return reply(nil, EMPTY) end
      local items = cc.kind == "include" and include_items(project, file, text, cc)
        or composite_items(project, file, text, cc)
      reply(nil, { isIncomplete = false, items = items })
    end)
    return
  end

  if cc.kind == "head" then
    bean_index.get(jdm().find_root(buf), function(index)
      reply(nil, { isIncomplete = false, items = M.head_items(index, text, pos) })
    end)
    return
  end

  with_ctx(buf, text, function(ctx)
    local t = resolve.type_of(ctx, cc.parsed, cc.typed_s)
    reply(nil, { isIncomplete = false, items = M.member_items(resolve.members_of(ctx, t)) })
  end, function() reply(nil, EMPTY) end)
end

handlers["textDocument/hover"] = function(params, reply)
  local buf, text, pos = locate(params)
  local parsed = el.parse_el(text, pos)
  if not parsed then return reply(nil, vim.NIL) end
  with_ctx(buf, text, function(ctx)
    local target = resolve.resolve(ctx, parsed, pos)
    local value
    if target.kind == "binding" then
      local b = target.binding
      value = string.format("```xml\n<%s var=\"%s\" ...>\n```\n%s `%s`", b.tag, parsed.bean,
        b.iterate and "phần tử của" or "=", b.expr)
    elseif target.kind == "class" then
      local bean = bean_index.pick(ctx.index, parsed.bean, ctx.file)
      value = string.format("```java\n%s\n```\nbean `%s` — `%s`",
        target.sym and decl_info(target.buf, target.sym).decl or bean.class_name, parsed.bean, bean.fqcn)
    else
      local info = decl_info(target.buf, target.sym)
      value = string.format("```java\n%s\n```\n%s", info.decl:gsub("%s*{%s*$", ""), target.owner or "")
    end
    reply(nil, { contents = { kind = "markdown", value = value } })
  end, function() reply(nil, vim.NIL) end)
end

handlers["textDocument/definition"] = function(params, reply)
  local buf, text, pos = locate(params)
  local parsed = el.parse_el(text, pos)
  if not parsed then return reply(nil, vim.NIL) end
  with_ctx(buf, text, function(ctx)
    local target = resolve.resolve(ctx, parsed, pos)
    if target.kind == "binding" then
      local p = offset_to_position(text, target.binding.decl)
      return reply(nil, { uri = params.textDocument.uri, range = { start = p, ["end"] = p } })
    end
    local range = target.sym and target.sym.selection_range
      or { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }
    reply(nil, { uri = vim.uri_from_bufnr(target.buf), range = range })
  end, function() reply(nil, vim.NIL) end)
end

-- ── in-process transport ────────────────────────────────────────────────────────────────────

---`cmd` for vim.lsp.start: builds the in-process "RPC client" Neovim talks to.
function M.cmd(dispatchers)
  local closing, next_id = false, 0
  local srv = {}
  function srv.request(method, params, callback, notify_reply_callback)
    next_id = next_id + 1
    local id = next_id
    local replied = false
    local function reply(err, result)
      if replied then return end
      replied = true
      callback(err, result)
      if notify_reply_callback then notify_reply_callback(id) end
    end
    local handler = handlers[method]
    vim.schedule(function()
      if not handler then
        return reply({ code = -32601, message = "jsf-el: method not supported: " .. method }, nil)
      end
      local ok, err = pcall(handler, params, reply)
      if not ok then reply({ code = -32603, message = "jsf-el: " .. tostring(err) }, nil) end
    end)
    return true, id
  end
  function srv.notify(method)
    if method == "exit" then
      closing = true
      dispatchers.on_exit(0, 0)
    end
    return true
  end
  function srv.is_closing() return closing end
  function srv.terminate() closing = true end
  return srv
end

---Starts (or reuses, one per project root) the server for an .xhtml buffer.
function M.attach(bufnr)
  local client_id = vim.lsp.start({ name = M.name, cmd = M.cmd, root_dir = jdm().find_root(bufnr) }, { bufnr = bufnr })
  if client_id then
    require("java-debug-model.completion").attach(client_id, bufnr, jdm().opts.native_completion)
  end
end

return M
