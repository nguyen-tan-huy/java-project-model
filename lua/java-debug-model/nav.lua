-- IntelliJ Ctrl+B / Ctrl+Alt+B parity: go to declaration, go to implementation(s), and a
-- lightweight type hierarchy (supertypes/subtypes) picker. jdtls already implements every LSP
-- method this needs (textDocument/definition, textDocument/implementation, LSP 3.17's
-- textDocument/prepareTypeHierarchy + typeHierarchy/supertypes|subtypes) - this module is just
-- the IntelliJ-shaped keymaps/commands wired on top, no protocol handling of its own.
local M = {}

local function jdtls_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })[1]
end

---True when `loc` (a Location or LocationLink) points at the same file/line the cursor is
---already sitting on - i.e. textDocument/definition just echoed back "you're already here",
---which is what jdtls returns when invoked ON a declaration itself (a method name in an
---interface, a class name, ...) rather than on a usage of it.
---@param loc table
---@param bufnr integer
---@param position table  LSP Position of the request
local function location_is_current_position(loc, bufnr, position)
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  if not uri or not range then return false end
  return uri == vim.uri_from_bufnr(bufnr) and range.start.line == position.line
end

---IntelliJ Alt+F7 / the "Usages" half of Ctrl+B: every reference to the symbol under the
---cursor, in a quickfix list (excludes the declaration itself, matching IntelliJ's own Find
---Usages default) - this is what answers "hàm này trong interface đang được dùng ở những đâu".
function M.show_usages()
  vim.lsp.buf.references({ includeDeclaration = false })
end

---IntelliJ Ctrl+B: on a USAGE, jumps to the declaration/definition (a single result jumps
---directly, several open the quickfix list - jdtls resolves library sources with no
---`-sources.jar` into a decompiled jdt:// buffer on its own, no extra handling needed for that
---case). Invoked ON the declaration itself instead (e.g. cursor already on the method name
---inside an interface) - textDocument/definition just points back at the same spot, which is
---exactly IntelliJ's own cue to show every USAGE instead, so that's what this does too.
function M.go_to_declaration()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = jdtls_client(bufnr)
  if not client then
    vim.lsp.buf.definition()
    return
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/definition", params, function(err, result)
    if err then
      vim.notify("java-debug-model: definition lỗi: " .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end
    local defs = {}
    if result then
      defs = vim.islist(result) and result or { result }
    end
    if #defs == 0 then
      vim.notify("java-debug-model: không tìm thấy declaration tại vị trí con trỏ.", vim.log.levels.WARN)
      return
    end
    if #defs == 1 and location_is_current_position(defs[1], bufnr, params.position) then
      M.show_usages()
      return
    end
    vim.lsp.util.show_document(defs[1], client.offset_encoding, { focus = true })
    if #defs > 1 then
      vim.fn.setqflist({}, " ", {
        title = "Definitions",
        items = vim.lsp.util.locations_to_items(defs, client.offset_encoding),
      })
      vim.cmd("copen")
    end
  end, bufnr)
end

---IntelliJ Ctrl+Alt+B: from an interface/abstract class (or one of its methods) to every class
---(or override) that actually implements it.
function M.go_to_implementations()
  vim.lsp.buf.implementation()
end

---@param bufnr integer
---@param direction "supertypes"|"subtypes"
---@param on_done fun(items: table[])  each item shaped like an LSP TypeHierarchyItem
function M.fetch_type_hierarchy(bufnr, direction, on_done)
  local client = jdtls_client(bufnr)
  if not client then
    vim.notify("java-debug-model: jdtls chưa attach cho buffer này.", vim.log.levels.WARN)
    return
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/prepareTypeHierarchy", params, function(err, items)
    if err then
      vim.notify("java-debug-model: prepareTypeHierarchy lỗi: " .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end
    if not items or #items == 0 then
      vim.notify("java-debug-model: không tìm thấy type/class tại vị trí con trỏ.", vim.log.levels.WARN)
      return
    end
    client:request("typeHierarchy/" .. direction, { item = items[1] }, function(err2, results)
      if err2 then
        vim.notify("java-debug-model: " .. direction .. " lỗi: " .. vim.inspect(err2), vim.log.levels.ERROR)
        return
      end
      on_done(results or {})
    end, bufnr)
  end, bufnr)
end

function M.jump_to_item(item)
  vim.lsp.util.show_document({ uri = item.uri, range = item.selectionRange or item.range }, "utf-16",
    { focus = true })
end

---Picker over one level of an item's supertypes (extends/implements chain, "class kế thừa") or
---subtypes (implementing classes/overriding subclasses, "class implement") - IntelliJ's Ctrl+H
---Type Hierarchy view, minus the persistent tree window. One level per call; re-invoke from
---wherever you land to keep walking further up/down the chain.
---@param bufnr integer
---@param direction "supertypes"|"subtypes"
function M.type_hierarchy(bufnr, direction)
  M.fetch_type_hierarchy(bufnr, direction, function(items)
    if #items == 0 then
      vim.notify(
        "java-debug-model: không có " ..
        (direction == "supertypes" and "lớp cha/interface nào (đã ở gốc)." or "lớp con/implementation nào."),
        vim.log.levels.INFO)
      return
    end
    if #items == 1 then
      M.jump_to_item(items[1])
      return
    end
    vim.ui.select(items, {
      prompt = direction == "supertypes" and "Supertypes (extends/implements):" or "Subtypes (implementations):",
      format_item = function(it) return it.name .. (it.detail and ("  (" .. it.detail .. ")") or "") end,
    }, function(choice)
      if choice then M.jump_to_item(choice) end
    end)
  end)
end

---Buffer-local keymaps wired on every jdtls attach (see jdtls_launcher.lua's on_attach).
---Ctrl+B/Ctrl+Alt+B mirror IntelliJ's own bindings directly; `<leader>jg*` are reliable
---fallbacks for terminals that don't forward Ctrl+Alt combinations.
---@param bufnr integer
function M.on_attach(bufnr)
  local opts = { buffer = bufnr }
  vim.keymap.set("n", "<C-b>", M.go_to_declaration,
    vim.tbl_extend("force", opts, { desc = "Java: go to declaration (IntelliJ Ctrl+B)" }))
  vim.keymap.set("n", "<C-A-b>", M.go_to_implementations,
    vim.tbl_extend("force", opts, { desc = "Java: go to implementation(s) (IntelliJ Ctrl+Alt+B)" }))
  vim.keymap.set("n", "<leader>jgd", M.go_to_declaration,
    vim.tbl_extend("force", opts, { desc = "Java: go to declaration" }))
  vim.keymap.set("n", "<leader>jgi", M.go_to_implementations,
    vim.tbl_extend("force", opts, { desc = "Java: go to implementation(s)" }))
  vim.keymap.set("n", "<leader>jgu", M.show_usages,
    vim.tbl_extend("force", opts, { desc = "Java: find usages (IntelliJ Alt+F7)" }))
  vim.keymap.set("n", "<leader>jgs", function() M.type_hierarchy(bufnr, "supertypes") end,
    vim.tbl_extend("force", opts, { desc = "Java: supertypes (lớp cha / interface kế thừa)" }))
  vim.keymap.set("n", "<leader>jgb", function() M.type_hierarchy(bufnr, "subtypes") end,
    vim.tbl_extend("force", opts, { desc = "Java: subtypes (class implement / kế thừa)" }))
end

return M
