# scripts/test/30-release-tooling.sh
# core/ pre-commit guard, auto-tag, release notes, freshness dashboard, fleet-member resolution
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── core/ pre-commit guard (lib/bootstrap-lib.sh blib_install_core_guard) ──────
# The guard hook (installed by sync-core.sh on every fan-out, and by a bootstrap on a
# fresh clone) is the mechanical backstop for "never hand-edit vendored core/". Drive it
# hermetically in throwaway git repos: assert it BLOCKS a core/ commit, ALLOWS a non-core
# commit, ALLOWS a core/ commit under the sync escape hatch, and never clobbers a foreign
# pre-commit hook. Pure bash + git (skipped where git is absent, like the nvim sections).
if have git; then
  hdr "core/ pre-commit guard (blib_install_core_guard)"
  # shellcheck source=lib/bootstrap-lib.sh
  source "$HERE/lib/bootstrap-lib.sh"
  # Pin git config to /dev/null (like the gcheck helper) so a host/CI global
  # core.hooksPath would not make git ignore our per-repo hook, and a global
  # commit.gpgsign can't break the non-core commit — keeps these assertions hermetic.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  GREPO="$SANDBOX/guardrepo"
  _guard_fresh() { # fresh repo with the guard installed
    rm -rf "$GREPO"
    mkdir -p "$GREPO/core"
    git -C "$GREPO" init -q
    git -C "$GREPO" config user.email t@example.com
    git -C "$GREPO" config user.name tester
    blib_install_core_guard "$GREPO" >/dev/null 2>&1
  }
  _guard_commit() { # _guard_commit <relpath> <allow:0|1> → echoes ok|blocked
    printf 'edit' >"$GREPO/$1"
    git -C "$GREPO" add -A
    local rc
    if [[ "${2:-0}" == 1 ]]; then
      DOTFILES_ALLOW_CORE_EDIT=1 git -C "$GREPO" commit -q -m x >/dev/null 2>&1
      rc=$?
    else
      git -C "$GREPO" commit -q -m x >/dev/null 2>&1
      rc=$?
    fi
    [[ $rc -eq 0 ]] && echo ok || echo blocked
  }

  _guard_fresh
  if [[ -x "$GREPO/.git/hooks/pre-commit" ]]; then pass "guard: pre-commit hook installed (+x)"; else fail "guard: hook missing or not executable"; fi

  _guard_fresh
  if [[ "$(_guard_commit core/x.txt 0)" == blocked ]]; then pass "guard: blocks a commit touching core/"; else fail "guard: did NOT block a core/ edit"; fi

  _guard_fresh
  if [[ "$(_guard_commit README.md 0)" == ok ]]; then pass "guard: allows a non-core commit"; else fail "guard: wrongly blocked a non-core commit"; fi

  _guard_fresh
  if [[ "$(_guard_commit core/y.txt 1)" == ok ]]; then pass "guard: DOTFILES_ALLOW_CORE_EDIT exempts a sync write"; else fail "guard: escape hatch did not allow a core/ commit"; fi

  # a pure DELETION of a vendored file (git rm core/…) drifts from Core too — must be blocked
  _guard_fresh
  printf 'seed' >"$GREPO/core/seed.txt"; git -C "$GREPO" add -A
  DOTFILES_ALLOW_CORE_EDIT=1 git -C "$GREPO" commit -q -m seed >/dev/null 2>&1
  git -C "$GREPO" rm -q core/seed.txt >/dev/null 2>&1
  if git -C "$GREPO" commit -q -m del >/dev/null 2>&1; then fail "guard: did NOT block a core/ deletion"; else pass "guard: blocks a core/ deletion (git rm)"; fi

  # a pre-existing, unrelated pre-commit hook must be preserved (not clobbered)
  rm -rf "$GREPO"; mkdir -p "$GREPO/core"; git -C "$GREPO" init -q
  printf '#!/bin/sh\nexit 0\n' >"$GREPO/.git/hooks/pre-commit"; chmod +x "$GREPO/.git/hooks/pre-commit"
  blib_install_core_guard "$GREPO" >/dev/null 2>&1
  if grep -q 'dotfiles-core-guard' "$GREPO/.git/hooks/pre-commit"; then fail "guard: clobbered a pre-existing custom hook"; else pass "guard: preserves a pre-existing custom pre-commit hook"; fi

  # core.hooksPath set → git ignores .git/hooks, so installing there is false
  # protection. The installer must skip rather than write an ignored hook.
  rm -rf "$GREPO"; mkdir -p "$GREPO/core"; git -C "$GREPO" init -q
  git -C "$GREPO" config core.hooksPath .githooks
  blib_install_core_guard "$GREPO" >/dev/null 2>&1
  if [[ -e "$GREPO/.git/hooks/pre-commit" ]] && grep -q 'dotfiles-core-guard' "$GREPO/.git/hooks/pre-commit" 2>/dev/null; then
    fail "guard: wrote into the ignored .git/hooks despite core.hooksPath"
  else
    pass "guard: skips when core.hooksPath is set (no false protection)"
  fi

  # worktree support (the reason the installer asks git instead of testing for a `.git`
  # DIR): in a linked worktree `.git` is a FILE, and hooks live in the shared common dir.
  # Install into the worktree and assert the guard actually blocks a core/ commit there.
  rm -rf "$GREPO"; mkdir -p "$GREPO/core"; git -C "$GREPO" init -q
  git -C "$GREPO" config user.email t@example.com; git -C "$GREPO" config user.name tester
  printf 'seed' >"$GREPO/seed.txt"; git -C "$GREPO" add -A
  git -C "$GREPO" commit -q -m seed >/dev/null 2>&1   # a worktree needs a commit to branch from
  GWT="$SANDBOX/guardwt"; rm -rf "$GWT"
  if git -C "$GREPO" worktree add -q "$GWT" -b wt >/dev/null 2>&1; then
    mkdir -p "$GWT/core"
    blib_install_core_guard "$GWT" >/dev/null 2>&1
    printf 'edit' >"$GWT/core/wt.txt"; git -C "$GWT" add -A
    if git -C "$GWT" commit -q -m x >/dev/null 2>&1; then
      fail "guard: did NOT block a core/ edit in a worktree (.git is a file)"
    else
      pass "guard: blocks a core/ edit in a linked worktree"
    fi
  else
    skip "guard: worktree case (git worktree unavailable)"
  fi
