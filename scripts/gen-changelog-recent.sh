#!/usr/bin/env bash
# scripts/gen-changelog-recent.sh — render the vendored CHANGELOG digest (#680).
# ──────────────────────────────────────────────────────────────────────────────
# `core whatsnew` needs the changelog ON A BOX, offline. CHANGELOG.md itself is not
# vendored and will not be: at ~707 KB it was 36% of the whole vendored tree — larger than
# all of zsh/ — which is exactly what #676/#784 measured and dropped. This renders the last
# RECENT_RELEASES released sections (~49 KB, ~4%) into CHANGELOG.recent.md, which
# core.vendor ships into every OS repo's core/.
#
# GENERATED AND COMMITTED. The file is an ordinary tracked blob at the pinned commit, so
# scripts/lib/core-vendor.sh filters it like any other path and core-integrity.sh needs
# ZERO special-casing. #680 pre-rejected a truncated changelog on the grounds that
# "core-integrity would have to special-case it" — true against the old whole-tree
# comparison, obsolete against #784's derive-from-the-pinned-commit design.
#
# [Unreleased] IS EXCLUDED, for two reasons. (1) A box runs a RELEASED core.version, so an
# [Unreleased] entry describes code it does not have — rendering it would make the verb
# lie. (2) It keeps the freshness gate cheap: released sections never change, so this file
# changes exactly once per release and has exactly ONE regeneration site (release.sh).
# Including [Unreleased] would make the digest stale on every changelog bullet — i.e. on
# nearly every PR — and audit §9e would red for everyone.
#
# DETERMINISTIC BY CONSTRUCTION: no date, no $RANDOM, no git, no $USER, no
# locale-sensitive sort. audit-core.sh §9e re-renders and cmp's against the committed file,
# so any non-determinism here reads as PERMANENT staleness that no regeneration can clear.
#
# Usage:
#   ./scripts/gen-changelog-recent.sh                      # rewrite CHANGELOG.recent.md
#   ./scripts/gen-changelog-recent.sh --stdout             # render to stdout, write nothing
#   ./scripts/gen-changelog-recent.sh --check              # 0 = fresh, 1 = stale/missing
#   ./scripts/gen-changelog-recent.sh --source F --out G   # fixture-drivable (the tests)
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"

# HOW MANY RELEASES, and why this number. sync-fanout.yml fires on EVERY Core tag, so a
# repo that syncs each release only ever needs a one-release delta. Eight covers a box that
# missed up to SEVEN CONSECUTIVE fan-outs; past that, fleet-drift.sh is already reporting it
# red and the answer is `make sync`, not a longer digest. It is a RELEASE COUNT, not a
# calendar window — at the observed cadence eight releases can be four days or four months,
# and the fan-out count is what actually bounds what a box has missed. Size seconds it:
# 8 sections ≈ 49 KB ≈ 4% of the vendored tree, against CHANGELOG.md's ~707 KB ≈ 36%.
#
# NOT an env var, deliberately: a per-invocation N would make the COMMITTED file's content
# depend on who ran the generator, and §9e asserts byte-identity against a fresh render.
RECENT_RELEASES=8

SOURCE="CHANGELOG.md"
OUT="CHANGELOG.recent.md"
MODE="write"

usage() {
  cat <<'EOF'
usage: gen-changelog-recent.sh [--stdout|--check] [--source FILE] [--out FILE]

Render the last 8 released CHANGELOG.md sections into CHANGELOG.recent.md — the digest
core.vendor ships to every OS repo so `core whatsnew` can answer offline.

  (no flag)        rewrite --out
  --stdout         render to stdout; write nothing
  --check          exit 0 if --out matches a fresh render, 1 if it is stale/missing
  --source FILE    read this changelog instead of CHANGELOG.md
  --out FILE       write/compare this path instead of CHANGELOG.recent.md
EOF
}

# Parse EVERY argument: an unknown flag or a stray operand is REJECTED, never silently
# ignored (the release.sh / audit-core.sh house rule).
while (($#)); do
  case "$1" in
  --stdout) MODE="stdout" ;;
  --check) MODE="check" ;;
  --source)
    SOURCE="${2:-}"
    shift
    ;;
  --out)
    OUT="${2:-}"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    fail "gen-changelog-recent.sh: unknown argument: $1"
    usage >&2
    exit 2
    ;;
  esac
  shift
done

[[ -n "$SOURCE" && -r "$SOURCE" ]] || {
  fail "gen-changelog-recent.sh: source changelog '${SOURCE:-}' missing or unreadable"
  exit 1
}
[[ -n "$OUT" ]] || {
  fail "gen-changelog-recent.sh: --out needs a path"
  exit 1
}

