#!/usr/bin/env bash
# scripts/gen-hero-tape.sh
# ──────────────────────────────────────────────────────────────────────────────
# Render assets/hero.tape.in into one VHS tape per row of assets/hero-repos.txt.
#
# THE DEFECT THIS CLOSES (#698). Ten public repos open with the same shields
# template and no visual; the one repo that HAS a hero is the one nobody installs
# directly, and its tape filmed the wrong checkout —
#
#     Type "cd ~/code/dotfiles/dotfiles-MacBook" Enter
#
# — inside dotfiles-core. assets/README.md already asserted the property that makes
# the fix cheap: the hero is a SCRIPT, so "re-run the command after any prompt or
# tooling change and the hero updates — no manual re-recording." Nine hand-recorded
# gifs would drift exactly the way the theme (#679), the alias tables (#685), the
# porting matrix (#686) and the desktop-bar parity pair (#693) drifted. The per-repo
# delta is two lines, so this is a substitution over one template, not nine files.
#
# WHAT VARIES, AND WHERE IT COMES FROM. The `cd` path is registry data. The one
# per-repo command is deliberately the SAME THREE CHARACTERS on every OS repo —
# `up -n` — because the thesis is what it RESOLVES to, and that is shown by running
# it, not by typing it. The trailing NOTE is derived from the repo's own
# os/*.capabilities PKG_UPGRADE, so it can never claim a verb the repo does not
# declare: Tumbleweed's says `zypper dup`, not `zypper up`, because its declaration
# does — the distinction that half-updates a box if you get it wrong.
#
# `Set Theme` IS A PALETTE CONSUMER. The tape used to carry `Set Theme "TokyoNight"`,
# a fourth place the theme was named by hand and the one place it named an upstream
# preset rather than theme/palette.toml's resolved table — so the hero could stay
# "Tokyo Night" while Core's actual chrome moved (#698 scope 4). It is now rendered
# from the palette, as a full JSON theme.
#
# WHY NOT A `# core:theme:gen` BLOCK, like the other thirteen consumers. Those files
# are hand-authored around a generated REGION; a rendered tape is generated end to
# end, so a marker pair inside it would hand one file to two generators and make
# `make gen-theme` and `make gen-hero-tape` each able to dirty the other's output.
# One owner per file. The cost is this script's own small palette reader, kept to
# the keys it emits and deliberately identical in shape to gen-theme.sh's — a
# palette change reds §9j here as well as §9d there, which is the coverage that
# matters.
#
# ONLY THIS REPO'S TAPE IS WRITTEN BY DEFAULT. Every other row needs a sibling
# checkout, and #698 sequences those renders AFTER dotfiles-core#667: nine heroes of
# the same Core verbs would be nine near-identical gifs. --fleet is that follow-up's
# button; the default run and --check touch this repo alone, which is what lets §9j
# be an always-on gate with no sibling dependency and no environment SKIP.
#
# Usage:
#   ./scripts/gen-hero-tape.sh                 # write this repo's assets/demo.tape
#   ./scripts/gen-hero-tape.sh --check         # exit 1 with a diff if it is stale — THE GATE
#   ./scripts/gen-hero-tape.sh --check-size    # exit 1 if a rendered hero gif is over the ceiling
#   ./scripts/gen-hero-tape.sh --list          # one row per hero, TAB-separated:
#                                              repo output sigcmd proof signature-source
#   ./scripts/gen-hero-tape.sh --fleet         # ALSO write the nine sibling tapes
#   ./scripts/gen-hero-tape.sh --fleet --check # ALSO check them
#   ./scripts/gen-hero-tape.sh --root DIR      # this repo lives at DIR (test fixtures)
#   ./scripts/gen-hero-tape.sh --fleet-root DIR# the siblings live under DIR (worktrees)
#   ./scripts/gen-hero-tape.sh --max-bytes N   # override the --check-size ceiling
#
# Exit: 0 = every in-scope tape matches the template (or was written);
#       1 = drift, an unwritable target, or a gif over the ceiling;
#       2 = usage, or the generator cannot run (missing template/registry/palette,
#           a malformed row, a capability declaration with no PKG_UPGRADE);
#       3 = --fleet only: a sibling repo is NOT CHECKED OUT, so this run could not
#           cover it. Callers read that as an ENVIRONMENT skip — the posture
#           gen-porting-matrix.sh (§9h) and gen-desktop-parity.sh (§9i) take for the
#           same input — but it is still a NON-ZERO exit here. Severity is sticky,
#           2 > 1 > 3 > 0: a structural failure must never surface as mere drift, and
#           real drift must never surface as an absent sibling.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

