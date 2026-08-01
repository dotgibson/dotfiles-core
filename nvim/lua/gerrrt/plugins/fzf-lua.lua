-- ================================================================================================
-- TITLE : fzf-lua | fuzzy finder (NvChad-styled layout)
-- LINKS : https://github.com/ibhagwan/fzf-lua
-- NOTE  : LSP-specific pickers (definitions/refs/symbols) live in utils/lsp.lua on_attach,
--         so they're buffer-local and only active when a server is attached. This file
--         keeps the general finders.
-- NVCHAD: NvChad ships its finder look via TELESCOPE, but you run fzf-lua — so the `opts` below
--         TRANSLATE NvChad's telescope config into fzf-lua's own terms rather than adopting
--         telescope. Mirrored 1:1 from nvchad/configs/telescope.lua:
--           width 0.87 · height 0.80 · preview on the RIGHT at 55% · prompt on TOP
--           prompt-prefix "   " (f002 magnifier) · selection caret " " (f0da)
--         Rounded borders + the FzfLua* highlight groups (see utils/ui-highlights.lua) finish
--         the minimal, border-tinted NvChad look. Border chars come from `border = "rounded"`.
-- CLAUDE: <C-y> sends the selection to Claude Code as @-mentions (see send_to_claude below).
-- ================================================================================================

-- ── <C-y> → send the fzf selection to Claude Code as @-mentions ─────────────────────────────────
-- The tree-based @-mention (<leader>as in nvim-tree/oil) adds ONE file, so putting six files in
-- context means six navigations. fzf is already multi-select (`--multi` is on for the file pickers;
-- <Tab> marks, <A-a> toggles all), so this turns "the files involved in this change" into one
-- gesture. From `live_grep` the entry carries a line number, so each hit is sent as its own
-- location rather than the whole file.
--
-- NOT gated at spec level, unlike plugins/claudecode-nvim.lua: fzf-lua is a core finder that must
-- load everywhere, and probing for `claude` while building this spec would cost a startup
-- `executable()` on every box AND miss a mid-session install. The action instead fails soft — on a
-- box without the CLI, claudecode is not on the runtimepath, `require` fails, and you get one
-- notify saying why rather than a stack trace.
local function send_to_claude(selected, opts)
	local ok, claudecode = pcall(require, "claudecode")
	if not ok then
		vim.notify(
			"Claude Code is not available — the `claude` CLI is not installed on this machine, "
				.. "so plugins/claudecode-nvim.lua is gated off (see :checkhealth gerrrt).",
			vim.log.levels.WARN,
			{ title = "fzf-lua" }
		)
		return
	end

	local path = require("fzf-lua.path")
	local sent, failed = 0, 0
	for _, entry in ipairs(selected or {}) do
		-- entry_to_file, not a raw string: entries carry devicon prefixes and grep entries are
		-- `file:line:col:text`, so hand-parsing would send Claude a path with a glyph glued to it.
		local file = path.entry_to_file(entry, opts)
		if file and file.path and file.path ~= "" then
			-- fzf-lua reports 1-indexed lines; send_at_mention documents its range as 0-indexed for
			-- Claude. `files` entries have no line (0 here) — pass nil so it means the whole file.
			local line = (file.line and file.line > 0) and (file.line - 1) or nil
			if claudecode.send_at_mention(file.path, line, line, "fzf-lua") then
				sent = sent + 1
			else
				failed = failed + 1
			end
		end
	end

	if sent > 0 then
		vim.notify(
			("Sent %d %s to Claude"):format(sent, sent == 1 and "entry" or "entries")
				.. (failed > 0 and (" (%d failed)"):format(failed) or ""),
			failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO,
			{ title = "Claude Code" }
		)
	elseif failed > 0 then
		vim.notify("Could not send the selection to Claude", vim.log.levels.ERROR, { title = "Claude Code" })
	end
end

