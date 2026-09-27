-- Smoke test for lua/java-debug-model/jsf/nav.lua (JSF Facelets Ctrl+B) against a real jdtls and
-- a real Maven-resolved Project Model - nothing is stubbed. Covers all four directions:
-- EL property -> getter, EL method -> method, <ui:include>/composite tag -> file, and
-- Java bean member -> .xhtml usages via the quickfix list.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))
vim.cmd("filetype on") -- -u NONE skips it; the FileType autocmds below are the real wiring under test

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local jdtls_bin = vim.fn.expand("~/.local/share/nvim/nvim-java/packages/jdtls/1.54.0/bin/jdtls")
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")

local webapp = root .. "/module-a/src/main/webapp"
local xhtml_file = webapp .. "/hello.xhtml"
local bean_file = root .. "/module-a/src/main/java/com/example/modulea/HelloBean.java"

local jdtls = require("jdtls")
local jsf_nav = require("java-debug-model.jsf.nav")
local bean_index = require("java-debug-model.jsf.bean_index")

local jdtls_cfg = { cmd = { jdtls_bin, "-data", workspace }, root_dir = root }
-- What opts.auto_attach (jdtls_launcher.lua's own FileType java autocmd) does in a real install.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "java",
  callback = function() jdtls.start_or_attach(jdtls_cfg) end,
})
jsf_nav.setup()

-- Warm jdtls up once on the bean file itself, so the jumps below measure navigation, not startup.
vim.cmd("edit " .. bean_file)
local ok = vim.wait(120000, function()
  return #vim.lsp.get_clients({ bufnr = 0, name = "jdtls" }) > 0
end, 200)
assert(ok, "jdtls did not attach within timeout")
vim.wait(20000, function() return false end, 1000) -- initial import/indexing
print("jdtls attached")

-- Bean index, built from the real resolved Project Model.
local index
bean_index.get(root, function(i) index = i end)
vim.wait(90000, function() return index ~= nil end, 200)
assert(index and index.beans.helloBean, "bean index should contain helloBean, got " .. vim.inspect(index))
assert(index.beans.helloBean.fqcn == "com.example.modulea.HelloBean", "helloBean fqcn")
print("bean index: OK " .. vim.inspect(vim.tbl_keys(index.beans)))

local function current_file()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
end

local function open_xhtml_at(pattern)
  if current_file() ~= xhtml_file then vim.cmd("edit " .. xhtml_file) end
  assert(vim.bo.filetype ~= "", ".xhtml should get a filetype")
  assert(vim.b.java_debug_model_jsf_nav, "jsf nav keymaps should be attached to the .xhtml buffer")
  vim.fn.cursor(1, 1)
  assert(vim.fn.search(pattern) > 0, "pattern not found in hello.xhtml: " .. pattern)
end

