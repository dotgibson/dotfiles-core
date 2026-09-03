#!/usr/bin/env bash
# scripts/fleet-vocabulary.sh — the Makefile verb x repo register, plus the test floor (#691)
# ──────────────────────────────────────────────────────────────────────────────
# DOES EVERY REPO SPEAK THE SAME `make`? Nine repos had nine dialects: "dry run" was spelled
# two ways, "verify core" five, "check packages" two, and only `help` was common to every
# Makefile in the fleet. A contributor moving between repos re-learned the verbs each time,
# and no gate noticed — the surface a contributor actually touches was a convention, and
# it was failing measurably.
#
# scripts/make-vocabulary.txt declares the canonical verbs ONCE, in Core. This script reads
# each sibling repo's Makefile and reports, per verb, whether the canonical target exists.
# Aliases are the repo's business: keeping `bootstrap-dry` as a `.PHONY` alias of `dry-run`
# costs two lines and is not this register's concern. THE REQUIREMENT IS THAT THE CANONICAL
# NAME EXISTS. A verb that genuinely does not apply is declared, not silently absent, in the
# repo's .github/core-gates.txt — the same file the gate x repo register reads:
#
#     make:<verb> none <why this repo has nothing to run here>
#
# THE TEST FLOOR rides in the last column. Five of nine repos had no repo-owned tests at
# all — including dotfiles-Fedora, the template every Linux repo is stamped from. The floor
# is deliberately low: a `test/` (or `tests/`) directory with something in it, and a
# workflow under .github/ that runs it. Not Windows' 85% coverage bar, which is
# disproportionate for a thin OS shim; just "a suite exists and CI runs it", which is what
# a template should meet before it is copied eight more times. There is no waiver line for
# the floor: a floor with a bypass is a suggestion.
#
# DERIVED, NOT HAND-MAINTAINED, for the reason fleet-coverage.sh gives: every cell is read
# from the repo at run time, so a target renamed away from the canonical spelling shows up
# on the next run instead of in the next contributor's confusion.
#
# Usage:
#   ./scripts/fleet-vocabulary.sh              # markdown table on stdout
#   ./scripts/fleet-vocabulary.sh --check      # exit 1 if any verb is missing/undeclared
#                                              #   or any repo is under the test floor
# Env: REPOS_ROOT (default: parent of this repo)
set -uo pipefail
HERE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

REPOS_ROOT="${REPOS_ROOT:-$(cd "$HERE/.." && pwd)}"
VOCAB_FILE="${CORE_MAKE_VOCABULARY:-$HERE/scripts/make-vocabulary.txt}"
CHECK=0
for a in "$@"; do
  case "$a" in
  --check) CHECK=1 ;;
  -h | --help)
    sed -n '2,40p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "unknown arg: $a" >&2
    exit 2
    ;;
  esac
done

