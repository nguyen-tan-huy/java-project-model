-- Builds and starts the actual jdtls LSP client: Mason package paths,
-- ASM-version-pinned jdtls/java-test versions, debug/test bundles, and the
-- buffer-local editor keymaps (extract var/const/method, organize imports,
-- JDK switcher, wipe-cache-and-restart). This is the environment-specific
-- half of running Java in this Neovim config - ported here from the user's
-- own former ftplugin/java.lua so java-debug-model owns the WHOLE Java
-- editing experience end to end: it already understands the project model,
-- now it also owns how jdtls gets launched from it.
local M = {}

-- root -> true while jdtls is starting up for that root: từ lúc resolve Project Model bắt đầu
-- tới lúc jdt.ls tự báo "ServiceReady" (qua notification language/status) - đây là mốc thật sự
-- đáng tin để biết import/index đã xong, chứ không phải lúc LSP client "attach" (attach chỉ
-- nghĩa là tiến trình đã chạy, CHƯA chắc đã import/index xong - đây chính là gốc rễ khiến Ctrl+B
-- "lúc được lúc không" nếu bấm quá sớm). ui/status.lua đọc bảng này để hiện lên statusline.
M.starting = {}

---@param root string
local function mark_starting(root)
  M.starting[root] = true
  -- Phòng khi ServiceReady không bao giờ tới (mạng/môi trường lỗi) - tự gỡ khỏi statusline sau
  -- 2 phút thay vì treo mãi, dù không tự thông báo "sẵn sàng" trong trường hợp đó.
  vim.defer_fn(function()
    M.starting[root] = nil
  end, 120000)
end

---@param root string
local function mark_ready(root)
  if not M.starting[root] then return end
  M.starting[root] = nil
  vim.notify(
    "java-debug-model: jdtls đã import/index xong " .. vim.fn.fnamemodify(root, ":t") ..
    " - có thể dùng Ctrl+B/gd xuyên module.",
    vim.log.levels.INFO)
end

-- root -> workspace_dir, cho mọi client jdtls plugin này đã tự khởi động - dùng bởi safety net
-- VimLeavePre bên dưới để đảm bảo tiến trình jdt.ls THẬT SỰ thoát khi Neovim quit, không chỉ gửi
-- yêu cầu tắt rồi thôi.
M.workspace_dirs = {}

local cleanup_registered = false

---Đăng ký (1 lần) autocmd VimLeavePre tự đợi + force-kill jdt.ls nếu cần khi Neovim thoát.
---
---Neovim core (vim/lsp.lua) tự có sẵn 1 VimLeavePre autocmd gọi client:stop() cho MỌI LSP
---client đang attach lúc quit - NHƯNG client:stop() mặc định chỉ GỬI request "shutdown" rồi
---notify "exit", KHÔNG đợi/xác nhận tiến trình đã thoát thật: exit_timeout mặc định là `false`
---(cấu hình ở đây chưa từng set), nên vòng lặp vim.wait() của core cũng bỏ qua việc đợi luôn
---(max_timeout tính từ `false` ra 0). jdt.ls là 1 JVM lớn (đóng OSGi framework, đóng workspace
---Eclipse, ghi lại index) - nếu việc đó chậm hơn thời gian Neovim thoát hẳn, tiến trình có thể bị
--- bỏ lại chạy MỒ CÔI vô thời hạn, âm thầm chiếm RAM qua từng lần mở/đóng Neovim - y hệt vấn đề
-- session.lua đã giải quyết cho JVM debuggee (terminate_all_sync), áp dụng lại cho chính jdt.ls.
--
---Autocmd này đăng ký SAU autocmd của core (chỉ đăng ký khi client jdtls đầu tiên khởi động,
---luôn muộn hơn lúc `vim.lsp` module tự đăng ký autocmd của nó lúc Neovim khởi động) nên chạy
---SAU - đúng lúc core đã gửi xong shutdown/exit, cho tiến trình 1 cơ hội tự thoát sạch trước khi
---ta kiểm tra.
local function register_cleanup()
  if cleanup_registered then return end
  cleanup_registered = true

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      local pids = {}
      for _, workspace_dir in pairs(M.workspace_dirs) do
        for _, line in ipairs(vim.fn.systemlist({ "pgrep", "-f", workspace_dir })) do
          local pid = tonumber(vim.trim(line))
          if pid then pids[pid] = true end
        end
      end
      if next(pids) == nil then return end

      local uv = vim.uv or vim.loop
      local deadline = uv.now() + 8000
      while uv.now() < deadline do
        local alive = false
        for pid in pairs(pids) do
          if uv.kill(pid, 0) then alive = true else pids[pid] = nil end
        end
        if not alive then return end
        vim.wait(300)
      end
      for pid in pairs(pids) do
        uv.kill(pid, 9) -- SIGKILL: vẫn còn sống sau 8s chờ tắt sạch - buộc phải force-kill
      end
    end,
  })
