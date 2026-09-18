# shellcheck shell=bash
# scripts/lib/gen-region.sh — the marker-region grammar and walker, once.
# ──────────────────────────────────────────────────────────────────────────────
# ONE definition of `core:<ns>:gen <id>` — the grammar, the walker, the structural
# preflight, the atomic install and (since #1144) the shape of the registry that says which
# blocks exist — shared by every generator that rewrites a REGION of a hand-authored file. Before #1129 there were four hand-rolled copies
# (gen-theme.sh, gen-aliases.sh, gen-porting-matrix.sh, gen-desktop-parity.sh), and
# each one detected a DIFFERENT subset of the ways a marker pair can be malformed.
# That is the defect this closes, not the duplication: gen-theme.sh — the generator
# with the most consumers, whose targets are symlinked into $HOME — was the one that
# could not see a nested or crossed pair and never checked that every `gen` had a
# matching `end`.
#
# THE GRAMMAR. A consumer opts a region in with a marker pair naming a block id, in
# the host file's own comment syntax:
#
#     # core:<ns>:gen <id>          …   # core:<ns>:end <id>          (toml, yml, zsh, sh, conf)
#     <!-- core:<ns>:gen <id> -->   …   <!-- core:<ns>:end <id> -->   (markdown, html)
#     /* core:<ns>:gen <id> */      …   /* core:<ns>:end <id> */      (css)
#
# `<ns>` is PROVENANCE: it names which generator owns the region, so a reader of a
# file in a sibling repo can tell what rewrites it. `<id>` is `[a-z0-9-]+`. Anything
# OUTSIDE a pair is hand-authored and never touched. Which syntaxes are legal is
# per-generator (region_init's third argument) rather than universal: accepting a
# form no consumer uses widens the surface a stray line can be mistaken for a marker.
#
# THE CSS FORM REQUIRES ITS CLOSING DELIMITER. A line that OPENS a comment it does
# not close would swallow the generated block into it, and the file would still parse
# while rendering nothing (#926).
#
# THIS IS A SOURCED LIBRARY, not a runnable script — so, exactly like scripts/lib/common.sh
# and the sourced zsh modules, it carries NO shebang and stays mode 100644
# (audit-core.sh §2 asserts this for scripts/lib/*.sh).
#
# IT IS DELIBERATELY NOT SOURCED FROM common.sh. common.sh is a `core.vendor` entry, and
# §1e's closure walk requires a vendored script's sourced siblings to be vendored too —
# so sourcing this from there would ship it into every OS repo's core/ for no consumer.
# The generators source it directly, and no generator is vendored.
#
# bash 3.2-safe (no associative arrays, no mapfile, no function references) so it runs
# on macOS too — PORTABILITY.md §1.
#
# Usage (from any scripts/gen-*.sh, AFTER lib/common.sh):
#   source "$HERE/scripts/lib/gen-region.sh"
#   region_init theme gen-theme "hash css" "BLOCKS in scripts/gen-theme.sh"
# ──────────────────────────────────────────────────────────────────────────────

# Idempotent: a second source is a no-op, mirroring common.sh.
[[ -n "${_CORE_GEN_REGION_SH:-}" ]] && return 0
_CORE_GEN_REGION_SH=1

# ── module state, set by region_init ──────────────────────────────────────────
# Declared with `:=` so a caller under `set -u` (all of them) cannot trip on a read
# before init — the failure would otherwise surface as an empty namespace silently
# matching `core::gen`, which is worse than an error.
: "${_REGION_NS:=}"       # the namespace: theme, aliases, porting-matrix, desktop-parity
: "${_REGION_PROG:=}"     # the program name that prefixes every message (gen-theme, …)
: "${_REGION_SYNTAX:=}"   # space-separated subset of: hash html css
: "${_REGION_HINT:=}"     # where a reader adds a missing registration, for remediation lines

