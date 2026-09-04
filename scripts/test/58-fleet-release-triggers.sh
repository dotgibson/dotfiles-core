# scripts/test/58-fleet-release-triggers.sh
# Release-trigger register (scripts/fleet-release-triggers.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.
#
# Numbered 58 to sit beside its siblings: 56 is the Makefile vocabulary register and 57
# the hermetic links gate, and this is the third register in that family.

# The fixtures below are literal GitHub Actions YAML: a `${{ … }}` inside one must reach
# the workflow file UNEXPANDED, which is the whole point of the shape being tested. Same
# file-wide false positive the sibling fragments and the dispatcher carry, for the same
# reason — single quotes are load-bearing here, not an oversight.
# shellcheck disable=SC2016

# ── the release-trigger register (scripts/fleet-release-triggers.sh) ─────────
# What an OS repo's own version number MEANS (#696). Every caller fired on
# `paths: ['core/**']`, so the tag advanced when Core moved and at no other time — native
# work was released only when an unrelated fan-out swept it up. The register reads each
# sibling's auto-tag.yml and says so. These drive the real script against a fake fleet
# root, and pin the two properties that make it worth having: it does not call a shape it
# could not read (`unparsed`, never a guessed verdict), and BOTH halves of a deliberate
# release — the dispatch and the `bump` value — are required before it says `dispatch`.
hdr "release-trigger register (fleet-release-triggers.sh)"
_frt_root="$SANDBOX/fleet-triggers"
_frt_sh="$HERE/scripts/fleet-release-triggers.sh"
_frt_reset() { rm -rf "$_frt_root"; mkdir -p "$_frt_root"; }
_frt_repo() { # _frt_repo <repo> [auto-tag.yml body] — a fake sibling; no body means no workflow
  mkdir -p "$_frt_root/$1/.git"
  if [[ $# -ge 2 ]]; then
    mkdir -p "$_frt_root/$1/.github/workflows"
    printf '%b' "$2" >"$_frt_root/$1/.github/workflows/auto-tag.yml"
  fi
  return 0
}
_frt_run() { REPOS_ROOT="$_frt_root" "$_frt_sh" "$@" 2>&1; }
# The shape Core now documents: a `**` denylist, a dispatch, and a bump reaching the
# reusable. Bodies are literal (printf '%b' expands the \n) rather than templated — a
# fixture about YAML shape should read as the YAML it is about.
_frt_good='name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "**"\n      - "!**.md"\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\n        options: [patch, minor, major]\n        default: patch\njobs:\n  tag:\n    uses: dotgibson/dotfiles-core/.github/workflows/auto-tag-call.yml@v6\n    with:\n      bump: ${{ inputs.bump || '"'"'patch'"'"' }}\n'

_frt_reset
if _frt_out="$(_frt_run --check)"; then
  if [[ "$_frt_out" == *"no sibling repo checked out"* ]]; then
    pass "triggers: an empty fleet root is an environment notice, exit 0"
  else
    fail "triggers: empty root exited 0 without the no-sibling notice: $_frt_out"
  fi
else
  fail "triggers: an empty fleet root exited non-zero: $_frt_out"
fi

# THE DEFECT, in both YAML spellings the fleet uses — a flow list and a block sequence.
# Both must read as core-only, or the register would have called half the fleet clean.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths: ["core/**"]\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**core-only**'* ]]; then
  pass "triggers: a flow-list core/** filter reads as core-only"
else
  fail "triggers: flow-list core/** was not reported core-only: $_frt_out"
fi
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "core/**"\n      - core.lock\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**core-only**'* ]]; then
  pass "triggers: a block-sequence core/** + core.lock filter reads as core-only (the sync's own stamp is not own-layer)"
else
  fail "triggers: block-sequence core-only was misread: $_frt_out"
fi

# The fixed shape: one own-layer path, a dispatch, and a bump reaching the reusable.
_frt_reset; _frt_repo dotfiles-Fedora "$_frt_good"
if _frt_out="$(_frt_run --check)" && [[ "$_frt_out" == *"releases its own layer and can cut a non-patch"* ]]; then
  pass "triggers: an own-layer denylist with a bump dispatch passes --check"
else
  fail "triggers: the corrected shape did not pass --check: $_frt_out"
fi

# BOTH HALVES ARE REQUIRED. A dispatch with no `bump:` reaches the reusable's `patch`
# default, and a `bump:` with no dispatch cannot be chosen at release time. Either alone
# is still patch-only — the fleet's actual state was the second kind of nothing.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\n  workflow_dispatch:\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* && "$_frt_out" == *'| own-layer |'* ]]; then
  pass "triggers: a dispatch with no bump: is still patch-only"
else
  fail "triggers: dispatch-without-bump was not reported patch-only: $_frt_out"
fi
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: minor\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* ]]; then
  pass "triggers: a bump: with no dispatch is still patch-only (nothing can choose it)"
