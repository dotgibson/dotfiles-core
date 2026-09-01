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
# pwsh source, and NAMES the PARITY.md table row it enforces. The coverage gate below
# then proves the one-to-one claim instead of asserting it: every `aligned` row in
# PARITY.md must have a check here, and every check must name a row that exists. Before
# #682 that was a comment and a discipline, and it was false — 21 aligned rows, 18
# checks, running green for years while `Alt+C`, History search, Word nav and five
# functions were tested by nothing at all.
#
# Usage:
#   ./scripts/parity-check.sh                 # check against sibling dotfiles-Windows
#   ./scripts/parity-check.sh --root ~/src    # the fleet lives elsewhere
#   ./scripts/parity-check.sh --strict        # a not-checked-out Windows repo FAILS
#
# Exit: 0 = every aligned row is covered by a check AND holds (or pwsh skipped);
#       1 = drift, or an aligned row nothing enforces; 2 = usage error.
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

# Each row: row-key | label | zsh-relpath | zsh-needle | pwsh-relpath | pwsh-needle.
# Needles are FIXED strings (grep -F), chosen distinctive enough to avoid false hits.
#
# ROW-KEY is the PARITY.md table row this check enforces — the slugified Capability cell
# ("Dir jump" -> dir-jump). It is what makes the one-to-one claim CHECKABLE rather than
# merely stated; the coverage gate below reads both sides and fails on either half of the
# mapping. Several checks MAY share a row-key: that is how the five utility functions and
# the three fuzzy-git verbs get a needle EACH, instead of one standing in for the set —
# the shape of bug that let `gaf` alone certify a row claiming `gaf`/`grf`/`grsf`.
#
# A pwsh-needle of `-` means the pwsh half comes from a FRAMEWORK DEFAULT and there is no
# string to grep (word-nav is the only one). Those report as a SKIP carrying the reason,
# never as a pass — the point is to be visibly honest, not to manufacture a green.
CHECKS=(
  # PARITY.md's Theme row, which was marked `aligned` with NO check behind it until #679
  # (#682 Bug 3) — one of the four rows that made the "every aligned row has a check here"
  # claim false. It shares its pwsh evidence with the fzf palette row below, because the
  # fzf --color block is the ONLY place dotfiles-Windows carries tokyonight colours at all:
  # it has no _CORE_ACCENT_SPEC equivalent. So this is honest coverage of "pwsh tracks
  # Core's theme", not independent proof, and the accent half stays a real gap — filed
  # against dotfiles-Windows rather than papered over here.
  "theme|theme: tokyonight|zsh/35-fzf.zsh|--color=|powershell/core/10-tools.ps1|--color="
  "prompt|prompt: starship|zsh/00-tools.zsh|starship init|powershell/core/10-tools.ps1|starship init"
  "smart-cd|smart cd: zoxide|zsh/00-tools.zsh|zoxide init|powershell/core/10-tools.ps1|zoxide init"
  "history-sync|history sync: atuin|zsh/00-tools.zsh|atuin init|powershell/core/10-tools.ps1|atuin init"
  # STRUCTURAL, not a pinned hex. This needled `query:#c0caf5:regular` until #679: a
  # value that a deliberate style change is SUPPOSED to move, in a gate that would then
  # fail on BOTH shells — including zsh, which had just been regenerated correctly — with
  # no fix available inside this repo. The row's claim is "both shells set an explicit
  # fzf palette"; that is what it now tests. The VALUE comparison follows the loop below,
  # where it can name the hex pwsh is missing instead of asserting a missing string.
  "fzf-palette|fzf explicit palette|zsh/35-fzf.zsh|--color=query:|powershell/core/10-tools.ps1|--color=query:"
  "fzf-source-cmd|fzf default command (fd)|zsh/35-fzf.zsh|fd --type f|powershell/core/10-tools.ps1|fd --type f"
  # Ctrl+R needles the CHORD, not PSFzf's option name: atuin's pwsh init ignores
  # ATUIN_NOBIND and seizes Ctrl+R, so 10-tools.ps1 re-asserts the chord afterwards in a
  # different place than the lazy-load stub sets it. Both must keep it, and the row's
  # promise (atuin on Ctrl+E, quick fzf history on Ctrl+R) is about the chord.
  "history-search|history search on Ctrl+R|zsh/40-bindings.zsh|'^R' _fzf_history_clean|powershell/core/10-tools.ps1|count:2:-Chord 'Ctrl+r'"
  "file-picker|file picker on Ctrl+T|zsh/40-bindings.zsh|'^T' _fzf_file_no_hidden|powershell/core/10-tools.ps1|PSReadlineChordProvider 'Ctrl+t'"
  "atuin-tui|atuin on Ctrl+E|zsh/40-bindings.zsh|'^E' _atuin_search_widget|powershell/core/10-tools.ps1|-Chord 'Ctrl+e'"
  # KEY-ANCHORED, like the Ctrl+T row above. This needled the bare `_fzf_zoxide_jump`
  # until #682 — which a rebind to a different key, or a mere COMMENT naming the widget,
  # passed unchanged. The row's claim is about the key, so the needle is too. The same
  # row also claimed `Alt+C`, which neither shell has ever bound; that half is gone. #808
  # tracks whether the capability is wanted for real (it is a two-repo change).
  "dir-jump|zoxide jump on Alt+Z|zsh/40-bindings.zsh|'^[z' _fzf_zoxide_jump|powershell/core/10-tools.ps1|-Chord 'Alt+z'"
  # KEY-ANCHORED for the Alt+Z reason, which this row was missed by in the first pass:
  # needling only the function names left `Ctrl+G` untested on BOTH shells, so moving
  # either binding to another key kept the row green.
  "session-picker|sessionizer on Ctrl+G|zsh/40-bindings.zsh|'^G' _tmux_sessionizer|powershell/core/10-tools.ps1|-Chord 'Ctrl+g'"
  # ...and what that chord DOES. Key-anchoring the row above dropped the pwsh behaviour
  # needle, so `Ctrl+G` bound to anything at all satisfied it. Both halves of the claim get a
  # needle under the shared row-key rather than one replacing the other.
  "session-picker|sessionizer target|zsh/35-fzf.zsh|_tmux_sessionizer() {|powershell/core/10-tools.ps1|Invoke-DotfilesSessionizer"
  "autosuggest-toggle|autosuggest/prediction toggle on Ctrl+\\|zsh/40-bindings.zsh|'^\\' autosuggest-toggle|powershell/core/10-tools.ps1|-Chord 'Ctrl+\\'"
  # Word nav's pwsh half is a PSReadLine DEFAULT, not configuration: nothing in
  # dotfiles-Windows binds Ctrl+Arrow — 10-tools.ps1's "Ctrl+arrow word movement" comment
  # sits directly above a line that sets Tab. There is no string to grep, so this asserts
  # Core's half and SKIPS pwsh's with the reason, rather than inventing a needle that
  # would go green without proving anything. dotgibson/dotfiles-Windows#231 tracks binding
  # it explicitly, which would upgrade this skip into a real assertion.
  # One needle per DIRECTION: the row promises Ctrl+Right and Ctrl+Left, and a single
  # forward-word needle left `'^[[1;5D' backward-word` free to be deleted with the row
  # still green — the partial-coverage shape this whole gate exists to end.
  "word-nav|word nav: forward-word on Ctrl+Right|zsh/40-bindings.zsh|'^[[1;5C' forward-word|powershell/core/10-tools.ps1|-"
  "word-nav|word nav: backward-word on Ctrl+Left|zsh/40-bindings.zsh|'^[[1;5D' backward-word|powershell/core/10-tools.ps1|-"
  # One needle per function, not one standing in for five: the row named `extract`,
  # `mkbak`, `serve`, `fif`, `fbr` and nothing tested ANY of them until #682.
  "utility-functions|extract|zsh/30-functions.zsh|extract() {|powershell/core/20-functions.ps1|function extract"
  "utility-functions|mkbak|zsh/30-functions.zsh|mkbak() {|powershell/core/20-functions.ps1|function mkbak"
  "utility-functions|serve|zsh/30-functions.zsh|serve() {|powershell/core/20-functions.ps1|function serve"
  "utility-functions|fif|zsh/35-fzf.zsh|fif() {|powershell/core/20-functions.ps1|function fif"
  "utility-functions|fbr|zsh/35-fzf.zsh|fbr() {|powershell/core/20-functions.ps1|function fbr"
  # Likewise: the row claims gaf/grf/grsf, and only gaf was needled before #682.
  "fuzzy-git-stage-restore|fuzzy git stage (gaf)|zsh/25-git.zsh|function gaf|powershell/core/20-functions.ps1|function gaf"
  "fuzzy-git-stage-restore|fuzzy git restore (grf)|zsh/25-git.zsh|function grf|powershell/core/20-functions.ps1|function grf"
  "fuzzy-git-stage-restore|fuzzy git unstage (grsf)|zsh/25-git.zsh|function grsf|powershell/core/20-functions.ps1|function grsf"
  # `cheat` is a `deliberate` row as of #682 — zsh's opens Core's own command index
  # (`alias cheat='core-help'`), pwsh's queries cht.sh — so it is not REQUIRED to carry a
  # check. Pinning that both shells still define the command is worth keeping anyway, and
  # a check is allowed to name a deliberate row; only `aligned` rows must have one.
  "cheat|cheat command|zsh/30-functions.zsh|alias cheat=|powershell/core/20-functions.ps1|function cheat"
  "front-door|core front door|zsh/30-functions.zsh|core() {|powershell/os/48-core.ps1|function global:core {"
  "health|core doctor|zsh/30-functions.zsh|core-doctor()|powershell/os/48-core.ps1|function global:core-doctor"
  "command-index|core help|zsh/30-functions.zsh|core-help()|powershell/os/48-core.ps1|function global:core-help"
  "version|core version|zsh/30-functions.zsh|core-version()|powershell/os/48-core.ps1|function global:core-version"
  "update|core update dispatch|zsh/30-functions.zsh|up \"\$@\"|powershell/os/48-core.ps1|'^update\$'"
)

