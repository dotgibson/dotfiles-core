# scripts/test/52-atuin-autostart.sh
# the detector's AUTOSTART premise + its --json output contract
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the AUTOSTART premise of the same detector (--premise autostart) ──────────
# The other premise _core_atuin_daemon_guard rests on: under ATUIN_DAEMON__AUTOSTART the guard
# stands DOWN entirely — unhooks itself, never probes — because atuin is supposed to supervise
# its own daemon. That covers Alpine and macOS, and on those two it is the ONLY mitigation
# (dotgibson/dotfiles-core#402).
#
# WHAT THIS FRAGMENT IS REALLY FOR. The premise detector's own assertions (scripts/test/
# 51-atuin-guard.sh) are mostly about the third verdict, and so
# are these — but the conflation is sharper here, because this premise cannot be measured by
# observing: something has to be SPAWNED. "autostart did not start a daemon" and "this box
# cannot host a daemon" are the same observation, and only one of them is a fact about
# upstream. The manual-spawn control is what separates them, and case 9 below is the assertion
# that it actually does. A future simplification that deletes it would turn every CI sandbox
# problem into an issue titled "the autostart self-healing premise has MOVED".
#
# Hermetic, and genuinely so: the stub runs a REAL bindable AF_UNIX daemon (python3, exec'd so
# the process is signal-addressable), but no atuin, no systemd and no network are involved.
# ── the premise block's exclusivity lock ─────────────────────────────────────────────
# `mkdir` and not flock/pgrep, deliberately:
#   • mkdir is atomic on every POSIX filesystem and needs no util-linux — flock is absent on
#     macOS, and this suite runs on the MacBook too;
#   • a pgrep for "another test-core.sh" cannot work here at all. audit-core.sh runs
#     test-core.sh in the BACKGROUND of the same audit, concurrent with its static gates, so
#     a process-name probe would find its own sibling — or itself — and skip every audit.
# The lock is content-addressed to nothing but the machine: one holder at a time, fleet-wide.
#
# STALENESS MATTERS MORE THAN THE LOCK. A run killed with SIGKILL (or a machine that lost
# power mid-audit) leaves the directory behind, and a lock nothing can clear turns one crash
# into a permanently skipped block — which is worse than the flakiness it replaces, because
# it is silent and forever. So the holder's pid is recorded and a lock whose holder is gone
# is taken over.
_D_LOCK="${TMPDIR:-/tmp}/core-atuin-premise.lock"
_D_LOCK_HELD=0
_d_take_lock() {
  if mkdir "$_D_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" >"$_D_LOCK/pid" 2>/dev/null || true
    _D_LOCK_HELD=1
    return 0
  fi
  local _holder
  _holder="$(cat "$_D_LOCK/pid" 2>/dev/null || true)"
  # No pid file, or a pid nobody answers for → the holder died. Take it over. `kill -0`
  # answers "is there a process" without signalling it, and a pid we do not own still
  # reports EPERM rather than ESRCH, so a live foreign holder is correctly left alone.
  if [[ -z "$_holder" ]] || ! kill -0 "$_holder" 2>/dev/null; then
    rm -rf "$_D_LOCK" 2>/dev/null || true
    if mkdir "$_D_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" >"$_D_LOCK/pid" 2>/dev/null || true
      _D_LOCK_HELD=1
      return 0
    fi
  fi
  return 1
}
# Released on EXIT rather than at the end of the block: the block can leave by a `fail` path,
# and a lock held by a finished process would be reclaimed only by the staleness check above
# — correct, but it would make the very next run skip for no reason.
# Called from _core_test_cleanup, NOT from a trap of its own: a second `trap … EXIT` replaces
# the first, and the first is what removes this run's $SANDBOX.
_d_drop_lock() { ((_D_LOCK_HELD)) && rm -rf "$_D_LOCK" 2>/dev/null; return 0; }

_DVERIFY="$HERE/scripts/research/verify-atuin-guard.sh"
if [[ ! -x "$_DVERIFY" ]]; then
  skip "atuin autostart premise (scripts/research/verify-atuin-guard.sh absent or not executable)"
elif ! ((SCOPE_ATUIN)); then
  skip "atuin autostart premise (out of scope)"
elif ! have python3; then
  skip "atuin autostart premise (python3 not installed)"
elif ! _d_take_lock; then
  # EXCLUSIVITY, and a skip rather than a fail (#495). This block is hermetic with respect to
  # atuin, systemd and the network — but not with respect to another copy of ITSELF. Its
  # leak assertion reasons about what appeared under shared /tmp during a window, and its
  # fork/reap assertions about processes; neither can tell this run's residue from a
  # concurrent run's. That is not hypothetical here: the release path audits TWICE (`make
  # release` then `make tag`), this repo has carried six worktrees on one .git driven by
  # separate sessions, and a cut therefore needed two consecutive lucky greens to get out.
  # The observed shape was the tell — the same unmodified tree went `pass 261 fail 0` and
  # then `pass 260 fail 1` nine minutes later, and across three attempts the failure COUNT
  # varied (6, then 4, then 0), which a real defect does not do.
  #
  # A skip is honest; a flaky fail is not, and it teaches the operator to reach for
  # TAG_SKIP_AUDIT=1 — eroding the gate the runbook depends on, which is a far worse outcome
  # than one uncovered block.
  skip "atuin autostart premise (another test-core.sh holds the premise lock — not safely parallel)"
