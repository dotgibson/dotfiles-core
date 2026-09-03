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

_makefile_text() { # _makefile_text <repo-dir> [file=Makefile] [depth] → the Makefile plus its includes
  # The register promises that `make <verb>` RESOLVES, not that the rule sits in the root
  # file, so `include`/`-include`/`sinclude` lines are followed — lexically, relative to the
  # repo root as make itself resolves them, to a bounded depth, and only when the path
  # carries no `$(…)` (a variable would need make's evaluation, which this deliberately
  # does not run in a sibling checkout). A missing optional include is simply absent.
  local d="$1" f="${2:-Makefile}" depth="${3:-0}" inc
  [[ -f "$d/$f" ]] || return 0
  cat "$d/$f"
  ((depth < 4)) || return 0
  while IFS= read -r inc; do
    [[ -n "$inc" && "$inc" != *'$'* ]] || continue
    _makefile_text "$d" "$inc" $((depth + 1))
  done < <(sed -nE 's/^-?s?include[[:space:]]+//p' "$d/$f" | tr ' \t' '\n\n')
}

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

# WHAT COUNTS AS RUNNING THE SUITE, in one simple shell command (the text is split at
# unquoted `;`/`&&`/`||`/`|` first — AWK_SHELL below — so command position is simply
# the start): a test path as the command (`./test/smoke.sh`, `tests/run`), or an
# interpreter in command position handed one (`bash -e test/smoke.sh`) — optionally under
# sudo or env, and after leading variable assignments (`CI=1 make test` is how a great
# many steps are written). `echo test/smoke.sh`, `echo bash test/smoke.sh` and `shellcheck test/*.sh` mention
# the path and run nothing, so they do not count. `DIRS` is replaced per repo with the
# directory that is actually populated (_run_re), so a populated test/ is not credited by a
# step running a nonexistent tests/. No backslashes: these are handed to awk via -v, which
# would eat them, so `[.]` and `[/]` stand in for the escaped forms.
RUN_RE_TEMPLATE='^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?([.][/])?(DIRS)[/]'
_run_re() { printf '%s' "${RUN_RE_TEMPLATE/DIRS/$1}"; } # _run_re <dir-alternation: test|tests>
# A NO-EXECUTE MODE PARSES OR PRINTS AND RUNS NOTHING: make's dry-run (`-n` in any short
# cluster, --dry-run/--just-print/--recon) and question (`-q`, --question) modes; a shell's
# `-n` syntax check; node's --check. For make the flag disqualifies ANYWHERE in the argument
# list (GNU make accepts `make test -n`); for an interpreter, between it and its operand.
# Applies wherever a command appears — a workflow step or a Makefile recipe.
NORUN_RE='(^|[[:space:]])(sudo[[:space:]]+)?(make[[:space:]]+([^[:space:]]+[[:space:]]+)*(-[a-zA-Z]*[nq][a-zA-Z]*|--dry-run|--just-print|--recon|--question)|(bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(-[a-zA-Z]*n[a-zA-Z]*|--check|--syntax-check))([[:space:]]|$)'

