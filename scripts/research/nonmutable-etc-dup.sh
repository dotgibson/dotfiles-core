#!/usr/bin/env bash
# scripts/research/nonmutable-etc-dup.sh — R1's last MicroOS cell of
# NON-MUTABLE-HOST-PROPOSAL.md (#1004, #1052): does an `/etc` edit survive
# `transactional-update dup`?
#
# Rung two measured that `/etc` IS writable in the running system — `chsh` took and
# /etc/shells accepted an entry (§5, run 34819015395) — and stopped there. What it could
# not say is what happens to those writes at the next transaction, because `/etc` on a
# transactional host is a per-snapshot overlay: the transaction clones the CURRENT /etc
# into the new snapshot, the running system keeps writing to the booted one, and the boot
# merges them. SUSE documents the resulting loss case in prose — "a file changed both
# during the update and afterwards in the running system keeps only the snapshot's copy" —
# and the fleet's transactional declaration inherits it, so the driver's own /etc writes
# (the login shell, /etc/shells) ride on it. Prose is not a measurement.
#
#   nonmutable-etc-dup.sh microos --phase 1|2 [--out FILE] [--timeout SECONDS]
#
# Phase 1 plants four sentinels around ONE transaction and phase 2 — after the reboot the
# workflow performs between them — reads every one of them back:
#
#   /etc/nmh-pre-dup    written BEFORE the transaction        → the snapshot has it
#   /etc/nmh-both       written before AND rewritten after    → the documented loss case
#   /etc/nmh-post-dup   created AFTER the transaction         → does the merge keep it?
#   /etc/shells + chsh  the driver's OWN two /etc writes      → the cell rung two left open
#
# The transaction is `transactional-update dup` — the verb the cell names. A `dup` with
# nothing to update DISCARDS its snapshot, which would leave nothing to reboot into and no
# loss case to observe, so phase 1 checks the default subvolume before and after and falls
# back to `pkg install` when the dup changed nothing. Either way the report names the verb
# it actually measured: the /etc mechanism is per-TRANSACTION rather than per-verb, but a
# report that claims `dup` when it ran something else is how a cell gets closed wrong.
#
# Phase 1 and phase 2 run in different boots, so what phase 2 needs to know about phase 1
# travels in a state file on /var — never in /etc, which is the thing under test.
#
# Every command's output is captured to a file first and excerpted — never piped through
# `head`, which SIGPIPEs the probe and fakes its exit code (R1 lesson).
set -u

target="${1:?microos}"; shift
phase="" out="" dup_timeout=2700
while (($#)); do
  case "$1" in
  --phase) phase="$2"; shift 2 ;;
  --out) out="$2"; shift 2 ;;
  --timeout) dup_timeout="$2"; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$target" in
microos) ;;  # the only transactional target in the fleet; Aeon is the same tooling
*) echo "usage: $0 microos --phase 1|2 [--out FILE] [--timeout SECONDS]" >&2; exit 2 ;;
esac
[[ -n "$phase" ]] || { echo "usage: $0 microos --phase 1|2 [--out FILE] [--timeout SECONDS]" >&2; exit 2; }
[[ -n "$out" ]] || out="/root/etc-dup-$target.md"
# Phase 1 WRITES to /etc and changes root's login shell. That is the measurement on a
# throwaway guest and vandalism anywhere else, so it refuses a host with no
# transactional-update — the one-line check that keeps it off a laptop.
if [[ "$phase" == 1 ]] && ! command -v transactional-update >/dev/null 2>&1; then
  echo "refusing: no transactional-update here — phase 1 writes /etc and runs chsh, and this is not a transactional guest" >&2
  exit 3
fi
work="$(mktemp -d /tmp/etcdup.XXXXXX)"

# The sentinels, and the state that has to outlive the reboot. /var is a shared subvolume
# on this layout — /etc is not, which is the entire point of the measurement.
PRE=/etc/nmh-pre-dup
BOTH=/etc/nmh-both
POST=/etc/nmh-post-dup
STATE=/var/lib/nmh-etc-dup.state

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
# file_state <path> — one line saying whether it is there and what it holds. The sentinels
# are one line each, so the whole content IS the evidence.
file_state() {
  local f="$1"
  if [[ -e "$f" ]]; then
    say "- \`$f\`: **present** — \`$(head -c 200 "$f" | tr '\n' ' ')\`"
  else
    say "- \`$f\`: **absent**"
  fi
}
# shellcheck disable=SC2016  # the sh -c bodies expand on the guest, deliberately
snapshot_state() {
  probe "snapper list (tail)" sh -c 'snapper --no-headers list 2>/dev/null | tail -6'
  probe "booted vs default subvolume" sh -c 'echo "booted=$(findmnt -no SOURCE /)  default=$(btrfs subvolume get-default / 2>/dev/null)"'
  probe "/run/reboot-needed (PKG_APPLY_PENDING's marker)" test -e /run/reboot-needed
}
default_subvol() { btrfs subvolume get-default / 2>/dev/null; }

