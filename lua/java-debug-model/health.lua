-- :checkhealth java-debug-model - everything a fresh machine needs, each missing piece with the
-- exact way to fix it. Also used by init.lua's one-time startup check (M.missing_essentials).
local M = {}

local h = vim.health

---Major version of the `java` on PATH (or $JAVA_HOME/bin/java), or nil.
---@return integer|nil major, string|nil exe
function M.java_major()
  local exe = vim.env.JAVA_HOME and (vim.env.JAVA_HOME .. "/bin/java") or "java"
  if vim.fn.executable(exe) == 0 then
    exe = "java"
    if vim.fn.executable(exe) == 0 then return nil, nil end
  end
  local out = vim.fn.system({ exe, "-version" })
  local v = out:match('version "([^"]+)"')
  if not v then return nil, exe end
  local major = v:match("^1%.(%d+)") or v:match("^(%d+)")
  return tonumber(major), exe
end

local function has_module(mod)
  return (pcall(require, mod))
end

---Quick check for things without which nothing works at all (no JDK able to run jdtls, no Maven).
---@param root string|nil  project root - a Maven wrapper there counts as Maven
---@return string[] problems (empty = fine)
function M.missing_essentials(root)
  local problems = {}
  local major = M.java_major()
  if not major then
    table.insert(problems, "không tìm thấy Java (JDK 21+) - cài JDK 21 và đặt JAVA_HOME/PATH")
  elseif major < 21 then
    table.insert(problems, "Java trên PATH là " .. major .. ", jdtls cần JDK 21+ để chạy")
  end
  local wrapper = root and vim.fn.executable(root .. "/mvnw") == 1
  if vim.fn.executable("mvn") == 0 and not wrapper then
    table.insert(problems, "không tìm thấy Maven (mvn) - cài Maven hoặc dùng mvnw trong project")
  end
  return problems
end

