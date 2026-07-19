-- ================================================================================================
-- TITLE : gitsigns.nvim | git hunks in the gutter
-- LINKS : https://github.com/lewis6991/gitsigns.nvim
-- NOTE  : gitsigns v1.0 DEPRECATED/REMOVED `undo_stage_hunk` — staging is now a TOGGLE: calling
--         stage_hunk on an already-staged hunk unstages it. So the old <leader>gu (undo stage)
--         is gone; <leader>gs now stages AND unstages. Current gitsigns also draws staged hunks
--         with their own signs by default, so the toggle is legible at a glance.
--         Changes from before: removed <leader>gu; nav (]h/[h) is now diff-mode aware so it
--         still steps through changes inside :diffthis / mergetool; added <leader>gS (stage
--         whole buffer) and an `ih` hunk text object (e.g. dih / vih).
-- ================================================================================================
return {
	"lewis6991/gitsigns.nvim",
	-- `User FilePost` (config/autocmds.lua) — signs appear a frame after the file instead of
	-- blocking it. gitsigns' setup iterates nvim_list_bufs() and attaches to already-open buffers,
	-- so the triggering buffer is covered without a replay.
	event = "User FilePost",
	opts = {
		on_attach = function(bufnr)
			local gs = require("gitsigns")
			local function map(mode, l, r, desc)
				vim.keymap.set(mode, l, r, { buffer = bufnr, desc = desc })
			end

			-- Navigation (diff-mode aware: fall back to ]c/[c inside diffs/mergetool)
			map("n", "]h", function()
				if vim.wo.diff then
					vim.cmd.normal({ "]c", bang = true })
				else
					gs.nav_hunk("next")
				end
			end, "Next git hunk")
			map("n", "[h", function()
				if vim.wo.diff then
					vim.cmd.normal({ "[c", bang = true })
				else
					gs.nav_hunk("prev")
				end
			end, "Prev git hunk")

			-- Stage / reset (stage_hunk toggles: stages an unstaged hunk, unstages a staged one)
			map({ "n", "v" }, "<leader>gs", gs.stage_hunk, "Stage / unstage hunk (toggle)")
			map({ "n", "v" }, "<leader>gr", gs.reset_hunk, "Reset hunk")
			map("n", "<leader>gS", gs.stage_buffer, "Stage buffer")

			-- Inspect
			map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
			map("n", "<leader>gb", function()
				gs.blame_line({ full = true })
			end, "Blame line")
			map("n", "<leader>gd", gs.diffthis, "Diff this")

			-- Hunk text object: dih / vih / cih
			map({ "o", "x" }, "ih", "<cmd>Gitsigns select_hunk<cr>", "Select hunk (text object)")
		end,
	},
}
