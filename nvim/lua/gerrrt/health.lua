-- nvim/lua/gerrrt/health.lua
-- ─────────────────────────────────────────────────────────────────────────────
-- `:checkhealth gerrrt` — a precise, actionable report for Core's Neovim bits that
-- otherwise fail with a generic message. Two sections:
--   • clipboard  — when no backend exists, `"+y` / `"+p` surface only Neovim's opaque
--     "clipboard provider" error. Here we run the SAME `clip` / `clip-paste` ladder the
--     provider uses and say exactly what's missing and how to fix it.
--   • LSP servers — the built-in `:checkhealth vim.lsp` only lists clients ATTACHED to the
--     current session, so from the dashboard it reads "No active clients" and tells you
--     nothing about whether your configured servers are installed. This section reports
--     every WANTED server (from gerrrt/servers) as installed/enabled/attached instead.
--
-- This module is loaded ONLY by :checkhealth (Neovim discovers lua/**/health.lua) —
-- it is never required at startup, so it adds nothing to load time.
-- ─────────────────────────────────────────────────────────────────────────────
local M = {}

local function check_clipboard(h)
  h.start("dotfiles-core: clipboard")

  local have_clip = vim.fn.executable("clip") == 1
  local have_paste = vim.fn.executable("clip-paste") == 1

  if not (have_clip and have_paste) then
    -- Core's bootstrap symlinks clip/clip-paste into ~/.local/bin; without them
    -- clipboard.lua leaves Neovim's own auto-detection in place (see its header).
    h.warn(
      ("Core's cross-OS clipboard scripts are not on PATH (clip: %s, clip-paste: %s)"):format(
        have_clip and "found" or "missing",
        have_paste and "found" or "missing"
      ),
      {
        "Neovim is using its built-in clipboard auto-detection instead.",
        "Run Core's bootstrap (it symlinks clip/clip-paste into ~/.local/bin),",
        "or add them to PATH, to get the unified WSL/macOS/Wayland/X11 provider.",
      }
    )
    return
  end

  h.ok("clip and clip-paste are on PATH")

  -- Probe a real backend by READING the clipboard (clip-paste mutates nothing). On a
  -- working box it exits 0; with no backend it exits 1 with the install hint, exactly
  -- the path that otherwise only shows up as an opaque yank/paste failure.
  local out = vim.fn.system({ "clip-paste" })
  if vim.v.shell_error == 0 then
    h.ok('a clipboard backend is reachable (clip-paste succeeded) — "+y / "+p will work')
  else
    h.error('no clipboard backend is reachable — "+y / "+p will fail', {
      "Install one for your session:",
      "  Wayland : wl-clipboard   (wl-copy / wl-paste)",
      "  X11     : xclip   or   xsel",
      "  macOS   : pbcopy/pbpaste ship with the OS",
      "  WSL     : clip.exe / powershell ship with Windows",
      vim.trim(out ~= "" and ("clip-paste said: " .. out) or ""),
    })
  end
end

local function check_lsp(h)
  h.start("dotfiles-core: LSP servers")

  -- require is idempotent (Lua caches the module), so this loads the registry if a code
  -- file hasn't yet triggered it, and is a cheap cache hit otherwise. M.status() reuses the
  -- servers module's own wanted-list + binary_available(), so there's no second list to drift.
  local ok, servers = pcall(require, "gerrrt.servers")
  if not ok or type(servers.status) ~= "function" then
    h.info("LSP registry not loaded yet — open a code file, then re-run :checkhealth gerrrt")
    return
  end

  local offline = vim.g.dotfiles_offline
  local attached, enabled, missing, broken = 0, 0, 0, 0

  for _, s in ipairs(servers.status()) do
    if not s.configured then
      broken = broken + 1
      h.error(("%s — config failed to load"):format(s.name), { "See :messages for the gerrrt.servers error." })
    elseif s.clients > 0 then
      attached = attached + 1
      h.ok(("%s — attached (%d client%s)"):format(s.name, s.clients, s.clients == 1 and "" or "s"))
    elseif s.available then
      enabled = enabled + 1
      h.ok(("%s — installed & enabled (no client attached right now)"):format(s.name))
    elseif offline then
      -- DOTFILES_OFFLINE boxes intentionally omit tooling; a missing binary is expected, not a
      -- defect — keep the section green (mirrors the startup-notify suppression in servers/init.lua).
      missing = missing + 1
      h.info(("%s — binary not found (DOTFILES_OFFLINE: expected)"):format(s.name))
    else
      missing = missing + 1
      h.warn(("%s — binary not found, server not enabled"):format(s.name), {
        "Install via :Mason (except ruff/ty via `uv tool install`, rust via rustup).",
      })
    end
  end

  h.info(
    ("%d attached · %d enabled (idle) · %d missing · %d broken"):format(attached, enabled, missing, broken)
      .. "\n'attached' is a snapshot of THIS moment — servers attach per-filetype, so open a file of that"
      .. " language to watch its server start."
  )
end

function M.check()
  local h = vim.health
  check_clipboard(h)
  check_lsp(h)
end

return M
