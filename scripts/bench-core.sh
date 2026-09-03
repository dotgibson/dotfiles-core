#!/usr/bin/env bash
# scripts/bench-core.sh
# ──────────────────────────────────────────────────────────────────────────────
# Measure Core's contribution to interactive-shell startup time — the metric this
# repo invests in (cached starship/zoxide/mise/atuin init in 00-tools.zsh, deferred
# heavy plugins in 45-plugins.zsh) but never actually MEASURED, so a regression could
# ship silently to all nine OS repos. This is the missing perf guard: run it before
# and after a change to the load path to see the delta.
#
# It benchmarks the SAME canonical load chain scripts/test-core.sh asserts, in the
# SAME hermetic sandbox (throwaway HOME/ZDOTDIR, pre-seeded EMPTY plugin dirs so
# the first-run clone is a no-op) — so the number reflects Core's own load cost,
# reproducibly and with no network.
#
# Graceful degradation (mirrors audit-core.sh / test-core.sh): with no zsh OR no
# hyperfine it SKIPs and exits 0, so it is safe to call anywhere. hyperfine is the
# tool 00-tools.zsh already detects as HAVE_HYPERFINE and the perf note in 00-tools.zsh
# already points at (`hyperfine 'zsh -i -c exit'`).
#
# Three modes (#688):
#   • report (default)  prints the mean and how it compares to the COMMITTED baseline in
#                       scripts/bench-baseline.env — the trend line. Never fails.
#   • --gate            what CI's `bench` job runs: FAIL (exit 1) when the mean exceeds the
#                       CORE_BENCH_BUDGET_MS committed in scripts/bench-baseline.env. The
#                       budget lives next to the script it governs, not in workflow YAML.
#                       A breach also prints the per-module profile so the red log names
#                       the culprit. Fails CLOSED: a missing/malformed baseline file, or a
#                       missing zsh/hyperfine/python3, is exit 1 here — a gate that cannot
#                       measure must not be green.
#   • CORE_BENCH_BUDGET_MS=<ms> in the environment overrides the file's budget (ad-hoc
#                       gate; the pre-#688 interface). Env wins over the file for the
#                       NUMBER; under --gate the file is still validated.
# Enforcement needs python3 to read hyperfine's JSON.
#
# Usage:
#   ./scripts/bench-core.sh                          # report the mean vs the committed baseline
#   ./scripts/bench-core.sh --gate                   # enforce scripts/bench-baseline.env (CI)
#   ./scripts/bench-core.sh --profile                # per-module breakdown, slowest first
#   CORE_BENCH_RUNS=20 ./scripts/bench-core.sh       # override the min run count
#   CORE_BENCH_BUDGET_MS=60 ./scripts/bench-core.sh  # ad-hoc gate: FAIL if mean > 60 ms
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# Shared palette + have()/skip() (this script keeps its own bench-table printfs).
# shellcheck source=scripts/lib/common.sh
source "${BASH_SOURCE[0]%/*}/lib/common.sh"

# Tuning is via env (CORE_BENCH_RUNS / CORE_BENCH_BUDGET_MS, see header). Flags: --gate
# (enforce the committed budget), --profile (B11: per-module cost attribution) and -h/--help.
# Parse EVERY arg and reject an unknown one (or a stray extra) rather than ignore it — same
# fail-closed contract as the gates.
PROFILE=0
GATE=0
while (($#)); do
  case "$1" in
  --profile) PROFILE=1 ;;
  --gate) GATE=1 ;;
  -h | --help)
    cat <<'EOF'
usage: bench-core.sh [--gate] [--profile] [-h|--help]

Hermetic benchmark of the canonical zsh load chain. Report-only unless --gate or a budget is set.

  --gate                      FAIL (exit 1) if the mean exceeds CORE_BENCH_BUDGET_MS from
                              scripts/bench-baseline.env — what CI's bench job runs. A breach
                              also prints the per-module profile. Fails closed: a missing or
                              malformed baseline file, or no zsh/hyperfine/python3, is exit 1.
  --profile                   per-module load-cost breakdown (attributes the total to
                              each module, slowest first) instead of the aggregate mean —
                              so a regression points at the culprit module. Needs zsh only.
                              Not combinable with --gate (one sample is not a measurement).
  -h, --help                  show this help and exit

