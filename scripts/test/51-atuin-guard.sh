# scripts/test/51-atuin-guard.sh
# the atuin-guard premise detector (scripts/research/verify-atuin-guard.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the atuin-guard premise detector (scripts/research/verify-atuin-guard.sh) ──────────
# The detector answers ONE question — does the upstream fact _core_atuin_daemon_guard is
# premised on still hold? — and the whole reason it exists in this shape is that the
# previous answer to that question could LIE. The copy-paste recipe it replaces seeded its
# DB through the unreachable-daemon path, so on a build that discards, the DB was never
# created, every row count fell back to 0, and it printed the premise-holds signature from
# an apparatus that had never written a row. Right by luck.
#
# So the assertions below are mostly about the THIRD verdict. `holds` and `moved` are the
# easy half; `unmeasurable` is the one that keeps a broken detector from reading as good
# news, and it is the one a well-meant future simplification would delete.
#
# Hermetic: a stub `atuin` supplies every shape, so this needs no atuin, no daemon and no
# network — the same stubbing idiom scripts/test/45-bootstrap-modules.sh uses on the
# example unit's ExecStart.
_VERIFY="$HERE/scripts/research/verify-atuin-guard.sh"
# SCOPE_ATUIN, not SCOPE_SHELL. This fragment and scripts/test/52-atuin-autostart.sh are
# 197s of a 286s suite — 68% of
# it, and the largest single cost on the CI critical path across all nine repos. What they
# exercise is the premise DETECTOR against stub binaries; the detector's real job, measuring
# live upstream atuin, runs on manual dispatch of .github/workflows/atuin-guard-verify.yml
# (#687) and never on a push. So the only changes that can move the result here are the detector itself (scripts/,
# which ci-classify.sh already treats as infra → full run), the guard it protects in
# zsh/00-tools.zsh, and atuin/. Every other shell change was paying 197s for a harness it
# cannot reach. Skipping is FAIL-CLOSED at the classifier, not here: an unrecognised or
# unparseable path forces the full scope, so an unclassified change still runs this.
if ! ((SCOPE_ATUIN)); then
  skip "atuin guard detector (out of scope)"
elif [[ ! -x "$_VERIFY" ]]; then
  skip "atuin guard detector (scripts/research/verify-atuin-guard.sh absent or not executable)"
elif ! have python3; then
  skip "atuin guard detector (python3 not installed)"
else
  hdr "atuin guard premise detector (scripts/research/verify-atuin-guard.sh, hermetic)"
  _vstub="$(mktemp -d "$SANDBOX/vstub.XXXXXX")"

  # _mkstub <name> <writes?> [version] — a fake atuin. `writes=yes` inserts a row on EVERY
  # invocation (an upstream that no longer discards); `writes=off-only` inserts one only
  # when the daemon is off (today's real 18.19.0 behaviour); `writes=no` never writes at
  # all (a broken apparatus — the case that used to read as "holds"); `writes=stops` writes
  # on the daemon-off path only until the DB exists and the opening control has run, then
  # stops for good (an apparatus that dies MID-run); `writes=replay` discards nothing — it
  # SPOOLS the daemon-on entries and flushes them on the next daemon-off write, the upstream
  # shape that would invert the guard's one-way degrade.
  #
  # _w is a COUNT, not a flag: `replay` has to land more than one row in a single call, and
  # every other mode simply leaves it at 1.
  _mkstub() {
    local name="$1" mode="$2" ver="${3:-18.19.0}"
    cat >"$_vstub/$name" <<STUB
#!/usr/bin/env bash
case "\$1" in --version) echo "atuin $ver"; exit 0 ;; esac
_w=0
_spool="\${XDG_DATA_HOME}/stub-spool"
case "$mode" in
  yes) _w=1 ;;
  off-only|badid|corrupt) [[ "\${ATUIN_DAEMON__ENABLED:-false}" == true ]] || _w=1 ;;
  stops)
    # Two daemon-off writes are allowed: the seed (which creates the DB) and the opening
    # control arm. After that this apparatus is dead — but it still READS fine, which is
    # exactly why the closing control arm has to exist.
    _n=\$(cat "\${XDG_DATA_HOME}/stub-writes" 2>/dev/null || echo 0)
    if [[ "\${ATUIN_DAEMON__ENABLED:-false}" != true ]] && ((_n < 2)); then
      _w=1
      mkdir -p "\${XDG_DATA_HOME}"; echo \$((_n + 1)) >"\${XDG_DATA_HOME}/stub-writes"
    fi
    ;;
  replay)
    if [[ "\${ATUIN_DAEMON__ENABLED:-false}" == true ]]; then
      mkdir -p "\${XDG_DATA_HOME}"; echo q >>"\$_spool"   # buffered, not discarded
    else
      _w=\$((1 + \$(wc -l <"\$_spool" 2>/dev/null || echo 0)))
      : >"\$_spool"
    fi
    ;;
