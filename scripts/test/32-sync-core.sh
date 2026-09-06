# scripts/test/32-sync-core.sh
# the fan-out (scripts/sync-core.sh) + the vendoring filter and its version switch
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── sync-core.sh — THE fan-out, on hermetic fixtures ─────────────────────────
# scripts/sync-core.sh is the highest-blast-radius script here: it gates on the audit,
# runs `git subtree pull` into nine working trees, and stamps core.lock. Until now it
# had NO coverage at all — its only proof was sync-fanout.yml running it for real
# against the live fleet, i.e. the fleet WAS the test.
#
# Everything below is a REFUSAL or an idempotency property. That matters for what these
# tests are worth: a broken guard does not throw, it fans a bad tree out to nine repos
# and reports success. So each case asserts the script DECLINED, and (where the guard is
# per-repo) that it declined without abandoning the repos after it.
#
# The fixture is a miniature of the real topology: `coreremote` is the origin every OS
# repo vendors from, `core` is the local checkout sync-core.sh runs out of ($HERE, as it
# computes from BASH_SOURCE), and `repos/` is REPOS_ROOT. audit-core.sh is STUBBED in the
# fixture so the audit gate can be driven both ways in-process — the real one cannot fail
# on demand.
# `git subtree` is a CONTRIB command, not part of core git: the Alpine/busybox image
# ships git without it, and Debian splits it into a separate git-subtree package. Every
# assertion below needs a real subtree add + pull, so probe for the command itself rather
# than assuming `have git` implies it — otherwise the fixture silently builds an OS repo
# with no core/ and half these tests fail for a reason that has nothing to do with
# sync-core.sh. Probing the exec-path is deterministic; `git subtree --help` can page.
_sc_subtree=0
if have git; then
  if [[ -x "$(git --exec-path 2>/dev/null)/git-subtree" ]] || have git-subtree; then _sc_subtree=1; fi
