#!/usr/bin/env bash
# scripts/parity-check.sh
# ──────────────────────────────────────────────────────────────────────────────
# Enforce the `aligned` rows of PARITY.md across the two interactive shells: zsh
# (Core, this repo) and PowerShell (the dotfiles-Windows host layer). PARITY.md is
# the human contract; this is the machine gate that fails when an `aligned`
# capability silently drifts out of one shell — e.g. someone drops the fzf
# tokyonight palette from pwsh, re-opening exactly the divergence we just closed.
#
# Cross-repo (like fleet-drift.sh): pwsh lives in a SEPARATE repo that doesn't
# vendor Core, so we read it from a sibling checkout. Graceful degradation mirrors
# audit-core.sh: if dotfiles-Windows isn't checked out, the pwsh side is SKIPPED
# with a notice (not failed) unless --strict — so this still runs green in a
# Core-only clone, and the scheduled workflow clones Windows first.
#
# Each check asserts a distinctive needle is present in BOTH a zsh source and a
# pwsh source. Keep these in step with PARITY.md: when a row there becomes
# `aligned`, add a check here; the check IS the enforcement.
#
# Usage:
#   ./scripts/parity-check.sh                 # check against sibling dotfiles-Windows
#   ./scripts/parity-check.sh --root ~/src    # the fleet lives elsewhere
#   ./scripts/parity-check.sh --strict        # a not-checked-out Windows repo FAILS
#
# Exit: 0 = every aligned row holds (or pwsh skipped); 1 = drift; 2 = usage error.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

ROOT="$(cd "$HERE/.." && pwd)" # siblings of dotfiles-core by default
[[ -n "${DOTFILES_ROOT:-}" ]] && ROOT="$DOTFILES_ROOT"
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  --root)
    ROOT="${2:-}"
    shift 2 || { fail "--root needs a directory"; exit 2; }
    ;;
  --strict) STRICT=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --color)
    _core_set_color "${2:-}" || { fail "--color wants auto|always|never"; exit 2; }
    shift 2
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0
    ;;
  *) fail "unknown argument: $1"; exit 2 ;;
  esac
done

[[ -d "$ROOT" ]] || { fail "fleet root not found: $ROOT"; exit 2; }
WIN="$ROOT/dotfiles-Windows"

# Each row: label | zsh-relpath | zsh-needle | pwsh-relpath | pwsh-needle.
# Needles are FIXED strings (grep -F), chosen distinctive enough to avoid false hits.
# Mirrors PARITY.md's `aligned` rows one-to-one — every aligned row has a check here,
# which is what makes the row "enforced" (PARITY.md's Enforcement section).
CHECKS=(
  # PARITY.md:27's Theme row, which was marked `aligned` with NO check behind it
  # (#682 Bug 3) — one of the four rows that made PARITY.md's "every aligned row has a
  # check here" claim false. It shares its pwsh evidence with the fzf palette row below,
  # because the fzf --color block is the ONLY place dotfiles-Windows carries tokyonight
  # colours at all: it has no _CORE_ACCENT_SPEC equivalent. So this is honest coverage of
  # "pwsh tracks Core's theme", not independent proof, and the accent half stays a real
  # gap — filed against dotfiles-Windows rather than papered over here.
  "theme: tokyonight|zsh/35-fzf.zsh|--color=|powershell/core/10-tools.ps1|--color="
  "prompt: starship|zsh/00-tools.zsh|starship init|powershell/core/10-tools.ps1|starship init"
  "smart cd: zoxide|zsh/00-tools.zsh|zoxide init|powershell/core/10-tools.ps1|zoxide init"
  "history: atuin|zsh/00-tools.zsh|atuin init|powershell/core/10-tools.ps1|atuin init"
  # STRUCTURAL, not a pinned hex. This needled `query:#c0caf5:regular` until #679: a
  # value that a deliberate style change is SUPPOSED to move, in a gate that would then
  # fail on BOTH shells — including zsh, which had just been regenerated correctly — with
  # no fix available inside this repo. The row's claim is "both shells set an explicit
  # fzf palette"; that is what it now tests. The VALUE comparison follows the loop below,
  # where it can name the hex pwsh is missing instead of asserting a missing string.
  "fzf explicit palette|zsh/35-fzf.zsh|--color=query:|powershell/core/10-tools.ps1|--color=query:"
  "fzf default command (fd)|zsh/35-fzf.zsh|fd --type f|powershell/core/10-tools.ps1|fd --type f"
  "file picker on Ctrl+T|zsh/40-bindings.zsh|'^T' _fzf_file_no_hidden|powershell/core/10-tools.ps1|PSReadlineChordProvider 'Ctrl+t'"
  "atuin on Ctrl+E|zsh/40-bindings.zsh|'^E' _atuin_search_widget|powershell/core/10-tools.ps1|-Chord 'Ctrl+e'"
  "zoxide jump on Alt+Z|zsh/40-bindings.zsh|_fzf_zoxide_jump|powershell/core/10-tools.ps1|-Chord 'Alt+z'"
  "sessionizer on Ctrl+G|zsh/40-bindings.zsh|_tmux_sessionizer|powershell/core/10-tools.ps1|Invoke-DotfilesSessionizer"
  "autosuggest/prediction toggle on Ctrl+\\|zsh/40-bindings.zsh|'^\\' autosuggest-toggle|powershell/core/10-tools.ps1|-Chord 'Ctrl+\\'"
  "fuzzy git stage/restore (gaf)|zsh/25-git.zsh|function gaf|powershell/core/20-functions.ps1|function gaf"
  "cheat command|zsh/30-functions.zsh|alias cheat=|powershell/core/20-functions.ps1|function cheat"
  "core front door|zsh/30-functions.zsh|core() {|powershell/os/48-core.ps1|function global:core {"
  "core doctor|zsh/30-functions.zsh|core-doctor()|powershell/os/48-core.ps1|function global:core-doctor"
  "core help|zsh/30-functions.zsh|core-help()|powershell/os/48-core.ps1|function global:core-help"
  "core version|zsh/30-functions.zsh|core-version()|powershell/os/48-core.ps1|function global:core-version"
  "core update dispatch|zsh/30-functions.zsh|up \"\$@\"|powershell/os/48-core.ps1|'^update\$'"
)

