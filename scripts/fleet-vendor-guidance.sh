#!/usr/bin/env bash
# scripts/fleet-vendor-guidance.sh — the vendoring-hint x repo register
# ──────────────────────────────────────────────────────────────────────────────
# DOES EVERY REPO TELL A USER THE SAME, CURRENT TRUTH ABOUT VENDORING core/? Eight of
# nine did not. Every OS repo prints a hint when core/ is missing or half-vendored, and
# seven of them said this:
#
#     git subtree add  --prefix=core <remote> main --squash   # first time
#     git subtree pull --prefix=core <remote> main --squash   # to update
#
# Both lines are wrong, and they fire at the worst possible moment — the user is already
# looking at a broken clone and trying to repair it:
#
#   * `main` is not what the fan-out pins. Every repo is pinned to the exact commit a
#     RELEASED TAG points at, and core.lock records that commit. A main-vendored tree is
#     not that commit, so core-integrity reports a freshly built repo as TAMPERED before
#     it has done anything wrong.
#   * `git subtree pull` moves core/ without moving core.lock — the stale-lock path
#     VENDORING.md warns about — and merges upstream's WHOLE tree, which since #676 is not
#     what a vendored core/ is (the vendor set is core.manifest ∪ core.vendor).
#
# THE FIX EXISTED THE WHOLE TIME AND DID NOT PROPAGATE, which is the actual finding here.
# dotfiles-MacBook has carried the right warning — "take the RELEASED tag (never main, or
# core-integrity reports the fresh subtree as TAMPERED)" — for a long time. Nothing read
# the other eight repos to notice they disagreed, so one repo was right and eight were
# wrong for as long as it took someone to hit it. Then MacBook's own hint went stale at
# the v4 major against a v7 fleet, which lands in exactly the TAMPERED state its warning
# exists to prevent: correct advice, defeated by a hardcoded number nothing checked.
#
# So this register asserts two different things, and the second is the one that keeps
# working after today: the guidance must be RIGHT (a tag, not a branch; no subtree pull
# for core/), and it must be CURRENT (the tag's major matches the Core being shipped).
#
# DERIVED, NOT HAND-MAINTAINED, like the other registers: the expected major comes from
# this repo's own core.version at run time, so the day Core cuts v8 every stale `v7` hint
# in the fleet reports itself instead of waiting to be discovered.
#
# SCOPED TO core/, DELIBERATELY. `git subtree` is not banned fleet-wide and this register
# must not read as if it were: dotfiles-Offense vendors a SECOND tree, offensive/companion
# from dotgibson/htpx, which genuinely is a subtree and whose scripts/sync-companion.sh
# runs `git subtree pull --prefix=offensive/companion` on purpose. Only `--prefix=core`
# (and `--prefix core`) is this register's business. Everything else is another tree's
# contract, and flagging it would train people to ignore the gate.
#
# SCOPED TO NAMED FILES, for a duller reason: this repo's own history and test fixtures
# are full of deliberately malformed refs (`refs/tags/v5.3.0-rc1`, `.../v5.3.0^foo`, and
# friends in scripts/test/21-guards.sh) that exist to exercise a parser. A tree-wide grep
# reports every one of them as fleet drift. The file list below is the guidance a user can
# actually be shown; CHANGELOG.md and the fixtures are not that.
#
# ABSENCE IS REPORTED, NOT FAILED. A repo with no vendoring hint at all shows as `none`.
# Requiring one would be inventing a contract this register was not asked to enforce —
# and the register's value is in what the hints SAY, not in mandating that they exist.
#
# Usage:
#   ./scripts/fleet-vendor-guidance.sh            # markdown table on stdout
#   ./scripts/fleet-vendor-guidance.sh --check    # exit 1 if any hint is wrong or stale
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
    sed -n '2,57p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "unknown arg: $a" >&2
    exit 2
    ;;
  esac
done

# The files a user can actually be shown vendoring guidance from. Named, not globbed:
# see SCOPED TO NAMED FILES above. `.github/workflows/core-drift.yml` earns its place —
# dotfiles-Defense's copy filed a recurring issue telling maintainers to run the very
# `git subtree pull` core.lock forbids, and no gate saw it because it was in a workflow
# rather than in bootstrap.sh.
GUIDANCE_FILES=(
  bootstrap.sh
  SETUP.md
  VENDORING.md
  Makefile
  .github/workflows/core-drift.yml
)

# The expected major, DERIVED from the Core this repo ships. Same posture as the fleet
# list (#669): an unreadable version is a loud stop, never a register that quietly checks
# nothing — "every hint is current" against an empty expectation is the green-because-
# absent result audit-core.sh's skip_env exists to avoid.
CORE_VER="$(tr -d '[:space:]' <"$HERE/core.version" 2>/dev/null || true)"
CORE_MAJOR="${CORE_VER%%.*}"
if [[ ! "$CORE_MAJOR" =~ ^[0-9]+$ ]]; then
  fail "core.version unreadable or not a version ('${CORE_VER:-}') — cannot derive the expected tag major"
  exit 2
fi

