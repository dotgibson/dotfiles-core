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
# So: a `fix(…)` PR must either close an issue or say in writing why it doesn't.
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
#   0  verdict=not-gated    not a `fix(…)` PR — this rule has no opinion
#   0  verdict=ok           gated, and it closes >= 1 issue
#   0  verdict=exempt       gated, no link, but the body records `No-Issue: <reason>`
#   1  verdict=missing-link gated, no link, no reason  ← the #446 shape
#   2  usage error
#
# GATED SET: `fix` only, deliberately. The regex is the repo's canonical
# Conventional-Commit shape, the same one scripts/gen-release-notes.sh:50 and
# cliff.toml:56 use — optional `(scope)`, optional breaking `!`, then `:`. Prose
# that merely starts with the word ("fixing a flaky test") is NOT gated, and
# neither is `fixup:`. The PR TITLE is what this repo squash-merges into the
# subject line, so the title is the honest thing to test.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <pr-title> <linked-issue-count>   # PR body on stdin\n' "${0##*/}" >&2
  exit 2
fi

title="$1"
linked="$2"

# A non-numeric count means the GraphQL probe returned something unexpected. FAIL
# CLOSED to 0 (i.e. "no links proven") rather than trusting a garbled value: the
# cost is a PR author adding a link or a reason, never a silently skipped gate.
[[ "$linked" =~ ^[0-9]+$ ]] || linked=0

if [[ ! "$title" =~ ^fix(\([^\)]*\))?!?: ]]; then
  echo "verdict=not-gated"
  printf 'ci-pr-link: title is not a `fix(…)` PR — rule does not apply.\n' >&2
  exit 0
fi

if ((linked > 0)); then
  echo "verdict=ok"
  printf 'ci-pr-link: closes %s linked issue(s).\n' "$linked" >&2
  exit 0
fi

# ── The escape hatch ─────────────────────────────────────────────────────────
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
if printf '%s\n' "$body_visible" | grep -Eqi '^[[:space:]]*No-Issue:[[:space:]]*[^[:space:]]'; then
  echo "verdict=exempt"
  printf 'ci-pr-link: no linked issue, but the body records a `No-Issue:` reason.\n' >&2
  exit 0
fi

echo "verdict=missing-link"
cat >&2 <<'EOF'
ci-pr-link: this `fix(…)` PR closes no issue and gives no reason.

A fix that merges without a link leaves the issue it fixed OPEN — the next
reader re-investigates a bug that already shipped. That is exactly what
happened with #446, which fixed #420 and #423 and closed neither.

Do ONE of these:

  1. Link the issue. Put a closing keyword in the PR body:

         Closes #420

     (or use the "Development" sidebar). "Refs #420" does NOT link — it must
     be a closing keyword: close/closes/closed, fix/fixes/fixed,
     resolve/resolves/resolved.

  2. Say why there isn't one. Add a line to the PR body:

         No-Issue: found and fixed in one pass, never filed

Editing the PR body re-runs this check automatically.
EOF
exit 1