MODE="write"
FLEET=0
ROOT=""
FLEET_ROOT=""
# The hero ceiling, in bytes. 2 MiB is a CEILING, not a target: the committed clip
# is ~1.8 MB for ~25 s, which is the size #698 filed against, and the shortened
# template plus the gifsicle pass assets/README.md documents lands well under half
# of it. One heavy gif is a preference; ten is a policy, so the number is asserted
# here rather than described in prose nothing reads.
MAX_BYTES=2097152

while (($#)); do
  case "$1" in
  --check) MODE="check" ;;
  --check-size) MODE="size" ;;
  --list) MODE="list" ;;
  --fleet) FLEET=1 ;;
  --root)
    [[ -n "${2:-}" ]] || { fail "--root needs a directory"; exit 2; }
    ROOT="$2"; shift ;;
  --fleet-root)
    [[ -n "${2:-}" ]] || { fail "--fleet-root needs a directory"; exit 2; }
    FLEET_ROOT="$2"; shift ;;
  --max-bytes)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || { fail "--max-bytes needs a byte count"; exit 2; }
    MAX_BYTES="$2"; shift ;;
  --quiet) QUIET=1 ;;
  --color)
    _core_set_color "${2:-}" || { fail "--color wants auto|always|never"; exit 2; }
    shift ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
    exit 0 ;;
  *) fail "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

[[ -n "$ROOT" ]] && HERE="$(cd -- "$ROOT" 2>/dev/null && pwd)"
[[ -n "$HERE" && -d "$HERE" ]] || { fail "--root is not a directory"; exit 2; }
cd "$HERE" || exit 2

TEMPLATE="assets/hero.tape.in"
REGISTRY="assets/hero-repos.txt"
PALETTE="theme/palette.toml"

# Siblings of this repo by default. Inside a git worktree that is .claude/worktrees/,
# which is why --fleet-root exists — the same escape hatch gen-porting-matrix.sh's
# --fleet gives, for the same reason.
[[ -z "$FLEET_ROOT" ]] && FLEET_ROOT="$(cd -- "$HERE/.." && pwd)"
[[ -n "${DOTFILES_ROOT:-}" && "$FLEET_ROOT" == "$(cd -- "$HERE/.." && pwd)" ]] && FLEET_ROOT="$DOTFILES_ROOT"

TAB="$(printf '\t')"

for f in "$TEMPLATE" "$REGISTRY" "$PALETTE"; do
  [[ -r "$f" ]] || { fail "$f is missing or unreadable — nothing to render from"; exit 2; }
done

# core_files_identical compares `git hash-object` outputs: with no git BOTH sides are
# empty and therefore EQUAL, so a drifted tape would read as clean and --check would
# report success having compared nothing. Fail closed, as gen-desktop-parity.sh does.
command -v git >/dev/null 2>&1 || {
  fail "git is not installed — the byte comparison needs it; the gate would compare NOTHING and pass"
  exit 2
}

# Remove the in-flight temp on ANY exit. The normal paths already rm it, but a Ctrl-C
# between mktemp and the install otherwise leaves a demo.tape.gen.XXXXXX sitting in
# someone's checkout — litter the audit's untracked-stray gate would then report. EXIT
# does the cleanup (a second rm -f is a no-op); INT/TERM exit with the conventional
# 128+signal and let EXIT fire, exactly as gen-desktop-parity.sh does.
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below, which shellcheck stops
# crediting once the script ends in an explicit `exit "$SEV"` (it does — the exit code IS
# this script's contract, so the terminal exit stays and the suppression goes here). BOTH
# ids: 0.11 calls it SC2329, the 0.9 that the Alpine leg installs calls the same body
# SC2317, and the audit fails on any non-zero shellcheck exit including info level.
_gh_cleanup() { [[ -n "${tmp:-}" ]] && rm -f "$tmp"; }
trap _gh_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── the palette ───────────────────────────────────────────────────────────────
# gen-theme.sh's reader, narrowed to the colours this template emits. The awk is the
# load-bearing part: a naive `sub(/#.*/,"")` comment-strip would EAT THE HEX, since
# every colour starts with `#`. Match a leading quoted string first. All POSIX awk —
# the Alpine CI leg runs busybox — and a flat PAL_<key> namespace, because macOS
# ships bash 3.2 and has no associative arrays.
_pal_load() {
  local k v
  while IFS="$TAB" read -r k v; do
    [[ -n "$k" ]] || continue
    case "$k" in
    [a-z]*) ;;
    *) fail "$PALETTE: bad key: $k"; return 2 ;;
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

# Exactly the keys emit_theme reads. Explicit, so a palette missing one fails ONCE
# here instead of writing `"background": ""` into ten tapes and rendering a black gif.
PAL_REQUIRED="style
color_bg color_fg color_fg_dark color_bg_visual color_black
color_blue color_cyan color_green color_magenta color_orange color_red color_red1
color_terminal_black color_yellow"

