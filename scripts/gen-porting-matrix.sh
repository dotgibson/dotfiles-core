#!/usr/bin/env bash
# scripts/gen-porting-matrix.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render PORTING-MATRIX.md's two data tables FROM the OS repos that own the data.
#
# THE DEFECT THIS CLOSES (#686). PORTING-MATRIX.md is ~1,350 lines. Its two tables
# (~60 lines) restate data the OS repos already hold and already enforce: the
# package-manager verbs live in each repo's os/<os>.capabilities (schema-gated by
# scripts/check-capabilities.sh), and the package names live in each repo's
# install/packages.txt — where dotfiles-Debian's `# only:kali` / `# skip:kali` tiers
# decide which of its two columns a line reaches and `# min:X.Y.Z` is a floor
# test/check-packages.sh enforces. The matrix kept a second, unenforced copy of all of
# it, and the copy is what the fleet reads (dotfiles-web mirrors this file release by
# release). This is theme/palette.toml → gen-theme.sh and the zsh sources →
# gen-aliases.sh, applied to the matrix: the repos are authoritative, the tables are
# rendered, and `make audit` fails when either moves without the other.
#
# WHAT IS GENERATED, AND WHAT DELIBERATELY IS NOT. Only the two regions between marker
# pairs (the shape gen-aliases.sh uses):
#
#     <!-- core:porting-matrix:gen packages -->
#     …a table rendered from the fleet…
#     <!-- core:porting-matrix:end packages -->
#
# Everything outside them — the recipe, the ~1,100 lines of numbered footnotes, the
# clipboard table, the quirks, the repo status — is hand-written judgment and is never
# touched. The footnotes are the reason the file exists; `/os-package-availability`
# is the routine that refreshes them, not this script.
#
# THE TABLE IS A HYBRID, AND THE REGISTRY SAYS WHICH HALF EACH CELL IS. About half of
# the package cells name a package the repo INSTALLS: those are DERIVED (`=` in
# PKG_ROWS), rendered from the packages.txt line that matches one of the tool's
# candidate names, with a `# min:` floor appended as ` ≥ X`. The other half are
# ASSERTED: footnote-²¹ "available, not installed" names, and sentinels such as
# asset²⁸ / cargo³ / AUR / GURU that record an out-of-band install route only
# bootstrap.sh knows. Those cells are the registry's literal text, verbatim. The two
# halves are held together by ONE rule: an asserted cell whose tool the repo now
# installs is exit 2, naming the cell and the packages.txt line — so "flip it to `=`"
# is a gate failure, never a quiet omission. The commands table is simpler: every
# cell is the declared PKG_* value, verbatim, plus a placeholder; a column backed by
# two declarations (openSUSE Leap/Tumbleweed) renders both, labelled.
#
#   gen-porting-matrix.sh              # rewrite both marked regions in PORTING-MATRIX.md
#   gen-porting-matrix.sh --check      # exit 1 (with a diff) if a region is stale — THE GATE
#   gen-porting-matrix.sh --list       # every cell's provenance: block<TAB>row<TAB>column<TAB>derived|asserted<TAB>source
#   gen-porting-matrix.sh --root DIR   # run against another Core tree (test-core.sh's fixtures)
#   gen-porting-matrix.sh --fleet DIR  # where the sibling OS clones live (default: the parent
#                                      #   of the Core tree — inside a git worktree, pass this)
#
# NEEDS THE SIBLING CLONES, so unlike gen-aliases.sh it CAN be unable to answer: with a
# required repo not checked out it exits 3 and writes nothing. audit-core.sh §9h
# records that as an environment SKIP (the posture §9c and fleet-drift.sh take) — a
# lone CI checkout of this repo is not a gate failure, and --require-siblings is what
# reds it. Nothing is generated from a partial fleet: a table with one column stale
# reads as health.
#
# PURE BASH + AWK, NO python3/jq/yq, bash 3.2 (no mapfile, no `declare -A`,
# PORTABILITY.md §1). The awk is POSIX (the Alpine CI leg runs busybox). The tables are
# emitted in prettier's aligned form — conform runs prettierd on markdown at save, so an
# unpadded table would be re-padded on the next save and read as drift. Widths are
# counted in code points under LC_ALL=C (every character in this file is width 1).
#
# Exit: 0 = clean; 1 = drift (a rendered region differs from what is on disk);
#       2 = the generator cannot run — a derived cell no line matches, an asserted
#           cell the repo now installs, an ambiguous match, a missing declaration
#           key, a broken marker, a registry error, an I/O failure, or a usage error;
#       3 = uncovered — a required sibling repo is not checked out (named).
# Structure is checked before coverage: a broken marker in this repo's own file is 2
# even when no sibling is checked out, so 3 is only ever reported for a well-formed
# document. Within a run 2 beats 1 (gen-aliases.sh's convention).
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Via the ALREADY-ABSOLUTE $HERE, not ${BASH_SOURCE[0]%/*}: we cd below, and
# BASH_SOURCE stays relative to the caller's original directory (gen-theme.sh:66).

# For load_os_repos / resolve_repo_dir (the fleet lookup every fan-out script shares)
# and core_files_identical — the cmp/diff BINARIES are forbidden in this repo (#572).
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

MODE=bare
ROOT=""
FLEET=""
while (($#)); do
  case "$1" in
  --check) MODE=check ;;
  --list) MODE=list ;;
  --root)
    [[ -n "${2:-}" ]] || { printf 'gen-porting-matrix: --root needs a directory\n' >&2; exit 2; }
    ROOT="$2"; shift ;;
  --fleet)
    [[ -n "${2:-}" ]] || { printf 'gen-porting-matrix: --fleet needs a directory\n' >&2; exit 2; }
    FLEET="$2"; shift ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0 ;;
  *)
    printf 'gen-porting-matrix: unexpected argument: %s (try --help)\n' "$1" >&2
    exit 2 ;;
  esac
  shift
done

# --root lets the behavioural suite drive this against a hermetic fixture tree; --fleet
# lets it point at a fixture fleet (and lets a worktree checkout, whose parent is
# .claude/worktrees/, name the real one).
[[ -n "$ROOT" ]] && HERE="$(cd -- "$ROOT" && pwd)"
cd "$HERE" || exit 2
[[ -n "$FLEET" ]] || FLEET="$(cd -- "$HERE/.." && pwd)"

TARGET="PORTING-MATRIX.md"
TAB="$(printf '\t')"

# --list's rows accumulate here: the renderers run inside command substitutions, so a
# shell variable they append to would be lost with the subshell.
LISTFILE="$(mktemp "${TMPDIR:-/tmp}/gen-porting-matrix.list.XXXXXX")" || exit 2
trap 'rm -f "$LISTFILE"' EXIT

# ── the registry ──────────────────────────────────────────────────────────────
# Block ids, in the doc's order. Each has exactly one marker pair in $TARGET.
BLOCK_IDS="commands packages"

# The commands table. id<TAB>header<TAB>repo<TAB>declaration(s)<TAB>unit
#   declaration(s): space-separated `os/<os>.capabilities` paths, each optionally
#   `Label=path`; a column with more than one renders differing values as
#   `Label: `v` · Label: `v``, identical values once.
#   unit: the word inside the install/remove placeholder — <pkg>, or <atom> on Gentoo.
CMD_COLUMNS="macos	macOS (brew)	dotfiles-MacBook	os/macos.capabilities	pkg
fedora	Fedora (dnf)	dotfiles-Fedora	os/fedora.capabilities	pkg
arch	Arch	dotfiles-Arch	os/arch.capabilities	pkg
opensuse	openSUSE	dotfiles-openSUSE	Leap=os/opensuse.leap.capabilities Tumbleweed=os/opensuse.capabilities	pkg
alpine	Alpine	dotfiles-Alpine	os/alpine.capabilities	pkg
gentoo	Gentoo	dotfiles-Gentoo	os/gentoo.capabilities	atom
kali	Kali (apt)	dotfiles-Debian	os/debian.kali.capabilities	pkg
debian	Debian/Ubuntu (apt)	dotfiles-Debian	os/debian.capabilities	pkg"

# action<TAB>key<TAB>placeholder — `unit` means the column's unit word in angle brackets.
CMD_ROWS="refresh	PKG_REFRESH	-
upgrade	PKG_UPGRADE	-
count-pending	PKG_COUNT_PENDING	-
install	PKG_INSTALL	unit
remove	PKG_REMOVE	unit
search	PKG_SEARCH	<term>
owns-file	PKG_OWNS	<path>"

# column/action<TAB>footnote marks appended to that cell. Curation: the footnote is
# about the VERB, so the mark travels with the cell, not with the declaration.
CMD_MARKS="fedora/refresh	³⁵
arch/refresh	²³
arch/count-pending	²³
macos/count-pending	³⁶
gentoo/count-pending	³⁷
macos/owns-file	³⁸"

# The package table. id<TAB>header<TAB>repo<TAB>tier
#   tier: `-` reads install/packages.txt whole; an os-release ID reads it THROUGH the
#   repo's scripts/pkg-filter.sh (pkg_filter_lines <file> <id>), so the grammar stays
#   the repo's own and dotfiles-Debian's one list feeds two columns exactly as its
#   bootstrap.sh sees it. A comma-separated list reads the file once PER ID: a column
#   that stands for several targets renders a derived cell only when every ID agrees
#   (same line, same floor) and refuses (exit 2) otherwise — a `skip:ubuntu` line must
#   not be shown as shared just because the debian pass saw it.
PKG_COLUMNS="arch	Arch	dotfiles-Arch	-
opensuse	openSUSE	dotfiles-openSUSE	-
alpine	Alpine	dotfiles-Alpine	-
gentoo	Gentoo (atom)	dotfiles-Gentoo	-
kali	Kali (apt)²¹ᵃ	dotfiles-Debian	kali
debian	Debian/Ubuntu	dotfiles-Debian	debian,ubuntu"

# label<TAB>candidates<TAB>arch<TAB>opensuse<TAB>alpine<TAB>gentoo<TAB>kali<TAB>debian
#   label       the Tool cell, verbatim (its footnote marks included)
#   candidates  space-separated package names that install this tool, matched against
#               each line's name and, for a `category/name` atom, its basename;
#               `-` means the label's leading [A-Za-z0-9._+-] run
#   cell        `=`            derived: the matching line's name, in backticks, with a
#                              `# min:` floor as ` ≥ X` — exactly one line must match
#               `=name`        derived, matching only that name (overrides candidates)
#               `=…marks`      either form with footnote marks appended (`=⁴`)
#               anything else  asserted: rendered verbatim; exit 2 if the repo installs
#                              a candidate, because then it should be `=`
# Row order is the doc's order. A tool the fleet starts packaging is a one-cell edit.
PKG_ROWS="eza	-	=	=	=	=	=	=
bat	-	=	=	=	=	=⁴	=⁴
fd	fd fd-find	=	=	=	=	=⁴	=⁴
ripgrep	-	=	=	=	=	=	=
zoxide	-	=	=	=	=	=	=
fzf	-	=	=	=	=	=	=
git-delta	git-delta delta	=	=	=	=	asset²⁸	=
btop	-	=	=	=	=	=	=
tldr	tldr tealdeer	=	=¹	cargo³	\`app-misc/tealdeer\`¹²	=	=
neovim³³	-	=	=	=	=	=	asset²⁸
lazygit	-	=	=	=	\`dev-vcs/lazygit\`¹²	=	asset²⁸
zsh	-	=	=	=²	=	=	=
tmux	-	=	=	=	=	=	=
starship	-	=	=¹⁸	=	=	=	asset²⁸
atuin²⁰	-	=	=¹⁸	=	=	asset²⁸	asset²⁸
mise³⁰	-	=	script³⁰	script³⁰	script³⁰	asset²⁸	asset²⁸
direnv³²	-	=	=	=	\`app-shells/direnv\`¹²	=	=
yazi	-	=	=¹⁸	=	\`app-misc/yazi\`¹²	cargo³	—²⁹
tree-sitter-cli⁵	tree-sitter-cli tree-sitter	=	=	=	=	=	asset²⁸
jq³⁴	-	=	=	=	=	=	=
yq⁶	yq go-yq yq-go	=	=	=	=	=	go³
duf	-	=	=	testing¹⁴	=	=	=
dust	dust du-dust	=	=	=	=	=⁴	asset²⁸
procs	-	=	=	=	=	=	asset²⁸
viddy¹⁶	-	AUR¹⁶	\`viddy\`¹⁸	=	cargo³	cargo³	—²⁹
sd²²	-	=	=	=	\`sys-apps/sd\`¹²	=	=
gron	-	=	=	=	go³	=	=
jnv¹⁷	-	\`jnv\`	cargo	cargo³	cargo	cargo	—²⁹
lnav²¹ ²⁴	-	\`lnav\`	\`lnav\`	=	=²⁴	\`lnav\`²⁴	\`lnav\`
glow	-	=	=	testing¹⁴	\`app-misc/glow\`¹²	=¹⁵	charm apt
gum	-	=	=	=	mise³⁰	=¹⁵	charm apt
xh	-	=	=	=	\`net-misc/xh\`¹²	=	asset²⁸
doggo	-	=	\`doggo\`¹⁸	=	=	go³	go³
gping¹⁹	-	\`gping\`	\`gping\`¹⁹	=	GURU¹⁹	\`gping\`¹⁹	\`gping\`
carapace	-	AUR²⁷	rpm²⁷	=	\`app-shells/carapace\`¹²	deb²⁷	deb²⁷
op (1Password)¹³	op 1password-cli	AUR	vendor rpm	vendor apk	GURU¹²	vendor apt	vendor apt
hyperfine²¹	-	\`hyperfine\`	\`hyperfine\`	=	=	\`hyperfine\`	\`hyperfine\`
watchexec²¹ ²⁵	-	\`watchexec\`	\`watchexec\`	=	cargo²⁵	cargo²⁵	—²⁹
shellcheck²¹	shellcheck ShellCheck shellcheck-bin	\`shellcheck\`	\`ShellCheck\`	=	=	\`shellcheck\`	\`shellcheck\`
shfmt⁷ ²¹	-	\`shfmt\`	\`shfmt\`	=	go²¹	\`shfmt\`⁷	\`shfmt\`
ouch²¹	-	\`ouch\`	=¹⁸	testing¹⁴	GURU¹² ²¹	cargo²¹	—²⁹
jujutsu (jj)⁸	jujutsu jj	\`jujutsu\`	\`jujutsu\`	=	\`dev-vcs/jj\`²¹	cargo²¹	—²⁹
sesh⁹	-	AUR⁹	go⁹	go⁹	go⁹	go⁹	go³
difftastic¹⁰	-	\`difftastic\`	\`difftastic\`	=	=	asset²⁸	asset²⁸
git-absorb²¹ ²⁶	-	\`git-absorb\`	\`git-absorb\`	=	=	\`git-absorb\`	\`git-absorb\`
ast-grep¹¹	-	\`ast-grep\`	=¹⁸	=	cargo²¹	cargo²¹	—²⁹
uv³⁰	uv python3-uv	=	\`python3-uv\`²¹	=	=	asset²⁸	asset²⁸
w3m	-	=	=	=	=	=	="

# ── helpers ───────────────────────────────────────────────────────────────────
die() { printf 'gen-porting-matrix: %s\n' "$*" >&2; exit 2; }


# _table — stdin: TAB-separated rows, header first; stdout: prettier's aligned table.
# Widths in CODE POINTS: under LC_ALL=C every byte is one character, and the UTF-8
# continuation bytes (0x80–0xBF) are the ones that are not a character of their own.
_table() {
  LC_ALL=C awk -F'\t' '
    BEGIN { for (i = 128; i < 192; i++) cont[sprintf("%c", i)] = 1 }
    function width(s,  i, n, w) { n = length(s); w = 0; for (i = 1; i <= n; i++) if (!(substr(s, i, 1) in cont)) w++; return w }
    function pad(s, w,  t) { t = s; while (width(t) < w) t = t " "; return t }
    function dashes(w,  t) { t = ""; while (length(t) < w) t = t "-"; return t }
    {
      if (NR > 1 && NF != nf) { printf "gen-porting-matrix: row %d has %d cells, the header has %d\n", NR, NF, nf > "/dev/stderr"; exit 2 }
      nf = NF
      for (i = 1; i <= NF; i++) { cell[NR, i] = $i; w = width($i); if (w > wid[i]) wid[i] = w }
      rows = NR
    }
    END {
      if (rows < 2) { print "gen-porting-matrix: a table needs a header and at least one row" > "/dev/stderr"; exit 2 }
      for (r = 1; r <= rows; r++) {
        line = "|"
        for (i = 1; i <= nf; i++) line = line " " pad(cell[r, i], wid[i]) " |"
        print line
        if (r == 1) { line = "|"; for (i = 1; i <= nf; i++) line = line " " dashes(wid[i]) " |"; print line }
      }
    }'
}

# ── the fleet: every repo the registry names must be checked out ──────────────
REPO_DIRS=""   # "name<TAB>dir" lines
MISSING=""
resolve_fleet() {
  local names="" name dir
  names="$(printf '%s\n%s\n' "$CMD_COLUMNS" "$PKG_COLUMNS" | awk -F'\t' 'NF { print $3 }' | sort -u)"
  load_os_repos || die "$CORE_OS_REPOS_ERR — cannot enumerate the fleet"
  for name in $names; do
    # A registry naming a repo the fleet list does not is a registry error, not a skip.
    [[ " ${CORE_OS_REPOS[*]} " == *" $name "* ]] || die "$name is named by the registry but is not in scripts/os-repos.txt"
    dir="$(resolve_repo_dir "$FLEET" "$name")" || dir="$FLEET/$name"
    # `-e`, not `-d`: .git is a FILE in a worktree checkout.
    if [[ -e "$dir/.git" ]]; then
      REPO_DIRS="$REPO_DIRS$name$TAB$dir
"
    else
      MISSING="$MISSING $name"
    fi
  done
  [[ -z "$MISSING" ]] || return 3
  return 0
}

repo_dir() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' <<EOF
$REPO_DIRS
EOF
}

# ── the commands table ────────────────────────────────────────────────────────
# CAPS: column<TAB>label<TAB>key<TAB>value, from every declaration the registry names.
# The reader is scripts/check-capabilities.sh's: KEY=value, `#` a comment only at line
# start — a `#` inside a value is part of the value.
CAPS=""
read_caps() {
  local col repo files spec label path dir
  while IFS="$TAB" read -r col _ repo files _; do
    [[ -n "$col" ]] || continue
    dir="$(repo_dir "$repo")"
    for spec in $files; do
      label=""; path="$spec"
      [[ "$spec" == *=* ]] && { label="${spec%%=*}"; path="${spec#*=}"; }
      [[ -r "$dir/$path" ]] || die "$repo has no $path — the registry names a declaration the repo does not carry"
      CAPS="$CAPS$(awk -v col="$col" -v label="$label" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { i = index($0, "="); if (!i) next; printf "%s\t%s\t%s\t%s\n", col, label, substr($0, 1, i - 1), substr($0, i + 1) }' "$dir/$path")
"
    done
  done <<EOF
$CMD_COLUMNS
EOF
}

# render_commands — ONE awk over CMD_COLUMNS, CMD_ROWS, CMD_MARKS and CAPS, emitting the
# TAB-separated rows for _table and the provenance lines. One process, not one per
# cell: the first cut forked awk and sed several times per cell, which put a single run
# at ~7 s and F10c's fifty-odd runs past the Linux legs' 15-minute audit budget.
render_commands() {
  {
    printf 'C\t%s\n' "$CMD_COLUMNS" | awk -F'\t' 'NR == 1 { print; next } { print "C\t" $0 }'
    printf 'A\t%s\n' "$CMD_ROWS" | awk 'NR == 1 { print; next } { print "A\t" $0 }'
    printf 'M\t%s\n' "$CMD_MARKS" | awk 'NR == 1 { print; next } { print "M\t" $0 }'
    printf '%s' "$CAPS" | awk 'NF { print "K\t" $0 }'
  } | awk -F'\t' -v listfile="$LISTFILE" '
    function esc(s,    out, k) { out = ""; while ((k = index(s, "|")) > 0) { out = out substr(s, 1, k - 1) "\\|"; s = substr(s, k + 1) } return out s }
    function err(msg) { print "gen-porting-matrix: " msg > "/dev/stderr" }
    $1 == "C" { nc++; cid[nc] = $2; chdr[nc] = $3; crepo[nc] = $4; cfiles[nc] = $5; cunit[nc] = $6; next }
    $1 == "A" { na++; act[na] = $2; akey[na] = $3; aph[na] = $4; next }
    $1 == "M" { mark[$2] = $3; next }
    $1 == "K" { val[$2 SUBSEP $3 SUBSEP $4] = $5; has[$2 SUBSEP $3 SUBSEP $4] = 1; next }
    END {
      line = "Action"
      for (c = 1; c <= nc; c++) line = line "\t" esc(chdr[c])
      print line
      for (a = 1; a <= na; a++) {
        line = act[a]
        for (c = 1; c <= nc; c++) {
          ph = aph[a]
          if (ph == "unit") ph = "<" cunit[c] ">"
          if (ph == "-") ph = ""
          nf = split(cfiles[c], specs, " ")
          cell = ""; first = ""; same = 1; src = ""
          for (i = 1; i <= nf; i++) {
            label = ""; path = specs[i]
            if ((k = index(path, "=")) > 0) { label = substr(path, 1, k - 1); path = substr(path, k + 1) }
            src = src (i > 1 ? " " : "") crepo[c] "/" path
            key = cid[c] SUBSEP label SUBSEP akey[a]
            if (!(key in has)) { err(cid[c] " declares no " akey[a]); exit 2 }
            v = val[key]
            if (v == "") { err(cid[c] ": " akey[a] " is empty"); exit 2 }
            if (index(v, "`")) { err(cid[c] ": " akey[a] " contains a backtick, which cannot sit inside a code span"); exit 2 }
            if (i == 1) first = v; else if (v != first) same = 0
            if (ph != "") v = v " " ph
            cell = cell (i > 1 ? " · " : "") (label != "" ? label ": " : "") "`" esc(v) "`"
          }
          # Every declaration agrees: one cell, no labels.
          if (nf > 1 && same) cell = "`" esc(first (ph != "" ? " " ph : "")) "`"
          line = line "\t" cell mark[cid[c] "/" act[a]]
          printf "commands\t%s\t%s\tderived\t%s\n", act[a], cid[c], src >> listfile
        }
        print line
      }
      close(listfile)
    }' | _table
}

# ── the package table ─────────────────────────────────────────────────────────
# PKGS: column<TAB>line<TAB>name<TAB>basename<TAB>floor<TAB>id, one per data line the
# column sees under each of its tier IDs (`-` for an untiered column). The name is what blib_read_pkgs (lib/bootstrap-lib.sh) makes of the line —
# everything before the first `#`, whitespace removed — so what is matched here is
# exactly what the repo's bootstrap installs. Tiered columns see the file through the
# repo's own pkg_filter_lines; the lines are numbered first so a filtered line still
# knows where it came from.
PKGS=""
read_pkgs() {
  local col repo tier dir file numbered filtered id
  while IFS="$TAB" read -r col _ repo tier; do
    [[ -n "$col" ]] || continue
    dir="$(repo_dir "$repo")"
    file="$dir/install/packages.txt"
    [[ -r "$file" ]] || die "$repo has no install/packages.txt — the registry expects one"
    numbered="$(mktemp "${TMPDIR:-/tmp}/gen-porting-matrix.XXXXXX")" || die "could not create a temp file"
    awk '{ print NR "\t" $0 }' "$file" >"$numbered" || { rm -f "$numbered"; die "could not read $file"; }
    [[ "$tier" == - ]] || {
      [[ -r "$dir/scripts/pkg-filter.sh" ]] || { rm -f "$numbered"; die "$repo has no scripts/pkg-filter.sh — the $col column is tiered ($tier) and cannot be read without it"; }
      # shellcheck source=/dev/null
      source "$dir/scripts/pkg-filter.sh"
      command -v pkg_filter_lines >/dev/null || { rm -f "$numbered"; die "$repo/scripts/pkg-filter.sh does not define pkg_filter_lines"; }
    }
    for id in ${tier//,/ }; do
    if [[ "$id" == - ]]; then
      filtered="$(cat "$numbered")"
    else
      filtered="$(pkg_filter_lines "$numbered" "$id")" || { rm -f "$numbered"; die "pkg_filter_lines refused $file"; }
    fi
    PKGS="$PKGS$(awk -F'\t' -v col="$col" -v id="$id" '
      {
        n = $1; line = $0; sub(/^[^\t]*\t/, "", line)
        cmt = ""; i = index(line, "#"); if (i) { cmt = substr(line, i + 1); line = substr(line, 1, i - 1) }
        gsub(/[[:space:]]/, "", line)
        if (line == "") next
        floor = ""
        if (match(cmt, /min:[0-9][^[:space:]]*/)) floor = substr(cmt, RSTART + 4, RLENGTH - 4)
        base = line; k = split(line, parts, "/"); if (k > 1) base = parts[k]
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", col, n, line, base, floor, id
      }' <<EOF
