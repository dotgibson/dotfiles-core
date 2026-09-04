# scripts/test/61-check-modern.sh
# CI modernization floor (scripts/check-modern.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── CI modernization floor: rules 2 and 7 (#521) ─────────────────────────────
# check-modern.sh had no behavioural coverage — every rule was "green on this tree",
# which cannot distinguish a rule that PASSES from a rule that never MATCHES. Rule 2 was
# in exactly that state: it had banned `ubuntu-22.04` since the floor was written and
# would have waved `ubuntu-22.04-arm` straight through.
#
# Hermetic: a throwaway git repo (the gate inventories through `git ls-files`, so a plain
# directory yields "no workflow/action files to check" and every assertion below would
# vacuously pass) holding only the script, its lib and a crafted workflow.
hdr "CI modernization floor (scripts/check-modern.sh rules 2, 3, 7 + 8)"
if ! have git; then
  skip "check-modern rule fixtures (git not installed)"
else
  CMF="$SANDBOX/check-modern"
  rm -rf "$CMF"
  mkdir -p "$CMF/scripts/lib" "$CMF/lib" "$CMF/.github/workflows"
  cp "$HERE/scripts/check-modern.sh" "$CMF/scripts/"
  cp "$HERE/scripts/modern-baseline.yml" "$CMF/scripts/"
  cp "$HERE/scripts/lib/common.sh" "$CMF/scripts/lib/"
  cp "$HERE/lib/ux.sh" "$CMF/lib/"
  git -C "$CMF" init -q 2>/dev/null
  git -C "$CMF" add -A 2>/dev/null

  # _cm_run <workflow-body> → the gate's stderr for that single workflow
  _cm_run() {
    printf '%s\n' "$1" >"$CMF/.github/workflows/probe.yml"
    git -C "$CMF" add -A 2>/dev/null
    # stdout (the one-line verdict) to /dev/null INSIDE the subshell, then the subshell's
    # stderr — where note() writes the violations — up to our stdout. Written this way
    # round rather than `2>&1 >/dev/null`, which does the same thing but reads as the
    # classic mistake.
    { ( cd "$CMF" && bash scripts/check-modern.sh >/dev/null ) || true; } 2>&1
  }

  # A clean baseline workflow: proves the fixture reaches the gate at all, so a later
  # "no violations" result means the rule passed rather than the harness misfiring.
  _cm_clean='name: p
on: [push]
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
  if [[ -z "$(_cm_run "$_cm_clean")" ]] \
    && ( cd "$CMF" && bash scripts/check-modern.sh 2>/dev/null | grep -q 'meets the modern baseline' ); then
    pass "check-modern fixture: a clean workflow reaches the gate and passes (harness is live)"
  else
    fail "check-modern fixture: harness misfire — a clean workflow did not reach the gate"
    _cm_run "$_cm_clean" | sed 's/^/    /' >&2
  fi

  # Rule 2: the variant suffixes. `ubuntu-22.04-arm` and `macos-14-xlarge` are named in the
  # SAME deprecation notices as their base labels, and both were slipping the ban.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-22.04-arm
    timeout-minutes: 5
    steps:
      - run: echo hi
  b:
    runs-on: macos-14-xlarge
    timeout-minutes: 5
    steps:
      - run: echo hi
  c:
    runs-on: macos-14-large
    timeout-minutes: 5
    steps:
      - run: echo hi')"
  if [[ "$(grep -c 'EOL runner' <<<"$_cm_out")" == 3 ]]; then
    pass "check-modern rule 2: -arm / -large / -xlarge variants of a banned runner are caught"
  else
    fail "check-modern rule 2: variant-suffixed runners slipped the ban (want 3 hits)"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  # …and the base labels must still be caught (a suffix group that swallowed the plain
  # form would pass the test above while silently disabling the rule it extends).
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-22.04
    timeout-minutes: 5
    steps:
      - run: echo hi')"
  if grep -q 'EOL runner (ubuntu-22.04)' <<<"$_cm_out"; then
    pass "check-modern rule 2: the bare banned label is still caught (suffix group is optional)"
  else
    fail "check-modern rule 2: the suffix group broke the plain-label match"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  # A supported runner whose name merely CONTAINS a banned one must not fire.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi')"
  if ! grep -q 'EOL runner' <<<"$_cm_out"; then
    pass "check-modern rule 2: a supported runner does not fire the ban"
  else
    fail "check-modern rule 2: false positive on a supported runner"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  # Rule 3's first-party exemption must be the POLICY's shape, not the whole owner. A bare
  # owner match let `uses: dotgibson/anything@main` through outright — wider than the @vN
  # policy it was named for, and asserted nowhere else, so the policy was documented in
  # RELEASE-STRATEGY.md and enforced by nothing.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  ok1:
    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v4
  bad1:
    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@main
  bad2:
    uses: dotgibson/some-action@v1')"
  if [[ "$(grep -c 'outside the @vN reusable-workflow policy' <<<"$_cm_out")" == 2 ]] \
    && ! grep -q 'lint-call.yml@v4' <<<"$_cm_out"; then
    pass "check-modern rule 3: first-party @main and non-workflow refs are caught, @vN is not"
  else
    fail "check-modern rule 3: the owner exemption is still wider than the @vN policy"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi
  # A SHA-pinned first-party ref must also pass — the exemption is a shortcut, not the only
  # acceptable form, and a repo that chose to pin its caller must not be told off for it.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  ok:
    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
  if ! grep -qE 'unpinned action|@vN reusable-workflow policy' <<<"$_cm_out"; then
    pass "check-modern rule 3: a SHA-pinned first-party ref is still accepted"
  else
    fail "check-modern rule 3: SHA-pinned first-party ref was rejected"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  # Rule 7: a `${{ }}` expression is substituted by the runner, textually, BEFORE the
  # shell parses the script — so an attacker-controlled value there is code, not data.
  # Both the block-scalar and the one-line `run:` forms must be caught.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: block scalar
        run: |
          echo "${{ github.event.pull_request.title }}"
      - name: one-line
        run: echo "${{ github.head_ref }}"')"
  if [[ "$(grep -c 'untrusted expression interpolated' <<<"$_cm_out")" == 2 ]]; then
    pass "check-modern rule 7: untrusted context spliced into a run: body is caught (block + inline)"
  else
    fail "check-modern rule 7: template injection into run: was not caught (want 2 hits)"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  # The three shapes that must NOT fire, asserted together because each is a live pattern
  # somewhere in the fleet and a false positive here is a red gate on every repo:
  #   - the same value routed through env: and read as $VAR (the prescribed remedy);
  #   - `inputs.*`, a first-party composite input (setup-core-tools/action.yml, ~8 steps);
  #   - a banned context in `if:` / `env:` / `concurrency:`, which are not shell.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
