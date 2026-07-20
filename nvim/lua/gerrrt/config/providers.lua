-- nvim/lua/gerrrt/config/providers.lua
-- ─────────────────────────────────────────────────────────────────────────────
-- Disable the language "providers" you don't use. Neovim's perl/ruby/node/python
-- providers exist only for a small set of legacy remote plugins; disabling an
-- unused one is the CORRECT, intentional way to clear its :checkhealth warning —
-- not a workaround. It also makes startup marginally faster (no probe spawn).
-- ─────────────────────────────────────────────────────────────────────────────

vim.g.loaded_perl_provider = 0 -- almost never needed
vim.g.loaded_ruby_provider = 0 -- enable only if some plugin actually needs ruby

-- Node provider: DISABLED, because nothing in this config can reach it.
--   • Its only consumers are remote plugins (node rplugins) — there is no `:node` command and no
--     vimscript/Lua entry point equivalent to py3eval.
--   • config/lazy.lua disables the `rplugin` runtime plugin (the remote-plugin MANIFEST loader),
--     so a remote plugin could not register even if one were installed.
--   • None of the installed plugins ships a remote-plugin manifest, and none references node_host.
-- Leaving it on bought nothing and cost a permanent `:checkhealth` WARNING ("Missing 'neovim' npm
-- package") — the ONLY warning in the whole config. Disabling is the documented, intended way to
-- clear that (vim.provider's own advice line says so), not a workaround.
vim.g.loaded_node_provider = 0

-- Python3 provider: LEFT ENABLED, and unlike node this is load-bearing. vimade probes
-- `has('python3')` (vimade/autoload/vimade.vim:80) and selects a python renderer when present, so
-- disabling it silently downgrades a plugin actually in use. Do not "tidy" this one away.
-- vim.g.loaded_python3_provider = 0