_pal_require() {
  local k ref v rc=0
  for k in $PAL_REQUIRED; do
    ref="PAL_$k"; v="${!ref-}"
    if [[ -z "$v" ]]; then
      fail "$PALETTE: missing key: $k"; rc=2; continue
    fi
    case "$k" in
    color_*)
      [[ "$v" =~ ^#[0-9a-f]{6}$ ]] ||
        { fail "$PALETTE: $k is not a 6-digit lowercase hex: $v"; rc=2; } ;;
    esac
  done
  return $rc
}

pal() { local r="PAL_color_$1"; printf '%s' "${!r}"; }
pal_raw() { local r="PAL_$1"; printf '%s' "${!r}"; }  # a non-colour key (style)

# emit_theme — VHS's `Set Theme { … }`, on ONE line.
#
# ONE LINE IS DELIBERATE. VHS's own documentation shows the JSON form inline, and a
# tape is not JSON — wrapping the object across lines depends on the tape lexer, not
# on a JSON parser, so the form that is documented is the form that is safe.
#
# THE ANSI MAPPING. tokyonight's terminal palette is what the resolved table in
# theme/palette.toml already holds, so each slot names the token that plays it rather
# than repeating a hex: `white` is fg_dark and `brightWhite` is fg (the plugin's own
# split), `brightBlack` is terminal_black, and `brightRed` is red1 — the only bright
# slot the palette distinguishes. The rest repeat their normal token, which is what
# tokyonight itself does; inventing brighter variants here would put colours in the
# hero that appear nowhere else in Core.
emit_theme() {
  # `name` first, as VHS's own documented example writes it. It is optional to the
  # parser and carries no colour, but it is what a reader of the tape sees, and naming
  # the palette's `style` there means a `--refresh` onto a different tokyonight variant
  # renames the theme instead of silently recolouring one called "storm".
  printf 'Set Theme { "name": "Tokyo Night %s (dotfiles-core)", ' "$(pal_raw style)"
  printf '"background": "%s", "foreground": "%s", "selection": "%s", "cursor": "%s", ' \
    "$(pal bg)" "$(pal fg)" "$(pal bg_visual)" "$(pal fg)"
  printf '"black": "%s", "red": "%s", "green": "%s", "yellow": "%s", "blue": "%s", "magenta": "%s", "cyan": "%s", "white": "%s", ' \
    "$(pal black)" "$(pal red)" "$(pal green)" "$(pal yellow)" "$(pal blue)" "$(pal magenta)" "$(pal cyan)" "$(pal fg_dark)"
  printf '"brightBlack": "%s", "brightRed": "%s", "brightGreen": "%s", "brightYellow": "%s", "brightBlue": "%s", "brightMagenta": "%s", "brightCyan": "%s", "brightWhite": "%s" }\n' \
    "$(pal terminal_black)" "$(pal red1)" "$(pal green)" "$(pal yellow)" "$(pal blue)" "$(pal magenta)" "$(pal cyan)" "$(pal fg)"
}

# ── the registry ──────────────────────────────────────────────────────────────
# rows() emits the data lines of assets/hero-repos.txt: blank and `#` lines dropped,
# five TAB fields asserted. A malformed row is exit 2, never a silently skipped hero —
# a registry that quietly renders four of ten rows is the "green having covered
# nothing" shape #682 was filed for.
# validate_registry — EVERY structural check, run to completion, BEFORE anything is written.
#
# TWO DEFECTS THIS SHAPE CLOSES (#862 review), both of which a streaming validator has by
# construction:
#
#   1. A LATER BAD ROW MUST NOT LEAVE EARLIER TAPES REWRITTEN. The first cut printed each
#      good row as it went and only exited 2 from END, so the sweep had already consumed —
#      and in write mode installed — every row above the malformed one. The registry is now
#      validated whole, and the run aborts before the sweep starts.
#   2. AN EMPTY FIELD IS NOT A VALID FIELD. `NF != 6` passes a row whose checkout is empty
#      (awk counts the empty span between two tabs), which renders `cd  || exit 1` — and a
#      BARE `cd` succeeds, landing in $HOME. That is precisely the wrong-tree hero this
#      generator exists to prevent, reintroduced through the guard meant to prevent it.
#
# It reports EVERY finding before exiting, rather than dying on the first: a registry with
# three bad rows should take one run to fix, not three.
validate_registry() {
  awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF != 6 {
      printf "gen-hero-tape: %s:%d: expected 6 tab-separated fields, found %d\n", FILENAME, FNR, NF > "/dev/stderr"
      bad = 1; next
    }
    {
      for (i = 1; i <= 6; i++) {
        if ($i ~ /^[[:space:]]*$/) {
          printf "gen-hero-tape: %s:%d: field %d is empty — every column is required (an empty checkout renders a bare `cd`, which succeeds into $HOME)\n", FILENAME, FNR, i > "/dev/stderr"
          bad = 1
        }
      }
      # THE DOCUMENTED SYNTAX CONTRACT, ENFORCED. checkout, sigcmd and proof are substituted
      # INSIDE the `Type "…"` line of the template, so a double quote closes that VHS string
      # early, and a `>` is a REDIRECTION in the shell vhs is driving: `up -n > file` writes a
      # file instead of showing one. assets/hero-repos.txt and assets/README.md both stated these
      # constraints and nothing checked them (#862 review); a contract only prose enforces is
      # the thing this whole generator exists to replace.
      for (i = 3; i <= 5; i++) {
        if (index($i, "\"")) {
          printf "gen-hero-tape: %s:%d: field %d contains a double quote — it is substituted inside Type \"…\" and would close the string early: %s\n", FILENAME, FNR, i, $i > "/dev/stderr"
          bad = 1
        }
        if (index($i, ">") || index($i, "<")) {
          printf "gen-hero-tape: %s:%d: field %d contains a redirection character — it is TYPED into a live shell: %s\n", FILENAME, FNR, i, $i > "/dev/stderr"
          bad = 1
        }
      }
      # A PATH FIELD MUST STAY INSIDE ITS CHECKOUT. Write mode resolves the output as
      # "$dir/$out" and atomically replaces it, so `../README.md` overwrites a file OUTSIDE
      # the target repo — verified to clobber one (#862 review). The capability path is read
      # rather than written, but it is the same class and the check costs nothing. Rejected:
      # an absolute path, a leading ~, and any `..` component (not a substring match, so a
      # legitimate name like `..foo` or `a..b` is untouched).
      for (pf = 0; pf < 2; pf++) {
        pv = (pf == 0) ? $2 : ($6 ~ /^caps:/ ? substr($6, 6) : "")
        pn = (pf == 0) ? "output" : "capability"
        if (pv == "") continue
        if (pv ~ /^[\/~]/) {
          printf "gen-hero-tape: %s:%d: %s path must be relative to the repo: %s\n", FILENAME, FNR, pn, pv > "/dev/stderr"
          bad = 1
        }
        ns = split(pv, seg, "/")
        for (si = 1; si <= ns; si++) {
          if (seg[si] == "..") {
            printf "gen-hero-tape: %s:%d: %s path escapes the checkout via `..`: %s\n", FILENAME, FNR, pn, pv > "/dev/stderr"
            bad = 1
            break
          }
        }
      }
      # WHICH TREE THE TAPE FILMS, checked against the row that names it. #698 opened because
      # the dotfiles-core hero ran `cd ~/…/dotfiles-MacBook`; a fixture cannot catch that
      # coming back, because a fixture writes its own registry (#862 review). So the rule is
      # self-referential and needs no hardcoded repo name: a sibling row must cd into a path
      # ending in ITS OWN repo name, and the `.` row must not cd into any OTHER registered
      # repo.
      base = $3; sub(/\/+$/, "", base); sub(/^.*\//, "", base)
      if ($1 == ".") { local_base = base } else {
        if (base != $1) {
          printf "gen-hero-tape: %s:%d: %s films %s — a repo\047s hero must film its own checkout\n", FILENAME, FNR, $1, $3 > "/dev/stderr"
          bad = 1
        }
      }
      repo_named[$1] = 1
      # The signature source decides whether a note is derived or literal; anything else is
      # a typo that would otherwise surface as a per-row failure mid-sweep.
      if ($6 !~ /^(note|caps):/) {
        printf "gen-hero-tape: %s:%d: signature source must start with note: or caps: — got: %s\n", FILENAME, FNR, $6 > "/dev/stderr"
        bad = 1
      }
      # A repo named twice would render its tape twice, the second silently winning.
      if ($1 in seen) {
        printf "gen-hero-tape: %s:%d: duplicate row for %s (first seen at line %d)\n", FILENAME, FNR, $1, seen[$1] > "/dev/stderr"
        bad = 1
      }
      seen[$1] = FNR
      if ($1 == ".") local_rows++
      n++
    }
    # EXACTLY ONE LOCAL ROW. Without this the default gate can pass having checked
    # NOTHING: delete or rename the `.` row and every remaining row is a sibling, every
    # sibling is out of scope without --fleet, the sweep body never runs, SEV stays 0 and
    # both audit legs report success over a tape nobody looked at (#862 review). That is
    # the exact "green because absent" shape §8a/§8d and #682 exist to close.
    END {
      if (local_rows != 1) {
        printf "gen-hero-tape: %s: expected exactly one `.` (this repo) row, found %d — the default gate would check nothing\n", FILENAME, local_rows > "/dev/stderr"
        bad = 1
      }
      if (n == 0) {
        printf "gen-hero-tape: %s: no rows at all — nothing would be rendered or gated\n", FILENAME > "/dev/stderr"
        bad = 1
      }
      # THE #698 REGRESSION ITSELF. Deferred to END because it needs every repo name.
      if (local_base != "" && (local_base in repo_named)) {
        printf "gen-hero-tape: %s: the `.` row films %s, which is another registered repo — that IS the #698 defect (this repo\047s hero shot inside a machine repo)\n", FILENAME, local_base > "/dev/stderr"
        bad = 1
      }
      if (bad) exit 2
    }
  ' "$REGISTRY"
}

# rows — the data lines, emitted ONLY after validate_registry has passed. It re-applies no
# checks: one validator, run once, up front.
rows() {
  awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF == 6 { print }
  ' "$REGISTRY"
}

# signature_note <repo> <dir> <spec> — the trailing comment on the signature line.
#
#   note:<text>   literal, for a repo with no capability declaration of its own.
#   caps:<path>   DERIVED from that declaration's PKG_UPGRADE, read the way
#                 scripts/check-capabilities.sh reads it: KEY=value, `#` a comment
#                 ONLY at line start, so a `#` inside a value stays in the value.
#
# A `caps:` row whose declaration is missing or carries no PKG_UPGRADE is exit 2,
# not an empty note: the note exists to prove the hero shows that repo's real verb,
# and a blank one would assert nothing while looking rendered.
signature_note() {
  local repo="$1" dir="$2" spec="$3" path up
  case "$spec" in
  note:*) printf '%s' "${spec#note:}"; return 0 ;;
  caps:*) path="${spec#caps:}" ;;
  *) fail "$repo: signature source must start with note: or caps: — got: $spec"; return 2 ;;
  esac
  [[ -r "$dir/$path" ]] || { fail "$repo: no readable $path — the registry names a declaration the repo does not carry"; return 2; }
  up="$(awk -F= '/^PKG_UPGRADE=/ { sub(/^PKG_UPGRADE=/, ""); print; exit }' "$dir/$path")"
  [[ -n "$up" ]] || { fail "$repo: $path declares no PKG_UPGRADE — the note would claim nothing"; return 2; }
  printf 'one verb → %s' "$up"
}