$filtered
EOF
)
"
    done
    rm -f "$numbered"
  done <<EOF
$PKG_COLUMNS
EOF
}

# render_packages — ONE awk over PKG_COLUMNS, PKG_ROWS and PKGS (see render_commands for
# why it is one process). Cell grammar is documented at PKG_ROWS.
render_packages() {
  {
    printf 'C\t%s\n' "$PKG_COLUMNS" | awk -F'\t' 'NR == 1 { print; next } { print "C\t" $0 }'
    printf 'R\t%s\n' "$PKG_ROWS" | awk 'NR == 1 { print; next } { print "R\t" $0 }'
    printf '%s' "$PKGS" | awk 'NF { print "P\t" $0 }'
  } | awk -F'\t' -v listfile="$LISTFILE" '
    function esc(s,    out, k) { out = ""; while ((k = index(s, "|")) > 0) { out = out substr(s, 1, k - 1) "\\|"; s = substr(s, k + 1) } return out s }
    function err(msg) { print "gen-porting-matrix: " msg > "/dev/stderr" }
    function ascii(s) { sub(/[^A-Za-z0-9._+-].*/, "", s); return s }     # the tool name in a label
    function pkgname(s) { sub(/[^A-Za-z0-9._+\/-].*/, "", s); return s }  # an =name override
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
    function inlist(x, list,    n, i, a) { n = split(list, a, " "); for (i = 1; i <= n; i++) if (a[i] == x) return 1; return 0 }
    $1 == "C" { nc++; cid[nc] = $2; chdr[nc] = $3; crepo[nc] = $4; ntier[nc] = split($5, t, ","); for (i = 1; i <= ntier[nc]; i++) tier[nc, i] = t[i]; next }
    $1 == "R" { nr++; rnf[nr] = NF - 1; for (i = 2; i <= NF; i++) row[nr, i - 1] = $i; next }
    $1 == "P" { np++; pcol[np] = $2; pline[np] = $3; pname[np] = $4; pbase[np] = $5; pfloor[np] = $6; pid[np] = $7; next }
    END {
      line = "Tool"
      for (c = 1; c <= nc; c++) line = line "\t" esc(chdr[c])
      print line
      for (r = 1; r <= nr; r++) {
        if (rnf[r] != 8) { err("PKG_ROWS: a row does not have 8 fields: " row[r, 1]); exit 2 }
        label = row[r, 1]; lbl = ascii(label)
        cands = (row[r, 2] == "-") ? lbl : row[r, 2]
        line = esc(label)
        for (c = 1; c <= nc; c++) {
          spec = row[r, c + 2]; file = crepo[c] "/install/packages.txt"
          if (substr(spec, 1, 1) == "=") {
            spec = substr(spec, 2); name = pkgname(spec); marks = ltrim(substr(spec, length(name) + 1))
            # The override belongs to THIS cell: `want` never touches the row candidates.
            want = (name != "") ? name : cands
            nh = 0
            for (p = 1; p <= np; p++) if (pcol[p] == cid[c] && (inlist(pname[p], want) || inlist(pbase[p], want))) hit[++nh] = p
            if (nh == 0) { err(lbl " / " cid[c] ": no line in " file " installs it (candidates: " want ") — change the cell to what the repo does, or restore the package"); exit 2 }
            # EVERY tier ID behind the column must see the same line with the same floor:
            # one cell cannot say two things, so a skip:ubuntu line under Debian/Ubuntu is
            # a refusal that names the split, not a shared-looking cell.
            for (i = 1; i <= ntier[c]; i++) {
              n = 0; names = ""
              for (h = 1; h <= nh; h++) if (pid[hit[h]] == tier[c, i]) { n++; names = names (n > 1 ? ", " : "") pname[hit[h]] }
              if (n == 0) {
                seen = ""; for (h = 1; h <= nh; h++) seen = seen (h > 1 ? ", " : "") pid[hit[h]] ":" pname[hit[h]]
                err(lbl " / " cid[c] ": the " tier[c, i] " tier does not install it but another tier of the same column does (" seen ") — one cell cannot render a split; tier it apart or footnote it"); exit 2
              }
              if (n > 1) { err(lbl " / " cid[c] ": several lines in " file " match under " tier[c, i] " (" names ") — name one with =<name>"); exit 2 }
            }
            key1 = pline[hit[1]] SUBSEP pname[hit[1]] SUBSEP pfloor[hit[1]]
            for (h = 2; h <= nh; h++) if (pline[hit[h]] SUBSEP pname[hit[h]] SUBSEP pfloor[hit[h]] != key1) {
              seen = ""; for (k = 1; k <= nh; k++) seen = seen (k > 1 ? ", " : "") pid[hit[k]] ":" pname[hit[k]] (pfloor[hit[k]] == "" ? "" : " min:" pfloor[hit[k]])
              err(lbl " / " cid[c] ": the tiers disagree on the line or its floor (" seen ") — one cell cannot render a split"); exit 2
            }
            p = hit[1]
            if (index(pname[p], "`")) { err(lbl " / " cid[c] ": the package name contains a backtick"); exit 2 }
            cell = "`" esc(pname[p]) "`"
            if (pfloor[p] != "") cell = cell " ≥ " esc(pfloor[p])
            cell = cell marks
            printf "packages\t%s\t%s\tderived\t%s:%s\n", lbl, cid[c], file, pline[p] >> listfile
          } else {
            for (p = 1; p <= np; p++) if (pcol[p] == cid[c] && (inlist(pname[p], cands) || inlist(pbase[p], cands))) {
              err(lbl " / " cid[c] " is asserted as \"" spec "\" but " file ":" pline[p] " now installs " pname[p] " — change the cell to = (and re-check its footnote)"); exit 2
            }
            cell = esc(spec)
            printf "packages\t%s\t%s\tasserted\tscripts/gen-porting-matrix.sh PKG_ROWS\n", lbl, cid[c] >> listfile
          }
          line = line "\t" cell
        }
        print line
      }
      close(listfile)
    }' | _table
}