# _has <file> <needle> — fixed-string presence test; non-zero if file missing too.
#
# A needle may be prefixed `count:N:` to demand at least N MATCHING LINES rather than one.
# That exists because presence is not always the claim: pwsh binds Ctrl+R twice on purpose —
# once as PSFzf's lazy stub, then again AFTER atuin's init seizes the chord — and the two
# lines are identical but for whitespace. A single presence needle is satisfied by either, so
# deleting the re-assertion left the row green while atuin kept Ctrl+R and the advertised
# parity (Ctrl+E atuin, Ctrl+R history) silently broke. Counting is the only thing that can
# tell those two apart.
_has() {
  local file="$1" needle="$2" want=1
  case "$needle" in
  count:[0-9]*:*)
    want="${needle#count:}"
    want="${want%%:*}"
    needle="${needle#count:*:}"
    ;;
  esac
  [[ -r "$file" ]] || return 1
  [[ "$(grep -cF -- "$needle" "$file")" -ge "$want" ]]
}
# _needle_says <needle> — how to describe it in a failure, with the count spelled out.
_needle_says() {
  case "$1" in
  count:[0-9]*:*) printf "%sx '%s'" "${1#count:}" "${1#count:*:}" | sed "s/:[^x]*x '/x '/" ;;
  *) printf "'%s'" "$1" ;;
  esac
}