fi

# ── auto-tag version math + exit-code contract (scripts/auto-tag.sh) ──────────
# auto-tag.sh cuts an OS repo's next vX.Y.Z when a Core fan-out lands. Drive its
# (dry-run) computation hermetically: it must patch-bump the latest STRICT SemVer tag
# while IGNORING a prerelease/suffixed tag (v1.2.0-rc1) and the moving major alias (v1),
# stay octal-safe on a zero-padded component (v1.08.0), seed an untagged repo, no-op when
# HEAD is already a release, and usage-error a bad --bump — the exact glob/parse
# regressions a loose `git tag --list` glob would let through. THEN the exit-code contract
# the script's fix(release) history is all about: success → 0, no-op → 0, validation error
# → 2, and a REAL push failure → non-zero (never a silent green). The first three legs are
# hermetic (no network, no gh); the push-failure leg deliberately drives the real `git push`
# error branch — there is no `origin` in the sandbox, so the push fails and the script goes
# non-zero, which is exactly the contract under test. Pure bash + git.
if have git; then
  hdr "auto-tag version math + exit-code contract (scripts/auto-tag.sh)"
  AT="$HERE/scripts/auto-tag.sh"
  ATR="$SANDBOX/atrepo"
  _at_fresh() {
    rm -rf "$ATR"
    mkdir -p "$ATR"
    git -C "$ATR" init -q
    git -C "$ATR" config user.email t@example.com
    git -C "$ATR" config user.name tester
    git -C "$ATR" commit -q --allow-empty -m c1
  }
  _at_would() { # [bump] → echoes the tag it WOULD cut (dry-run), or noop / err
    local out
    out="$(env -u CORE_JSON "$AT" "$ATR" ${1:+--bump "$1"} --color never 2>&1)" || {
      echo err
      return 0
    }
    if grep -q 'already tagged' <<<"$out"; then
      echo noop
    else
      sed -n 's/.*would tag \(v[0-9][0-9.]*\).*/\1/p' <<<"$out"
    fi
  }

  _at_assert() { # _at_assert <label> <want> [bump]
    local got
    got="$(_at_would "${3:-}")"
    if [[ "$got" == "$2" ]]; then pass "$1"; else fail "$1 (got $got, want $2)"; fi
  }

  _at_fresh
  git -C "$ATR" tag -a v1.2.0 -m v1.2.0
  git -C "$ATR" tag -a v1.2.0-rc1 -m rc      # prerelease — must be ignored
  git -C "$ATR" tag v1                       # moving major alias — must be ignored
  git -C "$ATR" commit -q --allow-empty -m c2 # HEAD now past the tags
  _at_assert "auto-tag: patch-bumps latest strict tag, ignoring rc + vN alias" v1.2.1
  _at_assert "auto-tag: minor bump" v1.3.0 minor

  _at_fresh
  git -C "$ATR" tag -a v1.08.0 -m x          # zero-padded component — must not octal-error
  git -C "$ATR" commit -q --allow-empty -m c2
  _at_assert "auto-tag: octal-safe on a zero-padded component" v1.9.0 minor

  _at_fresh # no tags at all → seed the initial
  _at_assert "auto-tag: seeds v0.1.0 when the repo has no tag" v0.1.0

  _at_fresh
  git -C "$ATR" tag -a v2.0.0 -m x           # HEAD itself tagged → idempotent no-op
  _at_assert "auto-tag: no-op when HEAD already carries a release" noop

  _at_assert "auto-tag: rejects an invalid --bump" err bogus

  _at_fresh # --release is meaningless without --push (can't release an unpushed tag)
  if "$AT" "$ATR" --release --color never >/dev/null 2>&1; then
    fail "auto-tag: --release without --push should error"
  else
    pass "auto-tag: --release requires --push"
  fi

  # ── exit-code contract (the band-aids' history is exactly about exit codes) ──
  # auto-tag.sh has had repeated fix(release) commits over its exit codes: a no-op must
  # be 0, a usage/validation error 2, and a REAL create failure non-zero (not a silent
  # green). Assert all three legs HERMETICALLY — no network, no gh. Helper: run + echo rc.
  _at_rc() { "$AT" "$ATR" "$@" --color never >/dev/null 2>&1; echo $?; }

  # 1) SUCCESS leg — a plain dry-run on a tagged repo computes a bump and exits 0.
  _at_fresh
  git -C "$ATR" tag -a v1.0.0 -m v1.0.0
  git -C "$ATR" commit -q --allow-empty -m c2
  if [[ "$(_at_rc)" == 0 ]]; then pass "auto-tag: success (dry-run computes a bump) exits 0"; else fail "auto-tag: dry-run should exit 0"; fi

  # 2) NO-OP leg — HEAD already carries a release → idempotent, exits 0 (not an error).
  _at_fresh
  git -C "$ATR" tag -a v1.0.0 -m v1.0.0   # tags HEAD
  if [[ "$(_at_rc)" == 0 ]]; then pass "auto-tag: no-op (HEAD already tagged) exits 0"; else fail "auto-tag: no-op should exit 0"; fi

  # 3) USAGE/VALIDATION error — a malformed --initial is rejected with exit 2 (not 1).
  _at_fresh   # untagged repo, so --initial is the seed path that validates it
  if [[ "$(_at_rc --initial 1.2)" == 2 ]]; then pass "auto-tag: malformed --initial exits 2"; else fail "auto-tag: bad --initial should exit 2"; fi

  # 4) REAL PUSH-FAILURE leg — exercise auto-tag.sh's push error branch (the one that
  #    `fail`s + exits 1 when `git push origin <tag>` fails). On a freshly-tagged repo the
  #    bump is computable and unique, so the script creates the tag and then tries to push
  #    it; the sandbox has NO `origin` remote, so the push genuinely fails and the script
  #    goes non-zero. This is the "a real push failure must go red, not green" contract the
  #    fix(release) history is about. (Not hermetic — it intentionally hits the push path;
  #    if an `origin` were ever added to the sandbox this leg would need a guaranteed-to-fail
  #    remote instead.)
  _at_fresh
  git -C "$ATR" tag -a v1.0.0 -m v1.0.0         # latest release on c1
  git -C "$ATR" commit -q --allow-empty -m c2   # HEAD past the tag → a real bump (v1.0.1) to push
  _rc_push="$(_at_rc --push)"
  if [[ "$_rc_push" != 0 ]]; then pass "auto-tag: --push with no reachable origin fails non-zero (rc=$_rc_push)"; else fail "auto-tag: failed push should exit non-zero, got 0"; fi
