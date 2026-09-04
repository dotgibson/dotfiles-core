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

# A heredoc, NOT `sed -n '2,Np'` over this file's own header. The fixed-range idiom
# breaks silently the moment the banner grows — it already did here once, during review,
# when the header gained a paragraph and --help began truncating mid-sentence. Same
# convention as scripts/check-links.sh and scripts/sync-core.sh.
usage() {
  cat <<'EOF'
usage: fleet-release-triggers.sh [--check]

The release-trigger register: for each repo in scripts/os-repos.txt, does its
.github/workflows/auto-tag.yml release that repo's OWN work, and can it cut a
deliberate non-patch bump?

  (no args)   render the register as a markdown table on stdout
  --check     exit 1 if any repo has a finding
  -h, --help  show this and exit

trigger  own-layer | unfiltered  no finding
         core-only               the tag tracks the vendored subtree, not this repo
         dispatch-only           no push trigger — nothing releases automatically
         absent                  no auto-tag.yml at all
         unparsed                the `on:` block could not be read; NOT a verdict

bump     dispatch                a workflow_dispatch input reaches the reusable
         patch-only              nothing can select a minor/major

Env: REPOS_ROOT (default: the parent of this repo)
EOF
}

HERE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

REPOS_ROOT="${REPOS_ROOT:-$(cd "$HERE/.." && pwd)}"
CHECK=0
for a in "$@"; do
  case "$a" in
  --check) CHECK=1 ;;
  -h | --help)
    usage
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

# _push_filter <file> — read ONLY the `on.push` mapping and describe its path filter.
#
# Emits one line per pattern, tagged by which key it came from:
#   P <pattern>   from `paths:`        — a watched path (an allowlist entry)
#   I <pattern>   from `paths-ignore:` — an IGNORED path (a denylist entry)
# plus a bare `PUSH` if a push trigger exists at all, and `BOTH` if the file uses both
# keys (GitHub rejects that combination; we report it rather than guess).
#
# SCOPED TO push, AND paths-ignore IS NOT paths. The first cut of this read neither.
# It scanned the whole `on:` mapping, so a `pull_request:` filter could decide a push
# verdict, and it treated `paths-ignore:` entries as watched paths — which inverts the
# meaning: `push.paths-ignore: ['core/**']` runs on everything EXCEPT the vendored
# subtree, i.e. exactly the own-layer shape, and would have been reported `core-only`.
# A register that reports the opposite of the truth is worse than one that abstains,
# so shapes this cannot read now say `unparsed` (see _trigger).
#
# A crude YAML reader on purpose, and bounded so it cannot bluff. The fleet's auto-tag.yml
# files are all one shape, and a real YAML parser is not a dependency this fleet assumes
# on every host (§ the diffutils rule). Handles both spellings in use:
#   paths: ['core/**']            (flow)
#   paths:\n      - 'core/**'     (block)
_push_filter() {
  awk '
    # Strip whole-line and trailing comments. Safe here: no watched glob in the fleet
    # contains a "#", and a "#" inside one would be a directory named "#" anyway.
    { sub(/[[:space:]]+#.*$/, ""); sub(/^[[:space:]]*#.*$/, "") }
    /^[[:space:]]*$/ { next }
    # The top-level `on:` mapping; any other column-0 key ends it.
    /^on:[[:space:]]*$/ { on = 1; next }
    on && /^[^[:space:]]/ { on = 0 }
    !on { next }
    # An event key sits one level in (`  push:`, `  workflow_dispatch:`). Entering a new
    # one leaves the previous event, which is what scopes everything below to push.
    /^[[:space:]][[:space:]][a-z_]+:/ {
      ev = $0; sub(/^[[:space:]]+/, "", ev); sub(/:.*$/, "", ev)
      rest = $0; sub(/^[[:space:]]*[a-z_]+:[[:space:]]*/, "", rest)
      inpush = (ev == "push"); indispatch = (ev == "workflow_dispatch"); inseq = 0
      if (indispatch) print "DISPATCH"
      if (inpush) {
        print "PUSH"
        # An INLINE mapping — `push: { branches: [main], paths: [core/**] }` — carries the
        # whole filter after the colon, where the block-form rules below never look. Taking
        # `next` here would discard it and _trigger would then see no path key and report
        # `unfiltered`: a green for a workflow still releasing only on Core. Flag it and let
        # _trigger abstain rather than parse flow-mapping YAML by hand.
        if (rest != "") print "INLINE"
      }
      next
    }
    # A `bump` input DECLARED under workflow_dispatch.inputs — the chooser the UI renders.
    # Forwarding `inputs.bump` without this yields an empty input and a silent `patch`.
    indispatch && /^[[:space:]]*bump:[[:space:]]*$/ { print "DBUMP" }
    !inpush { next }
    # Flow list on the key line: paths: [a, b]
    /^[[:space:]]*paths(-ignore)?:[[:space:]]*\[/ {
      tag = ($0 ~ /paths-ignore:/) ? "I" : "P"
      if (tag == "I") { seen_i = 1; print "IKEY" } else { seen_p = 1; print "PKEY" }
      # A flow sequence may run over several lines. If the closing bracket is not on this
      # line the values are elsewhere, and reading only this line yields nothing — which
      # used to leave has_paths false and report a core-only workflow as `unfiltered`.
      if ($0 !~ /\]/) print "TRUNC"
      s = $0
      sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]*["'"'"']?|["'"'"']?[[:space:]]*$/, "", parts[i])
        if (parts[i] != "") print tag " " parts[i]
      }
      inseq = 0
      next
    }
    # Block sequence under the key.
    /^[[:space:]]*paths(-ignore)?:[[:space:]]*$/ {
      curtag = ($0 ~ /paths-ignore:/) ? "I" : "P"
      if (curtag == "I") { seen_i = 1; print "IKEY" } else { seen_p = 1; print "PKEY" }
      inseq = 1
      next
    }
    inseq && /^[[:space:]]*-[[:space:]]*/ {
      s = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", s)
      gsub(/^["'"'"']|["'"'"']$/, "", s)
      if (s != "") print curtag " " s
      next
    }
    inseq && /^[[:space:]]*[^-[:space:]]/ { inseq = 0 }
    END { if (seen_p && seen_i) print "BOTH" }
  ' "$1"
}

