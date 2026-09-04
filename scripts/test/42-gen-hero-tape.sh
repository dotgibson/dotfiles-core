# scripts/test/42-gen-hero-tape.sh
# README hero tape generation (gen-hero-tape.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.
#
# Numbered 42 to sit beside the other generator suites — 40 is theme + aliases, 41 is the
# porting matrix + desktop parity. Same argument as those two: audit-core.sh §9j/§9k gate
# the real tree, where a red is the thing you never want to see, so every direction that
# matters — drift, cannot-run, the environment skip, and each refusal — is pinned here
# against fixtures instead.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── README hero tape generation (scripts/gen-hero-tape.sh) ───────────────────
# assets/demo.tape is rendered from assets/hero.tape.in, assets/hero-repos.txt and
# theme/palette.toml (#698). The defect it closes was invisible for exactly as long as
# nothing derived the tape: dotfiles-core's hero filmed `cd ~/…/dotfiles-MacBook`, and
# `Set Theme "TokyoNight"` named an upstream preset rather than the palette every other
# consumer is generated from. Both are pinned below — a gate that only proves "the file
# did not change" would have been green through the whole of that.
#
# The fixture copies the REAL template and the REAL palette (as F11 uses the shipped
# PARITY.shared.md) and swaps only the registry, so these tests exercise what ships.
hdr "README hero tape generation (scripts/gen-hero-tape.sh)"
GHR="$SANDBOX/herocore"      # the fixture "dotfiles-core"
GHF="$SANDBOX/herofleet"     # the fixture sibling fleet

_gh_fixture() { # _gh_fixture [--no-fedora]
  rm -rf "$GHR" "$GHF"
  mkdir -p "$GHR/assets" "$GHR/theme"
  cp "$HERE/assets/hero.tape.in" "$GHR/assets/hero.tape.in"
  cp "$HERE/theme/palette.toml" "$GHR/theme/palette.toml"
  {
    printf '# fixture registry\n'
    printf '.\tassets/demo.tape\t~/code/dotgibson/dotfiles-core\tcore status\tcore-version\tnote:the provenance panel\n'
    printf 'dotfiles-openSUSE\tassets/demo.tape\t~/code/dotgibson/dotfiles-openSUSE\tup -n\techo up resolves to $(_core_cap PKG_UPGRADE)\tcaps:os/opensuse.capabilities\n'
    printf 'dotfiles-Fedora\tassets/demo.tape\t~/code/dotgibson/dotfiles-Fedora\tup -n\techo up resolves to $(_core_cap PKG_UPGRADE)\tcaps:os/fedora.capabilities\n'
  } >"$GHR/assets/hero-repos.txt"

  # Tumbleweed's declaration says `dup`; Fedora's says dnf. Two repos is enough to prove
  # the note is DERIVED rather than typed — one could be a coincidence.
  mkdir -p "$GHF/dotfiles-openSUSE/os" "$GHF/dotfiles-openSUSE/.git" "$GHF/dotfiles-openSUSE/assets"
  printf 'PKG_UPGRADE=sudo zypper dup\n' >"$GHF/dotfiles-openSUSE/os/opensuse.capabilities"
  [[ "${1:-}" == --no-fedora ]] && return 0
  mkdir -p "$GHF/dotfiles-Fedora/os" "$GHF/dotfiles-Fedora/assets"
  printf 'gitdir: /nowhere\n' >"$GHF/dotfiles-Fedora/.git"   # a worktree's .git is a FILE
  printf 'PKG_UPGRADE=sudo dnf upgrade --refresh\n' >"$GHF/dotfiles-Fedora/os/fedora.capabilities"
}
_gh_run() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-hero-tape.sh" --root "$GHR" --fleet-root "$GHF" "$@" >/dev/null 2>&1; echo $?); }
_gh_out() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-hero-tape.sh" --root "$GHR" --fleet-root "$GHF" "$@" 2>&1); }

# POSITIVE — a clean render, and --check green on its own output.
_gh_fixture
if [[ "$(_gh_run)" == 0 ]] && [[ -f "$GHR/assets/demo.tape" ]]; then
  pass "gen-hero-tape: renders this repo's tape on a clean fixture"
else
  fail "gen-hero-tape: bare run did not write assets/demo.tape: $(_gh_out | head -n 3)"
fi
if [[ "$(_gh_run --check)" == 0 ]]; then
  pass "gen-hero-tape: --check is 0 on a freshly generated tree"
else
  fail "gen-hero-tape: --check reported drift on its own output"
fi

# THE DEFECT #698 WAS FILED FOR. The keystone repo's hero filmed a machine repo. A
# generated tape can only say what its registry row says, and this asserts it does.
if grep -qF 'Type "cd ~/code/dotgibson/dotfiles-core || exit 1" Enter' "$GHR/assets/demo.tape" &&
  ! grep -q 'dotfiles-MacBook' "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: this repo's tape films THIS repo (#698's first finding)"
else
  fail "gen-hero-tape: the rendered tape does not cd to the row's own checkout"
fi

