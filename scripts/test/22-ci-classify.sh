# scripts/test/22-ci-classify.sh
# content-gate file set, CI path classifier, PR link gate
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── content-gate file set (_audit_ls, scripts/lib/common.sh) ──────────────────
# The audit's content gates (bash -n, zsh -n, shellcheck, the pipefail scanner, toml/
# yaml/json) used to enumerate with a bare `git ls-files`, which lists ONLY tracked
# files. A brand-new script was therefore invisible until `git add`, and the gate still
# reported "all clean" — a green audit that had not read the file. That shipped: #496's
# scripts/ci-pr-link.sh passed a local 261/0 audit, then failed all four CI legs on two
# SC2016 violations. Pin the enumeration so the blind spot cannot come back.
#
# Driven in a THROWAWAY repo, not this one: asserting against the real checkout would
# depend on whatever happens to be untracked in the developer's tree, which is exactly
# the kind of ambient state that makes a test lie.
if have git; then
  hdr "content-gate file set (_audit_ls)"
  ALSREPO="$SANDBOX/audit-ls-repo"
  rm -rf "$ALSREPO"
  mkdir -p "$ALSREPO"
  git -C "$ALSREPO" init -q
  git -C "$ALSREPO" config user.email t@example.com
  git -C "$ALSREPO" config user.name tester
  printf 'ignored/\n' >"$ALSREPO/.gitignore"
  printf '#!/usr/bin/env bash\n:\n' >"$ALSREPO/tracked.sh"
  git -C "$ALSREPO" add -A
  git -C "$ALSREPO" commit -qm init
  # Created AFTER the commit: the exact state the bug was blind to.
  printf '#!/usr/bin/env bash\n:\n' >"$ALSREPO/untracked.sh"
  mkdir -p "$ALSREPO/ignored"
  printf '#!/usr/bin/env bash\n:\n' >"$ALSREPO/ignored/skipped.sh"
  _als_out="$(cd "$ALSREPO" && _audit_ls '*.sh')"
  _als_has() { # _als_has <label> <needle> <want:0|1>
    local n=0
    # Herestring, NOT `printf … | grep -qx`: that is the SIGPIPE shape §5d exists to
    # catch — grep exits on its first match, printf takes EPIPE, and pipefail reports
    # the pipeline as failed, which here would silently flip an assertion to false.
    # The list is small enough to fit the pipe buffer today, so it happens to work;
    # "happens to work" is exactly what this file should not rely on.
    grep -qx "$2" <<<"$_als_out" && n=1
    if ((n == $3)); then pass "$1"; else fail "$1 (got list: ${_als_out//$'\n'/ })"; fi
  }
  _als_has "_audit_ls includes a tracked script" 'tracked.sh' 1
  # THE REGRESSION GUARD: this is the assertion that would have failed before the fix.
  _als_has "_audit_ls includes an UNTRACKED script (the #496 blind spot)" 'untracked.sh' 1
  # --exclude-standard: a gitignored scratch script must not start failing anyone's audit.
  _als_has "_audit_ls excludes a gitignored script" 'ignored/skipped.sh' 0
  # Deduped: a tracked file must not be listed twice just because both probes ran.
  _als_n="$(printf '%s\n' "$_als_out" | grep -cx 'tracked.sh')"
  if [[ "$_als_n" == 1 ]]; then
    pass "_audit_ls does not double-list a tracked file"
  else
    fail "_audit_ls double-listed a tracked file ($_als_n times)"
  fi
  # The audit's CONTENT gates must all use _audit_ls; the GIT-STATE gates — the --changed
  # scope probe, manifest reverse-drift, and the index exec-bit check — must NOT.
  #
  # Manifest EXPANSION is deliberately absent from that list: it feeds §5c, which cat|greps
  # every file it names, so it is a content gate wearing manifest clothing and routes
  # through _audit_ls like the rest. It sat in this list while the implementation said
  # otherwise, which is how it got misfiled in the first place.
  #
  # Assert the split EXACTLY, in both directions. A floor (">= N helper calls") looks like
  # it guards this and does not: once seven calls exist, a NEW content gate can enumerate
  # with a bare `git ls-files` and the floor is still satisfied — the guard would sit green
  # through the reintroduction of the very bug it exists to prevent. Worse, a later helper
  # call could mask a regression elsewhere by keeping the total up.
  #
  # Exact counts are deliberately a tripwire: adding EITHER kind of enumeration fails here
  # until someone bumps the number, which is the moment to decide which side of the rule
  # the new gate belongs on. That decision is the whole point; a test that lets it be made
  # implicitly is not guarding anything.
  #
  # EVERY gate script that `make audit` consults, not just audit-core.sh. The first
  # version guarded one file, and the rule was quietly broken in three places outside it:
  # audit-core.sh's own manifest expansion (which feeds the §5c OS-path CONTENT scan and
  # merely looks like a manifest question), check-modern.sh's workflow inventory, and
  # nvim-reachability.sh's module inventory. A rule documented as universal but enforced
  # on one file is worse than no rule — it reads as covered.
  #
  # Count CALLS robustly: `_audit_ls '<glob>'`, `_audit_ls "$m"`, and `_audit_ls \` with
  # the pathspecs on the next line all count. Two earlier patterns here were too narrow
  # and undercounted exactly those forms. The definition line `_audit_ls() {` and comment
  # lines are excluded from both counts, so prose ABOUT either mechanism never trips it.
  _als_calls() { # _als_calls <file> → number of _audit_ls call sites
    grep -nE '(^|[^[:alnum:]_])_audit_ls([[:space:]]|$)' "$1" 2>/dev/null |
      grep -vE '^[0-9]+:[[:space:]]*#' | grep -vcE '_audit_ls\(\)'
  }
  _als_direct() { # _als_direct <file> → number of bare `git ls-files` sites
    grep -nE 'git ls-files' "$1" 2>/dev/null | grep -vcE '^[0-9]+:[[:space:]]*#'
  }
  # file:want_content:want_direct — exact on BOTH sides. A floor would stop guarding the
  # moment the count was met: a NEW content gate could use bare `git ls-files` and still
  # satisfy it. Exactness makes adding either kind of enumeration fail here until someone
  # picks a side, which is the decision this rule exists to force.
  # audit-core.sh 8→9 content calls: §5e (leaked RETURN trap) enumerates via _audit_ls.
  # It is a CONTENT gate — "is this file's text valid?" — so an untracked-but-not-ignored
  # script is in scope: a brand-new helper arming a leaked trap must be caught BEFORE it is
  # `git add`ed, not one round-trip later. That is the side of the rule this tripwire made
  # explicit, which is what it is for.
  #
  # 9→10: §5h (leftover conflict markers), same side and for the same reason. A marker is a
  # property of a file's TEXT, and the moment it most needs catching is before the commit
  # that would carry it onto main — which is precisely the untracked-but-not-ignored window
  # `_audit_ls` covers and bare `git ls-files` does not. Its pathspec is `*` rather than a
  # glob list because the defect that motivated it (#650) was in markdown, not in shell.
  #
  # 10→11: §5k (the bash 3.2 floor), same side again. It asks whether a file's TEXT uses a
  # construct the floor forbids, and the window that matters is before the commit: a new
  # helper written with `mapfile` should red on the author's machine, not survive until it is
  # `git add`ed and then cost a macos-latest leg seventeen minutes to report (#871, #874).
  # An untracked-but-not-ignored script is exactly the case, so `_audit_ls` is the side.
  #
  # DIRECT 3→5: §1b (routine reference integrity) takes bare `git ls-files` twice, and this
  # is the one gate where the choice is not a preference. It asks whether a file the
  # routines claim to read is SHIPPED — a pure "what does git record?" question — and the
  # defect it exists for (#700) was a file present on the author's disk and ignored by git.
  # `_audit_ls` includes untracked-but-not-ignored files, so using it here would wave that
  # exact file through while every clone stayed broken: the gate would be green precisely
  # on the machine where the bug is invisible. Both call sites are the same question — one
  # builds the tracked set to test membership against, the other picks the routine docs to
  # scan — so both take the git-state side.
  _als_expect="audit-core.sh:11:5 check-modern.sh:2:0 nvim-reachability.sh:2:0"
  _als_bad=""
  for _als_spec in $_als_expect; do
    _als_f="${_als_spec%%:*}"
    _als_rest="${_als_spec#*:}"
    _als_wc="${_als_rest%%:*}"
    _als_wd="${_als_rest##*:}"
    _als_gc="$(_als_calls "$HERE/scripts/$_als_f")"
    _als_gd="$(_als_direct "$HERE/scripts/$_als_f")"
    [[ "$_als_gc" == "$_als_wc" && "$_als_gd" == "$_als_wd" ]] ||
      _als_bad="${_als_bad}${_als_f} (got ${_als_gc}/${_als_gd}, want ${_als_wc}/${_als_wd}) "
  done
  if [[ -z "$_als_bad" ]]; then
    pass "enumeration split is exact across all three gate scripts (content via _audit_ls / git-state direct)"
  else
    fail "enumeration split changed: ${_als_bad}— a new enumeration must pick a side (content → _audit_ls, git-state → git ls-files), then update these counts"
  fi
