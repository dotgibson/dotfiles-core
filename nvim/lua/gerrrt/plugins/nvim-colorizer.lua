-- ================================================================================================
-- TITLE : nvim-colorizer.lua | colorify-style inline colour highlighter
-- LINKS : https://github.com/catgoose/nvim-colorizer.lua (maintained fork)
-- ABOUT : The always-on colour highlighter, styled after NvChad's `colorify`: it renders an inline
--         swatch next to each colour literal, processes only the VISIBLE viewport (cheap, updates on
--         scroll), and — crucially — pulls TailwindCSS / CSS-LSP document colours through the LSP
--         `textDocument/documentColor` provider, so `bg-red-500` gets a swatch too, not just hex.
-- SPLIT WITH ccc : ccc.nvim (plugins/ccc-nvim.lua) keeps the :CccPick colour PICKER / :CccConvert;
--         its always-on highlighter is turned off there so the two don't double-render. This module
--         owns the highlighting; ccc owns the interactive picking.
-- ICONS : the swatch uses U+25A0 (■ BLACK SQUARE) — a plain, universally-present glyph (no Nerd Font
--         private-use codepoint), so it can never render as tofu on a box with a partial font.
-- ================================================================================================
local web_fts = {
	"css",
	"scss",
	"sass",
	"less",
	"html",
	"javascript",
	"javascriptreact",
	"typescript",
	"typescriptreact",
	"svelte",
	"vue",
}

return {
	"catgoose/nvim-colorizer.lua",
	ft = web_fts,
	config = function()
		require("colorizer").setup({
			filetypes = web_fts,
			user_default_options = {
				names = false, -- don't colourize bare words like "red"/"blue" — too noisy in code
				css = true, -- rgb()/hsl()/#rgb/#rrggbb everywhere
				css_fn = true, -- rgb()/hsl() function forms
				tailwind = "lsp", -- Tailwind class colours via the LSP documentColor provider
				mode = "virtualtext", -- inline swatch, not a full-text background (colorify's look)
				virtualtext = "\u{25a0}", -- 25a0 ■ BLACK SQUARE swatch
				virtualtext_inline = true,
			},
		})
	end,
}
