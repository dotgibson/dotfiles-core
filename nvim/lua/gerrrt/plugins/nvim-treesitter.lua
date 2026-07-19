-- ================================================================================================
-- TITLE : nvim-treesitter (main branch — new API)
-- LINKS : https://github.com/nvim-treesitter/nvim-treesitter
-- NOTE  : Dropped lazy=false so the BufReadPost/BufNewFile event actually governs loading
--         (the two were fighting before).
-- ================================================================================================
return {
	"nvim-treesitter/nvim-treesitter",
	branch = "main",
	build = ":TSUpdate",
	event = { "BufReadPost", "BufNewFile" },
	config = function()
		local treesitter = require("nvim-treesitter")
		treesitter.setup({})
		local ensure_installed = {
			"bash",
			"c",
			"cpp",
			"css",
			"go",
			"html",
			"javascript",
			"json",
			"lua",
			"markdown",
			"markdown_inline",
			"python",
			"rust",
			"svelte",
			"solidity",
			"typescript",
			"vue",
			"yaml",
			"toml", -- pyproject/Cargo/foundry/starship/mise + taplo LSP
			"dockerfile", -- Dockerfile highlighting (dockerls attaches; this colours it)
			"diff", -- diffview.nvim + git diff buffers
			"gitcommit", -- commit message buffers (you write these via fugitive/lazygit)
			"vimdoc", -- :help and plugin docs
		}

		-- Installed-parser lookup, cached as a SET.
		--
		-- get_installed() is not a cheap accessor — it reads two directories off disk
		-- (nvim-treesitter/config.lua walks the `queries/` and `parser/` install dirs with
		-- vim.fs.dir) and returns a fresh list every call, measured at ~0.19ms. The old code called
		-- it inside the FileType callback and then did a LINEAR scan of the result, so every buffer
		-- you opened paid a directory walk plus an O(n) search just to answer "is this parser here?".
		-- Build the set once and answer from a hash lookup instead.
		local installed ---@type table<string, true>|nil
		local function refresh_installed()
			local set = {}
			for _, lang in ipairs(treesitter.get_installed()) do
				set[lang] = true
			end
			installed = set
		end
		refresh_installed()

		local config = require("nvim-treesitter.config")
		local already_installed = config.get_installed()
		local parsers_to_install = {}
		for _, parser in ipairs(ensure_installed) do
			if not vim.tbl_contains(already_installed, parser) then
				table.insert(parsers_to_install, parser)
			end
		end
		if #parsers_to_install > 0 then
			-- install() is async (nvim-treesitter.async). Refresh the cache when it finishes,
			-- otherwise a parser installed during this session stays invisible to start_ts until the
			-- next restart. pcall + the `await` guard because this is the `main` branch's evolving
			-- API: if the task shape ever changes we simply keep the pre-install set rather than error.
			local ok, task = pcall(treesitter.install, parsers_to_install)
			if ok and type(task) == "table" and type(task.await) == "function" then
				pcall(function()
					task:await(function()
						refresh_installed()
					end)
				end)
			end
		end

		-- Start treesitter for a buffer when its filetype's language has an installed parser.
		local function start_ts(buf, ft)
			local lang = vim.treesitter.language.get_lang(ft)
			if lang and installed and installed[lang] then
				vim.treesitter.start(buf)
			end
		end

		local group = vim.api.nvim_create_augroup("TreeSitterConfig", { clear = true })
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			callback = function(args)
				start_ts(args.buf, args.match)
			end,
		})
		-- This plugin lazy-loads on BufReadPost/BufNewFile, which fire AFTER FileType — so the
		-- buffer that TRIGGERED loading already missed the FileType autocmd above (and lazy.nvim
		-- only replays the triggering event, not FileType). Without this, the very FIRST file you
		-- open gets no highlighting/folds until re-edited. Start TS for every already-loaded
		-- buffer to cover that initial buffer.
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				start_ts(buf, vim.bo[buf].filetype)
			end
		end
	end,
}