else
  skip "auto-tag version math + exit-code contract (git unavailable)"
fi

# ── release-notes drafting (scripts/gen-release-notes.sh) ─────────────────────
# gen-release-notes.sh turns an OS repo's Conventional Commits in a range into the grouped
# markdown body auto-tag.sh feeds `gh release create --notes-file` (a real changelog,
# not a bare tag). Assert hermetically: the right groups appear in cliff.toml order, the
# subject is rendered as cliff renders it, a chore(release) commit is skipped and an
# unconventional subject is dropped, and a range with no conventional commits prints
# NOTHING (exit 0 → the caller falls back to gh --generate-notes). Pure bash + git.
#
# "as cliff renders it" is load-bearing and was the one thing this block got wrong: it used
# to assert `Feat(x): add a thing`, pinning the prefix-retaining bug rather than the twin's
# contract. cliff.toml sets conventional_commits = true, so git-cliff's `commit.message` is
# the DESCRIPTION alone — the type/scope/`!` are parsed off — and the bullet reads
# "Add a thing" under a heading that already says Features. Both directions are asserted now
# (description present AND prefix absent), so the bug cannot come back green.
if have git; then
  hdr "release-notes drafting (scripts/gen-release-notes.sh)"
  GRN="$HERE/scripts/gen-release-notes.sh"
  GRNR="$SANDBOX/grnrepo"
  rm -rf "$GRNR"; mkdir -p "$GRNR"
  git -C "$GRNR" init -q
  git -C "$GRNR" config user.email t@example.com
  git -C "$GRNR" config user.name tester
  git -C "$GRNR" commit -q --allow-empty -m "chore: seed"
  git -C "$GRNR" tag v1.0.0
  git -C "$GRNR" commit -q --allow-empty -m "fix: correct a bug"          # Bug Fixes
  git -C "$GRNR" commit -q --allow-empty -m "feat(x): add a thing"        # Features (later, but must sort first)
  git -C "$GRNR" commit -q --allow-empty -m "feat(y)!: upend a contract"  # breaking → must stay visible
  git -C "$GRNR" commit -q --allow-empty -m "chore(release): v1.1.0"      # must be skipped
  git -C "$GRNR" commit -q --allow-empty -m "totally unconventional line" # must be dropped
  git -C "$GRNR" commit -q --allow-empty -m "fixing a flaky test"         # prose, no delimiter → dropped
  git -C "$GRNR" commit -q --allow-empty -m "refactor:"                   # no description → dropped
  _grn_out="$(env -u CORE_JSON "$GRN" "$GRNR" v1.0.0 HEAD 2>/dev/null)"

  if grep -q '^### Features$' <<<"$_grn_out" && grep -q '^### Bug Fixes$' <<<"$_grn_out"; then
    pass "gen-notes: groups feat + fix under cliff.toml headings"
  else fail "gen-notes: expected Features + Bug Fixes headings"; fi

  if grep -q 'Add a thing' <<<"$_grn_out" && grep -qE '\([0-9a-f]{7}\)' <<<"$_grn_out"; then
    pass "gen-notes: upper-firsts the description and appends a 7-char SHA"
  else fail "gen-notes: subject/sha format wrong"; fi

  # The regression this block used to enshrine: cliff strips type/scope, so no bullet may
  # carry a Conventional prefix. Asserted over the whole body, not just the one subject.
  if ! grep -qiE '^- (\*\*BREAKING\*\* )?(feat|fix|docs|chore|perf|refactor|test|ci|build|style)(\([^)]*\))?!?:' <<<"$_grn_out"; then
    pass "gen-notes: strips the Conventional prefix (cliff conventional_commits=true)"
  else fail "gen-notes: a bullet kept its type(scope): prefix"; fi

  # Deliberate divergence from cliff (which renders breaking commits indistinguishably,
  # since the template interpolates commit.message and never commit.breaking): a `!` must
  # survive into the draft, because it is what drives the SemVer major bump.
  if grep -q '^- \*\*BREAKING\*\* Upend a contract' <<<"$_grn_out"; then
    pass "gen-notes: marks a breaking (!) commit instead of flattening it"
  else fail "gen-notes: breaking marker lost"; fi

  # A type with no description ("refactor:") is unparseable to git-conventional, so cliff's
  # filter_unconventional drops it — verified against git-cliff 2.13.1, which emits no
  # Refactoring group for that input. It must not surface as a bare or empty bullet.
  if ! grep -q '^### Refactoring$' <<<"$_grn_out" && ! grep -qE '^- (Refactor:)?$' <<<"$_grn_out"; then
    pass "gen-notes: a prefix-only subject (no description) is dropped, not an empty bullet"
  else fail "gen-notes: a description-less commit leaked into the notes"; fi

  if ! grep -qi 'release' <<<"$_grn_out" && ! grep -qi 'unconventional' <<<"$_grn_out"; then
    pass "gen-notes: skips chore(release) and drops unconventional commits"
  else fail "gen-notes: a skipped/dropped commit leaked into the notes"; fi

  # "fixing a flaky test" starts with 'fix' but has no `:` delimiter → must be filtered,
  # not grouped under Bug Fixes (the conventional-delimiter anchor; mirrors filter_unconventional).
  if ! grep -qi 'flaky' <<<"$_grn_out"; then
    pass "gen-notes: prose starting with a type word (no delimiter) is dropped"
  else fail "gen-notes: unconventional prose leaked into a group"; fi

  # commit_parsers order, not commit order: Features (committed later) must lead Bug Fixes.
  if [[ "$_grn_out" == "### Features"* ]]; then
    pass "gen-notes: emits groups in cliff.toml order (Features first)"
  else fail "gen-notes: group order is not the cliff.toml order"; fi

  git -C "$GRNR" tag v1.1.0
  git -C "$GRNR" commit -q --allow-empty -m "just some words"
  if _grn_empty="$(env -u CORE_JSON "$GRN" "$GRNR" v1.1.0 HEAD)"; [[ -z "$_grn_empty" ]]; then
    pass "gen-notes: a no-conventional-commit range prints nothing (caller falls back)"
  else fail "gen-notes: expected empty output for a non-conventional range"; fi

  # The section order now lives in TWO places: cliff.toml's `<N>` sort keys (which the
  # template strips back out) and this script's ORDER array. They must not drift — that is
  # the whole point of the `<N>` keys, which exist only to make git-cliff emit the twin's
  # order instead of Tera's alphabetical group_by.
  #
  # SORT, don't read in file order. What git-cliff renders is the LEXICAL order of the full
  # group strings — Tera's group_by sorts by the attribute value — so the position of a line
  # in commit_parsers is not what decides anything. Reading the file top-to-bottom would pass
  # happily while `<0>` and `<1>` were swapped in place, i.e. while cliff emitted Bug Fixes
  # ahead of Features again. So: extract each group WITH its key, sort exactly as Tera does
  # (LC_ALL=C for a byte-order sort that does not drift with the runner's locale), and only
  # then strip the keys. The result is the effective output order, which is the thing that
  # has to match ORDER. (chore(release) is skip=true and contributes no group.)
  #
  # `sed -E`, not BRE `\+`: BSD sed has no `\+`, so the BRE form silently matched nothing on
  # macOS and this guard reported a phantom drift against an empty string. -E is understood
  # by both GNU and BSD sed.
  if [[ -f "$HERE/cliff.toml" ]]; then
    _cliff_order="$(sed -n -E 's/.*group = "(<[0-9]+> [^"]*)".*/\1/p' "$HERE/cliff.toml" |
      LC_ALL=C sort | sed -E 's/^<[0-9]+> //' | paste -sd'|' -)"
    _twin_order="$(sed -n -E 's/.*split\("([^"]*)", ORDER.*/\1/p' "$GRN")"
    if [[ -n "$_cliff_order" && "$_cliff_order" == "$_twin_order" ]]; then
      pass "gen-notes: group order matches cliff.toml's <N> sort keys"
    else
      fail "gen-notes: group order drifted — cliff.toml '$_cliff_order' vs twin '$_twin_order'"
    fi

    # The `<N>` keys are single-digit, so they sort correctly only up to ten groups:
    # "<10>" would land between "<1>" and "<2>" and silently reorder the notes.
    _cliff_groups="$(grep -cE 'group = "<[0-9]+>' "$HERE/cliff.toml")"
    if ((_cliff_groups <= 10)) && ! grep -q 'group = "<[0-9][0-9]' "$HERE/cliff.toml"; then
      pass "gen-notes: cliff.toml stays within the single-digit <N> sort ceiling ($_cliff_groups/10)"
    else
      fail "gen-notes: cliff.toml has >10 groups or a two-digit <N> — the sort key needs widening"
    fi
  else
    skip "gen-notes: cliff.toml order cross-check (no cliff.toml)"
  fi
else
  skip "release-notes drafting (git unavailable)"
fi

# ── dashboard live-signal error handling (scripts/freshness-dashboard.sh) ─────
# The weekly board embeds LIVE GitHub API answers, and `gh api` does something surprising
# on an HTTP error: it SKIPS --jq and copies the raw error BODY to STDOUT, summarising only
# to stderr. So the old `2>/dev/null || true` silenced the wrong stream, threw away the one
# reliable signal (the exit code), and let {"message":"Not Found",…} through as if it were
# a value — every `// empty` and `[ -n "$n" ]` guard downstream waved it past (issue #324:
# a 404 body rendered as dotfiles-web's release tag, a 403 body as htpx's issue count).
# Shellcheck cannot see any of that, so drive it hermetically: a programmable `gh` stub
# reproducing gh's real error shape (body on stdout, `(HTTP NNN)` on stderr, non-zero rc),
# in a throwaway repo root whose four sub-check scripts are stubs — the real
# update-nvim-plugins.sh --check drives a full `:Lazy! sync` (minutes, network).
hdr "dashboard live-signal error handling (scripts/freshness-dashboard.sh)"
FDR="$SANDBOX/fdrepo"
FDBIN="$SANDBOX/fdbin"
rm -rf "$FDR" "$FDBIN"
mkdir -p "$FDR/scripts/lib" "$FDR/lib" "$FDBIN" "$SANDBOX/fdfleet"
cp "$HERE/scripts/freshness-dashboard.sh" "$FDR/scripts/"
# The board sources lib/common.sh for load_os_repos (#669), and common.sh sources
# ../../lib/ux.sh — same two libs the fleet-drift fixture below carries, for the same reason.
cp "$HERE/scripts/lib/common.sh" "$FDR/scripts/lib/"
cp "$HERE/lib/ux.sh" "$FDR/lib/"
for _fd_s in fleet-drift core-integrity update-plugins update-nvim-plugins; do
  printf '#!/bin/sh\nexit 0\n' >"$FDR/scripts/$_fd_s.sh"
  chmod +x "$FDR/scripts/$_fd_s.sh"
done
# One OS repo → REPOS is 5 (core, Windows, web, MacBook, htpx) → 10 search calls, which is
# what the ladder-latch count below is derived from.
printf 'dotfiles-MacBook\n' >"$FDR/scripts/os-repos.txt"

cat >"$FDBIN/gh" <<'GHSTUB'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
"auth status"*)     exit 1 ;;   # so the GH_OK=0 degradation case is reachable
*releases/latest*)  # never-released repo: gh prints the 404 BODY to stdout, rc 1
  printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}\n'
  echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