# host_guard <repo> <dir> <spec> — the hidden precondition line.
#
# For a `caps:` row it asserts that the RENDERING HOST resolves PKG_UPGRADE to the same
# value the row declares. It has to, because Core loads the declaration ONCE at shell
# startup from the host's linked os.capabilities (zsh/02-capabilities.zsh) — `cd` does not
# switch it, and `up -n` probes $PATH — so a Fedora tape filmed on a MacBook records
# `brew upgrade` under a comment claiming `dnf` (#862 review). A `note:` row has no
# declaration to check and gets a no-op.
#
# NO DOUBLE QUOTES, by construction: the line is substituted into the template's
# `Type "…"`. zsh does not word-split a command substitution inside [[ ]], so the left side
# needs no quoting, and the right side is single-quoted to stay a literal rather than a glob.
host_guard() {
  local repo="$1" dir="$2" spec="$3" path up
  case "$spec" in
  note:*) printf 'true'; return 0 ;;
  caps:*) path="${spec#caps:}" ;;
  esac
  up="$(awk -F= '/^PKG_UPGRADE=/ { sub(/^PKG_UPGRADE=/, ""); print; exit }' "$dir/$path")"
  # An apostrophe would close the single-quoted literal below. No declaration in the fleet
  # has one; refuse rather than emit a tape that cannot parse.
  case "$up" in
  *\'*) fail "$repo: PKG_UPGRADE contains an apostrophe, which cannot sit inside the host guard: $up"; return 2 ;;
  esac
  printf "[[ \$(_core_cap PKG_UPGRADE) == '%s' ]] || exit 1" "$up"
}

