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
# Severity is sticky, 3 > 2 > 1 > 0.
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
uv³⁰	uv python3-uv	=	\`python3-uv\`	=	=	asset²⁸	asset²⁸
w3m	-	=	=	=	=	=	="

# ── helpers ───────────────────────────────────────────────────────────────────
die() { printf 'gen-porting-matrix: %s\n' "$*" >&2; exit 2; }

field() { # field <n> <tab-separated line> — the n-th field
  awk -F'\t' -v n="$1" '{ print $n }' <<EOF
$2
EOF
}

# Escape a `|` for a GFM cell — honoured inside a code span, as gen-aliases.sh relies on.
esc() { printf '%s' "$1" | sed 's/|/\\|/g'; }

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
  local col header repo files unit spec label path dir
  while IFS="$TAB" read -r col header repo files unit; do
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

cmd_cell() { # cmd_cell <col> <key> <placeholder> — the rendered cell, or return 2
  local col="$1" key="$2" ph="$3" pairs label value out="" n=0 first="" same=1
  # value FIRST: a tab is IFS whitespace, so `read` would swallow an empty leading label.
  pairs="$(awk -F'\t' -v c="$col" -v k="$key" '$1 == c && $3 == k { print $4 "\t" $2 }' <<EOF
$CAPS
EOF
)"
  [[ -n "$pairs" ]] || { printf 'gen-porting-matrix: %s declares no %s\n' "$col" "$key" >&2; return 2; }
  while IFS="$TAB" read -r value label; do
    [[ -n "$value" ]] || { printf 'gen-porting-matrix: %s: %s is empty\n' "$col" "$key" >&2; return 2; }
    [[ "$value" != *'`'* ]] || { printf 'gen-porting-matrix: %s: %s contains a backtick, which cannot sit inside a code span\n' "$col" "$key" >&2; return 2; }
    n=$((n + 1))
    if ((n == 1)); then first="$value"; elif [[ "$value" != "$first" ]]; then same=0; fi
    [[ -z "$ph" ]] || value="$value $ph"
    if [[ -n "$label" ]]; then
      out="$out${out:+ · }$label: \`$(esc "$value")\`"
    else
      out="\`$(esc "$value")\`"
    fi
  done <<EOF
$pairs
EOF
  if ((n > 1 && same)); then
    # Every declaration agrees: one cell, no labels.
    [[ -z "$ph" ]] || first="$first $ph"
    out="\`$(esc "$first")\`"
  fi
  printf '%s' "$out"
}

