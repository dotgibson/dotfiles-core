return {
	settings = {
		yaml = {
			-- Let SchemaStore.nvim (plugins/schemastore.lua) own the catalogue instead of yamlls's
			-- built-in store — schemaStore.enable=false avoids duplicating it. The catalogue
			-- itself is merged in by before_init below.
			schemaStore = { enable = false, url = "" },
			validate = true,
			format = { enable = true },
		},
	},
	filetypes = { "yaml" },
	-- Same deferral as servers/jsonls.lua: schemastore.yaml.schemas() was resolved inline, so the
	-- YAML catalogue was built during server configuration regardless of what filetype you were
	-- actually editing. (That configuration pass runs once per session, not once per buffer —
	-- see the fuller note in servers/jsonls.lua; the waste is the unconditional build, not its
	-- frequency.) before_init runs once per client instance, so it now costs only when yamlls
	-- actually starts.
	-- The two project-specific schemas are merged on top of the catalogue, preserving the previous
	-- behaviour exactly (composer + docker-compose win over any catalogue entry for those globs).
	before_init = function(_, config)
		local ok, store = pcall(require, "schemastore")
		if not ok then
			return
		end
		config.settings = vim.tbl_deep_extend("force", config.settings or {}, {
			yaml = {
				schemas = vim.tbl_extend("force", store.yaml.schemas(), {
					["https://json.schemastore.org/composer.json"] = "composer.json",
					["https://json.schemastore.org/docker-compose.json"] = "docker-compose*.yml",
				}),
			},
		})
	end,
}