# THE SHELL-TEXT HELPERS, shared by both awk programs below (shell-level text, spliced in),
# so a workflow step and a Makefile recipe are read by the same rules:
#   * splitcmds — one simple command at a time, split at `;`/`&&`/`||`/`|` OUTSIDE quotes.
#     A naive split turned `echo "disabled && make test"` into a synthetic `make test"`.
#     Inside "…" a backslash escapes the next character, so `\"` does not end the string;
#     inside '…' nothing does.
#   * stripcomment — a shell comment (`#` at the start, or after whitespace) OUTSIDE
#     quotes, so `echo "value #"; make test` keeps its make.
#   * unquote_scalar — a YAML flow scalar: a fully "…"- or '…'-quoted value yields its
#     contents (with `\"` and `''` unescaped), anything after the closing quote being a
#     YAML comment; a plain value is returned as is (its ` #` comment is shell text too,
#     and stripcomment removes it). Unquoting runs BEFORE comment stripping, or
#     `run: "make test # suite"` loses its closing quote and never unquotes.
#   * cdnorm — a `cd test` (or tests) earlier in the same command list puts the commands
#     after it inside the suite directory, so `cd test && ./smoke.sh` is rewritten to
#     `./test/smoke.sh` and `cd tests && bash run.sh` to `bash tests/run.sh`; the regexes
#     then judge root-relative paths as always. A later `cd` elsewhere ends the effect.
#   * trim — whitespace only.
AWK_SHELL='
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function splitcmds(s, out,   i, c, q, n, cur) {
    n = 0; cur = ""; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "\"" && c == "\\") { cur = cur c substr(s, i + 1, 1); i++; continue }
      if (q != "") { if (c == q) q = ""; cur = cur c; continue }
      if (c == "\\") { cur = cur c substr(s, i + 1, 1); i++; continue }
      if (c == "\"" || c == SQ) { q = c; cur = cur c; continue }
      if (c == ";" || c == "&" || c == "|") { if (cur ~ /[^ \t]/) out[++n] = cur; cur = ""; continue }
      cur = cur c
    }
    if (cur ~ /[^ \t]/) out[++n] = cur
    return n
  }
  function stripcomment(s,   i, c, q, prev) {
    q = ""; prev = " "
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "\"" && c == "\\") { i++; prev = c; continue }
      if (q != "") { if (c == q) q = ""; prev = c; continue }
      if (c == "\\") { i++; prev = c; continue }
      if (c == "\"" || c == SQ) { q = c; prev = c; continue }
      if (c == "#" && prev ~ /[ \t]/) return substr(s, 1, i - 1)
      prev = c
    }
    return s
  }
  function cdnorm(c, n,   i, d, t, m) {
    d = ""
    for (i = 1; i <= n; i++) {
      t = trim(c[i])
      if (match(t, /^cd[ \t]+/)) {
        d = substr(t, RLENGTH + 1); sub(/^[.][/]/, "", d); sub(/[/]+$/, "", d)
        if (d !~ /^tests?$/) d = ""
        continue
      }
      if (d == "") continue
      if (t ~ /^[.][/]/) { sub(/^[.][/]/, "./" d "/", t); c[i] = t; continue }
      if (match(t, /^((sudo|env)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*(bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[ \t]+(-[^ \t]+[ \t]+)*/)) {
        m = RLENGTH
        if (substr(t, m + 1, 1) !~ /[-\/]/ && substr(t, m + 1) != "") c[i] = substr(t, 1, m) d "/" substr(t, m + 1)
      }
    }
  }
  function unquote_scalar(s,   i, c, out) {
    s = trim(s)
    if (substr(s, 1, 1) == "\"") {
      out = ""
      for (i = 2; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") { out = out substr(s, i + 1, 1); i++; continue }
        if (c == "\"") return out
        out = out c
      }
      return s
    }
    if (substr(s, 1, 1) == SQ) {
      out = ""
      for (i = 2; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == SQ) { if (substr(s, i + 1, 1) == SQ) { out = out SQ; i++; continue } ; return out }
        out = out c
      }
      return s
    }
    return s
  }
'

_run_lines() { # _run_lines <workflow.yml> → the command text of every step's `run:`, one command per line
  # Only what a STEP runs counts as running the suite. A path filter (`paths: ['test/**']`),
  # a job name, or a comment saying `make test` is a mention, not an execution, and an
  # unanchored grep read all three as the floor being met. Not a YAML parser — it needs no
  # document model, only the forms a workflow step actually takes:
  #   * `run:` is a command only inside a `steps:` block (from that key — trailing comment
  #     allowed — to the next non-blank, non-comment line at or above its column) AND at
  #     the step's own key column, the column after `- `, so a job-level `env: { run: … }`
  #     or a step-level `env:` entry named `run` is data.
  #   * an inline value is one logical command line: YAML-unquoted, then shell-comment
  #     stripped, then split.
  #   * a literal block (`|`) is one logical line per physical line, except that a
  #     trailing backslash continues onto the next — `make \` over `test` is `make test`,
  #     and a "…" string continued across lines stays one string; a folded block (`>`) is
  #     ONE line per paragraph, because YAML joins its lines with a space — `echo` over
  #     `make test` runs `echo make test`.
  # Block lines are the lines indented deeper than the key, and are emitted at column 0.
  awk -v SQ="'" "$AWK_SHELL"'
    function emit(s,   c, n, i) { s = trim(stripcomment(s)); n = splitcmds(s, c); cdnorm(c, n); for (i = 1; i <= n; i++) print trim(c[i]) }
    function flush() { if (acc != "") { emit(acc); acc = "" } }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) { flush(); next }
        match($0, /^[ \t]*/)
        if (RLENGTH > bind) {
          line = trim($0)
          if (fold) { acc = (acc == "" ? line : acc " " line); next }
          if (line ~ /\\$/) { acc = acc substr(line, 1, length(line) - 1) " "; next }
          acc = acc line; flush(); next
        }
        flush()
        inblock = 0
      }
      if ($0 ~ /^[ \t]*steps:[ \t]*(#.*)?$/) { match($0, /^[ \t]*/); sind = RLENGTH; insteps = 1; keycol = -1; next }
      if (!insteps) next
      if ($0 ~ /^[ \t]*#/) next
      if ($0 !~ /^[ \t]*$/) { match($0, /^[ \t]*/); if (RLENGTH <= sind) { insteps = 0; next } }
      if (match($0, /^[ \t]*-[ \t]+/)) keycol = RLENGTH
      if (match($0, /^[ \t]*(-[ \t]+)?run:([ \t]|$)/)) {
        rest = substr($0, RSTART + RLENGTH)
        match($0, /^[ \t]*(-[ \t]+)?/); bind = RLENGTH
        if (bind != keycol) next
        if (rest ~ /^[ \t]*[|>]/) { inblock = 1; fold = (rest ~ /^[ \t]*>/); acc = "" }
        else emit(unquote_scalar(rest))
      }
    }
    END { if (inblock) flush() }
  ' "$1"
}

_suite_targets() { # _suite_targets <Makefile> <run-re> → targets that run the suite, one per line
  # `make test` is the canonical spelling, but a workflow that runs `make test-repo` whose
  # recipe is `./test/test-repo.sh` IS running the suite — and the verb column already
  # reports the missing alias, so the floor must not report the same gap twice. A target
  # qualifies if a recipe line of its rule runs the suite (the run regex, after the
  # `@`/`-`/`+` prefixes, split and comment-stripped like a step, and not in a no-execute
  # mode), or if a prerequisite qualifies (to a fixpoint, so `test: test-repo` inherits).
  # A rule with several targets (`smoke test-repo:`) gives its recipe to each; an inline
  # recipe (`test: ; ./test/smoke.sh`) is the text after the rule's `;`. LOGICAL lines: a
  # trailing backslash continues a rule (`test: \` over `suite-run`) or a recipe onto the
  # next physical line, exactly as make reads it. Otherwise the same lexer as _targets:
  # rules at column 0, recipes on tab lines, comments and variable assignments ignored.
  awk -v re="$2" -v nore="$NORUN_RE" -v SQ="'" "$AWK_SHELL"'
    function runs(line,   n, c, i) {
      sub(/^[ \t]*[@+-]*[ \t]*/, "", line)
      n = splitcmds(trim(stripcomment(line)), c); cdnorm(c, n)
      for (i = 1; i <= n; i++) if (trim(c[i]) ~ re && trim(c[i]) !~ nore) return 1
      return 0
    }
    function handle(l,   lhs, rhs, inl, n, t, i) {
      if (l ~ /^\t/) { if (runs(l)) for (i = 1; i <= ncur; i++) hit[cur[i]] = 1; return }
      if (l ~ /^[^\t#. ][^:=]*::?([^=]|$)/) {
        lhs = l; sub(/::?.*/, "", lhs)
        rhs = l; sub(/^[^:]*::?/, "", rhs); sub(/#.*/, "", rhs)
        inl = ""
        if (match(rhs, /;/)) { inl = substr(rhs, RSTART + 1); rhs = substr(rhs, 1, RSTART - 1) }
        n = split(lhs, t, /[ \t]+/); ncur = 0
        for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) { cur[++ncur] = t[i]; pre[t[i]] = pre[t[i]] " " rhs; seen[t[i]] = 1 }
        if (inl != "" && runs(inl)) for (i = 1; i <= ncur; i++) hit[cur[i]] = 1
        return
      }
      ncur = 0
    }
    {
      if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1) " "; next }
      handle(buf $0); buf = ""
    }
    END {
      if (buf != "") handle(buf)
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
  local d="$1" dirs="" cand="" seen=0 wf alt="" tgt cmds hits re
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
  # What counts as running it: a step that executes the directory (the run regex), or
  # invokes `make` on a target whose recipe does. `test` earns its place like any other —
  # a `test:` whose recipe is `@true` runs nothing, and the verb column, not the floor,
  # is where "the canonical name exists" is judged.
  alt=""
  if [[ -f "$d/Makefile" ]]; then
    while IFS= read -r tgt; do
      [[ -n "$tgt" ]] && alt="${alt:+$alt|}$(_ere_escape "$tgt")"
    done < <(_suite_targets <(_makefile_text "$d") "$re")
  fi
  # No suite target at all: the make arm must match nothing, not the empty string.
  [[ -n "$alt" ]] || alt='[^[:alnum:]_-]never-a-target'
  # Only a workflow GitHub actually loads — top-level .yml/.yaml under .github/workflows,
  # never a nested directory or a stray notes file. _run_lines yields one simple command
  # per line; each is judged alone: the run regex, or `make` as the command (optionally
  # under sudo/env or after `VAR=value` assignments) with a suite target as a WHOLE operand
  # anywhere in its argument list (`make lint test`; not `test/report`, `test.coverage`
  # or `test=disabled`) — and in neither case a no-execute mode (NORUN_RE).
  # Captured, not piped from the producer: under pipefail a `grep -q` that exits on an
  # early match can SIGPIPE an awk still writing, and 141 would read as "not run".
  for wf in "$d"/.github/workflows/*.yml "$d"/.github/workflows/*.yaml; do
    [[ -f "$wf" ]] || continue
    # A make option that TAKES AN ARGUMENT (-C dir, -f file, -I dir, -o/-W file, and their
    # long forms) is removed with its argument first, so `make -C test lint` does not read
    # the directory operand as the suite target.
    cmds="$(_run_lines "$wf" | sed -E 's/(^|[[:space:]])(-[CfIoW]|--(directory|file|makefile|include-dir|old-file|assume-old|what-if|new-file|assume-new))[[:space:]]+[^[:space:]]+/\1/g')"
    hits="$(grep -E "($re|^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*make[[:space:]]+([^[:space:]]+[[:space:]]+)*($alt)([[:space:]]|\$))" <<<"$cmds" | grep -vE "$NORUN_RE")"
    if [[ -n "$hits" ]]; then
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
  [[ -f "$dir/Makefile" ]] && have="$(_targets <(_makefile_text "$dir"))"
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
# An `if`, not `[[ … ]] &&`: as the script's last command that test IS the exit status,
# and a fleet with no footnotes would make `make fleet-vocabulary` exit 1 for rendering.
if [[ -n "$notes" ]]; then printf '\n%s' "$notes"; fi
exit 0