# THE cd MUST FAIL LOUDLY. It runs inside Hide, so a path that does not exist on the
# rendering box would otherwise print into unrecorded frames and film $HOME — #698's
# wrong-tree defect wearing a different hat, and undetectable in the committed gif.
if grep -q 'Type "cd .* || exit 1" Enter' "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: the hidden cd exits on failure instead of filming \$HOME"
else
  fail "gen-hero-tape: the hidden cd has no failure guard — a bad checkout path would render the wrong tree"
fi

# `Set Theme` IS RENDERED FROM THE PALETTE, not typed. The string "TokyoNight" naming an
# upstream preset is the drift this closes: it can stay right while the palette moves.
_gh_bg="$(awk -F'"' '/^color_bg  */ { print $2; exit }' "$HERE/theme/palette.toml")"
if grep -q '^Set Theme {' "$GHR/assets/demo.tape" &&
  grep -qF "$_gh_bg" "$GHR/assets/demo.tape" &&
  ! grep -q 'Set Theme "' "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: Set Theme is rendered from theme/palette.toml, not a named preset"
else
  fail "gen-hero-tape: the tape's theme is not the palette's ($_gh_bg absent, or a quoted preset survived)"
fi

# A `caps:` ROW READS THE REPO'S OWN DECLARATION. openSUSE's must say `dup`, not `up` —
# #698's stated acceptance criterion, and the distinction that half-updates a box.
_gh_run --fleet >/dev/null
if grep -qF 'one verb → sudo zypper dup' "$GHF/dotfiles-openSUSE/assets/demo.tape" &&
  ! grep -qF 'one verb → sudo zypper up' "$GHF/dotfiles-openSUSE/assets/demo.tape"; then
  pass "gen-hero-tape: Tumbleweed's note derives \`zypper dup\`, not \`zypper up\`"
else
  fail "gen-hero-tape: openSUSE's signature note is not its declared PKG_UPGRADE"
fi
if grep -qF 'one verb → sudo dnf upgrade --refresh' "$GHF/dotfiles-Fedora/assets/demo.tape"; then
  pass "gen-hero-tape: a second caps: row derives its own verb (the note is data, not a coincidence)"
else
  fail "gen-hero-tape: Fedora's signature note did not come from its capability declaration"
fi

# THE RESOLUTION MUST BE VISIBLE, NOT JUST DERIVED. The signature NOTE is a tape comment —
# vhs never renders it — and `up -n` prints "via zypper", the MANAGER and not the verb
# (zsh/60-update.zsh's dry-run branch), so neither shows `dup` rather than `up`, which is
# #698's stated acceptance criterion. A `Type` line that PRINTS the resolved command does.
if grep -q '^Type "echo up resolves to \$(_core_cap PKG_UPGRADE)"' "$GHF/dotfiles-openSUSE/assets/demo.tape"; then
  pass "gen-hero-tape: an OS repo's tour TYPES the resolved upgrade command (visible in the gif)"
else
  fail "gen-hero-tape: no visible line resolves PKG_UPGRADE — the hero cannot show \`dup\` over \`up\`"
fi
# It must PRINT, never APPLY: a hero that upgrades the box it is filmed on is not a hero.
if ! grep -qE '^Type "(sudo|doas|brew) ' "$GHF/dotfiles-openSUSE/assets/demo.tape"; then
  pass "gen-hero-tape: the proof line reads the capability, it never runs the upgrade"
else
  fail "gen-hero-tape: the tape types a privileged upgrade command"
fi
# The substituted proof must not break the tape's own quoting: it lands inside Type "…",
# so a double quote in the registry value would close the string early.
if ! grep -E '^Type "' "$GHF/dotfiles-openSUSE/assets/demo.tape" | grep -qE '^Type "[^"]*"[^ ]'; then
  pass "gen-hero-tape: no substituted value breaks the Type \"…\" quoting"
else
  fail "gen-hero-tape: a substituted value closed its Type string early"
fi

# THE SIBLING ROWS ARE OUT OF SCOPE WITHOUT --fleet. #698 sequences those renders after
# #667; a default run reaching into another checkout would render nine near-identical
# heroes nobody asked for yet.
_gh_fixture
_gh_run >/dev/null
if [[ ! -f "$GHF/dotfiles-Fedora/assets/demo.tape" ]]; then
  pass "gen-hero-tape: a default run writes no sibling tape (--fleet is the opt-in)"
else
  fail "gen-hero-tape: a bare run wrote into a sibling repo"
fi

# DRIFT. A hand-edited tape must be 1, and the message must name the fix.
_gh_fixture && _gh_run >/dev/null
printf 'Type "rm -rf /"\n' >>"$GHR/assets/demo.tape"
_gh_drift_rc="$(_gh_run --check)"
_gh_drift_out="$(_gh_out --check)"
if [[ "$_gh_drift_rc" == 1 ]]; then
  pass "gen-hero-tape: --check exits 1 on a hand-edited tape"
else
  fail "gen-hero-tape: a hand-edited tape did not report as drift (rc=$_gh_drift_rc)"
fi
if grep -q 'demo.tape' <<<"$_gh_drift_out" && grep -q 'make gen-hero-tape' <<<"$_gh_drift_out"; then
  pass "gen-hero-tape: the drift report names the tape and the fix"
else
  fail "gen-hero-tape: drift reported without naming the tape / make gen-hero-tape"
fi

