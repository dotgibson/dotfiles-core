#!/usr/bin/env bash
# scripts/research/nonmutable-r5.sh — R5 of NON-MUTABLE-HOST-PROPOSAL.md (#1004):
# `up` and the maint runner on a staged host. Two questions, measured on the booted guest:
#
#   AVAILABLE — is a newer image / snapshot / channel upstream? (the once-a-day nudge's
#               question today: PKG_COUNT_PENDING, PKG_PENDING_*)
#   STAGED    — is a change already staged, waiting for PKG_APPLY (a reboot)? (the
#               question a mutable host never had to ask)
#
# For each: the verb, who may run it (this user vs root), its exit status, the shape of
# its output, and its cost in seconds. Then something small is staged for real and the
# STAGED verbs are asked again. Finally Core's own consumers are run against the variant
# declaration (the R4 patch applied to a clone of the sibling): what `_pkgup_count` says,
# what the nudge would print, what `up -n` would list — before and after staging.
#
#   nonmutable-r5.sh <bootc|microos|nixos> [--out FILE] [--repo-dir DIR] [--patch FILE] [--user NAME]
#
# --user NAME: when running as root, ask the "as this user" questions as NAME (runuser).
# When running unprivileged, the root questions go through `sudo -n`.
# Output is captured to files and excerpted — never piped through head (SIGPIPE fakes exits).
set -u

target="${1:?bootc|microos|nixos}"; shift
out="" repo_dir="" patch="" asuser=""
while (($#)); do
  case "$1" in
  --out) out="$2"; shift 2 ;;
  --repo-dir) repo_dir="$2"; shift 2 ;;
  --patch) patch="$2"; shift 2 ;;
  --user) asuser="$2"; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$out" ]] || out="/tmp/r5-$target.md"
work="$(mktemp -d /tmp/r5.XXXXXX)"
: >"$out"

say() { printf '%s\n' "$*" >>"$out"; }
h2() { say ""; say "## $*"; say ""; }
h3() { say ""; say "### $*"; say ""; }
now_ms() { date +%s%3N 2>/dev/null || echo 0; }
excerpt() { # <file> [n]
  local f="$1" n="${2:-12}" lines
  lines=$(wc -l <"$f" | tr -d ' ')
  say '```text'
  if ((lines > 2 * n)); then
    head -n "$n" "$f" >>"$out"; say "… ($((lines - 2 * n)) lines omitted) …"; tail -n "$n" "$f" >>"$out"
  else
    cat "$f" >>"$out"
  fi
  say '```'
}
# who: me | root — how to run the command from where this script stands
_as() { # <who> <cmd…>
  local who="$1"; shift
  case "$who" in
  root) if ((EUID == 0)); then "$@"; else sudo -n "$@"; fi ;;
  me) if ((EUID == 0)) && [[ -n "$asuser" ]]; then runuser -u "$asuser" -- "$@"; else "$@"; fi ;;
  esac
}
who_label() { case "$1" in root) echo "root" ;; me) if ((EUID == 0)) && [[ -n "$asuser" ]]; then echo "user $asuser"; elif ((EUID == 0)); then echo "root (no --user)"; else echo "user $(id -un)"; fi ;; esac; }
# measure <who> <label> <cmd…> — a table row: who | exit | seconds | first line of output | lines
measure() {
  local who="$1" label="$2"; shift 2
  local log; log="$(mktemp "$work/m.XXXXXX")"
  local t0 t1 rc; t0=$(now_ms)
  _as "$who" "$@" >"$log" 2>&1 </dev/null; rc=$?
  t1=$(now_ms)
  local first lines; first="$(head -n1 "$log" | cut -c1-110 | tr '|' '/')"; lines=$(wc -l <"$log" | tr -d ' ')
  say "| $label | \`$*\` | $(who_label "$who") | **$rc** | $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1000}') s | $lines | \`${first:-<none>}\` |"
}
table_head() { say "| what | verb | as | exit | cost | lines | first line |"; say "| --- | --- | --- | --- | --- | --- | --- |"; }
run() { # <who> <label> <cmd…> — full excerpt
  local who="$1" label="$2"; shift 2
  local log; log="$(mktemp "$work/r.XXXXXX")"
  local t0 t1 rc; t0=$(now_ms)
  _as "$who" "$@" >"$log" 2>&1 </dev/null; rc=$?
  t1=$(now_ms)
  say "**$label** — \`$*\` as $(who_label "$who") → exit **$rc** ($(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1000}') s)"; say ""
  excerpt "$log"
  return "$rc"
}

