#!/usr/bin/env bash
# scripts/gen-porting-matrix.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render PORTING-MATRIX.md's generated blocks: two data tables FROM the OS repos that own
# the data, plus one fleet-version enumeration per tool from this repo's own TSV. BLOCK_IDS
# is the registry and the count; no comment here states one, because the last one that did
# went stale the day a tool was added (#1082).
#
# THE DEFECT THIS CLOSES (#686). PORTING-MATRIX.md is ~1,570 lines. Its two data tables
# (~70 lines) restate data the OS repos already hold and already enforce: the
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
# WHAT IS GENERATED, AND WHAT DELIBERATELY IS NOT. Only the regions between marker
# pairs (the shape gen-aliases.sh uses) — see BLOCK_IDS below, which is the registry:
#
#     <!-- core:porting-matrix:gen packages -->
#     …a table rendered from the fleet…
#     <!-- core:porting-matrix:end packages -->
#
# Everything outside them — the recipe, the ~1,230 hand-written lines of numbered
# footnotes, the clipboard table, the quirks, the repo status — is hand-written judgment
# and is never touched. The footnotes are the reason the file exists;
# `/os-package-availability` is the routine that refreshes them, not this script.
#
# ONE EXCEPTION, and it is worth knowing: the fleet-version blocks sit INSIDE footnotes —
# 5 (tree-sitter-cli), 33 (neovim) and 34 (jq), each enumerating where the fleet sits against
# that tool's recorded floor. So those footnote regions are hand-written APART FROM their
# marker-delimited lines: the argument around them stays authored, the version facts inside
# them are rendered from scripts/fleet-package-versions.tsv. FV_TOOLS below says which block
# renders which tool — one block per tool, declared rather than derived from the id.
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
# more than one declaration (openSUSE Leap/Tumbleweed/Transactional — the MicroOS edition,
# dotfiles-openSUSE#191) renders each differing value, labelled, in registry order.
#
#   gen-porting-matrix.sh              # rewrite every marked region in PORTING-MATRIX.md
#   gen-porting-matrix.sh --check      # exit 1 (with a diff) if a region is stale — THE GATE
#   gen-porting-matrix.sh --list       # EVERY block's cells: block<TAB>row<TAB>column<TAB>derived|asserted<TAB>source
#                                      #   (every registered block — scripts/test/41 asserts
#                                      #    the coverage, not a sample of rows; #1096)
#   gen-porting-matrix.sh --root DIR   # run against another Core tree (test-core.sh's fixtures)
#   gen-porting-matrix.sh --fleet DIR  # where the sibling OS clones live (default: the parent
#                                      #   of the Core tree — inside a git worktree, pass this)
#   gen-porting-matrix.sh --local      # only the blocks whose inputs are IN THIS REPO
#   gen-porting-matrix.sh --check --local  #   …and gate them — needs no sibling clone
#   gen-porting-matrix.sh --list --local   #   …and list their provenance — likewise
#
# NEEDS THE SIBLING CLONES FOR TWO OF ITS BLOCKS — `commands` and `packages` — so unlike
# gen-aliases.sh it CAN
# be unable to answer: with a required repo not checked out it exits 3 and writes nothing.
# audit-core.sh §9h records that as an environment SKIP (the posture §9c and fleet-drift.sh
# take) — a lone CI checkout of this repo is not a gate failure, and --require-siblings is
# what reds it. Nothing is generated from a partial fleet: a table with one column stale
# reads as health.
#
# BUT THE FLEET-VERSION BLOCKS NEVER NEEDED THEM, and for a long time nobody checked them.
# They read scripts/fleet-package-versions.tsv, in this repo, and the
# whole of --check used to sit behind the fleet resolve — so on every CI leg and in every
# git worktree they went uncompared and §9h filed an environment skip over an input
# it was holding (#1046). --local is the scoped half: it selects LOCAL_BLOCKS, resolves no
# fleet, and passes every other region through exactly as found on disk. It is also a
# WRITE mode, deliberately, so the repair for the drift it reports can be run on the same
# box that reported it.
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
#       3 = uncovered — a required sibling repo is not checked out (named). NOT REACHABLE
#           under --local: every block it selects has its input in this repo, so
#           "uncovered" is not an answer that run can give. §9h classifies on that.
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
# The marker grammar, the block walker and the structural preflight, shared with every
# other region generator since #1129. The `--local` subset render below is the ONLY caller
# of the walker's pass-through-when-not-selected arm, so that behaviour is the library's
# and is pinned by scripts/test/43-gen-region.sh as well as by this script's own cases.
# shellcheck source=scripts/lib/gen-region.sh
source "$HERE/scripts/lib/gen-region.sh"
# `html` alone: the one target is a markdown document.
region_init porting-matrix gen-porting-matrix html "BLOCK_IDS in scripts/gen-porting-matrix.sh"

