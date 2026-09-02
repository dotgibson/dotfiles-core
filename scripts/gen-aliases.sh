#!/usr/bin/env bash
# scripts/gen-aliases.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render the alias tables in aliases.md FROM the zsh sources that define them.
#
# THE DEFECT THIS CLOSES (#685). ~200 of aliases.md's lines were a hand-copy of data
# the shell already holds: the `alias` lines in zsh/20-aliases.zsh and zsh/25-git.zsh,
# the `hash -d` named directories, and the `_core_help "synopsis" "description"`
# one-liners in zsh/30-functions.zsh. aliases.md even said its function descriptions
# "are the same one-liners those surfaces print" — and one already wasn't: `mkcd` was
# described three different ways in three places. A hand-copy is a comment about the
# code, and a comment is not a gate. This is theme/palette.toml → gen-theme.sh, applied
# to the cheat sheet: the source is authoritative, the doc is rendered from it, and
# `make audit` fails when either moves without the other.
#
# HOW. aliases.md opts a region in with an HTML-comment marker pair naming a block id
# (the shape dotfiles-Offense's gen-views.sh uses for its markdown views):
#
#     <!-- core:aliases:gen git-stash -->
#     …a table rendered from the sources…
#     <!-- core:aliases:end git-stash -->
#
# Anything OUTSIDE the markers is hand-authored and never touched — the header, the
# `web`/$BROWSER explanation, the jj/uv intros, the cdup-vs-up warning, the
# destructive-confirmation note. Curation (which alias goes in which table, in what
# order) lives in BLOCKS below; the DATA in every cell comes from the shell:
#
#   Alias       the alias name
#   Expands To  the alias value, VERBATIM (quotes stripped) — `$BAT_BIN --paging=never`,
#               `git checkout "$(git_main_branch)"` — because that is what the shell holds
#   Requires    the HAVE_* flag guarding the definition, as its tool name (eza, bat, …);
#               the column appears only in a table where some row is guarded
#   Note        the alias line's trailing `# comment`, verbatim; the column appears only
#               in a table where some row has one. So a comment on an alias line IS its
#               cheat-sheet note — write it to be read.
#   Command/Does (the functions block) the `_core_help` synopsis and description
#
# COVERAGE IS BIDIRECTIONAL, like parity-check.sh's row gate: every alias, `hash -d`
# and `_core_help` the sources define must be claimed by exactly one block, and every
# name a block claims must exist. That is what makes "add an alias and forget the doc"
# a failure rather than a silent omission — the new alias is UNCLAIMED, this exits 2,
# and the message names it and the fix. A fallback definition (the `else` arm of a
# HAVE_* guard, e.g. `ll='ls -lah'`) is not a separate alias: the guarded row wins and
# the header prose explains the fallback rule once.
#
#   gen-aliases.sh              # rewrite every marked block in aliases.md
#   gen-aliases.sh --check      # exit 1 (with a diff) if any block is stale — THE GATE
#   gen-aliases.sh --list       # every definition the sources hold, as kind<TAB>name<TAB>file:line
#   gen-aliases.sh --root DIR   # run against another tree (test-core.sh's fixtures)
#
# PURE BASH + AWK, NO python3/jq/yq, bash 3.2 (no mapfile, no `declare -A`,
# PORTABILITY.md §1): audit-core.sh §9g runs --check always-on with no `have` gate, so
# it must never be able to SKIP. The awk is POSIX (the Alpine CI leg runs busybox).
#
# Exit: 0 = clean; 1 = drift (a rendered block differs from what is on disk);
#       2 = the generator cannot run — a parse failure, an unclaimed or unknown name,
#           a missing/duplicated/unregistered marker, or a usage error.
# Severity is sticky, 2 > 1 > 0, the convention gen-theme.sh and parity-check.sh keep.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Via the ALREADY-ABSOLUTE $HERE, not ${BASH_SOURCE[0]%/*}: we cd below, and
# BASH_SOURCE stays relative to the caller's original directory (gen-theme.sh:66).

