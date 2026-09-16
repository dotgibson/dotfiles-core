#!/usr/bin/env bash
# scripts/research/nonmutable-r1-cells.sh — the three cells R1 left unmeasured
# (NON-MUTABLE-HOST-PROPOSAL.md §5, #1052). Each one is a claim a SHIPPED declaration or
# a shipped bootstrap already makes, which no run has ever asked the host to confirm:
#
#   bootc    PKG_SEARCH. `dotfiles-Fedora/os/fedora.atomic.capabilities` declares
#            `dnf search`. On a booted bootc host R1 probed only `dnf install` (a refusal
#            that arrives after resolving 317 packages) and, in a CONTAINER, `dnf -q
#            provides` (38/38). Whether the read-only search verb answers on the deployed,
#            read-only host — and with what exit status on a MISS, which is the status a
#            consumer reads — is unmeasured.
#   nixos    `chsh` across a switch. R1 measured that `chsh` TAKES (users.mutableUsers
#            defaults to true). `dotfiles-NixOS/bootstrap.sh` refuses to run it anyway and
#            prints the declaration instead, on the grounds that the next activation
#            reverts it — which is documentation (nixpkgs users-groups.nix), not a
#            measurement. This runs the activation and reads the shell back.
#   microos  an `/etc` edit across an update. transactional-update(8): "configuration file
#            changes applied to the currently running system will be visible in the new
#            system, but not vice versa", with a documented LOSS CASE when a file changes
#            both during the update and afterwards in the running system. The driver
#            writes `/etc/shells` and `chsh`es a login shell, so the loss case is not
#            hypothetical for this fleet. Forced deterministically, because a `dup` alone
#            may never touch a file we edited.
#
#   nonmutable-r1-cells.sh <bootc|microos|nixos> [--phase 1|2] [--out FILE]
#                          [--user NAME] [--next-system PATH]
#
#   --phase 1|2      microos only: the /etc cell exists only ACROSS a reboot. Phase 1
#                    updates, forces the collision and records what it wrote; the workflow
#                    reboots the guest; phase 2 reads it back and fills in the table. The
#                    other two targets are single-phase (phase 2 is a no-op there).
#   --user NAME      the unprivileged user the "as a user" questions are asked as, and the
#                    one whose login shell is chsh'd (created if absent). Default: research.
#   --next-system P  nixos only: a SECOND system generation, built on the runner over the
#                    shared /nix/store, that the guest activates. A `build-vm` guest
#                    carries no /etc/nixos/configuration.nix — which is exactly why this
#                    cell was still open — so the switch is handed in, already built.
#                    Without it the script replays the CURRENT system's activation and
#                    says in the report that that is a stand-in, not a switch.
#
# TRAPS, each already paid for once by an earlier iteration:
#   - never pipe a probe through `head`: a verbose tool dies of SIGPIPE and its status
#     reads as 141 (dnf) or 105 (zypper's "exit on signal"). Capture to a file first.
#   - `transactional-update` restarts from the BOOTED snapshot unless `--continue` is
#     given, silently dropping the pending one (R4).
#   - a reboot empties /tmp on these guests: phase state lives in $HOME (R4).
#   - never name a function-local `out` when `out` is the report path (R6).
#
# Deliberately tolerant: a failing probe IS the measurement. Non-zero only if the report
# cannot be written.
set -u

target="${1:?bootc|microos|nixos}"
shift
out="" phase=1 asuser="research" next_system=""
while (($#)); do
  case "$1" in
  --out) out="$2"; shift 2 ;;
  --phase) phase="$2"; shift 2 ;;
  --user) asuser="$2"; shift 2 ;;
  --next-system) next_system="$2"; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$target" in