*/tags*)
  case "${GH_TAGS:-ok}" in
  none) exit 0 ;;               # genuinely tagless: rc 0, --jq yields empty
  fail) printf '{"message":"Bad credentials","status":"401"}\n'
        echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
  *)    printf 'v1.2.3\n' ;;
  esac ;;
*compare*)          printf '7\n' ;;
*search/issues*)
  # GH_SEARCH=flaky — limited on attempts 1-2, healthy on 3-6, limited again from 7. Two
  # DISTINCT episodes: the first clears mid-ladder (must recover), the second never does
  # (must exhaust and latch). One episode alone cannot tell latch-on-exhaustion from
  # latch-on-ladder-start; the second episode is what separates them. The attempt counter
  # is GH_CALLS itself (appended above), so it survives the separate stub processes a
  # single ladder spawns.
  if [ "${GH_SEARCH:-limited}" = flaky ]; then
    _n="$(grep -c 'search/issues' "$GH_CALLS")"
    [ "$_n" -ge 3 ] && [ "$_n" -le 6 ] && { printf '4\n'; exit 0; }
  fi
  printf '{"message":"You have exceeded a secondary rate limit.","status":"403"}\n'
  echo 'gh: You have exceeded a secondary rate limit (HTTP 403)' >&2; exit 1 ;;
