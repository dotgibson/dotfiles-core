# scripts/test/36-bootstrap-lib.sh
# bootstrap-lib link accounting, git identity, system files, OS/role overlays, package lists
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── blib_link displacement accounting (lib/bootstrap-lib.sh) ─────────────────
# blib_link is reached above only THROUGH blib_link_core, and no test asserted a BLIB_*
# value at all — which is how #430 survived: a real file at $dst was moved to
# .pre-dotfiles.<epoch> and counted, while a symlink pointing SOMEWHERE ELSE was rm -f'd
# with no record of its target, no counter, and nothing in the run summary. The repos
# being wired are symlink farms, so that was the common case, not the rare one.
#
# These pin the contract both directions: a displaced link is logged + counted as
# RELINKED (never as backed up — that word promises a restorable file on disk), a
# displaced file still backs up, and an already-correct link stays silent so a plain
# re-run of bootstrap.sh prints no relink noise.
hdr "blib_link displacement accounting (relink is recorded, not silent)"
_bl="$(mktemp -d "$SANDBOX/blink.XXXXXX")"
printf 'REAL\n' >"$_bl/src"
printf 'OTHER\n' >"$_bl/other"

# The lib's `_CORE_BOOTSTRAP_LIB_SH` re-entry guard makes a re-`source` a no-op, so the
# counters cannot be observed from a subshell here — an earlier fragment already sourced it at
# file scope. Drive a fresh `bash -c` instead, exactly as the link run above does, so the
# tallies are genuinely read from 0. Prints the run's output, then `--`, then the four.
_bl_run() { # <dry> <src> <dst>
  BLIB_DRY="$1" bash -c '
    set -u
    . "'"$HERE/lib/bootstrap-lib.sh"'"
    blib_link "$1" "$2"
    printf -- "--\n%s %s %s %s\n" "$BLIB_LINKED" "$BLIB_BACKED" "$BLIB_RELINKED" "$BLIB_SKIPPED"
  ' _ "$2" "$3" 2>&1
}
_bl_tally() { printf '%s' "${1##*$'--\n'}" | tr -d '\n'; } # the line after the -- marker

# 1) a symlink pointing ELSEWHERE: repointed, its old target NAMED, counted as relinked
#    and NOT as backed up, and no stray .pre-dotfiles.* left behind.
ln -sfn "$_bl/other" "$_bl/dst1"
_bl_out="$(_bl_run 0 "$_bl/src" "$_bl/dst1")"
if [[ "$_bl_out" == *"relinking"*"$_bl/other"* ]] && [[ "$(_bl_tally "$_bl_out")" == "1 0 1 0" ]] &&
  [[ "$(readlink "$_bl/dst1")" == "$_bl/src" ]] &&
  [[ -z "$(find "$_bl" -name 'dst1.pre-dotfiles.*')" ]]; then
  pass "blib_link: a displaced symlink is repointed, its old target named, counted relinked"
else
  fail "blib_link: displaced symlink lost its target or was miscounted (got: $_bl_out)"
fi

# 2) a real file still takes the OTHER path — moved aside with its content intact, counted
#    as backed up and NOT as relinked. The two tallies must not bleed into each other.
printf 'MINE\n' >"$_bl/dst2"
_bl_out="$(_bl_run 0 "$_bl/src" "$_bl/dst2")"
_bl_bak="$(find "$_bl" -name 'dst2.pre-dotfiles.*' | head -1)"
if [[ "$(_bl_tally "$_bl_out")" == "1 1 0 0" ]] && [[ -n "$_bl_bak" ]] &&
  [[ "$(cat "$_bl_bak")" == "MINE" ]] && [[ "$(readlink "$_bl/dst2")" == "$_bl/src" ]]; then
  pass "blib_link: a displaced real file still backs up (content intact), counted backed up"
else
  fail "blib_link: real-file backup regressed or leaked into the relink tally (got: $_bl_out)"
fi

# 2b) …and it SAYS SO. The backup was correct but MUTE, and blib_link wires ~34 of ~40
#     destinations in an OS-repo bootstrap, so silent clobbering was the common case, not
#     the rare one (#463). The aggregate "N backed up" footer says THAT something moved,
#     never WHAT — which is the one thing the person migrating an existing machine needs.
#     Assert the destination AND the backup path are both named, so a future refactor
#     cannot quietly degrade this to "backed up a file".
if [[ "$_bl_out" == *"backed up existing $_bl/dst2 -> $_bl_bak"* ]]; then
  pass "blib_link: the backup is announced, naming both the destination and where it went"
else
  fail "blib_link: a real file was displaced silently or without naming the backup (got: $_bl_out)"
fi

# 2c) The backup SUFFIX is the one sortable format (#464). Core wrote `date +%s` here and
#     the `link()` helper new-os-repo.sh generates wrote `date +%Y%m%d-%H%M%S`, and an
#     OS repo's unlink_dest DOCUMENTS a lexical-sort-is-chronological invariant over the
#     glob. A 10-digit epoch always sorts before a `20…` datestamp, so across the pair the
#     invariant was false and --uninstall could restore the OLDER file. Pin the format so
#     the assertion in that comment is true rather than merely asserted. The `.<pid>` tail
#     is the same-second collision guard; it only ever tiebreaks WITHIN a second.
if [[ "${_bl_bak##*/}" =~ ^dst2\.pre-dotfiles\.[0-9]{8}-[0-9]{6}\.[0-9]+$ ]]; then
  pass "blib_link: backup suffix is the sortable pre-dotfiles.<YYYYmmdd-HHMMSS>.<pid> format"
else
  fail "blib_link: backup suffix drifted from the one fleet format (got: ${_bl_bak##*/})"
fi