# The vocabulary. Same posture as the fleet list (#669): an unreadable or empty declaration
# is a loud stop, never an empty register — a table with no verb columns reads as "every
# repo speaks the vocabulary" while asserting nothing.
VERBS=()
if [[ -r "$VOCAB_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    VERBS+=("${line%%[[:space:]]*}")
  done <"$VOCAB_FILE"
fi
((${#VERBS[@]})) || {
  fail "vocabulary list unreadable or empty: $VOCAB_FILE — cannot enumerate the verbs to report on"
  exit 2
}

load_os_repos || {
  fail "$CORE_OS_REPOS_ERR — cannot enumerate the fleet to report on"
  exit 2
}
REPOS=("${CORE_OS_REPOS[@]}")

_targets() { # _targets <Makefile> → one defined target name per line
  # A rule line is `targets: prereqs` (or `::`) at column 0 — not a recipe (tab), not a
  # comment, not a variable assignment (`=` before the colon), not `.PHONY:`. Several
  # targets may share one rule (`a b: …`), so the left side is split on whitespace.
  awk '
    /^[^\t#. ][^:=]*::?([^=]|$)/ {
      lhs = $0; sub(/::?.*/, "", lhs)
      n = split(lhs, t, /[ \t]+/)
      for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) print t[i]
    }
  ' "$1"
}

_declared() { # _declared <repo-dir> <verb> → the `none <why>` declaration, or ""
  local decl
  decl="$(sed -e 's/#.*//' "$1/.github/core-gates.txt" 2>/dev/null |
    awk -v k="make:$2" '$1==k && $2=="none" { $1=""; $2=""; sub(/^[[:space:]]+/,""); print; exit }')"
  [[ -n "$decl" ]] && printf '%s' "$decl"
}

_run_lines() { # _run_lines <workflow.yml> → the command text of every `run:` step, comments stripped
  # Only what a step RUNS counts as running the suite. A path filter (`paths: ['test/**']`),
  # a job name, or a comment saying `make test` is a mention, not an execution, and an
  # unanchored grep read all three as the floor being met. Inline `run: cmd` prints cmd;
  # `run: |` / `run: >` prints every line of the block (the lines indented deeper than the
  # key). Not a YAML parser — it needs no quoting rules, only indentation, which is the one
  # thing YAML block scalars guarantee.
  awk '
    function strip(s) { sub(/^[ \t]*#.*$/, "", s); sub(/[ \t]#.*$/, "", s); return s }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) next
        match($0, /^[ \t]*/)
        if (RLENGTH > bind) { print strip($0); next }
        inblock = 0
      }
      if (match($0, /^[ \t]*(-[ \t]+)?run:([ \t]|$)/)) {
        rest = substr($0, RSTART + RLENGTH)
        match($0, /^[ \t]*/); bind = RLENGTH
        if (rest ~ /^[ \t]*[|>]/) inblock = 1
        else print strip(rest)
      }
    }
  ' "$1"
}

_suite_targets() { # _suite_targets <Makefile> → targets that run the suite, one per line
  # `make test` is the canonical spelling, but a workflow that runs `make test-repo` whose
  # recipe is `./test/test-repo.sh` IS running the suite — and the verb column already
  # reports the missing alias, so the floor must not report the same gap twice. A target
  # qualifies if its recipe names test/ or tests/, or if a prerequisite qualifies (to a
  # fixpoint, so `test: test-repo` inherits). Same lexer as _targets: rules at column 0,
  # recipes on tab lines, comments and variable assignments ignored.
  awk '
    /^\t/ { if (cur != "") body[cur] = body[cur] " " $0; next }
    /^[^\t#. ][^:=]*::?([^=]|$)/ {
      lhs = $0; sub(/::?.*/, "", lhs)
      rhs = $0; sub(/^[^:]*::?/, "", rhs); sub(/#.*/, "", rhs)
      n = split(lhs, t, /[ \t]+/)
      for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) { cur = t[i]; pre[cur] = pre[cur] " " rhs; seen[cur] = 1 }
      next
    }
    { cur = "" }
    END {
      for (k in seen) if (body[k] ~ /(^|[^[:alnum:]_.-])tests?\//) hit[k] = 1
      do {
        changed = 0
        for (k in seen) if (!(k in hit)) {
          m = split(pre[k], p, /[ \t]+/)
          for (i = 1; i <= m; i++) if (p[i] in hit) { hit[k] = 1; changed = 1; break }
        }
      } while (changed)
      for (k in hit) print k
    }
  ' "$1"
}

_test_floor() { # _test_floor <repo-dir> → ok | no-dir | empty | not-in-ci
  local d="$1" t="" cand="" seen=0 wf alt="" tgt
  # Either directory name satisfies the floor, so the first POPULATED one is the suite; a
  # stale empty test/ beside a real, CI-run tests/ must not read as `empty`.
  for cand in "$d/test" "$d/tests"; do
    [[ -d "$cand" ]] || continue
    seen=1
    # `ls -A` is portable and empty output means empty dir (`find -mindepth` is GNU).
    [[ -n "$(ls -A "$cand" 2>/dev/null)" ]] && { t="$cand"; break; }
  done
  ((seen)) || { printf 'no-dir'; return 0; }
  [[ -n "$t" ]] || { printf 'empty'; return 0; }
  # What counts as running it: a `run:` step that names the directory, or invokes `make`
  # on a target whose recipe does (`make test`, or `make test-repo` → ./test/test-repo.sh).
  alt="test"
  if [[ -f "$d/Makefile" ]]; then
    while IFS= read -r tgt; do
      [[ -n "$tgt" && "$tgt" != test ]] && alt="$alt|$(printf '%s' "$tgt" | sed 's/[.[\\*^$|]/\\&/g')"
    done < <(_suite_targets "$d/Makefile")
  fi
  # Only a workflow GitHub actually loads — top-level .yml/.yaml under .github/workflows,
  # never a nested directory or a stray notes file. The path match wants a boundary on the
  # left so `bootstrap-test/` or `latest/` cannot satisfy it; the make match wants one on
  # the right so `make test-report` is not `make test`.
  for wf in "$d"/.github/workflows/*.yml "$d"/.github/workflows/*.yaml; do
    [[ -f "$wf" ]] || continue
    if _run_lines "$wf" | grep -qE "(make[[:space:]]+([^|&;]*[[:space:]])?($alt)([^[:alnum:]_-]|\$)|(^|[^[:alnum:]_.-])tests?/)"; then
      printf 'ok'
      return 0
    fi
  done
  printf 'not-in-ci'
}

rows=""
notes=""
missing=0
floor_short=0
present=0
n=0
for repo in "${REPOS[@]}"; do
  dir="$(resolve_repo_dir "$REPOS_ROOT" "$repo")" || dir="$REPOS_ROOT/$repo"
  # `-e`, not `-d`: .git is a FILE in a worktree checkout.
  [[ -e "$dir/.git" ]] || continue
  present=$((present + 1))
  line="| \`${repo#dotfiles-}\` |"
  have=""
  [[ -f "$dir/Makefile" ]] && have="$(_targets "$dir/Makefile")"
  for v in "${VERBS[@]}"; do
    if printf '%s\n' "$have" | grep -qxF -- "$v"; then
      line="$line ok |"
    elif [[ ! -f "$dir/Makefile" ]]; then
      line="$line **no Makefile** |"
      missing=$((missing + 1))
    else
      why="$(_declared "$dir" "$v")"
      if [[ -n "$why" ]]; then
        n=$((n + 1))
        line="$line none[^$n] |"
        notes="${notes}[^$n]: \`${repo#dotfiles-}\` / \`make $v\` — $why
"
      else
        line="$line **missing** |"
        missing=$((missing + 1))
      fi
    fi
  done
  floor="$(_test_floor "$dir")"
  case "$floor" in
  ok) line="$line ok |" ;;
  *)
    line="$line **$floor** |"
    floor_short=$((floor_short + 1))
    ;;
  esac
  rows="$rows$line
"
done

if ((CHECK)); then
  if ((present == 0)); then
    echo "fleet-vocabulary: no sibling repo checked out — nothing to check" >&2
    exit 0
  fi
  if ((missing || floor_short)); then
    echo "fleet-vocabulary: $missing verb x repo cell(s) missing/undeclared; $floor_short repo(s) under the test floor" >&2
    printf '%s' "$rows" | grep -F '**' >&2
    exit 1
  fi
  echo "fleet-vocabulary: every verb x repo cell is defined or declared and every repo meets the test floor ($present repo(s) x ${#VERBS[@]} verb(s))"
  exit 0
fi

hdr_row="| repo |"
sep_row="| --- |"
for v in "${VERBS[@]}"; do
  hdr_row="$hdr_row \`make $v\` |"
  sep_row="$sep_row --- |"
done
hdr_row="$hdr_row test floor |"
sep_row="$sep_row --- |"
printf '%s\n%s\n%s' "$hdr_row" "$sep_row" "$rows"
[[ -n "$notes" ]] && printf '\n%s' "$notes"
