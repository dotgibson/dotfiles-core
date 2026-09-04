# scripts/test/31-fleet-drift.sh
# fleet drift classifier (scripts/fleet-drift.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── fleet drift classifier (scripts/fleet-drift.sh) ───────────────────────────
# The sweep's verdict function had never been driven by a test. It flagged ANY recorded
# commit that wasn't byte-identical to the reference — but the reference DEFAULTS to the
# latest release tag while `make sync` fans out main's TIP, so every repo synced between
# releases was reported "AHEAD by N" and the sweep advised `make sync`, the one action that
# would push it further ahead (#371). The fix — ahead-of-tag but on main's lineage is
# CURRENT, ahead but off it is still drift — is pure git-reachability logic that shellcheck
# cannot see and that the real checkout cannot exercise (it needs a tag, commits past it, and
# an off-main commit, none of which may be created here). So build a throwaway Core: copy the
# script plus the two libs it sources into a sandbox repo root, git init a small history, and
# drive one fixture OS repo through every verdict by rewriting its core.lock.
if have git; then
  hdr "fleet drift classifier (scripts/fleet-drift.sh)"
  FDC="$SANDBOX/fdcore"    # the throwaway "Core" ($HERE, as fleet-drift.sh computes it)
  FDF="$SANDBOX/fdriftfleet"   # its fleet root (--root)
  rm -rf "$FDC" "$FDF"
  mkdir -p "$FDC/scripts/lib" "$FDC/lib" "$FDF/dotfiles-Test"
  cp "$HERE/scripts/fleet-drift.sh" "$FDC/scripts/"
  cp "$HERE/scripts/lib/common.sh" "$FDC/scripts/lib/"
  cp "$HERE/lib/ux.sh" "$FDC/lib/" # common.sh sources ../../lib/ux.sh
  printf 'dotfiles-Test\n' >"$FDC/scripts/os-repos.txt" # a one-repo fleet
  # Neutralise host git config: a global commit.gpgsign or init.defaultBranch must not reach
  # into the fixture (signing would block the commits; the branch name is load-bearing here).
  _fdg() { git -C "$FDC" -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t "$@"; }
  _fdc() { _fdg commit -q --allow-empty -m "$1"; }
  _fdg init -q >/dev/null 2>&1
  _fdg symbolic-ref HEAD refs/heads/main # not `init -b main` (needs git >= 2.28)
  _fdc c0; FD_OLD="$(_fdg rev-parse HEAD)"  # before the tag → genuinely stale
  _fdc c1; _fdg tag -a v1.0.0 -m v1.0.0     # ← becomes the default reference
  FD_REL="$(_fdg rev-parse 'v1.0.0^{commit}')"
  # FD_MID: on main and ahead of the tag, but NOT at main's tip — the stalled-fan-out shape,
  # which _classify rendered identically to FD_TIP before the behind-main clause existed.
  # Only the sha differs between the two rows, so together they isolate that clause alone.
  _fdc c2; FD_MID="$(_fdg rev-parse HEAD)"          # main, 1 past the tag, 1 behind the tip
  _fdc c3; FD_TIP="$(_fdg rev-parse HEAD)"          # main, 2 past the tag
  _fdg checkout -q -b feat v1.0.0
  _fdc f1; FD_OFF="$(_fdg rev-parse HEAD)"  # ahead of the tag but NOT on main
  _fdg checkout -q -b side "$FD_OLD"
  _fdc g1; FD_DIV="$(_fdg rev-parse HEAD)"  # behind AND ahead → diverged
  _fdg checkout -q main

  _fdd_lock() { printf '%s\n' "$@" >"$FDF/dotfiles-Test/core.lock"; }
  # -u CORE_JSON, for the same reason _sc_run and _tr_run strip it (#524/#508/#511): the
  # parent's --json EXPORTS CORE_JSON=1 so nested gates keep stdout clean for the JSON object,
  # common.sh's skip() then prints nothing, and fleet-drift.sh reports a not-checked-out repo
  # via exactly that skip() (fleet-drift.sh, the `else skip` arm of the NOT CHECKED OUT
  # branch). The assertions below grep for that line, so `test-core.sh --scope none --json`
  # reported fail:1 on a tree the identical non-JSON run passed clean. Third fixture bitten by
  # this, which is why the scan below now enforces the rule rather than trusting review.
  _fdd_run() { env -u CORE_JSON bash "$FDC/scripts/fleet-drift.sh" --root "$FDF" --color never 2>&1; }
  _fdd_is() { # _fdd_is <label> <want-rc> <status-regex>
    local out rc row
    out="$(_fdd_run)"; rc=$?
    row="$(grep 'dotfiles-Test' <<<"$out" | head -n1)"
    if [[ "$rc" == "$2" ]] && grep -qE "$3" <<<"$row"; then pass "$1"
    else fail "$1 (rc=$rc want=$2; row='$row')"; fi
  }

  _fdd_lock "core_sha=$FD_REL"
  _fdd_is "drift: sha identical to the reference tag is current" 0 'current *$'
  _fdd_lock "core_sha=$FD_OLD"
  # THE guard on the fix: tolerating AHEAD must not have tolerated real staleness.
  _fdd_is "drift: a sha behind the reference still FAILS" 1 'BEHIND by 1 commit'
  _fdd_lock "core_sha=$FD_TIP"
  # #371 itself — the fleet's ordinary between-releases state must be green.
  _fdd_is "drift: ahead of the tag but on main is current (#371)" 0 'current \(ahead of v1.0.0 by 2 commit\(s\), on main\)'
  # ...and the row must say how far it still is from main's TIP. `--is-ancestor` is reflexive
  # at both ends, so "on main" alone read identically for a repo synced this morning and one
  # synced five weeks ago — a stalled fan-out hid inside a green sweep (#381). REPORT-ONLY, so
  # the rc stays 0: this must add a number, never a verdict.
  _fdd_lock "core_sha=$FD_MID"
  _fdd_is "drift: ahead-of-tag but behind main's tip reports the lag and stays green" 0 \
    'current \(ahead of v1\.0\.0 by 1 commit\(s\), on main, 1 behind its tip\)'
  # At the tip the clause must VANISH, not read "0 behind its tip". The assertion above for
  # FD_TIP already enforces it (its regex ends `on main\)`), but only incidentally — name the
  # invariant, because it is the sole reason a finished row keeps its pre-#381 wording.
  _fdd_lock "core_sha=$FD_TIP"
  if ! grep -q 'behind its tip' <<<"$(_fdd_run)"; then
    pass "drift: a repo AT main's tip omits the behind-main clause"
  else fail "drift: behind-main clause printed for a repo already at main's tip"; fi
  _fdd_lock "core_sha=$FD_OFF"
  # ...and the tolerance must stay narrow: ahead off the released lineage is still drift.
  _fdd_is "drift: ahead of the tag but OFF main still FAILS" 1 'OFF-LINEAGE'
  _fdd_lock "core_sha=$FD_DIV"
  _fdd_is "drift: a diverged sha still FAILS" 1 'DIVERGED \(behind 1, ahead 1\)'
  _fdd_lock "core_tag=v1.0.0" # marker present, but no core_sha key
  _fdd_is "drift: a marker with no recorded sha FAILS" 1 'no provenance recorded'
  _fdd_lock "core_sha=$(printf '0%.0s' {1..40})" # a sha this clone has never seen
  _fdd_is "drift: an unknown sha degrades to DIFFERS, not a crash" 1 'DIFFERS'
  rm -f "$FDF/dotfiles-Test/core.lock"
  _fdd_is "drift: a missing core.lock FAILS" 1 'missing core.lock'

  # The header must name the RESOLVED REFERENCE (a tag), not the checkout's branch: the old
  # form printed "(main)" beside the tag's sha, which read as a comparison against main's tip.
  _fdd_lock "core_sha=$FD_REL"
  _fdd_hdr="$(_fdd_run | grep 'Fleet drift vs Core')"
  if [[ "$_fdd_hdr" == *"v1.0.0 (${FD_REL:0:12})"* ]]; then
    pass "drift: header names the resolved reference tag, not the current branch"
  else fail "drift: header is '$_fdd_hdr'"; fi

  # The closing advice must fit the verdict. `make sync` brings a LAGGING repo forward; it
  # would overwrite an off-lineage marker rather than reconcile it, so it must not be offered.
  _fdd_lock "core_sha=$FD_OLD"; _fdd_behind="$(_fdd_run)"
  _fdd_lock "core_sha=$FD_OFF"; _fdd_off="$(_fdd_run)"
  if grep -q "make sync" <<<"$_fdd_behind" && ! grep -q "make sync" <<<"$_fdd_off"; then
    pass "drift: 'make sync' is advised only for repos that actually lag"
  else fail "drift: remediation text does not match the verdict"; fi
  # An unstamped repo IS sync-fixable — but its branch returns before the verdict arm that
  # buckets the rest, so it needs its own assertion or the advice silently regresses.
  rm -f "$FDF/dotfiles-Test/core.lock"
  if grep -q "make sync" <<<"$(_fdd_run)"; then
    pass "drift: a missing marker is advised to re-sync"
  else fail "drift: a missing core.lock did not advise 'make sync'"; fi

  # The ahead-on-main state is GREEN but not FINISHED, so it must not render as a plain ✓ —
  # the whole reason it stopped being a failure is that the tally now carries the signal.
  _fdd_lock "core_sha=$FD_TIP"; _fdd_ahead="$(_fdd_run)"
  if grep -qE '^•.*current \(ahead of v1\.0\.0' <<<"$_fdd_ahead" &&
    grep -q '1 repo(s) carrying UNRELEASED Core' <<<"$_fdd_ahead"; then
    pass "drift: unreleased-Core rows render as a third state and are tallied"
  else fail "drift: third state not distinguished from a plain pass"; fi
  # ...and the tally must stay silent when the fleet really is pinned, or it becomes noise.
  _fdd_lock "core_sha=$FD_REL"
  if ! grep -q 'UNRELEASED Core' <<<"$(_fdd_run)"; then
    pass "drift: a fleet pinned to the tag reports no unreleased Core"
  else fail "drift: unreleased tally fired on a pinned fleet"; fi

  # An explicit --ref that doesn't resolve must be a usage error, not a silent fallback to
  # origin/main — the banner would otherwise name a ref that was never compared against.
  env -u CORE_JSON bash "$FDC/scripts/fleet-drift.sh" --root "$FDF" --ref nosuchref --color never >/dev/null 2>&1
  if [[ $? -eq 2 ]]; then pass "drift: an unresolvable --ref exits 2 instead of falling back"
  else fail "drift: unresolvable --ref did not exit 2"; fi

  # An unusable fleet list must STOP the sweep, not degrade to a hardcoded fleet (#669).
  # fleet-drift.sh used to carry an inline nine-name array for exactly this case, so an
  # unreadable os-repos.txt produced a full green sweep of a list nobody chose — a report
  # that looks like coverage and is not. Same exit 2 as any other usage error here.
  _fdd_fleet="$FDC/scripts/os-repos.txt"
  _fdd_body="$(cat "$_fdd_fleet")"
  _fdd_lock "core_sha=$FD_REL" # a state that WOULD sweep green, so only the load can red it
  for _fdd_case in absent empty; do
    case "$_fdd_case" in
    absent) rm -f "$_fdd_fleet" ;;
    empty) printf '# nothing but comments\n\n' >"$_fdd_fleet" ;;
    esac
    _fdd_out="$(_fdd_run)"
    _fdd_rc=$?
    if [[ $_fdd_rc -eq 2 ]] && grep -qE 'fleet list (unreadable|is empty)' <<<"$_fdd_out"; then
      pass "drift: an $_fdd_case fleet list exits 2 instead of sweeping a fallback fleet"
    else
      fail "drift: an $_fdd_case fleet list did not stop the sweep (rc=$_fdd_rc want=2)"
    fi
  done
  printf '%s\n' "$_fdd_body" >"$_fdd_fleet"
  unset _fdd_fleet _fdd_body _fdd_case _fdd_out _fdd_rc

  # --strict is documented to FAIL on a repo that isn't checked out. It printed red but
  # returned 0, so every caller read the run as clean. The root must EXIST and merely be
  # empty — a missing root is a separate usage error (exit 2) and would mask the regression.
  mkdir -p "$SANDBOX/fdempty"
  env -u CORE_JSON bash "$FDC/scripts/fleet-drift.sh" --root "$SANDBOX/fdempty" --strict --color never >/dev/null 2>&1
  _fdd_strict=$?
  env -u CORE_JSON bash "$FDC/scripts/fleet-drift.sh" --root "$SANDBOX/fdempty" --color never >/dev/null 2>&1
  _fdd_plain=$?
  if [[ $_fdd_strict -eq 1 && $_fdd_plain -eq 0 ]]; then
    pass "drift: --strict fails on a not-checked-out repo, plain mode still skips"
  else fail "drift: --strict exit code wrong (strict=$_fdd_strict plain=$_fdd_plain)"; fi

  # --- a repo RENAMED upstream, still cloned under its old directory name -------
  # The fleet is named by repo NAME (scripts/os-repos.txt) and every fleet script used to
  # turn that name into a path by string-joining it onto the root. So a box that cloned
  # dotfiles-Kali and never renamed the directory after it became dotfiles-Offense reported
  # "not checked out" for a repo sitting right there, fully vendored — a false CLEAN row on
  # the one sweep whose job is to notice staleness, and one `make sync` cannot repair.
  # resolve_repo_dir (scripts/lib/common.sh) falls back to origin's URL, which follows a
  # GitHub rename on its own. Assert the real verdict comes back, not the skip.
  mv "$FDF/dotfiles-Test" "$FDF/dotfiles-OldName"
  git -C "$FDF/dotfiles-OldName" init -q >/dev/null 2>&1
  git -C "$FDF/dotfiles-OldName" remote add origin https://github.com/dotgibson/dotfiles-Test.git
  _fdd_lock2() { printf '%s\n' "$@" >"$FDF/dotfiles-OldName/core.lock"; }
  _fdd_lock2 "core_sha=$FD_REL"
  _fdd_renamed="$(_fdd_run)"; _fdd_ren_rc=$?
  # Two halves, and both matter: the row must classify (proving the clone was FOUND) and it
  # must not still be reported as absent (proving the fallback replaced the skip rather than
  # printing alongside it).
  if ((_fdd_ren_rc == 0)) && grep -qE 'dotfiles-Test.*current' <<<"$_fdd_renamed" &&
    ! grep -qE 'dotfiles-Test.*not checked out' <<<"$_fdd_renamed"; then
    pass "drift: a repo cloned under its PRE-RENAME directory name is found via origin's URL"
  else
    fail "drift: renamed-clone lookup failed (rc=$_fdd_ren_rc; row='$(grep 'dotfiles-Test' <<<"$_fdd_renamed" | head -n1)')"
  fi
  # ...and --strict must not red it either: "NOT CHECKED OUT" is the one drift verdict that
  # sets DRIFT while `make sync` cannot clear it, so a false positive there is an
  # unactionable red build. Asserted on the ROW, not the exit code: fleet-drift.sh also
  # checks dotfiles-Windows unconditionally (line ~383, outside the os-repos loop) and this
  # one-repo fixture root has no such clone, so --strict exits 1 here no matter what the
  # dotfiles-Test row says. An rc assertion would pass for entirely the wrong reason.
  _fdd_strict_ren="$(env -u CORE_JSON bash "$FDC/scripts/fleet-drift.sh" --root "$FDF" --strict --color never 2>&1)"
  if grep -qE 'dotfiles-Test.*current' <<<"$_fdd_strict_ren" &&
    ! grep -qE 'dotfiles-Test.*NOT CHECKED OUT' <<<"$_fdd_strict_ren"; then
    pass "drift: --strict does not red a found-by-URL renamed clone"
  else
    fail "drift: --strict still reported the renamed clone as NOT CHECKED OUT"
  fi
  # An origin that points somewhere ELSE must NOT be adopted — the fallback has to identify
  # the repo, not merely find any clone lying around, or it would silently sync the wrong one.
  git -C "$FDF/dotfiles-OldName" remote set-url origin https://github.com/dotgibson/dotfiles-Unrelated.git
  if grep -qE 'dotfiles-Test.*not checked out' <<<"$(_fdd_run)"; then
    pass "drift: a clone whose origin names a DIFFERENT repo is not adopted"
  else fail "drift: the URL fallback adopted an unrelated repo"; fi
  # THE REGRESSION GATE for #511, same shape and same reason as the sync-core one above.
  # The assertion immediately above is the one that actually broke: it greps for the
  # not-checked-out line, fleet-drift.sh emits that line through skip(), and skip() is silent
  # when CORE_JSON is exported — so `test-core.sh --scope none --json` reported fail:1 on a
  # tree the identical non-JSON run passed clean. Reproduced on an unmodified checkout before
  # the fix. Drive the same fixture with CORE_JSON exported and require the identical verdict:
  # this fails loudly if anyone drops the `-u CORE_JSON` from _fdd_run.
  #
  # An explicit `export` in a subshell, not a `CORE_JSON=1 _fdd_run` prefix — the value must
  # genuinely be EXPORTED or `env -u` has nothing to strip and the gate passes vacuously.
  # shellcheck disable=SC2030,SC2031  # subshell-local by design — the export must NOT
  # outlive this command substitution, or it would silence every later section's skip()
  _fdd_json="$(
    export CORE_JSON=1
    _fdd_run
  )"
  if grep -qE 'dotfiles-Test.*not checked out' <<<"$_fdd_json"; then
    pass "drift: the fixture is insulated from an exported CORE_JSON (--json cannot change the verdict)"
  else
    fail "drift: an exported CORE_JSON silenced fleet-drift's skip() line — --json would red a green tree (#511)"
  fi
  # Restore the fixture: later legs assert on the plain directory, with no remote to find.
  rm -rf "$FDF/dotfiles-OldName/.git"
  mv "$FDF/dotfiles-OldName" "$FDF/dotfiles-Test"

  # Fail-CLOSED leg: with no mainline ref at all, an ahead-only marker is unverifiable and
  # must NOT be waved through as current. Last — it deletes the branch the fixture rides on.
  _fdg checkout -q --detach main
  _fdg branch -D main >/dev/null 2>&1
  _fdd_lock "core_sha=$FD_TIP"
  _fdd_is "drift: ahead with no mainline ref fails closed" 1 'no mainline ref'
else
  skip "fleet drift classifier (git unavailable)"
fi