# 2d) The invariant itself, end to end: two backups of the SAME destination, one second
#     apart, must sort chronologically under a plain lexical sort — the operation
#     --uninstall performs to choose the newest. This is the assertion that would have
#     caught the two-format split, because it fails on a mixed pair regardless of which
#     formats are in play.
printf 'OLDER\n' >"$_bl/dst4"
_bl_run 0 "$_bl/src" "$_bl/dst4" >/dev/null
rm -f "$_bl/dst4"
sleep 1
printf 'NEWER\n' >"$_bl/dst4"
_bl_run 0 "$_bl/src" "$_bl/dst4" >/dev/null
_bl_sorted=()
while IFS= read -r _bl_l; do _bl_sorted[${#_bl_sorted[@]}]="$_bl_l"; done < <(
  find "$_bl" -name 'dst4.pre-dotfiles.*' | sort
)
if ((${#_bl_sorted[@]} == 2)) &&
  [[ "$(cat "${_bl_sorted[0]}")" == "OLDER" && "$(cat "${_bl_sorted[1]}")" == "NEWER" ]]; then
  pass "blib_link: a lexical sort of the backups IS chronological (the --uninstall invariant)"
else
  fail "blib_link: lexical sort of backups is not chronological — --uninstall would restore the wrong file"
fi

# 3) BLIB_DRY previews the displacement instead of hiding it. "would relink: $dst" alone
#    reads as *repoint*; a reader has to be told what is about to go, and the fixture must
#    come through untouched.
ln -sfn "$_bl/other" "$_bl/dst3"
_bl_out="$(_bl_run 1 "$_bl/src" "$_bl/dst3")"
if [[ "$_bl_out" == *"would relink"* ]] && [[ "$_bl_out" == *"currently -> $_bl/other"* ]] &&
  [[ "$(readlink "$_bl/dst3")" == "$_bl/other" ]] && [[ "$(_bl_tally "$_bl_out")" == "1 0 1 0" ]]; then
  pass "blib_link: BLIB_DRY=1 names what it would displace and mutates nothing"
else
  fail "blib_link: dry-run plan hides the displaced target or mutated the fixture (got: $_bl_out)"
fi

# 4) the already-correct link is still a silent no-op. bootstrap.sh is re-run after every
#    sync, so a relink notice here would fire on every path on every run and mean nothing.
ln -sfn "$_bl/src" "$_bl/dst4"
_bl_out="$(_bl_run 0 "$_bl/src" "$_bl/dst4")"
if [[ "$(_bl_tally "$_bl_out")" == "1 0 0 0" ]] && [[ "$_bl_out" != *"relink"* ]]; then
  pass "blib_link: an already-correct link stays a silent no-op (no relink noise on re-run)"
else
  fail "blib_link: a correct link was counted or announced as a relink (got: $_bl_out)"
fi

# 5) the summary carries it. The counter only matters if the run's footer reports it —
#    that footer is what an OS repo's bootstrap prints, and it is the only place a user
#    who scrolled past the per-link lines can still see that something was displaced.
_bl_sum="$(bash -c '
  set -u
  . "'"$HERE/lib/bootstrap-lib.sh"'"
  ln -sfn "$2" "$3"; ln -sfn "$2" "$4"
  blib_link "$1" "$3" >/dev/null 2>&1
  blib_link "$1" "$4" >/dev/null 2>&1
  blib_wire_summary
' _ "$_bl/src" "$_bl/other" "$_bl/dst5" "$_bl/dst6" 2>&1)"
if [[ "$_bl_sum" == *"2 relinked"* ]]; then
  pass "blib_wire_summary: displaced links are reported in the run footer"
else
  fail "blib_wire_summary: the footer omits the relink tally (got: $_bl_sum)"
fi

# ── blib_link_os_layer's ssh overlay (lib/bootstrap-lib.sh) ──────────────────
# The escape hatch #450 depends on, and the one overlay NO repo ships yet — so without a
# fixture it is code that has never run anywhere. It is also what makes moving ssh/config
# into Core safe to argue for: a layer with a genuinely OS-specific ssh need has somewhere
# to put it other than a forked copy of the whole client config, which is how seven repos
# ended up hand-maintaining byte-identical files.
#
# Two properties, and the second is the one that bites. blib_link honours BLIB_DRY on its
# own, but the mkdir/chmod this overlay needs do NOT — they are plain commands, so a
# --dry-run would create and chmod ~/.ssh/config.d on a box the operator was only
# inspecting. That is the exact asymmetry the role-layer arm below pins (one repo's dry-run
# mutated the box, the other's did not), caught here before it can happen again.
#
# No `have` guard: this needs only bash and the library, unlike the link run in
# scripts/test/34-link-run.sh (git), so it runs
# everywhere — including the minimal containers where the heavier fixtures skip.
hdr "helper-adoption section is --strict-safe (audit-core.sh §5f)"
# The adoption section reads SIBLING repos off disk, and CI checks out only Core — so every
# run there takes a skip branch. --strict (which ci.yml passes) reds on TOOL-absent skips, so
# a sibling-absence skip landing in that class would turn the whole fleet's CI red the moment
# it landed, on every repo, for a purely advisory check.
#
# THIS CONTRACT CHANGED SHAPE. It used to be a WORDING rule: the skip text had to contain the
# literal "out of scope", because a substring test was what classified skips. That made the
# message the gate — you could not make the wording honest without moving a gate — and it
# filed "this box has no sibling to read" under the same heading as "you asked me to narrow
# this run". The class is recorded structurally now, by skip_env(), so what must be pinned is
# the CALL, not the prose. Wording is free to change; the classifier is not.
#
# Asserted statically on the source rather than by running the audit: reproducing "no sibling
# checked out" means a fake fleet root, and the property worth pinning is which function the
# section calls, which is exactly what a static read can see.
_ha_bad=0
while IFS= read -r _ha_line; do
  [ -n "$_ha_line" ] || continue
  case "$_ha_line" in
  *skip_env*) ;;
  *)
    fail "helper adoption: a plain skip() here lands in the TOOL-absent class and reds --strict in CI — $_ha_line"
    _ha_bad=1
    ;;
  esac
done <<EOF
$(grep -n 'skip[_a-z]* "helper adoption' "$HERE/scripts/audit-core.sh" 2>/dev/null || true)
EOF
if ((_ha_bad == 0)) && grep -q 'skip_env "helper adoption' "$HERE/scripts/audit-core.sh" 2>/dev/null; then
  pass "helper adoption: every sibling skip goes through skip_env, so --strict stays green in CI"
elif ((_ha_bad == 0)); then
  fail "helper adoption: audit-core.sh has no helper-adoption skip at all — the section is gone or renamed"
fi
# skip_env must actually EXIST and be the thing that records the class — otherwise the
# assertion above passes against a typo'd call that silently becomes an unbound command.
if grep -q '^skip_env()' "$HERE/scripts/lib/common.sh" && grep -q '_CORE_ENV_SKIPS' "$HERE/scripts/lib/common.sh"; then
  pass "helper adoption: skip_env is defined in common.sh and records the environment class"
else
  fail "helper adoption: skip_env is missing from common.sh — the sibling skips call nothing"
fi

# ── skip_env / _core_tool_skip_count: the classifier, as a unit ──────────────
# These drive _core_tool_skip_count ITSELF — the same function audit-core.sh calls. The
# previous version of this block re-implemented the classification loop inline, which meant it
# exercised its own copy and could never fail when audit-core.sh changed. It was demonstrated
# green while the defect it guarded was fully reintroduced in audit-core.sh. That is the whole
# reason the logic moved into common.sh: so a test can bind to the code that actually runs.
_tsc() { # <setup...> — run a scenario against the REAL helper, print its verdict
  CORE_JSON=1 bash -c '
    . "'"$HERE"'/scripts/lib/common.sh" 2>/dev/null || exit 9
    '"$1"'
    printf "%d %d %d" "$SKIP" "$(_core_tool_skip_count)" "${#_CORE_ENV_SKIPS[@]}"
  ' 2>/dev/null
}

# The happy partition: 1 tool, 1 scope, 2 environment.
_se_out="$(_tsc '
  skip     "luacheck (not installed)"
  skip     "nvim config load (out of scope)"
  skip_env "helper adoption (no sibling OS repo checked out — nothing to read here)"
  skip_env "coverage register (no sibling OS repo checked out — nothing to read here)"
')"
case "$_se_out" in
"4 1 2") pass "_core_tool_skip_count: 4 skips partition as 1 tool / 1 scope / 2 environment" ;;
"")      fail "_core_tool_skip_count: could not source scripts/lib/common.sh — the helper is unreachable" ;;
*)       fail "_core_tool_skip_count: partition is '$_se_out', want '4 1 2' (SKIP, tool, env) — --strict's meaning moved" ;;
esac

# THE POISONED-WORDING CASE — the one that was actually broken. An environment skip whose text
# contains "out of scope" must NOT cancel a genuine tool gap. Every call site in-tree is worded
# innocently, so only a test that supplies the poisoned wording can see this.
_pw_out="$(_tsc '
  skip     "luacheck (not installed)"
  skip_env "gitleaks policy (no sibling checked out — out of scope)"
')"
case "$_pw_out" in
"2 1 1") pass "_core_tool_skip_count: an env skip worded 'out of scope' does not cancel a real tool gap" ;;
*)       fail "_core_tool_skip_count: got '$_pw_out', want '2 1 1' — a poisoned env message masked an absent tool, so --strict goes green on a real gap" ;;
esac

# THE NOTE CLASS. A skip that reports an unassertable fact is NOT a coverage gap, so it must
# not be counted as an absent tool — otherwise `--strict` fails a fully-provisioned box purely
# because §9f is being honest about a PSReadLine default, and disagrees with
# `parity-check.sh --strict`, which accepts the same reported default.
_nt_out="$(_tsc '
  skip      "luacheck (not installed)"
  skip_env  "coverage register (no sibling OS repo checked out — nothing to read here)"
  skip_note "cross-shell parity: 2 pwsh half/halves are framework defaults — not asserted"
')"
case "$_nt_out" in
"3 1 1") pass "_core_tool_skip_count: a note skip is not an absent tool (--strict stays green on a full box)" ;;
*)       fail "_core_tool_skip_count: got '$_nt_out', want '3 1 1' — a reported framework default is being counted as a missing tool, so --strict fails a fully-provisioned box" ;;
esac
unset _nt_out

