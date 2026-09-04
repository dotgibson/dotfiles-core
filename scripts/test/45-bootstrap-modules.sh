# scripts/test/45-bootstrap-modules.sh
# module selection, v4 layout migration, managed .zshrc entry, shipped systemd unit
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── module selection (lib/bootstrap-lib.sh blib_select / blib_want) ────────────
# Track B's --only/--skip gate. blib_select VALIDATES a comma-separated selector and
# records BLIB_ONLY/BLIB_SKIP; blib_want is the allowlist/skiplist predicate the link
# helpers consult; blib_selected_note is the summary suffix. Pure bash (no git/zsh),
# so it runs everywhere: assert the regex rejects empty/leading/trailing/doubled
# commas + non-letters + spaces + unknown groups, accepts + normalises a clean
# selector, and that blib_want honours only-wins-over-skip precedence.
hdr "module selection (blib_select / blib_want)"
# shellcheck source=lib/bootstrap-lib.sh
source "$HERE/lib/bootstrap-lib.sh"

# Drift guard: the cases below hardcode the six groups as an independent oracle (so a
# corrupted BLIB_MODULES can't make them pass vacuously). Pin the production list to that
# oracle HERE so adding/renaming a group trips one obvious assertion instead of silently
# skewing every _want_set expectation.
if [[ "$BLIB_MODULES" == "zsh nvim tmux git prompt tools" ]]; then pass "BLIB_MODULES matches the tested group set"; else fail "BLIB_MODULES drifted from the tested oracle (got '$BLIB_MODULES') — update this fragment's oracle"; fi

# blib_select aborts (exit 1) on bad input — drive it in a subshell and read the rc.
_sel_rc() { ( blib_select "$1" "$2" ) >/dev/null 2>&1; }
for _bad in 'zsh,,nvim' 'zsh,' ',zsh' '' '*' 'a b' 'bogus' 'zsh nvim'; do
  if _sel_rc --only "$_bad"; then fail "blib_select accepted a bad selector: '$_bad'"; else pass "blib_select rejects '$_bad'"; fi
done

# an unknown flag (not --only/--skip) must fail fast, not silently no-op the selection.
if _sel_rc --bogus 'zsh'; then fail "blib_select accepted an unknown flag"; else pass "blib_select rejects an unknown flag"; fi

# a clean selector is accepted and normalised to space-separated (subshell: blib_select
# would mutate the suite's own BLIB_ONLY otherwise).
_only_norm="$( blib_select --only 'zsh,nvim'; printf '%s' "$BLIB_ONLY" )"
if [[ "$_only_norm" == "zsh nvim" ]]; then pass "blib_select accepts zsh,nvim → 'zsh nvim'"; else fail "blib_select did not normalise zsh,nvim (got '$_only_norm')"; fi

# blib_want over the six groups under each mode. Dynamic scope: the `local` BLIB_ONLY/
# BLIB_SKIP here is exactly what blib_want reads.
_want_set() {
  local BLIB_ONLY="$1" BLIB_SKIP="$2" g w=""
  for g in zsh nvim tmux git prompt tools; do
    if blib_want "$g"; then w+="$g "; fi
  done
  printf '%s' "${w% }"
}
if [[ "$(_want_set '' '')" == "zsh nvim tmux git prompt tools" ]]; then pass "blib_want: default wires every group"; else fail "blib_want: default did not wire all groups"; fi
if [[ "$(_want_set 'zsh nvim' '')" == "zsh nvim" ]]; then pass "blib_want: --only is an allowlist"; else fail "blib_want: --only allowlist wrong"; fi
if [[ "$(_want_set '' 'tmux')" == "zsh nvim git prompt tools" ]]; then pass "blib_want: --skip drops the named group"; else fail "blib_want: --skip wrong"; fi
if [[ "$(_want_set 'zsh' 'zsh')" == "zsh" ]]; then pass "blib_want: --only wins over --skip"; else fail "blib_want: precedence wrong (only should win)"; fi

