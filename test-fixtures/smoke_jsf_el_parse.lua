-- Pure unit assertions for lua/java-debug-model/jsf/el.lua + bean_index.parse_bean_file - no
-- jdtls, no mvn. Run: nvim --headless -u NONE -l test-fixtures/smoke_jsf_el_parse.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local el = require("java-debug-model.jsf.el")
local bean_index = require("java-debug-model.jsf.bean_index")

local function eq(actual, expected, what)
  assert(vim.deep_equal(actual, expected),
    what .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

---Column of the first occurrence of `marker` in `line` (1-based), for readable cursor placement.
local function at(line, marker, offset)
  return assert(line:find(marker, 1, true), "marker not in line: " .. marker) + (offset or 0)
end

---Compact view of a parse_el result: { bean, target, kind, member, path = "a.b(). [].c" }.
local function P(text, pos)
  local r = el.parse_el(text, pos)
  if not r then return nil end
  local parts = {}
  for _, seg in ipairs(r.chain) do
    table.insert(parts, seg.element and "[]" or (seg.name .. (seg.call and "()" or "") .. (seg.bracket and "'" or "")))
  end
  return { bean = r.bean, target = r.target, kind = r.kind, member = r.member, path = table.concat(parts, ".") }
end
local function R(bean, path, target, kind, member)
  return { bean = bean, path = path, target = target, kind = kind, member = member }
end

-- EL: property / method / bean-only / cursor outside
local l = [[<h:outputText value="#{helloBean.name}"/>]]
eq(P(l, at(l, "name}")), R("helloBean", "name", 1, "property", "name"), "property on member")
eq(P(l, at(l, "helloBean")), R("helloBean", "name", 0, "bean"), "cursor on bean name")
eq(P(l, at(l, "#{")), R("helloBean", "name", 1, "property", "name"), "cursor on #{")
eq(P(l, at(l, "outputText")), nil, "outside EL")

l = [[<h:commandButton action="#{helloBean.sayHello()}"/>]]
eq(P(l, at(l, "sayHello")), R("helloBean", "sayHello()", 1, "method", "sayHello"), "method call")
l = [[<h:commandButton action="#{helloBean.save}"/>]]
eq(P(l, at(l, "save")), R("helloBean", "save", 1, "property", "save"), "method expression w/o parens")
l = [[<h:commandButton action="#{helloBean.save(item, 'x}y')}"/>]]
eq(P(l, at(l, "save")), R("helloBean", "save()", 1, "method", "save"), "brace inside string arg")
l = [[#{helloBean.save(item.id, other)}]]
eq(P(l, at(l, "id")), R("item", "id", 1, "property", "id"), "chain inside call arguments")
eq(P(l, at(l, "other")), R("other", "", 0, "bean"), "bare arg")

-- several chains in one expression / several expressions on one line
l = [[<p:x rendered="#{empty a.list ? b.first : c.second}" v="${d.e}"/>]]
eq(P(l, at(l, "list")), R("a", "list", 1, "property", "list"), "chain 1")
eq(P(l, at(l, "first")), R("b", "first", 1, "property", "first"), "chain 2")
eq(P(l, at(l, "c.second", 2)), R("c", "second", 1, "property", "second"), "chain 3")
eq(P(l, at(l, "empty")), R("a", "list", 1, "property", "list"), "keyword -> first chain")
eq(P(l, at(l, "d.e", 2)), R("d", "e", 1, "property", "e"), "${} second expression")
l = [[#{fn:length(bean.items) gt 0}]]
eq(P(l, at(l, "items")), R("bean", "items", 1, "property", "items"), "EL function arg")
eq(P(l, at(l, "length")), R("bean", "items", 1, "property", "items"), "EL function name is not a chain")

-- deep chains: the segment under the cursor is the target
l = [[#{bean.address.country.name}]]
eq(P(l, at(l, "address")), R("bean", "address.country.name", 1, "property", "address"), "a.B.c.d")
eq(P(l, at(l, "country")), R("bean", "address.country.name", 2, "property", "country"), "a.b.C.d")
eq(P(l, at(l, "name")), R("bean", "address.country.name", 3, "property", "name"), "a.b.c.D")
l = [[#{bean.getAddress().city}]]
eq(P(l, at(l, "city")), R("bean", "getAddress().city", 2, "property", "city"), "method call mid-chain")
eq(P(l, at(l, "getAddress")), R("bean", "getAddress().city", 1, "method", "getAddress"), "the call itself")
l = [[#{bean['address'].city}]]
eq(P(l, at(l, "address")), R("bean", "address'.city", 1, "property", "address"), "bracket property")
eq(P(l, at(l, "city")), R("bean", "address'.city", 2, "property", "city"), "after bracket property")
l = [[#{bean.items[i.index].label}]]
eq(P(l, at(l, "label")), R("bean", "items.[].label", 3, "property", "label"), "index access")
eq(P(l, at(l, "index")), R("i", "index", 1, "property", "index"), "chain inside index")
l = [[#{justBean}]]
eq(P(l, 4), R("justBean", "", 0, "bean"), "bare bean")
eq(P("#{bean.x", 3), nil, "unterminated EL")

-- multi-line EL / attribute
local ml = "<h:outputText\n    value=\"#{bean.address\n              .city}\"/>"
eq(P(ml, at(ml, "city")), R("bean", "address.city", 2, "property", "city"), "EL spanning lines")
eq({ el.offset_to_pos(ml, at(ml, "city")) }, { 3, 15 }, "offset_to_pos")

-- page variables
local page = table.concat({
  [[<c:set var="addr" value="#{bean.address}"/>]],
  [[<ui:repeat var="item" value="#{bean.items}">]],
  [[  #{item.label} #{addr.city}]],
  [[</ui:repeat>]],
  [[#{item.label}]],
  [[<ui:param name="p" value="#{bean.p}"/> #{p.x}]],
}, "\n")
local function binding(marker, name)
  local b = el.find_var_binding(page, at(page, marker), name)
  return b and { tag = b.tag, expr = b.expr, iterate = b.iterate } or nil
end
eq(binding("item.label}", "item"), { tag = "ui:repeat", expr = "#{bean.items}", iterate = true }, "ui:repeat var")
eq(binding("addr.city", "addr"), { tag = "c:set", expr = "#{bean.address}", iterate = false }, "c:set var")
eq(binding("p.x", "p"), { tag = "ui:param", expr = "#{bean.p}", iterate = false }, "ui:param")
local after = page:find("#{item.label}", page:find("</ui:repeat>"), true)
eq(el.find_var_binding(page, after + 3, "item"), nil, "var out of scope after </ui:repeat>")
eq(el.parse_expression("#{bean.items}").chain[1].name, "items", "parse_expression")

-- type_token: which identifier of a declaration prefix names the (element) type
local function tt(prefix, element)
  local s, e = el.type_token(prefix, element)
  return s and prefix:sub(s, e) or nil
end
eq(tt("    public Address "), "Address", "plain type")
eq(tt("    public com.acme.Address "), "Address", "qualified type")
eq(tt("    private List<Item> "), "List", "generic, own type")
eq(tt("    private List<Item> ", true), "Item", "generic, element")
eq(tt("    public Map<String, List<Item>> ", true), "List", "Map value type")
eq(tt("    public List<? extends Item> ", true), "Item", "wildcard")
eq(tt("    public Item[] ", true), "Item", "array element")
eq(tt("    public Item [ ] "), "Item", "array own type")
eq(tt("    public String ", true), nil, "non-collection has no element type")
eq(tt("    public int "), "int", "primitive (definition lookup will fail later)")

-- include / template paths
l = [[    <ui:include src="/WEB-INF/includes/header.xhtml"/>]]
eq(el.parse_include_path(l, at(l, "header")), { path = "/WEB-INF/includes/header.xhtml" }, "ui:include src")
eq(el.parse_include_path(l, at(l, "ui:include")), nil, "cursor on tag name, not value")
l = [[<ui:composition template="layout.xhtml" xmlns:ui="jakarta.faces.facelets">]]
eq(el.parse_include_path(l, at(l, "layout")), { path = "layout.xhtml" }, "ui:composition template")
eq(el.parse_include_path(l, at(l, "faces.facelets")), nil, "other attribute on same tag")
l = [[<ui:decorate template='/t.xhtml'>]]
eq(el.parse_include_path(l, at(l, "t.xhtml")), { path = "/t.xhtml" }, "single quotes")
l = [[<c:import url="/frag.jsp"/>]]
eq(el.parse_include_path(l, at(l, "frag")), { path = "/frag.jsp" }, "c:import url")
local mi = "<ui:include\n    src=\"/WEB-INF/x.xhtml\">\n  <ui:param name=\"a\" value=\"#{b > c}\"/>"
eq(el.parse_include_path(mi, at(mi, "x.xhtml")), { path = "/WEB-INF/x.xhtml" }, "multi-line ui:include")
l = [[<h:graphicImage src="/img/a.png"/>]]
eq(el.parse_include_path(l, at(l, "img")), nil, "src on an unrelated tag")

-- composite components
local ns = el.composite_namespaces({
  [[<html xmlns:comp="jakarta.faces.composite/comp"]],
  [[      xmlns:old="http://java.sun.com/jsf/composite/legacy/widgets"]],
  [[      xmlns:h="jakarta.faces.html">]],
})
eq(ns, { comp = "comp", old = "legacy/widgets" }, "composite namespaces")
l = [[    <comp:greeting who="#{helloBean.name}"/>]]
eq(el.parse_composite_tag(l, at(l, "greeting"), ns), { library = "comp", tag = "greeting" }, "composite tag")
eq(el.parse_composite_tag(l, at(l, "who"), ns), nil, "cursor off the tag name")
eq(el.parse_composite_tag([[<h:form>]], 3, ns), nil, "non-composite prefix")

-- completion context (cursor at the END of the text = what's typed so far)
local function CC(text)
  local r = el.completion_context(text, #text + 1)
  if not r then return nil end
  assert(r.typed_s == #text + 1 - #r.typed, "typed_s must point at the start of the typed word: " .. text)
  local out = { kind = r.kind, typed = r.typed, prefix = r.prefix }
  if r.parsed then
    local parts = {}
    for _, seg in ipairs(r.parsed.chain) do table.insert(parts, seg.element and "[]" or seg.name) end
    out.chain = r.parsed.bean .. (#parts > 0 and ("." .. table.concat(parts, ".")) or "")
  end
  return out
end
eq(CC([[<h:outputText value="#{]]), { kind = "head", typed = "" }, "#{ -> head")
eq(CC([[value="#{hel]]), { kind = "head", typed = "hel" }, "typing a head")
eq(CC([[#{empty helloBean.items and it]]), { kind = "head", typed = "it" }, "head after operator")
eq(CC([[#{helloBean.]]), { kind = "member", typed = "", chain = "helloBean" }, "bean.")
eq(CC([[#{helloBean.addr]]), { kind = "member", typed = "addr", chain = "helloBean" }, "bean.typing")
eq(CC([[#{helloBean.address.co]]).chain, "helloBean.address", "a.b.typing")
eq(CC([[#{helloBean.items[0].]]).chain, "helloBean.items.[]", "after index")
eq(CC([[#{helloBean.getAddress().]]).chain, "helloBean.getAddress", "after call")
eq(CC([[#{helloBean['na]]), { kind = "member", typed = "na", chain = "helloBean" }, "bracket")
eq(CC([[#{bean.save(item.]]).chain, "item", "inside call args")
eq(CC("#{helloBean\n   .address.\n  "), { kind = "member", typed = "", chain = "helloBean.address" },
  "whitespace/newlines after the dot are still member position")
eq(CC([[#{1.]]), nil, "number")
eq(CC([[#{fn:len]]), nil, "EL function name")
eq(CC([[#{'abc]]), nil, "inside string literal")
eq(CC([[#{a.b} ]]), nil, "closed expression")
eq(CC([[<ui:include src="/WEB]]), { kind = "include", typed = "/WEB" }, "include src")
eq(CC("<ui:composition\n   template='"), { kind = "include", typed = "" }, "multi-line template attr")
eq(CC([[<comp:gre]]), { kind = "composite", prefix = "comp", typed = "gre" }, "composite tag")
eq(CC([[<h:outputText value="]]), nil, "plain attribute")

-- page variables in scope
eq(vim.tbl_map(function(v) return v.name end, el.page_variables(page, at(page, "item.label}"))),
  { "addr", "item" }, "page_variables inside ui:repeat")
eq(vim.tbl_map(function(v) return v.name end, el.page_variables(page, #page)),
  { "addr", "p" }, "page_variables after </ui:repeat>")

-- naming helpers
eq(el.decapitalize("HelloBean"), "helloBean", "decapitalize")
eq(el.decapitalize("URLBean"), "uRLBean", "CDI decapitalize")
eq(el.decapitalize("URLBean", true), "URLBean", "Introspector decapitalize")
eq({ el.property_name_for("getName") }, { "name", true }, "getter")
eq({ el.property_name_for("isActive") }, { "active", true }, "is-getter")
eq({ el.property_name_for("getURL") }, { "URL", true }, "getter, Introspector rule")
eq({ el.property_name_for("sayHello") }, { "sayHello", false }, "plain method")
eq({ el.property_name_for("gettysburg") }, { "gettysburg", false }, "not an accessor")

-- bean_index.parse_bean_file
local function bean(src, file)
  return bean_index.parse_bean_file(vim.split(src, "\n"), file or "/x/Foo.java")
end
eq(bean([[
package com.acme;
@Named
@RequestScoped
public class HelloBean {}]]), { name = "helloBean", class_name = "HelloBean", fqcn = "com.acme.HelloBean", file = "/x/Foo.java" }, "@Named default")
eq(bean([[
package com.acme;
@Named("greeter")
public class HelloBean {}]]).name, "greeter", "@Named(\"x\")")
eq(bean([[
@ManagedBean(name = "legacy", eager = true)
class OldBean {}]]).name, "legacy", "@ManagedBean(name=)")
eq(bean([[
@ManagedBean
class OldBean {}]]).name, "oldBean", "@ManagedBean default")
eq(bean([[
@Component(value = "springy")
public class S {}]]).name, "springy", "@Component(value=)")
eq(bean([[
@Service
public class URLService {}]]).name, "URLService", "Spring default uses Introspector rule")
eq(bean([[
/** This class is not a bean. */
public class Plain {
  @Inject @Named("x") Foo foo;
}]]), nil, "@Named on an injection point is not a bean definition")

-- no-jdtls fallback: declaration-only search (regression: used to land on a CALL like
-- `if (isBlankOrNull(getComputing().getName()))`, the first textual occurrence)
local nav = require("java-debug-model.jsf.nav")
local function decl(line, name, is_method)
  return vim.fn.match(line, nav.declaration_pattern(name, is_method)) >= 0
end
for _, c in ipairs({
  { "    public Computing getComputing() {", "getComputing", true, true },
  { "        if (vn.longvan.core.utils.StringUtils.isBlankOrNull(getComputing().getName())) {", "getComputing", true, false },
  { "        if (x.isBlankOrNull(getComputing().getName())) {", "getName", true, false },
  { "        return getComputing();", "getComputing", true, false },
  { "        getComputing().setType(VMTypeEnum.VM);", "getComputing", true, false },
  { "    @Override public List<Map<String, Item[]>> getItems() {", "getItems", true, true },
  { "    public abstract String getVersion();", "getVersion", true, true },
  { "    private Computing computing;", "computing", false, true },
  { "    @Column(name = \"x\") protected String name;", "name", false, true },
  { "            computing = new Computing();", "computing", false, false },
  { "        computing.setPartnerId(x);", "computing", false, false },
}) do
  eq(decl(c[1], c[2], c[3]), c[4], "declaration_pattern: " .. c[1])
end

-- same bean name in two apps of one repo -> the one closest to the page
local app_a = { name = "handler", file = "/r/app-a/src/main/java/x/Handler.java" }
local app_b = { name = "handler", file = "/r/app-b/src/main/java/y/Handler.java" }
local idx = { beans = { handler = app_a }, candidates = { handler = { app_a, app_b } } }
eq(bean_index.pick(idx, "handler", "/r/app-b/src/main/webapp/p.xhtml"), app_b, "pick nearest duplicate bean")
eq(bean_index.pick(idx, "handler", "/r/app-a/src/main/webapp/p.xhtml"), app_a, "pick nearest duplicate bean (a)")
eq(bean_index.pick(idx, "nope", "/r/app-a/p.xhtml"), nil, "unknown bean")

print("jsf el parse smoke test: OK")
vim.cmd("qa!")
