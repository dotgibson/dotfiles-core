-- ================================================================================================
-- TITLE : nvim-lspconfig | server config definitions for native LSP
-- LINKS : https://github.com/neovim/nvim-lspconfig
-- NOTE  : On Neovim 0.11+/0.12 lspconfig mainly SHIPS the server config files; the actual
--         enabling happens via vim.lsp.enable() in gerrrt/servers/init.lua. Mason installs
--         the server binaries (run :Mason to add/remove). Formatting/linting is handled by
--         conform.nvim + nvim-lint, not an LSP, so efmls-configs is no longer a dependency.
--         2026: cmp-nvim-lsp dropped — capabilities now come from blink.cmp (servers/init.lua).
-- ================================================================================================
return {
	"neovim/nvim-lspconfig",
	-- Loads on the custom `User FilePost` event (config/autocmds.lua) rather than BufReadPre, so the
	-- ~103ms of server configuration lands AFTER the first UI paint instead of in front of it.
	-- vim.lsp.enable() re-runs `doautoall nvim.lsp.enable FileType` when called post-startup, so the
	-- buffer that triggered the load still gets its client attached — no manual replay needed.
	event = "User FilePost",
	dependencies = {
		{ "mason-org/mason.nvim", opts = {} },
	},
	config = function()
		require("gerrrt.utils.diagnostics").setup()
		require("gerrrt.servers")
	end,
}
