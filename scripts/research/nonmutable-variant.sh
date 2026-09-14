#!/usr/bin/env bash
# scripts/research/nonmutable-variant.sh — R4 of NON-MUTABLE-HOST-PROPOSAL.md (#1004):
# is "the existing repo grows a variant" a WORKING shape, not just a small diff?
#
# Applies one of the R4 prototype patches (scripts/research/nonmutable/r4/dotfiles-*.patch:
# a detection flag, a second capability declaration relinked by bootstrap_wire_pre_loader,
# a staging path in the provision hook, a closing "reboot to apply" hint) to a checkout of
# the sibling repo on a BOOTED atomic / transactional guest, then runs the repo's own
# bootstrap.sh through it — dry run, then the real run — and records what the host says.
# The VM legs of research-nonmutable-vm.yml run phase 1, reboot the guest, and run phase 2
# (the re-run the closing hint asks for: are the layered packages live, do the cargo/go
# guards now fire, is the variant declaration what the shell reads?).
#
#   nonmutable-variant.sh <bootc|microos> --repo-dir DIR --patch FILE --phase 1|2 [--out FILE] [--as-user]
#
# Every command's output is captured to a file first and excerpted (head+tail) — never
# piped through `head`, which SIGPIPEs the probe and fakes its exit code (R1 lesson).
set -u

target="${1:?bootc|microos}"; shift
repo_dir="" patch="" phase="" out="" as_user=0
while (($#)); do
  case "$1" in
  --repo-dir) repo_dir="$2"; shift 2 ;;
  --patch) patch="$2"; shift 2 ;;
  --phase) phase="$2"; shift 2 ;;
  --out) out="$2"; shift 2 ;;
  --as-user) as_user=1; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -d "$repo_dir" && -n "$phase" ]] || { echo "usage: $0 bootc|microos --repo-dir DIR --patch FILE --phase 1|2 [--out FILE] [--as-user]" >&2; exit 2; }
[[ -n "$out" ]] || out="/tmp/r4-$target.md"
work="$(mktemp -d /tmp/r4.XXXXXX)"

say() { printf '%s\n' "$*" >>"$out"; }
h2() { say ""; say "## $*"; say ""; }
excerpt() { # <file> [n] — head+tail of a captured log, fenced
  local f="$1" n="${2:-25}" lines
  lines=$(wc -l <"$f" | tr -d ' ')
  say '```text'
  if ((lines > 2 * n)); then
    head -n "$n" "$f" >>"$out"; say "… ($((lines - 2 * n)) lines omitted) …"; tail -n "$n" "$f" >>"$out"
  else
    cat "$f" >>"$out"
  fi
  say '```'
}
run() { # <label> <cmd…> — record exit status + excerpt
  local label="$1"; shift
  local log; log="$(mktemp "$work/run.XXXXXX")"
  "$@" >"$log" 2>&1; local rc=$?
  say "**$label** — \`$*\` → exit **$rc**"; say ""
  excerpt "$log"
  return "$rc"
}
probe() { # <label> <cmd…> — one-line result
  local label="$1"; shift
  local log; log="$(mktemp "$work/probe.XXXXXX")"
  "$@" >"$log" 2>&1; local rc=$?
  say "- **$label**: \`$*\` → exit $rc — \`$(head -c 300 "$log" | tr '\n' ' ')\`"
}

# How the bootstrap is invoked: --as-user leaves BLIB_SU for the driver to resolve
# (bootc: the research wheel user, NOPASSWD); otherwise BLIB_SU= (root on the guest).
if ((as_user)); then su_env=(); su_note="escalator resolved by the driver (--as-user)"; else su_env=(BLIB_SU=); su_note="BLIB_SU= (root)"; fi
home="${HOME}"
bs() { ( cd "$repo_dir" && env HOME="$home" XDG_CONFIG_HOME="$home/.config" "${su_env[@]}" ./bootstrap.sh "$@" ); }

