#!/usr/bin/env bash
# scripts/fleet-gate-delta.sh — fail a Core PR on the fleet-gate failures IT introduces.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS (#1240, after #1239). The audit's fleet-wide gates (§5f, §9m-§9p, theme and
# desktop-parity drift, …) read the sibling repos from `$HERE/..`. A Core PR's CI checks out
# Core alone, so every one of them `skip_env`s there and the PR merges green. The first run
# that could see a sibling break was sync-fanout's pre-fan-out audit, AFTER the tag: #1210's
# correct Kali matrix cells merged green and then refused the whole v7.14.0 fan-out on
# dotfiles-Debian's stale TOOLS_OPTIN.
#
# WHY A DELTA, NOT THE BARE AUDIT. This runs as a REQUIRED check, and the siblings move on
# their own. A bare `--require-siblings` run would block every Core PR — a zsh fix, a typo —
# the moment any sibling drifted, for a failure the PR did not cause and often cannot fix.
# So the audit runs twice, at the PR's base and at its head, both against the SAME sibling
# clones, and only a ✗ block the head has and the base lacks fails the check. A failure that
# is already on main is reported as a warning: real, but not this PR's to carry. What main
# itself is carrying is /release-readiness's to hold before a tag.
#
# WHAT "A BLOCK" IS. A `✗` line from fail() plus the four-space-indented fail_detail lines
# under it, compared as one unit. That is deliberately strict: a PR that turns one repo's
# existing finding into two repos' changes the block, and that is a new failure.
# Paths are normalised first. The two runs live in different directories, and a gate that
# names its own checkout would otherwise make every finding look new.
#
# LAYOUT. Run it from a Core checkout whose PARENT holds the fleet (scripts/os-repos.txt,
# plus dotfiles-Windows for the theme and parity gates), which is how the gates find them.
# The base is checked out as a detached worktree BESIDE the fleet, so its `$HERE/..` is the
# same fleet. It is removed on exit.
#
# Usage:
#   fleet-gate-delta.sh --base REF
#       audit (--quiet --scope none --require-siblings) at REF and at HEAD; judge the delta.
#       In a pull_request job HEAD is the merge commit, so REF is `HEAD^1`.
#   fleet-gate-delta.sh --compare BASE_OUT HEAD_OUT [BASE_CORE HEAD_CORE]
#       the pure judgement over two captured audit outputs; BASE_CORE/HEAD_CORE are the
#       checkout paths to normalise away. This is the half the test suite drives.
#
# Exit: 0 nothing new · 1 the PR introduces a fleet-gate failure · 2 usage error, or the
# head run could not see its siblings (a gate that did not run cannot be judged).
set -uo pipefail

_fgd_die() { # _fgd_die <status> <msg>
  printf 'fleet-gate-delta: %s\n' "$2" >&2
  exit "$1"
}

# _fgd_blocks <audit-output> <core-path> — one line per ✗ block, normalised, sorted, unique.
# The block's lines are joined with " ¦ " so a block compares (and sorts) as one record.
_fgd_blocks() {
  awk -v p="${2:-}" '
    function norm(s,   i) {
      if (p != "") while ((i = index(s, p)) > 0) s = substr(s, 1, i - 1) "<core>" substr(s, i + length(p))
      return s
    }
    function flush() { if (blk != "") print blk; blk = "" }
    /^✗ / { flush(); blk = norm($0); next }
    blk != "" && /^    / { blk = blk " ¦ " norm($0); next }
    { flush() }
    END { flush() }
  ' "$1" | LC_ALL=C sort -u
}

# _fgd_show <prefix> <blocks> — print blocks back as lines, the first under <prefix>.
_fgd_show() {
  printf '%s\n' "$2" | awk -v pre="$1" 'NF {
    n = split($0, part, / ¦ /)
    for (i = 1; i <= n; i++) print (i == 1 ? pre : "") part[i]
  }'
}

