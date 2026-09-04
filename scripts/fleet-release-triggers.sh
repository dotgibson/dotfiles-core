#!/usr/bin/env bash
# scripts/fleet-release-triggers.sh — the release-trigger register (#696)
# ──────────────────────────────────────────────────────────────────────────────
# WHAT DOES EACH REPO'S OWN VERSION NUMBER ACTUALLY MEAN? Every OS repo carries a
# `vX.Y.Z` tag that reads like a release of that repo, and for most of the fleet it was
# not one. `auto-tag.yml` fired on `paths: ['core/**']` — the vendored subtree — so the
# tag advanced when *Core* moved and at no other time. Measured on dotfiles-Fedora at the
# time of #696: seven Core syncs produced seven releases, and six native commits (a
# package-name gate that had never run, a tracked file removed) produced zero. `v1.3.68`
# meant "this repo has received 68 Core syncs" — and `core.lock` already answers that
# question, precisely, offline.
#
# The other half of the same defect: `auto-tag-call.yml` has always accepted a `bump`
# input, and no caller had ever passed one. Every `bump` string in the fleet was a comment
# describing the default. A tag that can only ever patch is a build counter in a SemVer
# costume — three components, one of them reachable.
#
# WHY A REGISTER AND NOT JUST NINE EDITS. scripts/fleet-coverage.sh already tracks
# `auto-tag-call` and reports `reusable` for all nine repos — green, while six of them
# released only on Core syncs. That is the right answer to the question it asks ("who
# calls this gate?") and the wrong answer to the one that bit us ("does calling it
# release anything this repo owns?"). This register asks the second question. It is also
# the drift that a Core sync is most likely to reintroduce: dotfiles-MacBook's caller
# carries a standing `Please don't "restore" the upstream shape` note precisely because
# the shape Core documented was the broken one.
#
# THE TWO COLUMNS
#
#   trigger — what a push has to touch for this repo to cut its own tag:
#     own-layer   at least one watched path is outside core/ (the repo releases its own
#                 work). A `**` with `!` carve-outs (dotfiles-MacBook's denylist) counts.
#     unfiltered  no `paths:` filter at all — every push to the branch releases. Coarse,
#                 but never silently misses this repo's work, so it is not a finding.
#     core-only   every watched path is under core/ — the tag tracks the vendored
#                 dependency, not this repo. THE DEFECT.
#     absent      no .github/workflows/auto-tag.yml — the repo never tags itself.
#     unparsed    the file is there and this script could not read its `on:` block. Said
#                 out loud rather than guessed at: a register that reports a shape it did
#                 not actually read is the failure mode this whole family exists to avoid.
#
#   WHAT `core-only` CAN AND CANNOT SEE. It keys on `core/` — the one vendored subtree
#   Core knows every repo has, because Core writes it. A repo that vendors a SECOND
#   subtree and watches only that (dotfiles-Offense also carries `offensive/companion/`
#   from htpx) reads as own-layer here even though the same defect applies to its native
#   work. Core cannot derive those paths: they are written by that repo's own sync script.
#   So this column is a floor, not a proof — it catches the shape Core itself shipped.
#
#   bump — is a deliberate non-patch release reachable without editing the workflow?
#     dispatch    a workflow_dispatch exists AND a `bump` value reaches the reusable, so
#                 a minor/major is Actions → Run workflow → pick a component.
#     patch-only  push-triggered only, or no `bump:` passed — every tag this repo can cut
#                 is a patch.
#
# DELIBERATELY ABSENT: dotfiles-Windows, for the same reason it is absent from
# scripts/os-repos.txt — it vendors no core/ and is not a fan-out target, so
# load_os_repos does not enumerate it. Its auto-tag.yml has the same shape of defect
# (it fires on the nvim/ and starship/ trees it MIRRORS from Core, so host work earns
# nothing automatically), but that is documented and deliberate: RELEASE-RUNBOOK.md §3b
# is the hand-cut minor/major flow that covers it. Check it there, not here.
#
# ADVISORY, like the coverage and vocabulary registers: this reports fleet drift that
# arrives red on repos this commit did not touch, so audit-core.sh prints it and stays
# green (see §5f's REPORT, DO NOT BLOCK note).
#
# Usage:
#   ./scripts/fleet-release-triggers.sh            # markdown table on stdout
#   ./scripts/fleet-release-triggers.sh --check    # exit 1 if any repo has a finding
# Env: REPOS_ROOT (default: parent of this repo)
set -uo pipefail
HERE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

REPOS_ROOT="${REPOS_ROOT:-$(cd "$HERE/.." && pwd)}"
CHECK=0
for a in "$@"; do
  case "$a" in
  --check) CHECK=1 ;;
  -h | --help)
    sed -n '2,70p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "unknown arg: $a" >&2
    exit 2
    ;;
  esac
done

# The fleet, through the ONE reader in lib/common.sh (#669). An empty register is a lie —
# it renders as "no repo has a release-trigger problem", which is indistinguishable from a
# fleet that could not be enumerated. Say so and stop, exactly as fleet-coverage.sh does.
load_os_repos || {
  fail "$CORE_OS_REPOS_ERR — cannot enumerate the fleet to report on"
  exit 2
}
REPOS=("${CORE_OS_REPOS[@]}")