# ── the block walker (gen-aliases.sh's, HTML-comment markers) ─────────────────
marker_id() { # $1 = gen|end, $2 = line; prints the id, or returns 1
  local kind="$1" line="$2"
  [[ "$line" =~ ^[[:space:]]*\<!--[[:space:]]core:porting-matrix:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]--\>[[:space:]]*$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

_markers() { # every marker in $TARGET as "kind id", ONE grammar shared with marker_id
  sed -nE 's/^[[:space:]]*<!--[[:space:]]core:porting-matrix:(gen|end)[[:space:]]([a-z0-9-]+)[[:space:]]-->[[:space:]]*$/\1 \2/p' "$TARGET"
}

render_for() { # $1 = id — the pre-rendered block, blank-line padded
  case "$1" in
  commands) printf '\n%s\n\n' "$CMD_TABLE" ;;
  packages) printf '\n%s\n\n' "$PKG_TABLE" ;;
  *) printf 'gen-porting-matrix: unknown block id: %s\n' "$1" >&2; return 2 ;;
  esac
}

build_file() { # build_file <file> — emit <file> with every marked block re-rendered
  local file="$1" line id found l2 endid inner
  while IFS= read -r line || [[ -n "$line" ]]; do
    if id="$(marker_id gen "$line")"; then
      printf '%s\n' "$line"
      render_for "$id" || return 2
      found=0
      while IFS= read -r l2; do
        if inner="$(marker_id gen "$l2")"; then
          printf "gen-porting-matrix: 'core:porting-matrix:gen %s' opens inside the '%s' region of %s — blocks cannot nest or cross\n" "$inner" "$id" "$file" >&2
          return 2
        fi
        if endid="$(marker_id end "$l2")"; then
          [[ "$endid" == "$id" ]] || {
            printf "gen-porting-matrix: marker mismatch in %s: 'gen %s' closed by 'end %s'\n" "$file" "$id" "$endid" >&2
            return 2
          }
          printf '%s\n' "$l2"
          found=1
          break
        fi
      done
      ((found == 1)) || {
        printf "gen-porting-matrix: unterminated 'core:porting-matrix:gen %s' region in %s\n" "$id" "$file" >&2
        return 2
      }
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
}

