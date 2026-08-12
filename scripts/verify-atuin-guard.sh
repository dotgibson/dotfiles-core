#!/usr/bin/env bash
# scripts/verify-atuin-guard.sh
# ──────────────────────────────────────────────────────────────────────────────
# _core_atuin_daemon_guard (zsh/00-tools.zsh) is not a preference. It is a workaround for
# ONE measured upstream fact: on atuin 18.19.0, with the daemon enabled and its socket
# absent or stale, `atuin history start` exits 0, prints a well-formed history id, writes
# nothing to stderr — and DISCARDS the entry (atuinsh/atuin#3561). A persistent precmd
# hook, a throttled connect(2) on the prompt path, and a one-way degrade in every
# interactive shell across eight repos are ALL justified by that single fact. Nothing else.
#
# The fact has already moved once, in the direction that makes it harder to notice (18.16.1
# failed LOUDLY — an empty ATUIN_HISTORY_ID, which then crashed `history end`). So it can
# move again, and until this script nothing watched: atuin is not pinned in mise/config.toml,
# has no renovate.json entry, and /tool-scout's allowed-tools carry no Bash, so it can
# compare version NUMBERS and never measure. This measures.
#
# THREE VERDICTS, NEVER TWO. The two-verdict version of this check is the one that already
# shipped and was wrong, so the third is the whole point:
#
#   holds         BOTH control arms wrote exactly one row, and BOTH unreachable shapes gave
#                 rc 0, an id on stdout, empty stderr, and a row delta of exactly 0. The
#                 guard still earns its place on every prompt in the fleet.
#   moved         the control arms wrote, and something about an unreachable shape is now
#                 different — or the closing control wrote MORE than one row, meaning the
#                 unreachable entries were spooled and replayed rather than discarded.
#                 zsh/00-tools.zsh's rationale block is OVERCLAIMING, and the guard needs
#                 retiring, version-gating or reshaping — a human decision, weighed as an
#                 eight-repo change.
#   unmeasurable  the apparatus could not be trusted: no atuin, no python3, the anchor could
#                 not be read, the sandbox could not be built, the row count came back -1,
#                 unreachability could not be PROVEN, or either control arm did not write.
#                 This is NOT `holds`. A detector that quietly stops detecting is
#                 indistinguishable from good news, and that is the failure this exists to
#                 prevent — so declining is a first-class outcome with its own exit code.
#
# WHY A CONTROL ARM. "The row count did not go up" is the same observation whether atuin
# discarded the write or the apparatus never wrote anything. The earlier copy-paste recipe
# conflated exactly those two: it seeded its DB with the daemon already enabled and
# unreachable, so on a build that discards, the DB was never created, the row count fell
# back to 0, and it printed the premise-holds signature from an apparatus that had never
# written a row. It was right by luck. So here a daemon-OFF write runs FIRST and must land
# exactly one row; if it cannot, nothing observed afterwards means anything.
#
# WHY A SECOND ONE, AT THE END. The opening control proves the apparatus at t=0 only, and an
# apparatus can stop writing MID-RUN — a DB that goes unwritable still READS fine, so the
# -1 sentinel never fires and four honest-looking zeros produce a `holds` from a run that
# measured nothing. The closing arm also probes the ONE-WAY-DEGRADE premise, which the four
# arms structurally cannot: Core degrades a shell permanently on the first failed connect
# because atuin is DISCARDING during the outage, and a build that instead SPOOLED those
# entries would leave the same delta of 0 behind — but flush them on the next successful
# write, landing 5 rows here instead of 1. That would INVERT the reasoning one-way rests on
# (dotgibson/dotfiles-core#383).
#
# WHY UNREACHABILITY IS PROVEN, NOT ASSUMED. A delta of zero against a socket that was
# quietly healthy would read as "still discarding" when the truth is "the daemon took it".
# So each shape is probed before anything is written — a bounded connect(2), plus the
# /proc/net/unix LISTEN scan where /proc is readable (the primitive from
# bench-atuin-daemon.sh's unit_owns_socket).
#
# EXIT CODE = VERDICT, AND THAT BREAKS ONE HOUSE IDIOM ON PURPOSE. audit-core.sh /
# test-core.sh / bench-core.sh all SKIP a missing prerequisite and exit 0, so they are safe
# to call on a bare box. Here exit 0 is a POSITIVE ASSERTION ABOUT UPSTREAM, so a bare box
# must not be able to produce it. A missing prerequisite still prints a skip line (and is
# still tallied by scripts/lib/common.sh) but exits 3:
#
#   0  holds        1  moved        2  usage error        3  unmeasurable
#
# `moved` exiting non-zero follows freshness.yml's --check mode: an intended non-zero is THE
# REPORT, NOT A CRASH, which is why the workflow reads the verdict out of --json instead of
# letting $? paint the run red.
#
# NO NETWORK, NO DOWNLOAD, NO PINS. This script measures an atuin binary it is HANDED
# (--atuin) or the one on PATH. Resolving and fetching "whatever upstream ships now" is the
# workflow's job, deliberately: fetching an unpinned upstream binary is a supply-chain
# decision that must be argued where the TOKENS live, not buried in a gate script a
# developer runs on their laptop. Keeping this side hermetic is also what makes it testable
# with no atuin present at all (scripts/test-core.sh Section J3).
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# Shared palette + pass/skip/fail/have + the CORE_JSON convention.
# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"
# ROWCOUNT_PY / atuin_db_rows / atuin_db_checkpoint — the same schema model
# scripts/bench-atuin-daemon.sh's row rule rests on, so the two cannot drift apart.
# shellcheck source=scripts/lib/atuin-db.sh
source "${BASH_SOURCE[0]%/*}/lib/atuin-db.sh"