MODE=bare
LOCAL=0
ROOT=""
FLEET=""
while (($#)); do
  case "$1" in
  --check) MODE=check ;;
  --list) MODE=list ;;
  --local) LOCAL=1 ;;
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

# --list --local IS meaningful, now that every block writes provenance: it lists the
# in-repo blocks' cells and needs no sibling clone. It was a usage error only while
# fleet-versions contributed no rows, which would have made it an empty listing that
# exited 0 (#1096).

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
BLOCK_IDS="commands packages fleet-versions-tree-sitter-cli fleet-versions-neovim fleet-versions"

# WHICH BLOCKS ARE ANSWERABLE WITHOUT THE FLEET. A subset of BLOCK_IDS whose inputs are
# THIS repo's own files, so --check can compare them on a lone clone — which is every CI
# leg and every git worktree. DECLARED rather than inferred: a new block has to answer
# the locality question out loud, because getting it wrong in the quiet direction is what
# #1046 found. Deliberately NOT named *BLOCK_IDS: scripts/test/41-gen-matrix-parity.sh
# parses `^BLOCK_IDS=` out of this file, and a second name ending the same way is one
# unanchored regex away from being swept into that list.
LOCAL_BLOCKS="fleet-versions-tree-sitter-cli fleet-versions-neovim fleet-versions"

# WHICH TOOL EACH fleet-version BLOCK ENUMERATES. id<TAB>tool, one line each, in the doc's
# order. One block per tool and one tool per block: two blocks on one tool would print the
# same table into two footnotes and --check would then police a copy, which is the thing
# generation exists to remove.
#
# DECLARED, not derived from the id — the same rule, and the same reason, as LOCAL_BLOCKS
# above. `fleet-versions` is jq's and says so nowhere in its name: it predates the suffix,
# and renaming it would move bytes the gate compares for no gain (#1082). Deriving would
# also forbid any tool whose name is not a legal marker id, and that grammar is
# [a-z0-9-]+ while a tool name is whatever the distro calls it.
#
# THE TOOL IS NOT THE PACKAGE NAME. `tree-sitter-cli` is the tool; on openSUSE the package
# carrying it is `tree-sitter`, and on Homebrew `tree-sitter` is the lib-only formula
# (footnote 5). The table's header names the TOOL; each row's <source> in the TSV names
# where that row's value was actually read.
FV_TOOLS="fleet-versions-tree-sitter-cli	tree-sitter-cli
fleet-versions-neovim	neovim
fleet-versions	jq"

# The TSV both the renderer and preflight read. REGISTRY data, so it lives up here rather
# than beside the renderer: preflight validates FV_TOOLS against this file's `floor` lines,
# and preflight runs before anything else. $HERE is already final at this point (--root is
# applied above).
FLEET_VERSIONS="$HERE/scripts/fleet-package-versions.tsv"
# The same path, repo-relative, for --list's `source` field: the other two blocks name a
# sibling file as <repo>/install/packages.txt, so an absolute one here would be the only
# provenance a reader could not paste at a `git` command.
FV_REL="scripts/fleet-package-versions.tsv"

