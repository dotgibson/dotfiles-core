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
#   holds         the control arm wrote, and BOTH unreachable shapes gave rc 0, an id on
#                 stdout, empty stderr, and a row delta of exactly 0. The guard still earns
#                 its place on every prompt in the fleet.
#   moved         the control arm wrote, and something about an unreachable shape is now
#                 different. zsh/00-tools.zsh's rationale block is OVERCLAIMING, and the
#                 guard needs retiring, version-gating or reshaping — a human decision,
#                 weighed as an eight-repo change.
#   unmeasurable  the apparatus could not be trusted: no atuin, no python3, the anchor could
#                 not be read, the sandbox could not be built, the row count came back -1,
#                 unreachability could not be PROVEN, or the control arm did not write.
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
    _core_set_color "$1"
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
Each is PROVEN unreachable before anything is written, so a verdict can never rest on a
socket that was quietly healthy.

A daemon-OFF control arm runs first and must write exactly one row. It is the apparatus
check: if the control cannot write, nothing observed afterwards means anything, and the
verdict is `unmeasurable` rather than a guess.

VERDICTS AND EXIT CODES
  0  holds         control wrote; both shapes: rc 0, id printed, empty stderr, delta 0
  1  moved         control wrote; something differs — the rationale now overclaims
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
ABSENT_RC=-1 ABSENT_DELTA=-1 ABSENT_ERR="" ABSENT_ID=""
STALE_RC=-1 STALE_DELTA=-1 STALE_ERR="" STALE_ID=""
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