ATUIN_BIN=""
JSON=0
REPORT=""
FORCED_UNMEASURABLE=""
# Bounded, so a wedged atuin (the accept-but-silent shape of atuinsh/atuin#3382) cannot hang
# a scheduled job until the runner's timeout kills it with no verdict at all.
TIMEOUT_S="${CORE_ATVERIFY_TIMEOUT:-30}"

# Parse EVERY arg and reject an unknown one rather than ignore it — the same fail-closed
# contract as the gates, and as bench-atuin-daemon.sh's arg loop.
while (($#)); do
  case "$1" in
  --atuin)
    shift
    [[ $# -gt 0 ]] || {
      printf 'verify-atuin-guard.sh: --atuin needs a path\n' >&2
      exit 2
    }
    ATUIN_BIN="$1"
    ;;
  --json)
    JSON=1
    export CORE_JSON=1 # keeps skip() off stdout (scripts/lib/common.sh)
    ;;
  --report)
    shift
    [[ $# -gt 0 ]] || {
      printf 'verify-atuin-guard.sh: --report needs a path\n' >&2
      exit 2
    }
    REPORT="$1"
    ;;
  --unmeasurable)
    shift
    [[ $# -gt 0 ]] || {
      printf 'verify-atuin-guard.sh: --unmeasurable needs a reason\n' >&2
      exit 2
    }
    FORCED_UNMEASURABLE="$1"
    ;;
  --color)
    shift
    [[ $# -gt 0 ]] || {
      printf 'verify-atuin-guard.sh: --color needs auto|always|never\n' >&2
      exit 2
    }
    # Checked, not merely called. _core_set_color returns nonzero on a value outside
    # auto|always|never, and this script deliberately does not run under `set -e`, so an
    # unchecked call let `--color banana` fall through to a MEASUREMENT — turning a typo in
    # the caller's flags into a verdict about upstream. Every other bad flag here exits 2;
    # this one has to as well, or the usage contract is only true for some of the flags.
    _core_set_color "$1" || {
      printf 'verify-atuin-guard.sh: --color needs auto|always|never (got %s)\n' "$1" >&2
      exit 2
    }
    ;;
  -h | --help)
    cat <<'EOF'
usage: verify-atuin-guard.sh [--atuin PATH] [--json] [--report FILE]
                             [--unmeasurable REASON] [--color WHEN] [-h|--help]

Measure whether the ONE upstream fact _core_atuin_daemon_guard (zsh/00-tools.zsh) is
premised on still holds: with the daemon enabled and its socket unreachable, does
`atuin history start` still exit 0, print an id, stay silent on stderr, and DISCARD the
entry (atuinsh/atuin#3561)?

Hermetic: a throwaway HOME/XDG under env -i, Core's own atuin/config.toml, and a DB this
run creates and deletes. It never touches your real history.

Two unreachable shapes are measured, because the guard's rationale claims both:
  absent   the socket path does not exist
  stale    a real AF_UNIX socket file with nothing listening (a crashed daemon)
Each is measured with and without --hook (the form atuin's own `init zsh` emits, and so the
only one a real shell runs), and each is PROVEN unreachable before anything is written, so a
verdict can never rest on a socket that was quietly healthy.

A daemon-OFF control arm runs first and must write exactly one row. It is the apparatus
check: if the control cannot write, nothing observed afterwards means anything, and the
verdict is `unmeasurable` rather than a guess. A second one runs LAST and must also write
exactly one row: it proves the apparatus was still writable after the arms ran, and a delta
above 1 means atuin spooled the unreachable entries and replayed them rather than discarding
them — which would invert the premise the guard's one-way degrade rests on.

VERDICTS AND EXIT CODES
  0  holds         controls wrote 1 each; all arms: rc 0, id printed, empty stderr, delta 0
  1  moved         the controls wrote; something differs — the rationale now overclaims
  2  usage error
  3  unmeasurable  the apparatus could not be trusted. NOT "holds".

Exit 0 is a positive assertion about upstream, so — unlike the other gate scripts — a
missing prerequisite exits 3, not 0.

  --atuin PATH          measure this binary instead of the one on PATH
  --json                one JSON object on stdout; exit status matches the human path
  --report FILE         write an issue-ready markdown report (no title heading)
  --unmeasurable REASON emit a well-formed unmeasurable verdict WITHOUT measuring, so a
                        caller that failed before the binary existed (a download, a
                        checksum) reports through this one renderer instead of
                        hand-rolling prose at the call site
  --color WHEN          auto|always|never (CORE_COLOR works too)

Environment:
  CORE_ATVERIFY_TIMEOUT=<s>   per-call timeout (default 30). A call that never returns is
                              itself a finding — see atuinsh/atuin#3382.
EOF
    exit 0
    ;;
  *)
    printf 'verify-atuin-guard.sh: unexpected argument: %s\n' "$1" >&2
    printf 'try: verify-atuin-guard.sh --help\n' >&2
    exit 2
    ;;
  esac
  shift
