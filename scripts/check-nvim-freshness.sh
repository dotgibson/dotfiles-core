#!/usr/bin/env bash
# scripts/check-nvim-freshness.sh — is nvim.lock N releases behind dotfiles-nvim?
# ──────────────────────────────────────────────────────────────────────────────
# THE NUDGE THAT KEEPS "AT CORE'S PACE" FROM MEANING "NEVER". NVIM-SPLIT-PROPOSAL.md §7(3)
# decided that Core adopts the editor with a Core release, not on every nvim release —
# otherwise the churn the extraction removed comes straight back through the lock. That is
# the right call and it has one failure mode: a pin nobody is measuring stops moving, and
# the fleet quietly ships a year-old editor while every gate stays green.
#
# So this MEASURES the lag and reports it. It opens no PR and bumps nothing: the remedy is
# `scripts/sync-nvim.sh --ref <tag>` at release time, by a human who is cutting anyway.
# It replaces the freshness job's old nvim-plugins leg, which rolled plugin pins here —
# that work moved to dotfiles-nvim, which has a Neovim to test them against.
#
# It counts RELEASES, not commits, because that is the unit §7(3) speaks in and the unit a
# release-time decision is made in. "17 commits behind" says nothing about whether a bump
# is due; "2 releases behind" does.
#
# Exit codes — the contract, matching dotfiles-Offense/test/check-companion-freshness.sh:
#   0  current (or an environment SKIP: upstream unreachable)
#   1  a hard failure — a malformed or unreadable nvim.lock
#   2  behind — a NUDGE, deliberately distinct from the exit-1 failures, so a scheduled
#      run can render "you have work to do" differently from "this gate is broken"
#
# UNREACHABLE IS NOT DRIFT. A scheduled or offline run must say it could not look rather
# than imply the pin is fine — the rule audit-core.sh's sibling checks follow. A gate that
# reports green because it could not reach the network is worse than no gate.
#
# NO `sort -V`: it is GNU-only in practice (scripts/research/verify-atuin-guard.sh:623 says
# so and pays the same cost), and this must behave identically on macOS. The ordering below
# is a three-field numeric sort, which is POSIX.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

LOCK="$HERE/nvim.lock"

# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"

die() { printf '%s✗%s check-nvim-freshness: %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

if [[ ! -r "$LOCK" ]]; then
  die "nvim.lock missing or unreadable — nvim/ is vendored from dotgibson/dotfiles-nvim and this is the file that says which revision"
fi

lock_field() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$LOCK" 2>/dev/null | head -n1; }

repo="$(lock_field nvim_repo)"
rec_sha="$(lock_field nvim_sha)"
rec_tag="$(lock_field nvim_tag)"
[[ -n "$repo" ]] || die "nvim_repo missing from nvim.lock"
[[ -n "$rec_sha" ]] || die "nvim_sha missing from nvim.lock"
[[ "$rec_sha" =~ ^[0-9a-f]{40}$ ]] || die "nvim.lock has an invalid nvim_sha ($rec_sha) — expected a 40-char hex SHA"

UPSTREAM="${NVIM_UPSTREAM:-https://github.com/$repo.git}"

# `--` forces end-of-options: UPSTREAM is overridable, and ls-remote would treat a
# leading-dash value as an option (option-injection guard). GIT_TERMINAL_PROMPT=0 keeps it
# non-interactive — never block a scheduled run waiting on a credential prompt.
tags_raw="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs -- "$UPSTREAM" 2>/dev/null)"
if [[ -z "$tags_raw" ]]; then
  printf '%s–%s check-nvim-freshness: SKIPPED — cannot reach %s (offline/restricted?)\n' \
    "$c_yel" "$c_rst" "$UPSTREAM" >&2
  exit 0
fi

# Strict `vN.N.N` only. The `-` exclusion drops prereleases, and the moving major alias
# (`v1`) has too few fields to match — the same filter fleet-drift.sh:125-141 and
# auto-tag.sh:177-179 apply, for the same reason: a pin must never be measured against a
# tag that moves out from under it.
tags="$(printf '%s\n' "$tags_raw" |
  sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' |
  sort -t. -k1,1n -k2,2n -k3,3n)"

if [[ -z "$tags" ]]; then
  printf '%s–%s check-nvim-freshness: SKIPPED — %s publishes no vN.N.N release tags yet\n' \
    "$c_yel" "$c_rst" "$repo" >&2
  exit 0
fi

latest="$(printf '%s\n' "$tags" | tail -n1)"
rec_ver="${rec_tag#v}"

# Behind-count = releases strictly newer than the recorded one. Comparing on the SORTED
# list rather than by string equality is what makes a pin at an unknown or missing tag
# degrade sanely: it counts every release, which reads as "very behind" and prompts the
# same action, instead of silently reporting current.
if [[ -n "$rec_ver" ]]; then
  behind="$(printf '%s\n' "$tags" | awk -v r="$rec_ver" '
    function cmp(a, b,   x, y, i) {
      split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 3; i++) {
        if ((x[i] + 0) > (y[i] + 0)) return 1
        if ((x[i] + 0) < (y[i] + 0)) return -1
      }
      return 0
    }
    cmp($0, r) > 0 { n++ }
    END { print n + 0 }')"
else
  behind="$(printf '%s\n' "$tags" | wc -l | tr -d '[:space:]')"
fi

if [[ "$behind" -eq 0 ]]; then
  printf '%s✓%s nvim.lock is current with %s (%s, %s)\n' \
    "$c_grn" "$c_rst" "$repo" "${rec_tag:-untagged}" "${rec_sha:0:12}"
  exit 0
fi

# Behind. Report the gap and the remediation, then exit 2 so a scheduled run surfaces it as
# a nudge — distinct from the exit-1 hard failures above.
{
  printf '%s•%s nvim.lock is BEHIND by %s release(s)\n' "$c_yel" "$c_rst" "$behind"
  printf '    vendored: %s (%s)\n' "${rec_tag:-untagged}" "${rec_sha:0:12}"
  printf '    upstream: v%s\n' "$latest"
  printf '    update (at the NEXT Core release — NVIM-SPLIT-PROPOSAL.md §7(3)):\n'
  printf '      scripts/sync-nvim.sh --ref v%s\n' "$latest"
  printf '      git add nvim nvim.lock && git commit   # both in ONE commit, or audit §9q reds\n'
} >&2
exit 2
