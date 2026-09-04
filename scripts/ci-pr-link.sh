#!/usr/bin/env bash
# scripts/ci-pr-link.sh — does this PR satisfy the "a fix links its issue" rule?
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS. #446 fixed two reported bugs (#420 starship, #423 carapace) and
# merged green — but its body carried no `Closes #…` keyword, so GitHub linked
# nothing and both issues stayed OPEN for days looking like live defects. The next
# reader re-derived a 2021 upstream rename, re-ran the reproducer, and re-confirmed
# a bug that had already shipped in v4.12.0. Nothing was broken; the LINK was
# missing, and nothing in CI objected.
#
# So: a `fix(…)` or `feat(…)` PR must close an issue, or say in writing why not.
#
# Decision logic lives HERE rather than inline in the workflow YAML, matching
# scripts/ci-classify.sh — shellcheck-clean, unit-tested (scripts/test-core.sh),
# and runnable by hand. The workflow does only the part that needs the network
# (asking GitHub how many issues the PR closes) and hands the verdict to this.
#
# Usage:  ci-pr-link.sh <pr-title> <linked-issue-count>   # PR body on stdin
#
# Prints ONE `verdict=…` line to stdout (a stable token for the workflow and the
# tests), a human explanation to stderr, and exits:
#   0  verdict=not-gated    not a `fix(…)`/`feat(…)` PR — this rule has no opinion
#   0  verdict=ok           gated, and it closes >= 1 issue
#   0  verdict=exempt       gated, no link, but the body records `No-Issue: <reason>`
#   1  verdict=missing-link gated, no link, no reason  ← the #446 shape
#   1  verdict=probe-failed gated, no reason, and the count could not be determined —
#                           an API failure, NOT a claim about the PR (#500)
#   2  usage error
#
# missing-link and probe-failed share an exit code and mean different things. The
# exit code is the POLICY (block either way); the verdict is the CLAIM, and only one
# of them asserts anything about the author's PR.
#
# GATED SET: `fix` and `feat`. The regex is the delimiter-aware Conventional-Commit
# shape from scripts/gen-release-notes.sh:50 — optional `(scope)`, optional breaking
# `!`, then `:`. Prose that merely starts with the word ("fixing a flaky test") is NOT
# gated, and neither is `fixup:`.
#
# NOT cliff.toml:56, which groups on a bare `^fix` and so also matches `fixup:`. The
# two differ, and this gate deliberately takes the STRICTER of them on that axis: a
# false `not-gated` merely declines to ask for a link, while a false gate would demand
# one from a PR that is not a fix at all, and authors would learn to route around the
# check.
#
# WHY `feat` JOINED IT (#852). The set was `fix` only, and the argument for that — just
# above — is entirely about `fixup:` versus `fix:`. It says nothing about `feat:`, and
# the omission had a cost. #852 (`fix(fleet): make check is not hermetic…`) was resolved
# by #853, titled `feat(check): one Core-owned hermetic links gate`, plus three consumer
# PRs. Every part merged; nothing closed the issue; it sat OPEN looking like a live
# defect until a reader noticed — the exact #446 shape the gate exists to prevent,
# reached through the PR's title rather than its body. An issue does not know how the PR
# that resolves it will be typed.
#
# Measured over the 100 PRs merged after the gate landed (2026-08-17): 29 gated, 71 not,
# and 41 of those 71 cited an issue in the body and closed none.
#
# AND IT STOPS AT `feat`, on the same reasoning that keeps `fixup:` out. `chore(core):
# sync Core → vX.Y.Z` and `docs(changelog): release vX.Y.Z` are mechanical and close
# nothing by design; gating them would teach `No-Issue:` as a reflex, and an escape
# hatch taken by habit is a gate that has stopped working. `fix` and `feat` are the two
# types that mean someone reported this or someone asked for it.
#
# The PR TITLE is what this repo squash-merges into the subject line, so the
# title is the honest thing to test.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <pr-title> <linked-issue-count>   # PR body on stdin\n' "${0##*/}" >&2
  exit 2
fi

title="$1"
linked="$2"

# A non-numeric count means the probe could not answer — a GitHub API error, not a
# statement about this PR. Keep the two APART.
#
# The first version coerced it to 0 and let it fall through to the no-links branch. That
# is fail-closed, which is right, but it inherited that branch's wording and so asserted
# something the check does not know: during a run of GitHub 503s it failed #499 — which
# links #498 — with "this fix(…) PR closes no issue and gives no reason." The link was
# intact the whole time; re-running the identical job minutes later returned linked=1.
# Telling an author to add a link they already added is worse than saying nothing: it is
# how a gate earns a reputation for lying, and a gate people distrust is one they route
# around. See #500.
probe_ok=1
[[ "$linked" =~ ^[0-9]+$ ]] || {
  probe_ok=0
  linked=0
}

if [[ ! "$title" =~ ^(fix|feat)(\([^\)]*\))?!?: ]]; then
  echo "verdict=not-gated"
  # No backticks in these single-quoted strings: shellcheck reads them as an intended
  # command substitution and raises SC2016, which this repo's audit treats as a failure.
  printf 'ci-pr-link: title is not a fix(…) or feat(…) PR — rule does not apply.\n' >&2
  exit 0