# region_init <ns> <prog> <syntaxes> [registry-hint]
#
# The namespace and the program name are PARAMETERS rather than constants because every
# message this library emits is asserted verbatim by the behavioral suite
# (scripts/test/40-gen-theme-aliases.sh, scripts/test/41-gen-matrix-parity.sh), which
# greps for strings carrying each generator's own prefix. A shared library that reworded
# them would be a rewrite of ~2,000 lines of test for no behavioural gain.
region_init() {
  _REGION_NS="$1"
  _REGION_PROG="$2"
  _REGION_SYNTAX="$3"
  _REGION_HINT="${4:-}"
}

# ── the registry ──────────────────────────────────────────────────────────────
# ONE SHAPE FOR "WHICH BLOCKS EXIST" (#1144). Every generator declares exactly one registry,
# named BLOCKS: a TSV heredoc string, one row per block, blank lines ignored, COLUMN 1 THE
# BLOCK ID, and the remaining columns declared in the comment directly above it. Two honest
# column sets exist, and this library reads only the part they share:
#
#   placement    id<TAB>path<TAB>repo   blocks that live in many files, some in sibling
#                                       repos (gen-theme, gen-desktop-parity). An empty repo
#                                       is this tree. The resolver and the grouped preflight
#                                       below understand it.
#   descriptor   id<TAB>…               one target document, one row per block saying how
#                                       to render it (gen-aliases: kind, names;
#                                       gen-porting-matrix: scope, tool). Only column 1 is
#                                       the library's.
#
# They are NOT one five-column shape, on purpose: the union would put a constant path on
# every descriptor row and two empty columns on every placement row, documenting nothing.
# What the shared prefix buys is that region_registry_ids answers the same question for
# every generator, and the behavioural suite reads ANY registry with one parser
# (region_registry_from_script) instead of the four it carried — one of which had to be
# warned off matching a second variable whose name ended the same way.
#
# Every helper takes the registry TEXT, not a variable name: bash 3.2 has no namerefs.

# region_registry_ids <tsv> — column 1 of every non-blank row, space-separated, in order.
region_registry_ids() {
  awk -F'\t' '$1 != "" { printf "%s%s", (n++ ? " " : ""), $1 } END { if (n) printf "\n" }' <<EOF
$1
EOF
}

# region_registry_field <tsv> <id> <n> — column <n> of every row whose id is <id>, one per
# line; returns 1 when no row carries the id. A placement registry may repeat an id across
# rows (one block rendered into two files), so a caller that expects one value takes one line.
region_registry_field() {
  local out
  out="$(awk -F'\t' -v id="$2" -v n="$3" '$1 == id { print $n; f = 1 } END { exit !f }' <<EOF
$1
EOF
  )" || return 1
  printf '%s\n' "$out"
}

# region_registry_where <tsv> <n> <value> — the ids whose column <n> is <value>, in order.
region_registry_where() {
  awk -F'\t' -v n="$2" -v v="$3" '$1 != "" && $n == v { printf "%s%s", (k++ ? " " : ""), $1 } END { if (k) printf "\n" }' <<EOF
$1
EOF
}

# region_block_path <path> <repo> <fleet> — the ONE place a placement row becomes a
# filesystem path. An empty repo is this tree and prints <path> unchanged. A named repo is a
# sibling under <fleet>, resolved through resolve_repo_dir (common.sh — it also finds a clone
# whose directory name differs from the repo's) and accepted only when `<dir>/.git` EXISTS:
# `-e`, not `-d`, because .git is a FILE in a worktree or submodule checkout. That is the
# fleet convention gen-porting-matrix.sh's resolve_fleet and gen-desktop-parity.sh already
# follow; gen-theme.sh tested the bare directory until #1144, so a same-named directory that
# was not a clone read as checked out there and as absent everywhere else. Prints NOTHING
# (rc 0) when the sibling is not checked out, so every caller gets one answer to "can I read
# this?" and none re-implements the rule.
region_block_path() {
  local path="$1" repo="${2:-}" fleet="${3:-}" dir
  [[ -n "$repo" ]] || { printf '%s' "$path"; return 0; }
  dir="$(resolve_repo_dir "$fleet" "$repo")" || dir="$fleet/$repo"
  [[ -e "$dir/.git" ]] || return 0
  printf '%s' "$dir/$path"
}

