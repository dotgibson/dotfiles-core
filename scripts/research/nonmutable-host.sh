#!/usr/bin/env bash
# scripts/research/nonmutable-host.sh — R1 of NON-MUTABLE-HOST-PROPOSAL.md §5, the
# measurable half: run a fleet repo's bootstrap, UNCHANGED, on an atomic/transactional/
# declarative target and write down what the host actually is and what the driver
# actually did. One target per run; the report is Markdown, meant to be pasted (after
# reading) into the proposal's R1 findings.
#
#   scripts/research/nonmutable-host.sh <target> [--out DIR] [--repo-ref REF]
#
#   <target>   bootc     — Fedora bootc / Silverblue lineage. Runs dotfiles-Fedora.
#              microos   — openSUSE MicroOS / Aeon lineage. Runs dotfiles-openSUSE.
#              nixos     — NixOS. Runs a repo scaffolded by scripts/new-os-repo.sh (there
#                          is no dotfiles-NixOS yet), with this Core seeded as its core/.
#   --out FILE  where the report goes (default: research-out/<target>.md)
#   --repo-ref  the fleet repo ref to run (default: main)
#   --repo-dir  run THIS checkout instead of cloning or scaffolding one — how the VM legs
#               hand a repo prepared on the runner (a scaffolded dotfiles-NixOS with Core
#               seeded, say) to a guest that has no Core checkout of its own
#   --as-user   run the bootstrap as the calling user with the escalator RESOLVED (BLIB_SU
#               unset) rather than as root with BLIB_SU= — the realistic path on a booted
#               host, where sudo is what the driver would find
#
# WHAT IT MEASURES, in order, each recorded as it happens:
#   1. what the host is: os-release, the update tooling present, which of /usr /etc /var
#      is writable, the escalator, getent/chsh, /etc/shells;
#   2. the bootstrap's PROBE-ONLY paths — --help, --links-only, --dry-run — against a
#      throwaway HOME, with BLIB_SU= (root inside the image), recording exit codes and
#      every "would …"/"skip"/"warn" line;
#   3. the REAL run (`./bootstrap.sh`), which is where §3's hypotheses live: does the
#      provisioning verb work, block, or lie in this environment? What did the login-
#      shell step do? What did the closing report say?
#   4. the update verbs the schema would need: `rpm-ostree upgrade --check
#      --unchanged-exit-77`, `bootc upgrade --check`, `transactional-update --help`,
#      `nix --version`/`nixos-version` — exit codes and first lines.
#
# WHAT IT DOES NOT CLAIM. A container is not a booted host. On a bootc IMAGE, dnf works
# (that is how images are built) and rpm-ostree's daemon does not run — so "provisioning
# succeeded" here means the image-build path, not the deployed host. MicroOS in a
# container has no btrfs snapshots, so transactional-update cannot transact. The NixOS
# leg runs on the nixos/nix image, which is a plain mutable container with nix in it —
# it proves links and tool detection, not /etc being generated. The report says which of
# these it was; the VM legs (R1's real deliverable) come after, and reuse this script.
#
# The script is deliberately tolerant: every probe is `|| true` with its status recorded,
# because a failing probe IS the measurement. It exits non-zero only when it could not
# write the report.
set -uo pipefail

target="${1:-}"; shift || true
out=""; repo_ref="main"; repo_dir=""; as_user=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --out) out="$2"; shift 2 ;;
  --repo-ref) repo_ref="$2"; shift 2 ;;
  --repo-dir) repo_dir="$2"; shift 2 ;;
  --as-user) as_user=1; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$target" in