# A TEMPLATE EDIT MUST REACH THE TAPE. The whole point is that the body is authored once.
_gh_fixture && _gh_run >/dev/null
printf 'Sleep 250ms\n' >>"$GHR/assets/hero.tape.in"
if [[ "$(_gh_run --check)" == 1 ]]; then
  pass "gen-hero-tape: editing the template without regenerating is drift"
else
  fail "gen-hero-tape: a template edit left --check green — the tape is not derived from it"
fi

# A REGISTRY EDIT MUST TOO — the other half of the source, and the half that varies.
_gh_fixture && _gh_run >/dev/null
sed -i.bak 's|~/code/dotgibson/dotfiles-core|~/elsewhere|' "$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run --check)" == 1 ]]; then
  pass "gen-hero-tape: editing the registry without regenerating is drift"
else
  fail "gen-hero-tape: a registry edit left --check green"
fi

# CANNOT-RUN IS 2, NOT DRIFT. A malformed row, and a caps: row whose declaration carries no
# PKG_UPGRADE, must be a different failure from a stale tape — a broken gate reported as a
# stale doc is the shape §9g's exit-2 leg exists to keep apart.
_gh_fixture
printf 'dotfiles-Arch\tassets/demo.tape\tonly-three-fields\n' >>"$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run --check)" == 2 ]]; then
  pass "gen-hero-tape: a malformed registry row is 2 (cannot run), not 1 (drift)"
else
  fail "gen-hero-tape: a 3-field registry row was not reported as structural (rc=$(_gh_run --check))"
fi

# AN EMPTY FIELD IS NOT A VALID FIELD, and a field COUNT does not catch one: awk counts the
# empty span between two tabs, so a row with an empty checkout has NF == 6 and renders
# `cd  || exit 1` — where a BARE `cd` SUCCEEDS into $HOME. That is the wrong-tree hero this
# generator exists to prevent, reintroduced through the guard meant to prevent it (#862
# review). Asserted per column, because only one of the six was ever obviously dangerous.
for _gh_col in 2 3 4 5 6; do
  _gh_fixture
  awk -F'\t' -v OFS='\t' -v c="$_gh_col" 'NF == 6 && $1 == "." { $c = "" } { print }' \
    "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
  if [[ "$(_gh_run --check)" == 2 ]]; then
    pass "gen-hero-tape: an empty field $_gh_col is rejected (a count-only check would pass it)"
  else
    fail "gen-hero-tape: an empty field $_gh_col was accepted (rc=$(_gh_run --check))"
  fi
done

# The specific one that bites: a bare `cd` must never reach a tape.
_gh_fixture && _gh_run >/dev/null
if ! grep -qE '^Type "cd +\|\| exit 1"' "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: no tape can carry a bare \`cd\` (which would film \$HOME)"
else
  fail "gen-hero-tape: a tape carries a bare cd — it would land in \$HOME"
fi

# A MALFORMED LATER ROW MUST NOT LEAVE EARLIER TAPES REWRITTEN. Validating while streaming
# meant the sweep had already installed every row above the bad one before END exited 2.
_gh_fixture
rm -f "$GHR/assets/demo.tape"
printf 'dotfiles-Arch\tassets/demo.tape\tonly-three-fields\n' >>"$GHR/assets/hero-repos.txt"
_gh_run >/dev/null
if [[ ! -f "$GHR/assets/demo.tape" ]]; then
  pass "gen-hero-tape: a bad row aborts BEFORE any tape is written (no partial render)"
else
  fail "gen-hero-tape: a later malformed row still left an earlier tape rewritten"
fi

# A REPO LISTED TWICE would render its tape twice, the second silently winning.
_gh_fixture
printf 'dotfiles-Fedora\tassets/demo.tape\t~/dup\tup -n\tcore-version\tcaps:os/fedora.capabilities\n' >>"$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run --check)" == 2 ]]; then
  pass "gen-hero-tape: a duplicate repo row is rejected"
else
  fail "gen-hero-tape: a repo listed twice was accepted (rc=$(_gh_run --check))"
fi

# --list's DOCUMENTED shape must match what it PRINTS. The help text said three columns
# while the implementation grew to five (#862 review); anything parsing this is now wrong.
_gh_fixture
_gh_list_cols="$(_gh_out --list | awk -F'\t' 'NR == 1 { print NF }')"
_gh_help_cols="$(_gh_out --help | awk '/repo output sigcmd proof signature-source/ { print NF; exit }')"
if [[ "$_gh_list_cols" == 5 ]] && [[ "$_gh_help_cols" == 5 ]]; then
  pass "gen-hero-tape: --help documents exactly the $_gh_list_cols columns --list prints"
else
  fail "gen-hero-tape: --list prints $_gh_list_cols columns, --help documents $_gh_help_cols"
fi

_gh_fixture
printf 'PKG_REFRESH=sudo zypper refresh\n' >"$GHF/dotfiles-openSUSE/os/opensuse.capabilities"
if [[ "$(_gh_run --fleet)" == 2 ]]; then
  pass "gen-hero-tape: a caps: row with no PKG_UPGRADE is 2, not a blank note"
else
  fail "gen-hero-tape: a declaration missing PKG_UPGRADE rendered anyway (rc=$(_gh_run --fleet))"
fi

