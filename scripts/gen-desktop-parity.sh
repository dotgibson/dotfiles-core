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
#     <!-- core:desktop-parity:gen parity -->
#     …rendered from dotfiles-core/desktop/PARITY.shared.md…
#     <!-- core:desktop-parity:end parity -->
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
#   ./scripts/gen-desktop-parity.sh --quiet      # silence the section header and EVERY
#                                                #   success line, the final summary
#                                                #   included; failures and skips still print
#   ./scripts/gen-desktop-parity.sh --color WHEN # auto (default) | always | never
#   ./scripts/gen-desktop-parity.sh -h, --help   # print this block and exit
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
# shellcheck source=scripts/lib/gen-region.sh
source "$HERE/scripts/lib/gen-region.sh"

SRC="$HERE/desktop/PARITY.shared.md"

# ── the marker grammar, and where it comes from (#1129) ───────────────────────
# ONE BLOCK ID, `parity`, in the one grammar every generated region in this repo speaks:
# `core:<ns>:gen <id>` … `core:<ns>:end <id>`, matched, walked and installed by
# scripts/lib/gen-region.sh. No marker string is written out here, and neither is a count,
# a nesting check or an atomic install — that is the entire point of the library.
#
# `core:` is PROVENANCE. It names the repo whose generator owns the block, which is the one
# thing a reader of dotfiles-Windows/desktop/PARITY.md has to tell them that dotfiles-core
# rewrites it: nothing in that repo writes the block and nothing there gates it.
# `dotfiles-Offense`'s own gen-views.sh is correctly `companion:` for the same reason.
#
# THIS WAS THE LAST GENERATOR ONTO THE LIBRARY, and its targets are why. They live in TWO
# SIBLING REPOS, so Core and those repos could not change a marker string in one commit —
# whichever side moved first would red the other, and .github/workflows/parity-check.yml
# clones both siblings from `main` weekly and runs `--check --strict`. So Core learned the
# canonical form first while still ACCEPTING the id-less pre-#1129 pair (#1143), the two
# siblings were renamed one repo at a time, and the legacy arm went once no live copy
# carried it. A copy still on the old pair now has no region at all, which this gate reports
# as the drift it is.
region_init desktop-parity gen-desktop-parity html "BLOCKS in scripts/gen-desktop-parity.sh"

ROOT="$(cd "$HERE/.." && pwd)" # siblings of dotfiles-core by default
[[ -n "${DOTFILES_ROOT:-}" ]] && ROOT="$DOTFILES_ROOT"
MODE="write"
STRICT=0
CHECKED=0
MISSING=""

# ── the registry ──────────────────────────────────────────────────────────────
# BLOCKS: id<TAB>path<TAB>repo — a PLACEMENT registry in the shape scripts/lib/gen-region.sh
# documents (#1144): ONE block, rendered into two files in two sibling repos, so the same id
# sits on both rows. gen-theme.sh carries the other placement registry. Until #1144 this was
# a `repo<TAB>path` array with the id held apart in a constant — the same facts, permuted,
# because there was exactly one block; the library's resolver reads this shape and not that
# one. Both files are MANDATORY when their repo is checked out — this script's policy below,
# not the library's.
BLOCKS="parity	desktop/PARITY.md	dotfiles-Windows
parity	sketchybar/PARITY.md	dotfiles-MacBook"
N_TARGETS="$(grep -c . <<<"$BLOCKS")"

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

# Remove the in-flight render temp on ANY exit. The normal paths already rm it, but a Ctrl-C
# between mktemp and the comparison otherwise leaves a gen-desktop-parity.XXXXXX behind, and
# TMPDIR is pointed into the fixture by the behavioural suite — litter this gate would then
# read as a stray. EXIT does the cleanup (a second rm -f is a no-op); INT/TERM exit with the
# conventional 128+signal and let EXIT fire, exactly as audit-core.sh does. region_install's
# own sibling temp is cleaned by region_install, on both its success and its failure paths.
_gdp_cleanup() { [[ -n "${tmp:-}" ]] && rm -f "$tmp"; }
trap _gdp_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# render_for <id> <indent> — the block body, on stdout.
#
# region_build_file calls this between the markers it echoes back VERBATIM, so this function
# is the whole of what is generator-specific about the render; the walker is the library's.
# The INDENT argument is ignored on purpose: these markers sit at column 0 and the body is
# multi-line Markdown, so re-indenting it would corrupt the very tables the gate compares.
#
# `cat`'s exit status is the read-error guard, and it has to be checked. The awk this
# replaced used `getline`, which returns 1 per line, 0 at EOF and -1 on a READ ERROR, and
# `> 0` cannot tell the last two apart: a source that became unreadable after the -f test
# above (an I/O error, a concurrent replacement) yielded an EMPTY block while awk still
# exited 0, and write mode installed that over a perfectly good PARITY.md and called it a
# success. `return 2` makes region_build_file fail, and the caller leaves the target alone.
#
# The trailing blank line is FRAMING, not content: Markdown wants one between the last list
# item and the closing HTML comment, and without it prettier inserts one — which would make
# the rendered file differ from its own formatter and re-open the drift this gate closes. It
# lives here rather than in the source file because a trailing blank line is exactly what
# prettier strips from PARITY.shared.md on its own, so the source could not carry it and
# stay a fixed-point standalone.
#
# The disable below reads as dead code to the linter: this is invoked BY NAME through
# region_build_file, because bash 3.2 has no function references. BOTH codes, not one —
# 0.10.0 on the Alpine leg reports that diagnostic differently from the 0.11.0 pin, which
# is how #1141 first went red.
# shellcheck disable=SC2317,SC2329
render_for() {
  cat "$SRC" || return 2
  printf '\n'
}