render_commands() { # prints the aligned table
  local rows="" line col header repo files unit action key ph marks cell k spec first
  line="Action"
  while IFS="$TAB" read -r col header repo files unit; do
    [[ -n "$col" ]] || continue
    line="$line$TAB$(esc "$header")"
  done <<EOF
$CMD_COLUMNS
EOF
  rows="$line"
  while IFS="$TAB" read -r action key ph; do
    [[ -n "$action" ]] || continue
    line="$action"
    while IFS="$TAB" read -r col header repo files unit; do
      [[ -n "$col" ]] || continue
      k="$ph"
      [[ "$ph" == unit ]] && k="<$unit>"
      [[ "$ph" == - ]] && k=""
      cell="$(cmd_cell "$col" "$key" "$k")" || return 2
      first=""
      marks="$(awk -F'\t' -v k="$col/$action" '$1 == k { print $2 }' <<EOF
$CMD_MARKS
EOF
)"
      line="$line$TAB$cell$marks"
      # EVERY declaration behind the column, labels stripped: a two-file column's cell is
      # made of both, and a provenance line naming only the last would hide the other.
      printf 'commands\t%s\t%s\tderived\t%s\n' "$action" "$col" "$(for spec in $files; do printf '%s%s/%s' "${first:+ }" "$repo" "${spec#*=}"; first=1; done)" >>"$LISTFILE"
    done <<EOF
$CMD_COLUMNS
EOF
    rows="$rows
$line"
  done <<EOF
$CMD_ROWS
EOF
  _table <<EOF
$rows
EOF
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
  local col header repo tier dir file numbered filtered id
  while IFS="$TAB" read -r col header repo tier; do
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

# matches <col> <candidates> — the PKGS lines of <col> whose name or basename is a candidate
matches() {
  awk -F'\t' -v col="$1" -v cands="$2" '
    BEGIN { n = split(cands, c, " "); for (i = 1; i <= n; i++) want[c[i]] = 1 }
    $1 == col && (($3 in want) || ($4 in want))' <<EOF
$PKGS
EOF
}

render_packages() {
  local rows="" line header col repo tier label cands want spec cells i cell marks name hit nhit lineno floor file lbl id
  local cols=""
  line="Tool"
  while IFS="$TAB" read -r col header repo tier; do
    [[ -n "$col" ]] || continue
    line="$line$TAB$(esc "$header")"
    cols="$cols $col"
  done <<EOF
$PKG_COLUMNS
EOF
  rows="$line"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$(awk -F'\t' '{ print NF }' <<<"$line")" == 8 ]] || die "PKG_ROWS: a row does not have 8 fields: ${line%%"$TAB"*}"
    label="$(field 1 "$line")"
    cands="$(field 2 "$line")"
    [[ "$cands" != - ]] || cands="$(printf '%s' "$label" | sed 's/[^A-Za-z0-9._+-].*//')"
    lbl="$(printf '%s' "$label" | sed 's/[^A-Za-z0-9._+-].*//')"
    cells="$(esc "$label")"
    i=2
    for col in $cols; do
      i=$((i + 1))
      spec="$(field "$i" "$line")"
      repo="$(awk -F'\t' -v c="$col" '$1 == c { print $3 }' <<<"$PKG_COLUMNS")"
      file="$repo/install/packages.txt"
      if [[ "$spec" == =* ]]; then
        spec="${spec#=}"
        name="$(printf '%s' "$spec" | sed 's/[^A-Za-z0-9._+/-].*//')"
        marks="${spec#"$name"}"
        marks="${marks#"${marks%%[![:space:]]*}"}"
        # The override is THIS cell's: `want` is a copy, so `=go-yq` on Arch does not narrow
        # what the openSUSE cell to its right searches for.
        want="$cands"
        [[ -n "$name" ]] && want="$name"
        hit="$(matches "$col" "$want")"
        nhit="$(awk 'NF { n++ } END { print n + 0 }' <<<"$hit")"
        ((nhit > 0)) || {
          printf 'gen-porting-matrix: %s / %s: no line in %s installs it (candidates: %s) — change the cell to what the repo does, or restore the package\n' "$lbl" "$col" "$file" "$want" >&2
          return 2
        }
        # EVERY tier ID behind the column must see the same line with the same floor: one
        # cell cannot say two things, so a `skip:ubuntu` line under Debian/Ubuntu is a
        # refusal that names the split, not a shared-looking cell.
        tier="$(awk -F'\t' -v c="$col" '$1 == c { print $4 }' <<<"$PKG_COLUMNS")"
        for id in ${tier//,/ }; do
          case "$(awk -F'\t' -v i="$id" '$6 == i { n++ } END { print n + 0 }' <<<"$hit")" in
          1) ;;
          0) printf 'gen-porting-matrix: %s / %s: the %s tier does not install it but another tier of the same column does (%s) — one cell cannot render a split; tier it apart or footnote it\n' "$lbl" "$col" "$id" "$(awk -F'\t' '{ printf "%s%s:%s", (NR > 1 ? ", " : ""), $6, $3 }' <<<"$hit")" >&2; return 2 ;;
          *) printf 'gen-porting-matrix: %s / %s: several lines in %s match under %s (%s) — name one with =<name>\n' "$lbl" "$col" "$file" "$id" "$(awk -F'\t' -v i="$id" '$6 == i { printf "%s%s", (n++ ? ", " : ""), $3 }' <<<"$hit")" >&2; return 2 ;;
          esac
        done
        [[ "$(awk -F'\t' '{ print $2 "\t" $3 "\t" $5 }' <<<"$hit" | sort -u | awk 'END { print NR }')" == 1 ]] || {
          printf 'gen-porting-matrix: %s / %s: the tiers disagree on the line or its floor (%s) — one cell cannot render a split\n' "$lbl" "$col" "$(awk -F'\t' '{ printf "%s%s:%s%s", (NR > 1 ? ", " : ""), $6, $3, ($5 == "" ? "" : " min:" $5) }' <<<"$hit")" >&2
          return 2
        }
        hit="$(head -n 1 <<<"$hit")"
        lineno="$(field 2 "$hit")"; name="$(field 3 "$hit")"; floor="$(field 5 "$hit")"
        [[ "$name" != *'`'* ]] || { printf 'gen-porting-matrix: %s / %s: the package name contains a backtick\n' "$lbl" "$col" >&2; return 2; }
        cell="\`$(esc "$name")\`"
        [[ -z "$floor" ]] || cell="$cell ≥ $(esc "$floor")"
        cell="$cell$marks"
        printf 'packages\t%s\t%s\tderived\t%s:%s\n' "$lbl" "$col" "$file" "$lineno" >>"$LISTFILE"
      else
        hit="$(matches "$col" "$cands")"
        [[ -z "$hit" ]] || {
          printf 'gen-porting-matrix: %s / %s is asserted as "%s" but %s:%s now installs %s — change the cell to = (and re-check its footnote)\n' \
            "$lbl" "$col" "$spec" "$file" "$(field 2 "$(head -n 1 <<<"$hit")")" "$(field 3 "$(head -n 1 <<<"$hit")")" >&2
          return 2
        }
        cell="$(esc "$spec")"
        printf 'packages\t%s\t%s\tasserted\tscripts/gen-porting-matrix.sh PKG_ROWS\n' "$lbl" "$col" >>"$LISTFILE"
      fi
      cells="$cells$TAB$cell"
    done
    rows="$rows
$cells"
  done <<EOF
$PKG_ROWS
EOF
  _table <<EOF
$rows
EOF
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
if ! generated="$(build_file "$TARGET")"; then
  exit 2
fi
if [[ "$MODE" == check ]]; then
  _tmp="$(mktemp "${TMPDIR:-/tmp}/gen-porting-matrix.XXXXXX")" || exit 2
  # CHECKED, because there is no `set -e`: an I/O error here must be 2, not drift (1).
  printf '%s\n' "$generated" >"$_tmp" || {
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
  if printf '%s\n' "$generated" >"$_out" && chmod 0644 "$_out" && mv "$_out" "$TARGET"; then
    printf 'gen-porting-matrix: regenerated %s\n' "$TARGET"
  else
    rm -f "$_out"
    printf 'gen-porting-matrix: could not write %s — left untouched\n' "$TARGET" >&2
    exit 2
  fi
fi
exit "$rc"
