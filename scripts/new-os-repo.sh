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
  --no-vendor    scaffold the files but skip the `git subtree add` (do it yourself later)

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
_vendor_hint="git -C '$TARGET' fetch '$CORE_REMOTE' '$CORE_BRANCH' && (cd '$HERE' && ./scripts/sync-core.sh dotfiles-$OS)"
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
  elif core_vendor_materialize "$TARGET" "$_core_sha" &&
    git -C "$TARGET" commit -q -m "chore(core): vendor Core at ${_core_sha:0:12}"; then
    if core_vendor_is_filtered "$TARGET" "$_core_sha"; then
      pass "vendored Core into core/ at ${_core_sha:0:12} (filtered: core.manifest + core.vendor)"
    else
      pass "vendored Core into core/ at ${_core_sha:0:12} (whole tree — $CORE_BRANCH predates core.vendor)"
    fi
  else
    fail "materializing core/ failed — files scaffolded; vendor later with: $_vendor_hint"
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
#
#   ./bootstrap.sh                 # (re)create the symlinks
#   ./bootstrap.sh --dry-run, -n   # print every planned link; change nothing
#   ./bootstrap.sh --links-only    # accepted for parity with the fleet's bootstraps —
#                                  # this starter is links-only already, so it is the default
#   ./bootstrap.sh --help, -h
set -euo pipefail
REPO="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CFG="\$HOME/.config"
DRY=0
for a in "\$@"; do
  case "\$a" in
  --dry-run | -n) DRY=1 ;;
  --links-only) ;; # already the only thing this starter does — see the header
  -h | --help) sed -n '2,9p' "\${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "unknown flag: \$a (try --help)" >&2; exit 2 ;;
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
# beyond what CI already runs. `make lint` mirrors the SHELL half of Core's reusable lint
# gate (shellcheck, bash -n, zsh -n) plus the capability schema; the gate's other legs —
# RETURN-trap discipline, actionlint, markdownlint, gitleaks and the Makefile-gate check —
# run in CI only, so a green `make lint` is necessary, not sufficient. Add local mirrors
# as the repo grows (dotfiles-Fedora's Makefile shows the shape for each).
#
# THE VERBS ARE THE FLEET'S, NOT THIS REPO'S. help / lint / check / dry-run /
# packages-check / core-verify / test are the canonical vocabulary every repo that vendors
# Core defines (core/scripts/make-vocabulary.txt; the contract is core/VENDORING.md
# § "The `make` vocabulary, and the test floor"). Keep the canonical names; add your own
# targets and aliases beside them, never instead of them.
#
# NOT to be confused with core/Makefile — that is dotfiles-core's own Makefile, which
# arrives with the vendored subtree; its audit / sync / release targets are meaningless
# from a vendored copy. The vendored core/ is excluded from every check here: it is gated
# upstream.
#
# Every guard sits on the same recipe line as the tool it guards (dotfiles-core#775):
# make runs each line in its own shell, so an `exit 0` on a line of its own skips nothing.
# ──────────────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
.PHONY: help lint shellcheck syntax zsh-syntax capabilities check dry-run packages-check core-verify test

# Repo-owned shell only — core/ is gated upstream. Mirrors the reusable gate's pathspec.
SH_FILES  := $(shell git ls-files '*.sh' ':!:core/**' 2>/dev/null)
ZSH_FILES := $(shell git ls-files '*.zsh' ':!:core/**' 2>/dev/null)
# Identical to the reusable gate's env, so a local pass means a CI pass.
export SHELLCHECK_OPTS := -e SC1090 -e SC1091 -e SC2015 -e SC2088
# A sibling dotfiles-core checkout, for core-verify (override: make core-verify CORE_REPO=...)
CORE_REPO ?= $(CURDIR)/../dotfiles-core

help: ## Show this help
	@echo "$(notdir $(CURDIR)) — make targets:"
	@grep -E '^[a-z][a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/:.*## /\t/' | sort | awk -F'\t' '{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

