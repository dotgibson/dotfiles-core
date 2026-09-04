# scripts/test/40-gen-theme-aliases.sh
# theme + aliases generation (scripts/gen-theme.sh, scripts/gen-aliases.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── theme generation (scripts/gen-theme.sh) ───────────────────────────────────
# theme/palette.toml is the ONE place a colour is authored; gen-theme.sh renders it
# into every consumer, and audit-core.sh §9d gates the result. What is worth pinning
# here is NOT that generation works — §9d proves that against the real tree on every
# run — but the failure directions, which the real tree can never exercise without
# mutating tracked files.
#
# ONE FIXTURE PER ENCODING, not per consumer. The palette lives in FOUR forms across
# the tree — bare #rrggbb, zsh %F{#rrggbb} prompt specs, 24-bit decimal SGR triplets
# (lib/ux.sh:50 has no hex in it AT ALL), and hand-picked 256-colour indices. A
# fixture set covering only the first would pass a generator that silently skipped
# lib/ux.sh, and the gate would then be green about a file it no longer rendered.
# That is the exact shape of coverage-loss-reading-as-health this whole feature
# exists to end, so each encoding gets its own row below.
if have git; then
  hdr "theme generation (scripts/gen-theme.sh)"
  GT="$HERE/scripts/gen-theme.sh"
  GTR="$SANDBOX/themerepo"

  # _gt_fixture — rebuild a pristine fixture tree. Every assertion starts from this,
  # so a mutation in one row cannot leak into the next.
  _gt_fixture() {
    rm -rf "$GTR"
    mkdir -p "$GTR/theme" "$GTR/scripts" "$GTR/scripts/lib" "$GTR/zsh" "$GTR/lib" "$GTR/tmux"
    cp "$HERE/scripts/gen-theme.sh" "$GTR/scripts/"
    cp "$HERE/scripts/lib/common.sh" "$GTR/scripts/lib/"
    cat >"$GTR/theme/palette.toml" <<'GTPAL'
schema = 1
style = "storm"
# core:theme:gen palette-colors
color_bg                = "#24283b"
color_bg_dark           = "#1f2335"
color_bg_highlight      = "#292e42"
color_bg_visual         = "#2e3c64"
color_black             = "#1d202f"
color_blue              = "#7aa2f7"
color_blue1             = "#2ac3de"
color_border_highlight  = "#29a4bd"
color_comment           = "#565f89"
color_cyan              = "#7dcfff"
color_dark3             = "#545c7e"
color_fg                = "#c0caf5"
color_fg_dark           = "#a9b1d6"
color_green             = "#9ece6a"
color_magenta           = "#bb9af7"
color_magenta2          = "#ff007c"
color_orange            = "#ff9e64"
color_red               = "#f7768e"
color_red1              = "#db4b4b"
color_terminal_black    = "#414868"
color_yellow            = "#e0af68"
# core:theme:end palette-colors
role_accent = "blue"
role_muted  = "comment"
role_ok     = "green"
role_err    = "red"
role_rule   = "terminal_black"
fallback_accent_sgr  = 111
fallback_muted_sgr   = 103
fallback_accent_spec = 75
fallback_muted_spec  = 244
GTPAL
    # Encoding 1: bare #rrggbb, and a HAND-AUTHORED line on either side of the block.
    cat >"$GTR/tmux/tmux.conf" <<'GTTMUX'
# hand-authored above
set -g cursor-style block
# core:theme:gen tmux-palette
# core:theme:end tmux-palette
set -g status-position top
GTTMUX
    # Encoding 2: zsh %F{#rrggbb} prompt specs.
    cat >"$GTR/zsh/00-tools.zsh" <<'GTTOOLS'
# core:theme:gen sep-rule-colors
# core:theme:end sep-rule-colors
GTTOOLS
    # Encodings 3 + 4: decimal SGR triplets AND hand-picked 256-colour indices —
    # lib/ux.sh carries NO hex at all, which is why it needs its own rows below.
    # The REAL file, not a stub: scripts/lib/common.sh sources ../../lib/ux.sh for
    # its own palette, so a stub here breaks the generator before it starts. Using
    # the real one also means these rows exercise the shipped block, not a mock.
    cp "$HERE/lib/ux.sh" "$GTR/lib/ux.sh"
  }

  # _gt_run <args...> — invoke the generator against the fixture, echo its exit code.
  # env -u CORE_JSON: CORE_JSON is exported to nested gates and would suppress the
  # child's human output (see the boundary note at the top of this file).
  _gt_run() { (cd "$GTR" && env -u CORE_JSON bash ./scripts/gen-theme.sh "$@" >/dev/null 2>&1; echo $?); }
  _gt_out() { (cd "$GTR" && env -u CORE_JSON bash ./scripts/gen-theme.sh "$@" 2>&1); }

  _gt_fixture
  _gt_gen_rc="$(_gt_run)"
  if [[ "$_gt_gen_rc" == 0 ]]; then
    pass "gen-theme: renders a fixture tree clean"
  else
    fail "gen-theme: bare run failed on a clean fixture (rc=$_gt_gen_rc)"
  fi

  # 1. POSITIVE — a freshly generated tree is, by definition, not drifted.
  if [[ "$(_gt_run --check)" == 0 ]]; then
    pass "gen-theme: --check is 0 on a freshly generated tree"
  else
    fail "gen-theme: --check reported drift on its own output"
  fi

  # Each encoding actually landed. Asserting the RENDERED BYTES, not just an exit
  # code: a generator that wrote empty blocks would satisfy --check forever.
  if grep -q 'set -g @tn_blue    "#7aa2f7"' "$GTR/tmux/tmux.conf"; then
    pass "gen-theme: renders the bare-hex encoding (tmux @tn_*)"
  else
    fail "gen-theme: bare-hex encoding missing from the tmux fixture"
  fi
  if grep -q "col='%F{#414868}'" "$GTR/zsh/00-tools.zsh"; then
    pass "gen-theme: renders the zsh %F{} prompt-spec encoding"
  else
    fail "gen-theme: %F{} encoding missing from the 00-tools fixture"
  fi
  # 122;162;247 IS #7aa2f7 in decimal. The derivation is the assertion.
  if grep -q '38;2;122;162;247' "$GTR/lib/ux.sh"; then
    pass "gen-theme: derives the 24-bit decimal-SGR encoding from the hex"
  else
    fail "gen-theme: decimal-SGR encoding missing or underived in the ux.sh fixture"
  fi
  if grep -q '38;5;111' "$GTR/lib/ux.sh"; then
    pass "gen-theme: emits the hand-picked 256-colour fallbacks verbatim"
  else
    fail "gen-theme: 256-colour fallback missing from the ux.sh fixture"
  fi

  # 2. NEGATIVE — drift INSIDE a block is caught, exits 1, and NAMES the file. A gate
  # that reds on everything is as useless as one that reds on nothing.
  _gt_fixture && _gt_run >/dev/null
  sed -i.bak 's/#7aa2f7/#deadbe/' "$GTR/tmux/tmux.conf" && rm -f "$GTR/tmux/tmux.conf.bak"
  _gt_drift_rc="$(_gt_run --check)"
  if [[ "$_gt_drift_rc" == 1 ]]; then
    pass "gen-theme: --check exits 1 on drift inside a block"
  else
    fail "gen-theme: --check did not report drift as 1 (rc=$_gt_drift_rc)"
  fi
  # Captured, NOT piped into `grep -q`: an early-exiting reader SIGPIPEs the
  # producer and, under pipefail, fails the pipeline no matter what it printed.
  # That is the §5d hazard audit-core.sh gates, and it fires here too.
  _gt_drift_out="$(_gt_out --check)"
  if grep -q 'tmux/tmux.conf' <<<"$_gt_drift_out"; then
    pass "gen-theme: the drift report names the file that drifted"
  else
    fail "gen-theme: drift reported without naming the file"
  fi

  # 3. NEGATIVE, INVERSE — the region markers are the whole mechanism. Without this
  # row a generator that simply diffed WHOLE FILES passes row 2 and is still wrong:
  # every consumer carries hand-authored prose around its palette.
  _gt_fixture && _gt_run >/dev/null
  printf '# a hand-authored line added after generation\n' >>"$GTR/tmux/tmux.conf"
  if [[ "$(_gt_run --check)" == 0 ]]; then
    pass "gen-theme: an edit OUTSIDE a block is not drift"
  else
    fail "gen-theme: --check fired on a hand-authored line outside the markers"
  fi
  # …and regeneration must not eat it.
  _gt_run >/dev/null
  if grep -q 'a hand-authored line added after generation' "$GTR/tmux/tmux.conf"; then
    pass "gen-theme: regeneration preserves hand-authored content outside blocks"
  else
    fail "gen-theme: regeneration ate a hand-authored line"
  fi

  # 4. The decimal-SGR row, which is the one a hex-only drift check cannot see.
  _gt_fixture && _gt_run >/dev/null
  sed -i.bak 's/38;2;122;162;247/38;2;122;162;248/' "$GTR/lib/ux.sh" && rm -f "$GTR/lib/ux.sh.bak"
  if [[ "$(_gt_run --check)" == 1 ]]; then
    pass "gen-theme: catches drift in the decimal-SGR encoding (no hex to grep)"
  else
    fail "gen-theme: decimal-SGR drift went undetected — lib/ux.sh is unguarded"
  fi

  # 5. The 256-colour row, same argument.
  _gt_fixture && _gt_run >/dev/null
  sed -i.bak 's/38;5;111/38;5;110/' "$GTR/lib/ux.sh" && rm -f "$GTR/lib/ux.sh.bak"
  if [[ "$(_gt_run --check)" == 1 ]]; then
    pass "gen-theme: catches drift in the 256-colour fallback encoding"
  else
    fail "gen-theme: 256-colour drift went undetected"
  fi

  # 6. IDEMPOTENCE. A generator that reorders keys or stamps a timestamp makes
  # --check permanently red on a clean tree, which is how a gate gets turned off.
  _gt_fixture && _gt_run >/dev/null
  cp -R "$GTR" "$GTR.first"
  _gt_run >/dev/null
  # `git diff --no-index`, not `diff -r`: audit-core.sh forbids the diffutils
  # binaries (#572), and this drops the dependency on the Alpine leg too.
  if git --no-pager diff --no-index --quiet -- "$GTR.first" "$GTR" 2>/dev/null; then
    pass "gen-theme: generation is idempotent (second run is byte-identical)"
  else
    fail "gen-theme: a second run changed the tree — --check can never be stably green"
  fi
  rm -rf "$GTR.first"

  # 7. --check MUST NOT WRITE. A drift gate that quietly repairs can never be red,
  # so CI would go green on a tree nobody regenerated.
  _gt_fixture && _gt_run >/dev/null
  sed -i.bak 's/#7aa2f7/#deadbe/' "$GTR/tmux/tmux.conf" && rm -f "$GTR/tmux/tmux.conf.bak"
  _gt_before="$(git hash-object "$GTR/tmux/tmux.conf")"
  _gt_run --check >/dev/null
  _gt_after="$(git hash-object "$GTR/tmux/tmux.conf")"
  if [[ "$_gt_before" == "$_gt_after" ]]; then
    pass "gen-theme: --check writes nothing, even to a drifted file"
  else
    fail "gen-theme: --check REPAIRED a drifted file — the gate can never be red"
  fi

  # 8. FAIL CLOSED: no palette. Must be non-zero AND must not be 1 — "cannot run" and
  # "drift" are different facts, and §9d renders them differently on purpose. A gate
  # that reports a crash as drift teaches everyone to re-run it and ignore it.
  _gt_fixture && _gt_run >/dev/null
  rm -f "$GTR/theme/palette.toml"
  _gt_nopal_rc="$(_gt_run --check)"
  if [[ "$_gt_nopal_rc" != 0 && "$_gt_nopal_rc" != 1 ]]; then
    pass "gen-theme: a missing palette is 'cannot run' (rc=$_gt_nopal_rc), not drift"
  else
    fail "gen-theme: missing palette reported as rc=$_gt_nopal_rc (want non-zero, not 1)"
  fi

  # 9. FAIL CLOSED: stripped markers. Otherwise deleting two comment lines is an
  # undetectable way to opt a file out of the gate forever.
  _gt_fixture && _gt_run >/dev/null
  sed -i.bak '/core:theme:gen tmux-palette/d;/core:theme:end tmux-palette/d' "$GTR/tmux/tmux.conf"
  rm -f "$GTR/tmux/tmux.conf.bak"
  if [[ "$(_gt_run --check)" != 0 ]]; then
    pass "gen-theme: stripping a block's markers FAILS (cannot silently opt out)"
  else
    fail "gen-theme: a file whose markers were deleted still passed --check"
  fi

  # 10. FAIL CLOSED: a malformed palette, naming the offending key. The alternative is
  # emitting a literal `chartreuse` into fzf's --color, which fzf accepts silently.
  _gt_fixture
  sed -i.bak 's/^role_accent = "blue"/role_accent = "chartreuse"/' "$GTR/theme/palette.toml"
  rm -f "$GTR/theme/palette.toml.bak"
  _gt_bad_out="$(_gt_out --check)"
  if [[ "$(_gt_run --check)" != 0 ]] && grep -q 'role_accent' <<<"$_gt_bad_out"; then
    pass "gen-theme: a role naming an undefined colour FAILS, and names the key"
  else
    fail "gen-theme: a malformed palette was accepted, or the message did not name the key"
  fi

  # 11. The comment-strip trap. Every value in palette.toml starts with '#', so a
  # naive sub(/#.*/,"") reader eats the colour itself and yields an empty string.
  # Asserting the RENDERED value is what proves the reader survived its own syntax.
  _gt_fixture && _gt_run >/dev/null
  if grep -qE 'set -g @tn_bg +"#24283b"' "$GTR/tmux/tmux.conf"; then
    pass "gen-theme: the TOML reader does not mistake a hex value for a comment"
  else
    fail "gen-theme: a colour rendered empty or wrong — the comment-strip ate the value"
  fi

  # 12. --list is the coverage surface, so it must agree with the tree rather than
  # with a second hand-maintained list inside the script.
  _gt_fixture
  if [[ "$(_gt_out --list | grep -c .)" == 4 ]]; then
    pass "gen-theme: --list enumerates exactly the blocks present in the tree"
  else
    fail "gen-theme: --list disagreed with the fixture ($(_gt_out --list | grep -c .) of 4)"
  fi

  # 13. LIVE SMOKE against the real tree. Deliberately duplicates audit-core.sh §9d:
  # `make test` runs without the audit, and check-modern.sh sets the same precedent.
  if [[ "$(cd "$HERE" && env -u CORE_JSON bash "$GT" --check >/dev/null 2>&1; echo $?)" == 0 ]]; then
    pass "gen-theme: the real tree matches theme/palette.toml"
  else
    fail "gen-theme: the real tree has drifted — run: make gen-theme"
  fi

  # 14. The cross-repo needle parity-check.sh greps in BOTH shells. Reformatting the
  # fzf block — one-per-line to a single line, reordering, dropping :regular — breaks
  # that gate even with an identical palette, so it is pinned HERE, in the PR that
  # would break it, rather than in the weekly cross-repo sweep.
  _gt_fg="$(sed -nE 's/^color_fg[[:space:]]*=[[:space:]]*"(#[0-9a-f]{6})".*/\1/p' "$HERE/theme/palette.toml" | head -n1)"
  if [[ -n "$_gt_fg" ]] && grep -qF "query:${_gt_fg}:regular" "$HERE/zsh/35-fzf.zsh"; then
    pass "gen-theme: the fzf palette keeps parity-check.sh's query:<fg>:regular token intact"
  else
    fail "gen-theme: zsh/35-fzf.zsh no longer carries query:${_gt_fg:-<fg>}:regular — parity-check.sh will misfire"
  fi

  # NOT COVERED HERE, deliberately: --refresh reaches the tokyonight plugin tree, so it
  # needs nvim AND the pinned plugin installed — neither is guaranteed on a CI leg or a
  # bare box. What IS asserted is that it REFUSES rather than emitting an empty palette.
  _gt_fixture
  _gt_refresh_rc="$(cd "$GTR" && env -u CORE_JSON PATH=/nonexistent-for-this-test \
    /usr/bin/env bash ./scripts/gen-theme.sh --refresh >/dev/null 2>&1; echo $?)"
  if [[ "$_gt_refresh_rc" != 0 ]]; then
    pass "gen-theme: --refresh refuses when nvim is unreachable (never a silent no-op)"
  else
    fail "gen-theme: --refresh returned 0 with no nvim — it cannot have resolved anything"
  fi

  rm -rf "$GTR"
  unset _gt_gen_rc _gt_drift_rc _gt_before _gt_after _gt_nopal_rc _gt_fg _gt_refresh_rc
  unset _gt_drift_out _gt_bad_out
else
  skip "theme generation (git unavailable)"
fi

# ── aliases generation (scripts/gen-aliases.sh) ──────────────────────────────
# aliases.md's tables are rendered from the zsh sources and audit-core.sh §9g gates the
# result against the real tree. As with the theme generator above, what is worth pinning
# here is the FAILURE
# DIRECTIONS the real tree can never exercise without mutating tracked files — and the
# one that matters most, "an alias was added and no table lists it", is a structural
# exit (2), not drift (1), so the two must be told apart on purpose.
#
# The fixture carries the REAL zsh sources (a synthetic set would have to define every
# name the registry claims, and the registry is the thing under test) and a stub
# aliases.md holding one marker pair per registered block with hand-authored lines on
# either side. The block ids are read out of the script's own BLOCKS table so this
# section cannot silently fall out of step with the registry.
#
# THE REPOSITORY SCRIPT IS RUN WITH --root, not a copy from inside the fixture: --root
# is the documented fixture mechanism, so it is the thing to exercise — a copied script
# run from its own tree would keep this section green while --root's argument parsing
# or root switch regressed.
if have git; then
  hdr "aliases generation (scripts/gen-aliases.sh)"
  GAR="$SANDBOX/aliasrepo"
  _ga_ids="$(awk '/^BLOCKS="/ { f = 1; sub(/^BLOCKS="/, "") } f { print $1; if (/"$/) f = 0 }' "$HERE/scripts/gen-aliases.sh")"

  _ga_fixture() {
    rm -rf "$GAR"
    mkdir -p "$GAR/zsh"
    cp "$HERE/zsh/20-aliases.zsh" "$HERE/zsh/25-git.zsh" "$HERE/zsh/30-functions.zsh" "$GAR/zsh/"
    {
      printf '# fixture cheat sheet\n\nhand-authored above the first block\n\n'
      for _id in $_ga_ids; do
        printf '<!-- core:aliases:gen %s -->\n<!-- core:aliases:end %s -->\n\n' "$_id" "$_id"
      done
      printf 'hand-authored below the last block\n'
    } >"$GAR/aliases.md"
  }
  # Run from $SANDBOX, not from $GAR or the repo: proves --root, not the cwd, picks the tree.
  _ga_run() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-aliases.sh" --root "$GAR" "$@" >/dev/null 2>&1; echo $?); }
  _ga_out() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-aliases.sh" --root "$GAR" "$@" 2>&1); }

  _ga_fixture
  _ga_gen_rc="$(_ga_run)"
  if [[ "$_ga_gen_rc" == 0 ]]; then
    pass "gen-aliases: renders a fixture tree clean"
  else
    fail "gen-aliases: bare run failed on a clean fixture (rc=$_ga_gen_rc): $(_ga_out | head -n 3)"
  fi
  if [[ "$(_ga_run --check)" == 0 ]]; then
    pass "gen-aliases: --check is 0 on a freshly generated tree"
  else
    fail "gen-aliases: --check reported drift on its own output"
  fi

  # The RENDERED BYTES, one row per extraction rule: a guarded alias with its Requires
  # cell, a same-line-guarded one, a `hash -d`, the backslash-continued _core_help call,
  # a trailing-comment Note, and the `|` escape GFM needs inside a table cell.
  _ga_row() { grep -qF -- "$1" "$GAR/aliases.md"; }
  if _ga_row '| `ls` | `eza --group-directories-first --icons=auto` | eza |'; then
    pass "gen-aliases: renders a HAVE_*-guarded alias with its Requires cell"
  else
    fail "gen-aliases: the guarded ls row is missing or its Requires cell is wrong"
  fi
  if _ga_row '| `du` | `dust` | dust |'; then
    pass "gen-aliases: a same-line \`[[ -n \${HAVE_X} ]] && alias\` guard is attributed"
  else
    fail "gen-aliases: the same-line-guarded du row lost its Requires cell"
  fi
  if _ga_row '| `~dots` | `$HOME/.config` |'; then
    pass "gen-aliases: renders hash -d named directories"
  else
    fail "gen-aliases: the ~dots named-directory row is missing"
  fi
  if _ga_row '| `core-whatsnew [--full] [--all]` | release notes since you last looked'; then
    pass "gen-aliases: joins a backslash-continued _core_help call"
  else
    fail "gen-aliases: the two-line core-whatsnew _core_help call did not render as one row"
  fi
  if _ga_row '| `-` | `cd -` | previous directory |'; then
    pass "gen-aliases: the alias line's trailing comment is its Note cell"
  else
    fail "gen-aliases: the \`alias -- -\` row lost its name or its Note"
  fi
  if _ga_row '| `ports` | `ss -tulpn 2>/dev/null \|\| netstat -tulpn` |'; then
    pass "gen-aliases: escapes | inside a cell as \\| (and exactly one backslash)"
  else
    fail "gen-aliases: the ports row's || is not escaped as \\|\\| — the table would break"
  fi
  # A multi-line _core_help (the `core maint` sub-verb listing, #684) is not a one-liner:
  # --list shows it as fn-multi, and nothing requires it to be claimed or renders it.
  _ga_list_out="$(_ga_out --list)"
  if grep -q '^fn-multi'"$(printf '\t')"'core'"$(printf '\t')" <<<"$_ga_list_out" &&
    ! grep -q 'core maint <' "$GAR/aliases.md"; then
    pass "gen-aliases: a multi-line _core_help is listed as fn-multi and never rendered as a row"
  else
    fail "gen-aliases: the core maint sub-verb help was rendered as a row, or is missing from --list"
  fi
  # A fallback definition (the `else` arm) must not displace the guarded row.
  if _ga_row '| `df` | `duf` | duf |' && ! _ga_row '`df -h`'; then
    pass "gen-aliases: the guarded definition wins over its else-arm fallback"
  else
    fail "gen-aliases: the df row shows the fallback (df -h) instead of the guarded duf"
  fi

  # NEGATIVE — drift INSIDE a block exits 1 and names the file.
  _ga_fixture && _ga_run >/dev/null
  sed -i.bak 's/| `gst` | `git status` |/| `gst` | `git stat` |/' "$GAR/aliases.md" && rm -f "$GAR/aliases.md.bak"
  _ga_drift_rc="$(_ga_run --check)"
  if [[ "$_ga_drift_rc" == 1 ]]; then
    pass "gen-aliases: --check exits 1 on drift inside a block"
  else
    fail "gen-aliases: --check did not report drift as 1 (rc=$_ga_drift_rc)"
  fi
  _ga_drift_out="$(_ga_out --check)"
  if grep -q 'aliases.md' <<<"$_ga_drift_out" && grep -q 'make gen-aliases' <<<"$_ga_drift_out"; then
    pass "gen-aliases: the drift report names the file and the fix"
  else
    fail "gen-aliases: drift reported without naming aliases.md / make gen-aliases"
  fi
  # ...and --check MUST NOT WRITE.
  _ga_before="$(git hash-object "$GAR/aliases.md")"
  _ga_run --check >/dev/null
  if [[ "$(git hash-object "$GAR/aliases.md")" == "$_ga_before" ]]; then
    pass "gen-aliases: --check writes nothing, even to a drifted file"
  else
    fail "gen-aliases: --check REPAIRED a drifted file — the gate can never be red"
  fi

  # Source-side drift: the alias VALUE changes, the doc does not → 1, not 2.
  _ga_fixture && _ga_run >/dev/null
  sed -i.bak "s/^alias gst='git status'$/alias gst='git status --short'/" "$GAR/zsh/25-git.zsh" && rm -f "$GAR/zsh/25-git.zsh.bak"
  if [[ "$(_ga_run --check)" == 1 ]]; then
    pass "gen-aliases: a source edit without regeneration is drift (1)"
  else
    fail "gen-aliases: an alias value change in the source was not reported as drift"
  fi

  # NEGATIVE, INVERSE — an edit OUTSIDE the markers is not drift and survives regeneration.
  _ga_fixture && _ga_run >/dev/null
  printf 'a hand-authored line added after generation\n' >>"$GAR/aliases.md"
  if [[ "$(_ga_run --check)" == 0 ]]; then
    pass "gen-aliases: an edit OUTSIDE a block is not drift"
  else
    fail "gen-aliases: --check fired on a hand-authored line outside the markers"
  fi
  _ga_run >/dev/null
  if grep -q 'a hand-authored line added after generation' "$GAR/aliases.md" &&
    grep -q 'hand-authored above the first block' "$GAR/aliases.md"; then
    pass "gen-aliases: regeneration preserves hand-authored content outside blocks"
  else
    fail "gen-aliases: regeneration ate a hand-authored line"
  fi

  # THE ISSUE'S OWN VERIFICATION (#685): add an alias to the source, regenerate nothing.
  # It must fail — and as 2 (unclaimed name), naming the alias, not as drift.
  _ga_fixture && _ga_run >/dev/null
  printf "alias zz='ls'\n" >>"$GAR/zsh/20-aliases.zsh"
  _ga_new_rc="$(_ga_run --check)"
  _ga_new_out="$(_ga_out --check)"
  if [[ "$_ga_new_rc" == 2 ]] && grep -q 'alias zz is defined in the sources but no block' <<<"$_ga_new_out"; then
    pass "gen-aliases: an alias no table lists fails --check with 2 and is named"
  else
    fail "gen-aliases: an unlisted new alias did not fail as an unclaimed name (rc=$_ga_new_rc)"
  fi
  # ...and the bare run refuses too: nothing is written until the registry claims it.
  _ga_before="$(git hash-object "$GAR/aliases.md")"
  if [[ "$(_ga_run)" == 2 && "$(git hash-object "$GAR/aliases.md")" == "$_ga_before" ]]; then
    pass "gen-aliases: the bare run refuses (2) and writes nothing while a name is unclaimed"
  else
    fail "gen-aliases: the bare run generated past an unclaimed alias"
  fi
  # The other direction: a listed name nothing defines.
  _ga_fixture && _ga_run >/dev/null
  sed -i.bak "/^alias gap='git add --patch'$/d" "$GAR/zsh/25-git.zsh" && rm -f "$GAR/zsh/25-git.zsh.bak"
  _ga_gone_out="$(_ga_out --check)"
  if [[ "$(_ga_run --check)" == 2 ]] && grep -q 'alias gap is listed in BLOCKS but no source defines it' <<<"$_ga_gone_out"; then
    pass "gen-aliases: a listed name with no definition fails --check with 2 and is named"
  else
    fail "gen-aliases: deleting a listed alias from the source was not caught as a registry mismatch"
  fi

  # Markers are the mechanism: a missing end marker, a missing block, an unregistered one.
  _ga_fixture && _ga_run >/dev/null
  sed -i.bak '/^<!-- core:aliases:end git-stash -->$/d' "$GAR/aliases.md" && rm -f "$GAR/aliases.md.bak"
  if [[ "$(_ga_run --check)" == 2 ]]; then
    pass "gen-aliases: a deleted end marker is a structural failure (2), not drift"
  else
    fail "gen-aliases: an unterminated block was not reported as 2"
  fi
  _ga_fixture && _ga_run >/dev/null
  # Two -e expressions, not \(gen\|end\): BSD sed (the macOS leg) has no \| alternation, and
  # a delete that silently matches nothing turns this row green on the wrong answer.
  sed -i.bak -e '/core:aliases:gen git-stash/d' -e '/core:aliases:end git-stash/d' "$GAR/aliases.md" && rm -f "$GAR/aliases.md.bak"
  _ga_miss_out="$(_ga_out --check)"
  if [[ "$(_ga_run --check)" == 2 ]] && grep -q 'registered block is missing: git-stash' <<<"$_ga_miss_out"; then
    pass "gen-aliases: a registered block whose region was deleted is caught by name"
  else
    fail "gen-aliases: deleting a block's marker pair went unreported — coverage loss reading as health"
  fi
  # A STRAY END MARKER: build_file only pairs an end with the gen above it, so without
  # the preflight counting both kinds this passed through as prose and --check stayed 0.
  _ga_fixture && _ga_run >/dev/null
  printf '<!-- core:aliases:end modern-cli -->\n' >>"$GAR/aliases.md"
  _ga_stray_out="$(_ga_out --check)"
  if [[ "$(_ga_run --check)" == 2 ]] && grep -q 'modern-cli has 1 gen marker(s) but 2 end marker(s)' <<<"$_ga_stray_out"; then
    pass "gen-aliases: a stray duplicate end marker is a structural failure (2), named"
  else
    fail "gen-aliases: a duplicated end marker was accepted as prose"
  fi
  # …and with TABS between the marker's fields: marker_id accepts any single whitespace
  # character, so the counts must too, or a tab-separated duplicate is walked but never
  # counted and survives as prose.
  _ga_fixture && _ga_run >/dev/null
  printf '<!--\tcore:aliases:end\tmodern-cli\t-->\n' >>"$GAR/aliases.md"
  _ga_stray_out="$(_ga_out --check)"
  if [[ "$(_ga_run --check)" == 2 ]] && grep -q 'modern-cli has 1 gen marker(s) but 2 end marker(s)' <<<"$_ga_stray_out"; then
    pass "gen-aliases: a tab-separated duplicate end marker is counted by the same grammar the walker uses"
  else
    fail "gen-aliases: a tab-separated duplicate end marker slipped past the marker counts"
  fi
  _ga_fixture && _ga_run >/dev/null
  printf '<!-- core:aliases:end nope -->\n' >>"$GAR/aliases.md"
  _ga_stray_out="$(_ga_out --check)"
  if [[ "$(_ga_run --check)" == 2 ]] && grep -q 'unregistered end marker: nope' <<<"$_ga_stray_out"; then
    pass "gen-aliases: an unregistered end marker is caught by name"
  else
    fail "gen-aliases: an unregistered end marker was accepted as prose"
  fi
  # CROSSED PAIRS: gen A, gen B, end A, end B has exactly one marker of each kind per
  # block, so the counts pass; only the walker can see that B opens inside A.
  _ga_fixture && _ga_run >/dev/null
  sed -i.bak -e '/core:aliases:gen git-stash/d' -e '/core:aliases:end git-stash/d' \
    -e '/core:aliases:gen git-rebase/d' -e '/core:aliases:end git-rebase/d' "$GAR/aliases.md" && rm -f "$GAR/aliases.md.bak"
  printf '<!-- core:aliases:gen git-stash -->\n<!-- core:aliases:gen git-rebase -->\n<!-- core:aliases:end git-stash -->\n<!-- core:aliases:end git-rebase -->\n' >>"$GAR/aliases.md"
  _ga_cross_out="$(_ga_out --check)"
  _ga_before="$(git hash-object "$GAR/aliases.md")"
  if [[ "$(_ga_run --check)" == 2 && "$(_ga_run)" == 2 ]] && grep -q "opens inside the 'git-stash' region" <<<"$_ga_cross_out" &&
    [[ "$(git hash-object "$GAR/aliases.md")" == "$_ga_before" ]]; then
    pass "gen-aliases: crossed marker pairs are a structural failure (2) in both modes, and nothing is written"
  else
    fail "gen-aliases: crossed marker pairs were accepted — a block would be swallowed silently"
  fi
  _ga_fixture && _ga_run >/dev/null
  printf '<!-- core:aliases:gen nope -->\n<!-- core:aliases:end nope -->\n' >>"$GAR/aliases.md"
  _ga_unreg_out="$(_ga_out --check)" # captured, not piped into grep -q (the §5d SIGPIPE hazard)
  if [[ "$(_ga_run --check)" == 2 ]] && grep -q 'unregistered gen marker: nope' <<<"$_ga_unreg_out"; then
    pass "gen-aliases: an unregistered marker in aliases.md is caught by name"
  else
    fail "gen-aliases: an unregistered marker pair was accepted"
  fi

  # IDEMPOTENCE. A generator that reorders rows makes --check permanently red.
  _ga_fixture && _ga_run >/dev/null
  cp "$GAR/aliases.md" "$GAR/aliases.first.md"
  _ga_run >/dev/null
  if core_files_identical "$GAR/aliases.first.md" "$GAR/aliases.md"; then
    pass "gen-aliases: generation is idempotent (second run is byte-identical)"
  else
    fail "gen-aliases: a second run changed aliases.md — --check can never be stably green"
  fi

  # FAIL CLOSED: a missing source is "cannot run" (2), never drift (1) and never clean.
  _ga_fixture && _ga_run >/dev/null
  rm -f "$GAR/zsh/25-git.zsh"
  _ga_nosrc_rc="$(_ga_run --check)"
  if [[ "$_ga_nosrc_rc" == 2 ]]; then
    pass "gen-aliases: a missing source file fails closed with 2"
  else
    fail "gen-aliases: a missing source file exited $_ga_nosrc_rc — the gate did not fail closed"
  fi

  rm -rf "$GAR"
  unset GAR _ga_ids _ga_gen_rc _ga_drift_rc _ga_drift_out _ga_before _ga_new_rc _ga_new_out _ga_gone_out _ga_miss_out _ga_unreg_out _ga_stray_out _ga_cross_out _ga_list_out _ga_nosrc_rc
fi
