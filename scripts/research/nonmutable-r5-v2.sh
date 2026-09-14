#!/usr/bin/env bash
# scripts/research/nonmutable-r5-v2.sh — R5's second bootc ask (NON-MUTABLE-HOST-PROPOSAL.md
# §5 R5, #1004). Runs on the guest AFTER the workflow has pushed a v2 image to the runner's
# registry under the tag the guest is switched to: with the registry now newer than the
# booted deployment, what do the upgrade checks say, as the user and as root, at what cost —
# and does `rpm-ostree upgrade` then stage it (STAGED flips to 77)?
#
#   nonmutable-r5-v2.sh [--out FILE]      (appends a "## 6." section; needs sudo -n)
set -u
out="/home/research/r5-bootc.md"
[[ "${1:-}" == --out ]] && out="$2"
# shellcheck disable=SC2016  # the backticks are markdown, not expansion
row() { # <user|root> <cmd…>
  local w="$1"; shift
  local s e rc o
  s=$(date +%s%3N)
  if [[ "$w" == root ]]; then o=$(sudo -n "$@" 2>&1); rc=$?; else o=$("$@" 2>&1); rc=$?; fi
  e=$(date +%s%3N)
  printf '| `%s` | %s | **%s** | %s ms | `%s` |\n' "$*" "$w" "$rc" "$((e - s))" "$(printf '%s' "$o" | head -3 | tr '\n' ' ' | cut -c1-170)"
}
{
  echo; echo '## 6. After a v2 image was pushed to the registry under the same tag'; echo
  echo '| what | as | exit | cost | first lines |'; echo '| --- | --- | --- | --- | --- |'
  row root rpm-ostree cleanup -p
  row user rpm-ostree upgrade --check
  row root rpm-ostree upgrade --check
  row root rpm-ostree upgrade --check --unchanged-exit-77
  row root bootc upgrade --check
  row user rpm-ostree status --pending-exit-77
  row root rpm-ostree upgrade
  row user rpm-ostree status --pending-exit-77
  row root rpm-ostree upgrade --check --unchanged-exit-77
  row root bootc upgrade --check
} >>"$out"
echo "appended: $out"