esac
if (( _w )); then
  db="\${XDG_DATA_HOME}/atuin/history.db"; mkdir -p "\$(dirname "\$db")"
  python3 - "\$db" "\$_w" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("create table if not exists history (id text, duration integer)")
for _ in range(int(sys.argv[2])):
    c.execute("insert into history values ('x', -1)")
c.commit(); c.close()
PY
fi
# corrupt: after the daemon-on call, leave the DB unreadable — the shape that made an
# apparatus failure read as a MOVED verdict (a negative delta) before the readok sentinel.
# NOTE: no backticks anywhere in this heredoc body. The delimiter is unquoted (so \$mode and
# \$ver interpolate), which means a backtick here is COMMAND SUBSTITUTION at stub-generation
# time, not decoration.
if [ "$mode" = corrupt ] && [ "\${ATUIN_DAEMON__ENABLED:-false}" = true ]; then
  printf 'this is not a sqlite database' >"\${XDG_DATA_HOME}/atuin/history.db"
fi
# badid: exit 0, write nothing, and print something that is NOT a 32-hex history id —
# a deprecation notice on stdout is the realistic shape.
if [ "$mode" = badid ]; then
  echo "warning: atuin history start is deprecated"
else
  echo "0192deadbeefcafe0000000000000000"
fi
STUB
    chmod +x "$_vstub/$name"
  }

  _v_run() { # _v_run <stub> [extra args...] → sets _vout/_vrc
    local stub="$1"
    shift
    _vout="$(env -u CORE_JSON CORE_COLOR=never "$_VERIFY" --atuin "$_vstub/$stub" "$@" 2>&1)"
    _vrc=$?
  }
  _v_verdict() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null; }

  # ── apparatus-FREE assertions. These hold on any box, because none of them needs the
  #    stub to be able to write a row — so a platform where the apparatus cannot run still
  #    pins the script's contract surface.
  #
  # A. A bare box must not be able to produce a green "holds". This is the one place the
  #    repo's skip-and-exit-0 idiom is deliberately broken, so it is pinned.
  _vout="$(env -u CORE_JSON CORE_COLOR=never "$_VERIFY" --atuin /nonexistent/atuin --json 2>&1)"
  _vrc=$?
  if ((_vrc == 3)) && [[ "$(_v_verdict "$_vout")" == unmeasurable ]]; then
    pass "atuin verify: a missing atuin exits 3 (unmeasurable), NOT 0 — exit 0 asserts something about upstream"
  else
    fail "atuin verify: a missing atuin must exit 3, got rc$_vrc"
  fi

  # B. Usage errors stay distinct from verdicts: 2 is the caller's fault, 1 and 3 are
  #    findings. A workflow that conflated them would file an issue about a typo.
  CORE_COLOR=never "$_VERIFY" --definitely-not-a-flag >/dev/null 2>&1
  _vrc=$?
  CORE_COLOR=never "$_VERIFY" --atuin >/dev/null 2>&1
  _vrc2=$?
  if ((_vrc == 2)) && ((_vrc2 == 2)); then
    pass "atuin verify: an unknown flag and a flag missing its value both exit 2 (usage, not a finding)"
  else
    fail "atuin verify: usage errors must exit 2 (unknown=$_vrc missing-value=$_vrc2)"
  fi

  # C. --unmeasurable renders through the SAME one path as a real run, so the workflow
  #    never hand-rolls prose at the call site and the two cannot drift.
  _vout="$(CORE_COLOR=never "$_VERIFY" --unmeasurable "download failed" --json 2>&1)"
  _vrc=$?
  if ((_vrc == 3)) && [[ "$(_v_verdict "$_vout")" == unmeasurable ]] && [[ "$_vout" == *"download failed"* ]]; then
    pass "atuin verify: --unmeasurable emits a well-formed verdict without measuring (rc 3)"
  else
    fail "atuin verify: --unmeasurable must render a real unmeasurable verdict, got rc$_vrc"
  fi

  # D. The --json object carries every field a consumer reads (the workflow parses
  #    `verdict`; a human reads the rest). Asserted by SHAPE, not by grep, and on the
  #    apparatus-free path so it holds everywhere.
  if printf '%s' "$_vout" | python3 -c '