# region_resolve_targets <tsv> <fleet> — every placement row, resolved. Sets three globals
# rather than printing one stream, because they are three DIFFERENT facts:
#   REGION_TARGETS        resolved paths of the rows whose file is PRESENT, one per line,
#                         deduplicated (two blocks in one file is one target) and sorted
#   REGION_MISSING_REPOS  sibling repos a row names that are not checked out, each once
#   REGION_MISSING_FILES  `<repo>/<path>` for rows whose sibling IS checked out but does not
#                         hold the registered file
# both lists space-separated. A this-tree row whose file is absent is dropped in silence — a
# partial tree is the behavioural suite's documented fixture case. A SIBLING row that goes
# unread is reported in one list or the other, because "not checked out" and "checked out,
# file missing" (the block has not landed there, the path moved, someone deleted it) have
# different fixes (#933). What to DO about either is the caller's policy: gen-theme.sh skips
# with exit 3 and says so; gen-desktop-parity.sh fails a present repo whose file is missing,
# because its targets are named and mandatory.
# The two MISSING lists are read by the callers, not by this file, so ShellCheck sees them
# assigned and never read.
# shellcheck disable=SC2034
REGION_TARGETS=""
# shellcheck disable=SC2034
REGION_MISSING_REPOS=""
# shellcheck disable=SC2034
REGION_MISSING_FILES=""
region_resolve_targets() {
  local fleet="${2:-}" id path repo f targets="" repos="" files=""
  while IFS="$(printf '\t')" read -r id path repo; do
    [[ -n "$id" && -n "$path" ]] || continue
    f="$(region_block_path "$path" "${repo:-}" "$fleet")"
    if [[ -z "$f" ]]; then
      [[ " $repos " == *" $repo "* ]] || repos="$repos $repo"
    elif [[ -f "$f" ]]; then
      targets="$targets$f
"
    elif [[ -n "${repo:-}" ]]; then
      files="$files $repo/$path"
    fi
  done <<EOF
$1
EOF
  REGION_TARGETS="$(printf '%s' "$targets" | sort -u)"
  # shellcheck disable=SC2034
  REGION_MISSING_REPOS="${repos# }"
  # shellcheck disable=SC2034
  REGION_MISSING_FILES="${files# }"
}

# region_preflight_targets <tsv> <fleet> — the structural preflight over a placement
# registry, grouped BY FILE: region_preflight_file replays one file's marker SEQUENCE, so
# two blocks registered in the same file are checked together and a crossed pair between
# them is visible — gen-theme.sh registers two such files (tmux/scripts/tmux-cheat.sh,
# zsh/45-plugins.zsh), so the grouping is not academic. Absent files are skipped for
# region_resolve_targets' reasons; a sibling that is not checked out is an ENVIRONMENT fact
# the caller reports once, never a per-block failure here. Returns 2 on any fault.
region_preflight_targets() {
  local tsv="$1" fleet="${2:-}" rc=0 id path repo f seen ids
  region_resolve_targets "$tsv" "$fleet"
  while IFS= read -r seen; do
    [[ -n "$seen" ]] || continue
    ids=""
    while IFS="$(printf '\t')" read -r id path repo; do
      [[ -n "$id" && -n "$path" ]] || continue
      f="$(region_block_path "$path" "${repo:-}" "$fleet")"
      [[ "$f" == "$seen" ]] && ids="$ids$id "
    done <<EOF
$tsv
EOF
    region_preflight_file "$seen" "$ids" || rc=2
  done <<EOF
$REGION_TARGETS
EOF
  return $rc
}

# region_registry_from_script <script> [var] — the body of `VAR="…"` (default BLOCKS), read
# out of a generator's SOURCE. For the behavioural suite, which builds its fixtures from the
# real registry so that a newly registered block costs a registry line and no test edit. The
# suite carried one such awk per registry, each written against that registry's own shape;
# with one shape there is one parser, and it lives beside the shape it parses. The closing
# `"` is tested BEFORE it is stripped, or the read runs on into the rest of the script and
# any later tab-separated line becomes a row. A one-line `VAR="a b c"` is the same rule with
# both ends on one line.
region_registry_from_script() {
  local var="${2:-BLOCKS}"
  awk -v v="$var" '
    index($0, v "=\"") == 1 { f = 1; sub("^" v "=\"", "") }
    f { if (/"$/) { sub(/"$/, ""); print; f = 0 } else print }
  ' "$1"
}