if [[ "$phase" == 1 ]]; then
  : >"$out"
  say "# R1 — an /etc edit across a transaction on $target ($(date -u +%Y-%m-%dT%H:%MZ))"; say ""
  say "Guest: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"') (ID=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"'), VARIANT_ID=$(sed -n 's/^VARIANT_ID=//p' /etc/os-release | tr -d '"' || true)); uid $(id -u)."
  say ""

  h2 "1. What /etc is here"
  probe "findmnt /etc" findmnt -no FSTYPE,SOURCE,OPTIONS /etc
  probe "findmnt /" findmnt -no FSTYPE,SOURCE,OPTIONS /
  probe "transactional-update --version" transactional-update --version
  snapshot_state

  h2 "2. The sentinels, before the transaction"
  printf 'written-BEFORE-the-transaction\n' >"$PRE"
  printf 'written-BEFORE-the-transaction\n' >"$BOTH"
  rm -f "$POST"
  file_state "$PRE"
  file_state "$BOTH"
  file_state "$POST"
  say "- login shell now: \`$(getent passwd root | cut -d: -f7)\`"
  say "- \`/etc/shells\` now: \`$(tr '\n' ' ' </etc/shells 2>/dev/null)\`"

  h2 "3. The transaction"
  before_default="$(default_subvol)"
  say "- default subvolume before: \`$before_default\`"
  t0=$SECONDS
  run "transactional-update dup (capped at ${dup_timeout}s)" \
    timeout "$dup_timeout" transactional-update --non-interactive dup
  dup_rc=$?
  say "- \`dup\` took **$((SECONDS - t0))s**, exit **$dup_rc**"
  after_default="$(default_subvol)"
  say "- default subvolume after: \`$after_default\`"
  verb="transactional-update dup"
  if [[ "$after_default" == "$before_default" ]]; then
    # A dup with nothing to install discards its snapshot: the default never moves, no
    # reboot is pending, and there would be no second boot to read the sentinels in. Fall
    # back to a verb that always transacts — and say which one answered.
    say ""
    say "**The dup changed nothing** (the default subvolume did not move), so it left no snapshot to boot into. Falling back to a package transaction, which is the same /etc mechanism with a different verb — the report below names THIS one, not \`dup\`."
    say ""
    t0=$SECONDS
    run "transactional-update pkg install tree (the fallback transaction)" \
      timeout "$dup_timeout" transactional-update --non-interactive pkg install tree
    say "- fallback took **$((SECONDS - t0))s**"
    after_default="$(default_subvol)"
    say "- default subvolume after the fallback: \`$after_default\`"
    verb="transactional-update pkg install tree"
  fi
  printf 'verb=%s\n' "$verb" >"$STATE"
  printf 'before_default=%s\nafter_default=%s\n' "$before_default" "$after_default" >>"$STATE"
  say "- **verb measured: \`$verb\`** (recorded in \`$STATE\`, which is on /var and so outlives the reboot; /etc is the thing under test and cannot carry this)"

  h2 "4. The /etc writes made AFTER the transaction"
  say "This is the loss case, set up deliberately: the snapshot the guest is about to boot already holds \`$BOTH\` as written in §2, and the running system now rewrites it."
  say ""
  printf 'rewritten-AFTER-the-transaction\n' >"$BOTH"
  printf 'created-AFTER-the-transaction\n' >"$POST"
  zsh_path="$(command -v zsh || echo /usr/bin/zsh)"
  grep -qxF "$zsh_path" /etc/shells 2>/dev/null || printf '%s\n' "$zsh_path" >>/etc/shells
  probe "chsh -s $zsh_path root (the driver's own /etc write)" chsh -s "$zsh_path" root
  file_state "$PRE"
  file_state "$BOTH"
  file_state "$POST"
  say "- login shell now: \`$(getent passwd root | cut -d: -f7)\`"
  say "- \`/etc/shells\` now: \`$(tr '\n' ' ' </etc/shells 2>/dev/null)\`"
  snapshot_state
  say ""
  say "- reboot next: the workflow reboots the guest and runs phase 2, which reads every line above back."
else
  verb="$(sed -n 's/^verb=//p' "$STATE" 2>/dev/null)"
  h2 "5. After the reboot — what survived \`${verb:-the transaction}\`"
  snapshot_state
  say ""
  file_state "$PRE"
  file_state "$BOTH"
  file_state "$POST"
  say "- login shell now: \`$(getent passwd root | cut -d: -f7)\`"
  say "- \`/etc/shells\` now: \`$(tr '\n' ' ' </etc/shells 2>/dev/null)\`"
  probe "tree on PATH (did the fallback transaction land?)" command -v tree

  # The comparisons are mechanical — the script may as well make them, and say which
  # answer means what. The CONCLUSION (what the fleet should declare) stays with the
  # reader, per every other report in this series.
  both_now="$(head -c 200 "$BOTH" 2>/dev/null | tr -d '\n')"
  case "$both_now" in
  *AFTER*) both_verdict="KEPT the running system's copy" ;;
  *BEFORE*) both_verdict="**LOST** — only the snapshot's copy survived (the documented case)" ;;
  *) both_verdict="file is gone entirely" ;;
  esac
  h2 "6. The four cells, read back"
  say "| Sentinel | Written | After the reboot | Reads as |"
  say "| --- | --- | --- | --- |"
  say "| \`$PRE\` | before the transaction | $([[ -e $PRE ]] && echo present || echo absent) | in the snapshot |"
  say "| \`$BOTH\` | before **and** after | \`$both_now\` | $both_verdict |"
  say "| \`$POST\` | after the transaction only | $([[ -e $POST ]] && echo present || echo absent) | whether the merge keeps a new file |"
  say "| login shell | \`chsh\` after the transaction | \`$(getent passwd root | cut -d: -f7)\` | the driver's own write |"
  say ""
  say "Verb measured: \`${verb:-unknown — $STATE is missing, so phase 1 did not reach the transaction}\`."
fi
rm -rf "$work"
echo "report: $out"