import json,sys
d = json.load(sys.stdin)
need = {"premise","verdict","reason","atuin_version","host","anchor","anchor_relation","control_delta","drain_delta","bounded","arms"}
assert need <= set(d), sorted(need - set(d))
assert isinstance(d["arms"], dict), type(d["arms"])
# `premise` defaults to discard and the workflow ASSERTS it per leg: the two legs differ by
# one flag, and a copy-paste that dropped it would file a silent-discard measurement under
# the autostart title. A default that silently changed would defeat that check.
assert d["premise"] == "discard", d["premise"]
' 2>/dev/null; then
    pass "atuin verify: --json carries premise/verdict/reason/versions/host/deltas/bounded/arms"
  else
    fail "atuin verify: --json shape is missing fields consumers depend on"
  fi

  # ── APPARATUS SELF-CHECK. Everything below drives a stub that must actually write a row
  #    into a real SQLite file and be measured through it. A box where that cannot work —
  #    a python3 built without the sqlite3 module, a coreutils that cannot bound a call,
  #    a busybox whose tools differ — would fail every assertion below for a reason that
  #    has nothing to do with the code under test. So prove the apparatus FIRST and SKIP
  #    if it cannot be built, which is the same contract check_dep applies to a missing
  #    binary. The skip carries the verdict AND the reason, because a skip that does not
  #    say why is how a platform-specific breakage stays invisible.
  _mkstub atuin-discards off-only
  _v_run atuin-discards --json
  _vapp="$(_v_verdict "$_vout")"
  if [[ "$_vapp" != holds ]]; then
    _vwhy="$(printf '%s' "$_vout" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"][:160])' 2>/dev/null)"
    skip "atuin guard detector: measurement assertions (apparatus unusable here — verdict=${_vapp:-<unparseable>}: ${_vwhy:-no reason parsed})"
  else
    # 1. HOLDS — the control arm writes, both unreachable shapes discard. rc 0.
    _v_run atuin-discards --json
    if [[ "$(_v_verdict "$_vout")" == holds ]] && ((_vrc == 0)); then
      pass "atuin verify: an atuin that still discards on an unreachable socket → holds (rc 0)"
    else
      fail "atuin verify: expected holds/rc0, got $(_v_verdict "$_vout")/rc$_vrc"
    fi

    # 2. The control arm is REPORTED, not merely run. `holds` without a proven-working
    #    apparatus is exactly the old recipe's failure, so the number is in the output.
    if [[ "$_vout" == *'"control_delta":1'* ]]; then
      pass "atuin verify: holds is reported alongside a control arm that actually wrote"
    else
      fail "atuin verify: a holds verdict must carry control_delta 1 (got: $_vout)"
    fi

    # 3. MOVED — an atuin that writes on the unreachable path. rc 1, and the reason names
    #    WHICH property changed (a bare "it changed" is not actionable).
    _mkstub atuin-fixed yes 19.0.0
    _v_run atuin-fixed --json
    if [[ "$(_v_verdict "$_vout")" == moved ]] && ((_vrc == 1)) && [[ "$_vout" == *"no longer discards"* ]]; then
      pass "atuin verify: an atuin that writes on an unreachable socket → moved (rc 1), naming the change"
    else
      fail "atuin verify: expected moved/rc1 naming the change, got $(_v_verdict "$_vout")/rc$_vrc"
    fi

    # 4. A newer atuin than the anchor is REPORTED as such — the signal /tool-scout cannot
    #    compute for itself and the issue body leads with.
    if [[ "$_vout" == *'"anchor_relation":"newer"'* ]]; then
      pass "atuin verify: an atuin newer than the anchor reports anchor_relation=newer"
    else
      fail "atuin verify: anchor_relation must say 'newer' when the measured atuin outranks the anchor"
    fi

    # 5. THE LOAD-BEARING ONE. An apparatus that cannot write at all must be UNMEASURABLE,
    #    never holds. Both produce "the row count did not go up"; only one of them means the
    #    premise held. Deleting this assertion is how the fail-open bug comes back.
    _mkstub atuin-dead no
    _v_run atuin-dead --json
    if [[ "$(_v_verdict "$_vout")" == unmeasurable ]] && ((_vrc == 3)); then
      pass "atuin verify: an atuin that never writes is UNMEASURABLE (rc 3), never holds"
    else
      fail "atuin verify: a non-writing apparatus must be unmeasurable/rc3, got $(_v_verdict "$_vout")/rc$_vrc"
    fi

    # 6. The anchor is read from ONE machine-readable line, and a file that disagrees with
    #    itself (or has lost the line) is unmeasurable rather than defaulted. Driven from a
    #    sandbox repo whose zsh/00-tools.zsh is doctored.
    _vrepo="$(mktemp -d "$SANDBOX/vrepo.XXXXXX")"
    # lib/ux.sh too: scripts/lib/common.sh sources it as ../../lib/ux.sh, and without it the
    # script dies under `set -u` before it ever reads the anchor — which would make this
    # assertion pass for the wrong reason (a crash, not a refusal).
    mkdir -p "$_vrepo/scripts/research/lib" "$_vrepo/scripts/lib" "$_vrepo/lib" "$_vrepo/zsh" "$_vrepo/atuin"
    cp "$_VERIFY" "$_vrepo/scripts/research/"
    cp "$HERE/scripts/lib/common.sh" "$_vrepo/scripts/lib/"
    cp "$HERE/scripts/research/lib/atuin-db.sh" "$_vrepo/scripts/research/lib/"
    cp "$HERE/lib/ux.sh" "$_vrepo/lib/"
    cp "$HERE/atuin/config.toml" "$_vrepo/atuin/"
    for _case in none dupe; do
      if [[ "$_case" == none ]]; then
        printf '# no anchor here\n' >"$_vrepo/zsh/00-tools.zsh"
      else
        printf '# CORE_ATUIN_GUARD_VERIFIED_AGAINST=18.19.0\n# CORE_ATUIN_GUARD_VERIFIED_AGAINST=19.0.0\n' \
          >"$_vrepo/zsh/00-tools.zsh"
      fi
      _vout="$(CORE_COLOR=never "$_vrepo/scripts/research/verify-atuin-guard.sh" --atuin "$_vstub/atuin-discards" --json 2>&1)"
      _vrc=$?
      if ((_vrc == 3)) && [[ "$_vout" == *"anchor"* ]]; then
        pass "atuin verify: a $_case anchor in zsh/00-tools.zsh is unmeasurable, not a default"
      else
        fail "atuin verify: a $_case anchor must be unmeasurable (rc3), got rc$_vrc"
      fi
    done

    # 7. The report is issue-ready: no title heading (file-routine-issue.sh supplies one),
    #    and its prose AGREES WITH THE MATRIX THAT RAN. The blind spots it must still name —
    #    musl, autostart, #3382 — are pinned as before, but the coverage half is checked for
    #    COHERENCE rather than for keywords, because keywords are what let the last bug
    #    through: the scope paragraph went on saying "`--hook` is not exercised" after the
    #    matrix was widened to four arms, and the assertion that should have caught it grepped
    #    for two nouns the false sentence also contained.
    #
    #    Both renderers run from ONE invocation — emit_report runs before emit_json — so the
    #    two can never be compared across different runs. The comparison targets the DERIVED
    #    coverage sentence SPECIFICALLY, and that precision is the whole assertion: the
    #    per-arm table already lists every arm, so a check that merely looks for arm names
    #    somewhere in the report is satisfied by the table alone and never reads the claim.
    _vrep="$SANDBOX/atverify-report.md"
    _vrepjson="$SANDBOX/atverify-report.json"
    CORE_COLOR=never "$_VERIFY" --atuin "$_vstub/atuin-discards" --report "$_vrep" --json \
      >"$_vrepjson" 2>/dev/null
    if [[ -s "$_vrep" ]] && [[ "$(head -c 1 "$_vrep")" != "#" ]] &&
      grep -qi 'musl' "$_vrep" && grep -qi 'autostart' "$_vrep" && grep -q '3382' "$_vrep" &&
      python3 - "$_vrep" "$_vrepjson" <<'PY' 2>/dev/null; then
