#!/usr/bin/env bash
# scripts/sync-nvim.sh — vendor dotgibson/dotfiles-nvim into nvim/ and refresh nvim.lock.
# ──────────────────────────────────────────────────────────────────────────────
# THE CONSUMER-SIDE HALF of a vendoring contract Core is, for the first time, on the
# receiving end of. sync-core.sh pushes Core OUT into ten OS repos; this pulls the editor
# IN from the one repo that owns it. dotfiles-Offense/scripts/sync-companion.sh is the same
# shape for the same reason (it vendors offensive/companion from dotgibson/htpx), and this
# script is deliberately its sibling rather than a mode of sync-core.sh.
#
#   scripts/sync-nvim.sh                  # follow nvim_branch (main) from the lock's repo
#   scripts/sync-nvim.sh --ref vX.Y.Z     # pull an EXACT tag/branch instead of nvim_branch
#   scripts/sync-nvim.sh <remote-or-url>  # pull from a specific remote / URL / local clone
#   scripts/sync-nvim.sh --check          # report whether upstream is ahead; touch nothing
#
# --ref is the NORMAL bump, not the exotic one. NVIM-SPLIT-PROPOSAL.md §7(3) says Core
# adopts the editor at a RELEASE, with a Core release — so a bump names a tag. A bare run
# follows nvim_branch's tip, which is for checking what is coming, not for pinning.
#
# WHY read-tree AND NOT `git subtree pull`. dotfiles-nvim's history was rewritten by
# filter-repo when it was extracted (#1122): it shares no commit sha with this repo, so
# there is no subtree relationship to pull and `git subtree add` would refuse a prefix that
# already exists. `read-tree --prefix=nvim/` has no such requirement and is exactly what
# core_vendor_materialize does on the outbound side — it stages the upstream tree OBJECT,
# so file modes and bytes arrive unchanged. That is not a stylistic preference: the
# byte-identical assertion in NVIM-SPLIT-PROPOSAL.md §3.5 step 2 is only meaningful if the
# transport cannot perturb content, which rules out rsync and any copy loop.
#
# COMMITS NOTHING — it stages. The caller lands nvim/ and nvim.lock in ONE commit, for
# core_vendor_materialize's reason: there must be no window where the tree has moved but
# the lock has not, because that window reads as drift to §9q and is indistinguishable
# from a hand-edit.
#
# Pre-reqs it enforces: a readable nvim.lock carrying nvim_repo/nvim_branch/nvim_sha, and
# (outside --check) a clean nvim/ — staging over local edits would destroy them silently.
# The prefix (nvim) is FIXED, not read from the lock: it is core.manifest's entry and
# blib_link_core's target, and making it configurable would invite the two to disagree.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

PREFIX="nvim"
LOCK="$HERE/nvim.lock"

# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"
# core_vendor_remote_commit resolves a ref to a commit in ONE ls-remote, asking for the
# bare AND the peeled form so an ANNOTATED tag yields the commit rather than the tag
# object. That is dotgibson/dotfiles-core#1065, and re-implementing it here is how this
# script would reacquire the same bug — a bump to `--ref v1.1.0` would pin a tag object,
# `rev-parse "$sha:nvim"` would fail, and the failure would look like a missing tree.
# shellcheck source=scripts/lib/core-vendor.sh
source "${BASH_SOURCE[0]%/*}/lib/core-vendor.sh"

die() { printf 'sync-nvim: %s\n' "$*" >&2; exit 1; }

CHECK=0
REMOTE_ARG=""
REF_OPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1 ;;
    --ref)
      shift
      [[ $# -gt 0 ]] || die "--ref needs a value (a branch or tag)"
      case "$1" in -*) die "--ref needs a value, got another option: $1" ;; esac
      REF_OPT="$1" ;;
    --ref=*)
      REF_OPT="${1#--ref=}"
      [[ -n "$REF_OPT" ]] || die "--ref= needs a non-empty value (a branch or tag)" ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$REMOTE_ARG" ]] || die "only one remote/URL may be given"; REMOTE_ARG="$1" ;;
  esac
  shift