# For core_files_identical — the cmp/diff BINARIES are forbidden in this repo (#572;
# scripts/lib/common.sh's note on core_files_identical): that helper for equality and
# `git diff --no-index` for a human-readable diff, which also spares the Alpine leg a
# diffutils dependency.
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

MODE=bare
ROOT=""
while (($#)); do
  case "$1" in
  --check) MODE=check ;;
  --list) MODE=list ;;
  --root)
    [[ -n "${2:-}" ]] || { printf 'gen-aliases: --root needs a directory\n' >&2; exit 2; }
    ROOT="$2"; shift ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0 ;;
  *)
    printf 'gen-aliases: unexpected argument: %s (try --help)\n' "$1" >&2
    exit 2 ;;
  esac
  shift
done

# --root lets the behavioural suite drive this against a hermetic fixture tree: the
# drift direction is untestable except by mutating tracked files, and the drift
# direction is the entire point of the gate (gen-theme.sh:103).
[[ -n "$ROOT" ]] && HERE="$(cd -- "$ROOT" && pwd)"
cd "$HERE" || exit 2

TARGET="aliases.md"
SOURCES="zsh/20-aliases.zsh zsh/25-git.zsh zsh/30-functions.zsh"

# ── the registry: one block per table, in the doc's order ─────────────────────
# id<TAB>kind<TAB>names. `kind` says which definitions the names resolve against:
#   alias  — `alias NAME=VALUE` in any source           (Alias | Expands To [| Requires] [| Note])
#   dir    — `hash -d NAME=VALUE`                       (Shortcut | Expands To)
#   fn     — `_core_help "SYNOPSIS" "DESCRIPTION"`      (Command | Does), NAME = the synopsis's first word
# This is the single declaration of what the doc carries. The grouping is a curated
# cross-cut the source files' own section headers do not share (Modern CLI spans nine
# of 20-aliases.zsh's sections), so it is a decision, and decisions live here, not in
# the source. Adding an alias means adding its name to a list; forgetting to is exit 2.
BLOCKS="modern-cli	alias	ls ll la lt llt tree cat catp bat fd rg cd cdi du ps top htop watch df fm y http https md dns ping help
editors	alias	vim lg web notes cheat
nav-safety	alias	- diff rm cp mv mkdir
named-dirs	dir	dots proj
network	alias	myip ports
jj	alias	jjs jjl jjd
uv	alias	uvr uvs
functions	fn	mkcd cdup fcd extract mkbak serve genpw please pullall core-doctor core-version core-status core-whatsnew core-help
git-core	alias	g
git-status	alias	gst gss gsb
git-staging	alias	ga gaa gap
git-commit	alias	gc gcm gca gcam gc! gcn!
git-branch	alias	gb gba gbd gbD gbm
git-checkout	alias	gco gcb gcom gsw gswc gswm
git-diff	alias	gd gds gdw gdft
git-log	alias	glog gloga glol glola
git-fetch-pull-push	alias	gf gfa gl gpr gp gpu gpf gpf!
git-stash	alias	gsta gstaa gstp gstl gstd
git-rebase	alias	grb grbi grbm grbc grba
git-reset-restore	alias	grh grhh grs grss
git-remote-merge	alias	gr grv gm gma"

