#!/usr/bin/env bash
# scripts/nvim-reachability.sh
# ──────────────────────────────────────────────────────────────────────────────
# THE nvim ORPHAN BACKSTOP — is every lua module under nvim/ actually loadable?
#
# core.manifest lists `nvim/` as a DIRECTORY, not per-file, because the vendored
# lazy.nvim tree legitimately churns wholesale as plugins and servers come and go, so
# per-file listing would be maintenance noise. The cost of that choice is that the
# audit's §1 manifest⇄filesystem drift check cannot see an orphan here: any new path
# under nvim/ is auto-"listed", so a lua module that nothing loads sits in the tree
# indefinitely, gets vendored into all eight OS repos, and no gate says a word.
#
# core.manifest said that gap was "covered by verify-core.sh instead". That script has
# never existed in this repo (dotgibson/dotfiles-core#454) — so the backstop the comment
# promised was nothing at all. This is it.
#
# HOW IT WORKS — a real graph traversal, not an "is this name mentioned anywhere" scan.
# The distinction matters: a mention-scan passes two dead modules that require EACH OTHER
# (a disconnected cycle), and passes a module named only in some other file's comment.
# Both are exactly the orphan this exists to catch. So:
#
#   1. Inventory every module under nvim/lua/gerrrt (dir/init.lua ⇒ `gerrrt.dir`).
#   2. Strip lua comments, then read each file's edges — any quoted `gerrrt.*` string,
#      which covers `require("gerrrt.x")` and lazy's `{ import = "gerrrt.plugins" }`.
#   3. Walk outward from the ROOTS and flag every module never visited.
#
# The roots, and why each is a root rather than an exemption:
#
#   nvim/init.lua   the entry point Neovim loads; everything real hangs off it.
#   gerrrt.health   Neovim discovers lua/**/health.lua by runtimepath for :checkhealth.
#                   Nothing requires it and nothing should — it is genuinely a second
#                   entry point, so it is a ROOT, not a special case.
#
# Two edges cannot be read literally from the source and are resolved during the walk:
#
#   directory import   `{ import = "gerrrt.plugins" }` names a DIRECTORY, not a module.
#                      A target with no file of its own but with `target.*` children
#                      expands to all of them — which is what lazy.nvim does.
#   dynamic require    servers/init.lua does `pcall(require, "gerrrt.servers." .. name)`
#                      over its `servers` list, so the literal string is a dead end.
#                      Visiting `gerrrt.servers` expands to the listed names — that
#                      registry is the only static evidence those modules are wanted.
#
# The registry is ALSO checked both ways, because a generic "unreachable" is a worse
# message than the truth: a module in no list entry is dead config, and a list entry with
# no module file is a runtime load error servers/init.lua reports at startup. Both a
# missing and an unparseable registry FAIL CLOSED — silently skipping the registry check
# would disable the whole servers/ arm, which is precisely how this class of gap starts.
#
# Output contract: one finding per line on stdout, no colour, no decoration — the caller
# (audit-core.sh §4b) turns each line into a `fail`. Silence means clean.
# Exit: 0 = clean, 1 = findings, 2 = usage / cannot run.
#
# bash 3.2 safe (macos-latest runs the 2007 bash): no mapfile, no associative arrays.
#
# Usage:
#   ./scripts/nvim-reachability.sh            # check this repo
#   ./scripts/nvim-reachability.sh --root DIR # check a repo elsewhere (tests use this)
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="."
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || {
        echo "--root needs a directory" >&2
        exit 2
      }
      ROOT="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,55p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT" 2>/dev/null || {
  echo "not a directory: $ROOT" >&2
  exit 2
}
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not a git work tree: $ROOT" >&2
  exit 2
}
[ -d nvim/lua/gerrrt ] || exit 0 # nothing to check (an OS repo, or nvim not vendored)

rc=0
srv_init=nvim/lua/gerrrt/servers/init.lua

# ── inventory: "<module>\t<file>", one per line ───────────────────────────────
mods="$(git ls-files 'nvim/lua/gerrrt/*.lua' 2>/dev/null | while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#nvim/lua/gerrrt/}"
  m="gerrrt.$(printf '%s' "${rel%.lua}" | tr '/' '.')"
  printf '%s\t%s\n' "${m%.init}" "$f" # dir/init.lua is required as `gerrrt.dir`
done)"
[ -n "$mods" ] || exit 0