hdr "Desktop-bar parity (Zebar ↔ sketchybar)"

while IFS="$(printf '\t')" read -r id rel repo; do
  [[ -n "$id" ]] || continue
  # THE RESOLUTION RULE IS THE LIBRARY'S (region_block_path, #1144): resolve_repo_dir — a
  # clone whose directory name differs from the repo's is still found — then `-e <dir>/.git`,
  # not `-d <dir>`. `.git` is a FILE in a worktree or submodule checkout, so `-e` accepts
  # those; and a plain directory that merely SHARES the repo's name is not a clone, so `-d`
  # would treat it as checked out and then red on the PARITY.md it does not have — a false
  # failure where the honest answer is "not checked out, skipped". Empty means exactly that.
  file="$(region_block_path "$rel" "$repo" "$ROOT")"

  # Repo ABSENT → skip (Core-only clone), unless --strict.
  if [[ -z "$file" ]]; then
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
  # STRUCTURE, from the shared library — no marker string, no count and no ordering test
  # is written here. region_preflight_file replays the marker sequence and checks that the
  # one registered block appears exactly once with its `gen` and `end` in step. A copy with
  # no region at all — markers deleted, or a sibling never renamed off the pre-#1129 id-less
  # pair — reports the block MISSING, which is the drift this gate exists for rather than an
  # absence to skip. (gen-views.sh skips an unmarked file; its target list is opt-in. These
  # two targets are named and mandatory.)
  #
  # SEVERITY IS TRANSLATED HERE, DELIBERATELY. The library returns 2, "this document is
  # structurally broken". This generator reports it as 1, because an unmarked copy is the
  # DRIFT BEING GATED, not an absence — and audit-core.sh §9i is written around exactly
  # that: its catch-all arm says "a missing target or broken markers are exit 1, handled
  # above", and would otherwise file a broken marker as "the gate could not run". So every
  # library call is branched on and mapped to this script's own fail(), which drives the
  # final `exit 1`. Do not "simplify" this into propagating the library's return code.
  if ! region_preflight_file "$file" "$id"; then
    fail "$repo/$rel — its generated region is malformed (above); fix the markers in that repo"
    continue
  fi
  # The reverse direction: a marker whose id this generator does not render. One id is
  # registered, so anything else is either a typo or a second block nobody renders — and an
  # unrendered block is coverage loss that reads as health, the shape these gates exist to end.
  if ! region_unregistered_in_file "$file" "$id"; then
    fail "$repo/$rel — it carries a marker id this generator does not render"
    continue
  fi

  # ONE render, to a TEMPLATED temp file — bare `mktemp` is a BSD failure (PORTABILITY.md).
  # It goes to TMPDIR in BOTH modes now: region_install makes its own sibling temp for the
  # atomic same-filesystem rename, so the render itself no longer needs the target's
  # directory to be writable, and there is one temp path to clean instead of two.
  if ! tmp="$(mktemp "${TMPDIR:-/tmp}/gen-desktop-parity.XXXXXX" 2>/dev/null)"; then
    fail "$repo/$rel — could not create a temp file for the render (is TMPDIR writable?)"
    continue
  fi
  # NOTHING here runs under `set -e`, so every step that can fail is branched on: an
  # unchecked render or copy prints "rewritten" and exits 0 over a stale or partial file.
  # region_build_file returns 2 on a structural fault having written a PARTIAL stream, which
  # is why it renders into this temp and never straight at the target.
  if ! region_build_file "$file" render_for >"$tmp"; then
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
    # stdin is the registry heredoc this loop reads from, so git gets /dev/null.
    git --no-pager diff --no-index --no-color -- "$file" "$tmp" </dev/null | sed 's/^/    /' >&2 || true
    printf '    fix: edit desktop/PARITY.shared.md, then run: make gen-desktop-parity\n' >&2
    rm -f "$tmp"
  else
    # Install the COMPLETE render atomically, through the library's 0644 policy: a
    # templated SIBLING temp so the rename is same-filesystem (a full disk or a kill leaves
    # the old file intact rather than a half-written one), chmod BEFORE the rename because
    # mktemp creates 0600 and mv preserves it — without that every regeneration would turn
    # a tracked, world-readable PARITY.md into an owner-only file. git stores 100644.
    # region_install prints its own diagnostic and cleans up its temp; this adds the line
    # that names which repo's copy it was.
    if region_install "$tmp" "$file" 0644; then
      pass "$repo/$rel rewritten from desktop/PARITY.shared.md"
    else
      fail "$repo/$rel — could not install the rendered block; the file is unchanged"
    fi
    rm -f "$tmp"
  fi
done <<EOF
$BLOCKS
EOF

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
    "$ROOT" "$MISSING" "$CHECKED" "$N_TARGETS" >&2
  exit 3
fi
pass "desktop-bar parity — both copies track desktop/PARITY.shared.md"