# And the binding for it: §9f must actually reach for the class, or the assertion above guards
# a call site that no longer exists.
if grep -q 'skip_note "cross-shell parity' "$HERE/scripts/audit-core.sh"; then
  pass "_core_tool_skip_count: §9f reports its framework-default halves as a NOTE, not a tool gap"
else
  fail "_core_tool_skip_count: §9f no longer uses skip_note — a Windows-present --strict run will fail on an honest report"
fi

# BINDING. The two assertions above are only worth anything if audit-core.sh actually uses the
# helper AND does not adjust the number afterwards. The demonstrated regression was precisely
# that shape: leave the classification correct, then re-add a subtracting statement after it.
_tb=0
_tb_asg="$(grep -c '^_tool_skips=' "$HERE/scripts/audit-core.sh" || true)"
[[ "$_tb_asg" == 1 ]] || {
  fail "binding: _tool_skips is assigned $_tb_asg times in audit-core.sh, want exactly 1 — a second assignment can undo a correct classification"
  _tb=1
}
grep -q '^_tool_skips="\$(_core_tool_skip_count)"' "$HERE/scripts/audit-core.sh" || {
  fail "binding: audit-core.sh does not take _tool_skips straight from _core_tool_skip_count — the tested helper is not the code that runs"
  _tb=1
}
grep -q '_tool_skips=\$((_tool_skips' "$HERE/scripts/audit-core.sh" && {
  fail "binding: audit-core.sh post-processes _tool_skips — this is the exact partial revert the helper was extracted to prevent"
  _tb=1
}
((_tb)) || pass "binding: audit-core.sh takes _tool_skips solely from _core_tool_skip_count, with no post-processing"

# ANCHORED to a statement that can REACH stdout, which is not the same as a line starting
# with `printf` — and that distinction is why the previous two versions of this block were
# VACUOUS. Every fleet report here is written `((${CORE_JSON:-0})) || printf …`, so it
# begins with `((`; a `/^[[:space:]]*printf/` scan matched nothing at all, iterated an empty
# list, and passed. It would have gone on passing with every guard stripped. Deriving the
# line range (the fix before this one) did not help, because the range was never the bug.
#
# So: every line in the fleet sections that runs a `printf` which is not redirected to
# stderr, EXCEPT one inside a `$( )` — §5g and §5f both compose report strings that way,
# and a string being built reaches stdout only through whatever prints it, which this scan
# sees separately. Then assert the scan is NON-EMPTY, because "matched nothing" is exactly
# how this test failed silently twice.
_jg_from="$(grep -n '^# ── 5f\.' "$HERE/scripts/audit-core.sh" | cut -d: -f1)"
_jg_to="$(grep -n '^# ── 5i\.' "$HERE/scripts/audit-core.sh" | cut -d: -f1)"
if [ -z "$_jg_from" ] || [ -z "$_jg_to" ]; then
  fail "--json: cannot locate the §5f→§5i fleet sections in audit-core.sh — the banners were renamed and this guard now covers nothing"
else
  _jg_bad=0
  _jg_seen=0
  while IFS= read -r _jg_line; do
    [ -n "$_jg_line" ] || continue
    _jg_seen=$((_jg_seen + 1))
    case "$_jg_line" in
    *CORE_JSON*) ;;
    *)
      fail "--json: an unguarded fleet-section printf breaks JSON-only stdout — $_jg_line"
      _jg_bad=1
      ;;
    esac
  done <<EOF