# _on_paths <file> — echo one watched path pattern per line, from the `on:` mapping.
#
# A crude YAML reader on purpose, and bounded so it cannot bluff: it prints the patterns
# it recognizes and NOTHING for a file it does not understand, which the caller reports as
# `unparsed` rather than as a verdict. The fleet's auto-tag.yml files are all one shape —
# a top-level `on:` mapping with a `paths:` sequence or flow list — and a real YAML parser
# is not a dependency this fleet assumes on every host (§ the diffutils rule).
#
# Handles both spellings the fleet uses:
#   paths: ['core/**']                    (flow, dotfiles-Alpine and friends)
#   paths:\n      - 'core/**'             (block, dotfiles-openSUSE and friends)
# Comments are stripped first; `paths-ignore:` is read too, since a repo filtering that
# way is still filtering. Negated (`!`) patterns are emitted with the `!` intact — the
# caller decides what they mean, because they SUBTRACT from a wider match and must not be
# mistaken for the thing the repo watches.
_on_paths() {
  awk '
    # Strip whole-line and trailing comments. Safe here: no watched glob in the fleet
    # contains a "#", and a "#" inside one would be a directory named "#" anyway.
    { sub(/[[:space:]]+#.*$/, ""); sub(/^[[:space:]]*#.*$/, "") }
    /^[[:space:]]*$/ { next }
    # Enter the top-level `on:` mapping; leave at the next top-level key.
    /^on:[[:space:]]*$/ { on = 1; next }
    on && /^[^[:space:]]/ { on = 0 }
    !on { next }
    # A flow list on the key line: paths: [a, b] — split on the brackets and commas.
    /^[[:space:]]*paths(-ignore)?:[[:space:]]*\[/ {
      s = $0
      sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]*["'"'"']?|["'"'"']?[[:space:]]*$/, "", parts[i])
        if (parts[i] != "") print parts[i]
      }
      inseq = 0
      next
    }
    # A block sequence under the key: the items are the following `- ` lines.
    /^[[:space:]]*paths(-ignore)?:[[:space:]]*$/ { inseq = 1; next }
    inseq && /^[[:space:]]*-[[:space:]]*/ {
      s = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", s)
      gsub(/^["'"'"']|["'"'"']$/, "", s)
      if (s != "") print s
      next
    }
    # Any other key ends the sequence (branches:, workflow_dispatch:, …).
    inseq && /^[[:space:]]*[^-[:space:]]/ { inseq = 0 }
  ' "$1"
}

# _trigger <file> — the trigger verdict for one auto-tag.yml.
_trigger() {
  local f="$1" p positives=0 outside=0
  # No `on:` block we can find at all — do not guess.
  grep -qE '^on:[[:space:]]*$' "$f" || {
    printf 'unparsed'
    return 0
  }
  # A filter key is present but yielded no patterns → the reader failed, not the repo.
  if grep -qE '^[[:space:]]*paths(-ignore)?:' "$f" && [[ -z "$(_on_paths "$f")" ]]; then
    printf 'unparsed'
    return 0
  fi
  while IFS= read -r p; do
    [[ "$p" == '!'* ]] && continue # a carve-out subtracts; it is not a watched path
    positives=$((positives + 1))
    # Anything not rooted in the vendored subtree is this repo's own work. `core.lock` is
    # NOT own-layer: it is the sync's provenance stamp, written by the fan-out.
    [[ "$p" =~ ^core(/|\.lock$) ]] || outside=$((outside + 1))
  done < <(_on_paths "$f")
  if ((positives == 0)); then
    printf 'unfiltered'
  elif ((outside)); then
    printf 'own-layer'
  else
    printf 'core-only'
  fi
}

# _bump <file> — is a deliberate non-patch release reachable without editing this file?
# Both halves are required: a `bump:` with no dispatch cannot be chosen at release time,
# and a dispatch with no `bump:` reaches the reusable's `patch` default.
_bump() {
  local f="$1" body
  body="$(sed -e 's/[[:space:]]\+#.*$//' -e 's/^[[:space:]]*#.*$//' "$f")"
  if grep -qE '^[[:space:]]*workflow_dispatch:' <<<"$body" &&
    grep -qE '^[[:space:]]*bump:' <<<"$body"; then
    printf 'dispatch'
  else
    printf 'patch-only'
  fi
}

rows=""
present=0
findings=0
for repo in "${REPOS[@]}"; do
  dir="$(resolve_repo_dir "$REPOS_ROOT" "$repo")" || dir="$REPOS_ROOT/$repo"
  [[ -d "$dir/.git" ]] || continue
  present=$((present + 1))
  wf="$dir/.github/workflows/auto-tag.yml"
  if [[ -f "$wf" ]]; then
    t="$(_trigger "$wf")"
    b="$(_bump "$wf")"
  else
    t="absent"
    b="patch-only"
  fi
  case "$t" in own-layer | unfiltered) ;; *) findings=$((findings + 1)) ;; esac
  [[ "$b" == dispatch ]] || findings=$((findings + 1))
  # Bold the findings so a nine-row table is scannable without reading every cell.
  case "$t" in own-layer | unfiltered) tc="$t" ;; *) tc="**$t**" ;; esac
  case "$b" in dispatch) bc="$b" ;; *) bc="**$b**" ;; esac
  rows="$rows| \`${repo#dotfiles-}\` | $tc | $bc |
"
done

if ((CHECK)); then
  if ((present == 0)); then
    echo "fleet-release-triggers: no sibling repo checked out — nothing to check" >&2
    exit 0
  fi
  if ((findings)); then
    echo "fleet-release-triggers: $findings release-trigger finding(s) across $present repo(s)" >&2
    printf '%s' "$rows" | grep -F '**' >&2
    exit 1
  fi
  echo "fleet-release-triggers: every repo releases its own layer and can cut a non-patch ($present repo(s))"
  exit 0
fi

printf '| repo | trigger | bump |\n| --- | --- | --- |\n%s' "$rows"
exit 0