# ── preflight: every registered block has one marker pair; every marker is registered ──
preflight() {
  local rc=0 id n m kind line markers
  markers="$(_markers)"
  # Counts cannot see ORDER: gen A, gen B, end A, end B has one marker of each kind per
  # block. Replay the marker SEQUENCE (a handful of lines, not the document) with the
  # walker's rules so a crossed or nested pair is the structural 2 here — before the
  # fleet is resolved, where it would otherwise be filed under "no sibling to read" on a
  # lone checkout. The messages are the walker's, so both paths read the same.
  local open=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%% *}"
    id="${line#* }"
    if [[ "$kind" == gen ]]; then
      [[ -z "$open" ]] || { printf "gen-porting-matrix: 'core:porting-matrix:gen %s' opens inside the '%s' region of %s — blocks cannot nest or cross\n" "$id" "$open" "$TARGET" >&2; rc=2; open=""; break; }
      open="$id"
    elif [[ -n "$open" && "$id" != "$open" ]]; then
      printf "gen-porting-matrix: marker mismatch in %s: 'gen %s' closed by 'end %s'\n" "$TARGET" "$open" "$id" >&2; rc=2; open=""; break
    else
      open=""
    fi
  done <<EOF
$markers
EOF
  [[ -z "$open" ]] || { printf "gen-porting-matrix: unterminated 'core:porting-matrix:gen %s' region in %s\n" "$open" "$TARGET" >&2; rc=2; }
  for id in $BLOCK_IDS; do
    n="$(grep -c "^gen $id\$" <<<"$markers" || true)"
    m="$(grep -c "^end $id\$" <<<"$markers" || true)"
    case "$n" in
    1) ;;
    0) printf 'gen-porting-matrix: %s: registered block is missing: %s (was its region deleted?)\n' "$TARGET" "$id" >&2; rc=2 ;;
    *) printf 'gen-porting-matrix: %s: block appears %s times: %s (ambiguous)\n' "$TARGET" "$n" "$id" >&2; rc=2 ;;
    esac
    [[ "$m" == "$n" ]] || {
      printf 'gen-porting-matrix: %s: block %s has %s gen marker(s) but %s end marker(s) — every gen needs exactly one matching end\n' "$TARGET" "$id" "$n" "$m" >&2
      rc=2
    }
  done
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%% *}"
    id="${line#* }"
    [[ " $BLOCK_IDS " == *" $id "* ]] || {
      printf 'gen-porting-matrix: %s carries an unregistered %s marker: %s — add the block to BLOCK_IDS in scripts/gen-porting-matrix.sh, or remove the marker\n' "$TARGET" "$kind" "$id" >&2
      rc=2
    }
  done <<EOF