hdr "Cross-shell parity (PARITY.md aligned rows)"

DRIFT=0
UNASSERTED=0 # pwsh halves that are framework defaults — reported, never asserted (see `-`)
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
# ── PARITY.md <-> CHECKS coverage — the one-to-one claim, asserted ───────────
# THIS is the gate #682 was really about. Everything below it tests whether a needle
# still holds; this tests whether the needles COVER the contract at all — the failure
# mode that let PARITY.md promise `Alt+C` for years while this script ran green, because
# the Alt+Z half of that row had a needle and nothing checked that the other half didn't.
#
# Two directions, because both go wrong: a row added without a needle is an unenforced
# promise, and a needle left behind after its row was RENAMED OR DELETED is a check nobody
# can trace back to a claim. Reclassifying a row does NOT orphan its check — every status
# populates KNOWN_ROWS, and `deliberate`/`gap` rows may keep one (see the `cheat` row).
# Only `aligned` rows are REQUIRED to have one.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT. Coverage here is ROW-level: every aligned row has
# at least one check. It is not CLAIM-level — a row whose cells name two triggers is not
# forced to carry two needles, so widening a row's claim can still outrun its needles. That
# is precisely how `Alt+C` hid behind Alt+Z's needle, so the multi-check row-key exists for
# it and every multi-trigger row uses it (word-nav per direction, the five utility
# functions, the three fuzzy-git verbs). Adding a trigger to a row means adding its needle;
# that half is still a discipline, and this comment is the honest statement of the limit
# rather than a second overclaim. Tracked as #809 — the fix is a contract-format decision,
# not a change to this loop.
#
# bash 3.2 (macOS ships 2007's bash): no associative arrays, no mapfile — PORTABILITY.md
# §1, the same discipline gen-theme.sh and check-modern.sh keep. Membership is tested
# against space-delimited strings, iteration against indexed arrays.
#
# The parser splits table rows on `|`, so a cell containing an escaped `\|` would break
# it. None do; one that did would surface here as an unknown slug rather than silently.
_parity_rows() { # $1 = PARITY.md -> "<row-slug>\t<status-word>" per table row
  awk -F'|' '
    {
      # LEADING WHITESPACE IS STILL A TABLE ROW. Anchoring on /^\|/ silently ignored any
      # indented row, so ` | Clipboard sync | ... | `aligned` |` parsed as nothing at all and
      # the gate reported "all 20 aligned rows have a check" and exited 0 — a valid Markdown
      # row that bypassed the contract entirely. CommonMark allows up to three leading
      # spaces; four or more is an indented code block and genuinely not a row, which is the
      # length test below. Written without an interval expression ({0,3}) so it does not
      # depend on the awk on the box.
      line = $0
      sub(/^[ ]*/, "", line)
      if (line !~ /^\|/) next
      if (length($0) - length(line) > 3) next
      cap = $2; status = $(NF - 1)
      if (cap ~ /^[[:space:]]*:?-+:?[[:space:]]*$/) next # the | --- | separator row
      gsub(/[`*]/, "", cap)                              # markdown is not part of a name
      sub(/\(.*/, "", cap)                               # "Dir jump (frecency)" is one row
      cap = tolower(cap)
      gsub(/[^a-z0-9]+/, "-", cap)
      gsub(/^-+|-+$/, "", cap)
      if (cap == "" || cap == "capability") next         # the header row
      status = tolower(status)                           # `aligned` (engine) -> aligned
      gsub(/[^a-z]+/, " ", status)
      sub(/^ +/, "", status)
      split(status, w, " ")
      print cap "\t" w[1]
    }' "$1"
}

ALIGNED_KEYS=()
ALIGNED_N=0    # a plain counter, NOT ${#ALIGNED_KEYS[@]}: under `set -u`, touching an EMPTY
               # array aborts on bash < 4.4 (macOS's stock 3.2, which this must run on) — and
               # the empty case is exactly the fail-closed branch below, so the guard meant to
               # catch "parsed nothing" would have died before it could report it.
KNOWN_ROWS=" " # every table-row slug, whatever its status
while IFS=$'\t' read -r _slug _status; do
  [[ -n "$_slug" ]] || continue
  # A slug collision would silently merge two rows' enforcement — one row's needle would
  # certify the other, which is the exact class of hole this gate exists to close. Catch
  # it here rather than letting the mapping look complete.
  if [[ "$KNOWN_ROWS" == *" $_slug "* ]]; then
    fail "coverage — two PARITY.md rows both slugify to \`$_slug\`; one row's check would certify the other. Reword one Capability cell."
    DRIFT=1
    continue
  fi
  KNOWN_ROWS="$KNOWN_ROWS$_slug "
  # REJECT AN UNKNOWN STATUS rather than treating it as "not aligned". PARITY.md defines
  # exactly three (its own vocabulary section), and a typo like `aligend` is the worst
  # possible input here: the row stays in KNOWN_ROWS so its check is not orphaned, but it
  # never reaches ALIGNED_KEYS, so the row silently stops being required — a contract row
  # dropped out of enforcement with the gate still green. That is this gate's own failure
  # mode wearing a spelling mistake, so it is a hard fail, not a lenient default.
  case "$_status" in
  aligned)
    ALIGNED_KEYS+=("$_slug")
    ALIGNED_N=$((ALIGNED_N + 1))
    ;;
  deliberate | gap) ;;
  *)
    fail "coverage — PARITY.md row \`$_slug\` has status \`${_status:-<empty>}\`, which is not one of aligned/deliberate/gap; a misspelled status silently drops the row out of enforcement"
    DRIFT=1
    ;;
  esac
done < <(_parity_rows "$HERE/PARITY.md")

CHECKED_KEYS=()
CHECKED_ROWS=" "
for _row in "${CHECKS[@]}"; do
  _k="${_row%%|*}"
  if [[ "$CHECKED_ROWS" != *" $_k "* ]]; then
    CHECKED_ROWS="$CHECKED_ROWS$_k "
    CHECKED_KEYS+=("$_k")
  fi
done

if ((ALIGNED_N == 0)); then
  # Not "no drift" — the gate read nothing. Same distinction §9d draws between DRIFT and
  # "the generator could not run": a coverage check that covered nothing must never pass.
  fail "coverage — parsed NO aligned rows out of PARITY.md; the one-to-one gate checked NOTHING this run"
  DRIFT=1
else
  _uncovered=""
  for _k in ${ALIGNED_KEYS[@]+"${ALIGNED_KEYS[@]}"}; do
    [[ "$CHECKED_ROWS" == *" $_k "* ]] || _uncovered="$_uncovered $_k"
  done
  _orphan=""
  for _k in ${CHECKED_KEYS[@]+"${CHECKED_KEYS[@]}"}; do
    [[ "$KNOWN_ROWS" == *" $_k "* ]] || _orphan="$_orphan $_k"
  done
  if [[ -n "$_uncovered" ]]; then
    fail "coverage — PARITY.md marks these rows \`aligned\` with no check behind them:$_uncovered — add a needle to CHECKS, or change the row's status to \`deliberate\`/\`gap\`"
    DRIFT=1
  fi
  if [[ -n "$_orphan" ]]; then
    fail "coverage — these CHECKS row-keys match no PARITY.md table row:$_orphan — the row was renamed or deleted (reclassifying one keeps its key valid); retire the check or fix its key"
    DRIFT=1
  fi
  [[ -z "$_uncovered$_orphan" ]] &&
    pass "coverage — all $ALIGNED_N aligned PARITY.md rows have a check, and no check outlived its row"
  unset _uncovered _orphan
fi
unset _slug _status _k

for _row in "${CHECKS[@]}"; do
  # rowkey is named, not discarded into `_`, so the split here documents the row format
  # at the point it is parsed. It is CONSUMED by the coverage gate above (${_row%%|*}),
  # which is why ShellCheck cannot see a use for it in this loop.
  # shellcheck disable=SC2034
  IFS='|' read -r rowkey label zfile zneedle pfile pneedle <<<"$_row"
  # zsh side (always checked — this is the Core repo)
  if _has "$HERE/$zfile" "$zneedle"; then
    pass "$label — zsh ($zfile)"
  else
    fail "$label — MISSING from zsh ($zfile): $(_needle_says "$zneedle")"
    DRIFT=1
  fi
  # pwsh side (only when the Windows repo is present)
  ((WIN_PRESENT)) || continue
  # `-`: the pwsh half is a framework default with no string to grep. Reported, not
  # asserted — a needle that cannot fail is worse than an honest skip.
  if [[ "$pneedle" == "-" ]]; then
    skip "$label — pwsh half is a PSReadLine default, not configuration in $pfile; nothing to grep (PARITY.md, Enforcement)"
    UNASSERTED=$((UNASSERTED + 1))
    continue
  fi
  if _has "$WIN/$pfile" "$pneedle"; then
    pass "$label — pwsh ($pfile)"
  else
    fail "$label — MISSING from pwsh ($pfile): $(_needle_says "$pneedle")"
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
  fail "cross-shell parity — an aligned PARITY.md row is unenforced, or has drifted out of a shell"
  exit 1
fi
if ((WIN_PRESENT)); then
  if ((UNASSERTED)); then
    pass "every CONFIGURED aligned row holds across zsh + pwsh; $UNASSERTED pwsh half/halves were reported, not asserted (framework defaults — see the skips above)"
  else
    pass "all aligned rows hold across zsh + pwsh"
  fi
else
  pass "all aligned rows hold on zsh (pwsh side skipped — clone dotfiles-Windows to verify)"
fi
exit 0