esac
exit 0
GHSTUB
chmod +x "$FDBIN/gh"

# _fd_run — board on stdout, script's rc in $?. Pace/backoff zeroed so the ladder is
# exercised without sleeping through it. GITHUB_REPOSITORY_OWNER is PINNED, not inherited:
# the script defaults OWNER from it, GitHub Actions always sets it, and on a fork it is the
# fork owner — so an inherited value would fail the URL assertions below in a fork's CI
# even with the dashboard behaving correctly. A fixture owner (not the real `dotgibson`)
# keeps that pin honest: drop it and the assertions fail immediately, anywhere.
_fd_run() {
  PATH="$FDBIN:$PATH" GH_TOKEN=stub GH_CALLS="$SANDBOX/gh.calls" GH_TAGS="${GH_TAGS:-ok}" \
    GH_SEARCH="${GH_SEARCH:-limited}" GITHUB_REPOSITORY_OWNER=fixtureowner \
    DASH_SEARCH_PACE=0 DASH_RETRY_BASE="${DASH_RETRY_BASE:-0}" \
    DASH_RETRY_BUDGET="${DASH_RETRY_BUDGET:-60}" \
    env -u CORE_JSON bash "$FDR/scripts/freshness-dashboard.sh" --root "$SANDBOX/fdfleet" 2>/dev/null
}

