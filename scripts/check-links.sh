#!/usr/bin/env bash
# scripts/check-links.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does an OS/Role repo's bootstrap still wire the symlink graph Core's loader expects?
#
# Runs the caller's `bootstrap.sh --links-only` against a THROWAWAY HOME and asserts the
# result. This is the second half of every repo's `make check`; the first half is `lint`.
#
# WHY THIS IS A CORE SCRIPT AND NOT SIX MAKEFILE RECIPES, which is what it was. The block
# was copy-pasted into dotfiles-Fedora, -Debian, -Gentoo, -openSUSE, -Arch and the two Role
# repos, and it drifted exactly the way copies do: dotgibson/dotfiles-core#852 found the
# same defect in three of them at once — `HOME="$tmp"` alone is not hermetic, because
# bootstrap resolves `CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"` and lib/bootstrap-lib.sh
# defaults XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_CACHE_HOME / XDG_DATA_HOME and ZDOTDIR
# the same way. Those defaults apply ONLY when the variable is unset, so a developer who
# exports XDG_CONFIG_HOME got a "hermetic" gate that wrote Core into their real config tree
# and then failed its own assertions, which look under the temp dir bootstrap never
# touched. dotfiles-openSUSE had found and fixed it locally; three repos had not, and
# nothing could tell them. The fix then had to be applied by hand three more times.
#
# One definition, vendored, is the same argument scripts/check-capabilities.sh already
# makes for the capability schema: the fleet is gated by one file instead of N copies that
# agree until they do not.
#
# WHAT IS CORE'S TO ASSERT, AND WHAT IS NOT. The default set below is the graph
# blib_link_core wires in EVERY repo — the zsh module chain, the prompt, the editor, the
# multiplexer, git. Anything a particular repo adds on top is that repo's business and is
# passed in: `--require .config/zsh/80-os.zsh` for an OS repo's band-80 overlay,
# `--require .config/defense/templates` for a Role layer. Core asserting a Role path, or a
# Role repo re-asserting Core's, is how the copies drifted in the first place.
#
# THE THROWAWAY HOME IS THE WHOLE SAFETY PROPERTY, so it is guarded rather than assumed:
# an unguarded `tmp=$(mktemp -d)` leaves $tmp empty on failure, and the next line
# (`mkdir -p "$tmp/.config/..."`) then writes to /.config on the real filesystem. A trap
# removes it on every exit path, interrupts included.
#
# Exit codes — the three outcomes are genuinely different and a caller may want to tell
# them apart:
#   0  the graph is what Core expects
#   1  the check could not RUN (usage, no bootstrap script, mktemp failed, or bootstrap
#      itself exited non-zero — its output is printed)
#   2  bootstrap ran and the graph is WRONG — the drift signal
#
# Usage:
#   core/scripts/check-links.sh
#   core/scripts/check-links.sh --require .config/zsh/80-os.zsh
#   core/scripts/check-links.sh --require .config/tmux/role.conf --require .config/offensive/templates
#
#   --repo DIR        repo root to run in            (default: the current directory)
#   --bootstrap PATH  installer, relative to --repo  (default: ./bootstrap.sh)
#   --require PATH    an extra path that must be a SYMLINK, relative to the throwaway
#                     HOME. Repeatable.
#   --seed PATH       an extra path that must be a regular FILE and NOT a symlink — a
#                     seeded config the user is meant to edit. Repeatable.
#   --keep            do not delete the throwaway HOME; print where it is (debugging)
#
# The environment reaches bootstrap unchanged apart from HOME and the five scrubbed
# variables, so a caller that needs one — `BLIB_SU=true` on a container without sudo, say
# — simply exports it: `BLIB_SU=true core/scripts/check-links.sh`.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# Colour comes from Core's own palette when it is reachable (it is, in a vendored core/ and
# in this repo), and degrades to plain prefixes when it is not — this script must run from a
# checkout that has been pared down, and a missing UX file is not a reason to fail a gate.
_cl_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "$_cl_here/../lib/ux.sh" ]]; then
  # shellcheck source=lib/ux.sh
  source "$_cl_here/../lib/ux.sh"
fi
say() { printf '%s::%s %s\n' "${UX_BLU:-}" "${UX_RST:-}" "$*"; }
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
bad() { printf '%s%s%s %s\n' "${UX_YEL:-}" "${UX_WARN:-!}" "${UX_RST:-}" "$*" >&2; }

REPO="."
BOOTSTRAP="./bootstrap.sh"
KEEP=0
REQUIRE=()
SEED=()

# An option that takes a value is checked for one BEFORE the assignment: `--require` as the
# last word would otherwise append an empty path and then assert on "$tmp/", which is a
# directory and always exists — a silently weakened gate rather than a usage error.
_cl_needval() { (($1 >= 2)) || {
  bad "$2 needs a value"
  exit 1
}; }
while (($#)); do
  case "$1" in
  --repo)
    _cl_needval $# --repo
    REPO="$2"
    shift 2
    ;;
  --bootstrap)
    _cl_needval $# --bootstrap
    BOOTSTRAP="$2"
    shift 2
    ;;
  --require)
    _cl_needval $# --require
    REQUIRE+=("$2")
    shift 2
    ;;
  --seed)
    _cl_needval $# --seed
    SEED+=("$2")
    shift 2
    ;;
  --keep)
    KEEP=1
    shift
    ;;
  -h | --help)
    sed -n '2,62p' "${BASH_SOURCE[0]:-$0}"
    exit 0
    ;;
  *)
    bad "unknown argument: $1"
    exit 1
    ;;
  esac