end

local function mason_install_path(mason_registry, name)
  local ok, pkg = pcall(mason_registry.get_package, name)
  if ok and pkg:is_installed() then
    return pkg:get_install_path()
  end
  return nil
end

---Resolves the jdtls command, bundles, workspace_dir, and jdtls client
---config for `root`. Does not start anything - see start_or_attach below.
---@param root string  reactor root (java-debug-model's own find_root)
---@param opts table?  { jdtls_config?: table, jdtls_bundle_globs?: string[] }
---@return table|nil config
---@return string|nil error
function M.build_config(root, opts)
  opts = opts or {}
  local ok_registry, mason_registry = pcall(require, "mason-registry")
  if not ok_registry then
    return nil, "mason-registry chưa sẵn sàng, không thể khởi động jdtls."
  end

  -- LƯU Ý: KHÔNG dùng bản jdtls mới nhất của Mason (v1.60.0) - nó đóng gói ASM 9.10.1,
  -- trong khi bundle "java-test" của Mason (com.microsoft.java.test.plugin) yêu cầu
  -- ASM trong khoảng [9.9.0, 9.10.0) -> bundle test không load được (OSGi BundleException),
  -- khiến "No LSP client found that supports resolving possible test cases".
  -- Dùng lại bản jdtls 1.54.0 (đóng gói đúng ASM 9.9.0, đã test tương thích với java-test)
  -- còn cache lại từ nvim-java trước khi migrate.
  local jdtls_path = vim.fn.stdpath("data") .. "/nvim-java/packages/jdtls/1.54.0"
  if vim.fn.isdirectory(jdtls_path) == 0 then
    jdtls_path = mason_install_path(mason_registry, "jdtls")
    if jdtls_path then
      vim.notify(
        "java-debug-model: không thấy jdtls 1.54.0 cache cũ, dùng bản Mason mới nhất - có thể lỗi " ..
        "debug/run test do xung đột version ASM với java-test.", vim.log.levels.WARN)
    end
  end
  if not jdtls_path then
    return nil, "Không tìm thấy jdtls. Chạy :Mason rồi cài 'jdtls', 'java-debug-adapter', 'java-test'."
  end

  -- Bundle DAP (debug) + test runner (JUnit/TestNG) + spring-boot jdtls extension
  local bundles = {}
  local debug_path = mason_install_path(mason_registry, "java-debug-adapter")
  if debug_path then
    vim.list_extend(bundles,
      vim.split(vim.fn.glob(debug_path .. "/extension/server/com.microsoft.java.debug.plugin-*.jar"), "\n"))
  end
  -- LƯU Ý: java-test bản Mason (0.43.1) gọi CoreTestSearchEngine.hasJUnit6TestAnnotation() -
  -- method này chỉ có ở jdt.ls bản mới, KHÔNG có trong jdtls 1.54.0 đang dùng (để tương thích
  -- ASM với chính plugin java-test, xem comment ở jdtls_path) -> NoSuchMethodError khi tìm test.
  -- Dùng lại bản java-test 0.43.2 cache từ nvim-java (không đụng JUnit 6, khớp với jdtls 1.54.0).
  local test_path = vim.fn.stdpath("data") .. "/nvim-java/packages/java-test/0.43.2"
  if vim.fn.isdirectory(test_path) == 0 then
    test_path = mason_install_path(mason_registry, "java-test")
    if test_path then
      vim.notify(
        "java-debug-model: không thấy java-test 0.43.2 cache cũ, dùng bản Mason mới nhất - có thể lỗi " ..
        "'hasJUnit6TestAnnotation' do không khớp version với jdtls 1.54.0.", vim.log.levels.WARN)
    end
  end
  if test_path then
    vim.list_extend(bundles, vim.split(vim.fn.glob(test_path .. "/extension/server/*.jar"), "\n"))
  end
  local ok_spring, spring_boot = pcall(require, "spring_boot")
  if ok_spring then
    vim.list_extend(bundles, spring_boot.java_extensions())
  end
  for _, pattern in ipairs(opts.jdtls_bundle_globs or {}) do
    for _, jar in ipairs(vim.split(vim.fn.glob(pattern, false, false), "\n")) do
      if jar ~= "" then table.insert(bundles, jar) end
    end
  end

  -- project_name (tên thư mục cuối, KHÔNG hash) dùng làm gợi ý field "projectName" cho profile
  -- debug - phải giữ đúng tên Maven/Eclipse project thật, không được đụng vào, nếu không jdtls
  -- sẽ không tra được classpath/java executable ("Could not resolve java executable for ...").
  local project_name = vim.fn.fnamemodify(root, ":p:h:t")

  -- workspace_dir dùng tên RIÊNG (project_name + hash root) để tránh 2 root KHÁC NHAU nhưng
  -- trùng tên thư mục cuối bị chung 1 workspace_dir -> 2 tiến trình jdtls tranh nhau khoá
  -- workspace Eclipse -> tiến trình sau bị kill ngay (exit code 13).
  local workspace_id = project_name .. "-" .. vim.fn.sha256(root):sub(1, 8)
  local workspace_dir = vim.fn.stdpath("cache") .. "/jdtls-workspace/" .. workspace_id
  M.workspace_dirs[root] = workspace_dir
  register_cleanup()

  local capabilities
  local ok_cmp, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
  capabilities = ok_cmp and cmp_nvim_lsp.default_capabilities() or vim.lsp.protocol.make_client_capabilities()

  -- Dùng path tuyệt đối, KHÔNG gọi "jdtls" theo PATH - trên PATH là bản Mason mới nhất
  -- (bị lỗi ASM ở trên), còn đây trỏ thẳng launcher của bản 1.54.0 đang dùng.
  local cmd = { jdtls_path .. "/bin/jdtls" }
  local lombok_jar = jdtls_path .. "/lombok.jar"
  if vim.fn.filereadable(lombok_jar) == 0 then
    -- cache jdtls 1.54.0 của nvim-java không kèm lombok.jar trong cùng thư mục, lombok nằm riêng
    lombok_jar = vim.fn.stdpath("data") .. "/nvim-java/packages/lombok/1.18.42/lombok-1.18.42.jar"
  end
  if vim.fn.filereadable(lombok_jar) == 1 then
    -- launcher jdtls.py của Mason dùng argparse, JVM arg PHẢI theo dạng --jvm-arg=-Dxxx (có dấu
    -- =), truyền bare "-javaagent:..." sẽ bị coi là leftover arg và không áp dụng javaagent
    table.insert(cmd, "--jvm-arg=-javaagent:" .. lombok_jar)
  end

  -- Lớp bảo vệ dự phòng cho bug thật của eclipse.jdt.ls (đã fix TẬN GỐC bằng cách rebuild
  -- org.eclipse.jdt.ls.core từ source - xem ~/Git-projects/eclipse.jdt.ls-build, tag v1.54.0):
  -- nếu Mason/nvim-java sau này ghi đè lại bản jdtls gốc chưa vá, agent này vẫn tự vá field
  -- "directories" của MavenProjectImporter lúc runtime. Xem jdtls-patch/src/MavenImporterPatchAgent.java.
  local jdtls_patch_agent = vim.fn.expand("~/Git-projects/java-debug-model/jdtls-patch/jdtls-maven-importer-patch-agent.jar")
  if vim.fn.filereadable(jdtls_patch_agent) == 1 then
    table.insert(cmd, "--jvm-arg=-javaagent:" .. jdtls_patch_agent)
  end

  vim.list_extend(cmd, { "-data", workspace_dir })

  local jdk_runtimes = {}
  local ok_jdk, jdk = pcall(require, "jdk")
  if ok_jdk then
    jdk_runtimes = jdk.runtimes_for_jdtls()
  end

  local config = {
    cmd = cmd,
    root_dir = root,
    capabilities = capabilities,
    settings = {
      java = {
        configuration = {
          updateBuildConfiguration = "interactive",
          -- Danh sách JDK phát hiện được trên máy; đổi JDK dùng để compile/debug bằng <leader>jv
          runtimes = jdk_runtimes,
        },
        saveActions = { organizeImports = true },
        completion = {
          favoriteStaticMembers = {
            "org.junit.jupiter.api.Assertions.*",
            "org.mockito.Mockito.*",
            "java.util.Objects.requireNonNull",
          },
          importOrder = { "java", "javax", "org", "com", "" },
        },
        sources = {
          organizeImports = { starThreshold = 5, staticStarThreshold = 3 },
        },
        format = { enabled = true },
      },
    },
    init_options = {
      bundles = bundles,
    },
    -- "ServiceReady" là mốc jdt.ls tự báo đã import/index xong toàn bộ workspaceFolders -
    -- nvim-jdtls's setup.lua tự bọc thêm handler CỦA RIÊNG NÓ quanh field này (dùng cho tính
    -- năng set 'path' của buffer) và VẪN gọi lại handler này (pcall) nên đặt ở đây an toàn,
    -- không đụng tính năng có sẵn của nvim-jdtls.
    handlers = {
      ["language/status"] = function(_, result)
        if result and result.type == "ServiceReady" then
          mark_ready(root)
        end
      end,
    },
    on_attach = function(_, bufnr)
      M.on_attach(bufnr, root, workspace_dir)
    end,
  }

  return vim.tbl_deep_extend("force", config, opts.jdtls_config or {})
