#!/usr/bin/env bash
# scripts/update-fleet-versions.sh — re-read the fleet package versions from upstream.
# ──────────────────────────────────────────────────────────────────────────────
# scripts/fleet-package-versions.tsv feeds PORTING-MATRIX.md's generated fleet-versions
# block. gen-porting-matrix.sh deliberately does NOT reach the network — it runs inside an
# offline audit — so it can only report that a row has not been re-checked lately. This is
# the half that actually looks.
#
# WHY THE VERIFIED DATE MOVES EVEN WHEN NOTHING CHANGED. A freshness bot exists to prove
# somebody looked. If <verified> only advanced on a version bump, a row that is correctly
# stable for a year would read as a year stale, the staleness notice would cry wolf on the
# rows least in need of attention, and the one signal that means "nobody has checked this"
# would be indistinguishable from "this has not moved". Confirming a value IS the work.
#
# WHAT IT WILL NOT DO. A row whose <probe> is `-`, or whose probe returns nothing, is left
# ALONE — old version, old date — and reported as needing a human. Stamping today's date on
# a row we failed to confirm would launder a failed check into a fresh one, which is the
# exact defect this file was created to stop (a claim nothing could contradict).
#
# Repology is the probe because one request answers every target for a tool. It is not
# authoritative — dotfiles-Alpine#170 caught it reporting false ABSENCES where it splits a
# project across version-named entries — which is why <source> records where a value was
# originally read and is never rewritten here. Absence is the failure mode that bites, and
# absence is exactly what this script refuses to act on: no data means no write.
#
# Usage:
#   scripts/update-fleet-versions.sh            # apply: rewrite versions + dates in place
#   scripts/update-fleet-versions.sh --check    # report only; exit 1 if any row DRIFTED
#   scripts/update-fleet-versions.sh --fleet D  # where the sibling OS clones live
#
# --fleet EXISTS BECAUSE APPLY MODE CANNOT FINISH WITHOUT THE FLEET (#917). The TSV feeds
# PORTING-MATRIX.md's generated block, so writing one without regenerating the other leaves
# the tree carrying a matrix that disagrees with its own source. gen-porting-matrix.sh reads
# the sibling checkouts and defaults to this repo's PARENT directory — which on a CI runner
# holds nothing. The flag is passed straight through.
#
# Exit codes:
#   0  every probeable row confirmed (apply: file updated; check: nothing drifted)
#   1  --check only: at least one row's upstream version differs from the recorded one
#   2  usage/environment failure, or the probe could not be reached at all
#   3  apply only: the sibling fleet is not present, so the matrix could not be regenerated
#      — DISTINCT from 2 on purpose, mirroring gen-porting-matrix.sh's own split, which
#      audit-core.sh §9h relies on to record an absent fleet as an environment skip rather
#      than a defect. Collapsing the two is what made the freshness bot red (#917).
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$HERE" || exit 2
TSV="scripts/fleet-package-versions.tsv"
API="${REPOLOGY_API:-https://repology.org/api/v1/project}"
UA="dotgibson-dotfiles-core-freshness/1.0 (+https://github.com/dotgibson/dotfiles-core)"

CHECK=0
FLEET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --check) CHECK=1 ;;
  --fleet)
    [[ -n "${2:-}" ]] || { echo "usage: $0 [--check] [--fleet DIR]" >&2; exit 2; }
    FLEET="$2"; shift
    ;;
  *)
    echo "usage: $0 [--check] [--fleet DIR]" >&2
    exit 2
    ;;
  esac
  shift
done

[[ -r "$TSV" ]] || { echo "!! cannot read $TSV" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "!! curl is required" >&2; exit 2; }

say() { printf ':: %s\n' "$*"; }
today="$(date -u +%Y-%m-%d)"

# One request per TOOL, not per row: Repology answers every repository in a single
# document, so 16 rows cost one call. Cached in a temp dir for the life of the run.
CACHE="$(mktemp -d)" || exit 2
trap 'rm -rf "$CACHE"' EXIT

fetch_tool() { # <tool> — cache the project document; empty file on failure
  local tool="$1"
  local dest="$CACHE/$tool.json"
  [[ -s "$dest" ]] && return 0
  curl -fsSL --max-time 45 -H "User-Agent: $UA" "$API/$tool" -o "$dest" 2>/dev/null || : >"$dest"
  [[ -s "$dest" ]]
}

