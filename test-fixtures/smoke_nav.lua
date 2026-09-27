-- Smoke test for lua/java-debug-model/nav.lua (IntelliJ Ctrl+B/Ctrl+Alt+B parity): go to
-- declaration, go to implementation(s), and the supertypes/subtypes type hierarchy picker.
-- Exercises the real LSP methods against a real jdtls instance - no request is faked/stubbed.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-jdtls"))

local root = vim.fn.getcwd() .. "/test-fixtures/sample-project"
local jdtls_bin = vim.fn.expand("~/.local/share/nvim/nvim-java/packages/jdtls/1.54.0/bin/jdtls")

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")

local jdtls = require("jdtls")
local nav = require("java-debug-model.nav")
local attached = false

local impl_file = root .. "/module-a/src/main/java/com/example/modulea/GreetableImpl.java"
local greetable_file = root .. "/module-a/src/main/java/com/example/modulea/Greetable.java"

local jdtls_cfg = {
  cmd = { jdtls_bin, "-data", workspace },
  root_dir = root,
  on_attach = function() attached = true end,
}

vim.cmd("edit " .. impl_file)
jdtls.start_or_attach(jdtls_cfg)

vim.wait(120000, function() return attached end, 200)
assert(attached, "jdtls did not attach within timeout")
print("jdtls attached")

-- give jdt.ls a moment to finish initial project import/indexing
vim.wait(20000, function() return false end, 1000)

local function current_file()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
end

-- Two things this raw (no full plugin init, `-u NONE`) test harness has to do by hand that a
-- real java-debug-model install does automatically:
-- 1) Re-`:edit`-ing a buffer that's ALREADY current/unmodified detaches its jdtls client for a
--    moment (confirmed separately, reproducible with no LSP request in between) - so this only
--    switches file when the wanted buffer isn't already current.
-- 2) A buffer opened by an LSP jump (vim.lsp.util.show_document, used by go_to_declaration/
--    go_to_implementations/type_hierarchy) has no 'filetype' set and no jdtls client attached -
--    in a real install, jdtls_launcher.lua's own FileType autocmd (opts.auto_attach) is what
--    calls start_or_attach() for every new java buffer; here that's done explicitly instead.
--    start_or_attach() itself is idempotent for a buffer already attached to the same root_dir's
--    client, so calling it again for the ORIGINAL buffer here is harmless.
local function ensure_buffer(file)
  if current_file() ~= file then
    vim.cmd("edit " .. file)
  end
  vim.bo.filetype = "java"
  jdtls.start_or_attach(jdtls_cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local ok = vim.wait(15000, function()
    return #vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" }) > 0
  end, 100)
  assert(ok, "jdtls client did not (re)attach to " .. file)
  return bufnr
end

-- 1) Ctrl+B on "Greetable" in "implements Greetable" -> jumps to the interface declaration.
ensure_buffer(impl_file)
vim.fn.cursor(1, 1)
vim.fn.search([[implements \zsGreetable]]) -- lands right on the "Greetable" token itself
nav.go_to_declaration()
vim.wait(15000, function() return current_file() == greetable_file end, 100)
assert(current_file() == greetable_file, "go_to_declaration should jump from `implements Greetable` to Greetable.java, got " .. current_file())
print("go_to_declaration: OK")

-- 2) Ctrl+Alt+B on the Greetable interface name -> jumps to GreetableImpl, its implementation.
ensure_buffer(greetable_file)
vim.fn.cursor(1, 1)
vim.fn.search([[interface \zsGreetable]]) -- the `Greetable` interface name itself
nav.go_to_implementations()
vim.wait(15000, function() return current_file() == impl_file end, 100)
assert(current_file() == impl_file, "go_to_implementations should jump from Greetable to its implementation GreetableImpl.java, got " .. current_file())
print("go_to_implementations: OK")

-- 3) Type hierarchy: subtypes of Greetable -> GreetableImpl (single result, auto-jumps).
local bufnr = ensure_buffer(greetable_file)
vim.fn.cursor(1, 1)
vim.fn.search([[interface \zsGreetable]])
nav.type_hierarchy(bufnr, "subtypes")
vim.wait(15000, function() return current_file() == impl_file end, 100)
assert(current_file() == impl_file, "type_hierarchy(subtypes) from Greetable should land on GreetableImpl.java, got " .. current_file())
print("type_hierarchy(subtypes): OK")

-- 4) Type hierarchy: supertypes of GreetableImpl -> includes Greetable (also java.lang.Object,
-- since GreetableImpl is a class - use the raw fetch here rather than type_hierarchy()'s
-- auto-jump, which only fires for a single-item result).
bufnr = ensure_buffer(impl_file)
vim.fn.cursor(1, 1)
vim.fn.search([[class \zsGreetableImpl]])
local supertypes
nav.fetch_type_hierarchy(bufnr, "supertypes", function(items) supertypes = items end)
vim.wait(15000, function() return supertypes ~= nil end, 100)
assert(supertypes, "fetch_type_hierarchy(supertypes) should not error")
print("supertypes of GreetableImpl: " .. vim.inspect(vim.tbl_map(function(it) return it.name end, supertypes)))
local has_greetable = false
for _, it in ipairs(supertypes) do
  if it.name == "Greetable" then has_greetable = true end
end
assert(has_greetable, "GreetableImpl's supertypes should include Greetable")
print("fetch_type_hierarchy(supertypes): OK")

-- 5) Ctrl+B invoked ON the declaration itself (the `greet` method name inside the Greetable
-- interface, not a usage of it) -> IntelliJ shows usages instead of "jumping to itself"; here
-- that means populating the quickfix list via show_usages(). GreetableCaller.call() is a real
-- usage distinct from GreetableImpl's override.
bufnr = ensure_buffer(greetable_file)
vim.fn.cursor(1, 1)
vim.fn.search([[String \zsgreet]])
vim.fn.setqflist({}) -- clear from any earlier run, so the assertion below can't pass on stale state
nav.go_to_declaration()
vim.wait(15000, function() return #vim.fn.getqflist() > 0 end, 100)
local qf = vim.fn.getqflist()
print("usages of Greetable.greet: " .. vim.inspect(vim.tbl_map(function(e) return vim.fn.bufname(e.bufnr) end, qf)))
assert(#qf > 0, "go_to_declaration on the declaration itself should list usages via the quickfix list, got none")
print("go_to_declaration (on declaration -> show usages): OK")

print("nav.lua smoke test: OK")
vim.cmd("qa!")
