#!/usr/bin/env bash
# scripts/research/nonmutable-r6.sh — R6 of NON-MUTABLE-HOST-PROPOSAL.md (#1004): what CI
# can hold. Inside the CONTAINER image a target repo would name in its bootstrap-test.yml
# caller, run each reusable leg's recipe — the same shell bootstrap-test.yml runs — against
# the sibling with the R4 variant applied, and record what passes, what the stubs
# intercepted, and what a container can never reach:
#
#   lint            bash -n + --help (the reusable `lint` job's core)
#   links-only      ./bootstrap.sh --links-only + the reusable job's symlink assertions
#   provision-stub  the FULL bootstrap with the reusable job's shim set on PATH — in a
#                   container the variant's host marker is absent, so this walks the
#                   MUTABLE path; recorded as such
#   provision-stub, forced   the same, with BOOTSTRAP_PROVISIONER=<atomic|transactional>
#                   and rpm-ostree / bootc / transactional-update / snapper shimmed — does
#                   the STAGING path run to its closing line under a stub?
#   packages_check  the reusable resolver loop with the caller's RESOLVE verb (--resolve)
#
#   nonmutable-r6.sh <bootc|microos|nixos> --repo-dir DIR [--patch FILE] [--resolve CMD] [--out FILE]
set -u
target="${1:?bootc|microos|nixos}"; shift
repo_dir="" patch="" resolve="" out=""
while (($#)); do
  case "$1" in
  --repo-dir) repo_dir="$2"; shift 2 ;;
  --patch) patch="$2"; shift 2 ;;
  --resolve) resolve="$2"; shift 2 ;;
  --out) out="$2"; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -d "$repo_dir" ]] || { echo "usage: $0 <target> --repo-dir DIR [--patch FILE] [--resolve CMD] [--out FILE]" >&2; exit 2; }
[[ -n "$out" ]] || out="/tmp/r6-$target.md"
work="$(mktemp -d /tmp/r6.XXXXXX)"
: >"$out"
say() { printf '%s\n' "$*" >>"$out"; }
h2() { say ""; say "## $*"; say ""; }
excerpt() { local f="$1" n="${2:-15}" l; l=$(wc -l <"$f" | tr -d ' '); say '```text'; if ((l > 2 * n)); then head -n "$n" "$f" >>"$out"; say "… ($((l - 2 * n)) lines omitted) …"; tail -n "$n" "$f" >>"$out"; else cat "$f" >>"$out"; fi; say '```'; }
leg() { # <name> <rc> <verdict-text>
  say "| $1 | **$2** | $3 |"
}

say "# R6 — what CI can hold: $target in a container ($(date -u +%Y-%m-%dT%H:%MZ))"; say ""
say "Image: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'); uid $(id -u); repo \`$repo_dir\` @ $(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo scaffold); markers: /run/ostree-booted $( [[ -e /run/ostree-booted ]] && echo present || echo absent ), transactional-update $(command -v transactional-update >/dev/null 2>&1 && echo present || echo absent), /usr $( [[ -w /usr ]] && echo writable || echo read-only )."
if [[ -n "$patch" && -f "$patch" ]]; then
  if git -C "$repo_dir" apply --check "$patch" 2>/dev/null; then git -C "$repo_dir" apply "$patch" && say "- R4 variant patch applied."; else say "- R4 variant patch: already applied or does not apply."; fi
fi
say ""; say "| leg | exit | what happened |"; say "| --- | --- | --- |"
cd "$repo_dir" || exit 1

# ── lint ────────────────────────────────────────────────────────────────────
l="$work/lint.log"; { bash -n bootstrap.sh && ./bootstrap.sh --help; } >"$l" 2>&1; rc=$?
leg "lint (bash -n, --help)" "$rc" "$( ((rc == 0)) && echo "parses; --help prints $(wc -l <"$l" | tr -d ' ') lines" || echo "FAILED: $(head -1 "$l")")"

