#!/usr/bin/env bash
# scripts/research/nonmutable-home-manager.sh — R3 of NON-MUTABLE-HOST-PROPOSAL.md
# (#1004): apply scripts/research/nonmutable/home.nix against an OS repo checkout, record
# what home-manager owns, then run the repo's bootstrap --links-only OVER it and record the
# fight — which files each side claims, what the driver backs up, what home-manager
# restores on its next switch. Adopt / coexist / reject is read off this report.
#
#   scripts/research/nonmutable-home-manager.sh <repo-dir> <os> [--out FILE] [--switch|--no-switch]
#
#   <repo-dir>   an OS repo checkout with core/ vendored (dotfiles-Fedora, or a scaffold)
#   <os>         the os/<os>.zsh basename (fedora, nixos, …)
#   --switch     run `home-manager switch -f home.nix` here (standalone home-manager on a
#                mutable host); --no-switch means the module was activated by NixOS
#                (home-manager.users.<name> in configuration.nix) and only the inventory
#                and the driver pass run. Default: --switch when `home-manager` is on PATH.
#
# Tolerant like nonmutable-host.sh: every step records its status; a failing step is the
# measurement.
set -uo pipefail

repo="${1:-}"; os="${2:-}"; shift 2 || true
out=""; do_switch=auto
while [[ $# -gt 0 ]]; do
  case "$1" in
  --out) out="$2"; shift 2 ;;
  --switch) do_switch=1; shift ;;
  --no-switch) do_switch=0; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$repo" && -n "$os" && -d "$repo" ]] || { echo "usage: $0 <repo-dir> <os> [--out FILE] [--switch|--no-switch]" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${out:-$HERE/research-out/home-manager-$os.md}"
mkdir -p "$(dirname "$out")" || exit 1
work="$(mktemp -d "${TMPDIR:-/tmp}/hm.XXXXXX")"
: >"$out"
say() { printf '%s\n' "$*" >>"$out"; }
h2() { say ""; say "## $*"; say ""; }
run() { # <label> <cmd…>
  local label="$1"; shift; local rc log; log="$(mktemp "$work/run.XXXXXX")"
  ("$@") >"$log" 2>&1; rc=$?
  say "**$label** — \`$*\` → exit **$rc**"; say ""; say '```text'
  if [[ "$(wc -c <"$log")" -gt 7000 ]]; then head -c 3500 "$log" >>"$out"; say ""; say "… (middle omitted) …"; say ""; tail -c 3500 "$log" >>"$out"; else cat "$log" >>"$out"; fi
  say '```'; return 0
}
cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
# inventory <label> — every entry under $HOME/.config/{zsh,tmux,nvim,…} and the entry
# files, with the link target classified: store (home-manager's own), out-of-store (a
# home-manager mkOutOfStoreSymlink or the driver's blib_link — same shape, so the target
# path says which), or a real file.
inventory() {
  say "### $1"; say ""; say '```text'
  local p t kind
  for p in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.gitconfig" "$cfg/zsh/.zshrc" "$cfg/zsh/.zprofile" "$cfg/zsh/loader.zsh" "$cfg/zsh/00-tools.zsh" "$cfg/zsh/80-os.zsh" "$cfg/zsh/os.capabilities" "$cfg/nvim" "$cfg/tmux/tmux.conf" "$cfg/tmux/plugins/tpm" "$cfg/starship.toml" "$cfg/mise/config.toml"; do
    if [[ -L "$p" ]]; then
      t="$(readlink "$p")"
      case "$t" in /nix/store/*) kind="store   " ;; *) kind="outstore" ;; esac
      printf '%-9s %-42s -> %s\n' "$kind" "${p/#$HOME/~}" "$t" >>"$out"
    elif [[ -e "$p" ]]; then
      printf '%-9s %-42s (real %s%s)\n' "real     " "${p/#$HOME/~}" "$([[ -d "$p" ]] && echo dir || echo file)" "$([[ -f "$p" ]] && grep -q 'dotfiles-managed v4' "$p" 2>/dev/null && echo ', Core managed loader' || true)" >>"$out"
    else
      printf '%-9s %-42s\n' "absent   " "${p/#$HOME/~}" >>"$out"
    fi
  done
  say '```'
}

say "# R3 — home-manager over $os ($(date -u +%Y-%m-%dT%H:%MZ))"; say ""
say "Repo \`$repo\`; Core \`$(cat "$repo/core/core.version" 2>/dev/null || echo '?')\`; \`home-manager\`: $(command -v home-manager 2>/dev/null || echo absent); \`nix\`: $(nix --version 2>/dev/null || echo absent); user $(id -un), HOME=$HOME."
[[ "$do_switch" == auto ]] && { command -v home-manager >/dev/null 2>&1 && do_switch=1 || do_switch=0; }

h2 "1. Before anything"
inventory "the home before home-manager"

h2 "2. home-manager"
if ((do_switch)); then
  export DOTFILES_REPO="$repo" DOTFILES_BUILD="$repo" DOTFILES_OS="$os"
  run "home-manager switch" home-manager switch -f "$HERE/scripts/research/nonmutable/home.nix" -b hm-backup
else
  say "Activated by the system configuration (NixOS \`home-manager.users.<name>\`); no switch here."
fi
inventory "after home-manager"
say "- home-manager backups (\`*.hm-backup\`): $(find "$HOME" -maxdepth 3 -name '*.hm-backup' 2>/dev/null | wc -l | tr -d ' ')"

h2 "3. The driver over home-manager's result"
say "\`bootstrap.sh --links-only\` against the SAME home: what does blib_link back up, relink, or leave?"
mkdir -p "$cfg/tmux/plugins/tpm" 2>/dev/null || true
( cd "$repo" && HOME="$HOME" XDG_CONFIG_HOME="$cfg" BLIB_SU='' ./bootstrap.sh --links-only ) >"$work/driver.out" 2>&1; drc=$?
say "**--links-only** → exit **$drc**"; say ""; say '```text'
grep -E 'backed up|relink|would|skip|already|linked|seeded|zshrc|zshenv|core-guard|complete|WITH' "$work/driver.out" | head -40 >>"$out"
say '```'
inventory "after the driver"
say "- driver backups (\`*.pre-dotfiles.*\`): $(find "$HOME" -maxdepth 3 -name '*.pre-dotfiles.*' 2>/dev/null | wc -l | tr -d ' ')"

if ((do_switch)); then
  h2 "4. home-manager again (does it take its files back?)"
  run "home-manager switch (second)" home-manager switch -f "$HERE/scripts/research/nonmutable/home.nix" -b hm-backup2
  inventory "after the second switch"
fi

h2 "5. Reading it"
say "Fill in by hand: for each contested path — \`~/.zshrc\`, \`~/.zshenv\`, \`\$ZDOTDIR/.zshrc\`, \`mise/config.toml\`, \`tmux/plugins/tpm\` — who owned it after each step, and whether the shell still boots the loader (\`zsh -ic 'typeset -f core-doctor >/dev/null && echo loader-ok'\`):"
say ""
say '```text'
zsh -ic 'typeset -f core-doctor >/dev/null 2>&1 && echo "loader-ok: core-doctor is defined" || echo "loader-NOT-ok: core-doctor undefined"' >>"$out" 2>&1 || true
say '```'
rm -rf "$work"
echo "report: $out"
