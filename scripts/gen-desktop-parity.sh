#!/usr/bin/env bash
# scripts/gen-desktop-parity.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render the canonical desktop-bar parity contract into BOTH desktop repos.
#
# `desktop/PARITY.shared.md` (this repo) is the ONE place the Zebar ↔ sketchybar
# contract is authored. It is rendered verbatim between a marker pair in:
#
#     dotfiles-Windows/desktop/PARITY.md
#     dotfiles-MacBook/sketchybar/PARITY.md
#
#     <!-- desktop-parity:gen -->
#     …rendered from dotfiles-core/desktop/PARITY.shared.md…
#     <!-- desktop-parity:end -->
#
# Anything OUTSIDE the markers is hand-authored and never touched — that is where a
# host puts an addendum with no counterpart on the other bar (the Windows psmux
# battery-scale note), marked `deliberate` in the doc's own vocabulary.
#
# WHY THIS EXISTS. The two files were an admitted verbatim pair whose only mechanism
# was the sentence "Edit both together". It did not hold: they drifted 3.5 KB apart —
# ~4.4 KB of that a one-sided Markdown reformat, 947 bytes a real Windows-only block
# that had never been marked deliberate (#693). A sentence is not a gate; this is.
#
# THE SOURCE IS A PRETTIER FIXED-POINT, on purpose. Core's nvim maps
# `markdown = { "prettierd" }` (nvim/lua/gerrrt/plugins/conform.lua), and formatting one
# copy in the fleet's own editor is the most likely way the pair drifted: prettier on the
# Windows copy reproduces the MacBook copy to within its `*em*`→`_em_` rewrite. Authoring
# the block in prettier's own output form makes that keystroke a no-op instead of drift,
# so this gate never fights the editor. Core's .prettierrc.json only touches JSON, so the
# form is stable under prettier defaults too — which is what the desktop repos resolve,
# neither of them carrying a prettier config. Keep it that way: run the block through
# `prettier --parser markdown` after editing.
#
# Cross-repo, like parity-check.sh and fleet-drift.sh, though not for one single reason:
# dotfiles-MacBook DOES vendor Core, but sketchybar/PARITY.md is its own OS-layer file and
# sits outside the vendored core/ subtree; dotfiles-Windows vendors no core/ at all. Either
# way the target is not reachable from this checkout, so both are read from sibling
# checkouts under --root.
#
# A repo that isn't checked out is an ENVIRONMENT skip — but be precise about what that
# does and does not mean. This script still EXITS 3, so `make check-desktop-parity` on a
# Core-only clone fails like any other non-zero command; that is the posture
# gen-porting-matrix.sh takes for the same input. It is audit-core.sh §9i that translates 3
# into a skip_env and stays green, not this script. --strict collapses the distinction: an
# absent repo FAILS outright, which is what CI uses after cloning both.
#
# A repo that IS checked out is never skipped: a target file that is missing, or present
# without its markers, FAILS. gen-views.sh skips an unmarked file — right for its opt-in,
# host-agnostic target list — but here the two targets are named and mandatory, so "no
# markers" is the drift being gated, not an absence.
#
# Usage:
#   ./scripts/gen-desktop-parity.sh              # write the block into both repos
#   ./scripts/gen-desktop-parity.sh --check      # exit 1 with a diff if either is stale
#   ./scripts/gen-desktop-parity.sh --root ~/src # the fleet lives elsewhere
#   ./scripts/gen-desktop-parity.sh --strict     # a not-checked-out repo FAILS
#   ./scripts/gen-desktop-parity.sh --quiet      # suppress the per-target pass lines
#   ./scripts/gen-desktop-parity.sh --color WHEN # auto (default) | always | never
#
# Exit: 0 = every checked-out copy matches the canonical source (or was written);
#       1 = drift, or a malformed/missing target in a checked-out repo;
#       2 = usage error;
#       3 = a desktop repo is NOT CHECKED OUT, so this run could not cover it. Callers are
#           meant to read this as an ENVIRONMENT skip — §9h and fleet-drift.sh take the same
#           posture, and audit-core.sh records it via skip_env — but it is still a NON-ZERO
#           exit here, so a bare `make check-desktop-parity` on a Core-only clone fails.
#           Inside a git worktree $HERE/.. is .claude/worktrees/, so this skips there too;
#           pass --root DIR to gate from a worktree. Severity is sticky: drift (1) outranks an
#           absent sibling (3), so a half-checked-out fleet still reds on real drift.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

SRC="$HERE/desktop/PARITY.shared.md"
MARK_GEN='<!-- desktop-parity:gen -->'
MARK_END='<!-- desktop-parity:end -->'

ROOT="$(cd "$HERE/.." && pwd)" # siblings of dotfiles-core by default
[[ -n "${DOTFILES_ROOT:-}" ]] && ROOT="$DOTFILES_ROOT"
MODE="write"
STRICT=0
CHECKED=0
MISSING=""