: >"$SANDBOX/gh.calls"
_fd_board="$(GH_TAGS=none _fd_run)"
_fd_rc=$?

# The #324 regression itself: not one byte of an API error body may reach the board.
if ! grep -qE '"message"|documentation_url|"status":"40' <<<"$_fd_board"; then
  pass "dashboard: no GitHub API error body reaches the board"
else fail "dashboard: an API error body leaked into the rendered board"; fi

# `— (no tags)` was UNREACHABLE before the fix for any repo whose 404 body carries a
# `message` key, because the blob made `tag` non-empty and skipped the /tags fallback.
if grep -q -- '— (no tags)' <<<"$_fd_board"; then
  pass "dashboard: a genuinely tagless repo renders '— (no tags)'"
else fail "dashboard: '— (no tags)' branch still unreachable"; fi

# A rate-limited search must degrade to `?` in BOTH live tallies — the Renovate cell and
# the judgment-layer link text (the latter is the exact cell that rendered htpx's 403).
if grep -q '| dotfiles-core | ? |' <<<"$_fd_board" &&
  grep -qF '[?](https://github.com/fixtureowner/dotfiles-core/issues' <<<"$_fd_board"; then
  pass "dashboard: a rate-limited search renders '?' in both tallies"
else fail "dashboard: a failed search did not degrade to '?'"; fi

# A reporter never fails the build, even with every live call erroring.
if [ "$_fd_rc" -eq 0 ]; then
  pass "dashboard: still exits 0 with every live call failing"
else fail "dashboard: exited $_fd_rc with failing live calls (must always be 0)"; fi