# _has <file> <needle> — fixed-string presence test; non-zero if file missing too.
_has() { [[ -r "$1" ]] && grep -qF -- "$2" "$1"; }

hdr "Cross-shell parity (PARITY.md aligned rows)"

DRIFT=0
WIN_PRESENT=1
if [[ ! -d "$WIN" ]]; then
  WIN_PRESENT=0
  if ((STRICT)); then
    fail "dotfiles-Windows not checked out at $WIN (--strict)"
    DRIFT=1
  else
    skip "dotfiles-Windows not checked out at $WIN — pwsh side not verified"
  fi
fi
for _row in "${CHECKS[@]}"; do
  IFS='|' read -r label zfile zneedle pfile pneedle <<<"$_row"
  # zsh side (always checked — this is the Core repo)
  if _has "$HERE/$zfile" "$zneedle"; then
    pass "$label — zsh ($zfile)"
  else
    fail "$label — MISSING from zsh ($zfile): '$zneedle'"
    DRIFT=1
  fi
  # pwsh side (only when the Windows repo is present)
  ((WIN_PRESENT)) || continue
  if _has "$WIN/$pfile" "$pneedle"; then
    pass "$label — pwsh ($pfile)"
  else
    fail "$label — MISSING from pwsh ($pfile): '$pneedle'"
    DRIFT=1
  fi
done

