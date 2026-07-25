-- ================================================================================================
-- TITLE : nil (Nix LSP Setup)
-- LINKS : https://github.com/oxalica/nil
-- ABOUT : Nix language server (oxalica) — completion, diagnostics, gotos for the Nix expression
--         language. cmd `{ "nil" }` and flake.nix/.git root_markers come from nvim-lspconfig's
--         lsp/nil_ls.lua (a table cmd, so the binary-availability guard reads it directly).
-- INSTALL: NOT via Mason. Mason only cargo-builds nil from source, and its build needs the `nix`
--         binary, so the install fails on any box without Nix (see the note in plugins/
--         mason-tool-installer.lua). Install it the Nix-native way instead:
--             nix profile install github:oxalica/nil
--         The binary-availability guard (servers/init.lua) leaves this server dark until `nil` is on
--         PATH, so it lights up automatically once installed. Formatter: alejandra (conform). Linter:
--         statix (nvim-lint) — both mason-managed and pure-Rust. (deadnix, also not in Mason, can be
--         added to nvim-lint if you install it via nix/cargo.)
-- ================================================================================================
return {
	filetypes = { "nix" },
}
