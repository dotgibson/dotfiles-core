#!/usr/bin/env bash
# scripts/tag-release.sh — finish a release, in TWO phases: commit, then (after the PR
# merges) publish the tags.
# ──────────────────────────────────────────────────────────────────────────────
# `release.sh` deliberately stops short of git: it bumps core.version, promotes the
# CHANGELOG, runs the audit, and PRINTS the commit/tag/push recipe for the operator to
# run by hand. That hand-run recipe is the last drift-prone step — a fat-fingered tag
# name or a forgotten `git push --tags` is exactly the class of mistake the rest of the
# release path is mechanized to avoid. This is the other half.
#
# WHY TWO PHASES — the tag is created LAST, never before the merge:
#
# This script used to commit AND tag in one go, leaving a local `vX.Y.Z` sitting on a
# commit that was not yet on main. That window is not safe, and no amount of
# `--no-follow-tags` discipline closes it: the flag governs YOUR push, while the tag
# lives in SHARED .git state that any other process can push. It happened — a concurrent
# session pushed its own branch with `push.followTags` set, carried the release tag to
# origin, and fired release.yml + sync-fanout.yml against an unmerged commit, opening
# eight bad vendor PRs across the fleet. The version number had to be retired.
#
# So the invariant is now structural rather than procedural:
#
#     a vX.Y.Z tag only ever exists on a commit that is already on origin/main.
#
# Phase 1 (default) commits the release and creates NO tag — there is nothing for a
# stray push to carry. Phase 2 (--publish) runs after the PR merges: it proves
# origin/main actually carries this version, then tags origin/main and pushes.
#
# Usage:
#   ./scripts/tag-release.sh              # phase 1: commit core.version + CHANGELOG
#   ./scripts/tag-release.sh --publish    # phase 2: tag origin/main + push (AFTER merge)
#   make tag                              # phase 1, via the Makefile façade
#   make publish                          # phase 2
#
# Env:
#   TAG_SKIP_AUDIT=1   skip the green-tree gate (escape hatch for a tree you just audited)
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"

usage() {
  cat <<'EOF'
usage: tag-release.sh [--publish]

Finish the release that release.sh staged, in two phases.

  (no flag)     PHASE 1 — prove the tree green and commit core.version + CHANGELOG.md.
                Creates NO tag: until the commit is on origin/main there must be no
                vX.Y.Z for a stray push to carry to the remote. Prints the land recipe.

  --publish     PHASE 2 — run AFTER the release PR merges. Proves origin/main really
                carries this core.version, then creates the annotated vX.Y.Z and moves
                the vN alias AT origin/main, and pushes both.

  -h, --help    show this help and exit

Env: TAG_SKIP_AUDIT=1 skips the audit gate (use only on a tree you just audited).
EOF
}

MODE=commit
case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
--publish)
  MODE=publish
  ;;
--push)
  # Removed deliberately. Its whole semantic was "push the tag we just made on the
  # PRE-merge commit", which is the failure this script now exists to prevent.
  fail "tag-release.sh: --push was removed — it pushed a tag for a commit that was not on main yet"
  fail "run this with no flag to commit, land the PR, then re-run with --publish"
  exit 2
  ;;
"") ;;
*)
  fail "tag-release.sh: unknown argument '$1'"
  usage >&2
  exit 2
  ;;
esac

have git || {
  fail "tag-release.sh: git not found"
  exit 1
}
git rev-parse --git-dir >/dev/null 2>&1 || {
  fail "tag-release.sh: not a git checkout"
  exit 1
}

CHANGELOG="CHANGELOG.md"
VERFILE="core.version"
[[ -r "$VERFILE" && -r "$CHANGELOG" ]] || {
  fail "tag-release.sh: $VERFILE or $CHANGELOG missing/unreadable"
  exit 1
}

VERSION="$(tr -d '[:space:]' <"$VERFILE")"
# A tag stamps a clean SemVer release — the same shape release.sh enforces. A
# prerelease/dirty core.version means no release was cut; refuse rather than tag junk.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "tag-release.sh: core.version ('$VERSION') is not a clean release (X.Y.Z) — run 'make release VERSION=X.Y.Z' first"
  exit 2