# The commands table. id<TAB>header<TAB>repo<TAB>declaration(s)<TAB>unit
#   declaration(s): space-separated `os/<os>.capabilities` paths, each optionally
#   `Label=path`; a column with more than one renders differing values as
#   `Label: `v` · Label: `v``, identical values once. Registry order is render order:
#   openSUSE lists the two zypper flavours first and the transactional edition (a
#   Tumbleweed base that stages through transactional-update) last.
#   unit: the word inside the install/remove placeholder — <pkg>, or <atom> on Gentoo.
CMD_COLUMNS="macos	macOS (brew)	dotfiles-MacBook	os/macos.capabilities	pkg
fedora	Fedora (dnf)	dotfiles-Fedora	Workstation=os/fedora.capabilities Atomic=os/fedora.atomic.capabilities	pkg
arch	Arch	dotfiles-Arch	os/arch.capabilities	pkg
opensuse	openSUSE	dotfiles-openSUSE	Leap=os/opensuse.leap.capabilities Tumbleweed=os/opensuse.capabilities Transactional=os/opensuse.microos.capabilities	pkg
alpine	Alpine	dotfiles-Alpine	os/alpine.capabilities	pkg
gentoo	Gentoo	dotfiles-Gentoo	os/gentoo.capabilities	atom
nixos	NixOS	dotfiles-NixOS	os/nixos.capabilities	pkg
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
            # disp is the FULLY RENDERED cell for this one declaration — code span,
            # placeholder and any tail. The collapse below compares THESE, not raw values:
            # a rendered dash and a rendered verb are not the same cell even when one of
            # them has no value to compare, and rebuilding the span from a raw value plus
            # whatever placeholder the LAST loop pass left behind (what this did before) is
            # wrong the moment a declaration renders something that is not a code span.
            disp = ""
            if (key in has) {
              v = val[key]
              if (v == "") { err(cid[c] (label != "" ? " (" label ")" : "") ": " akey[a] " is empty"); exit 2 }
              if (index(v, "`")) { err(cid[c] ": " akey[a] " contains a backtick, which cannot sit inside a code span"); exit 2 }
              disp = "`" esc(v (ph != "" ? " " ph : "")) "`"
            } else {
              # AN ABSENT KEY IS RENDERABLE ONLY WHERE THE VALIDATOR ACCEPTS ITS ABSENCE.
              # scripts/check-capabilities.sh relaxes PKG_COUNT_PENDING in exactly two
              # cases — under PROVISIONER=declarative, and under PROVISIONER=atomic when
              # PKG_APPLY_PENDING is declared beside it — so those are the only two cases
              # here. Anything else stays exit 2, which is what keeps this gate strict for
              # the eight mutable declarations: a Fedora file that lost PKG_SEARCH must
              # still fail, not render a dash into a green table.
              #
              # THE SECOND ARM IS PROVISIONER-GATED SINCE #1057. It read "whenever
              # PKG_APPLY_PENDING is declared", which would have rendered a dash for a
              # mutable host that declared a truthful reboot probe and dropped a count
              # verb it actually has.
              #
              # ONE RULE, TWO READERS. If that relaxation ever moves, both sides follow
              # from the same sentence rather than from a policy restated here.
              pk = cid[c] SUBSEP label SUBSEP "PROVISIONER"
              ak = cid[c] SUBSEP label SUBSEP "PKG_APPLY_PENDING"
              prov  = (pk in has) ? val[pk] : ""
              probe = (ak in has) ? val[ak] : ""
              relaxed = (prov == "declarative") || (prov == "atomic" && probe != "")
              if (akey[a] != "PKG_COUNT_PENDING" || !relaxed) {
                err(cid[c] (label != "" ? " (" label ")" : "") " declares no " akey[a] \
                    (akey[a] == "PKG_COUNT_PENDING" \
                       ? " and nothing that permits its absence — declare the verb, or, under PROVISIONER=atomic, PKG_APPLY_PENDING beside it (scripts/check-capabilities.sh)" \
                       : ""))
                exit 2
              }
              if (probe != "") {
                # A STAGED host CAN answer, just not this question. The count verb asks
                # how many packages are pending; PKG_APPLY_PENDING asks whether a change
                # is staged, which is what the nudge actually runs there. Render the verb
                # it does have and say which question it answers — the tail sits OUTSIDE
                # the span, because the span holds exactly what runs.
                if (index(probe, "`")) { err(cid[c] ": PKG_APPLY_PENDING contains a backtick, which cannot sit inside a code span"); exit 2 }
                disp = "`" esc(probe) "` (staged?)"
              } else {
                # A DECLARATIVE host cannot answer it at all: packages-pending is not a
                # thing it knows, and the nearest question needs root and lists
                # derivations rather than packages. A dash is the honest cell, and it is
                # the mark this file already uses for nothing-here in the package table.
                disp = "—"
              }
            }
            if (i == 1) first = disp; else if (disp != first) same = 0
            cell = cell (i > 1 ? " · " : "") (label != "" ? label ": " : "") disp
          }
          # Every declaration agrees: one cell, no labels.
          if (nf > 1 && same) cell = first
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