import json, re, sys
rep = open(sys.argv[1]).read()
arms = set(json.load(open(sys.argv[2]))["arms"])

# The coverage claim, parsed and compared as a SET. emit_report renders "absent_hook" as
# "absent / hook", so the claim is mapped back rather than the arms mapped forward.
m = re.search(r"^\*\*Measured here:\*\* (.+)\.$", rep, re.M)
assert m, "the report states no coverage claim at all"
if arms:
    claimed = {a.strip().replace(" / ", "_") for a in m.group(1).split(",")}
    assert claimed == arms, sorted(claimed ^ arms)
else:
    assert m.group(1).startswith("nothing"), m.group(1)

# The scope section is BY CONSTRUCTION about what was not measured, so it may name neither an
# arm nor either hook mode — every arm is measured in both. That is the general form of the
# bug that shipped, where "`--hook` is not exercised" sat here while four hook arms ran; the
# previous exact-wording ban would have missed any reworded version of the same claim.
scope = rep.rsplit("\n---\n", 1)[-1]
named = [a for a in arms if a.replace("_", " / ") in scope]
assert not named, "the scope section names measured arms: %s" % named
assert "hook" not in scope.lower(), "the scope section disclaims hook coverage the matrix has"
PY
      pass "atuin verify: --report is issue-ready, names its musl/autostart/#3382 blind spots, and its prose matches the arms that ran"
    else
      fail "atuin verify: --report must omit a title heading, name the coverage it lacks, and not disclaim an arm it measured"
    fi

    # 8. FOUR arms, and the hook ones by name. atuin's own `init zsh` emits
    #    `atuin history start --hook -- "$1"`, so the plain form is a path no shell in the
    #    fleet actually runs; a detector that measured only it could report `holds` while an
    #    upstream change scoped to hook mode broke every prompt.
    _v_run atuin-discards --json
    if printf '%s' "$_vout" | python3 -c '