# banner <repo> — the provenance header the template's @@HEADER@@ becomes. It names
# BOTH inputs and the command that rewrites the file, because the reader who finds
# this is the one who just tried to hand-edit it.
# shellcheck disable=SC2016  # the backticked `make gen-hero-tape` below is TEXT for the
# rendered tape's reader, not a command substitution to expand here.
banner() {
  # THE COMMAND MUST BE THE ONE THAT UPDATES *THIS* FILE. `make gen-hero-tape` rewrites the
  # `.` row and nothing else, so a sibling tape carrying it named a command that would leave
  # the reader's own file untouched — advice that silently does nothing, which is worse than
  # none (#862 review). A sibling gets the --fleet target instead.
  local fix="make gen-hero-tape"
  [[ "$1" != "." ]] && fix="make gen-hero-tape-fleet"
  printf '# GENERATED by dotfiles-core scripts/gen-hero-tape.sh — DO NOT EDIT.\n'
  printf '#   body:     dotfiles-core assets/hero.tape.in\n'
  printf '#   per-repo: dotfiles-core assets/hero-repos.txt (row: %s)\n' "$1"
  printf '#   colours:  dotfiles-core theme/palette.toml\n'
  printf '# Edit the body or the registry, then run `%s` in dotfiles-core.\n' "$fix"
  printf '#\n'
  printf '# Render:  vhs assets/demo.tape      # writes assets/demo.gif — commit it\n'
  printf '# Needs:   vhs, and a Nerd Font installed locally (eza/starship icons).\n'
}