$markers
EOF
  return $rc
}

# ── driver ────────────────────────────────────────────────────────────────────
[[ -r "$TARGET" ]] || die "$TARGET is missing or unreadable"

# STRUCTURE BEFORE COVERAGE. The markers are this repo's own file, so a broken pair is
# answerable on a lone checkout and must be the structural 2 there — resolving the
# fleet first would file a deleted marker under "no sibling to read" (3), and
# audit-core.sh §9h would record a corrupted document as an environment skip.
preflight || exit 2

if ! resolve_fleet; then
  printf 'gen-porting-matrix: not checked out under %s:%s — nothing compared, nothing written (clone the fleet beside this repo, or pass --fleet DIR)\n' "$FLEET" "$MISSING" >&2
  exit 3
fi

read_caps
read_pkgs
CMD_TABLE="$(render_commands)" || exit 2
PKG_TABLE="$(render_packages)" || exit 2

if [[ "$MODE" == list ]]; then
  cat "$LISTFILE"
  exit 0
fi

rc=0
# The sentinel keeps the rendered stream BYTE-EXACT: `$(…)` strips every trailing
# newline, so a hand-authored blank line at the end of the document — outside both
# markers — would read as drift and be deleted on regeneration. build_file emits one
# newline per line, so what remains after `%x` is exactly what the walker printed.
if ! generated="$(build_file "$TARGET" && printf x)"; then
  exit 2