# _render → the whole digest on stdout. ONE renderer behind all three modes, so the bytes
# audit §9e compares and the bytes release.sh commits cannot diverge.
#
# THE SLICER is .github/workflows/release.yml's proven shape, generalised from one section
# to N. `^## +\[v?[0-9]` matches a RELEASE heading only, so `## [Unreleased]` is skipped
# with no special case and `f` never turns on until the first real release. Verified safe
# against the real file: CHANGELOG.md carries ZERO code fences, one H1, and no
# link-reference definitions, so a column-0 `## [` is unambiguously a section boundary.
_render() {
  awk -v n="$RECENT_RELEASES" -v src="$SOURCE" '
    /^## +\[v?[0-9]/ {
      seen++
      if (seen > n) { stop = 1 }
      else {
        if (seen == 1) { newest = $0 }
        oldest = $0
      }
    }
    stop { exit }
    seen { buf[++b] = $0 }
    END {
      if (b == 0) {
        print "gen-changelog-recent.sh: no released `## [vX.Y.Z]` heading in " src > "/dev/stderr"
        exit 3
      }
      kept = (seen > n) ? n : seen
      # Version tokens for the coverage line: strip "## [" and "] - DATE".
      sub(/^## +\[/, "", newest); sub(/\].*$/, "", newest)
      sub(/^## +\[/, "", oldest); sub(/\].*$/, "", oldest)
      print "# Changelog — recent releases"
      print ""
      print "GENERATED FILE — do not edit by hand. `scripts/gen-changelog-recent.sh` rewrites it"
      print "wholesale, `scripts/release.sh` runs that generator on every release, and"
      print "`scripts/audit-core.sh` §9e fails when this file is not byte-identical to a fresh"
      print "render. To fix a conflict or a stray edit, re-run the generator — never patch it."
      print ""
      printf "The last %d released sections of `%s` (%s … %s), vendored into every OS repo'\''s\n", kept, src, newest, oldest
      print "`core/` by `core.vendor` so `core whatsnew` can answer offline. The full changelog is"
      print "repo-meta and stays upstream:"
      print "[dotgibson/dotfiles-core/CHANGELOG.md](https://github.com/dotgibson/dotfiles-core/blob/main/CHANGELOG.md)."
      print ""
      # Trailing-blank trim so the file ends in exactly one newline — MD047 and pre-commit
      # end-of-file-fixer both require it, and a drifting trailing blank would red §9e on a
      # file nobody touched.
      while (b > 0 && buf[b] ~ /^[[:space:]]*$/) b--
      for (i = 1; i <= b; i++) print buf[i]
    }
  ' "$SOURCE"
}

case "$MODE" in
stdout)
  # NOTHING but the digest on stdout — this is what §9e cmp's and what the unit tests
  # consume. No pass() line here (pass writes to stdout); failures go to stderr.
  _render || exit 1
  ;;
check)
  tmp="$(mktemp "${TMPDIR:-/tmp}/changelog-recent.XXXXXX")" || {
    fail "gen-changelog-recent.sh: mktemp failed"
    exit 1
  }
  if ! _render >"$tmp"; then
    rm -f "$tmp"
    exit 1
  fi
  # core_files_identical, not `cmp`: diffutils is OPTIONAL on a bare box (busybox/Alpine),
  # and a gate that silently degrades where its tool is absent is not a gate (#572). It
  # compares git blob hashes, which is exactly byte-identity.
  if core_files_identical "$tmp" "$OUT"; then
    rm -f "$tmp"
    pass "$OUT is up to date ($RECENT_RELEASES releases)"
    exit 0
  fi
  rm -f "$tmp"
  fail "$OUT is stale or missing — run: ./scripts/gen-changelog-recent.sh"
  exit 1
  ;;
write)
  tmp="$(mktemp "${OUT}.XXXXXX")" || {
    fail "gen-changelog-recent.sh: mktemp failed"
    exit 1
  }
  # mktemp creates 0600; git stores 100644 for a non-executable blob, so match that on
  # disk too — otherwise the authored copy and every checked-out vendored copy disagree.
  if _render >"$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$OUT"; then
    pass "$OUT regenerated ($RECENT_RELEASES most recent releases of $SOURCE)"
  else
    rm -f "$tmp"
    fail "gen-changelog-recent.sh: render failed — $OUT left untouched"
    exit 1
  fi
  ;;
esac
