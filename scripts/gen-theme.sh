#!/usr/bin/env bash
# scripts/gen-theme.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render theme/palette.toml outward into every config that paints Core's chrome.
#
# THE DEFECT THIS CLOSES. Core is "themed in Tokyo Night", and until #679 that was
# a convention maintained by hand: ~90 hex literals across thirteen files in seven
# syntaxes, kept in step by COMMENTS — "kept in sync with starship.toml +
# tmux.conf @tn_*" appeared in six files and nothing checked any of them. A
# hand-edit to one file was a valid, lintable, shippable change that fanned a
# half-recoloured stack out to nine repos. nvim never had the problem: it holds
# zero hex literals and asks the plugin (nvim/lua/gerrrt/utils/palette.lua). This
# is that idea for everything else.
#
# HOW. A consumer opts a region in with a marker pair naming a block id, in its
# own comment syntax — which is `#` for all five host languages here (TOML, YAML,
# zsh, bash, tmux.conf), so unlike the prior art there is no second marker form:
#
#     # core:theme:gen fzf-colors
#     …rendered from theme/palette.toml…
#     # core:theme:end fzf-colors
#
# Anything OUTSIDE the markers is hand-authored and never touched. Leading
# indentation on the opening marker is captured and re-applied to every emitted
# line, which is what lets lazygit/config.yml's 4-space `theme:` block work.
#
#   gen-theme.sh              # rewrite every marked block from theme/palette.toml
#   gen-theme.sh --check      # exit 1 (with a diff) if any block is stale — THE GATE
#   gen-theme.sh --refresh    # re-resolve the palette from the PINNED tokyonight,
#                             #   rewrite theme/palette.toml, then regenerate
#   gen-theme.sh --refresh --check
#                             # re-resolve and REPORT, writing nothing — the weekly
#                             #   "has upstream restyled?" leg of `make check-pins`
#   gen-theme.sh --list       # id<TAB>file for every block (coverage, without grep)
#
# PORTED FROM dotfiles-Offense/offensive/companion/gen-views.sh, which does the
# same job for the htpx corpus and is drift-gated by companion.yml. Same
# build_file line-walker, same --check-diffs-and-fails, same sticky severity. One
# structural difference: gen-views renders a block from a FILE named by the id;
# here the source is one palette plus per-id emitter code, so the dispatch
# resolves an id to a FUNCTION.
#
# A LITERAL INSIDE A QUOTED STRING OR A CONTINUED COMMAND GETS HOISTED FIRST.
# Markers only ever wrap whole lines, because a `#` line inside
# `export FZF_DEFAULT_OPTS='…'` is not a comment — it is an argument fzf rejects.
# Two consumers needed this: zsh/35-fzf.zsh (the palette half split into its own
# append, so the layout options stay hand-authored) and tmux/scripts/tmux-cheat.sh
# (the --color comma-list hoisted to _CHEAT_FZF_COLORS).
#
# PURE BASH + AWK, NO python3/jq/yq. audit-core.sh §9d runs --check always-on with
# no `have` gate, so it must never be able to SKIP: a gate that skips itself on a
# bare box is the "green because absent" failure mode §8a and §8d exist to close.
# That also means bash 3.2 (macOS ships 2007's bash): no mapfile, no `declare -A`.
# The palette map is a flat PAL_<key> scalar namespace built with `printf -v`.
#
# Exit: 0 = clean; 1 = drift/findings; 2 = usage, or the generator cannot run.
# That is the gate convention this repo already uses (parity-check.sh:25,
# core-integrity.sh:55, nvim-reachability.sh:66) — NOT update-plugins.sh's
# 2-means-drift, which is a freshness reporter whose scheduled workflow keys on 2.
# Severity is sticky, 2 > 1 > 0: a structural failure in one target followed by
# mere drift in another must never exit as drift (the bug gen-views.sh records).
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Via the ALREADY-ABSOLUTE $HERE, not ${BASH_SOURCE[0]%/*}: we cd below, and
# BASH_SOURCE stays relative to the caller's original directory, so invoking this
# by a relative path from elsewhere would resolve the lib against the wrong base.
# The same note sits on check-modern.sh:23 and audit-core.sh:80.

# For core_files_identical — the cmp/diff BINARIES are forbidden in this repo (#572;
# see the helper's note in common.sh): that helper for equality and `git diff --no-index` for a
# human-readable diff. Both also drop a diffutils dependency the Alpine leg would
# otherwise need. Sourced via the ALREADY-ABSOLUTE $HERE, per the note above.
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

MODE=bare
REFRESH=0
ROOT=""
FLEET=""
while (($#)); do
  case "$1" in
  --check) MODE=check ;;
  # REFRESH is a separate axis from MODE, so `--refresh --check` composes: re-derive
  # the palette from the plugin, then REPORT what would change without writing. That
  # is the form `make check-pins` runs weekly.
  --refresh) REFRESH=1 ;;
  --list) MODE=list ;;
  --root)
    [[ -n "${2:-}" ]] || { printf 'gen-theme: --root needs a directory\n' >&2; exit 2; }
    ROOT="$2"; shift ;;
  --fleet)
    [[ -n "${2:-}" ]] || { printf 'gen-theme: --fleet needs a directory\n' >&2; exit 2; }
    FLEET="$2"; shift ;;
  -h | --help)
    # Self-documenting, like parity-check.sh:44 — print the header block above.
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0 ;;
  *)
    printf 'gen-theme: unexpected argument: %s (try --help)\n' "$1" >&2
    exit 2 ;;
  esac
  shift
done

# --root lets the behavioural suite drive this against a hermetic fixture tree.
# Without it the drift direction is untestable except by mutating tracked files —
# and the drift direction is the entire point of the gate. Same reason
# parity-check.sh:38 and core-integrity.sh take one.
[[ -n "$ROOT" ]] && HERE="$(cd -- "$ROOT" && pwd)"
cd "$HERE" || exit 2

# ── where the SIBLING repos live ──────────────────────────────────────────────
# Two consumers of this palette are not in Core and never will be: dotfiles-MacBook's
# sketchybar and dotfiles-Windows' zebar bar. Both hand-authored the same twelve Tokyo
# Night values, held in step by a comment reading "matched to core/starship + core/tmux"
# — the construction #693 and #682 exist to end, and #679's own note ("a comment is not a
# gate") was written about this very palette (#857).
#
# Defaults to Core's PARENT, the same convention gen-porting-matrix.sh and parity-check.sh
# use, so a normal fleet checkout needs no flag and the behavioural suite can point it at a
# fixture. Resolved AFTER the --root cd so a fixture root gets a fixture fleet.
[[ -n "$FLEET" ]] || FLEET="$(cd -- "$HERE/.." && pwd)"

PALETTE="theme/palette.toml"

# ── the palette ───────────────────────────────────────────────────────────────
# Parsed into PAL_<key> scalars with `printf -v` (the target name is DATA, so no
# eval) and read back through ${!ref}. bash 3.2 has no associative arrays, so a
# flat namespace IS the map.
#
# The awk is the load-bearing part. A naive `sub(/#.*/,"")` comment-strip would
# EAT THE HEX VALUE — every colour in this file starts with `#`. So: match a
# leading "…" first and only comment-strip a bare (integer) value. All POSIX awk,
# because the Alpine CI leg runs busybox.
_pal_load() {
  local k v
  # Process substitution, NOT a pipeline: a pipeline runs the loop in a subshell
  # and every printf -v is lost with it.
  while IFS="$(printf '\t')" read -r k v; do
    [[ -n "$k" ]] || continue
    case "$k" in
    [a-z]*) ;;
    *) printf 'gen-theme: bad key in %s: %s\n' "$PALETTE" "$k" >&2; return 2 ;;
    esac
    printf -v "PAL_$k" '%s' "$v"
  done < <(awk '
    /^[a-z][a-z0-9_]*[ \t]*=/ {
      k = $0; sub(/[ \t]*=.*/, "", k)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v)
      if (match(v, /^"[^"]*"/)) v = substr(v, RSTART + 1, RLENGTH - 2)
      else { sub(/[ \t]*#.*/, "", v); sub(/[ \t]+$/, "", v) }
      print k "\t" v
    }' "$PALETTE")
}

# Every key an emitter may ask for. Explicit, so a palette missing one fails ONCE
# here with a clear message instead of emitting an empty colour into thirteen
# files — `set -g @tn_blue ""`, fanned out to nine repos. This is also what makes
# `pal` below a TOTAL function: it can be called inside $( ) without a `return 1`
# being swallowed by the subshell.
PAL_REQUIRED="style role_accent role_muted role_ok role_err role_rule
fallback_accent_sgr fallback_muted_sgr fallback_accent_spec fallback_muted_spec
color_bg color_bg_dark color_bg_highlight color_bg_visual color_black color_blue
color_blue1 color_border_highlight color_comment color_cyan color_dark3 color_fg
color_fg_dark color_green color_magenta color_magenta2 color_orange color_red
color_red1 color_terminal_black color_yellow"

_pal_require() {
  local k ref v rc=0
  for k in $PAL_REQUIRED; do
    ref="PAL_$k"; v="${!ref-}"
    if [[ -z "$v" ]]; then
      printf 'gen-theme: %s: missing key: %s\n' "$PALETTE" "$k" >&2; rc=2; continue
    fi
    case "$k" in
    color_*)
      [[ "$v" =~ ^#[0-9a-f]{6}$ ]] ||
        { printf 'gen-theme: %s: %s is not a 6-digit lowercase hex: %s\n' "$PALETTE" "$k" "$v" >&2; rc=2; } ;;
    fallback_*)
      [[ "$v" =~ ^[0-9]{1,3}$ ]] ||
        { printf 'gen-theme: %s: %s is not a 256-colour index: %s\n' "$PALETTE" "$k" "$v" >&2; rc=2; } ;;
    role_*)
      ref="PAL_color_$v"
      [[ -n "${!ref-}" ]] ||
        { printf 'gen-theme: %s: %s names an undefined colour: %s\n' "$PALETTE" "$k" "$v" >&2; rc=2; } ;;
    esac
  done
  return $rc
}

pal() { local r="PAL_color_$1"; printf '%s' "${!r}"; }      # pal blue      -> #7aa2f7
pal_role() { local r="PAL_role_$1"; pal "${!r}"; }          # pal_role accent
pal_raw() { local r="PAL_$1"; printf '%s' "${!r}"; }        # pal_raw fallback_accent_sgr

# hex -> "R;G;B" decimal, for the 24-bit SGR sequences in 05-ui.zsh / ux.sh /
# tmux-cheat.sh. $((16#..)) rather than printf %d 0x.., which is ambiguous.
# The bare six hex digits, for forms that supply their own prefix. sketchybar wants
# 0xAARRGGBB — alpha FIRST — so the caller cannot simply prepend to `pal`'s output.
pal_hex() { local h; h="$(pal "$1")"; printf '%s' "${h#\#}"; }

_rgb() { local h="${1#\#}"; printf '%d;%d;%d' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))"; }