done

# Canonical-integer test, not `^[0-9]+$` plus an arithmetic compare: those look equivalent
# and are not — `08` passes the digit class and bash then reads it as OCTAL. Same guard
# bench-atuin-daemon.sh applies to its knobs.
[[ "$TIMEOUT_S" =~ ^[1-9][0-9]*$ ]] || {
  printf 'verify-atuin-guard.sh: CORE_ATVERIFY_TIMEOUT must be a positive integer with no leading zero: %s\n' \
    "$TIMEOUT_S" >&2
  exit 2
}

# ── the whole verdict lives in these scalars ──────────────────────────────────
# Flat scalars, not associative arrays: this must run on macOS's stock bash 3.2, the same
# constraint scripts/lib/common.sh pins.
VERDICT=""
REASON=""
AT_VER="unknown"
ANCHOR="unknown"
ANCHOR_REL="unknown" # same | newer | older | unknown
CTL_DELTA=-1
# The CLOSING daemon-off control arm's delta. A flat scalar beside CTL_DELTA and deliberately
# NOT an entry in ARM_NAME below: it is a control, not a measurement of the premise, and the
# report table and the JSON `arms` object both mean "an unreachable shape we measured".
DRAIN_DELTA=-1
# Parallel indexed arrays, one entry per measured arm — bash 3.2 has no associative arrays
# (scripts/lib/common.sh pins that constraint), and four arms x five facts as flat scalars
# was twenty names to keep in step. The index is the arm; ARM_NAME[i] is "shape_hookmode".
ARM_NAME=() ARM_RC=() ARM_DELTA=() ARM_IDOK=() ARM_ERR=()
_ok="" _rc="" _delta="" _idok="" _err=""   # run_one record fields, read via IFS
SB="" LOCALDIR=""
BOUNDED=true            # false when neither timeout(1) nor gtimeout(1) exists (see measure())
TIMEOUT_CMD=()          # the bounding prefix, empty when unbounded

# The ONLY two ways this script reaches a non-`holds` conclusion. Never `holds` by omission:
# VERDICT starts empty and is set explicitly, so a path that forgets to decide cannot fall
# through into good news.
unmeasurable() {
  VERDICT=unmeasurable
  REASON="$1"
}
moved() {
  VERDICT=moved
  REASON="$1"
}

# BOTH codes, deliberately: shellcheck renamed this diagnostic between the versions the
# fleet actually runs. 0.11.0 (the pin in scripts/tool-versions.env, used by CI's ubuntu and
# macOS legs) reports a trap-only function as SC2329 "never invoked"; 0.10.0 — which is what
# `apk add shellcheck` gives the Alpine leg — reports the same thing as SC2317 "unreachable"
# on the body instead. Disabling only the pinned version's code passes locally and on ubuntu
# and still fails Alpine, which is exactly how this went red the first time. An unknown code
# in a disable directive is ignored, so naming both is safe in either direction.
# shellcheck disable=SC2329,SC2317  # invoked indirectly, by the EXIT trap below
cleanup() {
  [[ -n "$LOCALDIR" ]] && rm -rf "$LOCALDIR"
  return 0
}
trap cleanup EXIT

# ── the anchor ────────────────────────────────────────────────────────────────
# Read the ONE machine-readable line in zsh/00-tools.zsh, anchored at column 0 with nothing
# but the value after the `=`. Deliberately NOT a grep for a bare version pattern anywhere
# in the file: that rationale paragraph also names 18.16.1, and a detector comparing against
# the wrong number is worse than one that never runs. Exactly ONE match is required — zero
# means the anchor was renamed or deleted, two means the file disagrees with itself, and
# both are `unmeasurable` rather than a default.
read_anchor() {
  local hits n
  # Exactly three integer components, not `[0-9][0-9.]*`. The loose pattern matched `18`,
  # `18.` and `18..19`, and ver_cmp then treats a missing or non-numeric field as 0 — so a
  # typo'd anchor did not fail, it silently compared against a DIFFERENT version and the run
  # still produced a verdict. Fail closed instead: an anchor that is not X.Y.Z matches
  # nothing here, read_anchor returns 1, and the run is `unmeasurable` with a named reason.
  hits="$(sed -n 's/^# CORE_ATUIN_GUARD_VERIFIED_AGAINST=\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*$/\1/p' \
    zsh/00-tools.zsh 2>/dev/null)"
  n="$(printf '%s\n' "$hits" | grep -c '^[0-9]')"
  [[ "$n" == 1 ]] || return 1
  ANCHOR="$hits"
  return 0
}

