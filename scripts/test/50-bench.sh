# scripts/test/50-bench.sh
# atuin daemon bench harness + the startup budget gate (bench-core.sh --gate)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the atuin daemon bench harness (scripts/research/bench-atuin-daemon.sh) ────────────
# The bench itself needs a real atuin, a real zsh and a background daemon, so `make audit`
# can never run it — which is exactly why its FAIL-CLOSED surface is worth pinning here.
# Everything below is pure bash + python3: no atuin, no zsh, no systemd bus.
#
# What is deliberately NOT covered: the row-count rule end to end. Driving it would need a
# stub atuin AND a stub zsh emulating zsh/datetime's $EPOCHREALTIME — a large, brittle fake
# of the very thing under measurement. (run_writers' short-arm refusal has the same status:
# validated by running the bench on a box that has atuin, not by this suite.) Test 6 pins the
# piece that IS cheaply hermetic — the SQL the whole rule rests on.
hdr "atuin daemon bench harness (scripts/research/bench-atuin-daemon.sh)"
_BENCH="$HERE/scripts/research/bench-atuin-daemon.sh"
if [[ ! -x "$_BENCH" ]]; then
  skip "atuin bench harness (scripts/research/bench-atuin-daemon.sh absent or not executable)"
else
  _bout=""
  _brc=0
  _b_run() { # _b_run [env=val ...] -- [args ...]
    local envs=()
    while (($#)) && [[ "$1" != -- ]]; do
      envs+=("$1")
      shift
    done
    shift || true
    # ${envs[@]+"${envs[@]}"}, not "${envs[@]}" — macOS ships bash 3.2, where expanding an
    # EMPTY array under `set -u` is an "unbound variable" error rather than zero words. The
    # calls that pass no env vars are exactly the ones that tripped it, so the bug only ever
    # showed on macOS. scripts/lib/common.sh pins the same 3.2 constraint for the same reason.
    _bout="$(env -u CORE_JSON CORE_COLOR=never ${envs[@]+"${envs[@]}"} "$_BENCH" "$@" 2>&1)"
    _brc=$?
  }

  # 1. --help documents the new surface. This is what stops a flag landing undocumented, and
  #    — more to the point — stops the SCOPE CAVEAT being dropped from the USER-VISIBLE surface
  #    while surviving only in a source comment. It pinned the UNVALIDATED marker until the
  #    seven runs that retired it; "not real hardware" is the caveat that outlives those runs,
  #    since a synthetic container/WSL2 figure is still not a real multi-pane box.
  _b_run -- --help
  if ((_brc == 0)) && [[ "$_bout" == *"--systemd"* && "$_bout" == *"CORE_ATBENCH_BASE"* &&
    "$_bout" == *"not real hardware"* ]]; then
    pass "atuin bench: --help documents --systemd, CORE_ATBENCH_BASE and the scope caveat"
  else
    fail "atuin bench: --help is missing one of --systemd / CORE_ATBENCH_BASE / 'not real hardware' (rc=$_brc)"
  fi

  # 2. The fail-closed arg contract still holds now that a flag exists which does not exit.
  _b_run -- --definitely-not-a-flag
  if ((_brc == 2)) && [[ "$_bout" == *"unexpected argument"* ]]; then
    pass "atuin bench: an unknown argument still exits 2"
  else
    fail "atuin bench: unknown argument should exit 2 (got rc=$_brc)"
  fi

  # 3. --systemd fails CLOSED and does not degrade. Stub systemd-run/systemctl that behave
  #    like a box with no bus, prepended to PATH so this is identical on a laptop with a real
  #    user manager and in CI without one. The load-bearing assertion is the last one: a skip
  #    that still printed a results table would be the silent degradation the flag exists to
  #    prevent, and "rc==0" alone would not catch it.
  _sdstub="$(mktemp -d "$SANDBOX/sdstub.XXXXXX")"
  for _t in systemd-run systemctl; do
    printf '%s\n' '#!/bin/sh' \
      'echo "Failed to connect to bus: No medium found" >&2' 'exit 1' >"$_sdstub/$_t"
    chmod +x "$_sdstub/$_t"
  done
  _bout="$(env CORE_COLOR=never PATH="$_sdstub:$PATH" "$_BENCH" --systemd 2>&1)"
  _brc=$?
  if ((_brc == 0)) && [[ "$_bout" == *"systemd"* && "$_bout" != *"results (ms per command"* &&
    "$_bout" != *"daemon off"* ]]; then
    pass "atuin bench: --systemd with no user bus SKIPs (rc 0) and reports no numbers"
  else
    fail "atuin bench: --systemd must skip without degrading to the no-systemd path (rc=$_brc)"
  fi

  # 4. CORE_ATBENCH_BASE validation — a caller error, so exit 2, never a silent skip.
  #    The non-writable leg is meaningless as root (-w is always true), hence the guard.
  _b_run "CORE_ATBENCH_BASE=relative/path" --
  _rc_rel=$_brc
  _b_run "CORE_ATBENCH_BASE=$SANDBOX/definitely-absent" --
  _rc_abs=$_brc
  if ((_rc_rel == 2)) && ((_rc_abs == 2)); then
    pass "atuin bench: CORE_ATBENCH_BASE rejects a relative and a nonexistent path (exit 2)"
  else
    fail "atuin bench: CORE_ATBENCH_BASE validation should exit 2 (relative=$_rc_rel absent=$_rc_abs)"
  fi

  # 5. Knob validation. WRITERS=0 is the one that matters: it makes every arm vacuously
  #    complete AND vacuously row-correct (0 samples, 0 rows) — a green run that measured
  #    nothing, which is precisely the outcome the row rule exists to make impossible.
  #    `08` is the third leg and the subtle one: it passes a `^[0-9]+$` digit class, and bash
  #    then reads it as OCTAL, so an arithmetic range check dies with "value too great for
  #    base" rather than producing the promised exit 2 — and the bad value goes on to break
  #    the writer loops. Assert the exit code AND that no arithmetic error leaked to stderr.
  _b_run "CORE_ATBENCH_WRITERS=abc" --
  _rc_nan=$_brc
  _b_run "CORE_ATBENCH_WRITERS=0" --
  _rc_zero=$_brc
  _b_run "CORE_ATBENCH_WRITERS=08" --
  _rc_oct=$_brc
  _oct_out="$_bout"
  if ((_rc_nan == 2)) && ((_rc_zero == 2)) && ((_rc_oct == 2)) &&
    [[ "$_oct_out" != *"value too great for base"* ]]; then
    pass "atuin bench: non-numeric, zero and octal-looking (08) CORE_ATBENCH_WRITERS exit 2"
  else
    fail "atuin bench: knob validation should exit 2 (abc=$_rc_nan zero=$_rc_zero 08=$_rc_oct)"
  fi

  # 6. EXECUTE the row-count SQL rather than pattern-match it — the shipped-unit fragment's
  #    philosophy (scripts/test/45-bootstrap-modules.sh) applied
  #    to the standing rule. Extract ROWCOUNT_PY (failing loudly if the extraction comes back
  #    empty, exactly as that fragment does for ExecStart) and run it against a synthetic history
  #    table. This pins both predicates the rule rests on: the total, and the `duration >= 0`
  #    FINISHED count that catches a silently-discarded `history end`.
  #    The SQL now lives in scripts/research/lib/atuin-db.sh, shared with scripts/research/verify-atuin-guard.sh
  #    — so this one assertion covers BOTH atuin gates, which is the point of the extraction.
  _rcpy="$(sed -n "/^ROWCOUNT_PY='/,/^'$/p" "$HERE/scripts/research/lib/atuin-db.sh" | sed -e "1s/^ROWCOUNT_PY='//" -e '$d')"
  if [[ -z "$_rcpy" ]]; then
    fail "atuin bench: could not extract ROWCOUNT_PY from the script (format changed?)"
  elif ! have python3; then
    skip "atuin bench: row-count SQL (python3 not installed)"
  else
    _rcdb="$SANDBOX/rowcount.db"
    rm -f "$_rcdb"
    python3 -c 'import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table history (duration integer)")
con.executemany("insert into history values (?)", [(-1,), (-1,), (5,), (7,), (0,)])
con.commit(); con.close()' "$_rcdb"
    _tot="$(python3 -c "$_rcpy" "$_rcdb" '1=1')"
    _fin="$(python3 -c "$_rcpy" "$_rcdb" 'duration >= 0')"
    if [[ "$_tot" == 5 && "$_fin" == 3 ]]; then
      pass "atuin bench: the row-count SQL counts all rows (5) and finished rows (3)"
    else
      fail "atuin bench: row-count SQL wrong (total=$_tot want 5; finished=$_fin want 3)"
    fi
    # And it must FAIL CLOSED — a -1 can only ever break an equality check, never satisfy one.
    if [[ "$(python3 -c "$_rcpy" "$SANDBOX/no-such.db" '1=1')" == -1 ]]; then
      pass "atuin bench: the row-count SQL returns -1 on an unreadable DB (fails closed)"
    else
      fail "atuin bench: row-count SQL must return -1 when it cannot read the DB"
    fi
  fi

  # 7. The two-metric split, EXECUTED rather than grepped. The writer emits `start_ms
  #    pair_ms` per line; the stats block must read one column per table. This needs a real
  #    test because the failure is invisible: the previous parser split the whole file on
  #    whitespace, so two-column input would flatten into a single distribution of double
  #    the length — a table that looks entirely normal and is entirely wrong. Feed it
  #    samples whose two columns differ and pin that each table reports its own.
  # Anchored on the stats INVOCATION, not on `<<'PY'`: the seeder above it uses the same
  # heredoc tag, so the generic pattern silently extracted the wrong block. Avoids `$` in
  # the pattern so BSD and GNU sed agree on it.
  _stats="$(sed -n '/^python3 - .*OFF_OK/,/^PY$/p' "$_BENCH" | sed -e '1d' -e '$d')"
  if [[ -z "$_stats" ]]; then
    fail "atuin bench: could not extract the stats block from the script (format changed?)"
  elif ! have python3; then
    skip "atuin bench: two-metric split (python3 not installed)"
  else
    _sdir="$(mktemp -d "$SANDBOX/stats.XXXXXX")"
    mkdir -p "$_sdir/off" "$_sdir/on"
    # start: off 10 ms, on 5 ms  (p50 ratio 2.00x).  pair: off 30 ms, on 25 ms  (1.20x).
    # The ratios are the assertion, and 1.20x is the load-bearing one: a flattened parse
    # yields the SAME distribution for both tables, so it can still produce 2.00x — but it
    # can never produce a second, different ratio.
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      printf '10.000000 30.000000\n' >>"$_sdir/off/1.txt"
      printf '5.000000 25.000000\n' >>"$_sdir/on/1.txt"
    done
    _sout="$(python3 -c "$_stats" "$_sdir" 1 1 'daemon on' 2>&1)"
    if [[ "$_sout" == *"PROMPT LATENCY"* && "$_sout" == *"TOTAL WRITE WORK"* &&
      "$_sout" == *"2.00x faster"* && "$_sout" == *"1.20x faster"* ]]; then
      pass "atuin bench: prompt-latency and total-write-work tables read separate columns"
    else
      fail "atuin bench: the two-metric split did not report both columns independently"
    fi

    # 8. A malformed sample line must REFUSE the arm, not coerce it. Same standing rule as
    #    the row count: a half-parsed latency table is indistinguishable from a real one.
    printf 'only-one-column\n' >"$_sdir/off/1.txt"
    _sout="$(python3 -c "$_stats" "$_sdir" 1 1 'daemon on' 2>&1)"
    if [[ "$_sout" == *"arm refused"* ]]; then
      pass "atuin bench: a malformed sample line refuses the arm"
    else
      fail "atuin bench: a malformed sample line must refuse the arm, not be coerced"
    fi
  fi
fi

# ── the startup budget gate (scripts/bench-core.sh --gate, #688) ──────────────────────
# 120 ms sat in ci.yml beside a comment guessing "~25 ms"; nothing recorded the real number,
# nothing kept the two in step, and nobody had ever seen the gate fail. The budget now lives
# in scripts/bench-baseline.env and --gate reads it FAIL-CLOSED. This pins (1) the ratchet
# policy itself — BUDGET is exactly 2× BASELINE, so widening the budget to green a red run is
# a red audit, not a quiet edit; (2) the fail-closed legs, which need no zsh because budget
# resolution precedes the tool probes; (3) the verdict, driven through a STUB hyperfine on
# PATH that writes whatever mean the case asks for — so a breach is PROVEN to exit 1 and to
# print the per-module profile, without running a 50-run benchmark inside the suite. (The
# real-hyperfine number is CI's `bench` job; a laptop's is 1–3× ubuntu-latest's and gates
# nothing.)
hdr "startup budget gate (scripts/bench-core.sh --gate)"
_BCORE="$HERE/scripts/bench-core.sh"
_BBASE="$HERE/scripts/bench-baseline.env"
if [[ ! -x "$_BCORE" || ! -r "$_BBASE" ]]; then
  skip "startup budget gate (scripts/bench-core.sh or scripts/bench-baseline.env absent)"
else
  _bcout=""
  _bcrc=0
  _bc_run() { # _bc_run [env=val ...] -- [args ...]   (the _b_run shape above, bash-3.2 safe)
    local envs=()
    while (($#)) && [[ "$1" != -- ]]; do
      envs+=("$1")
      shift
    done
    shift || true
    _bcout="$(env -u CORE_JSON -u CORE_BENCH_BUDGET_MS -u CORE_BENCH_BASELINE_FILE -u CORE_BENCH_RUNS \
      CORE_COLOR=never ${envs[@]+"${envs[@]}"} "$_BCORE" "$@" 2>&1)"
    _bcrc=$?
  }

  # 1. The ratchet policy pin. Whole ms, and the budget is EXACTLY 2× the baseline — the
  #    relation the file's header promises and the number the calibration justified (worst
  #    run-mean ever observed clears 2× by 1.5×; anything that doubles an ordinary host's
  #    startup fails — a gross-regression gate, not an additive threshold).
  _bc_base="$(sed -n 's/^CORE_BENCH_BASELINE_MS=//p' "$_BBASE" | head -n1)"
  _bc_bud="$(sed -n 's/^CORE_BENCH_BUDGET_MS=//p' "$_BBASE" | head -n1)"
  _bc_whole=1
  case "$_bc_base" in '' | *[!0-9]*) _bc_whole=0 ;; esac
  case "$_bc_bud" in '' | *[!0-9]*) _bc_whole=0 ;; esac
  if ((!_bc_whole)); then
    fail "bench gate: bench-baseline.env must hold whole-ms CORE_BENCH_BASELINE_MS and CORE_BENCH_BUDGET_MS (got '${_bc_base:-<unset>}' / '${_bc_bud:-<unset>}')"
  elif ((_bc_bud == 2 * _bc_base)); then
    pass "bench gate: bench-baseline.env budget $_bc_bud ms is exactly 2× baseline $_bc_base ms (the ratchet policy)"
  else
    fail "bench gate: budget $_bc_bud ms is not 2× baseline $_bc_base ms — re-baseline per the file's header; never widen the budget to green a run"
  fi

  # 2. --help documents the surface, including the test hook — so it cannot become an
  #    undocumented back door that quietly points CI at a different file.
  _bc_run -- --help
  if ((_bcrc == 0)) && [[ "$_bcout" == *"--gate"* && "$_bcout" == *"bench-baseline.env"* &&
    "$_bcout" == *"CORE_BENCH_BASELINE_FILE"* ]]; then
    pass "bench gate: --help documents --gate, bench-baseline.env and CORE_BENCH_BASELINE_FILE"
  else
    fail "bench gate: --help is missing one of --gate / bench-baseline.env / CORE_BENCH_BASELINE_FILE (rc=$_bcrc)"
  fi

  # 3. The fail-closed arg contract survives the new flag; and --gate --profile is refused —
  #    --profile exits 0 after ONE sample, which is a gate that cannot gate.
  _bc_run -- --gate --profile
  _rc_gp=$_bcrc
  _bc_run -- --definitely-not-a-flag
  if ((_rc_gp == 2)) && ((_bcrc == 2)); then
    pass "bench gate: --gate --profile and an unknown argument both exit 2"
  else
    fail "bench gate: --gate --profile should exit 2 (got $_rc_gp); unknown argument should exit 2 (got $_bcrc)"
  fi

  # 4. A missing baseline file under --gate is RED, not a skip, and the message names the path
  #    — and an env override does not excuse it: the override selects the number, the file is
  #    still the contract (a review catch — the first cut let `CORE_BENCH_BUDGET_MS=48 --gate`
  #    green a deleted file).
  _bc_run "CORE_BENCH_BASELINE_FILE=$SANDBOX/absent-baseline.env" -- --gate
  _rc_absent=$_bcrc
  _out_absent="$_bcout"
  _bc_run "CORE_BENCH_BASELINE_FILE=$SANDBOX/absent-baseline.env" "CORE_BENCH_BUDGET_MS=48" -- --gate
  if ((_rc_absent == 1)) && [[ "$_out_absent" == *"absent-baseline.env"* ]] && ((_bcrc == 1)); then
    pass "bench gate: a missing baseline file fails closed (exit 1) and names the file, even under an env override"
  else
    fail "bench gate: missing baseline file should exit 1 naming it (rc=$_rc_absent; with env override rc=$_bcrc): ${_out_absent//$'\n'/ | }"
  fi

  # 5. Malformed values and a budget with no headroom are refused the same way.
  printf 'CORE_BENCH_BASELINE_MS=24\nCORE_BENCH_BUDGET_MS=fast\n' >"$SANDBOX/bench-bad.env"
  _bc_run "CORE_BENCH_BASELINE_FILE=$SANDBOX/bench-bad.env" -- --gate
  _rc_bad=$_bcrc
  printf 'CORE_BENCH_BASELINE_MS=24\nCORE_BENCH_BUDGET_MS=20\n' >"$SANDBOX/bench-nohead.env"
  _bc_run "CORE_BENCH_BASELINE_FILE=$SANDBOX/bench-nohead.env" -- --gate
  _rc_nohead=$_bcrc
  _bc_run "CORE_BENCH_BUDGET_MS=fast" -- --gate
  _rc_envbad=$_bcrc
  if ((_rc_bad == 1)) && ((_rc_nohead == 1)) && ((_rc_envbad == 2)); then
    pass "bench gate: a non-numeric budget (1), a budget ≤ baseline (1) and a bad env override (2) are all refused"
  else
    fail "bench gate: malformed inputs should be refused (non-numeric rc=$_rc_bad, no-headroom rc=$_rc_nohead, env=fast rc=$_rc_envbad)"
  fi

  # 6. ci.yml runs --gate and carries NO budget literal — the dual-source drift the file
  #    exists to kill. A `CORE_BENCH_BUDGET_MS:` key reappearing in the workflow would
  #    silently override the committed number.
  #    Anchored to the `run:` key: the job's comment block names the same command, so a bare
  #    substring match would stay green after the actual step dropped --gate (a review catch).
  _bc_ci="$HERE/.github/workflows/ci.yml"
  if grep -qE '^[[:space:]]*run:[[:space:]]*\./scripts/bench-core\.sh --gate[[:space:]]*$' "$_bc_ci" &&
    ! grep -q 'CORE_BENCH_BUDGET_MS:' "$_bc_ci"; then
    pass "bench gate: ci.yml runs bench-core.sh --gate and sets no CORE_BENCH_BUDGET_MS literal"
  else
    fail "bench gate: ci.yml must run 'bench-core.sh --gate' and must NOT set CORE_BENCH_BUDGET_MS (the budget lives in scripts/bench-baseline.env)"
  fi

  # 7–12. The verdict, through a stub hyperfine. The stub honours only --export-json <file>
  #    and writes the mean/median the case chooses (seconds, hyperfine's unit); real zsh is
  #    needed by the script's probe and by the on-breach profile (which sources the real
  #    modules in the hermetic sandbox), python3 by the JSON read. These legs are the
  #    shell-area work of this section (they source the zsh modules), so they honour
  #    --scope like the zsh sections below; the policy pins above are cross-cutting and
  #    stay unscoped, like the CI-classifier tests.
  if ((SCOPE_SHELL)) && have zsh && have python3; then
    _hfstub="$(mktemp -d "$SANDBOX/hfstub.XXXXXX")"
    cat >"$_hfstub/hyperfine" <<'EOF'
#!/bin/sh
# stub hyperfine for test-core.sh: the "measurement" is CORE_TEST_HF_MEAN / CORE_TEST_HF_MEDIAN
# (seconds) so the caller picks the verdict; only --export-json <file> is honoured.
out=""
while [ $# -gt 0 ]; do
  [ "$1" = --export-json ] && { out="$2"; shift; }
  shift
done
[ -n "$out" ] || { echo "stub hyperfine: no --export-json" >&2; exit 1; }
m="${CORE_TEST_HF_MEAN:-0.020}"
md="${CORE_TEST_HF_MEDIAN:-$m}"
if [ -n "${CORE_TEST_HF_BAD_JSON:-}" ]; then
  # An export the reader cannot use (valid JSON, wrong shape) — a version skew, say.
  printf '{"results":[]}\n' >"$out"
else
  printf '{"results":[{"command":"zsh -i -c exit","mean":%s,"stddev":0.001,"median":%s,"user":0,"system":0,"min":%s,"max":%s,"times":[%s],"exit_codes":[0]}]}\n' \
    "$m" "$md" "$m" "$m" "$m" >"$out"
fi
echo "Benchmark 1: zsh -i -c exit (stub hyperfine, mean ${m}s)"
# CORE_TEST_HF_RC: exit non-zero AFTER writing the file — the shape a real hyperfine has when
# a run fails its own checks, and the one the gate must not trust.
exit "${CORE_TEST_HF_RC:-0}"
EOF
    chmod +x "$_hfstub/hyperfine"
    _bc_stub() { _bc_run "PATH=$_hfstub:$PATH" "$@"; } # _bc_stub [env=val ...] -- [args ...]

    # 7. Within budget: green, and the trend line names the committed baseline.
    _bc_stub "CORE_TEST_HF_MEAN=0.020" -- --gate
    if ((_bcrc == 0)) && [[ "$_bcout" == *"within budget $_bc_bud ms"* && "$_bcout" == *"CI baseline $_bc_base ms"* ]]; then
      pass "bench gate: a 20 ms mean passes the committed budget and reports the baseline delta"
    else
      fail "bench gate: 20 ms should pass (rc=$_bcrc): ${_bcout//$'\n'/ | }"
    fi

    # 8. THE ONE THAT MATTERS: a breach exits 1, says so, and the log carries the per-module
    #    profile (TOTAL + the first module) so the red run names the culprit. A budget nobody
    #    has seen fail is not known to work — this is where it fails.
    _bc_stub "CORE_TEST_HF_MEAN=0.100" -- --gate
    #    The profile must name EVERY numbered fragment the loader globs — a module missing
    #    from CORE_MODULES is one a breach can neither time nor attribute (02-capabilities
    #    was, until review) — so this walks zsh/ rather than trusting the script's list.
    _bc_missing=""
    for _bc_f in "$HERE"/zsh/[0-9][0-9]-*.zsh; do
      _bc_m="$(basename "$_bc_f" .zsh)"
      [[ "$_bcout" == *" $_bc_m"* ]] || _bc_missing="$_bc_missing $_bc_m"
    done
    if ((_bcrc == 1)) && [[ "$_bcout" == *"EXCEEDS budget $_bc_bud ms"* && "$_bcout" == *"TOTAL"* &&
      -z "$_bc_missing" && "$_bcout" != *"median IS within budget"* ]]; then
      pass "bench gate: a 100 ms mean FAILS (exit 1) and prints the per-module profile naming every numbered fragment"
    else
      fail "bench gate: 100 ms should exit 1 with EXCEEDS + a profile naming every zsh/NN-*.zsh (rc=$_bcrc; unnamed:${_bc_missing:- none}): ${_bcout//$'\n'/ | }"
    fi

    # 9. A breach whose median is within budget is still red (the gate is the mean, as every
    #    recorded measurement is) but labels the split — a skewed or intermittent slowdown
    #    rather than a uniform one — without diagnosing it as noise: a burst of slow runs can
    #    be a runner hiccup or a real intermittent regression, and the log should say which
    #    question to ask, not answer it.
    _bc_stub "CORE_TEST_HF_MEAN=0.100" "CORE_TEST_HF_MEDIAN=0.020" -- --gate
    if ((_bcrc == 1)) && [[ "$_bcout" == *"EXCEEDS"* && "$_bcout" == *"median IS within budget"* ]]; then
      pass "bench gate: mean over / median under still fails, and labels the skewed split"
    else
      fail "bench gate: mean 100 / median 20 should exit 1 with the median-within-budget note (rc=$_bcrc)"
    fi

    # 10. The env override wins over the file and is labelled as such.
    _bc_stub "CORE_TEST_HF_MEAN=0.020" "CORE_BENCH_BUDGET_MS=10" -- --gate
    if ((_bcrc == 1)) && [[ "$_bcout" == *"EXCEEDS budget 10 ms"* && "$_bcout" == *"override"* ]]; then
      pass "bench gate: CORE_BENCH_BUDGET_MS=10 overrides the file's budget and is labelled an override"
    else
      fail "bench gate: env override should win (rc=$_bcrc): ${_bcout//$'\n'/ | }"
    fi

    # 11. Report mode never fails — not even at 4× the budget — and shows the trend line.
    _bc_stub "CORE_TEST_HF_MEAN=0.100" --
    if ((_bcrc == 0)) && [[ "$_bcout" == *"report only"* && "$_bcout" == *"CI baseline"* &&
      "$_bcout" != *"EXCEEDS"* ]]; then
      pass "bench gate: report mode (no --gate, no env) stays exit 0 at 100 ms and prints the baseline delta"
    else
      fail "bench gate: report mode must not fail (rc=$_bcrc): ${_bcout//$'\n'/ | }"
    fi

    # 11b. hyperfine's OWN exit status is honoured: a 20 ms JSON written by a run that then
    #     exited 42 is not a measurement. Under --gate that is red (a review catch — the script
    #     has no errexit, so the first cut parsed the file and passed); report mode degrades to
    #     a loud skip, never a verdict.
    _bc_stub "CORE_TEST_HF_MEAN=0.020" "CORE_TEST_HF_RC=42" -- --gate
    _rc_hf_gate=$_bcrc
    _out_hf_gate="$_bcout"
    _bc_stub "CORE_TEST_HF_MEAN=0.020" "CORE_TEST_HF_RC=42" --
    if ((_rc_hf_gate == 1)) && [[ "$_out_hf_gate" == *"hyperfine exited 42"* && "$_out_hf_gate" != *"within budget"* ]] &&
      ((_bcrc == 0)) && [[ "$_bcout" == *"hyperfine exited 42"* && "$_bcout" != *"report only"* ]]; then
      pass "bench gate: a hyperfine that writes JSON but exits 42 is red under --gate and a skip in report mode"
    else
      fail "bench gate: hyperfine rc 42 should be exit 1 under --gate (got $_rc_hf_gate) and a skip in report mode (got $_bcrc): ${_out_hf_gate//$'\n'/ | }"
    fi

    # 11c. The same split for an export the reader cannot use (exit 0, wrong shape): red
    #     under --gate, a loud skip in report mode — `make bench` never returns 1 for it.
    _bc_stub "CORE_TEST_HF_BAD_JSON=1" -- --gate
    _rc_bad_gate=$_bcrc
    _bc_stub "CORE_TEST_HF_BAD_JSON=1" --
    if ((_rc_bad_gate == 1)) && ((_bcrc == 0)) && [[ "$_bcout" == *"could not parse"* && "$_bcout" != *"report only"* ]]; then
      pass "bench gate: an unreadable hyperfine export is red under --gate and a skip in report mode"
    else
      fail "bench gate: unreadable export should be exit 1 under --gate (got $_rc_bad_gate) and a skip in report mode (got $_bcrc): ${_bcout//$'\n'/ | }"
    fi
  elif ((!SCOPE_SHELL)); then
    skip "startup budget gate: stub-hyperfine verdict legs (out of scope)"
  else
    skip "startup budget gate: stub-hyperfine verdict legs (zsh or python3 not installed)"
  fi

  # 12. Under --gate an absent hyperfine is RED, not a skip — only assertable on a box that
  #     HAS zsh (the zsh probe comes first and would name zsh instead) and LACKS hyperfine,
  #     so elsewhere this is a note, not a coverage gap.
  if have zsh && ! have hyperfine; then
    _bc_run -- --gate
    if ((_bcrc == 1)) && [[ "$_bcout" == *"needs hyperfine"* ]]; then
      pass "bench gate: --gate without hyperfine fails closed (exit 1)"
    else
      fail "bench gate: --gate without hyperfine should exit 1 'needs hyperfine' (rc=$_bcrc)"
    fi
  else
    skip_note "bench gate: the no-hyperfine fail-closed leg needs a box with zsh and without hyperfine — not asserted here"
  fi
fi
