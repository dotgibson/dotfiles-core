# scripts/test/59-fleet-vendor-guidance.sh
# Vendoring-hint register (scripts/fleet-vendor-guidance.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.
#
# Numbered 59 to sit beside its siblings: 56 is the Makefile vocabulary register, 58 the
# release-trigger register, and this is the fourth in that family.

# The fixtures are literal shell and markdown that must reach the fake repo UNEXPANDED —
# backticks included, since one fixture is prose ABOUT `git subtree pull` and the whole
# point of it is that the register reads it as prose. Single quotes are load-bearing here,
# not an oversight; same file-wide false positive the sibling fragments carry.
# shellcheck disable=SC2016

# ── the vendoring-hint register (scripts/fleet-vendor-guidance.sh) ───────────
# Eight of nine repos told a user to vendor core/ from `main` and to update with
# `git subtree pull` — a branch is not the commit the fan-out pins (core-integrity then
# reports the fresh repo as TAMPERED) and subtree pull moves core/ without core.lock.
# dotfiles-MacBook had the right warning the whole time and nothing propagated it; then its
# own hint went stale at refs/tags/v4 against a v7 fleet.
#
# These drive the real script against a fake fleet root and pin the properties that make it
# worth having: each defect class gets its OWN label (a register that says "wrong" without
# saying how is a register nobody acts on), the expected major is DERIVED from core.version
# rather than hardcoded, and the two false-positive classes stay quiet — prose about subtree
# pull, and a legitimate subtree on a prefix that is not core/.
hdr "vendoring-hint register (fleet-vendor-guidance.sh)"
_fvg_root="$SANDBOX/fleet-vendor-guidance"
_fvg_sh="$HERE/scripts/fleet-vendor-guidance.sh"
_fvg_reset() {
  rm -rf "$_fvg_root"
  mkdir -p "$_fvg_root"
}
_fvg_repo() { # _fvg_repo <repo> [bootstrap.sh body] — a fake sibling; no body means no hint
  mkdir -p "$_fvg_root/$1/.git"
  [[ $# -ge 2 ]] && printf '%b' "$2" >"$_fvg_root/$1/bootstrap.sh"
  return 0
}
_fvg_run() { REPOS_ROOT="$_fvg_root" "$_fvg_sh" "$@" 2>&1; }

# An empty fleet root is an ENVIRONMENT notice, not a clean bill of health. This one is
# load-bearing beyond the usual: Core is itself a row in this register (its VENDORING.md
# carries the canonical recipe), so it is always present and a naive count would report
# "every hint is current" off Core's single row while reading no fleet at all — the
# green-because-absent result audit-core.sh's skip_env exists to avoid.
_fvg_reset
if _fvg_out="$(_fvg_run --check)"; then
  if [[ "$_fvg_out" == *"no sibling repo checked out"* ]]; then
    pass "vendor-guidance: an empty fleet root is an environment notice, exit 0"
  else
    fail "vendor-guidance: empty root exited 0 without the no-sibling notice (Core's own row must not count): $_fvg_out"
  fi
else
  fail "vendor-guidance: an empty fleet root exited non-zero: $_fvg_out"
fi

# THE DEFECT ITSELF, in the exact shape seven repos shipped.
_fvg_reset
_fvg_repo dotfiles-Fedora 'echo "  git subtree add  --prefix=core <remote> main --squash"\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" == *'**branch**'* ]]; then
  pass "vendor-guidance: vendoring from a branch reads as branch"
else
  fail "vendor-guidance: a main-vendoring hint was not flagged: $_fvg_out"
fi

# `subtree pull` on core/ is retired outright (#676) — no ref makes it right, so it must be
# decided before the ref is even looked at. The fixture deliberately pairs it with a CURRENT
# tag: a register that only caught `pull` alongside a bad ref would pass the moment someone
# "fixed" the tag and left the verb.
_fvg_reset
_fvg_repo dotfiles-Fedora 'echo "  git subtree pull --prefix=core <remote> refs/tags/v7 --squash"\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" == *'**subtree-pull**'* ]]; then
  pass "vendor-guidance: subtree pull on core/ is flagged even with a current tag"
else
  fail "vendor-guidance: subtree pull with a current tag was not flagged: $_fvg_out"
fi

# The MacBook failure: right advice, stale number. The label must name the major it found,
# because "stale" alone does not tell you whether you are one release behind or three.
_fvg_reset
_fvg_repo dotfiles-Fedora 'echo "  git subtree add --prefix=core <remote> refs/tags/v4 --squash"\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" == *'**stale-v4**'* ]]; then
  pass "vendor-guidance: a stale major reads as stale-v4 (names the major it found)"
else
  fail "vendor-guidance: a stale v4 pin was not flagged: $_fvg_out"
fi

# A point tag is current today and wrong tomorrow — it does not track the v-series, so it
# cannot be judged current on the next release. Its own label, since the fix differs from
# both `branch` and `stale`.
_fvg_reset
_fvg_repo dotfiles-Fedora 'echo "  git subtree add --prefix=core <remote> refs/tags/7.0.0 --squash"\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" == *'**non-major-tag**'* ]]; then
  pass "vendor-guidance: a point tag reads as non-major-tag"
else
  fail "vendor-guidance: a point tag was not flagged: $_fvg_out"
fi

# THE EXPECTED MAJOR IS DERIVED, not hardcoded — the property that makes this register keep
# working after today. Same fixture, judged against two different core.version values: a
# `v7` hint is ok while Core ships 7.x and stale the moment it ships 8.x. Driven through a
# fake Core root rather than by editing this repo's core.version, so the test cannot leave
# the tree dirty if it dies midway.
_fvg_reset
_fvg_repo dotfiles-Fedora 'echo "  git subtree add --prefix=core <remote> refs/tags/v7 --squash"\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" != *'**'* ]]; then
  pass "vendor-guidance: a v7 hint is ok while core.version is $(tr -d '[:space:]' <"$HERE/core.version")"
else
  fail "vendor-guidance: a current v7 hint was flagged: $_fvg_out"
fi

_fvg_fakecore="$SANDBOX/fake-core-v8"
rm -rf "$_fvg_fakecore"
# `lib/ux.sh` alongside the two scripts: scripts/lib/common.sh sources it at ../../lib/ux.sh
# and dies under `set -u` without it. Copying the real files rather than stubbing them keeps
# this a test of the SHIPPING script — a stub could drift from what actually runs.
mkdir -p "$_fvg_fakecore/scripts/lib" "$_fvg_fakecore/lib" "$_fvg_fakecore/.git"
echo "8.0.0" >"$_fvg_fakecore/core.version"
cp "$HERE/scripts/fleet-vendor-guidance.sh" "$_fvg_fakecore/scripts/"
cp "$HERE/scripts/lib/common.sh" "$_fvg_fakecore/scripts/lib/"
cp "$HERE/lib/ux.sh" "$_fvg_fakecore/lib/"
cp "$HERE/scripts/os-repos.txt" "$_fvg_fakecore/scripts/" 2>/dev/null || true
_fvg_out="$(REPOS_ROOT="$_fvg_root" "$_fvg_fakecore/scripts/fleet-vendor-guidance.sh" 2>&1)"
if [[ "$_fvg_out" == *'**stale-v7**'* ]]; then
  pass "vendor-guidance: the same v7 hint reads stale-v7 against a v8 core.version (expectation is derived)"
else
  fail "vendor-guidance: expected major is not derived from core.version: $_fvg_out"
fi

# FALSE POSITIVE 1 — prose. These repos discuss `git subtree pull` constantly, and every
# mention is correct writing that must not be flagged. The discriminator is a --prefix
# naming core: a sentence has none, a command has one.
_fvg_reset
_fvg_repo dotfiles-Fedora '# `git subtree pull` is retired: it moves core/ but not core.lock.\n# Never run git subtree pull by hand.\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" != *'**'* ]]; then
  pass "vendor-guidance: prose about subtree pull is not flagged (no --prefix)"
else
  fail "vendor-guidance: prose about subtree pull was flagged as a command: $_fvg_out"
fi

# FALSE POSITIVE 2 — another tree's contract. dotfiles-Offense vendors offensive/companion
# from dotgibson/htpx, which genuinely IS a subtree and whose sync-companion.sh runs subtree
# pull on purpose. Flagging it would train people to ignore this gate.
_fvg_reset
_fvg_repo dotfiles-Offense 'git subtree pull --prefix=offensive/companion <htpx> main --squash\n'
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" != *'**'* ]]; then
  pass "vendor-guidance: a subtree pull on a non-core prefix is another tree's contract, not a finding"
else
  fail "vendor-guidance: the companion subtree was flagged: $_fvg_out"
fi

# A repo with no hint at all is REPORTED, not failed: requiring one would invent a contract
# this register was not asked to enforce.
_fvg_reset
_fvg_repo dotfiles-Fedora
_fvg_out="$(_fvg_run)"
if [[ "$_fvg_out" == *'none'* && "$_fvg_out" != *'**'* ]]; then
  pass "vendor-guidance: a repo with no hint reads as none, and is not a finding"
else
  fail "vendor-guidance: a repo with no hint was mishandled: $_fvg_out"
fi

# --check is the gate half: a finding must be exit 1, not a table on stdout with exit 0.
_fvg_reset
_fvg_repo dotfiles-Fedora 'echo "  git subtree add --prefix=core <remote> main --squash"\n'
if _fvg_out="$(_fvg_run --check)"; then
  fail "vendor-guidance: --check exited 0 with a finding present: $_fvg_out"
else
  pass "vendor-guidance: --check exits non-zero when a hint is wrong"
fi

unset _fvg_root _fvg_sh _fvg_out _fvg_fakecore