# blib_selected_note — empty when unfiltered, reflects the active selection otherwise.
if [[ -z "$( blib_selected_note )" ]]; then pass "blib_selected_note: empty when nothing is filtered"; else fail "blib_selected_note: not empty by default"; fi
if [[ "$( blib_select --only zsh,nvim; blib_selected_note )" == " (only: zsh nvim)" ]]; then pass "blib_selected_note: shows the --only suffix"; else fail "blib_selected_note: --only suffix wrong"; fi
if [[ "$( blib_select --skip tmux; blib_selected_note )" == " (skipped: tmux)" ]]; then pass "blib_selected_note: shows the --skip suffix"; else fail "blib_selected_note: --skip suffix wrong"; fi
# precedence: when both are set --only wins in blib_want, so the note must report ONLY the
# only-mode (showing a skipped suffix that's actually ignored would be misleading).
if [[ "$( blib_select --only zsh; blib_select --skip nvim; blib_selected_note )" == " (only: zsh)" ]]; then pass "blib_selected_note: --only wins, --skip not shown"; else fail "blib_selected_note: should report only-mode when both set"; fi

# ── v4 layout migration (lib/bootstrap-lib.sh blib_migrate_v4) ────────────────
# The destructive pre-v4 → v4 migration: relocate history to $XDG_STATE_HOME, rename a
# host local.zsh → 99-local.zsh, and drop the stale unnumbered Core symlinks + compdump.
# Hermetic (temp dirs, no network). Covers relocation, cleanup, second-run idempotence,
# and dry-run (must change NOTHING) — so a re-bootstrap cannot silently lose host state.
hdr "v4 layout migration (blib_migrate_v4)"
# fixture: a realistic pre-v4 ~/.config/zsh under a throwaway root. Prints the root.
_mkv4_fixture() {
  local root zdir
  root="$(mktemp -d "$SANDBOX/v4mig.XXXXXX")"
  zdir="$root/.config/zsh"
  mkdir -p "$zdir"
  printf 'old history\n' >"$zdir/.zsh_history"
  printf 'export FOO=bar\n' >"$zdir/local.zsh"
  ln -s /nonexistent/core/zsh/tools.zsh "$zdir/tools.zsh" # stale unnumbered Core symlink
  : >"$zdir/tools.zsh.zwc"
  : >"$zdir/.zcompdump"
  mkdir -p "$zdir/plugins/zsh-defer"                      # pre-v4 plugin checkout
  : >"$zdir/plugins/zsh-defer/zsh-defer.plugin.zsh"
  printf '%s' "$root"
}
# run migrate in a SUBSHELL so BLIB_DRY / XDG_* don't leak into the suite shell (a
# var-prefixed function call would persist in bash). XDG_DATA_HOME is derived from the
# state path's sibling so the plugins move stays inside the throwaway root (never the real
# HOME). Filesystem effects still persist.
_run_migrate() { ( export XDG_STATE_HOME="$2" XDG_DATA_HOME="${2%/state}/share"; BLIB_DRY="$1"; blib_migrate_v4 "$3" ) >/dev/null 2>&1; }

# 1) real run relocates + cleans up.
_v4root="$(_mkv4_fixture)"; _zd="$_v4root/.config/zsh"
_run_migrate 0 "$_v4root/.local/state" "$_v4root/.config"
if [[ -f "$_v4root/.local/state/zsh/history" ]] && grep -q 'old history' "$_v4root/.local/state/zsh/history" && [[ ! -e "$_zd/.zsh_history" ]]; then
  pass "migrate: history relocated to \$XDG_STATE_HOME"; else fail "migrate: history not relocated"; fi
if [[ -f "$_zd/99-local.zsh" ]] && grep -q 'FOO=bar' "$_zd/99-local.zsh" && [[ ! -e "$_zd/local.zsh" ]]; then
  pass "migrate: local.zsh → 99-local.zsh (contents preserved)"; else fail "migrate: local.zsh not renamed"; fi
if [[ ! -e "$_zd/tools.zsh" && ! -e "$_zd/tools.zsh.zwc" ]]; then
  pass "migrate: stale unnumbered symlink + .zwc removed"; else fail "migrate: stale symlink/.zwc lingered"; fi