return {
	"ibhagwan/fzf-lua",
	dependencies = { "nvim-tree/nvim-web-devicons" },
	cmd = "FzfLua",
	keys = {
		{
			"<leader>ff",
			function()
				require("fzf-lua").files()
			end,
			desc = "FZF Files",
		},
		{
			"<leader>fg",
			function()
				require("fzf-lua").live_grep()
			end,
			desc = "FZF Live Grep",
		},
		{
			"<leader>fb",
			function()
				require("fzf-lua").buffers()
			end,
			desc = "FZF Buffers",
		},
		{
			"<leader>fh",
			function()
				require("fzf-lua").help_tags()
			end,
			desc = "FZF Help Tags",
		},
		{
			"<leader>fr",
			function()
				require("fzf-lua").oldfiles()
			end,
			desc = "FZF Recent Files",
		},
		{
			"<leader>fk",
			function()
				require("fzf-lua").keymaps()
			end,
			desc = "FZF Keymaps",
		},
		{
			"<leader>fx",
			function()
				require("fzf-lua").diagnostics_document()
			end,
			desc = "FZF Diagnostics (doc)",
		},
		{
			"<leader>fX",
			function()
				require("fzf-lua").diagnostics_workspace()
			end,
			desc = "FZF Diagnostics (workspace)",
		},
	},
	opts = {
		-- Window geometry — NvChad's telescope layout, in fzf-lua terms.
		winopts = {
			height = 0.80, -- NvChad layout_config.height
			width = 0.87, -- NvChad layout_config.width
			row = 0.35, -- centered-ish, matching telescope's default vertical anchor
			col = 0.50,
			border = "rounded", -- the minimal rounded frame (border chars = ╭ ╮ ╰ ╯ ─ │)
			preview = {
				border = "rounded",
				layout = "horizontal",
				horizontal = "right:55%", -- NvChad preview_width = 0.55, on the right
				title = true,
				title_pos = "center",
				scrollbar = "float",
			},
		},
		-- fzf CLI flags that reproduce NvChad's prompt/caret placement.
		fzf_opts = {
			["--layout"] = "reverse", -- prompt on TOP (NvChad prompt_position = "top")
			["--info"] = "inline-right",
			["--prompt"] = "\u{f002}  ", -- f002 nf-fa-search — NvChad's prompt_prefix
			["--pointer"] = "\u{f0da}", -- f0da nf-fa-caret_right — NvChad's selection_caret
			["--marker"] = "\u{f0da}", -- multi-select marker, same caret for consistency
		},
		-- Inherit tokyonight's palette; the FzfLua* groups in utils/ui-highlights.lua then tint
		-- borders/titles for the minimal NvChad look.
		fzf_colors = true,
		-- Telescope-familiar preview scrolling without leaving the finder.
		keymap = {
			builtin = {
				["<C-d>"] = "preview-page-down",
				["<C-u>"] = "preview-page-up",
			},
		},
		-- `files` is fzf-lua's SHARED action set for every file-ish picker, so this one entry covers
		-- <leader>ff / fg / fb / fr. `ctrl-y` is free in both layers: fzf's own keymap binds ctrl-a to
		-- beginning-of-line and alt-a to toggle-all, and fzf-lua's default file actions never claim
		-- ctrl-y (only the git pickers do, for yank-commit — a different action set).
		--
		-- THE LEADING `true` IS LOad-BEARING. An action table without it REPLACES fzf-lua's defaults
		-- wholesale rather than extending them — dropping enter, ctrl-s/v/t and alt-q/Q/i/h/f, i.e.
		-- opening a file at all. `[1] == true` is fzf-lua's inheritance marker (config.lua: it
		-- switches the merge to `tbl_deep_extend("keep", yours, defaults)` and then strips the [1]).
		-- Verified by diffing the resolved action set against a baseline build.
		actions = {
			files = {
				true,
				["ctrl-y"] = send_to_claude,
			},
		},
	},
}