# _trigger <file> — the trigger verdict for one auto-tag.yml.
_trigger() {
  local f="$1" line pat positives=0 outside=0 has_push=0 has_paths=0 has_ignore=0 both=0 inline=0 pkey=0 ikey=0 trunc=0
  # No `on:` block we can find at all — do not guess.
  grep -qE '^on:[[:space:]]*$' "$f" || {
    printf 'unparsed'
    return 0
  }
  while IFS= read -r line; do
    case "$line" in
    PUSH) has_push=1 ;;
    BOTH) both=1 ;;
    "P "*)
      has_paths=1
      pat="${line#P }"
      [[ "$pat" == '!'* ]] && continue # a carve-out subtracts; not a watched path
      positives=$((positives + 1))
      # Anything not rooted in the vendored subtree is this repo's own work. `core.lock`
      # is NOT own-layer: it is the sync's provenance stamp, written by the fan-out.
      [[ "$pat" =~ ^core(/|\.lock$) ]] || outside=$((outside + 1))
      ;;
    "I "*) has_ignore=1 ;;
    PKEY) pkey=1 ;;
    IKEY) ikey=1 ;;
    TRUNC) trunc=1 ;;
    INLINE) inline=1 ;;
    esac
  done < <(_push_filter "$f")
  # An inline `push:` mapping holds its filter where the block reader cannot see it.
  ((inline)) && {
    printf 'unparsed'
    return 0
  }
  # GitHub rejects paths + paths-ignore together; say so rather than pick one.
  ((both)) && {
    printf 'unparsed'
    return 0
  }
  # No push trigger: whatever else this file does, nothing releases automatically.
  ((has_push)) || {
    printf 'dispatch-only'
    return 0
  }
  # A filter KEY was present but yielded no values — a multi-line flow sequence, or a
  # shape this reader does not know. Keyed on the KEY, not on the values: keying on the
  # values is what let `paths: [` continued on the next line fall through to `unfiltered`,
  # which is a clean bill of health for a core-only workflow.
  if ((trunc)) || { ((pkey)) && ((!has_paths)); } || { ((ikey)) && ((!has_ignore)); }; then
    printf 'unparsed'
    return 0
  fi
  if ((has_ignore)); then
    # paths-ignore is a DENYLIST: the push runs on everything not listed, so this repo's
    # own work is watched by construction. (An ignore list that swallowed everything would
    # be pathological; it is not a shape the fleet has, and `**` there would be a bug the
    # author wrote deliberately.)
    printf 'own-layer'
  elif ((!has_paths)); then
    printf 'unfiltered'
  elif ((outside)); then
    printf 'own-layer'
  else
    printf 'core-only'
  fi
}

