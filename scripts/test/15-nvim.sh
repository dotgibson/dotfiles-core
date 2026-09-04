# scripts/test/15-nvim.sh
# Neovim config load, lockfile, event callbacks, LSP registry (headless)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── Neovim config load (nvim/, headless) ──────────────────────────────────────
# nvim/ is the largest body of code in Core yet was validated only by luacheck
# (static). Lua that is luacheck-clean can still be a BROKEN config — a bad vim API
# call, a malformed lazy spec — that surfaces only when nvim actually starts, and it
# fans out to nine repos. This loads the AUTHORED Lua headlessly: the pure config layer
# (globals/options/keymaps/autocmds/clipboard/providers) AND every plugin SPEC file
# (require evaluates the spec TABLE; lazy's deferred config/keys callbacks do NOT run,
# so no plugin needs to be installed — every plugin `require` in this tree is inside
# such a callback). Hermetic + offline, mirroring how the zsh tests pre-seed empty
# plugin dirs; graceful skip when nvim is absent, exactly like the linters. Real
# plugin RUNTIME (the deferred callbacks) is out of scope — luacheck covers its syntax.
hdr "neovim config load (nvim/ headless)"
if ! ((SCOPE_NVIM)); then
  skip "nvim config load (out of scope)"
elif have nvim; then
  probe="$SANDBOX/nvim-probe.lua"
  cat >"$probe" <<'LUA'