else
  fail "triggers: bump-without-dispatch was not reported patch-only: $_frt_out"
fi

# A COMMENT DESCRIBING THE DEFAULT IS NOT A CALLER PASSING IT. Every `bump` string in the
# fleet was exactly this, which is why the input had never once been exercised.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\n# PATCH-bumps by default; a caller can pass bump: minor for a deliberate release.\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\n  workflow_dispatch:\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* ]]; then
  pass "triggers: a commented-out bump: does not count as reachable"
else
  fail "triggers: a comment mentioning bump: was read as a passed input: $_frt_out"
fi

# A `!` CARVE-OUT SUBTRACTS; it is not a watched path. dotfiles-MacBook's denylist is
# `**` plus ten exclusions, and counting those as own-layer paths would be accidentally
# right for the wrong reason — so assert the positive `**` is what carries the verdict.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "core/**"\n      - "!core/vendor/**"\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**core-only**'* ]]; then
  pass "triggers: a ! carve-out does not turn a core-only filter into own-layer"
else
  fail "triggers: a negated pattern was counted as a watched path: $_frt_out"
fi

# NO FILTER AT ALL is coarse but never silently misses this repo's work — not a finding.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: ${{ inputs.bump || '"'"'patch'"'"' }}\n'
if _frt_out="$(_frt_run --check)"; then
  pass "triggers: an unfiltered push trigger is not a finding"
else
  fail "triggers: an unfiltered trigger was reported as a defect: $_frt_out"
fi

# ── the two shapes that LOOK dispatch-capable and are not ─────────────────────
# Checking only "is there a workflow_dispatch and a bump: somewhere" certifies both of
# these, which is the exact broken wiring this column exists to detect.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\n        options: [patch, minor, major]\n        default: patch\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* ]]; then
  pass "triggers: a dispatch input the job never forwards is patch-only (the chooser is decorative)"
else
  fail "triggers: a declared-but-unforwarded bump input was certified as dispatch: $_frt_out"
fi
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: patch\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* ]]; then
  pass "triggers: a CONSTANT forwarded bump is patch-only (forwarded, and unselectable)"
else
  fail "triggers: a constant bump: patch was certified as dispatch: $_frt_out"
fi

# ── paths-ignore is a DENYLIST, and reading it as a watched path INVERTS the verdict ──
# `push.paths-ignore: [core/**]` runs on everything EXCEPT the vendored subtree — the
# own-layer shape — and the first cut of the reader reported it core-only.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths-ignore:\n      - "core/**"\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: ${{ inputs.bump }}\n'
if _frt_out="$(_frt_run --check)"; then
  pass "triggers: push.paths-ignore [core/**] reads as own-layer, not core-only"
else
  fail "triggers: paths-ignore was read as a watched path, inverting the verdict: $_frt_out"
fi
# GitHub rejects paths + paths-ignore together; abstain rather than pick one.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "core/**"\n    paths-ignore:\n      - "docs/**"\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**unparsed**'* ]]; then
  pass "triggers: paths AND paths-ignore together is unparsed, not a guessed verdict"
else
  fail "triggers: the both-keys shape produced a verdict anyway: $_frt_out"
fi

# ── the filter must come from on.push, not from whatever event appears first ──
# A pull_request filter deciding a push verdict is the same class of false green.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  pull_request:\n    paths:\n      - "os/**"\n  push:\n    branches: [main]\n    paths:\n      - "core/**"\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**core-only**'* ]]; then
  pass "triggers: a pull_request paths filter does not decide the push verdict"
else
  fail "triggers: a non-push event's filter leaked into the verdict: $_frt_out"
fi

# ── a MULTI-LINE flow sequence: the key is there, the values are on later lines ──
# `paths: [` matched, no `]` was found on that line, no P record was emitted, has_paths
# stayed false — and a core-only workflow reported `unfiltered`. The guard keys on the
# path KEY now, not on whether values came back.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths: [\n      "core/**"\n    ]\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**unparsed**'* ]]; then
  pass "triggers: a multi-line flow paths sequence is unparsed, not a false unfiltered"
else
  fail "triggers: an unterminated flow sequence fell through to a clean verdict: $_frt_out"
fi

# ── a bare workflow_dispatch renders NO chooser ──────────────────────────────
# `workflow_dispatch:` with no inputs, plus a job forwarding inputs.bump, satisfied the
# earlier two-fact check — and every dispatch resolves to the empty input and patches.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\n  workflow_dispatch:\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: ${{ inputs.bump }}\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* ]]; then
  pass "triggers: forwarding inputs.bump with no DECLARED input is patch-only (no chooser exists)"