import json,sys
a = json.load(sys.stdin)["arms"]
want = {"absent_hook","absent_plain","stale_hook","stale_plain"}
assert want == set(a), sorted(set(a) ^ want)
for name, arm in a.items():
    assert {"rc","delta","stderr_empty","id_wellformed"} <= set(arm), name
' 2>/dev/null; then
      pass "atuin verify: all four arms are measured — absent/stale x hook/plain"
    else
      fail "atuin verify: --json must carry absent/stale x hook/plain arms (got: $_vout)"
    fi

    # 9. A malformed id is a FINDING, not a pass. "stdout was non-empty" is not the premise —
    #    the shell hands that id to `history end`, and 18.16.1's empty id is what crashed it.
    _mkstub atuin-badid badid
    _v_run atuin-badid --json
    if [[ "$(_v_verdict "$_vout")" == moved ]] && [[ "$_vout" == *"well-formed history id"* ]]; then
      pass "atuin verify: stdout that is not a 32-hex id is moved, not holds"
    else
      fail "atuin verify: a malformed history id must be a finding, got $(_v_verdict "$_vout")"
    fi

    # 10. THE OTHER HALF OF THE CENTRAL RULE. An unreadable DB must be `unmeasurable`, never
    #     `moved`. atuin_db_rows returns -1 on a failed read, and `after - before` then goes
    #     NEGATIVE — which the verdict block reads as "the row count changed". That renders an
    #     apparatus failure as a finding about upstream: the same conflation the control arm
    #     exists to prevent, pointing the other way.
    _mkstub atuin-corrupt corrupt
    _v_run atuin-corrupt --json
    if [[ "$(_v_verdict "$_vout")" == unmeasurable ]] && ((_vrc == 3)); then
      pass "atuin verify: an unreadable DB mid-run is unmeasurable (rc 3), never moved"
    else
      fail "atuin verify: an unreadable DB must be unmeasurable, got $(_v_verdict "$_vout")/rc$_vrc"
    fi

    # 11. THE SAME RULE, ONE STEP LATER IN THE RUN. #10 covers a DB that stops being
    #     READABLE; this covers one that stops being WRITABLE, which the -1 sentinel cannot
    #     see at all — the reads keep succeeding, so all four arms report an honest-looking
    #     delta of 0 and the run would report `holds` from an apparatus that died after the
    #     opening control. Only the CLOSING control arm can tell those apart. Deleting this
    #     assertion is how that fail-open comes back, the same way #5 guards the first one.
    _mkstub atuin-stops stops
    _v_run atuin-stops --json
    if [[ "$(_v_verdict "$_vout")" == unmeasurable ]] && ((_vrc == 3)) && [[ "$_vout" == *CLOSING* ]]; then
      pass "atuin verify: an apparatus that stops writing mid-run is unmeasurable (rc 3), never holds"
    else
      fail "atuin verify: a mid-run write failure must be unmeasurable naming the closing arm, got $(_v_verdict "$_vout")/rc$_vrc"
    fi

    # 12. BUFFER-AND-REPLAY IS A FINDING, and it is invisible to the four arms: a spooled
    #     entry and a discarded one both leave the row count at 0 while the socket is
    #     unreachable. It matters because the guard degrades a shell PERMANENTLY on the first
    #     failed connect, and that is only correct while atuin is discarding — an atuin that
    #     replays inverts the reasoning (dotgibson/dotfiles-core#383). The stub spools its
    #     four daemon-on entries and flushes them with the next daemon-off write, so the
    #     closing arm lands 5 rows instead of 1.
    _mkstub atuin-replay replay
    _v_run atuin-replay --json
    if [[ "$(_v_verdict "$_vout")" == moved ]] && ((_vrc == 1)) &&
      [[ "$_vout" == *'"drain_delta":5'* ]] && [[ "$_vout" == *BUFFERS* ]]; then
      pass "atuin verify: an atuin that spools and replays is moved (rc 1), naming the inverted premise"
    else
      fail "atuin verify: buffer-and-replay must be moved/rc1 with drain_delta 5, got $(_v_verdict "$_vout")/rc$_vrc"
    fi
  fi
fi

