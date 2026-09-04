#!/usr/bin/env bash
# scripts/test-core.sh
# ──────────────────────────────────────────────────────────────────────────────
# BEHAVIORAL tests for Core — the layer scripts/audit-core.sh's static analysis can't
# reach. audit-core.sh proves the modules PARSE (zsh -n) and that the manifest and
# exec-bits are consistent; this proves the modules actually LOAD TOGETHER in the
# canonical order and that the pure shell functions DO what they claim. A defect
# here passes every per-file `zsh -n` cleanly and still fans out to nine OS repos —
# which is exactly the gap this file closes.
#
# THIS FILE IS THE DISPATCHER; the suite lives in scripts/test/NN-name.sh. Each
# fragment is SOURCED into this shell in NN order, so the run is the single stream it
# has always been: one $SANDBOX, one set of PASS/SKIP/FAIL counters, one summary, one
# exit code. The CLI is unchanged, and so is every assertion the suite already had: the
# split moved them, it did not rewrite or prune them. The one addition is
# scripts/test/05-suite-shape.sh, which gates the layout this file now depends on.
#
# WHY IT IS SPLIT (#699). This was one 18,700-line file, and shellcheck's cost grows
# superlinearly with file length: that one file was 42.6s of the audit's 65.9s of
# ShellCheck, paid on all four CI legs by any PR touching any shell file, with the
# macOS leg setting the wall clock for the whole PR. Three dozen ~500-line fragments and
# this dispatcher lint in 9.7s, taking the whole sweep to 31.7s. The second win is
# organisational: the sections were lettered A–L, the letters had drifted into two
# different "E"s and an A that ran after J, and this file's own header still described
# "two sections". Names fix that by construction — a fragment cannot collide with
# another fragment's letter.
#
# ADDING A SECTION = adding scripts/test/NN-name.sh. The glob below picks it up; there
# is no registry to forget and therefore no way to add assertions that never run. NN is
# a sort key only, and the gaps in it are room to insert.
#
# Hermetic: a throwaway $HOME/$ZDOTDIR/$XDG_CACHE_HOME is used, and the plugin dirs
# are pre-seeded EMPTY so plugins.zsh's first-run `git clone` is skipped — the test
# needs no network and writes nothing outside its tempdir.
#
# Graceful degradation: with no zsh installed (a bare box) the zsh-gated fragments SKIP
# and the script exits 0 — identical philosophy to audit-core.sh, so this is safe to
# call from CI, pre-commit, and a developer's laptop alike.
#
# Usage:
#   ./scripts/test-core.sh            # run every section
#   ./scripts/test-core.sh --quiet    # only print SKIP/FAIL + the summary
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

QUIET=0
JSON=0 # --json: machine-readable summary on stdout (implies quiet); mirrors audit-core.sh
# Scope mirrors audit-core.sh: gate the slow AREA-specific sections so a per-area run
# does less. FAIL-CLOSED default (no --scope → every area runs). The cross-cutting,
# pure-bash sections (clipboard ladder, CI-classifier) ALWAYS run — they are fast and
# guard runtime artifacts shared by every area. audit-core.sh passes the classifier's
# verdict here; a bare `./scripts/test-core.sh` runs everything.
SCOPE_SHELL=1
SCOPE_NVIM=1
SCOPE_ATUIN=1
# Shared palette + pass/skip/fail/hdr/have + _set_scope + _seed_plugin_dirs (one
# definition for every gate script). Sourced HERE — before the arg loop calls _set_scope
# — and after QUIET is set so the lib's `: "${QUIET:=0}"` preserves it.
# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"

# Same flag contract as audit-core.sh: parse EVERY arg and reject an unknown option or
# a stray extra operand instead of ignoring it; -h/--help prints usage. (audit-core.sh
# invokes this with --quiet/--scope or nothing.)
while (($#)); do
  case "$1" in
  -q | --quiet) QUIET=1 ;;
  --scope)
    # Require an explicit value (mirrors audit-core.sh): `--scope --quiet` must not
    # eat the next flag as the scope list.
    if (($# < 2)) || [[ "$2" == -* ]]; then
      printf 'test-core.sh: --scope requires a value (shell,nvim,atuin|all|none)\n' >&2
      printf 'try: test-core.sh --help\n' >&2
      exit 2
    fi
    shift
    _set_scope "$1"
    ;;
  --scope=*) _set_scope "${1#*=}" ;;
  --json) JSON=1 QUIET=1 CORE_JSON=1 && export CORE_JSON ;; # only JSON on stdout
  --color)
    if (($# < 2)) || ! _core_set_color "$2"; then
      printf 'test-core.sh: --color requires a value (auto|always|never)\n' >&2
      printf 'try: test-core.sh --help\n' >&2
      exit 2
    fi
    shift
    ;;
  --color=*)
    _core_set_color "${1#*=}" || {
      printf 'test-core.sh: --color requires auto|always|never\n' >&2
      exit 2
    }
    ;;
  -h | --help)
    cat <<'EOF'