done

# `set -e` is deliberately off (the exit code IS the result), so the cd is guarded by hand:
# continuing in the wrong directory would run some other repo's bootstrap.
cd -- "$REPO" || {
  bad "not a directory: $REPO"
  exit 1
}
[[ -f "$BOOTSTRAP" ]] || {
  bad "no installer at $BOOTSTRAP (run this from an OS or Role repo, or pass --repo)"
  exit 1
}

# ── the throwaway HOME ────────────────────────────────────────────────────────
tmp="$(mktemp -d)" || {
  bad "mktemp -d failed — refusing to run bootstrap without a throwaway HOME"
  exit 1
}
[[ -n "$tmp" ]] || {
  bad "mktemp -d printed nothing — same refusal"
  exit 1
}
# shellcheck disable=SC2329  # invoked by the trap below, which shellcheck cannot see
_cl_cleanup() { ((KEEP)) || rm -rf "$tmp"; }
trap _cl_cleanup EXIT INT TERM

# blib_link_core clones the tmux plugin manager into this directory on a first run. Creating
# it up front keeps the check about symlinks rather than about network reachability.
mkdir -p "$tmp/.config/tmux/plugins/tpm"

say "bootstrap --links-only into $tmp"
# THE SCRUB. Five variables, because that is what the bootstrap path consults: bootstrap.sh
# itself reads XDG_CONFIG_HOME, and lib/bootstrap-lib.sh defaults the other four — ZDOTDIR
# from XDG_CONFIG_HOME, so leaving it set redirects the managed .zshrc on its own. `env -u`
# removes them for this one command and leaves the rest of the environment alone.
if ! env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME -u ZDOTDIR \
  HOME="$tmp" "$BOOTSTRAP" --links-only >"$tmp/.bootstrap.log" 2>&1; then
  bad "$BOOTSTRAP --links-only failed — its output follows"
  sed 's/^/    /' "$tmp/.bootstrap.log" >&2
  exit 1
fi

# ── the graph ─────────────────────────────────────────────────────────────────
# What blib_link_core wires in every repo that vendors Core. A repo's own additions arrive
# through --require / --seed; see the header.
LINKS=(
  .config/zsh/loader.zsh     # the module chain's entry point
  .config/starship.toml      # prompt, at the default path 00-tools.zsh inits against
  .config/lazygit/config.yml # git TUI
  .config/nvim               # the editor tree, linked as a DIRECTORY
  .config/tmux/tmux.conf     # multiplexer
  .vimrc                     # the stock-vim fallback, for boxes without nvim
  .gitconfig                 # git, including the Core include chain
)
SEEDS=(
  .config/sesh/sesh.toml # seeded as a COPY: yours to edit, not tracked from here
)
((${#REQUIRE[@]})) && LINKS+=("${REQUIRE[@]}")
((${#SEED[@]})) && SEEDS+=("${SEED[@]}")

rc=0
for l in "${LINKS[@]}"; do
  [[ -L "$tmp/$l" ]] || {
    bad "MISSING symlink: $l"
    rc=2
  }
done

# A symlink can exist and point at nothing — the shape this catches is a Core file renamed
# upstream while the OS repo's link name stayed put.
[[ -e "$tmp/.config/zsh/loader.zsh" ]] || {
  bad "loader.zsh is a dangling symlink"
  rc=2
}

for s in "${SEEDS[@]}"; do
  if [[ -L "$tmp/$s" ]]; then
    bad "$s must be a COPY, not a symlink — it is the user's to edit"
    rc=2
  elif [[ ! -f "$tmp/$s" ]]; then
    bad "$s was not seeded"
    rc=2
  fi
done

# THE MANAGED ENTRY FILE, in the throwaway HOME — never the caller's own. `source
# .*loader\.zsh` with the dot escaped and anchored past any comment: the unescaped,
# unanchored form this replaces matched a COMMENTED-OUT source line and `loaderXzsh`
# besides, so an entry file that sources nothing passed the gate.
if ! grep -q "dotfiles-managed v4" "$tmp/.zshrc" 2>/dev/null; then
  bad "the throwaway .zshrc is not the managed file"
  rc=2
fi
if ! grep -qE '^[^#]*source .*loader\.zsh' "$tmp/.zshrc" 2>/dev/null; then
  bad "the throwaway .zshrc does not source the loader"
  rc=2
fi

((KEEP)) && say "kept the throwaway HOME at $tmp"

if ((rc == 0)); then
  ok "symlink graph OK (${#LINKS[@]} links, ${#SEEDS[@]} seeded)"
else
  bad "the symlink graph is not what Core's loader expects — see above"
fi
exit "$rc"