if [[ ! -e "$_zd/.zcompdump" ]]; then pass "migrate: stale pre-v4 compdump removed"; else fail "migrate: compdump lingered"; fi
if [[ -f "$_v4root/.local/share/zsh/plugins/zsh-defer/zsh-defer.plugin.zsh" && ! -e "$_zd/plugins" ]]; then
  pass "migrate: plugins dir relocated to \$XDG_DATA_HOME"; else fail "migrate: plugins not relocated"; fi

# 2) idempotence: a second run changes nothing and returns 0.
_run_migrate 0 "$_v4root/.local/state" "$_v4root/.config"; _mig_rc=$?
if [[ $_mig_rc -eq 0 && -f "$_zd/99-local.zsh" && ! -e "$_zd/.zsh_history" ]]; then
  pass "migrate: second run is an idempotent no-op"; else fail "migrate: not idempotent (rc=$_mig_rc)"; fi

# 3) dry-run (BLIB_DRY=1) mutates NOTHING — fresh fixture, every pre-v4 file untouched.
_v4dry="$(_mkv4_fixture)"; _dzd="$_v4dry/.config/zsh"
_run_migrate 1 "$_v4dry/.local/state" "$_v4dry/.config"
if [[ -f "$_dzd/.zsh_history" && -e "$_dzd/local.zsh" && ! -e "$_dzd/99-local.zsh" && -L "$_dzd/tools.zsh" && -d "$_dzd/plugins" && ! -e "$_v4dry/.local/state/zsh/history" && ! -e "$_v4dry/.local/share/zsh/plugins" ]]; then
  pass "migrate: dry-run (BLIB_DRY=1) changes nothing"; else fail "migrate: dry-run mutated the fixture"; fi

# 4) partial-migration CONFLICT: when the v4 destinations already exist, migrate must WARN
# and leave the pre-v4 files in place — never clobber the new file, never silently drop the
# old one (a re-bootstrap must not lose host state). rc stays 0 (a warning is not a failure).
_v4cf="$(mktemp -d "$SANDBOX/v4cf.XXXXXX")"
_cfzd="$_v4cf/.config/zsh"
mkdir -p "$_cfzd" "$_v4cf/.local/state/zsh"
printf 'old\n' >"$_cfzd/.zsh_history"
printf 'new\n' >"$_v4cf/.local/state/zsh/history"
printf 'old\n' >"$_cfzd/local.zsh"
printf 'new\n' >"$_cfzd/99-local.zsh"
mkdir -p "$_cfzd/plugins/old-plugin" "$_v4cf/.local/share/zsh/plugins/new-plugin"
_run_migrate 0 "$_v4cf/.local/state" "$_v4cf/.config"
_cf_rc=$?
if [[ $_cf_rc -eq 0 && -f "$_cfzd/.zsh_history" && "$(cat "$_v4cf/.local/state/zsh/history")" == new && -e "$_cfzd/local.zsh" && "$(cat "$_cfzd/99-local.zsh")" == new && -d "$_cfzd/plugins/old-plugin" && -d "$_v4cf/.local/share/zsh/plugins/new-plugin" ]]; then
  pass "migrate: conflicting destinations preserved (no clobber, no silent drop)"; else fail "migrate: conflict handling wrong (rc=$_cf_rc)"; fi

# ── managed .zshrc entry (lib/bootstrap-lib.sh blib_write_zshrc_loader) ───────
# The written ~/.zshrc EXPORTS ZDOTDIR, so the entry file must ALSO exist at
# $ZDOTDIR/.zshrc — otherwise every zsh started from inside the first one inherits the
# export, finds no startup file there, and runs zsh-newuser-install with no Core loaded.
# `exec zsh` is the documented first step after a bootstrap, so this is the fresh-box
# path, not an edge case. Pure bash (no zsh needed) so it runs everywhere, like G and H.
hdr "managed .zshrc entry (blib_write_zshrc_loader)"

