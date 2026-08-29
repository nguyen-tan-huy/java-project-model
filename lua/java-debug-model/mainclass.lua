-- LSP/bundle-based main-method and test-method discovery. Never regexes over
-- raw source text (`public static void main`, `@Test`) - both are prone to
-- false positives from comments/strings/disabled code. Instead this reuses
-- the exact executeCommand endpoints the java-debug and java-test jdtls
-- bundles expose (the same ones nvim-jdtls's own jdtls.dap module uses),
-- which are backed by JDT's real AST, not a client-side scan.
local M = {}

local function jdtls_clients(bufnr)
  local clients = bufnr and vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" }) or {}
  if #clients == 0 then
    clients = vim.lsp.get_clients({ name = "jdtls" })
  end
  return clients
end

local function supports_command(client, command)
  local provider = client.server_capabilities.executeCommandProvider
  local commands = type(provider) == "table" and provider.commands or {}
  return vim.list_contains(commands, command)
end

---Finds every `main(String[])` entry point across the whole project via the
---java-debug bundle's `vscode.java.resolveMainClass` executeCommand -
---AST-backed, whole-workspace, no per-file text scanning needed.
---@param project table Project (used to attach a Module to each result)
---@param callback fun(entries: {main_class:string, project_name:string, file:string, module:table|nil}[])
function M.find_main_classes(project, callback)
  local client = jdtls_clients()[1]
  if not client then callback({}) return end

  client:request("workspace/executeCommand", { command = "vscode.java.resolveMainClass" }, function(err, result)
    if err or not result then
      callback({})
      return
    end
    local entries = {}
    for _, item in ipairs(result) do
      local file = item.filePath
      table.insert(entries, {
        main_class = item.mainClass,
        project_name = item.projectName,
        file = file,
        module = file and project:find_module_for_file(file) or nil,
      })
    end
    callback(entries)
  end, 0)
end

---Finds every @Test-annotated method (JUnit 4/5/parameterized/TestNG) across
---the project's test source roots, via the java-test bundle's own AST-backed
---search command (whichever of the two the attached server advertises) -
---exactly what nvim-jdtls's own test runner (wrapped in step 8's test.lua)
---uses to actually execute tests, so discovery and execution never disagree.
---@param project table Project
---@param callback fun(entries: {class_name:string, method_name:string|nil, level:string, module:table|nil, file:string, lens: table}[])
function M.find_test_methods(project, callback)
  local uris = {}
  for _, mod in ipairs(project.modules) do
    for _, sr in ipairs(mod:test_source_roots()) do
      for name, ftype in vim.fs.dir(sr.path, { depth = 100 }) do
        if ftype == "file" and name:match("%.java$") then
          table.insert(uris, vim.uri_from_fname(sr.path .. "/" .. name))
        end
      end
    end
  end
  if #uris == 0 then callback({}) return end

  local cmd_codelens = "vscode.java.test.search.codelens"
  local cmd_find_tests = "vscode.java.test.findTestTypesAndMethods"

  local entries = {}
  local pending = #uris

  local function done_one()
    pending = pending - 1
    if pending == 0 then callback(entries) end
  end

  for _, uri in ipairs(uris) do
    local file = vim.uri_to_fname(uri)
    local client, command = nil, nil
    for _, c in ipairs(jdtls_clients()) do
      if supports_command(c, cmd_codelens) then
        client, command = c, cmd_codelens
        break
      elseif supports_command(c, cmd_find_tests) then
        client, command = c, cmd_find_tests
        break
      end
    end
    if not client then
      done_one()
      goto continue
    end
    client:request("workspace/executeCommand", { command = command, arguments = { uri } }, function(err, result)
      if not err then
        for _, lens in ipairs(result or {}) do
          local name_parts = vim.split(lens.fullName or "", "#")
          table.insert(entries, {
            class_name = name_parts[1],
            method_name = name_parts[2],
            level = lens.testLevel or lens.level,
            module = project:find_module_for_file(file),
            file = file,
            lens = lens,
          })
        end
      end
      done_one()
    end, 0)
    ::continue::
  end
end

return M
