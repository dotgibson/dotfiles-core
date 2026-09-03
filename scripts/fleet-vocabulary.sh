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

_makefile_text() { # _makefile_text <repo-dir> [file=Makefile] [depth] → the Makefile plus its includes
  # The register promises that `make <verb>` RESOLVES, not that the rule sits in the root
  # file, so `include`/`-include`/`sinclude` lines are followed — lexically, relative to the
  # repo root as make itself resolves them, to a bounded depth, and only when the path
  # carries no `$(…)` (a variable would need make's evaluation, which this deliberately
  # does not run in a sibling checkout); a wildcard include is globbed from the root as
  # make globs it. A missing optional include is simply absent.
  # A MANDATORY include that is missing (`include x.mk`, no such file) aborts make before
  # any rule is read, so `make <verb>` resolves NOTHING: this returns 1 and the caller
  # discards the text. `-include`/`sinclude` tolerate absence, as make does. A path
  # carrying `$(…)` is unevaluable and is taken on trust either way.
  local d="$1" f="${2:-Makefile}" depth="${3:-0}" inc m g kind found
  [[ -f "$d/$f" ]] || return 0
  cat "$d/$f"
  ((depth < 4)) || return 0
  while read -r kind inc; do   # default IFS: `kind` is the directive, `inc` the path
    [[ -n "$inc" && "$inc" != *'$'* ]] || continue
    # `include mk/*.mk` is expanded by make; expand it here the same way, from the root.
    if [[ "$inc" == *[\*\?\[]* ]]; then
      found=0
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        found=1
        _makefile_text "$d" "$m" $((depth + 1)) || return 1
      # shellcheck disable=SC2086  # $inc IS the glob: a make include operand is word-split and expanded, as make does
      done < <(cd "$d" && for g in $inc; do [[ -f "$g" ]] && printf '%s\n' "$g"; done)
      [[ "$kind" == include && "$found" == 0 ]] && return 1
    elif [[ -f "$d/$inc" ]]; then
      _makefile_text "$d" "$inc" $((depth + 1)) || return 1
    elif [[ "$kind" == include ]]; then
      return 1
    fi
  done < <(awk '
    # A trailing `# reason` is a comment, not a path; a directive may be space-indented.
    { sub(/#.*/, ""); sub(/^[ ]+/, "") }
    /^(ifeq|ifneq|ifdef|ifndef)([ \t]|\()/ { cond++; next }
    /^endif([ \t]|$)/ { if (cond) cond--; next }
    /^define([ \t]|$)/ { indef = 1; next }
    /^endef([ \t]|$)/ { indef = 0; next }
    cond || indef { next }
    /^-?s?include[ \t]/ { for (i = 2; i <= NF; i++) print $1, $i }
  ' "$d/$f")
  return 0
}

_targets() { # _targets <Makefile> → one defined target name per line
  # A rule line is `targets: prereqs` (or `::`) at column 0 — not a recipe (tab), not a
  # comment, not a variable assignment (`=` before the colon), not `.PHONY:`. Several
  # targets may share one rule (`a b: …`), so the left side is split on whitespace.
  # A rule inside `ifeq`/`ifdef`…`endif` or a `define`…`endef` body is NOT counted: make
  # may or may not define it, and this scanner does not evaluate make — so it says
  # "missing" rather than guess. No fleet Makefile uses either construct around a rule.
  awk '
    /^[ ]*(ifeq|ifneq|ifdef|ifndef)([ \t]|\()/ { cond++; next }
    /^[ ]*endif([ \t]|$)/ { if (cond) cond--; next }
    /^[ ]*define([ \t]|$)/ { indef = 1; next }
    /^[ ]*endef([ \t]|$)/ { indef = 0; next }
    cond || indef { next }
    /^[^\t#. ][^:=]*::?([^=]|$)/ {
      lhs = $0; sub(/::?.*/, "", lhs)
      n = split(lhs, t, /[ \t]+/)
      for (i = 1; i <= n; i++) if (t[i] != "" && t[i] !~ /\$\(/) print t[i]
    }
  ' "$1"
}

_declared() { # _declared <repo-dir> <verb> → the `none <why>` declaration, or ""
  local decl
  # `test` cannot be declared away: the floor makes a repo-owned suite universal, and the
  # canonical way to run it is `make test`. A repo that ran test/ from CI while declaring
  # `make:test none` would go fully green with the promised verb unavailable.
  [[ "$2" == test ]] && return 0
  decl="$(sed -e 's/#.*//' "$1/.github/core-gates.txt" 2>/dev/null |
    awk -v k="make:$2" '$1==k && $2=="none" { $1=""; $2=""; sub(/^[[:space:]]+/,""); print; exit }')"
  [[ -n "$decl" ]] && printf '%s' "$decl"
}

# WHAT COUNTS AS RUNNING THE SUITE, in one simple shell command (the text is split at
# unquoted `;`/`&&`/`||`/`|` first — AWK_SHELL below — so command position is simply
# the start): a test path as the command (`./test/smoke.sh`, `tests/run`), or an
# interpreter in command position handed one (`bash -e test/smoke.sh`, and through the
# options that take an operand of their own: `bash -o pipefail test/smoke.sh`, `python3
# -m pytest tests/`, or the bare directory: `python3 -m pytest tests`) — optionally under
# sudo or env, and after leading variable assignments (`CI=1 make test` is how a great
# many steps are written). In DIRECT command position the path needs its slash: a bare
# `test` there is the shell utility, not the suite. `echo test/smoke.sh`, `echo bash test/smoke.sh` and `shellcheck test/*.sh` mention
# the path and run nothing, so they do not count. `DIRS` is replaced per repo with the
# directory that is actually populated (_run_re), so a populated test/ is not credited by a
# step running a nonexistent tests/. No backslashes: these are handed to awk via -v, which
# would eat them, so `[.]` and `[/]` stand in for the escaped forms.
RUN_RE_TEMPLATE='^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*([.][/])?(DIRS)([/]|[[:space:]]|$)|([.][/])?(DIRS)[/])'
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
# are case-insensitive words (`-noprofile` runs). For node: --check / -c / -v. For every
# interpreter: its help and version modes (--help/--version, -h/-V, pwsh -Help/-Version/-?),
# which print and exit without touching the operand.
NORUN_RE='(^|[[:space:]])((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(make[[:space:]]+([^[:space:]]+[[:space:]]+)*(-[a-eg-ik-np-zA-BD-HJ-NP-VX-Z]*[nqhvt][a-zA-Z]*|-[a-np-zA-HJ-VX-Z]*[Cf][^[:space:]]*|--dry-run|--just-print|--recon|--question|--help|--version|--touch|--directory|--file|--makefile)([[:space:]=]|$)|(bash|sh|zsh|dash|ksh)[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(-[a-zA-Z]*n[a-zA-Z]*)([[:space:]]|$)|node[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(--check|-c|-v)([[:space:]]|$)|(bash|sh|zsh|dash|ksh|bats|prove|python3?|node|pwsh)[[:space:]]+((-o|-m|-W|-X|-r|--require|-ExecutionPolicy|-File)[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*(--version|--help|-V|-h|-Version|-Help|-[?])([[:space:]]|$))'

# THE SHELL-TEXT HELPERS, shared by both awk programs below (shell-level text, spliced in),
# so a workflow step and a Makefile recipe are read by the same rules:
#   * splitcmds — one simple command at a time, split at `;`/`&&`/`||`/`|` OUTSIDE quotes.
#     A naive split turned `echo "disabled && make test"` into a synthetic `make test"`.
#     Inside "…" a backslash escapes the next character, so `\"` does not end the string;
#     inside '…' nothing does. The operator before each command is kept (SPLITOP) and
#     cdnorm decides reachability for the decidable pairs: `true || make test` and
#     `false && make test` never reach make; `false || make test` always does.
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
#     then judge root-relative paths as always (a `make` there reads test/Makefile and is
#     not judged). A `cd` ANYWHERE ELSE (`cd docs`, `cd ..`, `cd tools`) puts the rest of
#     the list outside the tree this register inspected — a `make test` there is another
#     Makefile — so those commands are dropped, not judged. Shell `if` blocks are followed
#     as far as they are static: a `false` body and a `true` else never run.
#   * trim — whitespace only.
AWK_SHELL='
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
        SPLITOP[n + 1] = (c == "|" && substr(s, i + 1, 1) == "|") ? "||" : c
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
      if (c == "#" && prev ~ /[ \t]/) return substr(s, 1, i - 1)
      prev = c
    }
    return s
  }
  function cdnorm(c, n,   i, d, t, m, x, prev, skip, nest, mode, kw) {
    d = ""; x = 0; prev = ""; skip = 0; nest = 0; mode = ""
    for (i = 1; i <= n; i++) {
      # Reachability, for the statically decidable pairs: behind `||` a command runs only
      # if the previous one FAILED — reachable after a literal `false`, unreachable after
      # `true`/`:`, and (conservatively) not credited after anything else; behind `&&` it
      # runs only on SUCCESS — unreachable after `false`, credited otherwise.
      if (SPLITOP[i] == "||" && prev != "false") { prev = trim(c[i]); c[i] = ""; continue }
      if (SPLITOP[i] == "&" && prev == "false") { prev = trim(c[i]); c[i] = ""; continue }
      prev = trim(c[i])
      t = trim(c[i])
      # Shell control flow, as far as it is static: `if false; then … fi` never runs its
      # body and `if true` never runs its else; any other condition may run either. The
      # keywords then/do/else/elif carry no command of their own and are stripped.
      kw = ""
      if (match(t, /^(then|do|else|elif)([ \t]+|$)/)) { kw = substr(t, 1, RLENGTH); sub(/[ \t]+$/, "", kw); t = substr(t, RLENGTH + 1) }
      if (kw == "else" && nest == 1) skip = (mode == "true")
      if (kw == "elif") { if (nest == 1) { mode = ""; skip = 0 } ; c[i] = ""; continue }
      if (t ~ /^if([ \t]|$)/) {
        nest++
        if (nest == 1) { mode = (t ~ /^if[ \t]+false([ \t]|$)/) ? "false" : ((t ~ /^if[ \t]+(true|:)([ \t]|$)/) ? "true" : ""); skip = (mode == "false") }
        c[i] = ""; continue
      }
      if (t ~ /^fi([ \t]|$)/) { if (nest) nest--; if (nest == 0) { skip = 0; mode = "" } ; c[i] = ""; continue }
      if (skip || t == "") { c[i] = ""; continue }
      c[i] = t
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
  #   * a step with a statically false `if:` never runs, nor does any step of a job with
  #     one; a runtime condition may.
  #   * a step runs in its EFFECTIVE WORKING DIRECTORY: its own `working-directory:`, else
  #     the job's `defaults.run.working-directory`, else the workflow's. Every line is
  #     emitted as `cd <dir> && <line>`, so cdnorm judges it like a `cd` in the command
  #     itself: `make test` from `tools/` is another Makefile and does not count.
  # YAML MAPPING ORDER IS NOT SEMANTIC: a job's `if:` or `defaults:` may follow its
  # `steps:`, a step's `working-directory:` may precede its `run:`. So NOTHING is emitted
  # until the file ends — each step's lines are held with the step's own settings and the
  # job they belong to, and resolved once every job- and workflow-level key has been seen.
  # Block lines are the lines indented deeper than the key, and are emitted at column 0.
  awk -v SQ="'" "$AWK_SHELL"'
    function emit(s,   c, n, i) { s = trim(stripcomment(s)); n = splitcmds(s, c); cdnorm(c, n); for (i = 1; i <= n; i++) if (trim(c[i]) != "") print trim(c[i]) }
    function flushblock() { if (acc != "") { held[++nheld] = acc; acc = "" } }
    function flushstep(   i, all) {
      if (inblock) { flushblock(); inblock = 0 }
      # ONE SHELL per step: its lines are joined with `;` so a `cd`, an `if false; then`
      # or a `fi` on one line governs the lines after it, as it does when the step runs.
      # Each line loses its shell comment BEFORE the join — a `# note` line would
      # otherwise comment out every line joined after it.
      all = ""
      for (i = 1; i <= nheld; i++) { line = trim(stripcomment(held[i])); if (line != "") all = (all == "" ? line : all " ; " line) }
      if (nheld) { nh++; H[nh] = all; HWD[nh] = stepwd; HOFF[nh] = stepoff; HJOB[nh] = jobidx }
      nheld = 0; stepwd = ""; stepoff = 0
    }
    function keyval(s) { sub(/^[^:]*:[ \t]*/, "", s); return unquote_scalar(stripcomment(s)) }
    function isfalse(v) { return v ~ /^(\$\{\{[ \t]*)?false([ \t]*\}\})?$/ }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) { flushblock(); next }
        match($0, /^[ \t]*/)
        if (RLENGTH > bind) {
          line = trim($0)
          if (fold) { acc = (acc == "" ? line : acc " " line); next }
          if (line ~ /\\$/) { acc = acc substr(line, 1, length(line) - 1) " "; next }
          acc = acc line; flushblock(); next
        }
        flushblock()
        inblock = 0
      }
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      match($0, /^[ \t]*/); ind = RLENGTH
      if (insteps && ind <= sind) { flushstep(); insteps = 0 }
      if (!insteps) {
        if ($0 ~ /^jobs:[ \t]*(#.*)?$/) { injobs = 1; jobind = -1; next }
        if (injobs) {
          if (ind == 0) { injobs = 0 }
          else {
            if (jobind < 0) jobind = ind
            if (ind == jobind) { jobidx++; propind = -1; next }
            if (propind < 0) propind = ind
            if (ind == propind && $0 ~ /^[ \t]*if:/ && isfalse(keyval($0))) JOFF[jobidx] = 1
          }
        }
        if ($0 ~ /^[ \t]*steps:[ \t]*(#.*)?$/) { sind = ind; insteps = 1; keycol = -1; next }
        if ($0 ~ /^[ \t]*working-directory:/) { if (injobs) JWD[jobidx] = keyval($0); else wfwd = keyval($0) }
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
  # rules at column 0, recipes on tab lines, comments and variable assignments ignored,
  # and nothing inside a conditional or a define body counted (see _targets).
  awk -v re="$2" -v nore="$NORUN_RE" -v SQ="'" "$AWK_SHELL"'
    function runs(line,   n, c, i) {
      sub(/^[ \t]*[@+-]*[ \t]*/, "", line)
      n = splitcmds(trim(stripcomment(line)), c); cdnorm(c, n)
      for (i = 1; i <= n; i++) if (trim(c[i]) ~ re && trim(c[i]) !~ nore) return 1
      return 0
    }
    function handle(l,   lhs, rhs, inl, n, t, i) {
      if (l ~ /^[ ]*(ifeq|ifneq|ifdef|ifndef)([ \t]|\()/) { cond++; ncur = 0; return }
      if (l ~ /^[ ]*endif([ \t]|$)/) { if (cond) cond--; ncur = 0; return }
      if (l ~ /^[ ]*define([ \t]|$)/) { indef = 1; ncur = 0; return }
      if (l ~ /^[ ]*endef([ \t]|$)/) { indef = 0; ncur = 0; return }
      if (cond || indef) return
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
        for (k in seen) if (!(k in hit)) {
          m = split(pre[k], p, /[ \t]+/)
          for (i = 1; i <= m; i++) if (p[i] in hit) { hit[k] = 1; changed = 1; break }
        }
      } while (changed)
      for (k in hit) print k
    }
  ' "$1"
}

_phony_targets() { # _phony_targets <Makefile> → every name declared .PHONY, one per line (not inside a conditional/define)
  awk '
    { if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1) " "; next } ; l = buf $0; buf = "" }
    l ~ /^[ ]*(ifeq|ifneq|ifdef|ifndef)([ \t]|\()/ { cond++; next }
    l ~ /^[ ]*endif([ \t]|$)/ { if (cond) cond--; next }
    l ~ /^[ ]*define([ \t]|$)/ { indef = 1; next }
    l ~ /^[ ]*endef([ \t]|$)/ { indef = 0; next }
    cond || indef { next }
    l ~ /^[.]PHONY[ \t]*:/ { sub(/^[.]PHONY[ \t]*:/, "", l); sub(/#.*/, "", l); n = split(l, t, /[ \t]+/); for (i = 1; i <= n; i++) if (t[i] != "") print t[i] }
  ' "$1"
}

_ere_escape() { # _ere_escape <string> → the string as a literal inside a POSIX ERE
  # The COMPLETE ERE metacharacter set, so a legal target such as `test+coverage` or
  # `t(1)` matches itself instead of rewriting — or breaking — the pattern it lands in.
  printf '%s' "$1" | sed 's/[][\\.|*?+(){}^$]/\\&/g'
}

_test_floor() { # _test_floor <repo-dir> → ok | no-dir | empty | not-in-ci
  local d="$1" dirs="" cand="" seen=0 wf alt="" tgt cmds hits re phony mktext
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
  # A suite target whose name is ALSO A PATH in the repo — `test:` beside the `test/`
  # directory it runs — must be declared .PHONY, or `make test` says "is up to date" and
  # runs nothing. That is the single most likely way a repo adopting this floor gets a
  # green cell for a suite that never executes, so the target is not credited without it.
  alt=""
  if [[ -f "$d/Makefile" ]]; then
    mktext="$(_makefile_text "$d")" || mktext=""   # a missing mandatory include: no targets at all
    phony="$(_phony_targets <(printf '%s\n' "$mktext"))"
    while IFS= read -r tgt; do
      [[ -n "$tgt" ]] || continue
      if [[ -e "$d/$tgt" ]] && ! grep -qxF -- "$tgt" <<<"$phony"; then continue; fi
      alt="${alt:+$alt|}$(_ere_escape "$tgt")"
    done < <(_suite_targets <(printf '%s\n' "$mktext") "$re")
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
    # A make option that TAKES AN ARGUMENT and does not change which Makefile runs (-I dir,
    # -o/-W file and their long forms) is removed with its argument first, so `make -I test
    # lint` does not read the directory operand as the goal — on make commands ONLY, so
    # `python -I test/smoke.py` keeps its operand. `-C`/`-f` are not rewritten: they select
    # another Makefile and NORUN_RE rejects the invocation outright.
    cmds="$(_run_lines "$wf" | sed -E '/^[[:space:]]*((sudo|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*make([[:space:]]|$)/ s/(^|[[:space:]])(-[IoW]|--(include-dir|old-file|assume-old|what-if|new-file|assume-new))[[:space:]]+[^[:space:]]+/\1/g')"
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
  if [[ -f "$dir/Makefile" ]]; then
    mktext="$(_makefile_text "$dir")" || mktext=""   # a missing mandatory include: no targets at all
    have="$(_targets <(printf '%s\n' "$mktext"))"
  fi
  for v in "${VERBS[@]}"; do
    # Herestring, not a printf pipe: §5d's pipefail rule, and grep -q exits early anyway.
    # A declaration fills a cell whether or not a Makefile exists — a repo that genuinely
    # has nothing to run may say so for every verb. The label only differs for the rest.
    why=""
    grep -qxF -- "$v" <<<"$have" || why="$(_declared "$dir" "$v")"
    if grep -qxF -- "$v" <<<"$have"; then
      line="$line ok |"
    elif [[ -n "$why" ]]; then
      n=$((n + 1))
      line="$line none[^$n] |"
      notes="${notes}[^$n]: \`${repo#dotfiles-}\` / \`make $v\` — $why
"
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
    echo "fleet-vocabulary: $missing verb x repo cell(s) missing/undeclared; $floor_short repo(s) under the test floor" >&2
    printf '%s' "$rows" | grep -F '**' >&2
    exit 1
  fi
  echo "fleet-vocabulary: every verb x repo cell is defined or declared and every repo meets the test floor ($present repo(s) x $nverbs verb(s))"
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