block_tool() { # $1 = block id -> the tool whose rows it renders; empty + rc 1 if unregistered
  local _bt
  _bt="$(awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' <<EOF
$FV_TOOLS
EOF
  )"
  [[ -n "$_bt" ]] || return 1
  printf '%s' "$_bt"
}

# ── the block walker ──────────────────────────────────────────────────────────
# Was marker_id and _markers here, copied from gen-aliases.sh, which copied them from
# gen-theme.sh. Since #1129 they are scripts/lib/gen-region.sh, parameterised by namespace
# and program name so this file's diagnostics still say `gen-porting-matrix:` and
# `core:porting-matrix:gen` without it owning a regex.

render_block() { # $1 = block id -> that block's markdown table on stdout
  #   LAZY, and dispatched from ONE place. The fleet-fed tables are still pre-rendered into
  #   CMD_TABLE/PKG_TABLE by the driver, because reading the fleet twice would be the
  #   expensive half; the fleet-version tables read one in-repo file and are cheap, so they
  #   render on demand and need no per-tool variable — which bash 3.2 could not key by id
  #   anyway (no associative arrays, PORTABILITY.md §1).
  #
  #   The `*` arm is the self-policing half that used to live only on the --local path: a
  #   block registered in BLOCK_IDS with nothing behind it is now a loud 2 on EVERY path,
  #   not a region that quietly compares clean against itself.
  local _tool
  case "$1" in
  (commands) printf '%s' "$CMD_TABLE" ;;
  (packages) printf '%s' "$PKG_TABLE" ;;
  (fleet-versions | fleet-versions-*)
    _tool="$(block_tool "$1")" || {
      printf 'gen-porting-matrix: %s renders a fleet-version table but names no tool in FV_TOOLS\n' "$1" >&2
      return 2
    }
    render_fleet_versions "$_tool" "$1" || return 2
    ;;
  (*)
    printf 'gen-porting-matrix: %s is registered in BLOCK_IDS but nothing renders it — name its tool in FV_TOOLS, or add an arm to render_block\n' "$1" >&2
    return 2
    ;;
  esac
}

# INVOKED BY NAME through the shared walker (region_build_file takes the renderer as a
# string, because bash 3.2 has no function references), so ShellCheck cannot see the call.
# BOTH CODES: 0.11.0 reports it as SC2329 on the function, 0.10.0 — the Alpine leg — as
# SC2317 on the body. Naming one passes locally and reds Alpine.
# shellcheck disable=SC2317,SC2329
render_for() { # $1 = id — the rendered block, blank-line padded; called via region_build_file
  local _body
  _body="$(render_block "$1")" || return 2
  printf '\n%s\n\n' "$_body"
}