# AN ABSENT SIBLING IS 3 (an environment skip), and DRIFT OUTRANKS IT. The severity order
# is 2 > 1 > 3 > 0, which is NOT numeric order — a naive `max` would report a drifted tape
# as "the fleet is not checked out" and stay green in audit-core.sh.
_gh_fixture --no-fedora
_gh_run --fleet >/dev/null
if [[ "$(_gh_run --fleet --check)" == 3 ]]; then
  pass "gen-hero-tape: an absent sibling is 3 (environment), not a failure"
else
  fail "gen-hero-tape: an un-cloned sibling was not reported as 3 (rc=$(_gh_run --fleet --check))"
fi
printf 'Type "rm -rf /"\n' >>"$GHR/assets/demo.tape"
if [[ "$(_gh_run --fleet --check)" == 1 ]]; then
  pass "gen-hero-tape: drift outranks an absent sibling (sticky severity 1 > 3)"
else
  fail "gen-hero-tape: real drift was masked by an absent sibling (rc=$(_gh_run --fleet --check))"
fi

# THE BYTE CEILING. #698's third finding: assets/README.md documented the gifsicle remedy
# and nothing applied it. The gate weighs the file the tape's `Output` line names, so a
# renamed output cannot slip past a hardcoded path.
_gh_fixture && _gh_run >/dev/null
head -c 100 /dev/zero >"$GHR/assets/demo.gif"
if [[ "$(_gh_run --check-size)" == 0 ]]; then
  pass "gen-hero-tape: --check-size passes a hero under the ceiling"
else
  fail "gen-hero-tape: a 100-byte gif was reported as over the ceiling"
fi
if [[ "$(_gh_run --check-size --max-bytes 50)" == 1 ]]; then
  pass "gen-hero-tape: --check-size exits 1 on a hero over the ceiling"
else
  fail "gen-hero-tape: an oversized hero did not fail the size gate"
fi
_gh_out_size="$(_gh_out --check-size --max-bytes 50)"
if grep -q 'gifsicle' <<<"$_gh_out_size" && grep -q 'hero.tape.in' <<<"$_gh_out_size"; then
  pass "gen-hero-tape: the size failure names both remedies (shorten the tape, optimize the gif)"
else
  fail "gen-hero-tape: the size failure does not say how to fix it"
fi
# A MISSING LOCAL HERO IS A FAILURE, NOT A SKIP. README.md's [product-screenshot] points
# at it, so an absent gif is a broken front page — and a size gate that weighs nothing and
# reports green is the shape this section exists to prevent (#862 review). A SIBLING's is
# the opposite case: those nine are #698's follow-up and are un-rendered on purpose.
rm -f "$GHR/assets/demo.gif"
if [[ "$(_gh_run --check-size)" == 1 ]]; then
  pass "gen-hero-tape: a missing LOCAL hero fails (README points at it), never skips"
else
  fail "gen-hero-tape: a missing assets/demo.gif was reported as green (rc=$(_gh_run --check-size))"
fi
_gh_run --fleet >/dev/null   # siblings now have TAPES but no gifs — the follow-up's exact state
# Herestring, NOT `_gh_out … | grep -q`: grep -q exits on the first match and kills the
# producer, which under `set -o pipefail` makes the whole pipeline non-zero — the #459
# SIGPIPE trap this repo has hit three times and scans for in audit-core.sh.
_gh_sib_out="$(_gh_out --fleet --check-size)"
if [[ "$(_gh_run --fleet --check-size)" == 1 ]] && grep -q 'not rendered yet' <<<"$_gh_sib_out"; then
  pass "gen-hero-tape: an un-rendered SIBLING hero is still a note skip (the follow-up's state)"
else
  fail "gen-hero-tape: a sibling's absent gif was not treated as a note skip"
fi

# THE DEFAULT GATE MUST NOT BE ABLE TO CHECK NOTHING. Delete the `.` row and every
# remaining row is a sibling, every sibling is out of scope without --fleet, the sweep body
# never runs and both audit legs report success over a tape nobody looked at (#862 review).
_gh_fixture
grep -v '^\.	' "$GHR/assets/hero-repos.txt" >"$GHR/assets/hero-repos.new" &&
  mv "$GHR/assets/hero-repos.new" "$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run --check)" == 2 ]] && [[ "$(_gh_run --check-size)" == 2 ]]; then
  pass "gen-hero-tape: a registry with no \`.\` row is 2 on BOTH legs, not a green over nothing"
else
  fail "gen-hero-tape: deleting the local row left a gate green (check=$(_gh_run --check) size=$(_gh_run --check-size))"
fi

# THE SUMMARY MUST SAY WHAT IT WEIGHED. "every rendered hero is under the ceiling" is true
# of a run that weighed nothing, and that sentence is the one line a reader takes away
# (#862 review). The count, and the un-weighed remainder, have to be in it.
_gh_fixture && _gh_run >/dev/null
head -c 100 /dev/zero >"$GHR/assets/demo.gif"
_gh_sum="$(_gh_out --check-size)"
if grep -qE '1 weighed' <<<"$_gh_sum" && ! grep -q 'not rendered yet' <<<"$_gh_sum"; then
  pass "gen-hero-tape: --check-size reports how many heroes it actually weighed"