# render <repo> <checkout> <sigcmd> <signote> — the tape, on stdout.
#
# The template's own header block is DROPPED: it documents the placeholders, which no
# longer exist by the time this runs, and shipping "PLACEHOLDERS, substituted by the
# generator" into ten rendered tapes would describe a file that has none. Everything
# from @@HEADER@@ onward is the tape.
#
# SUBSTITUTION IS LITERAL, VIA index/substr — NOT gsub. sed would be the obvious tool and
# is the wrong one, because a `/` or `&` in a replacement changes its meaning. awk's gsub
# fixes the `/` half and NOT the `&` half: `&` in a gsub REPLACEMENT expands to the matched
# text, so a signature command like `check && report` rendered as
# `check @@SIGCMD@@@@SIGCMD@@ report` and then tripped the unsubstituted-placeholder check.
# This comment used to claim -v made that safe; -v protects the value on the way IN, not on
# the way out (#862 review). `lit()` below is the same index/substr walk gen-porting-matrix.sh
# uses for its `esc()`, and it has no metacharacters at all.
#
# THE BANNER IS PRINTED BY BASH, NOT PASSED IN. macOS ships the one-true-awk, which
# REJECTS a literal newline inside a `-v` assignment — `awk: newline in string` — and
# the banner is eight lines. gawk and busybox awk both accept it, so this passed on
# Linux and Alpine and failed only on the macOS leg (#698 review). Every remaining -v
# value is a single line by construction; keep it that way.
render() {
  awk -v checkout="$1" -v sigcmd="$2" -v signote="$3" -v proof="$4" -v guard="$5" -v theme="$6" '
    # lit(s, ph, v) — every occurrence of the LITERAL ph in s replaced by the LITERAL v.
    function lit(s, ph, v,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) {
        out = out substr(s, 1, i - 1) v
        s = substr(s, i + length(ph))
      }
      return out s
    }
    # @@HEADER@@ marks where the body starts; the banner itself is already on stdout.
    !started { if ($0 == "@@HEADER@@") { started = 1; next } else next }
    {
      line = $0
      # The signature line is the one line whose length is DATA, so its trailing
      # comment cannot be aligned in the template — pad it here to the column the
      # three fixed tour lines already use. Cosmetic, but the rendered tape is what
      # a reader of another repo sees, and a ragged comment column reads as a file
      # someone edited by hand, which is exactly what it must not look like.
      if (line ~ /@@SIGCMD@@/) {
        head = line; sub(/[ \t]*#.*/, "", head)
        head = lit(head, "@@SIGCMD@@", sigcmd)
        printf "%-53s# %s\n", head, signote
        next
      }
      # The proof line carries no comment (the note above it already names the verb) and
      # is long enough that padding it would only add trailing space, so it takes the
      # ordinary substitution path below.
      line = lit(line, "@@THEME@@", theme)
      line = lit(line, "@@PROOF@@", proof)
      line = lit(line, "@@HOSTGUARD@@", guard)
      line = lit(line, "@@CHECKOUT@@", checkout)
      line = lit(line, "@@SIGCMD@@", sigcmd)
      line = lit(line, "@@SIGNOTE@@", signote)
      if (line ~ /@@[A-Z]+@@/) {
        printf "gen-hero-tape: %s: unsubstituted placeholder: %s\n", FILENAME, line > "/dev/stderr"
        exit 2
      }
      print line
    }
    END { if (!started) { printf "gen-hero-tape: %s carries no @@HEADER@@ line — the tape body cannot be located\n", FILENAME > "/dev/stderr"; exit 2 } }
  ' "$TEMPLATE"
}

# repo_root <repo> — where this row's tape lives, or "" if unreachable.
#   `.`   THIS repo, always present.
#   else  a sibling checkout, `-e <dir>/.git` (a worktree's .git is a FILE, so not -d),
#         resolved through resolve_repo_dir so a clone under a different directory
#         name still counts.
repo_root() {
  local repo="$1" dir
  [[ "$repo" == "." ]] && { printf '%s' "$HERE"; return 0; }
  dir="$(resolve_repo_dir "$FLEET_ROOT" "$repo")" || dir="$FLEET_ROOT/$repo"
  [[ -e "$dir/.git" ]] || return 1
  printf '%s' "$dir"
}

# BEFORE the palette and before any mode: a run that cannot trust its registry must not
# write, check or weigh anything.
validate_registry || exit 2
_pal_load || exit 2
_pal_require || exit 2
THEME_LINE="$(emit_theme)"