done

[[ -r "$LOCK" ]] || die "$LOCK not found or unreadable — is the editor vendored?"

# Read provenance out of the lock with core-lock.sh's idiom, so `key = value` (the spelling
# dotfiles-Windows' nvim/.core-ref uses) reads the same as `key=value`.
lock_field() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$LOCK" 2>/dev/null | head -n1; }

repo="$(lock_field nvim_repo)"
branch="$(lock_field nvim_branch)"
old_sha="$(lock_field nvim_sha)"
old_tree="$(lock_field nvim_tree)"
[[ -n "$repo" ]]   || die "nvim_repo missing from $LOCK"
[[ -n "$branch" ]] || die "nvim_branch missing from $LOCK"
# The rewrite below REPLACES existing lines (awk) — it does not insert them. A lock missing
# either field would let the fetch succeed and leave the lock silently unchanged, which is
# the one outcome worse than failing: the tree moves, §9q reds, and nothing says why.
[[ -n "$old_sha" ]]  || die "nvim_sha missing/empty in $LOCK — add an 'nvim_sha=' line before syncing."
[[ -n "$old_tree" ]] || die "nvim_tree missing/empty in $LOCK — add an 'nvim_tree=' line before syncing."

remote="${REMOTE_ARG:-https://github.com/$repo.git}"
ref="${REF_OPT:-$branch}"

new_sha="$(GIT_TERMINAL_PROMPT=0 core_vendor_remote_commit "$remote" "$ref" 2>/dev/null)"
if [[ -z "$new_sha" ]]; then
  # Unreachable is NOT drift. A scheduled or offline run must say it could not look rather
  # than imply the pin is fine — the same rule audit-core.sh's sibling checks follow.
  if [[ "$CHECK" -eq 1 ]]; then
    printf 'sync-nvim: SKIPPED — cannot reach %s (%s) — offline/restricted?\n' "$remote" "$ref" >&2
    exit 0
  fi
  die "cannot resolve $ref at $remote — offline, or no such branch/tag"
fi

if [[ "$CHECK" -eq 1 ]]; then
  if [[ "$new_sha" == "$old_sha" ]]; then
    printf 'sync-nvim: nvim/ is current with %s@%s (%s)\n' "$repo" "$ref" "${old_sha:0:12}"
    exit 0
  fi
  printf 'sync-nvim: nvim.lock is behind %s@%s\n    vendored: %s\n    upstream: %s\n    update:   scripts/sync-nvim.sh --ref <tag>\n' \
    "$repo" "$ref" "${old_sha:0:12}" "${new_sha:0:12}" >&2
  exit 2
fi

# Refuse to stage over local work. `git rm` + `rm -rf` below are destructive to the prefix,
# and a dirty nvim/ here is either an unfinished edit (which belongs upstream, not in the
# vendored copy) or a half-applied earlier sync.
if [[ -n "$(git status --porcelain -- "$PREFIX" 2>/dev/null)" ]]; then
  die "$PREFIX/ has uncommitted changes — commit, stash or discard them first (the vendored tree is overwritten wholesale)."
fi

# Fetch the pinned commit itself, not the branch: --depth 1 of an exact sha is the smallest
# thing that can produce the tree, and it works for a tag, a branch tip or a bare sha.
GIT_TERMINAL_PROMPT=0 git fetch --quiet --depth 1 "$remote" "$new_sha" 2>/dev/null ||
  GIT_TERMINAL_PROMPT=0 git fetch --quiet "$remote" "$new_sha" 2>/dev/null ||
  die "fetched nothing for $new_sha from $remote"

# The payload is upstream's nvim/ SUBDIRECTORY, not its root: dotfiles-nvim carries its own
# gate, CI and docs beside the tree, and none of that is Core's to vendor.
new_tree="$(git rev-parse --verify --quiet "${new_sha}:$PREFIX")" ||
  die "$new_sha has no $PREFIX/ directory — is $repo the right repo?"
[[ -n "$new_tree" ]] || die "$new_sha has no $PREFIX/ directory — is $repo the right repo?"

