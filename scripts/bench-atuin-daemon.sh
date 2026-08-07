#!/usr/bin/env bash
# scripts/bench-atuin-daemon.sh
# ──────────────────────────────────────────────────────────────────────────────
# Measure the ONE claim atuin daemon adoption never proved: that letting the daemon
# own the SQLite writes removes the DB-lock contention every shell and every tmux
# pane otherwise pays. core/atuin/config.toml and zsh/00-tools.zsh both assert that
# rationale on UPSTREAM's authority — it was never measured here — and this script
# is what turns it into a number.
#
# WHAT THIS COVERS, AND WHAT IT CANNOT. Proving the claim on the paths the fleet
# actually ships needs hardware: a real Fedora box for the systemd-unit path and a
# real musl box for the autostart path. This script does NOT stand in for those. What
# a plain Linux container DOES reproduce is the TOPOLOGY of the Alpine path — no
# systemd user manager, XDG_RUNTIME_DIR unset, so atuin falls back to
# ~/.local/share/atuin/atuin.sock, which is exactly the path _core_atuin_daemon_guard
# (zsh/00-tools.zsh) resolves. That is enough to measure the contention mechanism
# directly and to confirm atuin and the guard agree on the socket path — a fact the
# behavioral suite can today only assert from reading upstream's settings.rs.
#
# So a green run here NARROWS the gap; it does not close it. Every number this prints
# carries these caveats, and the summary repeats them so a figure cannot be quoted
# without them:
#   · a container, not real hardware        · glibc, not musl
#   · no systemd unit (the Fedora path)     · local disk, not a network home
#   · synthetic commands, not a real session
#
# WHAT IT MEASURES. The per-command round trip a shell hook actually pays —
# `atuin history start` then `atuin history end` — under N concurrent writers sharing
# one already-busy history DB, reported as p50/p95/p99 so the TAIL (the thing the
# daemon is adopted for) is visible and not averaged away. Three arms:
#   off              Core's shipped default: every writer opens the DB itself
#   on               daemon enabled and already running (the supervised shape)
#   autostart-first  no daemon running, autostart=true — isolates the daemon-SPAWN
#                    cost the FIRST command in a fresh shell pays, which is unique to
#                    the Alpine path and has its own open question upstream of here
#
# It runs the atuin BINARY directly rather than through Core's zsh load chain: the
# subject is atuin's write path, not shell startup. Startup cost is bench-core.sh's
# job, and the daemon is not on the startup path at all.
#
# NOT part of `make audit`, deliberately: this needs a real atuin binary and it starts
# a background daemon. The audit gate does neither. Report-only, no budget, no exit
# code to gate on — like bench-core.sh's default mode.
#
# Graceful degradation (mirrors audit-core.sh / test-core.sh / bench-core.sh): any
# missing prerequisite SKIPs and exits 0, so this is safe to call on a bare box.
#
# Usage:
#   ./scripts/bench-atuin-daemon.sh                       # the three-arm comparison
#   CORE_ATBENCH_WRITERS=16 ./scripts/bench-atuin-daemon.sh   # heavier contention
#   CORE_ATBENCH_SEED=50000 ./scripts/bench-atuin-daemon.sh   # a busier history DB
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# Shared palette + have()/skip() (this script keeps its own result-table printfs).
# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"

# Tuning is via env (see header). Parse EVERY arg and reject an unknown one (or a stray
# extra) rather than ignore it — the same fail-closed contract as the gates.
while (($#)); do
  case "$1" in
  -h | --help)
    cat <<'EOF'
usage: bench-atuin-daemon.sh [-h|--help]

Measure atuin's per-command write latency with the daemon OFF vs ON, under concurrent
writers sharing one busy history DB. Hermetic (throwaway HOME) and report-only.

Reproduces the TOPOLOGY of the Alpine/no-systemd path only — not musl, not the
systemd-unit path, not real hardware, not a network home. Results carry those caveats.

Tuning via environment:
  CORE_ATBENCH_WRITERS=<n>   concurrent writer processes (default 8 — a busy tmux)
  CORE_ATBENCH_ITERS=<n>     commands each writer runs (default 200)
  CORE_ATBENCH_SEED=<n>      history rows pre-seeded into the DB (default 20000)
  CORE_ATBENCH_REPS=<n>      fresh-shell repetitions for autostart-first (default 10)
EOF
    exit 0
    ;;
  *)
    printf 'bench-atuin-daemon.sh: unexpected argument: %s\n' "$1" >&2
    printf 'try: bench-atuin-daemon.sh --help\n' >&2
    exit 2
    ;;
  esac
done