# ── what carries blocks ───────────────────────────────────────────────────────
# The registry: one `id<TAB>file` row per block. This is the single declaration of
# what exists — TARGETS is derived from it, --list prints it, and preflight checks
# it BOTH ways against the tree.
#
# A FILE THAT IS ABSENT IS SKIPPED, NOT A FAILURE. That is what lets test-core.sh
# drive this against a hermetic fixture holding one file per ENCODING rather than a
# copy of all fourteen consumers. In the real repo every file is present, so the
# "was this block deleted?" check below still has full force there — the case it
# guards is a marker pair removed from a file that still exists, which is exactly
# how a consumer would silently stop being covered.
# THREE COLUMNS AS OF #857: id, path, and the SIBLING REPO the path is relative to.
# An empty third column means Core's own tree, which is every row that predates #857 —
# so the added column costs those rows nothing and the resolver below reads one rule
# rather than two. A row naming a repo is resolved under --fleet.
BLOCKS="palette-colors	theme/palette.toml
tmux-palette	tmux/tmux.conf
battery-palette	tmux/scripts/tmux-battery.sh
netinfo-palette	tmux/scripts/tmux-netinfo.sh
cheat-sgr	tmux/scripts/tmux-cheat.sh
cheat-fzf-colors	tmux/scripts/tmux-cheat.sh
starship-palette	starship/starship.toml
starship-showcase-palette	examples/starship.showcase.toml
lazygit-theme	lazygit/config.yml
fzf-colors	zsh/35-fzf.zsh
zsyntax-styles	zsh/45-plugins.zsh
transient-prompt-chars	zsh/45-plugins.zsh
ui-accent-tiers	zsh/05-ui.zsh
pkgup-accent-tiers	zsh/60-update.zsh
sep-rule-colors	zsh/00-tools.zsh
ux-accent-tiers	lib/ux.sh
sketchybar-colors	sketchybar/colors.sh	dotfiles-MacBook
zebar-palette	desktop/zebar/vanilla-clear/styles.css	dotfiles-Windows"

# TARGETS carries RESOLVED paths — Core-relative rows unchanged, sibling rows prefixed
# with $FLEET/<repo>. MISSING_REPOS collects the siblings that are not checked out, which
# the driver reports as an environment SKIP rather than passing over in silence: a green
# `--check` that never opened a file is the failure this whole gate exists to prevent.
#
# MISSING_FILES is the OTHER way a sibling row can go unread, and it needs its own list
# because it is a different fact: the repo IS checked out but the registered file is not in
# it — the sibling has not landed the palette yet, the path moved (zebar's config paths are
# not stable), or someone deleted it. Until #933 only the directory was tested here, so that
# row fell to the render loop's partial-tree `continue` and --check exited 0 having inspected
# nothing: coverage loss reading as health, in the gate whose comment above says it exists
# to prevent exactly that. Core-relative rows keep the silent `continue` — a partial Core
# tree is the documented fixture case — but a sibling that is present and incomplete is
# reported by file, and exits 3 like an absent one.
TARGETS=""
MISSING_REPOS=""
MISSING_FILES=""
while IFS="$(printf '\t')" read -r _b_id _b_path _b_repo; do
  [[ -n "$_b_path" ]] || continue
  if [[ -z "${_b_repo:-}" ]]; then
    TARGETS="$TARGETS$_b_path
