# scripts/audit/20-lua.sh
# luacheck over nvim/, and no lua module under nvim/lua/gerrrt is orphaned
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

# ── 4b. nvim module reachability (the orphan backstop) ───────────────────────
# core.manifest lists `nvim/` as a DIRECTORY, so §1's manifest⇄fs drift check auto-lists
# every new path under it and cannot see an orphan — a lua module nothing loads would sit
# in the tree and fan out to all nine Core-vendoring repos silently. core.manifest said that gap was
# covered "by verify-core.sh instead"; that script has never existed here (#454). The real
# logic — a graph walk from nvim/init.lua, not a "is this name mentioned" scan — lives in
# the script below, along with the rationale for its roots and its two resolved edges. It
# is a standalone script rather than an inline block precisely so test-core.sh can drive
# it against synthetic fixtures. Findings arrive one per line; each becomes a fail.
hdr "nvim module reachability"
if ! ((SCOPE_NVIM)); then
  skip "nvim reachability (out of scope)"
elif [[ ! -d nvim/lua/gerrrt ]]; then
  skip "nvim reachability (no nvim/lua/gerrrt)"
else
  # Gate on the EXIT STATUS as well as the output. Deciding purely on "did it print
  # anything" means a silent non-zero exit — the script killed, or dying before it can
  # emit a diagnostic — reads as a passing gate, which is the one outcome a backstop must
  # never produce. Pass requires rc 0 AND no findings; anything else fails, and a
  # status-without-output still says something actionable rather than nothing.
  orph_out="$("$HERE/scripts/nvim-reachability.sh" --root "$HERE" 2>&1)"
  orph_rc=$?
  if [[ -n "$orph_out" ]]; then
    while IFS= read -r orph_line; do
      [[ -n "$orph_line" ]] && fail "nvim: $orph_line"
    done <<EOF
$orph_out
EOF
    ((orph_rc == 0)) && fail "nvim: reachability reported findings but exited 0 (contract violation)"
  elif ((orph_rc == 0)); then
    pass "nvim module reachability (no orphaned lua modules)"
  else
    fail "nvim: reachability exited $orph_rc with no output — the gate did not actually run"
  fi
fi
