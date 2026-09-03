#!/usr/bin/env bash
# scripts/new-os-repo.sh — scaffold a new OS repo that vendors Core (B3).
# ──────────────────────────────────────────────────────────────────────────────
# Onboarding a new OS repo was a tribal, multi-step ritual (README "Adding a new file"
# + "How an OS repo consumes Core"): git init, `git subtree add`, hand-write a .zshrc
# loader in the EXACT canonical order, stub an os/<os>.zsh, write a bootstrap. Get the
# load order wrong and the shell breaks in ways the per-file linters never catch. This
# turns all of it into one command, generating a skeleton that already loads Core
# correctly and is ready for `bootstrap.sh`.
#
# Usage:
#   ./scripts/new-os-repo.sh <OSName> [target-dir]      # e.g. Fedora  (→ ../dotfiles-Fedora)
#   ./scripts/new-os-repo.sh Fedora --dry-run           # print the plan, write nothing
#   ./scripts/new-os-repo.sh Fedora --no-vendor         # skeleton only, skip the subtree add
#
# It vendors Core via `git subtree add --prefix=core` from this repo's origin (override
# with CORE_REMOTE), then writes the entry .zshrc/.zshenv/.zprofile, an os/<os>.zsh stub,
# a starter bootstrap, a .gitignore, a Makefile carrying the fleet's canonical `make`
# vocabulary, a test/ suite and the workflow that runs it (#691). The canonical module
# order lives in ONE place here, so a scaffolded repo can never start out of order — and
# the vocabulary + test floor live here for the same reason: a repo born without them is
# under the contract from day one, and the register (audit §5h) says so.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"
# The vendored-set filter and the ONE producer, shared with sync-core.sh (#676). A repo
# scaffolded here must be born carrying the SAME subset the fan-out would give it, or its
# very first core-integrity run reports TAMPERED against a filter its creator never applied.
# shellcheck source=scripts/lib/core-vendor.sh
source "${BASH_SOURCE[0]%/*}/lib/core-vendor.sh"

# v4: the load order is the numbered fragments' NN prefix, globbed by the vendored
# loader — a scaffolded .zshrc no longer lists module names, it just sources the loader.
CORE_REMOTE="${CORE_REMOTE:-$(git -C "$HERE" remote get-url origin 2>/dev/null || echo '')}"
# Default to the RELEASED major alias, never `main`: the fan-out pins every repo to the
# exact commit a release tag points at, so a tree vendored from whatever `main` happened
# to be is not a commit any core.lock would record — and core-integrity reports the fresh
# subtree as TAMPERED before the repo has done anything wrong (#588).
CORE_BRANCH="${CORE_BRANCH:-refs/tags/v5}"

usage() {
  cat <<'EOF'
usage: new-os-repo.sh <OSName> [target-dir] [--dry-run] [--no-vendor]

Scaffold a new OS repo that vendors Core: subtree-add core/, then write a correct
.zshrc loader (canonical order), os/<os>.zsh, a starter bootstrap, .gitignore, a Makefile
with the fleet's make vocabulary, a test/ suite and the workflow that runs it.

  <OSName>       e.g. Fedora, Arch, Gentoo  (repo defaults to ../dotfiles-<OSName>)
  target-dir     override the destination directory
  --dry-run, -n  print every planned action; create nothing
  --no-vendor    scaffold the files but skip the vendoring. sync-core.sh will NOT fill
                 the gap later (it skips a repo with no core/); follow the manual
                 one-time setup in VENDORING.md instead — the script prints it.

Env: CORE_REMOTE (default: this repo's origin)
     CORE_BRANCH (default: refs/tags/v5 — a RELEASED tag, never main; pin a specific
                  vX.Y.Z to freeze the tree at a known version)
EOF
}

OS="" TARGET="" DRY=0 NO_VENDOR=0
for a in "$@"; do
  case "$a" in
  -h | --help)
    usage
    exit 0
    ;;
  --dry-run | -n) DRY=1 ;;
  --no-vendor) NO_VENDOR=1 ;;
  -*)
    fail "unknown flag: $a"
    usage >&2
    exit 2
    ;;
  *)
    if [[ -z "$OS" ]]; then OS="$a"
    elif [[ -z "$TARGET" ]]; then TARGET="$a"
    else
      fail "unexpected extra argument: $a"
      exit 2
    fi
    ;;
  esac
done
[[ -n "$OS" ]] || {
  fail "an OS name is required (e.g. Fedora)"
  usage >&2
  exit 2
}
TARGET="${TARGET:-$(dirname "$HERE")/dotfiles-$OS}"
os_lc="$(printf '%s' "$OS" | tr '[:upper:]' '[:lower:]')"

