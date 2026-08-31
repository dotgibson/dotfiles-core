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

# For core_files_identical — audit-core.sh §5j forbids the cmp/diff BINARIES (#572);
# the sanctioned forms are that helper for equality and `git diff --no-index` for a
# human-readable diff. Both also drop a diffutils dependency the Alpine leg would
# otherwise need. Sourced via the ALREADY-ABSOLUTE $HERE, per the note above.
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

MODE=bare
ROOT=""
while (($#)); do
  case "$1" in
  --check) MODE=check ;;
  --refresh) MODE=refresh ;;
  --list) MODE=list ;;
  --root)
    [[ -n "${2:-}" ]] || { printf 'gen-theme: --root needs a directory\n' >&2; exit 2; }
    ROOT="$2"; shift ;;
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
ux-accent-tiers	lib/ux.sh"

TARGETS="$(awk -F'\t' '{print $2}' <<<"$BLOCKS" | sort -u)"

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
marker_id() { # $1 = gen|end, $2 = line; prints the id, or returns 1
  local kind="$1" line="$2"
  [[ "$line" =~ ^[[:space:]]*#[[:space:]]core:theme:${kind}[[:space:]]([a-z0-9-]+)[[:space:]]*$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# The opening marker's leading whitespace, re-applied to every emitted line. This
# is what lets lazygit/config.yml carry a block inside its 4-space gui.theme map;
# everywhere else it is the empty string.
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

# ── preflight: the registry and the tree must agree ───────────────────────────
# Runs before anything is emitted or compared. A block silently deleted from a
# consumer would otherwise just stop being generated, and --check would stay green
# about a file it no longer covers — coverage loss reading as health, which is the
# failure mode this whole script exists to end.
preflight() {
  local rc=0 id f n line
  # Forward: every REGISTERED block must appear exactly once in its file — unless
  # that file is absent, which is the documented partial-tree case.
  while IFS="$(printf '\t')" read -r id f; do
    [[ -n "$id" ]] || continue
    [[ -f "$f" ]] || continue
    n="$(grep -c "^[[:space:]]*# core:theme:gen $id\$" "$f" || true)"
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
  # about to be committed is caught too.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    f="${line%%:*}"
    id="${line##* }"
    grep -qxF "$(printf '%s\t%s' "$id" "$f")" <<<"$BLOCKS" || {
      printf 'gen-theme: %s carries an unregistered block: %s\n' "$f" "$id" >&2
      rc=2
    }
  # scripts/ is EXCLUDED: it is dev tooling, never a shipped consumer, and
  # test-core.sh's hermetic fixtures legitimately contain marker text inside
  # heredocs. Scanning it would report this script's own test suite as drift.
  done < <(grep -rnE '^[[:space:]]*# core:theme:gen ' . \
    --include='*.toml' --include='*.yml' --include='*.zsh' --include='*.sh' --include='*.conf' 2>/dev/null |
    sed 's|^\./||' | grep -v '^\.git/' | grep -v '^scripts/' |
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
  while IFS="$(printf '\t')" read -r _id _f; do
    [[ -n "$_id" && -f "$_f" ]] || continue
    printf '%s\t%s\n' "$_id" "$_f"
  done <<EOF
$BLOCKS
EOF
  exit 0
fi

_pal_require || exit 2
preflight || exit 2

if [[ "$MODE" == refresh ]]; then
  refresh_palette || exit $?
fi

rc=0
_bump() { (($1 > rc)) && rc="$1"; return 0; } # sticky severity: 2 > 1 > 0

while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  # A configured target that is not present is skipped, not fatal, so a partial
  # fixture tree (test-core.sh's) and a standalone checkout both stay clean.
  [[ -f "$t" ]] || continue
  grep -qE '^[[:space:]]*# core:theme:gen ' "$t" || continue
  if ! generated="$(build_file "$t")"; then
    _bump 2
    continue
  fi
  if [[ "$MODE" == check ]]; then
    # Materialize, then compare with the two sanctioned forms: core_files_identical
    # (git hash-object, byte-exact, no diffutils) for the verdict, and
    # `git diff --no-index` for the human diff. audit-core.sh §5j fails a script
    # that reaches for the cmp/diff binaries instead (#572).
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

if [[ "$MODE" == check && "$rc" == 0 ]]; then
  printf 'gen-theme: every generated block matches %s\n' "$PALETTE"
fi
exit "$rc"