usage: test-core.sh [-q|--quiet] [--scope LIST] [--color WHEN] [--json] [-h|--help]

Behavioral suite: clipboard ladder + nvim headless load + nvim event callbacks
+ zsh load-order smoke + function/unit + detection tests. Degrades gracefully
when zsh/nvim are absent.

The sections live in scripts/test/NN-name.sh and are sourced in NN order; this
script is the dispatcher. Adding a section is adding a file there.

  -q, --quiet     only print SKIP/FAIL lines and the final summary
  --scope LIST    limit the slow area sections: shell, nvim, atuin, all (default),
                  none. The clipboard + CI-classifier sections always run.
                  `atuin` drives the premise detector's hermetic self-test
                  (scripts/research/verify-atuin-guard.sh) — the slowest thing here by far.
  --color WHEN    auto (default) | always | never; NO_COLOR still wins. (CORE_COLOR env.)
  --json          machine-readable summary on stdout (implies --quiet):
                  {pass,skip,fail,seconds,skipped[],result}
  -h, --help      show this help and exit
EOF
    exit 0
    ;;
  *)
    printf 'test-core.sh: unexpected argument: %s\n' "$1" >&2
    printf 'try: test-core.sh --help\n' >&2
    exit 2
    ;;
  esac
  shift
done

# ── STOP CORE_JSON AT THIS PROCESS BOUNDARY (#511/#524/#508) ──────────────────
# CORE_JSON=1 means "stdout carries only the JSON object", and common.sh's skip() honours
# it by printing nothing. That is right for THIS script and wrong for every child it runs.
#
# The fixtures below execute real gate scripts — fleet-drift.sh, sync-core.sh, auto-tag.sh,
# tag-release.sh — and assert on their human-readable output, skip() lines included. An
# INHERITED CORE_JSON silences exactly those lines, so an assertion fails for a reason that
# has nothing to do with the code under test: `test-core.sh --scope none --json` reported a
# failing result on a tree the identical non-JSON run passed clean, three separate times
# (#508 tag-release, #524 sync-core, #511 fleet-drift). Each was fixed where it hurt, and
# the next fixture inherited the trap again — because the default was wrong.
#
# `export -n` fixes the DEFAULT rather than the symptom: the value stays readable in this
# shell, so our own skip() is still quiet and the JSON object is still clean, but no child
# inherits it. It handles both routes in: our own --json above, and audit-core.sh --json,
# which puts CORE_JSON in our environment before we start.
#
# The explicit `env -u CORE_JSON` at each fixture invocation is kept as well. It is not
# redundant: it documents the hazard at the call site, and it keeps each fixture correct if
# it is ever lifted out of this file. The two insulation gates (sync-core, fleet-drift)
# export CORE_JSON inside a subshell precisely to prove those pins still work.
export -n CORE_JSON 2>/dev/null || true

# Wall-clock for the standalone summary (mirrors audit-core.sh) — the headless nvim
# leg can take a few seconds, so showing elapsed reads as progress, not a hang.
SECONDS=0

# When invoked from audit-core.sh (CORE_TEST_NESTED=1) the audit owns the summary,
# so we suppress ours and only signal pass/fail via the exit code.
NESTED="${CORE_TEST_NESTED:-0}"
summary() {
  [[ "$NESTED" == 1 ]] && return 0
  if ((JSON)); then
    local _result _first=1 _s
    ((FAIL == 0)) && _result=ok || _result=failed
    printf '{"pass":%d,"skip":%d,"fail":%d,"seconds":%d,"skipped":[' \
      "$PASS" "$SKIP" "$FAIL" "$SECONDS"
    for _s in ${_CORE_SKIPS[@]+"${_CORE_SKIPS[@]}"}; do
      _s="${_s//\\/\\\\}"
      _s="${_s//\"/\\\"}"
      ((_first)) || printf ','
      printf '"%s"' "$_s"
      _first=0
    done
    printf '],"result":"%s"}\n' "$_result"
    return 0
  fi
  printf '\n%s──────── test summary ────────%s\n' "$c_blu" "$c_rst"
  printf '  %spass %d%s   %sskip %d%s   %sfail %d%s   %s(%ds)%s\n' \
    "$c_grn" "$PASS" "$c_rst" "$c_yel" "$SKIP" "$c_rst" "$c_red" "$FAIL" "$c_rst" \
    "$c_blu" "$SECONDS" "$c_rst"
}

