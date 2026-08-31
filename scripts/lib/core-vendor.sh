# shellcheck shell=bash
# scripts/lib/core-vendor.sh — ONE definition of "which paths does a vendored core/ carry?"
# ──────────────────────────────────────────────────────────────────────────────
# The vendored set is `core.manifest` ∪ `core.vendor`, and this file is the only place
# that turns those two lists into a git tree. THREE callers need the answer and they sit
# on different sides of it: sync-core.sh PRODUCES the vendored tree, new-os-repo.sh
# produces the FIRST one, and core-integrity.sh (via core-lock.sh) REPORTS on it later.
# Two implementations of one filter would be strictly worse than one shared one — a
# producer that computed a different subset than the verifier expects would materialize a
# tree, pass its own assertion, and be reported TAMPERED by an unrelated command later.
# That is #556's failure mode, and #676 would have re-created it one layer down.
#
# READ FROM THE COMMIT, NEVER FROM A WORKING TREE. Every function resolves the two lists
# as `${sha}:core.manifest` / `${sha}:core.vendor`. This is the load-bearing constraint of
# the whole design: sync-core.sh builds the tree inside the CONSUMER (which is guaranteed
# to hold the objects after its fetch) while core-integrity.sh rebuilds it inside CORE.
# Git trees are content-addressed, so those two builds agree BY CONSTRUCTION — but only
# while both derive the filter from the same commit. Reading either side's checkout would
# make "expected" mean something different depending on who asked.
#
# THE PRESENCE OF core.vendor AT A COMMIT IS THE VERSION SWITCH (see
# core_vendor_effective_tree). A commit carrying it vendors the filtered tree; one that
# does not predates #676 and vendored its whole tree. Deriving that from the PINNED
# COMMIT — not from a flag, an env var, or this checkout's state — is what let #676 land
# with no flag day: every repo still pinning an older Core stayed `pristine`.
#
# This is a SOURCED library, not a runnable script — so, like scripts/lib/common.sh and
# scripts/lib/core-lock.sh, it carries NO shebang and stays mode 100644 (audit-core.sh's
# exec-bit section asserts this). bash 3.2-safe (no associative arrays / mapfile) so it
# runs on macOS too.
#
# NOT pure, and deliberately in its own file rather than folded into core-lock.sh: that
# file's header promises every function there is read-only, and building a tree writes a
# temporary index and loose objects. Folding these in would have made that promise false
# for the whole file — and two existing callers rely on reading it.
#
# Callers run under different `set` options (sync-core.sh `set -euo pipefail`,
# core-integrity.sh `set -uo pipefail`), so nothing here may depend on either.

# Does this commit carry the vendoring allowlist — i.e. does it postdate #676?
core_vendor_is_filtered() { # core_vendor_is_filtered <repo-dir> <sha>
  git -C "$1" cat-file -e "${2}:core.vendor" 2>/dev/null
}

# The union of the two lists AT A COMMIT, one path per line.
#
# The parse is core.manifest's canonical one (audit-core.sh): strip `#` comments, strip
# trailing whitespace, first field wins. Both files share it so there is one format to
# learn and one parser to get wrong.
core_vendor_paths() { # core_vendor_paths <repo-dir> <sha>
  local repo="$1" sha="$2" man ven
  man="$(git -C "$repo" show "${sha}:core.manifest" 2>/dev/null)" || return 1
  ven="$(git -C "$repo" show "${sha}:core.vendor" 2>/dev/null)" || return 1
  printf '%s\n%s\n' "$man" "$ven" |
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' |
    awk 'NF {print $1}'
}

# Is <path> in the vendored set described by <keeplist> (newline-separated)?
#
# PURE TEXT — no git, no filesystem. Split out from core_vendor_tree for the same reason
# common.sh splits its `_core_*_hits` extractors from their verdicts: test-core.sh can
# drive it on fixtures without building a repo, which is the difference between this rule
# being tested and being assumed.
#
# Trailing `/` means directory prefix, matching core.manifest's `nvim/` entry and
# audit-core.sh's is_listed(). Everything else is an exact path match.
# Split on newline with globbing OFF, rather than the obvious `while read <<EOF`: this is
# called once per tracked file (285×) and bash implements a heredoc as a TEMPORARY FILE, so
# the read-loop form spent 387ms of a 431ms tree build creating and deleting them. Splitting
# in-process is 63ms for the same 185 kept paths. `set -f` is load-bearing — without it a
# list entry containing a glob character would be expanded against the cwd before it was
# ever compared. Both $IFS and the noglob flag are restored, including when the caller
# already had noglob set.
core_vendor_keeps() { # core_vendor_keeps <path> <keeplist>
  local p="$1" m rc=1 _oifs="$IFS" _oglob=0
  case "$-" in *f*) _oglob=1 ;; esac
  set -f
  IFS='
'
  for m in $2; do
    case "$m" in
    '') continue ;;
    */) case "$p" in "$m"*) rc=0; break ;; esac ;;
    *) [ "$p" = "$m" ] && { rc=0; break; } ;;
    esac
  done
  IFS="$_oifs"
  ((_oglob)) || set +f
  return "$rc"
}