# ver_cmp a b → prints -1 / 0 / 1. Field-wise integer compare: no `sort -V` (GNU-only in
# practice) and no bash 4 constructs, so this behaves the same on macOS.
ver_cmp() {
  local i x y
  local -a A B
  local IFS=.
  # shellcheck disable=SC2206  # deliberate word-splitting on IFS=. — that IS the parse
  A=($1)
  # shellcheck disable=SC2206
  B=($2)
  unset IFS
  for ((i = 0; i < 4; i++)); do
    x="${A[i]:-0}"
    y="${B[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    if ((10#$x > 10#$y)); then
      printf '1'
      return 0
    elif ((10#$x < 10#$y)); then
      printf -- '-1'
      return 0
    fi
  done
  printf '0'
}

# ── unreachability proof ──────────────────────────────────────────────────────
# prove_unreachable <path> — 0 when nothing is listening, 1 when something is (or when we
# cannot tell). Two independent checks, both fail-closed:
#   (1) /proc/net/unix, where readable: field 6 == 01 is LISTEN, field 8 is the path. This
#       is the primitive bench-atuin-daemon.sh's unit_owns_socket uses. Linux-only.
#   (2) a real connect(2) via python, bounded by a short timeout. A refusal (ECONNREFUSED)
#       or a missing path is the proof we want; a SUCCESSFUL connect means something is
#       serving the socket and the measurement below would be meaningless.
prove_unreachable() {
  local p="$1"
  if [[ -r /proc/net/unix ]] &&
    awk -v path="$p" '$6=="01" && $NF==path {found=1} END{exit !found}' /proc/net/unix 2>/dev/null; then
    return 1 # something is LISTENing on it
  fi
  [[ -e "$p" ]] || return 0 # absent path: nothing can be listening
  python3 - "$p" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
except OSError:
    sys.exit(0)          # refused / gone — genuinely unreachable
else:
    s.close()
    sys.exit(1)          # someone answered
PY
}

# make_stale <path> — bind+listen a real AF_UNIX socket, then exit without unlinking, so the
# inode survives with nothing behind it. That is the shape a crashed daemon leaves, and the
# one a plain `[[ -S ]]` test cannot tell from health.
make_stale() {
  python3 - "$1" <<'PY' 2>/dev/null
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
os._exit(0)              # no unlink, no close: the socket file stays behind
PY
  [[ -S "$1" ]]
}

# ── the measurement ───────────────────────────────────────────────────────────
# One `atuin history start` under the sandbox env, capturing rc, stdout (the history id)
# and stderr, and the row delta it caused.
DB=""
# run_one <mode> <socket-or-empty> <hook:yes|no> [settle_s]
#   -> "readok|rc|delta|idok|err"   (5 fields, `|`-joined; err has | and newlines stripped)
#
# An empty socket path is the daemon-OFF control arm.
#
# readok is NOT cosmetic. atuin_db_rows returns -1 when it cannot read the DB, and -1 is
# indistinguishable from a legitimate count in arithmetic: `after - before` with an
# unreadable `after` yields a NEGATIVE delta, which the verdict block would then read as
# "the row count changed" and report as `moved`. That is the design's central conflation
# pointing the other way — an apparatus failure rendered as a finding about upstream — so
# a failed read is flagged here and turned into `unmeasurable` by the caller. It also
# BREAKS the poll immediately: retrying a read that just spent SQLite's 30-second busy
# timeout, twenty times, is ten minutes of a scheduled job proving nothing.
run_one() {
  local mode="$1" sock="$2" hook="$3" settle="${4:-0}" before after rc id err idok=0 i
  local -a env_extra=() hookarg=()
  if [[ -n "$sock" ]]; then
    env_extra=("ATUIN_DAEMON__ENABLED=true" "ATUIN_DAEMON__SOCKET_PATH=$sock")
  else
    env_extra=("ATUIN_DAEMON__ENABLED=false")
  fi
  # --hook is what REAL SHELLS RUN: atuin's own `init zsh` emits
  # `atuin history start --hook -- "$1"` from _atuin_preexec. Measuring only the plain
  # form would measure a code path no shell in the fleet takes, so an upstream change
  # scoped to hook mode could break every prompt while this still reported `holds`.
  [[ "$hook" == yes ]] && hookarg=(--hook)
  before="$(atuin_db_rows "$DB")"
  ((before < 0)) && {
    printf '0|-1|-1|0|\n'
    return 0
  }
  id="$("${AT_ENV[@]}" "${env_extra[@]}" \
    "ATUIN_SESSION=$(printf '%032x' 1)" \
    ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$ATUIN_BIN" history start \
    ${hookarg[@]+"${hookarg[@]}"} -- "verify-$mode" 2>"$SB/err.$mode")"
  rc=$?
  # `|` stripped as well as newlines: this string is a FIELD in the record below, and an
  # stderr line containing a pipe would otherwise shift every field after it.
  err="$(tr -d '\n|' <"$SB/err.$mode" 2>/dev/null | cut -c1-200)"
  # A daemon-owned write can be committed slightly after the client returns, so give the
  # row a bounded moment to appear before concluding it never did. Bounded and short: the
  # expected delta here is 0, and waiting long for a 0 proves nothing, but NOT waiting at
  # all would manufacture a false `holds` on a build that writes asynchronously.
  after=-1
  for ((i = 0; i < 20; i++)); do
    after="$(atuin_db_rows "$DB")"
    ((after < 0)) && break
    ((after > before)) && break
    sleep 0.1
  done
  # SETTLE — only the drain arm passes this, and only the drain arm needs it. The poll above
  # breaks the instant the count goes UP, which is exactly right for an arm whose expected
  # delta is 0 but wrong for the one arm expecting 1: a build that replays a spool would very
  # plausibly commit this command's own row first and the spooled ones a moment later, and
  # breaking on the first increment would read that as a delta of 1 — the discard signature —
  # from the arm that exists to catch it. One sleep, once, on one arm: the four measurement
  # arms' timing is untouched.
  if [[ "$settle" != 0 ]] && ((after >= 0)); then
    sleep "$settle"
    after="$(atuin_db_rows "$DB")"
  fi
  ((after < 0)) && {
    printf '0|%s|-1|0|%s\n' "$rc" "$err"
    return 0
  }
  # A WELL-FORMED id, not merely a non-empty line. The premise this script measures says
  # atuin "prints a well-formed history id", and the shell then hands that id to
  # `history end` — an empty or malformed one is exactly what crashed 18.16.1. Warning
  # text on stdout would satisfy "non-empty" and produce a false `holds`. atuin emits
  # UUIDv7 in simple hex form: 32 lowercase hex digits, no dashes.
  is_history_id "$id" && idok=1
  printf '1|%s|%s|%s|%s\n' "$rc" "$((after - before))" "$idok" "$err"
}

# A history id as atuin actually emits one: UUIDv7 in 32-character simple-hex form. The
# premise is not "stdout was non-empty" — it is that the shell gets an id it can hand to
# `history end`, which is what 18.16.1's EMPTY id broke. A warning line, a deprecation
# notice or any other stray stdout would satisfy a mere -n test and produce `holds` for a
# build whose output would then fail in a real shell.
is_history_id() { [[ "$1" =~ ^[0-9a-f]{32}$ ]]; }

measure() {
  local line

  have python3 || {
    unmeasurable "python3 is not installed — the row count is what the whole verdict rests on"
    return
  }
  [[ -n "$ATUIN_BIN" ]] || ATUIN_BIN="$(command -v atuin 2>/dev/null)"
  [[ -n "$ATUIN_BIN" && -x "$ATUIN_BIN" ]] || {
    unmeasurable "no executable atuin to measure (looked for --atuin, then PATH)"
    return
  }
  # BOUNDING THE CALL, PORTABLY. macOS ships coreutils' timeout as `gtimeout` and has no
  # plain `timeout` at all — maint/dotfiles-maint.sh's _to() exists for exactly this — so a
  # hard requirement on `timeout` would make this script permanently `unmeasurable` on the
  # macOS third of the fleet, which is a broken detector rather than a cautious one.
  # Where neither exists we still measure, unbounded, and SAY SO: the bound guards against
  # a wedged atuin (the accept-but-silent shape of atuinsh/atuin#3382) hanging a scheduled
  # job, which is a real but narrow hazard — narrower than never measuring at all.
  # `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: macOS ships bash 3.2, where expanding an
  # EMPTY array under `set -u` is an "unbound variable" error rather than zero words.
  if have timeout; then
    TIMEOUT_CMD=(timeout "$TIMEOUT_S")
  elif have gtimeout; then
    TIMEOUT_CMD=(gtimeout "$TIMEOUT_S")
  else
    TIMEOUT_CMD=()
    BOUNDED=false
  fi
  read_anchor || {
    unmeasurable "could not read exactly one '# CORE_ATUIN_GUARD_VERIFIED_AGAINST=' line from zsh/00-tools.zsh — the anchor was renamed, deleted, or duplicated"
    return
  }

  # Bounded by the SAME per-call timeout as the measurement arms. This is the FIRST call the
  # script makes into the binary under test, so an atuin wedged the way atuinsh/atuin#3382
  # wedges one hung here — before any arm ran — until the scheduled job's own 15-minute
  # timeout killed it, producing no verdict at all rather than the promised `unmeasurable`.
  # A timed-out or empty result falls through to AT_VER=unknown, which the anchor comparison
  # below already handles, so the bound costs nothing when the binary is healthy.
  AT_VER="$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$ATUIN_BIN" --version 2>/dev/null |
    grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
  [[ -n "$AT_VER" ]] || AT_VER="unknown"
  if [[ "$AT_VER" != unknown ]]; then
    case "$(ver_cmp "$AT_VER" "$ANCHOR")" in
    0) ANCHOR_REL=same ;;
    1) ANCHOR_REL=newer ;;
    *) ANCHOR_REL=older ;;
    esac
  fi

  # /tmp, not $TMPDIR: AF_UNIX sun_path caps near 108 bytes and macOS's TMPDIR is long
  # enough on its own to blow that — the same reason bench-atuin-daemon.sh hardcodes /tmp.
  LOCALDIR="$(mktemp -d /tmp/atverify.XXXXXX)" || {
    unmeasurable "could not create a sandbox under /tmp"
    return
  }
  SB="$LOCALDIR/home"
  mkdir -p "$SB/.config/atuin" "$SB/.local/share" || {
    unmeasurable "could not build the sandbox tree"
    return
  }

  # MANDATORY, not hygiene: atuin/config.toml leaves [daemon] enabled/autostart UNSET on
  # purpose, because atuin layers the config FILE after the Environment source, so any key
  # written there SHADOWS its ATUIN_* override. Without Core's real config in place, an
  # ATUIN_DAEMON__ENABLED=true below would be silently ignored, every arm would measure the
  # daemon-OFF path, and the run would report a confident, entirely false `moved`.
  cp atuin/config.toml "$SB/.config/atuin/config.toml" 2>/dev/null || {
    unmeasurable "could not copy atuin/config.toml into the sandbox — without it the daemon env override is shadowed and every arm measures the wrong path"
    return
  }

  # env -i, not merely HOME=: anything we do not name — ATUIN_CONFIG_DIR, ATUIN_DB_PATH, a
  # stray ATUIN_DAEMON__* from the caller's shell — would otherwise reach atuin and could
  # point it at the developer's real files. XDG_RUNTIME_DIR is deliberately UNSET so atuin
  # resolves its default socket under the sandbox data dir rather than the real /run/user.
  AT_VARS=(
    "PATH=$PATH"
    "HOME=$SB"
    "XDG_DATA_HOME=$SB/.local/share"
    "XDG_CONFIG_HOME=$SB/.config"
    "XDG_CACHE_HOME=$SB/.cache"
    "XDG_STATE_HOME=$SB/.local/state"
    "TERM=dumb"
  )
  AT_ENV=(env -i "${AT_VARS[@]}")
  DB="$SB/.local/share/atuin/history.db"

  # SEED WITH THE DAEMON OFF. This is the fix for the exact bug the earlier recipe had:
  # seeding through the unreachable-daemon path means that on a build which discards, the DB
  # is never created at all, and every later count reads 0 — which then looks like "the rows
  # did not land", i.e. the premise holding, from an apparatus that never worked.
  "${AT_ENV[@]}" ATUIN_DAEMON__ENABLED=false "ATUIN_SESSION=$(printf '%032x' 0)" \
    ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$ATUIN_BIN" history start -- "verify-seed" >/dev/null 2>&1
  [[ -s "$DB" ]] || {
    unmeasurable "the daemon-off seed did not create a history DB at all — this atuin cannot write in the sandbox, so nothing measured here would mean anything"
    return
  }
  atuin_db_checkpoint "$DB"

  # ── control arm: daemon OFF must write exactly one row ──────────────────────
  # Plain (no --hook) on purpose: this arm proves the APPARATUS can write, and keeping it
  # on the same form the original #366 measurement used keeps the two comparable.
  line="$(run_one control "" no)"
  IFS='|' read -r _ok _rc CTL_DELTA _idok _err <<<"$line"
  if [[ "$_ok" != 1 || "$CTL_DELTA" != 1 ]]; then
    unmeasurable "the daemon-OFF control arm wrote ${CTL_DELTA} rows, not 1 — the apparatus cannot be trusted, so neither can any verdict drawn from it (readok=${_ok}: 0 means the history DB could not be read at all; a delta other than 1 means this atuin's per-command row model is not the one this script encodes)"
    return
  fi

  # ── the measurement matrix: {absent, stale} x {hook, plain} ─────────────────
  # FOUR arms, not two. --hook is the form atuin's own `init zsh` emits from
  # _atuin_preexec, i.e. the only one a real shell in this fleet ever runs; the plain form
  # is what #366 measured and what keeps this comparable to that record. An upstream change
  # scoped to hook mode would break every prompt while a plain-only detector still said
  # `holds`, and a hook-only detector would lose the tie to the original measurement — so
  # both, and `holds` requires all four.
  local shape sock hook
  for shape in absent stale; do
    case "$shape" in
    absent)
      sock="$LOCALDIR/absent.sock"
      ;;
    stale)
      sock="$LOCALDIR/stale.sock"
      make_stale "$sock" || {
        unmeasurable "could not manufacture a stale socket file — the shape a crashed daemon leaves is half of what the guard claims to catch, and an unmeasured half is not a pass"
        return
      }
      ;;
    esac
    prove_unreachable "$sock" || {
      unmeasurable "the ${shape} socket is not actually unreachable — something answered a connect, so a row delta of zero here would mean 'the daemon took it', not 'atuin discarded it'"
      return
    }
    for hook in hook plain; do
      local h=no
      [[ "$hook" == hook ]] && h=yes
      line="$(run_one "${shape}-${hook}" "$sock" "$h")"
      IFS='|' read -r _ok _rc _delta _idok _err <<<"$line"
      [[ "$_ok" == 1 ]] || {
        unmeasurable "the ${shape}/${hook} arm could not read the history DB (row count -1) — an unreadable DB is an apparatus failure, not evidence that upstream changed"
        return
      }
      ARM_NAME+=("${shape}_${hook}")
      ARM_RC+=("$_rc")
      ARM_DELTA+=("$_delta")
      ARM_IDOK+=("$_idok")
      ARM_ERR+=("$_err")
    done
  done

  # ── closing control arm: daemon OFF must STILL write exactly one row ────────
  # Two jobs the opening control cannot do, and the second is why #383 asked for it.
  #
  # (a) It proves the apparatus was still writable AFTER the arms ran. The opening control
  #     proves it at t=0 only, and a DB that goes UNWRITABLE mid-run still READS fine — so
  #     `readok` never fires, all four arms report a delta of 0, and the run reports `holds`
  #     from an apparatus that had quietly stopped working. That is the same
  #     apparatus-versus-upstream conflation the opening control exists to prevent, one step
  #     further along the timeline.
  #
  # (b) It is the cheapest probe of the ONE-WAY-DEGRADE premise (zsh/00-tools.zsh). Core
  #     degrades a shell PERMANENTLY on the first failed connect specifically because atuin
  #     is DISCARDING during the outage, so degrading early is still correct. If atuin ever
  #     buffers and replays instead, that reasoning INVERTS and one-way becomes the wrong
  #     default — and the four arms cannot see the difference, because a spooled entry and a
  #     discarded one both leave the row count at 0 while the socket is unreachable. A build
  #     that spools the four and flushes them on the next successful write lands HERE as a
  #     delta of 5, not 1. A delta of exactly 1 does not DISPROVE buffering — a spool only a
  #     live daemon would drain is out of reach without spawning one — and the report says so
  #     rather than implying coverage.
  #
  # Plain, no --hook, matching the opening control: this arm measures the apparatus, and
  # keeping the two controls on the same form makes their deltas directly comparable.
  line="$(run_one drain "" no 1)"
  IFS='|' read -r _ok _rc DRAIN_DELTA _idok _err <<<"$line"
  if [[ "$_ok" != 1 ]] || ((DRAIN_DELTA < 1)); then
    unmeasurable "the CLOSING daemon-off control arm wrote ${DRAIN_DELTA} rows, not 1 — the apparatus stopped writing partway through this run, so the zeros the four arms reported are not evidence about upstream (readok=${_ok}: 0 means the history DB could not be read at all)"
    return
  fi

  # ── the verdict ─────────────────────────────────────────────────────────────
  # `holds` is the CONJUNCTION of every property zsh/00-tools.zsh claims, on every arm.
  # Written as an explicit list of failures rather than one boolean, so the report can say
  # WHICH property moved on WHICH arm — "it changed" is not actionable, and the remedy
  # differs depending on whether it now errors, now writes, or now says something.
  local -a diffs=()
  local n
  for ((n = 0; n < ${#ARM_NAME[@]}; n++)); do
    local a="${ARM_NAME[n]//_/ }"
    [[ "${ARM_RC[n]}" == 0 ]] || diffs+=("${a}: exit code is ${ARM_RC[n]}, was 0")
    [[ "${ARM_DELTA[n]}" == 0 ]] || diffs+=("${a}: the row count changed by ${ARM_DELTA[n]}, was 0 (it no longer discards)")
    [[ -z "${ARM_ERR[n]}" ]] || diffs+=("${a}: it now writes to stderr — \"${ARM_ERR[n]}\"")
    [[ "${ARM_IDOK[n]}" == 1 ]] || diffs+=("${a}: stdout is not a well-formed history id (32 hex digits), and a malformed id is what crashed \`history end\` on 18.16.1")
  done
  # The drain arm reads as a `moved` finding only ABOVE 1 — below it is an apparatus failure
  # and was already turned into `unmeasurable` above. Routed through the same `diffs` list as
  # the arms so the "say WHICH property moved" reporting is reused rather than forked, and so
  # a run where both the arms AND the drain moved reports both.
  ((DRAIN_DELTA == 1)) || diffs+=("drain: the first successful write after four unreachable ones landed ${DRAIN_DELTA} rows, not 1 — this atuin BUFFERS and replays rather than discarding, which INVERTS the premise the one-way degrade in zsh/00-tools.zsh rests on")

  if ((${#diffs[@]})); then
    local joined="" d
    for d in "${diffs[@]}"; do joined+="; $d"; done
    moved "${joined#; }"
  else
    VERDICT=holds
    REASON="all ${#ARM_NAME[@]} arms ($(arms_sentence)) still exit 0, print a well-formed id, stay silent on stderr, and discard the entry — and the daemon-off write that followed them landed exactly 1 row, so nothing was spooled and replayed"
  fi
}

# ── render ────────────────────────────────────────────────────────────────────
# What this run actually measured, DERIVED from ARM_NAME rather than written out beside the
# loop that fills it. Both prose claims about coverage — the `holds` reason and the report —
# read from here, because a hand-written coverage claim is a second copy of the matrix and the
# second copy is the one that rots: the arm list was extended to four in review, and the
# report's scope paragraph went on saying `--hook` was not exercised while two hook arms ran,
# in the same output as a reason that said "all four arms (absent/stale x hook/plain)".
# An empty list is a legitimate answer — an `unmeasurable` run measured nothing, and saying
# that is more useful than inheriting a list from a run that did.
arms_sentence() {
  local n out=""
  ((${#ARM_NAME[@]})) || {
    printf 'nothing — no arm ran'
    return
  }
  for ((n = 0; n < ${#ARM_NAME[@]}; n++)); do out+=", ${ARM_NAME[n]//_/ / }"; done
  printf '%s' "${out#, }"
}

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null; }

emit_json() {
  printf '{"verdict":"%s","reason":"%s","atuin_version":"%s","anchor":"%s","anchor_relation":"%s",' \
    "$VERDICT" "$(json_escape "$REASON")" "$AT_VER" "$ANCHOR" "$ANCHOR_REL"
  printf '"control_delta":%s,"drain_delta":%s,"bounded":%s,"arms":{' \
    "${CTL_DELTA:--1}" "${DRAIN_DELTA:--1}" "$BOUNDED"
  local n first=1
  for ((n = 0; n < ${#ARM_NAME[@]}; n++)); do
    ((first)) || printf ','
    first=0
    printf '"%s":{"rc":%s,"delta":%s,"stderr_empty":%s,"id_wellformed":%s}' \
      "${ARM_NAME[n]}" "${ARM_RC[n]}" "${ARM_DELTA[n]}" \
      "$([[ -z "${ARM_ERR[n]}" ]] && echo true || echo false)" \
      "$([[ "${ARM_IDOK[n]}" == 1 ]] && echo true || echo false)"
  done
  printf '}}\n'
}

# shellcheck disable=SC2016  # the backticks below are MARKDOWN code spans in the report,
# not command substitution — single quotes are exactly right for a printf format string.
emit_report() {
  # No title heading: .github/workflows/file-routine-issue.sh supplies one, and a second
  # would nest under it. Issue-ready markdown, so a human can act without opening the run.
  {
    printf '**Verdict: `%s`**\n\n%s\n\n' "$VERDICT" "$REASON"
    printf '| | |\n| --- | --- |\n'
    printf '| atuin measured | `%s` |\n' "$AT_VER"
    printf '| verified-against anchor (`zsh/00-tools.zsh`) | `%s` (%s) |\n' "$ANCHOR" "$ANCHOR_REL"
    printf '| daemon-off control arm (opening) | wrote %s row(s) — must be 1 |\n' "$CTL_DELTA"
    printf '| daemon-off control arm (closing) | wrote %s row(s) — must be 1; above 1 means the unreachable arms were spooled and replayed |\n' "$DRAIN_DELTA"
    [[ "$BOUNDED" == true ]] ||
      printf '| call bound | **none** — no `timeout`/`gtimeout` on this box, so a wedged atuin could not have been cut short |\n'
    local n
    for ((n = 0; n < ${#ARM_NAME[@]}; n++)); do
      printf '| %s | rc %s, delta %s, stderr %s, id %s |\n' \
        "${ARM_NAME[n]//_/ / }" "${ARM_RC[n]}" "${ARM_DELTA[n]}" \
        "$([[ -z "${ARM_ERR[n]}" ]] && echo empty || echo "\"${ARM_ERR[n]}\"")" \
        "$([[ "${ARM_IDOK[n]}" == 1 ]] && echo well-formed || echo MALFORMED)"
    done
    printf '\n'
    case "$VERDICT" in
    moved)
      printf 'The premise `_core_atuin_daemon_guard` rests on has changed, so the rationale block in `zsh/00-tools.zsh` is now overclaiming. Decide deliberately whether the guard should be **retired**, **version-gated**, or **reshaped** — and weigh it as an eight-repo change: retiring it removes a `precmd` hook from every interactive shell in the fleet. Re-measure by hand before deciding; do not act on this report alone.\n\n'
      printf 'If the premise is genuinely gone, the anchor line `# CORE_ATUIN_GUARD_VERIFIED_AGAINST=` in `zsh/00-tools.zsh` should only move as part of that decision — editing it is a claim that the premise was re-measured, not a version bump.\n\n'
      ;;
    unmeasurable)
      printf 'This is **not** good news and must not be read as one. The check could not establish anything, so the guard'"'"'s justification is currently unverified rather than confirmed. Repair the detector (`scripts/verify-atuin-guard.sh`), then re-run.\n\n'
      ;;
    holds)
      printf 'No action needed. The guard still earns its place.\n\n'
      ;;
    esac
    printf -- '**Measured here:** %s.\n\n' "$(arms_sentence)"
    printf -- '---\n\n**Scope this does not cover**, stated so it is not mistaken for coverage. Linux x86_64 **glibc only** — the Alpine/musl half of the fleet is unmeasured. The **`autostart` stand-down** is unmeasured too, and it is the ONLY mitigation on the two machines that take it (Alpine, macOS): this run never sets `ATUIN_DAEMON__AUTOSTART`, so "atuin health-checks its own daemon" stays an assumption here rather than a measurement, and testing it would mean spawning a real daemon and owning its teardown. **Buffer-and-replay** is probed only by the closing daemon-off control arm above; a spool that only a live daemon would drain is out of reach for the same reason. The accept-but-silent socket (`atuinsh/atuin#3382`) is structurally out of scope: this measures *unreachable*, and that shape is *reachable and lying*.\n'
  } >"$REPORT"
}

# ── main ──────────────────────────────────────────────────────────────────────
if [[ -n "$FORCED_UNMEASURABLE" ]]; then
  # A caller that failed before a binary ever existed (a download, a checksum, an
  # attestation) reports through this same renderer, so the wording a human reads cannot
  # drift from the code that produces it.
  unmeasurable "$FORCED_UNMEASURABLE"
else
  measure
fi

# Belt and braces: an unset verdict is a bug in the flow above, and the safe reading of a
# bug is "we do not know", never "all is well".
[[ -n "$VERDICT" ]] || unmeasurable "internal: no verdict was reached (this is a bug in verify-atuin-guard.sh)"

[[ -n "$REPORT" ]] && emit_report
if ((JSON)); then
  emit_json
else
  case "$VERDICT" in
  holds) pass "atuin guard premise HOLDS on ${AT_VER} — $REASON" ;;
  moved) fail "atuin guard premise MOVED on ${AT_VER} — $REASON" ;;
  *) skip "atuin guard premise UNMEASURABLE — $REASON" ;;
  esac
fi

case "$VERDICT" in
holds) exit 0 ;;
moved) exit 1 ;;
*) exit 3 ;;
esac