bootc | microos | nixos) ;;
*) echo "usage: $0 bootc|microos|nixos [--phase 1|2] [--out FILE] [--user NAME] [--next-system PATH]" >&2; exit 2 ;;
esac
[[ -n "$out" ]] || out="/tmp/r1cells-$target.md"
mkdir -p "$(dirname "$out")" || { echo "cannot create $(dirname "$out")" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/r1cells.XXXXXX")"
# $HOME, not /tmp: phase 2 runs after a reboot.
state="${HOME:-/root}/.r1cells-$target.state"

say() { printf '%s\n' "$*" >>"$out"; }
h2() {
  say ""
  say "## $*"
  say ""
}
now_ms() { date +%s%3N 2>/dev/null || echo 0; }
excerpt() { # <file> [n] — head+tail of a captured log, fenced
  local f="$1" n="${2:-15}" lines
  lines=$(wc -l <"$f" | tr -d ' ')
  say '```text'
  if ((lines > 2 * n)); then
    head -n "$n" "$f" >>"$out"
    say "… ($((lines - 2 * n)) lines omitted) …"
    tail -n "$n" "$f" >>"$out"
  else
    cat "$f" >>"$out"
  fi
  say '```'
}
# who: me | root — how to run the command from where this script stands.
_as() { # <who> <cmd…>
  local who="$1"
  shift
  case "$who" in
  root) if ((EUID == 0)); then "$@"; else sudo -n "$@"; fi ;;
  me) if ((EUID == 0)) && [[ -n "$asuser" ]] && id "$asuser" >/dev/null 2>&1; then runuser -u "$asuser" -- "$@"; else "$@"; fi ;;
  esac
}
who_label() {
  case "$1" in
  root) echo "root" ;;
  me)
    if ((EUID == 0)) && [[ -n "$asuser" ]] && id "$asuser" >/dev/null 2>&1; then
      echo "user $asuser"
    elif ((EUID == 0)); then echo "root (no --user)"; else echo "user $(id -un)"; fi
    ;;
  esac
}
# measure <who> <label> <cmd…> — one table row, and MEASURE_RC / MEASURE_LOG for a caller
# that wants to CONCLUDE from it rather than re-run the command to ask again.
MEASURE_RC=0 MEASURE_LOG=""
table_head() {
  say "| what | verb | as | exit | cost | lines | first line |"
  say "| --- | --- | --- | --- | --- | --- | --- |"
}
measure() {
  local who="$1" label="$2"
  shift 2
  local log t0 t1 rc first lines
  log="$(mktemp "$work/m.XXXXXX")"
  t0=$(now_ms)
  _as "$who" "$@" >"$log" 2>&1 </dev/null
  rc=$?
  t1=$(now_ms)
  first="$(head -n1 "$log" | cut -c1-110 | tr '|' '/')"
  lines=$(wc -l <"$log" | tr -d ' ')
  say "| $label | \`$*\` | $(who_label "$who") | **$rc** | $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1000}') s | $lines | \`${first:-<none>}\` |"
  MEASURE_RC=$rc
  MEASURE_LOG="$log"
}
run() { # <who> <label> <cmd…> — full excerpt; the return status is the command's
  local who="$1" label="$2"
  shift 2
  local log t0 t1 rc
  log="$(mktemp "$work/r.XXXXXX")"
  t0=$(now_ms)
  _as "$who" "$@" >"$log" 2>&1 </dev/null
  rc=$?
  t1=$(now_ms)
  say "**$label** — \`$*\` as $(who_label "$who") → exit **$rc** ($(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1000}') s)"
  say ""
  excerpt "$log"
  return "$rc"
}
shell_of() { getent passwd "$1" 2>/dev/null | cut -d: -f7; }
verdict() { # <before> <after> — did a value survive?
  if [[ "$1" == "$2" ]]; then echo "**kept**"; else echo "**REVERTED**"; fi
}
ensure_user() {
  id "$asuser" >/dev/null 2>&1 && return 0
  useradd -m "$asuser" >/dev/null 2>&1 || true
}

if [[ "$phase" == 2 ]]; then
  [[ -f "$out" ]] || : >"$out" # phase 2 APPENDS to phase 1's report; the workflow ships one file