else
  fail "triggers: a bare workflow_dispatch was certified as dispatch: $_frt_out"
fi

# ── a trailing comment mentioning inputs.bump must not read as a forward ──────
# This one is PLATFORM-SPECIFIC: the comment stripper used `[[:space:]]\+`, a GNU BRE
# extension that BSD sed reads as a literal plus. On the macOS audit leg the comment
# survived and this shape passed. POSIX `[[:space:]][[:space:]]*` now.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push:\n    branches: [main]\n    paths:\n      - "os/**"\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: patch  # dispatches pass inputs.bump\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**patch-only**'* ]]; then
  pass "triggers: a trailing comment naming inputs.bump does not make a constant a forward"
else
  fail "triggers: a comment was read as the forwarded value (BSD-sed shape): $_frt_out"
fi
# And no `sed` INVOCATION carries a GNU-only BRE, which is invisible on a Linux runner.
# Scoped to sed lines, not the whole file: the prose above explains the rule and names the
# forbidden form, and a file-wide grep matches that explanation (the same over-broad shape
# the --help assertion had).
if ! grep -n 'sed' "$_frt_sh" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -qF '[[:space:]]\+'; then
  pass "triggers: no sed invocation uses the GNU-only one-or-more BSD sed reads as a literal +"
else
  fail "triggers: a sed invocation in fleet-release-triggers.sh still uses a GNU-only BRE"
fi

# ── an INLINE event mapping hides the filter from the block reader ───────────
# `push: { branches: [main], paths: ["core/**"] }` is valid YAML the fleet does not use,
# and the block-form rules never look after the colon. Discarding it made _trigger see no
# path key and report `unfiltered` — a green for a workflow still releasing only on Core.
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  push: { branches: [main], paths: ["core/**"] }\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**unparsed**'* ]]; then
  pass "triggers: an inline push mapping is unparsed, not a false unfiltered"
else
  fail "triggers: an inline push mapping's filter was discarded and passed as unfiltered: $_frt_out"
fi

# ── no push trigger at all: nothing releases automatically ────────────────────
_frt_reset; _frt_repo dotfiles-Fedora 'name: auto-tag\non:\n  workflow_dispatch:\n    inputs:\n      bump:\n        type: choice\njobs:\n  tag:\n    uses: x@v6\n    with:\n      bump: ${{ inputs.bump }}\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**dispatch-only**'* ]]; then
  pass "triggers: a dispatch-only workflow is a finding (nothing releases on a push)"
else
  fail "triggers: a workflow with no push trigger was not reported dispatch-only: $_frt_out"
fi

# NO WORKFLOW AT ALL — the state a scaffolded repo used to be born in.
_frt_reset; _frt_repo dotfiles-Fedora
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**absent**'* ]]; then
  pass "triggers: a repo with no auto-tag.yml reads as absent, not as green"
else
  fail "triggers: a repo with no auto-tag.yml was not reported absent: $_frt_out"
fi

# DOES NOT BLUFF. A file whose `on:` block this reader cannot parse must say `unparsed`
# rather than fall through to a verdict — a register reporting a shape it never read is
# the exact failure mode this family of scripts exists to avoid.
_frt_reset; _frt_repo dotfiles-Fedora '"on":\n  push:\n    paths: ["core/**"]\njobs:\n  tag:\n    uses: x@v6\n'
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *'**unparsed**'* ]]; then
  pass "triggers: an on: spelling the reader does not handle is unparsed, not a guessed verdict"
else
  fail "triggers: an unreadable on: block produced a verdict anyway: $_frt_out"
fi

# A LINKED WORKTREE stores .git as a FILE. Testing -d skipped those, so a fleet of
# worktrees reported "no sibling repo checked out" — a green over an un-inspected fleet.
_frt_reset
mkdir -p "$_frt_root/dotfiles-Fedora/.github/workflows"
printf 'gitdir: /elsewhere/.git/worktrees/w\n' >"$_frt_root/dotfiles-Fedora/.git"
printf '%b' "$_frt_good" >"$_frt_root/dotfiles-Fedora/.github/workflows/auto-tag.yml"
if _frt_out="$(_frt_run --check)" && [[ "$_frt_out" != *"no sibling repo"* ]]; then
  pass "triggers: a sibling whose .git is a FILE (worktree/submodule) is still read"
else
  fail "triggers: a linked-worktree sibling was skipped, reporting an empty fleet: $_frt_out"
fi