fi
generated="${generated%x}"
if [[ "$MODE" == check ]]; then
  # core_files_identical compares `git hash-object` outputs: with no git both sides are
  # empty and EQUAL, so a drifted table would read as clean. Fail closed instead.
  command -v git >/dev/null 2>&1 || die "git is not installed — the byte comparison and the drift report need it; the gate checked NOTHING"
  _tmp="$(mktemp "${TMPDIR:-/tmp}/gen-porting-matrix.XXXXXX")" || exit 2
  # CHECKED, because there is no `set -e`: an I/O error here must be 2, not drift (1).
  printf '%s' "$generated" >"$_tmp" || {
    printf 'gen-porting-matrix: could not write the comparison copy %s\n' "$_tmp" >&2
    rm -f "$_tmp"
    exit 2
  }
  if ! core_files_identical "$TARGET" "$_tmp"; then
    printf 'gen-porting-matrix: DRIFT in %s — a generated table no longer matches the OS repos:\n' "$TARGET" >&2
    git --no-pager diff --no-index --src-prefix=on-disk/ --dst-prefix=generated/ \
      -- "$TARGET" "$_tmp" 2>/dev/null | sed 's/^/  /' >&2 || true
    printf '  fix: run make gen-porting-matrix and commit the result.\n' >&2
    rc=1
  else
    printf 'gen-porting-matrix: every generated table in %s matches the OS repos\n' "$TARGET"
  fi
  rm -f "$_tmp"
else
  # ATOMIC: render to a sibling temp file and rename it over the target only once the
  # whole write succeeded. mktemp creates 0600; git stores 100644, so match that.
  _out="$(mktemp "${TARGET}.XXXXXX")" || {
    printf 'gen-porting-matrix: could not create a temp file beside %s\n' "$TARGET" >&2
    exit 2
  }
  if printf '%s' "$generated" >"$_out" && chmod 0644 "$_out" && mv "$_out" "$TARGET"; then
    printf 'gen-porting-matrix: regenerated %s\n' "$TARGET"
  else
    rm -f "$_out"
    printf 'gen-porting-matrix: could not write %s — left untouched\n' "$TARGET" >&2
    exit 2
  fi
fi
exit "$rc"