else
  : >"$out"
  say "# R1's remaining cells — $target ($(date -u +%Y-%m-%dT%H:%MZ))"
  say ""
  say "Generated by \`scripts/research/nonmutable-r1-cells.sh $target\` (#1052). Guest: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"') (ID=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')); environment **$([[ -f /.dockerenv || -f /run/.containerenv ]] && echo container || echo host)**; uid $(id -u); \`sudo -n\`: $(sudo -n true 2>/dev/null && echo works || echo no)."
fi

# ── bootc: PKG_SEARCH on a booted, read-only host ────────────────────────────
bootc_cells() {
  local repos
  repos="$(find /etc/yum.repos.d -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
  h2 "1. The host the verb is being asked of"
  say "- \`/run/ostree-booted\`: $([[ -e /run/ostree-booted ]] && echo present || echo absent)"
  say "- \`/usr\` writable: $([[ -w /usr ]] && echo yes || echo no)"
  say "- \`/etc/yum.repos.d\`: \`$repos\`"
  say "- layered packages: \`$(rpm-ostree status 2>/dev/null | grep -E 'LayeredPackages|LocalPackages' | tr -s ' ' | tr '\n' ';')\`"
  say ""
  say "Nothing has run a bootstrap on this host yet — that matters, because R6 found a forced provision run writes a COPR repo file and breaks every later \`dnf\`. This is the stock repo set."

  h2 "2. \`PKG_SEARCH\` and its read-only siblings"
  say "The verb under test is \`dotfiles-Fedora/os/fedora.atomic.capabilities\`'s \`PKG_SEARCH=dnf search\`, asked twice: once where a match exists, once where none does — the MISS is the interesting one, because its exit status is what a consumer reads."
  say ""
  say "\`makecache\` goes first, and **as the user**, for a reason R6 paid for: against a cold cache every query is a false miss, and \`PKG_SEARCH\` is declared with no escalator — so whether an unprivileged user can populate \`/var/cache\` on a read-only host is part of the cell, not setup."
  say ""
  table_head
  measure me "dnf -q makecache (can a user warm the cache here?)" dnf -q makecache
  local cache_rc=$MEASURE_RC
  measure me "dnf search (hit)" dnf search zsh
  local hit_rc=$MEASURE_RC hit_lines
  hit_lines=$(wc -l <"$MEASURE_LOG" | tr -d ' ')
  measure root "dnf search (hit)" dnf search zsh
  measure me "dnf search (miss)" dnf search dotgibson-no-such-package
  local miss_rc=$MEASURE_RC miss_lines
  miss_lines=$(wc -l <"$MEASURE_LOG" | tr -d ' ')
  measure root "dnf search (miss)" dnf search dotgibson-no-such-package
  measure me "dnf search --refresh (hit)" dnf search --refresh zsh
  local refresh_rc=$MEASURE_RC
  # shellcheck disable=SC2016  # the $(…) expands in the probe's own sh, deliberately
  measure me "dnf -q provides (R6's container verb)" sh -c 'dnf -q provides "$(command -v zsh)"'
  local provides_rc=$MEASURE_RC
  # shellcheck disable=SC2016  # ditto
  measure me "rpm -qf (PKG_OWNS)" sh -c 'rpm -qf "$(command -v zsh)"'
  local owns_rc=$MEASURE_RC

  h2 "3. What the hit printed"
  run me "dnf search zsh" dnf search zsh

  local miss_note
  if ((hit_rc == miss_rc)); then
    miss_note="the SAME status as a hit — **a consumer cannot tell \"no such package\" from \"the verb answered\" by exit status alone here**; it has to read the output"
  elif ((miss_rc != 0)); then
    miss_note="distinct from the hit's **$hit_rc** — a consumer that reads the status must treat \`$miss_rc\` as \"no such package\", not as \"the verb is broken\""
  else
    miss_note="**0 — a miss looks like a success**"
  fi
  h2 "4. Reading it"
  say "- **\`PKG_SEARCH=dnf search\` on a booted bootc host**: a match exits **$hit_rc** with $hit_lines lines$( ((hit_rc == 0)) && echo " — the shipped declaration is true here" || echo " — **the shipped declaration is NOT true here**")."
  say "- **on a miss**: exit **$miss_rc** with $miss_lines lines, $miss_note."
  say "- \`dnf -q makecache\` as the user: exit **$cache_rc**$( ((cache_rc != 0)) && echo " — **a cold cache**, so a miss above may be an artefact of that and not of the verb; read the §3 output before concluding" || echo " — the cache was warm, so the statuses above are the verb's")."
  say "- \`--refresh\` (metadata fetch as the user): exit **$refresh_rc**; \`dnf -q provides\`: exit **$provides_rc**; \`PKG_OWNS=rpm -qf\`: exit **$owns_rc**."
  say "- Read against R1's measured refusal: \`dnf install\` resolves and then refuses (*\"this bootc system is configured to be read-only\"*). The split this section measures is whether the READ-ONLY half of the same tool is unaffected."
}

# ── nixos: chsh across an activation ─────────────────────────────────────────
nixos_cells() {
  ensure_user
  local zsh_path root_before user_before root_after user_after marker=/etc/research-generation
  zsh_path="$(command -v zsh || echo /run/current-system/sw/bin/zsh)"

  h2 "1. Before: the generation, the users, \`/etc/shells\`"
  say "- current system: \`$(readlink -f /run/current-system 2>/dev/null)\`"
  say "- booted system: \`$(readlink -f /run/booted-system 2>/dev/null)\`"
  say "- generation marker \`$marker\`: $([[ -f "$marker" ]] && echo "present (\`$(cat "$marker")\`)" || echo absent)"
  say "- root shell: \`$(shell_of root)\`; \`$asuser\` shell: \`$(shell_of "$asuser")\` ($(id "$asuser" >/dev/null 2>&1 && echo "created imperatively — \`users.mutableUsers\` permits it" || echo "could not be created"))"
  say "- \`/etc/shells\`: \`$(tr '\n' ' ' </etc/shells 2>/dev/null)\`"
  say "- \`zsh\`: \`$zsh_path\`"

  h2 "2. \`chsh\` — the verb \`dotfiles-NixOS\` refuses to run"
  say "It is run here anyway, on both a DECLARED user (root, whose shell \`users.users.root.shell\` names) and an IMPERATIVE one (\`$asuser\`, created with \`useradd\` and declared nowhere). If activation reverts only the declared one, the repo's boundary is narrower than its comment says."
  say ""
  table_head
  measure root "chsh root" chsh -s "$zsh_path" root
  measure root "chsh $asuser" chsh -s "$zsh_path" "$asuser"
  root_before="$(shell_of root)"
  user_before="$(shell_of "$asuser")"
  say ""
  say "- after \`chsh\` — root: \`$root_before\`; \`$asuser\`: \`$user_before\`"

  h2 "3. The switch"
  if [[ -n "$next_system" && -x "$next_system/bin/switch-to-configuration" ]]; then
    say "Activating a **second generation**, \`$next_system\`, built on the runner and reached over the shared \`/nix/store\` — a real switch to a different system, with no evaluation, no network and no store writes inside the guest. It differs from the booted one by one \`environment.etc\` entry, so sshd and the authorized key are identical and this session survives it."
    say ""
    say "The action is \`test\`, not \`switch\`, and that is the honest choice rather than a timid one. \`switch\` is *activate + make it the boot default*, and the boot-default half installs a boot loader — which a \`build-vm\` guest, booted from QEMU's \`-kernel\`, does not have. The **activation** half is where \`users-groups\` runs, so \`test\` on a genuinely different generation measures the cell exactly, and cannot abort halfway through the thing being measured."
    say ""
    run root "gen2 switch-to-configuration test" "$next_system/bin/switch-to-configuration" test || true
    say "- generation marker \`$marker\` now: $([[ -f "$marker" ]] && echo "present (\`$(cat "$marker")\`) — **the second generation really activated**, so the rows below are a switch's activation" || echo "**ABSENT — the activation did not take**; read the rows below as inconclusive, not as a switch")"
    say ""
    say "And then the full verb, **expected to fail**, so this run finally records *why* rather than the bare exit status R1 has been carrying since iteration 3:"
    say ""
    run root "gen2 switch-to-configuration switch (the bootloader half)" "$next_system/bin/switch-to-configuration" switch || true
  else
    say "**No \`--next-system\` was handed in**, so this replays the CURRENT system's activation with \`switch-to-configuration test\`. That runs the very \`users-groups\` activation script a real \`nixos-rebuild switch\` runs — but it is a **stand-in for a switch, not a switch**, and the finding must say so."
    say ""
    run root "switch-to-configuration test (activation replay)" /run/current-system/bin/switch-to-configuration test || true
  fi

  h2 "4. After: did the hand-set shell survive?"
  root_after="$(shell_of root)"
  user_after="$(shell_of "$asuser")"
  say "| who | declared? | after \`chsh\` | after the activation | verdict |"
  say "| --- | --- | --- | --- | --- |"
  say "| root | declared (\`users.users.root.shell\`) | \`$root_before\` | \`$root_after\` | $(verdict "$root_before" "$root_after") |"
  say "| $asuser | imperative (\`useradd\`; \`users.mutableUsers\`) | \`$user_before\` | \`$user_after\` | $(verdict "$user_before" "$user_after") |"
  say ""
  say "- \`$asuser\` still exists after the activation: $(id "$asuser" >/dev/null 2>&1 && echo yes || echo "**no — activation removed the imperative user**")"
  say "- \`/etc/shells\` now: \`$(tr '\n' ' ' </etc/shells 2>/dev/null)\`"
  say "- current system now: \`$(readlink -f /run/current-system 2>/dev/null)\`"
  say ""
  say "Read it against \`dotfiles-NixOS/bootstrap.sh\`, which says \`chsh\` *\"would work here (users.mutableUsers defaults to true) and is still wrong\"*: a **REVERTED** row is the measurement that sentence has been missing."
}

# ── microos: an /etc edit across an update ───────────────────────────────────
# The markers, and what each one isolates. Written at three distinguishable moments, so
# phase 2 can tell the three outcomes apart (carried / shadowed / absent) rather than
# guessing from one file:
#
#   research-before    running /etc, BEFORE the snapshot opened, never touched again
#                      → the documented "visible in the new system" half. If THIS is lost,
#                        nothing else in the report is readable.
#   research-snapshot  inside the snapshot only
#                      → proves the guest really booted the snapshot we wrote (otherwise
#                        every "shadowed" is really "wrong snapshot").
#   research-after     running /etc, only AFTER the snapshot opened, no collision
#                      → the "but not vice versa" half.
#   research-collide   all three moments
#                      → the documented LOSS CASE itself.
#
# /etc/shells and a login shell ride the same three moments, because those are the two
# writes a real bootstrap makes (`blib_set_login_shell`) — they are the payload, the four
# markers above are the instrument.
microos_phase1() {
  ensure_user
  local zsh_path snaps_before snaps_after dup_rc open_rc overlays
  zsh_path="$(command -v zsh || echo /bin/zsh)"
  overlays="$(find /var/lib/overlay -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"

  h2 "1. Before: the snapshots, the \`/etc\` overlay, and the timers that would fight us"
  say "- booted subvolume: \`$(findmnt -no SOURCE / 2>/dev/null)\`"
  say "- default subvolume: \`$(btrfs subvolume get-default / 2>&1 | tr -d '\n')\`"
  say "- \`/etc\` overlay dirs: \`$overlays\`"
  say "- \`/etc\` mount: \`$(findmnt -no FSTYPE,OPTIONS /etc 2>/dev/null | cut -c1-160)\`"
  snaps_before=$(snapper --no-headers list 2>/dev/null | wc -l | tr -d ' ')
  say ""
  run root "snapper list (before)" sh -c 'snapper --no-headers list 2>/dev/null | tail -6'
  say ""
  say "MicroOS ships its own \`transactional-update.timer\` and a reboot manager. Either would open a snapshot of its own — which this run's \`--continue\` would then continue, measuring the wrong transaction — or reboot the guest mid-experiment. Stopping them is part of the method, not housekeeping:"
  say ""
  run root "stop the distro's own updater and reboot manager" systemctl disable --now transactional-update.timer rebootmgr.service
  run root "rebootmgrctl set-strategy off" rebootmgrctl set-strategy off

  h2 "2. The running \`/etc\`, BEFORE any snapshot is open"
  say "Two synthetic markers and the real pair — \`/etc/shells\` and \`$asuser\`'s login shell, the two writes \`blib_set_login_shell\` makes."
  printf 'running-before\n' >/etc/research-before
  printf 'running-before\n' >/etc/research-collide
  printf '%s\n' /running/before/marker >>/etc/shells
  chsh -s "$zsh_path" "$asuser" >/dev/null 2>&1 || true
  say ""
  say "- \`/etc/research-before\`, \`/etc/research-collide\` = \`running-before\`; \`/etc/shells\` += \`/running/before/marker\`; \`$asuser\` shell = \`$(shell_of "$asuser")\`"

  h2 "3. Open a snapshot and change the same files INSIDE it"
  say "\`transactional-update run\` executes a command inside a new snapshot. Doing this **first**, before the update, is deliberate: it means the snapshot is already dirty when the \`dup\` runs, so a \`dup\` with nothing to do still has a snapshot to close and the experiment survives a no-op. \`--no-selfupdate\` so the tool cannot restart itself out from under the transaction."
  say ""
  # shellcheck disable=SC2016  # the sh -c body runs inside the SNAPSHOT's chroot, not here
  run root "the snapshot side" timeout 15m transactional-update -n --no-selfupdate run sh -c 'printf "snapshot\n" >/etc/research-collide; printf "snapshot\n" >/etc/research-snapshot; printf "%s\n" /snapshot/marker >>/etc/shells; chsh -s /bin/bash '"$asuser"
  open_rc=$?
  say "- exit **$open_rc**"
  say ""
  run root "snapper list (snapshot open)" sh -c 'snapper --no-headers list 2>/dev/null | tail -4'

  h2 "4. The running \`/etc\` again, with that snapshot open"
  printf 'running-after\n' >/etc/research-collide
  printf 'running-after\n' >/etc/research-after
  printf '%s\n' /running/after/marker >>/etc/shells
  chsh -s "$zsh_path" "$asuser" >/dev/null 2>&1 || true
  say "- \`/etc/research-collide\` = \`running-after\` (**the collision**); \`/etc/research-after\` = \`running-after\`; \`/etc/shells\` += \`/running/after/marker\`; \`$asuser\` shell = \`$(shell_of "$asuser")\`"

  h2 "5. Close the transaction: \`transactional-update dup\`"
  say "\`dup\` is the verb \`dotfiles-openSUSE/os/opensuse.microos.capabilities\` names for an upgrade (\`zypper dup --no-allow-vendor-change\` into the snapshot, live after \`PKG_APPLY\`). **\`--continue\` is load-bearing**: without it \`transactional-update\` restarts from the BOOTED snapshot and §3's writes are silently dropped (R4). Capped at \`${DUP_TIMEOUT:-45m}\` — the cost is a measurement, not a hang to wait out."
  say ""
  run root "transactional-update dup" timeout "${DUP_TIMEOUT:-45m}" transactional-update -n --no-selfupdate --continue dup
  dup_rc=$?
  snaps_after=$(snapper --no-headers list 2>/dev/null | wc -l | tr -d ' ')
  say "- exit **$dup_rc** (0 ok; 1 a command failed and the snapshot was deleted; 2 \`apply\` failed); snapshots $snaps_before → $snaps_after"
  say "- \`/run/reboot-needed\`: $([[ -e /run/reboot-needed ]] && echo present || echo absent)"
  say "- default subvolume now: \`$(btrfs subvolume get-default / 2>&1 | tr -d '\n')\`"

  h2 "6. What phase 2 will be judged against"
  say "| file | running before | in the snapshot | running after | value now (still on the booted snapshot) |"
  say "| --- | --- | --- | --- | --- |"
  say "| \`/etc/research-before\` | \`running-before\` | — | — | \`$(cat /etc/research-before 2>/dev/null || echo absent)\` |"
  say "| \`/etc/research-snapshot\` | — | \`snapshot\` | — | \`$(cat /etc/research-snapshot 2>/dev/null || echo absent)\` |"
  say "| \`/etc/research-after\` | — | — | \`running-after\` | \`$(cat /etc/research-after 2>/dev/null || echo absent)\` |"
  say "| \`/etc/research-collide\` | \`running-before\` | \`snapshot\` | \`running-after\` | \`$(cat /etc/research-collide 2>/dev/null || echo absent)\` |"
  say "| \`/etc/shells\` | \`/running/before/marker\` | \`/snapshot/marker\` | \`/running/after/marker\` | \`$(tr '\n' ' ' </etc/shells 2>/dev/null)\` |"
  say "| \`$asuser\`'s login shell | \`$zsh_path\` | \`/bin/bash\` | \`$zsh_path\` | \`$(shell_of "$asuser")\` |"
  {
    echo "dup_rc=$dup_rc"
    echo "open_rc=$open_rc"
    echo "snaps_before=$snaps_before"
    echo "snaps_after=$snaps_after"
    echo "zsh_path=$zsh_path"
    echo "booted_before=$(findmnt -no SOURCE / 2>/dev/null)"
    echo "default_before=$(btrfs subvolume get-default / 2>&1 | tr -d '\n')"
  } >"$state"
  say ""
  say "State for phase 2 is in \`$state\` (\`\$HOME\`, not \`/tmp\` — the reboot empties \`/tmp\`). **The workflow reboots the guest now.**"
}

microos_phase2() {
  local booted_before="" zsh_path="" dup_rc="?" open_rc="?" snaps_before="?" snaps_after="?"
  # shellcheck disable=SC1090  # a state file this script wrote in phase 1
  [[ -f "$state" ]] && . "$state"
  local booted_now collide shells_now user_now snap_marker before_marker after_marker
  booted_now="$(findmnt -no SOURCE / 2>/dev/null)"
  collide="$(cat /etc/research-collide 2>/dev/null || echo absent)"
  shells_now="$(tr '\n' ' ' </etc/shells 2>/dev/null)"
  user_now="$(shell_of "$asuser")"
  case " $shells_now " in *" /snapshot/marker "*) snap_marker=yes ;; *) snap_marker=no ;; esac
  case " $shells_now " in *" /running/before/marker "*) before_marker=yes ;; *) before_marker=no ;; esac
  case " $shells_now " in *" /running/after/marker "*) after_marker=yes ;; *) after_marker=no ;; esac

  h2 "7. After the reboot — is there anything to read?"
  say "- booted subvolume: \`$booted_before\` → \`$booted_now\`"
  say "- default subvolume: \`$(btrfs subvolume get-default / 2>&1 | tr -d '\n')\`"
  say "- phase 1: the snapshot opened with exit $open_rc, \`dup\` exited $dup_rc, snapshots $snaps_before → $snaps_after"
  if [[ -n "$booted_before" && "$booted_now" == "$booted_before" ]]; then
    say ""
    say "> **The booted subvolume did not change — this round measured NOTHING.** A failed"
    say "> transaction deletes its own snapshot (\`transactional-update\` exit 1), and so can a"
    say "> \`dup\` with nothing to do. Every row below is the OLD \`/etc\`, so a \`carried\` there"
    say "> means the file was never crossed by anything. Read §5's exit status, not the table."
  fi
  say ""
  run root "snapper list (after)" sh -c 'snapper --no-headers list 2>/dev/null | tail -6'

  h2 "8. Verdict — what the new snapshot's \`/etc\` kept"
  local shells_verdict
  if [[ "$snap_marker" == yes && "$after_marker" == no ]]; then
    shells_verdict="**the loss case, on the driver's own write** — the snapshot's \`/etc/shells\` won and the later append is gone"
  elif [[ "$after_marker" == yes && "$before_marker" == yes ]]; then
    shells_verdict="both running appends survived"
  elif [[ "$after_marker" == yes ]]; then
    shells_verdict="the post-snapshot append survived, the pre-snapshot one did not"
  else
    shells_verdict="**neither running append survived**"
  fi
  say "| file | written where | after the reboot | verdict |"
  say "| --- | --- | --- | --- |"
  say "| \`/etc/research-before\` | running, before the snapshot | \`$(cat /etc/research-before 2>/dev/null || echo absent)\` | $([[ "$(cat /etc/research-before 2>/dev/null)" == running-before ]] && echo "**carried** — the documented \"visible in the new system\" half holds" || echo "**LOST — the documented half does NOT hold; nothing below is readable**") |"
  say "| \`/etc/research-snapshot\` | the snapshot only | \`$(cat /etc/research-snapshot 2>/dev/null || echo absent)\` | $([[ "$(cat /etc/research-snapshot 2>/dev/null)" == snapshot ]] && echo "**live** — the guest really booted the snapshot this run wrote" || echo "**ABSENT — the guest did not boot that snapshot**") |"
  say "| \`/etc/research-after\` | running, after the snapshot opened | \`$(cat /etc/research-after 2>/dev/null || echo absent)\` | $([[ "$(cat /etc/research-after 2>/dev/null)" == running-after ]] && echo "**carried** — a post-snapshot running edit still reaches the new \`/etc\`" || echo "**LOST** — \"but not vice versa\", measured") |"
  say "| \`/etc/research-collide\` | all three moments | \`$collide\` | $(case "$collide" in snapshot) echo "**the loss case, confirmed** — the snapshot's copy won and the later running edit is gone" ;; running-after) echo "the running edit won — the documented loss case did NOT fire here" ;; running-before) echo "**neither later write survived**" ;; *) echo "**absent** — never reached the new \`/etc\`" ;; esac) |"
  say "| \`/etc/shells\` | all three moments | before: **$before_marker**; snapshot: **$snap_marker**; after: **$after_marker** | $shells_verdict |"
  say "| \`$asuser\`'s login shell | \`$zsh_path\` → \`/bin/bash\` (snapshot) → \`$zsh_path\` | \`$user_now\` | $(case "$user_now" in "$zsh_path") echo "**carried** — the driver's \`chsh\` survived" ;; /bin/bash) echo "**shadowed** — the snapshot's \`chsh\` won; the driver's later one is gone" ;; *) echo "neither — \`$user_now\`" ;; esac) |"
  say ""
  say "- \`/etc/shells\` now: \`$shells_now\`"
  say "- \`.rpmnew\` / \`.rpmsave\` the update left under \`/etc\`: \`$(find /etc -maxdepth 2 \( -name '*.rpmnew' -o -name '*.rpmsave' \) 2>/dev/null | tr '\n' ' ')\`"

  h2 "9. Reading it"
  say "The rows above are mechanical string comparisons, so the script fills them in; what a person decides is the consequence. The question for the fleet is narrow. A bootstrap on a transactional host writes \`/etc/shells\` and \`chsh\`es a login shell — and it may well do so while a snapshot is already staged, because \`PKG_INSTALL\` there **is** a staging verb, so every provisioning run leaves one open behind it. If the \`/etc/research-collide\` row says *the loss case, confirmed*, the two rows under it say whether the driver's own writes are exposed to it, and \`dotfiles-openSUSE\`'s transactional arm has to say so out loud."
}

case "$target" in
bootc)
  if [[ "$phase" == 2 ]]; then say "(phase 2 is a no-op on $target — this cell is single-phase.)"; else bootc_cells; fi
  ;;
nixos)
  if [[ "$phase" == 2 ]]; then say "(phase 2 is a no-op on $target — this cell is single-phase.)"; else nixos_cells; fi
  ;;
microos)
  if [[ "$phase" == 2 ]]; then microos_phase2; else microos_phase1; fi
  ;;
esac

rm -rf "$work"
echo "report: $out"
