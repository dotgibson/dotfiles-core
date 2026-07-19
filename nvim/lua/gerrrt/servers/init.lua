-- ================================================================================================
-- TITLE : LSP server registry
-- ABOUT : Registers every server's config with native vim.lsp.config, then enables the ones whose
--         binary is actually installed. Each gerrrt/servers/<name>.lua returns a PLAIN TABLE — the
--         server's config — and the `servers` list below is the single place a name is written.
--
-- WHY NOT lsp/<name>.lua : Neovim 0.11+ also reads server configs from `lsp/<name>.lua` on the
--         runtimepath, which looks like the tidier home for these. It is a TRAP here. Resolution is
--             tbl_deep_extend("force", config["*"], <every lsp/<name>.lua on rtp>, config[<name>])
--         and the rtp files are merged in rtp ORDER with the user config dir FIRST — so
--         nvim-lspconfig's own lsp/<name>.lua, coming later, would override ours key-for-key.
--         Verified empirically: a user lsp/gopls.lua setting `cmd = { "PROBE_CMD" }` resolved to
--         `cmd = { "gopls" }` — lspconfig won. Explicit vim.lsp.config(name, tbl) calls, as below,
--         are the LAST argument to that merge and therefore always win, which is what we want:
--         lspconfig supplies the sensible defaults, this repo supplies the deliberate overrides.
-- ================================================================================================

-- Client capabilities, advertised ONCE on the "*" wildcard rather than threaded through all 19
-- server modules. Every server config deep-merges over this, so a server needing an extra
-- capability (html/cssls and their snippetSupport) sets only the leaf it cares about.
-- Guarded: if blink.cmp fails to load (fresh box, plugin not built yet) fall back to Neovim's
-- defaults rather than aborting the whole server stack.
local ok, capabilities = pcall(function()
	return require("blink.cmp").get_lsp_capabilities()
end)
if not ok then
	capabilities = vim.lsp.protocol.make_client_capabilities()
end
vim.lsp.config("*", { capabilities = capabilities })

-- The servers we WANT on. This list is the ONLY place a server name appears: it drives both the
-- module require and the enable pass below. (It used to be written twice — once as a require block,
-- once as a `wanted` table — which was pure drift risk.)
--
-- Python: ty (types) + ruff (lint/codeactions) is the Astral stack — pyright intentionally not
-- enabled. To fall back to pyright, add servers/pyright.lua and list it here.
local servers = {
	"lua_ls",
	"ty", -- Astral: Python type checking + language features
	"ruff", -- Astral: Python lint diagnostics + code actions
	"gopls",
	"jsonls",
	"ts_ls",
	"vue_ls", -- Vue/Volar template + styles (ts_ls owns <script>)
	"bashls",
	"clangd",
	"dockerls",
	"emmet_ls",
	"yamlls",
	"tailwindcss",
	"solidity_ls_nomicfoundation",
	"taplo", -- TOML (pyproject/Cargo/foundry/starship/mise)
	"marksman", -- Markdown cross-file intelligence
	"html", -- HTML validation (emmet only expands)
	"cssls", -- CSS/SCSS/LESS validation
	"svelte", -- Svelte component intelligence (ts_ls owns <script>)
}

-- Register each server's config. pcall'd per module so one broken or missing server file degrades
-- to "that one server is unconfigured" instead of taking the whole LSP stack — and the editor —
-- down with it.
for _, name in ipairs(servers) do
	local okm, cfg = pcall(require, "gerrrt.servers." .. name)
	if okm and type(cfg) == "table" then
		vim.lsp.config(name, cfg)
	else
		vim.schedule(function()
			vim.notify(
				("LSP config failed to load for %q: %s"):format(name, tostring(cfg)),
				vim.log.levels.ERROR,
				{ title = "gerrrt.servers" }
			)
		end)
	end
end

-- Only enable a server whose executable is actually installed. Native vim.lsp.enable() otherwise
-- tries to SPAWN the configured cmd every time a matching filetype opens, and a missing binary
-- surfaces as a recurring "spawn <server> ENOENT" / "client quit" error on every such buffer. This
-- guard keeps the stack resilient on any box where a binary isn't present yet (fresh machine,
-- DOTFILES_OFFLINE, or a uv/npm-provided server like ruff/ty/solidity not installed).
local function binary_available(name)
	local cfg = vim.lsp.config[name]
	local cmd = cfg and cfg.cmd
	-- No resolvable cmd (nil) or a function launcher: don't second-guess it, let it try.
	if type(cmd) ~= "table" or cmd[1] == nil then
		return true
	end
	return vim.fn.executable(cmd[1]) == 1
end

local M = {}

-- Enable every WANTED server whose binary is currently present; return the list still missing.
-- Safe to call REPEATEDLY: vim.lsp.enable is idempotent and, on 0.11+, attaches a newly-enabled
-- server to already-open matching buffers. That is what lets the post-install hook in
-- plugins/mason-tool-installer.lua (User MasonToolsUpdateCompleted) bring a fresh box's LSP up in
-- the SAME session — the initial pass ran before the binaries existed and skipped them; re-running
-- after the install attaches them without a restart.
function M.enable_available()
	local to_enable, missing = {}, {}
	for _, name in ipairs(servers) do
		if binary_available(name) then
			to_enable[#to_enable + 1] = name
		else
			missing[#missing + 1] = name
		end
	end
	vim.lsp.enable(to_enable)
	return missing
end

-- Initial pass at load. Surface (once) which servers were skipped so a missing binary is
-- discoverable, not silent. Suppressed on engagement/offline boxes (DOTFILES_OFFLINE=1, see
-- config/globals.lua), where tools are intentionally not installed and the warning would be noise.
-- (The post-install re-enable hook does NOT re-notify — it only enables what's now available.)
local missing = M.enable_available()
if #missing > 0 and not vim.g.dotfiles_offline then
	vim.schedule(function()
		vim.notify(
			"LSP not enabled (binary not found): "
				.. table.concat(missing, ", ")
				.. "\nInstall via :Mason — except ruff/ty (uv tool install) and rust (rustup).",
			vim.log.levels.WARN,
			{ title = "gerrrt.servers" }
		)
	end)
end

return M