local java = root .. "/module-a/src/main/java/com/example/modulea/"
-- { label, cursor pattern in hello.xhtml, expected file (string, or predicate on the buffer name),
--   Lua pattern the landing line must match, expected M.last_jump_via (nil = file jump) }
local cases = {
  { "EL property -> getter", [[helloBean\.\zsname}]], bean_file, "getName%(", "jdtls" },
  { "EL method -> method", [[helloBean\.\zssayHello]], bean_file, "sayHello%(", "jdtls" },
  { "EL boolean property -> is-getter", [[helloBean\.\zsactive]], bean_file, "isActive%(", "jdtls" },
  { "ui:include", [[includes/\zsheader]], webapp .. "/WEB-INF/includes/header.xhtml", "" },
  { "composite component", [[<comp:\zsgreeting]], webapp .. "/resources/comp/greeting.xhtml", "" },
  { "a.b.C (chain, non-bean class)", [[helloBean\.address\.\zscity]], java .. "Address.java", "getCity%(", "jdtls" },
  { "a.B.c (middle of chain)", [[helloBean\.\zsaddress\.city]], bean_file, "getAddress%(", "jdtls" },
  { "a.b.c.D (4 deep)", [[address\.country\.\zsname]], java .. "Country.java", "getName%(", "jdtls" },
  { "a.getB().C", [[getAddress()\.\zscity]], java .. "Address.java", "getCity%(", "jdtls" },
  { "a.GetB().c", [[helloBean\.\zsgetAddress()]], bean_file, "getAddress%(", "jdtls" },
  { "a['b']", [[helloBean\['\zsname]], bean_file, "getName%(", "jdtls" },
  { "a.list[0].C (element type)", [[items\[0\]\.\zslabel]], java .. "Item.java", "getLabel%(", "jdtls" },
  { "inherited getter", [[helloBean\.\zsversion]], java .. "BaseBean.java", "getVersion%(", "jdtls" },
  { "library type (java.lang.String)", [[name\.\zsbytes]],
    function(name) return name:find("String", 1, true) ~= nil end, "getBytes%(", "jdtls" },
  { "ui:repeat var -> element type", [[{item\.\zslabel]], java .. "Item.java", "getLabel%(", "jdtls" },
  { "cursor on page variable -> its var=", [[{\zsitem\.label]], xhtml_file, 'var="item"', "page" },
  { "c:set var chain", [[addr\.country\.\zsname]], java .. "Country.java", "getName%(", "jdtls" },
  { "multi-line <ui:include>", [[^\s*src="\/WEB-INF\/includes\/\zsheader]], webapp .. "/WEB-INF/includes/header.xhtml", "" },
  { "multi-line EL", [[^\s*\.\zscountry]], java .. "Address.java", "getCountry%(", "jdtls" },
  { "getter-less field in a superclass (Lombok-style)", [[address\.\zszip]], java .. "Place.java", "zip", "jdtls" },
}

for _, c in ipairs(cases) do
  local label, pattern, want_file, want_line, want_via = unpack(c)
  open_xhtml_at(pattern)
  local start_line = vim.fn.line(".")
  jsf_nav.last_jump_via = nil
  jsf_nav.go_to_declaration_xhtml()
  local function file_ok()
    if type(want_file) == "function" then return want_file(vim.api.nvim_buf_get_name(0)) end
    return current_file() == want_file
  end
  local landed = vim.wait(30000, function()
    local moved = want_via ~= "page" or vim.fn.line(".") ~= start_line
    return moved and file_ok() and vim.api.nvim_get_current_line():find(want_line) ~= nil
  end, 100)
  assert(landed, string.format("%s: expected %s at /%s/, got %s:%d `%s`", label, tostring(want_file), want_line,
    vim.api.nvim_buf_get_name(0), vim.fn.line("."), vim.api.nvim_get_current_line()))
  if want_via then
    assert(jsf_nav.last_jump_via == want_via,
      string.format("%s: expected via %s, got %s", label, want_via, tostring(jsf_nav.last_jump_via)))
  end
  print(label .. ": OK")
end

---Runs find_xhtml_usages with the cursor on `pattern` in `file`; returns "hello.xhtml:<lnum>" list.
local function usages(file, pattern)
  vim.cmd("edit " .. file)
  vim.bo.filetype = "java"
  jdtls.start_or_attach(jdtls_cfg)
  local ok_attach = vim.wait(15000, function() return #vim.lsp.get_clients({ bufnr = 0, name = "jdtls" }) > 0 end, 100)
  assert(ok_attach, "jdtls should be attached to " .. file)
  vim.fn.cursor(1, 1)
  assert(vim.fn.search(pattern) > 0, "pattern not found: " .. pattern)
  vim.fn.setqflist({})
  local items
  jsf_nav.find_xhtml_usages(function(it) items = it end)
  vim.wait(20000, function() return items ~= nil end, 100)
  assert(items, "find_xhtml_usages should complete")
  local out = {}
  for _, e in ipairs(vim.fn.getqflist()) do
    table.insert(out, vim.fn.fnamemodify(vim.fn.bufname(e.bufnr), ":t") .. ":" .. e.lnum)
  end
  table.sort(out, function(a, b) return tonumber(a:match("%d+$")) < tonumber(b:match("%d+$")) end)
  return out
end

-- Java -> xhtml, bean member: #{helloBean.name}, #{helloBean['name']}, #{helloBean.name.bytes}
local u = usages(bean_file, [[\<getName\>]])
print("xhtml usages of helloBean.name: " .. vim.inspect(u))
local eq_list = function(a, b, what) assert(vim.deep_equal(a, b), what .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a)) end
eq_list(u, { "hello.xhtml:9", "hello.xhtml:12", "hello.xhtml:18", "hello.xhtml:21" }, "usages of HelloBean.getName")
print("Java -> xhtml usages (bean member): OK")

-- Java -> xhtml, member of a non-bean class (only reachable through a chain): by property name
u = usages(java .. "Address.java", [[\<getCity\>]])
print("xhtml usages of *.city: " .. vim.inspect(u))
eq_list(u, { "hello.xhtml:15", "hello.xhtml:17" }, "usages of Address.getCity")
print("Java -> xhtml usages (chained member): OK")

print("jsf nav smoke test: OK")
vim.cmd("qa!")