else
  fail "gen-hero-tape: the size summary does not say what it weighed: $(head -n 5 <<<"$_gh_sum")"
fi
_gh_run --fleet >/dev/null
_gh_sum="$(_gh_out --fleet --check-size)"
if grep -q 'not rendered yet (not covered by this run)' <<<"$_gh_sum"; then
  pass "gen-hero-tape: the summary names the un-weighed remainder, so a skip is never read as a pass"
else
  fail "gen-hero-tape: the size summary hides un-weighed heroes: $(tail -n 3 <<<"$_gh_sum")"
fi

# IDEMPOTENCE — a second render must be byte-identical, or --check can never be stably green.
_gh_fixture && _gh_run >/dev/null
cp "$GHR/assets/demo.tape" "$GHR/assets/demo.first.tape"
_gh_run >/dev/null
if core_files_identical "$GHR/assets/demo.first.tape" "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: generation is idempotent (second run is byte-identical)"
else
  fail "gen-hero-tape: a second run changed the tape — --check can never be stably green"
fi
rm -f "$GHR/assets/demo.first.tape"

# THE VERDICT MUST NOT DEPEND ON DIFFUTILS. `cmp`/`diff` ship in diffutils, which is not
# guaranteed present in this fleet, and a missing binary exits non-zero — indistinguishable
# from "the files differ" (#572). Shadow both: identical files must still verify as identical.
_gh_shim="$SANDBOX/nodiffutils-hero"
mkdir -p "$_gh_shim"
for _b in diff cmp; do printf '#!/bin/sh\nexit 127\n' >"$_gh_shim/$_b"; chmod +x "$_gh_shim/$_b"; done
_gh_fixture && _gh_run >/dev/null
_gh_nodiff_rc="$( (cd "$SANDBOX" && PATH="$_gh_shim:$PATH" env -u CORE_JSON bash "$HERE/scripts/gen-hero-tape.sh" --root "$GHR" --fleet-root "$GHF" --check >/dev/null 2>&1; echo $?) )"
if [[ "$_gh_nodiff_rc" == 0 ]]; then
  pass "gen-hero-tape: --check survives a host with no working diff/cmp"
else
  fail "gen-hero-tape: a broken diff/cmp turned a matching tape into drift (rc=$_gh_nodiff_rc)"
fi

# A WRITE THAT CANNOT HAPPEN MUST NOT REPORT SUCCESS. Nothing runs under `set -e`, so an
# unchecked mktemp or mv prints "rewritten" and exits 0 over a stale file. Skipped as root.
if [[ "${EUID:-$(id -u)}" != 0 ]]; then
  _gh_fixture
  chmod a-w "$GHR/assets"
  _gh_ro_rc="$(_gh_run)"
  _gh_ro_out="$(_gh_out)"
  chmod u+w "$GHR/assets"
  if [[ "$_gh_ro_rc" == 1 ]] && ! grep -q 'rewritten' <<<"$_gh_ro_out"; then
    pass "gen-hero-tape: an unwritable assets/ fails instead of claiming it was rewritten"
  else
    fail "gen-hero-tape: an unwritable target reported success (rc=$_gh_ro_rc)"
  fi
fi

# A PATH FIELD MUST NOT ESCAPE ITS CHECKOUT. Write mode resolves the output as "$dir/$out"
# and atomically replaces it, so `../README.md` overwrote a file OUTSIDE the target repo —
# verified against a real victim file before the fix (#862 review).
_gh_fixture
printf 'ORIGINAL\n' >"$SANDBOX/gh-victim.md"
awk -F'\t' -v OFS='\t' '$1 == "." { $2 = "../gh-victim.md" } { print }' \
  "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
_gh_run >/dev/null
if [[ "$(_gh_run)" == 2 ]] && grep -qx 'ORIGINAL' "$SANDBOX/gh-victim.md"; then
  pass "gen-hero-tape: an output path with \`..\` is refused and writes nothing outside the checkout"
else
  fail "gen-hero-tape: a traversing output path was accepted, or clobbered a file outside the repo"
fi
# Absolute output, and a traversing capability path, are the same class.
# shellcheck disable=SC2088  # the LITERAL tilde is the input under test: an unexpanded ~
# in the registry is a path the generator must refuse, not one the suite should expand.
for _gh_path in '/etc/x.tape' '~/x.tape'; do
  _gh_fixture
  awk -F'\t' -v OFS='\t' -v v="$_gh_path" '$1 == "." { $2 = v } { print }' \
    "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
  [[ "$(_gh_run)" == 2 ]] || fail "gen-hero-tape: an absolute output path '$_gh_path' was accepted"
done
_gh_fixture
awk -F'\t' -v OFS='\t' '$1 == "dotfiles-Fedora" { $6 = "caps:../../etc/passwd" } { print }' \
  "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
[[ "$(_gh_run --fleet)" == 2 ]] || fail "gen-hero-tape: a traversing capability path was accepted"
pass "gen-hero-tape: absolute and traversing paths are refused in both path columns"
# The check is per COMPONENT, not a substring match: a legitimate name with dots survives.
_gh_fixture
awk -F'\t' -v OFS='\t' '$1 == "." { $2 = "assets/my..tape" } { print }' \
  "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run)" == 0 ]]; then
  pass "gen-hero-tape: a filename merely CONTAINING .. is not mistaken for traversal"
