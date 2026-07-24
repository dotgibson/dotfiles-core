-- ================================================================================================
-- TITLE : nil (Nix LSP Setup)
-- LINKS : https://github.com/oxalica/nil
-- ABOUT : Nix language server (oxalica) — completion, diagnostics, gotos for the Nix expression
--         language. cmd `{ "nil" }` and flake.nix/.git root_markers come from nvim-lspconfig's
--         lsp/nil_ls.lua (a table cmd, so the binary-availability guard reads it directly).
-- INSTALL: mason — "nil" (Rust binary). Formatter: alejandra (conform). Linters: statix
--         (anti-patterns) + deadnix (dead code) via nvim-lint — both config-optional and fast.
-- ================================================================================================
return {
	filetypes = { "nix" },
}