lint: shellcheck syntax zsh-syntax capabilities ## shellcheck + bash -n + zsh -n + the capability schema (the shell half of CI's lint gate)
	@printf '\033[32m✓\033[0m lint clean\n'

shellcheck: ## ShellCheck the repo-owned bash (excludes the vendored core/)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed — install it with your package manager"; exit 1; }
	@test -n "$(SH_FILES)" || { echo "no repo-owned .sh"; exit 0; }
	@echo "shellcheck -x $(SH_FILES)"
	@shellcheck -x $(SH_FILES)

syntax: ## bash -n the repo-owned bash, and check --help still works
	@test -n "$(SH_FILES)" || { echo "no repo-owned .sh"; exit 0; }
	@for f in $(SH_FILES); do echo "bash -n $$f"; bash -n "$$f" || exit 1; done
	@bash bootstrap.sh --help >/dev/null || { echo "bootstrap.sh --help failed"; exit 1; }

zsh-syntax: ## zsh -n the repo-owned zsh (shellcheck has no zsh mode; skips without zsh)
	@if ! command -v zsh >/dev/null 2>&1; then echo "zsh not installed — skipping"; \
	elif test -z "$(ZSH_FILES)"; then echo "no repo-owned .zsh"; \
	else for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || exit 1; done; fi

capabilities: ## Validate os/*.capabilities against Core's schema
	@# The glob is guarded: an unmatched glob stays LITERAL in sh, and a gate must never
	@# pass on nothing. --packages is passed only once install/packages.txt exists.
	@rc=0; found=0; pk=""; [ -r install/packages.txt ] && pk="--packages install/packages.txt"; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" $$pk || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc

check: lint ## lint + a hermetic links run against a throwaway HOME (test/check-links.sh)
	@./test/check-links.sh

dry-run: ## Preview every link bootstrap would create; change nothing
	@./bootstrap.sh --dry-run

# A verb that does not apply is STUBBED, not absent, so `make packages-check` resolves in
# every repo (core/VENDORING.md). Replace this the day install/packages.txt exists —
# dotfiles-Debian/test/check-packages.sh is the model for a real resolver.
packages-check: ## Resolve every package name (stub until this repo has a package list)
	@echo "packages-check: not applicable to this repo (no OS package list yet)"

core-verify: ## Verify the vendored core/ is pristine vs core.lock (needs CORE_REPO)
	@[ -x "$(CORE_REPO)/scripts/core-integrity.sh" ] || { echo "need a dotfiles-core checkout at CORE_REPO=$(CORE_REPO)"; exit 1; }
	@"$(CORE_REPO)/scripts/core-integrity.sh" --self "$(CURDIR)"

test: ## Run this repo's own suite (test/)
	@./test/check-links.sh
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
rc=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*" >&2; rc=1; }

# ── 1. --dry-run touches nothing ─────────────────────────────────────────────
mkdir -p "$tmp/dry"
if ! HOME="$tmp/dry" ./bootstrap.sh --dry-run >"$tmp/dry.out" 2>&1; then
  bad "bootstrap.sh --dry-run exited non-zero: $(cat "$tmp/dry.out")"
fi
if [[ -z "$(find "$tmp/dry" -mindepth 1 -print -quit)" ]]; then
  ok "--dry-run wrote nothing"
else
  bad "--dry-run wrote into HOME: $(find "$tmp/dry" -mindepth 1 | head -5 | tr '\n' ' ')"
fi
if grep -q 'would link' "$tmp/dry.out"; then ok "--dry-run printed its plan"; else bad "--dry-run printed no plan"; fi