# shellcheck disable=SC2016  # the sh -c bodies expand on the guest, deliberately
host_state() {
  case "$target" in
  bootc)
    probe "rpm-ostree status --pending-exit-77 (77 = a deployment is staged)" rpm-ostree status --pending-exit-77
    probe "rpm-ostree status (deployments)" sh -c 'rpm-ostree status 2>/dev/null | grep -E "^[● ] |LayeredPackages|Pinned|Version" | head -12'
    probe "layered packages per deployment" sh -c 'rpm-ostree status 2>/dev/null | grep -E "LayeredPackages|LocalPackages" | head -4'
    ;;
  microos)
    probe "snapper list (snapshots; * = current, + = default/next)" sh -c 'snapper --no-headers list 2>/dev/null | tail -6'
    probe "default vs booted snapshot" sh -c 'echo "booted=$(findmnt -no SOURCE / )  default=$(btrfs subvolume get-default / 2>/dev/null)"'
    probe "transactional-update status" sh -c 'transactional-update --quiet status 2>&1 | tail -3 || true'
    ;;
  esac
  probe "tools on PATH (package-provided)" sh -c 'for t in zsh tmux nvim git ripgrep fd bat eza zoxide fzf cargo go gcc lazygit; do command -v $t >/dev/null 2>&1 && printf "%s " $t; done; echo'
  probe "os.capabilities link → PROVISIONER" sh -c 'f="$HOME/.config/zsh/os.capabilities"; printf "%s => %s ; " "$f" "$(readlink "$f" 2>/dev/null || echo real-or-absent)"; grep -m1 "^PROVISIONER=" "$f" 2>/dev/null || echo "PROVISIONER absent"'
}

if [[ "$phase" == 1 ]]; then
  : >"$out"
  say "# R4 — the variant shape on $target ($(date -u +%Y-%m-%dT%H:%MZ))"; say ""
  say "Guest: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"') (ID=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"'), VARIANT_ID=$(sed -n 's/^VARIANT_ID=//p' /etc/os-release | tr -d '"' || true)); uid $(id -u); $su_note; repo \`$repo_dir\` @ $(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null); Core \`$(cat "$repo_dir/core/core.version" 2>/dev/null)\`."
  say ""
  h2 "1. Before: the host and the unpatched repo"
  probe "/run/ostree-booted" test -e /run/ostree-booted
  probe "transactional-update on PATH" command -v transactional-update
  probe "/usr writable?" test -w /usr
  host_state
  say "- unpatched declaration: \`$(grep -m1 '^PKG_INSTALL=' "$repo_dir"/os/*.capabilities 2>/dev/null | head -1)\`"

  h2 "2. The patch"
  say "\`${patch##*/}\` (base $(sed -n 's/^# Base: \([0-9a-f]*\).*/\1/p' "$patch" | head -1 | cut -c1-12)):"
  run "git apply" git -C "$repo_dir" apply --index "$patch" || { say "**patch did not apply — stopping**"; echo "report: $out"; exit 1; }
  say "- diff: \`$(git -C "$repo_dir" diff --cached --stat | tail -1)\`"
  new_caps="$(git -C "$repo_dir" diff --cached --name-only --diff-filter=A | grep '\.capabilities$' | head -1)"
  say "- new declaration: \`$new_caps\`"
  run "check-capabilities on the new declaration" bash "$repo_dir/core/scripts/check-capabilities.sh" "$repo_dir/$new_caps"

  h2 "3. Dry run through the variant"
  mkdir -p "$home/.config/tmux/plugins/tpm"
  run "--dry-run" bs --dry-run

  h2 "4. The real run (phase 1 — staging)"
  say "Invoked with $su_note. This is the measurement: does the variant's provision hook stage without a refusal, and does the closing hint say what to do next?"; say ""
  run "full run" bs
  rc=$?
  say "- exit **$rc** (${target}: 0 = staged and wired; the repo's strict default may exit non-zero on optional-tool misses — read the tally)"
  host_state
  say "- reboot next: the workflow reboots the guest and runs phase 2."
else
  h2 "5. After the reboot (phase 2 — is the layer live, does the re-run see it?)"
  host_state
  run "re-run after reboot" bs
  say "- exit **$?**"
  host_state
  say "- loader boots: $(HOME="$home" zsh -ic 'typeset -f core-doctor >/dev/null 2>&1 && echo "core-doctor defined" || echo "core-doctor UNDEFINED"' 2>/dev/null | tail -1)"
  h2 "6. Reading it"
  say "Fill in by hand: did phase 1 stage without a refusal (§4), did the reboot make the packages live (§5 tools on PATH), did the re-run pick up the toolchain-dependent tools and stay idempotent, and is the shell reading the VARIANT declaration (\`PROVISIONER\` line)?"
fi
rm -rf "$work"
echo "report: $out"
