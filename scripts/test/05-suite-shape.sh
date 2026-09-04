# scripts/test/05-suite-shape.sh
# the suite's own layout contract: every fragment is numbered, sourced, and lintable
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the suite's own layout contract ───────────────────────────────────────────
# The dispatcher globs `scripts/test/[0-9][0-9]-*.sh`. That is the right shape — it has no
# registry to forget — but it buys that at the price of a NEW way to write assertions that
# never run: drop `scripts/test/helpers.sh` in beside the others, and the glob skips it in
# silence while the suite reports a clean run. That failure looks exactly like success,
# which is the class of defect this whole file exists to catch elsewhere. So the layout is
# asserted, not assumed. Pure bash, and numbered 05 so it runs before anything it describes.
hdr "the behavioral suite's own layout (scripts/test/)"

_ss_dir="$HERE/scripts/test"
_ss_all=0 _ss_numbered=0 _ss_stray="" _ss_exec="" _ss_untracked=""
for _ss_f in "$_ss_dir"/*.sh; do
  [[ -e "$_ss_f" ]] || break
  _ss_all=$((_ss_all + 1))
  _ss_b="${_ss_f##*/}"
  case "$_ss_b" in
  [0-9][0-9]-*.sh) _ss_numbered=$((_ss_numbered + 1)) ;;
  *) _ss_stray="${_ss_stray:+$_ss_stray }$_ss_b" ;;
  esac
  # Sourced libraries, so 100644 — audit-core.sh §2 owns the git-index view of this; here we
  # check the working tree, which is what actually gets sourced and what a fresh `chmod +x`
  # would break first.
  [[ -x "$_ss_f" ]] && _ss_exec="${_ss_exec:+$_ss_exec }$_ss_b"
done

if ((_ss_all == 0)); then
  fail "suite layout: no fragments under scripts/test/ — the dispatcher should have refused to run at all"
elif [[ -n "$_ss_stray" ]]; then
  fail "suite layout: not matched by the dispatcher's [0-9][0-9]-*.sh glob, so never sourced: $_ss_stray — rename it with an NN- prefix, or it is dead code that reads as coverage"
else
  pass "suite layout: all $_ss_all fragments carry the NN- prefix the dispatcher globs (none silently unsourced)"
fi

# A floor, not an exact count: the point is that the glob found THE SUITE and not two
# leftovers. An exact number would be a second registry to update on every split.
if ((_ss_numbered >= 20)); then
  pass "suite layout: the glob resolves the whole suite ($_ss_numbered fragments)"
else
  fail "suite layout: only $_ss_numbered fragments matched — the suite is 35-odd files; a glob this short means most of it is not running"
fi

if [[ -z "$_ss_exec" ]]; then
  pass "suite layout: no fragment is executable (they are sourced libraries, like scripts/lib/)"
else
  fail "suite layout: executable fragment(s): $_ss_exec — they are sourced, never run, and +x invites someone to run one standalone and read the empty result as a pass"
fi

# Tracked matters for a reason that is not tidiness, and not the two you might reach for first:
# `_audit_ls` deliberately picks up untracked files, so the linters DO see one; and `scripts/`
# is repo-meta with per-file `core.vendor` granularity, so these fragments ship to no OS repo
# either way. The failure mode is simpler and worse than both — an untracked fragment never
# reaches the remote, so CI and every fresh clone run the suite WITHOUT it. Its assertions
# vanish everywhere except the box that wrote them, and the run still says green.
if have git && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  for _ss_f in "$_ss_dir"/[0-9][0-9]-*.sh; do
    [[ -e "$_ss_f" ]] || break
    git -C "$HERE" ls-files --error-unmatch "${_ss_f#"$HERE/"}" >/dev/null 2>&1 ||
      _ss_untracked="${_ss_untracked:+$_ss_untracked }${_ss_f##*/}"
  done
  if [[ -z "$_ss_untracked" ]]; then
    pass "suite layout: every fragment is tracked (so CI and a fresh clone run the same suite this box does)"
  else
    fail "suite layout: untracked fragment(s): $_ss_untracked — they never reach the remote, so CI and every fresh clone run the suite without them and still report green"
  fi
else
  skip "suite layout: tracked-fragment check (not a git checkout)"
fi

# ── the empty-glob refusal, driven rather than believed ───────────────────────
# The dispatcher exits 2 rather than reporting a clean run over zero fragments. That arm is
# unreachable in normal use, which is exactly why it needs driving: an untested refusal is a
# refusal that quietly became a `continue` at some point. Hermetic — a throwaway tree holding
# the real dispatcher, the real common.sh, and an EMPTY scripts/test/.
# The three files the dispatcher needs before it reaches the glob: itself, common.sh, and
# lib/ux.sh — which common.sh sources as ../../lib/ux.sh for the palette, so the fixture has
# to reproduce that relative shape rather than just drop two files in a directory.
_ss_root="$SANDBOX/empty-suite"
mkdir -p "$_ss_root/scripts/lib" "$_ss_root/scripts/test" "$_ss_root/lib"
cp "$HERE/scripts/test-core.sh" "$_ss_root/scripts/" 2>/dev/null
cp "$HERE/scripts/lib/common.sh" "$_ss_root/scripts/lib/" 2>/dev/null
cp "$HERE/lib/ux.sh" "$_ss_root/lib/" 2>/dev/null
if [[ -r "$_ss_root/scripts/test-core.sh" && -r "$_ss_root/scripts/lib/common.sh" && -r "$_ss_root/lib/ux.sh" ]]; then
  _ss_out="$(env -u CORE_JSON -u CORE_TEST_NESTED bash "$_ss_root/scripts/test-core.sh" --scope none 2>&1)"
  _ss_rc=$?
  if ((_ss_rc == 2)) && [[ "$_ss_out" == *"no fragments matched"* ]]; then
    pass "suite layout: an empty scripts/test/ is exit 2 and says so — never a green run that asserted nothing"
  else
    fail "suite layout: an empty scripts/test/ exited $_ss_rc (want 2) saying '${_ss_out:-<nothing>}' — a suite with no fragments must refuse, not report a clean run"
  fi
else
  skip "suite layout: empty-glob refusal (could not stage the dispatcher)"
fi

unset _ss_dir _ss_all _ss_numbered _ss_stray _ss_exec _ss_untracked _ss_f _ss_b _ss_root _ss_out _ss_rc