else
  fail "gen-hero-tape: assets/my..tape was rejected — the traversal check is a substring match"
fi

# MATCHING-HOST RENDERING IS A CHECKED PRECONDITION, NOT AN ASSUMPTION. Core reads the
# capability declaration ONCE at shell startup, from the HOST's linked os.capabilities
# (zsh/02-capabilities.zsh) — `cd` does not switch it and `up -n` probes $PATH — so an OS
# hero filmed on the wrong box records that box's manager under a comment naming the row's:
# dotfiles-Fedora rendered on a MacBook says `brew upgrade` while the tape says `dnf`
# (#862 review). The tape now refuses to render there.
_gh_fixture && _gh_run --fleet >/dev/null
_gh_guard="$(grep -o 'Type "\[\[ \$(_core_cap PKG_UPGRADE) == .*exit 1"' "$GHF/dotfiles-openSUSE/assets/demo.tape")"
if grep -qF "== 'sudo zypper dup' ]] || exit 1" <<<"$_gh_guard"; then
  pass "gen-hero-tape: an OS tape asserts the rendering host declares THAT row's PKG_UPGRADE"
else
  fail "gen-hero-tape: no host guard, or it does not name the row's verb: $_gh_guard"
fi
# The guard and the visible note must agree — they are derived from one declaration, and a
# hero whose hidden precondition and printed comment disagree is worse than neither.
if grep -qF 'one verb → sudo zypper dup' "$GHF/dotfiles-openSUSE/assets/demo.tape"; then
  pass "gen-hero-tape: the host guard and the signature note name the same verb"
else
  fail "gen-hero-tape: the guard and the note disagree about the declared verb"
fi
# HIDDEN, so it costs the viewer nothing: it must sit between Hide and Show.
if awk '/^Hide$/ { h = 1 } /_core_cap PKG_UPGRADE/ && h && !s { found = 1 } /^Show$/ { s = 1 } END { exit !found }' \
  "$GHF/dotfiles-openSUSE/assets/demo.tape"; then
  pass "gen-hero-tape: the host guard runs inside the Hide block (no cost to the clip)"
else
  fail "gen-hero-tape: the host guard is outside Hide — it would be recorded"
fi
# A `note:` row has no declaration to assert and must get a no-op, not a broken guard.
if grep -qx 'Type "true" Enter' "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: a note: row gets a no-op guard (nothing to assert)"
else
  fail "gen-hero-tape: the local row's host guard is not the documented no-op"
fi
# An apostrophe in the declared verb would close the guard's single-quoted literal.
_gh_fixture
printf 'PKG_UPGRADE=sudo zypper dup --with-o'"'"'clock\n' >"$GHF/dotfiles-openSUSE/os/opensuse.capabilities"
if [[ "$(_gh_run --fleet)" == 2 ]]; then
  pass "gen-hero-tape: an apostrophe in PKG_UPGRADE is refused, not emitted into the guard"
else
  fail "gen-hero-tape: an apostrophe in PKG_UPGRADE was emitted (rc=$(_gh_run --fleet))"
fi

# THE SHIPPED REGISTRY, NOT THE FIXTURE. Every assertion above writes its own registry, so
# none of them pins assets/hero-repos.txt — point its `.` row back at dotfiles-MacBook,
# regenerate, and F11b plus both audit legs stay green while #698's original defect is
# fully reinstated (#862 review). These read the tracked files.
_gh_ship_row="$(awk -F'\t' '$1 == "." { print $3; exit }' "$HERE/assets/hero-repos.txt")"
case "$_gh_ship_row" in
*/dotfiles-core)
  pass "gen-hero-tape: the SHIPPED registry's \`.\` row films dotfiles-core ($_gh_ship_row)" ;;
*)
  fail "gen-hero-tape: the shipped \`.\` row films '$_gh_ship_row', not a dotfiles-core checkout — #698's defect" ;;
esac
if grep -q 'Type "cd .*/dotfiles-core || exit 1" Enter' "$HERE/assets/demo.tape"; then
  pass "gen-hero-tape: the SHIPPED assets/demo.tape cds into dotfiles-core, guarded"
else
  fail "gen-hero-tape: the shipped tape does not cd into a guarded dotfiles-core checkout"
fi
# No OTHER fleet repo may appear in an EXECUTED line of this repo's own tape. Restricted to
# `Type` lines on purpose: the shared body carries a comment that names repos to explain the
# host guard, and a whole-file grep would read that documentation as the defect it warns
# about — a gate that fails on its own explanation trains people to delete the explanation.
_gh_ship_alien=""
while IFS= read -r _gh_r; do
  [[ -n "$_gh_r" ]] || continue
  grep '^Type ' "$HERE/assets/demo.tape" | grep -q "$_gh_r" && _gh_ship_alien="$_gh_ship_alien $_gh_r"
done < <(awk -F'\t' 'NF == 6 && $1 != "." { print $1 }' "$HERE/assets/hero-repos.txt")
if [[ -z "$_gh_ship_alien" ]]; then
  pass "gen-hero-tape: the shipped tape names no other fleet repo"
