-- lazy.nvim package spec: the dependencies below are installed/loaded automatically, so a user's
-- whole spec can be the one line `{ "nguyen-tan-huy/java-project-model" }`. setup() runs by
-- itself too (plugin/java-debug-model.lua) - no `opts`/`config` needed for the defaults.
--
-- Dependencies ONLY, deliberately no spec for this plugin itself: lazy.nvim scopes this file to
-- the plugin under whatever name the user installed it as, but a `{ "owner/repo", opts = ... }`
-- entry here is matched by the name derived from the URL - with a renamed install (`name = ...`)
-- that becomes a SECOND, separate plugin instead of configuring this one.
return {
  { "mfussenegger/nvim-jdtls" },
  { "mfussenegger/nvim-dap" },
  { "rcarriga/nvim-dap-ui" },
  { "nvim-neotest/nvim-nio", lazy = true },
  { "MunifTanjim/nui.nvim", lazy = true },
  { "williamboman/mason.nvim" },
  { "JavaHello/spring-boot.nvim", lazy = true },
}