# repo<TAB>path-within-repo. Both are mandatory when the repo is checked out.
TARGETS=(
  "dotfiles-Windows	desktop/PARITY.md"
  "dotfiles-MacBook	sketchybar/PARITY.md"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
  --check) MODE="check"; shift ;;
  --root)
    # Validate BEFORE assigning: an explicitly empty --root '' passed the old shift-based
    # check and then resolved every target under /dotfiles-*, silently gating nothing.
    [[ -n "${2:-}" ]] || { fail "--root needs a directory"; exit 2; }
    ROOT="$2"
    shift 2
    ;;
  --strict) STRICT=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --color)
    _core_set_color "${2:-}" || { fail "--color wants auto|always|never"; exit 2; }
    shift 2
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0
    ;;
  *) fail "unknown argument: $1"; exit 2 ;;
  esac
done

[[ -f "$SRC" ]] || { fail "canonical source missing: desktop/PARITY.shared.md"; exit 2; }

# core_files_identical compares `git hash-object` outputs: with no git BOTH substitutions are
# empty and therefore EQUAL, so a drifted copy would read as clean and --check would report
# success having compared nothing. Fail closed, exactly as gen-porting-matrix.sh does. This
# guards write mode too, where the same false "identical" would skip a needed regeneration.
command -v git >/dev/null 2>&1 || {
  fail "git is not installed — the byte comparison needs it; the gate would compare NOTHING and pass"
  exit 2
}

# Remove the in-flight temp on ANY exit. The normal paths already rm it, but a Ctrl-C
# between mktemp and the install otherwise leaves a PARITY.md.gen.XXXXXX sitting in
# someone's checkout — litter this gate would then read as an untracked stray. EXIT does the
# cleanup (a second rm -f is a no-op); INT/TERM exit with the conventional 128+signal and let
# EXIT fire, exactly as audit-core.sh does.
_gdp_cleanup() { [[ -n "${tmp:-}" ]] && rm -f "$tmp"; }
trap _gdp_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# render <target-file> — the file with everything between the markers replaced by $SRC.
#
# The trailing `print ""` is FRAMING, not content: Markdown wants a blank line between the
# last list item and the closing HTML comment, and without it prettier inserts one — which
# would make the rendered file differ from its own formatter and re-open the drift this
# gate closes. It lives here rather than in the source file because a trailing blank line
# is exactly what prettier strips from PARITY.shared.md on its own, so the source could not
# carry it and stay a fixed-point standalone.
render() {
  # `getline` returns 1 per line, 0 at EOF and -1 on a READ ERROR, and `> 0` cannot tell the
  # last two apart. Unguarded, a source that became unreadable after the -f check above (an
  # I/O error, a concurrent replacement) yields an EMPTY block and awk still exits 0 — write
  # mode would then install that over a perfectly good PARITY.md and call it a success. Check
  # the status and exit non-zero so the render-failure branch leaves the target untouched.
  awk -v src="$SRC" -v g="$MARK_GEN" -v e="$MARK_END" '
    $0 == g {
      print
      while ((_rc = (getline l < src)) > 0) print l
      if (_rc < 0) { print "gen-desktop-parity: cannot read " src > "/dev/stderr"; exit 1 }
      close(src); print ""; skip = 1; next
    }
    $0 == e { skip = 0; print; next }
    !skip   { print }
  ' "$1"
}

hdr "Desktop-bar parity (Zebar ↔ sketchybar)"