say "# R5 — \`up\` and the maint runner on a staged host: $target ($(date -u +%Y-%m-%dT%H:%MZ))"; say ""
say "Guest: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'); running as uid $(id -u)$( [[ -n "$asuser" ]] && echo " with --user $asuser"); sudo -n: $(sudo -n true 2>/dev/null && echo works || echo no)."

# ── AVAILABLE ────────────────────────────────────────────────────────────────
h2 "1. AVAILABLE — is there something newer upstream? (the nudge's question)"
table_head
case "$target" in
bootc)
  measure me   "rpm-ostree upgrade --check (user)"                 rpm-ostree upgrade --check
  measure root "rpm-ostree upgrade --check (root)"                 rpm-ostree upgrade --check
  measure root "rpm-ostree upgrade --check --unchanged-exit-77"    rpm-ostree upgrade --check --unchanged-exit-77
  measure me   "bootc upgrade --check (user)"                      bootc upgrade --check
  measure root "bootc upgrade --check (root)"                      bootc upgrade --check
  measure root "bootc status --format json (bytes)"                sh -c 'bootc status --format json | wc -c'
  measure me   "dnf -q check-update (read-only metadata, user)"    dnf -q check-update
  measure root "rpm-ostree refresh-md"                             rpm-ostree refresh-md
  measure me   "rpm-ostree status (user)"                          rpm-ostree status
  ;;
microos)
  measure me   "zypper -q list-updates (user)"                     zypper -q --non-interactive list-updates
  measure root "zypper -q list-updates (root)"                     zypper -q --non-interactive list-updates
  measure me   "zypper --non-interactive dup --dry-run (user)"     zypper --non-interactive dup --dry-run
  measure root "zypper --non-interactive dup --dry-run (root)"     zypper --non-interactive dup --dry-run
  measure root "transactional-update --help | grep dry"            sh -c 'transactional-update --help 2>&1 | grep -i -E "dry|drop-if|check"'
  measure root "transactional-update -n --dry-run dup"             transactional-update -n --no-selfupdate --dry-run dup
  measure root "zypper refresh"                                    zypper --non-interactive refresh
  measure me   "rebootmgrctl status (user)"                        rebootmgrctl status
  ;;
nixos)
  measure me   "nix-channel --list (user)"                         nix-channel --list
  measure root "nix-channel --list (root)"                         nix-channel --list
  measure root "nixos-rebuild dry-build"                           nixos-rebuild dry-build
  measure me   "nix flake metadata nixpkgs/nixos-25.05 --json (bytes)" sh -c 'nix --extra-experimental-features "nix-command flakes" flake metadata github:NixOS/nixpkgs/nixos-25.05 --json 2>/dev/null | wc -c'
  measure root "nix-channel --update (cost)"                       nix-channel --update
  measure me   "nix-env -qa --installed (user profile)"            sh -c 'nix-env -q 2>&1 | wc -l'
  ;;
esac

# ── STAGED, before ───────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # the sh -c bodies expand on the guest, deliberately
staged_probes() { # <label>
  h3 "$1"
  table_head
  case "$target" in
  bootc)
    measure me   "rpm-ostree status --pending-exit-77 (user)"  rpm-ostree status --pending-exit-77
    measure me   "rpm-ostree status --json deployments (user)" sh -c 'rpm-ostree status --json | python3 -c "import json,sys; d=json.load(sys.stdin)[\"deployments\"]; print(len(d), \"deployments;\", \"staged\" if any(x.get(\"staged\") for x in d) else \"none staged\")"'
    measure root "bootc status (root)"                          sh -c 'bootc status 2>&1 | grep -E -i "staged|booted|image|version" | head -8'
    measure me   "test -e /run/ostree-booted"                   test -e /run/ostree-booted
    ;;
  microos)
    measure me   "test -e /run/reboot-needed (user)"            test -e /run/reboot-needed
    measure me   "btrfs subvolume get-default / (user)"         btrfs subvolume get-default /
    measure root "btrfs subvolume get-default / (root)"         btrfs subvolume get-default /
    measure me   "findmnt -no SOURCE / (booted snapshot, user)" findmnt -no SOURCE /
    measure me   "snapper list (user)"                          snapper --no-headers list
    measure root "snapper list (root; last 3)"                  sh -c 'snapper --no-headers list | tail -3'
    measure me   "rebootmgrctl is-active (user)"                rebootmgrctl is-active
    ;;
  nixos)
    measure me   "booted vs current kernel (user)"              sh -c 'b=$(readlink -f /run/booted-system/kernel); c=$(readlink -f /run/current-system/kernel); [ "$b" = "$c" ] && echo "same kernel: $b" || echo "DIFFER booted=$b current=$c"'
    measure me   "booted vs current system (user)"              sh -c 'b=$(readlink -f /run/booted-system); c=$(readlink -f /run/current-system); [ "$b" = "$c" ] && echo same || echo "DIFFER $b vs $c"'
    measure me   "nix profile list / generations (user)"        sh -c 'nix-env --list-generations 2>&1 | tail -2'
    ;;
  esac
}
h2 "2. STAGED — is a change waiting for PKG_APPLY?"
staged_probes "2a. Before staging anything"