# ── preflight: every registered block has one marker pair; every marker is registered ──
preflight() {
  local rc=0 id
  # STRUCTURE, from the shared library. Counts cannot see ORDER — `gen A, gen B, end A,
  # end B` has one marker of each kind per block — so region_preflight_file replays the
  # marker SEQUENCE with the walker's own rules, and does it BEFORE the fleet is resolved,
  # where a crossed pair would otherwise be filed under "no sibling to read" on a lone
  # checkout. It also covers the counts and the gen/end parity; the reverse direction (a
  # marker the registry does not know) is its own call so the remediation can name
  # BLOCK_IDS. Every message is the walker's, so both paths read the same.
  region_preflight_file "$TARGET" "$BLOCK_IDS" || rc=2
  region_unregistered_in_file "$TARGET" "$BLOCK_IDS" || rc=2

  # THE LOCALITY REGISTRY, checked here so a typo in it is a loud 2 and never a quiet
  # green. An EMPTY set matters most: `--check --local` over zero blocks is a gate that
  # cannot fail, which is the failure mode this whole seam exists to remove.
  [[ -n "$LOCAL_BLOCKS" ]] || {
    printf 'gen-porting-matrix: LOCAL_BLOCKS is empty — --local would compare nothing and report success\n' >&2
    rc=2
  }
  for id in $LOCAL_BLOCKS; do
    [[ " $BLOCK_IDS " == *" $id "* ]] || {
      printf 'gen-porting-matrix: LOCAL_BLOCKS names %s, which is not a registered block — add it to BLOCK_IDS or fix the typo\n' "$id" >&2
      rc=2
    }
  done

  # THE BLOCK -> TOOL MAP, checked the way LOCAL_BLOCKS just was: a registry is only worth
  # declaring if a typo in it is a loud 2 rather than a quiet green.
  local fv_ids="" fv_tools="" tool
  while IFS="$TAB" read -r id tool; do
    [[ -n "$id" ]] || continue
    [[ " $BLOCK_IDS " == *" $id "* ]] || {
      printf 'gen-porting-matrix: FV_TOOLS names %s, which is not a registered block — add it to BLOCK_IDS or fix the typo\n' "$id" >&2
      rc=2
    }
    [[ -n "$tool" ]] || {
      printf 'gen-porting-matrix: FV_TOOLS gives %s no tool\n' "$id" >&2
      rc=2
    }
    [[ " $fv_ids " == *" $id "* ]] && {
      printf 'gen-porting-matrix: FV_TOOLS maps %s twice\n' "$id" >&2
      rc=2
    }
    [[ " $fv_tools " == *" $tool "* ]] && {
      printf 'gen-porting-matrix: FV_TOOLS maps %s to two blocks — one tool would render the same table into two footnotes, and --check would then police a copy\n' "$tool" >&2
      rc=2
    }
    fv_ids="$fv_ids $id"
    fv_tools="$fv_tools $tool"
  done <<EOF
$FV_TOOLS
EOF

  # EVERY REGISTERED BLOCK HAS A RENDERER. `commands` and `packages` are render_block's
  # built-in arms; everything else has to come from FV_TOOLS, or its region is walked,
  # re-rendered from nothing, and compared clean against itself.
  for id in $BLOCK_IDS; do
    case "$id" in (commands | packages) continue ;; esac
    [[ " $fv_ids " == *" $id "* ]] || {
      printf 'gen-porting-matrix: %s is registered in BLOCK_IDS but nothing renders it — name its tool in FV_TOOLS\n' "$id" >&2
      rc=2
    }
  done

  # THE SET CHECK, BOTH DIRECTIONS — and this is the one that closes #1082's defect class
  # rather than only its instance. A tool with a floor and rows in the TSV that NO block
  # renders is data nobody can see: the enumeration it was recorded for stays the unchecked
  # prose the TSV exists to end, and nothing else in this repo would say so. The reverse — a
  # block whose tool has no floor — the renderer reports as "no floor recorded", which is
  # true but reads as a data gap when it is a registry one.
  if [[ -r "$FLEET_VERSIONS" ]]; then
    while IFS= read -r tool; do
      [[ -n "$tool" ]] || continue
      [[ " $fv_tools " == *" $tool "* ]] || {
        printf 'gen-porting-matrix: %s records a floor for %s, but no block renders it — add a block id and an FV_TOOLS entry (and its marker pair in %s), or drop the rows\n' "$FV_REL" "$tool" "$TARGET" >&2
        rc=2
      }
    done < <(awk -F"$TAB" '$1 == "floor" && $2 ~ /^[A-Za-z0-9._+-]+$/ { print $2 }' "$FLEET_VERSIONS")
    for tool in $fv_tools; do
      grep -q "^floor$TAB$tool$TAB" "$FLEET_VERSIONS" || {
        printf 'gen-porting-matrix: FV_TOOLS maps a block to %s, but %s records no floor for it — the status column is DERIVED against that floor and cannot be rendered without one\n' "$tool" "$FV_REL" >&2
        rc=2
      }
    done
  fi
  return $rc
}