# Drive the writer against a throwaway HOME in a SUBSHELL so HOME/XDG_*/BLIB_* never leak
# into the suite shell. BLIB_ONLY/BLIB_SKIP are reset because the module-selection arm
# above leaves them set,
# and blib_want gates this function on the zsh group.
#
# ZDOTDIR MUST be unset: the managed shell EXPORTS it, so running this suite from a
# configured machine would otherwise make the writer resolve $ZDOTDIR to the developer's
# REAL ~/.config/zsh and replace their .zshrc with a link into a sandbox that is deleted
# on exit. Unsetting it is what keeps the fixture hermetic — and honest, since the fresh
# box this models has no ZDOTDIR in the environment either.
#
# SC2030/SC2031: the subshell-local HOME/XDG_CONFIG_HOME is the POINT — the writer targets
# $HOME, and leaking a throwaway HOME into the suite shell would send later sections at the
# real one. Confining it to the subshell is the isolation, not a lost assignment.
# shellcheck disable=SC2030,SC2031
_run_zrc() { ( unset ZDOTDIR; export HOME="$1" XDG_CONFIG_HOME="$1/.config"; BLIB_DRY="${2:-0}"; BLIB_ONLY=""; BLIB_SKIP=""; blib_write_zshrc_loader ) >/dev/null 2>&1; }
# Same, but capturing stdout so the dry-run PLAN can be asserted.
# shellcheck disable=SC2030,SC2031
_run_zrc_out() { ( unset ZDOTDIR; export HOME="$1" XDG_CONFIG_HOME="$1/.config"; BLIB_DRY="${2:-0}"; BLIB_ONLY=""; BLIB_SKIP=""; blib_write_zshrc_loader ) 2>&1; }

# 1) fresh box: both entry points exist, and the ZDOTDIR one resolves to ~/.zshrc.
_zr="$(mktemp -d "$SANDBOX/zrc.XXXXXX")"
_run_zrc "$_zr"
if [[ -f "$_zr/.zshrc" ]] && grep -q 'dotfiles-managed v4' "$_zr/.zshrc"; then
  pass "zshrc: managed ~/.zshrc written"; else fail "zshrc: managed ~/.zshrc not written"; fi
if [[ -L "$_zr/.config/zsh/.zshrc" && "$(readlink "$_zr/.config/zsh/.zshrc")" == "$_zr/.zshrc" ]]; then
  pass "zshrc: \$ZDOTDIR/.zshrc seeded → ~/.zshrc"; else fail "zshrc: \$ZDOTDIR/.zshrc missing — a re-exec'd zsh would hit zsh-newuser-install"; fi

# 2) the file zsh actually looks for is present, so the newuser wizard cannot trigger.
#    (zsh runs it only when NONE of these exist in $ZDOTDIR.)
_zr_found=0
for _f in .zshenv .zprofile .zshrc .zlogin; do [[ -e "$_zr/.config/zsh/$_f" ]] && _zr_found=1; done
if ((_zr_found)); then pass "zshrc: \$ZDOTDIR has a startup file (no newuser wizard)"; else fail "zshrc: \$ZDOTDIR has none of .zshenv/.zprofile/.zshrc/.zlogin"; fi

# 3) REGRESSION: a box bootstrapped BEFORE the seeding existed already has a managed
#    ~/.zshrc, so the writer takes its idempotent early return. It must still reconcile
#    the missing $ZDOTDIR entry rather than skipping straight past it.
_zold="$(mktemp -d "$SANDBOX/zold.XXXXXX")"
mkdir -p "$_zold/.config/zsh"
printf '# dotfiles-managed v4 — pre-existing\n' >"$_zold/.zshrc"
_run_zrc "$_zold"
if [[ -L "$_zold/.config/zsh/.zshrc" ]]; then
  pass "zshrc: pre-existing v4 rc still gets \$ZDOTDIR seeded"; else fail "zshrc: early return skipped \$ZDOTDIR seeding on an already-managed box"; fi
if grep -q 'pre-existing' "$_zold/.zshrc"; then
  pass "zshrc: pre-existing v4 rc left untouched"; else fail "zshrc: clobbered an already-managed ~/.zshrc"; fi

# 4) idempotence: a second run changes nothing and leaves the link correct.
_run_zrc "$_zr"
if [[ -L "$_zr/.config/zsh/.zshrc" && "$(readlink "$_zr/.config/zsh/.zshrc")" == "$_zr/.zshrc" ]] && ! compgen -G "$_zr/.config/zsh/.zshrc.pre-dotfiles.*" >/dev/null; then
  pass "zshrc: second run is an idempotent no-op (no backup churn)"; else fail "zshrc: not idempotent"; fi

