-- ================================================================================================
-- TITLE : taplo (TOML language server) LSP Setup
-- LINKS : https://github.com/tamasfe/taplo  ·  https://taplo.tamasfe.dev/
-- ABOUT : Completion, validation, hover and formatting for TOML — which is everywhere in your
--         stack: pyproject.toml (ruff/ty), Cargo.toml (rust), foundry.toml (solidity), plus
--         starship/mise configs in this very dotfiles repo. Schema-aware via SchemaStore.
-- INSTALL: mason — package name "taplo" (added to ensure_installed in plugins/conform.lua).
-- ================================================================================================
return function(capabilities)
	vim.lsp.config("taplo", {
		capabilities = capabilities,
		cmd = { "taplo", "lsp", "stdio" },
		filetypes = { "toml" },
		-- Real base names only: vim.fs.root / vim.fs.find do NOT support globs (see neovim
		-- runtime/lua/vim/fs.lua — "paths and globs are not supported"). The old "*.toml" never
		-- matched, so taplo silently always fell back to .git and a lone TOML file outside a repo
		-- got a cwd root. List the TOML manifests this stack actually uses instead.
		root_markers = { "pyproject.toml", "Cargo.toml", "foundry.toml", "taplo.toml", ".taplo.toml", ".git" },
	})
end