concurrency: ci-${{ github.head_ref }}
jobs:
  a:
    if: github.actor != "bot"
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: routed through env
        env:
          T: ${{ github.event.pull_request.title }}
        run: |
          echo "$T"
      - name: first-party composite input
        run: echo "${{ inputs.bindir }}"
      - name: dedent ends the block
        run: |
          echo safe
      - name: not a run body
        uses: ./.github/actions/x
        with:
          v: ${{ github.event.number }}')"
  if ! grep -q 'untrusted expression interpolated' <<<"$_cm_out"; then
    pass "check-modern rule 7: env:-routed, inputs.*, if:/concurrency: and with: do not fire"
  else
    fail "check-modern rule 7: false positive — this shape is the prescribed remedy"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi
  # Rule 8: a runner job with no timeout-minutes. GitHub's default is 360 minutes — six
  # hours of a held runner and a live GITHUB_TOKEN for a job that hung. `b` is the control
  # in the SAME fixture: a job that declares one must not be flagged, so a rule that simply
  # fired on every job would fail here rather than pass the negative case by luck.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  b:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi')"
  if [[ "$(grep -c 'without timeout-minutes' <<<"$_cm_out")" == 1 ]] \
    && grep -q 'without timeout-minutes.*: a$' <<<"$_cm_out"; then
    pass "check-modern rule 8: a runner job with no timeout-minutes is caught (and only that one)"
  else
    fail "check-modern rule 8: want exactly one hit, naming job 'a'"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  # THE FALSE-FIRE THIS RULE IS SHAPED AROUND. A job that calls a reusable workflow (`uses:`
  # at job level) CANNOT legally carry timeout-minutes — GitHub rejects the workflow. Ten
  # jobs in this repo are exactly that shape, every one a notify-failure-call/notify-web-call.
  # Keying on `runs-on:` rather than "every job" is the whole reason the rule is written the
  # way it is, and this is the assertion that keeps it that way.
  _cm_out="$(_cm_run 'name: p
on: [push]
permissions:
  contents: read
jobs:
  call:
    uses: ./.github/workflows/other.yml
  local:
    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v4')"
  if ! grep -q 'without timeout-minutes' <<<"$_cm_out"; then
    pass "check-modern rule 8: a reusable-workflow call job does not fire (it cannot carry one)"
  else
    fail "check-modern rule 8: false positive on a job that cannot legally set timeout-minutes"
    printf '%s\n' "$_cm_out" | sed 's/^/    /' >&2
  fi

  unset _cm_out _cm_clean
  unset -f _cm_run
fi