else
  fail "gen-hero-tape: the shipped tape mentions$_gh_ship_alien — it is filming, or naming, another repo"
fi
# And the generator itself must REFUSE that registry, so the gate catches it even if these
# two assertions are ever deleted.
_gh_fixture
{ printf '.\tassets/demo.tape\t~/code/dotgibson/dotfiles-MacBook\tcore status\tcore-version\tnote:p\n'
  printf 'dotfiles-MacBook\tassets/demo.tape\t~/code/dotgibson/dotfiles-MacBook\tup -n\tcore-version\tnote:q\n'
} >"$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run --check)" == 2 ]] && grep -q '#698 defect' <<<"$(_gh_out --check)"; then
  pass "gen-hero-tape: a \`.\` row pointed at a sibling repo is refused by name (#698 by construction)"
else
  fail "gen-hero-tape: the generator accepted a \`.\` row filming another registered repo"
fi
# A sibling that films the wrong tree is the same defect one row over.
_gh_fixture
awk -F'\t' -v OFS='\t' '$1 == "dotfiles-Fedora" { $3 = "~/code/dotgibson/dotfiles-Arch" } { print }' \
  "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
if [[ "$(_gh_run --check)" == 2 ]]; then
  pass "gen-hero-tape: a sibling row filming another repo's checkout is refused"
else
  fail "gen-hero-tape: dotfiles-Fedora was allowed to film dotfiles-Arch"
fi

# SUBSTITUTION MUST BE LITERAL. `&` in an awk gsub REPLACEMENT expands to the matched text,
# so `check && report` rendered as `check @@SIGCMD@@@@SIGCMD@@ report` — the -v that protects
# the value on the way in does nothing on the way out (#862 review).
_gh_fixture
awk -F'\t' -v OFS='\t' '$1 == "." { $4 = "check && report" } { print }' \
  "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
_gh_run >/dev/null
if grep -qF 'Type "check && report"' "$GHR/assets/demo.tape"; then
  pass "gen-hero-tape: an \`&\` in a registry value substitutes literally (not as the match)"
else
  fail "gen-hero-tape: \`&\` was expanded by the replacement: $(grep -o 'Type "check.*' "$GHR/assets/demo.tape")"
fi

# THE DOCUMENTED SYNTAX CONTRACT MUST BE ENFORCED, not merely written down. A `"` closes the
# template's Type string; a `>` redirects in the shell vhs drives. Both were documented in
# assets/hero-repos.txt and assets/README.md and neither was checked.
for _gh_bad in 'echo "hi"' 'up -n > out' 'up -n < in'; do
  for _gh_col in 3 4 5; do
    _gh_fixture
    awk -F'\t' -v OFS='\t' -v c="$_gh_col" -v v="$_gh_bad" '$1 == "." { $c = v } { print }' \
      "$GHR/assets/hero-repos.txt" >"$GHR/assets/hr.new" && mv "$GHR/assets/hr.new" "$GHR/assets/hero-repos.txt"
    [[ "$(_gh_run --check)" == 2 ]] || fail "gen-hero-tape: field $_gh_col accepted '$_gh_bad'"
  done
done
pass "gen-hero-tape: a quote or redirection in any Type-substituted field is refused (3 values x 3 fields)"

# THE BANNER'S FIX COMMAND MUST UPDATE THE FILE IT IS WRITTEN IN. `make gen-hero-tape`
# rewrites the `.` row and nothing else, so a sibling tape carrying it names a command that
# leaves the reader's own file untouched — advice that silently does nothing (#862 review).
_gh_fixture && _gh_run --fleet >/dev/null
if grep -q 'run `make gen-hero-tape` in dotfiles-core' "$GHR/assets/demo.tape" &&
  grep -q 'run `make gen-hero-tape-fleet` in dotfiles-core' "$GHF/dotfiles-Fedora/assets/demo.tape"; then
  pass "gen-hero-tape: each banner names the target that actually regenerates THAT tape"
else
  fail "gen-hero-tape: a tape's banner names a command that would not update it"
fi

# THE FRAMERATE IS A SIZE LEVER AND MUST NOT BE LOST. VHS captures at 50fps by default;
# bytes track REDRAWS rather than seconds, so halving the frame count is the cheapest
# reduction available and the only one with no cost to the viewer. Dropping this line would
# silently double every rendered hero.
if grep -qE '^Set Framerate [0-9]+$' "$HERE/assets/demo.tape"; then
  pass "gen-hero-tape: the tape pins a capture framerate (VHS defaults to 50)"
else
  fail "gen-hero-tape: no Set Framerate — every hero would render at 50fps and roughly double"
fi

# WINDOWS IS OUT OF SCOPE, AND THAT MUST STAY DELIBERATE. #698 counts dotfiles-Windows among
# the public repos with no hero; this generator covers nine of the ten, because Windows
# replicates its host layer in PowerShell and vendors no core/ — there is no zsh to
# `Set Shell` and no `up`/`ll`/`_core_cap` for the shared body to type, so a row here would
# render a tape that cannot run (#862 review). Asserted BOTH ways: absent from the registry,
# and the absence explained where someone about to add it would look.
if ! awk -F'\t' 'NF == 6 { print $1 }' "$HERE/assets/hero-repos.txt" | grep -qx 'dotfiles-Windows'; then
  pass "gen-hero-tape: dotfiles-Windows is not registered (its host layer is PowerShell)"