end

---Buffer-local keymaps + hooks wired on every jdtls attach.
---@param bufnr integer
---@param root string
---@param workspace_dir string
function M.on_attach(bufnr, root, workspace_dir)
  local jdtls = require("jdtls")
  jdtls.setup_dap({ hotcodereplace = "manual" })

  -- Đẩy Project Model (java-debug-model) vào workspace jdtls ngay khi có thể - resolve nền,
  -- không chặn UI, rồi tự đẩy toàn bộ module (kể cả mồ côi) vào qua sync_workspace_folders().
  local ok_jdm, jdm = pcall(require, "java-debug-model")
  if ok_jdm then
    jdm.get_project(root, function() end)
  end

  -- KHÔNG tự redefineClasses nữa. Chỉ báo khi code đã biên dịch xong, chờ Ctrl+\ để áp dụng
  -- thủ công (xem lua/plugins/dap.lua).
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap then
    dap.listeners.before["event_hotcodereplace"]["jdtls"] = function(_, body)
      if body.changeType == "BUILD_COMPLETE" then
        vim.notify("Code đã biên dịch xong. Nhấn Ctrl+\\ để áp dụng (hot reload).", vim.log.levels.INFO)
      elseif (body.changeType == "ERROR" or body.changeType == "WARNING") and body.message then
        vim.notify("Hot reload: " .. body.message, vim.log.levels.WARN)
      end
    end
  end

  -- Reformat code khi lưu file, giống "Reformat on Save" của IntelliJ
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    callback = function(args)
      vim.lsp.buf.format({ bufnr = args.buf, async = false })
    end,
  })

  local opts = { buffer = bufnr }

  vim.keymap.set({ "n", "x" }, "<leader>jev", jdtls.extract_variable,
    vim.tbl_extend("force", opts, { desc = "Java: extract variable" }))
  vim.keymap.set({ "n", "x" }, "<leader>jec", jdtls.extract_constant,
    vim.tbl_extend("force", opts, { desc = "Java: extract constant" }))
  vim.keymap.set({ "n", "x" }, "<leader>jem", jdtls.extract_method,
    vim.tbl_extend("force", opts, { desc = "Java: extract method" }))
  vim.keymap.set("n", "<leader>joi", jdtls.organize_imports,
    vim.tbl_extend("force", opts, { desc = "Java: organize imports" }))

  -- Xoá sạch workspace cache + restart jdtls (giống Invalidate Caches/Restart của IntelliJ)
  vim.keymap.set("n", "<leader>jR", function()
    vim.ui.select({ "Huỷ", "Xoá cache + restart jdtls" }, {
      prompt = "Xoá workspace cache tại " .. workspace_dir .. " ?",
    }, function(choice)
      if choice ~= "Xoá cache + restart jdtls" then return end
      require("jdtls.setup").wipe_data_and_restart()
    end)
  end, vim.tbl_extend("force", opts, { desc = "Java: xoá cache + reimport project sạch" }))

  -- Đổi JDK dùng để compile/debug project hiện tại (giống Project SDK của IntelliJ)
  vim.keymap.set("n", "<leader>jv", function()
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })[1]
    if not client then
      vim.notify("jdtls chưa attach.", vim.log.levels.WARN)
      return
    end
    local runtimes = vim.tbl_get(client.config, "settings", "java", "configuration", "runtimes") or {}
    if #runtimes == 0 then
      vim.notify("Không có JDK nào được cấu hình sẵn.", vim.log.levels.WARN)
      return
    end
    vim.ui.select(runtimes, {
      prompt = "Chọn JDK cho project (compile/debug):",
      format_item = function(rt) return rt.name .. " :: " .. rt.path end,
    }, function(choice)
      if not choice then return end
      for _, rt in ipairs(client.config.settings.java.configuration.runtimes) do
        rt.default = (rt.path == choice.path) or nil
      end
      client:notify("workspace/didChangeConfiguration", { settings = client.config.settings })
      vim.notify("Đã đổi JDK project sang " .. choice.name .. " (" .. choice.path .. ")", vim.log.levels.INFO)
    end)
  end, vim.tbl_extend("force", opts, { desc = "Java: chọn JDK version cho project (compile/debug)" }))
