-- Smoke test for jsf/server.lua ("jsf-el" in-process LSP server): EL completion, hover and
-- definition on .xhtml buffers, against a real jdtls + the real Maven-resolved Project Model.
-- Requests go through Neovim's own LSP client machinery (vim.lsp.buf_request_sync) exactly like
-- nvim-cmp's nvim_lsp source would send them - nothing is stubbed.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))
vim.cmd("filetype on")

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local jdtls_bin = vim.fn.expand("~/.local/share/nvim/nvim-java/packages/jdtls/1.54.0/bin/jdtls")
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
local xhtml_file = root .. "/module-a/src/main/webapp/hello.xhtml"
local bean_file = root .. "/module-a/src/main/java/com/example/modulea/HelloBean.java"

local jdtls = require("jdtls")
local jdtls_cfg = { cmd = { jdtls_bin, "-data", workspace }, root_dir = root }
vim.api.nvim_create_autocmd("FileType", {
  pattern = "java",
  callback = function() jdtls.start_or_attach(jdtls_cfg) end,
})
require("java-debug-model.jsf.nav").setup()

vim.cmd("edit " .. bean_file)
assert(vim.wait(120000, function() return #vim.lsp.get_clients({ bufnr = 0, name = "jdtls" }) > 0 end, 200),
  "jdtls did not attach")
vim.wait(20000, function() return false end, 1000)
print("jdtls attached")

vim.cmd("edit " .. xhtml_file)
local xbuf = vim.api.nvim_get_current_buf()
assert(vim.wait(5000, function() return #vim.lsp.get_clients({ bufnr = xbuf, name = "jsf-el" }) > 0 end, 50),
  "jsf-el server should attach to the .xhtml buffer")
print("jsf-el attached")

local function eq(a, b, what)
  assert(vim.deep_equal(a, b), what .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

---Inserts `text` as a new line after the first line matching `after_pattern` (vim regex), puts
---the cursor at its end, and returns the LSP position there.
local function type_line(text, after_pattern)
  vim.cmd("silent! undo 0") -- back to the pristine file for every probe
  vim.fn.cursor(1, 1)
  local lnum = vim.fn.search(after_pattern)
  assert(lnum > 0, "pattern not found: " .. after_pattern)
  vim.api.nvim_buf_set_lines(xbuf, lnum, lnum, false, { text })
  vim.api.nvim_win_set_cursor(0, { lnum + 1, #text })
  return { line = lnum, character = #text }
end

local function request(method, position)
  local params = { textDocument = { uri = vim.uri_from_bufnr(xbuf) }, position = position }
  local responses = vim.lsp.buf_request_sync(xbuf, method, params, 30000) or {}
  for id, resp in pairs(responses) do
    if vim.lsp.get_client_by_id(id).name == "jsf-el" then
      assert(not resp.err, method .. " error: " .. vim.inspect(resp.err))
      return resp.result
    end
  end
  error("no jsf-el response for " .. method)
end

local function labels(text, after_pattern)
  local result = request("textDocument/completion", type_line(text, after_pattern))
  local out = {}
  for _, item in ipairs(result.items or result) do out[item.label] = item end
  return out
end

local function has(items, names, what)
  for _, n in ipairs(names) do
    assert(items[n], what .. ": missing '" .. n .. "' in " .. vim.inspect(vim.tbl_keys(items)))
  end
end
local function lacks(items, names, what)
  for _, n in ipairs(names) do
    assert(not items[n], what .. ": '" .. n .. "' should not be offered")
  end
end

local BODY = [[<h:body>]]

-- 1) #{  -> beans + implicit objects
local items = labels([[    <h:outputText value="#{]], BODY)
has(items, { "helloBean", "param", "flash" }, "#{")
eq(items.helloBean.detail, "com.example.modulea.HelloBean", "bean item detail")
print("complete #{ (beans/implicit objects): OK")

-- 2) #{helloBean.  -> properties (own + inherited) and methods; no setters, no Object members
items = labels([[    <h:outputText value="#{helloBean.]], BODY)
has(items, { "name", "active", "address", "items", "version", "sayHello()" }, "#{helloBean.")
lacks(items, { "setName", "setName(String)", "getName", "class", "hashCode()" }, "#{helloBean.")
eq(items.address.detail, "Address", "property type detail")
eq(items.items.detail, "List<Item>", "generic property type detail")
eq(items.version.labelDetails.description, "BaseBean", "inherited property shows its declaring class")
eq(items["sayHello()"].insertText, "sayHello", "method inserts its bare name")
print("complete #{helloBean. : OK " .. vim.inspect(vim.tbl_keys(items)))

-- 3) chains, typed prefix, index, method call
has(labels([[    <h:outputText value="#{helloBean.address.]], BODY), { "city", "country" }, "a.b.")
has(labels([[    <h:outputText value="#{helloBean.address.country.na]], BODY), { "name" }, "a.b.c.<typed>")
has(labels([[    <h:outputText value="#{helloBean.items[0].]], BODY), { "label" }, "list[0].")
has(labels([[    <h:outputText value="#{helloBean.getAddress().]], BODY), { "city" }, "getB().")
has(labels([[    <h:outputText value="#{helloBean.name.]], BODY), { "bytes", "empty", "length()" }, "String (JDK)")
print("complete chains / index / call / library type: OK")

-- 4) page variables: inside <ui:repeat var="item">
items = labels([[        <h:outputText value="#{]], [[#{item\.label}]])
has(items, { "item", "helloBean" }, "#{ inside ui:repeat")
lacks(items, { "addr" }, "#{ inside ui:repeat (<c:set var=addr> is declared further down)")
eq(items.item.detail, "phần tử của #{helloBean.items}", "page variable detail")
has(labels([[        <h:outputText value="#{item.]], [[#{item\.label}]]), { "label" }, "item.")
has(labels([[    <h:outputText value="#{addr.]], [[addr\.country]]), { "city", "country" }, "c:set var.")
print("complete page variables: OK")

-- 5) include paths and composite tags
items = labels([[    <ui:include src="/]], BODY)
has(items, { "/WEB-INF/includes/header.xhtml", "/resources/comp/greeting.xhtml" }, "include src")
lacks(items, { "/hello.xhtml" }, "include src (the file itself)")
has(labels([[    <comp:]], BODY), { "greeting" }, "composite tag")
print("complete include paths / composite tags: OK")

-- 6) hover + definition
local pos = type_line([[    <h:outputText value="#{helloBean.address.city}"/>]], BODY)
pos.character = pos.character - 6 -- on "city"
local hover = request("textDocument/hover", pos)
assert(hover and hover.contents.value:find("getCity", 1, true) and hover.contents.value:find("Address", 1, true),
  "hover should show Address.getCity's declaration, got " .. vim.inspect(hover))
print("hover: OK")
local def = request("textDocument/definition", pos)
assert(def and def.uri:match("Address%.java$"), "definition should point at Address.java, got " .. vim.inspect(def))
print("definition: OK")

-- 7) nothing to complete outside EL/paths
local none = request("textDocument/completion", type_line([[    <h:outputText value="]], BODY))
eq(#(none.items or none), 0, "plain attribute")
print("no JSF completion outside EL: OK")

print("jsf completion smoke test: OK")
vim.cmd("qa!")