fi

# ── CI path classifier (scripts/ci-classify.sh) ───────────────────────────────
# ci.yml's change-detection picks which gates run per push. That logic now lives in
# scripts/ci-classify.sh (pulled out of the workflow YAML so it can be linted + tested);
# this asserts the contract the workflow depends on: known paths map to the right gates,
# the __ALL__ sentinel runs everything, and — the regression that matters — an
# UNRECOGNISED top-level path FAILS CLOSED to the full run instead of silently skipping
# a gate on the nine-repo fan-out. Pure bash, so it runs even where zsh/nvim are absent.
hdr "CI path classifier (scripts/ci-classify.sh)"
CLASSIFY="$HERE/scripts/ci-classify.sh"
_classify_is() { # _classify_is <label> <newline-input> <want-shell> <want-nvim> <want-atuin>
  local got
  got="$(printf '%s\n' "$2" | "$CLASSIFY" 2>/dev/null)"
  if [[ "$got" == "shell=$3"$'\n'"nvim=$4"$'\n'"atuin=$5" ]]; then
    pass "$1"
  else
    fail "$1 (got: ${got//$'\n'/ }; want shell=$3 nvim=$4 atuin=$5)"
  fi
}
_classify_is "zsh/ change → shell gate only" 'zsh/05-ui.zsh' true false false
_classify_is "nvim/ change → nvim gate only" 'nvim/init.lua' false true false
_classify_is "docs (*.md) change → no gate" 'README.md' false false false
# The generated digest is 49 KB of markdown that changes on EVERY release (#680). It must
# not drag a full CI run along with it — it already matches the *.md inert arm, and this
# pins that so a future classifier tweak cannot quietly make every release a full run.
_classify_is "generated digest (CHANGELOG.recent.md) → no gate" 'CHANGELOG.recent.md' false false false
# Infra still forces shell AND nvim — it is genuinely cross-cutting, and a generator or the
# audit itself can rewrite or re-gate any shipped module. It no longer forces ATUIN: the
# detector's self-test is hermetic (stub `atuin`, a doctored SANDBOX copy of
# zsh/00-tools.zsh), so nothing outside the four paths in the arm above can move it. Every
# one of the last seven merges to main touched scripts/ and paid ~197s of atuin harness on
# all four legs for a gate it could not reach — the #699 leftover.
_classify_is "infra (scripts/) change → shell + nvim, NOT atuin" 'scripts/audit-core.sh' true true false
_classify_is "infra (.shellcheckrc) change → shell + nvim, NOT atuin" '.shellcheckrc' true true false
# ...and the four paths that CAN move it still force the full run. scripts/research/ is the
# script under test plus its lib; scripts/lib/ is the common.sh the fragments source;
# scripts/test/ and test-core.sh are the harness; ci-classify.sh is this file's own subject,
# which decides the scope and so must re-run everything.
_classify_is "scripts/research/ change → full run (the script under test, #687)" 'scripts/research/verify-atuin-guard.sh' true true true
_classify_is "scripts/research/lib/ change → full run (atuin-db.sh, the detector's own lib)" 'scripts/research/lib/atuin-db.sh' true true true
_classify_is "scripts/lib/ change → full run (common.sh, sourced by every fragment)" 'scripts/lib/common.sh' true true true
_classify_is "scripts/test/ change → full run (the harness that drives the detector)" 'scripts/test/51-atuin-guard.sh' true true true
_classify_is "scripts/test-core.sh change → full run (the dispatcher the fragments re-run)" 'scripts/test-core.sh' true true true
_classify_is "scripts/ci-classify.sh change → full run (it decides the scope)" 'scripts/ci-classify.sh' true true true
_classify_is "__ALL__ sentinel → full run" '__ALL__' true true true
_classify_is "unrecognised path → FAIL CLOSED to full run" 'newdir/thing.xyz' true true true
_classify_is "mixed shell+nvim set → union of both" $'zsh/05-ui.zsh\nnvim/init.lua' true true false
_classify_is "examples/ change → no gate (repo-meta, nothing links it)" 'examples/atuin-daemon.service' false false false
# The atuin axis. zsh/00-tools.zsh carries _core_atuin_daemon_guard — the thing the premise
# detector exists to protect — and atuin/ is its config, so both must reach the atuin gate
# AND the shell gate. The first of these is the ORDERING assertion: 00-tools.zsh also matches
# the general `zsh/*` arm, and since first match wins, an arm added in the wrong order would
# classify it as plain shell and silently stop running the detector's self-test on the one
# module that can break it.
_classify_is "zsh/00-tools.zsh change → shell AND atuin (guard's own module)" 'zsh/00-tools.zsh' true false true
_classify_is "atuin/ config change → shell AND atuin" 'atuin/config.toml' true false true
# tealdeer is a plain tools-group config: shell gate only. NOT the atuin axis — that one
# gates the premise detector's hermetic self-test and is kept narrow on purpose.
_classify_is "tealdeer/ config change → shell gate only" 'tealdeer/config.toml' true false false
# theme/ is a plain config tree whose consumers are zsh + tmux + starship + lazygit, so it
# rides the shell gate. NOT nvim: nvim's colours come from the tokyonight PLUGIN, which is
# gen-theme.sh --refresh's SOURCE, not one of its outputs — a palette edit cannot change
# what nvim renders. NOT atuin, for the reason the tealdeer row above records.
_classify_is "theme/ palette change → shell gate only (consumers are zsh+tmux+starship+lazygit)" 'theme/palette.toml' true false false
# The sharp case, and the reason the narrowing above needed checking rather than assuming.
# gen-theme.sh writes a generated block INTO zsh/00-tools.zsh (scripts/gen-theme.sh:210) —
# the module carrying _core_atuin_daemon_guard — so on paper it reaches the guard. It does
# not reach the guard's TEST: the atuin fragments stub `atuin` and doctor their own sandbox
# copy of that file, so the real tree is not an input to anything they assert. shell and
# nvim stay forced, because rewriting every consumer in one run is exactly what it does.
_classify_is "scripts/gen-theme.sh change → shell + nvim (it rewrites consumers), NOT atuin" 'scripts/gen-theme.sh' true true false
_classify_is "a plain zsh/ change does NOT pay the atuin gate" 'zsh/45-plugins.zsh' true false false
_classify_is "mixed atuin+nvim set → union across all three axes" $'atuin/config.toml\nnvim/init.lua' true true true