function M.check()
  h.start("Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  elseif vim.fn.has("nvim-0.10") == 1 then
    h.warn("Neovim " .. tostring(vim.version()) .. " - chạy được, nhưng completion sẵn có (không cần plugin) cần 0.11+")
  else
    h.error("Neovim " .. tostring(vim.version()) .. " quá cũ - cần 0.10+ (khuyên dùng 0.11+)")
  end

  h.start("Java / Maven")
  local major, exe = M.java_major()
  if not major then
    h.error("Không tìm thấy Java", { "Cài JDK 21+ (vd. `sudo pacman -S jdk21-openjdk`, `brew install openjdk@21`)",
      "Đặt JAVA_HOME hoặc thêm `java` vào PATH" })
  elseif major < 21 then
    h.error(("Java %d (%s) - jdtls cần JDK 21+ để chạy"):format(major, exe),
      { "Project của bạn vẫn có thể build bằng JDK cũ hơn - chỉ riêng jdtls cần 21+",
        "Đặt JAVA_HOME trỏ tới JDK 21+ trước khi mở Neovim" })
  else
    h.ok(("Java %d (%s)"):format(major, exe))
  end
  local root = require("java-debug-model").find_root(0)
  if vim.fn.executable("mvn") == 1 then
    h.ok("Maven: " .. vim.fn.exepath("mvn"))
  elseif root and vim.fn.executable(root .. "/mvnw") == 1 then
    h.ok("Maven wrapper: " .. root .. "/mvnw")
  else
    h.error("Không tìm thấy Maven", { "Cài Maven (`mvn`), hoặc dùng `mvnw` trong project" })
  end
  for _, tool in ipairs({ "curl", "tar" }) do
    if vim.fn.executable(tool) == 1 then h.ok(tool) else
      h.warn(tool .. " không có - cần cho lần tải jdtls/lombok đầu tiên") end
  end

  h.start("Plugin phụ thuộc")
  local deps = {
    { "jdtls", "mfussenegger/nvim-jdtls", true },
    { "dap", "mfussenegger/nvim-dap", true },
    { "dapui", "rcarriga/nvim-dap-ui", false },
    { "nio", "nvim-neotest/nvim-nio", false },
    { "nui.popup", "MunifTanjim/nui.nvim", false },
    { "mason", "williamboman/mason.nvim", true },
  }
  for _, d in ipairs(deps) do
    if has_module(d[1]) then
      h.ok(d[2])
    elseif d[3] then
      h.error(d[2] .. " chưa được cài", { "lazy.nvim tự cài từ lazy.lua của plugin - chạy `:Lazy sync`" })
    else
      h.warn(d[2] .. " chưa được cài (một số panel/UI sẽ không có)", { "Chạy `:Lazy sync`" })
    end
  end

  h.start("jdtls + bundle debug/test")
  local data = vim.fn.stdpath("data")
  local prebuilt = data .. "/nvim-java/packages/jdtls/1.54.0"
  local jdtls_path
  if vim.fn.filereadable(prebuilt .. "/bin/jdtls") == 1 then
    jdtls_path = prebuilt
    h.ok("jdtls 1.54.0 (bản đã vá): " .. prebuilt)
  elseif vim.fn.isdirectory(data .. "/mason/packages/jdtls") == 1 then
    jdtls_path = data .. "/mason/packages/jdtls"
    h.warn("Đang dùng jdtls của Mason (chưa vá) - bản vá sẽ được tự tải ở lần khởi động tới",
      { "Kiểm tra mạng / `curl`, hoặc xem opts.jdtls_prebuilt_url" })
  else
    h.error("Chưa có jdtls", { "Khởi động lại Neovim để plugin tự tải, hoặc `:MasonInstall jdtls`" })
  end
  for _, pkg in ipairs({ "java-debug-adapter", "java-test" }) do
    if vim.fn.isdirectory(data .. "/mason/packages/" .. pkg) == 1 then
      h.ok(pkg)
    else
      h.warn(pkg .. " chưa cài (" .. (pkg == "java-test" and "chạy/debug unit test" or "debug") .. " sẽ không có)",
        { "Plugin tự cài qua Mason lúc khởi động - hoặc `:MasonInstall " .. pkg .. "`" })
    end
  end
  local lombok = require("java-debug-model.bootstrap").find_lombok(jdtls_path)
  if lombok then h.ok("lombok: " .. lombok) else
    h.warn("Không có lombok.jar - project dùng Lombok sẽ báo lỗi getter/setter",
      { "Khởi động lại Neovim để plugin tự tải (cần curl)" })
  end

  h.start("Completion / tiện ích")
  local completion = require("java-debug-model.completion")
  if completion.plugin_present() then
    h.ok("Có plugin completion (nvim-cmp/blink.cmp/...) - jdtls và JSF EL tự hiện trong đó")
  elseif completion.should_enable(require("java-debug-model").opts.native_completion) then
    h.ok("Dùng completion sẵn có của Neovim (popup khi gõ, <C-Space>, <CR>)")
  else
    h.warn("Không có completion", { "Cài nvim-cmp/blink.cmp, hoặc dùng Neovim 0.11+ với opts.native_completion" })
  end
  if vim.fn.executable("rg") == 1 then h.ok("ripgrep (index bean JSF nhanh hơn)") else
    h.info("ripgrep không có - JSF dùng grep (vẫn chạy)") end

  h.start("Project hiện tại")
  if root and vim.fn.filereadable(root .. "/pom.xml") == 1 then
    h.ok("Maven project: " .. root)
    local clients = vim.tbl_filter(function(c) return c.config.root_dir == root end,
      vim.lsp.get_clients({ name = "jdtls" }))
    if #clients > 0 then h.ok("jdtls đang chạy cho project này") else
      h.info("jdtls chưa chạy cho project này - mở 1 file .java để khởi động") end
  else
    h.info("Thư mục hiện tại không phải Maven project (không thấy pom.xml)")
  end
end

return M