h2 "3. Stage something small (as root), then ask again"
case "$target" in
bootc)   run root "rpm-ostree install --idempotent htop" rpm-ostree install --idempotent htop ;;
microos) run root "transactional-update -n --continue pkg in htop" transactional-update -n --no-selfupdate --continue pkg in htop ;;
nixos)   run root "nix-env -iA nixos.htop (imperative, user profile — no reboot semantics on NixOS)" nix-env -iA nixos.htop ;;
esac
staged_probes "3a. After staging"
case "$target" in
bootc)
  table_head
  measure root "rpm-ostree upgrade --check --unchanged-exit-77 (staged install present)" rpm-ostree upgrade --check --unchanged-exit-77
  measure root "bootc upgrade --check (staged install present)" bootc upgrade --check
  measure me   "dnf -q check-update (user)"                  dnf -q check-update
  ;;
microos)
  table_head
  measure me   "zypper -q list-updates (user, after)"         zypper -q --non-interactive list-updates
  measure root "transactional-update -n --continue --dry-run pkg in htop (again)" transactional-update -n --no-selfupdate --continue --dry-run pkg in htop
  ;;
esac

# ── Core's consumers, today, against the variant declaration ────────────────
h2 "4. What Core's consumers say TODAY against the variant declaration"
if [[ -n "$repo_dir" && -d "$repo_dir" ]]; then
  if [[ -n "$patch" && -f "$patch" ]]; then
    if git -C "$repo_dir" apply --check "$patch" 2>/dev/null; then git -C "$repo_dir" apply "$patch" && say "- R4 patch applied to \`$repo_dir\`"; else say "- R4 patch already applied (or does not apply) — using the tree as is"; fi
  fi
  decl=""
  for f in "$repo_dir"/os/*.atomic.capabilities "$repo_dir"/os/*.microos.capabilities "$repo_dir"/os/nixos.capabilities "$repo_dir"/os/*.capabilities; do
    [[ -f "$f" ]] && { decl="$f"; break; }
  done
  say "- declaration: \`$decl\`"; say ""
  say '```text'; grep -E '^(PROVISIONER|PKG_COUNT_PENDING|PKG_PENDING_|PKG_APPLY|PKG_UPGRADE|MAINT_UNATTENDED)' "$decl" >>"$out" 2>/dev/null; say '```'
  # shellcheck disable=SC2016  # the zsh -c body is the probe; it expands on the guest
  consumer() { # <label>
    local log; log="$(mktemp "$work/c.XXXXXX")"
    env HOME="$HOME" XDG_CACHE_HOME="$work/cache" XDG_STATE_HOME="$work/state" CORE_CAPABILITIES_FILE="$decl" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_WHATSNEW_NUDGE=0 \
      zsh -c '
        source "$1/core/zsh/02-capabilities.zsh" 2>/dev/null
        source "$1/core/zsh/60-update.zsh" 2>/dev/null
        echo "_pkgup_mgr      → $(_pkgup_mgr)"
        echo "_pkgup_count    → $(_pkgup_count 2>&1 | tail -1)"
        echo "_pkgup_pending  → $(_pkgup_pending 2>&1 | head -3 | tr "\n" "|") (lines: $(_pkgup_pending 2>/dev/null | wc -l | tr -d " "))"
        _pkgup_refresh; echo "nudge (from cache) → $(_pkgup_notice 2>&1 | tr -d "\033" )"
        echo "up -n           → $(up -n 2>&1 | head -4 | tr "\n" "|")"
      ' _ "$repo_dir" >"$log" 2>&1
    say "**$1**"; say ""; excerpt "$log" 20
  }
  consumer "consumers after staging (this is what the user would see)"
else
  say "- no --repo-dir given; skipped."
fi

h2 "5. Reading it"
say "Fill in by hand: which verb answers AVAILABLE unprivileged and at what cost; which answers STAGED unprivileged; what the nudge and \`up -n\` say today on a staged host (§4) versus what they should say — the design lands in the proposal."
rm -rf "$work"
echo "report: $out"