# ── the atuin arm is DERIVED, not hand-kept ──────────────────────────────────
# Narrowing scripts/* away from the atuin axis (#699 leftover) leaves one arm listing the
# paths that CAN still move the detector's self-test. A hand-kept list of exceptions inside
# a fail-closed gate is precisely what CONTRIBUTING says was deleted from audit §5c, and for
# the same reason: the day someone adds a dependency is the day nobody re-reads the arm.
#
# So the claim is checked instead of asserted. Read the atuin-scoped fragments, extract every
# repo path they actually reach for, and require ci-classify.sh to force atuin=true for each.
# A new `$HERE/scripts/…` dependency in either fragment reds THIS assertion, naming the path,
# until the arm covers it — which is the moment the arm needed editing.
_ac_frags=("$HERE/scripts/test/51-atuin-guard.sh" "$HERE/scripts/test/52-atuin-autostart.sh")
_ac_missing="" _ac_seen=0
for _ac_f in "${_ac_frags[@]}"; do
  [[ -r "$_ac_f" ]] || continue
  # `$HERE/scripts/...` in code, not in prose: require the sigil, and strip a trailing quote.
  while IFS= read -r _ac_dep; do
    [[ -n "$_ac_dep" ]] || continue
    _ac_seen=$((_ac_seen + 1))
    if [[ "$(printf '%s\n' "$_ac_dep" | "$CLASSIFY" 2>/dev/null | sed -n 's/^atuin=//p')" != true ]]; then
      _ac_missing="${_ac_missing:+$_ac_missing }$_ac_dep"
    fi
  done < <(grep -hoE '\$HERE/scripts/[A-Za-z0-9_./-]+' "$_ac_f" | sed 's|^\$HERE/||' | sort -u)
