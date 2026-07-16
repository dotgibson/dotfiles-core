-- ================================================================================================
-- TITLE : auto-commands
-- ABOUT : automatically run code on defined events (e.g. save, yank)
-- ================================================================================================
local on_attach = require("gerrrt.utils.lsp").on_attach

-- Restore last cursor position when reopening a file
local last_cursor_group = vim.api.nvim_create_augroup("LastCursorGroup", {})
vim.api.nvim_create_autocmd("BufReadPost", {
  group = last_cursor_group,
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    local lcount = vim.api.nvim_buf_line_count(0)
    if mark[1] > 0 and mark[1] <= lcount then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Highlight the yanked text for 200ms
local highlight_yank_group = vim.api.nvim_create_augroup("HighlightYank", {})
vim.api.nvim_create_autocmd("TextYankPost", {
  group = highlight_yank_group,
  pattern = "*",
  callback = function()
    -- vim.hl.on_yank is the current API (it succeeded vim.highlight.on_yank when the
    -- highlight helpers moved to the vim.hl namespace). TextYankPost fires on yanks
    -- AND deletes, so a bad call here throws E5108 on every such edit — the op still
    -- runs, but a red error trails it. There is no vim.hl.hl_op.
    vim.hl.on_yank({
      higroup = "IncSearch",
      timeout = 200,
    })
  end,
})

-- Format on save: trim trailing whitespace, then run conform.
-- lsp_format = "fallback" means filetypes without a conform formatter still get
-- formatted by their LSP (e.g. gopls), and filetypes with neither are left alone.
local lsp_fmt_group = vim.api.nvim_create_augroup("FormatOnSaveGroup", {})
vim.api.nvim_create_autocmd("BufWritePre", {
  group = lsp_fmt_group,
  callback = function(args)
    require("mini.trailspace").trim()
    -- Never auto-format zsh. shfmt (whether reached through conform OR through the
    -- lsp_format="fallback" path via bash-language-server, which shells out to shfmt)
    -- parses zsh as bash and silently corrupts zsh-only syntax. Skipping by FILETYPE
    -- (not a single filename) protects every zsh file in Core, not just plugins.zsh.
    -- Trailing-whitespace trim above already ran, so zsh still gets that.
    if vim.bo[args.buf].filetype == "zsh" then
      return
    end
    require("conform").format({ bufnr = args.buf, lsp_format = "fallback", timeout_ms = 1500 })
  end,
})

-- on attach function shortcuts
local lsp_on_attach_group = vim.api.nvim_create_augroup("LspMappings", {})
vim.api.nvim_create_autocmd("LspAttach", {
  group = lsp_on_attach_group,
  callback = on_attach,
})

-- custom options for text/markdown files
local markdown_options = vim.api.nvim_create_augroup("MarkdownOptions", {})
vim.api.nvim_create_autocmd("FileType", {
  group = markdown_options,
  pattern = { "markdown", "text", "gitcommit" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.relativenumber = false
    vim.opt_local.number = false
    vim.opt_local.cursorline = false
    vim.opt_local.colorcolumn = ""
    vim.opt_local.signcolumn = "no"
    vim.opt_local.conceallevel = 2 -- conceal markup (link/bold markers); moved here from global options
    vim.opt_local.concealcursor = "" -- still show markup on the cursor line
  end,
})

-- Notify when the tracked upstream is ahead of HEAD, so you know to rebase/pull before starting.
-- Async `git fetch` on VimEnter so startup never blocks. Gated on dotfiles_offline (engagement
-- boxes) — same switch that already silences lazy's checker and mason, so this never emits
-- unattended network traffic on a Kali/Defense box. Routes through vim.notify -> mini.notify,
-- so the toast matches the rest of the UI for free.
if not vim.g.dotfiles_offline then
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("GitRemoteAhead", { clear = true }),
    callback = function()
      if os.execute("git rev-parse --is-inside-work-tree > /dev/null 2>&1") ~= 0 then
        return -- not a git repo
      end
      vim.fn.jobstart({ "git", "fetch" }, {
        on_exit = function()
          local count = vim.fn.system("git rev-list --count HEAD..@{u} 2>/dev/null"):gsub("%s+", "")
          if count ~= "" and tonumber(count) and tonumber(count) > 0 then
            vim.schedule(function()
              -- \u{f0662} nf-md-source_branch_sync, written as an escape so the glyph survives
              -- transfer (house convention, matches lualine.lua / diagnostics.lua).
              vim.notify("\u{f0662} " .. count .. " new commit(s) on remote", vim.log.levels.INFO, { title = "Git" })
            end)
          end
        end,
      })
    end,
  })
end

-- Show cursorline only in the active window. Pairs with vimade (plugins/vimade.lua): vimade fades
-- inactive splits, this drops their cursorline, together giving a clear "which split is live" cue
-- for the globalstatus + split-heavy workflow. cursorline defaults ON globally (options.lua); this
-- just suppresses it on the windows you're not in.
local active_cursorline_group = vim.api.nvim_create_augroup("ActiveCursorline", { clear = true })
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = active_cursorline_group,
  callback = function()
    vim.opt_local.cursorline = true
  end,
})
vim.api.nvim_create_autocmd("WinLeave", {
  group = active_cursorline_group,
  callback = function()
    vim.opt_local.cursorline = false
  end,
})
