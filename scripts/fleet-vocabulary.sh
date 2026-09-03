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

# WHAT COUNTS AS RUNNING THE SUITE, in a shell command line: a test path in COMMAND position
# (`./test/smoke.sh`, `tests/run`, or after `;`/`&&`/`|`) or handed to an interpreter
# (`bash -e test/smoke.sh`). `echo test/smoke.sh` and `shellcheck test/*.sh` mention the
# path and run nothing, so they do not count. `DIRS` is replaced per repo with the
# directory that is actually populated (_run_re), so a populated test/ is not credited
# by a step running a nonexistent tests/. No backslashes: this is handed to awk via -v,
# which would eat them, so `[.]` and `[/]` stand in for the escaped forms.
RUN_RE_TEMPLATE='(^|[;&|][[:space:]]*|(bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)([.][/])?(DIRS)[/]'
_run_re() { printf '%s' "${RUN_RE_TEMPLATE/DIRS/$1}"; } # _run_re <dir-alternation: test|tests>

_run_lines() { # _run_lines <workflow.yml> → the command text of every `run:` step, comments stripped
  # Only what a step RUNS counts as running the suite. A path filter (`paths: ['test/**']`),
  # a job name, or a comment saying `make test` is a mention, not an execution, and an
  # unanchored grep read all three as the floor being met. Inline `run: cmd` prints cmd;
  # `run: |` / `run: >` prints every line of the block — the lines indented deeper than
  # the KEY, where for a compact sequence step (`- run: |`) the key sits after the `- `,
  # so a sibling `env:` at the key's own column ends the block rather than joining it.
  # Not a YAML parser — it needs no quoting rules, only indentation, which is the one
  # thing YAML block scalars guarantee.
  awk '
    # Leading indentation goes too: a block line is a command, and the command-position
    # anchors downstream must see it at column 0, as an inline `run:` value already is.
    function strip(s) { sub(/^[ \t]*#.*$/, "", s); sub(/[ \t]#.*$/, "", s); sub(/^[ \t]+/, "", s); return s }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) next
        match($0, /^[ \t]*/)
        if (RLENGTH > bind) { print strip($0); next }
        inblock = 0
      }
      if (match($0, /^[ \t]*(-[ \t]+)?run:([ \t]|$)/)) {
        rest = substr($0, RSTART + RLENGTH)
        match($0, /^[ \t]*(-[ \t]+)?/); bind = RLENGTH
        if (rest ~ /^[ \t]*[|>]/) inblock = 1
        else print strip(rest)
      }
    }
  ' "$1"
}

_suite_targets() { # _suite_targets <Makefile> <run-re> → targets that run the suite, one per line
  # `make test` is the canonical spelling, but a workflow that runs `make test-repo` whose
  # recipe is `./test/test-repo.sh` IS running the suite — and the verb column already
  # reports the missing alias, so the floor must not report the same gap twice. A target
  # qualifies if a recipe line of its rule runs the suite (the run regex, after the `@`/`-`/`+`
  # recipe prefixes), or if a prerequisite qualifies (to a fixpoint, so `test: test-repo`
  # inherits). A rule with several targets (`smoke test-repo:`) gives its recipe to each.
  # Same lexer as _targets: rules at column 0, recipes on tab lines, comments and variable
  # assignments ignored.
  awk -v re="$2" '
    /^\t/ {
      line = $0; sub(/^\t[ \t]*[@+-]*[ \t]*/, "", line)
      if (line ~ re) for (i = 1; i <= ncur; i++) hit[cur[i]] = 1
      next
    }
    /^[^\t#. ][^:=]*::?([^=]|$)/ {
      lhs = $0; sub(/::?.*/, "", lhs)
      rhs = $0; sub(/^[^:]*::?/, "", rhs); sub(/#.*/, "", rhs)
      n = split(lhs, t, /[ \t]+/); ncur = 0
      for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) { cur[++ncur] = t[i]; pre[t[i]] = pre[t[i]] " " rhs; seen[t[i]] = 1 }
      next
    }
    { ncur = 0 }
    END {
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

_ere_escape() { # _ere_escape <string> → the string as a literal inside a POSIX ERE
  # The COMPLETE ERE metacharacter set, so a legal target such as `test+coverage` or
  # `t(1)` matches itself instead of rewriting — or breaking — the pattern it lands in.
  printf '%s' "$1" | sed 's/[][\\.|*?+(){}^$]/\\&/g'
}

_test_floor() { # _test_floor <repo-dir> → ok | no-dir | empty | not-in-ci
  local d="$1" dirs="" cand="" seen=0 wf alt="" tgt lines re
  # Either directory name satisfies the floor, and only a POPULATED one is the suite: a
  # stale empty test/ beside a real, CI-run tests/ must not read as `empty`, and a step
  # that runs a nonexistent tests/ must not credit a populated test/ it never touches.
  for cand in test tests; do
    [[ -d "$d/$cand" ]] || continue
    seen=1
    # `ls -A` is portable and empty output means empty dir (`find -mindepth` is GNU).
    [[ -n "$(ls -A "$d/$cand" 2>/dev/null)" ]] && dirs="${dirs:+$dirs|}$cand"
  done
  ((seen)) || { printf 'no-dir'; return 0; }
  [[ -n "$dirs" ]] || { printf 'empty'; return 0; }
  re="$(_run_re "$dirs")"
  # What counts as running it: a `run:` step that executes the directory (the run regex), or
  # invokes `make` on a target whose recipe does (`make test`, `make test-repo`).
  alt="test"
  if [[ -f "$d/Makefile" ]]; then
    while IFS= read -r tgt; do
      [[ -n "$tgt" && "$tgt" != test ]] && alt="$alt|$(_ere_escape "$tgt")"
    done < <(_suite_targets "$d/Makefile" "$re")
  fi
  # Only a workflow GitHub actually loads — top-level .yml/.yaml under .github/workflows,
  # never a nested directory or a stray notes file. `make` must be in COMMAND position too
  # (start, after a control operator, or under sudo): `echo "make test is disabled"` is a
  # string, not a run. The right boundary keeps `make test-report` from being `make test`.
  # The step text is captured, then searched from a herestring: under pipefail a `grep -q`
  # that exits on an early match can SIGPIPE a producer still writing, and 141 would read
  # as "not run".
  for wf in "$d"/.github/workflows/*.yml "$d"/.github/workflows/*.yaml; do
    [[ -f "$wf" ]] || continue
    lines="$(_run_lines "$wf")"
    if grep -qE "((^|[;&|])[[:space:]]*(sudo[[:space:]]+)?make[[:space:]]+([^|&;]*[[:space:]])?($alt)([^[:alnum:]_-]|\$)|$re)" <<<"$lines"; then
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
    # Herestring, not a printf pipe: §5d's pipefail rule, and grep -q exits early anyway.
    if grep -qxF -- "$v" <<<"$have"; then
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
