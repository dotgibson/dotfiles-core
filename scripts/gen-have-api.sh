#!/usr/bin/env bash
# scripts/gen-have-api.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render zsh/have-api.txt FROM PORTABILITY.md §5's declared table, so the HAVE_*
# contract can be enforced in a repo that has never seen PORTABILITY.md.
#
# THE DEFECT THIS CLOSES (#866). audit-core.sh §5j direction 2 — no OS or role repo
# reads a Core HAVE_* flag that PORTABILITY.md §5 does not declare — never fires in
# any CI. Core's own CI checks out this repo alone, so direction 2 records an
# environment skip on every run; and the reusable lint workflow the nine OS repos
# call cannot run it either, because it needs the declared table and PORTABILITY.md
# is not vendored. So an OS-repo PR can add `${HAVE_LNAV:-}` — a flag Core no longer
# sets — and merge green, with the break surfacing later as a shell function quietly
# not firing. That is the exact failure #694 existed to prevent, one repo over.
#
# WHY A GENERATED DATA FILE, and not the two alternatives (#866 weighed all three):
#
#   · VENDORING PORTABILITY.md would put the contract beside the code that implements
#     it, which is the cleanest story — but it is a core.vendor allowlist change,
#     requires retraining core-integrity in lockstep, and ships 270 lines of prose the
#     OS repos have never needed. V5-PROPOSAL.md §4 treats an allowlist change as a
#     major-version concern in its own right.
#   · DECLARING IT IN scripts/lib/common.sh needs no generator at all, since that file
#     is already vendored and already holds the matcher. But it inverts "the doc is the
#     contract", which #860 deliberately chose and which reads better for a human.
#
# This keeps the doc authoritative and ships only the machine-readable half, which is
# the idiom aliases.md, PORTING-MATRIX.md, the theme blocks and desktop/PARITY.md
# already follow: author once in the form a human reads, render the form a gate reads,
# and fail when the two move apart.
#
# THE RENDERED FILE IS DELIBERATELY BORING — one flag name per line, `#` comments, no
# columns. It is read by a workflow leg with grep, on a runner that may have busybox,
# and every ounce of structure in it is something a parser can disagree about.
#
# The backticked `make` hints below are prose in single quotes, never expansions.
# shellcheck disable=SC2016  # backticks inside the operator-facing messages are literal
#
#   gen-have-api.sh           # rewrite zsh/have-api.txt from PORTABILITY.md
#   gen-have-api.sh --check   # exit 1 with a diff if it is stale — THE GATE
#   gen-have-api.sh --list    # print the declared flags, one per line
#
# --root DIR relocates the repo root, so the behavioural suite can drive this against
# a hermetic fixture tree rather than by mutating tracked files — the same reason
# gen-theme.sh:89 and parity-check.sh:38 take one.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODE="write"
ROOT=""

while (($#)); do
  case "$1" in
  --check) MODE=check ;;
  --list) MODE=list ;;
  --root)
    [[ -n "${2:-}" ]] || { printf 'gen-have-api: --root needs a directory\n' >&2; exit 2; }
    ROOT="$2"; shift ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0 ;;
  *)
    printf 'gen-have-api: unexpected argument: %s (try --help)\n' "$1" >&2
    exit 2 ;;
  esac
  shift
done

[[ -n "$ROOT" ]] && HERE="$(cd -- "$ROOT" && pwd)"
cd "$HERE" || exit 2

DOC="PORTABILITY.md"
OUT="zsh/have-api.txt"

[[ -f "$DOC" ]] || { printf 'gen-have-api: %s not found under %s\n' "$DOC" "$HERE" >&2; exit 2; }

# THE SAME AWK AS audit-core.sh §5j, deliberately character-for-character. Two parsers
# for one table is how the table and its gate drift, which is the defect one level up
# from the one this script closes — so scripts/test/ pins that they stay identical.
# Range-anchored to the heading so an unrelated table elsewhere can never widen the
# surface by accident.
declared="$(awk '
  /^### What downstream may use/ { inb = 1; next }
  inb && /^### / { inb = 0 }
  inb && /^\|[ \t]*`HAVE_[A-Z0-9_]+`/ {
    if (match($0, /HAVE_[A-Z0-9_]+/)) print substr($0, RSTART, RLENGTH)
  }
' "$DOC" | sort -u)"

# PARSING NOTHING IS A FAILURE, NOT AN EMPTY FILE. Rename §5's heading and this would
# render an empty allowlist — under which every downstream read is "undeclared" and the
# leg that consumes this reds the whole fleet at once, for a defect that is in THIS repo.
# The inverse of audit-core.sh's reason for the same guard, and just as load-bearing.
if [[ -z "$declared" ]]; then
  printf 'gen-have-api: parsed NO declared flags out of %s §5 — its "### What downstream may use" heading or table is missing or renamed. Refusing to render an empty contract\n' "$DOC" >&2
  exit 2
fi

if [[ "$MODE" == list ]]; then
  printf '%s\n' "$declared"
  exit 0
fi

render() {
  cat <<'HDR'
# zsh/have-api.txt — the HAVE_* flags Core declares for DOWNSTREAM use.
#
# GENERATED by scripts/gen-have-api.sh from PORTABILITY.md §5's "What downstream may
# use" table. Do not hand-edit: `make audit` fails when this and the table disagree.
# To declare a flag, add its row to that table in the same change that reads it.
#
# This file exists so the contract can be checked in a repo that has no copy of
# PORTABILITY.md — every repo with a vendored core/. See dotfiles-core#866.
#
# One flag per line. Everything else Core sets is INTERNAL and may be renamed or
# dropped in any release; probe the tool with `command -v` instead.
HDR
  printf '%s\n' "$declared"
}

if [[ "$MODE" == check ]]; then
  if [[ ! -f "$OUT" ]]; then
    printf 'gen-have-api: %s is missing — run `make gen-have-api`\n' "$OUT" >&2
    exit 1
  fi
  if diff -u "$OUT" <(render) >/dev/null 2>&1; then
    printf 'gen-have-api: %s matches PORTABILITY.md §5\n' "$OUT"
    exit 0
  fi
  printf 'gen-have-api: %s is STALE — regenerate with `make gen-have-api`\n' "$OUT" >&2
  diff -u "$OUT" <(render) >&2 || true
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
render >"$OUT.tmp" && mv "$OUT.tmp" "$OUT"
printf 'gen-have-api: wrote %s (%s flag(s))\n' "$OUT" "$(printf '%s\n' "$declared" | wc -l | tr -d ' ')"