bootc) repo=dotfiles-Fedora ;;
microos) repo=dotfiles-openSUSE ;;   # in a container this is Tumbleweed + the transactional-update PACKAGE — see the workflow
nixos) repo=SCAFFOLD ;;
*) echo "usage: $0 bootc|microos|nixos [--out DIR] [--repo-ref REF]" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${out:-$HERE/research-out/$target.md}"
mkdir -p "$(dirname "$out")" || { echo "cannot create $(dirname "$out")" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/nonmutable.XXXXXX")"
: >"$out"

say() { printf '%s\n' "$*" >>"$out"; }
h2() { say ""; say "## $*"; say ""; }
h3() { say ""; say "### $*"; say ""; }
# run <label> <cmd…> — record the command, its exit status and its output (fenced)
run() {
  local label="$1"; shift
  local rc log
  log="$(mktemp "$work/run.XXXXXX")"
  ("$@") >"$log" 2>&1; rc=$?
  say "**$label** — \`$*\` → exit **$rc**"
  say ""
  say '```text'
  # Head AND tail: a package manager's list can run past any cap, and the exit reason is
  # at the END — the first VM run lost dnf's refusal behind 6 KB of "Installing:" rows.
  if [[ "$(wc -c <"$log")" -gt 7000 ]]; then
    head -c 3500 "$log" >>"$out"; say ""; say "… (middle omitted) …"; say ""; tail -c 3500 "$log" >>"$out"
  else
    cat "$log" >>"$out"
  fi
  say '```'
  return 0
}
# probe <label> <cmd…> — one line: exit status and the first output line
probe() {
  local label="$1"; shift
  local rc first log
  # Capture to a file, then read the first line — NOT `| head -1`: a verbose command dies of
  # SIGPIPE when head exits, and its exit status reads as 141 (dnf) or zypper's 105
  # ("exit on signal"), which iteration 2 wrote down as if the tool had said it.
  log="$(mktemp "$work/probe.XXXXXX")"
  ("$@") >"$log" 2>&1; rc=$?
  first="$(head -1 "$log")"
  say "- **$label**: \`$*\` → exit $rc${first:+ — \`$(printf '%s' "$first" | cut -c1-160)\`}"
}
writable() { # writable <dir> — can root create a file there?
  local d="$1" f rc
  f="$d/.nonmutable-probe.$$"
  if (: >"$f") 2>/dev/null; then rm -f "$f"; rc=writable; else rc="NOT writable"; fi
  say "- \`$d\`: $rc"
}

say "# R1 — $target ($(date -u +%Y-%m-%dT%H:%MZ))"
say ""
say "Generated by \`scripts/research/nonmutable-host.sh $target\`. Environment: **$([[ -f /.dockerenv || -f /run/.containerenv ]] && echo container || echo host)**; uid $(id -u); shell $BASH_VERSION."

h2 "1. What the host is"
h3 "os-release"
say '```text'
grep -E '^(NAME|ID|ID_LIKE|VARIANT_ID|VERSION_ID|PRETTY_NAME)=' /etc/os-release 2>/dev/null >>"$out" || say "(no /etc/os-release)"
say '```'
h3 "Update tooling present"
for t in rpm-ostree bootc dnf transactional-update zypper snapper nix nixos-rebuild home-manager nix-env flatpak toolbox distrobox brew; do
  p="$(command -v "$t" 2>/dev/null || true)"
  say "- \`$t\`: ${p:-absent}"
done
h3 "Writable?"
for d in /usr /usr/bin /etc /var /opt /home "$HOME"; do [[ -d "$d" ]] && writable "$d"; done
h3 "Escalator and login-shell machinery"
for t in sudo doas chsh usermod getent zsh git; do p="$(command -v "$t" 2>/dev/null || true)"; say "- \`$t\`: ${p:-absent}"; done
say "- \`/etc/shells\`: $([[ -f /etc/shells ]] && tr '\n' ' ' </etc/shells || echo absent)"
say "- \`/etc/passwd\` writable: $( (: >>/etc/passwd) 2>/dev/null && echo yes || echo no)"
h3 "The update verbs, as the schema would call them"
case "$target" in
bootc)
  probe "rpm-ostree status" rpm-ostree status
  probe "rpm-ostree status --pending-exit-77" rpm-ostree status --pending-exit-77
  probe "rpm-ostree upgrade --check --unchanged-exit-77" rpm-ostree upgrade --check --unchanged-exit-77
  probe "bootc status" bootc status
  probe "bootc upgrade --check" bootc upgrade --check
  probe "dnf --version" dnf --version
  # The mutable verb, as the Fedora declaration would call it: what does dnf say on a booted
  # bootc host? (--assumeno: resolve, print, refuse — no transaction.)
  probe "dnf install --assumeno tmux (the mutable verb, refused how?)" dnf install --assumeno tmux
  # And the layering verb the schema would need instead (dry: no download).
  probe "rpm-ostree install --dry-run tmux" rpm-ostree install --dry-run tmux
  # PKG_SEARCH, which the atomic declaration still names as `dnf search`. Only the
  # TRANSACTION is refused on a booted host ("this bootc system is configured to be
  # read-only") — a metadata query writes nothing, so it should hold where install does
  # not. The harness had only ever probed `dnf install` and `dnf -q provides`, which is why
  # the cell sat "to verify" (#1052). The two bootc passes run this as the user AND as
  # root: whether an unprivileged search can refresh the repo cache is the half that
  # matters, because `have`/PKG_SEARCH runs as the person.
  probe "dnf search tmux (PKG_SEARCH, the read-only half)" dnf search tmux
  probe "dnf -q list --available tmux (search's stricter neighbour)" dnf -q list --available tmux
  ;;