before_tree="$(git rev-parse --verify --quiet "HEAD:$PREFIX" 2>/dev/null || echo '')"

# Clear the prefix from index AND worktree: read-tree --prefix refuses to write over
# existing index entries. --ignore-unmatch so a half-repaired tree (entries already gone,
# directory still present) is recoverable rather than fatal.
git rm -rq --ignore-unmatch -- "$PREFIX" || die "could not clear $PREFIX/ from the index"
# The rm above removes TRACKED files only. An untracked leftover would survive into the new
# tree and then read as drift to §9q — a failure that looks like a corrupt upstream and is
# not. `${HERE:?}` guards an empty path expanding this to `rm -rf /nvim`.
rm -rf -- "${HERE:?}/$PREFIX"
git read-tree --prefix="$PREFIX/" -u "$new_tree" || die "read-tree of $new_tree failed"

# nvim_version comes from the tree we just vendored, so it cannot disagree with what is on
# disk. nvim.version lives at the SOURCE repo's root — outside the vendored payload — so it
# is read from the fetched commit rather than from the worktree.
new_version="$(git show "${new_sha}:nvim.version" 2>/dev/null | tr -d '[:space:]')"
[[ -n "$new_version" ]] || new_version="$(lock_field nvim_version)"

# nvim_tag needs upstream's tag objects. An explicit --ref that already looks like a release
# tag IS the answer; otherwise ask the remote which tag points at this commit. Best-effort:
# a tagless resolution leaves the previous value rather than lying.
new_tag=""
case "$ref" in
  v[0-9]*) new_tag="$ref" ;;
  *) new_tag="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$remote" 2>/dev/null |
       awk -v s="$new_sha" '$1 == s { sub(/^refs\/tags\//, "", $2); print $2; exit }')" ;;
esac
[[ -n "$new_tag" ]] || new_tag="$(lock_field nvim_tag)"

# Rewrite only the recorded fields; leave the header and repo/branch untouched. These
# REPLACE existing lines rather than inserting, which is why the guards above require
# nvim_sha and nvim_tree to be present before the fetch starts.
set_field() { # set_field <key> <value>
  local key="$1" val="$2" t
  t="$(mktemp "${TMPDIR:-/tmp}/nvim-lock.XXXXXX")" || return 1
  awk -v k="$key" -v v="$val" '$0 ~ "^" k "=" { print k "=" v; next } { print }' "$LOCK" >"$t" || return 1
  mv -- "$t" "$LOCK"
}
set_field nvim_sha "$new_sha"      || die "could not rewrite nvim_sha in $LOCK"
set_field nvim_tree "$new_tree"    || die "could not rewrite nvim_tree in $LOCK"
set_field nvim_version "$new_version" || die "could not rewrite nvim_version in $LOCK"
set_field nvim_tag "$new_tag"      || die "could not rewrite nvim_tag in $LOCK"
git add -- "$LOCK" || die "could not stage $LOCK"

printf 'sync-nvim: nvim.lock  %s -> %s  (v%s, %s)\n' "${old_sha:0:12}" "${new_sha:0:12}" "$new_version" "$new_tag"
if [[ "$before_tree" == "$new_tree" ]]; then
  # The byte-identical case, and it is the EXPECTED one for the first sync
  # (NVIM-SPLIT-PROPOSAL.md §3.5 step 2). Say so out loud: an operator who sees no diff
  # should be told that is the assertion passing, not that the sync did nothing.
  printf 'sync-nvim: %s/ is byte-identical (tree %s) — only the lock moved.\n' "$PREFIX" "${new_tree:0:12}"
else
  printf 'sync-nvim: %s/ tree %s -> %s\n' "$PREFIX" "${before_tree:0:12}" "${new_tree:0:12}"
fi
cat <<EOF

sync-nvim: staged. Next:
  1. review the diff:  git diff --cached -- $PREFIX
  2. commit nvim.lock TOGETHER with $PREFIX/ — they must land in one commit, or
     audit-core.sh §9q reds on the window between them.
EOF
