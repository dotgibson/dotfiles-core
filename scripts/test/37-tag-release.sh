# scripts/test/37-tag-release.sh
# tag-release.sh (a tag may only exist on a commit that is on main)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── tag-release.sh — the tag may only exist on a commit that is on main ──────
# This script had NO coverage, which is how its ordering bug survived: it used to commit
# AND tag in one step, leaving a local vX.Y.Z on a commit that was not yet on main. A
# concurrent session pushing with push.followTags carried exactly such a tag to origin and
# fired release.yml + sync-fanout.yml against an unmerged commit — eight bad vendor PRs,
# and a retired version number, because release tags are immutable by ruleset.
#
# The invariant these pin: a vX.Y.Z tag only ever exists on a commit already on
# origin/main. Phase 1 must create NO tag; phase 2 must refuse unless origin/main really
# carries the version.
if have git; then
  hdr "tag-release.sh two-phase ordering (hermetic fixtures)"
  TR="$SANDBOX/tagrelease"
  rm -rf "$TR"; mkdir -p "$TR"
  _trg() { git -C "$1" -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t "${@:2}"; }
  _tr_ident() {
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name t
    git -C "$1" config commit.gpgsign false
  }
  # A miniature release repo: the REAL tag-release.sh plus the two files it reads, and an
  # "origin" it can fetch. audit is stubbed so the gate can be driven without running the
  # real one inside a test.
  mkdir -p "$TR/origin/scripts/lib" "$TR/origin/lib"
  cp "$HERE/scripts/tag-release.sh" "$TR/origin/scripts/"
  cp "$HERE/scripts/lib/common.sh" "$TR/origin/scripts/lib/"
  cp "$HERE/lib/ux.sh" "$TR/origin/lib/"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TR/origin/scripts/audit-core.sh"
  chmod +x "$TR/origin/scripts/audit-core.sh" "$TR/origin/scripts/tag-release.sh"
  printf '1.0.0\n' >"$TR/origin/core.version"
  printf '# Changelog\n\n## [Unreleased]\n\n## [v1.0.0] - 2026-01-01\n\n- released\n' >"$TR/origin/CHANGELOG.md"
  # The vendored digest is a THIRD release file since #680 — release.sh regenerates it and
  # tag-release.sh must commit it. The fixture carries it so these tests exercise the real
  # three-file pathspec; without it they would only ever prove the two-file case still works.
  printf '# Changelog — recent releases\n\n## [v1.0.0] - 2026-01-01\n\n- released\n' >"$TR/origin/CHANGELOG.recent.md"
  _trg "$TR/origin" init -q >/dev/null 2>&1
  _tr_ident "$TR/origin"
  _trg "$TR/origin" symbolic-ref HEAD refs/heads/main
  _trg "$TR/origin" add -A; _trg "$TR/origin" commit -q -m "v1.0.0"
  # The fixture "origin" is a normal repo with main checked out, so a push to that branch
  # is refused by default. Allow it: the test needs to LAND the release on origin's main
  # to exercise the guard, and nothing here reads origin's worktree.
  git -C "$TR/origin" config receive.denyCurrentBranch ignore
  git -c commit.gpgsign=false clone -q "$TR/origin" "$TR/work" >/dev/null 2>&1
  _tr_ident "$TR/work"
  _TRS="$TR/work/scripts/tag-release.sh"

  # Stage a 1.1.0 release in the clone, exactly as release.sh would leave it.
  printf '1.1.0\n' >"$TR/work/core.version"
  printf '# Changelog\n\n## [Unreleased]\n\n## [v1.1.0] - 2026-02-02\n\n- new\n\n## [v1.0.0] - 2026-01-01\n\n- released\n' >"$TR/work/CHANGELOG.md"
  printf '# Changelog — recent releases\n\n## [v1.1.0] - 2026-02-02\n\n- new\n\n## [v1.0.0] - 2026-01-01\n\n- released\n' >"$TR/work/CHANGELOG.recent.md"

  # LC_ALL=C so assertions on this output mean the same thing on every box: the script's
  # own strings are ours and stable, but anything bash or git emits — notably a shell's
  # "command not found" — is localized, and an assertion that greps a translated
  # diagnostic silently stops matching rather than failing.
  # -u CORE_JSON alongside the pins: under --json, common.sh's skip() prints NOTHING (stdout
  # must carry only the JSON object), and both test-core.sh and audit-core.sh EXPORT
  # CORE_JSON=1 for that mode. The fixture inherits it, the advanced-tip notice vanishes,
  # and the assertion below fails for a reason that has nothing to do with tag-release.sh.
  # Verified: before this, `test-core.sh --json` reported the notice missing. The rule this
  # follows — a fixture asserting on OUTPUT must pin every variable that governs how output
  # is produced — is the same one behind LC_ALL and CORE_COLOR here, and $EDITOR below.
  _tr_run() { (cd "$TR/work" && env -u CORE_JSON LC_ALL=C CORE_COLOR=never TAG_SKIP_AUDIT=1 bash "$_TRS" "$@" 2>&1); }

  # THE property. Phase 1 commits and must leave NO tag behind — there must be nothing
  # for a stray push to carry while the commit is still off main.
  _tr_out="$(_tr_run)"; _tr_rc=$?
  _tr_tags="$(_trg "$TR/work" tag -l | tr '\n' ' ')"
  if ((_tr_rc == 0)) && [[ -z "$_tr_tags" ]] &&
    [[ -n "$(_trg "$TR/work" log --oneline -1 --grep='release v1.1.0')" ]]; then
    pass "tag-release: phase 1 commits the release and creates NO tag"
  else
    fail "tag-release: phase 1 left tags '$_tr_tags' (rc=$_tr_rc) — a pre-merge tag is the hazard"
  fi

  # Phase 2 must REFUSE while the commit is only local: origin/main still carries 1.0.0.
  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  if ((_tr_rc != 0)) && grep -q 'has not merged' <<<"$_tr_out" &&
    [[ -z "$(_trg "$TR/work" tag -l 'v1.1.0')" ]]; then
    pass "tag-release: --publish refuses while origin/main lacks the version (no tag created)"
  else
    fail "tag-release: --publish tagged a release that had not landed (rc=$_tr_rc)"
  fi

  # The withdrawn flag must fail loudly rather than silently doing the old thing.
  _tr_out="$(_tr_run --push)"; _tr_rc=$?
  if ((_tr_rc == 2)) && grep -q 'was removed' <<<"$_tr_out"; then
    pass "tag-release: the withdrawn --push flag fails with a pointer to --publish"
  else
    fail "tag-release: --push did not fail cleanly (rc=$_tr_rc)"
  fi

  # Land the release on origin's main — and then let main ADVANCE, which is the case
  # that matters. core.version does not change again until the next release, so "the tip
  # carries $VERSION" stays true for every later commit; tagging the tip would sweep work
  # still under [Unreleased] into the release, and release.yml builds the body from the
  # [vX.Y.Z] section, so it would ship undescribed.
  _trg "$TR/work" push -q origin HEAD:main 2>/dev/null
  _tr_release_sha="$(_trg "$TR/work" rev-parse HEAD)"
  # a later, unrelated commit on origin/main
  printf 'later\n' >"$TR/work/later.txt"
  _trg "$TR/work" add later.txt; _trg "$TR/work" commit -q -m "unrelated work after the release"
  _trg "$TR/work" push -q origin HEAD:main 2>/dev/null
  _trg "$TR/work" fetch -q origin

  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  _tr_at="$(_trg "$TR/work" rev-parse -q --verify 'v1.1.0^{commit}' 2>/dev/null)"
  _tr_tip="$(_trg "$TR/work" rev-parse -q --verify origin/main 2>/dev/null)"
  if ((_tr_rc == 0)) && [[ "$_tr_at" == "$_tr_release_sha" ]]; then
    pass "tag-release: --publish tags the RELEASE commit, not origin/main's tip"
  else
    fail "tag-release: tagged $_tr_at, wanted the release commit $_tr_release_sha (tip=$_tr_tip, rc=$_tr_rc)"
  fi
  if [[ "$_tr_at" != "$_tr_tip" ]]; then
    pass "tag-release: the tip had advanced, and the tag did not follow it"
  else
    fail "tag-release: fixture did not actually advance the tip — the assertion above proves nothing"
  fi
  # No undefined helper on the publish path. This run just exercised the advanced-tip
  # branch, which called a `note` that scripts/lib/common.sh has never defined (it defines
  # pass/skip/fail/hdr/have) — so it printed "note: command not found" and SWALLOWED the
  # very notice it exists to give. It survived because this branch only runs when main has
  # moved past the release commit, and because shellcheck cannot flag a bare word that
  # might be some command on PATH; the assertions above only ever inspected tags, never the
  # output. It fired for real while publishing v4.12.2.
  #
  # BOTH halves, because either alone is satisfiable by the wrong thing:
  #   * absence of the shell diagnostic alone passes if the notice is DELETED — the
  #     user-visible regression (no notice at all) would sail through;
  #   * presence of the notice alone would pass while a second, later helper was undefined.
  # And the diagnostic is matched only as a NEGATIVE, because bash localizes "command not
  # found" — a translated shell would silently satisfy a positive match. The notice text
  # is ours and stable, so that is the half worth asserting positively. _tr_run pins
  # LC_ALL=C so the negative match stays meaningful wherever this runs.
  # Order matters for the DIAGNOSIS, not the verdict. An undefined helper fails both halves
  # at once — bash prints "…: command not found" and the message text never appears, since
  # the words were arguments to a command that does not exist — so testing the missing
  # notice first would report "deleted? suppressed?" for a helper that is merely misspelled.
  # Check the specific cause first and let the general one catch the rest.
  if grep -qi 'command not found' <<<"$_tr_out"; then
    fail "tag-release: --publish invoked an undefined helper: $(grep -i 'command not found' <<<"$_tr_out" | head -1)"
  elif ! grep -q 'origin/main has advanced' <<<"$_tr_out"; then
    fail "tag-release: --publish printed NO advanced-tip notice — the fixture advanced the tip, so it was due (deleted? suppressed?)"
  else
    pass "tag-release: --publish emits the advanced-tip notice, via a helper that exists"
  fi
  # ...and the moving major alias rides along to the same commit.
  if [[ "$(_trg "$TR/work" rev-parse -q --verify 'v1^{commit}' 2>/dev/null)" == "$_tr_release_sha" ]]; then
    pass "tag-release: --publish moves the vN alias to the release commit too"
  else
    fail "tag-release: the vN alias did not follow the release"
  fi

  # ── the alias must be ANNOTATED, or signing operators cannot publish (#506) ──────────
  # The assertion above passes on any box with `tag.gpgsign` OFF, which is why this shipped
  # broken: under `tag.gpgsign = true` git makes every tag SIGNED — therefore annotated —
  # so a message-less `git tag -f "$MAJOR"` aborts with "fatal: no tag message?" and the
  # publish dies AFTER creating the immutable tag locally. It broke the first real release
  # cut by an operator with signing enabled (v4.12.2).
  #
  # This cannot be driven by simply flipping gpgsign on in the fixture: git would then try
  # to actually sign, and CI has no key, so the test would fail for an unrelated reason and
  # prove nothing. Note also WHY the fixture never caught this on the maintainer's own box,
  # where signing IS on — this suite exports GIT_CONFIG_GLOBAL=/dev/null (above), so the
  # fixture is hermetic from exactly the config that triggers the bug. Hermeticity is right,
  # and it is also what hid this. Pin it from both ends instead, neither needing a key:
  #   1. the hazard is REAL — the message-less form still fails under gpgsign, and it fails
  #      BEFORE any signing is attempted, so no key is required to observe it;
  #   2. the alias the script ACTUALLY produced is annotated and carries a message.
  _tr_gpgd="$SANDBOX/tagsign"; rm -rf "$_tr_gpgd"; mkdir -p "$_tr_gpgd"
  git init -q "$_tr_gpgd"; _tr_ident "$_tr_gpgd"
  git -C "$_tr_gpgd" commit -q --allow-empty -m x
  # Assert the STATUS and ONLY the status. The wording is environment-dependent, not a
  # stable contract: with no message and no -m, git needs one, and how it complains
  # depends on whether it can open an editor —
  #     macOS, interactive:  fatal: no tag message?
  #     CI, no TTY/EDITOR:   error: Terminal is dumb, but EDITOR unset
  # Both are the same hazard. An earlier version of this assertion demanded the first
  # wording and went red across all four CI legs for a difference that says nothing about
  # the bug. The message is kept for the failure text, where it aids diagnosis, and is
  # never gated on.
  # GIT_EDITOR=true, and the inherited editor vars cleared. Without this the probe is only
  # deterministic where there is no editor to launch — i.e. CI. On a developer's
  # interactive `make audit`, git would open $EDITOR here to collect the tag message and
  # BLOCK the suite on a modal vim; saving a message would then let it proceed to a real
  # signing attempt, which is neither what this asserts nor guaranteed to be possible.
  # `true` is a no-op editor: it exits 0 having written nothing, so the message stays
  # empty and git aborts exactly as it does in CI — deterministic, key-free, everywhere.
  _tr_sign_err="$(LC_ALL=C GIT_EDITOR=true EDITOR=true VISUAL=true \
    git -C "$_tr_gpgd" -c tag.gpgsign=true tag -f vSIG 2>&1)"
  _tr_sign_rc=$?
  if ((_tr_sign_rc != 0)); then
    pass "tag-release: a message-less 'git tag -f' really does abort under tag.gpgsign (the #506 hazard)"
  else
    # Not a failure of ours — git changed behaviour, so the check below is guarding a
    # hazard that may no longer exist. Say so rather than reporting a silent pass.
    fail "tag-release: message-less 'git tag -f' no longer aborts under gpgsign — re-check whether #506's fix is still needed (git said: ${_tr_sign_err:-<nothing>})"
  fi
  # BEHAVIOUR, not source spelling. Grepping tag-release.sh for a command form would match
  # a comment or dead code, and would reject equivalent correct spellings like
  # `--annotate --force`. The publish above already created v1 with the real script, so ask
  # git what that ref actually IS: an annotated tag is its own object (`cat-file -t` → tag)
  # and carries a message; a lightweight tag resolves straight to the commit.
  _tr_v1_type="$(_trg "$TR/work" cat-file -t "$(_trg "$TR/work" rev-parse -q --verify v1 2>/dev/null)" 2>/dev/null)"
  _tr_v1_msg="$(_trg "$TR/work" tag -l --format='%(contents)' v1 2>/dev/null)"
  if [[ "$_tr_v1_type" == tag && -n "${_tr_v1_msg//[[:space:]]/}" ]]; then
    pass "tag-release: the vN alias is an ANNOTATED tag with a message (publishable under gpgsign)"
  else
    fail "tag-release: the vN alias is '${_tr_v1_type:-missing}' with message '${_tr_v1_msg:-<empty>}' — a lightweight alias makes publish abort for a signing operator (#506)"
  fi
  # Re-publishing an already-published tag must refuse — release tags are immutable.
  # Runs here, while 1.1.0 is still origin/main's newest core.version change.
  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  if ((_tr_rc != 0)) && grep -q 'already exists on origin' <<<"$_tr_out"; then
    pass "tag-release: --publish refuses to re-tag a published release (immutable)"
  else
    fail "tag-release: --publish would clobber a published tag (rc=$_tr_rc)"
  fi

  # The alias may only move FORWARD. The lease covers changes after REMOTE_MAJOR is read,
  # but a publisher that finishes BEFORE that read is seen as our own expected value, and
  # the leased push would satisfy the lease while rolling vN backward. Reaching that state
  # naturally needs a real race, so drive it directly: stage an UNPUBLISHED release (so the
  # immutability guard does not fire first), point origin's alias at a commit that is NOT
  # an ancestor of it, and require the refusal.
  printf '1.3.0\n' >"$TR/work/core.version"
  printf '# Changelog\n\n## [Unreleased]\n\n## [v1.3.0] - 2026-05-05\n\n- three\n' >"$TR/work/CHANGELOG.md"
  _trg "$TR/work" add -A; _trg "$TR/work" commit -q -m "release v1.3.0"
  _trg "$TR/work" push -q origin HEAD:main 2>/dev/null
  _tr_rel13="$(_trg "$TR/work" rev-parse HEAD)"
  # a commit off that line, published to origin so a ref there can point at it
  _trg "$TR/work" checkout -q -b divergent "$_tr_rel13~1" 2>/dev/null
  printf 'divergent\n' >"$TR/work/side.txt"
  _trg "$TR/work" add side.txt; _trg "$TR/work" commit -q -m "a commit off the release line"
  _tr_div="$(_trg "$TR/work" rev-parse HEAD)"
  _trg "$TR/work" push -q origin HEAD:refs/heads/divergent 2>/dev/null
  git -C "$TR/origin" update-ref refs/tags/v1 "$_tr_div"
  _trg "$TR/work" checkout -q main 2>/dev/null
  _trg "$TR/work" fetch -q --tags --force origin
  printf '1.3.0\n' >"$TR/work/core.version"

  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  _tr_v1_now="$(git -C "$TR/origin" rev-parse -q --verify 'v1^{commit}' 2>/dev/null)"
  if ((_tr_rc != 0)) && grep -q 'not an ancestor' <<<"$_tr_out" &&
    [[ "$_tr_v1_now" == "$_tr_div" ]] && [[ -z "$(_trg "$TR/work" tag -l 'v1.3.0')" ]]; then
    pass "tag-release: --publish refuses to move vN off its line (ancestry, not just the lease)"
  else
    fail "tag-release: alias moved off its line (rc=$_tr_rc, v1=$_tr_v1_now want=$_tr_div)"
  fi
  # restore a sane alias for the cases below
  git -C "$TR/origin" update-ref refs/tags/v1 "$_tr_rel13"
  _trg "$TR/work" fetch -q --tags --force origin

  # Publishing an OLDER release must be refused and must not move the alias. The property
  # matters more than which guard enforces it: resolution only accepts origin/main's
  # NEWEST core.version change, so an older version never resolves — and vN, which every
  # reusable-workflow caller pins to, cannot be pointed at an older Core.
  printf '1.0.0\n' >"$TR/work/core.version"
  _tr_v1_before="$(git -C "$TR/origin" rev-parse -q --verify 'v1^{commit}' 2>/dev/null)"
  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  _tr_v1_after="$(git -C "$TR/origin" rev-parse -q --verify 'v1^{commit}' 2>/dev/null)"
  if ((_tr_rc != 0)) && [[ -z "$(_trg "$TR/work" tag -l 'v1.0.0')" ]] &&
    [[ -n "$_tr_v1_before" && "$_tr_v1_before" == "$_tr_v1_after" ]]; then
    pass "tag-release: publishing an older release is refused and vN does not move backward"
  else
    fail "tag-release: older publish not refused (rc=$_tr_rc, v1 $_tr_v1_before -> $_tr_v1_after)"
  fi

  # A heading with an EMPTY body must be refused too. release.yml rejects an empty Release
  # body, and release.sh will promote an empty [Unreleased] without complaint — so without
  # this the immutable tag is pushed and the workflow fails afterwards, burning the version
  # for a reason knowable up front. Uses release.yml's own extraction, so the two agree.
  printf '2.5.0\n' >"$TR/work/core.version"
  printf '# Changelog\n\n## [Unreleased]\n\n## [v2.5.0] - 2026-04-04\n\n## [v1.1.0] - 2026-02-02\n\n- new\n' >"$TR/work/CHANGELOG.md"
  _trg "$TR/work" add -A; _trg "$TR/work" commit -q -m "release v2.5.0 (empty section)"
  _trg "$TR/work" push -q origin HEAD:main 2>/dev/null; _trg "$TR/work" fetch -q origin
  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  if ((_tr_rc != 0)) && grep -q 'is EMPTY' <<<"$_tr_out" &&
    [[ -z "$(_trg "$TR/work" tag -l 'v2.5.0')" ]]; then
    pass "tag-release: --publish refuses an empty [vX.Y.Z] section (no tag created)"
  else
    fail "tag-release: published a version release.yml would reject as an empty body (rc=$_tr_rc)"
  fi

  # A release commit with the right core.version but NO [vX.Y.Z] heading must be refused
  # BEFORE any tag exists: release.yml builds the Release body from that section, so
  # publishing first and finding out later leaves an immutable tag on a release that
  # cannot be published — the version is burned. (This guard was silently lost in an
  # earlier revision of this script, which is why it is pinned.) Both files move in ONE
  # commit, as release.sh + make tag produce. Runs LAST: it advances origin/main.
  printf '3.0.0\n' >"$TR/work/core.version"
  printf '# Changelog\n\n## [Unreleased]\n\n- deliberately no 3.0.0 heading\n' >"$TR/work/CHANGELOG.md"
  _trg "$TR/work" add -A; _trg "$TR/work" commit -q -m "release v3.0.0 (no heading)"
  _trg "$TR/work" push -q origin HEAD:main 2>/dev/null; _trg "$TR/work" fetch -q origin
  _tr_out="$(_tr_run --publish)"; _tr_rc=$?
  if ((_tr_rc != 0)) && grep -q 'has no' <<<"$_tr_out" &&
    [[ -z "$(_trg "$TR/work" tag -l 'v3.0.0')" ]]; then
    pass "tag-release: --publish refuses a release commit with no CHANGELOG heading (no tag created)"
  else
    fail "tag-release: published a version release.yml would fail on (rc=$_tr_rc)"
  fi
else
  skip "tag-release.sh two-phase ordering (git unavailable)"
fi