done
if ((_ac_seen == 0)); then
  fail "atuin arm: found no \$HERE/scripts/ dependency in either atuin fragment — the derivation stopped deriving, so this gate is now vacuous"
elif [[ -z "$_ac_missing" ]]; then
  pass "atuin arm: every scripts/ path the atuin fragments depend on ($_ac_seen) still forces atuin=true"
else
  fail "atuin arm: the atuin fragments depend on $_ac_missing, which ci-classify.sh no longer sends to the atuin gate — a change to it would skip the detector's self-test; widen the arm in scripts/ci-classify.sh"
fi
unset _ac_frags _ac_missing _ac_seen _ac_f _ac_dep

# ── PR link gate (scripts/ci-pr-link.sh) ──────────────────────────────────────
# #446 fixed #420 and #423 and merged green with NO closing keyword, so GitHub linked
# nothing and both issues sat open looking like live bugs. pr-link-check.yml now gates
# that, and the verdict logic lives in a script (like ci-classify.sh) precisely so it
# can be pinned here instead of rotting untested inside workflow YAML.
hdr "PR link gate (scripts/ci-pr-link.sh)"
PRLINK="$HERE/scripts/ci-pr-link.sh"
_prlink_is() { # _prlink_is <label> <title> <linked-count> <body> <want-verdict>
  local got rc want_rc
  got="$(printf '%s' "$4" | "$PRLINK" "$2" "$3" 2>/dev/null)"
  rc=$?
  # Assert the EXIT STATUS as well as the verdict line. The workflow enforces the policy
  # through the status, not the text — so a regression to `exit 0` on missing-link would
  # silently stop failing PRs while a stdout-only assertion stayed green. Checking both
  # pins the two together: missing-link is the only verdict that may exit non-zero.
  # Both blocking verdicts exit 1. They are NOT interchangeable: missing-link asserts
  # something about the PR, probe-failed asserts only that the API could not be reached
  # (#500). Same policy, different claim — so the tests pin the verdict token too, and a
  # regression that swapped one for the other would fail on the stdout comparison above.
  case "$5" in
  missing-link | probe-failed) want_rc=1 ;;
  *) want_rc=0 ;;
  esac
  if [[ "$got" == "verdict=$5" ]] && ((rc == want_rc)); then
    pass "$1"
  else
    fail "$1 (got: ${got:-<empty>} rc=$rc; want verdict=$5 rc=$want_rc)"
  fi
}
# The gated set: the delimiter-aware Conventional-Commit shape from
# scripts/gen-release-notes.sh:50 — optional (scope), optional breaking `!`, then the `:`.
# NOT cliff.toml:56, which groups on a broader bare `^fix` and would sweep in `fixup:`;
# the gate deliberately takes the stricter of the two.
_prlink_is "fix( PR with a linked issue → ok" 'fix(doctor): probe both names' 1 '' ok
_prlink_is "fix( PR with no link and no reason → missing-link" 'fix(doctor): probe both names' 0 '' missing-link
_prlink_is "unscoped fix: is gated too" 'fix: probe both names' 0 '' missing-link
_prlink_is "breaking fix!: is gated too" 'fix!: probe both names' 0 '' missing-link
_prlink_is "breaking scoped fix(x)!: is gated too" 'fix(doctor)!: probe both names' 0 '' missing-link
# feat( JOINED the gated set in #852: #853 resolved that issue in full, was titled
# feat(check), closed nothing, and left it open looking like a live defect. An issue does
# not know how the PR resolving it will be typed. All four shapes, like fix( above.
_prlink_is "feat( PR with a linked issue -> ok" 'feat(doctor): new panel' 1 '' ok
_prlink_is "feat( PR with no link and no reason -> missing-link" 'feat(doctor): new panel' 0 '' missing-link
_prlink_is "unscoped feat: is gated too" 'feat: new panel' 0 '' missing-link
_prlink_is "breaking feat!: is gated too" 'feat!: new panel' 0 '' missing-link
_prlink_is "breaking scoped feat(x)!: is gated too" 'feat(doctor)!: new panel' 0 '' missing-link
_prlink_is "No-Issue: exempts a feat( too" 'feat(x): y' 0 'No-Issue: scratch-built, never filed' exempt
# ...and the set STOPS there. These are mechanical PRs that close nothing by design;
# gating them would teach No-Issue: as a reflex, and a habitual escape hatch is a gate
# that has stopped working.
_prlink_is "chore( is not gated" 'chore(deps): bump actions' 0 '' not-gated
_prlink_is "a Core sync chore( is not gated" 'chore(core): sync Core -> v6.1.0' 0 '' not-gated
_prlink_is "a release docs( is not gated" 'docs(changelog): release v6.1.0' 0 '' not-gated
_prlink_is "refactor( is not gated" 'refactor(zsh): split the loader' 0 '' not-gated
# The delimiter rule holds for the new type as well: prose beginning with the word is not
# a Conventional-Commit type, and "feature:" is not "feat:".
_prlink_is "prose starting with feat is not gated" 'featuring a new panel' 0 '' not-gated
_prlink_is "feature: is not the feat type (delimiter, not prefix)" 'feature: new panel' 0 '' not-gated
# The delimiter is what separates a type from prose — without it, `fixup:` and an
# ordinary sentence would both be swept in, and authors would learn to distrust the gate.
_prlink_is "fixup: is not the fix type (delimiter, not prefix)" 'fixup: squash me' 0 '' not-gated
_prlink_is "prose starting with the word is not gated" 'fixing a flaky test' 0 '' not-gated
# The escape hatch, and its two failure modes.
_prlink_is "No-Issue: with a reason exempts" 'fix(x): y' 0 'No-Issue: found in one pass, never filed' exempt
_prlink_is "No-Issue: is case-insensitive and may be indented" 'fix(x): y' 0 '   no-issue: trivial typo' exempt
_prlink_is "bare No-Issue: with no reason does NOT exempt" 'fix(x): y' 0 'No-Issue:' missing-link
_prlink_is "no-issue: mid-prose does NOT exempt (line-anchored)" 'fix(x): y' 0 'there is no-issue: here' missing-link
# THE ONE THAT MATTERS. pull_request_template.md documents the marker inside an HTML
# comment; if the scan read the raw body, every unedited-template PR would exempt itself
# and the gate would ship dead — green and green look identical, so nothing would catch it.
_prlink_is "commented-out No-Issue: does NOT exempt (inline)" \
  'fix(x): y' 0 '<!-- No-Issue: <reason> if there is no issue -->' missing-link