"
  elif [[ -f "$FLEET/$_b_repo/$_b_path" ]]; then
    TARGETS="$TARGETS$FLEET/$_b_repo/$_b_path
"
  elif [[ -d "$FLEET/$_b_repo" ]]; then
    MISSING_FILES="$MISSING_FILES $_b_repo/$_b_path "
  else
    case "$MISSING_REPOS" in
    *" $_b_repo "*) ;;
    *) MISSING_REPOS="$MISSING_REPOS $_b_repo " ;;
    esac
  fi
done <<EOF
$BLOCKS
EOF
TARGETS="$(printf '%s' "$TARGETS" | sort -u)"
MISSING_FILES="$(printf '%s' "$MISSING_FILES" | sed 's/^ *//; s/ *$//; s/  */ /g')"
unset _b_id _b_path _b_repo

# _block_path <path> <repo> — the ONE place a registry row becomes a filesystem path.
# Prints nothing when the row names a sibling that is not checked out, so every caller
# gets the same answer to "can I read this?" and none of them re-implements the rule.
_block_path() {
  local path="$1" repo="${2:-}"
  [[ -n "$repo" ]] || { printf '%s' "$path"; return 0; }
  [[ -d "$FLEET/$repo" ]] || return 0
  printf '%s' "$FLEET/$repo/$path"
}

# ── emitters: one function per block id ───────────────────────────────────────
# NOT a generic renderer over a spec table. The forms differ in quoting, in `=`
# alignment, in YAML list structure with a conditional "bold" element, in one
# fzf line carrying a `:regular` attribute, in comma-joining and in decimal-SGR
# derivation — a spec language expressive enough for all of that is harder to
# review than the printf it replaces, and bash 3.2's lack of associative arrays
# would make the table parallel arrays anyway. Each emitter is a literal picture
# of its target block, so a reviewer diffs the two side by side. Straight-line
# printf, no loops: a loop needs either a pipeline (subshell) or a variable
# format string (SC2059).
#
# $1 is always the opening marker's indentation, re-applied to every line.

# theme/palette.toml itself — rewritten by --refresh. Keeping the palette's own
# table inside a block is what lets --refresh preserve every hand-authored line
# around it (the role_* map, the 256-colour fallbacks, all the prose).
emit_palette_colors() {
  local i="$1" k
  for k in bg bg_dark bg_highlight bg_visual black blue blue1 border_highlight \
    comment cyan dark3 fg fg_dark green magenta magenta2 orange red red1 \
    terminal_black yellow; do
    printf '%scolor_%-17s = "%s"\n' "$i" "$k" "$(pal "$k")"
  done
}

# tmux/tmux.conf — user options the status-bar rules then read as #{@tn_blue}.
# tmux.conf already had this indirection; only the values were hand-copied.
emit_tmux_palette() {
  local i="$1"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_bg' "$(pal bg)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_bg_dark' "$(pal bg_dark)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_bg_hl' "$(pal bg_highlight)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_fg' "$(pal fg)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_fg_dim' "$(pal fg_dark)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_blue' "$(pal blue)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_cyan' "$(pal cyan)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_green' "$(pal green)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_magenta' "$(pal magenta)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_red' "$(pal red)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_yellow' "$(pal yellow)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_orange' "$(pal orange)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_comment' "$(pal comment)"
  printf '%sset -g %-11s "%s"\n' "$i" '@tn_black' "$(pal terminal_black)"
}

emit_battery_palette() {
  local i="$1"
  printf '%sBGDA="%s"\n' "$i" "$(pal bg_dark)"
  printf '%sGREEN="%s"\n' "$i" "$(pal green)"
  printf '%sYELLOW="%s"\n' "$i" "$(pal yellow)"
  printf '%sRED="%s"\n' "$i" "$(pal red)"
}

emit_netinfo_palette() {
  local i="$1"
  printf '%sORANGE="%s"\n' "$i" "$(pal orange)"
  printf '%sGREEN="%s"\n' "$i" "$(pal green)"
  printf '%sBGDA="%s"\n' "$i" "$(pal bg_dark)"
}

# tmux-cheat.sh's group/description colours, as 24-bit SGR rather than hex — the
# same accent lib/ux.sh and 05-ui.zsh carry, derived from the one palette entry.
emit_cheat_sgr() {
  local i="$1" l
  printf -v l "GC=\$'\\\\033[38;2;%sm'" "$(_rgb "$(pal_role accent)")"
  printf '%s%-28s # tokyonight blue (group)\n' "$i" "$l"
  printf -v l "DIM=\$'\\\\033[38;2;%sm'" "$(_rgb "$(pal_role muted)")"
  printf '%s%-28s # comment (description)\n' "$i" "$l"
}

# HOISTED out of the fzf continuation line at the call site: a marker cannot sit
# mid-command, so the comma-list became its own assignment.
emit_cheat_fzf_colors() {
  printf "%s_CHEAT_FZF_COLORS='border:%s,prompt:%s,header:%s'\n" \
    "$1" "$(pal blue)" "$(pal cyan)" "$(pal comment)"
}

# starship/starship.toml — single quotes, and the accents group aligns its
# trailing comments to a fixed column (a hex is always 7 chars, so the column is
# stable under any palette). The surfaces group uses one space, as authored.
emit_starship_palette() {
  local i="$1" l
  printf '%s# ── accents — now used as TEXT, not as fills ──────────────────────────────────\n' "$i"
  printf -v l "color_fg0 = '%s'" "$(pal fg)"
  printf '%s%-25s # fg (brightest text)\n' "$i" "$l"
  printf -v l "color_fg_dark = '%s'" "$(pal fg_dark)"
  printf '%s%-25s # softer text (quiet segments)\n' "$i" "$l"
  printf "%scolor_blue = '%s'\n" "$i" "$(pal blue)"
  printf -v l "color_aqua = '%s'" "$(pal cyan)"
  printf '%s%-25s # cyan\n' "$i" "$l"
  printf "%scolor_green = '%s'\n" "$i" "$(pal green)"
  printf "%scolor_orange = '%s'\n" "$i" "$(pal orange)"
  printf -v l "color_purple = '%s'" "$(pal magenta)"
  printf '%s%-25s # magenta\n' "$i" "$l"
  printf "%scolor_red = '%s'\n" "$i" "$(pal red)"
  printf "%scolor_yellow = '%s'\n" "$i" "$(pal yellow)"
  printf -v l "color_comment = '%s'" "$(pal comment)"
  printf '%s%-25s # muted / de-emphasized\n' "$i" "$l"
  printf '%s# ── surfaces — the two dark segment fills (subtle stepped depth) ──────────────\n' "$i"
  printf "%scolor_srf1 = '%s' # storm bg, slightly raised above the terminal\n" "$i" "$(pal bg)"
  printf "%scolor_srf2 = '%s' # bg_dark, a touch deeper\n" "$i" "$(pal bg_dark)"
}