load_os_repos || {
  fail "$CORE_OS_REPOS_ERR — cannot enumerate the fleet to report on"
  exit 2
}
# Core itself is a row: VENDORING.md and sync-core.sh carry the canonical `refs/tags/vN`
# that every OS repo copies, so a stale hint HERE seeds the next round of fleet drift.
REPOS=("$(basename "$HERE")" "${CORE_OS_REPOS[@]}")

# _hints <dir> — emit one `file:line:text` per core/-scoped `git subtree` invocation.
#
# Matches a COMMAND, not prose. The repos discuss `git subtree pull` constantly in
# comments and docs ("`git subtree pull` is retired", "…moves core/ but not core.lock"),
# and every one of those mentions is correct writing that must not be flagged. The
# discriminator is a --prefix naming core: a sentence about subtree pull has no --prefix,
# a command has one.
_hints() {
  local dir="$1" f
  for f in "${GUIDANCE_FILES[@]}"; do
    [[ -f "$dir/$f" ]] || continue
    grep -nE 'git subtree (add|pull)[^|;&]*--prefix[= ]"?core"?([[:space:]]|$)' "$dir/$f" 2>/dev/null |
      sed "s|^|$f:|"
  done
}

# _verdict <hint-text> — classify ONE invocation. Echoes `ok` or a finding label.
_verdict() {
  local t="$1" ref=""
  # `git subtree pull` on core/ is retired outright (#676): it cannot produce the filtered
  # vendor set, and it moves core/ without core.lock. No ref makes it right, so this is
  # decided before the ref is even looked at.
  [[ "$t" =~ git[[:space:]]+subtree[[:space:]]+pull ]] && {
    printf 'subtree-pull'
    return
  }
  # The ref is the token after the remote. Placeholders (<remote>, $VAR, ~/path, a URL)
  # vary; the ref is the one that looks like a ref, so match it directly rather than
  # counting words — `--prefix=core <a> <b> --squash` and `--prefix core <a> <b>` differ
  # in arity and both appear in the fleet.
  if [[ "$t" =~ refs/tags/v([0-9]+) ]]; then
    ref="${BASH_REMATCH[1]}"
    if [[ "$ref" == "$CORE_MAJOR" ]]; then printf 'ok'; else printf 'stale-v%s' "$ref"; fi
    return
  fi
  # A tag that is not a vN tag at all (a point tag, a placeholder like vN) — current or
  # not, it is not the moving major tag VENDORING.md prescribes, so it will not track the
  # v-series and cannot be judged current. Named separately from `branch` so the fix is
  # obvious from the label.
  [[ "$t" =~ refs/tags/ ]] && {
    printf 'non-major-tag'
    return
  }
  printf 'branch'
}

rows=""
findings=0
present=0
# Siblings counted SEPARATELY from Core's own row. Core is always present — it is the repo
# the script lives in — so a `present == 0` test could never fire, and a run with no fleet
# checked out would report "every hint is current" off Core's single row. That is the
# green-because-absent result audit-core.sh's skip_env exists to avoid, and it would have
# silently disarmed this gate on every CI box in the fleet.
siblings=0
for repo in "${REPOS[@]}"; do
  if [[ "$repo" == "$(basename "$HERE")" ]]; then dir="$HERE"; else
    dir="$(resolve_repo_dir "$REPOS_ROOT" "$repo")" || dir="$REPOS_ROOT/$repo"
  fi
  # `-e`, not `-d`: .git is a FILE in a worktree checkout.
  [[ -e "$dir/.git" ]] || continue
  present=$((present + 1))
  [[ "$dir" == "$HERE" ]] || siblings=$((siblings + 1))

  hints="$(_hints "$dir")"
  if [[ -z "$hints" ]]; then
    rows="$rows| \`${repo#dotfiles-}\` | — | none |
"
    continue
  fi

  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    where="${h%%:*}"
    rest="${h#*:}"
    lineno="${rest%%:*}"
    text="${rest#*:}"
    v="$(_verdict "$text")"
    if [[ "$v" == ok ]]; then
      rows="$rows| \`${repo#dotfiles-}\` | \`$where:$lineno\` | ok |
"
    else
      rows="$rows| \`${repo#dotfiles-}\` | \`$where:$lineno\` | **$v** |
"
      findings=$((findings + 1))
    fi
  done <<<"$hints"
done

if ((CHECK)); then
  if ((siblings == 0)); then
    echo "fleet-vendor-guidance: no sibling repo checked out — nothing to check" >&2
    exit 0
  fi
  if ((findings)); then
    echo "fleet-vendor-guidance: $findings vendoring hint(s) wrong or stale (expected refs/tags/v$CORE_MAJOR)" >&2
    printf '%s' "$rows" | grep -F '**' >&2
    exit 1
  fi
  echo "fleet-vendor-guidance: every core/ vendoring hint pins refs/tags/v$CORE_MAJOR and none uses subtree pull ($present repo(s))"
  exit 0
fi

# shellcheck disable=SC2016  # the backticks are markdown code spans for the table header,
# not command substitution — single quotes are what keeps them literal.
printf '| repo | hint | verdict (expected `refs/tags/v%s`) |\n| --- | --- | --- |\n%s' "$CORE_MAJOR" "$rows"
exit 0