# ── the grammar ───────────────────────────────────────────────────────────────
# region_marker_id <gen|end> <line>
#
# Returns 0 and sets REGION_MARKER_ID + REGION_INDENT when <line> is a marker of that
# kind; returns 1 otherwise.
#
# SETS GLOBALS RATHER THAN PRINTING, on purpose. The walker calls this twice per line of
# every target file — PORTING-MATRIX.md alone is ~1,500 lines — and `id="$(marker_id …)"`
# forks a subshell per call. The four copies this replaces all paid that; the shape here
# does not. REGION_INDENT rides along because the one caller that needs the indent needs
# it for exactly the lines that matched, so a second pass over the same line would be
# waste.
REGION_MARKER_ID=""
REGION_INDENT=""
region_marker_id() {
  local kind="$1" line="$2" s
  for s in $_REGION_SYNTAX; do
    if [[ "$s" == hash ]] &&
      [[ "$line" =~ ^[[:space:]]*#[[:space:]]core:${_REGION_NS}:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]*$ ]]; then
      REGION_MARKER_ID="${BASH_REMATCH[1]}"
      REGION_INDENT="${line%%[! ]*}"
      return 0
    fi
    if [[ "$s" == html ]] &&
      [[ "$line" =~ ^[[:space:]]*\<!--[[:space:]]core:${_REGION_NS}:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]--\>[[:space:]]*$ ]]; then
      REGION_MARKER_ID="${BASH_REMATCH[1]}"
      REGION_INDENT="${line%%[! ]*}"
      return 0
    fi
    # The closing `*/` is REQUIRED, not optional — see the header.
    if [[ "$s" == css ]] &&
      [[ "$line" =~ ^[[:space:]]*/\*[[:space:]]core:${_REGION_NS}:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]*\*/[[:space:]]*$ ]]; then
      REGION_MARKER_ID="${BASH_REMATCH[1]}"
      REGION_INDENT="${line%%[! ]*}"
      return 0
    fi
  done
  return 1
}

# region_marker_re — a `grep -E` presence test for an OPENING marker in any enabled
# syntax. For the coarse "does this file carry a block at all?" question and for the
# tree-wide scan; it deliberately captures nothing, because a pattern that has to serve
# both a presence test and an id capture ends up doing neither well.
region_marker_re() {
  local s out=""
  for s in $_REGION_SYNTAX; do
    [[ "$s" == hash ]] && out="${out:+$out|}#"
    [[ "$s" == html ]] && out="${out:+$out|}<!--"
    [[ "$s" == css ]] && out="${out:+$out|}/\\*"
  done
  printf '^[[:space:]]*(%s)[[:space:]]core:%s:gen[[:space:]]' "$out" "$_REGION_NS"
}

# region_markers <file> — every marker in <file> as "kind id", one per line.
#
# ONE GRAMMAR, shared with region_marker_id by CONSTRUCTION rather than by care: this
# walks the file through that function instead of carrying a second regex. gen-theme.sh
# had a hand-written second pattern for exactly this job, which is how its preflight came
# to count only `gen` markers while its walker honoured both — a stray or duplicated `end`
# passed through as content. A marker the walker would honour can no longer be one the
# structural checks overlook.
region_markers() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if region_marker_id gen "$line"; then
      printf 'gen %s\n' "$REGION_MARKER_ID"
    elif region_marker_id end "$line"; then
      printf 'end %s\n' "$REGION_MARKER_ID"
    fi
  done <"$1"
}