# The newest version Repology lists for <repo>, ignoring rolling/incoming statuses that do
# not represent what `install` would actually get.
probe_version() { # <tool> <repo>
  local tool="$1" repo="$2"
  [[ -s "$CACHE/$tool.json" ]] || return 1
  python3 - "$CACHE/$tool.json" "$repo" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
vs = {p.get("version") for p in d
      if p.get("repo") == sys.argv[2]
      and p.get("status") in ("newest", "unique", "outdated", "legacy")
      and p.get("version")}
if not vs:
    sys.exit(1)


def key(v):
    return [int(x) if x.isdigit() else 0 for x in v.replace("-", ".").split(".")]


print(sorted(vs, key=key)[-1])
PY
}

drift=0 confirmed=0 unconfirmed=0
declare -a NEW_LINES=() REPORT=()

while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]]; then
    NEW_LINES+=("$line"); continue
  fi
  IFS=$'\t' read -r rt tool target ver vdate src probe <<<"$line"
  if [[ "$rt" != "ver" ]]; then NEW_LINES+=("$line"); continue; fi

  if [[ -z "${probe:-}" || "$probe" == "-" ]]; then
    unconfirmed=$((unconfirmed + 1))
    REPORT+=("  ?  $tool/$target — no probe; confirm by hand against $src (recorded $ver, $vdate)")
    NEW_LINES+=("$line"); continue
  fi

  fetch_tool "$tool" || true
  if ! upstream="$(probe_version "$tool" "$probe")"; then
    unconfirmed=$((unconfirmed + 1))
    REPORT+=("  ?  $tool/$target — probe '$probe' returned nothing; NOT stamped (recorded $ver, $vdate)")
    NEW_LINES+=("$line"); continue
  fi

  if [[ "$upstream" == "$ver" ]]; then
    confirmed=$((confirmed + 1))
    REPORT+=("  ok $tool/$target — still $ver")
    NEW_LINES+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$rt" "$tool" "$target" "$ver" "$today" "$src" "$probe")")
  else
    drift=$((drift + 1))
    REPORT+=("  ~> $tool/$target — $ver → $upstream")
    NEW_LINES+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$rt" "$tool" "$target" "$upstream" "$today" "$src" "$probe")")
  fi
done <"$TSV"

printf '%s\n' "${REPORT[@]}"
say "confirmed=$confirmed drifted=$drift unconfirmed=$unconfirmed"

# Nothing was reachable at all — a network or API failure, not a fleet finding. Say so
# rather than reporting "all current", which is what an empty drift count would imply.
if ((confirmed == 0 && drift == 0)); then
  echo "!! no row could be probed — treating this as an environment failure, not a clean run" >&2
  exit 2
fi

if ((CHECK)); then
  ((drift == 0)) || { say "re-run without --check to write these, then commit the regenerated matrix"; exit 1; }
  exit 0
fi

# THE TSV IS WRITTEN BEHIND A BACKUP, and restored if the matrix cannot follow it. The two
# files are one artifact: PORTING-MATRIX.md's fleet-versions block is generated FROM this
# TSV, so a tree carrying a new TSV and an old matrix is drift that audit-core.sh §9h reds
# the moment anyone runs it beside the fleet. Before #917 the write happened first and the
# failure exited straight out, leaving exactly that state behind.
_ufv_backup="$(mktemp "${TMPDIR:-/tmp}/fleet-tsv.XXXXXX")" || { echo "!! cannot stage a backup" >&2; exit 2; }
cp -- "$TSV" "$_ufv_backup" || { echo "!! cannot stage a backup" >&2; exit 2; }
printf '%s\n' "${NEW_LINES[@]}" >"$TSV"
say "wrote $TSV"

_ufv_args=()
[[ -n "$FLEET" ]] && _ufv_args=(--fleet "$FLEET")
./scripts/gen-porting-matrix.sh ${_ufv_args[@]+"${_ufv_args[@]}"}
_ufv_rc=$?
if ((_ufv_rc == 3)); then
  # The fleet is absent — an ENVIRONMENT fact, not a defect in this tree. Put the TSV back
  # so nothing half-applied is left to commit, and say which half could not run.
  cp -- "$_ufv_backup" "$TSV"; rm -f -- "$_ufv_backup"
  echo "!! the sibling fleet is not checked out — the matrix could not be regenerated, so $TSV was left unchanged" >&2
  echo "   clone the fleet beside this repo, or pass --fleet DIR" >&2
  exit 3
elif ((_ufv_rc != 0)); then
  cp -- "$_ufv_backup" "$TSV"; rm -f -- "$_ufv_backup"
  echo "!! regeneration failed (rc=$_ufv_rc) — $TSV was left unchanged" >&2
  exit 2
fi
rm -f -- "$_ufv_backup"