# The ladder must run ONCE and then latch. 10 search calls → 4 invocations for the first
# (initial + 3 retries) + 1 each for the other 9 = 13. A variable latch would re-ladder
# every call (40) because the helpers run inside `$( )`; no latch at all, also 40.
_fd_calls="$(grep -c 'search/issues' "$SANDBOX/gh.calls")"
if [ "$_fd_calls" -eq 13 ]; then
  pass "dashboard: 403 backoff ladder runs once per run, then latches (13 search calls)"
else fail "dashboard: expected 13 search calls (one ladder + 9 latched), got $_fd_calls"; fi

# A FAILED tag probe must not masquerade as a confident "this repo has no tags" — that is
# the distinction the propagated exit status buys, and the board asserted it without
# evidence before.
_fd_board_fail="$(GH_TAGS=fail _fd_run)"
if grep -q '| dotfiles-web | ? | ? |' <<<"$_fd_board_fail" &&
  ! grep -q -- '(no tags)' <<<"$_fd_board_fail"; then
  pass "dashboard: a failed tag probe renders '?', not '— (no tags)'"
else fail "dashboard: a failed tag probe was reported as 'no tags'"; fi

# A TRANSIENT limit that clears must RECOVER, not latch — the ladder exists precisely so a
# blip still yields the real number — while a limit that never clears must still exhaust
# and latch. Two episodes (see the stub): the Renovate tally's first 4 repos ride out
# episode 1 and report real counts, htpx opens episode 2 and exhausts, and the judgment
# tally is latched from there on.
#
# The call count is what pins the DESIGN. 15 = 3 (episode-1 ladder recovers) + 3 (healthy)
# + 4 (episode-2 ladder exhausts) + 6 (latched). Latching when a ladder STARTS instead of
# when it is exhausted gives 12, because episode 2 would be refused without ever retrying —
# i.e. one recoverable blip would permanently downgrade the rest of the run.
: >"$SANDBOX/gh.calls"
_fd_flaky="$(GH_SEARCH=flaky GH_TAGS=none _fd_run)"
_fd_flaky_calls="$(grep -c 'search/issues' "$SANDBOX/gh.calls")"
if [ "$_fd_flaky_calls" -eq 15 ] &&
  grep -q '| dotfiles-core | 4 |' <<<"$_fd_flaky" && grep -q '| htpx | ? |' <<<"$_fd_flaky"; then
  pass "dashboard: a transient 403 recovers; only an exhausted ladder latches"
else fail "dashboard: recover-vs-latch wrong (calls=$_fd_flaky_calls, expected 15)"; fi

# Cumulative-sleep ceiling. The exhausted-ladder latch cannot bound a run where every
# ladder RECOVERS, so DASH_RETRY_BUDGET caps total backoff instead. Budget 0 proves the
# gate: the very first 403 exceeds it, so no call ever sleeps and each of the 10 makes
# exactly one invocation (vs 13 when the budget allows one full ladder).
: >"$SANDBOX/gh.calls"
_fd_budget="$(DASH_RETRY_BASE=1 DASH_RETRY_BUDGET=0 _fd_run)"
_fd_budget_rc=$?
_fd_budget_calls="$(grep -c 'search/issues' "$SANDBOX/gh.calls")"
if [ "$_fd_budget_calls" -eq 10 ] && [ "$_fd_budget_rc" -eq 0 ]; then
  pass "dashboard: the cumulative backoff budget caps total sleep across ladders"
else fail "dashboard: backoff budget not enforced (calls=$_fd_budget_calls, expected 10)"; fi

# Without gh/token the board must still compose, with the unavailable note.
_fd_degraded="$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$FDBIN:$PATH" \
  GH_CALLS="$SANDBOX/gh.calls" \
  env -u CORE_JSON bash "$FDR/scripts/freshness-dashboard.sh" --root "$SANDBOX/fdfleet" 2>/dev/null)"
_fd_deg_rc=$?
if [ "$_fd_deg_rc" -eq 0 ] && grep -q 'Unavailable in this run' <<<"$_fd_degraded"; then
  pass "dashboard: degrades to the 'unavailable' note without gh/token"
else fail "dashboard: GH_OK=0 degradation path broken (rc=$_fd_deg_rc)"; fi