# ── links-only ──────────────────────────────────────────────────────────────
h1="$work/home-links"; mkdir -p "$h1/.config/tmux/plugins/tpm"
l="$work/links.log"; env HOME="$h1" XDG_CONFIG_HOME="$h1/.config" BLIB_SU= ./bootstrap.sh --links-only >"$l" 2>&1; rc=$?
miss=""
for link in "$h1/.config/zsh/loader.zsh" "$h1/.gitconfig" "$h1/.config/zsh/00-tools.zsh"; do [[ -L "$link" ]] || miss="$miss ${link#"$h1"/}"; done
ls os/*.zsh >/dev/null 2>&1 && { [[ -L "$h1/.config/zsh/80-os.zsh" ]] || miss="$miss 80-os.zsh"; }
[[ -e "$h1/.config/zsh/loader.zsh" ]] || miss="$miss loader-dangling"
grep -q 'dotfiles-managed v4' "$h1/.zshrc" 2>/dev/null || miss="$miss zshrc-unmanaged"
[[ -f core/mise/config.toml ]] && { [[ -f "$h1/.config/mise/config.toml" && ! -L "$h1/.config/mise/config.toml" ]] || miss="$miss mise-not-adopted"; }
leg "links-only + the reusable job's assertions" "$rc" "$( ((rc == 0)) && [[ -z "$miss" ]] && echo "pass — $(grep -o '[0-9]* linked' "$l" | tail -1), assertions hold" || echo "FAILED —${miss:- see log}")"

# packages_check runs BEFORE the stubbed legs: under the forced atomic path the variant
# writes a COPR repo file through the reusable curl shim, which drops the literal word
# "shim" into any -o path — /etc/yum.repos.d then holds a malformed file and every later
# dnf call fails with "Error in configuration file" (measured, run 34938554648). The
# reusable job never notices because nothing runs dnf after its stubbed bootstrap.
# ── packages_check ──────────────────────────────────────────────────────────
resolve_all() { # the reusable resolver loop, as bootstrap-test.yml runs it
  local -a pkgs=()
  local p n=0 unresolved=""
  # shellcheck disable=SC1091
  . core/lib/bootstrap-lib.sh
  blib_read_pkgs_into pkgs install/packages.txt || return 1
  echo ":: resolving ${#pkgs[@]} names with: $resolve"
  local first_out=""
  for p in "${pkgs[@]}"; do
    n=$((n + 1))
    if ! out="$($resolve "$p" 2>&1)"; then
      echo "  UNRESOLVED: $p"; unresolved="$unresolved $p"
      [[ -n "$first_out" ]] || first_out="$(printf '%s' "$out" | tail -n 6)"
    fi
  done
  echo ":: $n asked, $(echo "$unresolved" | wc -w | tr -d ' ') unresolved:$unresolved"
  if [[ -n "$unresolved" ]]; then
    # the reusable job prints the tail of the failing output; so do we, plus the
    # resolver's version and the two neighbouring verbs, for the first miss
    local p1; read -r p1 _ <<<"${unresolved# }"
    echo ":: first miss ($p1), tail of its output:"; printf '%s\n' "$first_out" | sed 's/^/      | /'
    echo ":: resolver version: $($(printf '%s' "$resolve" | cut -d' ' -f1) --version 2>&1 | head -1)"
    case "$resolve" in
    dnf*) echo ":: dnf repoquery $p1 → exit $(dnf -q repoquery "$p1" >/dev/null 2>&1; echo $?); dnf repoquery --whatprovides $p1 → exit $(dnf -q repoquery --whatprovides "$p1" >/dev/null 2>&1; echo $?); dnf provides $p1 (no -q) → exit $(dnf provides "$p1" >/dev/null 2>&1; echo $?)" ;;
    esac
  fi
  [[ -z "$unresolved" ]]
}
if [[ -n "$resolve" ]]; then
  l="$work/resolve.log"; t0=$(date +%s)
  # A Fedora caller's prep (`dnf install -y -q bash zsh`) fills dnf's metadata cache before
  # the resolver runs; this image's prep may not have touched dnf, and `dnf -q provides`
  # then fails every name in a second (measured, run 34933037546). Do what the prep does.
  case "$resolve" in dnf*) dnf -q makecache >/dev/null 2>&1 || true ;; esac
  resolve_all >"$l" 2>&1; rc=$?
  leg "packages_check (\`$resolve\`)" "$rc" "$(tail -1 "$l" | cut -c1-140) — $(( $(date +%s) - t0 )) s"
else
  leg "packages_check" "-" "no --resolve given for this target (the repo does not exist yet, or the archive has no per-name resolver)"
fi


# ── the reusable provision-stub shim set, verbatim in spirit ────────────────
# shellcheck disable=SC2016  # the shim bodies are written to files; they expand when run
mkshims() { # <dir> <log> [extra cmds…]
  local d="$1" log="$2"; shift 2
  mkdir -p "$d"; : >"$log"
  for c in curl wget gpg gpg2; do
    printf '#!/bin/sh\necho "%s $*" >>%s\nout=\nwhile [ $# -gt 0 ]; do case $1 in -o|--output) out=$2; shift 2 ;; --output=*) out=${1#--output=}; shift ;; *) shift ;; esac; done\n[ -n "$out" ] && { mkdir -p "$(dirname "$out")" 2>/dev/null; printf shim >"$out" 2>/dev/null; }\nexit 0\n' "$c" "$log" >"$d/$c"
  done
  for c in apt-get apt apt-key add-apt-repository dpkg debconf-set-selections dnf yum rpm pacman paru yay zypper apk emerge eselect layman brew snap flatpak gpgconf systemctl update-alternatives unattended-upgrade pipx go cargo npm "$@"; do
    printf '#!/bin/sh\necho "%s $*" >>%s\nexit 0\n' "$c" "$log" >"$d/$c"
  done
  for c in sudo doas; do
    printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -n|-E|-H|-k) shift ;; -u) shift 2 ;; --) shift; break ;; *) break ;; esac; done\n[ $# -eq 0 ] && exit 0\nexec "$@"\n' >"$d/$c"
  done
  chmod +x "$d"/*
}
stubbed() { # <label> <force-provisioner|""> [extra shims…] — full bootstrap under the shims
  local label="$1" force="$2"; shift 2
  local h="$work/home-$RANDOM" d="$work/shim-$RANDOM" log l rc
  mkdir -p "$h/.config/tmux/plugins/tpm"; log="$d.log"; l="$work/run-$RANDOM.log"
  mkshims "$d" "$log" "$@"
  env HOME="$h" XDG_CONFIG_HOME="$h/.config" BLIB_SU= PATH="$d:$PATH" ${force:+BOOTSTRAP_PROVISIONER="$force"} ./bootstrap.sh >"$l" 2>&1; rc=$?
  local links="" ; for link in "$h/.config/zsh/loader.zsh" "$h/.gitconfig"; do [[ -L "$link" ]] || links="$links ${link#"$h"/}"; done
  local verbs; verbs="$(cut -d' ' -f1 "$log" | sort | uniq -c | sort -rn | head -6 | awk '{printf "%s×%s ", $2, $1}')"
  local staged; staged="$(grep -E 'reboot to apply|layered into|transacted into|would rpm-ostree|would transactional' "$l" | head -2 | tr '\n' ' ' | cut -c1-160)"
  leg "$label" "$rc" "links $( [[ -z "$links" ]] && echo ok || echo "MISSING$links"); intercepted: ${verbs:-nothing}; staging line: ${staged:-none}"
  say ""; say "<details><summary>$label — what the shims intercepted (head)</summary>"; say ""; excerpt "$log" 12; say ""; say "</details>"; say ""
  say "| leg | exit | what happened |"; say "| --- | --- | --- |"
}
stubbed "provision-stub (the reusable job's shims; marker absent → mutable path)" ""
case "$target" in
bootc)   stubbed "provision-stub, BOOTSTRAP_PROVISIONER=atomic (+ rpm-ostree, bootc shims)" atomic rpm-ostree bootc ;;
microos) stubbed "provision-stub, BOOTSTRAP_PROVISIONER=transactional (+ transactional-update, snapper shims)" transactional transactional-update snapper btrfs ;;
nixos)   stubbed "provision-stub (+ nix-env, nix-channel, nixos-rebuild shims)" "" nix-env nix-channel nixos-rebuild nix ;;
esac

h2 "Reading it"
say "Per leg: green in a container, green only with a forced provisioner + shims, or VM-only. The R1 rung-one reports already hold the UNSTUBBED container run for each image (the package manager works in the image-build context — that is the mutable path, not the host's)."
rm -rf "$work"
echo "report: $out"