# ── 2. a real run links what it says ─────────────────────────────────────────
mkdir -p "$tmp/home"
if ! HOME="$tmp/home" ./bootstrap.sh >"$tmp/run1.out" 2>&1; then
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
# Core-provided: asserted when the vendored core/ carries the source (it may not yet,
# in a --no-vendor scaffold), so the test is honest in both states. EVERY Core zsh
# module, both tmux files and the single configs — the whole link list bootstrap.sh
# carries, so dropping or breaking any link line there goes red here.
for f in "$REPO"/core/zsh/*.zsh; do [[ -e "$f" ]] && check_link "$CFG/zsh/$(basename "$f")" "$f"; done
for pair in "core/starship/starship.toml:$CFG/starship.toml" "core/tmux/tmux.conf:$CFG/tmux/tmux.conf" \
  "core/tmux/tmux.reset.conf:$CFG/tmux/tmux.reset.conf" "core/nvim:$CFG/nvim" \
  "core/git/gitconfig:$tmp/home/.gitconfig"; do
  src="$REPO/${pair%%:*}"
  dest="${pair#*:}"
  [[ -e "$src" ]] || continue
  check_link "$dest" "$src"
done
if [[ -f "$REPO/core/mise/config.toml" ]]; then
  if [[ -f "$CFG/mise/config.toml" && ! -L "$CFG/mise/config.toml" ]]; then
    ok "mise config is seeded as a COPY (a link would write \`mise use -g\` into core/)"
  else
    bad "mise config is missing or is a symlink into the vendored tree"
  fi
fi

# ── 3. the second run is silent ──────────────────────────────────────────────
if ! HOME="$tmp/home" ./bootstrap.sh >"$tmp/run2.out" 2>&1; then
  bad "second bootstrap.sh run exited non-zero: $(cat "$tmp/run2.out")"
fi
if grep -Eq '^(linked|backed up|seeded) ' "$tmp/run2.out"; then
  bad "second run was not idempotent: $(grep -E '^(linked|backed up|seeded) ' "$tmp/run2.out" | tr '\n' ' ')"
else
  ok "second run changed nothing"
fi

if ((rc == 0)); then
  printf '\033[32m✓\033[0m check-links: bootstrap.sh wires this repo and is idempotent\n'
fi
exit "$rc"
EOF
((DRY)) || chmod +x "$TARGET/test/check-links.sh" 2>/dev/null

# The floor's second rung: the suite is RUN from a workflow, not merely present. `make
# test` is the step, so "passes locally" and "passes CI" are one command.
w "$TARGET/.github/workflows/test.yml" <<'EOF'
name: test

# Generated by dotfiles-core/scripts/new-os-repo.sh. Runs this repo's own suite, which is
# the fleet's test floor (core/VENDORING.md § "The `make` vocabulary, and the test floor"):
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
the fleet's Makefile vocabulary (\`core/VENDORING.md\` § "The \`make\` vocabulary, and the
test floor"); keep those names and add your own beside them. \`make test\` runs \`test/\`,
which \`.github/workflows/test.yml\` also runs on every push. \`packages-check\` is a stub
until this repo has an \`install/packages.txt\`.

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
  cat <<EOF
  next:
    cd "$TARGET"
    git add -A && git commit -m "scaffold dotfiles-$OS"
    ./bootstrap.sh            # wire the symlinks
    make test                 # the repo's own suite (the fleet's test floor)
    \$EDITOR os/$os_lc.zsh     # add your $OS-native bits

  THEN FIX THE CAPABILITY DECLARATION — it was scaffolded with FEDORA's verbs so the
  schema is satisfied from birth, and they are wrong for any other archive:
    \$EDITOR os/$os_lc.capabilities
    core/scripts/check-capabilities.sh os/$os_lc.capabilities

  then, back in dotfiles-core — REGISTER IT, or the fleet never sees this repo:
    echo dotfiles-$OS >> scripts/os-repos.txt   # one line; keep the list sorted
    ./scripts/sync-core.sh dotfiles-$OS         # materializes core/ and stamps core.lock
EOF
fi