fi
if ((_sc_subtree)); then
  hdr "sync-core.sh fan-out guards (hermetic fixtures)"
  SCF="$SANDBOX/synccore"
  rm -rf "$SCF"
  mkdir -p "$SCF"
  # Host git config must not reach in: a global commit.gpgsign blocks every fixture
  # commit, and init.defaultBranch decides whether `main` even exists (load-bearing —
  # CORE_BRANCH defaults to main). Same neutralisation the fleet-drift fixture uses.
  _scg() { git -C "$1" -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t "${@:2}"; }
  # sync-core.sh runs `git subtree pull` and `git commit` INSIDE these fixtures with its
  # own argv — it never inherits the -c flags above. A CI runner has no global git
  # identity, so those commits abort with "Please tell me who you are" and the whole
  # fan-out silently produces no core.lock. (A developer machine hides this: the global
  # identity is already set, so it passes locally and fails only on CI.) Stamp the
  # identity into each fixture's LOCAL config so any git invocation inside it can commit.
  _sc_ident() {
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name t
    git -C "$1" config commit.gpgsign false
  }

  # 1) coreremote — the vendored origin. Carries the REAL sync-core.sh + the libs it
  #    sources, so the code under test is the shipped code, not a copy of its logic.
  mkdir -p "$SCF/coreremote/scripts/lib" "$SCF/coreremote/lib"
  cp "$HERE/scripts/sync-core.sh" "$SCF/coreremote/scripts/"
  # core-lock.sh too: sync-core.sh sources it for its post-fan-out assertion (#556), so
  # without this this whole fan-out block dies at `source` rather than failing an assertion.
  # core-vendor.sh for the same reason since #676 — sync-core.sh sources it directly for
  # core_vendor_materialize, and core-lock.sh sources it for the version switch.
  #
  # NOTE the fixture deliberately carries NO core.manifest and NO core.vendor. That makes
  # every commit in it take core_vendor_effective_tree's WHOLE-TREE branch — which is exactly
  # the pre-#676 fleet, so this whole block keeps asserting the migration path for free. The
  # FILTERED branch is asserted separately by the vendoring-filter arm below.
  cp "$HERE/scripts/lib/common.sh" "$HERE/scripts/lib/core-lock.sh" \
    "$HERE/scripts/lib/core-vendor.sh" "$SCF/coreremote/scripts/lib/"
  cp "$HERE/lib/ux.sh" "$HERE/lib/bootstrap-lib.sh" "$SCF/coreremote/lib/"
  printf '9.9.9\n' >"$SCF/coreremote/core.version"
  printf 'dotfiles-Test\ndotfiles-Other\ndotfiles-NotCloned\n' >"$SCF/coreremote/scripts/os-repos.txt"
  printf 'core payload v1\n' >"$SCF/coreremote/payload.txt"
  # The stub audit: exits with whatever $SCF/auditrc says, so a single file flips the
  # pre-fan-out gate between green and red without touching the script under test.
  # The stub also PUSHES TO CORE when $SCF/pushduring exists — which reproduces #556
  # exactly and deterministically: the tip moves strictly between sync-core.sh's up-front
  # `ls-remote` and its per-repo fetch, with no sleeps and no timing dependence. That is
  # the real-world shape (a PR merging while the ~250s pre-fan-out audit runs), and the
  # audit gate is the one place in the run guaranteed to sit inside that window.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ -s "%s/pushduring" ]; then\n' "$SCF"
    printf '  cat "%s/pushduring" > "%s/coreremote/payload.txt"\n' "$SCF" "$SCF"
    printf '  rm -f "%s/pushduring"\n' "$SCF"
    printf '  git -C "%s/coreremote" add -A\n' "$SCF"
    printf '  git -C "%s/coreremote" -c commit.gpgsign=false commit -q -m "core raced" >/dev/null 2>&1\n' "$SCF"
    printf 'fi\n'
    printf 'exit "$(cat "%s/auditrc" 2>/dev/null || echo 0)"\n' "$SCF"
  } >"$SCF/coreremote/scripts/audit-core.sh"
  chmod +x "$SCF/coreremote/scripts/audit-core.sh" "$SCF/coreremote/scripts/sync-core.sh"
  printf '0\n' >"$SCF/auditrc"
  _scg "$SCF/coreremote" init -q >/dev/null 2>&1
  _sc_ident "$SCF/coreremote"
  _scg "$SCF/coreremote" symbolic-ref HEAD refs/heads/main
  _scg "$SCF/coreremote" add -A
  _scg "$SCF/coreremote" commit -q -m "core c0"

  # 2) core — the local checkout sync-core.sh runs from. A clone, so HEAD == remote tip
  #    (the state the local-vs-remote guard demands).
  git -c commit.gpgsign=false clone -q "$SCF/coreremote" "$SCF/core" >/dev/null 2>&1
  _sc_ident "$SCF/core"
  _SCS="$SCF/core/scripts/sync-core.sh"

  # 3) the fleet. dotfiles-Test gets a real core/ subtree; the other two are the
  #    "not cloned" and "no core/ yet" shapes the loop must SKIP rather than fail.
  mkdir -p "$SCF/repos/dotfiles-Other" "$SCF/repos/dotfiles-NotCloned"
  _sc_new_osrepo() { # <name>  — a repo with a real core/ subtree sharing history
    local d="$SCF/repos/$1"
    mkdir -p "$d"
    _scg "$d" init -q >/dev/null 2>&1
    _sc_ident "$d"
    _scg "$d" symbolic-ref HEAD refs/heads/main
    printf 'os layer\n' >"$d/os.txt"
    _scg "$d" add -A
    _scg "$d" commit -q -m "os c0"
    _scg "$d" subtree add -q --prefix=core "$SCF/coreremote" main --squash >/dev/null 2>&1
  }
  _sc_new_osrepo dotfiles-Test
  _scg "$SCF/repos/dotfiles-Other" init -q >/dev/null 2>&1   # a git repo with NO core/
  _sc_ident "$SCF/repos/dotfiles-Other"
  _scg "$SCF/repos/dotfiles-Other" symbolic-ref HEAD refs/heads/main
  rm -rf "$SCF/repos/dotfiles-NotCloned/.git"                 # a dir that is not a repo

  _sc_run() { # run the fixture's sync-core.sh against the fixture fleet
    # -u CORE_JSON: --json EXPORTS CORE_JSON=1 so nested gates keep stdout clean for the
    # JSON object, and common.sh's skip() then prints nothing. The fixture inherits that
    # export, sync-core.sh reports absent / core/-less repos via skip(), and the assertions
    # below grep for exactly those lines — so `audit-core.sh --json` went red on a tree the
    # identical non-JSON run passed (#524). Same guard, same reason, as _tr_run below.
    env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never \
      REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main \
      SYNC_JOBS=1 "$@" bash "$_SCS" 2>&1
  }

  # --- the audit gate: the property that a RED tree must never fan out ---------
  # This is the single most important assertion in the file: every other guard protects
  # one repo, this one protects all nine. It must also refuse BEFORE mutating anything.
  printf '1\n' >"$SCF/auditrc"
  _sc_head_before="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  _sc_out="$(_sc_run)"; _sc_rc=$?
  if ((_sc_rc != 0)) && grep -q 'refusing to fan out a red tree' <<<"$_sc_out"; then
    pass "sync-core: a RED audit refuses the fan-out (rc=$_sc_rc)"
  else
    fail "sync-core: a red audit did NOT stop the fan-out (rc=$_sc_rc)"
  fi
  # ...and it refused BEFORE touching anything. HEAD alone is too weak a claim: a
  # regression that WROTE core.lock or staged a file before returning would leave HEAD
  # unchanged and still pass. Require the working tree to be clean as well.
  if [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" == "$_sc_head_before" ]] &&
    [[ -z "$(_scg "$SCF/repos/dotfiles-Test" status --porcelain)" ]]; then
    pass "sync-core: the red-audit refusal happens before any repo is mutated"
  else
    fail "sync-core: a repo was written to or moved despite the red-audit refusal"
  fi
  printf '0\n' >"$SCF/auditrc"

  # --- the local-vs-remote guard ----------------------------------------------
  # subtree pull fetches the REMOTE tip, but the audit above validated the LOCAL tree.
  # Advance the remote so the two disagree; the run must refuse rather than vendor a
  # commit nobody audited.
  printf 'core payload v2\n' >"$SCF/coreremote/payload.txt"
  _scg "$SCF/coreremote" commit -q -am "core c1"
  _sc_out="$(_sc_run)"; _sc_rc=$?
  if ((_sc_rc != 0)) && grep -q 'local HEAD' <<<"$_sc_out"; then
    pass "sync-core: local HEAD != remote tip refuses (audited tree != vendored tree)"
  else
    fail "sync-core: local/remote mismatch was not caught (rc=$_sc_rc)"
  fi
  _scg "$SCF/core" pull -q --ff-only >/dev/null 2>&1   # realign for the runs below

  # --- skip vs fail: an absent repo is not a failure ---------------------------
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
  # Both names appearing is not the property — they would still appear if either branch
  # were changed from skip() to err(). Assert the SUMMARY BUCKETS: two skipped, none
  # failed. That is the distinction that decides whether a missing clone reds a fan-out.
  if grep -q 'dotfiles-NotCloned' <<<"$_sc_out" && grep -qE 'dotfiles-Other.*no core/' <<<"$_sc_out" &&
    grep -qE 'skipped 2' <<<"$_sc_out" && grep -qE 'failed 0' <<<"$_sc_out"; then
    pass "sync-core: uncloned repo and core/-less repo land in the SKIPPED bucket, not failed"
  else
    fail "sync-core: absent/core-less repos not counted as skips (want skipped 2 / failed 0)"
  fi
  # THE REGRESSION GATE for #524, and the reason it is here rather than in a --json test:
  # the bug was invisible from inside a normal run. Both assertions above pass under a bare
  # `test-core.sh` and fail only when the parent was invoked with --json, so the suite
  # certified sync-core's bucketing while `audit-core.sh --json` reported the tree red.
  #
  # Drive the SAME fixture with CORE_JSON=1 exported — exactly what --json does — and require
  # the identical verdict. This fails loudly if anyone drops the `-u CORE_JSON` above, and it
  # costs one extra fixture run rather than a recursive audit.
  #
  # Asserted on the skip LINES, not just the summary counts: the counts are printed by
  # sync-core.sh's own printf and would survive a silenced skip(), so a count-only assertion
  # would go on passing through precisely this bug.
  # An explicit `export` inside a subshell, not a `CORE_JSON=1 _sc_run` prefix. The value must
  # genuinely be EXPORTED or `env -u` has nothing to strip and the gate passes vacuously; and a
  # prefix assignment on a FUNCTION call is the one form whose persistence bash and POSIX mode
  # disagree about, so it could leak CORE_JSON into every later section and silence their skips.
  # shellcheck disable=SC2030,SC2031  # subshell-local by design, as above
  _sc_out="$(
    export CORE_JSON=1
    _sc_run SYNC_SKIP_AUDIT=1
  )"
  if grep -q 'dotfiles-NotCloned' <<<"$_sc_out" && grep -qE 'dotfiles-Other.*no core/' <<<"$_sc_out" &&
    grep -qE 'skipped 2' <<<"$_sc_out" && grep -qE 'failed 0' <<<"$_sc_out"; then
    pass "sync-core: the fixture is insulated from an exported CORE_JSON (--json cannot change the verdict)"
  else
    fail "sync-core: an exported CORE_JSON silenced the fixture's skip() lines — --json would red a green tree (#524)"
  fi

  # --- dotfiles-Windows is never a target -------------------------------------
  # It vendors no core/ (its host layer is native PowerShell), so fanning into it would
  # be wrong, not merely useless. Since #669 the data file is the ONLY place it could be
  # wrongly added — the second clause here used to grep sync-core.sh's ALL_OS_REPOS array,
  # which no longer exists and would now pass vacuously. Assert the SHIPPED data file, not
  # the fixture's.
  if ! grep -qE '^[[:space:]]*dotfiles-Windows[[:space:]]*$' "$HERE/scripts/os-repos.txt"; then
    pass "sync-core: dotfiles-Windows is not in the fleet file"
  else
    fail "sync-core: dotfiles-Windows would be fanned into (it carries no core/ subtree)"
  fi

  # --- an unusable fleet list STOPS the fan-out, it does not degrade -----------
  # The whole point of #669. sync-core.sh used to fall back to a hardcoded nine-name array
  # when scripts/os-repos.txt was missing — the one moment nobody could see it — so a repo
  # registered in the file alone silently vanished from the fan-out. Now it exits 2 and
  # touches nothing. Driven for real rather than asserted by grep: a comment claiming the
  # script fails closed is exactly what the old fallback's comment also claimed.
  _sc_fleet_file="$SCF/core/scripts/os-repos.txt"
  _sc_fleet_body="$(cat "$_sc_fleet_file")"
  _sc_head_pre="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  for _sc_case in absent empty; do
    case "$_sc_case" in
    absent) rm -f "$_sc_fleet_file" ;;
    # Comments-only is the same hazard as absent and a far likelier edit slip: the reader
    # would yield zero names and the sweep would report a clean fleet of nobody.
    empty) printf '# every entry commented out\n\n' >"$_sc_fleet_file" ;;
    esac
    _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
    _sc_rc=$?
    if [[ "$_sc_rc" == 2 ]] && grep -qE 'fleet list (unreadable|is empty)' <<<"$_sc_out" &&
      [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" == "$_sc_head_pre" ]]; then
      pass "sync-core: an $_sc_case fleet list exits 2 and fans out into nothing"
    else
      fail "sync-core: an $_sc_case fleet list did not stop the fan-out (rc=$_sc_rc, want 2) — the maintain button degraded silently"
    fi
  done
  printf '%s\n' "$_sc_fleet_body" >"$_sc_fleet_file"

  # Naming targets on the CLI must NOT need the fleet list — the file describes the default
  # fan-out, not the argument parser, and coupling the two would make a broken data file
  # block the one-repo recovery sync you reach for to fix it.
  # Called directly, not through _sc_run: that helper appends its "$@" as env-var prefixes
  # BEFORE `bash`, so it cannot carry script arguments. --dry-run keeps this hermetic — the
  # fleet load happens during target selection either way, which is the thing under test.
  rm -f "$_sc_fleet_file"
  _sc_out="$(env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never \
    REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main SYNC_JOBS=1 \
    bash "$_SCS" --dry-run dotfiles-Test 2>&1)" || true
  if grep -q 'dotfiles-Test' <<<"$_sc_out" && ! grep -qE 'fleet list (unreadable|is empty)' <<<"$_sc_out"; then
    pass "sync-core: an explicitly named target still syncs with no fleet list present"
  else
    fail "sync-core: a named target was blocked by the missing fleet list it does not need"
  fi
  printf '%s\n' "$_sc_fleet_body" >"$_sc_fleet_file"
  unset _sc_fleet_file _sc_fleet_body _sc_head_pre _sc_case _sc_rc

  # --- the fleet list is the single source, and no copy has grown back ---------
  # This REPLACES the old four-way agreement assertion (#669). sync-core.sh, fleet-drift.sh
  # and core-integrity.sh each used to carry a hardcoded fallback array, and this suite
  # asserted the four agreed — a backstop for a design flaw rather than a fix. The arrays
  # are gone; what is worth policing now is that they stay gone, and that the one remaining
  # source is actually loadable. Three assertions, in that order.
  if load_os_repos; then
    pass "fleet list: scripts/os-repos.txt is readable and names ${#CORE_OS_REPOS[@]} repo(s)"
  else
    fail "fleet list: $CORE_OS_REPOS_ERR — every fleet script now hard-fails on this"
  fi

  for _fb_file in sync-core.sh fleet-drift.sh core-integrity.sh; do
    if grep -q 'load_os_repos' "$HERE/scripts/$_fb_file"; then
      pass "$_fb_file: reads the fleet through load_os_repos (lib/common.sh)"
    else
      fail "$_fb_file: no longer calls load_os_repos — it has its own fleet reader again"
    fi
    # Two fleet names on one line, comments stripped: the signature of a pasted-back array,
    # and it catches the `for r in a b c` shape as well as a `VAR=(…)` literal.
    # Deliberately not a bare `dotfiles-[A-Za-z]+` scan — sync-core.sh legitimately carries
    # the `dotfiles-*)` arg glob and a `dotfiles-Fedora` example, and a check that cannot
    # tell those from an array is a check nobody will keep. Usage lines are dropped too: an
    # example INVOKING the script ("sync-core.sh dotfiles-Fedora dotfiles-Arch") is prose
    # that happens to name two repos, and reporting it as a re-grown array would be a false
    # positive whose message actively misleads. Names may contain digits and further hyphens;
    # the old assertion's `^dotfiles-[A-Za-z]+$` would have silently dropped such a repo and
    # reported false DRIFT, so do not narrow this back.
    if sed -e 's/#.*//' -e "/$_fb_file/d" "$HERE/scripts/$_fb_file" |
      grep -qE 'dotfiles-[A-Za-z0-9-]+[[:space:]]+dotfiles-[A-Za-z0-9-]+'; then
      fail "$_fb_file: a hardcoded fleet list has grown back — scripts/os-repos.txt is the only source"
    else
      pass "$_fb_file: carries no hardcoded fleet list of its own"
    fi
  done
  unset _fb_file

  # --- --dry-run mutates nothing ----------------------------------------------
  _sc_head_before="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  # -u CORE_JSON for the same reason as _sc_run (#524). This call site does not currently
  # assert on skip() output, so it was not failing — but it is the identical trap one
  # assertion away, and a guard applied only where it already hurts is how this one got in.
  _sc_out="$(env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never REPOS_ROOT="$SCF/repos" \
    CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main SYNC_JOBS=1 bash "$_SCS" --dry-run 2>&1)"
  # 'would: materialize' since #587 — the plan line stopped naming `git subtree pull`
  # when the sync stopped BEING one. Matched on the verb rather than the whole line so
  # this pins "a plan was printed", not the sentence's punctuation.
  if grep -q 'would: materialize' <<<"$_sc_out" &&
    [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" == "$_sc_head_before" ]] &&
    [[ -z "$(_scg "$SCF/repos/dotfiles-Test" status --porcelain)" ]]; then
    pass "sync-core: --dry-run prints the plan and writes nothing"
  else
    fail "sync-core: --dry-run mutated the target or printed no plan"
  fi

  # --- the real pull: core.lock lands at the ROOT and records the full sha -----
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
  _sc_lock="$SCF/repos/dotfiles-Test/core.lock"
  _sc_remote_sha="$(_scg "$SCF/coreremote" rev-parse main)"
  if [[ -f "$_sc_lock" ]] && ! [[ -e "$SCF/repos/dotfiles-Test/core/core.lock" ]]; then
    pass "sync-core: core.lock is written at the repo ROOT (a subtree pull cannot clobber it)"
  else
    fail "sync-core: core.lock is missing or landed inside core/"
  fi
  if grep -q "^core_sha=$_sc_remote_sha\$" "$_sc_lock" &&
    grep -q '^core_version=9.9.9$' "$_sc_lock" && grep -q '^core_ref=main$' "$_sc_lock"; then
    pass "sync-core: core.lock records the FULL vendored sha, version and ref"
  else
    fail "sync-core: core.lock contents wrong ($(tr '\n' ' ' <"$_sc_lock"))"
  fi
  # The field must NOT be called core_branch any more (#453) — it was written from
  # $CORE_BRANCH, which sync-fanout.yml deliberately sets to a pinned SHA, so a field
  # documented as a branch held a commit and duplicated core_sha. Assert the old name is
  # gone rather than only that the new one is present: emitting BOTH would satisfy the
  # check above while leaving the contradicting field in every OS repo's lock file.
  if ! grep -q '^core_branch=' "$_sc_lock"; then
    pass "sync-core: core.lock no longer emits the mislabelled core_branch field"
  else
    fail "sync-core: core.lock still emits core_branch"
  fi
  # The tree must be CLEAN afterwards, or the dirty-tree guard blocks the next run —
  # the self-inflicted deadlock the core.lock commit exists to prevent.
  if [[ -z "$(_scg "$SCF/repos/dotfiles-Test" status --porcelain)" ]]; then
    pass "sync-core: the target tree is clean after a sync (next run is not self-blocked)"
  else
    fail "sync-core: sync left the target dirty — the next run would refuse it"
  fi

  # --- idempotency: re-syncing the same sha must not manufacture a commit ------
  _sc_head_before="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
  if grep -q 'core.lock current' <<<"$_sc_out" &&
    [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" == "$_sc_head_before" ]]; then
    pass "sync-core: re-syncing an unchanged sha is a no-op (no empty core.lock commit)"
  else
    fail "sync-core: a no-change re-sync still moved HEAD"
  fi

  # --- a sync must NOT depend on the subtree trailer surviving (#587) ------------
  # THE REGRESSION THIS EXISTS FOR, and it is not hypothetical: it took the v4.15.0
  # fan-out down in 9 repos out of 9, simultaneously.
  #
  # `git subtree pull --squash` finds its base by grepping history for the previous sync
  # commit's `git-subtree-split:` trailer. Every fleet repo SQUASH-merges its fan-out PR
  # (RELEASE-STRATEGY.md), and a squash keeps the original body only if it happens to be
  # carried over — so the trailer dies intermittently. Seven of nine repos had lost it
  # after the v4.14.3 round.
  #
  # The damage is not a missing marker, it is a WRONG BASE. Reproducing that needs TWO
  # prior syncs, not one: destroy the NEWEST trailer and subtree falls back to the one
  # before it, then replays both rounds of changes onto a tree that already contains the
  # first — so any file touched by BOTH rounds conflicts. That is why CHANGELOG.md and
  # core.version (which every release rewrites) were the two casualties in the real
  # failure, and why payload.txt is rewritten in both rounds here.
  #
  # Materializing the tree has no base and no trailer to lose.
  # 'v2-round2', NOT 'v2': the local-vs-remote guard section above already wrote the exact
  # bytes 'core payload v2' to this file and committed them, so re-writing them here staged
  # nothing and `commit -q` was a NO-OP. That cost two things. It printed git's "nothing to
  # commit, working tree clean" to STDOUT — where --json promises the JSON object and nothing
  # else, so the machine-readable mode this section's own sibling fixtures exist to protect
  # was itself unparseable. And it quietly hollowed out this fixture: with no round-2 commit
  # the remote never moved, so round 2's sync was a no-op too and the "TWO prior syncs" the
  # comment above insists on were only ever one. The content must differ from BOTH the value
  # already vendored and the v3 written below.
  printf 'core payload v2-round2\n' >"$SCF/coreremote/payload.txt"
  _scg "$SCF/coreremote" add -A >/dev/null 2>&1
  _scg "$SCF/coreremote" commit -q -m 'core: payload v2-round2'
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"   # round 2 — this is the sync whose trailer dies
  # Destroy the trailer the way a squash-merge does — from EVERY commit, not just HEAD.
  # Amending HEAD alone is not enough and quietly proves nothing: under the old
  # `subtree pull` a sync round produced TWO commits (the squash, then core.lock), so
  # amending HEAD rewrote the lock commit and left the subtree marker untouched. Stripping
  # the trailer repo-wide is both the honest reproduction (a fleet repo can lose it on any
  # round) and what makes the assertion below able to fail.
  FILTER_BRANCH_SQUELCH_WARNING=1 _scg "$SCF/repos/dotfiles-Test" \
    filter-branch -f --msg-filter 'sed "/^git-subtree-/d"' -- --all >/dev/null 2>&1
  if _scg "$SCF/repos/dotfiles-Test" log --format=%B | grep -q 'git-subtree-split'; then
    fail "sync-core (#587 fixture): could not destroy the trailer — the test below would prove nothing"
  else
    printf 'core payload v3\n' >"$SCF/coreremote/payload.txt"   # SAME file round 2 touched
    _scg "$SCF/coreremote" add -A >/dev/null 2>&1
    _scg "$SCF/coreremote" commit -q -m 'core: payload v3'
    _sc_v3_sha="$(_scg "$SCF/coreremote" rev-parse main)"
    _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"                        # round 3 — the one that broke
    _sc_587=""
    grep -qi 'conflict' <<<"$_sc_out" && _sc_587="$_sc_587 conflicted"
    grep -q 'failed 0' <<<"$_sc_out" || _sc_587="$_sc_587 repo-failed"
    # The payload must actually have moved — a sync that "succeeded" without updating the
    # tree would satisfy the two checks above and be exactly as broken.
    [[ "$(cat "$SCF/repos/dotfiles-Test/core/payload.txt" 2>/dev/null)" == 'core payload v3' ]] ||
      _sc_587="$_sc_587 payload-stale"
    grep -q "^core_sha=$_sc_v3_sha\$" "$_sc_lock" || _sc_587="$_sc_587 lock-stale"
    if [[ -z "$_sc_587" ]]; then
      pass "sync-core: a sync succeeds with the subtree trailer DESTROYED (#587 — the v4.15.0 fan-out failure)"
    else
      fail "sync-core: trailer-less sync regressed —$_sc_587"
    fi
    # And the tree must be clean afterwards, or the next run self-blocks on the dirty guard.
    if [[ -z "$(_scg "$SCF/repos/dotfiles-Test" status --porcelain)" ]]; then
      pass "sync-core: the trailer-less sync leaves a clean tree (one atomic commit)"
    else
      fail "sync-core: the trailer-less sync left the target dirty"
    fi
  fi

  # --- core_ref records the ref that was FOLLOWED, branch or pinned commit (#453) --
  # The bug this pins: sync-fanout.yml sets CORE_BRANCH="$target_sha" on purpose, so each
  # release PR vendors the exact released commit rather than a moving main — and the value
  # was then persisted into a field named, and documented, as a *branch*. Every OS repo's
  # lock file ended up with core_branch == core_sha: a contract violation, and a field
  # carrying no information core_sha did not already have.
  #
  # The run above covers the branch half (core_ref=main). This covers the half that was
  # actually wrong, by driving the script the way the fan-out drives it.
  _sc_pin_sha="$(_scg "$SCF/coreremote" rev-parse main)"
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1 CORE_BRANCH="$_sc_pin_sha")"
  if grep -q "^core_ref=$_sc_pin_sha\$" "$_sc_lock"; then
    pass "sync-core: a pinned-SHA sync records that commit as core_ref (the fan-out shape)"
  else
    fail "sync-core: core_ref did not record the pinned sha ($(grep '^core_ref=' "$_sc_lock" || echo absent))"
  fi

  # --- the dirty-tree guard, and that it does not abandon the rest of the fleet -
  # Ordering matters here: dotfiles-Test sorts BEFORE dotfiles-Other in the fixture fleet
  # file, so if a dirty first repo aborted the loop the second would never be reached.
  printf 'uncommitted\n' >"$SCF/repos/dotfiles-Test/dirty.txt"
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
  # Asserted on the ✗ line and the SUMMARY, deliberately NOT on $?. sync-core.sh exits
  # ZERO here: the failure branch prints "done with failures" to stderr but never sets a
  # status. That is load-bearing rather than an oversight to "fix" in passing —
  # sync-fanout.yml runs this under `bash -e` and then does its OWN per-repo
  # post-condition check, so a non-zero exit would abort that step and stop it opening PRs
  # for the repos that DID sync. Pinning the observable contract here keeps the test honest
  # about what the script actually promises; whether $? should also be non-zero is a design
  # call. That post-condition is now THREE assertions, not two — core.lock pins the released
  # sha, the branch is ≥1 commit ahead, and every dotgibson/dotfiles-core 40-hex pin in
  # .github/workflows/* equals the target (#484). The third was added because the first two
  # are both satisfied by a repo whose pin rewrite FAILED: err() flips it into the failed
  # bucket here, but that verdict cannot cross the exit-0 boundary, and core.lock is
  # deliberately committed anyway. The fan-out now checks the artefact rather than trusting
  # this script's report — which is what makes keeping exit 0 safe.
  if grep -q 'has uncommitted changes' <<<"$_sc_out" &&
    grep -qE 'failed 1' <<<"$_sc_out"; then
    pass "sync-core: a dirty target is refused and counted failed (not stashed, not force-merged)"
  else
    fail "sync-core: a dirty target was not refused/counted"
  fi
  if grep -q 'dotfiles-Other' <<<"$_sc_out"; then
    pass "sync-core: a dirty repo does not abandon the repos after it"
  else
    fail "sync-core: the fan-out stopped at the first dirty repo"
  fi
  rm -f "$SCF/repos/dotfiles-Test/dirty.txt"

  # --- the THIRD Core reference: reusable-workflow SHA pins (#482) -------------
  # A repo names the vendored Core in three places — the core/ subtree, core.lock, and the
  # `uses:` pins of any SHA-pinned reusable caller. The sync wrote two and left the third,
  # so a fan-out produced a tree that VENDORED one Core and RAN another, with both existing
  # the gate green (core-integrity compares a tree object and never reads a workflow). It reached production on the v4.12.0 fan-out and only surfaced because
  # dotfiles-MacBook had built its own pin gate.
  #
  # Tag the fixture Core first: the comment rewrite is driven by core.lock's core_tag, so
  # without a tag that half of the contract would go untested (and core_tag untested too).
  #
  # TWO tags on ONE commit, in release order, because that is the shape that broke (#515).
  # Every real cut writes the specific vX.Y.Z and then re-points the moving major alias, so
  # the alias is the NEWER tag — and a bare `git describe --tags` picks it. On v4.15.1 it did,
  # and all nine repos stamped `core_tag=v4`: a provenance field naming a target that moves on
  # the next release, which then became the `# v4` comment on every rewritten pin, i.e. a
  # Renovate bump target that never changes. Reproduced here: without the vX.Y.Z shape filter
  # in sync-core.sh, describe returns `v9` and both assertions below go red.
  _scg "$SCF/coreremote" tag -f v9.9.9 >/dev/null 2>&1
  _scg "$SCF/coreremote" tag -f v9 >/dev/null 2>&1
  _scg "$SCF/core" fetch -q --tags origin >/dev/null 2>&1
  _sc_remote_sha="$(_scg "$SCF/coreremote" rev-parse main)"
  _sc_oldsha=0123456789abcdef0123456789abcdef01234567
  _sc_wf="$SCF/repos/dotfiles-Test/.github/workflows"
  mkdir -p "$_sc_wf"
  # Four shapes: the first two must move, the last two must NOT.
  printf 'jobs:\n  t:\n    uses: dotgibson/dotfiles-core/.github/workflows/auto-tag-call.yml@%s # v9.0.0\n' \
    "$_sc_oldsha" >"$_sc_wf/pinned-with-comment.yml"
  printf 'jobs:\n  n:\n    uses: dotgibson/dotfiles-core/.github/workflows/notify-web-call.yml@%s\n' \
    "$_sc_oldsha" >"$_sc_wf/pinned-no-comment.yml"
  printf 'jobs:\n  l:\n    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v4\n' \
    >"$_sc_wf/mutable-alias.yml"
  printf 'jobs:\n  c:\n    uses: actions/checkout@%s # v4.2.2\n' \
    "$_sc_oldsha" >"$_sc_wf/third-party.yml"
  # ...and the nastier variant: a NON-Core reference already sitting at the exact sha we
  # are syncing to. A third-party action can be pinned there by coincidence and a FORK of
  # this repo by construction. The sha pass is scoped to the dotgibson/dotfiles-core
  # prefix, so it never moved these — but the comment pass was addressed on the bare sha
  # and rewrote their `# vX.Y.Z` to our tag, falsifying a version claim on someone else's
  # action. Two files: neither prefix matches, and their comments must survive verbatim.
  printf 'jobs:\n  s:\n    uses: someorg/someaction@%s # v1.2.3\n' \
    "$_sc_remote_sha" >"$_sc_wf/third-party-same-sha.yml"
  printf 'jobs:\n  k:\n    uses: someonelse/dotfiles-core/.github/workflows/lint-call.yml@%s # v9.0.0\n' \
    "$_sc_remote_sha" >"$_sc_wf/forked-core.yml"
  _scg "$SCF/repos/dotfiles-Test" add -A
  _scg "$SCF/repos/dotfiles-Test" commit -q -m "ci: pinned callers"
  _sc_head_before="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"

  if grep -q "@${_sc_remote_sha} # v9.9.9\$" "$_sc_wf/pinned-with-comment.yml"; then
    pass "sync-core: a SHA-pinned caller is repointed at the vendored Core, comment and all"
  else
    fail "sync-core: pinned caller not repointed ($(grep -o '@[^ ]*.*' "$_sc_wf/pinned-with-comment.yml"))"
  fi
  # The lock side of the same property. Asserted separately from the pin comment above
  # because the two can diverge: core_tag is written even by a repo that SHA-pins nothing,
  # and fleet-drift renders it as the RECORDED column, so `v9` here would make the fleet
  # dashboard answer "which Core?" with "9.x" for every repo (#515).
  if grep -q '^core_tag=v9\.9\.9$' "$_sc_lock"; then
    pass "sync-core: core.lock stamps the SPECIFIC release tag, not the moving major alias"
  else
    fail "sync-core: core.lock core_tag is '$(grep '^core_tag=' "$_sc_lock" || echo '(absent)')', want v9.9.9"
  fi
  # No comment in, no comment out: inventing one would hand Renovate a version claim the
  # repo never made.
  if grep -q "@${_sc_remote_sha}\$" "$_sc_wf/pinned-no-comment.yml"; then
    pass "sync-core: a pin with no version comment gets the sha moved and no comment invented"
  else
    fail "sync-core: comment-less pin mishandled ($(cat "$_sc_wf/pinned-no-comment.yml"))"
  fi
  # The two must-not-touch cases. `@v4` is a deliberate per-repo policy (8 of the 9 repos take
  # the moving alias); converting it to a SHA pin would change that repo's update model
  # behind its back. And a third-party action pinned to a sha with a `# vX.Y.Z` comment has
  # exactly the shape of our own pins — rewriting it would point actions/checkout at a
  # dotfiles-core commit, which is the worst outcome in this whole block.
  if grep -q '@v4$' "$_sc_wf/mutable-alias.yml"; then
    pass "sync-core: a caller on the mutable @v4 alias is left alone (policy is the repo's)"
  else
    fail "sync-core: the @v4 alias was rewritten into a SHA pin"
  fi
  if grep -q "actions/checkout@${_sc_oldsha} # v4.2.2\$" "$_sc_wf/third-party.yml"; then
    pass "sync-core: a third-party action pinned in the same shape is untouched"
  else
    fail "sync-core: a non-dotfiles-core action was rewritten ($(cat "$_sc_wf/third-party.yml"))"
  fi
  # The case the first version of this fixture missed: pinning the OLD sha made every
  # non-Core file trivially out of scope, so a comment pass addressed on the bare sha
  # looked correct. These two sit at the sha being synced TO.
  if grep -q "someorg/someaction@${_sc_remote_sha} # v1.2.3\$" "$_sc_wf/third-party-same-sha.yml" &&
    grep -q "someonelse/dotfiles-core/.github/workflows/lint-call.yml@${_sc_remote_sha} # v9.0.0\$" "$_sc_wf/forked-core.yml"; then
    pass "sync-core: a third-party action and a FORK already at the synced sha keep their own version comments"
  else
    fail "sync-core: a non-Core reference at the synced sha had its version comment rewritten"
  fi
  # The pins must land in the SAME commit as core.lock: landing them apart leaves a window
  # where the repo's own pin gate is red on main.
  if [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" != "$_sc_head_before" ]] &&
    [[ -z "$(_scg "$SCF/repos/dotfiles-Test" status --porcelain)" ]] &&
    _scg "$SCF/repos/dotfiles-Test" show --stat --oneline HEAD | grep -q 'core.lock' &&
    _scg "$SCF/repos/dotfiles-Test" show --stat --oneline HEAD | grep -q 'pinned-with-comment.yml'; then
    pass "sync-core: pins and core.lock land in ONE commit, leaving the tree clean"
  else
    fail "sync-core: pins/core.lock were not committed together (or left the tree dirty)"
  fi
  # The regression the staged-wide check exists for: core.lock is now current, so a
  # core.lock-scoped idempotency test would report "current" and silently skip a stale pin.
  sed -i.bak "s|@${_sc_remote_sha}|@${_sc_oldsha}|" "$_sc_wf/pinned-with-comment.yml"
  rm -f "$_sc_wf/pinned-with-comment.yml.bak"
  _scg "$SCF/repos/dotfiles-Test" commit -q -a -m "ci: regress the pin"
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
  if grep -q "@${_sc_remote_sha} # v9.9.9\$" "$_sc_wf/pinned-with-comment.yml"; then
    pass "sync-core: a stale pin is fixed even when core.lock is already current"
  else
    fail "sync-core: stale pin left behind because core.lock needed no change"
  fi
  # ...and re-syncing an already-correct repo still manufactures nothing.
  _sc_head_before="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
  if [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" == "$_sc_head_before" ]]; then
    pass "sync-core: a repo whose pins and core.lock are both current gets no empty commit"
  else
    fail "sync-core: an already-correct repo still produced a commit"
  fi
  # A rewrite that CANNOT run must fail the repo, not read as "no pins here". Swallowed,
  # it would let the run commit core.lock and report the repo synced while a caller still
  # pointed at the previous Core — this fix's own error path recreating the drift it
  # exists to end. Root ignores the mode bits, so the CI legs that run as root skip it
  # rather than assert a property they cannot create.
  if [[ "$(id -u)" -ne 0 ]]; then
    chmod a-w "$_sc_wf"
    _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
    chmod u+w "$_sc_wf"
    if grep -q 'pin rewrite failed' <<<"$_sc_out" && grep -qE 'failed 1' <<<"$_sc_out"; then
      pass "sync-core: an unwritable workflow fails the repo instead of reading as 'no pins'"
    else
      fail "sync-core: a pin-rewrite failure was swallowed (want the named file and failed 1)"
    fi
  else
    skip "sync-core: unwritable-workflow case (suite is running as root)"
  fi

  # ── #556: a push to Core DURING the run must not desync core/ from core.lock ──
  # sync-core.sh resolves the tip once up front, then audits (~250s on a real fleet), then
  # vendors. It used to re-resolve the BRANCH at vendor time, so a push inside that window
  # gave core/ the new tree while core.lock recorded the old sha. `make core-integrity`
  # then reported TAMPERED (core/ edited since sync) — for a tree nobody hand-edited,
  # which is the part that cost the most time to diagnose. Observed three times in one
  # afternoon on a normally-active day.
  #
  # Note the local-HEAD guard cannot see this: $SCF/core is still at the pre-push tip, so
  # it agrees with the up-front resolution. That is exactly why the bug shipped.
  _sc_race_n=0
  _sc_race_check() { # _sc_race_check <label-suffix> [ENV=VAL ...]  — extra env goes to _sc_run
    local want_sha want_tree got_tree locked payload trailer pre token
    _scg "$SCF/core" pull -q --ff-only >/dev/null 2>&1 || true
    want_sha="$(_scg "$SCF/coreremote" rev-parse HEAD)"
    # Through the shared lib, not a bare rev-parse: since #676 "the tree this sha should
    # produce" is core_vendor_effective_tree's answer, and a test that hardcodes ^{tree}
    # would keep passing while the thing it claims to check had changed meaning.
    # shellcheck source=scripts/lib/core-vendor.sh
    source "$HERE/scripts/lib/core-vendor.sh"
    want_tree="$(core_vendor_effective_tree "$SCF/coreremote" "$want_sha")"
    # The payload as it stands BEFORE this race — that is what must end up vendored. A
    # fixed marker string will not do: the previous case's race commit becomes this one's
    # baseline, so the second run would compare a value against itself and pass vacuously
    # while no race had actually occurred.
    pre="$(cat "$SCF/coreremote/payload.txt")"
    _sc_race_n=$((_sc_race_n + 1))
    token="core payload RACED-$_sc_race_n"
    printf '0\n' >"$SCF/auditrc"   # ensure the gate is green for this run
    printf '%s\n' "$token" >"$SCF/pushduring"
    _sc_out="$(_sc_run "${@:2}")"; _sc_rc=$?
    payload="$(cat "$SCF/repos/dotfiles-Test/core/payload.txt" 2>/dev/null || echo MISSING)"
    locked="$(sed -n 's/^core_sha=//p' "$SCF/repos/dotfiles-Test/core.lock" 2>/dev/null)"
    got_tree="$(_scg "$SCF/repos/dotfiles-Test" rev-parse 'HEAD:core')"
    trailer="$(_scg "$SCF/repos/dotfiles-Test" log -1 --format=%B | sed -n 's/^git-subtree-split: //p')"

    if [[ "$payload" == "$pre" ]] && [[ "$payload" != *"$token"* ]] \
      && [[ "$locked" == "$want_sha" ]] \
      && [[ "$got_tree" == "$want_tree" ]] && grep -qE 'failed 0' <<<"$_sc_out"; then
      pass "sync-core: a push to Core during the audit does not desync core/ from core.lock ($1)"
    else
      fail "sync-core: #556 race — core/ and core.lock disagree ($1)"
      printf '    payload=%s\n    expected=%s\n    raced-in=%s\n    locked=%s want=%s\n    tree=%s want=%s\n' \
        "$payload" "$pre" "$token" "${locked:0:12}" "${want_sha:0:12}" \
        "${got_tree:0:12}" "${want_tree:0:12}" >&2
    fi
    # The subtree trailer is a THIRD artefact stamped from the same snapshot; consumer
    # tooling (dotfiles-MacBook's verify-core) warns when it disagrees with the lock.
    if [[ "$trailer" == "$want_sha" || -z "$trailer" ]]; then
      pass "sync-core: the git-subtree-split trailer names the vendored commit ($1)"
    else
      fail "sync-core: trailer ${trailer:0:12} != vendored ${want_sha:0:12} ($1)"
    fi
    # The assertion must have RUN and been GREEN — otherwise everything above could hold
    # while the guard itself is dead code that would never catch a future regression.
    if grep -q 'core/ verified ==' <<<"$_sc_out"; then
      pass "sync-core: the post-fan-out tree-vs-lock assertion runs and passes ($1)"
    else
      fail "sync-core: the post-fan-out assertion did not run, or ran and failed ($1)"
    fi
    rm -f "$SCF/pushduring"
  }

  # A: the direct-SHA fetch path. GitHub sets uploadpack.allowReachableSHA1InWant, and the
  #    release fan-out already relies on it (sync-fanout.yml pins CORE_BRANCH to a raw sha).
  _scg "$SCF/coreremote" config uploadpack.allowReachableSHA1InWant true
  _sc_race_check "direct-sha fetch"

  # B: the SAME assertions with that config OFF, so the ref-fetch fallback is exercised.
  #    This is the case that catches a fallback written against FETCH_HEAD — which would
  #    re-create #556 inside the fix, since FETCH_HEAD is the new tip by definition.
  _scg "$SCF/coreremote" config --unset uploadpack.allowReachableSHA1InWant || true
  _sc_race_check "ref-fetch fallback"

  # C: with the parallel prefetch on. A warm-up that fetched the moving BRANCH could
  #    smuggle the newer tip into the object store and have read-tree pick it up. SYNC_JOBS
  #    is passed through _sc_run's env-prefix parameter, which the outer runner already
  #    supports — overriding it wins over the SYNC_JOBS=1 baked into the runner.
  _scg "$SCF/coreremote" config uploadpack.allowReachableSHA1InWant true
  _sc_race_check "SYNC_JOBS=4 prefetch" SYNC_JOBS=4

  # ── #556: an unresolvable Core must hard-fail BEFORE anything is written ──────
  # Previously `unknown` was tolerated: the run materialized core/ from the branch and
  # skipped core.lock entirely — a second, race-free producer of the same TAMPERED state.
  _sc_head_before="$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)"
  _sc_out="$(_sc_run CORE_REMOTE="$SCF/nope" CORE_BRANCH=nosuchref)"; _sc_rc=$?
  if ((_sc_rc != 0)) && grep -q 'must vendor a named commit' <<<"$_sc_out" \
    && [[ "$(_scg "$SCF/repos/dotfiles-Test" rev-parse HEAD)" == "$_sc_head_before" ]] \
    && [[ -z "$(_scg "$SCF/repos/dotfiles-Test" status --porcelain)" ]]; then
    pass "sync-core: an unresolvable Core hard-fails before any repo is written"
  else
    fail "sync-core: unresolvable Core did not refuse cleanly (rc=$_sc_rc)"
    printf '%s\n' "$_sc_out" | sed 's/^/    /' >&2
  fi

  # ── #556: core_tag must never describe a commit other than the vendored one ───
  # The `|| describe "$CORE_BRANCH"` fallback re-resolved the branch at describe time, so a
  # moved branch stamped a tag belonging to a DIFFERENT commit — into core.lock and onto
  # every rewritten workflow pin comment, which is the field Renovate reads.
  _sc_old_sha="$(_scg "$SCF/coreremote" rev-parse HEAD)"
  _scg "$SCF/coreremote" tag -f v9.9.9 "$_sc_old_sha" >/dev/null 2>&1
  printf 'core payload newer\n' >"$SCF/coreremote/payload.txt"
  _scg "$SCF/coreremote" add -A
  _scg "$SCF/coreremote" commit -q -m "core c-newer"
  _scg "$SCF/coreremote" tag -f v9.9.10 >/dev/null 2>&1
  _scg "$SCF/core" fetch -q --tags origin >/dev/null 2>&1 || true
  _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1 CORE_BRANCH="$_sc_old_sha")"
  _sc_tag="$(sed -n 's/^core_tag=//p' "$SCF/repos/dotfiles-Test/core.lock" 2>/dev/null)"
  if [[ "$_sc_tag" != v9.9.10 ]] \
    && ! grep -rq '# v9.9.10' "$SCF/repos/dotfiles-Test/.github/workflows" 2>/dev/null; then
    pass "sync-core: core_tag never names a tag belonging to a different commit"
  else
    fail "sync-core: core_tag stamped v9.9.10 for a run that vendored ${_sc_old_sha:0:12}"
  fi
  _scg "$SCF/core" pull -q --ff-only >/dev/null 2>&1 || true
  unset _sc_old_sha _sc_tag
  unset _sc_race_n
  unset -f _sc_race_check

  # ── core_lock_classify: the shared comparison, both verdicts ──────────────────
  # core-integrity.sh had NO behavioural coverage, so extracting its classifier into a
  # shared lib could have changed the verdict silently. Drive the lib directly.
  # shellcheck source=scripts/lib/core-lock.sh
  source "$HERE/scripts/lib/core-lock.sh"
  _sc_run SYNC_SKIP_AUDIT=1 >/dev/null 2>&1
  _sc_rec="$(sed -n 's/^core_sha=//p' "$SCF/repos/dotfiles-Test/core.lock")"
  if [[ "$(core_lock_classify "$SCF/repos/dotfiles-Test" "$_sc_rec" "$SCF/coreremote")" == pristine ]]; then
    pass "core_lock_classify: a freshly synced repo is pristine"
  else
    fail "core_lock_classify: a freshly synced repo was not reported pristine"
  fi
  printf 'hand edit\n' >>"$SCF/repos/dotfiles-Test/core/payload.txt"
  _scg "$SCF/repos/dotfiles-Test" add -A
  DOTFILES_ALLOW_CORE_EDIT=1 _scg "$SCF/repos/dotfiles-Test" commit -q -m "hand edit core/"
  if [[ "$(core_lock_classify "$SCF/repos/dotfiles-Test" "$_sc_rec" "$SCF/coreremote")" == TAMPERED* ]]; then
    pass "core_lock_classify: a hand-edited core/ is reported TAMPERED"
  else
    fail "core_lock_classify: a hand-edited core/ was NOT caught"
  fi
  if [[ "$(core_lock_classify "$SCF/repos/dotfiles-Test" "$(printf '0%.0s' {1..40})" "$SCF/coreremote")" == UNVERIFIABLE* ]]; then
    pass "core_lock_classify: a sha absent from Core history is UNVERIFIABLE, not TAMPERED"
  else
    fail "core_lock_classify: an absent sha was misclassified"
  fi
  unset _sc_rec

  # ── the staleness guard: a target BEHIND its remote must refuse pre-flight (#622) ──
  # The dirty-tree guard asks "uncommitted work?" and nothing asked "current with the
  # remote?", so a sync landed on a stale base in all nine repos and reported
  # `updated 9 / failed 0`; every push was then rejected as non-fast-forward. The property
  # that matters is not the message, it is that the refusal happens BEFORE anything is
  # written — the whole cost of the bug was nine repos already committed to.
  #
  # A dedicated fixture, because the fleet above deliberately has no upstream: a repo with
  # no @{upstream} has no remote counterpart to be behind, which is a case this guard must
  # stay quiet about and which the other assertions rely on.
  _sc_st="$SCF/stale"
  mkdir -p "$_sc_st"
  git init -q --bare "$_sc_st/origin.git" >/dev/null 2>&1 || true
  # Point the bare HEAD at main BEFORE anything clones it. Without this the clone below
  # inherits the host's init.defaultBranch (often master), lands on an unborn branch that
  # the origin does not have, and a later commit there becomes a ROOT commit rather than a
  # descendant — so the "advance the remote" step produces a divergence, not a fast-forward,
  # and the target is never actually BEHIND. Silent, and it makes the guard look broken.
  git -C "$_sc_st/origin.git" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || true
  if git clone -q "$_sc_st/origin.git" "$SCF/repos/dotfiles-Stale" >/dev/null 2>&1; then
    _sc_ident "$SCF/repos/dotfiles-Stale"
    mkdir -p "$SCF/repos/dotfiles-Stale/core"
    printf 'seed\n' >"$SCF/repos/dotfiles-Stale/core/payload.txt"
    _scg "$SCF/repos/dotfiles-Stale" add -A
    _scg "$SCF/repos/dotfiles-Stale" commit -q -m "seed"
    _scg "$SCF/repos/dotfiles-Stale" push -q -u origin HEAD:main >/dev/null 2>&1
    # Advance the shared origin from a second clone, then fetch — leaving the target
    # exactly one commit behind its upstream, with a clean tree.
    if git clone -q "$_sc_st/origin.git" "$_sc_st/other" >/dev/null 2>&1; then
      _sc_ident "$_sc_st/other"
      printf 'upstream moved\n' >"$_sc_st/other/n.txt"
      _scg "$_sc_st/other" add -A
      _scg "$_sc_st/other" commit -q -m "remote advance"
      _scg "$_sc_st/other" push -q origin HEAD:main >/dev/null 2>&1
    fi
    _scg "$SCF/repos/dotfiles-Stale" fetch -q origin >/dev/null 2>&1
    _sc_st_head="$(_scg "$SCF/repos/dotfiles-Stale" rev-parse HEAD)"
    _sc_st_run() { # the fixture sync, aimed at the stale repo only
      env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never \
        REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main \
        SYNC_JOBS=1 "$@" bash "$_SCS" dotfiles-Stale 2>&1
    }
    _sc_out="$(_sc_st_run SYNC_SKIP_AUDIT=1)"; _sc_rc=$?
    if ((_sc_rc != 0)) && grep -qi 'behind their remote' <<<"$_sc_out"; then
      pass "sync-core: a target BEHIND its remote refuses the fan-out (rc=$_sc_rc)"
    else
      fail "sync-core: a stale target did NOT stop the fan-out (rc=$_sc_rc)"
    fi
    # The refusal must be pre-flight. HEAD alone is too weak — a regression that wrote
    # core.lock before returning would leave HEAD unchanged and still pass.
    if [[ "$(_scg "$SCF/repos/dotfiles-Stale" rev-parse HEAD)" == "$_sc_st_head" ]] &&
      [[ -z "$(_scg "$SCF/repos/dotfiles-Stale" status --porcelain)" ]] &&
      [[ ! -f "$SCF/repos/dotfiles-Stale/core.lock" ]]; then
      pass "sync-core: the staleness refusal happens before any repo is mutated"
    else
      fail "sync-core: a repo was written to despite the staleness refusal"
    fi
    # It names the correct recovery. Rebasing the sync commit is NOT it: the workflow pin
    # rewrite is a sed over the target's own files, so it can replay cleanly and be wrong.
    if grep -q 'RE-RUN this sync' <<<"$_sc_out" && grep -qi 'do NOT rebase' <<<"$_sc_out"; then
      pass "sync-core: the staleness refusal names re-running, not rebasing, as the fix"
    else
      fail "sync-core: the staleness refusal does not point at the correct recovery"
    fi
    # The documented escape hatch must actually bypass it.
    _sc_out="$(_sc_st_run SYNC_SKIP_AUDIT=1 SYNC_SKIP_STALE=1)"
    if ! grep -qi 'behind their remote' <<<"$_sc_out"; then
      pass "sync-core: SYNC_SKIP_STALE=1 bypasses the staleness guard"
    else
      fail "sync-core: SYNC_SKIP_STALE=1 did not bypass the staleness guard"
    fi
    # ...and a repo with NO upstream is silently fine, which is what keeps every other
    # assertion in this section working.
    _sc_out="$(_sc_run SYNC_SKIP_AUDIT=1)"
    if ! grep -qi 'behind their remote' <<<"$_sc_out"; then
      pass "sync-core: a target with no @{upstream} is not reported stale"
    else
      fail "sync-core: a target with no upstream was wrongly reported stale"
    fi
    rm -rf "$SCF/repos/dotfiles-Stale"
    unset -f _sc_st_run
    unset _sc_st_head
  else
    skip "sync-core staleness guard (could not build the clone fixture — out of scope)"
  fi
  unset _sc_st

  # --- --strict: a failed TARGET becomes the exit status ------------------------
  # By default a per-repo failure is a summary line and exit 0 — the fan-out runs this
  # script bare inside a `bash -e` step and then does per-repo push/PR work, so a default
  # non-zero exit would abort that for every repo when one fails. A single-target caller
  # (the scaffold's recovery command, the first-vendor recipe) needs the opposite: a
  # status it can chain on. Both contracts are pinned here on the same failure — a
  # dirty target, which the guard refuses — so neither can drift without notice.
  # Invoked directly rather than through _sc_run, which feeds its arguments to env.
  : >"$SCF/repos/dotfiles-Test/dirty-by-design"
  _sc_strict_out="$(env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never \
    REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main \
    SYNC_JOBS=1 SYNC_SKIP_AUDIT=1 bash "$_SCS" dotfiles-Test 2>&1)"
  _sc_strict_rc=$?
  if ((_sc_strict_rc == 0)) && grep -q 'uncommitted changes' <<<"$_sc_strict_out" && grep -q 'failed 1' <<<"$_sc_strict_out"; then
    pass "sync-core: by default a failed target is a summary line (failed 1) and exit 0 — the fan-out's contract"
  else
    fail "sync-core: the default contract moved — rc=$_sc_strict_rc: $(grep -E 'uncommitted|failed' <<<"$_sc_strict_out" | head -2 | tr '\n' ' ')"
  fi
  _sc_strict_out="$(env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never \
    REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main \
    SYNC_JOBS=1 SYNC_SKIP_AUDIT=1 bash "$_SCS" --strict dotfiles-Test 2>&1)"
  _sc_strict_rc=$?
  if ((_sc_strict_rc == 1)) && grep -q 'uncommitted changes' <<<"$_sc_strict_out"; then
    pass "sync-core: --strict turns the same failed target into exit 1 (the recovery command's verdict)"
  else
    fail "sync-core: --strict did not return 1 on a failed target — rc=$_sc_strict_rc"
  fi
  rm -f "$SCF/repos/dotfiles-Test/dirty-by-design"
  # A SKIPPED target is a strict failure too: a wrong name or REPOS_ROOT ("not cloned")
  # and a repo with no core/ yet both stamp nothing, and the default still exits 0.
  mkdir -p "$SCF/repos/dotfiles-NoCore"
  _scg "$SCF/repos/dotfiles-NoCore" init -q >/dev/null 2>&1
  _sc_ident "$SCF/repos/dotfiles-NoCore"
  : >"$SCF/repos/dotfiles-NoCore/README.md"
  _scg "$SCF/repos/dotfiles-NoCore" add -A
  _scg "$SCF/repos/dotfiles-NoCore" commit -q -m "no core yet"
  _sc_strict_bad=""
  for _sc_t in dotfiles-NotCloned dotfiles-NoCore; do
    env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main SYNC_JOBS=1 SYNC_SKIP_AUDIT=1 bash "$_SCS" "$_sc_t" >/dev/null 2>&1 || _sc_strict_bad="$_sc_strict_bad $_sc_t:default-nonzero"
    env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main SYNC_JOBS=1 SYNC_SKIP_AUDIT=1 bash "$_SCS" --strict "$_sc_t" >/dev/null 2>&1 && _sc_strict_bad="$_sc_strict_bad $_sc_t:strict-zero"
  done
  if [[ -z "$_sc_strict_bad" ]]; then
    pass "sync-core: a targeted SKIP (not cloned, no core/) exits 0 by default and 1 under --strict"
  else
    fail "sync-core: the skip contract is wrong —$_sc_strict_bad"
  fi
  rm -rf "$SCF/repos/dotfiles-NoCore"

  # A LINKED WORKTREE target is a clone, and must not be skipped (#850). `.git` is a FILE
  # there, not a directory, so the `-d "$path/.git"` this script used at three sites called a
  # perfectly good target "not cloned" — and once --strict (above) turned a skip into exit 1,
  # a fan-out over a worktree checkout failed outright instead of syncing it. Both the default
  # summary and --strict are asserted, because the two contracts diverge exactly here: the
  # default hides the misclassification in a `skipped 1` nobody reads, and only --strict makes
  # it loud. Submodule checkouts have the same `.git`-is-a-file shape and are covered by the
  # same predicate.
  if _scg "$SCF/repos/dotfiles-Test" worktree add -q -b sync-wt-probe \
    "$SCF/repos/dotfiles-Worktree" >/dev/null 2>&1 &&
    [[ -f "$SCF/repos/dotfiles-Worktree/.git" ]]; then
    _sc_wt_out="$(env -u DOTFILES_ALLOW_CORE_EDIT -u CORE_JSON CORE_COLOR=never \
      REPOS_ROOT="$SCF/repos" CORE_REMOTE="$SCF/coreremote" CORE_BRANCH=main \
      SYNC_JOBS=1 SYNC_SKIP_AUDIT=1 bash "$_SCS" --strict dotfiles-Worktree 2>&1)"
    _sc_wt_rc=$?
    if ((_sc_wt_rc == 0)) && ! grep -q 'not cloned' <<<"$_sc_wt_out"; then
      pass "sync-core: a linked-worktree target (.git is a FILE) is a clone, not a skip (#850)"
    else
      fail "sync-core: a linked-worktree target was misclassified — rc=$_sc_wt_rc: $(grep -E 'not cloned|skipped|failed' <<<"$_sc_wt_out" | head -2 | tr '\n' ' ')"
    fi
    unset _sc_wt_out _sc_wt_rc
    _scg "$SCF/repos/dotfiles-Test" worktree remove --force "$SCF/repos/dotfiles-Worktree" >/dev/null 2>&1
    _scg "$SCF/repos/dotfiles-Test" branch -q -D sync-wt-probe >/dev/null 2>&1
    rm -rf "$SCF/repos/dotfiles-Worktree"
  else
    skip "sync-core: linked-worktree target (could not create the worktree fixture — out of scope)"
    rm -rf "$SCF/repos/dotfiles-Worktree"
  fi

  unset _sc_strict_out _sc_strict_rc _sc_strict_bad _sc_t
else
  skip "sync-core.sh fan-out guards (git subtree unavailable — it is a contrib command)"
fi

# ── the vendoring filter and its version switch (#676) ──────────────────────
# THE ASSERTION THE WHOLE OF #676 RESTS ON. sync-core.sh no longer vendors the upstream
# tree; it vendors `core.manifest` ∪ `core.vendor`, and core-integrity.sh must expect
# exactly that subset. If the producer and the verifier ever computed different subsets, a
# sync would pass its own post-fan-out assertion and the fleet would be reported TAMPERED by
# an unrelated command later — #556's failure, one layer down.
#
# The switch is PRESENCE-BASED: a commit carrying core.vendor vendors the filtered tree, one
# that does not vendors its whole tree. That is what let #676 land with no flag day, so both
# branches are asserted here — a test that only covered the new shape would not have caught
# a change that broke every repo still pinning an older Core.
# ── CHANGELOG digest generator (scripts/gen-changelog-recent.sh) ─────────────
# CHANGELOG.recent.md is the ONLY changelog a box has (#680): CHANGELOG.md is not vendored
# and will not be (~707 KB, 36% of the vendored tree — the freight #676 removed). The
# generator is therefore the whole feature's data source, driven here against FIXTURES
# rather than this repo's real changelog, so the assertions are about SLICING and
# DETERMINISM, not about whatever happened to ship. audit-core.sh §9e owns the separate
# claim that the committed digest matches the real CHANGELOG.md.
hdr "CHANGELOG digest generator (scripts/gen-changelog-recent.sh)"
GCR="$HERE/scripts/gen-changelog-recent.sh"
if [[ ! -x "$GCR" ]]; then
  fail "scripts/gen-changelog-recent.sh missing or not executable"
else
  GCRD="$(mktemp -d "$SANDBOX/gencr.XXXXXX")"
  # TEN releases plus an [Unreleased] section, so the N=8 window has something to drop at
  # BOTH ends and the [Unreleased] exclusion is observable rather than vacuous.
  {
    printf '# Changelog\n\nPreamble prose.\n\n## [Unreleased]\n\n### Added\n\n- UNRELEASED-MARKER work in flight\n\n'
    for _i in 10 9 8 7 6 5 4 3 2 1; do
      printf '## [v1.0.%s] - 2026-01-%02d\n\n### Added\n\n- entry for 1.0.%s\n\n' "$_i" "$_i" "$_i"
    done
  } >"$GCRD/CHANGELOG.md"

  gcr() { "$GCR" --source "$GCRD/CHANGELOG.md" --out "$GCRD/recent.md" "$@"; }

  # (1) THE WINDOW. Exactly RECENT_RELEASES sections, no more, no fewer.
  _gcr_n="$(gcr --stdout | grep -c '^## \[')"
  if [[ "$_gcr_n" == 8 ]]; then
    pass "digest renders exactly 8 release sections"
  else
    fail "digest rendered $_gcr_n release sections (want 8) — the N window is not being applied"
  fi

  # (2) WHICH EIGHT. The newest must be in; the two that fall off the end must be out.
  _gcr_out="$(gcr --stdout)"
  if [[ "$_gcr_out" == *'## [v1.0.10]'* && "$_gcr_out" == *'## [v1.0.3]'* &&
    "$_gcr_out" != *'## [v1.0.2]'* && "$_gcr_out" != *'## [v1.0.1]'* ]]; then
    pass "digest keeps the 8 NEWEST releases and drops the older two"
  else
    fail "digest window is off by one or reversed — want v1.0.10..v1.0.3 in, v1.0.2/v1.0.1 out"
  fi

  # (3) [Unreleased] IS EXCLUDED — heading AND body. A box runs a RELEASED core.version, so
  # an [Unreleased] entry describes code it does not have; including it would also make the
  # digest stale on every changelog bullet and red §9e on nearly every PR.
  if [[ "$_gcr_out" != *'[Unreleased]'* && "$_gcr_out" != *UNRELEASED-MARKER* ]]; then
    pass "digest excludes the [Unreleased] section (heading and body)"
  else
    fail "digest carries [Unreleased] — the verb would describe code the box does not run, and §9e would red on every PR"
  fi

  # (4) DETERMINISM, two ways. §9e asserts byte-identity against a fresh render, so any
  # non-determinism reads as PERMANENT staleness that no regeneration could clear.
  if [[ "$(gcr --stdout)" == "$_gcr_out" ]]; then
    pass "digest render is deterministic across runs"
  else
    fail "digest render is NOT deterministic — §9e would red forever and no regeneration could fix it"
  fi
  if [[ "$_gcr_out" != *"$(date +%Y-%m-%d)"* ]]; then
    pass "digest embeds no generated-on date (fixture dates are 2026-01-xx)"
  else
    fail "digest embeds today's date — it would go stale at midnight, with §9e red until someone re-ran the generator"
  fi

  # (5) THE HEADER MUST DEFEND ITSELF. A vendored copy is read by someone who has never seen
  # this repo; if it does not say "generated" and name its generator, it gets hand-edited.
  if [[ "$_gcr_out" == *'GENERATED FILE'* && "$_gcr_out" == *'gen-changelog-recent.sh'* &&
    "$_gcr_out" == *'CHANGELOG.md'* ]]; then
    pass "digest header self-identifies as generated, names its generator and the full log"
  else
    fail "digest header does not self-identify — a vendored copy invites the hand edits §9e then reds on"
  fi

  # (6) MARKDOWNLINT SEAMS. §7 lints '**/*.md', so the generator's own header is the only
  # NEW markdown in the tree and its seams are where a bug would land: exactly one H1
  # (MD025), and a last line that is not blank (MD047 + pre-commit end-of-file-fixer).
  _gcr_h1="$(printf '%s\n' "$_gcr_out" | grep -c '^# ')"
  _gcr_last="$(printf '%s\n' "$_gcr_out" | tail -n1)"
  if [[ "$_gcr_h1" == 1 && -n "$_gcr_last" ]]; then
    pass "digest has exactly one H1 and no trailing blank line (MD025 / MD047 seams)"
  else
    fail "digest markdown seams are wrong: $_gcr_h1 H1 heading(s), last line '${_gcr_last}'"
  fi

  # (7) --check is the human/Makefile mirror of audit §9e: 0 when fresh, non-zero when not.
  gcr >/dev/null 2>&1
  if gcr --check >/dev/null 2>&1; then
    pass "--check returns 0 against a file the generator just wrote"
  else
    fail "--check reds on its own fresh output — the audit gate would be unfixable"
  fi
  printf 'hand edit\n' >>"$GCRD/recent.md"
  if gcr --check >/dev/null 2>&1; then
    fail "--check passed a HAND-EDITED digest — the gate cannot detect the thing it exists for"
  else
    pass "--check rejects a hand-edited digest"
  fi

  # (8) FEWER RELEASES THAN N is not an error — a young fork, or this repo at v1.0.1.
  printf '# Changelog\n\n## [v0.2.0] - 2026-01-02\n\n- b\n\n## [v0.1.0] - 2026-01-01\n\n- a\n' >"$GCRD/short.md"
  _gcr_short="$("$GCR" --source "$GCRD/short.md" --stdout 2>/dev/null)"
  if [[ "$(printf '%s\n' "$_gcr_short" | grep -c '^## \[')" == 2 ]]; then
    pass "a changelog with fewer than 8 releases renders all of them and exits 0"
  else
    fail "a short changelog is mishandled — a young repo could not generate a digest at all"
  fi

  # (9) NO releases at all → refuse LOUDLY rather than commit an empty digest that the verb
  # would then have to explain away on nine boxes.
  printf '# Changelog\n\n## [Unreleased]\n\n- only unreleased\n' >"$GCRD/none.md"
  if "$GCR" --source "$GCRD/none.md" --stdout >/dev/null 2>&1; then
    fail "a changelog with NO released section produced a digest — it would ship empty"
  else
    pass "a changelog with no released section is refused (non-zero), not shipped empty"
  fi

  # (10) THE VENDORING DECISION, pinned. #680 ships a 49 KB digest precisely BECAUSE
  # #676/#784 measured CHANGELOG.md at 36% of the vendored tree. Re-adding the full file
  # would silently undo that, and this is the only place that would notice.
  if grep -qE '^CHANGELOG\.recent\.md([[:space:]]|$)' "$HERE/core.vendor"; then
    pass "core.vendor ships CHANGELOG.recent.md (the digest core whatsnew reads)"
  else
    fail "core.vendor does not list CHANGELOG.recent.md — core whatsnew would find nothing on any box"
  fi
  if grep -qE '^CHANGELOG\.md([[:space:]]|$)' "$HERE/core.vendor"; then
    fail "core.vendor lists the FULL CHANGELOG.md — ~707 KB, 36% of the vendored tree, the freight #676 removed"
  else
    pass "core.vendor does not ship the full CHANGELOG.md (the digest is the whole point)"
  fi
  unset _gcr_n _gcr_out _gcr_h1 _gcr_last _gcr_short _i
fi

hdr "vendoring filter (core.vendor) + the version switch"
if have git; then
  VF="$SANDBOX/vendorfilter"
  rm -rf "$VF"; mkdir -p "$VF/core"
  _vf() { git -C "$VF/core" "$@" >/dev/null 2>&1; }
  git init -q "$VF/core"
  _vf config user.email t@example.com; _vf config user.name t; _vf config commit.gpgsign false
  # A miniature Core: two shipped files, one that rides along, one that must NOT ship.
  mkdir -p "$VF/core/zsh" "$VF/core/scripts" "$VF/core/assets"
  printf 'shipped\n' >"$VF/core/zsh/00-tools.zsh"
  printf '1.0.0\n'   >"$VF/core/core.version"
  printf 'consumed by the OS repos\n' >"$VF/core/scripts/tool-versions.env"
  printf 'a very large gif\n' >"$VF/core/assets/demo.gif"
  printf 'authoring only\n'   >"$VF/core/scripts/release.sh"
  printf 'core.version\nzsh/00-tools.zsh\n' >"$VF/core/core.manifest"
  _vf add -A; _vf commit -m "pre-filter Core"
  vf_old="$(git -C "$VF/core" rev-parse HEAD)"
  printf 'core.manifest\ncore.vendor\nscripts/tool-versions.env\n' >"$VF/core/core.vendor"
  _vf add -A; _vf commit -m "Core carrying core.vendor"
  vf_new="$(git -C "$VF/core" rev-parse HEAD)"

  # shellcheck source=scripts/lib/core-vendor.sh
  source "$HERE/scripts/lib/core-vendor.sh"
  # shellcheck source=scripts/lib/core-lock.sh
  source "$HERE/scripts/lib/core-lock.sh"

  # (a) the switch itself, both directions
  if core_vendor_is_filtered "$VF/core" "$vf_new"; then
    pass "core.vendor at a commit marks it filtered"
  else
    fail "a commit carrying core.vendor was not detected as filtered — the whole fleet would keep vendoring 285 files"
  fi
  if core_vendor_is_filtered "$VF/core" "$vf_old"; then
    fail "a commit PREDATING core.vendor was treated as filtered — every repo pinning an older Core would report TAMPERED on the day #676 merged"
  else
    pass "a commit predating core.vendor is not filtered (the no-flag-day migration path)"
  fi

  # (b) the whole-tree branch is still literally ^{tree}, so old locks are untouched
  if [[ "$(core_vendor_effective_tree "$VF/core" "$vf_old")" == "$(git -C "$VF/core" rev-parse "${vf_old}^{tree}")" ]]; then
    pass "unfiltered commit → expected tree is still its whole tree"
  else
    fail "unfiltered commit → expected tree changed; repos pinning pre-#676 Core would be misreported"
  fi

  # (c) the filtered tree carries exactly the union, and nothing else
  vf_tree="$(core_vendor_tree "$VF/core" "$vf_new")"
  vf_files="$(git -C "$VF/core" ls-tree -r --name-only "$vf_tree" | sort | tr '\n' ' ')"
  if [[ "$vf_files" == "core.manifest core.vendor core.version scripts/tool-versions.env zsh/00-tools.zsh " ]]; then
    pass "filtered tree == core.manifest ∪ core.vendor, exactly"
  else
    fail "filtered tree carries the wrong set: $vf_files"
  fi
  for _drop in assets/demo.gif scripts/release.sh; do
    if git -C "$VF/core" ls-tree -r --name-only "$vf_tree" | grep -qx "$_drop"; then
      fail "filtered tree still carries $_drop — it is in neither list"
    else
      pass "filtered tree drops $_drop (in neither list)"
    fi
  done

  # (d) DETERMINISM. The producer builds this tree inside the consumer and the verifier
  # rebuilds it inside Core; they agree only because the build is a pure function of the
  # commit. Two builds must be byte-identical or the fleet flaps between pristine and
  # TAMPERED depending on who asked.
  if [[ "$(core_vendor_tree "$VF/core" "$vf_new")" == "$vf_tree" ]]; then
    pass "filtered tree build is deterministic"
  else
    fail "filtered tree build is NOT deterministic — core-integrity would flap"
  fi

  # (e) modes survive. read-tree --prefix used to give us the exec bits straight from the
  # tree object; the index-info rebuild must not quietly reconstruct them as 100644.
  _vf update-index --chmod=+x scripts/tool-versions.env 2>/dev/null || true
  if git -C "$VF/core" ls-tree -r "$vf_tree" | grep -q '^100644 blob .*zsh/00-tools.zsh$'; then
    pass "filtered tree preserves file modes from the source tree"
  else
    fail "filtered tree lost the source file modes (audit §2's exec-bit assertions would follow)"
  fi

  # (e2) CALLED FROM A SUBDIRECTORY. `git -C <subdir> update-index --index-info` resolves its
  # paths against the cwd PREFIX, so building the index from anywhere but the repo root
  # matched nothing and returned git's EMPTY tree — with rc 0, so the caller got a
  # valid-looking object id for a tree containing no files and reported TAMPERED against it.
  # A vendored `core/scripts/core-integrity.sh --self` hits exactly this: its own $HERE is
  # <consumer>/core. Assert the root-resolve, and assert the empty tree is never returned for
  # a non-empty keep list.
  for _sub in "$VF/core/zsh" "$VF/core/scripts"; do
    [ -d "$_sub" ] || continue
    if [[ "$(core_vendor_tree "$_sub" "$vf_new")" == "$vf_tree" ]]; then
      pass "core_vendor_tree from a subdirectory ($(basename "$_sub")) agrees with the repo root"
    else
      fail "core_vendor_tree gave a different tree from $_sub — index paths resolved against the cwd prefix"
    fi
  done
  if [[ "$(core_vendor_tree "$VF/core" "$vf_new")" == "4b825dc642cb6eb9a060e54bf8d69288fbee4904" ]]; then
    fail "core_vendor_tree returned the EMPTY tree for a non-empty keep list — silently vendors nothing"
  else
    pass "core_vendor_tree never returns the empty tree for a non-empty keep list"
  fi

  # (f) END TO END: a consumer materialized by the shared producer classifies pristine, and
  # the SAME lock against a whole-tree vendor classifies TAMPERED. That second case is not
  # hypothetical — it is what a `git subtree pull` (Offense's retired path) would produce.
  rm -rf "$VF/consumer"; mkdir -p "$VF/consumer"
  git init -q "$VF/consumer"
  git -C "$VF/consumer" config user.email t@example.com >/dev/null 2>&1
  git -C "$VF/consumer" config user.name t >/dev/null 2>&1
  git -C "$VF/consumer" config commit.gpgsign false >/dev/null 2>&1
  git -C "$VF/consumer" fetch -q --no-tags "$VF/core" "$vf_new" >/dev/null 2>&1
  if core_vendor_materialize "$VF/consumer" "$vf_new" &&
    git -C "$VF/consumer" commit -qm vendor >/dev/null 2>&1; then
    if [[ "$(core_lock_classify "$VF/consumer" "$vf_new" "$VF/core")" == "pristine" ]]; then
      pass "filtered vendor + filtering lock → pristine"
    else
      fail "filtered vendor was not pristine — the producer and the verifier disagree (#556 shape)"
    fi
    # now replace core/ with the WHOLE tree, keeping the same lock
    git -C "$VF/consumer" rm -rq core >/dev/null 2>&1
    rm -rf "$VF/consumer/core"
    git -C "$VF/consumer" read-tree --prefix=core/ -u "${vf_new}^{tree}" >/dev/null 2>&1
    git -C "$VF/consumer" commit -qm whole >/dev/null 2>&1
    if [[ "$(core_lock_classify "$VF/consumer" "$vf_new" "$VF/core")" == TAMPERED* ]]; then
      pass "whole-tree vendor against a filtering lock → TAMPERED (catches an unfiltered producer)"
    else
      fail "an UNFILTERED core/ passed as pristine — a stray 'git subtree pull' would go unnoticed"
    fi
  else
    skip "vendoring filter end-to-end (could not build the consumer fixture — out of scope)"
  fi
  unset -f _vf
else
  skip "vendoring filter (git unavailable)"
fi