Tuning via environment:
  CORE_BENCH_RUNS=<n>          minimum hyperfine runs (default 10; CI uses 50)
  CORE_BENCH_BUDGET_MS=<ms>    ad-hoc gate: FAIL if the mean exceeds this. Overrides the
                               committed budget when combined with --gate (needs python3)
  CORE_BENCH_BASELINE_FILE=<p> read the baseline/budget from <p> instead of
                               scripts/bench-baseline.env (the test suite's hook)

The report and gate modes print the mean against CORE_BENCH_BASELINE_MS (the committed
ubuntu-latest figure) so a local run shows the trend; --profile prints only the breakdown.
Under --gate the committed file is validated even when the env override selects the budget.
Re-baseline policy: see scripts/bench-baseline.env.
EOF
    exit 0
    ;;
  *)
    printf 'bench-core.sh: unexpected argument: %s\n' "$1" >&2
    printf 'try: bench-core.sh --help\n' >&2
    exit 2
    ;;
  esac
  shift
done
if ((GATE && PROFILE)); then
  printf 'bench-core.sh: --gate and --profile are mutually exclusive (--profile is a one-sample breakdown, not a measurement to gate on)\n' >&2
  exit 2
fi

# ── committed baseline (scripts/bench-baseline.env) ───────────────────────────
# Resolved BEFORE the zsh/hyperfine probes so a malformed file is reported (and testable)
# on any box. The reader is audit-core.sh §9's tool-versions.env idiom — never `source`,
# which would execute the file.
BASELINE_FILE="${CORE_BENCH_BASELINE_FILE:-$HERE/scripts/bench-baseline.env}"
_baseline_get() { # _baseline_get <KEY> — first KEY=VALUE line, or nothing
  [[ -r "$BASELINE_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$BASELINE_FILE" | head -n1
}
# _is_ms <value> — a positive decimal (digits, at most one dot). Shape via case (bash 3.2-safe,
# no =~ quoting trap); positivity via awk, since bash has no floats.
_is_ms() {
  case "${1:-}" in '' | *[!0-9.]* | . | *.*.*) return 1 ;; esac
  awk -v v="$1" 'BEGIN { exit !(v > 0) }'
}
BASELINE_MS="$(_baseline_get CORE_BENCH_BASELINE_MS)"
FILE_BUDGET_MS="$(_baseline_get CORE_BENCH_BUDGET_MS)"
BUDGET="${CORE_BENCH_BUDGET_MS:-}"
BUDGET_SRC="env"
if [[ -n "$BUDGET" ]] && ! _is_ms "$BUDGET"; then
  printf 'bench-core.sh: CORE_BENCH_BUDGET_MS must be a positive number of ms, got: %s\n' "$BUDGET" >&2
  exit 2
fi
if ((GATE)); then
  # Fail CLOSED: a gate that cannot find its budget must not go green. The committed file is
  # validated on EVERY --gate run — an env override selects the budget, it does not excuse a
  # missing or malformed contract (otherwise `CORE_BENCH_BUDGET_MS=48 --gate` would green a
  # deleted baseline file).
  if [[ ! -r "$BASELINE_FILE" ]]; then
    printf '%s✗%s --gate: baseline file missing or unreadable: %s\n' "$c_red" "$c_rst" "$BASELINE_FILE" >&2
    exit 1
  fi
  if ! _is_ms "$BASELINE_MS" || ! _is_ms "$FILE_BUDGET_MS"; then
    printf '%s✗%s --gate: %s must set CORE_BENCH_BASELINE_MS and CORE_BENCH_BUDGET_MS to positive numbers (got %s / %s)\n' \
      "$c_red" "$c_rst" "$BASELINE_FILE" "${BASELINE_MS:-<unset>}" "${FILE_BUDGET_MS:-<unset>}" >&2
    exit 1
  fi
  if ! awk -v b="$BASELINE_MS" -v g="$FILE_BUDGET_MS" 'BEGIN { exit !(g > b) }'; then
    printf '%s✗%s --gate: budget %s ms must exceed baseline %s ms (%s) — a budget with no headroom reds every run\n' \
      "$c_red" "$c_rst" "$FILE_BUDGET_MS" "$BASELINE_MS" "$BASELINE_FILE" >&2
    exit 1
  fi
  if [[ -z "$BUDGET" ]]; then
    BUDGET="$FILE_BUDGET_MS"
    BUDGET_SRC="$BASELINE_FILE"
  fi
fi

# ── prerequisites: report mode degrades, --gate fails closed ──────────────────
_gate_needs() { # _gate_needs <tool> — under --gate an absent tool is a red run, not a skip
  printf '%s✗%s --gate needs %s (a gate that cannot measure must not be green)\n' "$c_red" "$c_rst" "$1" >&2
  exit 1
}
if ! have zsh; then
  ((GATE)) && _gate_needs zsh
  skip "bench skipped (zsh not installed)"
  exit 0
fi
# hyperfine is only needed for the aggregate benchmark, NOT for --profile (which times
# each module in-process via zsh/datetime) — so don't skip the profile run for its absence.
if ((!PROFILE)) && ! have hyperfine; then
  ((GATE)) && _gate_needs hyperfine
  skip "bench skipped (hyperfine not installed — 00-tools.zsh detects it as HAVE_HYPERFINE)"
  exit 0
fi
if ((GATE)) && ! have python3; then
  _gate_needs "python3 (reads hyperfine's JSON)"
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/core-bench.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# The sandbox ZDOTDIR (holds the generated .zshrc). v4: plugins moved to $XDG_DATA_HOME,
# so seeding them no longer creates $SANDBOX/zdot as a side effect — make it explicitly.
mkdir -p "$SANDBOX/zdot"
# Pre-seed empty plugin dirs so 45-plugins.zsh's first-run `git clone` is a no-op
# (hermetic, no network) — v4: plugins live under $XDG_DATA_HOME/zsh/plugins, not $ZDOTDIR.
_seed_plugin_dirs "$SANDBOX/data/zsh/plugins"

# The numbered Core fragments in load order (no os/local — those belong to OS repos). Used
# by the --profile per-module attribution below (which times each source individually).
# Must match what the loader globs from zsh/ — a fragment missing here is one the breach
# profile can neither time nor name (02-capabilities was absent until a #688 review catch).
CORE_MODULES=(00-tools 02-capabilities 05-ui 10-options 15-history 20-aliases 25-git 30-functions 35-fzf 40-bindings 45-plugins 50-op 55-maint 60-update)
export CORE_DIR="$HERE/zsh"

# AGGREGATE benchmark: drive the REAL v4 loader against a symlinked $ZSH_CFG (like the smoke
# test), so the number includes the glob, the sort and the compile/wordcode fast path —
# a faithful production startup, and a regression in the loader itself is now visible. (The
# --profile mode below keeps direct per-fragment sourcing, which is what per-module timing needs.)
ln -s "$HERE/zsh/loader.zsh" "$SANDBOX/zdot/loader.zsh"
for f in "$HERE"/zsh/[0-9][0-9]-*.zsh; do ln -s "$f" "$SANDBOX/zdot/$(basename "$f")"; done
# $ZDOTDIR/$ZSH_CFG stay LITERAL in the written .zshrc (expanded by the zsh child at startup,
# not this bash parent) — so the single quotes are intentional. shellcheck disable=SC2016
# shellcheck disable=SC2016
printf 'ZSH_CFG="$ZDOTDIR"\nsource "$ZSH_CFG/loader.zsh"\n' >"$SANDBOX/zdot/.zshrc"

# ── per-module cost attribution (B11) ─────────────────────────────────────────
# The aggregate mean tells you startup got slower; it doesn't tell you WHICH module. This
# sources the canonical chain in ONE hermetic interactive zsh, timing each module with
# zsh/datetime's $EPOCHREALTIME, and prints the breakdown slowest-first — so a regression
# points at the culprit. Informational (never gated: one sample per module is too noisy to
# gate on); needs zsh only, not hyperfine. Called by --profile AND by a --gate breach, so the
# red CI log localises the regression instead of reporting one aggregate (#688).
_profile_modules() {
  local prof_body
  # shellcheck disable=SC2016  # $EPOCHREALTIME/$m/$CORE_DIR expand in the zsh CHILD.
  prof_body='zmodload zsh/datetime
    typeset -F prev=$EPOCHREALTIME now total=0
    for _m in '"${CORE_MODULES[*]}"'; do
      source "$CORE_DIR/$_m.zsh" 2>/dev/null
      now=$EPOCHREALTIME
      printf "%8.1f ms  %s\n" $(( (now-prev)*1000 )) "$_m"
      (( total += (now-prev)*1000 )); prev=$now
    done
    printf "%8.1f ms  %s\n" $total "TOTAL"'
  # `-f` (NO_RCS): the child must NOT run the sandbox .zshrc first — with ZDOTDIR pointing at
  # it, an interactive zsh would source the loader (and so every module) before prof_body
  # even starts, and the breakdown would time a warm RE-source, which can point at the wrong
  # module (a #688 review catch; --profile had always done this). ZSH_CFG is what the loader
  # would have set, so a fragment that reads it sees the same value as at real startup.
  HOME="$SANDBOX" ZDOTDIR="$SANDBOX/zdot" ZSH_CFG="$SANDBOX/zdot" \
    XDG_CACHE_HOME="$SANDBOX/cache" XDG_STATE_HOME="$SANDBOX/state" \
    XDG_RUNTIME_DIR="$SANDBOX/run" XDG_DATA_HOME="$SANDBOX/data" CORE_DIR="$CORE_DIR" \
    zsh -f -ic "$prof_body" 2>/dev/null | sort -rn | sed "s/^/  /"
  printf '%s(per-module wall time of a cold first sourcing; TOTAL sorts to the top — run twice, the 2nd is fs-warm)%s\n' "$c_blu" "$c_rst"
}
if ((PROFILE)); then
  printf '\n%s== Core startup profile (per-module, hermetic) ==%s\n' "$c_blu" "$c_rst"
  _profile_modules
  exit 0
fi

runs="${CORE_BENCH_RUNS:-10}"
printf '\n%s== Core startup benchmark (canonical .zshrc chain, hermetic) ==%s\n' "$c_blu" "$c_rst"

# `zsh -i -c exit` sources the sandbox .zshrc (interactive, so the modules' `[[ $-
# == *i* ]]` guards pass) and exits. --warmup primes the fs/exec cache so the
# reported mean is steady-state, not first-run cold. --export-json captures the
# mean for the verdict below (the human table still prints).
json="$SANDBOX/bench.json"
HOME="$SANDBOX" ZDOTDIR="$SANDBOX/zdot" \
  XDG_CACHE_HOME="$SANDBOX/cache" XDG_STATE_HOME="$SANDBOX/state" \
  XDG_RUNTIME_DIR="$SANDBOX/run" XDG_DATA_HOME="$SANDBOX/data" CORE_DIR="$CORE_DIR" \
  hyperfine --warmup 3 --min-runs "$runs" --export-json "$json" 'zsh -i -c exit'

# ── verdict: report vs the committed baseline; gate vs the budget ─────────────
# hyperfine's JSON reports seconds; ONE python3 call converts mean + median to ms, and awk
# does the arithmetic from there (bash has no floats). No budget → report only; a budget
# with no python3 → loud skip rather than a false pass (the gate must be honest; --gate
# already refused above, so this leg is the env-override path).
if ! have python3; then
  if [[ -n "$BUDGET" ]]; then
    skip "budget set ($BUDGET ms) but python3 absent — cannot read hyperfine JSON; not gating"
  else
    skip "baseline comparison needs python3 to read hyperfine JSON — the table above is the result"
  fi
  exit 0
fi
mean_ms=""
median_ms=""
read -r mean_ms median_ms < <(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))["results"][0]
print(r["mean"] * 1000, r["median"] * 1000)' "$json" 2>/dev/null)
if [[ -z "$mean_ms" || -z "$median_ms" ]]; then
  printf '%s✗%s could not parse hyperfine JSON for the verdict\n' "$c_red" "$c_rst" >&2
  exit 1