# ── prerequisites ─────────────────────────────────────────────────────────────
# atuin is the subject; zsh times the writers with $EPOCHREALTIME (the same idiom
# bench-core.sh --profile uses); python3 seeds the DB and computes the percentiles
# (already this repo's convention for "needs real parsing/arithmetic" — bench-core.sh's
# budget gate and audit-core.sh's config gate both lean on it).
for _t in atuin zsh python3; do
  if ! have "$_t"; then
    skip "atuin daemon bench skipped ($_t not installed)"
    exit 0
  fi
done

WRITERS="${CORE_ATBENCH_WRITERS:-8}"
# 200 x 8 writers = 1600 samples per arm. Sized for the METRIC THAT MATTERS: p99 of 400
# samples is the 4th-worst observation, which moves by tens of percent between runs — a
# tail benchmark whose default cannot support a stable tail number is worse than none,
# because it invites a conclusion the data does not carry. At 1600 the p50/p95 are steady
# run-to-run; the p99 still is not, and the summary says so rather than pretending.
ITERS="${CORE_ATBENCH_ITERS:-200}"
SEED="${CORE_ATBENCH_SEED:-20000}"
REPS="${CORE_ATBENCH_REPS:-10}"

# ── sandbox ───────────────────────────────────────────────────────────────────
# Deliberately NOT ${TMPDIR:-/tmp} (which is what bench-core.sh uses): the daemon binds
# an AF_UNIX socket under $HOME, and sun_path caps at ~108 bytes. Under a long TMPDIR
# the daemon dies with "path must be shorter than SUN_LEN" (atuin-daemon/src/server.rs)
# — an obscure failure that reads as "the daemon is broken" rather than "your tmpdir is
# long". A short, fixed base plus the explicit preflight below keeps that legible.
SB="$(mktemp -d /tmp/atbench.XXXXXX)" || {
  skip "atuin daemon bench skipped (could not create a sandbox under /tmp)"
  exit 0
}
DAEMON_PID=""
cleanup() {
  [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT

# The socket path atuin will resolve with XDG_RUNTIME_DIR unset — and, by construction,
# the same expression _core_atuin_daemon_guard uses. Checked BEFORE anything is seeded so
# a doomed run costs nothing.
SOCK="$SB/.local/share/atuin/atuin.sock"
if ((${#SOCK} > 100)); then
  skip "atuin daemon bench skipped (socket path is ${#SOCK} bytes — AF_UNIX caps near 108)"
  exit 0
fi

# Run against Core's REAL config, not a synthetic one: the [daemon] block's deliberately
# UNSET enabled/autostart keys are precisely what lets the ATUIN_* env overrides below
# reach atuin at all (see the long comment in atuin/config.toml), so a bench with its own
# config would silently stop testing the thing Core actually ships.
mkdir -p "$SB/.config/atuin"
cp "$HERE/atuin/config.toml" "$SB/.config/atuin/config.toml"

# `env -u XDG_RUNTIME_DIR` on every atuin call: unset is the Alpine/no-systemd condition
# this reproduces, and it is what forces the data-dir socket fallback.
AT_ENV=(env -u XDG_RUNTIME_DIR "HOME=$SB")

printf '\n%s== atuin daemon: per-command write latency under contention ==%s\n' "$c_blu" "$c_rst"
printf '   %s writers x %s commands, %s-row seeded DB, XDG_RUNTIME_DIR unset\n' \
  "$WRITERS" "$ITERS" "$SEED"

# ── seed a BUSY history DB ────────────────────────────────────────────────────
# The claim is about lock contention, and lock hold times grow with the table — a bench
# against an empty DB would measure almost nothing. Bulk-load via `atuin import zsh`
# (~1.5 s for 20k rows); the same rows pushed through `atuin history start` one at a
# time is ~25 ms each, i.e. minutes, which would make a realistic seed impractical.
python3 - "$SB/.zsh_history" "$SEED" <<'PY'
import random, sys
# Extended-zsh-history format: ": <start>:<elapsed>;<command>". Deterministic seed so two
# runs of this script build the identical DB and their numbers stay comparable.
path, n = sys.argv[1], int(sys.argv[2])
rnd = random.Random(20250807)
verbs = ['git status', 'ls -la', 'cargo build --release', 'rg needle src/',
         'make audit', 'docker ps -a', 'kubectl get pods -n prod', 'nvim README.md']
with open(path, 'w') as fh:
    for i in range(n):
        fh.write(': %d:0;%s %d\n' % (1700000000 + i, rnd.choice(verbs), i))
PY
"${AT_ENV[@]}" "HISTFILE=$SB/.zsh_history" atuin import zsh >/dev/null 2>&1
DB="$SB/.local/share/atuin/history.db"
if [[ ! -s "$DB" ]]; then
  skip "atuin daemon bench skipped (seeding the history DB produced nothing)"
  exit 0
fi
rows="$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from history").fetchone()[0])' "$DB" 2>/dev/null)"
printf '   seeded: %s rows (%s)\n' "${rows:-?}" "$(du -h "$DB" | cut -f1)"

# Snapshot the seeded DB so every arm starts from the SAME table size. Without this the
# second arm inherits the first arm's writes and is measured against a bigger table —
# which is exactly the variable being controlled for.
cp "$DB" "$SB/seed.db"
db_reset() {
  rm -f "$DB" "$DB-wal" "$DB-shm"
  cp "$SB/seed.db" "$DB"
}

# ── the writer ────────────────────────────────────────────────────────────────
# One process per simulated pane, timing the pair a real shell hook calls. zsh, not bash:
# $EPOCHREALTIME (zsh/datetime) gives sub-ms wall time with no fork, the same way
# bench-core.sh --profile attributes per-module cost.
#
# ATUIN_SESSION is set per writer because a real shell has one (atuin init exports it) and
# distinct sessions are what distinct tmux panes look like to atuin.
cat >"$SB/writer.zsh" <<'ZSH'
zmodload zsh/datetime
typeset -F t0 t1
local out=$1 iters=$2 tag=$3 id
: >| $out
for i in {1..$iters}; do
  t0=$EPOCHREALTIME
  id=$(atuin history start -- "bench-$tag-$i --flag value")
  atuin history end --exit 0 $id >/dev/null 2>&1
  t1=$EPOCHREALTIME
  printf '%.6f\n' $(( (t1 - t0) * 1000 )) >> $out
done
ZSH

# run_writers <outdir> [extra env assignments...] — fan out $WRITERS concurrent writers
# and wait for all of them. Contention is the point, so they must overlap.
run_writers() {
  local outdir="$1"
  shift
  mkdir -p "$outdir"
  local w pids=()
  for ((w = 1; w <= WRITERS; w++)); do
    "${AT_ENV[@]}" "$@" "ATUIN_SESSION=$(printf '%032x' "$w")" \
      zsh "$SB/writer.zsh" "$outdir/$w.txt" "$ITERS" "$w" >/dev/null 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
}

daemon_start() {
  "${AT_ENV[@]}" ATUIN_DAEMON__ENABLED=true atuin daemon start >"$SB/daemon.log" 2>&1 &
  DAEMON_PID=$!
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -S "$SOCK" ]] && return 0
    sleep 0.1
  done
  return 1
}
daemon_stop() {
  [[ -n "$DAEMON_PID" ]] || return 0
  "${AT_ENV[@]}" ATUIN_DAEMON__ENABLED=true atuin daemon stop >/dev/null 2>&1
  kill "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
  rm -f "$SOCK"
}

# ── arm 1: daemon OFF (Core's shipped default) ────────────────────────────────
printf '\n%s-- arm: daemon OFF (direct SQLite writes) --%s\n' "$c_blu" "$c_rst"
db_reset
run_writers "$SB/off"

# ── arm 2: daemon ON, already running (the supervised shape) ──────────────────
printf '%s-- arm: daemon ON (writes via the unix socket) --%s\n' "$c_blu" "$c_rst"
db_reset
DAEMON_OK=0
if daemon_start; then
  DAEMON_OK=1
  # The socket-path agreement check the behavioral suite cannot make: atuin, with
  # XDG_RUNTIME_DIR unset, must bind the SAME path _core_atuin_daemon_guard probes. If
  # these ever diverge, the guard silently probes a path nothing listens on and disables
  # the daemon on every shell of a machine that correctly opted in.
  printf '   %s✓%s socket-path agreement: atuin bound %s\n' "$c_grn" "$c_rst" \
    "${SOCK/#$SB/\$HOME}"
  # The ${...} below is QUOTED PROSE — the guard's expression reproduced verbatim so the
  # two can be compared by eye. Expanding it here would print this sandbox's path twice.
  # shellcheck disable=SC2016
  printf '     %s\n' \
    '(= ${XDG_DATA_HOME:-$HOME/.local/share}/atuin/atuin.sock — the expression' \
    ' _core_atuin_daemon_guard resolves in zsh/00-tools.zsh)'
  run_writers "$SB/on" ATUIN_DAEMON__ENABLED=true
else
  printf '   %s✗%s daemon did not come up — see %s\n' "$c_red" "$c_rst" "$SB/daemon.log"
  cat "$SB/daemon.log" 2>/dev/null | sed 's/^/     /'
fi

# ── arm 3: autostart, FIRST command in a fresh shell (the Alpine-only cost) ────
# Where nothing supervises the daemon, atuin spawns it itself — so the first command
# after a cold boot pays for that spawn and every later one does not. The Alpine issue
# singled this out, and it is invisible to the two arms above (both measure steady
# state). Each rep is a genuinely cold start: daemon stopped, socket removed.
printf '%s-- arm: autostart, FIRST command in a fresh shell (%s reps) --%s\n' \
  "$c_blu" "$REPS" "$c_rst"
daemon_stop
mkdir -p "$SB/first"
: >"$SB/first/first.txt"
: >"$SB/first/steady.txt"
for ((r = 1; r <= REPS; r++)); do
  db_reset
  pkill -f 'atuin daemon' 2>/dev/null
  rm -f "$SOCK"
  # iters=6: line 1 is the cold first command (it pays the spawn), lines 2-6 are the
  # steady state immediately after — same process topology, so the delta IS the spawn.
  "${AT_ENV[@]}" ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__AUTOSTART=true \
    "ATUIN_SESSION=$(printf '%032x' "$((900 + r))")" \
    zsh "$SB/writer.zsh" "$SB/first/rep$r.txt" 6 "first$r" >/dev/null 2>&1
  head -1 "$SB/first/rep$r.txt" >>"$SB/first/first.txt" 2>/dev/null
  tail -n +2 "$SB/first/rep$r.txt" >>"$SB/first/steady.txt" 2>/dev/null
done
pkill -f 'atuin daemon' 2>/dev/null

# ── results ───────────────────────────────────────────────────────────────────
# Percentiles, not a mean: the daemon is adopted for the TAIL, and a mean hides exactly
# the lock-wait spikes that motivate it.
printf '\n%s== results (ms per command: history start + history end) ==%s\n' "$c_blu" "$c_rst"
python3 - "$SB" "$DAEMON_OK" <<'PY'
import glob, os, sys

sb, daemon_ok = sys.argv[1], sys.argv[2] == '1'

def load(pattern):
    vals = []
    for path in sorted(glob.glob(pattern)):
        with open(path) as fh:
            vals += [float(x) for x in fh.read().split() if x]
    return sorted(vals)

def pct(xs, p):
    # Nearest-rank. With n in the thousands the interpolation choice is noise, and
    # nearest-rank has the virtue of always being a value that was actually observed.
    return xs[min(len(xs) - 1, int(round(p / 100.0 * len(xs) + 0.5)) - 1)]

def row(label, xs):
    if not xs:
        print('  %-18s %s' % (label, '(no samples)'))
        return
    print('  %-18s %7d %9.2f %9.2f %9.2f %9.2f %9.2f' % (
        label, len(xs), sum(xs) / len(xs), pct(xs, 50), pct(xs, 95), pct(xs, 99), xs[-1]))

off = load(os.path.join(sb, 'off', '*.txt'))
on = load(os.path.join(sb, 'on', '*.txt')) if daemon_ok else []

print('  %-18s %7s %9s %9s %9s %9s %9s' % ('arm', 'n', 'mean', 'p50', 'p95', 'p99', 'max'))
print('  ' + '-' * 74)
row('daemon off', off)
row('daemon on', on)

if off and on:
    print()
    for name, p in (('p50', 50), ('p95', 95), ('p99', 99)):
        a, b = pct(off, p), pct(on, p)
        # Report the direction honestly. The daemon is SUPPOSED to win on the tail; if it
        # does not, that is the finding, and dressing it up would defeat the point of
        # measuring at all.
        verb = 'faster' if b < a else 'SLOWER'
        print('  %-4s  off %8.2f ms -> on %8.2f ms   (%.2fx %s with the daemon)'
              % (name, a, b, (a / b if b else 0) if b < a else (b / a if a else 0), verb))

first = load(os.path.join(sb, 'first', 'first.txt'))
steady = load(os.path.join(sb, 'first', 'steady.txt'))
if first:
    print()
    print('  autostart path — the cost unique to a machine with no service manager:')
    print('  %-18s %7s %9s %9s %9s %9s %9s' % ('', 'n', 'mean', 'p50', 'p95', 'p99', 'max'))
    row('first command', first)
    row('then steady', steady)
    if steady:
        print()
        print('  the spawn costs the first command %+.2f ms vs steady state (p50)'
              % (pct(first, 50) - pct(steady, 50)))
PY

cat <<EOF

$(printf '%s' "$c_yel")These numbers narrow the gap; they do not close it.$(printf '%s' "$c_rst") They were taken in a
container reproducing the TOPOLOGY of the Alpine path only. Not covered, and still
needing real hardware: musl (this is glibc), the systemd-unit path, a network home
(where the contention claim is strongest), and any real multi-pane session.

Run it twice before believing the tail. p50 and p95 settle quickly; p99 and max are
the last to, and a single run's p99 can flip sign. If two runs disagree on a
percentile, that percentile is noise — report it as unresolved, not as a result.
EOF