for entry in "${TARGETS[@]}"; do
  repo="${entry%%	*}"
  rel="${entry##*	}"
  # `-e <dir>/.git`, not `-d <dir>` — the fleet convention (scripts/lib/common.sh,
  # gen-porting-matrix.sh). `.git` is a FILE in a worktree or submodule checkout, so `-e`
  # accepts those; and a plain directory that merely SHARES the repo's name is not a clone,
  # so `-d` would treat it as checked out and then red on the PARITY.md it does not have —
  # a false failure where the honest answer is "not checked out, skipped". resolve_repo_dir
  # additionally finds a clone whose directory name differs from the repo name.
  dir="$(resolve_repo_dir "$ROOT" "$repo")" || dir="$ROOT/$repo"
  file="$dir/$rel"

  # Repo ABSENT → skip (Core-only clone), unless --strict.
  if [[ ! -e "$dir/.git" ]]; then
    if ((STRICT)); then
      fail "$repo is not checked out under $ROOT (--strict)"
    else
      MISSING="$MISSING $repo"
      skip_env "$repo not checked out — skipping $rel (clone it, or pass --root)"
    fi
    continue
  fi

  # Repo PRESENT → the file and its markers are mandatory. Missing markers is the
  # drift this gate exists for, so it fails rather than skipping.
  if [[ ! -f "$file" ]]; then
    fail "$repo/$rel is missing — the repo is checked out, so this file must exist"
    continue
  fi
  n_gen=$(grep -cFx "$MARK_GEN" "$file")
  n_end=$(grep -cFx "$MARK_END" "$file")
  if ((n_gen != 1 || n_end != 1)); then
    fail "$repo/$rel — expected exactly one '$MARK_GEN' and one '$MARK_END' (found $n_gen/$n_end); the generated block must be delimited exactly once"
    continue
  fi
  if [[ "$(grep -nFx "$MARK_GEN" "$file" | cut -d: -f1)" -gt "$(grep -nFx "$MARK_END" "$file" | cut -d: -f1)" ]]; then
    fail "$repo/$rel — '$MARK_END' appears before '$MARK_GEN'"
    continue
  fi

  # ONE render, to a TEMPLATED temp file — bare `mktemp` is a BSD failure (PORTABILITY.md).
  # In write mode the temp is a SIBLING of the target so the install below is an atomic
  # same-filesystem rename: a full disk or a kill leaves the old file intact rather than a
  # half-written one. In check mode nothing is installed, so it goes to TMPDIR and the
  # target's directory need not be writable at all.
  if [[ "$MODE" == check ]]; then _tmpl="${TMPDIR:-/tmp}/gen-desktop-parity.XXXXXX"; else _tmpl="$file.gen.XXXXXX"; fi
  if ! tmp="$(mktemp "$_tmpl" 2>/dev/null)"; then
    fail "$repo/$rel — could not create a temp file next to it (is the directory writable?)"
    continue
  fi
  # NOTHING here runs under `set -e`, so every step that can fail is branched on: an
  # unchecked render or copy prints "rewritten" and exits 0 over a stale or partial file.
  if ! render "$file" >"$tmp"; then
    fail "$repo/$rel — rendering the block failed; the file was NOT modified"
    rm -f "$tmp"
    continue
  fi
  CHECKED=$((CHECKED + 1))

  # core_files_identical, NOT cmp/diff, decides the verdict. Both ship in diffutils, which
  # is not guaranteed present — a Tumbleweed box in this fleet had neither — and a missing
  # binary exits non-zero, which is indistinguishable from "the files differ". That exact
  # shape red-flagged a lockfile that had never moved (#572); the helper hashes instead, so
  # it cannot be fooled. diff stays for DIAGNOSTICS only, guarded by have(), never the verdict.
  if core_files_identical "$file" "$tmp"; then
    rm -f "$tmp"
    if [[ "$MODE" == check ]]; then
      pass "$repo/$rel matches desktop/PARITY.shared.md"
    else
      pass "$repo/$rel already up to date"
    fi
  elif [[ "$MODE" == check ]]; then
    fail "$repo/$rel has drifted from desktop/PARITY.shared.md:"
    # `git diff`, never diff(1). diffutils is absent on minimal hosts in this fleet, and
    # scripts/test-core.sh BANS a bare `diff -`/`cmp -` for exactly that reason — the #572
    # hole one step over. git is the one tool these scripts already cannot run without
    # (core_files_identical is built on git hash-object), so it is the portable diagnostic,
    # and the gate's exemption is structural: `diff` preceded by `git` in the same stage.
    git --no-pager diff --no-index --no-color -- "$file" "$tmp" | sed 's/^/    /' >&2 || true
    printf '    fix: edit desktop/PARITY.shared.md, then run: make gen-desktop-parity\n' >&2
    rm -f "$tmp"
  else
    # Install the COMPLETE render atomically; only claim success if the whole thing worked.
    # chmod BEFORE the rename: mktemp creates 0600, and mv preserves it, so without this
    # every regeneration would turn a tracked, world-readable PARITY.md into an owner-only
    # file. git stores 100644, so match that (gen-porting-matrix.sh and gen-aliases.sh both do).
    if chmod 0644 "$tmp" && mv -f "$tmp" "$file"; then
      pass "$repo/$rel rewritten from desktop/PARITY.shared.md"
    else
      fail "$repo/$rel — could not install the rendered block; the file is unchanged"
      rm -f "$tmp"
    fi
  fi
done

if ((FAIL)); then
  if [[ "$MODE" == check ]]; then
    fail "desktop-bar parity — a copy no longer matches the canonical source"
  fi
  exit 1
fi

# A repo we could not read is an environment skip (3), never a green 0: reporting success
# over an un-inspected copy is the "checked NOTHING and exited 0" shape #682 was filed for.
# The message shape is the one audit-core.sh §9h parses — "not checked out under <root>:<repos> — ".
if [[ -n "$MISSING" ]]; then
  printf 'gen-desktop-parity: not checked out under %s:%s — %d of %d copies compared (clone the fleet beside this repo, or pass --root DIR)\n' \
    "$ROOT" "$MISSING" "$CHECKED" "${#TARGETS[@]}" >&2
  exit 3
fi
pass "desktop-bar parity — both copies track desktop/PARITY.shared.md"