# ── fzf palette VALUE parity — compared, never pinned ────────────────────────
# The CHECKS row above asserts both shells set an explicit palette. This asserts they
# set the SAME one, and that Core's matches theme/palette.toml.
#
# WHY THIS IS NOT A NEEDLE. Until #679 the row pinned the literal string
# `query:#c0caf5:regular` in both files. Core's half is now GENERATED, so a style
# change rewrites zsh/35-fzf.zsh and leaves dotfiles-Windows — which is hand-maintained
# and out of the generator's scope — untouched. The pinned form then failed on both
# halves, including the one that had just done exactly the right thing, and named no
# fix that could be made from this repo. Extracting and comparing turns a two-sided
# false-plus-true into a one-sided TRUE finding, in the repo that can act on it.
_qcolor() { # $1 = file -> the hex fzf is told to paint the query with
  [[ -r "$1" ]] || return 1
  sed -nE 's/.*--color=query:(#[0-9a-fA-F]{6}).*/\1/p' "$1" | head -n1
}
_pal_fg="$(sed -nE 's/^color_fg[[:space:]]*=[[:space:]]*"(#[0-9a-f]{6})".*/\1/p' "$HERE/theme/palette.toml" 2>/dev/null | head -n1)"
_z_q="$(_qcolor "$HERE/zsh/35-fzf.zsh" || true)"

if [[ -z "$_pal_fg" ]]; then
  skip "fzf palette value (theme/palette.toml unreadable — nothing to compare against)"
elif [[ -z "$_z_q" ]]; then
  fail "fzf palette value — zsh/35-fzf.zsh sets no --color=query at all"
  DRIFT=1
elif [[ "$_z_q" != "$_pal_fg" ]]; then
  # Should be unreachable: gen-theme.sh --check gates this in `make audit`. Kept
  # because a gate that trusts another gate is how both stop being run.
  fail "fzf palette value — zsh/35-fzf.zsh has $_z_q but theme/palette.toml says $_pal_fg; run: make gen-theme"
  DRIFT=1
else
  pass "fzf palette value — zsh matches theme/palette.toml ($_pal_fg)"
fi

if ((WIN_PRESENT)) && [[ -n "$_z_q" ]]; then
  _p_q="$(_qcolor "$WIN/powershell/core/10-tools.ps1" || true)"
  if [[ -z "$_p_q" ]]; then
    fail "fzf palette value — powershell/core/10-tools.ps1 sets no --color=query"
    DRIFT=1
  elif [[ "$_p_q" != "$_z_q" ]]; then
    fail "fzf palette value — Core is on style=$(sed -nE 's/^style[[:space:]]*=[[:space:]]*"([a-z]+)".*/\1/p' "$HERE/theme/palette.toml" 2>/dev/null | head -n1) (query $_z_q); dotfiles-Windows still carries $_p_q. Port powershell/core/10-tools.ps1 by hand — it is outside Core's generation scope."
    DRIFT=1
  else
    pass "fzf palette value — pwsh tracks Core ($_z_q)"
  fi
fi
unset _pal_fg _z_q

# ── data-driven tool-swap alias parity (scripts/parity-aliases.txt) ──────────
# The CHECKS array above covers the tools/bindings/functions rows; the modern-CLI
# tool-swap aliases (ls→eza, cat→bat, ps→procs, …) are a bigger, churnier set, so they
# live in a flat manifest instead of hand-coded rows — "cover every tool-swap alias"
# means add a manifest row, not a code block. Each aligned row asserts the zsh alias is
# DEFINED in zsh/20-aliases.zsh AND the pwsh name is in 00-aliases.ps1's `provides:` contract
# (which tests/LoadContract.Tests.ps1 gates to the real definitions). This is what makes
# it bidirectional: a rename/drop on EITHER shell fails the row.
ALIAS_MANIFEST="$HERE/scripts/parity-aliases.txt"
ZSH_ALIASES="$HERE/zsh/20-aliases.zsh"
PWSH_ALIASES="$WIN/powershell/core/00-aliases.ps1"
if [[ -r "$ALIAS_MANIFEST" ]]; then
  # The pwsh `provides:` contract line as a ,-delimited set (read once; empty when the
  # Windows repo/file is absent — the per-row pwsh check is then skipped anyway).
  provides=""
  if ((WIN_PRESENT)) && [[ -r "$PWSH_ALIASES" ]]; then
    provides="$(grep -m1 '^# provides:' "$PWSH_ALIASES" | sed 's/^# provides://')"
  fi
  while IFS='|' read -r cap zalias palias _note; do
    [[ "$cap" =~ ^[[:space:]]*# ]] && continue # comment row
    [[ -z "${cap// /}" ]] && continue          # blank row
    # zsh side (always checked): the alias must be defined in zsh/20-aliases.zsh. Match
    # `alias <name>=` anywhere a word boundary allows — many are defined inline as
    # `[[ -n $HAVE_X ]] && alias du=…`, not on their own line, so the match can't anchor
    # to line-start; the leading space/line-start guard still rules out `myalias`.
    if grep -qE "(^|[[:space:]])alias (--[[:space:]]+)?${zalias}=" "$ZSH_ALIASES" 2>/dev/null; then
      pass "alias ${cap} — zsh (${zalias})"
    else
      fail "alias ${cap} — MISSING from zsh/20-aliases.zsh: alias ${zalias}"
      DRIFT=1
    fi
    # pwsh side (only when Windows is present): the name must be in the `provides:` set.
    ((WIN_PRESENT)) || continue
    if grep -qE "(^|,)[[:space:]]*${palias}[[:space:]]*(,|\$)" <<<"$provides"; then
      pass "alias ${cap} — pwsh (${palias})"
    else
      fail "alias ${cap} — MISSING from pwsh 00-aliases.ps1 provides: ${palias}"
      DRIFT=1
    fi
  done <"$ALIAS_MANIFEST"
fi

echo
if ((DRIFT)); then
  fail "cross-shell parity drift — an aligned PARITY.md row is missing from a shell"
  exit 1
fi
if ((WIN_PRESENT)); then
  pass "all aligned rows hold across zsh + pwsh"
else
  pass "all aligned rows hold on zsh (pwsh side skipped — clone dotfiles-Windows to verify)"
fi
exit 0