_prlink_is "commented-out No-Issue: does NOT exempt (multi-line)" \
  'fix(x): y' 0 $'<!--\nNo-Issue: <reason>\n-->' missing-link
_prlink_is "a real marker after a comment still exempts" \
  'fix(x): y' 0 $'<!-- guidance -->\nNo-Issue: genuinely no issue' exempt
# ── An undeterminable count is NOT zero links (#500) ─────────────────────────────────
# The first version coerced a non-numeric count to 0, so a GitHub API blip produced
# `missing-link` and told the author their linked PR had no link. That happened for real:
# #499 links #498, and during a run of 503s the check failed it with "closes no issue and
# gives no reason" — false, and the kind of thing that teaches people to distrust a gate.
# It still BLOCKS (a broken probe must never silently open the gate), but the claim it
# makes is now true.
_prlink_is "an undeterminable count is probe-failed, NOT missing-link" \
  'fix(x): y' 'unknown' '' probe-failed
_prlink_is "an empty count (partial API response) is probe-failed too" \
  'fix(x): y' '' '' probe-failed
# The escape hatch is read from the body and needs no API call, so it must still work
# while the probe is down — blocking a PR that already carries its reason would be
# gratuitous, and the check has everything it needs to say yes.
_prlink_is "No-Issue: still exempts while the probe is down" \
  'fix(x): y' 'unknown' 'No-Issue: found in one pass' exempt
# An UNGATED PR is out of scope whatever the probe did. The example used to be
# 'feat(x): y', which #852 moved into the gated set — so it is now a chore(, and the
# assertion is unchanged: scope is decided before the probe's result is consulted.
_prlink_is "an ungated PR stays not-gated while the probe is down" \
  'chore(deps): bump actions' 'unknown' '' not-gated
# Usage error is its own exit code (2), distinct from a policy violation (1), so a
# workflow that miscalls the script reads as broken rather than as a failing PR.
# Asserted inline rather than via check(), which is zsh-only and defined further down.
"$PRLINK" 'only-one-arg' </dev/null >/dev/null 2>&1
if [[ $? -eq 2 ]]; then
  pass "ci-pr-link.sh exits 2 on usage error"
else
  fail "ci-pr-link.sh exits 2 on usage error"
fi