else
  hdr "atuin autostart self-healing premise (--premise autostart, hermetic)"
  # THIS RUN'S NAME IN SHARED /tmp. Case 17 asserts that a completed verifier run leaves no
  # sandbox behind, and the only evidence it has is what appeared under /tmp during a window.
  # /tmp has other writers — a second worktree, another agent, `make audit` in one terminal
  # while `make tag` audits in another — and an untagged glob cannot tell their sandbox from a
  # leak of ours. That is not hypothetical: it failed a `make tag` for exactly this reason.
  # Exported once, so every invocation below (case 18 runs the script from a copied repo, not
  # through _d_run) tags its trees identically and case 17's glob is exhaustive for OUR runs
  # and blind to everyone else's. The pid is the token because two LIVE processes cannot share
  # one, which is precisely the collision being defended against.
  _DTAG="t$$"
  export CORE_ATVERIFY_TAG="$_DTAG"
  _dstub="$(mktemp -d "$SANDBOX/dstub.XXXXXX")"
  # Section-local reaping. Every stub daemon writes its pid where the stub can find it, but a
  # test that fails midway can leave one behind — and unlike the script under test, this
  # harness has no EXIT trap of its own for them. The SANDBOX trap removes the files; this
  # removes the processes, which the files cannot do.
  _dreap() {
    local pf
    for pf in "$_dstub"/*.pid; do
      [[ -f "$pf" ]] || continue
      kill -9 "$(cat "$pf" 2>/dev/null)" 2>/dev/null
      rm -f "$pf"
    done
    for pf in "$_dstub"/*.forked; do
      [[ -f "$pf" ]] || continue
      while read -r _dp; do
        [[ -n "$_dp" ]] && kill -9 "$_dp" 2>/dev/null
      done <"$pf"
      rm -f "$pf"
    done
    rm -f "$_dstub"/*.spawned "$_dstub"/*.calls
    return 0
  }

  # _mkdstub <name> <mode> [version] — a fake atuin whose daemon really binds and really
  # answers, so prove_reachable's connect(2) has something to succeed against. Modes:
  #   heals                    everything works. Mirrors real 18.19.0 exactly, INCLUDING that
  #                            `daemon start` refuses over a stale inode while the autostart
  #                            CLIENT unlinks it first — measured, not assumed.
  #   never-spawns             manual works, autostart never spawns.            → moved
  #   heals-absent-not-stale   spawns on a clear path, not over a crashed daemon's leftover
  #                            inode. THE headline regression this premise exists to catch.
  #   spawns-but-discards      daemon comes up, entry never lands.              → moved
  #   manual-spawn-impossible  nothing can host a daemon here.                  → unmeasurable
  #   end-hangs                `history end` wedges on the autostart path only, so the manual
  #                            control still passes and the arms are reached — the bound then
  #                            expires on the half that carries the row.
  #   stop-unlinks-only        `daemon stop` removes the SOCKET and leaves the process alive
  #                            and holding the DB — atuin unlinks early in shutdown, so
  #                            "nothing answers" is not "the daemon exited".
  #   stop-noop                `daemon stop` accepts and does nothing — the teardown
  #                            escalation must still leave nothing running.
  #   no-daemon-subcommand     no `daemon start`.                               → unmeasurable
  #   no-stop-subcommand       no `daemon stop`.                                → unmeasurable
  #   fork-hang                autostart forks a child that NEVER binds and never exits —
  #                            invisible to every socket-based teardown path there is.
  #   manual-fork-nobind       `daemon start` forks a child that never binds and then EXITS,
  #                            so MANUAL_DAEMON_PID names a corpse and the socket never
  #                            answers — the manual control's version of fork-hang.
  #   fork-hang-end            the same, but the fork happens on `history end` rather than on
  #                            `history start`. atuin reaches its daemon through the same
  #                            autostarting path from both, so tracking only the opening half
  #                            of the pair would leave this one untracked.
  #
  # Every invocation is appended to stub-calls, which is how the "discard never spawns" and
  # "refused builds are never spawned on" assertions are made by CONSTRUCTION rather than by
  # trusting a comment.
  #
  # NOTE, as in §J3: the delimiter is unquoted so $mode and $ver interpolate, which means no
  # backticks may appear in this body and every runtime $ must be escaped.
  _mkdstub() {
    local name="$1" mode="$2" ver="${3:-18.19.0}"
    # The stub's daemon binds where a REAL daemon of the version it claims binds: under the
    # data dir before 18.20.0, under $TMPDIR/atuin-$UID from 18.20.0 (upstream #3910). A
    # version-aware verifier can only be pinned by a stub that moves with the version.
    # Literal `$`s here: the heredoc below is unquoted, and an expansion's OUTPUT is not
    # re-scanned for escapes, so these reach the stub as written.
    local sock_expr='$DH/atuin/atuin.sock' strict_sockdir=0 vmaj vmin vpat vpre=""
    # Semver, like the verifier: a pre-release of 18.20.0 (18.20.0-beta.3) predates #3910 and
    # binds at the OLD path; 18.20.0 and anything above bind at the new one.
    [[ "$ver" == *-* ]] && vpre="${ver#*-}"
    IFS=. read -r vmaj vmin vpat _ <<<"${ver%%-*}"
    # ...and from 18.20.0 the daemon REFUSES a socket directory that is not exactly 0700
    # ("incorrect permissions (expected 700, got 755)") and exits before binding — measured on
    # 18.21.0. The stub does the same, so a verifier that pre-creates the directory the way
    # a shell's umask would is caught here rather than on the next real measurement.
    if ((vmaj > 18 || (vmaj == 18 && vmin > 20) || (vmaj == 18 && vmin == 20 && ${vpat:-0} > 0))) ||
      { ((vmaj == 18 && vmin == 20)) && [[ -z "$vpre" ]]; }; then
      sock_expr='${TMPDIR:-/tmp}/atuin-$UID/atuin.sock'
      strict_sockdir=1
    fi
    cat >"$_dstub/$name" <<STUB
#!/usr/bin/env bash
MODE="$mode"
DH="\${XDG_DATA_HOME:-/nonexistent}"
# LOG and PIDF live in the STUB dir, not the sandbox: verify-atuin-guard.sh removes its
# sandbox on the way out, so a log kept in there is gone by the time an assertion reads it —
# and "grep found no spawn" would pass for a deleted file exactly as it does for a real
# absence. Interpolated at generation time; only SOCK and DB belong to the measured tree.
LOG="$_dstub/$name.calls"
SPAWNMARK="$_dstub/$name.spawned"
FORKMARK="$_dstub/$name.forked"
SOCK="$sock_expr"
STRICT_SOCKDIR="$strict_sockdir"
PIDF="$_dstub/$name.pid"
DB="\$DH/atuin/history.db"
mkdir -p "\$DH/atuin" 2>/dev/null
printf '%s\n' "\$*" >>"\$LOG" 2>/dev/null

row() {
  python3 - "\$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("create table if not exists history (id text, duration integer)")
c.execute("insert into history values ('x',-1)")
c.commit(); c.close()
PY
}

# EXEC, not a child: MANUAL_DAEMON_PID and socket_owner_pid both have to be able to signal
# this process, and a bash wrapper holding a python child would swallow the SIGKILL the
# teardown escalation depends on. The daemon then setsid()s below, so it leaves our process
# group the way a real one does. Binds in the FOREGROUND so a failure is immediate — and
# refuses over an existing inode, which is what 18.19.0 really does:
#   Error: Address already in use (os error 48)  crates/atuin-daemon/src/server.rs:72
serve_fg() {
  exec python3 - "\$SOCK" "\$PIDF" "\$MODE" "\$DB" "\$STRICT_SOCKDIR" <<'PY'
import socket, sys, os, sqlite3, stat
sock, pidf, mode, db, strict = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
# ONLY a daemon start creates the socket directory — never --version or a daemon-off write —
# and it creates it 0700, as the real daemon does. A directory that already exists was made by
# the caller, and from 18.20.0 the real daemon refuses it unless it is exactly 0700; the stub
# does the same, so a verifier that prepared it with the umask is caught here.
sockdir = os.path.dirname(sock)
if not os.path.isdir(sockdir):
    os.makedirs(sockdir)
    os.chmod(sockdir, 0o700)
elif strict == "1":
    perm = stat.S_IMODE(os.stat(sockdir).st_mode)
    if perm != 0o700:
        sys.stderr.write("Error: %s has incorrect permissions (expected 700, got %o)\n" % (sockdir, perm))
        sys.exit(1)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.bind(sock)
except OSError:
    sys.stderr.write("Error: Address already in use (os error 48)\n")
    sys.exit(98)
s.listen(8)
# DETACH, exactly as a real atuin daemon does. Measured on 18.19.0: the arm ran in process
# group 88291 and the daemon it spawned landed in 88299. A stub that stayed in the group
# would be reachable by the group reap and every teardown assertion here would pass for a
# reason that does not apply to atuin -- the stub has to be at least as hard to kill as the
# thing it stands in for.
try:
    os.setsid()
except OSError:
    pass
open(pidf, "w").write(str(os.getpid()))
s.settimeout(0.3)
while True:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        # stop-unlinks-only: once the socket is gone this daemon KEEPS COMMITTING. That is
        # what makes "nothing answers" different from "the daemon exited" — and it is only
        # observable because the extra rows land in arms that come after the fake stop.
        if mode == "stop-unlinks-only" and not os.path.exists(sock):
            try:
                con = sqlite3.connect(db, timeout=5)
                con.execute("insert into history values ('zombie',-1)")
                con.commit()
                con.close()
            except Exception:
                pass
    except Exception:
        pass
PY
}

daemon_up() {
  [[ -S "\$SOCK" ]] || return 1
  python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(2)
try: s.connect('\$SOCK')
except OSError: sys.exit(1)
s.close()" 2>/dev/null
}

# What the autostart CLIENT does. stderr is silenced but STDOUT IS DELIBERATELY INHERITED:
# a spawned daemon holding the caller's fd 1 open is exactly the shape that used to hang
# run_one's \$( ) capture forever, so every autostart arm here regression-tests that fix
# instead of merely trusting it.
spawn_bg() {
  # The marker is the assertion's real subject. A call-log check only ever proved the CLI
  # spelling "daemon start" was not used -- and in this stub, as in atuin, the autostart
  # spawn happens INSIDE "history start", so a regression that turned autostart on in the
  # default premise would fork a daemon, log no "daemon start", and pass. Recorded outside
  # the sandbox, which the script deletes before any assertion runs. (No backticks here: the
  # heredoc delimiter is unquoted, so one would be command substitution at generation time.)
  printf 'spawn\n' >>"\$SPAWNMARK" 2>/dev/null
  ( serve_fg 2>/dev/null ) &
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    daemon_up && return 0
    sleep 0.05
  done
  return 1
}

case "\$1" in
--version) echo "atuin $ver"; exit 0 ;;
daemon)
  case "\$2" in
  start)
    if [[ "\$3" == --help ]]; then
      [[ "\$MODE" == no-daemon-subcommand ]] && exit 1
      echo "usage: atuin daemon start"; exit 0
    fi
    [[ "\$MODE" == manual-spawn-impossible ]] && { echo "Error: no" >&2; exit 1; }
    if [[ "\$MODE" == manual-fork-nobind ]]; then
      # Forks a child that never binds, then EXITS 0. The pid the caller recorded is dead a
      # moment later, nothing ever answers the socket, and no inode exists to resolve an
      # owner from -- only the process group knows about the survivor.
      sleep 300 &
      printf '%s\n' "\$!" >>"\$FORKMARK" 2>/dev/null
      exit 0
    fi
    serve_fg
    ;;
  stop)
    if [[ "\$3" == --help ]]; then
      [[ "\$MODE" == no-stop-subcommand ]] && exit 1
      echo "usage: atuin daemon stop"; exit 0
    fi
    # stop-noop ACCEPTS and does nothing, which is the realistic bad shape: a stop whose exit
    # status says yes while the process lives on. Proof-not-exit-status is why it is caught.
    [[ "\$MODE" == stop-noop ]] && exit 0
    # Unlink the socket and leave the daemon running -- it then starts committing rows. A
    # socket-only stop proof accepts this as stopped, after which every later arm measures
    # against a daemon it did not start and whose writes it will attribute to upstream.
    [[ "\$MODE" == stop-unlinks-only ]] && { rm -f "\$SOCK"; exit 0; }
    [[ -f "\$PIDF" ]] && kill "\$(cat "\$PIDF")" 2>/dev/null
    rm -f "\$SOCK" "\$PIDF"
    exit 0
    ;;
  esac
  exit 1
  ;;
history)
  case "\$2" in
  start)
    if [[ "\${ATUIN_DAEMON__ENABLED:-false}" != true ]]; then
      row   # daemon OFF: the row lands on start, and history end updates it in place
      echo "0192deadbeefcafe0000000000000000"; exit 0
    fi
    if [[ "\${ATUIN_DAEMON__AUTOSTART:-false}" == true ]] && ! daemon_up; then
      case "\$MODE" in
      never-spawns) : ;;
      fork-hang)
        # Forks a child that never binds and never exits. This is the shape the socket-based
        # teardown structurally cannot see: nothing ever answers, so the stop proof succeeds
        # instantly and socket_owner_pid has no inode to resolve a pid from. Only the arm's
        # process group knows about it. The pid is recorded so the test can check it died.
        sleep 300 &
        printf '%s\n' "\$!" >>"\$FORKMARK" 2>/dev/null
        ;;
      heals-absent-not-stale)
        # Spawns only onto a CLEAR path. A crashed daemon's leftover inode defeats it — the
        # silent net-loss on Alpine and macOS, and invisible to an absent-socket-only test.
        [[ -e "\$SOCK" ]] || spawn_bg
        ;;
      *)
        # heals and fork-hang-end both take this path: a real daemon must come up, or the arm
        # never gets a well-formed id and "history end" is never called.
        rm -f "\$SOCK"   # the real client clears a stale inode before spawning
        spawn_bg
        ;;
      esac
    fi
    echo "0192deadbeefcafe0000000000000000"; exit 0
    ;;
  end)
    # end-hangs: wedge the CLOSING half only, and only on the autostart path. Keyed that way
    # so the manual-spawn control (which does not set AUTOSTART) still passes and the run
    # actually reaches the arms, where the bound is supposed to fire.
    if [[ "\$MODE" == end-hangs && "\${ATUIN_DAEMON__AUTOSTART:-false}" == true ]]; then
      sleep 300
    fi
    # fork-hang-end: the closing half of the pair forks its own never-binding child. Recorded
    # in the same marker file, so one assertion covers however many halves forked.
    if [[ "\$MODE" == fork-hang-end && "\${ATUIN_DAEMON__AUTOSTART:-false}" == true ]]; then
      sleep 300 &
      printf '%s\n' "\$!" >>"\$FORKMARK" 2>/dev/null
    fi
    # With a daemon serving, the row lands on END, not on start. Measured on 18.19.0.
    if [[ "\${ATUIN_DAEMON__ENABLED:-false}" == true ]] && daemon_up; then
      # Keyed on AUTOSTART, not on the mode alone: the manual-spawn control writes through a
      # hand-started daemon, and if THAT is broken too the run is honestly unmeasurable rather
      # than a finding. This models the narrower, real shape — the daemon works, but entries
      # issued down the autostart path are dropped.
      if [[ "\$MODE" == spawns-but-discards && "\${ATUIN_DAEMON__AUTOSTART:-false}" == true ]]; then :; else row; fi
    fi
    exit 0
    ;;
  esac
  exit 1
  ;;
esac
exit 1
STUB
    chmod +x "$_dstub/$name"
  }

  # POLL very low on purpose, and only here. Every stub writes its row, binds its socket and
  # unlinks it SYNCHRONOUSLY before the call returns, so a positive case is satisfied on the
  # first tick and the bound is pure waiting for the cases that are SUPPOSED never to write —
  # of which there are several, four arms each. 3 ticks is therefore not a flakiness risk
  # here, and it is the difference between J4 costing seconds and costing minutes. Lowering it
  # against a REAL atuin manufactures findings; see the knob's own comment in
  # verify-atuin-guard.sh.
  # …AND THAT ARGUMENT DOES NOT COVER THE APPARATUS GATE, which is the one case here running a
  # stub that is supposed to SUCCEED at everything. For it the bound is not idle waiting, it is
  # a deadline: the manual-spawn control has 3 ticks — 300ms — for a spawned daemon to bind and
  # answer, and a loaded runner misses that. The verifier then declines, correctly and by
  # design, and the gate reads the decline as a defect in the detector. That reddened an audit
  # leg for an unrelated change.
  #
  # So the KNOWN-GOOD run gets a deadline with real headroom while every negative case keeps
  # the tight one. Measured on this repo's own fixture, all four arms holding: POLL=3 → 10.9s,
  # POLL=30 → 14.0s, POLL=100 → 23.4s. Three seconds of headroom for three seconds of wall
  # clock, once per suite, and 10x the margin on the only bound that has ever flaked here.
  # (Not free, because --premise autostart also spends the bound PROVING unreachability, which
  # is waiting that no amount of promptness shortens — hence 30 rather than 100.)
  _DPOLL=3
  _DPOLL_GATE=30
  # Set by the gate around its own calls; empty everywhere else. Declared here so `set -u`
  # holds and so the override is visible next to the constants it overrides.
  _dpoll=""
  _d_run() { # _d_run <stub> [extra args...] → sets _dout (stdout) / _dstderr / _drc
    local stub="$1"
    shift
    # STDOUT AND STDERR KEPT SEPARATE, unlike §J3's helper. Every case here passes --json and
    # the JSON is on stdout, so merging the two means any stray line — a busybox timeout
    # notice, a shell job-control message — lands inside the text being parsed and the
    # assertion fails for a reason that has nothing to do with the behaviour under test. That
    # is exactly how this first went red on Alpine: the exit code was a correct 3 and the
    # verdict came back empty, because something musl-side wrote to stderr and json.load then
    # choked on it. stderr is still captured, so a genuine crash still reaches the message.
    _dstderr=""
    _dout="$(CORE_COLOR=never CORE_ATVERIFY_POLL="${_dpoll:-$_DPOLL}" "$_DVERIFY" --atuin "$_dstub/$stub" "$@" 2>"$SANDBOX/derr.txt")"
    _drc=$?
    _dstderr="$(head -c 400 "$SANDBOX/derr.txt" 2>/dev/null | tr '\n' ' ')"
  }
  _d_get() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"$2\"])" 2>/dev/null; }
  # _d_calls <stub> — every invocation that stub received. Read from the stub dir, which
  # outlives the sandbox, so "no spawn was attempted" is a real absence rather than a
  # deleted file.
  _d_calls() { cat "$_dstub/$1.calls" 2>/dev/null; }
  # Did this stub ever FORK a daemon, by any route? Survives the sandbox, and unlike the call
  # log it is about the thing that matters rather than the command that usually causes it.
  _d_spawned() { [[ -s "$_dstub/$1.spawned" ]]; }
  # _d_forked_wait <stub> — wait, briefly and boundedly, for the stub's fork log to appear.
  #
  # The stub writes .forked from the CHILD it just forked, so "the file is not there yet" and
  # "the stub never forked" are the same observation at the wrong moment. Reading immediately
  # made that race decide the verdict, and the failure it produced named the wrong thing —
  # "the stub never forked, so the reaping assertion proved nothing" — which is how #495 came
  # to be filed as a flaky test rather than a race. ~2s at 50ms is far longer than a fork
  # needs and far shorter than the run it guards. Returns non-zero if it never appears, which
  # is then a real finding rather than a timing artefact.
  _d_forked_wait() {
    local _i
    for _i in $(seq 1 40); do
      [[ -s "$_dstub/$1.forked" ]] && return 0
      sleep 0.05
    done
    return 1
  }
  # _d_forks_alive <stub> — how many of the children that stub forked are STILL running.
  #
  # The `-s` guard is not defensive padding; without it this returned a SILENT ZERO. Bash
  # applies redirections left to right, so `<"$_dstub/$1.forked"` is opened BEFORE
  # `2>/dev/null` takes effect — a missing file therefore printed a raw
  # "No such file or directory" on the inherited stderr AND still ran the printf, handing the
  # caller a 0 indistinguishable from a genuinely clean reap. Its sibling _d_spawned just
  # above has always checked -s; this one was the outlier (#495).
  _d_forks_alive() {
    local n=0 pid
    [[ -s "$_dstub/$1.forked" ]] || { printf '0'; return 0; }
    while read -r pid; do
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && n=$((n + 1))
    done <"$_dstub/$1.forked" 2>/dev/null
    printf '%s' "$n"
  }

  # ── apparatus-free: the flag contract, assertable with no daemon anywhere ──
  # 1. An unknown premise is a USAGE error, not a measurement. The --color lesson applied to
  #    the one flag that selects which upstream fact is being asserted: a typo that fell
  #    through would measure the default premise and report it under the caller's title.
  CORE_COLOR=never "$_DVERIFY" --premise banana >/dev/null 2>&1
  _drc=$?
  CORE_COLOR=never "$_DVERIFY" --premise >/dev/null 2>&1
  _drc2=$?
  if ((_drc == 2 && _drc2 == 2)); then
    pass "atuin autostart: an unknown --premise and a --premise with no value both exit 2 (usage, not a finding)"
  else
    fail "atuin autostart: --premise must exit 2 on a bad value (got rc$_drc) and on a missing one (got rc$_drc2)"
  fi

  # 1b. THE TAG CONTRACT, asserted where it is cheapest — no daemon, no sandbox, no atuin.
  #     CORE_ATVERIFY_TAG is a PUBLIC knob (it is in --help), and case 17 only ever exports a
  #     generated valid one, so every way a caller can get it wrong was unasserted: the value
  #     becomes a path component under /tmp, and it is the only thing standing between the
  #     leak check and a glob that silently matches nothing.
  #
  #     THE EMPTY CASE IS THE IMPORTANT ONE, and it is why the script reads `${…-$$}` rather
  #     than the `${…:-…}` its two neighbouring knobs use. An empty tag is not a request for
  #     the default — it is a caller whose tag expression came out empty — and accepting it
  #     would put the sandbox under the pid while the caller globbed `/tmp/atverify..*`,
  #     matching nothing and greening the leak assertion forever. That is precisely the
  #     vacuous pass case 17's self-check exists to catch, arriving by a different door, so
  #     it is pinned here rather than left to the `-` vs `:-` being noticed in review.
  #
  #     Rejection must also happen BEFORE anything is measured, which is read off the stub's
  #     own call log rather than assumed: a tag validated late would already have spawned.
  _mkdstub atuin-tagck heals
  _dbad=0
  _dtagwhy=""
  # 17 chars, one past the cap — not 16, which is the accepted boundary asserted just below.
  #
  # THE TWO NON-ASCII CASES assert the ASCII half of the contract, and are the ones that would
  # notice if the script's LC_ALL=C pin were removed on a userland where it matters. A range
  # like [A-Z] is defined by COLLATION, not codepoint, so a locale may admit letters this
  # contract does not mean to allow; `ábcdefghij123456` is the same fault one step downstream —
  # sixteen CHARACTERS but seventeen BYTES, so a character-counting cap would pass a path
  # component longer than promised, against an AF_UNIX budget measured in bytes. Downstream,
  # not separate: every character in [A-Za-z0-9_-] is single-byte ASCII, so 16 chars can only
  # exceed 16 bytes once collation has already leaked a non-ASCII one in.
  #
  # THE PROBE ASKS THE ONLY QUESTION THAT MATTERS: is there a locale here under which the
  # UNPINNED pattern actually accepts the sample? An earlier version probed for multibyte
  # DECODING (`${#é}` is 1, not 2) and picked the first hit — which proved nothing, because a
  # locale can decode multibyte and still collate `á` outside [A-Za-z]. C.UTF-8 does exactly
  # that and was probed first, so the case passed identically with and without the pin: a
  # regression test that could not fail. Selecting on the real predicate means that where a
  # locale IS found the case genuinely fails if the pin is removed, and where none is found the
  # message SAYS the pin is unexercised here rather than implying coverage this box cannot give.
  # ENUMERATED, not guessed, wherever the box can answer. A hand-written candidate list is its
  # own way of reporting the wrong coverage: the locale that misbehaves here need not be among
  # seven names someone happened to think of — this machine offers 84 UTF-8 locales, not 7.
  # `locale -a` is the box's own answer; musl ships no such command, so the named candidates
  # survive as the fallback and the result line says which source it actually used.
  _dlocs="$(locale -a 2>/dev/null | grep -iE 'utf-?8' || true)"
  _dlocsrc=installed
  if [[ -z "$_dlocs" ]]; then
    _dlocsrc=candidate
    _dlocs="$(printf '%s\n' C.UTF-8 en_US.UTF-8 en_US.utf8 UTF-8 de_DE.UTF-8 cs_CZ.UTF-8 hu_HU.UTF-8)"
  fi
  _dutf8=""
  _dlocn=0
  while read -r _dl; do
    [[ -n "$_dl" ]] || continue
    _dlocn=$((_dlocn + 1))
    if LC_ALL="$_dl" "$BASH" -c '[[ "$1" =~ ^[A-Za-z0-9_-]{1,16}$ ]]' _ 'tág' 2>/dev/null; then
      _dutf8="$_dl"
      break
    fi
  done <<<"$_dlocs"
  # Said out loud in the result line, because "the pin is exercised here" and "no locale here
  # can exercise it" are different facts and a reader must not have to guess which one a green
  # tick meant. This is the same discipline as case 17's self-check, applied to coverage.
  if [[ -n "$_dutf8" ]]; then
    _dcov=" — LC_ALL=C pin EXERCISED under $_dutf8, which accepts the sample unpinned"
  else
    _dcov=" — none of $_dlocn $_dlocsrc UTF-8 locales accepts the sample unpinned, so the LC_ALL=C pin is unexercised on this box (contract only)"
  fi
  for _dcase in "bad/tag" "up..dir" "abcdefghij1234567" "" "tag with space" "tág" "ábcdefghij123456"; do
    # `:-C`, not a bare "$_dutf8". An EMPTY LC_ALL is not "no locale" — it falls through to the
    # caller's LC_COLLATE/LANG, which is an unprobed locale that could be the very one that
    # accepts the sample. The run would then exercise the pin while the line above reported it
    # unexercised: the report would be wrong in the one direction a coverage claim must not be.
    LC_ALL="${_dutf8:-C}" CORE_COLOR=never CORE_ATVERIFY_TAG="$_dcase" "$_DVERIFY" \
      --premise autostart --atuin "$_dstub/atuin-tagck" >/dev/null 2>&1
    _drc=$?
    if ((_drc != 2)); then
      _dbad=1
      _dtagwhy="$_dtagwhy '${_dcase:-<empty>}'→rc$_drc"
    fi
  done
  # Accepted, by contrast: the 16-char boundary and an ABSENT tag both get past validation and
  # fail later for the missing binary (rc 3), which is what tells acceptance from rejection
  # without measuring anything. The absent case is the standalone contract — it is what
  # `make verify-atuin-guard` and atuin-guard-verify.yml rely on, and the section exports a
  # tag, so it is unset in a SUBSHELL rather than for the rest of the run.
  CORE_COLOR=never CORE_ATVERIFY_TAG="sixteenchars0123" "$_DVERIFY" \
    --premise autostart --atuin "$_dstub/nonexistent" >/dev/null 2>&1
  _drc=$?
  if ((_drc != 3)); then
    _dbad=1
    _dtagwhy="$_dtagwhy 16-char→rc$_drc"
  fi
  (
    unset CORE_ATVERIFY_TAG
    CORE_COLOR=never "$_DVERIFY" --premise autostart \
      --atuin "$_dstub/nonexistent" >/dev/null 2>&1
  )
  _drc=$?
  if ((_drc != 3)); then
    _dbad=1
    _dtagwhy="$_dtagwhy unset→rc$_drc"
  fi
  [[ -z "$(_d_calls atuin-tagck)" ]] || {
    _dbad=1
    _dtagwhy="$_dtagwhy (a rejected tag still invoked atuin)"
  }
  _dreap
  if ((_dbad == 0)); then
    pass "atuin autostart: a tag that is empty, overlong, non-ASCII, or not [A-Za-z0-9_-] exits 2 before measuring, while the 16-char boundary and an ABSENT tag are accepted$_dcov"
  else
    fail "atuin autostart: the CORE_ATVERIFY_TAG contract is not enforced —$_dtagwhy; an accepted bad tag globs nothing and greens the leak check vacuously"
  fi

  # 2. The premise travels in the JSON. The workflow's two legs differ by ONE flag and both
  #    file issues under different titles, so it asserts this field rather than trusting the
  #    flag reached the script — this is the assertion that makes that check meaningful.
  _d_run nonexistent-stub --premise autostart --json
  if [[ "$(_d_get "$_dout" verdict)" == unmeasurable ]] && ((_drc == 3)) &&
    [[ "$(_d_get "$_dout" premise)" == autostart ]]; then
    pass "atuin autostart: --premise autostart is carried in --json, and a missing atuin is still rc 3"
  else
    fail "atuin autostart: expected unmeasurable/rc3/premise=autostart, got $(_d_get "$_dout" verdict)/rc$_drc/$(_d_get "$_dout" premise)"
  fi

  # 3. THE DEFAULT TARGET MUST STAY LAPTOP-SAFE. `make verify-atuin-guard` starts no
  #    background process today, and adding one silently would change what that target costs
  #    on a developer's machine. Asserted by CONSTRUCTION — the stub logs every invocation it
  #    receives, so this reads the log rather than believing a comment.
  _mkdstub atuin-heals heals
  _d_run atuin-heals --json >/dev/null 2>&1
  if _d_calls atuin-heals | grep -qE '^daemon start( |$)' || _d_spawned atuin-heals; then
    fail "atuin autostart: --premise discard started a daemon — the default target must spawn nothing, by any route"
  else
    pass "atuin autostart: --premise discard forks no daemon at all (not via 'daemon start', not via autostart inside 'history start')"
  fi
  _dreap

  # ── APPARATUS SELF-CHECK — and deliberately NOT through the subject under test.
  #    The obvious form of this gate ("run the known-good stub; skip everything if it does not
  #    say holds") uses the code under test as its own apparatus check, so ANY regression that
  #    made the healthy stub report `moved` or `unmeasurable` would skip every assertion below
  #    and leave the audit GREEN — the regression suite going blind to exactly the failures it
  #    exists to catch. So the box is proven FIRST, with python3 alone: bind an AF_UNIX socket
  #    under /tmp and connect to it, which is the only capability these cases need that an
  #    ordinary box might lack. Only if THAT fails is a skip honest.
  if ! python3 - "/tmp/j4probe.$$.sock" <<'J4PROBE' 2>/dev/null
import socket, sys, os
p = sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(p)
    s.listen(1)
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(2)
    c.connect(p)
    c.close()
    s.close()
    os.unlink(p)
except Exception:
    sys.exit(1)
J4PROBE
  then
    rm -f "/tmp/j4probe.$$.sock"
    skip "atuin autostart: measurement assertions (this box cannot bind and connect an AF_UNIX socket under /tmp)"
  else
    rm -f "/tmp/j4probe.$$.sock"
    # The apparatus is established WITHOUT the subject's help, so a known-good stub that does
    # not report `holds` is a regression in the detector — a FAILURE, never a skip. This gate is
    # deliberately NOT §J3's blanket "skip unless holds": there, no independent probe exists, so
    # declining is all it can honestly do; here one does, and the stricter stance is the point.
    #
    # THE STRICTNESS IS KEPT AND THE DEADLINE IS FIXED INSTEAD, which is the whole correction.
    # This arm used to fail on ANY non-`holds`, including `unmeasurable` — the verifier's
    # fail-closed answer when the manual-spawn control's daemon did not answer inside 300ms. On
    # a loaded runner that is a property of the BOX, and reporting it as a defect in the
    # detector is a false finding of exactly the kind §J4 exists to prevent.
    #
    # The tempting repair — skip on `unmeasurable` — is wrong, and the reason is worth keeping:
    # that verdict covers a family of causes, and most are DETERMINISTIC AND ARE THE DETECTOR
    # (a renamed or duplicated anchor, control-arm row accounting that no longer matches, and
    # `internal: no verdict was reached (this is a bug in verify-atuin-guard.sh)`). Skipping on
    # it would silence the sixteen assertions below while the subject announces its own bug —
    # the blindness the block comment above refuses to allow, arriving by a quieter door. No
    # amount of retrying separates those from slowness either, since every one of them repeats.
    #
    # So nothing here skips. The deadline is simply made generous enough that missing it is not
    # ordinary: $_DPOLL_GATE ticks instead of $_DPOLL, and one retry, so a transient stall has
    # to land twice inside a 10x-wider window to be seen at all. What remains is a gate that
    # cannot go quiet — every verdict other than `holds` still reddens it — bought with about
    # three seconds of wall clock, once.
    #
    # The three failures are told apart because they mean different things to whoever reads the
    # line: `moved` is the verifier miscategorising correct behaviour, `unmeasurable` is it
    # declining where it should measure (and carries its own reason, which names the cause), and
    # no parseable verdict at all is the apparatus failing to report — the Alpine shape, where a
    # stray stderr line merged into the JSON, so that one carries stderr.
    _dpoll="$_DPOLL_GATE"
    _d_run atuin-heals --premise autostart --json
    _dapp="$(_d_get "$_dout" verdict)"
    _dappwhy="$(_d_get "$_dout" reason)"
    _dreap
    if [[ "$_dapp" == unmeasurable ]]; then
      _d_run atuin-heals --premise autostart --json
      _dapp="$(_d_get "$_dout" verdict)"
      _dappwhy="$(_d_get "$_dout" reason)"
      _dreap
    fi
    _dpoll=""
    if [[ "$_dapp" == unmeasurable ]]; then
      fail "atuin autostart: the known-good stub reported unmeasurable TWICE at a ${_DPOLL_GATE}-tick bound — this box can bind AF_UNIX sockets, so verify-atuin-guard.sh is declining where it should measure: ${_dappwhy:-no reason parsed}"
    elif [[ "$_dapp" == moved ]]; then
      fail "atuin autostart: this box can bind AF_UNIX sockets, yet the known-good stub reported moved rather than holds — that is a regression in verify-atuin-guard.sh, not an unusable apparatus: ${_dappwhy:-no reason parsed}"
    elif [[ "$_dapp" != holds ]]; then
      fail "atuin autostart: the known-good stub produced no parseable verdict (rc$_drc) — the apparatus failed to report rather than measuring${_dstderr:+ (stderr: $_dstderr)}"
    else

    # 4. The happy path, and the shape real 18.19.0 has: all four arms spawn and land a row.
    if ((_drc == 0)) && [[ "$_dout" == *'"spawned":"no"'* ]]; then
      fail "atuin autostart: a healing atuin reported an arm that did not spawn"
    elif ((_drc == 0)); then
      pass "atuin autostart: an atuin that self-heals its daemon → holds (rc 0), every arm spawned"
    else
      fail "atuin autostart: expected holds/rc0 for a healing atuin, got rc$_drc"
    fi

    # 4b. THE SOCKET MOVED IN 18.20.0 (upstream #3910): the default is $TMPDIR/atuin-$UID/
    #     atuin.sock now, and a verifier still waiting on the data-dir path reports a healthy
    #     daemon as `unmeasurable` ("never answered") — which is what the first measurement
    #     past the anchor did, on 18.21.0 (#826). Same stub, claiming 18.20.0, binding where a
    #     real 18.20.0 does; same one-retry the known-good stub gets at the low bound.
    _mkdstub atuin-heals-1820 heals 18.20.0
    _dpoll="$_DPOLL_GATE"
    _d_run atuin-heals-1820 --premise autostart --json
    _dapp="$(_d_get "$_dout" verdict)"
    _dappwhy="$(_d_get "$_dout" reason)"
    _dreap
    if [[ "$_dapp" == unmeasurable ]]; then
      _d_run atuin-heals-1820 --premise autostart --json
      _dapp="$(_d_get "$_dout" verdict)"
      _dappwhy="$(_d_get "$_dout" reason)"
      _dreap
    fi
    _dpoll=""
    if [[ "$_dapp" == holds ]] && ((_drc == 0)); then
      pass "atuin autostart: a healing 18.20.0 (socket under \$TMPDIR/atuin-\$UID, upstream #3910) → holds — the verifier waits where that version binds"
    else
      fail "atuin autostart: a healing 18.20.0 binding under \$TMPDIR/atuin-\$UID reported ${_dapp:-no verdict} (rc$_drc) — the verifier is waiting on the pre-18.20 data-dir socket, or made the socket directory with a mode the daemon refuses: ${_dappwhy:-no reason parsed}"
    fi

    # 4c. THE BOUNDARY ITSELF. 18.20.0-beta.3 predates #3910 and binds in the data dir, and its
    #     numeric triple is 18.20.0 — a verifier that drops the pre-release suffix sends it to
    #     the new path and reports a healthy binary as unmeasurable. Semver's rule (a
    #     pre-release sorts below its release) is what both sides apply.
    _mkdstub atuin-heals-1820b3 heals 18.20.0-beta.3
    _dpoll="$_DPOLL_GATE"
    _d_run atuin-heals-1820b3 --premise autostart --json
    _dapp="$(_d_get "$_dout" verdict)"
    _dappwhy="$(_d_get "$_dout" reason)"
    _dreap
    if [[ "$_dapp" == unmeasurable ]]; then
      _d_run atuin-heals-1820b3 --premise autostart --json
      _dapp="$(_d_get "$_dout" verdict)"
      _dappwhy="$(_d_get "$_dout" reason)"
      _dreap
    fi
    _dpoll=""
    if [[ "$_dapp" == holds ]] && ((_drc == 0)); then
      pass "atuin autostart: a healing 18.20.0-beta.3 (pre-#3910, data-dir socket) → holds — the pre-release suffix keeps it on the old path"
    else
      fail "atuin autostart: a healing 18.20.0-beta.3 binding in the data dir reported ${_dapp:-no verdict} (rc$_drc) — the verifier dropped the pre-release suffix and waited at the 18.20.0 path: ${_dappwhy:-no reason parsed}"
    fi

    # 5. Expected delta is 1 here and 0 under discard, on arms with IDENTICAL names. Without
    #    expected_delta in the JSON a reader has no way to tell a healthy autostart arm from a
    #    discard arm that just broke.
    if [[ "$_dout" == *'"expected_delta":1'* ]] && [[ "$_dout" != *'"expected_delta":0'* ]]; then
      pass "atuin autostart: every arm records expected_delta 1, so an identically-named discard arm cannot be misread"
    else
      fail "atuin autostart: arms must carry expected_delta 1 under this premise"
    fi

    # 6. An atuin that never spawns is a FINDING, and the reason must say so in the words the
    #    remedy depends on — "no daemon became reachable", not merely "the row count changed".
    _mkdstub atuin-nospawn never-spawns
    _d_run atuin-nospawn --premise autostart --json
    _dreap
    if [[ "$(_d_get "$_dout" verdict)" == moved ]] && ((_drc == 1)) &&
      [[ "$_dout" == *"no daemon became reachable"* ]]; then
      pass "atuin autostart: an atuin that never spawns a daemon → moved (rc 1), naming the absent spawn"
    else
      fail "atuin autostart: expected moved/rc1 naming the absent spawn, got $(_d_get "$_dout" verdict)/rc$_drc"
    fi

    # 7. THE HEADLINE SHAPE. Spawns onto a clear path, not over a crashed daemon's leftover
    #    inode. Every `atuin history start` is a fresh process, so this is what
    #    "fire-and-forget" can actually mean — and an absent-socket-only detector would call
    #    it healthy while Alpine and macOS quietly lost their net.
    _mkdstub atuin-halfheal heals-absent-not-stale
    _d_run atuin-halfheal --premise autostart --json
    _dreap
    if [[ "$(_d_get "$_dout" verdict)" == moved ]] && ((_drc == 1)) &&
      [[ "$_dout" == *'"stale_hook":{"rc":0,"delta":0'* ]] &&
      [[ "$_dout" == *'"absent_hook":{"rc":0,"delta":1'* ]]; then
      pass "atuin autostart: spawning on an absent socket but NOT over a stale one is moved — the stale arm is why it is measured"
    else
      fail "atuin autostart: half-healing must be moved with stale arms failing and absent arms passing, got $(_d_get "$_dout" verdict)/rc$_drc"
    fi

    # 8. A daemon that comes up and drops the entry is a DIFFERENT finding from one that never
    #    came up, and both leave delta 0 — which is exactly why `spawned` is recorded per arm
    #    rather than inferred from the row count.
    _mkdstub atuin-nowrite spawns-but-discards
    _d_run atuin-nowrite --premise autostart --json
    _dreap
    if [[ "$(_d_get "$_dout" verdict)" == moved ]] && ((_drc == 1)) &&
      [[ "$_dout" == *'"spawned":"yes"'* ]] && [[ "$_dout" == *"did not land"* ]]; then
      pass "atuin autostart: a daemon that spawns but drops the entry is moved, and is distinguished from one that never spawned"
    else
      fail "atuin autostart: spawn-but-discard must be moved naming the unlanded entry, got $(_d_get "$_dout" verdict)/rc$_drc"
    fi

    # 9. THE LOAD-BEARING ONE, and §J3 case 5's counterpart. A box that cannot host a daemon
    #    AT ALL must be `unmeasurable` — never a finding about upstream. This is the whole
    #    reason the manual-spawn control exists, and the assertion a future simplification
    #    that deletes it would trip.
    _mkdstub atuin-nodaemon manual-spawn-impossible
    _d_run atuin-nodaemon --premise autostart --json
    _dreap
    if [[ "$(_d_get "$_dout" verdict)" == unmeasurable ]] && ((_drc == 3)) &&
      [[ "$_dout" == *"cannot host a daemon"* ]]; then
      pass "atuin autostart: a box where NO daemon can start is unmeasurable (rc 3), never a finding about upstream"
    else
      fail "atuin autostart: a failed spawn CONTROL must be unmeasurable/rc3, got $(_d_get "$_dout" verdict)/rc$_drc — an apparatus limit was rendered as an upstream finding"
    fi

    # 10. A build this script cannot cleanly stop is one it must not start. atuin has moved
    #     the daemon subcommand spelling before (#380), and unlike the bench — which holds a
    #     PID to kill — an autostart daemon's PID is never handed to us. Refusing costs an
    #     unmeasurable run; spawning anyway costs a process writing into a deleted tree.
    for _dcase in no-daemon-subcommand no-stop-subcommand; do
      _mkdstub "atuin-$_dcase" "$_dcase"
      _d_run "atuin-$_dcase" --premise autostart --json
      # REAP AFTER THE ASSERTION, not before: _dreap deletes the .calls and .spawned markers,
      # and reading them afterwards is reading files that are already gone — both checks would
      # then pass for a build that DID spawn.
      if [[ "$(_d_get "$_dout" verdict)" == unmeasurable ]] && ((_drc == 3)) &&
        ! _d_calls "atuin-$_dcase" | grep -qE '^daemon start$' && ! _d_spawned "atuin-$_dcase"; then
        pass "atuin autostart: $_dcase is unmeasurable (rc 3) and nothing was spawned on it"
      else
        fail "atuin autostart: $_dcase must be unmeasurable/rc3 with no spawn attempted, got $(_d_get "$_dout" verdict)/rc$_drc"
      fi
      _dreap
    done

    # 11. TEARDOWN IS THE KNOWN-HARD PART. A `daemon stop` that returns 0 and does nothing is
    #     the realistic bad shape — which is why the stop is PROVEN by a connect rather than
    #     believed from an exit status. The escalation must still leave nothing running and
    #     nothing behind, or the next arm measures a daemon it did not start and the EXIT
    #     trap rm -rf's a tree a live process is writing into.
    #
    #     WHAT THIS DOES NOT COVER, stated so the gap is not mistaken for coverage: the branch
    #     where the stop can never be proven at all, which PRESERVES the sandbox and prints its
    #     path. No portable stub can reach it — a process that survives SIGKILL does not exist,
    #     and the escalation's PID lookup is what would have to fail instead (/proc on Linux,
    #     lsof on macOS), which is platform-specific rather than something a stub can arrange.
    #     It was verified by hand on macOS by running this same stub with lsof off PATH:
    #     verdict `unmeasurable`, sandbox kept, and the exact `rm -rf` printed to stderr.
    _mkdstub atuin-stopnoop stop-noop
    _d_run atuin-stopnoop --premise autostart --json
    _dleft=0
    _dpf="$_dstub/atuin-stopnoop.pid"
    if [[ -f "$_dpf" ]] && kill -0 "$(cat "$_dpf" 2>/dev/null)" 2>/dev/null; then
      _dleft=1
    fi
    _dreap
    if ((_dleft == 0)) && [[ -n "$(_d_get "$_dout" verdict)" ]]; then
      pass "atuin autostart: a 'daemon stop' that lies still leaves no daemon running — the stop is proven, not believed"
    else
      fail "atuin autostart: a no-op 'daemon stop' left a daemon alive; teardown escalation did not work"
    fi

    # 12. THE CHILD NO SOCKET CAN SEE. autostart may fork a daemon that hangs or dies before
    #     it ever binds: nothing answers, so the stop proof succeeds instantly and
    #     socket_owner_pid has no inode to resolve a pid from. The arm's PROCESS GROUP is the
    #     only handle on it, which is why the arms run under `set -m` — and why run_one returns
    #     its record in a global rather than on stdout, since a command substitution would run
    #     the whole function in a subshell and discard the group id before cleanup ever saw it.
    _mkdstub atuin-forkhang fork-hang
    _d_run atuin-forkhang --premise autostart --json
    _d_forked_wait atuin-forkhang || true
    _dalive="$(_d_forks_alive atuin-forkhang)"
    _dforked="$(grep -c . "$_dstub/atuin-forkhang.forked" 2>/dev/null || echo 0)"
    _dreap
    if ((_dforked > 0)) && ((_dalive == 0)); then
      pass "atuin autostart: a child that forks and never binds is still reaped ($_dforked forked, 0 alive) — the process group catches what the socket cannot"
    elif ((_dforked == 0)); then
      fail "atuin autostart: the fork-hang stub never forked, so the reaping assertion proved nothing"
    else
      fail "atuin autostart: $_dalive of $_dforked never-bound children survived the run — cleanup deleted the sandbox around a live process"
    fi

    # (There is no case here for a child that DETACHES and never binds. The handle that
    #  covered it — matching processes by the sandbox path in their environment — was removed
    #  deliberately: exact only on Linux, a different mechanism on macOS, and in two
    #  consecutive reviews the source of fail-open defects of its own. The residual is
    #  documented at daemon_stop_proven and in the report's scope note rather than half-tested
    #  here.)

    # 13. THE SAME HOLE IN THE CLOSING HALF OF THE PAIR. Tracking only `history start` would
    #     pass case 12 while leaving an `end`-spawned child untracked, and `end` runs with the
    #     same AUTOSTART env down the same autostarting path — so it is asserted separately
    #     rather than assumed to be covered by its sibling.
    _mkdstub atuin-forkhangend fork-hang-end
    _d_run atuin-forkhangend --premise autostart --json
    _d_forked_wait atuin-forkhangend || true
    _dalive="$(_d_forks_alive atuin-forkhangend)"
    _dforked="$(grep -c . "$_dstub/atuin-forkhangend.forked" 2>/dev/null || echo 0)"
    _dreap
    if ((_dforked > 0)) && ((_dalive == 0)); then
      pass "atuin autostart: a child forked by the CLOSING half of the pair is reaped too ($_dforked forked, 0 alive)"
    elif ((_dforked == 0)); then
      fail "atuin autostart: the fork-hang-end stub never forked on 'history end', so the assertion proved nothing"
    else
      fail "atuin autostart: $_dalive of $_dforked children forked by 'history end' survived — only the opening half of the pair is tracked"
    fi

    # 14. THE MANUAL CONTROL HAS THE SAME HOLE, and it was the last untracked spawn here. If
    #     `daemon start` forks a child that never binds and its parent exits, the recorded pid
    #     is a corpse, wait_reachable fails, cleanup sees an absent socket and calls it
    #     stopped, and reap_manual has nothing left to kill. The verdict must still be
    #     `unmeasurable` (this box could not host a daemon -- never a finding about upstream),
    #     AND the survivor must be reaped.
    _mkdstub atuin-manualfork manual-fork-nobind
    _d_run atuin-manualfork --premise autostart --json
    _d_forked_wait atuin-manualfork || true
    _dalive="$(_d_forks_alive atuin-manualfork)"
    _dforked="$(grep -c . "$_dstub/atuin-manualfork.forked" 2>/dev/null || echo 0)"
    _dv="$(_d_get "$_dout" verdict)"
    _dreap
    if [[ "$_dv" == unmeasurable ]] && ((_drc == 3)) && ((_dforked > 0)) && ((_dalive == 0)); then
      pass "atuin autostart: a manual spawn that forks without binding is unmeasurable AND its orphan is reaped ($_dforked forked, 0 alive)"
    elif ((_dforked == 0)); then
      fail "atuin autostart: the manual-fork-nobind stub never forked, so the assertion proved nothing"
    else
      fail "atuin autostart: manual-fork-nobind gave $_dv/rc$_drc with $_dalive of $_dforked orphans alive — the manual control is not process-group tracked"
    fi

    # 15. A BOUND THAT EXPIRES ON THE CLOSING HALF IS STILL AN APPARATUS LIMIT. The row lands
    #     on `history end` when a daemon is serving, so `end` is the verdict-bearing call —
    #     and its status used to be discarded, leaving a timed-out `end` looking like a
    #     successful `start` with a missing row, which the verdict block reported as
    #     "the entry did not land". A finding about upstream, manufactured by this run's own
    #     timeout. The wedge is on the autostart path only, so the manual control passes and
    #     the arms are actually reached.
    # GUARDED ON A TIMEOUT UTILITY, because this case's whole mechanism is the bound. Where
    # neither timeout(1) nor gtimeout(1) exists the verifier deliberately measures UNBOUNDED
    # and discloses it — which is right for a real run and fatal here: TIMEOUT_CMD is empty, so
    # nothing cuts the stub's four 300-second wedges and the suite runs to the job timeout
    # instead of failing. A stock macOS box has neither utility, and the macOS audit leg runs
    # this section.
    if ! have timeout && ! have gtimeout; then
      skip "atuin autostart: wedged 'history end' (no timeout(1)/gtimeout(1) here, so the verifier measures unbounded by design and the case's own wedge would never be cut)"
    else
    _mkdstub atuin-endhangs end-hangs
    CORE_ATVERIFY_TIMEOUT=2 _d_run atuin-endhangs --premise autostart --json
    _dv="$(_d_get "$_dout" verdict)"
    _dwhy="$(_d_get "$_dout" reason)"
    _dreap
    if [[ "$_dv" == unmeasurable ]] && ((_drc == 3)) && [[ "$_dwhy" == *"did not return within"* ]]; then
      pass "atuin autostart: a 'history end' that wedges is unmeasurable (rc 3), never a finding that the entry did not land"
    else
      fail "atuin autostart: a wedged 'history end' must be unmeasurable/rc3 naming the bound, got ${_dv:-<unparseable>}/rc$_drc${_dstderr:+ (stderr: $_dstderr)}"
    fi
    fi

    # 16. "NOTHING ANSWERS" IS NOT "THE DAEMON EXITED". atuin unlinks its socket early in
    #     shutdown and `daemon stop` can return while teardown is still running, so a
    #     socket-only proof accepts a daemon that is gone from the socket and still HOLDING
    #     THE DB. The harm is not a leak — cleanup's group reap would catch that — it is
    #     CONTAMINATION: every later arm then measures against a daemon it did not start, and
    #     attributes that daemon's writes to upstream. This stub's zombie keeps committing
    #     once its socket is unlinked, so a socket-only proof yields extra rows and a FALSE
    #     `moved`; the group half of the proof kills it at the inter-arm stop and the run
    #     stays clean. Asserted on the VERDICT, because that is where the damage would show.
    #
    #     THREE VERDICTS HERE TOO, and this is the one case in the section that had to learn
    #     it. Every other verdict-bearing arm drives its stub to a SPECIFIC negative
    #     (`moved`, or `unmeasurable` for a named apparatus limit), so anything else is a
    #     genuine miss. This one is the only arm that expects the POSITIVE verdict from an
    #     otherwise well-behaved stub — which means it inherits every environmental way a run
    #     can honestly decline, and `[[ $_dv == holds ]]` … `else fail` swept all of them into
    #     a message asserting an upstream finding. That is precisely the inversion the third
    #     verdict exists to prevent (see verify-atuin-guard.sh's header: `unmeasurable` is
    #     "the apparatus could not be trusted … never a finding about upstream"), so the check
    #     that polices it must not be the one committing it.
    #
    #     NOT HYPOTHETICAL, and not a rare corner. The section runs at CORE_ATVERIFY_POLL=3 —
    #     300ms for the manual-spawn control's daemon to bind and answer — which a loaded box
    #     misses, yielding "a daemon started by hand never answered … An apparatus limit, not
    #     a finding" with NOTHING having survived. Reproduced under CPU contention (the same
    #     stub flips holds/unmeasurable), and it reddened audit-alpine on an unrelated
    #     docs-only PR, where a rerun of the identical commit went green.
    #
    #     THE SKIP DOES NOT MAKE THIS GO QUIET, which is the only reason it is allowed. The
    #     two halves are separated: the SURVIVOR half is unconditional and stays a failure
    #     under any verdict — a live daemon is a leak whether or not the run could measure —
    #     and `moved` stays a failure because that is the false verdict the zombie's rows
    #     would manufacture. Nor can a contaminated control hide behind the skip: the opening
    #     control runs before any daemon exists, the spawn control runs while the socket is
    #     PRESENT (this stub only commits once it is gone), and the closing drain control runs
    #     only after daemon_stop_proven has confirmed the owner pid dead. Contamination has no
    #     route to `unmeasurable` here — it can only surface as `moved` or a survivor.
    _mkdstub atuin-stopunlink stop-unlinks-only
    _d_run atuin-stopunlink --premise autostart --json
    _dv="$(_d_get "$_dout" verdict)"
    _dwhy="$(_d_get "$_dout" reason)"
    _dleft=0
    _dpf="$_dstub/atuin-stopunlink.pid"
    if [[ -f "$_dpf" ]] && kill -0 "$(cat "$_dpf" 2>/dev/null)" 2>/dev/null; then
      _dleft=1
    fi
    _dreap
    if ((_dleft != 0)); then
      fail "atuin autostart: a socket-only stop left the zombie daemon alive (verdict=$_dv) — it keeps committing into later arms and its writes would be reported as an upstream finding"
    elif [[ "$_dv" == holds ]]; then
      pass "atuin autostart: a daemon that outlives its own socket is stopped before the next arm — it cannot write rows the run would blame on upstream"
    elif [[ "$_dv" == unmeasurable ]]; then
      skip "atuin autostart: a daemon that outlives its own socket — no zombie survived, but the verdict half could not be measured on this box (${_dwhy:-no reason reported})"
    elif [[ "$_dv" == moved ]]; then
      fail "atuin autostart: a socket-only stop let the zombie's rows land in a measured arm — the run reports a premise that MOVED on writes it made itself"
    else
      # NO VERDICT AT ALL is its own outcome, and routing it into the `moved` arm would name a
      # cause this run has no evidence for. It is also the one shape with a KNOWN history here:
      # a stray line on stderr merging into stdout leaves json.load with nothing to parse, which
      # is how §J4 first went red on Alpine (see _d_run's comment). So stderr is carried into the
      # message — it is the only thing that can say what actually happened.
      fail "atuin autostart: the socket-only-stop run produced no parseable verdict (rc$_drc) — this is the apparatus failing to report, not a measurement${_dstderr:+ (stderr: $_dstderr)}"
    fi

    # 17. The sandbox is REMOVED on a normal run — asserted on the DELTA, not on a global scan
    #     of /tmp. The verifier DELIBERATELY preserves a sandbox when a stop cannot be proven,
    #     so a tree left by an earlier run, a hand-run, or a concurrent one would otherwise
    #     fail this for a run that cleaned up perfectly. Only paths this run created count.
    #
    #     A DELTA IS NOT ENOUGH, because /tmp is a SHARED namespace and the window is not
    #     exclusive. This globbed every `atverify.*` and treated anything new as a leak, which
    #     silently assumed no second run existed — and a second run is ordinary here: another
    #     worktree, another agent, or simply `make audit` in one terminal while `make tag`
    #     audits in another. The second run's sandbox is born inside the first run's window and
    #     the first run reports a leak that does not exist. That is what happened: a `make tag`
    #     failed the audit with "leaked 1 new sandbox dir(s)" on the repo's most consequential
    #     command, where the operator's natural next move — re-run, or reach for
    #     TAG_SKIP_AUDIT=1 — is the exact habit a release gate must not teach. So the glob is
    #     narrowed to $_DTAG, the tag every sandbox of OURS carries (see CORE_ATVERIFY_TAG),
    #     and a foreign tree is now invisible to it by construction rather than by luck.
    #
    #     THE SELF-CHECK IS NOT OPTIONAL. A delta over a directory listing that silently
    #     returns nothing passes for every run, forever — and that is precisely what the first
    #     version of this did: on macOS /tmp is a symlink to private/tmp and `find /tmp`
    #     without -L does not descend it, so both snapshots were empty and the assertion was
    #     vacuous on a third of the fleet. Prove the snapshot can see a directory before
    #     trusting it to notice one. (The fault there was the unfollowed symlink, not a
    #     missing -maxdepth.) Narrowing the glob makes that guard MORE load-bearing, not less:
    #     a tag that never reached the script would empty both snapshots the same way.
    # The shell's own one-level glob, not find(1) and not ls(1). BSD find on macOS does
    # support -maxdepth (checked against /usr/bin/find, which is what the macOS CI leg runs),
    # so the earlier version was not broken for that reason — but a glob needs no portability
    # argument at all, and this check has already been silently blind once.
    _dsnap() {
      local d
      local -a out=()
      for d in "/tmp/atverify.$_DTAG."*; do [[ -d "$d" ]] && out+=("$d"); done
      ((${#out[@]})) && printf '%s\n' "${out[@]}" | sort
      return 0
    }
    # _dnewdirs <pre-snapshot> — the tagged dirs present now that were absent in <pre>.
    # comm needs sorted input on both sides; _dsnap sorts, so a snapshot may be fed back in.
    _dnewdirs() {
      comm -13 <(printf '%s\n' "$1" | grep -v '^$') <(_dsnap | grep -v '^$')
    }
    _dselfck="/tmp/atverify.$_DTAG.selfcheck$$"
    mkdir -p "$_dselfck"
    if ! _dsnap | grep -q "atverify.$_DTAG.selfcheck$$"; then
      rmdir "$_dselfck" 2>/dev/null
      fail "atuin autostart: the sandbox-leak check cannot enumerate /tmp — it would pass vacuously, so it is reported as broken rather than green"
    else
      rmdir "$_dselfck" 2>/dev/null
      _dpre="$(_dsnap)"
      _d_run atuin-heals --premise autostart --json
      _dreap
      # A CONCURRENT RUN'S SANDBOX, planted inside the window on purpose — this is the
      # regression half of the assertion, not scaffolding. Who created it is irrelevant: a
      # glob is all this check has to reason with, so a directory of the right SHAPE under a
      # tag that is not ours is exactly what a second test-core.sh on this box contributes.
      # If it is ever counted again, this arm goes red here rather than at a release cut.
      _dforeign="/tmp/atverify.foreign$$.regress"
      mkdir -p "$_dforeign"
      _dleaked="$(_dnewdirs "$_dpre")"
      rmdir "$_dforeign" 2>/dev/null
      _dnew="$(printf '%s\n' "$_dleaked" | grep -c . || true)"
      if ((_dnew == 0)); then
        pass "atuin autostart: a completed run leaves no NEW sandbox behind, daemon stopped first — and a concurrent run's sandbox in shared /tmp is not mistaken for one"
      else
        fail "atuin autostart: a completed run leaked $_dnew new sandbox dir(s) under /tmp: $(printf '%s' "$_dleaked" | tr '\n' ' ')"
      fi
    fi

    # 17b. THE OTHER HALF OF 17, and the reason narrowing the glob is safe rather than merely
    #      quiet. A check that ignores a foreign tree and a check that ignores EVERY tree look
    #      identical from a green run, and 17 alone cannot tell them apart — its expected
    #      result is zero either way. So the discrimination is asserted directly, with no
    #      verifier involved: plant one sandbox under a foreign tag and one under ours, and
    #      require the delta to name OURS and only ours. A single string compare carries both
    #      directions — a wrong count or a wrong path fails it.
    _dpre="$(_dsnap)"
    _dforeign="/tmp/atverify.foreign$$.control"
    _dmine="/tmp/atverify.$_DTAG.leak$$"
    mkdir -p "$_dforeign" "$_dmine"
    _dleaked="$(_dnewdirs "$_dpre")"
    rmdir "$_dforeign" "$_dmine" 2>/dev/null
    if [[ "$_dleaked" == "$_dmine" ]]; then
      pass "atuin autostart: the leak check still SEES a genuine leak under this run's tag while ignoring a foreign one — narrowing the glob did not make it blind"
    else
      fail "atuin autostart: the leak check must report exactly $_dmine as new and nothing else, got '$(printf '%s' "$_dleaked" | tr '\n' ' ')' — it is either blind to a real leak or still counting foreign sandboxes"
    fi

    # 18. A MALFORMED ANCHOR IS NOT AN ABSENT ONE. Absence is legitimate for THIS premise —
    #     nobody has written the line until a human measures it — which is exactly why the two
    #     must not be conflated: `=18.19`, or a valid value with a trailing token, would
    #     otherwise sail through as `unanchored` and the run would report a verdict against
    #     nothing. Cheap to assert: read_anchor runs before the sandbox is built, so no daemon
    #     is spawned on this path.
    _dvrepo="$(mktemp -d "$SANDBOX/dvrepo.XXXXXX")"
    mkdir -p "$_dvrepo/zsh" "$_dvrepo/scripts/research/lib" "$_dvrepo/scripts/lib" "$_dvrepo/lib" "$_dvrepo/atuin"
    cp "$_DVERIFY" "$_dvrepo/scripts/research/"
    cp "$HERE/scripts/lib/common.sh" "$_dvrepo/scripts/lib/"
    cp "$HERE/scripts/research/lib/atuin-db.sh" "$_dvrepo/scripts/research/lib/"
    cp "$HERE/lib/ux.sh" "$_dvrepo/lib/" 2>/dev/null || true
    cp "$HERE/atuin/config.toml" "$_dvrepo/atuin/"
    _dbad=0
    for _dcase in "18.19" "18.19.0 EXTRA"; do
      {
        echo "# CORE_ATUIN_GUARD_VERIFIED_AGAINST=18.19.0"
        echo "# CORE_ATUIN_AUTOSTART_VERIFIED_AGAINST=$_dcase"
      } >"$_dvrepo/zsh/00-tools.zsh"
      _dout="$(cd "$_dvrepo" && CORE_COLOR=never "./scripts/research/verify-atuin-guard.sh" \
        --premise autostart --atuin "$_dstub/atuin-heals" --json 2>/dev/null)"
      [[ "$(_d_get "$_dout" verdict)" == unmeasurable ]] || _dbad=1
    done
    # Absence, by contrast, must still be allowed through as unanchored.
    echo "# CORE_ATUIN_GUARD_VERIFIED_AGAINST=18.19.0" >"$_dvrepo/zsh/00-tools.zsh"
    _dout="$(cd "$_dvrepo" && CORE_COLOR=never CORE_ATVERIFY_POLL=3 "./scripts/research/verify-atuin-guard.sh" \
      --premise autostart --atuin "$_dstub/atuin-heals" --json 2>/dev/null)"
    [[ "$(_d_get "$_dout" anchor_relation)" == unanchored ]] || _dbad=1
    _dreap
    if ((_dbad == 0)); then
      pass "atuin autostart: a malformed anchor is unmeasurable while an ABSENT one is still unanchored — the two are not conflated"
    else
      fail "atuin autostart: a malformed autostart anchor was treated as absent, so the run reported a verdict against nothing"
    fi

    # 19. THE LIBC MARKER MUST SURVIVE musl's EXIT STATUS. musl's ldd prints its banner and
    #     then exits NON-ZERO, and this script runs under `set -o pipefail` — so the obvious
    #     `ldd --version | grep -qi musl` is false even when grep matched, and every musl run
    #     loses the one marker that says which half of the fleet it spoke for. This repo has
    #     already paid for that exact mistake once (see CHANGELOG and bench-atuin-daemon.sh),
    #     which is why it is pinned here rather than left to a comment.
    _dshim="$(mktemp -d "$SANDBOX/dshim.XXXXXX")"
    for _dt in bash sh python3 sed grep awk tr cut head sleep mktemp rm cat kill ls chmod mkdir printf env find sort wc dirname basename readlink cp comm; do
      _dp="$(command -v "$_dt" 2>/dev/null)" && ln -sf "$_dp" "$_dshim/$_dt" 2>/dev/null
    done
    printf '#!/bin/sh\necho "musl libc (x86_64)" >&2\nexit 1\n' >"$_dshim/ldd"
    printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' >"$_dshim/uname"
    chmod +x "$_dshim/ldd" "$_dshim/uname"
    _dout="$(PATH="$_dshim" CORE_COLOR=never "$_DVERIFY" --unmeasurable probe --json 2>/dev/null)"
    if [[ "$(_d_get "$_dout" host)" == *musl* ]]; then
      pass "atuin autostart: musl is detected even though its ldd exits non-zero (the pipefail trap this repo has hit before)"
    else
      fail "atuin autostart: a musl host reported host='$(_d_get "$_dout" host)' — the libc marker was lost to pipefail"
    fi

    # 20. Report coherence, §J3 case 7's counterpart with this premise's claims. The scope
      #   paragraph must NOT still say the autostart premise is unmeasured — that sentence was
      #   true until this mode existed and is exactly the kind of prose that rots — and must
      #   name the machines a green run here does and does not speak for.
    _drep="$SANDBOX/atverify-auto.md"
    _d_run atuin-heals --premise autostart --report "$_drep" --json
    _dreap
    if [[ -s "$_drep" ]] && printf '%s' "$_dout" | python3 -c '
import json,re,sys
d = json.load(sys.stdin)
rep = open(sys.argv[1]).read()
arms = set(d["arms"])
m = re.search(r"^\*\*Measured here:\*\* (.+)\.$", rep, re.M)
assert m, "no derived coverage sentence"
claimed = {a.strip().replace(" / ", "_") for a in m.group(1).split(",")}
assert claimed == arms, sorted(claimed ^ arms)
assert "premise: `autostart`" in rep, "the report does not say which premise it measured"
scope = rep.split("---\n\n", 1)[1]
# The claim this whole section retires. If it survives here, the report is telling a reader
# that nothing measures the thing the report is a measurement of.
assert "stand-down** is unmeasured" not in scope, "the autostart report still claims the premise is unmeasured"
for want in ("musl", "macOS", "3382", "--premise discard"):
    assert want in scope, want
# The teardown residual must be described as what it IS. An earlier version of this note
# claimed the run "preserves its sandbox rather than deleting one it could not account for"
# for a case NOTHING DETECTS — every check passes, the stop is accepted, and the tree is
# deleted around a live child. A scope note that promises a safety behaviour the code does not
# perform is the exact defect this section exists to catch, so the honest wording is pinned.
assert "undetected leak" in scope, "the scope note no longer names the teardown residual as undetected"
assert "preserving its sandbox rather than deleting" not in scope, "the scope note has re-acquired the preservation claim for a case nothing detects"
named = [a for a in arms if a.replace("_", " / ") in scope]
assert not named, "the scope section names measured arms: %s" % named
' "$_drep" 2>/dev/null; then
      pass "atuin autostart: --report names this premise, matches the arms that ran, and no longer calls autostart unmeasured"
    else
      fail "atuin autostart: the autostart report's prose does not match what it measured"
    fi
    fi  # known-good stub held
  fi    # apparatus probe
  _dreap
fi

# ── --json output contract (self-run) ─────────────────────────────────────────
# ── --json IS A CONTRACT: stdout carries ONE parseable object and nothing else ─
# The mode exists for CI steps and editor integrations that PARSE rather than scrape, so
# every guarantee it makes is machine-facing: a single JSON object on stdout, and a
# `result` that agrees with the same run without --json. Three separate bugs have broken
# one half or the other, each found by hand on a green tree (#508, #524, #511), and each
# time the suite went on certifying itself because no test ever ran --json.
#
# Two failure shapes this catches that nothing else does:
#   1. a fixture leaking to STDOUT — the last one was a no-op `git commit` printing
#      "nothing to commit, working tree clean", which made the object unparseable while
#      every assertion still passed;
#   2. an inherited CORE_JSON silencing a child gate's skip() lines, which flips assertions
#      that grep for them and reports a failing result on a healthy tree.
#
# Runs the suite against ITSELF at --scope none (the cheapest scope, a few seconds).
# CORE_TEST_SELFJSON=1 in the child is what stops the recursion, and the guard is on the
# PARENT so a nested run simply skips this section rather than re-entering it.
#
# Placed ABOVE the zsh-gated block below, not at the end of the file, because that block
# ends in `summary; exit` on a box where zsh is absent or shell scope is off — so anything
# after it is unreachable for exactly the `--scope none` invocation this gate is about.
if [[ "${CORE_TEST_SELFJSON:-0}" == 1 ]]; then
  : # nested self-run: this section is what invoked us
else
  hdr "--json output contract (self-run, hermetic)"
  # -u CORE_TEST_NESTED is this section obeying its own rule. audit-core.sh sets it so the
  # audit owns the summary and we print none — and the child would INHERIT it and print
  # nothing at all, so under `make audit` the gate saw 0 lines and failed for a reason that
  # had nothing to do with the contract. Exactly the shape #508/#524/#511 each took: a
  # fixture asserting on output while a variable that governs how that output is produced
  # leaks in from the parent.
  _sj_out="$(env -u CORE_TEST_NESTED CORE_TEST_SELFJSON=1 bash "$HERE/scripts/test-core.sh" --scope none --json 2>/dev/null)"
  _sj_lines="$(printf '%s\n' "$_sj_out" | grep -c . || true)"
  if [[ "$_sj_lines" == 1 ]]; then
    pass "--json: stdout is exactly one line (no fixture leaked onto it)"
  else
    fail "--json: stdout carried $_sj_lines lines, want 1 — something printed alongside the object:
$(printf '%s\n' "$_sj_out" | grep -v '^{' | head -5)"
  fi
  # Parse it for real rather than grepping: a truncated or interleaved object can still
  # contain the substring `"result":"ok"`, and a consumer would choke where a grep would not.
  if _sj_result="$(printf '%s' "$_sj_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])' 2>/dev/null)"; then
    pass "--json: stdout parses as JSON and exposes .result"
  else
    _sj_result=""
    if have python3; then
      fail "--json: stdout is not parseable JSON"
    else
      skip "--json parse (python3 not installed)"
    fi
  fi
  # THE property #511 was filed about: --json must not change the VERDICT. Compared against
  # the same scope without it, so a disagreement means the mode itself moved the result.
  if [[ -n "$_sj_result" ]]; then
    if env -u CORE_TEST_NESTED CORE_TEST_SELFJSON=1 bash "$HERE/scripts/test-core.sh" --scope none --quiet --color never >/dev/null 2>&1; then
      _sj_plain=ok
    else
      _sj_plain=failed
    fi
    if [[ "$_sj_result" == "$_sj_plain" ]]; then
      pass "--json: the verdict matches the identical run without --json (#511)"
    else
      fail "--json: reported '$_sj_result' where the same scope without --json reported '$_sj_plain' — the mode changed the result"
    fi
  fi
  unset _sj_out _sj_lines _sj_result _sj_plain
fi