fi

if ((probe_ok)) && ((linked > 0)); then
  echo "verdict=ok"
  printf 'ci-pr-link: closes %s linked issue(s).\n' "$linked" >&2
  exit 0
fi

# ── The escape hatch ─────────────────────────────────────────────────────────
# Evaluated BEFORE the probe-failure verdict below, deliberately: `No-Issue:` is read
# from the PR body, which the workflow already has in hand, so it needs no API call. A
# PR that carries a reason is satisfiable offline, and blocking it on an outage would be
# gratuitous — the check has everything it needs to say yes.
# Strip HTML comments BEFORE looking for the marker. This is load-bearing, not
# tidiness: pull_request_template.md documents `No-Issue:` inside a `<!-- … -->`
# block, so scanning the raw body would let the UNEDITED template exempt every
# PR — the gate would ship dead on arrival and nobody would notice, because a
# green check looks the same either way. The stripper handles inline and
# multi-line comments.
body_visible="$(
  awk '
    BEGIN { inc = 0 }
    {
      line = $0; out = ""
      while (length(line)) {
        if (inc) {
          i = index(line, "-->")
          if (i == 0) { line = ""; break }
          line = substr(line, i + 3); inc = 0
        } else {
          i = index(line, "<!--")
          if (i == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, i - 1); line = substr(line, i + 4); inc = 1
        }
      }
      print out
    }
  '
)"

# `No-Issue:` must start its own line (leading whitespace tolerated) and carry at
# least one non-space character of reason. Anchoring stops ordinary prose from
# exempting a PR by accident, and requiring a reason stops a bare `No-Issue:`
# from being a one-word bypass — the reason is the whole point, since it is what
# a future reader finds instead of an issue link. Deliberately NOT policing the
# reason's length: a rule that rejects "n/a" just teaches people to type "n/a "
# and hides the same signal behind a longer string.
# Herestring, NOT `printf … | grep -Eqi`. Under this script's `set -o pipefail`, grep
# exits on its first match, printf takes EPIPE, and the PIPELINE reports 141 — so a body
# larger than the pipe buffer would make a VALID `No-Issue:` line evaluate false and fail
# a correctly-exempt PR. The escape hatch failing into a false accusation is the same
# shape as #500, one layer down. It survived this long because a PR body fits the buffer;
# the §5d scanner could not see it because its regex required grep's `q` to be the last
# letter of the flag cluster, and this reads `-Eqi` (widened in the same change; see #501).
if grep -Eqi '^[[:space:]]*No-Issue:[[:space:]]*[^[:space:]]' <<<"$body_visible"; then
  echo "verdict=exempt"
  printf 'ci-pr-link: no linked issue, but the body records a No-Issue: reason.\n' >&2
  exit 0
fi

# The probe never answered, and the body carries no reason — so this check does not know
# whether the PR is linked. Say exactly that. Still EXIT NON-ZERO (the recorded decision
# in #500): blocking is the safe side, since passing here would let an unlinked fix PR
# through on any API blip, which is the hole the gate exists to close. The difference
# from missing-link is not the exit code, it is the claim.
if ((!probe_ok)); then
  echo "verdict=probe-failed"
  cat >&2 <<'EOF'
ci-pr-link: could NOT determine whether this PR closes an issue.

The GitHub GraphQL probe did not return a count -- an API error on our side, not
a problem with your PR. This check is deliberately failing rather than guessing,
because guessing "no link" would be wrong exactly when GitHub is having a bad
day, and guessing "linked" would let an unlinked fix PR through.

Nothing to change in the PR. Re-run this job:

  Actions tab -> this workflow run -> "Re-run failed jobs"

If it keeps failing while github.com is healthy, that is a real bug -- see #500.
EOF
  exit 1
fi

echo "verdict=missing-link"
cat >&2 <<'EOF'
ci-pr-link: this `fix(…)`/`feat(…)` PR closes no issue and gives no reason.

Merging without a link leaves the issue OPEN — the next reader re-investigates
something that already shipped. That is exactly what happened with #446, which
fixed #420 and #423 and closed neither, and again with #852, which #853 resolved
in full and left open because the PR was typed `feat(…)` rather than `fix(…)`.

Do ONE of these:

  1. Link the issue. Put a closing keyword in the PR body:

         Closes #420

     It must be a CLOSING keyword -- close/closes/closed, fix/fixes/fixed,
     resolve/resolves/resolved. "Refs #420" reads like a link but closes
     nothing, so it will not satisfy this check.

  2. Say why there isn't one. Add a line to the PR body:

         No-Issue: found and fixed in one pass, never filed

Either way, editing the PR body re-runs this check automatically.

Linking from the "Development" sidebar instead also works, and this check will
count it -- but GitHub emits no pull_request event for a sidebar link, so the
check will NOT re-run on its own. Re-run it from the Actions tab, or make any
edit to the PR body, to pick the link up.
EOF
exit 1