# shellcheck disable=SC2329  # invoked indirectly, by the EXIT trap below
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
  hits="$(sed -n 's/^# CORE_ATUIN_GUARD_VERIFIED_AGAINST=\([0-9][0-9.]*\)[[:space:]]*$/\1/p' \
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
# run_one <label-var-prefix> <socket-path-or-empty> — one `atuin history start` under the
# sandbox env, capturing rc, stdout (the history id) and stderr, and the row delta it caused.
# An empty socket path means the daemon-OFF control arm.
DB=""
run_one() {
  local mode="$1" sock="$2" before after rc id err
  local -a env_extra=()
  if [[ -n "$sock" ]]; then
    env_extra=("ATUIN_DAEMON__ENABLED=true" "ATUIN_DAEMON__SOCKET_PATH=$sock")
  else
    env_extra=("ATUIN_DAEMON__ENABLED=false")
  fi
  before="$(atuin_db_rows "$DB")"
  ((before < 0)) && {
    printf -- '-1|-1||\n'
    return 0
  }
  id="$("${AT_ENV[@]}" "${env_extra[@]}" \
    "ATUIN_SESSION=$(printf '%032x' 1)" \
    ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$ATUIN_BIN" history start -- "verify-$mode" 2>"$SB/err.$mode")"
  rc=$?
  err="$(tr -d '\n' <"$SB/err.$mode" 2>/dev/null | cut -c1-200)"
  # A daemon-owned write can be committed slightly after the client returns, so give the
  # row a bounded moment to appear before concluding it never did. Bounded and short: the
  # expected delta here is 0, and waiting long for a 0 proves nothing, but NOT waiting at
  # all would manufacture a false `holds` on a build that writes asynchronously.
  local i
  for ((i = 0; i < 20; i++)); do
    after="$(atuin_db_rows "$DB")"
    ((after > before)) && break
    sleep 0.1
  done
  printf '%s|%s|%s|%s\n' "$rc" "$((after - before))" "$err" "$id"
}

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

  AT_VER="$("$ATUIN_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
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
  line="$(run_one control "")"
  CTL_DELTA="${line#*|}"
  CTL_DELTA="${CTL_DELTA%%|*}"
  if [[ "$CTL_DELTA" != 1 ]]; then
    unmeasurable "the daemon-OFF control arm wrote ${CTL_DELTA} rows, not 1 — the apparatus cannot be trusted, so neither can any verdict drawn from it (a row-count of -1 means the DB could not be read; anything else means this atuin's per-command row model is not the one this script encodes)"
    return
  fi

  # ── arm 1: an ABSENT socket ─────────────────────────────────────────────────
  local absent="$LOCALDIR/absent.sock"
  prove_unreachable "$absent" || {
    unmeasurable "something is listening on the socket path that is supposed to be absent — refusing to measure"
    return
  }
  line="$(run_one absent "$absent")"
  IFS='|' read -r ABSENT_RC ABSENT_DELTA ABSENT_ERR ABSENT_ID <<<"$line"

  # ── arm 2: a STALE socket file with nothing behind it ───────────────────────
  local stale="$LOCALDIR/stale.sock"
  if ! make_stale "$stale"; then
    unmeasurable "could not manufacture a stale socket file — the shape a crashed daemon leaves is half of what the guard claims to catch, and an unmeasured half is not a pass"
    return
  fi
  prove_unreachable "$stale" || {
    unmeasurable "the stale socket still has a listener behind it — refusing to measure"
    return
  }
  line="$(run_one stale "$stale")"
  IFS='|' read -r STALE_RC STALE_DELTA STALE_ERR STALE_ID <<<"$line"

  # ── the verdict ─────────────────────────────────────────────────────────────
  # `holds` is the CONJUNCTION of every property zsh/00-tools.zsh claims, on both shapes.
  # Written as an explicit list of failures rather than one boolean, so the report can say
  # WHICH property moved — "it changed" is not actionable, and the remedy differs.
  local -a diffs=()
  [[ "$ABSENT_RC" == 0 ]] || diffs+=("absent-socket: exit code is $ABSENT_RC, was 0")
  [[ "$STALE_RC" == 0 ]] || diffs+=("stale-socket: exit code is $STALE_RC, was 0")
  [[ "$ABSENT_DELTA" == 0 ]] || diffs+=("absent-socket: the row count changed by $ABSENT_DELTA, was 0 (it no longer discards)")
  [[ "$STALE_DELTA" == 0 ]] || diffs+=("stale-socket: the row count changed by $STALE_DELTA, was 0 (it no longer discards)")
  [[ -z "$ABSENT_ERR" ]] || diffs+=("absent-socket: it now writes to stderr — \"$ABSENT_ERR\"")
  [[ -z "$STALE_ERR" ]] || diffs+=("stale-socket: it now writes to stderr — \"$STALE_ERR\"")
  [[ -n "$ABSENT_ID" ]] || diffs+=("absent-socket: no history id on stdout, and an empty id is what crashed \`history end\` on 18.16.1")
  [[ -n "$STALE_ID" ]] || diffs+=("stale-socket: no history id on stdout, and an empty id is what crashed \`history end\` on 18.16.1")

  if ((${#diffs[@]})); then
    local joined=""
    local d
    for d in "${diffs[@]}"; do joined+="; $d"; done
    moved "${joined#; }"
  else
    VERDICT=holds
    REASON="both unreachable shapes still exit 0, print an id, stay silent on stderr, and discard the entry"
  fi
}

# ── render ────────────────────────────────────────────────────────────────────
json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null; }

emit_json() {
  printf '{"verdict":"%s","reason":"%s","atuin_version":"%s","anchor":"%s","anchor_relation":"%s",' \
    "$VERDICT" "$(json_escape "$REASON")" "$AT_VER" "$ANCHOR" "$ANCHOR_REL"
  printf '"control_delta":%s,"bounded":%s,' "${CTL_DELTA:--1}" "$BOUNDED"
  printf '"absent":{"rc":%s,"delta":%s,"stderr_empty":%s,"id_present":%s},' \
    "${ABSENT_RC:--1}" "${ABSENT_DELTA:--1}" \
    "$([[ -z "$ABSENT_ERR" ]] && echo true || echo false)" \
    "$([[ -n "$ABSENT_ID" ]] && echo true || echo false)"
  printf '"stale":{"rc":%s,"delta":%s,"stderr_empty":%s,"id_present":%s}}\n' \
    "${STALE_RC:--1}" "${STALE_DELTA:--1}" \
    "$([[ -z "$STALE_ERR" ]] && echo true || echo false)" \
    "$([[ -n "$STALE_ID" ]] && echo true || echo false)"
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
    printf '| daemon-off control arm | wrote %s row(s) — must be 1 |\n' "$CTL_DELTA"
    [[ "$BOUNDED" == true ]] ||
      printf '| call bound | **none** — no `timeout`/`gtimeout` on this box, so a wedged atuin could not have been cut short |\n'
    printf '| absent socket | rc %s, delta %s, stderr %s, id %s |\n' \
      "$ABSENT_RC" "$ABSENT_DELTA" \
      "$([[ -z "$ABSENT_ERR" ]] && echo empty || echo "\"$ABSENT_ERR\"")" \
      "$([[ -n "$ABSENT_ID" ]] && echo present || echo MISSING)"
    printf '| stale socket | rc %s, delta %s, stderr %s, id %s |\n\n' \
      "$STALE_RC" "$STALE_DELTA" \
      "$([[ -z "$STALE_ERR" ]] && echo empty || echo "\"$STALE_ERR\"")" \
      "$([[ -n "$STALE_ID" ]] && echo present || echo MISSING)"
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
    printf -- '---\n\n**Scope this does not cover**, stated so it is not mistaken for coverage: Linux x86_64 **glibc only** — the Alpine/musl half of the fleet is unmeasured, and musl is exactly where the `autostart` path lives. `--hook` is not exercised. The accept-but-silent socket (`atuinsh/atuin#3382`) is structurally out of scope: this measures *unreachable*, and that shape is *reachable and lying*.\n'
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
