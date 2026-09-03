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
# NAME RESOLVES, in every repo — that is the promise scripts/make-vocabulary.txt makes to a
# contributor, and the issue's own verification step. A verb that genuinely does not apply
# to a repo is therefore not declared away but STUBBED: a target of the canonical name that
# says so and exits 0 —
#
#     packages-check: ## (n/a) no OS package list to resolve here
#     	@echo "packages-check: not applicable to this repo (no OS package list)"
#
# — so `make packages-check` means the same thing everywhere, including "nothing to do".
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
#   ./scripts/fleet-vocabulary.sh --check      # exit 1 if any verb does not resolve
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
# A scalar count beside the array: on bash 3.2 (the macOS lane) `set -u` rejects an empty
# array's expansion, and the guard below must reach its exit 2, not trip on its own test.
VERBS=()
nverbs=0
if [[ -r "$VOCAB_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    VERBS+=("${line%%[[:space:]]*}")
    nverbs=$((nverbs + 1))
  done <"$VOCAB_FILE"
fi
((nverbs)) || {
  fail "vocabulary list unreadable or empty: $VOCAB_FILE — cannot enumerate the verbs to report on"
  exit 2
}

load_os_repos || {
  fail "$CORE_OS_REPOS_ERR — cannot enumerate the fleet to report on"
  exit 2
}
REPOS=("${CORE_OS_REPOS[@]}")

# MAKE CONDITIONALS, decided where they can be, shared by the four Makefile scanners
# (shell-level text, spliced in): an `ifeq`/`ifneq` whose operands carry no `$` is
# evaluated (`(a,b)` and `"a" "b"` forms; `else` flips it); `ifdef`/`ifndef` and a `$(…)`
# operand are undecidable. mc_line(t) consumes a directive line and returns 1; mc_active()
# is "1" inside every enclosing active branch, "0" under an inactive one, "?" when any
# enclosing condition is undecidable. Rules, .PHONY and includes in an active branch
# count as if unconditional; in an inactive one they do not exist; under "?" a rule stays
# uncounted (the safe direction for a rule is "missing") and a mandatory include fails
# closed (the safe direction there is "unloadable"). No fleet Makefile uses a conditional
# around a rule today.
AWK_MAKECOND='
  function trimq(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); gsub(/^["\047]|["\047]$/, "", x); return x }
  function decide(t,   a, b, neg, body, m) {
    neg = (t ~ /^ifneq/)
    if (t !~ /^ifn?eq/) return "?"
    body = t; sub(/^ifn?eq[ \t]*/, "", body)
    if (body ~ /\$/) return "?"
    if (body ~ /^\(.*,.*\)[ \t]*$/) { sub(/^\(/, "", body); sub(/\)[ \t]*$/, "", body); m = index(body, ","); a = trimq(substr(body, 1, m - 1)); b = trimq(substr(body, m + 1)) }
    else if (body ~ /^["\047][^"\047]*["\047][ \t]+["\047][^"\047]*["\047][ \t]*$/) { m = match(body, /["\047][ \t]+["\047]/); a = trimq(substr(body, 1, m)); b = trimq(substr(body, m + RLENGTH - 1)) }
    else return "?"
    return ((a == b) != neg) ? "1" : "0"
  }
  function mc_active(   k) { for (k = 1; k <= mcdepth; k++) if (MCACT[k] != "1") return MCACT[k]; return "1" }
  # MCTAKEN per level: "1" once an arm evaluated true, "?" once one was undecidable, "0"
  # while every arm so far was false — so `else ifeq (…)` (a chained arm) is "0" after a
  # taken arm, evaluated after only-false arms, and a plain `else` is the complement.
  function mc_line(t,   r) {
    sub(/#.*/, "", t); sub(/^[ ]+/, "", t)
    if (t ~ /^(ifeq|ifneq|ifdef|ifndef)([ \t]|\()/) { mcdepth++; MCACT[mcdepth] = decide(t); MCTAKEN[mcdepth] = MCACT[mcdepth]; return 1 }
    if (t ~ /^else[ \t]+(ifeq|ifneq|ifdef|ifndef)([ \t]|\()/) {
      if (mcdepth) {
        sub(/^else[ \t]+/, "", t); r = decide(t)
        if (MCTAKEN[mcdepth] == "1") MCACT[mcdepth] = "0"
        else if (MCTAKEN[mcdepth] == "?") MCACT[mcdepth] = "?"
        else { MCACT[mcdepth] = r; MCTAKEN[mcdepth] = r }
      }
      return 1
    }
    if (t ~ /^else([ \t]|$)/) { if (mcdepth) MCACT[mcdepth] = (MCTAKEN[mcdepth] == "1") ? "0" : ((MCTAKEN[mcdepth] == "?") ? "?" : "1"); return 1 }
    if (t ~ /^endif([ \t]|$)/) { if (mcdepth) { delete MCACT[mcdepth]; delete MCTAKEN[mcdepth]; mcdepth-- } ; return 1 }
    return 0
  }
'

_makefile_text() { # _makefile_text <repo-dir> [file=Makefile] [depth] → the Makefile with its includes inlined
  # The register promises that `make <verb>` RESOLVES, not that the rule sits in the root
  # file, so `include`/`-include`/`sinclude` lines are followed — lexically, relative to the
  # repo root as make itself resolves them, to a bounded depth, and only when the path
  # carries no `$(…)` (a variable would need make's evaluation, which this deliberately
  # does not run in a sibling checkout); a wildcard include is globbed from the root as
  # make globs it; an include inside a conditional or a define body is not followed, by
  # the same policy that leaves rules there uncounted. The included text is spliced IN
  # PLACE, where make reads it, so a later rule for the same target overrides an earlier
  # one in file order, includes and all. Backslash-continued lines are joined first, so
  # `include \` over `mk/verbs.mk` is one directive.
  #
  # A MANDATORY include that is missing (`include x.mk`, no such file) aborts make before
  # any rule is read, so `make <verb>` resolves NOTHING: this returns 1 and the caller
  # discards the text. `-include`/`sinclude` tolerate absence, as make does.
  local d="$1" f="${2:-Makefile}" depth="${3:-0}" line kind inc m g found
  [[ -f "$d/$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != '@@INCLUDE '* ]]; then
      printf '%s\n' "$line"
      continue
    fi
    # The nesting bound FAILS CLOSED: an include this scanner will not follow could be a
    # missing mandatory one (make aborts) or carry a later override, so the Makefile is
    # treated as unloadable rather than partially read. Five levels of include nesting is
    # far beyond any fleet Makefile.
    ((depth < 4)) || return 1
    kind="${line#@@INCLUDE }"; inc="${kind#* }"; kind="${kind%% *}"
    [[ -n "$inc" ]] || continue
    # A mandatory include under a condition the scanner could not decide: fail closed.
    [[ "$inc" == '?' ]] && return 1
    # A path carrying `$(…)` cannot be resolved without evaluating make. Optional forms are
    # skipped (absence is tolerated either way); a MANDATORY one fails closed — it may well
    # name a file that is not there, and make would abort on it.
    if [[ "$inc" == *'$'* ]]; then
      [[ "$kind" == include ]] && return 1
      continue
    fi
    if [[ "$inc" == *[\*\?\[]* ]]; then
      found=0
      # shellcheck disable=SC2086  # $inc IS the glob: a make include operand is word-split and expanded, as make does
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        found=1
        _makefile_text "$d" "$m" $((depth + 1)) || return 1
      done < <(cd "$d" && for g in $inc; do [[ -f "$g" ]] && printf '%s\n' "$g"; done)
      [[ "$kind" == include && "$found" == 0 ]] && return 1
    elif [[ -f "$d/$inc" ]]; then
      _makefile_text "$d" "$inc" $((depth + 1)) || return 1
    elif [[ "$kind" == include ]]; then
      return 1
    fi
  done < <(awk "$AWK_MAKECOND"'
    # Logical lines; every line is passed through, and an include directive becomes one
    # `@@INCLUDE <kind> <path>` marker per operand (comment stripped, leading spaces
    # allowed), for the shell above to splice — decided by any enclosing conditional
    # (AWK_MAKECOND): followed in an active branch, skipped in an inactive one, and a
    # MANDATORY one under an undecidable condition becomes `@@INCLUDE include ?`, which
    # the shell fails closed.
    { if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1) " "; next } ; l = buf $0; buf = "" }
    { t = l; sub(/#.*/, "", t); sub(/^[ ]+/, "", t) }
    indef { if (t ~ /^endef([ \t]|$)/) indef = 0; print l; next }
    t ~ /^define([ \t]|$)/ { indef = 1; print l; next }
    mc_line(l) { print l; next }
    t ~ /^-?s?include[ \t]/ {
      st = mc_active()
      if (st == "0") next
      n = split(t, w, /[ \t]+/)
      for (i = 2; i <= n; i++) if (w[i] != "") print "@@INCLUDE " w[1] " " ((st == "?" && w[1] == "include") ? "?" : w[i])
      next
    }
    { print l }
    END { if (buf != "") print buf }
  ' "$d/$f")
  return 0
}

_targets() { # _targets <Makefile> → one defined target name per line
  # A rule line is `targets: prereqs` (or `::`) at column 0 — not a recipe (tab), not a
  # comment, not a variable assignment (`=` before the colon), not `.PHONY:`. Several
  # targets may share one rule (`a b: …`), so the left side is split on whitespace.
  # A rule under a make conditional follows AWK_MAKECOND: counted in a statically active
  # branch, absent in an inactive one, uncounted under an undecidable condition ("missing"
  # rather than a guess). A `define`…`endef` body defines no rule.
  awk "$AWK_MAKECOND"'
    indef { if ($0 ~ /^[ ]*endef([ \t]|$)/) indef = 0; next }
    /^[ ]*define([ \t]|$)/ { indef = 1; next }
    mc_line($0) { next }
    mc_active() != "1" { next }
    # A rule may be SPACE-indented (make strips leading blanks from a non-recipe line);
    # only a TAB makes a recipe. The pattern allows the spaces, the split discards them.
    /^[ ]*[^\t#. ][^:=]*::?([^=]|$)/ {
      lhs = $0; sub(/::?.*/, "", lhs); sub(/^[ ]+/, "", lhs)
      n = split(lhs, t, /[ \t]+/)
      for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) print t[i]
    }
  ' "$1"
}

# WHAT COUNTS AS RUNNING THE SUITE, in one simple shell command (the text is split at
# unquoted `;`/`&&`/`||`/`|` first — AWK_SHELL below — so command position is simply
# the start): a FILE under the suite directory as the command (`./test/smoke.sh`), or
# handed to an interpreter in command position (`bash -e test/smoke.sh`, `python3
# test/x.py`, through the options that take an operand of their own: `bash -o pipefail
# test/smoke.sh`); or the directory itself, or a file in it, handed to a TEST RUNNER that
# takes directories (`bats test/`, `prove tests`, `pytest tests/`, `python3 -m pytest
# tests`, `-m unittest discover tests`). A bare directory given to a shell or executed directly (`bash test/`,
# `./test/`) only fails; a python module other than a test runner (`-m tokenize
# test/x.py`) reads the file and runs nothing — neither counts. `echo test/smoke.sh` and
# `shellcheck test/*.sh` mention the path and run nothing, so they do not count. All of it
# optionally under sudo or env, and after leading variable assignments (`CI=1 make test`
# is how a great many steps are written). `DIRS` is replaced per repo with the directory
# that is actually populated (_run_re), so a populated test/ is not credited by a step
# running a nonexistent tests/. No backslashes: these are handed to awk via -v, which
# would eat them, so `[.]` and `[/]` stand in for the escaped forms.
RUN_RE_TEMPLATE='^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((bash|sh|zsh|dash|ksh|python3?|node|pwsh)[[:space:]]+((-o|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*([.][/])?(DIRS)[/][^[:space:]]+|(bats|prove|pytest)[[:space:]]+([^[:space:]]+[[:space:]]+)*([.][/])?(DIRS)([/]|[[:space:]]|$)|python3?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-m[[:space:]]+(pytest|unittest|nose2?)([[:space:]]+[^[:space:]]+)*[[:space:]]+([.][/])?(DIRS)([/]|[[:space:]]|$)|([.][/])?(DIRS)[/][^[:space:]]+)'
_run_re() { printf '%s' "${RUN_RE_TEMPLATE//DIRS/$1}"; } # _run_re <dir-alternation: test|tests> — every DIRS, both arms
# A NO-EXECUTE MODE PARSES, PRINTS OR ASKS AND RUNS NOTHING. For make: dry-run (`-n` in any
# short cluster, --dry-run/--just-print/--recon), question (`-q`, --question), touch
# (`-t`, --touch — marks the target updated, runs no recipe), and the modes that exit
# before building (`-h`/--help, `-v`/--version) — anywhere in the argument list, since
# GNU make accepts options after goals; and a `-C`/`-f` (--directory/--file/--makefile)
# invocation, which builds from a DIFFERENT Makefile than the one whose targets were
# inspected, so the root target's recipe says nothing about it. `-C`/`-f` are matched
# with their operand attached too (`-fother.mk`, `-C../tools`); the cluster before them
# may not contain `I`, `o` or `W`, whose own attached operand could spell an `f`. Likewise
# a no-run letter counts only in a cluster that starts with no operand-taking option
# (`-O`, `-W`, `-o`, `-I`, `-f`, `-C`, `-j`, `-l`): `-Otarget` and `-Wnothing` are
# operands that happen to contain `t`/`n`/`h`, and make runs. For a POSIX
# shell: `-n` (syntax check) between it and its operand, looking past options that take an
# operand of their own (`bash -o pipefail -n x`) — ONLY the shells, because pwsh options
# are case-insensitive words (`-noprofile` runs). For node: --check / -c / -v, and the
# code-string modes -e/-p/--eval/--print; for python: -c (the operand is source text, not
# a file — a shell's -c, by contrast, executes its string) and the compile- or lint-only
# modules (`-m compileall tests/` byte-compiles; pyflakes/pylint/flake8/mypy/black/ruff/
# isort read the files and run nothing), and pytest's own non-executing modes
# (--collect-only/--co, --version, -h/--help) anywhere in its argument list. For every interpreter: its
# help and version modes (--help/--version, -h/-V, pwsh -Help/-Version/-?), which print
# and exit without touching the operand.
NORUN_RE='(^|[[:space:]])((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(make[[:space:]]+([^[:space:]]+[[:space:]]+)*(-[a-eg-ik-np-zA-BD-HJ-NP-VX-Z]*[nqhvt][a-zA-Z]*|-[a-np-zA-HJ-VX-Z]*[Cf][^[:space:]]*|--dry-run|--just-print|--recon|--question|--help|--version|--touch|--directory|--file|--makefile)([[:space:]=]|$)|(bash|sh|zsh|dash|ksh)[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(-[a-zA-Z]*n[a-zA-Z]*)([[:space:]]|$)|node[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(--check|-c|-v|-e|-p|--eval|--print)([[:space:]]|$)|python3?[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(-c([[:space:]]|$)|-m[[:space:]]+(compileall|py_compile|pyflakes|pylint|flake8|mypy|black|ruff|isort)([[:space:]]|$)|-m[[:space:]]+pytest([[:space:]]+[^[:space:]]+)*[[:space:]]+(--collect-only|--co|--version|-h|--help)([[:space:]]|$))|pytest([[:space:]]+[^[:space:]]+)*[[:space:]]+(--collect-only|--co|--version|-h|--help)([[:space:]]|$)|(bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(--version|--help|-V|-h|-Version|-Help|-[?])([[:space:]]|$))'

# THE SHELL-TEXT HELPERS, shared by both awk programs below (shell-level text, spliced in),
# so a workflow step and a Makefile recipe are read by the same rules:
#   * splitcmds — one simple command at a time, split at `;`/`&&`/`||`/`|` OUTSIDE quotes.
#     A naive split turned `echo "disabled && make test"` into a synthetic `make test"`.
#     Inside "…" a backslash escapes the next character, so `\"` does not end the string;
#     inside '…' nothing does. The operator before each command is kept (SPLITOP) and
#     cdnorm decides reachability for the decidable pairs: `true || make test` and
#     `false && make test` never reach make; `false || make test` always does. A shell
#     function body is spliced at each reachable call and judged there (cdnorm).
#   * stripcomment — a shell comment (`#` at the start, after whitespace, or right after
#     a control operator: `:;# …`) OUTSIDE quotes, so `echo "value #"; make test` keeps
#     its make and `:;# disabled && make test` has none.
#   * unquote_scalar — a YAML flow scalar: a fully "…"- or '…'-quoted value yields its
#     contents (with `\"` and `''` unescaped), anything after the closing quote being a
#     YAML comment; a plain value is returned as is (its ` #` comment is shell text too,
#     and stripcomment removes it). Unquoting runs BEFORE comment stripping, or
#     `run: "make test # suite"` loses its closing quote and never unquotes.
#   * cdnorm — a `cd test` (or tests) earlier in the same command list puts the commands
#     after it inside the suite directory, so `cd test && ./smoke.sh` is rewritten to
#     `./test/smoke.sh` and `cd tests && bash run.sh` to `bash tests/run.sh`; the regexes
#     then judge root-relative paths as always (a `make` there reads test/Makefile and is
#     not judged). A `cd` ANYWHERE ELSE (`cd docs`, `cd ..`, `cd tools`) puts the rest of
#     the list outside the tree this register inspected — a `make test` there is another
#     Makefile — so those commands are dropped, not judged. Shell `if` blocks and loops are
#     followed as far as they are static: a `false` body, a `true` else, a `while false`,
#     `until true` or `for x in;` body never run; a real condition (`if make test`) is a
#     command that runs; nothing after an unconditional `exit`/`exec`/`return` runs.
#   * pathok — the suite path a credited command names must EXIST: `bash test/missing.sh`
#     beside a real test/smoke.sh runs nothing. The set of entries under the populated
#     suite directories is handed in through `existl` (one relative path per line); a
#     literal operand must be in it, a glob must match one, the bare directory is fine,
#     and an operand carrying `$` cannot be checked and is taken on trust. The list is
#     passed inline (`existl`, newline-separated), never through a temp file.
#   * dequote — a command with its shell quotes removed, as the program sees its words.
#   * trim — whitespace only.
AWK_SHELL='
  function loadexist(lst,   n, a, i) { split("", EXIST); n = split(lst, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") EXIST[a[i]] = 1 }
  function globre(g,   r, i, c) {
    r = "^"
    for (i = 1; i <= length(g); i++) {
      c = substr(g, i, 1)
      if (c == "*") r = r "[^/]*"; else if (c == "?") r = r "[^/]"
      else if (c ~ /[.^$+(){}|\\\[\]]/) r = r "\\" c; else r = r c
    }
    return r "$"
  }
  function pathok(cmd,   t, k, n, w, i) {
    n = split(cmd, w, /[ \t]+/)
    for (i = 1; i <= n; i++) {
      t = w[i]; sub(/^[.][/]/, "", t)
      if (t !~ /^tests?([/]|$)/) continue
      if (t ~ /\$/) return 1
      sub(/[/]+$/, "", t)
      if (t ~ /^tests?$/) return 1
      if (t in EXIST) return 1
      if (t ~ /[*?[]/) { for (k in EXIST) if (k ~ globre(t)) return 1 }
      return 0
    }
    return 1
  }
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function splitcmds(s, out,   i, c, q, n, cur) {
    n = 0; cur = ""; q = ""; split("", SPLITOP); SPLITOP[1] = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "\"" && c == "\\") { cur = cur c substr(s, i + 1, 1); i++; continue }
      if (q != "") { if (c == q) q = ""; cur = cur c; continue }
      if (c == "\\") { cur = cur c substr(s, i + 1, 1); i++; continue }
      if (c == "\"" || c == SQ) { q = c; cur = cur c; continue }
      if (c == ";" || c == "&" || c == "|") {
        if (cur ~ /[^ \t]/) out[++n] = cur
        cur = ""
        # The operator BEFORE the next command: `||` runs it only when the previous one
        # failed, so `true || make test` never reaches make. Recorded in SPLITOP by index.
        SPLITOP[n + 1] = (c == "|" && substr(s, i + 1, 1) == "|") ? "||" : ((c == "&" && substr(s, i + 1, 1) == "&") ? "&&" : c)
        if (substr(s, i + 1, 1) == c) i++
        continue
      }
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
      if (c == "#" && prev ~ /[ \t;&|(]/) return substr(s, 1, i - 1)
      prev = c
    }
    return s
  }
  function fnbodies(c, n,   i, t, fn, depth, w, pend) {
    # SHELL FUNCTION BODIES run only when the function is CALLED. A first pass marks every
    # command inside a `name() {` / `function name {` body with its function name (a bare
    # `{ … }` is a group and runs where it stands), then records which functions are
    # invoked as a command outside any body; cdnorm drops the body of a function that is
    # never invoked, so dead command text cannot meet the floor. The opener and the
    # closing `}` are not commands; a first body command on the same line as the opener is.
    split("", BODY); split("", FNAME); fn = ""; depth = 0; pend = ""
    for (i = 1; i <= n; i++) {
      t = trim(c[i])
      # `name()` (or `function name`) alone declares a function whose `{` opens on the
      # next command: the declaration is pending until that brace.
      if (fn == "" && pend == "" && (t ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)$/ || t ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*$/)) {
        pend = t; sub(/^function[ \t]+/, "", pend); sub(/[ \t]*\(\)$/, "", pend); BODY[i] = "@"; continue
      }
      if (pend != "" && t ~ /^\{/) { fn = pend; FNAME[fn] = i; depth = 1; pend = ""; sub(/^\{[ \t]*/, "", t); c[i] = trim(t); if (c[i] == "") { BODY[i] = "@"; continue } ; BODY[i] = fn; continue }
      pend = ""
      if (fn == "" && match(t, /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*(\(\))?[ \t]*\{/)) {
        if (t ~ /^function[ \t]/ || t ~ /\(\)/) {
          fn = t; sub(/^function[ \t]+/, "", fn); sub(/[ \t]*(\(\))?[ \t]*\{.*$/, "", fn)
          FNAME[fn] = i
          depth = 1; t = substr(t, RLENGTH + 1); c[i] = trim(t)
          if (c[i] == "") { BODY[i] = "@"; continue }
        }
      }
      if (fn != "") {
        if (t ~ /^\{([ \t]|$)/) depth++
        if (t ~ /^\}([ \t]|$)/) { depth--; if (depth == 0) { BODY[i] = "@"; fn = ""; continue } }
        BODY[i] = fn
      }
    }
  }
  # cdnorm runs the reachability pass TWICE: pass 1 on a copy with every function body
  # dropped, recording which function names are invoked by a command that is itself
  # reachable; pass 2 for real, keeping the bodies of exactly those functions. A call made
  # only inside `if false` invokes nothing.
  # cdnorm runs the reachability pass TWICE: pass 1 on a copy with every function body
  # dropped, recording which function names are invoked by a command that is itself
  # reachable (transitively through invoked bodies); then the reachable calls are
  # EXPANDED IN PLACE — the body is spliced at each call site, nested calls too, so it is
  # judged in the context of the call (a `cd tools` before the call applies to it, a
  # `return` ends only that body) — and pass 2 runs for real on the expanded list. A body
  # at its definition is never a command. Returns the new command count.
  function cdnorm(c, n,   i, k, m, c2, changed, w, f, t, kw) {
    fnbodies(c, n)
    split("", INVOKED)
    for (i = 1; i <= n; i++) c2[i] = c[i]
    cdpass(c2, n, 0)
    do {
      changed = 0
      for (i = 1; i <= n; i++) if ((i in BODY) && (BODY[i] in INVOKED)) {
        w = trim(c[i]); sub(/[ \t].*$/, "", w)
        if ((w in FNAME) && !(w in INVOKED)) { INVOKED[w] = 1; changed = 1 }
      }
    } while (changed)
    split("", E); split("", EOP); split("", EINL); m = 0; ncall = 0
    for (i = 1; i <= n; i++) {
      if (i in BODY) continue
      # A call may sit behind a then/do/else keyword (`if true; then suite; fi`): the
      # keyword is emitted on its own and the body follows it.
      t = trim(c[i]); kw = ""
      if (match(t, /^(then|do|else)[ \t]+/)) { kw = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1) }
      w = t; sub(/[ \t].*$/, "", w)
      if ((w in INVOKED) && FNAME[w] < i) {
        if (kw != "") { E[++m] = kw; EOP[m] = SPLITOP[i]; EINL[m] = 0 }
        m = inline(c, n, m, w, (kw != "" ? ";" : SPLITOP[i]), 1)
      }
      else { E[++m] = c[i]; EOP[m] = SPLITOP[i]; EINL[m] = 0 }
    }
    split("", BODY); split("", INL)
    for (k = 1; k <= m; k++) { c[k] = E[k]; SPLITOP[k] = EOP[k]; INL[k] = EINL[k] }
    for (k = m + 1; k <= n; k++) { c[k] = ""; delete SPLITOP[k] }
    cdpass(c, m, 1)
    return m
  }
  function inline(c, n, m, f, op, depth,   j, w, first, id) {
    id = ++ncall; first = 1
    for (j = 1; j <= n; j++) if ((j in BODY) && BODY[j] == f) {
      w = trim(c[j]); sub(/[ \t].*$/, "", w)
      if ((w in INVOKED) && w != f && depth < 4) m = inline(c, n, m, w, (first ? op : SPLITOP[j]), depth + 1)
      else { E[++m] = c[j]; EOP[m] = (first ? op : SPLITOP[j]); EINL[m] = id }
      first = 0
    }
    return m
  }
  # lit(t) — the static status of one command: "true", "false", or "" (unknown).
  # lit(t) also decides a LITERAL test: `[ -n x ]`, `[ -z "" ]`, `test x = x`, `[ a != b ]`
  # with `$`-free operands (a quoted empty string counts as empty). Anything else is "".
  function lit(t,   a, b, op) {
    if (t == "true" || t == ":") return "true"
    if (t == "false") return "false"
    if (t ~ /\$/) return ""
    if (t ~ /^\[[ \t].*[ \t]\]$/) { sub(/^\[[ \t]+/, "", t); sub(/[ \t]+\]$/, "", t) }
    else if (t ~ /^test[ \t]/) sub(/^test[ \t]+/, "", t)
    else return ""
    if (match(t, /^-n[ \t]+/)) { a = substr(t, RLENGTH + 1); gsub(/^["\047]|["\047]$/, "", a); return (a != "") ? "true" : "false" }
    if (match(t, /^-z[ \t]+/)) { a = substr(t, RLENGTH + 1); gsub(/^["\047]|["\047]$/, "", a); return (a == "") ? "true" : "false" }
    if (match(t, /[ \t]+(=|!=|==)[ \t]+/)) {
      a = substr(t, 1, RSTART - 1); op = substr(t, RSTART, RLENGTH); b = substr(t, RSTART + RLENGTH)
      gsub(/[ \t]/, "", op); gsub(/^["\047]|["\047]$/, "", a); gsub(/^["\047]|["\047]$/, "", b)
      if (a ~ /[ \t]/ || b ~ /[ \t]/) return ""
      return ((a == b) == (op != "!=")) ? "true" : "false"
    }
    return ""
  }
  # condlist(c, n, i, first) — a COMPOUND condition `if a && b || c; then` was split at its
  # operators before the `if` was seen. Starting from the condition text `first` at index
  # i, fold the following `&&`/`||` arms (up to the command that begins with then/do) into
  # one static status with three-valued logic — `unknown && false` is false, `unknown ||
  # true` is true, the rest unknown — and mark each folded arm in COND with the command
  # it contributes (its text when it can run, "" when a literal or unreachable), and
  # CONDEND with the last index folded. Returns the status.
  function condlist(c, n, i, first,   j, r, t, op, a) {
    r = lit(first); CONDEND = i; split("", COND)
    for (j = i + 1; j <= n; j++) {
      op = SPLITOP[j]
      if (op != "&&" && op != "||") break
      t = trim(c[j])
      if (t ~ /^(then|do)([ \t]|$)/) break
      a = lit(t)
      if (op == "&&") { if (r == "false") { COND[j] = ""; } else { COND[j] = (a == "" ? t : ""); r = (a == "false") ? "false" : ((a == "true") ? r : ((r == "false") ? "false" : "")) } }
      else            { if (r == "true")  { COND[j] = ""; } else { COND[j] = (a == "" ? t : ""); r = (a == "true") ? "true" : ((a == "false") ? r : ((r == "true") ? "true" : "")) } }
      CONDEND = j
    }
    return r
  }
  function cdpass(c, n, final,   i, d, t, m, x, st, skip, nest, kw, lvl, w, term, outer, r, sd, subterm, retid, closing, ee) {
    d = ""; x = 0; st = ""; nest = 0; skip = 0; term = 0; sd = 0; subterm = 0; retid = 0; ee = ERREXIT
    split("", TAKEN); split("", SKIPD); split("", DEF); split("", COND)
    for (i = 1; i <= n; i++) {
      # A SUBSHELL `( … )` has its own exit: an `exit` inside it ends the subshell only.
      # Its depth is tracked by leading `(` and trailing `)` on the split commands.
      t = trim(c[i]); closing = 0
      while (t ~ /^\(/) { sd++; sub(/^\([ \t]*/, "", t) }
      while (t ~ /\)$/) { closing++; sub(/[ \t]*\)$/, "", t) }
      c[i] = t
      if (subterm && sd >= subterm) { c[i] = ""; sd -= closing; if (sd < subterm) subterm = 0; continue }
      sd -= closing
      # A `return` inside a body expanded at a call site ends that body only.
      if (retid && INL[i] == retid) { c[i] = ""; continue }
      retid = 0
      # An arm folded into a preceding compound condition: emit what condlist decided.
      if (i in COND) { c[i] = (skip ? "" : COND[i]); continue }
      if ((i in BODY) && (BODY[i] == "@" || !(BODY[i] in INVOKED))) { c[i] = ""; continue }
      # Reachability, for the statically decidable pairs. `st` is the status of the AND-OR
      # list EVALUATED so far — "true" after a literal true/`:`, "false" after a literal
      # false, "" when unknown — and only a command that RUNS updates it: a skipped arm
      # leaves it alone, so `true || false || make test` never reaches make (the `false`
      # never ran) while `false && true || make test` does (the `true` never ran, the list
      # is still false). Behind `||` a command runs only on a failed list — credited after
      # "false", skipped after "true", and (conservatively) not credited when unknown;
      # behind `&&` it runs unless the list is "false".
      if (SPLITOP[i] == "||") { if (st != "false") { if (st == "") st = ""; c[i] = ""; continue } }
      if (SPLITOP[i] == "&&") { if (st == "false") { c[i] = ""; continue } }
      # A single `&` backgrounds the previous command; the next one always runs.
      t = trim(c[i])
      st = (t == "true" || t == ":") ? "true" : ((t == "false") ? "false" : "")
      # Shell control flow, as far as it is static, PER NESTING DEPTH: an `if false` body
      # never runs and an `if true` else never runs, at whatever depth; any other
      # condition may run either. The keywords then/do/else/elif carry no command of
      # their own and are stripped; a command is dropped while any enclosing level skips.
      # Per level, TAKEN records whether a branch of the conditional has been taken —
      # "yes" after `if true`/`elif true`, "no" while every condition so far was a literal
      # false, "" once a runtime condition was seen — so an `elif`/`else` after a taken
      # branch never runs, an `elif false` never runs, and an `else` after only false
      # conditions always does.
      kw = ""
      if (match(t, /^(then|do|else|elif)([ \t]+|$)/)) { kw = substr(t, 1, RLENGTH); sub(/[ \t]+$/, "", kw); t = substr(t, RLENGTH + 1) }
      if (kw == "else" && nest) { SKIPD[nest] = (TAKEN[nest] == "yes"); DEF[nest] = (TAKEN[nest] == "no") }
      if (kw == "elif") {
        outer = 0; for (lvl = 1; lvl < nest; lvl++) if (SKIPD[lvl]) outer = 1
        m = ""
        if (nest) {
          m = condlist(c, n, i, t)
          if (outer || TAKEN[nest] == "yes") for (w in COND) COND[w] = ""
          DEF[nest] = 0
          if (TAKEN[nest] == "yes") SKIPD[nest] = 1
          else if (m == "false") SKIPD[nest] = 1
          else { SKIPD[nest] = 0; if (m == "true" && TAKEN[nest] == "no") { TAKEN[nest] = "yes"; DEF[nest] = 1 } else TAKEN[nest] = "" }
        }
        # An elif condition runs when no earlier branch was taken and the if is reachable.
        c[i] = (nest && lit(t) == "" && !outer && TAKEN[nest] != "yes") ? t : ""
        skip = 0; for (lvl = 1; lvl <= nest; lvl++) if (SKIPD[lvl]) skip = 1; continue
      }
      if (term) { c[i] = ""; continue }
      if (t ~ /^if([ \t]|$)/) {
        # The CONDITION is a command that runs (when the `if` itself is reachable):
        # `if make test; then …` executes the suite. A literal true/false is not a command.
        # A compound condition is folded by condlist (three-valued), its arms emitted or
        # dropped as decided there.
        outer = skip
        sub(/^if[ \t]*/, "", t)
        m = condlist(c, n, i, t)
        if (outer) for (w in COND) COND[w] = ""
        nest++
        TAKEN[nest] = (m == "true") ? "yes" : ((m == "false") ? "no" : "")
        SKIPD[nest] = (m == "false")
        DEF[nest] = (m == "true")
        skip = 0; for (lvl = 1; lvl <= nest; lvl++) if (SKIPD[lvl]) skip = 1
        c[i] = (lit(t) == "" && !outer && t != "") ? t : ""
        continue
      }
      if (t ~ /^fi([ \t]|$)/) { if (nest) { delete TAKEN[nest]; delete SKIPD[nest]; delete DEF[nest]; nest-- } ; skip = 0; for (lvl = 1; lvl <= nest; lvl++) if (SKIPD[lvl]) skip = 1; c[i] = ""; continue }
      # Loops, as far as they are static: `while false` and `until true` never run their
      # body; any other loop (a runtime condition, `while true`, `for`) may. A loop is a
      # level like an `if`, closed by `done`.
      if (t ~ /^(while|until|for)([ \t]|$)/) {
        outer = skip
        # `while false`, `until true` and `for x in;` (an empty literal list) never run
        # their body. A while/until condition that is a real command runs at least once;
        # a compound one is folded like an if condition.
        if (t ~ /^for([ \t]|$)/) { m = (t ~ /^for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]*$/) ? "false" : ""; r = "" }
        else {
          kw = (t ~ /^while/) ? "while" : "until"
          sub(/^(while|until)[ \t]*/, "", t)
          r = condlist(c, n, i, t)
          if (outer) for (w in COND) COND[w] = ""
          m = (kw == "while") ? ((r == "false") ? "false" : "") : ((r == "true") ? "false" : "")
        }
        nest++
        TAKEN[nest] = ""
        SKIPD[nest] = (m == "false")
        # The body certainly runs at least once for `while true`, `until false`, or a
        # `for` over a non-empty literal list.
        DEF[nest] = ((kw == "while" && r == "true") || (kw == "until" && r == "false") || (t ~ /^for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+[^ \t]/ && t !~ /\$/))
        skip = 0; for (lvl = 1; lvl <= nest; lvl++) if (SKIPD[lvl]) skip = 1
        c[i] = (t !~ /^for/ && lit(t) == "" && !outer && t != "" && kw != "") ? t : ""
        kw = ""
        continue
      }
      if (t ~ /^done([ \t]|$)/) { if (nest) { delete TAKEN[nest]; delete SKIPD[nest]; delete DEF[nest]; nest-- } ; skip = 0; for (lvl = 1; lvl <= nest; lvl++) if (SKIPD[lvl]) skip = 1; c[i] = ""; continue }
      skip = 0; for (lvl = 1; lvl <= nest; lvl++) if (SKIPD[lvl]) skip = 1
      # A group or subshell runs where it stands: `{ make test; }` and `( make test )` are
      # `make test` in command position once the delimiters go.
      sub(/^[{][ \t]+/, "", t)
      if (t ~ /^[{}]$/ || t == "") t = ""
      if (skip || t == "") { c[i] = ""; continue }
      # An unconditional `exit`/`exec`/`return` ends what can run: at the top level nothing
      # after it is reachable; inside a block, nothing further in that block is.
      # …and when every enclosing branch is statically CERTAIN to run (DEF), the exit is
      # certain too and ends the whole shell: `if true; then exit 0; fi; make test` never
      # reaches make. Under a runtime condition it may run, so only its block ends.
      if (t ~ /^(exit|exec|return)([ \t]|$)/) {
        if (t ~ /^return/ && INL[i]) { retid = INL[i]; c[i] = ""; continue }
        if (sd + closing > 0) { subterm = sd + closing; c[i] = ""; if (sd < subterm) subterm = 0; continue }
        w = 1; for (lvl = 1; lvl <= nest; lvl++) if (!DEF[lvl]) w = 0
        if (nest == 0 || w) term = 1; else SKIPD[nest] = 1
        skip = 1; c[i] = ""; continue
      }
      c[i] = t
      # A call counts only AFTER the definition (FNAME holds its index): `suite; suite() {…}`
      # fails at the call and never reaches the body.
      if (!final) { w = t; sub(/^(then|do|else)[ \t]+/, "", w); sub(/[ \t].*$/, "", w); if ((w in FNAME) && FNAME[w] < i) INVOKED[w] = 1 }
      # ERREXIT (ERREXIT is set by the caller): a workflow step runs under `bash -e` unless
      # it says `set +e`, so a bare literal `false` — not an arm of `&&`/`||`/`|`, not
      # backgrounded — ends the shell exactly as an `exit` would, certain where its
      # branches are certain. A Makefile recipe line runs under plain `sh -c`, so there
      # the same `false; make test` runs make.
      if (t ~ /^set[ \t]/) { if (t ~ /[ \t]\+e([ \t]|$)/ || t ~ /\+o[ \t]+errexit/) ee = 0; else if (t ~ /[ \t]-[a-zA-Z]*e/ || t ~ /-o[ \t]+errexit/) ee = 1 }
      if (ee && t == "false" && SPLITOP[i + 1] !~ /^(&&|\|\||\||&)$/) {
        w = 1; for (lvl = 1; lvl <= nest; lvl++) if (!DEF[lvl]) w = 0
        if (nest == 0 || w) term = 1; else SKIPD[nest] = 1
      }
      if (match(t, /^cd[ \t]+/)) {
        d = unquote_scalar(substr(t, RLENGTH + 1)); sub(/^[.][/]/, "", d); sub(/[/]+$/, "", d)
        if (d ~ /^tests?$/) { x = 0; continue }
        if (d == "" || d == ".") { d = ""; x = 0; continue }
        x = 1; d = ""; continue
      }
      if (x) { c[i] = ""; continue }
      if (d == "") continue
      # Inside the suite directory, `make` reads test/Makefile, not the root one whose
      # targets were inspected — so it is not judged against them.
      if (t ~ /^((sudo|env)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*make([ \t]|$)/) { c[i] = ""; continue }
      if (t ~ /^[.][/]/) { sub(/^[.][/]/, "./" d "/", t); c[i] = t; continue }
      if (match(t, /^((sudo|env)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*(bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[ \t]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[ \t]+[^ \t]+[ \t]+|-[^ \t]+[ \t]+)*/)) {
        m = RLENGTH
        if (substr(t, m + 1, 1) !~ /[-\/]/ && substr(t, m + 1) != "") c[i] = substr(t, 1, m) d "/" substr(t, m + 1)
      }
    }
  }
  # dequote(s) — a command with its shell quotes REMOVED and their contents kept, the way
  # the shell hands words to the program: `bash "test/smoke.sh"` runs test/smoke.sh and
  # `make "test"` builds test. Applied once reachability has been decided (quotes matter
  # to the splitter and the comment stripper, not to what a word names). Inside "…" a
  # backslash escapes the next character; inside a single-quoted string nothing does.
  function dequote(s,   i, c, q, out) {
    out = ""; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "\"") { if (c == "\\") { out = out substr(s, i + 1, 1); i++ } else if (c == "\"") q = ""; else out = out c; continue }
      if (q == SQ) { if (c == SQ) q = ""; else out = out c; continue }
      if (c == "\"" || c == SQ) { q = c; continue }
      if (c == "\\") { out = out substr(s, i + 1, 1); i++; continue }
      out = out c
    }
    return out
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
  #     `make test` runs `echo make test`. A heredoc payload inside a literal block is
  #     data and is dropped up to its delimiter line.
  #   * a step with a statically false `if:` never runs, nor does any step of a job with
  #     one; a runtime condition may.
  #   * a step runs under `bash -e` (the default shell invocation on GitHub): a bare
  #     literal `false` ends it unless the step said `set +e` first (ERREXIT, in cdnorm).
  #   * a step runs in its EFFECTIVE WORKING DIRECTORY: its own `working-directory:`, else
  #     the job's `defaults.run.working-directory`, else the workflow's. Every line is
  #     emitted as `cd <dir> && <line>`, so cdnorm judges it like a `cd` in the command
  #     itself: `make test` from `tools/` is another Makefile and does not count.
  # YAML MAPPING ORDER IS NOT SEMANTIC: a job's `if:` or `defaults:` may follow its
  # `steps:`, a step's `working-directory:` may precede its `run:`. So NOTHING is emitted
  # until the file ends — each step's lines are held with the step's own settings and the
  # job they belong to, and resolved once every job- and workflow-level key has been seen.
  # Block lines are the lines indented deeper than the key, and are emitted at column 0.
  awk -v SQ="'" -v ERREXIT=1 "$AWK_SHELL"'
    function emit(s,   c, n, i) { s = trim(stripcomment(s)); n = splitcmds(s, c); n = cdnorm(c, n); for (i = 1; i <= n; i++) if (trim(c[i]) != "") print trim(dequote(c[i])) }
    function flushblock() { if (acc != "") { held[++nheld] = acc; acc = "" } }
    function flushstep(   i, all) {
      if (inblock) { flushblock(); inblock = 0 }
      # ONE SHELL per step: its lines are joined with `;` so a `cd`, an `if false; then`
      # or a `fi` on one line governs the lines after it, as it does when the step runs.
      # Each line loses its shell comment BEFORE the join — a `# note` line would
      # otherwise comment out every line joined after it.
      # A line ending in `&&`/`||`/`|` (or beginning with one) continues its list onto the
      # next line: joined with a space, not a `;`, or `false &&` over `make test` would
      # become two reachable commands.
      all = ""
      for (i = 1; i <= nheld; i++) {
        line = trim(stripcomment(held[i])); if (line == "") continue
        if (all == "") all = line
        else if (all ~ /(&&|\|\||\||;)$/ || line ~ /^(&&|\|\||\|)/) all = all " " line
        else all = all " ; " line
      }
      if (nheld) { nh++; H[nh] = all; HWD[nh] = stepwd; HOFF[nh] = stepoff; HJOB[nh] = jobidx }
      nheld = 0; stepwd = ""; stepoff = 0
    }
    function keyval(s) { sub(/^[^:]*:[ \t]*/, "", s); return unquote_scalar(stripcomment(s)) }
    # GitHub coerces `false`, `0`, `null` and the empty string to false in an expression.
    function isfalse(v) { return v ~ /^(\$\{\{[ \t]*)?(false|0|null|\047\047|"")?([ \t]*\}\})?$/ }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) { flushblock(); next }
        match($0, /^[ \t]*/)
        if (RLENGTH > bind) {
          line = trim($0)
          # A HEREDOC PAYLOAD is data, not commands: from a `<<DELIM` / `<<'DELIM'` /
          # `<<\DELIM` / `<<-DELIM` (not `<<<`, a herestring) to the line that is exactly DELIM, the
          # lines are written somewhere, never run. The command carrying the operator is
          # kept; the payload is dropped.
          if (hd != "") { if (line == hd) hd = ""; next }
          if (!fold && match(line, /(^|[^<])<<-?[ \t]*([\047"]|\\)?[A-Za-z_][A-Za-z0-9_]*/)) {
            hd = substr(line, RSTART, RLENGTH); sub(/^.*<<-?[ \t]*([\047"]|\\)?/, "", hd)
          }
          if (fold) { acc = (acc == "" ? line : acc " " line); next }
          if (line ~ /\\$/) { acc = acc substr(line, 1, length(line) - 1) " "; next }
          acc = acc line; flushblock(); next
        }
        flushblock()
        inblock = 0; hd = ""
      }
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      match($0, /^[ \t]*/); ind = RLENGTH
      # YAML allows a sequence item at the indent of its parent key (`steps:` over `- run:`),
      # so a `- ` at the steps column is a step, not the end of the block.
      if (insteps && (ind < sind || (ind == sind && $0 !~ /^[ \t]*-[ \t]/))) { flushstep(); insteps = 0; dind = -1; rind = -1 }
      if (!insteps) {
        if ($0 ~ /^jobs:[ \t]*(#.*)?$/) { injobs = 1; jobind = -1; dind = -1; rind = -1; next }
        if (injobs) {
          if (ind == 0) { injobs = 0; dind = -1; rind = -1 }
          else {
            if (jobind < 0) jobind = ind
            if (ind == jobind) { jobidx++; propind = -1; dind = -1; rind = -1; next }
            if (propind < 0) propind = ind
            if (ind == propind && $0 ~ /^[ \t]*if:/ && isfalse(keyval($0))) JOFF[jobidx] = 1
          }
        }
        if ($0 ~ /^[ \t]*steps:[ \t]*(#.*)?$/) { sind = ind; insteps = 1; keycol = -1; next }
        # Only `defaults: → run: → working-directory:` is a default. The path is tracked
        # by indentation: `defaults:` opens at its column, `run:` beneath it, and the key
        # beneath that; a line at or above either column closes it. A `working-directory`
        # under `strategy.matrix` (or anywhere else) is data.
        if (dind >= 0 && ind <= dind) { dind = -1; rind = -1 }
        if (rind >= 0 && ind <= rind) rind = -1
        if ($0 ~ /^[ \t]*defaults:[ \t]*(#.*)?$/) { dind = ind; rind = -1; next }
        if (dind >= 0 && rind < 0 && $0 ~ /^[ \t]*run:[ \t]*(#.*)?$/) { rind = ind; next }
        if (dind >= 0 && rind >= 0 && $0 ~ /^[ \t]*working-directory:/) { if (injobs) JWD[jobidx] = keyval($0); else wfwd = keyval($0) }
        next
      }
      # RLENGTH is read into a local BEFORE flushstep(): the helpers it runs call match()
      # and sub() themselves, and a clobbered RLENGTH mis-set the key column so that every
      # step after the first in a job was silently dropped.
      if (match($0, /^[ \t]*-[ \t]+/)) { kc = RLENGTH; flushstep(); keycol = kc }
      if ($0 ~ /^[ \t]*(-[ \t]+)?working-directory:/) { match($0, /^[ \t]*(-[ \t]+)?/); if (RLENGTH == keycol) stepwd = keyval($0) }
      if ($0 ~ /^[ \t]*(-[ \t]+)?if:/) { match($0, /^[ \t]*(-[ \t]+)?/); if (RLENGTH == keycol && isfalse(keyval($0))) stepoff = 1 }
      if (match($0, /^[ \t]*(-[ \t]+)?run:([ \t]|$)/)) {
        rest = substr($0, RSTART + RLENGTH)
        match($0, /^[ \t]*(-[ \t]+)?/); bind = RLENGTH
        if (bind != keycol) next
        if (rest ~ /^[ \t]*[|>]/) { inblock = 1; fold = (rest ~ /^[ \t]*>/); acc = "" }
        else held[++nheld] = unquote_scalar(rest)
      }
    }
    END {
      flushstep()
      for (k = 1; k <= nh; k++) {
        j = HJOB[k]
        if (HOFF[k] || JOFF[j]) continue
        wd = (HWD[k] != "" ? HWD[k] : (JWD[j] != "" ? JWD[j] : wfwd))
        emit((wd != "" && wd !~ /^[.][\/]?$/) ? "cd " wd " && " H[k] : H[k])
      }
    }
  ' "$1"
}

_suite_targets() { # _suite_targets <Makefile> <run-re> [exist-list] → targets that run the suite, one per line
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
  # rules at column 0, recipes on tab lines, comments and variable assignments ignored,
  # conditionals decided as in _targets (AWK_MAKECOND), nothing in a define body counted.
  awk -v re="$2" -v nore="$NORUN_RE" -v SQ="'" -v ERREXIT=0 -v existl="${3:-}" "$AWK_SHELL$AWK_MAKECOND"'
    BEGIN { loadexist(existl) }
    function runs(line,   n, c, i, w) {
      sub(/^[ \t]*[@+-]*[ \t]*/, "", line)
      n = splitcmds(trim(stripcomment(line)), c); n = cdnorm(c, n)
      for (i = 1; i <= n; i++) { w = trim(dequote(c[i])); if (w ~ re && w !~ nore && pathok(w)) return 1 }
      return 0
    }
    # A single-colon rule that carries a recipe REPLACES any earlier recipe for its
    # targets (make warns and keeps the last), so `test:; ./test/smoke.sh` followed by
    # `test:; @true` runs only true; a rule with no recipe adds prerequisites and keeps
    # the recipe; a double-colon rule is additive. `fresh` is set by a rule line and
    # consumed by the first recipe line of that rule.
    function handle(l,   lhs, rhs, inl, n, t, i) {
      if (indef) { if (l ~ /^[ ]*endef([ \t]|$)/) indef = 0; return }
      if (l ~ /^[ ]*define([ \t]|$)/) { indef = 1; ncur = 0; return }
      if (mc_line(l)) { ncur = 0; return }
      if (mc_active() != "1") return
      if (l ~ /^\t/) {
        if (fresh) { for (i = 1; i <= ncur; i++) hit[cur[i]] = 0; fresh = 0 }
        if (runs(l)) for (i = 1; i <= ncur; i++) hit[cur[i]] = 1
        return
      }
      if (l ~ /^[ ]*[^\t#. ][^:=]*::?([^=]|$)/) {
        lhs = l; sub(/::?.*/, "", lhs); sub(/^[ ]+/, "", lhs)
        rhs = l; sub(/^[^:]*::?/, "", rhs); sub(/#.*/, "", rhs)
        fresh = (l !~ /^[^:]*::/)
        inl = ""; hassemi = 0
        if (match(rhs, /;/)) { inl = substr(rhs, RSTART + 1); rhs = substr(rhs, 1, RSTART - 1); hassemi = 1 }
        n = split(lhs, t, /[ \t]+/); ncur = 0
        for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) { cur[++ncur] = t[i]; pre[t[i]] = pre[t[i]] " " rhs; seen[t[i]] = 1 }
        # `test: ;` is an EMPTY recipe, and it replaces the earlier one all the same.
        if (hassemi) {
          if (fresh) { for (i = 1; i <= ncur; i++) hit[cur[i]] = 0; fresh = 0 }
          if (runs(inl)) for (i = 1; i <= ncur; i++) hit[cur[i]] = 1
        }
        return
      }
      # A blank or comment-only line between a rule and its recipe is permitted by make
      # and changes nothing; anything else (a variable, a directive) ends the rule.
      if (l ~ /^[ \t]*$/ || l ~ /^[ \t]*#/) return
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
        for (k in seen) if (!hit[k]) {
          m = split(pre[k], p, /[ \t]+/)
          for (i = 1; i <= m; i++) if (hit[p[i]]) { hit[k] = 1; changed = 1; break }
        }
      } while (changed)
      for (k in hit) if (hit[k]) print k
    }
  ' "$1"
}

_phony_targets() { # _phony_targets <Makefile> → every name declared .PHONY, one per line (conditionals decided as in _targets)
  awk "$AWK_MAKECOND"'
    { if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1) " "; next } ; l = buf $0; buf = "" }
    indef { if (l ~ /^[ ]*endef([ \t]|$)/) indef = 0; next }
    l ~ /^[ ]*define([ \t]|$)/ { indef = 1; next }
    mc_line(l) { next }
    mc_active() != "1" { next }
    l ~ /^[ ]*[.]PHONY[ \t]*:/ { sub(/^[ ]*[.]PHONY[ \t]*:/, "", l); sub(/#.*/, "", l); n = split(l, t, /[ \t]+/); for (i = 1; i <= n; i++) if (t[i] != "") print t[i] }
  ' "$1"
}

_ere_escape() { # _ere_escape <string> → the string as a literal inside a POSIX ERE
  # The COMPLETE ERE metacharacter set, so a legal target such as `test+coverage` or
  # `t(1)` matches itself instead of rewriting — or breaking — the pattern it lands in.
  printf '%s' "$1" | sed 's/[][\\.|*?+(){}^$]/\\&/g'
}

_suite_dirs() { # _suite_dirs <repo-dir> → "test|tests" (the POPULATED ones), or ""
  local d="$1" cand dirs=""
  for cand in test tests; do
    [[ -d "$d/$cand" ]] || continue
    # `ls -A` is portable and empty output means empty dir (`find -mindepth` is GNU).
    [[ -n "$(ls -A "$d/$cand" 2>/dev/null)" ]] && dirs="${dirs:+$dirs|}$cand"
  done
  printf '%s' "$dirs"
}

_exist_list() { # _exist_list <repo-dir> → every entry under the suite dirs, relative, one per line
  ( cd "$1" && find test tests -mindepth 1 2>/dev/null )
}

_suite_names() { # _suite_names <repo-dir> → the make targets credited with running the suite, one per line
  # A suite target whose name is ALSO A PATH in the repo — `test:` beside the `test/`
  # directory it runs — must be declared .PHONY, or `make test` says "is up to date" and
  # runs nothing. That is the single most likely way a repo adopting this floor gets a
  # green cell for a suite that never executes, so the target is not credited without it.
  local d="$1" dirs mktext phony tgt
  [[ -f "$d/Makefile" ]] || return 0
  dirs="$(_suite_dirs "$d")"
  [[ -n "$dirs" ]] || return 0
  mktext="$(_makefile_text "$d")" || mktext=""   # a missing mandatory include: no targets at all
  phony="$(_phony_targets <(printf '%s\n' "$mktext"))"
  while IFS= read -r tgt; do
    [[ -n "$tgt" ]] || continue
    if [[ -e "$d/$tgt" ]] && ! grep -qxF -- "$tgt" <<<"$phony"; then continue; fi
    printf '%s\n' "$tgt"
  done < <(_suite_targets <(printf '%s\n' "$mktext") "$(_run_re "$dirs")" "$(_exist_list "$d")")
}

_test_floor() { # _test_floor <repo-dir> → ok | no-dir | empty | not-in-ci
  local d="$1" dirs wf alt="" tgt cmds hits re existl
  # Either directory name satisfies the floor, and only a POPULATED one is the suite: a
  # stale empty test/ beside a real, CI-run tests/ must not read as `empty`, and a step
  # that runs a nonexistent tests/ must not credit a populated test/ it never touches.
  [[ -d "$d/test" || -d "$d/tests" ]] || { printf 'no-dir'; return 0; }
  dirs="$(_suite_dirs "$d")"
  [[ -n "$dirs" ]] || { printf 'empty'; return 0; }
  re="$(_run_re "$dirs")"
  existl="$(_exist_list "$d")"
  # What counts as running it: a step that executes the directory (the run regex), or
  # invokes `make` on a target whose recipe does (_suite_names). `test` earns its place
  # like any other — a `test:` whose recipe is `@true` runs nothing.
  while IFS= read -r tgt; do
    [[ -n "$tgt" ]] && alt="${alt:+$alt|}$(_ere_escape "$tgt")"
  done < <(_suite_names "$d")
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
    # A make option that TAKES AN ARGUMENT and does not change which Makefile runs (-I dir,
    # -o/-W file and their long forms) is removed with its argument first, so `make -I test
    # lint` does not read the directory operand as the goal — on make commands ONLY, so
    # `python -I test/smoke.py` keeps its operand. `-C`/`-f` are not rewritten: they select
    # another Makefile and NORUN_RE rejects the invocation outright.
    cmds="$(_run_lines "$wf" | sed -E '/^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*make([[:space:]]|$)/ s/(^|[[:space:]])(-[IoW]|--(include-dir|old-file|assume-old|what-if|new-file|assume-new))[[:space:]]+[^[:space:]]+/\1/g')"
    hits="$(grep -E "($re|^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*make[[:space:]]+([^[:space:]]+[[:space:]]+)*($alt)([[:space:]]|\$))" <<<"$cmds" | grep -vE "$NORUN_RE" |
      awk -v SQ="'" -v existl="$existl" "$AWK_SHELL"'BEGIN { loadexist(existl) } pathok($0) { print }')"
    if [[ -n "$hits" ]]; then
      printf 'ok'
      return 0
    fi
  done
  printf 'not-in-ci'
}

rows=""
missing=0
floor_short=0
present=0
for repo in "${REPOS[@]}"; do
  dir="$(resolve_repo_dir "$REPOS_ROOT" "$repo")" || dir="$REPOS_ROOT/$repo"
  # `-e`, not `-d`: .git is a FILE in a worktree checkout.
  [[ -e "$dir/.git" ]] || continue
  present=$((present + 1))
  line="| \`${repo#dotfiles-}\` |"
  have=""
  suite=""; sdirs="$(_suite_dirs "$dir")"
  if [[ -f "$dir/Makefile" ]]; then
    mktext="$(_makefile_text "$dir")" || mktext=""   # a missing mandatory include: no targets at all
    have="$(_targets <(printf '%s\n' "$mktext"))"
    suite="$(_suite_names "$dir")"
  fi
  for v in "${VERBS[@]}"; do
    # Herestring, not a printf pipe: §5d's pipefail rule, and grep -q exits early anyway.
    # Every verb must RESOLVE: ok, or one of three reasons it does not — the label is the
    # finding. A verb that does not apply is stubbed (header), never declared away.
    if [[ "$v" == test && -n "$sdirs" ]] && grep -qxF -- test <<<"$have" && ! grep -qxF -- test <<<"$suite"; then
      # A suite exists and the canonical `test` exists but RUNS NOTHING — `@true`, a
      # recipe that never touches the suite, or a path-shadowing target without .PHONY.
      # The contract is that `make test` runs the suite, so this is a missing cell with a
      # truer label. With no suite at all, the floor column already says `no-dir`; the
      # verb column does not repeat it.
      line="$line **no-op** |"
      missing=$((missing + 1))
    elif grep -qxF -- "$v" <<<"$have"; then
      line="$line ok |"
    elif [[ ! -f "$dir/Makefile" ]]; then
      line="$line **no Makefile** |"
      missing=$((missing + 1))
    else
      line="$line **missing** |"
      missing=$((missing + 1))
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
    echo "fleet-vocabulary: $missing verb x repo cell(s) missing; $floor_short repo(s) under the test floor" >&2
    printf '%s' "$rows" | grep -F '**' >&2
    exit 1
  fi
  echo "fleet-vocabulary: every verb x repo cell resolves and every repo meets the test floor ($present repo(s) x $nverbs verb(s))"
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
exit 0