end

---Resolves root (Maven-aware via java-debug-model's own find_root, falling
---back to jdtls's marker-based search for Gradle/other build systems where
---java-debug-model itself doesn't apply) and starts/attaches jdtls for
---`bufnr`. Guards against double-starting the same buffer.
---@param bufnr integer
---@param opts table?  { jdtls_config?: table, jdtls_bundle_globs?: string[] }
function M.start_or_attach(bufnr, opts)
  opts = opts or {}
  if vim.b[bufnr].java_debug_model_jdtls_started then return end

  local ok_jdtls, jdtls = pcall(require, "jdtls")
  if not ok_jdtls then
    vim.notify("java-debug-model: nvim-jdtls not found", vim.log.levels.ERROR)
    return
  end

  local jdm = require("java-debug-model")
  local root = jdm.find_root(bufnr)

  -- Buffer KHÔNG phải file thật của người dùng đang gõ - vd source jar được jdt.ls tự decompile
  -- (jdt://contents/...) - dap-ui/nvim-dap tự bufload NGẦM 1 buffer như vậy cho MỖI frame trong
  -- stack trace lúc dừng ở breakpoint để hiện context, và Spring có thể có 60-70 frame trỏ vào
  -- thư viện/jar. Nếu cứ chạy full flow bên dưới (build_config quét filesystem + jdm.get_project
  -- resolve Maven) cho TỪNG buffer đó thì lặp lại hàng chục lần liên tiếp, chặn cứng main thread
  -- (đã xác nhận qua gdb bt: bufload -> FileType autocmd -> filereadable/isdirectory lặp lại) dù
  -- jdtls đã chạy sẵn cho đúng root này rồi. Có client jdtls sẵn cho root đó thì chỉ attach thẳng
  -- (rẻ), bỏ qua toàn bộ build_config/get_project.
  if root then
    for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
      if client.config.root_dir == root then
        vim.lsp.buf_attach_client(bufnr, client.id)
        vim.b[bufnr].java_debug_model_jdtls_started = true
        return
      end
    end
  end

  if not root or vim.fn.filereadable(root .. "/pom.xml") == 0 then
    -- Không phải project Maven (hoặc chưa xác định được root qua pom.xml) - fallback về cách
    -- jdtls tự dò root bằng marker file, để vẫn hỗ trợ project Gradle/khác (java-debug-model chỉ
    -- hiểu Maven).
    root = require("jdtls.setup").find_root({ "mvnw", "gradlew", "settings.gradle", "settings.gradle.kts", ".git" })
    if not root then
      local found = vim.fs.find({ "pom.xml", "build.gradle" }, { upward = true, path = vim.fn.expand("%:p:h") })[1]
      root = found and vim.fs.dirname(found)
    end
  end
  if not root then
    vim.notify("java-debug-model: không tìm thấy project root (pom.xml/build.gradle/.git) cho file này.",
      vim.log.levels.WARN)
    return
  end

  -- Set guard NGAY TRƯỚC build_config (không phải sau) - build_config/jdtls.start_or_attach có
  -- thể khiến buffer này bị set lại 'filetype' NGAY BÊN TRONG (vd nvim-jdtls tự set filetype sau
  -- khi fetch xong nội dung decompile cho buffer jdt://), tự tái kích hoạt autocmd FileType này
  -- LỒNG NHAU cho CHÍNH bufnr này trước khi guard được set - khiến toàn bộ flow chạy lại từ đầu
  -- (2 lần lồng nhau trở lên) thay vì bị chặn bởi guard ở đầu hàm.
  vim.b[bufnr].java_debug_model_jdtls_started = true

  local config, err = M.build_config(root, opts)
  if not config then
    vim.notify("java-debug-model: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  -- Resolve Project Model TRƯỚC khi khởi động jdtls, đưa TOÀN BỘ module (kể cả mồ côi) vào
  -- config.init_options.workspaceFolders (field TÙY BIẾN jdt.ls thật sự đọc để import project
  -- lúc khởi động - KHÔNG phải config.workspace_folders chuẩn LSP, xem comment lịch sử debug ở
  -- git log của file này).
  --
  -- ĐÃ THỬ "start ngay + tự sync module vào sau" (workspace/didChangeWorkspaceFolders sau khi
  -- attach) - về mặt import project thì đúng (đủ project trong java.project.getAll), NHƯNG gây
  -- race: jdt.ls cần thời gian import+index (WorkspaceJob nền) sau khi 1 module được thêm, nên
  -- Ctrl+B/gd tới symbol trong module vừa thêm lúc được lúc không tuỳ đúng lúc bấm sớm hay muộn
  -- so với lúc index xong - trải nghiệm không đáng tin cậy. Quay lại cách chờ-rồi-start (chấp
  -- nhận chậm hơn ở lần mở file đầu tiên của 1 project chưa có cache) vì đây là cách DUY NHẤT đã
  -- xác nhận điều hướng chéo module luôn ổn định.
  mark_starting(root)
  jdm.get_project(root, function(project)
    if project then
      local uris = { vim.uri_from_fname(root) }
      local seen = { [root] = true }
      for _, mod in ipairs(project.modules) do
        if not seen[mod.path] then
          seen[mod.path] = true
          table.insert(uris, vim.uri_from_fname(mod.path))
        end
      end
      config.init_options.workspaceFolders = uris
    end
    jdtls.start_or_attach(config)
  end)
end

return M