# ── fleet-member resolution (scripts/lib/common.sh :: resolve_repo_dir) ───────
# sync-core.sh, fleet-drift.sh and core-integrity.sh all turn a repo NAME from
# scripts/os-repos.txt into a path. They used to do it by string-joining onto the fleet
# root, which is right until a repo is RENAMED upstream: git follows the rename, the
# directory name does not, and all three scripts then reported "not cloned"/"not checked
# out" for a repo that was present, vendored and pristine. The fan-out SKIPPED it.
#
# Driven here rather than only through the fixtures because the failure is entirely in
# this one function, and the sharp edges (URL shapes, case-folding, precedence, a clone
# with no origin) are cheap to enumerate directly and expensive to stage end-to-end.
if have git; then
  hdr "fleet-member resolution (resolve_repo_dir)"
  RRD="$SANDBOX/repodir"
  rm -rf "$RRD"
  mkdir -p "$RRD/root"
  _rrd_repo() { # _rrd_repo <dir-name> [origin-url] — a clone, optionally with an origin
    local d="$RRD/root/$1"
    mkdir -p "$d"
    git -C "$d" init -q >/dev/null 2>&1
    [[ -n "${2:-}" ]] && git -C "$d" remote add origin "$2"
    return 0
  }
  _rrd_is() { # _rrd_is <label> <asked-name> <want-dir-or-empty>
    local got rc
    got="$(resolve_repo_dir "$RRD/root" "$2")" || rc=1
    rc="${rc:-0}"
    if [[ "$got" == "${3:+$RRD/root/$3}" ]] && [[ "$rc" == "$([[ -n "$3" ]] && echo 0 || echo 1)" ]]; then
      pass "$1"
    else
      fail "$1 (got='$got' rc=$rc, want='${3:-<unresolved>}')"
    fi
  }

  # 1) The fast path: a directory of the right name resolves with no remote at all — the
  #    conventional layout must not acquire a dependency on having an origin configured.
  mkdir -p "$RRD/root/dotfiles-Plain"
  _rrd_is "resolve: a directory matching the name wins outright (no git needed)" dotfiles-Plain dotfiles-Plain

  # 2) THE regression: no directory of that name, but a clone whose origin says it IS
  #    that repo. This is the dotfiles-Kali → dotfiles-Offense shape.
  _rrd_repo old-name https://github.com/dotgibson/dotfiles-Renamed.git
  _rrd_is "resolve: a renamed repo is found by its origin URL" dotfiles-Renamed old-name

  # 3) Both URL shapes. An scp-style remote (git@host:owner/repo) has no slash before the
  #    owner, so a naive ${url##*/} works on one form and silently fails on the other.
  _rrd_repo scp-clone git@github.com:dotgibson/dotfiles-Scp.git
  _rrd_is "resolve: an scp-style git@host:owner/repo remote parses" dotfiles-Scp scp-clone
  _rrd_repo bare-clone https://github.com/dotgibson/dotfiles-NoSuffix
  _rrd_is "resolve: an https remote with no .git suffix parses" dotfiles-NoSuffix bare-clone

  # 4) GitHub repo names are case-insensitive, so a clone of dotfiles-offense IS
  #    dotfiles-Offense. Matching case-sensitively would reintroduce the same false miss.
  _rrd_repo lower-clone https://github.com/dotgibson/dotfiles-mixedcase.git
  _rrd_is "resolve: matching is case-insensitive, like GitHub itself" dotfiles-MixedCase lower-clone

  # 5) Precedence. With BOTH a correctly-named directory and some other clone claiming the
  #    name via its origin, the directory must win — otherwise adding the fallback could
  #    silently move an existing, working fan-out onto a different tree.
  mkdir -p "$RRD/root/dotfiles-Both"
  _rrd_repo decoy-clone https://github.com/dotgibson/dotfiles-Both.git
  _rrd_is "resolve: the directory-name match takes precedence over a URL match" dotfiles-Both dotfiles-Both

  # 6) Nothing matches → return 1 and print nothing, so a caller's `|| path=<conventional>`
  #    fallback fires and the "not cloned at <path>" advice still names the expected path.
  _rrd_is "resolve: an absent repo is unresolved (rc 1, no output)" dotfiles-Absent ""

  # 7) A clone with NO origin must be stepped over, not crash the sweep. The scripts run
  #    under `set -euo pipefail`, so a bare `git remote get-url` failure inside the loop is
  #    a live abort risk, not a cosmetic one — and a fleet root routinely holds unrelated
  #    checkouts (dotfiles-web, a scratch clone) that have nothing to say about the fleet.
  _rrd_repo orphan-clone
  # rc captured off the `||`, not read back from `$?`: the distinction that matters is
  # 1 (searched, found nothing) vs anything else (aborted mid-scan), and only an explicit
  # capture keeps those apart.
  _rrd_orphan_rc=0
  (
    set -euo pipefail
    resolve_repo_dir "$RRD/root" dotfiles-Absent
  ) >/dev/null 2>&1 || _rrd_orphan_rc=$?
  if [[ "$_rrd_orphan_rc" -eq 1 ]]; then
    pass "resolve: a remote-less clone is skipped, not fatal under set -e"
  else
    fail "resolve: scanning a clone with no origin exited $_rrd_orphan_rc (want 1)"
  fi
fi