# Sticky severity, ranked 2 > 1 > 3 > 0 — which is NOT numeric order, so a bare
# `(($1 > rc))` would let an absent sibling (3) outrank real drift (1) and report a
# drifted tape as an environment skip. RANK is the ordering; SEV maps back to the
# exit code the header documents.
RANK=0
SEV=0
_bump() { # _bump <exit-code>
  local r
  case "$1" in 0) r=0 ;; 3) r=1 ;; 1) r=2 ;; *) r=3 ;; esac
  ((r > RANK)) && { RANK=$r; SEV="$1"; }
  return 0
}
MISSING=""
# --check-size accounting. "every rendered hero is under the ceiling" is TRUE of a run that
# weighed nothing, so the summary says how many it actually put on the scale (#862 review).
# A skip is already printed and counted by skip_note; this stops the FINAL line from being
# the one place a reader could mistake "nothing to weigh" for "nothing wrong".
WEIGHED=0
UNWEIGHED=0


# ── --list ────────────────────────────────────────────────────────────────────
# Coverage without grep: what would be rendered where, and with which signature —
# the answer to "is dotfiles-Gentoo in the hero set?" that does not require reading
# a TAB-separated file by eye. Nothing is resolved against the fleet, so it works on
# a Core-only clone.
if [[ "$MODE" == list ]]; then
  rows | awk -F'\t' -v OFS='\t' '{ print $1, $2, $4, $5, $6 }' || exit 2
  exit 0
fi

hdr "README hero tapes (rendered from assets/hero.tape.in)"