# THE RUN'S ONE ENDING: the summary, then the verdict line, then the exit code. A function
# because there are TWO call sites — the end of this file, and the zsh gate in
# scripts/test/60-loader.sh, which ends the run early on a box with no zsh. Those two were
# verbatim copies of each other for as long as the gate has existed, which was survivable
# while they were forty lines apart in one file; since #699 they sit in different files,
# where a copy drifts silently and the bare-box path is exactly the one no developer
# watches. NESTED means audit-core.sh owns the summary and reads only our exit code;
# --json means stdout carries the object and nothing else. Both suppress the verdict line.
_core_test_finish() {
  summary
  if ((FAIL == 0)); then
    { [[ "$NESTED" == 1 ]] || ((JSON)); } || printf '%stests OK%s\n' "$c_grn" "$c_rst"
    exit 0
  fi
  { [[ "$NESTED" == 1 ]] || ((JSON)); } || printf '%stests FAILED%s\n' "$c_red" "$c_rst" >&2
  exit 1
}

# One throwaway sandbox for the whole run; clean it up no matter how we exit. It is created
# BEFORE the zsh gate because the pure-bash fragments — the clipboard ladder first of all —
# must run even where zsh is absent; bin/clip's whole reason to exist is bare-box portability.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/core-test.XXXXXX")"
# ONE handler, because `trap … EXIT` REPLACES rather than appends — a second one installed by
# ANY FRAGMENT would silently take the sandbox cleanup with it, leaving a core-test.XXXXXX per
# run under /tmp for nobody to notice. Anything else needing to run at exit hangs off this
# function (scripts/test/52-atuin-autostart.sh's lock drop is the one that does). The
# `declare -F` guard is for the early exits above (--help, a bad argument): those leave before
# the fragments are sourced, and an EXIT handler that calls a not-yet-defined function turns a
# clean `exit 0` into a command-not-found on stderr.
# shellcheck disable=SC2329  # invoked indirectly, by the EXIT trap installed below
_core_test_cleanup() {
  rm -rf "$SANDBOX"
  declare -F _d_drop_lock >/dev/null && _d_drop_lock
  return 0
}
trap '_core_test_cleanup' EXIT

# ── the suite: scripts/test/NN-name.sh, sourced in NN order ───────────────────
# GLOB + SORT, not a hand-maintained list — the same reason zsh/loader.zsh globs its
# numbered fragments instead of naming them. A registry is a second place to edit, and
# the copy you forget is the one that silently drops assertions from a green run.
#
# SOURCED, not executed: every fragment runs in THIS shell and shares its state — the
# PASS/SKIP/FAIL counters, $SANDBOX and its EXIT trap, $HERE, the SCOPE_* flags, and the
# helpers common.sh defined above. That is what makes the split a pure move: the stream
# of assertions, their order, the summary and the exit code are what they were when this
# was one file. It also means a fragment may `exit` to end the whole run —
# scripts/test/60-loader.sh does exactly that on a box with no zsh, as this file did.
#
# AN EMPTY GLOB IS A HARD FAILURE, not an empty run. A suite that quietly asserts nothing
# reports green, and green is what a caller acts on; this is the posture common.sh's
# load_os_repos takes on an unreadable fleet list, for the same reason. `nullglob` is not
# set here, so an unmatched pattern comes through literally and the -e test catches it.
_core_test_frags=0
for _core_test_frag in "$HERE"/scripts/test/[0-9][0-9]-*.sh; do
  [[ -e "$_core_test_frag" ]] || break
  # Deliberately NOT a `# shellcheck source=` directive: one directive cannot name three
  # dozen files, and following them would re-merge the suite into one 18,700-line unit
  # for the linter — which is the cost #699 removed. Each fragment is a tracked *.sh and
  # is linted on its own by audit-core.sh §5.
  # shellcheck source=/dev/null
  source "$_core_test_frag"
  _core_test_frags=$((_core_test_frags + 1))
done
if ((_core_test_frags == 0)); then
  printf 'test-core.sh: no fragments matched %s/scripts/test/[0-9][0-9]-*.sh\n' "$HERE" >&2
  printf 'test-core.sh: refusing to report a clean run having asserted nothing\n' >&2
  exit 2
fi
unset _core_test_frag _core_test_frags

# ── summary ───────────────────────────────────────────────────────────────────
_core_test_finish