# The README showcase carries the same values in a DIFFERENT house style (no
# spaces around =, no trailing comments) and no fg_dark. A separate emitter, not
# a shared one — the whole point of the showcase is that it reads differently.
emit_starship_showcase_palette() {
  local i="$1"
  printf "%scolor_fg0='%s'\n" "$i" "$(pal fg)"
  printf "%scolor_blue='%s'\n" "$i" "$(pal blue)"
  printf "%scolor_aqua='%s'\n" "$i" "$(pal cyan)"
  printf "%scolor_green='%s'\n" "$i" "$(pal green)"
  printf "%scolor_orange='%s'\n" "$i" "$(pal orange)"
  printf "%scolor_purple='%s'\n" "$i" "$(pal magenta)"
  printf "%scolor_red='%s'\n" "$i" "$(pal red)"
  printf "%scolor_yellow='%s'\n" "$i" "$(pal yellow)"
  printf "%scolor_comment='%s'\n" "$i" "$(pal comment)"
  printf "%scolor_srf1='%s'\n" "$i" "$(pal bg)"
  printf "%scolor_srf2='%s'\n" "$i" "$(pal bg_dark)"
}

# lazygit/config.yml — QUOTING IS MANDATORY: a bare # opens a YAML comment, so an
# unquoted colour silently becomes an empty value. Indent-aware, because this
# block sits inside gui.theme rather than at column 0.
_lg() { printf '%s%s:\n%s  - "%s"\n' "$3" "$1" "$3" "$2"; }
_lg_bold() { _lg "$1" "$2" "$3"; printf '%s  - "bold"\n' "$3"; }
emit_lazygit_theme() {
  local i="$1"
  _lg_bold activeBorderColor "$(pal orange)" "$i"
  _lg inactiveBorderColor "$(pal border_highlight)" "$i"
  _lg_bold searchingActiveBorderColor "$(pal orange)" "$i"
  _lg optionsTextColor "$(pal blue)" "$i"
  _lg selectedLineBgColor "$(pal bg_visual)" "$i"
  _lg cherryPickedCommitFgColor "$(pal blue)" "$i"
  _lg cherryPickedCommitBgColor "$(pal magenta)" "$i"
  _lg markedBaseCommitFgColor "$(pal blue)" "$i"
  _lg markedBaseCommitBgColor "$(pal yellow)" "$i"
  _lg unstagedChangesColor "$(pal red1)" "$i"
  _lg defaultFgColor "$(pal fg)" "$i"
}

# zsh/35-fzf.zsh — appended to FZF_DEFAULT_OPTS rather than embedded in it,
# because a marker inside that single-quoted string is an ARGUMENT, not a
# comment, and fzf rejects it. Splitting the assignment also keeps the layout
# options (--height, --prompt, …) hand-authored, where they belong.
#
# --color=query:<fg>:regular IS LOAD-BEARING FOR A CROSS-REPO GATE.
# scripts/parity-check.sh greps that exact token in this file AND in
# dotfiles-Windows' 10-tools.ps1. Reformatting this block — one-per-line to a
# single line, reordering, dropping :regular — breaks the needle even with an
# identical palette. Keep the token contiguous.
# shellcheck disable=SC2016  # the $VARs below are emitted LITERALLY into the
# target file, which is the point — they must not expand here.
emit_fzf_colors() {
  local i="$1"
  printf '%sFZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS\n' "$i"
  printf '%s  --color=border:%s\n' "$i" "$(pal border_highlight)"
  printf '%s  --color=fg:%s\n' "$i" "$(pal fg)"
  printf '%s  --color=gutter:%s\n' "$i" "$(pal black)"
  printf '%s  --color=header:%s\n' "$i" "$(pal orange)"
  printf '%s  --color=hl:%s\n' "$i" "$(pal blue1)"
  printf '%s  --color=hl+:%s\n' "$i" "$(pal blue1)"
  printf '%s  --color=info:%s\n' "$i" "$(pal dark3)"
  printf '%s  --color=marker:%s\n' "$i" "$(pal magenta2)"
  printf '%s  --color=pointer:%s\n' "$i" "$(pal magenta2)"
  printf '%s  --color=prompt:%s\n' "$i" "$(pal blue1)"
  printf '%s  --color=query:%s:regular\n' "$i" "$(pal fg)"
  printf '%s  --color=scrollbar:%s\n' "$i" "$(pal border_highlight)"
  printf '%s  --color=separator:%s\n' "$i" "$(pal orange)"
  printf '%s  --color=spinner:%s"\n' "$i" "$(pal magenta2)"
}

emit_zsyntax_styles() {
  local i="$1" l
  printf -v l "ZSH_HIGHLIGHT_STYLES[command]='fg=%s'" "$(pal_role ok)"
  printf '%s%-55s # green  — valid command\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[builtin]='fg=%s'" "$(pal_role ok)"
  printf '%s%-55s # green\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[function]='fg=%s'" "$(pal_role ok)"
  printf '%s%-55s # green\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[alias]='fg=%s'" "$(pal_role ok)"
  printf '%s%-55s # green\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=%s'" "$(pal_role err)"
  printf '%s%-55s # red    — bad command/syntax\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[path]='fg=%s'" "$(pal_role accent)"
  printf '%s%-55s # blue   — existing path\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=%s'" "$(pal yellow)"
  printf '%s%-55s # yellow\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=%s'" "$(pal yellow)"
  printf '%s%-55s # yellow\n' "$i" "$l"
  printf -v l "ZSH_HIGHLIGHT_STYLES[comment]='fg=%s'" "$(pal_role muted)"
  printf '%s%-55s # muted comment\n' "$i" "$l"
}

# shellcheck disable=SC2016  # the $VARs below are emitted LITERALLY into the
# target file, which is the point — they must not expand here.
emit_transient_prompt_chars() {
  printf '%stypeset -g TRANSIENT_PROMPT_TRANSIENT_PROMPT="${_CORE_OSC133_MARK:-}"%s%%(?.%%F{%s}.%%F{%s})❖%%f %s\n' \
    "$1" "'" "$(pal_role ok)" "$(pal_role err)" "'"
}

# zsh/05-ui.zsh — the truecolor arm DERIVES its SGR from the hex; the 256-colour
# arm reads the hand-picked fallbacks verbatim. The whole if/else is the block so
# the markers land on comment-legal lines outside the control flow.
# shellcheck disable=SC2016  # the $VARs below are emitted LITERALLY into the
# target file, which is the point — they must not expand here.
emit_ui_accent_tiers() {
  local i="$1"
  printf '%sif [[ "${COLORTERM:-}" == (24bit|truecolor) ]]; then\n' "$i"
  printf "%s  typeset -g _CORE_C_ACCENT=\$'\\\\e[1;38;2;%sm' _CORE_C_MUTED=\$'\\\\e[38;2;%sm'\n" \
    "$i" "$(_rgb "$(pal_role accent)")" "$(_rgb "$(pal_role muted)")"
  printf "%s  typeset -g _CORE_ACCENT_SPEC='%s' _CORE_MUTED_SPEC='%s'\n" \
    "$i" "$(pal_role accent)" "$(pal_role muted)"
  printf '%selse\n' "$i"
  printf "%s  typeset -g _CORE_C_ACCENT=\$'\\\\e[1;38;5;%sm' _CORE_C_MUTED=\$'\\\\e[38;5;%sm'\n" \
    "$i" "$(pal_raw fallback_accent_sgr)" "$(pal_raw fallback_muted_sgr)"
  printf '%s  typeset -g _CORE_ACCENT_SPEC=%s _CORE_MUTED_SPEC=%s\n' \
    "$i" "$(pal_raw fallback_accent_spec)" "$(pal_raw fallback_muted_spec)"
  printf '%sfi\n' "$i"
}