# ── the walker ────────────────────────────────────────────────────────────────
# region_build_file <file> <render-fn> [only-ids]
#
# Emits <file> with every marked block re-rendered, on stdout. <render-fn> is called as
# `<render-fn> <id> <indent>` and must write the block body; a generator whose emitters
# ignore indentation simply ignores the second argument. Injected BY NAME because bash
# 3.2 has no function references.
#
# [only-ids], when non-empty, is a space-separated subset to re-render; every OTHER
# block's existing body is passed through unchanged, so the region is a no-op in the
# comparison rather than an empty one. That is what `gen-porting-matrix.sh --local`
# needs to compare the blocks whose inputs are in-repo without resolving a fleet.
#
# Returns 2 on any structural fault, having written a partial stream — every caller
# renders into a temp and branches on the status, so a fault never reaches the target.
region_build_file() {
  local file="$1" render="$2" only="${3:-}" line id indent found l2 endid inner sub
  while IFS= read -r line || [[ -n "$line" ]]; do
    if region_marker_id gen "$line"; then
      id="$REGION_MARKER_ID"
      indent="$REGION_INDENT"
      printf '%s\n' "$line" # the opening marker, verbatim
      sub=1
      if [[ -n "$only" ]]; then
        sub=0
        [[ " $only " == *" $id "* ]] && sub=1
      fi
      ((sub == 1)) && { "$render" "$id" "$indent" || return 2; }
      # Consume the stale block up to and including its end marker.
      found=0
      while IFS= read -r l2; do
        # A second `gen` before this block's `end` is a CROSSED or NESTED pair. The
        # preflight COUNTS cannot see it — `gen A, gen B, end A, end B` has exactly one
        # of each — and consuming it as stale body would silently drop block B from the
        # document.
        if region_marker_id gen "$l2"; then
          inner="$REGION_MARKER_ID"
          printf "%s: 'core:%s:gen %s' opens inside the '%s' region of %s — blocks cannot nest or cross\n" \
            "$_REGION_PROG" "$_REGION_NS" "$inner" "$id" "$file" >&2
          return 2
        fi
        if region_marker_id end "$l2"; then
          endid="$REGION_MARKER_ID"
          [[ "$endid" == "$id" ]] || {
            printf "%s: marker mismatch in %s: 'gen %s' closed by 'end %s'\n" \
              "$_REGION_PROG" "$file" "$id" "$endid" >&2
            return 2
          }
          printf '%s\n' "$l2"
          found=1
          break
        fi
        ((sub == 1)) || printf '%s\n' "$l2"
      done
      ((found == 1)) || {
        printf "%s: unterminated 'core:%s:gen %s' region in %s\n" \
          "$_REGION_PROG" "$_REGION_NS" "$id" "$file" >&2
        return 2
      }
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
}

# ── the structural preflight ──────────────────────────────────────────────────
# region_preflight_file <file> <registered-ids>
#
# Runs BEFORE anything is emitted or compared, and answers three questions about ONE
# file that the render pass cannot: are the pairs well-formed in SEQUENCE, does every
# registered block appear exactly once, and does every `gen` have exactly one `end`.
# Returns 2 on any fault, 0 otherwise. Messages go to stderr.
#
# The sequence replay is a one-slot state machine over region_markers' output, and it
# runs FIRST so a crossed pair is reported before any expensive input (a fleet read, a
# palette resolve) is touched. Its messages are byte-identical to the walker's, so the
# two paths read the same to anyone debugging a broken document.
#
# A block silently deleted from a consumer would otherwise just stop being generated and
# --check would stay green about a file it no longer covers — coverage loss reading as
# health, which is the failure mode the generators exist to end.
region_preflight_file() {
  local file="$1" ids="$2" rc=0 markers line kind id open="" n m
  markers="$(region_markers "$file")"

  # 1. Sequence: no nesting, no crossing, nothing left open.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%% *}"
    id="${line#* }"
    if [[ "$kind" == gen ]]; then
      [[ -z "$open" ]] || {
        printf "%s: 'core:%s:gen %s' opens inside the '%s' region of %s — blocks cannot nest or cross\n" \
          "$_REGION_PROG" "$_REGION_NS" "$id" "$open" "$file" >&2
        rc=2
        open=""
        break
      }
      open="$id"
    elif [[ -n "$open" && "$id" != "$open" ]]; then
      printf "%s: marker mismatch in %s: 'gen %s' closed by 'end %s'\n" \
        "$_REGION_PROG" "$file" "$open" "$id" >&2
      rc=2
      open=""
      break
    else
      open=""
    fi
  done <<EOF
$markers
EOF
  [[ -z "$open" ]] || {
    printf "%s: unterminated 'core:%s:gen %s' region in %s\n" \
      "$_REGION_PROG" "$_REGION_NS" "$open" "$file" >&2
    rc=2
  }

  # 2. Counts: each registered block exactly once, and `gen`/`end` in step. BOTH kinds,
  #    because the walker only ever pairs an `end` with the `gen` above it — so a stray
  #    or duplicated `end` would otherwise pass through as prose, and the contract is
  #    that a malformed marker fails rather than hides.
  for id in $ids; do
    n="$(grep -c "^gen $id\$" <<<"$markers" || true)"
    m="$(grep -c "^end $id\$" <<<"$markers" || true)"
    if [[ "$n" == 0 ]]; then
      printf '%s: %s: registered block is missing: %s (was its region deleted?)\n' \
        "$_REGION_PROG" "$file" "$id" >&2
      rc=2
    elif [[ "$n" != 1 ]]; then
      printf '%s: %s: block appears %s times: %s (ambiguous)\n' \
        "$_REGION_PROG" "$file" "$n" "$id" >&2
      rc=2
    fi
    [[ "$m" == "$n" ]] || {
      printf '%s: %s: block %s has %s gen marker(s) but %s end marker(s) — every gen needs exactly one matching end\n' \
        "$_REGION_PROG" "$file" "$id" "$n" "$m" >&2
      rc=2
    }
  done
  return $rc
}