# ── the sweep ─────────────────────────────────────────────────────────────────
# Process substitution, NOT a pipeline: a `rows | while` loop runs in a subshell and
# every _bump is lost with it — the script would exit 0 over a drifted tape. The same
# trap gen-theme.sh's _pal_load documents.
while IFS="$TAB" read -r repo out checkout sigcmd proof signature; do
  [[ -n "$repo" ]] || continue

  # A sibling row is OUT OF SCOPE without --fleet. Not a skip and not a failure: #698
  # sequences those renders after #667, so a default run has no business reaching into
  # another checkout, and reporting nine skips every audit would be noise about a
  # decision that has already been made.
  if [[ "$repo" != "." ]] && ((!FLEET)); then continue; fi

  # `.` is a registry token, not a name a reader should ever see in a report line:
  # "./assets/demo.tape has drifted" names no repo. Label it.
  label="$repo"; [[ "$repo" == "." ]] && label="dotfiles-core"

  if ! dir="$(repo_root "$repo")"; then
    MISSING="$MISSING $repo"
    skip_env "$label not checked out under $FLEET_ROOT — skipping $out (clone it, or pass --fleet-root)"
    _bump 3
    continue
  fi
  file="$dir/$out"

  if ! signote="$(signature_note "$repo" "$dir" "$signature")"; then _bump 2; continue; fi
  if ! hostguard="$(host_guard "$repo" "$dir" "$signature")"; then _bump 2; continue; fi

  # ── --check-size: the byte ceiling on the RENDERED hero ────────────────────
  # A tape is a script; a gif is bytes, and #698's third finding is that nothing
  # enforced them — assets/README.md documented the gifsicle remedy and no gate
  # applied it. `Output <path>` in the tape is what names the file, so the ceiling
  # follows the tape rather than assuming assets/demo.gif; a tape that names no
  # output is a broken tape, not a passed check.
  if [[ "$MODE" == size ]]; then
    if [[ ! -f "$file" ]]; then
      if [[ "$repo" == "." ]]; then
        fail "$out is missing — this repo's tape must exist"; _bump 1
      else
        skip_note "$label has no $out yet (the nine renders are #698's follow-up)"
        UNWEIGHED=$((UNWEIGHED + 1))
      fi
      continue
    fi
    gif="$(awk '/^[[:space:]]*Output[[:space:]]/ { print $2; exit }' "$file")"
    if [[ -z "$gif" ]]; then
      fail "$label/$out names no Output file — the size gate has nothing to measure"; _bump 2; continue
    fi
    if [[ ! -f "$dir/$gif" ]]; then
      # THE LOCAL ROW IS NOT ALLOWED TO BE MISSING. README.md's [product-screenshot]
      # points at this file, so an absent gif is a BROKEN HERO on the repo's front page,
      # and a size gate that weighs nothing and reports green is the failure this section
      # exists to prevent (#862 review). A sibling's is a different case entirely: those
      # nine are #698's follow-up and have not been rendered on purpose.
      if [[ "$repo" == "." ]]; then
        fail "$label/$gif is missing — README.md's hero points at it; render it: vhs $out"
        _bump 1
      else
        skip_note "$label/$gif not rendered yet — nothing to weigh"
        UNWEIGHED=$((UNWEIGHED + 1))
      fi
      continue
    fi
    # `wc -c <file` and not `wc -c file`: BSD and GNU wc agree on the number but not
    # on the whitespace around it, and redirecting drops the filename entirely.
    bytes="$(wc -c <"$dir/$gif" | tr -d ' ')"
    if ((bytes > MAX_BYTES)); then
      fail "$label/$gif is $bytes bytes, over the $MAX_BYTES ceiling — shorten the clip in assets/hero.tape.in, re-render, then: gifsicle -O3 --lossy=80 $gif -o $gif"
      _bump 1
    else
      pass "$label/$gif is $bytes bytes (ceiling $MAX_BYTES)"
      WEIGHED=$((WEIGHED + 1))
    fi
    continue
  fi

  # ── write / --check ────────────────────────────────────────────────────────
  # ONE render, to a TEMPLATED temp file — bare `mktemp` is a BSD failure
  # (PORTABILITY.md). In write mode the temp is a SIBLING of the target so the install
  # is an atomic same-filesystem rename; in check mode nothing is installed, so it goes
  # to TMPDIR and the target's directory need not be writable at all.
  if [[ "$MODE" == check ]]; then
    _tmpl="${TMPDIR:-/tmp}/gen-hero-tape.XXXXXX"
  else
    # Write mode only. A read-only --check must not create directories in another repo —
    # a gate with a side effect is a gate you cannot trust to have measured what was there.
    _tmpl="$file.gen.XXXXXX"
    mkdir -p "$(dirname "$file")" 2>/dev/null
  fi
  if ! tmp="$(mktemp "$_tmpl" 2>/dev/null)"; then
    fail "$label/$out — could not create a temp file next to it (is the directory writable?)"; _bump 1; continue
  fi
  # NOTHING here runs under `set -e`, so every step that can fail is branched on: an
  # unchecked render prints "rewritten" and exits 0 over a stale or half-written file.
  # `{ banner && render; }` yields render's status when banner succeeds, so a failed
  # render is still caught — and the banner reaches the file through bash's own printf
  # rather than an awk -v the macOS awk refuses (see render's note).
  if ! { banner "$repo" && render "$checkout" "$sigcmd" "$signote" "$proof" "$hostguard" "$THEME_LINE"; } >"$tmp"; then
    fail "$label/$out — rendering the tape failed; the file was NOT modified"
    rm -f "$tmp"; _bump 2; continue
  fi

  if [[ "$MODE" == check ]]; then
    if [[ ! -f "$file" ]]; then
      fail "$label/$out is missing — run: make gen-hero-tape"; rm -f "$tmp"; _bump 1; continue
    fi
    # core_files_identical, NOT cmp/diff: both ship in diffutils, which is not
    # guaranteed present in this fleet, and a missing binary exits non-zero —
    # indistinguishable from "the files differ", the exact shape that red-flagged a
    # lockfile which had never moved (#572). The helper hashes instead. git diff stays
    # for DIAGNOSTICS only, never the verdict.
    if core_files_identical "$file" "$tmp"; then
      pass "$label/$out matches assets/hero.tape.in"
    else
      fail "$label/$out has drifted from assets/hero.tape.in:"
      git --no-pager diff --no-index --no-color --src-prefix=on-disk/ --dst-prefix=generated/ \
        -- "$file" "$tmp" | sed 's/^/    /' >&2 || true
      printf '    fix: edit assets/hero.tape.in or assets/hero-repos.txt, then run: make gen-hero-tape\n' >&2
      _bump 1
    fi
    rm -f "$tmp"
  else
    # chmod BEFORE the rename: mktemp creates 0600 and mv preserves it, so without this
    # every regeneration would turn a tracked, world-readable tape into an owner-only
    # file. git stores 100644, so match that — as gen-desktop-parity.sh does.
    if chmod 0644 "$tmp" && mv -f "$tmp" "$file"; then
      pass "$label/$out rewritten from assets/hero.tape.in"
    else
      fail "$label/$out — could not install the rendered tape; the file is unchanged"
      rm -f "$tmp"; _bump 1
    fi
  fi
done < <(rows)

if [[ -n "$MISSING" ]]; then
  # The message shape audit-core.sh parses — "not checked out under <root>:<repos> — ".
  printf 'gen-hero-tape: not checked out under %s:%s — those tapes were not covered (clone the fleet beside this repo, or pass --fleet-root DIR)\n' \
    "$FLEET_ROOT" "$MISSING" >&2
fi

case "$SEV" in
0) case "$MODE" in
   check) pass "README hero tapes — every rendered tape tracks assets/hero.tape.in" ;;
   size)
     if ((UNWEIGHED)); then
       pass "README hero size — $WEIGHED weighed, under the ${MAX_BYTES}-byte ceiling; $UNWEIGHED not rendered yet (not covered by this run)"
     else
       pass "README hero size — $WEIGHED weighed, all under the ${MAX_BYTES}-byte ceiling"
     fi
     ;;
   *) pass "README hero tapes — rendered from assets/hero.tape.in" ;;
   esac ;;
esac
exit "$SEV"
