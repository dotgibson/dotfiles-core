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
# WHAT THIS IS NOT: a byte-for-byte comparison against upstream. This is a REACHABILITY
# check — a module is reachable if some path through the load graph can require it.
#
# Four groups are reachable BY CONSTRUCTION and are exempt for stated reasons, not for
# convenience:
#
#   plugins/*      lazy.nvim imports the DIRECTORY (`{ import = "gerrrt.plugins" }` in
#                  config/lazy.lua), so every file there is loaded by construction.
#   health.lua     Neovim discovers lua/**/health.lua by runtimepath for :checkhealth.
#                  Zero require() references is CORRECT here, not orphaned.
#   init.lua       lua/gerrrt/init.lua is required by nvim/init.lua, the entry point.
#   servers/*      require()d DYNAMICALLY — servers/init.lua does
#                  `pcall(require, "gerrrt.servers." .. name)` over its `servers` list,
#                  so a static grep finds nothing and that registry is the only evidence
#                  there is. It is checked BOTH ways below.
#
# Everything else — utils/, config/, and any top-level lua/gerrrt/*.lua — must be
# require()d by name somewhere in the tree. That is precisely the surface with no other
# guard: luacheck lints the files it is handed and does no reachability analysis.
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
      sed -n '2,45p' "$0"
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

# The LSP registry, extracted once. FAIL CLOSED: if the block cannot be parsed (it was
# reformatted, renamed, or removed) every server module would look unlisted and this
# check would emit ~28 bogus findings. Worse, a future edit could make the range match
# nothing and the check would go quiet while appearing to pass. Say so once instead.
srv_listed=""
if [ -f "$srv_init" ]; then
  srv_listed="$(awk '/^local servers = \{/,/^\}/' "$srv_init" | grep -oE '"[a-z_0-9]+"' | tr -d '"' | sort -u)"
  if [ -z "$srv_listed" ]; then
    echo "could not parse the \`local servers = {…}\` registry in $srv_init"
    rc=1
  fi
fi

# Cache the file list once — the per-module grep below would otherwise re-run git for
# every module in the tree.
all_lua="$(git ls-files 'nvim/*.lua' 2>/dev/null)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#nvim/lua/gerrrt/}"
  case "$rel" in
    plugins/*) continue ;;             # lazy imports the directory wholesale
    health.lua | init.lua) continue ;; # checkhealth convention / entry point
    servers/init.lua) continue ;;      # required as "gerrrt.servers"
    servers/*)
      [ -n "$srv_listed" ] || continue # unparseable registry already reported
      name="${rel##*/}"
      name="${name%.lua}"
      if ! printf '%s\n' "$srv_listed" | grep -qx "$name"; then
        echo "orphaned LSP module — $f is in no \`servers\` registry entry (dead config)"
        rc=1
      fi
      continue
      ;;
  esac

  # Module name: utils/term.lua -> gerrrt.utils.term; config/init.lua -> gerrrt.config
  mod="gerrrt.$(printf '%s' "${rel%.lua}" | tr '/' '.')"
  mod="${mod%.init}"
  # Fixed-string search INCLUDING the quotes, so gerrrt.utils.lsp cannot be satisfied by
  # a longer name that merely starts with it. Both quote styles are accepted, and the
  # defining file is excluded so a self-reference in a comment cannot mask an orphan.
  if ! printf '%s\n' "$all_lua" | grep -vxF "$f" | tr '\n' '\0' |
    xargs -0 grep -lF -e "\"$mod\"" -e "'$mod'" >/dev/null 2>&1; then
    echo "orphaned module — nothing requires \"$mod\" ($f)"
    rc=1
  fi
done <<EOF
$(git ls-files 'nvim/lua/gerrrt/*.lua' 2>/dev/null)
EOF

# Reverse direction: a name in the registry with no module file is a RUNTIME error, not
# dead weight — servers/init.lua pcall-requires it and logs a load failure at startup.
if [ -n "$srv_listed" ]; then
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