# region_unregistered_in_file <file> <registered-ids>
#
# The reverse direction, within ONE file: a marker of either kind whose id the registry
# does not know about. Without it, adding a block and forgetting to register it reads as
# success — the region is simply never rendered.
#
# For a generator whose blocks span MANY files, region_scan_tree below is the right
# reverse check instead: this one can only see the files it is handed, and the case that
# matters there is a marker in a file nobody registered at all.
region_unregistered_in_file() {
  local file="$1" ids="$2" rc=0 line kind id
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%% *}"
    id="${line#* }"
    [[ " $ids " == *" $id "* ]] || {
      printf '%s: %s carries an unregistered %s marker: %s — add the block to %s, or remove the marker\n' \
        "$_REGION_PROG" "$file" "$kind" "$id" "$_REGION_HINT" >&2
      rc=2
    }
  done <<EOF
$(region_markers "$file")
EOF
  return $rc
}

# ── the tree-wide reverse scan ────────────────────────────────────────────────
# region_scan_tree <registry-tsv> <extension…>
#
# Hunts the whole working tree for an opening marker in a file the registry does not
# claim. <registry-tsv> is `id<TAB>path` rows (the resolved block registry); each
# extension is a glob like '*.toml'.
#
# GIT-AWARE when the tree is a repo, because a plain recursive walk is wrong in a way
# that only shows up on a developer box: it descends into `.claude/worktrees/`, where
# Claude Code parks a full checkout per session, and every themed consumer in every OTHER
# session's worktree is reported as unregistered drift. `_audit_ls` (tracked +
# untracked-but-not-ignored, from common.sh) is the right primitive — it keeps the
# property that motivates the scan, an untracked consumer about to be committed is still
# caught, while inheriting git's exclusions.
#
# THE FALLBACK IS NOT BELT-AND-BRACES. The behavioral suite's fixtures are plain
# directories with no `git init`, so git-only discovery would list zero files there and
# report success — coverage loss reading as health, the exact failure this scan exists to
# end. The walk is correct in a fixture, which has no nested checkouts to trip over.
#
# The git path is taken only when the work-tree root IS the directory being scanned: a
# fixture created under a $TMPDIR that happens to sit inside some other repo would
# otherwise satisfy `--is-inside-work-tree` and get that repo's file list.
#
# scripts/ is EXCLUDED: it is dev tooling, never a shipped consumer, and the suite's
# hermetic fixtures legitimately contain marker text inside heredocs. Scanning it would
# report the generators' own test suite as drift.
region_scan_tree() {
  local registry="$1"
  shift
  local rc=0 line f id top files re
  re="$(region_marker_re)"

  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [[ -n "$top" && "$top" -ef "$PWD" ]]; then
    files="$(_audit_ls "$@")"
  else
    local find_args=() ext first=1
    for ext in "$@"; do
      ((first == 1)) || find_args+=(-o)
      find_args+=(-name "$ext")
      first=0
    done
    # `"${arr[@]+"${arr[@]}"}"`, not a bare expansion: `set -u` on bash 3.2 treats an
    # EMPTY array expansion as unset and aborts (PORTABILITY.md §1). Callers always pass
    # at least one extension, so this is the belt on a brace — but the failure it guards
    # is a hard abort on the one platform the gate cannot skip.
    files="$(find . -name .git -prune -o -name .claude -prune -o -type f \
      \( "${find_args[@]+"${find_args[@]}"}" \) -print 2>/dev/null | sed 's|^\./||' | sort -u)"
  fi

  # `/dev/null` in the grep argument list does two jobs, both load-bearing:
  #   1. a batch of exactly one file still prints a filename — without it grep emits
  #      bare `LINE:text` and the awk below reads the line number as the path;
  #   2. it makes the empty-input case safe WITHOUT GNU's `xargs -r`, which BSD/macOS
  #      xargs does not accept. On empty input GNU xargs runs grep once with only
  #      /dev/null to read, which is a clean no-match rather than a read from stdin.
  # `tr '\n' '\0' | xargs -0` is the idiom common.sh already uses, likewise without `-r`.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    f="${line%%:*}"
    # THE LAST FIELD IS NOT THE ID IN EVERY SYNTAX. On the CSS form it is the closing
    # `*/`, so every CSS block would report as unregistered under a name no registry
    # could ever carry (#926). Strip a trailing `*/` first.
    id="${line##* }"
    [[ "$id" == '*/' ]] && { id="${line% \*/}"; id="${id##* }"; }
    grep -qxF "$(printf '%s\t%s' "$id" "$f")" <<<"$registry" || {
      printf '%s: %s carries an unregistered block: %s\n' "$_REGION_PROG" "$f" "$id" >&2
      rc=2
    }
  done < <(printf '%s\n' "$files" | grep -v '^scripts/' |
    tr '\n' '\0' | xargs -0 grep -nE "$re" /dev/null 2>/dev/null |
    awk -F: '{f=$1; $1=""; $2=""; sub(/^ +/,""); print f":"$0}' |
    sed 's/[[:space:]]*$//' | sort -u)
  return $rc
}