microos)
  probe "transactional-update --version" transactional-update --version
  probe "snapper list" snapper list
  probe "zypper --version" zypper --version
  # The count verb the schema would fall back to (transactional-update has no check mode):
  # read-only against the running snapshot's repo cache.
  probe "zypper --non-interactive lu (read-only pending list)" zypper --non-interactive lu
  probe "zypper --non-interactive in --dry-run zsh (the mutable verb, refused?)" zypper --non-interactive in --dry-run zsh
  probe "findmnt / (fstype)" findmnt -no FSTYPE,OPTIONS /
  ;;
nixos)
  probe "nix --version" nix --version
  probe "nixos-version" nixos-version
  probe "nix-env --version" nix-env --version
  probe "home-manager --version" home-manager --version
  probe "ls /run/current-system/sw/bin (count)" sh -c 'ls /run/current-system/sw/bin | wc -l'
  probe "ls ~/.nix-profile/bin" ls "$HOME/.nix-profile/bin"
  # The imperative install the schema would name, and the declarative rebuild it is meant to
  # replace. `nix profile install` is the anti-pattern the proposal names; measure it anyway.
  # `nix profile install` has no --dry-run (measured: "unrecognised flag"); `nix build
  # --dry-run` is the fetch-and-resolve half of the same imperative path.
  probe "nix build nixpkgs#hello --dry-run (imperative fetch, resolved only)" nix --extra-experimental-features 'nix-command flakes' build nixpkgs#hello --dry-run
  probe "nixos-rebuild dry-build (needs /etc/nixos/configuration.nix — a build-vm guest has none)" nixos-rebuild dry-build
  # shellcheck disable=SC2016  # the $(…) are for the guest's sh, on purpose
  probe "chsh -s zsh (mutableUsers default: does it take?)" sh -c 'chsh -s "$(command -v zsh)" "$(id -un)" && getent passwd "$(id -un)" | cut -d: -f7'
  # … and does it SURVIVE? `users.mutableUsers` (default true) merges /etc/passwd with
  # the generated one, and that merge is `update-users-groups.pl`, which runs from the
  # system's ACTIVATION script and nowhere else. The build half of `nixos-rebuild switch`
  # cannot touch /etc/passwd; the activation half is the whole question, and it is runnable
  # against the current system in ~2 s — which is what closes the cell here, because a
  # build-vm guest has no /etc/nixos/configuration.nix to rebuild FROM (the line above) and
  # its store is the runner's. Re-activating an identical configuration restarts no unit,
  # so this does not take the ssh session down with it.
  run "switch-to-configuration test (the activation half of nixos-rebuild switch)" \
    sh -c 'exec /run/current-system/bin/switch-to-configuration test'
  # shellcheck disable=SC2016  # the $(…) is for the guest's sh, on purpose
  probe "login shell AFTER activation (did the mutableUsers merge revert chsh?)" sh -c 'getent passwd "$(id -un)" | cut -d: -f7'
  probe "users.mutableUsers as the built system declares it" sh -c 'grep -om1 "mutableUsers[^,}]*" /run/current-system/activate 2>/dev/null || echo "(not spelled in the activation script)"'
  ;;
esac

h2 "2. The repo"
if [[ -n "$repo_dir" ]]; then
  say "Using the prepared checkout \`$repo_dir\` (--repo-dir)."
  rdir="$repo_dir"
  say "- vendored Core: \`$(cat "$rdir/core/core.version" 2>/dev/null || echo '?')\` (core.lock: $(grep -m1 '^core_tag' "$rdir/core.lock" 2>/dev/null || echo 'none'))"