# _bump <file> — is a deliberate non-patch release reachable without editing this file?
#
# THREE things must line up, and checking fewer certifies the exact wiring this register
# claims to detect. The first cut grepped for `workflow_dispatch:` and a bare `bump:`
# anywhere in the file, which passes on both of the shapes that CANNOT cut a non-patch:
#
#   * a `bump` input declared for the dispatch UI that the job never forwards — the
#     chooser appears in Actions, and the reusable takes its own `patch` default;
#   * a job forwarding a CONSTANT (`with: { bump: patch }`) — forwarded, and unselectable.
#
# So: a workflow_dispatch must exist, and the value handed to the reusable must REFERENCE
# the dispatch input. That last part is what makes the chooser load-bearing rather than
# decorative, and it is why this greps for `inputs.bump` on the forwarding line rather
# than for `bump:` alone.
_bump() {
  local f="$1" body
  # `[[:space:]][[:space:]]*`, NOT `[[:space:]]\+`: the `\+` one-or-more is a GNU BRE
  # extension and a LITERAL plus to BSD sed, so on the macOS audit leg trailing comments
  # survived and `bump: patch  # dispatches pass inputs.bump` read as dispatch-capable —
  # a false green reachable only on one platform. PORTABILITY.md names this class.
  body="$(sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/^[[:space:]]*#.*$//' "$f")"
  # THREE facts, not two. A bare `workflow_dispatch:` with no inputs, plus a job
  # forwarding `inputs.bump`, passed the earlier check — and renders NO chooser, so every
  # dispatch resolves to the empty input and silently patches. So the `bump` input must be
  # DECLARED under workflow_dispatch.inputs (read with event scope by _push_filter, not
  # grepped for globally, since `bump:` also appears on the forwarding line), and the value
  # handed to the reusable must reference it.
  if grep -qx 'DBUMP' < <(_push_filter "$f") &&
    grep -qE '^[[:space:]]*bump:[[:space:]]*.*inputs\.bump' <<<"$body"; then
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
  # -e, not -d: a linked worktree or a submodule checkout stores .git as a FILE, and -d
  # skipped those — so a fleet of worktrees reported "no sibling repo checked out", which
  # is a green. Same convention as scripts/lib/common.sh and scripts/fleet-vocabulary.sh.
  [[ -e "$dir/.git" ]] || continue
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

# BEFORE the --check branch, deliberately. This guard used to live inside it, so the
# DEFAULT command — and `make fleet-release-triggers` — printed a header, a separator and
# no rows when no sibling was checked out: a register asserting that no repo has a
# release-trigger problem, which is indistinguishable from one that could not look. That
# is the bluff this script's header says it will not make.
if ((present == 0)); then
  echo "fleet-release-triggers: no sibling repo checked out — nothing to report on" >&2
  exit 0
fi

if ((CHECK)); then
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
