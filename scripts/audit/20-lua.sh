# scripts/audit/20-lua.sh
# luacheck over the VENDORED nvim/ tree
#
# A SOURCED FRAGMENT of scripts/audit-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: the PASS/SKIP/FAIL counters, $HERE (already cd'd
# to), the SCOPE_* flags, META_ALLOWLIST/META_PREFIXES, MANIFEST_PATHS/VENDOR_PATHS (parsed
# by 10-manifest.sh, §1), and the pass/skip/skip_env/fail/fail_detail/hdr/have helpers from
# scripts/lib/common.sh. NO EXIT TRAP HERE: the dispatcher installs the one that reaps the
# backgrounded behavioral suite, and `trap … EXIT` REPLACES rather than appends. The §-ids
# below are the STABLE gate ids — CLAUDE.md, CONTRIBUTING.md, VENDORING.md, PORTABILITY.md
# and the CHANGELOG all cite them — and the split did not renumber one; the NN- in this
# file's name carries run order only. See the header of scripts/audit-core.sh for the
# contract.

# ── 4. lua ───────────────────────────────────────────────────────────────────
# CORE DOES NOT AUTHOR THE EDITOR ANY MORE, so why lint it here at all? nvim/ is a
# vendored copy of dotgibson/dotfiles-nvim (#1123), whose own gate luachecks the same tree
# against a real Neovim before the release this repo pins. This leg is therefore
# defence-in-depth, kept for the reason NVIM-SPLIT-PROPOSAL.md §7(2) gives — it is the
# cheapest leg there is — and NOT, as §7(2) also says, because it is what would catch a
# corrupt sync. §9q catches that, by comparing the committed tree of nvim/ against
# nvim.lock's nvim_tree, byte for byte and with no network. A corrupt sync cannot reach
# this section without §9q having failed first.
#
# §4b WAS HERE and retired with the editor's tests (#1125): a live run of
# scripts/nvim-reachability.sh over nvim/, asking whether any lua module had fallen out of
# the load graph. That question is now answered upstream, on the same tree, by
# dotfiles-nvim's own audit §2 — and it has to be, because a tree failing it never becomes
# a release for nvim.lock to pin. The ids are stable: 4b is retired, never reused.
hdr "lua (luacheck)"
# PROBE BEFORE LINTING, so a broken toolchain is never reported as a defect in nvim/ (#726).
# `have luacheck` is a weak precondition: luarocks generates a wrapper that `exec`s an ABSOLUTE
# interpreter path, so the name stays on PATH long after the lua it was built against is gone,
# and the wrapper still answers `command -v`.
#
# EXIT CODE ALONE CANNOT SEPARATE THE TWO, which is why this is a probe and not a status check.
# luacheck's own vocabulary is 0 clean / 1 warnings / 2 syntax errors / 3 I/O error, and a
# LOAD failure — luacheck's source failing to parse or a module going missing — also exits 1.
# That is the documented mise/config.toml case: luacheck 1.2.0 cannot load under Lua 5.5 at
# all ("attempt to assign to const variable" in its own source), and it would land here as
# exit 1, indistinguishable from honest lint warnings. A missing interpreter is the easier
# shape (the shell's 126/127) and would be separable; the 5.5 one is not.
#
# `--version` lints nothing and exercises the same module load, so ANY failure from it is a
# toolchain failure by construction. One extra process on a leg that only runs when nvim/ is
# in scope.
if ! ((SCOPE_NVIM)); then
  skip "luacheck (out of scope)"
elif ! have luacheck; then
  # Name the 5.4 requirement HERE, at the moment the reader learns they need the tool —
  # mise/config.toml carries the full explanation, but nobody reaching for `luarocks install
  # luacheck` is reading a runtime pin file (#726).
  skip "luacheck (not installed — install it against an explicit Lua 5.4; luacheck 1.2.0 cannot load under 5.5, see mise/config.toml)"
else
  # The probe lints nothing; only its STATUS matters, and its output is the diagnostic to
  # show when it fails. luacheck discovers .luacheckrc by searching UP from the CWD, not the
  # target — so the lint pass runs from inside nvim/, where nvim/.luacheckrc lives. From repo
  # root it would miss the config and emit hundreds of false "undefined vim" warnings.
  lua_probe="$(luacheck --version 2>&1)"
  lua_probe_rc=$?
  if ((lua_probe_rc == 0)); then
    lua_out="$(cd nvim && luacheck . --no-color 2>&1)"
    lua_rc=$?
  else
    lua_out="$lua_probe"
    lua_rc=0
  fi
  # The three-way call is in common.sh so test-core.sh can drive every branch; this only
  # renders. Same split §1b uses, and for the same reason.
  case "$(_core_luacheck_verdict "$lua_probe_rc" "$lua_rc")" in
  ok)
    pass "luacheck nvim/"
    ;;
  broken)
    fail "luacheck is on PATH but cannot RUN — a broken toolchain, NOT a lint finding in nvim/. If it was installed with luarocks against mise's lua, that is the trap mise/config.toml describes; the sanctioned installers each pin their own 5.4. Re-running luacheck will only repeat this."
    fail_detail "$lua_probe"
    ;;
  broken-midrun)
    fail "luacheck stopped being runnable mid-audit (exit $lua_rc) — the toolchain broke after the version probe passed, so this is not a lint finding in nvim/"
    fail_detail "$lua_out"
    ;;
  *)
    fail "luacheck reported issues — run: (cd nvim && luacheck .)"
    fail_detail "$lua_out"
    ;;
  esac
  unset lua_rc lua_probe_rc lua_probe lua_out
fi
