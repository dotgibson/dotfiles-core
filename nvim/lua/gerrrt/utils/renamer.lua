-- ================================================================================================
-- TITLE : renamer | NvChad-style inline LSP rename prompt
-- ABOUT : Replaces the bare `vim.lsp.buf.rename()` (which prompts on the cmdline) with a small,
--         cursor-anchored floating input prefilled with the symbol under the cursor — NvChad's
--         renamer look. <CR> applies the rename across the workspace, <Esc> / q cancels.
-- SAFE  : the float is a scratch buffer; on <CR> we return focus to the ORIGINAL window (so the
--         rename runs against the real symbol, not the float) before calling vim.lsp.buf.rename,
--         which handles prepareRename + the workspace edit itself. Border/title colors come from
--         utils/ui-highlights.lua (GerrrtRenamer*), so they track the theme.
-- ================================================================================================
local M = {}

function M.rename()
	local cword = vim.fn.expand("<cword>")
	if cword == "" then
		vim.lsp.buf.rename() -- nothing under cursor to prefill — fall back to native prompt
		return
	end

	-- Capture where we launched from: the rename must run in THIS window/buffer with the cursor on
	-- the symbol, not inside the float we're about to open.
	local from_win = vim.api.nvim_get_current_win()

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 1,
		width = math.max(#cword + 15, 25),
		height = 1,
		style = "minimal",
		border = "rounded", -- matches the global winborder + the rest of the config's floats
		title = { { " Rename ", "GerrrtRenamerTitle" } },
		title_pos = "center",
	})
	vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:GerrrtRenamerBorder"

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { cword })
	vim.cmd("startinsert")
	-- park the cursor at end-of-word so you can just start typing / editing the name
	pcall(vim.api.nvim_win_set_cursor, win, { 1, #cword + 1 })

	local function close()
		vim.cmd("stopinsert")
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function apply()
		local newname = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
		close()
		if newname == "" or newname == cword then
			return -- empty or unchanged → no-op
		end
		-- Back to the source window so vim.lsp.buf.rename sees the real symbol under the cursor.
		if vim.api.nvim_win_is_valid(from_win) then
			vim.api.nvim_set_current_win(from_win)
		end
		vim.lsp.buf.rename(newname)
	end

	local map = function(mode, lhs, fn)
		vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
	end
	map({ "i", "n" }, "<CR>", apply)
	map({ "i", "n" }, "<Esc>", close)
	map("n", "q", close)
end

return M