$(awk -v a="$_jg_from" -v b="$_jg_to" '
    NR>=a && NR<=b && /printf/ && !/>&2/ {
      if (match($0, /\$\([[:space:]]*printf/)) next
      printf "%d: %s\n", NR, $0
    }' "$HERE/scripts/audit-core.sh" 2>/dev/null || true)
EOF
  if ((_jg_seen == 0)); then
    fail "--json: the fleet-section scan matched NO printf at all — it is vacuous again, which is how it stayed green through two rewrites while protecting nothing"
  elif ((_jg_bad == 0)); then
    pass "--json: all $_jg_seen fleet-section stdout writes (§5f–§5i) are CORE_JSON-guarded"
  fi
fi
unset _jg_from _jg_to _jg_seen

# ── the adoption RATCHET: _core_helper_verdict, as a unit ───────────────────────
# What used to be here was a single assertion on the section's SOURCE TEXT — "audit-core.sh
# contains no `fail \"helper adoption`" — pinning the section as advisory by construction.
# That assertion was green for the whole life of the bug it should have caught. §5f measured
# `blib_user_bindirs_on_path 1/9` and printed it; the gap that fraction names was shipping a
# bootstrap that exited 2 on every openSUSE run, and a second repo carried the same probe
# masked by an apk-installed `go` (#748). "It never fails" was not a property worth pinning.
# It was the defect.
#
# So the section ratchets now, and what is pinned is the JUDGMENT — driven through the same
# helper audit-core.sh calls, not re-implemented here. That distinction is the lesson of
# _core_tool_skip_count directly above: a test that owns its own copy of the logic stays
# green while the shipped logic changes underneath it.
_hv() { CORE_JSON=1 bash -c '. "'"$HERE"'/scripts/lib/common.sh" 2>/dev/null || exit 9; _core_helper_verdict "$1" "$2"' _ "$1" "$2" 2>/dev/null; }
_hv_bad=0
# ledger=1 present=1 — the settled state.
[[ "$(_hv 1 1)" == ok ]] || { fail "_core_helper_verdict 1 1 = '$(_hv 1 1)', want 'ok' — a repo in good standing is being reported as something else"; _hv_bad=1; }
# ledger=1 present=0 — a repo DROPPED a helper it had. The one class the old counter could
# in principle have caught, and could not: the fraction would simply have read one lower.
[[ "$(_hv 1 0)" == regressed ]] || { fail "_core_helper_verdict 1 0 = '$(_hv 1 0)', want 'regressed' — a repo can now silently lose a bootstrap-lib helper"; _hv_bad=1; }
# ledger=0 present=1 — good news that must still fail, because recording it is the ONLY
# thing that ever tightens the ratchet. Let this pass and the ledger goes stale, every later
# regression reads as an unremarkable gap, and §5f is a counter again.
[[ "$(_hv 0 1)" == advanced ]] || { fail "_core_helper_verdict 0 1 = '$(_hv 0 1)', want 'advanced' — an unrecorded adoption leaves the ledger stale and the ratchet cannot tighten"; _hv_bad=1; }
# ledger=0 present=0 — the on-arrival state, and the one that must NOT fail: most of the
# fleet is short today and a gate that is red on arrival is a gate someone turns off.
[[ "$(_hv 0 0)" == gap ]] || { fail "_core_helper_verdict 0 0 = '$(_hv 0 0)', want 'gap' — an unclaimed gap would red the whole fleet on arrival"; _hv_bad=1; }
[[ "$(_hv 1 1)" == "" ]] && { fail "_core_helper_verdict: could not source scripts/lib/common.sh — the helper is unreachable"; _hv_bad=1; }
((_hv_bad)) || pass "_core_helper_verdict: ok / regressed / advanced / gap — both movements block, the standing gap does not"
unset _hv_bad

# BINDING. The unit above is worth nothing if §5f decides for itself. Assert it calls the
# helper, and that each verdict lands where the ratchet needs it: both movements on fail(),
# the standing gap on the advisory accumulator.
_hb=0
grep -q '_core_helper_verdict' "$HERE/scripts/audit-core.sh" || {
  fail "binding: audit-core.sh §5f does not call _core_helper_verdict — the tested judgment is not the code that runs"
  _hb=1
}
grep -q 'fail "helper adoption: .* no longer calls' "$HERE/scripts/audit-core.sh" || {
  fail "binding: §5f has no 'regressed' fail — a repo dropping a helper is back to being a silently smaller number"
  _hb=1
}
grep -q 'fail "helper adoption: .* and the ledger does not say so' "$HERE/scripts/audit-core.sh" || {
  fail "binding: §5f has no 'advanced' fail — nothing forces the ledger to be ratcheted, so it will go stale"
  _hb=1
}
grep -q 'gap) _ha_gaps=' "$HERE/scripts/audit-core.sh" || {
  fail "binding: §5f no longer routes a 'gap' to the advisory report — if it now fails, 8 of 9 repos red the fleet on arrival"
  _hb=1
}
((_hb)) || pass "binding: §5f judges through _core_helper_verdict and routes all four verdicts as the ratchet requires"
unset _hb

# THE LEDGER'S OWN INTEGRITY. Every repo named in it must be a real fleet entry. A typo
# ('dotfiles-Fedroa') is not a loud failure — it reads as "that repo has not adopted this",
# which is the quietest possible way for the ratchet to stop watching a repo.
_hl_bad=0
while IFS= read -r _hl_repo; do
  [ -n "$_hl_repo" ] || continue
  grep -qx "$_hl_repo" "$HERE/scripts/os-repos.txt" || {
    fail "§5f ledger names '$_hl_repo', which is not in scripts/os-repos.txt — a typo here reads as 'not adopted' and silently drops that repo from the ratchet"
    _hl_bad=1
  }
done <<EOF
$(sed -n '/^  _ha_ledger=/,/^'"'"'$/p' "$HERE/scripts/audit-core.sh" | grep -o 'dotfiles-[A-Za-z]*' | sort -u)
EOF
((_hl_bad)) || pass "§5f ledger: every repo it names is a real entry in scripts/os-repos.txt"
unset _hl_bad _hl_repo _ha_bad _ha_line

# ── _core_helper_called: a CALL, not a mention ──────────────────────────────────
# The ledger above is only as good as this predicate, and its first version was a bare
# `grep -q "$helper" bootstrap.sh`. An adoption PR's whole shape is "add the call, explain
# why in a comment" — so deleting the call and leaving the paragraph kept that grep green
# and reported `ok`, and the one regression the ledger exists to catch was invisible in
# exactly the files it had just been taught to watch. It was ALREADY inflating three rows
# before the ledger existed: dotfiles-MacBook credited with blib_note_fail and
# blib_failures_report from four comment lines, dotfiles-Fedora with blib_resolve_su from
# one. Fixtures, not a re-implementation — this drives the shipped predicate.
# Under $SANDBOX with an XXXXXX template — PORTABILITY.md bans a template-less `mktemp`
# (BSD requires one, and this suite runs on the macOS leg), and $SANDBOX is what the
# harness reaps, so a fixture that fails mid-block cannot leak a temp tree.
_hc_dir="$(mktemp -d "$SANDBOX/helpercall.XXXXXX")"
printf 'set -e\nblib_user_bindirs_on_path\n'                              >"$_hc_dir/call.sh"
printf 'set -e\n# blib_user_bindirs_on_path\n'                            >"$_hc_dir/commented.sh"
printf 'set -e\n  #   blib_user_bindirs_on_path — why we call it\n'       >"$_hc_dir/indented-comment.sh"
printf 'set -e\n# see blib_user_bindirs_on_path\nblib_wire_summary\n'     >"$_hc_dir/mention-only.sh"
printf 'set -e\nblib_note_fail_once "x"\n'                                >"$_hc_dir/longer-name.sh"
printf 'set -e\n((DRY)) && export BLIB_DRY=1\n'                           >"$_hc_dir/var.sh"
# Prose the USER sees, in both quote styles — not a call.
printf 'set -e\necho "run blib_user_bindirs_on_path first"\n'            >"$_hc_dir/dquote.sh"
printf "set -e\necho 'run blib_user_bindirs_on_path first'\n"              >"$_hc_dir/squote.sh"
# A usage() heredoc documenting the env var, with no code reference left. This shape is
# LIVE in dotfiles-Arch (`BLIB_DRY    set to 1 …`), which is why it earns a fixture.
printf 'set -e\nusage() {\n  cat <<EOF\nEnv overrides:\n  BLIB_DRY    set to 1 for a dry run\nEOF\n}\n' >"$_hc_dir/heredoc.sh"
# The same, with an indented terminator (<<-) and a quoted delimiter.
printf 'set -e\nusage() {\n\tcat <<-\x27EOF\x27\n\t  BLIB_DRY documented here\n\tEOF\n}\n' >"$_hc_dir/heredoc-dash.sh"
# A herestring and a comment marker that both LOOK like heredoc openers. dotfiles-Offense
# marks its usage block `# <<<USAGE`, and reading that as a heredoc swallowed the rest of
# the file — four adopted helpers reported absent.
printf 'set -e\n# <<<USAGE\ngrep -q x <<<"$y"\nblib_wire_summary\n'      >"$_hc_dir/herestring.sh"
# A PLAIN <<EOF whose body contains an indented delimiter-lookalike. Only <<- strips an
# indent from the terminator, and only tabs — trimming unconditionally ended the heredoc
# here and handed the rest of its prose to the matcher as executable code.
printf 'set -e\ncat <<EOF\n  EOF\nblib_user_bindirs_on_path documented here\nEOF\nblib_wire_summary\n' >"$_hc_dir/hd-indented-body.sh"
# Escaped quotes inside a double-quoted string: `s/"[^"]*"//g` matched the fragments AROUND
# the helper and left the token bare between them.
printf 'set -e\nprintf "run \\"blib_user_bindirs_on_path\\" first"\nblib_wire_summary\n' >"$_hc_dir/escaped-quote.sh"
# Multi-line strings — a quote that opens on one line and closes on another, whose interior
# line is a bare helper name. Line-local substitution could never see these.
printf 'set -e\necho "line one\nblib_user_bindirs_on_path\nline three"\nblib_wire_summary\n' >"$_hc_dir/multiline-dq.sh"
printf "set -e\necho 'line one\nblib_user_bindirs_on_path\nline three'\nblib_wire_summary\n" >"$_hc_dir/multiline-sq.sh"
_hc_bad=0
_hc() { # <fixture> <helper> <want 0|1> <why>
  local got=0
  _core_helper_called "$_hc_dir/$1" "$2" && got=1
  [[ "$got" == "$3" ]] || { fail "_core_helper_called $1 $2 = $got, want $3 — $4"; _hc_bad=1; }
}
_hc call.sh             blib_user_bindirs_on_path 1 "a bare call must count"
_hc commented.sh        blib_user_bindirs_on_path 0 "a commented-out call must NOT count — this is the regression the ledger exists to catch"
_hc indented-comment.sh blib_user_bindirs_on_path 0 "an indented prose comment must NOT count"
_hc mention-only.sh     blib_user_bindirs_on_path 0 "naming the helper in a comment while calling a DIFFERENT one must NOT count"
_hc longer-name.sh      blib_note_fail            0 "blib_note_fail_once must not satisfy the blib_note_fail row (whole-identifier match)"
_hc longer-name.sh      blib_note_fail_once       1 "the longer name must satisfy its own row"
_hc var.sh              BLIB_DRY                  1 "BLIB_DRY is a variable, not a function — a reference is adoption"
_hc missing.sh          BLIB_DRY                  0 "an unreadable file is not adoption"
_hc dquote.sh           blib_user_bindirs_on_path 0 "a helper named inside a double-quoted string is prose, not a call"
_hc squote.sh           blib_user_bindirs_on_path 0 "a helper named inside a single-quoted string is prose, not a call"
_hc heredoc.sh          BLIB_DRY                  0 "a usage() heredoc documenting the var is not a reference — the dotfiles-Arch shape"
_hc heredoc-dash.sh     BLIB_DRY                  0 "<<- with an indented, quoted terminator must be skipped too"
_hc herestring.sh       blib_wire_summary         1 "a '<<<' herestring and a '# <<<MARKER' comment must not be read as heredoc openers — that swallowed the rest of the file"
_hc hd-indented-body.sh blib_user_bindirs_on_path 0 "a plain <<EOF body may contain an indented 'EOF' line; only <<- strips an indent, and only tabs"
_hc escaped-quote.sh    blib_user_bindirs_on_path 0 "a helper between backslash-escaped quotes is still inside the string"
_hc multiline-dq.sh     blib_user_bindirs_on_path 0 "a multi-line double-quoted string is not code"
_hc multiline-sq.sh     blib_user_bindirs_on_path 0 "a multi-line single-quoted string is not code"
# Every construct above must also leave the scanner in sync: if a heredoc or a string
# swallowed the rest of the file, the call that FOLLOWS it would vanish too — which is the
# failure mode a fixture asserting only "the bypass is rejected" cannot tell apart from a
# scanner that stopped reading. Assert the tail survives, for each.
for _hc_f in hd-indented-body escaped-quote multiline-dq multiline-sq herestring; do
  _hc "$_hc_f.sh" blib_wire_summary 1 "the call AFTER the construct must still be seen — otherwise the scanner lost sync and swallowed the file"
done
unset _hc_f
# THE PIPEFAIL CASE, and it is not hypothetical: the first version of this predicate was
# `sed … | grep -q`, and `grep -q` exits on first match, SIGPIPEing sed, which under
# `set -o pipefail` — which audit-core.sh sets — makes the pipeline non-zero ON SUCCESS.
# Every adopted helper then read as "not called" and the ratchet failed the whole fleet.
# Run the predicate in a shell with pipefail on, the way the audit actually runs it.
_hc_pf="$(bash -c 'set -euo pipefail; . "'"$HERE"'/scripts/lib/common.sh" 2>/dev/null || exit 9
  _core_helper_called "'"$_hc_dir"'/call.sh" blib_user_bindirs_on_path && echo yes || echo no' 2>/dev/null)"
[[ "$_hc_pf" == yes ]] || { fail "_core_helper_called under 'set -o pipefail' says '$_hc_pf', want 'yes' — the SIGPIPE trap (#459) is back and the ratchet fails every repo that HAS adopted"; _hc_bad=1; }
((_hc_bad)) || pass "_core_helper_called: a call counts, a comment does not, a longer identifier does not, and it survives pipefail"
rm -rf "$_hc_dir"
unset _hc_dir _hc_bad _hc_pf

# BINDING: §5f must ask the predicate, not grep the file itself.
if grep -q '_core_helper_called "\$_ha_dir/bootstrap.sh" "\$_ha_h"' "$HERE/scripts/audit-core.sh"; then
  pass "binding: §5f tests adoption through _core_helper_called (comments cannot satisfy the ledger)"
else
  fail "binding: §5f no longer calls _core_helper_called — a bare grep counts a comment as a call, which is how a deleted helper stays invisible"
fi

hdr "git identity refuses to guess (useConfigOnly + a commented-out seed)"
# What a FRESHLY BOOTSTRAPPED box does when the user has not set an identity yet.
#
# The seeded ~/.config/git/local.gitconfig used to ship a live `Your Name
# <you@example.com>`, and gitconfig [include]s it — so the box had a VALID identity, commits
# succeeded, and they were authored as Your Name. Before bootstrap the same box had no
# identity and the commit would have failed loudly, so bootstrapping made the failure mode
# strictly worse; the result lands in public repo history, where authorship is not fixable
# retroactively (#476).
#
# Both halves are asserted because either alone is insufficient: with a live placeholder,
# useConfigOnly is satisfied and git commits; with it commented out but useConfigOnly unset,
# git invents $USER@$(hostname) and commits. Only the pair produces the error.
if have git; then
  _gi="$(mktemp -d "$SANDBOX/gitid.XXXXXX")"
  mkdir -p "$_gi/home/.config/git" "$_gi/repo"
  cp "$HERE/git/gitconfig" "$_gi/home/.gitconfig"
  # exactly what blib_seed does on a first bootstrap
  cp "$HERE/git/local.gitconfig.example" "$_gi/home/.config/git/local.gitconfig"
  # GIT_CONFIG_GLOBAL must be POINTED at the fixture's copy, not left to $HOME. This suite
  # exports GIT_CONFIG_GLOBAL=/dev/null suite-wide (so a developer's real signing config
  # cannot reach the tag-release fixtures), and that override wins over $HOME/.gitconfig
  # outright — git would read no global config at all here. The first draft of this block set
  # only HOME and passed two of its four assertions VACUOUSLY: with no config whatsoever there
  # is no identity, so "resolves no user.email" and "the commit fails" were both true for
  # entirely the wrong reason. HOME is still set because gitconfig's [include] path is written
  # as ~/.config/git/local.gitconfig and `~` is $HOME.
  _gi_git() {
    HOME="$_gi/home" XDG_CONFIG_HOME="$_gi/home/.config" \
      GIT_CONFIG_GLOBAL="$_gi/home/.gitconfig" git -C "$_gi/repo" "$@"
  }
  _gi_git init -q >/dev/null 2>&1
  printf 'x\n' >"$_gi/repo/a"
  _gi_git add a >/dev/null 2>&1

  # 1) the seed must not supply an identity. Asserted on the RESOLVED value rather than by
  #    grepping the example file: the whole defect was that the include made a commented-out
  #    line and a live one indistinguishable from where git stands.
  if [[ -z "$(_gi_git config --get user.email || true)" ]] &&
    [[ -z "$(_gi_git config --get user.name || true)" ]]; then
    pass "git identity: a freshly seeded box resolves NO user.name/user.email"
  else
    fail "git identity: the seed supplied an identity ($(_gi_git config --get user.name || true) <$(_gi_git config --get user.email || true)>)"
  fi
  # 2) useConfigOnly must be on, or git fills the gap with a guess instead of erroring.
  if [[ "$(_gi_git config --get user.useConfigOnly || true)" == "true" ]]; then
    pass "git identity: user.useConfigOnly is set, so git will not invent an author"
  else
    fail "git identity: useConfigOnly is not set — git would author as \$USER@\$(hostname)"
  fi
  # 3) THE property, end to end: the commit must FAIL, and its message must tell the user what
  #    to do. This is the assertion that catches the live-placeholder half — restoring the
  #    example's `name`/`email` makes it report `rc=0 — authored as Your Name
  #    <you@example.com>`, i.e. #476 verbatim. It does NOT discriminate on the useConfigOnly
  #    half on every box: where the hostname is not a FQDN git declines to guess an email and
  #    refuses anyway. That is exactly why assertion 2 checks the setting directly rather than
  #    relying on this one to cover both.
  _gi_out="$(_gi_git -c commit.gpgsign=false commit -m probe 2>&1)"
  _gi_rc=$?
  if ((_gi_rc != 0)) && grep -qi 'please tell me who you are' <<<"$_gi_out"; then
    pass "git identity: committing on an unconfigured box FAILS loudly, naming the fix"
  else
    fail "git identity: commit succeeded on an unconfigured box (rc=$_gi_rc) — authored as $(_gi_git log -1 --format='%an <%ae>' 2>/dev/null)"
  fi
  # 4) ...and filling the seed in must still work. useConfigOnly only refuses to GUESS; a
  #    configured identity has to keep working, or the fix would have traded one bug for a
  #    worse one.
  _gi_git config -f "$_gi/home/.config/git/local.gitconfig" user.name "Real Person" >/dev/null 2>&1
  _gi_git config -f "$_gi/home/.config/git/local.gitconfig" user.email "real@example.org" >/dev/null 2>&1
  if _gi_git -c commit.gpgsign=false commit -qm probe >/dev/null 2>&1 &&
    [[ "$(_gi_git log -1 --format='%an <%ae>' 2>/dev/null)" == "Real Person <real@example.org>" ]]; then
    pass "git identity: filling the seed in restores committing, with the real author"
  else
    fail "git identity: a filled-in local.gitconfig still could not commit"
  fi
  unset _gi _gi_out _gi_rc
else
  skip "git identity (git not installed)"
fi

hdr "blib_install_system_file (root-owned /etc write, non-destructive)"
# The system-file counterpart to the blib_link accounting above, and the same property:
# nothing that was already on the machine is destroyed unannounced. blib_link has had this
# since the beginning; `_blib_priv tee` into /etc never did, so each OS repo hand-rolled it
# and dotfiles-Arch did not — it re-rendered /etc/wsl.conf on every run of a script its docs
# call idempotent, and on a real box destroyed a pre-existing `[boot] systemd=true` (#475).
#
# BLIB_SU= throughout: the helper escalates through _blib_priv, and an empty BLIB_SU means
# "run directly". That is what makes this hermetic — it writes only under $SANDBOX and needs
# no sudo, so it runs identically in CI, in a container and on a developer box.
_sf="$(mktemp -d "$SANDBOX/sysfile.XXXXXX")"
# Same `bash -c` shape as _bl_run above, and for the same reason: the lib's re-entry guard
# makes a re-source a no-op, so the counters can only be read from a fresh interpreter.
_sf_run() { # <dry> <content> <dst>  → run output, then "--", then LINKED BACKED SKIPPED
  BLIB_DRY="$1" BLIB_SU='' bash -c '
    set -u
    . "'"$HERE/lib/bootstrap-lib.sh"'"
    blib_install_system_file "$1" "$2"
    printf -- "--\n%s %s %s\n" "$BLIB_LINKED" "$BLIB_BACKED" "$BLIB_SKIPPED"
  ' _ "$2" "$3" 2>&1
}
_sf_tally() { printf '%s' "${1##*$'--\n'}" | tr -d '\n'; }

# 1) THE #475 CASE, verbatim: a real pre-existing /etc/wsl.conf carrying systemd=true, and a
#    bootstrap that renders something else. The old content must survive on disk.
mkdir -p "$_sf/etc"
printf '[boot]\nsystemd=true\n' >"$_sf/etc/wsl.conf"
_sf_out="$(_sf_run 0 "$(printf '[interop]\nappendWindowsPath=false')" "$_sf/etc/wsl.conf")"
_sf_bak="$(find "$_sf/etc" -name 'wsl.conf.pre-dotfiles.*' 2>/dev/null | head -n1)"
if [[ -n "$_sf_bak" ]] && grep -q 'systemd=true' "$_sf_bak" &&
  grep -q 'appendWindowsPath=false' "$_sf/etc/wsl.conf" && [[ "$_sf_out" == *"backed up existing"* ]]; then
  pass "blib_install_system_file: an existing /etc file is preserved, announced, and replaced"
else
  fail "blib_install_system_file: the pre-existing file was not backed up (got: $_sf_out)"
fi
# The backup must be findable by the SAME convention as a dotfile backup — one naming rule
# for the whole system, which is the whole point of routing it through _blib_backup_suffix.
if [[ "${_sf_bak##*/}" =~ ^wsl\.conf\.pre-dotfiles\.[0-9]{8}-[0-9]{6}\.[0-9]+$ ]]; then
  pass "blib_install_system_file: the backup uses the shared .pre-dotfiles.<stamp>.<pid> name"
else
  fail "blib_install_system_file: backup name '${_sf_bak##*/}' is not the shared convention (#464)"
fi
# ...and it must be counted, or the closing summary would report a clean run over a displaced
# system file — the aggregate half of the same silence.
if [[ "$(_sf_tally "$_sf_out")" == "0 1 0" ]]; then
  pass "blib_install_system_file: a displaced system file counts into BLIB_BACKED"
else
  fail "blib_install_system_file: wrong tally '$(_sf_tally "$_sf_out")' (want LINKED=0 BACKED=1 SKIPPED=0)"
fi

# 2) IDEMPOTENCE, which is the property the helper is really for. A second run with the same
#    rendering must write nothing and back up nothing — otherwise a weekly re-bootstrap
#    accumulates a directory of identical .pre-dotfiles copies, which is its own damage.
_sf_n1="$(find "$_sf/etc" -name 'wsl.conf.pre-dotfiles.*' | wc -l | tr -d ' ')"
_sf_out="$(_sf_run 0 "$(printf '[interop]\nappendWindowsPath=false')" "$_sf/etc/wsl.conf")"
_sf_n2="$(find "$_sf/etc" -name 'wsl.conf.pre-dotfiles.*' | wc -l | tr -d ' ')"
if [[ "$_sf_n1" == "$_sf_n2" ]] && [[ "$(_sf_tally "$_sf_out")" == "0 0 1" ]] &&
  [[ "$_sf_out" != *"backed up"* ]]; then
  pass "blib_install_system_file: an identical re-run is a silent no-op (no second backup)"
else
  fail "blib_install_system_file: re-run was not a no-op (backups $_sf_n1 -> $_sf_n2, tally '$(_sf_tally "$_sf_out")')"
fi
# The same content rendered the way a bootstrap actually renders it — a heredoc, i.e. WITH a
# trailing newline. $(...) strips trailing newlines from what is read off disk but nothing
# strips them from the argument, so without the normalisation inside the helper this compares
# unequal to the file the helper itself just wrote and rewrites on EVERY run: the exact
# non-idempotence the helper exists to remove, reintroduced one layer up.
_sf_out="$(_sf_run 0 "$(printf '[interop]\nappendWindowsPath=false\n\n')" "$_sf/etc/wsl.conf")"
_sf_n3="$(find "$_sf/etc" -name 'wsl.conf.pre-dotfiles.*' | wc -l | tr -d ' ')"
if [[ "$_sf_n2" == "$_sf_n3" ]] && [[ "$(_sf_tally "$_sf_out")" == "0 0 1" ]]; then
  pass "blib_install_system_file: trailing newlines do not make a heredoc rendering look changed"
else
  fail "blib_install_system_file: trailing-newline difference triggered a rewrite (backups $_sf_n2 -> $_sf_n3)"
fi

# 3) an ABSENT destination is written, with no backup and nothing counted as displaced.
_sf_out="$(_sf_run 0 'key=value' "$_sf/etc/fresh.conf")"
if [[ "$(cat "$_sf/etc/fresh.conf" 2>/dev/null)" == "key=value" ]] &&
  [[ "$(_sf_tally "$_sf_out")" == "0 0 0" ]]; then
  pass "blib_install_system_file: an absent destination is created and nothing is counted"
else
  fail "blib_install_system_file: absent-destination write wrong (tally '$(_sf_tally "$_sf_out")')"
fi

# 4) BLIB_DRY must PLAN and touch nothing. Asserted on the file's bytes, not just the message:
#    a dry run that announced correctly and wrote anyway would satisfy a message-only check,
#    and this helper's whole audience is people who run --dry-run before letting it near /etc.
_sf_before="$(cat "$_sf/etc/wsl.conf")"
_sf_out="$(_sf_run 1 'totally different' "$_sf/etc/wsl.conf")"
_sf_n4="$(find "$_sf/etc" -name 'wsl.conf.pre-dotfiles.*' | wc -l | tr -d ' ')"
if [[ "$(cat "$_sf/etc/wsl.conf")" == "$_sf_before" ]] && [[ "$_sf_n3" == "$_sf_n4" ]] &&
  [[ "$_sf_out" == *"would back up + write"* ]] && [[ "$(_sf_tally "$_sf_out")" == "0 1 0" ]]; then
  pass "blib_install_system_file: BLIB_DRY plans the write and backup, and changes nothing"
else
  fail "blib_install_system_file: dry run mutated the box or did not announce (got: $_sf_out)"
fi

# 5) a missing destination argument must warn, not write somewhere surprising, and must not
#    take down a bootstrap running under `set -e`.
_sf_out="$(_sf_run 0 'content' '')"
if [[ "$_sf_out" == *"no destination given"* ]] && [[ "$(_sf_tally "$_sf_out")" == "0 0 0" ]]; then
  pass "blib_install_system_file: a missing destination warns and returns cleanly"
else
  fail "blib_install_system_file: missing destination mishandled (got: $_sf_out)"
fi

hdr "blib_link_os_layer ssh overlay (config.d drop-in, dry-run safe)"
# Local rather than scripts/test/34-link-run.sh's _lr_mode: that one is defined inside
# `if have git`, so it does
# not exist on a box without git, where this fixture still runs.
_ol_mode() { # <path> — octal permission bits, GNU or BSD stat (the macOS CI leg)
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
_ol_wire() { # run blib_link_os_layer against the fixture, honouring the caller's BLIB_DRY
  HOME="$_ol/home" XDG_CONFIG_HOME="$_ol/config" bash -c '
    set -u
    . "'"$HERE/lib/bootstrap-lib.sh"'"
    blib_link_os_layer "'"$_ol"'/repo" "'"$_ol"'/config" testos
  ' >/dev/null 2>&1
}
_ol="$(mktemp -d "$SANDBOX/oslayer.XXXXXX")"
mkdir -p "$_ol/home" "$_ol/config" "$_ol/repo/ssh"
printf 'Host *\n  IdentityAgent ~/.1password/agent.sock\n' >"$_ol/repo/ssh/os.conf"

# 1) --dry-run must touch NOTHING, not even the directory.
BLIB_DRY=1 _ol_wire
if [[ ! -e "$_ol/home/.ssh/config.d" ]]; then
  pass "os layer: --dry-run creates no ~/.ssh/config.d and links nothing"
else
  fail "os layer: --dry-run created ~/.ssh/config.d — the mkdir/chmod escaped the BLIB_DRY guard"
fi

# 2) the real run links it at the numbered drop-in path, with ssh's required 0700.
_ol_wire
_ol_bad=""
[[ -L "$_ol/home/.ssh/config.d/50-os.conf" ]] || _ol_bad="$_ol_bad link(missing)"
[[ "$(readlink "$_ol/home/.ssh/config.d/50-os.conf" 2>/dev/null)" == "$_ol/repo/ssh/os.conf" ]] ||
  _ol_bad="$_ol_bad link(wrong-target)"
[[ "$(_ol_mode "$_ol/home/.ssh/config.d")" == 700 ]] || _ol_bad="$_ol_bad config.d(perms)"
if [[ -z "$_ol_bad" ]]; then
  pass "os layer: ssh/os.conf links to ~/.ssh/config.d/50-os.conf with the dir at 0700"
else
  fail "os layer: ssh overlay wiring wrong —$_ol_bad"
fi

# 3) a repo WITHOUT one is the normal case, not a gap — no repo ships ssh/os.conf today,
#    so a version of this that linked unconditionally would break every one of them.
rm -f "$_ol/repo/ssh/os.conf"
rm -rf "$_ol/home/.ssh"
_ol_wire
if [[ ! -e "$_ol/home/.ssh/config.d/50-os.conf" ]]; then
  pass "os layer: no ssh/os.conf is a silent no-op (the case every repo is in today)"
else
  fail "os layer: linked a 50-os.conf with no source file"
fi


# ── blib_link_role_layer (lib/bootstrap-lib.sh) ──────────────────────────────
# The Role band (85-94) had no Core wiring for years, so BOTH role repos hand-rolled it
# and drifted: dotfiles-Defense honoured BLIB_DRY when dropping the stale pre-v4
# unnumbered link, dotfiles-Offense did not — so the same `--dry-run` mutated one box and
# not the other. That asymmetry is exactly what case 3 below pins.
#
# The other invariant worth a test is a NEGATIVE one: a role repo must never write band
# 80. That band belongs to the OS repo underneath it, and a role layer that claimed it
# would silently displace the OS layer's fragment on every bootstrap — a failure that
# looks like "my aliases vanished", three layers from its cause.
hdr "blib_link_role_layer (band 85 + tmux/role.conf, and never band 80)"
_rl="$(mktemp -d "$SANDBOX/rolelayer.XXXXXX")"
mkdir -p "$_rl/repo/offensive/templates"
printf 'ROLEZSH\n'  >"$_rl/repo/offensive/offensive.zsh"
printf 'ROLECONF\n' >"$_rl/repo/offensive/offensive.conf"
printf 'TPL\n'      >"$_rl/repo/offensive/templates/engagement.md"

# Fresh `bash -c` per case: the lib's re-entry guard makes a re-source a no-op, and these
# need BLIB_DRY / BLIB_SKIP read from a clean start. <dry> <skip-csv> <config-dir>.
_rl_run() {
  BLIB_DRY="$1" bash -c '
    set -u
    . "'"$HERE/lib/bootstrap-lib.sh"'"
    [ -n "$2" ] && blib_select --skip "$2"
    blib_link_role_layer "$1/repo" "$3" offensive
  ' _ "$_rl" "$2" "$3" 2>&1
}

# 1) the full wire: band 85, tmux/role.conf, and templates under <config>/<role>/.
_rl_c1="$_rl/cfg1"
_rl_out="$(_rl_run 0 "" "$_rl_c1")"
if [[ "$(readlink "$_rl_c1/zsh/85-offensive.zsh")" == "$_rl/repo/offensive/offensive.zsh" ]] &&
  [[ "$(readlink "$_rl_c1/tmux/role.conf")" == "$_rl/repo/offensive/offensive.conf" ]] &&
  [[ "$(readlink "$_rl_c1/offensive/templates")" == "$_rl/repo/offensive/templates" ]]; then
  pass "blib_link_role_layer: wires 85-<role>.zsh, tmux/role.conf and <role>/templates"
else
  fail "blib_link_role_layer: the role surface is not fully wired (got: $_rl_out)"
fi

# 2) it must NOT touch band 80 — that is the OS repo's, and this helper has no business
#    there even though the role fragment rides the same `zsh` group.
if [[ ! -e "$_rl_c1/zsh/80-os.zsh" ]]; then
  pass "blib_link_role_layer: leaves band 80 alone (the OS repo owns it)"
else
  fail "blib_link_role_layer: wrote band 80 — a role layer would displace the OS fragment"
fi

# 3) the stale pre-v4 unnumbered link. The v4 loader globs NN-*.zsh, so an unnumbered
#    <role>.zsh is INERT while still looking wired — it must be dropped on a real run and
#    SURVIVE a dry run. The second half is the drift this helper was written to end.
_rl_c3="$_rl/cfg3"
mkdir -p "$_rl_c3/zsh"
ln -sfn "$_rl/repo/offensive/offensive.zsh" "$_rl_c3/zsh/offensive.zsh"
_rl_out="$(_rl_run 1 "" "$_rl_c3")"
if [[ -L "$_rl_c3/zsh/offensive.zsh" ]] && [[ ! -e "$_rl_c3/zsh/85-offensive.zsh" ]] &&
  [[ "$_rl_out" == *"would drop stale pre-v4 link"* ]]; then
  pass "blib_link_role_layer: BLIB_DRY names the stale pre-v4 link and removes nothing"
else
  fail "blib_link_role_layer: dry-run mutated the box or hid the stale link (got: $_rl_out)"
fi
_rl_out="$(_rl_run 0 "" "$_rl_c3")"
if [[ ! -e "$_rl_c3/zsh/offensive.zsh" ]] &&
  [[ "$(readlink "$_rl_c3/zsh/85-offensive.zsh")" == "$_rl/repo/offensive/offensive.zsh" ]]; then
  pass "blib_link_role_layer: a real run drops the inert pre-v4 link and numbers the fragment"
else
  fail "blib_link_role_layer: the stale unnumbered link survived a real run (got: $_rl_out)"
fi

# 4) group gating, both directions in one pass: --skip tmux must drop role.conf WITHOUT
#    dropping the zsh fragment. A helper that ignored blib_want would wire both; one that
#    gated the whole function on a single group would wire neither.
_rl_c4="$_rl/cfg4"
_rl_out="$(_rl_run 0 tmux "$_rl_c4")"
if [[ ! -e "$_rl_c4/tmux/role.conf" ]] &&
  [[ "$(readlink "$_rl_c4/zsh/85-offensive.zsh")" == "$_rl/repo/offensive/offensive.zsh" ]]; then
  pass "blib_link_role_layer: --skip tmux drops role.conf and keeps the band-85 fragment"
else
  fail "blib_link_role_layer: --skip tmux gated the wrong half (got: $_rl_out)"
fi

# 5) <role> names the directory AND the stem, so a role with no .conf (dotfiles-Defense
#    ships none today) wires cleanly instead of leaving a dangling tmux/role.conf.
mkdir -p "$_rl/repo2/defense"
printf 'BLUE\n' >"$_rl/repo2/defense/defense.zsh"
_rl_c5="$_rl/cfg5"
_rl_out="$(BLIB_DRY=0 bash -c '
  set -u
  . "'"$HERE/lib/bootstrap-lib.sh"'"
  blib_link_role_layer "$1/repo2" "$2" defense
' _ "$_rl" "$_rl_c5" 2>&1)"
# -e AND -L, not -e alone: bash's -e follows the link, so it is FALSE for a dangling
# symlink — an -e-only assertion would pass on exactly the regression this test is named
# after. -L catches the dangling case, -e catches a real file or directory.
if [[ "$(readlink "$_rl_c5/zsh/85-defense.zsh")" == "$_rl/repo2/defense/defense.zsh" ]] &&
  [[ ! -e "$_rl_c5/tmux/role.conf" && ! -L "$_rl_c5/tmux/role.conf" ]]; then
  pass "blib_link_role_layer: a role with no .conf and no templates leaves no dangling role.conf"
else
  fail "blib_link_role_layer: the no-.conf role wired wrongly (got: $_rl_out)"
fi

# ── package-list reading (lib/bootstrap-lib.sh) ──────────────────────────────
# blib_read_pkgs had NO coverage, which is how #460 survived: it read its file with a bare
# redirect and no existence check, and every caller reaches it through a process
# substitution, where `mapfile` reports its OWN status rather than the reader's. A missing
# packages.txt therefore produced a zero-length array WITH A SUCCESS STATUS, and a broken
# clone provisioned nothing while reporting that as intended.
#
# blib_read_pkgs_into is the shape that actually fixes it — it assigns in the CALLER'S
# frame, so `|| exit 1` works. These pin both halves: the guard on the old function (loud
# even where the status is discarded) and the new function's status/assignment contract.
hdr "package-list reading (a missing list is a failure, not an empty array)"
_rp="$(mktemp -d "$SANDBOX/readpkgs.XXXXXX")"
printf 'foo # inline comment\n\n# whole-line comment\n  bar  \nbaz\n' >"$_rp/list.txt"
# A list whose LAST line is a comment — the common real shape, and the one that made the
# old `[[ -n "$line" ]] && printf …` tail return 1 from the loop.
printf 'pkg\n# trailing comment\n' >"$_rp/comment-final.txt"

# Fresh `bash -c` per case (the lib's re-entry guard makes a re-source a no-op at file
# scope). Prints the case's own verdict lines; the assertions match on those.
_rp_run() { bash -c '
  set -uo pipefail
  . "'"$HERE/scripts/lib/common.sh"'"
  . "'"$HERE/lib/bootstrap-lib.sh"'"
  '"$1"'
' 2>&1; }

# 1) THE BUG. An unreadable list must fail, loudly, and must not hand back a plausible
#    empty array. Both halves matter: the status is what a caller tests, the warning is
#    what an operator reads when the caller is the process-substitution form that cannot.
_rp_out="$(_rp_run '
  blib_read_pkgs_into pkgs /nonexistent/packages.txt && echo "STATUS=0" || echo "STATUS=$?"
  echo "SIZE=${#pkgs[@]}"
')"
if [[ "$_rp_out" == *"STATUS=1"* && "$_rp_out" == *"SIZE=0"* &&
  "$_rp_out" == *"not readable"* ]]; then
  pass "blib_read_pkgs_into: an unreadable list returns 1, warns, and yields no packages"
else
  fail "blib_read_pkgs_into: a missing list did not fail loudly (got: $_rp_out)"
fi

# 2) The happy path still parses exactly as before: inline comments, whole-line comments,
#    blank lines and surrounding whitespace all stripped.
_rp_out="$(_rp_run '
  blib_read_pkgs_into pkgs "'"$_rp"'/list.txt" || echo "STATUS=$?"
  echo "GOT=${#pkgs[@]}:${pkgs[*]}"
')"
if [[ "$_rp_out" == *"GOT=3:foo bar baz"* ]]; then
  pass "blib_read_pkgs_into: comments, blanks and whitespace are stripped into the array"
else
  fail "blib_read_pkgs_into: parsing drifted from blib_read_pkgs (got: $_rp_out)"
fi

# 3) The two readers must not disagree. CI and bootstrap both read the same file, and a
#    gate that parses it differently from the thing it gates is worse than no gate.
# core_files_identical, NOT diff — diffutils is not guaranteed present, and the Arch CI
# container is a box that genuinely lacks it. That is the same rule #572 records for `cmp`
# (they ship in the same package); the gate below now bans both.
_rp_out="$(_rp_run '
  blib_read_pkgs_into pkgs "'"$_rp"'/list.txt"
  blib_read_pkgs "'"$_rp"'/list.txt" >"'"$_rp"'/via-print.txt"
  printf "%s\n" "${pkgs[@]}" >"'"$_rp"'/via-array.txt"
  if core_files_identical "'"$_rp"'/via-print.txt" "'"$_rp"'/via-array.txt"; then
    echo AGREE
  else echo DIFFER; fi
')"
if [[ "$_rp_out" == *AGREE* ]]; then
  pass "blib_read_pkgs and blib_read_pkgs_into parse a list identically"
else
  fail "the two package-list readers disagree (got: $_rp_out)"
fi

# 4) A PROCESS SUBSTITUTION argument still works. dotfiles-Debian calls
#    `blib_read_pkgs <(pkg_filter_lines "$base_list" "$OS_ID")` to drop the lines annotated
#    for other distros, and that argument is a /dev/fd/N PIPE. This is why the guard is
#    `-r` and not `-f`: the obvious existence check would reject it and break a working
#    caller, turning a bug fix into an outage on one repo.
_rp_out="$(_rp_run '
  blib_read_pkgs_into pkgs <(printf "foo # c\n\nbar\n") || echo "STATUS=$?"
  echo "GOT=${#pkgs[@]}:${pkgs[*]}"
')"
if [[ "$_rp_out" == *"GOT=2:foo bar"* ]]; then
  pass "blib_read_pkgs_into: a /dev/fd process substitution is readable (the Debian shape)"
else
  fail "blib_read_pkgs_into: rejected a process substitution — -f crept back in (got: $_rp_out)"
fi

# 5) A failed read CLEARS the array rather than leaving the previous run's contents, so a
#    caller that ignores the status cannot silently install a stale list.
_rp_out="$(_rp_run '
  blib_read_pkgs_into pkgs "'"$_rp"'/list.txt"
  blib_read_pkgs_into pkgs /nonexistent 2>/dev/null
  echo "SIZE=${#pkgs[@]}"
')"
if [[ "$_rp_out" == *"SIZE=0"* ]]; then
  pass "blib_read_pkgs_into: a failed read empties the array (no stale package list)"
else
  fail "blib_read_pkgs_into: stale contents survived a failed read (got: $_rp_out)"
fi

# 6) The array NAME is spliced into an eval, so anything but a plain identifier must be
#    rejected before it gets there — this is a code-injection surface, not a typo check.
_rp_out="$(_rp_run '
  blib_read_pkgs_into "x;touch '"$_rp"'/PWNED" "'"$_rp"'/list.txt" && echo "STATUS=0" || echo "STATUS=$?"
  blib_read_pkgs_into "9lead" "'"$_rp"'/list.txt" 2>/dev/null && echo "D=0" || echo "D=$?"
')"
if [[ "$_rp_out" == *"STATUS=2"* && "$_rp_out" == *"D=2"* && ! -e "$_rp/PWNED" ]]; then
  pass "blib_read_pkgs_into: a malformed array name returns 2 and never reaches the eval"
else
  fail "blib_read_pkgs_into: a bad array name was not rejected (got: $_rp_out)"
fi

# 7) blib_read_pkgs' own status is now MEANINGFUL, so it has to be right in both
#    directions. The failure case is the point of #460; the success case is the
#    regression it could have introduced — the function used to end on
#    `[[ -n "$line" ]] && printf …`, so a list whose final line is a comment returned 1.
#    Harmless while every caller discarded the status, a landmine the moment one stops.
_rp_out="$(_rp_run '
  blib_read_pkgs "'"$_rp"'/comment-final.txt" >/dev/null && echo "OK=0" || echo "OK=$?"
  blib_read_pkgs /nonexistent >/dev/null 2>&1 && echo "MISS=0" || echo "MISS=$?"
')"
if [[ "$_rp_out" == *"OK=0"* && "$_rp_out" == *"MISS=1"* ]]; then
  pass "blib_read_pkgs: exits 0 on a comment-final list and 1 on a missing one"
else
  fail "blib_read_pkgs: status contract is wrong in one direction (got: $_rp_out)"
fi