fi

_pct() { awk -v v="$1" -v b="$2" 'BEGIN { printf "%+.0f", (v - b) / b * 100 }'; } # _pct <value> <base>
vs_base=""
if _is_ms "$BASELINE_MS"; then
  vs_base="$(printf ' (CI baseline %s ms, %s%%)' "$BASELINE_MS" "$(_pct "$mean_ms" "$BASELINE_MS")")"
fi

if [[ -z "$BUDGET" ]]; then
  printf '%s·%s startup mean %.1f ms, median %.1f ms%s — report only; --gate enforces %s ms\n' \
    "$c_blu" "$c_rst" "$mean_ms" "$median_ms" "$vs_base" "${FILE_BUDGET_MS:-<no committed budget>}"
  exit 0
fi
src_note=""
[[ "$BUDGET_SRC" == env ]] && src_note=" (CORE_BENCH_BUDGET_MS override)"
if awk -v m="$mean_ms" -v b="$BUDGET" 'BEGIN { exit !(m <= b) }'; then
  printf '%s✓%s startup mean %.1f ms (median %.1f) within budget %s ms%s%s\n' \
    "$c_grn" "$c_rst" "$mean_ms" "$median_ms" "$BUDGET" "$src_note" "$vs_base"
  exit 0
fi
printf '%s✗%s startup mean %.1f ms (median %.1f) EXCEEDS budget %s ms%s%s — perf regression\n' \
  "$c_red" "$c_rst" "$mean_ms" "$median_ms" "$BUDGET" "$src_note" "$vs_base" >&2
if awk -v m="$median_ms" -v b="$BUDGET" 'BEGIN { exit !(m <= b) }'; then
  printf '  note: the median IS within budget — the mean is outlier-driven (runner hiccup?); re-run before chasing a regression\n' >&2
fi
# Localise it: the red log should name the module, not just the aggregate.
printf '\n%s== per-module profile (single sample, to localise the regression) ==%s\n' "$c_blu" "$c_rst"
_profile_modules
exit 1