else
  fail "gen-hero-tape: dotfiles-Windows has a registry row — the zsh tape body cannot run there"
fi
if grep -q 'DELIBERATELY ABSENT' "$HERE/assets/hero-repos.txt" &&
  grep -q 'dotfiles-Windows' "$HERE/assets/hero-repos.txt"; then
  pass "gen-hero-tape: the registry says WHY Windows is absent, where someone would re-add it"
else
  fail "gen-hero-tape: Windows is absent from the registry with no note — it reads as an oversight"
fi

# EVERY REMEDY MUST NAME THE TARGET THAT REPAIRS THE FILE IT IS ABOUT. This was fixed in the
# banner and survived in two diagnostics — the missing-tape failure and the drift `fix:` line
# — each of which told a sibling to run `make gen-hero-tape`, which rewrites the `.` row and
# nothing else (#862 review). One helper now, asserted in both directions.
_gh_fixture
_gh_miss_out="$(_gh_out --fleet --check)"
if grep -q 'assets/demo.tape is missing — run: make gen-hero-tape-fleet' <<<"$_gh_miss_out"; then
  pass "gen-hero-tape: a missing SIBLING tape is reported with the fleet target"
else
  fail "gen-hero-tape: a missing sibling tape names a command that would not create it"
fi
_gh_fixture && _gh_run --fleet >/dev/null
printf 'Type "x"\n' >>"$GHF/dotfiles-Fedora/assets/demo.tape"
printf 'Type "x"\n' >>"$GHR/assets/demo.tape"
_gh_fix_out="$(_gh_out --fleet --check)"
if grep -q 'then run: make gen-hero-tape-fleet' <<<"$_gh_fix_out" &&
  grep -q 'then run: make gen-hero-tape$' <<<"$_gh_fix_out"; then
  pass "gen-hero-tape: drift on a sibling and on the local row each name their own target"
else
  fail "gen-hero-tape: a drift remedy names the wrong make target: $(grep 'fix:' <<<"$_gh_fix_out")"
fi

# NO MARKDOWN FENCE MAY CARRY TRAILING TEXT. CommonMark allows only whitespace after a
# closing fence, so ``` followed by prose is not a close — the rest of the document renders
# inside the code block. markdownlint does not flag it, and it swallowed the tail of
# assets/README.md once (#862 review), so it is asserted here.
_gh_fence_bad=""
for _gh_md in assets/README.md CLAUDE.md CHANGELOG.md; do
  [[ -f "$HERE/$_gh_md" ]] || continue
  grep -qE '^```[a-zA-Z]*[[:space:]]+[^[:space:]]' "$HERE/$_gh_md" && _gh_fence_bad="$_gh_fence_bad $_gh_md"
  (($(grep -c '^```' "$HERE/$_gh_md") % 2)) && _gh_fence_bad="$_gh_fence_bad $_gh_md(odd)"
done
if [[ -z "$_gh_fence_bad" ]]; then
  pass "gen-hero-tape docs: every code fence opens and closes cleanly (no swallowed prose)"
else
  fail "gen-hero-tape docs: a fence carries trailing text or is unbalanced:$_gh_fence_bad"
fi

# THE BANNER MUST NOT TRAVEL THROUGH `awk -v`. macOS ships the one-true-awk, which REJECTS
# a literal newline in a -v assignment ("awk: newline in string"); gawk and busybox awk both
# accept it, so passing the eight-line banner that way was green on Linux and Alpine and red
# only on the macOS leg. Pinned as source shape because the box that catches it is CI's.
if ! grep -qE 'awk .*-v (hdr|banner|header)=' "$HERE/scripts/gen-hero-tape.sh"; then
  pass "gen-hero-tape: the multi-line banner is printed by bash, not passed to awk -v (macOS awk)"
else
  fail "gen-hero-tape: a multi-line value is passed to awk -v — the macOS leg rejects that"
fi

# THE GATE MUST ACTUALLY BE WIRED. A generator nothing calls is a script, not a gate — and
# both legs matter: §9j proves the tape tracks its template, §9k that the render stayed
# small. Pinned here rather than trusted, exactly as F11 pins parity-check.yml's --check.
for _gh_leg in '--check' '--check-size'; do
  if grep -qE "scripts/gen-hero-tape\.sh\" $_gh_leg" "$HERE/scripts/audit-core.sh"; then
    pass "gen-hero-tape: audit-core.sh runs the generator with $_gh_leg"
  else
    fail "gen-hero-tape: audit-core.sh never calls gen-hero-tape.sh $_gh_leg — that leg gates nothing"
  fi
done

rm -rf "$GHR" "$GHF" "$_gh_shim"
unset GHR GHF _gh_bg _gh_shim _gh_leg _gh_drift_rc _gh_drift_out _gh_nodiff_rc _gh_ro_rc _gh_ro_out _gh_out_size _gh_sib_out _gh_sum _gh_col _gh_list_cols _gh_help_cols _gh_fence_bad _gh_md _gh_ship_row _gh_ship_alien _gh_r _gh_bad _gh_guard _gh_path _gh_miss_out _gh_fix_out