vim.opt.runtimepath:prepend(vim.env.CORE_NVIM_DIR)
local errs = {}
local function try(mod)
  local ok, err = pcall(require, mod)
  if not ok then errs[#errs + 1] = mod .. " → " .. tostring(err) end
end
for _, m in ipairs({
  "gerrrt.config.globals", "gerrrt.config.options", "gerrrt.config.keymaps",
  "gerrrt.config.autocmds", "gerrrt.config.clipboard", "gerrrt.config.providers",
}) do try(m) end
-- :checkhealth gerrrt module — loaded only by checkhealth at runtime, so this is its
-- only load gate. Require it AND assert it exposes a check() function.
do
  local ok, m = pcall(require, "gerrrt.health")
  if not ok then
    errs[#errs + 1] = "gerrrt.health → " .. tostring(m)
  elseif type(m) ~= "table" or type(m.check) ~= "function" then
    errs[#errs + 1] = "gerrrt.health → did not return a table with a check() function"
  end
end
-- buf-config filetype detection (config/autocmds.lua, required above). Every buf config basename
-- must resolve to the `buf-config` filetype (so buf_ls attaches and `:checkhealth vim.lsp` stops
-- flagging an unknown filetype), and `buf-config` must alias the yaml treesitter parser (so
-- plugins/nvim-treesitter's get_lang-driven start lights these buffers). A dropped basename or a
-- lost parser alias is luacheck-clean but silently regresses attach/highlighting — and fans out 9×.
do
  for _, fname in ipairs({ "buf.yaml", "buf.gen.yaml", "buf.work.yaml", "buf.policy.yaml", "buf.lock" }) do
    local got = vim.filetype.match({ filename = fname })
    if got ~= "buf-config" then
      errs[#errs + 1] = ("buf-config ft: %s → %s (want buf-config)"):format(fname, tostring(got))
    end
  end
  local alias = vim.treesitter.language.get_lang("buf-config")
  if alias ~= "yaml" then
    errs[#errs + 1] = "buf-config ft: treesitter lang alias → " .. tostring(alias) .. " (want yaml)"
  end
end
-- every plugin spec must require cleanly and return a lazy spec table
local pdir = vim.env.CORE_NVIM_DIR .. "/lua/gerrrt/plugins"
for _, f in ipairs(vim.fn.readdir(pdir) or {}) do
  local name = f:match("^(.+)%.lua$")
  if name then
    local mod = "gerrrt.plugins." .. name
    local ok, res = pcall(require, mod)
    if not ok then
      errs[#errs + 1] = mod .. " → " .. tostring(res)
    elseif type(res) ~= "table" then
      errs[#errs + 1] = mod .. " → did not return a spec table"
    end
  end
end
-- #652 REGRESSION NET — nvim-lint must DECLARE mason.nvim as a dependency.
-- plugins/nvim-lint.lua loads on `User FilePost` and replays the triggering buffer at the end of
-- its config(), spawning Mason-installed linters (rubocop, markdownlint-cli2, eslint_d, ...). Those
-- resolve only once mason.setup() has prepended <data>/mason/bin to vim.env.PATH. nvim-lspconfig
-- loads on the SAME event and pulls mason in, but lazy.nvim orders a plugin against its DECLARED
-- dependencies only -- never against another plugin on the same event -- so without this edge the
-- replay raced mason's PATH prepend and lost about half the time: rubocop linted on open 4/6 on
-- macOS (dotgibson/dotfiles-MacBook#191) and 3/6 on Windows, while shellcheck, which lives on the
-- inherited PATH, was 6/6. vim.uv.spawn got ENOENT -- silently on Windows, where it read as "this
-- file is clean" rather than as an error.
-- ASSERTED AT SPEC LEVEL, deliberately: the ordering this guards is a lazy.nvim guarantee, so
-- re-deriving it at runtime would test lazy rather than this config -- and it cannot be tested
-- hermetically anyway (it needs lazy.nvim, nvim-lint AND mason really installed, i.e. the network).
-- Dropping the dependency is luacheck-clean, load-clean and regresses only intermittently on a real
-- machine, which is exactly the profile that needs a static gate.
-- #703 EXTENDS THE SAME NET TO conform.nvim, which had the identical undeclared dependency
-- with a WORSE failure shape. plugins/conform.lua loads on `BufWritePre` and spawns Mason-installed
-- formatters (prettierd, gofumpt, clang-format, php-cs-fixer, sql-formatter, ktlint,
-- google-java-format, taplo, ...); it declared no dependencies at all, and mason arrived only
-- incidentally via nvim-lspconfig / mason-tool-installer. Unlike #652 that is NOT a race: `-c`
-- commands run BEFORE VimEnter, so in the one-shot/scripted shape neither VeryLazy nor the
-- vim.schedule'd `User FilePost` emit has fired and mason has NEVER loaded by BufWritePre.
-- MEASURED on macOS with a `{"a":1,   "b":[1,2,3]}` fixture and prettierd (Mason-only; stylua and
-- shfmt also live on the base PATH and MASK this):
--   one-shot `nvim --headless f.json -c write -c qa!` -> 0/4 formatted (mason loaded=false,
--     executable("prettierd")=0 at BufWritePre); the same write deferred past startup (the
--     interactive shape) -> 4/4 (mason loaded=true, =1).
-- And it fails SILENTLY -- conform auto-skips a formatter that is not on PATH, so there is no
-- error and no notification, the file is just written unformatted.
-- ONE table-driven check rather than two copies: the assertion is identical, the per-entry `why`
-- keeps the failure message specific, and the next Mason-spawning spec is one more line.
for _, case in ipairs({
  {
    mod = "gerrrt.plugins.nvim-lint",
    file = "plugins/nvim-lint.lua",
    why = "its on-open replay will race mason's PATH prepend again (#652)",
  },
  {
    mod = "gerrrt.plugins.conform",
    file = "plugins/conform.lua",
    why = "format-on-save will silently skip every Mason-installed formatter in the "
      .. "one-shot/scripted shape again (#703)",
  },
}) do
  local ok, spec = pcall(require, case.mod)
  if not ok or type(spec) ~= "table" then
    errs[#errs + 1] = "mason dep: " .. case.file .. " did not load as a spec table"
  else
    local found = false
    for _, d in ipairs(spec.dependencies or {}) do
      -- lazy accepts a bare "owner/name" or a { "owner/name", opts = ... } fragment
      local dep = type(d) == "table" and d[1] or d
      if dep == "mason-org/mason.nvim" then
        found = true
      end
    end
    if not found then
      errs[#errs + 1] = "mason dep: " .. case.file .. " no longer declares "
        .. "mason-org/mason.nvim in `dependencies` -- " .. case.why
    end
  end
end
-- LSP layer: servers/init.lua wires 19 server configs + the on_attach/diagnostics
-- helpers, but ALL of it runs inside a deferred plugin callback (plugins/nvim-lspconfig)
-- — so the loop above never touches it, and luacheck (static) was its only gate. A bad
-- vim.lsp.config{} call or a typo'd capability there is luacheck-clean and breaks only on
-- first file-open, then fans out 9×. Close that: require utils.lsp/diagnostics, and every
-- servers/* LEAF. Each leaf returns a PLAIN CONFIG TABLE (it used to return a
-- `function(capabilities)` factory; capabilities now come from the "*" wildcard set once in
-- servers/init.lua, so the leaves are pure data). Requiring one evaluates the file without
-- registering anything, so no blink.cmp/lspconfig need be installed. servers/init.lua itself
-- is skipped — it require()s blink.cmp, a plugin absent from this hermetic probe.
-- utils.ui-highlights has the SAME gap: it's only require()d inside tokyonight's deferred
-- on_highlights callback (plugins/theme.lua), which the plugins/* loop above never runs — so
-- add it here too. It returns `M` with an `apply(hl, c)` function; requiring evaluates the
-- file without calling apply, so no tokyonight/colorscheme need be present.
for _, m in ipairs({ "gerrrt.utils.lsp", "gerrrt.utils.diagnostics", "gerrrt.utils.ui-highlights" }) do
  try(m)
end
local sdir = vim.env.CORE_NVIM_DIR .. "/lua/gerrrt/servers"
for _, f in ipairs(vim.fn.readdir(sdir) or {}) do
  local name = f:match("^(.+)%.lua$")
  if name and name ~= "init" then
    local mod = "gerrrt.servers." .. name
    local ok, res = pcall(require, mod)
    if not ok then
      errs[#errs + 1] = mod .. " → " .. tostring(res)
    elseif type(res) ~= "table" then
      errs[#errs + 1] = mod .. " → did not return a config table (got " .. type(res) .. ")"
    elseif next(res) == nil then
      -- An empty table means the file evaluated but configures nothing — almost certainly a
      -- botched edit rather than intent, and it would silently leave that server on defaults.
      errs[#errs + 1] = mod .. " → returned an EMPTY config table"
    end
  end
end
if #errs > 0 then
  io.stderr:write(table.concat(errs, "\n") .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("quitall!")
LUA
  # -u the probe AS init (so the repo's real bootstrap never runs → no lazy clone, no
  # network), headless, no shada/swap. A clean exit means every authored module and
  # spec loaded; the probe `:cquit 1`s with the offending modules on stderr otherwise.
  nvim_err="$SANDBOX/nvim.err"
  if CORE_NVIM_DIR="$HERE/nvim" nvim --headless -u "$probe" -i NONE -n +qa >/dev/null 2>"$nvim_err"; then
    pass "nvim loaded all config + plugin specs + LSP server configs (no lua errors)"
  else
    fail "nvim config/plugin-spec/lsp load error:"
    [[ -s "$nvim_err" ]] && sed 's/^/    /' "$nvim_err" >&2
  fi

  # Actually RUN :checkhealth gerrrt. The probe above only proves gerrrt.health LOADS and
  # exposes check(); this FIRES check() in the real checkhealth context, so a runtime error
  # in its vim.health calls (a typo'd h.warn, a bad API) is caught — nothing else exercises
  # it. -u NONE keeps it hermetic; --cmd puts nvim/ on the runtimepath so checkhealth
  # discovers lua/gerrrt/health.lua; we write the report buffer out and assert OUR section
  # rendered (h.start("dotfiles-core: …") is check()'s first call, so its absence means
  # check() never ran or threw immediately). checkhealth never prompts, so headless can't hang.
  ckrep="$SANDBOX/checkhealth.txt"
  ckerr="$SANDBOX/checkhealth.err"
  : >"$ckrep"
  # Pass the paths via ENV and fnameescape() them INSIDE vim (the idiom the event probe
  # below uses), so a space in $SANDBOX/$HERE can't break the Ex `set rtp`/`write` parsing.
  # `-c` runs post-startup in order: rtp is set before checkhealth scans it, before write.
  # Capture stderr (not /dev/null) so a failure with an empty report is still diagnosable.
  CORE_NVIM_DIR="$HERE/nvim" CORE_CK_REP="$ckrep" \
    nvim --headless -u NONE -i NONE -n \
    -c 'execute "set rtp^=" .. fnameescape($CORE_NVIM_DIR)' \
    -c 'checkhealth gerrrt' \
    -c 'execute "write!" fnameescape($CORE_CK_REP)' \
    -c 'qa!' >/dev/null 2>"$ckerr"
  # Assert ALL FIVE sections rendered — each helper's h.start() runs before any early return, so a
  # header proves that helper ran without throwing (a bad vim.health call in any of them would drop
  # its header). The LSP/formatters/linters sections show their "not loaded — open a file" info here
  # (hermetic: no plugins, no file opened), which is the correct side-effect-free behavior.
  if grep -q "dotfiles-core: clipboard" "$ckrep" 2>/dev/null \
     && grep -q "dotfiles-core: LSP servers" "$ckrep" 2>/dev/null \
     && grep -q "dotfiles-core: formatters" "$ckrep" 2>/dev/null \
     && grep -q "dotfiles-core: linters" "$ckrep" 2>/dev/null \
     && grep -q "dotfiles-core: Claude Code" "$ckrep" 2>/dev/null; then
    pass "checkhealth gerrrt ran (clipboard + LSP + formatters + linters + Claude sections rendered)"
  else
    fail "checkhealth gerrrt did not render all sections (a check() helper missing or threw):"
    [[ -s "$ckrep" ]] && sed 's/^/    /' "$ckrep" >&2
    [[ -s "$ckerr" ]] && sed 's/^/    /' "$ckerr" >&2
  fi

  # Native-Windows clipboard branch (headless, has("win32") stubbed). The Neovim CI matrix is
  # Ubuntu/macOS, so check_clipboard's has("win32") early return never runs under the gate — a
  # regression in it (running the Unix clip/clip-paste probe on the host, or a bad vim.health
  # call) would otherwise pass the full audit. This stubs vim.fn.has→win32 and CAPTURES the
  # vim.health calls (rather than rendering a report), asserting the clipboard section reports OK
  # (never warn/error) AND that the branch skips the executable()/system() probe entirely. The
  # whole body is pcall-guarded so even a bad stub cquits (fails) instead of hanging on a prompt.
  winprobe="$SANDBOX/nvim-health-win32.lua"
  cat >"$winprobe" <<'LUA'
local function run()
  local calls = {}
  vim.health = {
    start = function(s) calls[#calls + 1] = { "start", s } end,
    ok    = function(s) calls[#calls + 1] = { "ok", s } end,
    warn  = function(s) calls[#calls + 1] = { "warn", s } end,
    info  = function(s) calls[#calls + 1] = { "info", s } end,
    error = function(s) calls[#calls + 1] = { "error", s } end,
  }
  -- Force the native-Windows branch; trip a flag if the Unix probe is ever run.
  -- SCOPED TO THE CLIPBOARD SECTION. A run-wide flag would also fire on helpers that probe
  -- legitimately on Windows — check_claude gates on the `claude` binary there exactly as it does
  -- everywhere else — turning this into a "no helper may call executable()" rule, which is not the
  -- invariant being guarded. The one being guarded is: check_clipboard's win32 early return must
  -- fire BEFORE its clip/clip-paste ladder.
  local probed = false
  local function in_clipboard()
    for i = #calls, 1, -1 do
      if calls[i][1] == "start" then
        return (calls[i][2] or ""):find("dotfiles%-core: clipboard", 1) ~= nil
      end
    end
    return false
  end
  vim.fn.has = function(f) return (f == "win32") and 1 or 0 end
  vim.fn.executable = function(_) probed = probed or in_clipboard(); return 0 end
  vim.fn.system = function(_) probed = probed or in_clipboard(); return "" end
  assert(vim.fn.has("win32") == 1, "stub failed: vim.fn.has('win32') did not return 1")

  local M = dofile(vim.env.CORE_HEALTH_LUA)
  assert(type(M) == "table" and type(M.check) == "function", "health.lua did not return a module with check()")
  M.check()

  -- The clipboard section's calls run from its start() up to the next start().
  local in_clip, saw_start, saw_ok = false, false, false
  for _, c in ipairs(calls) do
    local kind, text = c[1], c[2] or ""
    if kind == "start" then
      in_clip = text:find("dotfiles%-core: clipboard", 1) ~= nil
      if in_clip then saw_start = true end
    elseif in_clip then
      assert(kind ~= "warn" and kind ~= "error", "clipboard section emitted a " .. kind .. " on native Windows: " .. text)
      if kind == "ok" then saw_ok = true end
    end
  end
  assert(saw_start, "clipboard section did not run (no start)")
  assert(saw_ok, "clipboard section did not report OK on native Windows")
  assert(not probed, "native-Windows branch called executable()/system() — it must skip the Unix probe")
end

local ok, err = pcall(run)
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("quitall!")
LUA
  win_err="$SANDBOX/nvim-health-win32.err"
  if CORE_HEALTH_LUA="$HERE/nvim/lua/gerrrt/health.lua" \
     nvim --headless -u "$winprobe" -i NONE -n +qa >/dev/null 2>"$win_err"; then
    pass "checkhealth gerrrt: native-Windows clipboard branch skips the Unix probe (has('win32') stubbed)"
  else
    fail "checkhealth gerrrt native-Windows clipboard branch probe failed:"
    [[ -s "$win_err" ]] && sed 's/^/    /' "$win_err" >&2
  fi
else
  skip "nvim config load (nvim not installed — runs in CI)"
fi

# ── lazy.nvim's lockfile lives in STATE, not the vendored tree ────────────────
# THE regression net for #465. nvim/lazy-lock.json is tracked inside core/, the one tree a
# consumer must keep byte-for-byte upstream — and lazy.nvim REWRITES its lockfile in place
# whenever plugins are installed or updated, while an OS repo bootstrap-symlinks
# ~/.config/nvim into that very tree. Opening the editor ONCE was enough to dirty it: a
# fresh openSUSE box repinned 10 plugins, a fresh Gentoo box 2, with nobody running
# :Lazy update. Consumers' vendoring gates (`make check-core`, a no-core-edits pre-commit
# hook, core-integrity at PR time) then failed closed on it — correctly, but against the
# operator, since the writer was lazy.nvim rather than a person. A pre-push gate that a
# routine editor session turns red is a gate people learn to ignore.
#
# So the contract is now: lazy writes $XDG_STATE_HOME/nvim/lazy-lock.json, and
# nvim/lazy-lock.json is a read-only fleet SEED copied in on first run. Both halves need
# pinning — the seed alone would not stop the drift, and the relocation alone would lose
# reproducibility on a fresh machine.
#
# HERMETIC, because the real thing needs the network: a STUB lazy.nvim is planted where
# lazy would be cloned (so config/lazy.lua's bootstrap finds it and skips the git clone),
# and its setup() records the opts instead of installing anything. That lets the actual
# nvim/lua/gerrrt/config/lazy.lua run start to finish — seeding included — with no plugin
# ever fetched. Asserting the recorded `lockfile` opt is what makes this a real gate rather
# than a grep: it is the value lazy would actually use.
hdr "lazy.nvim lockfile is state, not the vendored config tree (#465)"
if have nvim; then
  _lz="$(mktemp -d "$SANDBOX/lazylock.XXXXXX")"
  mkdir -p "$_lz/config" "$_lz/state" "$_lz/data" "$_lz/cache"
  # NORMALISE BOTH SIDES before comparing paths, because the two platforms disagree about
  # which form nvim reports. On macOS $TMPDIR is /var/folders/…, and /var is a symlink to
  # /private/var, and stdpath() came back RESOLVED — so comparing against the literal $_lz
  # false-reds there. Resolving only the expected side then false-reds on Linux, where the
  # same call came back LITERAL. Neither form is "the" answer, so resolve both and compare
  # resolved-to-resolved; the assertion is about WHICH DIRECTORY the lockfile is in, not
  # about which spelling of that directory nvim happened to hand back.
  _lz_real="$(cd "$_lz" && pwd -P)"
  _core_nvim_real="$(cd "$HERE/nvim" && pwd -P)"
  _lz_resolve() { # <path> — absolute, symlink-resolved; EMPTY unless the input is itself
    # an absolute path with an existing parent. The absolute-input guard is load-bearing:
    # without it, an UNSET opt arrives here as the literal "nil", `dirname nil` is ".", and
    # the result is a perfectly plausible $PWD/nil — so the "is an absolute path outside the
    # tree" assertion passes vacuously on exactly the pre-fix code it exists to catch.
    local d b
    [[ "$1" == /* ]] || return 0
    d="$(dirname "$1")" b="$(basename "$1")"
    [[ -d "$d" ]] || return 0
    printf '%s/%s' "$(cd "$d" && pwd -P)" "$b"
  }
  ln -s "$HERE/nvim" "$_lz/config/nvim"
  # The stub, at the exact path config/lazy.lua bootstraps into — so `fs_stat(lazypath)`
  # is true, no clone is attempted, and `require("lazy")` resolves here.
  mkdir -p "$_lz/data/nvim/lazy/lazy.nvim/lua/lazy"
  cat >"$_lz/data/nvim/lazy/lazy.nvim/lua/lazy/init.lua" <<'LZSTUB'
-- test stub: record what the real config asked for, install nothing.
local M = {}
function M.setup(opts)
  local f = assert(io.open(vim.env.CORE_LZ_OUT, "w"))
  f:write(tostring(opts.lockfile) .. "\n")
  f:close()
end
return M
LZSTUB
  _lz_out="$_lz/opts.txt"
  _lz_err="$_lz/nvim.err"
  # SNAPSHOT the vendored seed before the run, so assertion 3 below can ask the question it
  # actually means — "did THIS RUN write through into the vendored tree?" — against content
  # rather than against git's view of the maintainer's worktree. See the note there.
  _lz_seed_before="$_lz/seed-before.json"
  cp "$HERE/nvim/lazy-lock.json" "$_lz_seed_before"
  # -u the repo's REAL init.lua (via the symlinked config dir), not a probe: the seeding
  # runs at config load, so a probe that skipped it would test nothing.
  if HOME="$_lz" XDG_CONFIG_HOME="$_lz/config" XDG_STATE_HOME="$_lz/state" \
    XDG_DATA_HOME="$_lz/data" XDG_CACHE_HOME="$_lz/cache" \
    DOTFILES_OFFLINE=1 CORE_LZ_OUT="$_lz_out" \
    nvim --headless -i NONE -n +qa </dev/null >/dev/null 2>"$_lz_err"; then
    _lz_lock="$(head -n1 "$_lz_out" 2>/dev/null || true)"
    _lz_lock_real="$(_lz_resolve "$_lz_lock")"

    # 1) THE FIX. The path lazy was handed must be under XDG_STATE_HOME and must NOT be
    #    inside the config tree — that tree is the vendored one, and anything lazy writes
    #    there is drift a consumer's integrity gate will reject.
    if [[ "$_lz_lock_real" == "$_lz_real/state/nvim/lazy-lock.json" ]]; then
      pass "lazy lockfile resolves to \$XDG_STATE_HOME/nvim/lazy-lock.json"
    else
      fail "lazy lockfile is '$_lz_lock' — it must not live in the vendored config tree"
    fi
    # Stated as a POSITIVE requirement, not just "not inside the tree": an unset opt is
    # also not inside the tree, so the negative form alone passes vacuously on exactly the
    # pre-fix code this exists to catch. Require a real absolute path that is neither the
    # seed nor anywhere under the symlinked config dir.
    # The config dir is a SYMLINK into the repo, so "inside the config tree" resolves to
    # the repo nvim/ dir — check against that, which catches both spellings at once.
    if [[ "$_lz_lock_real" == /* && "$_lz_lock_real" != "$_core_nvim_real/"* ]]; then
      pass "lazy lockfile is an absolute path outside the symlinked config tree and is not the seed"
    else
      fail "lazy lockfile '$_lz_lock' is unset, is the seed, or is inside the vendored tree"
    fi

    # 2) REPRODUCIBILITY. A first run must start from the fleet's committed pins rather
    #    than resolving every plugin's default branch afresh — that is the entire reason
    #    Core ships a lockfile at all, and the half a bare relocation would have lost.
    # core_files_identical, not `cmp` — diffutils is not guaranteed present and this
    # repo has been bitten by assuming it (#572); the helper hashes with git instead.
    if [[ -f "$_lz/state/nvim/lazy-lock.json" ]] &&
      core_files_identical "$_lz/state/nvim/lazy-lock.json" "$HERE/nvim/lazy-lock.json"; then
      pass "first run seeds the state lockfile from Core's vendored pins (reproducible)"
    else
      fail "first run did not seed \$XDG_STATE_HOME/nvim/lazy-lock.json from the Core seed"
    fi

    # 3) The seed and the working copy must be DIFFERENT FILES, not the same inode reached
    #    two ways. Copying rather than symlinking is the whole mechanism: a symlink from
    #    state back into the config tree would satisfy every path assertion above and still
    #    let lazy write straight through into the vendored tree — the original bug wearing
    #    a state-directory costume.
    if [[ ! -L "$_lz/state/nvim/lazy-lock.json" ]]; then
      pass "the state lockfile is an independent copy, not a link back into the vendored tree"
    else
      fail "the state lockfile links back into the vendored tree"
    fi

    # 3b) The run must leave the vendored seed BYTE-IDENTICAL.
    #
    #    WHAT THIS DOES NOT CATCH, stated first so nobody reads it as more than it is: the
    #    #465 bug itself. lazy is stubbed here, so nothing plays the part of lazy REWRITING
    #    its lockfile, and "the vendored file is untouched" would pass on the pre-fix code
    #    too. Assertions 1 and 2 are what pin #465, by testing the CONFIGURED destination.
    #
    #    WHAT IT DOES CATCH: config/lazy.lua's own SEEDING, which — unlike lazy — really does
    #    run here, against a config dir symlinked at the vendored tree. `seed` there resolves
    #    to $HERE/nvim/lazy-lock.json, so an inverted fs_copyfile(lockfile, seed), an
    #    fs_symlink, or anything else that writes the seed instead of reading it would
    #    corrupt the fleet's pins from a plain editor start. That is a live path, and it is
    #    worth a gate.
    #
    #    WHY CONTENT AND NOT `git status --porcelain nvim/lazy-lock.json`, which this
    #    replaces: that asked git whether the WORKTREE was dirty, which is a different
    #    question and answers this one wrongly in both directions.
    #      · False RED, the one that bit: a maintainer running ./scripts/update-nvim-plugins.sh
    #        — the sanctioned way to move these pins — has an uncommitted seed by design, so
    #        `make audit` failed before they could commit. A gate that fires on the workflow
    #        it is meant to protect is one people learn to route around, which is the same
    #        lesson the #465 comment above already records about consumer vendoring gates.
    #      · False GREEN: outside a git checkout (a release tarball, a vendored copy) the
    #        `git rev-parse --show-toplevel` guard short-circuited the whole clause to true,
    #        so the assertion silently stopped asserting.
    #    Comparing a pre-run snapshot to the post-run file has neither failure mode and needs
    #    no repo. core_files_identical, not `cmp` — diffutils is not guaranteed present (#572).
    if core_files_identical "$_lz_seed_before" "$HERE/nvim/lazy-lock.json"; then
      pass "the run left the vendored seed byte-identical (no write-through)"
    else
      fail "the run MODIFIED $HERE/nvim/lazy-lock.json — config/lazy.lua wrote through into the vendored tree"
    fi
  else
    fail "nvim failed to load the real config with a stubbed lazy.nvim:"
    [[ -s "$_lz_err" ]] && sed 's/^/    /' "$_lz_err" >&2
  fi
else
  skip "lazy lockfile location (nvim not installed — runs in CI)"
fi

# ── Neovim event-driven autocmd callbacks (nvim/, headless) ───────────────────
# The config-load arm above proves the modules LOAD; it does not prove their EVENT
# CALLBACKS run.
# An autocmd registers fine and only its callback fires later — on a yank, a save,
# an LSP attach — so a bad vim API call inside one is luacheck-clean, load-clean, and
# breaks only when you actually edit. That blind spot shipped a real bug: the
# TextYankPost highlight called a non-existent `vim.hl.hl_op`, throwing on every yank
# AND delete (TextYankPost fires on both) while the edit still ran — a red error with
# no failing gate, fanned out to nine repos. This closes it: load the autocmds, then
# FIRE the events and assert the callbacks ran clean.
#
# Events are triggered via post-startup `-c` commands (NOT inside the `-u` init): an
# autocmd error during init makes headless nvim block on a "Press ENTER" prompt,
# whereas a `-c` error is reported and nvim proceeds to the next command — so the
# gate can never hang in CI. The require itself stays in `-u` and `cquit`s on failure
# (no prompt). Detection is STDERR-NON-EMPTY, not exit code: a fired-callback error
# does not change nvim's exit status (both clean and broken runs exit 0), it only
# prints — exactly the signature the bug has. BufWritePre (format-on-save) and
# LspAttach are deliberately NOT fired here: their callbacks require plugins
# (mini.trailspace/conform) or a live LSP attach, neither present in this hermetic
# probe — luacheck covers their syntax; runtime is out of scope.
hdr "neovim event callbacks (nvim/ headless)"
if ! ((SCOPE_NVIM)); then
  skip "nvim event callbacks (out of scope)"
elif have nvim; then
  evt_probe="$SANDBOX/nvim-events.lua"
  cat >"$evt_probe" <<'LUA'
vim.opt.runtimepath:prepend(vim.env.CORE_NVIM_DIR)
-- Register the autocmds. A require failure cquit's immediately (no ENTER prompt);
-- the EVENTS themselves are fired by the caller's -c flags, after startup.
local ok, err = pcall(require, "gerrrt.config.autocmds")
if not ok then
  io.stderr:write("require gerrrt.config.autocmds → " .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
LUA
  evt_file="$SANDBOX/probe.txt"
  printf 'one\ntwo\nthree\n' >"$evt_file"
  evt_err="$SANDBOX/nvim-events.err"
  # Stub `uv` on PATH so the Python FileType callback (config/autocmds.lua) is not gated out — it
  # registers its buffer-local pytest maps only when `executable("uv")`. The stub is never invoked
  # here (we assert the maps REGISTER, not that pytest runs), so its body only needs to exist +x.
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/uv"
  chmod +x "$SANDBOX/bin/uv"
  # Fire each registered event once: yank + delete (TextYankPost — the regression above), a
  # markdown FileType (per-filetype view options) and a python FileType (the pytest runner maps),
  # and a real file open (BufReadPost — cursor restore). Any callback that throws prints to stderr.
  # The python step also ASSERTS the buffer-local <leader>t{t,f} maps registered — matched by their
  # "pytest" desc, so the check is independent of whatever <leader> resolves to. The file path is
  # passed via $CORE_EVT_FILE and opened through fnameescape() rather than interpolated into the Ex
  # command, so a $SANDBOX/$TMPDIR containing spaces is safe.
  PATH="$SANDBOX/bin:$PATH" CORE_NVIM_DIR="$HERE/nvim" CORE_EVT_FILE="$evt_file" nvim --headless -u "$evt_probe" -i NONE -n \
    -c 'call setline(1, ["alpha","bravo","charlie"])' \
    -c 'normal! yy' -c 'normal! dd' \
    -c 'setfiletype markdown' \
    -c 'enew | setlocal filetype=python' \
    -c 'lua local ok=false; for _,k in ipairs(vim.api.nvim_buf_get_keymap(0,"n")) do if k.desc and k.desc:match("pytest") then ok=true end end; if not ok then io.stderr:write("FileType python did not register buffer-local pytest maps\n") end' \
    -c 'execute "edit" fnameescape($CORE_EVT_FILE)' \
    -c 'qa!' </dev/null >/dev/null 2>"$evt_err"
  if [[ -s "$evt_err" ]]; then
    fail "nvim autocmd callback errored when fired (e.g. the yank/delete highlight):"
    sed 's/^/    /' "$evt_err" >&2
  else
    pass "nvim event callbacks fired clean (TextYankPost yank+delete, FileType markdown+python w/ pytest maps, BufReadPost)"
  fi
else
  skip "nvim event callbacks (nvim not installed — runs in CI)"
fi

# ── Neovim `User FilePost` contract (nvim/, headless) ─────────────────────────
# config/autocmds.lua defers nvim-lspconfig, gitsigns, nvim-lint and todo-comments onto
# a custom `User FilePost` event so they load AFTER startup instead of in front of the
# first paint. Four plugins now depend on that event, but the event-callbacks arm above only proves the
# autocmds load and don't throw — it would still pass if FilePost never fired at all
# (every deferred plugin silently dead: no LSP, no linting, no git signs) or fired
# repeatedly (every later buffer re-emitting it). Neither shows up as an error, which
# is exactly the kind of silent breakage that fans out to nine repos.
#
# So assert the CONTRACT, not just the absence of errors — fires EXACTLY ONCE, in both
# startup shapes:
#   A. started WITH a file  — the readiness event arrives after the buffer is already named
#   B. bare start, then :edit two files — readiness arrives first, the first real file
#      triggers it, and the second must NOT re-fire (the augroup self-deletes)
# Counting (not just "did it fire") is what catches the fires-more-than-once regression.
# Headless is the only mode available in CI, and it is also the mode where UIEnter never
# fires — so this doubles as the guard on the VimEnter fallback that makes headless work.
#
# THE FIRST FILE MUST ALSO END UP WITH A FILETYPE. Firing FilePost synchronously inside
# the first buffer's BufReadPost chain once shipped a real bug: vim.lsp.enable() (loaded
# by FilePost) replays `doautoall <group> FileType`, and that nested trigger sets Vim's
# global did_filetype flag for the still-running chain — so the runtime filetypedetect
# handler's later `:setf` was a documented no-op and the FIRST file of every bare session
# opened with NO filetype (no highlighting, no LSP, no linter; later files fine). The
# probe can't see that through plugins — it is hermetic, FilePost loads nothing — so it
# SIMULATES the one relevant side effect: a `User FilePost` listener that replays a
# group-scoped FileType exactly like vim.lsp.enable does. If FilePost ever goes back to
# firing inside the read chain, that replay re-poisons did_filetype and the asserted
# `ft=lua` collapses to `ft=` on scenario B. (Fixtures are .lua for a filetype that is
# detected by name alone, no content sniffing.)
hdr "neovim User FilePost contract (nvim/ headless)"
if ! ((SCOPE_NVIM)); then
  skip "nvim FilePost contract (out of scope)"
elif have nvim; then
  fp_probe="$SANDBOX/nvim-filepost.lua"
  # The probe drives itself off the event loop rather than via `-c`: `-c` commands run
  # BEFORE VimEnter (:h VimEnter — it fires "after ... executing the -c cmd arguments"),
  # so reporting from a `-c` would sample the counter before readiness ever arrives and
  # report 0 on perfectly good code. vim.defer_fn lands strictly after startup, which is
  # also the ordering a real session has. Any :edit is deferred for the same reason —
  # done from `-c` it would run before readiness and test the wrong sequence.
  cat >"$fp_probe" <<'LUA'
vim.opt.runtimepath:prepend(vim.env.CORE_NVIM_DIR)
-- Count BEFORE requiring the module, so a FilePost emitted during startup is caught.
_G.filepost_count = 0
vim.api.nvim_create_autocmd("User", {
  pattern = "FilePost",
  callback = function()
    _G.filepost_count = _G.filepost_count + 1
  end,
})
-- Simulate the FileType-firing side effect of a real FilePost consumer: vim.lsp.enable()
-- replays `doautoall nvim.lsp.enable FileType` when called post-startup. The hermetic probe
-- loads no plugins, so without this replay the did_filetype poisoning path (see the header)
-- is invisible here and the ft assertion below would pass on broken code.
vim.api.nvim_create_augroup("ProbeFtReplay", { clear = true })
vim.api.nvim_create_autocmd("FileType", { group = "ProbeFtReplay", callback = function() end })
vim.api.nvim_create_autocmd("User", {
  pattern = "FilePost",
  callback = function()
    vim.cmd("doautoall ProbeFtReplay FileType")
  end,
})
local ok, err = pcall(require, "gerrrt.config.autocmds")
if not ok then
  io.stderr:write("require gerrrt.config.autocmds → " .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
vim.defer_fn(function()
  -- Scenario B only: open two real files AFTER startup. The second must not re-fire.
  local a, b = vim.env.CORE_FP_A, vim.env.CORE_FP_B
  local first_buf -- the FIRST real file's buffer: startup file (A) or first :edit (B)
  if a and a ~= "" then
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(a))
    first_buf = vim.api.nvim_get_current_buf()
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(b))
  else
    first_buf = vim.api.nvim_get_current_buf()
  end
  vim.defer_fn(function()
    -- Sampled AFTER the deferred FilePost tick, so this is the filetype the buffer is left
    -- with — `ft=` here means the first file of the session came up dead (see header).
    io.stdout:write(("filepost=%d ready=%s ft=%s\n"):format(
      _G.filepost_count, tostring(vim.g.startup_done), vim.bo[first_buf].filetype))
    vim.cmd("qa!")
  end, 200)
end, 200)
LUA
  fp_a="$SANDBOX/fp_a.lua"; printf 'return "alpha"\n' >"$fp_a"
  fp_b="$SANDBOX/fp_b.lua"; printf 'return "bravo"\n' >"$fp_b"
  fp_want='filepost=1 ready=true ft=lua'

  # A. nvim <file> — buffer is named before the readiness event arrives.
  fp_got_a=$(CORE_NVIM_DIR="$HERE/nvim" nvim --headless -u "$fp_probe" -i NONE -n "$fp_a" \
    </dev/null 2>/dev/null | tr -d '\r')
  # B. bare nvim, then open TWO files — readiness first; only the first file may fire.
  fp_got_b=$(CORE_NVIM_DIR="$HERE/nvim" CORE_FP_A="$fp_a" CORE_FP_B="$fp_b" \
    nvim --headless -u "$fp_probe" -i NONE -n \
    </dev/null 2>/dev/null | tr -d '\r')

  if [[ "$fp_got_a" == "$fp_want" ]]; then
    pass "FilePost fires exactly once when nvim starts with a file (filetype intact)"
  else
    fail "FilePost contract broken on 'nvim <file>' — want '$fp_want', got '$fp_got_a'"
  fi
  if [[ "$fp_got_b" == "$fp_want" ]]; then
    pass "FilePost fires exactly once on bare start + two :edits (no re-fire, filetype intact)"
  else
    fail "FilePost contract broken on bare-then-edit — want '$fp_want', got '$fp_got_b'"
  fi
else
  skip "nvim FilePost contract (nvim not installed — runs in CI)"
fi

# ── Neovim LSP server registry (servers/init.lua, headless) ───────────────────
# The config-load arm requires every servers/* LEAF but deliberately SKIPS servers/init.lua, because it
# require()s blink.cmp — absent from that hermetic probe. That left the registry itself
# untested: the "*" wildcard capability registration, the per-server vim.lsp.config calls,
# the failed-module isolation, and which names actually get enabled could all regress while
# the leaf probe stayed green. It is the file that decides whether you have LSP at all, and
# it fans out to nine repos.
#
# Close it by stubbing the two things that made it untestable — blink.cmp (via package.preload)
# and the vim.lsp surface — then require the real module and assert what it registered. No
# plugins, no servers, no network. Also injects a deliberately broken module to prove one bad
# server file degrades to "that server is unconfigured" instead of taking the editor down.
hdr "neovim LSP server registry (servers/init.lua, headless)"
if ! ((SCOPE_NVIM)); then
  skip "nvim LSP registry (out of scope)"
elif have nvim; then
  reg_probe="$SANDBOX/nvim-registry.lua"
  cat >"$reg_probe" <<'LUA'
vim.opt.runtimepath:prepend(vim.env.CORE_NVIM_DIR)

-- Stub blink.cmp so the registry's capabilities call resolves without the plugin.
package.preload["blink.cmp"] = function()
  return { get_lsp_capabilities = function() return { STUB_CAPS = true } end }
end
-- Break ONE server module to prove failures are isolated, not fatal.
package.preload["gerrrt.servers.gopls"] = function()
  error("deliberate probe failure")
end

-- Pin the binary gate. binary_available() calls vim.fn.executable(), so without this the
-- enabled count would depend on which language servers happen to be installed on the host —
-- different locally vs each CI runner. CORE_REG_EXE drives both directions of the gate.
local exe_result = tonumber(vim.env.CORE_REG_EXE) or 1
local real_executable = vim.fn.executable
vim.fn.executable = function() return exe_result end

local registered, enabled = {}, {}
local real_config, real_enable = vim.lsp.config, vim.lsp.enable
vim.lsp.config = setmetatable({}, {
  __call = function(_, name, cfg) registered[name] = cfg end,
  -- binary_available() reads vim.lsp.config[name]; hand back what was registered.
  __index = function(_, name) return registered[name] end,
})
vim.lsp.enable = function(names)
  for _, n in ipairs(type(names) == "table" and names or { names }) do enabled[#enabled + 1] = n end
end

local ok, mod = pcall(require, "gerrrt.servers")

-- Exercise the read-only status() export (feeds :checkhealth gerrrt) WHILE the stubs are still
-- active, so the binary gate stays pinned and get_clients() is the real (empty, headless) surface.
-- Asserts the states health.lua renders: a broken override reports registered=false (NOT masked by
-- an upstream default); a good server reports registered+enabled+available; clients is a count.
local st_ok, st_gopls_reg, st_luals_reg, st_luals_en, st_luals_av, st_luals_cl = false
if ok and type(mod) == "table" and type(mod.status) == "function" then
  local oks, rows = pcall(mod.status)
  if oks and type(rows) == "table" then
    st_ok = true
    for _, s in ipairs(rows) do
      if s.name == "gopls" then st_gopls_reg = s.registered end
      if s.name == "lua_ls" then
        st_luals_reg, st_luals_en, st_luals_av, st_luals_cl = s.registered, s.enabled, s.available, s.clients
      end
    end
  end
end

vim.lsp.config, vim.lsp.enable = real_config, real_enable
vim.fn.executable = real_executable
if not ok then
  io.stderr:write("require gerrrt.servers → " .. tostring(mod) .. "\n")
  vim.cmd("cquit 1")
end

local n_servers, n_nocmd = 0, 0
for name, cfg in pairs(registered) do
  if name ~= "*" then
    n_servers = n_servers + 1
    -- binary_available() deliberately does NOT second-guess a config without a literal cmd list
    -- (nil, or a function launcher) — those bypass the executable check entirely.
    if type(cfg) ~= "table" or type(cfg.cmd) ~= "table" then n_nocmd = n_nocmd + 1 end
  end
end
-- The broken module registered nothing, so its cmd resolves to nil and it bypasses the gate too.
if registered["gopls"] == nil then n_nocmd = n_nocmd + 1 end
io.stdout:write(("wildcard=%s caps=%s servers=%d broken_registered=%s enabled=%d nocmd=%d"):format(
  tostring(registered["*"] ~= nil),
  tostring(registered["*"] and registered["*"].capabilities and registered["*"].capabilities.STUB_CAPS or false),
  n_servers,
  tostring(registered["gopls"] ~= nil),
  #enabled,
  n_nocmd))
io.stdout:write((" status_ok=%s st_gopls_reg=%s st_luals_reg=%s st_luals_en=%s st_luals_av=%s st_luals_cl=%s\n"):format(
  tostring(st_ok),
  tostring(st_gopls_reg),
  tostring(st_luals_reg),
  tostring(st_luals_en),
  tostring(st_luals_av),
  tostring(st_luals_cl)))
vim.cmd("qa!")
LUA
  reg_err="$SANDBOX/nvim-registry.err"
  _reg_field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

  # A. every binary present. The wildcard must carry the stubbed capabilities; the deliberately
  #    broken module must NOT be registered (isolated) while the module still completes; and every
  #    configured server must end up enabled — registered ones plus the broken one, which falls
  #    back to nvim-lspconfig's own defaults rather than disappearing.
  reg_a=$(CORE_NVIM_DIR="$HERE/nvim" CORE_REG_EXE=1 nvim --headless -u "$reg_probe" -i NONE -n \
    </dev/null 2>"$reg_err" | tr -d '\r')
  a_servers=$(_reg_field "$reg_a" servers); a_enabled=$(_reg_field "$reg_a" enabled)
  if [[ "$(_reg_field "$reg_a" wildcard)" == "true" && "$(_reg_field "$reg_a" caps)" == "true" \
        && "$(_reg_field "$reg_a" broken_registered)" == "false" \
        && -n "$a_servers" && "$a_enabled" -eq $((a_servers + 1)) ]]; then
    pass "LSP registry: wildcard caps set, broken module isolated, all $a_enabled servers enabled"
  else
    fail "LSP registry contract broken — got '$reg_a' (expected caps+wildcard true, broken_registered false, enabled = servers+1)"
    [[ -s "$reg_err" ]] && sed 's/^/    /' "$reg_err" >&2
  fi

  # status() export (feeds :checkhealth gerrrt). The broken gopls override must report
  # registered=false — the whole point of tracking it separately from vim.lsp.config[name], which
  # would resolve an upstream default and hide the failure. A good server (lua_ls) must report
  # registered + enabled + available, and clients must be a number (0 in this headless probe).
  if [[ "$(_reg_field "$reg_a" status_ok)" == "true" \
        && "$(_reg_field "$reg_a" st_gopls_reg)" == "false" \
        && "$(_reg_field "$reg_a" st_luals_reg)" == "true" \
        && "$(_reg_field "$reg_a" st_luals_en)" == "true" \
        && "$(_reg_field "$reg_a" st_luals_av)" == "true" \
        && "$(_reg_field "$reg_a" st_luals_cl)" == "0" ]]; then
    pass "LSP registry: status() separates registered/enabled/available (broken override → registered=false)"
  else
    fail "LSP registry status() contract broken — got '$reg_a' (expected status_ok, gopls reg=false, lua_ls reg/en/av=true, clients=0)"
  fi

  # B. no binary present. Only configs that bypass the gate by design may remain — those with no
  #    literal `cmd` list, which binary_available() deliberately does not second-guess. Asserted
  #    against the probe's own count rather than a magic number, so adding a server can't silently
  #    invalidate it. Anything more would mean a missing binary gets enabled and then respawn-errors
  #    on every matching buffer, which is exactly what that guard exists to prevent.
  reg_b=$(CORE_NVIM_DIR="$HERE/nvim" CORE_REG_EXE=0 nvim --headless -u "$reg_probe" -i NONE -n \
    </dev/null 2>/dev/null | tr -d '\r')
  b_enabled=$(_reg_field "$reg_b" enabled); b_nocmd=$(_reg_field "$reg_b" nocmd)
  if [[ -n "$b_enabled" && "$b_enabled" == "$b_nocmd" ]]; then
    pass "LSP registry: binary gate enables only the $b_nocmd cmd-less configs when no binary exists"
  else
    fail "LSP registry binary gate broken — got '$reg_b' (expected enabled == nocmd)"
  fi
else
  skip "nvim LSP registry (nvim not installed — runs in CI)"
fi