# 5) dry-run mutates NOTHING…
_zdry="$(mktemp -d "$SANDBOX/zdry.XXXXXX")"
_zdry_out="$(_run_zrc_out "$_zdry" 1)"
if [[ ! -e "$_zdry/.zshrc" && ! -e "$_zdry/.config/zsh/.zshrc" ]]; then
  pass "zshrc: BLIB_DRY=1 writes nothing"; else fail "zshrc: dry run mutated the tree"; fi
# …and PREVIEWS the whole plan. BLIB_DRY's contract is the full set of actions, so the
# seeded $ZDOTDIR entry — a second file the real run creates — has to appear too, or a
# --dry-run reader is told less than will happen.
if [[ "$_zdry_out" == *".zshrc"* && "$_zdry_out" == *"$_zdry/.config/zsh"* ]]; then
  pass "zshrc: BLIB_DRY=1 previews the \$ZDOTDIR seeding too"; else fail "zshrc: dry-run plan omits the \$ZDOTDIR seeding (got: $_zdry_out)"; fi

# 6) INVERTED LAYOUT: ~/.zshrc is itself a symlink TO $ZDOTDIR/.zshrc. The two path
#    strings differ but resolve to one file — linking would move the real file aside and
#    leave the symlinks pointing at each other (ELOOP, every shell broken). Must no-op.
_zinv="$(mktemp -d "$SANDBOX/zinv.XXXXXX")"
mkdir -p "$_zinv/.config/zsh"
printf '# dotfiles-managed v4 — real file lives in ZDOTDIR\n' >"$_zinv/.config/zsh/.zshrc"
ln -s "$_zinv/.config/zsh/.zshrc" "$_zinv/.zshrc"
_run_zrc "$_zinv"
if [[ -f "$_zinv/.config/zsh/.zshrc" ]] && grep -q 'real file lives in ZDOTDIR' "$_zinv/.config/zsh/.zshrc" \
   && [[ "$(readlink "$_zinv/.zshrc")" == "$_zinv/.config/zsh/.zshrc" ]] \
   && ! compgen -G "$_zinv/.config/zsh/.zshrc.pre-dotfiles.*" >/dev/null; then
  pass "zshrc: inverted layout (~/.zshrc → \$ZDOTDIR/.zshrc) left intact — no symlink cycle"; else fail "zshrc: inverted layout clobbered or cycled"; fi
# and prove it: a real zsh must still start from it rather than dying on ELOOP.
if have zsh && zsh -f -c "ZDOTDIR='$_zinv/.config/zsh'; source \"\$ZDOTDIR/.zshrc\"" 2>/dev/null; then
  pass "zshrc: inverted layout still sources (no ELOOP)"; else
  if have zsh; then fail "zshrc: inverted layout no longer sources"; else skip "zshrc: ELOOP check (zsh absent)"; fi
fi

# 7) ZDOTDIR already pointing at $HOME — ~/.zshrc IS the entry, so nothing to seed and
#    certainly no self-referential link.
_zh="$(mktemp -d "$SANDBOX/zh.XXXXXX")"
# shellcheck disable=SC2030,SC2031  # subshell-local by design — see _run_zrc above
( export HOME="$_zh" XDG_CONFIG_HOME="$_zh/.config" ZDOTDIR="$_zh"; BLIB_DRY=0; BLIB_ONLY=""; BLIB_SKIP=""; blib_write_zshrc_loader ) >/dev/null 2>&1
if [[ -f "$_zh/.zshrc" && ! -L "$_zh/.zshrc" ]]; then
  pass "zshrc: ZDOTDIR=\$HOME leaves ~/.zshrc a real file (no self-link)"; else fail "zshrc: ZDOTDIR=\$HOME produced a self-referential link"; fi