# The no-sibling notice must guard the DEFAULT render too, not just --check: a header and
# no rows reads as "no repo has a problem", which is the bluff this register disclaims.
_frt_reset
_frt_out="$(_frt_run)"
if [[ "$_frt_out" == *"no sibling repo"* && "$_frt_out" != *"| repo | trigger |"* ]]; then
  pass "triggers: report mode says it has no siblings rather than printing an empty table"
else
  fail "triggers: default render printed a headers-only table with no siblings: $_frt_out"
fi

# --help must not depend on source line numbers: the fixed-range idiom truncates the
# moment the banner grows, which it did here during review.
if _frt_out="$($_frt_sh --help)" && [[ "$_frt_out" == *"usage: fleet-release-triggers.sh"* &&
  "$_frt_out" == *"Env: REPOS_ROOT"* ]] && grep -qE '^[[:space:]]*usage$' "$_frt_sh"; then
  pass "triggers: --help is a heredoc usage(), complete and not a fixed header range"
else
  fail "triggers: --help still reads a fixed range of the file header"
fi

# Rendering is not a verdict (the trailing-test shape that made `make fleet-vocabulary`
# exit 1 for printing a full table — #846).
_frt_reset; _frt_repo dotfiles-Fedora "$_frt_good"
if _frt_run >/dev/null; then pass "triggers: report mode exits 0 (rendering is not a verdict)"; else fail "triggers: report mode exits non-zero"; fi

# The wiring, so the register cannot become a script nothing runs.
if grep -q 'fleet-release-triggers.sh" --check' "$HERE/scripts/audit-core.sh" &&
  grep -qF '"fleet list "' "$HERE/scripts/audit-core.sh"; then
  pass "triggers: audit-core.sh §5h runs the register and reads its fleet-list notice as an environment skip"
else
  fail "triggers: audit-core.sh §5h no longer runs fleet-release-triggers.sh --check"
fi
if grep -qE '^fleet-release-triggers: ' "$HERE/Makefile"; then
  pass "triggers: \`make fleet-release-triggers\` prints the register"
else
  fail "triggers: Makefile has no fleet-release-triggers target"
fi
# Core's DOCUMENTED caller example is the thing that fanned the defect out in the first
# place, so hold it to the shape this register checks for: a non-core path, a dispatch,
# and a bump actually passed.
_frt_ex="$HERE/.github/workflows/auto-tag-call.yml"
if grep -qF "workflow_dispatch:" "$_frt_ex" && grep -qF "bump: \${{ inputs.bump || 'patch' }}" "$_frt_ex" &&
  ! grep -qE "^#   *paths: \['core/\*\*'\]" "$_frt_ex"; then
  pass "triggers: auto-tag-call.yml's caller example no longer documents the core-only shape"
else
  fail "triggers: auto-tag-call.yml's caller example still documents paths: ['core/**'] or omits the bump dispatch"
fi
# The caller idiom's ONE failure mode: if the dispatch fallback ever resolved to "" rather
# than "patch", the reusable's strict allowlist would fail every push-triggered tag run in
# every consumer repo at once. An unsupplied optional input means its documented default,
# so the reusable normalises empty BEFORE the allowlist — and the expression itself must
# NOT appear inside the `run:` body, which the runner interpolates before the shell sees
# it (the exact caller-input splice that step's own comments exist to prevent).
if grep -qF '[ -n "$BUMP" ] || BUMP="patch"' "$_frt_ex"; then
  pass "triggers: auto-tag-call.yml normalises an empty bump to its documented default"
else
  fail "triggers: auto-tag-call.yml would fail the allowlist on an empty bump — every push-triggered tag run in the fleet"
fi
if awk '/^        run: \|/ { inrun = 1; next } inrun && /^        [^ ]/ { inrun = 0 } inrun' "$_frt_ex" | grep -qF '${{'; then
  fail "triggers: auto-tag-call.yml interpolates an expression inside a run: body — caller input would be spliced into the script"
else
  pass "triggers: no \${{ }} inside auto-tag-call.yml's run: bodies (caller input cannot be spliced)"
fi
# new-os-repo.sh must stamp that same shape, or a fresh repo is born with the old defect
# (or, as it was, with no auto-tag.yml at all and no release line of its own).
if grep -qF '.github/workflows/auto-tag.yml' "$HERE/scripts/new-os-repo.sh" &&
  grep -qF "bump: \\\${{ inputs.bump || 'patch' }}" "$HERE/scripts/new-os-repo.sh"; then
  pass "triggers: new-os-repo.sh scaffolds an auto-tag caller with a reachable bump"
else
  fail "triggers: new-os-repo.sh does not scaffold an auto-tag.yml carrying the bump dispatch"
fi
rm -rf "$_frt_root"
