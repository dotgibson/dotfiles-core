# scripts/test/23-audit-shape.sh
# the audit's layout as this suite sees it: the fragment set the static assertions read, and the empty-glob refusal, driven
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# ── the audit's fragments, as the static assertions read them ────────────────
# scripts/audit-core.sh split into scripts/audit/NN-name.sh the way this suite's own
# dispatcher did (#699), so "does the audit's source say X?" — which fifteen static
# assertions across this suite ask — stopped being a question about ONE file. The
# dispatcher assembles $_audit_src (the audit's dispatcher plus every fragment) once, and
# the assertions grep that. A SHORT SET DOES NOT WEAKEN THOSE ASSERTIONS, IT INVERTS HALF
# OF THEM: the positive ones fail loudly when the set is wrong, but the negative ones —
# `_audit_grep -q '_tool_skips=$((_tool_skips'` in 36-bootstrap-lib.sh is the sharpest —
# are must-NOT-match, and a set missing the fragment that holds the forbidden thing passes
# by asserting nothing. So the set is asserted here, first, before anything reads it.
hdr "the audit's layout (scripts/audit/), as this suite reads it"

_as_n=0
for _as_f in "$HERE"/scripts/audit/[0-9][0-9]-*.sh; do
  [[ -e "$_as_f" ]] && _as_n=$((_as_n + 1))
done
# shellcheck disable=SC2154  # cross-fragment: assembled in scripts/test-core.sh
if [[ ! -r "$HERE/scripts/audit-core.sh" ]]; then
  fail "audit layout: scripts/audit-core.sh is unreadable — every static assertion about the audit's source is reading a short list"
elif ((_as_n >= 8)) && ((${#_audit_src[@]} == _as_n + 1)); then
  pass "audit layout: the static assertions read the dispatcher + all $_as_n scripts/audit/ fragments"
else
  fail "audit layout: \$_audit_src holds ${#_audit_src[@]} file(s) against $_as_n fragment(s) on disk (want fragments + 1, and at least 9) — the must-NOT-match assertions in this suite pass vacuously against a set that short"
fi

# _audit_frag must refuse an ambiguous answer: the one caller that derives a LINE RANGE
# (36-bootstrap-lib.sh's --json guard) would otherwise scan whichever file grep listed
# first and call the range meaningful.
if _audit_frag '^# ── 5f\.' >/dev/null && ! _audit_frag '^# ── ' >/dev/null; then
  pass "audit layout: _audit_frag names the one fragment for a unique banner and refuses a pattern that matches several"
else
  fail "audit layout: _audit_frag is not single-valued — a range-based assertion would pick a file arbitrarily"
fi

# ── the empty-glob refusal, driven rather than believed ───────────────────────
# The audit's dispatcher exits 2 rather than reporting `audit OK` over zero fragments —
# the same arm this suite's dispatcher has, driven the same way (05-suite-shape.sh), for
# the same reason: an untested refusal is a refusal that quietly became a `continue` at
# some point. Driven from HERE and not from scripts/audit/05-shape.sh because the audit
# has no sandbox of its own to stage a tree in, and staging one would need a second EXIT
# trap — the one thing an audit fragment must never install.
#
# The fixture: the real dispatcher, the real common.sh, lib/ux.sh (which common.sh sources
# as ../../lib/ux.sh), an EMPTY scripts/audit/, and a two-line test-core.sh stub. The stub
# is belt to CORE_AUDIT_SERIAL=1's braces: serial mode never backgrounds the behavioral
# suite, and exit 2 fires before section 10 would run it inline anyway — but a fixture
# that could fork a real 20-minute suite on a bad day gets both.
_as_root="$SANDBOX/empty-audit"
mkdir -p "$_as_root/scripts/lib" "$_as_root/scripts/audit" "$_as_root/lib"
cp "$HERE/scripts/audit-core.sh" "$_as_root/scripts/" 2>/dev/null
cp "$HERE/scripts/lib/common.sh" "$_as_root/scripts/lib/" 2>/dev/null
cp "$HERE/lib/ux.sh" "$_as_root/lib/" 2>/dev/null
printf '#!/usr/bin/env bash\nexit 0\n' > "$_as_root/scripts/test-core.sh"
chmod +x "$_as_root/scripts/test-core.sh"
if [[ -r "$_as_root/scripts/audit-core.sh" && -r "$_as_root/scripts/lib/common.sh" && -r "$_as_root/lib/ux.sh" ]]; then
  _as_out="$(env -u CORE_JSON -u CORE_TEST_NESTED CORE_AUDIT_SERIAL=1 bash "$_as_root/scripts/audit-core.sh" --quiet 2>&1)"
  _as_rc=$?
  if ((_as_rc == 2)) && [[ "$_as_out" == *"no fragments matched"* ]]; then
    pass "audit layout: an empty scripts/audit/ is exit 2 and says so — never an \`audit OK\` that asserted nothing"
  else
    fail "audit layout: an empty scripts/audit/ exited $_as_rc (want 2) saying '${_as_out:-<nothing>}' — an audit with no fragments must refuse, not report OK"
  fi
else
  skip "audit layout: empty-glob refusal (could not stage the dispatcher)"
fi

unset _as_n _as_f _as_root _as_out _as_rc