# lib/ux.sh — the same two tiers for the BASH layer (bootstrap.sh runs before any
# zsh module exists), as a case rather than an if.
# shellcheck disable=SC2016  # the $VARs below are emitted LITERALLY into the
# target file, which is the point — they must not expand here.
emit_ux_accent_tiers() {
  local i="$1"
  printf '%scase "${COLORTERM:-}" in\n' "$i"
  printf "%s24bit | truecolor) UX_ACCENT=\$'\\\\e[1;38;2;%sm' UX_MUTED=\$'\\\\e[38;2;%sm' ;;\n" \
    "$i" "$(_rgb "$(pal_role accent)")" "$(_rgb "$(pal_role muted)")"
  printf "%s*) UX_ACCENT=\$'\\\\e[1;38;5;%sm' UX_MUTED=\$'\\\\e[38;5;%sm' ;;\n" \
    "$i" "$(pal_raw fallback_accent_sgr)" "$(pal_raw fallback_muted_sgr)"
  printf '%sesac\n' "$i"
}

# zsh/60-update.zsh — prefers 05-ui.zsh's canonical specs; the other two arms are
# a standalone fallback for the unit tests, which source this module alone.
# shellcheck disable=SC2016  # the $VARs below are emitted LITERALLY into the
# target file, which is the point — they must not expand here.
emit_pkgup_accent_tiers() {
  local i="$1"
  printf '%sif [[ -n ${_CORE_ACCENT_SPEC:-} ]]; then\n' "$i"
  printf '%s  typeset -g _PKGUP_ACCENT=$_CORE_ACCENT_SPEC _PKGUP_MUTED=$_CORE_MUTED_SPEC\n' "$i"
  printf '%selif [[ "${COLORTERM:-}" == (24bit|truecolor) ]]; then\n' "$i"
  printf "%s  typeset -g _PKGUP_ACCENT='%s' _PKGUP_MUTED='%s'\n" \
    "$i" "$(pal_role accent)" "$(pal_role muted)"
  printf '%selse\n' "$i"
  printf '%s  typeset -g _PKGUP_ACCENT=%s _PKGUP_MUTED=%s\n' \
    "$i" "$(pal_raw fallback_accent_spec)" "$(pal_raw fallback_muted_spec)"
  printf '%sfi\n' "$i"
}

# zsh/00-tools.zsh — the separator rule above each prompt, coloured by exit status.
emit_sep_rule_colors() {
  printf "%sif (( ec == 0 )); then col='%%F{%s}'; else col='%%F{%s}'; fi\n" \
    "$1" "$(pal_role rule)" "$(pal_role err)"
}

# ── dotfiles-MacBook :: sketchybar/colors.sh ──────────────────────────────────
# 0xAARRGGBB, alpha FIRST — sketchybar's own format, not a variant of anything Core
# already emits. The alpha is PER ENTRY rather than a constant: the bar background is
# deliberately translucent (0xee, ~93%) over the storm black.
#
# TRANSPARENT (0x00000000) is NOT emitted and must stay outside the markers: it is not a
# palette colour, it is the absence of one, and there is no token in palette.toml it could
# be derived from. A generator inventing one would be asserting a colour nobody chose.
#
# Bare assignments, no trailing comments, deliberately. The hand-written file aligned its
# comment column in contiguous groups — which is what shfmt does — and a generator
# reproducing shfmt's alignment by hand is a fight waiting to happen the first time a
# token's name changes length. The prose moves above the block, where it is not generated.
emit_sketchybar_colors() {
  local i="$1"
  printf '%sexport BAR_COLOR=0xee%s\n' "$i" "$(pal_hex black)"
  printf '%sexport BG=0xff%s\n' "$i" "$(pal_hex bg)"
  printf '%sexport FG=0xff%s\n' "$i" "$(pal_hex fg)"
  printf '%sexport ACCENT=0xff%s\n' "$i" "$(pal_hex blue)"
  printf '%sexport GREEN=0xff%s\n' "$i" "$(pal_hex green)"
  printf '%sexport YELLOW=0xff%s\n' "$i" "$(pal_hex yellow)"
  printf '%sexport RED=0xff%s\n' "$i" "$(pal_hex red)"
  printf '%sexport MAGENTA=0xff%s\n' "$i" "$(pal_hex magenta)"
  printf '%sexport CYAN=0xff%s\n' "$i" "$(pal_hex cyan)"
  printf '%sexport ORANGE=0xff%s\n' "$i" "$(pal_hex orange)"
  printf '%sexport GREY=0xff%s\n' "$i" "$(pal_hex comment)"
}

# ── dotfiles-Windows :: desktop/zebar/vanilla-clear/styles.css ────────────────
# Plain #rrggbb CSS custom properties. The `--tn-` prefix and the property names are the
# BAR'S OWN vocabulary, not Core's, so they are spelled here rather than derived: each
# emitter is a literal picture of the block it renders, which is the rule the emitter header
# above states for all of them.
#
# The last hand-authored copy of Core's palette (#857/#926). sketchybar's was generated
# first; this one had to wait for the marker grammar to learn a second comment syntax,
# because `#` in CSS is an id selector and not a comment at all.
emit_zebar_palette() {
  local i="$1"
  printf '%s--tn-bg: %s;\n' "$i" "$(pal bg)"
  printf '%s--tn-fg: %s;\n' "$i" "$(pal fg)"
  printf '%s--tn-fg-dim: %s;\n' "$i" "$(pal fg_dark)"
  printf '%s--tn-blue: %s;\n' "$i" "$(pal blue)"
  printf '%s--tn-comment: %s;\n' "$i" "$(pal comment)"
  printf '%s--tn-red: %s;\n' "$i" "$(pal red)"
  printf '%s--tn-green: %s;\n' "$i" "$(pal green)"
  printf '%s--tn-yellow: %s;\n' "$i" "$(pal yellow)"
  printf '%s--tn-cyan: %s;\n' "$i" "$(pal cyan)"
  printf '%s--tn-purple: %s;\n' "$i" "$(pal magenta)"
  printf '%s--tn-orange: %s;\n' "$i" "$(pal orange)"
}

render_for() { # $1 = id, $2 = indent
  case "$1" in
  palette-colors) emit_palette_colors "$2" ;;
  tmux-palette) emit_tmux_palette "$2" ;;
  battery-palette) emit_battery_palette "$2" ;;
  netinfo-palette) emit_netinfo_palette "$2" ;;
  cheat-sgr) emit_cheat_sgr "$2" ;;
  cheat-fzf-colors) emit_cheat_fzf_colors "$2" ;;
  starship-palette) emit_starship_palette "$2" ;;
  starship-showcase-palette) emit_starship_showcase_palette "$2" ;;
  lazygit-theme) emit_lazygit_theme "$2" ;;
  fzf-colors) emit_fzf_colors "$2" ;;
  zsyntax-styles) emit_zsyntax_styles "$2" ;;
  transient-prompt-chars) emit_transient_prompt_chars "$2" ;;
  ui-accent-tiers) emit_ui_accent_tiers "$2" ;;
  ux-accent-tiers) emit_ux_accent_tiers "$2" ;;
  sketchybar-colors) emit_sketchybar_colors "$2" ;;
  zebar-palette) emit_zebar_palette "$2" ;;
  pkgup-accent-tiers) emit_pkgup_accent_tiers "$2" ;;
  sep-rule-colors) emit_sep_rule_colors "$2" ;;
  *) printf 'gen-theme: unknown block id: %s\n' "$1" >&2; return 2 ;;
  esac
}