_file_for() { printf '%s\n' "$mods" | awk -F'\t' -v m="$1" '$1 == m { print $2; exit }'; }
_children_of() { printf '%s\n' "$mods" | awk -F'\t' -v p="$1." 'index($1, p) == 1 { print $1 }'; }

# Edges out of one file: every quoted `gerrrt.*` string in CODE. Comments are stripped
# first so a module named in prose cannot fake an edge — the mention-scan bug above.
# A trailing dot (the `"gerrrt.servers." .. name` concatenation) is dropped; that edge is
# resolved from the registry instead.
_edges_of() {
  [ -f "$1" ] || return 0
  sed -e 's/--\[\[.*\]\]//g' -e 's/--.*$//' "$1" |
    grep -oE '["'"'"']gerrrt[A-Za-z0-9_.-]*["'"'"']' |
    tr -d '"'"'"'' | sed -e 's/\.$//' | sort -u
}

# ── the LSP registry (also the dynamic edge out of `gerrrt.servers`) ──────────
# Fail closed on BOTH failure modes. A missing servers/init.lua used to skip the whole
# registry arm silently, so deleting it disabled the check instead of failing.
srv_listed=""
if [ -f "$srv_init" ]; then
  srv_listed="$(awk '/^local servers = \{/,/^\}/' "$srv_init" | grep -oE '"[a-z_0-9]+"' | tr -d '"' | sort -u)"
  if [ -z "$srv_listed" ]; then
    echo "could not parse the \`local servers = {…}\` registry in $srv_init"
    rc=1
  fi
elif [ -n "$(_children_of gerrrt.servers)" ]; then
  echo "missing $srv_init, but servers/ modules exist — the registry check cannot run"
  rc=1
fi

# ── walk the graph from the roots ─────────────────────────────────────────────
# Roots: whatever nvim/init.lua pulls in, plus gerrrt.health (runtimepath-discovered by
# :checkhealth — a genuine second entry point, not an exemption).
queue="$(_edges_of nvim/init.lua)
gerrrt.health"
visited=""

while [ -n "$queue" ]; do
  m="${queue%%
*}"
  if [ "$m" = "$queue" ]; then queue=""; else queue="${queue#*
}"; fi
  [ -n "$m" ] || continue
  printf '%s\n' "$visited" | grep -qxF "$m" && continue
  visited="$visited
$m"

  f="$(_file_for "$m")"
  if [ -z "$f" ]; then
    # No module file: a DIRECTORY import (lazy's `{ import = "gerrrt.plugins" }`).
    # Expand to its children; a name with neither a file nor children is a dangling
    # require, which lua would raise at runtime — reported below.
    kids="$(_children_of "$m")"
    if [ -n "$kids" ]; then
      queue="$queue
$kids"
    fi
    continue
  fi

  queue="$queue
$(_edges_of "$f")"

  # The dynamic arm: `gerrrt.servers` require()s each listed name at runtime.
  if [ "$m" = gerrrt.servers ] && [ -n "$srv_listed" ]; then
    queue="$queue
$(printf '%s\n' "$srv_listed" | sed 's/^/gerrrt.servers./')"
  fi
done

# ── report ───────────────────────────────────────────────────────────────────
# servers/* are reported by the registry check below instead: "in no registry entry" is
# a truer diagnosis than "unreachable" for a module the walk could only reach via a list.
while IFS="$(printf '\t')" read -r m f; do
  [ -n "$m" ] || continue
  case "$m" in gerrrt.servers.*) continue ;; esac
  printf '%s\n' "$visited" | grep -qxF "$m" && continue
  echo "orphaned module — nothing reaches \"$m\" from nvim/init.lua ($f)"
  rc=1
done <<EOF
$mods
EOF

if [ -n "$srv_listed" ]; then
  # a module file in no registry entry is dead config …
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    name="${m#gerrrt.servers.}"
    if ! printf '%s\n' "$srv_listed" | grep -qx "$name"; then
      echo "orphaned LSP module — nvim/lua/gerrrt/servers/$name.lua is in no \`servers\` registry entry (dead config)"
      rc=1
    fi
  done <<EOF
$(_children_of gerrrt.servers)
EOF
  # … and a registry entry with no module file is a runtime load error.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -f "nvim/lua/gerrrt/servers/$name.lua" ]; then
      echo "\`servers\` lists \"$name\" but nvim/lua/gerrrt/servers/$name.lua does not exist"
      rc=1
    fi
  done <<EOF
$srv_listed
EOF
fi

exit $rc
