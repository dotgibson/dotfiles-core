# scripts/test/26-fleet-gate-delta.sh
# the PR-time fleet-gate delta (scripts/fleet-gate-delta.sh --compare)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# ── fleet-gate delta (#1240) ─────────────────────────────────────────────────
# ci.yml's `fleet-gates` job is a REQUIRED check that audits the PR's base and head against
# the same sibling clones and fails only on a ✗ block the head adds. The --base half needs
# the fleet and two audits, so it is proven by the job itself. What is pinned here is the
# judgement, --compare, because that is the half that decides whether a PR is blocked: a miss
# lets another #1239 through, and a false red blocks every Core PR on a sibling's drift.
hdr "fleet-gate delta (fleet-gate-delta.sh --compare)"
_fgd_="$SANDBOX/fleet-gate-delta"
rm -rf "$_fgd_"
mkdir -p "$_fgd_"
# A realistic --quiet audit tail: tool skips, fail blocks, then the summary whose skip list
# is ALSO four-space indented. That list must never be read as a block's detail.
_fgd_summary=$'\n──────── audit summary ────────\n  7 check(s) SKIPPED — this run is PARTIAL, not full:\n    – luacheck (not installed)\naudit FAILED'
printf "– luacheck (not installed)\n✗ a repo's TOOLS_OPTIN disagrees\n    dotfiles-Debian: declared [a], expected [a b]\n%s\n" "$_fgd_summary" >"$_fgd_/debian.txt"
printf "– luacheck (not installed)\n✗ a repo's TOOLS_OPTIN disagrees\n    dotfiles-Debian: declared [a], expected [a b]\n    dotfiles-Alpine: declared [], expected [c]\n%s\n" "$_fgd_summary" >"$_fgd_/debian-alpine.txt"
printf "– luacheck (not installed)\n– gitleaks (not installed)\n\n──────── audit summary ────────\n  2 check(s) SKIPPED — this run is PARTIAL, not full:\n    – luacheck (not installed)\n    – gitleaks (not installed)\naudit OK — PARTIAL\n" >"$_fgd_/clean.txt"
printf "✗ a repo's TOOLS_OPTIN disagrees\n    dotfiles-Debian: declared [a], expected [a b]\n\n──────── audit summary ────────\n  9 check(s) SKIPPED — this run is PARTIAL, not full:\n    – markdownlint (not installed)\n    – actionlint (not installed)\naudit FAILED\n" >"$_fgd_/debian-otherskips.txt"
printf "– markdownlint (not installed)\n\n──────── audit summary ────────\n  1 check(s) SKIPPED — this run is PARTIAL, not full:\n    – markdownlint (not installed)\naudit OK — PARTIAL\n" >"$_fgd_/clean-otherskips.txt"
printf "✗ theme drift in /w/base/zsh/10-ui.zsh\n%s\n" "$_fgd_summary" >"$_fgd_/path-base.txt"
printf "✗ theme drift in /w/head/zsh/10-ui.zsh\n%s\n" "$_fgd_summary" >"$_fgd_/path-head.txt"

_fgd_is() { # _fgd_is <label> <want-rc> <base> <head> [base-core head-core]
  local rc=0
  "$HERE/scripts/fleet-gate-delta.sh" --compare "$_fgd_/$3" "$_fgd_/$4" ${5:+"$5"} ${6:+"$6"} \
    >"$_fgd_/out" 2>&1 || rc=$?
  if [[ "$rc" == "$2" ]]; then
    pass "fleet-gate delta: $1"
  else
    fail "fleet-gate delta: $1 (exit $rc, want $2)"
    fail_detail "$(cat "$_fgd_/out")"
  fi
}

# THE #1239 SHAPE: the base is clean against the siblings, and the head adds a failure.
_fgd_is "a failure the head adds is a red (the #1239 shape)" 1 clean.txt debian.txt
# ...and the finding must name the block, not just the fact of one.
if grep -q 'dotfiles-Debian: declared' "$_fgd_/out"; then
  pass "fleet-gate delta: the red names the failing block and its detail"
else
  fail "fleet-gate delta: the red did not print the block it judged new"
fi

# THE REASON IT IS A DELTA: a sibling drifted on its own and main already carries the red.
# Blocking an unrelated PR on it would make a required check block every Core PR.
_fgd_is "a failure already on the base does not block the PR" 0 debian.txt debian.txt
_fgd_is "a PR that fixes a base failure is green" 0 debian.txt clean.txt

# STRICT BY BLOCK: widening an existing finding to a second repo is a new failure.
_fgd_is "an existing block that gains a repo is a red" 1 debian.txt debian-alpine.txt

# The two audits run from different checkouts. A path the gate prints must not make a
# finding look new, and without the paths passed it must (proving the normalisation is load-bearing).
_fgd_is "the two checkouts' paths are normalised away" 0 path-base.txt path-head.txt /w/base /w/head
_fgd_is "without normalisation the same finding reads as new" 1 path-base.txt path-head.txt

# The summary's skip list is four-space indented too. It must not glue onto a block, or a
# changed skip list would read as a new failure.
_fgd_is "a clean head with a different skip list is green" 0 clean.txt clean-otherskips.txt
_fgd_is "the same block over a different skip list is not new" 0 debian.txt debian-otherskips.txt

# A usage error is 2, never 0: a mis-invoked required check must not read as a pass.
_fgd_rc=0
"$HERE/scripts/fleet-gate-delta.sh" --compare "$_fgd_/clean.txt" >/dev/null 2>&1 || _fgd_rc=$?
if [[ "$_fgd_rc" == 2 ]]; then
  pass "fleet-gate delta: a mis-invoked --compare exits 2, not green"
else
  fail "fleet-gate delta: a mis-invoked --compare exited $_fgd_rc (want 2)"
fi
unset _fgd_ _fgd_summary _fgd_rc
unset -f _fgd_is