# ── the block walker ──────────────────────────────────────────────────────────
# marker_id is PURE — it prints the id and nothing else. It is called through
# $( ), which is a subshell, so anything it assigned would be discarded the
# moment it returned. The indentation therefore comes from a separate expansion
# in the caller's own frame (marker_indent), NOT from a side effect here. That is
# the same subshell trap _pal_load avoids by reading from a process substitution
# instead of a pipeline; getting it wrong here silently flattened every emitted
# line to column 0, which only lazygit/config.yml's nested block would have shown.
# TWO COMMENT SYNTAXES, because a marker has to be a comment in ITS OWN file's language and
# `#` is not one everywhere (#926). Every consumer up to now happened to be `#`-commented —
# toml, yml, zsh, sh, conf — so the grammar was written for `#` and that looked like a
# property of the tool rather than an accident of which files had blocks. CSS has no `#`
# comment at all (`#` there begins an id selector), so dotfiles-Windows' zebar palette could
# not carry a marker in any form and stayed the last hand-authored copy of Core's colours.
#
# THE STYLE IS NOT REGISTERED ANYWHERE, and that is the whole shape of this change.
# build_file echoes both markers VERBATIM — it never writes them — so the generator never
# needs to know which syntax a file uses. Only the MATCHERS do, and they can simply accept
# either. A fourth registry column (the first design) would have been a fact stored in two
# places, and the copy in the file is the one that decides.
# The ERE the three greps below share. Defined once because it was restated in three places
# and a fourth syntax would have had to find all of them — which is exactly how the `#`-only
# assumption survived unnoticed until a CSS file needed a block (#926). `marker_id` above
# stays a pair of explicit [[ =~ ]] arms rather than reusing this: it must CAPTURE the id and
# reject an unterminated `/*`, neither of which a shared presence-test pattern should carry.
MARKER_RE='^[[:space:]]*(#|/\*)[[:space:]]core:theme:gen[[:space:]]'

