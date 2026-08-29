-- Streams a Maven invocation's output into a real terminal buffer/split.
-- Maven output has ANSI colors and can run long, so quickfix isn't a good
-- fit here.
local M = {}

---@type table<string, integer>  title -> bufnr, so re-running the same
---logical job reuses its split instead of spawning a new one every time.
local bufs_by_title = {}

---@param cmd string[]
---@param cwd string
---@param opts table?  { title?: string, on_exit?: fun(exit_code: integer) }
function M.run_in_terminal(cmd, cwd, opts)
  opts = opts or {}
  local title = opts.title or table.concat(cmd, " ")

  local existing = bufs_by_title[title]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    local win = vim.fn.bufwinid(existing)
    if win == -1 then
      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, existing)
    else
      vim.api.nvim_set_current_win(win)
    end
    vim.api.nvim_buf_set_name(existing, title .. " (" .. os.time() .. ")")
  end

  vim.cmd("botright split")
  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  bufs_by_title[title] = bufnr

  vim.fn.termopen(cmd, {
    cwd = cwd,
    on_exit = function(_, exit_code)
      if opts.on_exit then opts.on_exit(exit_code) end
      if exit_code == 0 then
        vim.notify("java-debug-model: " .. title .. " finished OK", vim.log.levels.INFO)
      else
        vim.notify("java-debug-model: " .. title .. " failed (exit " .. exit_code .. ")", vim.log.levels.ERROR)
      end
    end,
  })
  vim.b[bufnr].java_debug_model_maven_title = title
  vim.cmd("normal! G")
end

return M