# ── driver ────────────────────────────────────────────────────────────────────
[[ -r "$TARGET" ]] || die "$TARGET is missing or unreadable"

# STRUCTURE BEFORE COVERAGE. The markers are this repo's own file, so a broken pair is
# answerable on a lone checkout and must be the structural 2 there — resolving the
# fleet first would file a deleted marker under "no sibling to read" (3), and
# audit-core.sh §9h would record a corrupted document as an environment skip.
preflight || exit 2

# ── WHICH HALF OF THE DOCUMENT THIS RUN ANSWERS ──────────────────────────────
# --local selects only the blocks whose inputs are in THIS repo, so it neither resolves
# nor reads the fleet: 3 is unreachable by construction. Without it nothing has moved —
# the fleet resolves or the run is an uncovered 3, exactly as before.
if ((LOCAL)); then
  RENDER_BLOCKS="$LOCAL_BLOCKS"
else
  RENDER_BLOCKS="$BLOCK_IDS"
  if ! resolve_fleet; then
    printf 'gen-porting-matrix: not checked out under %s:%s — nothing compared, nothing written (clone the fleet beside this repo, or pass --fleet DIR)\n' "$FLEET" "$MISSING" >&2
    exit 3
  fi
  read_caps
  read_pkgs
fi
# ── fleet package versions (footnote enumerations) ────────────────────────────
# PORTING-MATRIX's floor footnotes used to enumerate a dozen distro versions in prose, and
# prose cannot be checked: footnote 34's jq line was corrected twice in one day, once for
# Alpine and once for Fedora, because nothing could contradict it. The enumeration now
# comes from scripts/fleet-package-versions.tsv and the REASONING stays hand-written
# beside it — facts generated, argument authored.
#
# at-or-below is DERIVED here rather than recorded, so a row cannot assert a status its own
# version contradicts. That was the actual defect both times: the version and the side of
# the line it was filed under disagreed, and only a human re-reading the sentence could
# notice.
FRESH_DAYS="${FRESH_DAYS:-90}"

# Field-wise numeric compare, the same shape used across the fleet's floor guards: a
# string compare ranks 1.10 below 1.9, and an -r suffix is truncated rather than parsed.
_fv_lt() { # <a> <b> — true when a sorts below b
  local i x y; local -a A B; local IFS=.
  # shellcheck disable=SC2206  # deliberate word-splitting on IFS=. — that IS the parse
  A=(${1%%-*})
  # shellcheck disable=SC2206
  B=(${2%%-*})
  unset IFS
  for ((i = 0; i < 4; i++)); do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 1 # equal is NOT below a >= floor
}