fi
TAG="v$VERSION"

MAJOR="v${VERSION%%.*}"

# ── PHASE 2 — publish the tags for a release that has ALREADY landed on main ──
if [[ "$MODE" == publish ]]; then
  hdr "publish $TAG (tag origin/main)"
  git fetch -q origin 2>/dev/null || {
    fail "tag-release.sh: could not fetch origin — publishing needs the remote's view of main"
    exit 1
  }
  git rev-parse -q --verify origin/main >/dev/null || {
    fail "tag-release.sh: no origin/main to tag"
    exit 1
  }

  # THE guard. core.version at origin/main is what proves the release commit actually
  # merged — not that a branch exists, not that CI was green, but that the released
  # version is on main right now. Everything else here is a sanity check; this is the
  # one that makes it impossible to publish a tag for a version main does not carry.
  ORIGIN_VERSION="$(git show origin/main:core.version 2>/dev/null | tr -d '[:space:]')"
  if [[ "$ORIGIN_VERSION" != "$VERSION" ]]; then
    fail "tag-release.sh: origin/main carries core.version '$ORIGIN_VERSION', not '$VERSION' — the release PR has not merged yet"
    fail "land it first: the recipe is printed by a no-flag run"
    exit 1
  fi
  pass "origin/main carries core.version $VERSION"

  # Captured first, NOT piped into `grep -q`. Under `set -o pipefail` that pipeline
  # reports FAILURE on a successful match: grep -q exits the moment it matches, git show
  # dies of SIGPIPE (141) part-way through a 4000-line file, and pipefail surfaces git's
  # status rather than grep's. The phase-1 guard below is immune only because it greps the
  # file directly instead of through a pipe.
  ORIGIN_CHANGELOG="$(git show origin/main:"$CHANGELOG" 2>/dev/null)"
  if ! grep -qE "^## +\[v?${VERSION//./\\.}\]" <<<"$ORIGIN_CHANGELOG"; then
    fail "tag-release.sh: origin/main's $CHANGELOG has no '## [v$VERSION]' heading"
    exit 1
  fi
  pass "origin/main's $CHANGELOG carries the [v$VERSION] heading"

  # Never clobber a published release. vX.Y.Z is immutable by ruleset, so a re-push
  # would be rejected anyway — fail here with a reason instead of a git error.
  if git ls-remote --tags --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
    fail "tag-release.sh: $TAG already exists on origin — a published release tag is immutable"
    exit 1
  fi

  if ! git tag -fa "$TAG" origin/main -m "$TAG"; then
    fail "tag-release.sh: could not create $TAG at origin/main"
    exit 1
  fi
  pass "tagged $TAG at origin/main ($(git rev-parse --short origin/main))"

  # The moving MAJOR alias reusable-workflow callers pin to (RELEASE-STRATEGY.md
  # §"Pinning reusable workflows"). Force-moved to each new vN.x so callers pick up
  # patch/minor guard fixes without a manual bump.
  if ! git tag -f "$MAJOR" origin/main >/dev/null; then
    fail "tag-release.sh: could not move major tag $MAJOR"
    exit 1
  fi
  pass "moved major tag $MAJOR → origin/main"

  # Independent pushes: vX.Y.Z is a fresh immutable tag, vN is a force-move. Chaining
  # them with && would skip the alias if the first push raced someone else.
  push_rc=0
  git push origin "$TAG" || push_rc=1
  git push -f origin "$MAJOR" || push_rc=1
  if ((push_rc)); then
    fail "tag-release.sh: tag push failed — retry: git push origin $TAG ; git push -f origin $MAJOR"
    exit 1
  fi
  pass "pushed $TAG and $MAJOR"

  printf '\n%s──────── %s published ────────%s\n' "$c_blu" "$TAG" "$c_rst"
  cat <<EOF
  release.yml publishes the GitHub Release from the CHANGELOG section, then
  sync-fanout.yml opens a vendor PR in every repo in scripts/os-repos.txt.
  It opens PRs and never merges them — review canary-first (RELEASE-STRATEGY.md).

  verify:  gh run list --workflow release --limit 1
           gh run list --workflow sync-fanout --limit 1