marker_id() { # $1 = gen|end, $2 = line; prints the id, or returns 1
  local kind="$1" line="$2"
  # `#`-comment form: toml, yml, zsh, sh, conf.
  if [[ "$line" =~ ^[[:space:]]*#[[:space:]]core:theme:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  # `/* … */` form: CSS. The closing delimiter is REQUIRED, not optional — a line opening a
  # comment it does not close would swallow the generated block into it, and the file would
  # still parse while rendering nothing.
  if [[ "$line" =~ ^[[:space:]]*/\*[[:space:]]core:theme:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]*\*/[[:space:]]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# The opening marker's leading whitespace, re-applied to every emitted line. This
# is what lets lazygit/config.yml carry a block inside its 4-space gui.theme map;
# everywhere else it is the empty string.
# Unchanged by #926: it takes the leading run of spaces, which is the same question
# whatever the comment delimiter that follows is.
marker_indent() { # $1 = line
  local line="$1"
  printf '%s' "${line%%[! ]*}"
}

# build_file <file> — emit <file> with every marked block re-rendered.
build_file() {
  local file="$1" line id indent found l2 endid
  while IFS= read -r line || [[ -n "$line" ]]; do
    if id="$(marker_id gen "$line")"; then
      indent="$(marker_indent "$line")"
      printf '%s\n' "$line" # the opening marker, verbatim
      render_for "$id" "$indent" || return 2
      # consume the stale block up to and including its end marker
      found=0
      while IFS= read -r l2; do
        if endid="$(marker_id end "$l2")"; then
          [[ "$endid" == "$id" ]] || {
            printf "gen-theme: marker mismatch in %s: 'gen %s' closed by 'end %s'\n" "$file" "$id" "$endid" >&2
            return 2
          }
          printf '%s\n' "$l2"
          found=1
          break
        fi
      done
      ((found == 1)) || {
        printf "gen-theme: unterminated 'core:theme:gen %s' region in %s\n" "$id" "$file" >&2
        return 2
      }
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
}

# ── the reverse scan's file set ───────────────────────────────────────────────
# Which files preflight() reads when hunting for an UNREGISTERED marker. Split out
# because the discovery rule, not the scan, is the subtle part.
#
# GIT-AWARE when the tree is a repo, because a plain `grep -r .` walk is wrong in a
# way that only shows up on a developer box: it descends into `.claude/worktrees/`,
# where Claude Code parks a full checkout per session. Every themed consumer in every
# OTHER session's worktree was reported as unregistered drift — 57 phantom failures
# against a tracked tree with no drift at all — and `make audit` then printed
# `the real tree has drifted — run: make gen-theme`. That remediation is actively
# wrong: the tree had not drifted, and regenerating from a scan polluted by unrelated
# checkouts is a worse outcome than the gate simply not running.
#
# `_audit_ls` (tracked + untracked-but-not-ignored) is the right primitive and was
# what the comment above already claimed to be using. It keeps the property that
# motivates the reverse scan — an untracked consumer about to be committed is still
# caught — while inheriting git's exclusions, and `.claude/` is ignored (.gitignore).
#
# THE FALLBACK IS NOT BELT-AND-BRACES. test-core.sh's fixtures are plain directories
# with no `git init` (scripts/test/40-gen-theme-aliases.sh builds $SANDBOX/themerepo
# by hand), so git-only discovery would list zero files there and report success —
# coverage loss reading as health, the exact failure this preflight exists to end.
# The walk is correct in a fixture, which has no nested checkouts to trip over.
#
# The git path is taken only when the work-tree root IS the directory being scanned.
# A fixture created under a $TMPDIR that happens to sit inside some other repo would
# otherwise satisfy `--is-inside-work-tree` and get that repo's file list.
_theme_scan_files() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [[ -n "$top" && "$top" -ef "$PWD" ]]; then
    _audit_ls '*.toml' '*.yml' '*.zsh' '*.sh' '*.conf' '*.css'
  else
    find . -name .git -prune -o -name .claude -prune -o -type f \
      \( -name '*.toml' -o -name '*.yml' -o -name '*.zsh' -o -name '*.sh' -o -name '*.conf' \
      -o -name '*.css' \) \
      -print 2>/dev/null | sed 's|^\./||' | sort -u
  fi
}

# ── preflight: the registry and the tree must agree ───────────────────────────
# Runs before anything is emitted or compared. A block silently deleted from a
# consumer would otherwise just stop being generated, and --check would stay green
# about a file it no longer covers — coverage loss reading as health, which is the
# failure mode this whole script exists to end.
preflight() {
  local rc=0 id f n line repo
  # Forward: every REGISTERED block must appear exactly once in its file — unless
  # that file is absent, which is the documented partial-tree case.
  while IFS="$(printf '\t')" read -r id f repo; do
    [[ -n "$id" ]] || continue
    f="$(_block_path "$f" "${repo:-}")"
    # Empty = the sibling repo is not checked out. That is an ENVIRONMENT fact, reported
    # once by the driver as a skip, never a per-block failure here.
    [[ -n "$f" && -f "$f" ]] || continue
    # Both syntaxes, and the `/* … */` arm requires its closing delimiter for marker_id's
    # reason — a count that matched an unterminated opener would call a broken file healthy.
    n="$(grep -cE "^[[:space:]]*(#[[:space:]]core:theme:gen ${id}|/\*[[:space:]]core:theme:gen ${id}[[:space:]]\*/)[[:space:]]*\$" "$f" || true)"
    case "$n" in
    1) ;;
    0) printf 'gen-theme: %s: registered block is missing: %s (was its region deleted?)\n' "$f" "$id" >&2; rc=2 ;;
    *) printf 'gen-theme: %s: block appears %s times: %s (ambiguous)\n' "$f" "$n" "$id" >&2; rc=2 ;;
    esac
  done <<EOF
$BLOCKS
EOF
  # Reverse: a marker in the tree that the registry does not know about. Without
  # this, adding a block and forgetting to register it reads as success — the file
  # is simply never rendered. _audit_ls-style discovery so an UNTRACKED consumer
  # about to be committed is caught too — see _theme_scan_files for why that phrase
  # now names the actual helper instead of describing a hand-rolled imitation of it.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    f="${line%%:*}"
    # THE LAST FIELD IS NOT THE ID IN EVERY SYNTAX. `${line##* }` was written when a marker
    # could only be a `#` comment, where the id does end the line; on the CSS form it yields
    # the closing `*/` instead, so every CSS block in this tree would report as unregistered
    # under a name no registry could ever carry (#926). Strip a trailing `*/` first.
    id="${line##* }"
    [[ "$id" == '*/' ]] && { id="${line% \*/}"; id="${id##* }"; }
    grep -qxF "$(printf '%s\t%s' "$id" "$f")" <<<"$BLOCKS" || {
      printf 'gen-theme: %s carries an unregistered block: %s\n' "$f" "$id" >&2
      rc=2
    }
  # scripts/ is EXCLUDED: it is dev tooling, never a shipped consumer, and
  # test-core.sh's hermetic fixtures legitimately contain marker text inside
  # heredocs. Scanning it would report this script's own test suite as drift.
  #
  # `/dev/null` in the grep argument list does two jobs, and both are load-bearing:
  #   1. a batch of exactly one file still prints a filename — without it grep emits
  #      bare `LINE:text` and the awk below reads the line number as the path;
  #   2. it makes the empty-input case safe WITHOUT GNU's `xargs -r`, which BSD/macOS
  #      xargs does not accept. On empty input GNU xargs runs grep once with only
  #      /dev/null to read, which is a clean no-match rather than a read from stdin.
  # `tr '\n' '\0' | xargs -0` is the idiom common.sh:1954 already uses, and likewise
  # without `-r` — PORTABILITY.md §1 puts macOS inside the floor.
  done < <(_theme_scan_files | grep -v '^scripts/' |
    tr '\n' '\0' | xargs -0 grep -nE "$MARKER_RE" /dev/null 2>/dev/null |
    awk -F: '{f=$1; $1=""; $2=""; sub(/^ +/,""); print f":"$0}' |
    sed 's/[[:space:]]*$//' | sort -u)
  return $rc
}

# ── --refresh: re-resolve the palette from the PINNED tokyonight ──────────────
# Maintainer-only, and NEVER on the --check path: CI must not need nvim.
refresh_palette() {
  local tn lock_sha have_sha style nvim_style out n
  style="$(pal_raw style)"

  command -v nvim >/dev/null 2>&1 || {
    printf 'gen-theme: --refresh needs nvim (to resolve tokyonight); not on PATH\n' >&2
    return 2
  }
  tn="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/tokyonight.nvim"
  [[ -d "$tn" ]] || {
    printf 'gen-theme: --refresh needs the tokyonight plugin at %s\n' "$tn" >&2
    return 2
  }

  # The palette must be reproducible from the COMMITTED lock, not from whatever
  # the maintainer happens to have installed. Refuse rather than guess.
  lock_sha="$(sed -n 's/.*"tokyonight\.nvim": *{ *"branch": *"[^"]*", *"commit": *"\([0-9a-f]*\)".*/\1/p' nvim/lazy-lock.json)"
  have_sha="$(git -C "$tn" rev-parse HEAD 2>/dev/null)"
  if [[ -n "$lock_sha" && -n "$have_sha" && "$lock_sha" != "$have_sha" ]]; then
    printf 'gen-theme: installed tokyonight is off the pin.\n  lock: %s\n  have: %s\n  fix:  open nvim and run :Lazy restore\n' \
      "$lock_sha" "$have_sha" >&2
    return 2
  fi

  # style must match nvim's own mirror, which palette.lua:18 has only ever asked
  # for in a comment. Now it is checked.
  nvim_style="$(sed -n 's/^M\.style[[:space:]]*=[[:space:]]*"\([a-z]*\)".*/\1/p' nvim/lua/gerrrt/utils/palette.lua)"
  if [[ -n "$nvim_style" && "$nvim_style" != "$style" ]]; then
    printf 'gen-theme: style disagrees with nvim.\n  %s: %s\n  nvim/lua/gerrrt/utils/palette.lua: %s\n' \
      "$PALETTE" "$style" "$nvim_style" >&2
    return 2
  fi

  out="$(nvim --headless -u NONE -i NONE -n --cmd "set rtp^=$tn" \
    -c "lua local ok,c = pcall(function() return require('tokyonight.colors').setup({style='$style'}) end)
        if not ok or type(c) ~= 'table' then os.exit(3) end
        local k={} for n,v in pairs(c) do if type(v)=='string' and v:match('^#%x%x%x%x%x%x\$') then k[#k+1]=n end end
        table.sort(k)
        for _,n in ipairs(k) do io.write(n..'\t'..c[n]..'\n') end" \
    -c 'qa!' </dev/null 2>/dev/null)" || {
    printf 'gen-theme: could not resolve tokyonight style %s\n' "$style" >&2
    return 2
  }
  n="$(grep -c . <<<"$out" || true)"
  ((n > 0)) || { printf 'gen-theme: tokyonight resolved no colours\n' >&2; return 2; }

  # Map through the required keys. A key upstream no longer provides is an ERROR,
  # not an empty value — that is exactly the signal wanted when a plugin bump
  # renames a token.
  local k v ref rc=0
  for k in $PAL_REQUIRED; do
    case "$k" in color_*) ;; *) continue ;; esac
    v="$(awk -v want="${k#color_}" -F'\t' '$1==want{print $2; exit}' <<<"$out")"
    if [[ -z "$v" ]]; then
      printf 'gen-theme: tokyonight (%s) no longer provides: %s\n' "$style" "${k#color_}" >&2
      rc=2; continue
    fi
    # PAL_ prefix, NOT the bare key: pal() reads PAL_color_bg. Writing `color_bg`
    # here left the loaded values untouched, so --refresh reported the right count
    # and then regenerated from the STALE palette — a silent no-op that _pal_require
    # could not catch, because the old values were still perfectly valid.
    ref="PAL_$k"; printf -v "$ref" '%s' "$v"
  done
  ((rc == 0)) || return $rc
  _pal_require || return 2
  printf 'gen-theme: resolved %d colours from tokyonight (%s)\n' "$n" "$style"
}

# ── driver ────────────────────────────────────────────────────────────────────
[[ -r "$PALETTE" ]] || {
  printf 'gen-theme: %s is missing or unreadable — the drift gate checked NOTHING\n' "$PALETTE" >&2
  exit 2
}
_pal_load || exit 2

if [[ "$MODE" == list ]]; then
  # id<TAB>file for every block whose file is present, so coverage is enumerable
  # without parsing this script.
  while IFS="$(printf '\t')" read -r _id _f _r; do
    [[ -n "$_id" ]] || continue
    _f="$(_block_path "$_f" "${_r:-}")"
    [[ -n "$_f" && -f "$_f" ]] || continue
    printf '%s\t%s\n' "$_id" "$_f"
  done <<EOF
$BLOCKS
EOF
  exit 0
fi

_pal_require || exit 2
preflight || exit 2

if ((REFRESH)); then
  refresh_palette || exit $?
fi

rc=0
_bump() { (($1 > rc)) && rc="$1"; return 0; } # sticky severity: 2 > 1 > 0

while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  # A configured target that is not present is skipped, not fatal, so a partial
  # fixture tree (test-core.sh's) and a standalone checkout both stay clean.
  [[ -f "$t" ]] || continue
  grep -qE "$MARKER_RE" "$t" || continue
  if ! generated="$(build_file "$t")"; then
    _bump 2
    continue
  fi
  if [[ "$MODE" == check ]]; then
    # Materialize, then compare with the two sanctioned forms: core_files_identical
    # (git hash-object, byte-exact, no diffutils) for the verdict, and
    # `git diff --no-index` for the human diff. Reaching for the cmp/diff binaries
    # instead is the #572 defect (macOS and Alpine do not agree on what `diff` is).
    _tmp="$(mktemp "${TMPDIR:-/tmp}/gen-theme.XXXXXX")" || { _bump 2; continue; }
    printf '%s\n' "$generated" >"$_tmp"
    if ! core_files_identical "$t" "$_tmp"; then
      printf 'gen-theme: DRIFT in %s — a generated block no longer matches %s:\n' "$t" "$PALETTE" >&2
      # --src-prefix/--dst-prefix so the hunk headers read "on disk" vs "generated"
      # instead of leaking the mktemp path, which tells the reader nothing.
      git --no-pager diff --no-index --src-prefix=on-disk/ --dst-prefix=generated/ \
        -- "$t" "$_tmp" 2>/dev/null | sed 's/^/  /' >&2 || true
      printf '  fix: run make gen-theme and commit the result.\n' >&2
      _bump 1
    fi
    rm -f "$_tmp"
  else
    # `>` preserves the existing mode — tmux/scripts/*.sh are 0755 and the audit
    # asserts exec bits.
    printf '%s\n' "$generated" >"$t"
    printf 'gen-theme: regenerated %s\n' "$t"
  fi
done <<EOF
$TARGETS
EOF

# ── a sibling that is not checked out is SAID, never passed over ──────────────
# The whole point of reaching into dotfiles-MacBook is that its palette stops being held
# in step by a comment. A run that could not open the file and still printed "every
# generated block matches" would replace one unchecked claim with a more confident one —
# so the skip is reported, and `--check` returns 3 for it.
#
# 3, NOT 2: gen-porting-matrix.sh draws exactly this line (its own comment explains that
# collapsing them would let audit-core.sh record a corrupted document as an environment
# skip), and §9d classifies on it the way §9h/§9i already do for their siblings. Real
# drift outranks it — the `rc == 0` guard means a genuine mismatch still reports as
# drift, with the skip named alongside rather than instead.
#
# Two lines, not one: "not checked out" and "checked out, but the registered file is not
# there" are different facts with different fixes (clone the sibling vs. land the file or
# fix the registry row), and a reader acting on the skip should not have to guess which.
# audit-core.sh §9d collects the names from both to label its skip_env.
if [[ -n "$MISSING_REPOS" ]]; then
  printf 'gen-theme: SKIPPED — not checked out: %s (their blocks were not inspected)\n' \
    "$(printf '%s' "$MISSING_REPOS" | sed 's/^ *//; s/ *$//; s/  */ /g')" >&2
  ((rc == 0)) && rc=3
fi
if [[ -n "$MISSING_FILES" ]]; then
  printf 'gen-theme: SKIPPED — registered file absent in a checked-out sibling: %s (its block was not inspected)\n' \
    "$MISSING_FILES" >&2
  ((rc == 0)) && rc=3
fi

# ── PARITY.md's style claim ───────────────────────────────────────────────────
# PARITY.md's Theme and FZF-palette rows name the style in prose ("tokyonight-storm"), as
# a cross-repo contract with dotfiles-Windows. It is deliberately NOT generated: a generator
# rewriting Core's half of a two-repo claim would let a Core-side flip silently rewrite
# the assertion ABOUT pwsh. So it is checked instead — a flip fails at author time
# rather than becoming doc-drift for /doc-audit to find weeks later.
#
# Advisory-shaped but not silent: it only fires when PARITY.md exists AND names a style.
if [[ -r PARITY.md ]]; then
  _pm_style="$(pal_raw style)"
  # `^ {0,3}\|`, NOT `^\|`: CommonMark allows one to three leading spaces on a table row, and
  # this guard is the whole trigger — indent PARITY.md's Theme row and the match goes false,
  # so the cross-shell style contract stops being checked with `gen-theme --check` still
  # GREEN. Silent-disable, not a false alarm, which is the worse direction. Exactly the bug
  # #682 fixed in parity-check.sh's own row parser, in a sibling that did not get the memo
  # (#820). Four or more spaces IS an indented code block and must still be ignored.
  if grep -qE '^ {0,3}\| (Theme|FZF palette) ' PARITY.md && ! grep -qF "tokyonight-$_pm_style" PARITY.md; then
    if [[ "$MODE" == check ]]; then
      printf 'gen-theme: PARITY.md still names a different style than %s (style = %s).\n' "$PALETTE" "$_pm_style" >&2
      printf '  Its Theme and FZF-palette rows are a cross-repo contract with dotfiles-Windows,\n' >&2
      printf '  so they are hand-edited, not generated. Update them (and port the pwsh side).\n' >&2
      _bump 1
    else
      printf 'gen-theme: NOTE — PARITY.md still names a different style than %s (style = %s); update its Theme / FZF-palette rows by hand.\n' \
        "$PALETTE" "$_pm_style" >&2
    fi
  fi
  unset _pm_style
fi

if [[ "$MODE" == check && "$rc" == 0 ]]; then
  printf 'gen-theme: every generated block matches %s\n' "$PALETTE"
fi
exit "$rc"