# ── shipped example systemd unit (examples/atuin-daemon.service) ──────────────
# This file is classified repo-meta by ci-classify (nothing links it, so it cannot break a
# shell) and was consequently never validated at all. It still ships onto real machines by
# copy-paste, and its failure mode is quiet: with the daemon enabled and unreachable, atuin
# exits 0 and DISCARDS the entry, so a unit whose ExecStart the binary rejects becomes a
# 3s restart loop while shells silently record nothing. Cheap assertions, pure bash.
hdr "example systemd unit (examples/atuin-daemon.service)"
_UNIT="$HERE/examples/atuin-daemon.service"
if [[ ! -f "$_UNIT" ]]; then
  skip "atuin unit (examples/atuin-daemon.service absent)"
else
  _ux="$(grep -E '^ExecStart=' "$_UNIT" || true)"
  # RUN the ExecStart payload against stub atuins rather than pattern-matching it. String
  # assertions are too weak here: "contains daemon start" is satisfied by the PROBE alone,
  # so a unit that probes correctly and then execs the bare form in BOTH branches would
  # pass while being exactly the bug this fixes. Executing it pins the actual choice.
  _uxcmd="$(sed -n "s|^ExecStart=/bin/sh -c '\(.*\)'\$|\1|p" "$_UNIT")"
  if [[ -z "$_uxcmd" ]]; then
    fail "atuin unit: could not extract the sh -c payload from ExecStart (format changed?)"
  else
    _ustub="$(mktemp -d "$SANDBOX/unitstub.XXXXXX")"
    mkdir -p "$_ustub/new" "$_ustub/old"
    # NEW atuin: `daemon start` exists, so the probe succeeds and start must be chosen.
    printf '%s\n' '#!/bin/sh' \
      '[ "$1" = daemon ] && [ "$2" = start ] && [ "$3" = --help ] && exit 0' \
      '[ "$1" = daemon ] && [ "$2" = start ] && { echo START >"$UNIT_MARK"; exit 0; }' \
      '[ "$1" = daemon ] && [ -z "$2" ] && { echo BARE >"$UNIT_MARK"; exit 0; }' \
      'exit 2' >"$_ustub/new/atuin"
    # OLD atuin: no `start` subcommand — the probe must fail and the bare form be chosen.
    printf '%s\n' '#!/bin/sh' \
      '[ "$1" = daemon ] && [ "$2" = start ] && exit 2' \
      '[ "$1" = daemon ] && { echo BARE >"$UNIT_MARK"; exit 0; }' \
      'exit 2' >"$_ustub/old/atuin"
    chmod +x "$_ustub/new/atuin" "$_ustub/old/atuin"

    UNIT_MARK="$_ustub/mark.new" PATH="$_ustub/new:$PATH" sh -c "$_uxcmd" >/dev/null 2>&1
    if [[ "$(cat "$_ustub/mark.new" 2>/dev/null)" == START ]]; then
      pass "atuin unit: on an atuin WITH 'daemon start', ExecStart runs the non-deprecated form"; else fail "atuin unit: modern atuin did not get 'daemon start' (got: $(cat "$_ustub/mark.new" 2>/dev/null || echo nothing))"; fi

    UNIT_MARK="$_ustub/mark.old" PATH="$_ustub/old:$PATH" sh -c "$_uxcmd" >/dev/null 2>&1
    if [[ "$(cat "$_ustub/mark.old" 2>/dev/null)" == BARE ]]; then
      pass "atuin unit: on an atuin WITHOUT it, ExecStart falls back to the bare form"; else fail "atuin unit: old atuin got no working fallback (got: $(cat "$_ustub/mark.old" 2>/dev/null || echo nothing))"; fi
  fi
  # `exec A || exec B` LOOKS like a fallback but is not: once exec succeeds the process is
  # replaced, so atuin exiting non-zero can never reach the `||`. Pin that it is not used.
  if [[ "$_ux" != *"|| exec"* ]]; then
    pass "atuin unit: no 'exec … || exec …' pseudo-fallback"; else fail "atuin unit: 'exec … || exec …' cannot fall back — exec replaces the process"; fi
  # Syntax, when the tool is around (Linux CI; absent on macOS runners).
  if have systemd-analyze; then
    if systemd-analyze verify "$_UNIT" >/dev/null 2>&1; then
      pass "atuin unit: systemd-analyze verify clean"; else fail "atuin unit: systemd-analyze verify reported problems"; fi
  else
    skip "atuin unit: systemd-analyze verify (not installed)"
  fi
fi