EOF
  exit 0
fi

# ── PHASE 1 — commit the release. NO TAG IS CREATED HERE. ────────────────────
hdr "commit $TAG (from core.version)"

# Guard 1: never clobber an existing tag — a re-run after a successful tag must be a
# clear no-op error, not a silent second tag or a moved ref.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag-release.sh: tag $TAG already exists — bump core.version or delete the tag to re-cut"
  exit 1
fi

# Guard 2: the CHANGELOG must already carry this version's dated heading — i.e.
# release.sh ran. Tagging a version with no changelog section is exactly the
# incoherence the audit's version/CHANGELOG gate exists to catch; refuse up front.
if ! grep -qE "^## +\[v?${VERSION//./\\.}\]" "$CHANGELOG"; then
  fail "tag-release.sh: no '## [v$VERSION]' heading in $CHANGELOG — run 'make release VERSION=$VERSION' first"
  exit 1
fi

# Guard 3: prove the tree green before it's tagged (the same gate release.sh and
# sync-core.sh enforce). Skippable for a tree you JUST audited, mirroring SYNC_SKIP_AUDIT.
if [[ "${TAG_SKIP_AUDIT:-0}" == 1 ]]; then
  skip "audit (TAG_SKIP_AUDIT=1)"
else
  hdr "audit (tag must be green)"
  if ./scripts/audit-core.sh --quiet; then
    pass "audit green"
  else
    fail "audit FAILED — fix before tagging (or TAG_SKIP_AUDIT=1 to override a just-audited tree)"
    exit 1
  fi
fi

# Commit the two release files iff they actually differ from HEAD (release.sh left them
# modified). Re-running after the commit already landed is a no-op, not an error. The
# explicit pathspec commits ONLY these two files, so unrelated staged work is never
# swept into the release commit.
if git diff --quiet HEAD -- "$VERFILE" "$CHANGELOG"; then
  pass "release commit already present ($VERFILE/$CHANGELOG match HEAD)"
else
  if git commit -q -m "release $TAG" -- "$VERFILE" "$CHANGELOG"; then
    pass "committed release $TAG"
  else
    fail "tag-release.sh: commit failed"
    exit 1
  fi
fi

printf '\n%s──────── %s committed (no tag yet, by design) ────────%s\n' "$c_blu" "$TAG" "$c_rst"
cat <<EOF
  review:  git show HEAD

  NO TAG EXISTS YET, and that is the point. A vX.Y.Z tag is only created once the commit
  is on origin/main, so there is no window in which a stray push — yours or a concurrent
  session sharing this checkout — can carry $TAG to the remote and fire release.yml +
  sync-fanout.yml against an unmerged commit.

  You should be ON release/$TAG right now — this script commits to whatever branch you are
  standing on, and RELEASE-RUNBOOK.md §1.1 step 1 branches before staging for that reason.
  If you staged from main instead, the release commit is sitting on your local main, one
  ahead of origin, where it must NEVER be pushed (main is protected and takes the commit
  through the PR below). Push it to the branch as step 1 shows, then 'git reset --hard
  origin/main' to put your local main back.

  1. land the commit:
       git push origin HEAD:release/$TAG
       gh pr create --base main --head release/$TAG --title "release $TAG"
       # merge it — GitHub only offers the methods this repo enables, and any of them is
       # fine: phase 2 tags origin/main, so the merge method cannot affect the tag.
       # (Why this names no method: RELEASE-RUNBOOK.md §"Why squash is fine".)
  2. publish the tags AFTER the PR merges:
       make publish          # or: ./scripts/tag-release.sh --publish
       # refuses unless origin/main actually carries core.version $VERSION
  3. fan out: sync-fanout.yml opens the vendor PRs on release; or ./scripts/sync-core.sh

  Abandoning instead? Nothing to undo but the commit and the branch — no tags were
  created, so there is no 'git tag -d' step and no vN alias pointing at a dropped commit.
  Full recipe: RELEASE-RUNBOOK.md §"Abandoning a cut".
EOF
