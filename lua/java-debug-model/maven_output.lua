-- Streams a Maven invocation's output into a real terminal buffer/split.
-- Maven output has ANSI colors and can run long, so quickfix isn't a good
-- fit here.
local M = {}

---@type table<string, integer>  title -> bufnr, so re-running the same
---logical job reuses its split instead of spawning a new one every time.
local bufs_by_title = {}

---@type table<string, boolean>  title -> true while that job's terminal is
---still running, so a statusline component can show what's in flight.
local running_titles = {}

---@return string[]  titles of every maven_runner job currently in flight
function M.active_titles()
  local titles = {}
  for title in pairs(running_titles) do table.insert(titles, title) end
  table.sort(titles)
  return titles
end

---@param cmd string[]
---@param cwd string
---@param opts table?  { title?: string, on_exit?: fun(exit_code: integer), env?: table<string, string> }
function M.run_in_terminal(cmd, cwd, opts)
  opts = opts or {}
  local title = opts.title or table.concat(cmd, " ")

  local existing = bufs_by_title[title]
  -- A cached bufnr from a PREVIOUS run of this exact title is only trustworthy if it's STILL
  -- actually that terminal buffer. `nvim_buf_is_valid(existing)` alone can't tell that apart from
  -- "some unrelated buffer - even a real FILE - that happened to get this exact number reassigned
  -- later": Neovim freely reuses a buffer NUMBER once its old buffer is fully wiped (e.g. the user
  -- closed that terminal tab via ui/bufferline.lua's own click-to-close, or plain `:bwipeout`).
  -- Confirmed for real: re-running the same Maven job picked up a recycled bufnr that by then
  -- belonged to an open pom.xml buffer - renamed THAT (corrupting the real file buffer's own
  -- identity) and left a stray little window sitting in the layout, scrolled to wherever pom.xml's
  -- cursor happened to be ("bị hiển thị lỗi gì như trong hình" - a screenshot showed exactly this:
  -- a small window showing a random `<order-core.version>` line from pom.xml). Checking `buftype`
  -- AND the marker this same function sets on every real terminal buffer of its own
  -- (`java_debug_model_maven_title`, set below) is what actually distinguishes "still our
  -- terminal" from "reused for something else" - `existing = nil` falls through to the plain
  -- fresh-terminal path below instead of touching whatever that buffer really is now.
  if existing and not (vim.api.nvim_buf_is_valid(existing)
      and vim.bo[existing].buftype == "terminal"
      and vim.b[existing].java_debug_model_maven_title == title) then
    existing = nil
  end
  if existing then
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

  running_titles[title] = true
  vim.fn.termopen(cmd, {
    cwd = cwd,
    env = opts.env, -- e.g. JAVA_HOME/PATH override from maven_jdk.lua's persisted selection
    on_exit = function(_, exit_code)
      running_titles[title] = nil
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