# ── the install ───────────────────────────────────────────────────────────────
# region_install <content-file> <target> <mode-policy>
#
# Puts a fully-rendered <content-file> in place of <target>. <mode-policy> is:
#
#   preserve — truncate-and-write through the EXISTING inode, keeping its mode. What
#              gen-theme.sh needs: its targets include tmux/scripts/*.sh at 0755, and
#              audit-core.sh §2 asserts those exec bits. A mktemp+mv install would land
#              0644 over them.
#   0644     — atomic rename from a sibling temp. What the document generators need: a
#              full disk or a kill leaves the old file intact rather than a half-written
#              one, and the forced mode matches what git stores for a tracked doc
#              (mktemp creates 0600 and mv preserves it, so without the chmod every
#              regeneration would turn a world-readable file owner-only).
#
# Both branches are fully BRANCHED rather than chained: nothing here runs under `set -e`,
# and an unchecked copy prints success over a stale or partial file.
region_install() {
  local src="$1" target="$2" policy="$3" tmp

  if [[ "$policy" == preserve ]]; then
    if cat "$src" >"$target"; then
      return 0
    fi
    printf '%s: could not write %s — it may be incomplete\n' "$_REGION_PROG" "$target" >&2
    return 2
  fi

  # A TEMPLATED temp, never a bare `mktemp` — that is a BSD failure (PORTABILITY.md).
  # A SIBLING of the target, so the rename below is an atomic same-filesystem one.
  if ! tmp="$(mktemp "$target.XXXXXX" 2>/dev/null)"; then
    printf '%s: could not create a temp file beside %s\n' "$_REGION_PROG" "$target" >&2
    return 2
  fi
  if cat "$src" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp"
  printf '%s: could not write %s — left untouched\n' "$_REGION_PROG" "$target" >&2
  return 2
}