# Build the FILTERED tree for <sha> and print its object id. Fails (rc 1) if the commit
# does not carry core.vendor — callers wanting the version switch use
# core_vendor_effective_tree instead.
#
# ADDITIVE, via `update-index --index-info`: the index is built from ONLY the kept paths
# rather than by reading the full tree and removing the rest. Three reasons, and the third
# is the one that would have bitten:
#   1. it matches allowlist semantics — you list what ships, and that is what is built;
#   2. it never needs the dropped paths' objects at all;
#   3. the subtractive shape ends in `xargs -0 ... update-index --force-remove`, whose
#      EMPTY-input behaviour is not portable (GNU needs -r to suppress the exec, BSD/macOS
#      differs by release, and -r is not portable). Here an empty keep-set is a clean
#      no-op that yields git's canonical empty tree with rc 0.
#
# Modes come straight from ls-tree, so the exec bits audit-core.sh §2 asserts survive
# without being reconstructed — the same property `read-tree --prefix` gave us before.
core_vendor_tree() { # core_vendor_tree <repo-dir> <sha>
  local repo="$1" sha="$2" keep dir tree rc=0
  # RESOLVE TO THE REPO ROOT FIRST. `git -C <subdir> update-index --index-info` interprets
  # its paths against the cwd PREFIX, not the repo root, so handing this function a
  # subdirectory built a tree from a path set that matched nothing — and returned git's
  # EMPTY tree (4b825dc6…) with rc 0. Silently: the caller got a valid-looking object id for
  # a tree with no files in it.
  #
  # Not hypothetical. A vendored `core/scripts/core-integrity.sh --self` resolves its own
  # $HERE to <consumer>/core, which is exactly such a subdirectory, and reported every repo
  # TAMPERED against an empty expectation.
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$repo" ] || return 1
  core_vendor_is_filtered "$repo" "$sha" || return 1
  keep="$(core_vendor_paths "$repo" "$sha")" || return 1
  [ -n "$keep" ] || return 1
  dir="$(mktemp -d "${TMPDIR:-/tmp}/core-vendor.XXXXXX")" || return 1
  # GIT_INDEX_FILE is resolved against the GIT PROCESS's cwd, and `git -C "$repo"` changes
  # that. A relative path here silently builds the index inside $repo instead of the temp
  # dir — the easiest way to get this function subtly and invisibly wrong.
  case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
  # mktemp -d + $dir/index, never a bare mktemp: git errors on a zero-length existing
  # index file, and the directory form makes cleanup one rm -rf.
  #
  # The export lives inside the command substitution's subshell, so the caller's index is
  # untouched — load-bearing, because sync-core.sh calls this immediately before
  # read-tree'ing into its REAL index. Do not lift it out.
  tree="$(
    export GIT_INDEX_FILE="$dir/index"
    git -C "$repo" ls-tree -r -z "${sha}^{tree}" 2>/dev/null |
      while IFS= read -r -d '' line; do
        core_vendor_keeps "${line#*$'\t'}" "$keep" && printf '%s\0' "$line"
      done |
      git -C "$repo" update-index -z --index-info || exit 1
    git -C "$repo" write-tree || exit 1
  )" || rc=1
  # Explicit cleanup on every path, NOT a trap: audit-core.sh already installs `trap
  # _audit_cleanup EXIT`, and a sourced library arming EXIT would clobber its caller's.
  rm -rf -- "$dir"
  [ "$rc" -eq 0 ] || return 1
  [ -n "$tree" ] || return 1
  # An EMPTY tree out of a NON-EMPTY keep list is never a correct answer — it is the
  # signature of the filter matching nothing, and handing it back would vendor an empty
  # core/ or expect one. The empty tree is a legitimate no-op only when there was nothing to
  # keep, and $keep is non-empty by the guard above, so here it can only mean a bug.
  if [ "$tree" = 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ]; then
    return 1
  fi
  printf '%s\n' "$tree"
}

# THE VERSION SWITCH, and the only copy of it.
#
# A commit carrying core.vendor vendors the filtered tree; one that does not predates #676
# and vendored its whole tree. Both the producer (sync-core.sh, new-os-repo.sh) and the
# verifier (core-lock.sh :: core_lock_expected_tree) go through here, so "what should this
# repo carry?" has exactly one answer no matter who asks.
core_vendor_effective_tree() { # core_vendor_effective_tree <repo-dir> <sha>
  if core_vendor_is_filtered "$1" "$2"; then
    core_vendor_tree "$1" "$2"
  else
    git -C "$1" rev-parse --verify --quiet "${2}^{tree}" 2>/dev/null
  fi
}

# Stage <repo-dir>/core/ at the tree <sha> should produce. The ONE producer, shared by
# sync-core.sh's fan-out and new-os-repo.sh's first vendor so a newly created repo cannot
# be born TAMPERED against a filter its creator did not apply.
#
# COMMITS NOTHING — it leaves the tree staged so the caller can land core/ and core.lock in
# the same commit (there must be no window where core/ has moved but core.lock has not).
core_vendor_materialize() { # core_vendor_materialize <repo-dir> <sha>
  local path="$1" sha="$2" tree
  tree="$(core_vendor_effective_tree "$path" "$sha")" || return 1
  [ -n "$tree" ] || return 1
  # Clear the prefix from index AND worktree: read-tree --prefix refuses to write over
  # existing index entries. --ignore-unmatch so a half-repaired repo (entries already gone,
  # directory still present) is recoverable rather than fatal.
  git -C "$path" rm -rq --ignore-unmatch -- core || return 1
  # The rm above removes TRACKED files only. An untracked leftover under core/ would survive
  # into the new tree and then read as drift to core-integrity, so clear the directory
  # outright. `${path:?}` guards an empty path expanding this to `rm -rf /core`.
  rm -rf -- "${path:?}/core"
  git -C "$path" read-tree --prefix=core/ -u "$tree" || return 1
}