render_fleet_versions() { # <tool> <block-id> -> the markdown table for that block
  #   BOTH parameters, not one. The tool selects the rows and names the column; the block id
  #   is what --list files the provenance under, and it is a DIFFERENT string — the block
  #   called `fleet-versions` renders jq. Deriving either from the other is what kept this
  #   renderer jq-only (#1082), and hard-coding the id in the $LISTFILE lines below would
  #   have filed all three blocks' provenance under one id while every existing assertion
  #   still passed.
  local tool="$1" id="$2"
  [[ -n "$tool" && -n "$id" ]] || {
    printf 'gen-porting-matrix: render_fleet_versions needs <tool> <block-id>\n' >&2
    return 2
  }
  [[ -r "$FLEET_VERSIONS" ]] || {
    printf 'gen-porting-matrix: %s: cannot read %s\n' "$id" "$FLEET_VERSIONS" >&2
    return 2
  }
  local floor="" floor_line="" lno rt t target ver vdate status
  floor="$(awk -F'\t' -v tool="$tool" '$1 == "floor" && $2 == tool { print $3; exit }' "$FLEET_VERSIONS")"
  # The floor's own line, because the status cell is COMPUTED against it — provenance that
  # named only the version row would hide half of what decided the verdict.
  floor_line="$(awk -F'\t' -v tool="$tool" '$1 == "floor" && $2 == tool { print NR; exit }' "$FLEET_VERSIONS")"
  [[ -n "$floor" ]] || {
    printf 'gen-porting-matrix: %s: no floor recorded for %s in %s\n' "$id" "$tool" "$FLEET_VERSIONS" >&2
    return 2
  }

  # THROUGH _table, like the other two blocks — this is not cosmetic. The header of this
  # file states the rule: markdown here is emitted in prettier's ALIGNED form, because
  # conform runs prettierd on save, so an unpadded table is re-padded the next time anyone
  # opens the file and then reads as drift to --check. This renderer printed raw pipes and
  # was the one block in PORTING-MATRIX.md that was not a prettier fixed point (#836): a
  # save in Core's own nvim reformatted it and red §9h, and `make gen-porting-matrix` put it
  # back — a loop between two gates, each correct on its own terms.
  #
  # Rows are collected BEFORE the pipe rather than counted inside it: a `while` on the right
  # of a pipeline runs in a subshell on bash 3.2, so `rows` incremented there is lost and the
  # empty-input guard below would never fire.
  local rows=0 body=""
  while IFS=$'\t' read -r lno rt t target ver vdate _; do
    [[ "$rt" == "ver" && "$t" == "$tool" ]] || continue
    if _fv_lt "$ver" "$floor"; then status="**below**"; else status="at or above"; fi
    # PROVENANCE, unconditionally, exactly as the other two blocks do it. This block wrote
    # nothing to $LISTFILE while --help promised "every cell's provenance", so --list was
    # silent about a third of the document (#1096). Three cells per row: the version and
    # the date are RECORDED in the TSV, the floor comparison is COMPUTED from the version
    # against the floor row — so that cell names both lines it depends on.
    {
      printf '%s\t%s\tversion\tderived\t%s:%s\n' "$id" "$target" "$FV_REL" "$lno"
      printf '%s\t%s\tvs-floor\tderived\t%s:%s vs %s:%s\n' "$id" "$target" "$FV_REL" "$lno" "$FV_REL" "$floor_line"
      printf '%s\t%s\tverified\tderived\t%s:%s\n' "$id" "$target" "$FV_REL" "$lno"
    } >>"$LISTFILE"
    # A real TAB, via the $TAB the file already defines, and `%s` below: the first cut wrote
    # a literal `\t` and emitted with `%b`, which reinterprets escapes in the DATA too — a
    # backslash in any field would have been rewritten, and a `\c` would have truncated the
    # rest of the table without a word (#933). Version strings make that unlikely; the
    # class is removed anyway, for the same number of characters.
    body="$body$target$TAB$ver$TAB$status$TAB$vdate
"
    rows=$((rows + 1))
    # NR, not a counter over the filtered stream: --list's file:line has to point at the
    # line a reader opens, so comment and blank lines must still be counted. The `ver`
    # test in the loop body does the filtering the old grep did.
  done < <(awk '{ print NR "\t" $0 }' "$FLEET_VERSIONS")

  ((rows)) || {
    printf 'gen-porting-matrix: %s: no version rows for %s in %s\n' "$id" "$tool" "$FLEET_VERSIONS" >&2
    return 2
  }

  # shellcheck disable=SC2016  # the backticks are literal MARKDOWN code ticks, not a subshell
  { printf 'Target\t`%s`\tvs ≥ %s\tverified\n' "$tool" "$floor"
    printf '%s' "$body"; } | _table
}