elif [[ "$repo" == SCAFFOLD ]]; then
  say "No \`dotfiles-NixOS\` exists; scaffolding one with \`scripts/new-os-repo.sh --no-vendor NixOS\` and seeding THIS Core as its \`core/\` (the same seeding \`scripts/test/35-new-os-repo.sh\` does)."
  rdir="$work/dotfiles-NixOS"
  run "scaffold" env -u CORE_JSON bash "$HERE/scripts/new-os-repo.sh" --no-vendor NixOS "$rdir"
  mkdir -p "$rdir/core/scripts/lib"
  for d in zsh tmux starship nvim git mise lib bin; do [[ -d "$HERE/$d" ]] && cp -r "$HERE/$d" "$rdir/core/"; done
  cp "$HERE/scripts/lib/common.sh" "$rdir/core/scripts/lib/" 2>/dev/null || true
  cp "$HERE/core.version" "$rdir/core/" 2>/dev/null || true
  say "- seeded core/ from Core at \`$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo '?')\` (core.version $(cat "$HERE/core.version" 2>/dev/null))"
else
  rdir="$work/$repo"
  run "clone $repo @ $repo_ref" git clone -q --depth=1 --branch "$repo_ref" "https://github.com/dotgibson/$repo.git" "$rdir"
  say "- vendored Core: \`$(cat "$rdir/core/core.version" 2>/dev/null || echo '?')\` (core.lock: $(grep -m1 '^core_tag' "$rdir/core.lock" 2>/dev/null || echo 'none'))"
fi
cd "$rdir" || { say "**could not enter the repo dir — stopping**"; exit 0; }
say "- bootstrap.sh hands over to the driver: $(grep -qE '^\s*blib_main\s+"\$@"' bootstrap.sh && echo yes || echo NO)"

# How every bootstrap below is invoked. Default: BLIB_SU= (root inside an image, or root
# in a guest). --as-user: leave BLIB_SU unset so the driver resolves the escalator the way
# a person's run would — that is the realistic path on a booted host.
if ((as_user)); then su_env=(); su_note="escalator resolved by the driver (--as-user)"; else su_env=(BLIB_SU=); su_note="BLIB_SU= (no escalator; uid $(id -u))"; fi
bs() { env HOME="$1" XDG_CONFIG_HOME="$1/.config" "${su_env[@]}" ./bootstrap.sh "${@:2}"; }

h2 "3. Probe-only paths (throwaway HOME; $su_note)"
home="$work/home"; mkdir -p "$home/.config/tmux/plugins/tpm"   # tpm placeholder: no network needed for links
run "--help" bs "$home" --help
run "--links-only" bs "$home" --links-only
say "- links made under the throwaway HOME: $(find "$home" -type l 2>/dev/null | wc -l | tr -d ' '); managed ~/.zshrc: $([[ -f "$home/.zshrc" ]] && grep -q 'dotfiles-managed v4' "$home/.zshrc" && echo yes || echo no)"
home2="$work/home-dry"; mkdir -p "$home2"
run "--dry-run" bs "$home2" --dry-run
if [[ -z "$(find "$home2" -mindepth 1 -print 2>/dev/null | head -1)" ]]; then
  say "- --dry-run wrote into HOME: nothing"
else
  say "- --dry-run wrote into HOME: $(find "$home2" -mindepth 1 -maxdepth 1 -print | sed "s#^$home2/##" | tr '\n' ' ')"
fi

h2 "4. The real run (this is the measurement)"
say "Invoked with $su_note; the provisioning verb is whatever the repo declares. On a container this is the image-build context, not a booted host — read §1 before trusting a green here."
home3="$work/home-real"; mkdir -p "$home3/.config/tmux/plugins/tpm"
run "full run" bs "$home3"
say "- login shell now: $(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7 || awk -F: -v u="$(id -un)" '$1==u{print $7}' /etc/passwd)"
say "- /etc/shells now: $([[ -f /etc/shells ]] && tr '\n' ' ' </etc/shells || echo absent)"
say "- tools on PATH after the run: $(for t in zsh tmux nvim git starship atuin mise yazi; do command -v $t >/dev/null 2>&1 && printf '%s ' "$t"; done)"

h2 "5. Reading the run against §3's table"
say "Fill in by hand after reading the sections above — the script records, the reader concludes:"
say ""
say "| Assumption | Held / broke here | Note |"
say "| --- | --- | --- |"
say "| PKG_INSTALL is synchronous | | |"
say "| PKG_UPGRADE returns with the box updated | | |"
say "| PKG_COUNT_PENDING lists packages | | |"
say "| /etc writable (chsh, /etc/shells, system files) | | |"
say "| Escalator + keepalive | | |"
say "| Tools on PATH by package | | |"
say "| --links-only holds unchanged | | |"

rm -rf "$work"
echo "report: $out"