# The recovery command and the register step judge the RELEASED sync-core.sh by its
# per-repo footer (`repos:  updated 1   skipped 0   failed 0`), which is printed since
# v4.1.0; v4.0.2 and older print a per-CHECK count with no `repos:` prefix, so under such
# a pin a SUCCESSFUL sync would be reported as a failure — after it had vendored and
# stamped the target. A pin that names an older release is refused here, before anything
# is written, instead of at the one moment the reader is recovering. A ref that is not
# version-shaped (a branch, a SHA) cannot be judged here and passes. A prerelease
# (v4.1.0-rc1, the suffix core.version allows) sorts BELOW its release, so a prerelease
# of the floor itself is older than the floor.
_footer_floor="4.1.0"
_pin="${CORE_BRANCH#refs/tags/}"
_pin_re='^v([0-9]+)(\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?)?$'
if [[ "$_pin" =~ $_pin_re ]]; then
  IFS=. read -r _fl_M _fl_m _fl_p <<<"$_footer_floor"
  _pin_M=$((10#${BASH_REMATCH[1]}))
  if [[ -z "${BASH_REMATCH[2]}" ]]; then
    # A major alias (v4) points at the newest release of that major, so only a major
    # below the floor's can be older than the floor.
    _pin_old=$((_pin_M < _fl_M))
  else
    _pin_m=$((10#${BASH_REMATCH[3]})) _pin_p=$((10#${BASH_REMATCH[4]}))
    _pin_pre=$(( ${#BASH_REMATCH[5]} > 0 ))
    _pin_old=$((_pin_M < _fl_M || (_pin_M == _fl_M && (_pin_m < _fl_m || (_pin_m == _fl_m && (_pin_p < _fl_p || (_pin_p == _fl_p && _pin_pre)))))))
  fi
  if ((_pin_old)); then
    fail "CORE_BRANCH=$CORE_BRANCH names a release older than v$_footer_floor, whose sync-core.sh prints no per-repo summary — the recovery and register commands could not judge it. Pin v$_footer_floor or newer."
    exit 2
  fi
  unset _fl_M _fl_m _fl_p _pin_M _pin_m _pin_p _pin_pre _pin_old
fi
unset _footer_floor _pin _pin_re

hdr "scaffold dotfiles-$OS"
echo ":: target   = $TARGET"
echo ":: core     = $CORE_REMOTE ($CORE_BRANCH)"
((DRY)) && echo ":: DRY RUN — nothing will be written"

if [[ -e "$TARGET" && ! -d "$TARGET" ]]; then
  fail "$TARGET exists and is not a directory"
  exit 1
fi
if [[ -d "$TARGET/.git" ]]; then
  fail "$TARGET is already a git repo — refusing to overwrite (scaffold a fresh dir)"
  exit 1
fi

# w <path> <<heredoc — write a file (honouring --dry-run + announcing), making parents.
w() {
  local path="$1"
  if ((DRY)); then
    skip "would write ${path#"$TARGET"/}"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  pass "wrote ${path#"$TARGET"/}"
}

((DRY)) || mkdir -p "$TARGET"
((DRY)) || git -C "$TARGET" init -q

# ── vendor Core ───────────────────────────────────────────────────────────────
# NOT `git subtree add --squash` any more (#676). A subtree add copies the WHOLE upstream
# tree, so from the moment core.vendor exists it would scaffold a repo whose core/ carries
# 285 files against an expectation of 185 — TAMPERED on the first `make core-integrity`,
# before anyone had touched it. Materializing through the shared producer means there is one
# definition of "what a vendored core/ contains" and a new repo starts life agreeing with it.
#
# Nothing downstream loses anything: core.lock is the authoritative provenance since #587,
# and the fan-out stamps it on this repo's first `make sync`.
# The manual path, NOT a bare sync-core.sh: the fan-out skips a repo with no core/ (that is
# the one thing it will not create), so the hint is VENDORING.md's one-time setup — a
# subtree add to bring core/ into existence, then the sync from Core to replace it with the
# filtered set and stamp core.lock.
#
# REPOS_ROOT is passed explicitly: sync-core.sh resolves `dotfiles-$OS` under the parent
# of the CORE checkout by default, and a scaffold placed elsewhere (the target-dir
# override) would be skipped as "not cloned" while the subtree add had already succeeded.
# The name is the other half of that resolution — the scaffold sets no origin the
# fallback could match — so a target not named dotfiles-$OS is told so.
#
# ABSOLUTE paths, because the hint's sync half runs after `cd '$HERE'`: a relative
# target-dir would make REPOS_ROOT resolve under the Core checkout instead. (Under
# --dry-run the target may not exist yet, so the relative form is the fallback.)
#
# And the sync half carries THE PIN, the way VENDORING.md's recipe does: sync-core.sh
# defaults CORE_BRANCH to main and refuses unless Core's HEAD is the commit being
# vendored, so it passes the peeled commit — otherwise copying the hint would replace
# the just-added release tree with `main` and stamp that. The ref is FETCHED from
# CORE_REMOTE first (a release that exists only on a mirror or fork would otherwise
# subtree-add fine and then fail to resolve here), CORE_REMOTE is forwarded to the sync,
# and the sync runs from a TEMPORARY DETACHED WORKTREE at FETCH_HEAD, removed afterwards:
# checking the tag out in the reader's own Core checkout would leave it detached there,
# and the banner then sends them "back in dotfiles-core" to register the repo — on a
# stale tag instead of their branch. The subshell returns the SYNC's status, not the
# cleanup's: `sync; cleanup` would report success after a failed sync as long as the
# worktree removal succeeded, leaving the repo unstamped while the command said ok. The
# mktemp PARENT is tracked and removed too — the worktree lives in a `core` subdirectory
# so `git worktree add` gets a path that does not exist yet, and removing only that
# would leave an empty temp directory behind on every successful recovery. And the
# cleanup is ENTERED only once `worktree add` has succeeded: the pasted subshell inherits
# the reader's shell variables, so a cleanup that ran after a failed fetch or mktemp
# could force-remove whatever an inherited `_wt` happened to name — while a FAILED add
# still removes the mktemp parent this very chain just created (an empty directory of
# ours, never an inherited path) and stops. The sync runs as an
# `if` condition — exempt from errexit — so a reader whose shell has `set -e` still
# reaches the cleanup. And the VERDICT is the released script's own SUMMARY LINE: the
# sync runs from the worktree at the PINNED TAG, so the sync-core.sh that executes is
# the released one — which may predate `--strict` (added after v6.1.0) and exits 0 after
# a per-repo failure — and a matching core.lock line is no proof either, since the lock
# can be written before a later pin, commit or verification step fails. Every release
# prints `repos:  updated N   skipped N   failed N`, so the output is captured
# (CORE_COLOR=never, honoured by every release) and the verdict is `updated 1  skipped 0
# failed 0` for the one target; the capture is `|| true` so errexit cannot skip it. Only
# the LAST `repos:` row is judged (awk keeps the final match): the log also carries the
# target's own output — a git hook, say — and a success-shaped line printed there must
# not outvote a footer that reports a failure.
#
# Every interpolated value is shell-escaped (`printf %q`, bash 3.2-safe): the hint is
# COPIED, and a target such as dotfiles-O'Brien wrapped in literal single quotes would
# hand the reader a misparsed command at exactly the moment vendoring must be recovered.
_q() { printf '%q' "$1"; }
# No origin and no CORE_REMOTE: an empty remote baked into the hint would fail at every
# step. Render a runtime expansion instead, so the pasted command refuses loudly until
# the reader exports CORE_REMOTE — the one thing the error below tells them to do.
_remote_q="$(_q "$CORE_REMOTE")"
# shellcheck disable=SC2016  # deliberately literal: the expansion belongs to the PASTED command, not to this script
[[ -n "$CORE_REMOTE" ]] || _remote_q='"${CORE_REMOTE:?export CORE_REMOTE=<dotfiles-core remote URL> first}"'
# A target that does not exist yet (--dry-run prints this same hint before anything is
# written) cannot be cd-ed into, and a relative path embedded as-is would be resolved by
# the chain AFTER it cd's into the Core checkout: REPOS_ROOT=<relative parent> then names
# a directory under Core and the sync skips the very repo the hint was written for. So
# the fallback anchors the path to the invocation directory instead of copying it.
_abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$PWD/${1#./}" ;; esac; }
_target_abs="$(cd "$TARGET" 2>/dev/null && pwd)" || _target_abs="$(_abs "$TARGET")"
_target_parent="$(cd "$(dirname "$TARGET")" 2>/dev/null && pwd)" || _target_parent="$(dirname "$(_abs "$TARGET")")"
#
# The scaffold is UNCOMMITTED when this hint is printed (with --no-vendor there is not
# even an initial commit), and both halves need a clean, committed target: subtree add
# wants a HEAD and refuses a dirty tree, and sync-core.sh refuses a dirty target. So the
# chain commits the scaffold first — a no-op when the reader already has.
#
# The Core-side half stands on its own too: when core/ WAS materialized and only the
# commit after it failed, the subtree add would fail on the existing prefix, so that
# state gets "commit what is staged, then stamp the lock" instead (see the vendor step).
_sync_half="(cd $(_q "$HERE") && git fetch $_remote_q $(_q "$CORE_BRANCH") && _wtp=\"\$(mktemp -d)\" && _wt=\"\$_wtp/core\" && { git worktree add --detach \"\$_wt\" FETCH_HEAD || { rmdir \"\$_wtp\"; false; }; } && { _o=\"\$( (cd \"\$_wt\" && CORE_BRANCH=\"\$(git rev-parse 'HEAD^{commit}')\" CORE_REMOTE=$_remote_q CORE_COLOR=never REPOS_ROOT=$(_q "$_target_parent") ./scripts/sync-core.sh $(_q "dotfiles-$OS")) 2>&1)\" || true; printf '%s\\n' \"\$_o\"; _l=\"\$(awk '/^ *repos: /{l=\$0} END{print l}' <<<\"\$_o\")\"; if grep -Eq '^ *repos: +updated 1 +skipped 0 +failed 0 +\(of 1 targeted\)$' <<<\"\$_l\"; then _rc=0; else _rc=1; fi; git worktree remove --force \"\$_wt\" && rmdir \"\$_wtp\" && exit \"\$_rc\"; })"
# RESUMABLE: the subtree add is the one step that cannot run twice ("prefix 'core'
# already exists"), and the sync after it is the step most likely to fail (network, a
# refused guard, a dirty tree). Rerunning the exact same command must therefore skip the
# add once HEAD already carries core/ and go straight back to the sync — `cat-file -e
# HEAD:core` is that test, and it is why the commit step precedes it: a core/ that was
# materialized but never committed is committed by the chain, then found in HEAD.
_vendor_hint="git -C $(_q "$_target_abs") add -A && (git -C $(_q "$_target_abs") diff --cached --quiet || git -C $(_q "$_target_abs") commit -q -m $(_q "scaffold dotfiles-$OS")) && { git -C $(_q "$_target_abs") cat-file -e HEAD:core 2>/dev/null || git -C $(_q "$_target_abs") subtree add --prefix=core $_remote_q $(_q "$CORE_BRANCH") --squash; } && $_sync_half   # VENDORING.md § One-time setup"
# A target not named dotfiles-$OS gets the symlink FIRST in the chain — before the
# subtree add and the sync, and never after the trailing `#`, where it would be a
# comment — so the sync resolves the conventional name. A symlink, not a rename: the
# chain embeds the original path. GUARDED: the canonical path must be absent, or
# already a link to exactly this scaffold. `ln -sfn` alone replaces a stale symlink but
# onto a REAL directory of that name it nests a link inside it — and the sync would then
# modify that unrelated repository. Any other occupant is refused, and the chain stops.
_canon="$_target_parent/dotfiles-$OS"
_link_cmd="{ { [ ! -e $(_q "$_canon") ] && [ ! -L $(_q "$_canon") ]; } || { [ -L $(_q "$_canon") ] && [ \"\$(readlink $(_q "$_canon"))\" = $(_q "$_target_abs") ]; }; } || { echo $(_q "refusing: $_canon exists and is not a link to this scaffold — remove or rename it first") >&2; false; } && ln -sfn $(_q "$_target_abs") $(_q "$_canon")"
# The sync-only recovery (used when core/ is already materialized) needs that same link
# for a custom basename, or the sync just skips a directory it cannot resolve.
_sync_recover="$_sync_half"
[[ "$(basename "$TARGET")" == "dotfiles-$OS" ]] || {
  _vendor_hint="$_link_cmd && $_vendor_hint; sync-core.sh resolves the NAME dotfiles-$OS under REPOS_ROOT, hence the guarded symlink (not a rename — the chain embeds the original path)"
  _sync_recover="$_link_cmd && $_sync_half"
}
if ((NO_VENDOR)); then
  skip "skipping vendor (--no-vendor) — run later: $_vendor_hint"
elif ((DRY)); then
  skip "would: materialize $TARGET/core from $CORE_REMOTE ($CORE_BRANCH)"
elif [[ -z "$CORE_REMOTE" ]]; then
  fail "CORE_REMOTE empty (set origin on dotfiles-core, or export CORE_REMOTE) — scaffolding files, skipping vendor"
else
  # The materialize needs at least one commit on the new repo first (it stages into an index
  # that must have a HEAD to be committed against).
  git -C "$TARGET" commit -q --allow-empty -m "init dotfiles-$OS" 2>/dev/null
  # Resolve the ref to a SHA and address the tree by it, for the same reason sync-core.sh
  # does (#556): the filter and the provenance must name one commit, not "whatever this ref
  # meant during whichever fetch".
  _core_sha="$(git ls-remote "$CORE_REMOTE" "$CORE_BRANCH" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -z "$_core_sha" ]]; then
    fail "could not resolve $CORE_BRANCH on $CORE_REMOTE (offline/unreachable?) — files scaffolded; vendor later with: $_vendor_hint"
  elif ! git -C "$TARGET" fetch -q --no-tags "$CORE_REMOTE" "$_core_sha" >/dev/null 2>&1 &&
    ! git -C "$TARGET" fetch -q --no-tags "$CORE_REMOTE" "$CORE_BRANCH" >/dev/null 2>&1; then
    fail "fetch of Core failed (offline/unreachable?) — files scaffolded; vendor later with: $_vendor_hint"
  elif ! core_vendor_materialize "$TARGET" "$_core_sha"; then
    fail "materializing core/ failed — files scaffolded; vendor later with: $_vendor_hint"
  elif ! git -C "$TARGET" commit -q -m "chore(core): vendor Core at ${_core_sha:0:12}"; then
    # core/ IS materialized and staged; only the commit failed. The subtree-add hint would
    # fail here on the existing prefix, so the recovery is: commit, then stamp the lock —
    # the Core-side half alone. It STAGES FIRST: this commit runs before the scaffold
    # files below are written, so by the time the reader retries, those files exist
    # untracked, and a commit of core/ alone would leave the tree dirty for the sync's
    # guard to refuse.
    fail "core/ materialized at ${_core_sha:0:12} but the commit failed — fix that, then: git -C $(_q "$_target_abs") add -A && git -C $(_q "$_target_abs") commit -q -m $(_q "chore(core): vendor Core at ${_core_sha:0:12}") && $_sync_recover"
  elif core_vendor_is_filtered "$TARGET" "$_core_sha"; then
    pass "vendored Core into core/ at ${_core_sha:0:12} (filtered: core.manifest + core.vendor)"
  else
    pass "vendored Core into core/ at ${_core_sha:0:12} (whole tree — $CORE_BRANCH predates core.vendor)"
  fi
fi

# ── entry layer (ZDOTDIR model): ~/.zshenv → ZDOTDIR; .zprofile/.zshrc in $ZDOTDIR ──
#
# THE .zsh EXTENSION IS LOAD-BEARING (#451). Core's reusable lint gate syntax-checks
# repo-owned zsh with `git ls-files '*.zsh'` (.github/workflows/lint-call.yml). Emitted
# as plain `zshenv`/`zprofile`/`zshrc`, these three matched nothing and were the only
# files in a generated repo that CI never checked — while ~/.zshenv in particular is
# sourced on EVERY zsh invocation, including non-interactive ones, and carries the
# ZDOTDIR indirection. A syntax error there does not degrade the shell, it breaks login
# shells outright on every box running that layer. Highest blast radius in the repo, and
# the one file the gate could not see. The symlink DESTINATION is ~/.zshenv regardless of
# the source filename, so the extension costs nothing.
w "$TARGET/zsh/zshenv.zsh" <<'EOF'
# zsh/zshenv.zsh → ~/.zshenv. Point ZDOTDIR at ~/.config/zsh so the rest of the shell
# config lives under XDG. Keep this file tiny — it runs for EVERY zsh (incl. scripts).
#
# Do NOT rename this to plain `zshenv` to match the symlink: the .zsh suffix is what
# puts it in front of the lint gate's `git ls-files '*.zsh'` (#451).
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
EOF

w "$TARGET/zsh/zprofile.zsh" <<'EOF'
# zsh/zprofile.zsh → $ZDOTDIR/.zprofile. Login-shell setup (PATH, env). Interactive
# config lives in .zshrc. Add OS login-time bits here.
#
# The .zsh suffix is load-bearing for the lint gate — see zshenv.zsh (#451).
EOF

w "$TARGET/zsh/zshrc.zsh" <<'EOF'
# zsh/zshrc.zsh → $ZDOTDIR/.zshrc — interactive shell.
# The .zsh suffix is load-bearing for the lint gate — see zshenv.zsh (#451).
# Sources the vendored v4 Core loader, which globs the numbered fragments (Core NN-*.zsh
# + this repo's 80-os.zsh + any 99-local.zsh) and sources them in NN order. v4 keeps
# mutable state out of the config tree: history→$XDG_STATE_HOME, compdump→$XDG_CACHE_HOME,
# plugins→$XDG_DATA_HOME.
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
ZSH_CFG="${ZDOTDIR:-$HOME/.config/zsh}"
if [[ -r "$ZSH_CFG/loader.zsh" ]]; then
  source "$ZSH_CFG/loader.zsh"
else
  print -u2 -- "zshrc: Core loader not found — re-run bootstrap.sh to (re)link Core."
fi
EOF

# ── OS layer stub ─────────────────────────────────────────────────────────────
w "$TARGET/os/$os_lc.zsh" <<EOF
# os/$os_lc.zsh — the $OS interactive layer (symlinked to \$ZDOTDIR/80-os.zsh by bootstrap;
# band 80 = OS-native, the range reserved for this repo's own fragment).
# Put OS-specific aliases, PATH, and package-manager bits HERE — never in Core.
# It may use any Core helper (00-tools.zsh's _cache_eval and _core_is_wsl, 05-ui.zsh's
# _core_* primitives).
#
# Core ALREADY hooks direnv/gh/uv/ty and already answers "is this WSL?" (_core_is_wsl) —
# do not re-add either here. Seven os layers each carried a copy until dotfiles-core#449,
# and the reusable lint workflow now flags a duplicate. See VENDORING.md.
EOF

# ── OS capability declaration stub (#663/#667) ────────────────────────────────
# THE SAME ARGUMENT AS THE LOAD ORDER ABOVE. This script centralises the canonical
# module order in ONE place so a scaffolded repo can never start out of order; the
# capability table is the other thing a repo cannot be correct without and cannot
# discover for itself. A repo scaffolded without one boots into Core's built-in
# fallback rows and looks fine — which is exactly how the fleet ended up with nine
# repos and zero declarations for two releases after the schema landed.
#
# SCHEMA-VALID FROM BIRTH, so `make capabilities` and Core's audit §9c are green on
# day one and the author edits values rather than fighting a red gate. Every REQUIRED
# key is present; the values are dnf's and are WRONG for any other archive, which the
# banner says in the one place someone will actually read it.
#
# The optional keys are deliberately NOT stubbed out as commented placeholders. In this
# schema an OMISSION IS A STATEMENT — no PKG_ASSUME_YES means "never auto-confirm", no
# PKG_UPGRADE_PARTIAL means "`up -i` refuses", no MAINT_UNATTENDED_UPGRADE means
# "refuse" — so a stub that pre-declares them would hand every new repo the permissive
# answer by default. Point at the example instead; it documents all of them.
w "$TARGET/os/$os_lc.capabilities" <<EOF
# os/$os_lc.capabilities — the $OS capability declaration (Core v5, #663).
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ REPLACE EVERY VALUE BELOW. They are FEDORA's (dnf), copied so this file   │
# │ satisfies the schema from birth — they are NOT defaults and nothing in    │
# │ Core falls back to them. On any other archive they are simply wrong.      │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Read (never sourced) by Core's zsh/02-capabilities.zsh into \$_CORE_CAP, and by
# core/maint/dotfiles-maint.sh, which is bash. bootstrap.sh links it to
# \$ZDOTDIR/os.capabilities.
#
# core/PORTING-MATRIX.md §"Package-manager commands" tabulates all seven archives and
# is the transcription source. core/examples/os.capabilities.example documents every
# key, including the OPTIONAL ones this stub deliberately omits — in this schema an
# omission is a STATEMENT (no PKG_ASSUME_YES = never auto-confirm; no
# PKG_UPGRADE_PARTIAL = \`up -i\` refuses; no MAINT_UNATTENDED_UPGRADE = refuse), so
# read that file before adding one.
#
# Validate with:  core/scripts/check-capabilities.sh os/$os_lc.capabilities
#
# A \`#\` INSIDE A VALUE IS NOT A COMMENT — the reader keeps it. Notes go above.

# ── package-manager verbs (all required) ──────────────────────────────────────
PKG_REFRESH=sudo dnf check-update
# The INTERACTIVE upgrade verb — no auto-confirm flag here; that is PKG_ASSUME_YES.
PKG_UPGRADE=sudo dnf upgrade --refresh
PKG_INSTALL=sudo dnf install -y
PKG_REMOVE=sudo dnf remove -y
PKG_SEARCH=dnf search
PKG_OWNS=dnf provides
# What \`up\`'s once-a-day "N updates available" nudge counts, and the verb that
# diverges most across archives. Non-root and non-mutating, always.
PKG_COUNT_PENDING=dnf -q --refresh check-update

# ── scheduler (required) ──────────────────────────────────────────────────────
# systemd | launchd | cron | none. \`cron\` is what an OpenRC box gets; \`none\` is a
# real answer (a container) and tells the maint layer to offer the manual verb
# rather than claim a timer it cannot install.
SCHEDULER=systemd
# REQUIRED for systemd and launchd; cron and none take NONE. A DIRECTORY, not a full
# path — Core appends its own unit name. An OS-absolute path is CORRECT here and
# wrong in Core, which is this key's whole point.
SCHEDULER_UNIT_DIR=~/.config/systemd/user
EOF

# ── starter bootstrap ─────────────────────────────────────────────────────────
w "$TARGET/bootstrap.sh" <<EOF
#!/usr/bin/env bash
# bootstrap.sh — symlink the vendored Core + the $OS os/ layer into place. Idempotent.
# Generated by dotfiles-core/scripts/new-os-repo.sh — extend with $OS provisioning.
set -euo pipefail
# usage() is the ONE place a flag is documented, and --help prints it — never a line
# range of this header, which drifts the moment a line is added above it and then
# prints implementation instead of help. Add a flag: add its line here and its case below.
usage() {
  cat <<'USAGE'
usage: bootstrap.sh [--dry-run | -n] [--links-only] [--help | -h]

Symlink the vendored Core + the $OS os/ layer into place. Idempotent; safe to re-run
after every Core sync.

  --dry-run, -n   print every planned link; change nothing
  --links-only    accepted for parity with the fleet's bootstraps — this starter is
                  links-only already, so it is the default
  --help, -h      this text
USAGE
}
REPO="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CFG="\$HOME/.config"
DRY=0
for a in "\$@"; do
  case "\$a" in
  --dry-run | -n) DRY=1 ;;
  --links-only) ;; # already the only thing this starter does — see usage()
  -h | --help) usage; exit 0 ;;
  *) echo "unknown flag: \$a" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -d "\$REPO/core" ]] || { echo "core/ subtree missing — run the subtree add first" >&2; exit 1; }

link() { # link <src> <dest> — back up a real file once, then symlink
  local src="\$1" dest="\$2" bak=""
  [[ -e "\$src" ]] || return 0
  if [[ -L "\$dest" && "\$(readlink "\$dest")" == "\$src" ]]; then return 0; fi
  if ((DRY)); then
    [[ -e "\$dest" && ! -L "\$dest" ]] && echo "would back up existing \${dest/#\$HOME/~}"
    echo "would link \${dest/#\$HOME/~} -> \${src/#\$REPO/.}"
    return 0
  fi
  mkdir -p "\$(dirname "\$dest")"
  [[ -L "\$dest" ]] && rm -f "\$dest"
  # ONE fleet-wide backup format: a zero-padded YYYYMMDD-HHMMSS stamp (so a lexical sort
  # is chronological, which is what --uninstall relies on to pick the newest) plus \$\$
  # (so two backups of the same dest inside one second cannot overwrite each other).
  # Matches core/lib/bootstrap-lib.sh's _blib_backup_suffix — keep the two in step (#464).
  # Announced, not silent: a displaced real file is the one wiring outcome that touched
  # something the user owned (#463).
  if [[ -e "\$dest" ]]; then
    bak="\$dest.pre-dotfiles.\$(date +%Y%m%d-%H%M%S).\$\$"
    mv "\$dest" "\$bak"
    echo "backed up existing \${dest/#\$HOME/~} -> \${bak/#\$HOME/~}" >&2
  fi
  ln -s "\$src" "\$dest"
  echo "linked \${dest/#\$HOME/~}"
}

# Core zsh modules + entry layer
for f in "\$REPO"/core/zsh/*.zsh; do link "\$f" "\$CFG/zsh/\$(basename "\$f")"; done
link "\$REPO/os/$os_lc.zsh" "\$CFG/zsh/80-os.zsh"
# The capability DECLARATION. Un-numbered and not a .zsh on purpose: the loader globs
# [0-9][0-9]-*.zsh, so this is never sourced into your shell — it is DATA that Core
# READS, which is what keeps a per-repo file off the code-execution path.
link "\$REPO/os/$os_lc.capabilities" "\$CFG/zsh/os.capabilities"
link "\$REPO/zsh/zshenv.zsh"   "\$HOME/.zshenv"
link "\$REPO/zsh/zprofile.zsh" "\$CFG/zsh/.zprofile"
link "\$REPO/zsh/zshrc.zsh"    "\$CFG/zsh/.zshrc"
# Core configs
link "\$REPO/core/starship/starship.toml" "\$CFG/starship.toml"
link "\$REPO/core/tmux/tmux.conf"         "\$CFG/tmux/tmux.conf"
link "\$REPO/core/tmux/tmux.reset.conf"   "\$CFG/tmux/tmux.reset.conf"
link "\$REPO/core/nvim"                   "\$CFG/nvim"
link "\$REPO/core/git/gitconfig"          "\$HOME/.gitconfig"
# mise is COPIED, not linked: \`mise use -g\` rewrites this file, and through a symlink
# that write lands in the vendored core/ tree (tampered tree + skipped fleet sync). The
# full bootstrap (core/lib/bootstrap-lib.sh) uses blib_adopt here, which also migrates an
# existing symlink and reports drift; this starter template just avoids creating one.
if [[ ! -e "\$CFG/mise/config.toml" && -f "\$REPO/core/mise/config.toml" ]]; then
  if ((DRY)); then
    echo "would seed \${CFG/#\$HOME/~}/mise/config.toml"
  else
    mkdir -p "\$CFG/mise"
    cp "\$REPO/core/mise/config.toml" "\$CFG/mise/config.toml"
    echo "seeded \${CFG/#\$HOME/~}/mise/config.toml (yours to edit)"
  fi
fi
if ((DRY)); then echo "dry run — nothing was written"; else echo "done — open a new shell or: exec zsh"; fi
EOF
((DRY)) || chmod +x "$TARGET/bootstrap.sh" 2>/dev/null

w "$TARGET/.gitignore" <<'EOF'
# machine-local / never tracked
zsh/99-local.zsh
.config/git/local.gitconfig
*.zwc
# Crash dumps. `core.[0-9]*`, NOT `core.*`: this repo tracks core.lock, and bare `core` is
# the vendored Core DIRECTORY — a blanket rule would hide either one silently.
core.[0-9]*
EOF

# ── the fleet's make vocabulary + the test floor (#691) ───────────────────────
# THE SAME ARGUMENT A THIRD TIME. Load order and the capability declaration are stamped
# here because a repo cannot be correct without them and cannot discover them for itself.
# The seven canonical `make` verbs (scripts/make-vocabulary.txt) and the test floor — a
# populated test/ dir, run from a workflow — are the third such thing: a repo scaffolded
# without them is **missing** across its whole row of the vocabulary register the day it
# joins scripts/os-repos.txt, and nothing inside it would ever notice. Stamp them once, so
# a greenfield repo meets the contract from birth instead of owing it.
#
# EVERY RECIPE HERE CLEARS _core_make_gate_hits (#775): a guard and the tool it guards sit
# on ONE logical line, and only `exit 1` guards stand alone. test-core.sh F7b asserts it.
#
# `test` runs the suite by EXPLICIT PATH, not a `test/*.sh` loop, so the register's suite
# detection credits it and the cell reads ok rather than no-op; a repo that grows more
# scripts adds them as more recipe lines.
w "$TARGET/Makefile" <<'EOF'
# Makefile — a discoverable façade over this repo's entry points.
# ──────────────────────────────────────────────────────────────────────────────
# Generated by dotfiles-core/scripts/new-os-repo.sh. Deliberately thin: it adds no logic
# beyond what CI already runs. `make lint` runs the BLOCKING legs of Core's reusable lint
# gate locally — shellcheck, bash -n, zsh -n, RETURN-trap discipline, the capability
# schema, markdownlint, actionlint, gitleaks and the Makefile-gate check — reading the
# SAME rules the gate reads: the vendored core/scripts/lib/common.sh scanners, Core's
# gitleaks.toml, this repo's .markdownlint.jsonc. The gate itself is called by
# .github/workflows/lint.yml (scaffolded beside this file), and it is the verdict: it
# installs and verifies PINNED tool versions (core/scripts/tool-versions.env) where these
# recipes use whatever is on PATH, and it also runs the advisory shfmt and Core-owned-block
# legs, which are not mirrored here. A leg whose tool is not installed SAYS SO and skips —
# never silently, and CI still runs it — so on a bare box the skips name what was not
# checked, and a local green is a strong prediction of the gate, not the gate.
#
# THE VERBS ARE THE FLEET'S, NOT THIS REPO'S. help / lint / check / dry-run /
# packages-check / core-verify / test are the canonical vocabulary every repo that vendors
# Core defines. Declared in dotfiles-core's scripts/make-vocabulary.txt; the contract is
# dotfiles-core's VENDORING.md § "The `make` vocabulary, and the test floor" — both live
# in the SOURCE repo only, neither is vendored into core/. Keep the canonical names; add
# your own targets and aliases beside them, never instead of them.
#
# NOT to be confused with dotfiles-core's own Makefile: that one exists in the SOURCE
# repo only — it is in neither core.manifest nor core.vendor, so no core/Makefile is ever
# vendored here — and its audit / sync / release targets would be meaningless from a
# vendored copy anyway. The vendored core/ is excluded from every check here: it is
# gated upstream.
#
# Every guard sits on the same recipe line as the tool it guards (dotfiles-core#775):
# make runs each line in its own shell, so an `exit 0` on a line of its own skips nothing.
# ──────────────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
.PHONY: help lint shellcheck syntax zsh-syntax trap-guard capabilities markdownlint actionlint secrets make-gate check dry-run packages-check core-verify test

# Repo-owned shell only — core/ is gated upstream. Mirrors the reusable gate's pathspec.
SH_FILES  := $(shell git ls-files '*.sh' ':!:core/**' 2>/dev/null)
ZSH_FILES := $(shell git ls-files '*.zsh' ':!:core/**' 2>/dev/null)
MD_FILES  := $(shell git ls-files '*.md' ':!:core/**' 2>/dev/null)
# The vendored scanners `trap-guard` and `make-gate` source — the rules live in Core, once.
CORE_LIB  := core/scripts/lib/common.sh
# Identical to the reusable gate's env, so a local pass means a CI pass.
export SHELLCHECK_OPTS := -e SC1090 -e SC1091 -e SC2015 -e SC2088
# A sibling dotfiles-core checkout, for core-verify (override: make core-verify CORE_REPO=...)
CORE_REPO ?= $(CURDIR)/../dotfiles-core

help: ## Show this help
	@echo "$(notdir $(CURDIR)) — make targets:"
	@grep -E '^[a-z][a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/:.*## /\t/' | sort | awk -F'\t' '{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

lint: shellcheck syntax zsh-syntax trap-guard capabilities markdownlint actionlint secrets make-gate ## The blocking legs of CI's lint gate, locally (a leg whose tool is absent says so and skips; CI pins the versions and is the verdict)
	@printf '\033[32m✓\033[0m lint clean\n'

shellcheck: ## ShellCheck the repo-owned bash, excluding the vendored core/ (skips without shellcheck; CI runs it)
	@# The skip, the empty-list branch and the run share ONE logical line: SH_FILES is
	@# `git ls-files`, so it is empty until the scaffold is committed, and a separate
	@# `exit 0` would end only its own line and let `shellcheck -x` run with no files.
	@if ! command -v shellcheck >/dev/null 2>&1; then echo "shellcheck not installed — skipped; CI runs it"; \
	elif test -z "$(SH_FILES)"; then echo "no repo-owned .sh tracked yet (git add first)"; \
	else echo "shellcheck -x $(SH_FILES)"; shellcheck -x $(SH_FILES); fi

syntax: ## bash -n the repo-owned bash, and check --help still works
	@if test -z "$(SH_FILES)"; then echo "no repo-owned .sh tracked yet (git add first)"; \
	else for f in $(SH_FILES); do echo "bash -n $$f"; bash -n "$$f" || exit 1; done; fi
	@bash bootstrap.sh --help >/dev/null || { echo "bootstrap.sh --help failed"; exit 1; }

zsh-syntax: ## zsh -n the repo-owned zsh (shellcheck has no zsh mode; skips without zsh)
	@if ! command -v zsh >/dev/null 2>&1; then echo "zsh not installed — skipping"; \
	elif test -z "$(ZSH_FILES)"; then echo "no repo-owned .zsh"; \
	else for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || exit 1; done; fi

trap-guard: ## Refuse a RETURN trap that does not disarm itself (shellcheck cannot see this; the rule is Core's _core_return_trap_hits)
	@# A bash RETURN trap is a GLOBAL slot, not a function-scoped one: armed inside a
	@# function it survives into the caller's frame and fires again on ITS return. Valid
	@# bash, so shellcheck and bash -n pass it — hence the dedicated scan, whose one
	@# definition is the vendored scanner. One logical line, like every leg here.
	@if test -z "$(SH_FILES)"; then echo "no repo-owned .sh tracked yet (git add first)"; \
	elif ! test -r "$(CORE_LIB)"; then echo "$(CORE_LIB) missing — vendor Core first"; exit 1; \
	else bash -c '. "$$0"; rc=0; shift; for f; do while IFS= read -r l; do [ -n "$$l" ] || continue; echo "$$f:$$l: a RETURN trap is armed without disarming itself"; rc=1; done < <(_core_return_trap_hits "$$f"); done; [ "$$rc" -eq 0 ] && echo "RETURN traps disarm themselves ($(words $(SH_FILES)) files)"; exit $$rc' "$(CORE_LIB)" $(SH_FILES); fi

capabilities: ## Validate os/*.capabilities against Core's schema (skips when the vendored validator predates v4.19.0; CI runs it)
	@# The validator arrived in Core v4.19.0; a pin between the v4.1.0 floor and that
	@# release vendors none, and the reusable gate's leg skips in that state — so does this.
	@# The glob is guarded: an unmatched glob stays LITERAL in sh, and a gate must never
	@# pass on nothing. --packages is passed only once install/packages.txt exists.
	@if ! test -x core/scripts/check-capabilities.sh; then echo "core/scripts/check-capabilities.sh not vendored (Core older than v4.19.0) — skipped; CI runs it"; \
	else rc=0; found=0; pk=""; [ -r install/packages.txt ] && pk="--packages install/packages.txt"; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" $$pk || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc; fi

markdownlint: ## Lint repo-owned markdown against this repo's .markdownlint.jsonc (markdownlint-cli2 on PATH, else npx at Core's pinned version; skips without either)
	@if test -z "$(MD_FILES)"; then echo "no repo-owned .md tracked yet"; \
	elif command -v markdownlint-cli2 >/dev/null 2>&1; then markdownlint-cli2 $(MD_FILES); \
	elif command -v npx >/dev/null 2>&1; then v="$$(sed -n '/^MARKDOWNLINT_VERSION=/{s///p;q;}' core/scripts/tool-versions.env)"; npx --yes "markdownlint-cli2@$${v:-latest}" $(MD_FILES); \
	else echo "markdownlint-cli2 not installed (npm i -g markdownlint-cli2) — skipped; CI runs it"; fi

actionlint: ## Lint .github/workflows (skips without actionlint; CI runs it)
	@if ! command -v actionlint >/dev/null 2>&1; then echo "actionlint not installed — skipped; CI runs it"; else actionlint; fi

secrets: ## Scan the working tree for committed secrets against Core's ONE policy file (skips without gitleaks; CI runs it)
	@# -c core/gitleaks.toml: every repo measured the same way, no repo widening its own
	@# allowlist — the rule the reusable gate's secrets leg states.
	@if ! command -v gitleaks >/dev/null 2>&1; then echo "gitleaks not installed — skipped; CI runs it"; else gitleaks dir . -c core/gitleaks.toml --no-banner --redact; fi

make-gate: ## Every Makefile guard shares a line with its tool, and skips/fails as its help text says (Core's _core_make_gate_hits, dotfiles-core#775)
	@if ! test -r "$(CORE_LIB)"; then echo "$(CORE_LIB) missing — vendor Core first"; exit 1; \
	else bash -c '. "$$0"; h="$$(_core_make_gate_hits .)" || { echo "_core_make_gate_hits failed to run"; exit 1; }; [ -z "$$h" ] || { printf "%s\n" "$$h"; exit 1; }; echo "every Makefile gate skips, fails and scopes as its help text claims"' "$(CORE_LIB)"; fi

check: lint ## lint + a hermetic links run against a throwaway HOME (test/check-links.sh)
	@./test/check-links.sh

dry-run: ## Preview every link bootstrap would create; change nothing
	@./bootstrap.sh --dry-run

# A verb that does not apply is STUBBED, not absent, so `make packages-check` resolves in
# every repo (dotfiles-core's VENDORING.md). Replace this the day install/packages.txt exists —
# dotfiles-Debian/test/check-packages.sh is the model for a real resolver.
packages-check: ## Resolve every package name (stub until this repo has a package list)
	@echo "packages-check: not applicable to this repo (no OS package list yet)"

core-verify: ## Verify the vendored core/ is pristine vs core.lock (needs CORE_REPO)
	@[ -x "$(CORE_REPO)/scripts/core-integrity.sh" ] || { echo "need a dotfiles-core checkout at CORE_REPO=$(CORE_REPO)"; exit 1; }
	@"$(CORE_REPO)/scripts/core-integrity.sh" --self "$(CURDIR)"

test: ## Run this repo's own suite (test/)
	@./test/check-links.sh
EOF

# The reusable gate's markdown leg lints against the CALLER's own .markdownlint.jsonc, so a
# repo without one is judged by markdownlint's stock defaults — MD013's 80-column limit
# alone would red the README above. Core's rule choices, the two that are off and why,
# with the README-specific HTML allowance left out: a fresh OS repo has no showcase page.
w "$TARGET/.markdownlint.jsonc" <<'EOF'
// .markdownlint.jsonc — the rules `make markdownlint` and the reusable lint gate's
// markdown leg judge this repo's own markdown by (the vendored core/ is gated upstream).
// Generated by dotfiles-core/scripts/new-os-repo.sh from Core's choices; keep it tight —
// a rule turned off here should be a deliberate decision, not a silencer.
{
  "default": true,

  // MD013 (line-length): OFF. Prose wraps by sentence and tables run wide; a long line
  // is not a defect here, so flagging every table row is pure noise.
  "MD013": false,

  // MD041 (first-line-h1): OFF. Issue and PR templates are fragments injected into
  // GitHub's UI and legitimately open with front matter or a section heading.
  "MD041": false,

  // MD024 (no-duplicate-heading): SIBLINGS ONLY. A Keep-a-Changelog CHANGELOG repeats
  // ### Added / ### Changed / ### Fixed under every release; a true duplicate under the
  // SAME parent still fires.
  "MD024": { "siblings_only": true }
}
EOF

# A REAL test, not an `exit 0` stub: the floor is worth nothing if the template meets it
# with a script that asserts nothing. What it pins is the one property every later
# `make check` relies on — that bootstrap.sh wires what it says and is quiet the second
# time — and it needs only bash, so it runs on any runner and in Core's own fixture.
w "$TARGET/test/check-links.sh" <<'EOF'
#!/usr/bin/env bash
# test/check-links.sh — does bootstrap.sh wire this repo the way it says, and stay quiet
# the second time? Generated by dotfiles-core/scripts/new-os-repo.sh; extend it as the
# repo grows (dotfiles-Debian/test/ is the model for what a real suite looks like).
#
# Runs bootstrap.sh three times against a throwaway HOME and asserts:
#   1. --dry-run prints its plan and writes nothing;
#   2. a real run links every repo-owned file to its destination — and the Core-provided
#      ones too, when the vendored core/ carries them;
#   3. a second run changes nothing. Idempotency is the property every later `make check`
#      relies on, and the one a hand-edited bootstrap loses first.
# Needs only bash. Exit 0 clean, 1 on any failure.
set -uo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO" || exit 1

# `set -e` is deliberately off (the exit code IS the result), so the sandbox is guarded
# by hand: an empty $tmp would turn "$tmp/home" into /home, and a hermetic test would
# write to the host.
tmp="$(mktemp -d)" && [[ -n "$tmp" && -d "$tmp" ]] || { echo "check-links: could not create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
rc=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*" >&2; rc=1; }

# ── 1. --dry-run touches nothing ─────────────────────────────────────────────
mkdir -p "$tmp/dry"
if ! HOME="$tmp/dry" ./bootstrap.sh --dry-run >"$tmp/dry.out" 2>&1; then
  bad "bootstrap.sh --dry-run exited non-zero: $(cat "$tmp/dry.out")"
fi
# `ls -A`, not `find -quit`: BSD find on macOS lacks -quit, and a failing find would
# substitute EMPTY and pass this assertion for the wrong reason.
if [[ -z "$(ls -A "$tmp/dry")" ]]; then
  ok "--dry-run wrote nothing"
else
  # shellcheck disable=SC2012  # a diagnostic listing of our own temp dir; `find -mindepth` is GNU-only
  bad "--dry-run wrote into HOME: $(ls -A "$tmp/dry" | head -5 | tr '\n' ' ')"
fi
if grep -q 'would link' "$tmp/dry.out"; then ok "--dry-run printed its plan"; else bad "--dry-run printed no plan"; fi

# ── 2. a real run links what it says ─────────────────────────────────────────
# --links-only on BOTH real runs, deliberately: `make check` is defined as a hermetic
# links run (dotfiles-core's VENDORING.md), and this suite is what `make check`, `make test` and CI
# all reach. The starter bootstrap is links-only today, but the moment this repo adds
# the provisioning it is expected to, a bare invocation here would install packages on
# the runner — and would be testing provisioning idempotency, not link idempotency.
mkdir -p "$tmp/home"
if ! HOME="$tmp/home" ./bootstrap.sh --links-only >"$tmp/run1.out" 2>&1; then
  bad "bootstrap.sh exited non-zero: $(cat "$tmp/run1.out")"
fi
CFG="$tmp/home/.config"
check_link() { # check_link <dest> <src>
  if [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; then
    ok "${1#"$tmp/home/"} -> ${2#"$REPO/"}"
  else
    bad "${1#"$tmp/home/"} is not a symlink to ${2#"$REPO/"}"
  fi
}
# Repo-owned: always present, always linked.
check_link "$tmp/home/.zshenv" "$REPO/zsh/zshenv.zsh"
check_link "$CFG/zsh/.zprofile" "$REPO/zsh/zprofile.zsh"
check_link "$CFG/zsh/.zshrc" "$REPO/zsh/zshrc.zsh"
for f in "$REPO"/os/*.zsh; do [[ -e "$f" ]] && check_link "$CFG/zsh/80-os.zsh" "$f"; done
for f in "$REPO"/os/*.capabilities; do [[ -e "$f" ]] && check_link "$CFG/zsh/os.capabilities" "$f"; done
# The one Core file that is NOT optional: the scaffolded zshrc sources
# $ZDOTDIR/loader.zsh, so a core/ that exists but lacks zsh/loader.zsh boots a bare shell
# while bootstrap reports success. Require it before the conditional Core checks below.
if [[ -e "$REPO/core/zsh/loader.zsh" ]]; then
  check_link "$CFG/zsh/loader.zsh" "$REPO/core/zsh/loader.zsh"
else
  bad "core/zsh/loader.zsh is missing — the scaffolded zshrc sources it, so every shell would start bare"
fi
# The rest of Core is asserted when the vendored core/ carries the source (a core/
# vendored from an older Core may lack one), so the test never asserts a link
# bootstrap.sh would not have made. EVERY Core zsh
# module, both tmux files and the single configs — the whole link list bootstrap.sh
# carries, so dropping or breaking any link line there goes red here.
# The loader was asserted above; skip it here so each link is counted exactly once.
for f in "$REPO"/core/zsh/*.zsh; do
  [[ -e "$f" && "${f##*/}" != loader.zsh ]] && check_link "$CFG/zsh/$(basename "$f")" "$f"
done
for pair in "core/starship/starship.toml:$CFG/starship.toml" "core/tmux/tmux.conf:$CFG/tmux/tmux.conf" \
  "core/tmux/tmux.reset.conf:$CFG/tmux/tmux.reset.conf" "core/nvim:$CFG/nvim" \
  "core/git/gitconfig:$tmp/home/.gitconfig"; do
  src="$REPO/${pair%%:*}"
  dest="${pair#*:}"
  [[ -e "$src" ]] || continue
  check_link "$dest" "$src"
done
if [[ -f "$REPO/core/mise/config.toml" ]]; then
  # A regular file is not enough — an empty or stale one would pass as "seeded". The
  # copy must carry the seed's bytes. Compared by Git blob hash, not `cmp`: cmp ships in
  # diffutils, which a Tumbleweed box in this fleet did not have, and a missing cmp is
  # indistinguishable from "the files differ" (core/scripts/lib/common.sh has the story).
  _seed_hash="$(git hash-object "$REPO/core/mise/config.toml" 2>/dev/null)"
  _copy_hash="$(git hash-object "$CFG/mise/config.toml" 2>/dev/null)"
  if [[ -f "$CFG/mise/config.toml" && ! -L "$CFG/mise/config.toml" && -n "$_seed_hash" && "$_seed_hash" == "$_copy_hash" ]]; then
    ok "mise config is seeded as a COPY of core/mise/config.toml (a link would write \`mise use -g\` into core/)"
  else
    bad "mise config is missing, is a symlink into the vendored tree, or does not match the seed's bytes"
  fi
fi

# ── 3. the second run changes nothing ────────────────────────────────────────
# Three independent witnesses, because none alone is proof:
#   · The MUTATING COMMANDS the run invokes. The second run happens with a shim directory
#     first on PATH whose rm/ln/mv/cp/mkdir/chmod log their invocation and then exec the
#     real tool; an idempotent run invokes none of them. This is the primary witness — a
#     remove-and-recreate is seen as it happens, whatever the filesystem does with inodes.
#   · The TREE. Every entry under HOME — inode, mode, kind, link target, and for a regular
#     file its bytes — must be identical before and after. This catches what no wrapped
#     command performs: a file rewritten through a shell redirection keeps its inode but
#     not its checksum, and a mode changed through an absolute-path chmod keeps everything
#     but its mode string. `ls -ldi`, `readlink` and POSIX `cksum` are what GNU and BSD
#     share; no `-mindepth` (GNU) — the root row is dropped by name instead.
#   · WRITES. A rewrite with the SAME bytes is invisible to both of the above — no wrapped
#     command, and inode, mode, kind and checksum all survive — so a stamp file is touched
#     after the first run and `find -newer` (POSIX) must list nothing under HOME after
#     the second. One second is slept before that run: on a filesystem with 1-second
#     mtime resolution a rewrite inside the stamp's own second could otherwise hide.
# Output prefixes are the fourth, weakest claim, kept only as a message.
snapshot() { # snapshot <dir> → one line per entry: inode mode kind path [-> target | cksum]
  find "$1" -print | LC_ALL=C sort | while IFS= read -r p; do
    [[ "$p" == "$1" ]] && continue
    # shellcheck disable=SC2012  # the paths are ours (no odd names), and `find -printf` / `stat -c` are GNU-only
    ino_mode="$(ls -ldi "$p" | awk '{print $1, $2}')"   # no `--`: BSD ls; the paths are our own absolute sandbox paths
    if [[ -L "$p" ]]; then printf '%s L %s -> %s\n' "$ino_mode" "$p" "$(readlink "$p")"
    elif [[ -d "$p" ]]; then printf '%s D %s\n' "$ino_mode" "$p"
    else printf '%s F %s %s\n' "$ino_mode" "$p" "$(cksum <"$p" | awk '{print $1, $2}')"; fi
  done
}
# The rows that differ, without diffutils (a fleet host has been seen without `diff`;
# core/scripts/lib/common.sh records it): a two-pass awk set difference.
snapshot_delta() { # snapshot_delta <before> <after> → "> row" for rows gone, "< row" for rows new
  awk 'NR == FNR { seen[$0]; next } !($0 in seen) { print "> " $0 }' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
  awk 'NR == FNR { seen[$0]; next } !($0 in seen) { print "< " $0 }' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}
mkdir -p "$tmp/shim"
: >"$tmp/mutations.log"
for cmd in rm ln mv cp mkdir chmod; do
  # Log, then hand off to the real tool — found by searching PATH with the shim dir
  # (its first entry) removed, so the wrapper never recurses into itself.
  cat >"$tmp/shim/$cmd" <<'SHIM'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$MUT_LOG"
PATH="${PATH#*:}" exec "${0##*/}" "$@"
SHIM
  chmod +x "$tmp/shim/$cmd"
done
before="$(snapshot "$tmp/home")"
: >"$tmp/stamp"
sleep 1
if ! HOME="$tmp/home" MUT_LOG="$tmp/mutations.log" PATH="$tmp/shim:$PATH" ./bootstrap.sh --links-only >"$tmp/run2.out" 2>&1; then
  bad "second bootstrap.sh run exited non-zero: $(cat "$tmp/run2.out")"
fi
after="$(snapshot "$tmp/home")"
written="$(find "$tmp/home" -newer "$tmp/stamp" -print)"
if [[ -s "$tmp/mutations.log" ]]; then
  bad "second run invoked mutating commands: $(head -4 "$tmp/mutations.log" | tr '\n' ';')"
elif [[ "$before" != "$after" ]]; then
  bad "second run changed the tree: $(snapshot_delta "$before" "$after" | head -4 | tr '\n' ' ')"
elif [[ -n "$written" ]]; then
  bad "second run rewrote files in place (same bytes, newer mtime): $(head -4 <<<"$written" | tr '\n' ' ')"
elif grep -Eq '^(linked|backed up|seeded) ' "$tmp/run2.out"; then
  bad "second run claims to have changed something: $(grep -E '^(linked|backed up|seeded) ' "$tmp/run2.out" | tr '\n' ' ')"
else
  ok "second run changed nothing (no rm/ln/mv/cp/mkdir/chmod invoked; every inode, mode, kind, link target and file checksum identical; nothing written after the stamp)"
fi

if ((rc == 0)); then
  printf '\033[32m✓\033[0m check-links: bootstrap.sh wires this repo and is idempotent\n'
fi
exit "$rc"
EOF
((DRY)) || chmod +x "$TARGET/test/check-links.sh" 2>/dev/null

# The lint gate is Core's reusable workflow, consumed as the fleet's three-line caller —
# without it a new repo's Makefile would claim legs (RETURN-trap, actionlint, markdown,
# gitleaks, Makefile-gate) that nothing ran. The major is READ FROM core.version at
# scaffold time rather than typed, so this caller cannot rot the way the first-vendor
# pin did (audit §8a-ter): a v7 Core scaffolds a v7 caller.
_core_major="$(tr -d '[:space:]' <"$HERE/core.version" | cut -d. -f1)"
[[ "$_core_major" =~ ^[0-9]+$ ]] || { fail "core.version major unreadable ('$_core_major') — cannot pin the lint caller"; exit 1; }
w "$TARGET/.github/workflows/lint.yml" <<EOF
name: lint

# Thin caller for the reusable shell/actionlint/markdown/secrets/Makefile-gate lint gate
# authored in dotfiles-core (.github/workflows/lint-call.yml) — one definition for the
# whole fleet. Generated by dotfiles-core/scripts/new-os-repo.sh at Core major v$_core_major.
# NO path filters, deliberately: lint is meant to be a REQUIRED status check, and a
# required check that is filtered out never reports, so the PR waits forever.
on:
  push:
    branches: [main, master]
  pull_request:

concurrency:
  group: lint-\${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  lint:
    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v$_core_major
EOF

# The floor's second rung: the suite is RUN from a workflow, not merely present. `make
# test` is the step, so "passes locally" and "passes CI" are one command.
w "$TARGET/.github/workflows/test.yml" <<'EOF'
name: test

# Generated by dotfiles-core/scripts/new-os-repo.sh. Runs this repo's own suite, which is
# the fleet's test floor (dotfiles-core's VENDORING.md § "The `make` vocabulary, and the
# test floor" — in the source repo, not under core/):
# a populated test/ directory, run from a workflow. `make test` is what runs here, so
# "passes locally" and "passes CI" are the same command.
on:
  push:
    # Both, like the fleet's callers: the scaffold's `git init` follows the author's
    # init.defaultBranch, which may still be master, and a push filter that names only
    # main would then never run.
    branches: [main, master]
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: make test
EOF

w "$TARGET/README.md" <<EOF
# dotfiles-$OS

The $OS machine repo. Vendors [Core](../dotfiles-core) under \`core/\`
and adds the $OS-native layer (\`os/$os_lc.zsh\`, package manager, paths).

## The capability declaration

\`os/$os_lc.capabilities\` tells Core how THIS archive updates: the package-manager
verbs, the scheduler, and which tools are opt-in here. Core's \`up\`, its maintenance
runner and \`core-doctor\` all dispatch through it, so it is the file that stops Core
from carrying $OS knowledge it has no business having.

**The scaffold shipped Fedora's values.** Replace them —
\`core/PORTING-MATRIX.md\` §"Package-manager commands" tabulates every archive, and
\`core/examples/os.capabilities.example\` documents every key. Then:

\`\`\`bash
core/scripts/check-capabilities.sh os/$os_lc.capabilities
\`\`\`

In this schema an **omission is a statement**: no \`PKG_ASSUME_YES\` means never
auto-confirm, no \`PKG_UPGRADE_PARTIAL\` means \`up -i\` refuses, and no
\`MAINT_UNATTENDED_UPGRADE\` means the scheduled runner will not apply system upgrades
here. Leave a key out to mean those things; do not add one to be helpful.

## Install

\`\`\`bash
./bootstrap.sh
\`\`\`

## Gates

\`make help\` lists every target. The seven that exist in every repo vendoring Core —
\`help\`, \`lint\`, \`check\`, \`dry-run\`, \`packages-check\`, \`core-verify\`, \`test\` — are
the fleet's Makefile vocabulary (dotfiles-core's \`VENDORING.md\` — the source repo, it is
not vendored into \`core/\` — § "The \`make\` vocabulary, and the
test floor"); keep those names and add your own beside them. \`make test\` runs \`test/\`,
which \`.github/workflows/test.yml\` also runs on every push; \`make lint\` runs the
blocking legs of Core's reusable lint gate with whatever tools are on PATH — a leg whose
tool is not installed says so and skips — while \`.github/workflows/lint.yml\` calls the
gate itself, with pinned tool versions and its advisory legs, and is the verdict.
\`packages-check\` is a stub until this repo has an \`install/packages.txt\`.

## Update Core

Core is fanned out **from Core**, not pulled from here. A raw \`git subtree pull\` moves
\`core/\` but not \`core.lock\`, and \`core-integrity\` then reports this tree as TAMPERED.

Normally a sync arrives as a PR from Core's fan-out and you just merge it. To run one
by hand, from a \`dotfiles-core\` checkout:

\`\`\`bash
./scripts/sync-core.sh dotfiles-$OS   # materializes core/ AND stamps core.lock
\`\`\`

Then, in this repo:

\`\`\`bash
./bootstrap.sh          # re-link any new/changed Core files
\`\`\`
EOF

printf '\n%s──────── dotfiles-%s scaffolded ────────%s\n' "$c_blu" "$OS" "$c_rst"
if ((DRY)); then
  echo "dry-run — nothing was written."
else
  # The registration step is named HERE because it is the one thing the scaffold cannot do
  # for you and the one thing nothing downstream will remind you about: a repo that exists
  # but is not in scripts/os-repos.txt is invisible to the fan-out, to fleet-drift and to
  # core-integrity, and every one of them stays green while ignoring it. Since #669 that
  # registration is a single line rather than four coordinated edits — see VENDORING.md.
  # A scaffold with no core/ yet (--no-vendor, or the vendor step failed) cannot follow
  # the sequence below in order: bootstrap.sh refuses to run without core/, and F7b
  # asserts that `make test` goes red in exactly that state. So that path is told to
  # materialize core/ FIRST, with the same recovery hint the vendor step printed.
  _next_vendor=""
  [[ -d "$TARGET/core" ]] || _next_vendor="
  FIRST — this scaffold has no core/ yet, and bootstrap.sh refuses to run without one,
  so nothing below passes until it exists. Materialize it (this commits the scaffold,
  then adds core/ and runs the pinned sync that stamps core.lock):
    $_vendor_hint
"
  # The REGISTER step's sync has the same two blind spots the recovery hint had: it
  # resolves the NAME dotfiles-$OS under REPOS_ROOT, which defaults to the Core
  # checkout's parent. A scaffold placed elsewhere, or named otherwise, would be skipped
  # as "not cloned" — so the printed command carries REPOS_ROOT when the parent differs
  # and is preceded by the canonical-name symlink when the name does. `ln -sfn`: on a
  # --no-vendor scaffold the FIRST step above has already created that link, and a plain
  # `ln -s` onto an existing directory symlink would follow it and drop a new link inside
  # the target repo, which the sync then refuses as dirty.
  # The register step is the FIRST sync that stamps core.lock, so it must carry the
  # release pin: a bare `./scripts/sync-core.sh dotfiles-X` defaults CORE_BRANCH to main
  # and would replace the just-materialized release tree with an unreleased tip — the
  # very thing this scaffold exists to prevent. It reuses the pinned worktree sync
  # (_sync_recover): the throwaway worktree at the pinned ref, the released script's own
  # summary line as the verdict (that script may predate --strict), REPOS_ROOT, and for
  # a custom name the guarded symlink chained in front with `&&`, so a refused guard
  # stops the sync instead of letting its directory fast path pick the occupant.
  _reg_sync="$_sync_recover"
  # The scaffold commit is IDEMPOTENT: on the no-core/ path the FIRST recovery command
  # has already committed the scaffold, and a bare `git commit` would then fail with
  # "nothing to commit" — the one step in the sequence a reader could not follow. And the
  # OS-layer edits get a commit of their own BEFORE the register step, because the sync
  # refuses a target with uncommitted changes (its dirty-tree guard) — without it the
  # advertised registration flow skips the repo it is registering.
  cat <<EOF
  next:$_next_vendor
    cd "$TARGET"
    git add -A && { git diff --cached --quiet || git commit -m "scaffold dotfiles-$OS"; }   # a no-op if already committed
    ./bootstrap.sh            # wire the symlinks
    make test                 # the repo's own suite (the fleet's test floor)
    \$EDITOR os/$os_lc.zsh     # add your $OS-native bits

  THEN FIX THE CAPABILITY DECLARATION — it was scaffolded with FEDORA's verbs so the
  schema is satisfied from birth, and they are wrong for any other archive:
    \$EDITOR os/$os_lc.capabilities
    core/scripts/check-capabilities.sh os/$os_lc.capabilities
    git add -A && git commit -m "os: the $OS layer and its capability declaration"   # the sync below refuses a dirty tree

  then, back in dotfiles-core — REGISTER IT, or the fleet never sees this repo:
    echo dotfiles-$OS >> scripts/os-repos.txt   # one line; keep the list sorted
    $_reg_sync   # the PINNED sync (a throwaway worktree at the release ref; its summary line is the verdict): stamps core.lock — a custom name gets the guarded symlink first, and a refusal stops it
EOF
fi