# ── extraction: one awk pass over the sources ─────────────────────────────────
# Emits one record per DEFINITION, tab-separated:
#   kind  name  value  guard  note  file:line  fallback
# where guard is the HAVE_* suffix (EZA, BAT, …) or empty, note is the trailing
# comment or empty, and fallback is 1 for a definition in the `else` arm of a guard.
#
# What it understands, because the sources use exactly these shapes and no others:
#   - `alias` in COMMAND POSITION only (line start, or after && ; then { else do), so a
#     comment or a string that mentions alias syntax is not a definition. Comment lines
#     are skipped outright. Several aliases on one line are all taken (`&& alias top=…
#     && alias htop=…`; the one-line `if …; then alias df=…; else alias df=…; fi`).
#   - Names bare, quoted (`'gc!'`), or after `--` (`alias -- -='cd -'`). Values quoted
#     with ' or " — the first matching quote closes; no source escapes a quote — or bare.
#   - A GUARD STACK, not a flag: `if [[ -n ${HAVE_X:-} ]]; then` and `[[ -n ${HAVE_X:-} ]]
#     && {` push a frame, `fi` / `}` pop, `else` marks the frame's remainder as fallback,
#     and a same-line `[[ -n ${HAVE_X:-} ]] && alias …` guards that line. The active
#     guard is the nearest NON-EMPTY frame, which is what makes the `if [[ -z $DISPLAY`
#     nested inside 20-aliases.zsh's HAVE_BROWSER block keep the outer guard instead of
#     clearing it one `fi` early. Function bodies and the diff-probe's anonymous
#     function push empty frames and cost nothing.
#   - `_core_help "SYNOPSIS" "DESCRIPTION"` after joining backslash-continued lines
#     (core-whatsnew's call spans two). Anchored on `_core_help "` so _core_help_render
#     does not match. A call with MORE than one description line is a sub-verb listing
#     (the `core maint` namespace help, #684), not a one-liner: it is recorded as
#     `fn-multi` — visible in --list, never a row, never required to be claimed.
_extract() {
  # shellcheck disable=SC2086  # SOURCES is a deliberate word list
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function have_of(s,    g) {
      if (match(s, /-n[[:space:]]+\$\{HAVE_[A-Z0-9_]+/)) {
        g = substr(s, RSTART, RLENGTH); sub(/.*HAVE_/, "", g); return g
      }
      return ""
    }
    function active_guard(    d) { for (d = depth; d >= 1; d--) if (guard[d] != "") return guard[d]; return "" }
    function in_fallback(    d) { for (d = depth; d >= 1; d--) if (fb[d]) return 1; return 0 }
    function bad(msg) { printf "gen-aliases: %s:%d: %s\n", FILENAME, fnr0, msg > "/dev/stderr"; errs++ }
    function emit(kind, name, val, g, note, isfb) {
      print kind "\t" name "\t" val "\t" g "\t" note "\t" FILENAME ":" fnr0 "\t" isfb
    }
    # every `alias NAME=VALUE` on line s; g0/f0 = the frame guard and fallback state
    function parse_aliases(s, g0, f0,    rest, pre, pos, q, k, name, val, lg, cnt, note, i) {
      rest = s; cnt = 0; lg = ""
      while (match(rest, /alias[[:space:]]+/)) {
        pre = substr(rest, 1, RSTART - 1)
        pos = RSTART + RLENGTH
        if (!(pre ~ /^[[:space:]]*$/ || pre ~ /(&&|;|then|\{|else|do)[[:space:]]*$/)) {
          rest = substr(rest, pos); continue        # not in command position
        }
        if (cnt == 0) { lg = have_of(pre); if (lg == "") lg = g0 }
        if (pre ~ /else[[:space:]]*$/) f0 = 1      # the one-line if/else/fi arm
        rest = substr(rest, pos)
        sub(/^--[[:space:]]+/, "", rest)
        q = substr(rest, 1, 1)
        if (q == "\047" || q == "\"") {
          rest = substr(rest, 2); k = index(rest, q)
          if (k == 0) { bad("unterminated alias name"); return }
          name = substr(rest, 1, k - 1); rest = substr(rest, k + 1)
        } else {
          k = index(rest, "=")
          if (k == 0) { bad("alias without =: " s); return }
          name = substr(rest, 1, k - 1); rest = substr(rest, k)
        }
        if (substr(rest, 1, 1) != "=") { bad("cannot parse alias name: " s); return }
        rest = substr(rest, 2)
        q = substr(rest, 1, 1)
        if (q == "\047" || q == "\"") {
          rest = substr(rest, 2); k = index(rest, q)
          if (k == 0) { bad("unterminated alias value: " s); return }
          val = substr(rest, 1, k - 1); rest = substr(rest, k + 1)
        } else {
          match(rest, /^[^[:space:];&]*/)
          val = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
        }
        cnt++; names[cnt] = name; vals[cnt] = val; fbs[cnt] = f0
      }
      note = ""
      if (rest ~ /^[[:space:]]*#/) { note = rest; sub(/^[[:space:]]*#[[:space:]]*/, "", note); note = trim(note) }
      for (i = 1; i <= cnt; i++) emit("alias", names[i], vals[i], (fbs[i] ? "" : lg), (i == cnt ? note : ""), fbs[i])
    }
    function parse_hashd(s,    rest, k, q, name, val) {
      rest = s; sub(/^[[:space:]]*hash[[:space:]]+-d[[:space:]]+/, "", rest)
      k = index(rest, "="); if (k == 0) { bad("cannot parse hash -d: " s); return }
      name = substr(rest, 1, k - 1); rest = substr(rest, k + 1)
      q = substr(rest, 1, 1)
      if (q == "\047" || q == "\"") {
        rest = substr(rest, 2); k = index(rest, q)
        if (k == 0) { bad("unterminated hash -d value: " s); return }
        val = substr(rest, 1, k - 1)
      } else { match(rest, /^[^[:space:];&]*/); val = substr(rest, 1, RLENGTH) }
      emit("dir", name, val, "", "", 0)
    }
    function parse_help(s,    rest, k, syn, desc, name) {
      match(s, /_core_help[[:space:]]+"/); rest = substr(s, RSTART + RLENGTH)
      k = index(rest, "\""); if (k == 0) { bad("unterminated _core_help synopsis"); return }
      syn = substr(rest, 1, k - 1); rest = substr(rest, k + 1)
      if (!match(rest, /^[[:space:]]+"/)) { bad("_core_help needs a quoted description after the synopsis"); return }
      rest = substr(rest, RLENGTH + 1)
      k = index(rest, "\""); if (k == 0) { bad("unterminated _core_help description"); return }
      desc = substr(rest, 1, k - 1); rest = substr(rest, k + 1)
      name = syn; sub(/[[:space:]].*/, "", name)
      # A THIRD ARGUMENT means a multi-line help: a sub-verb listing (`core maint`), not a
      # one-liner, and not a row — reported as fn-multi so --list shows it, never claimed.
      if (rest ~ /^[[:space:]]*"/) { emit("fn-multi", name, syn, "", desc, 0); return }
      emit("fn", name, syn, "", desc, 0)
    }
    FNR == 1 { depth = 0; buf = "" }
    {
      if (buf != "") { s = buf " " trim($0); buf = "" } else { s = $0; fnr0 = FNR }
      if (s ~ /\\$/) { sub(/[[:space:]]*\\$/, "", s); buf = s; next }   # continued: join with the next line
      if (s ~ /^[[:space:]]*#/ || s ~ /^[[:space:]]*$/) next
      st = s; sub(/[[:space:]]+#.*$/, "", st); st = trim(st)          # structure only: comment stripped
      if (st ~ /^if[[:space:]]/) {
        if (!(st ~ /(^|[;[:space:]])fi$/)) { depth++; guard[depth] = have_of(st); fb[depth] = 0 }
      } else if (st ~ /^elif[[:space:]]/) { if (depth > 0) { guard[depth] = have_of(st); fb[depth] = 0 } }
      else if (st ~ /^else([[:space:]]|$)/) { if (depth > 0) fb[depth] = 1 }
      else if (st ~ /^fi([[:space:]]|;|$)/) { if (depth > 0) depth-- }
      else if (st ~ /\{$/) { depth++; guard[depth] = have_of(st); fb[depth] = 0 }
      else if (st ~ /^\}/) { if (depth > 0) depth-- }
      if (st ~ /(^|&&|;|then|\{|else|do)[[:space:]]*alias[[:space:]]/) parse_aliases(trim(s), active_guard(), in_fallback())
      else if (st ~ /^hash[[:space:]]+-d[[:space:]]/) parse_hashd(s)
      else if (s ~ /_core_help[[:space:]]+"/) parse_help(s)
    }
    END { if (errs) exit 2 }
  ' $SOURCES
}

# One row per NAME: a guarded definition beats its fallback, otherwise first wins.
# Output keeps first-appearance order.
_dedupe() {
  awk -F'\t' '
    { k = $1 SUBSEP $2 }
    !(k in row) { order[++n] = k; row[k] = $0; isfb[k] = $7; next }
    isfb[k] == 1 && $7 == 0 { row[k] = $0; isfb[k] = 0 }
    END { for (i = 1; i <= n; i++) print row[order[i]] }
  '
}

# ── rendering: one table per block ────────────────────────────────────────────
# $1 = kind, $2 = space-separated names; reads ROWS (deduped) from stdin.
# A `|` in any cell is escaped as `\|` — GFM honours the escape inside a code span, and
# aliases.md already relies on that (its `serve [-l\|--local]` row). A backtick inside a
# value that is itself rendered as a code span cannot be escaped that way, so it is a
# structural failure with a message, not a mangled row.
_render() {
  awk -F'\t' -v kind="$1" -v names="$2" '
    function esc(s,    out, k) { out = ""; while ((k = index(s, "|")) > 0) { out = out substr(s, 1, k - 1) "\\|"; s = substr(s, k + 1) } return out s }
    function req_name(g) {
      if (g == "RG") return "ripgrep"
      if (g == "FD") return "fd-find / fd"
      if (g == "BROWSER") return "w3m / lynx / links2 / links / elinks"
      return tolower(g)
    }
    { k = $1 SUBSEP $2; val[k] = $3; grd[k] = $4; nte[k] = $5 }
    END {
      n = split(names, want, " ")
      hasreq = 0; hasnote = 0
      for (i = 1; i <= n; i++) {
        k = kind SUBSEP want[i]
        if (!(k in val)) { printf "gen-aliases: no %s definition for %s\n", kind, want[i] > "/dev/stderr"; exit 2 }
        # EVERY rendered code span — alias values, directory targets AND function
        # synopses — is wrapped in backticks below, so a backtick in any of them is a
        # broken table, not a rendering case. (The fn description is prose: allowed.)
        if (index(val[k], "`")) {
          printf "gen-aliases: %s %s: the value contains a backtick, which cannot sit inside a code span\n", kind, want[i] > "/dev/stderr"; exit 2
        }
        if (grd[k] != "") hasreq = 1
        if (nte[k] != "") hasnote = 1
      }
      print ""
      if (kind == "fn") {
        print "| Command | Does |"
        print "| ------- | ---- |"
        for (i = 1; i <= n; i++) { k = kind SUBSEP want[i]; print "| `" esc(val[k]) "` | " esc(nte[k]) " |" }
      } else {
        h = (kind == "dir") ? "| Shortcut | Expands To |" : "| Alias | Expands To |"
        s = (kind == "dir") ? "| -------- | ---------- |" : "| ----- | ---------- |"
        if (hasreq) { h = h " Requires |"; s = s " -------- |" }
        if (hasnote) { h = h " Note |"; s = s " ---- |" }
        print h; print s
        for (i = 1; i <= n; i++) {
          k = kind SUBSEP want[i]
          line = "| `" ((kind == "dir") ? "~" : "") esc(want[i]) "` | `" esc(val[k]) "` |"
          if (hasreq) line = line ((grd[k] == "") ? " |" : " " esc(req_name(grd[k])) " |")
          if (hasnote) line = line ((nte[k] == "") ? " |" : " " esc(nte[k]) " |")
          print line
        }
      }
      print ""
    }
  '
}

render_for() { # $1 = id
  local kind names
  kind="$(awk -F'\t' -v id="$1" '$1 == id { print $2 }' <<<"$BLOCKS")"
  names="$(awk -F'\t' -v id="$1" '$1 == id { print $3 }' <<<"$BLOCKS")"
  [[ -n "$kind" ]] || { printf 'gen-aliases: unknown block id: %s\n' "$1" >&2; return 2; }
  _render "$kind" "$names" <<EOF
$ROWS
EOF
}

# ── the block walker (gen-theme.sh's build_file, HTML-comment markers) ────────
marker_id() { # $1 = gen|end, $2 = line; prints the id, or returns 1
  local kind="$1" line="$2"
  [[ "$line" =~ ^[[:space:]]*\<!--[[:space:]]core:aliases:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]--\>[[:space:]]*$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# _markers — every marker in $TARGET as "kind id", ONE grammar shared with marker_id:
# a single whitespace character between fields, any indentation, trailing blanks. The
# preflight counts come from here, not from a second regex, so a marker the walker
# would honour (tab-separated, say) can never be one the structural checks overlook.
_markers() {
  sed -nE 's/^[[:space:]]*<!--[[:space:]]core:aliases:(gen|end)[[:space:]]([a-z0-9-]+)[[:space:]]-->[[:space:]]*$/\1 \2/p' "$TARGET"
}

build_file() { # build_file <file> — emit <file> with every marked block re-rendered
  local file="$1" line id found l2 endid inner
  while IFS= read -r line || [[ -n "$line" ]]; do
    if id="$(marker_id gen "$line")"; then
      printf '%s\n' "$line"
      render_for "$id" || return 2
      found=0
      while IFS= read -r l2; do
        # A second `gen` before this block's `end` is a CROSSED or NESTED pair. The
        # preflight counts cannot see it (gen A, gen B, end A, end B has one of each), and
        # consuming it as stale body would silently drop block B from the document.
        if inner="$(marker_id gen "$l2")"; then
          printf "gen-aliases: 'core:aliases:gen %s' opens inside the '%s' region of %s — blocks cannot nest or cross\n" "$inner" "$id" "$file" >&2
          return 2
        fi
        if endid="$(marker_id end "$l2")"; then
          [[ "$endid" == "$id" ]] || {
            printf "gen-aliases: marker mismatch in %s: 'gen %s' closed by 'end %s'\n" "$file" "$id" "$endid" >&2
            return 2
          }
          printf '%s\n' "$l2"
          found=1
          break
        fi
      done
      ((found == 1)) || {
        printf "gen-aliases: unterminated 'core:aliases:gen %s' region in %s\n" "$id" "$file" >&2
        return 2
      }
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
}

# ── preflight: sources, registry and doc must agree, all three ways ───────────
preflight() {
  local rc=0 id kind names n line f claimed=" " have=" " k m markers
  markers="$(_markers)"
  # 1. Every registered block's `gen` AND `end` marker appears exactly once in the doc,
  #    and every marker of either kind in the doc is registered. (gen-theme.sh's forward
  #    + reverse checks, one file.) BOTH KINDS: build_file only pairs an `end` with the
  #    `gen` above it, so a stray or duplicated `end` marker would otherwise pass through
  #    as prose — and the doc's contract is that a malformed marker fails, not hides.
  while IFS="$(printf '\t')" read -r id kind names; do
    [[ -n "$id" ]] || continue
    n="$(grep -c "^gen $id\$" <<<"$markers" || true)"
    m="$(grep -c "^end $id\$" <<<"$markers" || true)"
    case "$n" in
    1) ;;
    0) printf 'gen-aliases: %s: registered block is missing: %s (was its region deleted?)\n' "$TARGET" "$id" >&2; rc=2 ;;
    *) printf 'gen-aliases: %s: block appears %s times: %s (ambiguous)\n' "$TARGET" "$n" "$id" >&2; rc=2 ;;
    esac
    [[ "$m" == "$n" ]] || {
      printf 'gen-aliases: %s: block %s has %s gen marker(s) but %s end marker(s) — every gen needs exactly one matching end\n' "$TARGET" "$id" "$n" "$m" >&2
      rc=2
    }
  done <<EOF
$BLOCKS
EOF
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%% *}"
    id="${line#* }"
    awk -F'\t' -v id="$id" '$1 == id { found = 1 } END { exit !found }' <<<"$BLOCKS" || {
      printf 'gen-aliases: %s carries an unregistered %s marker: %s — add the block to BLOCKS in scripts/gen-aliases.sh, or remove the marker\n' "$TARGET" "$kind" "$id" >&2
      rc=2
    }
  done <<EOF
$markers
EOF

  # 2. Names: every claimed name is defined, no name is claimed twice, and — the
  #    direction that matters — every DEFINED name is claimed. Membership tests against
  #    space-delimited strings, because bash 3.2 has no associative arrays.
  while IFS="$(printf '\t')" read -r id kind names; do
    [[ -n "$id" ]] || continue
    for n in $names; do
      k="$kind:$n"
      if [[ "$claimed" == *" $k "* ]]; then
        printf 'gen-aliases: %s %s is claimed by more than one block (the second is %s)\n' "$kind" "$n" "$id" >&2; rc=2
      fi
      claimed="$claimed$k "
    done
  done <<EOF
$BLOCKS
EOF
  while IFS="$(printf '\t')" read -r kind n _rest; do
    [[ -n "$kind" ]] || continue
    case "$kind" in alias | dir | fn) ;; *) continue ;; esac # fn-multi is informational
    have="$have$kind:$n "
  done <<EOF
$ROWS
EOF
  for k in $claimed; do
    [[ "$have" == *" $k "* ]] ||
      { printf 'gen-aliases: %s %s is listed in BLOCKS but no source defines it — remove it from the list, or restore the definition\n' "${k%%:*}" "${k#*:}" >&2; rc=2; }
  done
  for k in $have; do
    [[ "$claimed" == *" $k "* ]] ||
      { printf 'gen-aliases: %s %s is defined in the sources but no block in %s lists it — add it to a block list in scripts/gen-aliases.sh, then run make gen-aliases\n' "${k%%:*}" "${k#*:}" "$TARGET" >&2; rc=2; }
  done
  return $rc
}

# ── driver ────────────────────────────────────────────────────────────────────
for f in $SOURCES; do
  [[ -r "$f" ]] || { printf 'gen-aliases: %s is missing or unreadable — the drift gate checked NOTHING\n' "$f" >&2; exit 2; }
done
[[ -r "$TARGET" ]] || { printf 'gen-aliases: %s is missing or unreadable\n' "$TARGET" >&2; exit 2; }

ALL_ROWS="$(_extract)" || exit 2
if [[ "$MODE" == list ]]; then
  # Every definition, fallbacks included, so what the sources hold is enumerable
  # without reading this script.
  awk -F'\t' '{ print $1 "\t" $2 "\t" $6 ($7 == 1 ? "\tfallback" : "") }' <<EOF
$ALL_ROWS
EOF
  exit 0
fi
ROWS="$(_dedupe <<EOF
$ALL_ROWS
EOF
)"
[[ -n "$ROWS" ]] || { printf 'gen-aliases: the sources yielded no definitions at all — nothing to render\n' >&2; exit 2; }

preflight || exit 2

rc=0
if ! generated="$(build_file "$TARGET")"; then
  exit 2
fi
if [[ "$MODE" == check ]]; then
  _tmp="$(mktemp "${TMPDIR:-/tmp}/gen-aliases.XXXXXX")" || exit 2
  # CHECKED, because there is no `set -e`: a full disk or an I/O error here would
  # otherwise fall through to the comparison and be reported as drift (1), when the
  # contract says "could not render" is 2.
  printf '%s\n' "$generated" >"$_tmp" || {
    printf 'gen-aliases: could not write the comparison copy %s\n' "$_tmp" >&2
    rm -f "$_tmp"
    exit 2
  }
  if ! core_files_identical "$TARGET" "$_tmp"; then
    printf 'gen-aliases: DRIFT in %s — a generated table no longer matches the zsh sources:\n' "$TARGET" >&2
    git --no-pager diff --no-index --src-prefix=on-disk/ --dst-prefix=generated/ \
      -- "$TARGET" "$_tmp" 2>/dev/null | sed 's/^/  /' >&2 || true
    printf '  fix: run make gen-aliases and commit the result.\n' >&2
    rc=1
  else
    printf 'gen-aliases: every generated table in %s matches the zsh sources\n' "$TARGET"
  fi
  rm -f "$_tmp"
else
  # Same reason: an unwritable aliases.md (read-only checkout, permissions) must not
  # print "regenerated" and exit 0 — `make gen-aliases` would report a success that
  # never happened.
  printf '%s\n' "$generated" >"$TARGET" || {
    printf 'gen-aliases: could not write %s\n' "$TARGET" >&2
    exit 2
  }
  printf 'gen-aliases: regenerated %s\n' "$TARGET"
fi
exit "$rc"