# Staleness is REPORTED, never failed. This generator cannot see upstream, so an old row
# means "nobody has looked recently", not "this is wrong" — and failing CI on the calendar
# would red PRs that changed nothing. Printed to stderr so it surfaces in a run's output
# without becoming part of the generated file.
#
# The date arithmetic is done in awk, NOT with `date`. The first cut used
# `date -d "$today - $FRESH_DAYS days"` with a `date -v` fallback and `|| return 0`, which
# is GNU-or-BSD-only: busybox date accepts neither, so on Alpine — a first-class fleet
# target, and the very lane this footnote is about — the whole check silently did nothing
# and reported success. A staleness gate that goes quiet on one libc is worse than none,
# because its silence reads as "all fresh". Days-from-civil needs no date library at all.
warn_stale_versions() {
  [[ -r "$FLEET_VERSIONS" ]] || return 0
  local today
  today="$(date -u +%Y-%m-%d)" || {
    printf 'gen-porting-matrix: cannot read the current date — staleness NOT checked\n' >&2
    return 0
  }
  grep -v '^[[:space:]]*#' "$FLEET_VERSIONS" |
    awk -F'\t' -v today="$today" -v days="$FRESH_DAYS" '
      # days_from_civil (Howard Hinnant) — integer-only and calendar-correct
      # (leap years included). Portable everywhere awk is, which is the point.
      function dfc(y, m, d,   era, yoe, doy, doe) {
        y -= (m <= 2)
        era = int((y >= 0 ? y : y - 399) / 400)
        yoe = y - era * 400
        doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        return era * 146097 + doe - 719468
      }
      function dnum(s,   p) { split(s, p, "-"); return dfc(p[1] + 0, p[2] + 0, p[3] + 0) }
      BEGIN { cutoff = dnum(today) - days; n = 0 }
      $1 == "ver" && dnum($5) < cutoff {
        if (n++ == 0) printf "gen-porting-matrix: version rows not re-verified in %s days:\n", days
        printf "  %-24s %-8s last checked %s (%s)\n", $2 "/" $3, $4, $5, $6
      }
      END { if (n) print "  re-check the source in each row, then: make gen-porting-matrix" }
    ' >&2
}

# The two FLEET-fed tables are pre-rendered here because reading the fleet is the expensive
# half and build_file would otherwise reach for them mid-walk. The fleet-version tables read
# one in-repo file, so render_block builds them on demand — which is what lets the registry
# carry N tools without N variables a bash 3.2 script cannot key by id.
if ! ((LOCAL)); then
  CMD_TABLE="$(render_commands)" || exit 2
  PKG_TABLE="$(render_packages)" || exit 2
fi
warn_stale_versions # reads only the TSV, so it is right in both paths

if [[ "$MODE" == list ]]; then
  # --list never walks the document, so the renderers must be driven here: their $LISTFILE
  # writes ARE the listing. Output discarded — the provenance is the product. RENDER_BLOCKS
  # is already narrowed to LOCAL_BLOCKS under --local, so --list --local narrows for free.
  for _id in $RENDER_BLOCKS; do
    render_block "$_id" >/dev/null || exit 2
  done
  cat "$LISTFILE"
  exit 0
fi

rc=0
# The sentinel keeps the rendered stream BYTE-EXACT: `$(…)` strips every trailing
# newline, so a hand-authored blank line at the end of the document — outside both
# markers — would read as drift and be deleted on regeneration. build_file emits one
# newline per line, so what remains after `%x` is exactly what the walker printed.
if ! generated="$(region_build_file "$TARGET" render_for "$RENDER_BLOCKS" && printf x)"; then
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
    printf 'gen-porting-matrix: DRIFT in %s — a generated table no longer matches its source:\n' "$TARGET" >&2
    git --no-pager diff --no-index --src-prefix=on-disk/ --dst-prefix=generated/ \
      -- "$TARGET" "$_tmp" 2>/dev/null | sed 's/^/  /' >&2 || true
    printf '  fix: run make gen-porting-matrix and commit the result.\n' >&2
    rc=1
  else
    printf 'gen-porting-matrix: every selected table in %s matches its source (%s)\n' "$TARGET" "$RENDER_BLOCKS"
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