# _fgd_compare <base-out> <head-out> [base-core head-core] — the judgement. Returns 0/1.
_fgd_compare() {
  local base head new old
  # An audit that died before its summary printed no ✗ lines either, and a delta over two
  # empty outputs is a vacuous green. Only a run that reached its summary can be judged.
  grep -q 'audit summary' "$2" ||
    _fgd_die 2 "the head audit did not reach its summary (it died early), so there is nothing to judge"
  grep -q 'audit summary' "$1" ||
    _fgd_die 2 "the base audit did not reach its summary (it died early), so there is nothing to compare against"
  printf 'base: %s\nhead: %s\n' "$(grep -m1 -E 'pass [0-9]+ ' "$1" | sed 's/^ *//')" \
    "$(grep -m1 -E 'pass [0-9]+ ' "$2" | sed 's/^ *//')"
  base="$(_fgd_blocks "$1" "${3:-}" | awk NF)"
  head="$(_fgd_blocks "$2" "${4:-}" | awk NF)"
  new="$(LC_ALL=C comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$head") | awk NF)"
  old="$(LC_ALL=C comm -12 <(printf '%s\n' "$base") <(printf '%s\n' "$head") | awk NF)"

  if [ -n "$old" ]; then
    printf 'Already failing on the base: not this PR'"'"'s to fix, and /release-readiness holds a tag on it.\n'
    _fgd_show '  ' "$old"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      printf '%s\n' "$old" | awk 'NF { sub(/ ¦ .*/, ""); print "::warning title=fleet gate already red on the base::" $0 }'
    fi
  fi
  if [ -z "$new" ]; then
    printf 'fleet-gate-delta: this PR introduces no fleet-gate failure against the siblings.\n'
    return 0
  fi
  printf '\nThis PR introduces %d fleet-gate failure(s) against the sibling repos:\n' \
    "$(printf '%s\n' "$new" | wc -l | tr -d ' ')" >&2
  _fgd_show '  ' "$new" >&2
  cat >&2 <<'EOF'

These gates read the sibling repos, which a Core PR's own CI never checks out. Uncaught here,
they would first fail in sync-fanout's pre-fan-out audit, after the tag (#1239). The fix usually
lands in the named sibling: merge that PR FIRST, then re-run this check. That is the same
sibling-first order as the fleet ratchets. If the gate itself is wrong, fix the gate in this PR.
EOF
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '%s\n' "$new" | awk 'NF { sub(/ ¦ .*/, ""); print "::error title=new fleet-gate failure::" $0 }'
  fi
  return 1
}

_fgd_run() { # _fgd_run <base-ref>
  local ref="$1" here fleet base_dir out
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || _fgd_die 2 "cannot resolve the Core checkout"
  fleet="$(cd "$here/.." && pwd)"
  git -C "$here" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 ||
    _fgd_die 2 "base ref '$ref' does not resolve to a commit (a shallow checkout? use fetch-depth: 0)"

  out="$(mktemp -d)" || _fgd_die 2 "mktemp failed"
  base_dir="$fleet/.core-base-$$"
  # shellcheck disable=SC2064 # expand now: the paths are fixed for this run
  trap "git -C '$here' worktree remove --force '$base_dir' >/dev/null 2>&1; rm -rf '$out'" EXIT
  git -C "$here" worktree add -q --detach "$base_dir" "$ref" >/dev/null 2>&1 ||
    _fgd_die 2 "could not check out '$ref' beside the fleet at $base_dir"

  printf 'fleet-gate-delta: auditing the base (%s) against %s\n' \
    "$(git -C "$here" rev-parse --short "$ref")" "$fleet"
  (cd "$base_dir" && ./scripts/audit-core.sh --quiet --scope none --require-siblings --color never) \
    >"$out/base.txt" 2>&1
  printf 'fleet-gate-delta: auditing the head (%s)\n' "$(git -C "$here" rev-parse --short HEAD)"
  (cd "$here" && ./scripts/audit-core.sh --quiet --scope none --require-siblings --color never) \
    >"$out/head.txt" 2>&1

  # A gate that could not read its sibling did not run, and a check that did not run
  # cannot vouch for this PR. Say which, and fail as unjudgeable rather than green.
  if grep -q 'audit FAILED (--require-siblings' "$out/head.txt"; then
    sed -n '/check(s) SKIPPED/,/FLEET-WIDE gates/p' "$out/head.txt" >&2
    _fgd_die 2 "the head audit could not see every sibling: clone the fleet beside Core"
  fi
  _fgd_compare "$out/base.txt" "$out/head.txt" "$base_dir" "$here"
}

case "${1:-}" in
--base)
  [ $# -eq 2 ] || _fgd_die 2 "usage: fleet-gate-delta.sh --base REF"
  _fgd_run "$2"
  ;;
--compare)
  [ $# -eq 3 ] || [ $# -eq 5 ] ||
    _fgd_die 2 "usage: fleet-gate-delta.sh --compare BASE_OUT HEAD_OUT [BASE_CORE HEAD_CORE]"
  _fgd_compare "$2" "$3" "${4:-}" "${5:-}"
  ;;
-h | --help)
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
  ;;
*) _fgd_die 2 "usage: fleet-gate-delta.sh --base REF | --compare BASE_OUT HEAD_OUT [BASE_CORE HEAD_CORE]" ;;
esac
