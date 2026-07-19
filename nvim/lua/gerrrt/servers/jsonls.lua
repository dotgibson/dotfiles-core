return {
	filetypes = { "json", "jsonc" },
	settings = {
		json = {
			validate = { enable = true },
		},
	},
	-- SchemaStore (plugins/schemastore.lua) feeds the full schemastore.org catalogue so common
	-- config files (package.json, tsconfig, .eslintrc, GitHub Actions, ...) get validation +
	-- completion.
	--
	-- Resolved in before_init, NOT inline in `settings` above. schemastore.json.schemas() builds
	-- a 1,368-entry table (~5ms with the catalogue require); inline, that ran while this module
	-- was being configured — i.e. for EVERY buffer you opened, because servers/init.lua configures
	-- all servers up front. Opening a Lua file paid for the entire JSON schema catalogue.
	-- before_init runs once per client instance, so the cost now lands only when a jsonls client
	-- actually starts. This is the idiom Neovim documents for exactly this
	-- (:h vim.lsp.ClientConfig — the tailwindcss configFile example).
	--
	-- pcall'd: on a box where schemastore isn't installed yet we keep validate=true and simply
	-- go without the catalogue, rather than erroring out of client startup.
	before_init = function(_, config)
		local ok, store = pcall(require, "schemastore")
		if not ok then
			return
		end
		config.settings = vim.tbl_deep_extend("force", config.settings or {}, {
			json = { schemas = store.json.schemas() },
		})
	end,
}
