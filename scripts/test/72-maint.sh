# scripts/test/72-maint.sh
# maint dispatch through os.capabilities + the scheduler artifacts
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── maint dispatches through os.capabilities (#665) ──────────────────────────
# The probe above is what an UNDECLARED box uses, and that is every box that has not yet
# re-bootstrapped onto the declaration #667 authored for it — so it
# must keep working. These pin the other half: that a declaration is what actually decides,
# because a dispatcher nothing ever dispatches through looks identical to one that works.
CAPD_MNT="$SANDBOX/capmnt"
rm -rf "$CAPD_MNT"
mkdir -p "$CAPD_MNT"
CAPZ_M="$HERE/zsh/02-capabilities.zsh"
_mntcheck() { # _mntcheck <label> <decl> <body> [VAR=VAL ...]
  local label="$1" decl="$2" body="$3"
  shift 3
  printf '%s\n' "$decl" >"$CAPD_MNT/os.capabilities"
  ucheck "$label" "source '$UI'; source '$CAPZ_M'; source '$MNT'; $body" \
    PATH="$PMBIN" CORE_CAPABILITIES_FILE="$CAPD_MNT/os.capabilities" "$@"
}
_mntcheck "maint: a declared SCHEDULER decides, not the probe" \
  'SCHEDULER=systemd
SCHEDULER_UNIT_DIR=~/.config/systemd/user' \
  '[[ $(_maint_scheduler) == systemd ]]'
# SCHEDULER=none is a REAL answer — a container, a box with neither init — and probing past
# it to install a timer anyway would make the declaration a suggestion. This host has
# crontab on the stub PATH, so a fallthrough would answer `cron` and the assertion catches it.
_mntcheck "maint: a declared SCHEDULER=none is honoured, never probed past" \
  'SCHEDULER=none' \
  '[[ $(_maint_scheduler) == none ]]'
# The unit path is the declared DIRECTORY plus CORE's filename — the split that keeps
# `systemctl enable dotfiles-maint.timer` naming the file Core actually wrote.
_mntcheck "maint: the unit path is the declared dir + Core's own unit name" \
  'SCHEDULER=systemd
SCHEDULER_UNIT_DIR=/opt/units' \
  '[[ $(_maint_unit_file) == /opt/units/dotfiles-maint.service ]]'
_mntcheck "maint: a leading ~ in the declared dir expands (the reader never expands)" \
  'SCHEDULER=launchd
SCHEDULER_UNIT_DIR=~/Agents' \
  '[[ $(_maint_unit_file) == "$HOME/Agents/com.dotfiles.maint.plist" ]]'
# cron keeps no unit file of its own, so there is nothing to name.
_mntcheck "maint: cron resolves to no unit file (its entry lives in the crontab)" \
  'SCHEDULER=cron' \
  '[[ -z $(_maint_unit_file) ]]'

# maint-log defensive input (#6): a non-numeric N must be rejected in Core's voice, not
# handed to `tail` to fail with a raw "invalid number". -f/--follow and a positive int
# are the only valid args (mirrors serve/cdup/mkbak's input guards).
ucheck "maint: maint-log rejects a non-numeric N in Core's voice" \
  "source '$UI'; source '$MNT'; out=\$(maint-log abc 2>&1); (( \$? != 0 )) && [[ \$out == *'maint-log: N must be'* ]]" \
  PATH="$PMBIN"

# ── maint scheduler artifacts (systemd unit / launchd plist / cron line) ──────
# maint-install GENERATES a systemd unit+timer, a launchd plist (XML), and a cron line —
# fan-out artifacts that, until now, had NO gate: a malformed OnCalendar, a broken plist,
# or a bad cron field only fails on the user's box, then fans out to nine repos. Every OTHER
# fan-out artifact class is gated (toml/yaml/json §6, workflows actionlint §8); this closes
# the maint hole the same way. Hermetic: override _maint_scheduler to pick the branch,
# stub systemctl/launchctl/crontab to no-ops (so nothing touches the real system), sandbox
# HOME/XDG, render at 09:30, then VALIDATE the generated artifact. The runner path resolves
# to this repo's maint/dotfiles-maint.sh via maint.zsh's %x, so the [[ -f ]] guard passes.
hdr "maint scheduler artifacts (systemd / launchd / cron, hermetic render)"
SCHEDBIN="$SANDBOX/schedbin"
mkdir -p "$SCHEDBIN"
for s in systemctl launchctl; do
  printf '#!/bin/sh\n:\n' >"$SCHEDBIN/$s"
  chmod +x "$SCHEDBIN/$s"
done
# crontab stub: `-l` prints nothing (no existing table); `-` captures the new table to a
# file so we can assert the generated line instead of mutating the real crontab.
printf '#!/bin/sh\ncase "$1" in -l) exit 0 ;; -) cat > "$CRON_CAPTURE" ;; *) exit 0 ;; esac\n' >"$SCHEDBIN/crontab"
chmod +x "$SCHEDBIN/crontab"

# systemd: the timer's OnCalendar must be the rendered HH:MM, and the service must point
# ExecStart at the runner. Override the scheduler so the branch runs on any host.
ucheck "maint: systemd timer+service render with a valid OnCalendar" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; maint-install 09:30 >/dev/null 2>&1; ud=\"\$XDG_CONFIG_HOME/systemd/user\"; [[ -f \"\$ud/dotfiles-maint.timer\" && -f \"\$ud/dotfiles-maint.service\" ]] || exit 1; grep -q 'OnCalendar=\*-\*-\* 09:30:00' \"\$ud/dotfiles-maint.timer\" || exit 1; grep -q 'ExecStart=.*dotfiles-maint.sh' \"\$ud/dotfiles-maint.service\"" \
  PATH="$SCHEDBIN:$PATH" XDG_CONFIG_HOME="$SANDBOX/sched-systemd"
# cron: the captured table line must be a well-formed 5-field schedule at MM HH, tagged.
# The runner is single-quoted, which is part of the contract rather than incidental: cron's
# command field is handed to /bin/sh, so a bare runner is split on whitespace and a $(…) in
# the path would be evaluated on every scheduled run. Anchoring on the closing quote is what
# makes dropping the quoting fail HERE rather than on the one box whose path contains a space.
ucheck "maint: cron line renders as a valid 5-field schedule with the runner quoted" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; maint-install 09:30 >/dev/null 2>&1; [[ -f \"\$CRON_CAPTURE\" ]] || exit 1; grep -qE '^30 09 \* \* \* .*dotfiles-maint\.sh'\\'' # dotfiles-maint\$' \"\$CRON_CAPTURE\"" \
  PATH="$SCHEDBIN:$PATH" CRON_CAPTURE="$SANDBOX/cron.captured"
# launchd: the plist must be WELL-FORMED XML (plistlib parses it) with the rendered
# Hour/Minute — the one artifact that's silent text the other gates never inspect. Needs
# python3 (stdlib plistlib); skip gracefully otherwise, like the linters above.
if have python3; then
  ucheck "maint: launchd plist is well-formed XML with the rendered Hour/Minute" \
    "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; maint-install 09:30 >/dev/null 2>&1; p=\"\$HOME/Library/LaunchAgents/com.dotfiles.maint.plist\"; [[ -f \"\$p\" ]] || exit 1; python3 -c 'import sys,plistlib; d=plistlib.load(open(sys.argv[1],\"rb\")); s=d[\"StartCalendarInterval\"]; sys.exit(0 if s[\"Hour\"]==9 and s[\"Minute\"]==30 else 1)' \"\$p\"" \
    PATH="$SCHEDBIN:$PATH" HOME="$SANDBOX/sched-launchd"
else
  skip "maint launchd plist (python3 absent — cannot parse plist XML)"
fi

# ── the PATH capture (the one seam where an OS prefix may enter the runner) ───
# maint/dotfiles-maint.sh is portable Core and names no Homebrew/pkgsrc/Nix prefix, so
# the scheduler unit is the ONLY thing that tells the unattended runner where this box
# keeps its binaries. Drop the capture in a refactor and nothing breaks loudly: the job
# still fires, still logs, still exits 0 — it just resolves no brew/mise and skips those
# steps silently. That is why this is asserted per-scheduler rather than trusted.
# A /sentinel/bin injected into PATH at install time must appear in the rendered unit.
ucheck "maint: systemd unit bakes in the installing shell's PATH" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; PATH=/sentinel/bin:\$PATH maint-install 09:30 >/dev/null 2>&1; grep -q '^Environment=\"PATH=.*/sentinel/bin' \"\$XDG_CONFIG_HOME/systemd/user/dotfiles-maint.service\"" \
  PATH="$SCHEDBIN:$PATH" XDG_CONFIG_HOME="$SANDBOX/sched-path-systemd"
# cron's command field is sh, so the PATH rides as an env prefix — and `%` is cron's
# newline metacharacter, which would truncate the line mid-PATH if it were not escaped.
# The sentinel deliberately contains one.
ucheck "maint: cron line carries the PATH, single-quoted, with % escaped" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; PATH='/sent%inel/bin':\$PATH maint-install 09:30 >/dev/null 2>&1; line=\$(cat \"\$CRON_CAPTURE\"); [[ \$line == *\"PATH='\"* ]] && [[ \$line == *'sent\\%inel'* ]]" \
  PATH="$SCHEDBIN:$PATH" CRON_CAPTURE="$SANDBOX/cron-path.captured"
# The decisive one. cron's command field is handed to /bin/sh, so a PATH entry holding
# $(…), a backtick, or a quote is CODE unless it is quoted as DATA — an unquoted or
# double-quoted assignment would evaluate it on every scheduled run, silently and with
# the user's privileges. Build the assignment exactly as maint-install does, then let a
# real /bin/sh parse it back and compare: nothing but a true round-trip passes this.
_mq_want='/we'"'"'ird/$(echo pwned)/`echo pwned`/"dq"/bin'
_mq_rendered="$(zsh -c "source '$UI'; source '$MNT'; _maint_sh_squote \"\$1\"" _ "$_mq_want" 2>/dev/null)"
_mq_got="$(sh -c "PATH=$_mq_rendered; printf '%s' \"\$PATH\"" 2>/dev/null)"
if [[ "$_mq_got" == "$_mq_want" ]]; then
  pass "maint: a hostile PATH round-trips through /bin/sh as data (no \$() evaluation)"
else
  fail "maint: PATH did not round-trip through sh (got '$_mq_got')"
fi
# launchd's plist is XML: an unescaped & in a directory name yields a malformed plist
# that launchctl rejects at load time, i.e. a schedule that silently never runs. Assert
# plistlib can still PARSE it and that the value round-trips — the escape and the parse
# together, since either alone would pass while the pair is broken.
if have python3; then
  ucheck "maint: launchd plist XML-escapes the PATH and still parses" \
    "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; PATH='/a&b/bin':\$PATH maint-install 09:30 >/dev/null 2>&1; python3 -c 'import sys,plistlib; d=plistlib.load(open(sys.argv[1],\"rb\")); sys.exit(0 if \"/a&b/bin\" in d[\"EnvironmentVariables\"][\"PATH\"] else 1)' \"\$HOME/Library/LaunchAgents/com.dotfiles.maint.plist\"" \
    PATH="$SCHEDBIN:$PATH" HOME="$SANDBOX/sched-path-launchd"
else
  skip "maint launchd PATH capture (python3 absent — cannot parse plist XML)"
fi
# systemd expands % SPECIFIERS inside Environment= (%h = home, %i = instance, …), so a
# legitimate PATH entry like /sent%h/bin would silently become /sent<homedir>/bin — or
# the unit would refuse to load on an unknown specifier. Quotes and backslashes carry
# unit-file syntax there too. Assert the three documented substitutions against a
# literal expectation rather than round-tripping through a reimplementation of the rule.
_ms_got="$(zsh -c "source '$UI'; source '$MNT'; _maint_systemd_escape \"\$1\"" _ '/a%h/b"c/d\e/bin' 2>/dev/null)"
_ms_want='/a%%h/b\"c/d\\e/bin'
if [[ "$_ms_got" == "$_ms_want" ]]; then
  pass "maint: systemd Environment= escapes %, \" and \\ (no specifier expansion)"
else
  fail "maint: systemd escape wrong (got '$_ms_got' want '$_ms_want')"
fi
# ...and the rendered unit actually carries it, so the helper cannot be wired up wrong.
ucheck "maint: the systemd unit's PATH survives a % in the installing PATH" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; PATH='/sent%h/bin':\$PATH maint-install 09:30 >/dev/null 2>&1; grep -q 'Environment=\"PATH=/sent%%h/bin' \"\$XDG_CONFIG_HOME/systemd/user/dotfiles-maint.service\"" \
  PATH="$SCHEDBIN:$PATH" XDG_CONFIG_HOME="$SANDBOX/sched-pct-systemd"

# ── the stale-unit detector (_maint_unit_needs_refresh) ──────────────────────
# This is what makes the migration survivable. A unit written before the PATH capture
# still fires, still logs, still exits 0 — and silently resolves no brew/mise. maint-status
# is the ONLY place that can surface it, so the detector is load-bearing rather than a
# nicety.
#
# The SECOND silent death is a unit whose recorded runner path no longer resolves: move
# the consuming repo and the scheduler keeps firing at the old absolute path. Observed in
# the wild, and invisible from every angle — `maint-status` printed the timer happily,
# `launchctl list` reported exit status 0 (the job had not fired since the move), and
# `maint-run` kept working because it re-resolves the runner from the live config rather
# than reading the unit. Only reading the unit back catches it, so each arm is asserted
# per-scheduler with a REAL runner path for the healthy fixture — point the "current"
# fixtures at a path that does not exist and this whole section passes vacuously.
#
# Four states per scheduler, and the last matters as much as the others: a box with NO
# schedule installed must stay quiet, or every such box is nagged forever.
_MRF="$SANDBOX/maint-refresh"
_MRF_RUNNER="$HERE/maint/dotfiles-maint.sh" # a path that really exists
_MRF_GONE="$_MRF/moved-away/core/maint/dotfiles-maint.sh"
rm -rf "$_MRF"
mkdir -p "$_MRF/bin" "$_MRF/sd-new/systemd/user" "$_MRF/sd-old/systemd/user" \
  "$_MRF/sd-dead/systemd/user" "$_MRF/sd-none" \
  "$_MRF/ld-new/Library/LaunchAgents" "$_MRF/ld-old/Library/LaunchAgents" \
  "$_MRF/ld-dead/Library/LaunchAgents" "$_MRF/ld-none"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash %s\n' "$_MRF_RUNNER" \
  >"$_MRF/sd-new/systemd/user/dotfiles-maint.service"
printf '[Service]\nExecStart=/usr/bin/env bash %s\n' "$_MRF_RUNNER" \
  >"$_MRF/sd-old/systemd/user/dotfiles-maint.service"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash %s\n' "$_MRF_GONE" \
  >"$_MRF/sd-dead/systemd/user/dotfiles-maint.service"
printf '<plist><dict><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x/bin</string></dict></dict></plist>\n' \
  "$_MRF_RUNNER" >"$_MRF/ld-new/Library/LaunchAgents/com.dotfiles.maint.plist"
# ld-old is precisely the case a bare `EnvironmentVariables` presence test MISSES: the
# dict exists but carries no PATH, so the runner is still handed a stripped environment
# while the detector reports the schedule as current.
printf '<plist><dict><key>EnvironmentVariables</key><dict><key>LANG</key><string>C</string></dict></dict></plist>\n' \
  >"$_MRF/ld-old/Library/LaunchAgents/com.dotfiles.maint.plist"
# ld-dead is the observed macOS case, rendered as maint-install writes it (ProgramArguments
# on its own line, argv[0] the interpreter) so the argv[1] extraction is exercised for real.
printf '<plist><dict>\n  <key>ProgramArguments</key>\n  <array><string>/bin/bash</string><string>%s</string></array>\n  <key>EnvironmentVariables</key>\n  <dict><key>PATH</key><string>/x/bin</string></dict>\n</dict></plist>\n' \
  "$_MRF_GONE" >"$_MRF/ld-dead/Library/LaunchAgents/com.dotfiles.maint.plist"
printf '#!/bin/sh\ncase "$1" in -l) cat "${CRON_TABLE:-/dev/null}" ;; *) exit 0 ;; esac\n' >"$_MRF/bin/crontab"
chmod +x "$_MRF/bin/crontab"
# The PATH prefix is SINGLE-quoted, as _maint_sh_squote renders it — the runner extraction
# has to step over that assignment, so a fixture using bare or double quotes would let a
# parser that simply grabbed field 6 pass.
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash %s # dotfiles-maint\n" "$_MRF_RUNNER" >"$_MRF/cron-new"
printf '30 09 * * * /usr/bin/env bash %s # dotfiles-maint\n' "$_MRF_RUNNER" >"$_MRF/cron-old"
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash %s # dotfiles-maint\n" "$_MRF_GONE" >"$_MRF/cron-dead"
: >"$_MRF/cron-none"

ucheck "maint/refresh: systemd unit WITH the PATH capture and a resolvable runner is current" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-new"
ucheck "maint/refresh: systemd unit WITHOUT it is flagged stale (why=path)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == path ]]" \
  XDG_CONFIG_HOME="$_MRF/sd-old"
ucheck "maint/refresh: systemd unit whose runner path is gone is flagged (why=runner)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  XDG_CONFIG_HOME="$_MRF/sd-dead"
ucheck "maint/refresh: no systemd unit at all stays quiet (no nag without a schedule)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-none"
ucheck "maint/refresh: launchd plist WITH a PATH key and a resolvable runner is current" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; ! _maint_unit_needs_refresh" \
  HOME="$_MRF/ld-new"
ucheck "maint/refresh: launchd plist with EnvironmentVariables but NO PATH is flagged stale (why=path)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == path ]]" \
  HOME="$_MRF/ld-old"
ucheck "maint/refresh: launchd plist whose ProgramArguments runner is gone is flagged (why=runner)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  HOME="$_MRF/ld-dead"
ucheck "maint/refresh: no launchd plist at all stays quiet" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; ! _maint_unit_needs_refresh" \
  HOME="$_MRF/ld-none"
ucheck "maint/refresh: cron line carrying a PATH and a resolvable runner is current" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-new"
ucheck "maint/refresh: cron line without a PATH is flagged stale (why=path)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == path ]]" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-old"
ucheck "maint/refresh: cron line whose runner path is gone is flagged (why=runner)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-dead"
ucheck "maint/refresh: an empty crontab stays quiet" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-none"
# The runner a unit records must be read back VERBATIM — the hint prints it, and an
# extraction that mangled it (dropping the PATH prefix's quoting, or half a path with a
# space) would still "detect" a dead runner while telling the operator the wrong path.
ucheck "maint/refresh: the recorded runner path is read back verbatim (launchd argv[1])" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; [[ \"\$(_maint_unit_runner)\" == '$_MRF_GONE' ]]" \
  HOME="$_MRF/ld-dead"
ucheck "maint/refresh: the recorded runner path is read back verbatim (cron, past the PATH prefix)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ \"\$(_maint_unit_runner)\" == '$_MRF_GONE' ]]" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-dead"

# ── the runner path is DATA in three different grammars ──────────────────────
# maint-install escapes the captured PATH per scheduler but wrote the RUNNER raw, and the
# runner is not a constant: it is wherever the consuming repo was cloned to. Every one of
# the three failures is silent or nearly so, which is why they survived —
#
#   systemd  % is a SPECIFIER in ExecStart, so a repo under …/a%h/… runs a different path
#            (or the unit refuses to load on an unknown one); an unquoted argument is also
#            split on whitespace, and " / \ carry unit-file syntax.
#   cron     % is cron's NEWLINE metacharacter: the command is truncated there and the
#            remainder is fed to it as stdin, so the job simply stops running. Unquoted,
#            the command field is also sh, so a space splits it and $(…) is CODE.
#   launchd  & < > make the plist malformed and `launchctl load` rejects it.
#
# One fixture path carries all of it — % space & < > " \ ' — and each arm asserts the full
# loop: maint-install renders it, _maint_unit_runner reads it back VERBATIM, and the unit
# reads as CURRENT rather than as a dead runner. That last part is the user-visible bug:
# before this, a repo at such a path got a broken schedule AND a maint-status that either
# said nothing or named the wrong file.
#
# The pre-existing fixtures above all use the older UNQUOTED shapes, so they double as the
# backward-compatibility gate: units already on disk are only rewritten when the operator
# re-runs maint-install, and must keep parsing until they do.
# Every hazard in one component. The last four are the ones a "looks about right" fixture
# misses: `$i`/`${j}` because systemd substitutes VARIABLES in ExecStart on top of its %
# specifiers, and `\n`/`\c` because they are the two-character sequences zsh's `echo`
# builtin would rewrite — `\c` truncating the crontab line outright. An earlier revision of
# this fixture used `\g`, which is not a recognized escape, so the whole hazard sat
# unexercised while the assertion read green.
_MRF_HOSTILE_DIR="$_MRF/hostile/a%h b&c<d>e\"f\\g'h\$i\${j}\\nk\\cl"
_MRF_HOSTILE="$_MRF_HOSTILE_DIR/dotfiles-maint.sh"
if mkdir -p "$_MRF_HOSTILE_DIR" 2>/dev/null && printf '#!/bin/bash\n:\n' >"$_MRF_HOSTILE" 2>/dev/null; then
  # A crontab stub that ROUND-TRIPS: `-` stores the table, `-l` reads that same table back.
  # The one above is read-only, and install-then-read is the whole point here.
  mkdir -p "$_MRF/rtbin"
  printf '#!/bin/sh\ncase "$1" in -l) [ -f "$CRON_TABLE" ] && cat "$CRON_TABLE"; exit 0 ;; -) cat > "$CRON_TABLE" ;; *) exit 0 ;; esac\n' >"$_MRF/rtbin/crontab"
  chmod +x "$_MRF/rtbin/crontab"
  : >"$_MRF/cron-hostile"
  # The path rides in through the ENVIRONMENT — it holds a single quote, a double quote and
  # a backslash, so interpolating it into the assertion body would rewrite the body itself.
  _MRF_RT="source '$UI'; source '$MNT'; _MAINT_SH=\"\$SH\"; _maint_scheduler() { echo SCHED }; maint-install 09:30 >/dev/null 2>&1; [[ \"\$(_maint_unit_runner)\" == \"\$SH\" ]] && ! _maint_unit_needs_refresh"

  ucheck "maint/refresh: a runner path holding % \$ \" \\ and a space round-trips through the systemd unit" \
    "${_MRF_RT/SCHED/systemd}" \
    PATH="$SCHEDBIN:$PATH" XDG_CONFIG_HOME="$_MRF/rt-sd" SH="$_MRF_HOSTILE"
  ucheck "maint/refresh: a runner path holding & < > and a quote round-trips through the launchd plist" \
    "${_MRF_RT/SCHED/launchd}" \
    PATH="$SCHEDBIN:$PATH" HOME="$_MRF/rt-ld" SH="$_MRF_HOSTILE"
  ucheck "maint/refresh: a runner path holding % and shell metacharacters round-trips through the cron line" \
    "${_MRF_RT/SCHED/cron}" \
    PATH="$_MRF/rtbin:$SCHEDBIN:$PATH" CRON_TABLE="$_MRF/cron-hostile" SH="$_MRF_HOSTILE"

  # ...and the same three artifacts read by something that is NOT this codebase. A round-trip
  # through our own reader proves only that the two halves AGREE — escape it wrongly and
  # unescape it wrongly the same way and the assertions above stay green while the scheduler
  # runs nothing. These pin the emitted text against the real grammar instead, the way the
  # PATH assertions already do.
  #
  # systemd has no parser to borrow on a macOS runner, so it gets the literal expectation:
  # the ONE directory component is spelled out post-escape (% doubled, " and \ backslashed)
  # rather than recomputed here — restating the rule in the test would let a wrong rule pass.
  if grep -qF 'ExecStart=/usr/bin/env bash "' "$_MRF/rt-sd/systemd/user/dotfiles-maint.service" 2>/dev/null &&
    grep -qF 'a%%h b&c<d>e\"f\\g'"'"'h$$i$${j}\\nk\\cl/dotfiles-maint.sh"' "$_MRF/rt-sd/systemd/user/dotfiles-maint.service" 2>/dev/null; then
    pass "maint: the systemd ExecStart runner is quoted with %, \$, \" and \\ escaped"
  else
    fail "maint: the systemd ExecStart runner is not escaped as expected"
  fi
  # cron: let a real /bin/sh parse the command back, after applying cron's OWN pass (\% → %)
  # exactly as crond would before handing the field over. Exactly one argument must come out
  # of it, spelled the same as the file on disk.
  # ONE line, AND that line reaches its terminating marker. maint-install runs under
  # `emulate -L zsh`, where `echo` interprets backslash escapes, so a `\n` in the runner
  # splits the entry in two and a `\c` truncates it and swallows the trailing newline.
  #
  # BOTH halves are needed, and the reason is worth stating because the obvious single check
  # does not work: with this fixture the two corruptions CANCEL in the line count — `\n`
  # adds a newline, `\c` removes the final one, and a line count of exactly 1 comes back
  # from a table that is in fact one wrapped fragment plus one unterminated one. What the
  # truncation cannot fake is arriving at the marker, since everything past the `\c` is
  # gone. Verified against a reverted copy of the module: `echo` yields marker-terminated=0
  # while `print -r` yields 1, with the line count reading 1 for both.
  _mr_nlines="$(wc -l <"$_MRF/cron-hostile" 2>/dev/null | tr -d ' ')"
  _mr_tagged="$(grep -c '# dotfiles-maint$' "$_MRF/cron-hostile" 2>/dev/null || true)"
  if [[ "$_mr_nlines" == 1 && "$_mr_tagged" == 1 ]]; then
    pass "maint: the cron entry is one marker-terminated line (no echo-escape split or truncation)"
  else
    fail "maint: cron table is $_mr_nlines line(s), $_mr_tagged marker-terminated — a backslash escape corrupted the entry"
  fi
  _mr_line="$(cat "$_MRF/cron-hostile" 2>/dev/null)"
  # A BARE % is one left over once every escaped \% is accounted for — testing for the
  # mere presence of \% would pass a line that escaped the PATH's % and not the runner's.
  if [[ "${_mr_line//\\%/}" == *'%'* ]]; then
    fail "maint: the cron line carries a BARE % — crond truncates the command there"
  else
    _mr_tok="${_mr_line% # dotfiles-maint}"
    _mr_tok="${_mr_tok#*"/usr/bin/env bash "}"
    _mr_tok="${_mr_tok//\\%/%}" # cron's own unescape
    _mr_got="$(sh -c "set -- $_mr_tok; printf '%s|%s' \"\$#\" \"\$1\"" 2>/dev/null)"
    if [[ "$_mr_got" == "1|$_MRF_HOSTILE" ]]; then
      pass "maint: the cron runner survives cron's % pass and reaches sh as one argument"
    else
      fail "maint: cron runner did not round-trip through sh (got '$_mr_got')"
    fi
  fi
  # launchd: plistlib is the third party, as it is for the PATH value two sections up.
  if have python3; then
    if python3 -c 'import sys,plistlib; d=plistlib.load(open(sys.argv[1],"rb")); sys.exit(0 if d["ProgramArguments"][1]==sys.argv[2] else 1)' \
      "$_MRF/rt-ld/Library/LaunchAgents/com.dotfiles.maint.plist" "$_MRF_HOSTILE" 2>/dev/null; then
      pass "maint: the launchd plist still parses and ProgramArguments[1] is the real path"
    else
      fail "maint: the launchd plist is malformed or ProgramArguments[1] is not the runner"
    fi
  else
    skip "maint launchd runner escape (python3 absent — cannot parse plist XML)"
  fi
else
  # Some filesystems (a CI runner on exFAT, a Windows-hosted mount) reject " or \ in a
  # name. Skipping is honest; silently passing would vouch for an escape never exercised.
  skip "maint runner-path escaping (this filesystem rejects a name holding \" or \\)"
fi

# The refusals — the other half of the contract, and the half that decides whether this
# feature is trustworthy. systemd's ExecStart and cron's command field are COMMANDS, not
# path fields, so a parse that swallows the whole tail turns `bash /a/live/runner --quiet`
# into the nonexistent path "/a/live/runner --quiet" and reports a HEALTHY job as dead.
# The launchd equivalent is an `<array>` that is not ProgramArguments' own value: skip over
# a non-array value there and the parser lifts the second string out of whatever key owns
# the NEXT array, naming a path the unit never runs. Each fixture below runs a runner that
# genuinely EXISTS, so a regression here is a false death notice, not a missed one.
mkdir -p "$_MRF/sd-args/systemd/user" "$_MRF/ld-displaced/Library/LaunchAgents"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash %s --quiet\n' "$_MRF_RUNNER" \
  >"$_MRF/sd-args/systemd/user/dotfiles-maint.service"
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash %s >>/tmp/m.log # dotfiles-maint\n" "$_MRF_RUNNER" \
  >"$_MRF/cron-args"
printf '<plist><dict><key>ProgramArguments</key><string>%s</string><key>WatchPaths</key><array><string>/a</string><string>%s</string></array><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x/bin</string></dict></dict></plist>\n' \
  "$_MRF_RUNNER" "$_MRF_GONE" >"$_MRF/ld-displaced/Library/LaunchAgents/com.dotfiles.maint.plist"

ucheck "maint/refresh: a systemd ExecStart with extra argv is refused, not read as one path" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-args"
ucheck "maint/refresh: a cron command with a redirection is refused, not read as one path" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-args"
ucheck "maint/refresh: a later key's <array> is not mistaken for ProgramArguments'" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  HOME="$_MRF/ld-displaced"

# The same rule against the QUOTED shapes, where "one argument" is a property of where the
# closing quote sits rather than of whitespace. Both fixtures run a runner that exists, so
# a regression is again a false death notice. The third is the quoted counterpart of the
# `%` refusal below: there, a bare `%` reaches `_maint_lone_arg` and is rejected because
# nothing escaped it; here the value IS escaped, so a SINGLE `%` inside the quotes is a
# specifier that survived — a path we cannot reconstruct without reimplementing systemd's
# table, and therefore not evidence of anything either.
mkdir -p "$_MRF/sd-qargs/systemd/user" "$_MRF/sd-spec/systemd/user"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash "%s" --quiet\n' "$_MRF_RUNNER" \
  >"$_MRF/sd-qargs/systemd/user/dotfiles-maint.service"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash "/a%%h/dotfiles-maint.sh"\n' \
  >"$_MRF/sd-spec/systemd/user/dotfiles-maint.service"
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash '%s' >>/tmp/m.log # dotfiles-maint\n" "$_MRF_RUNNER" \
  >"$_MRF/cron-qargs"

ucheck "maint/refresh: a quoted systemd runner with argv after the closing quote is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-qargs"
ucheck "maint/refresh: a QUOTED systemd runner holding an unresolved % specifier is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-spec"
ucheck "maint/refresh: a quoted cron runner with a redirection after it is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-qargs"

# The two metacharacters that sh QUOTING does not save you from, one per scheduler. cron
# translates % before sh ever sees the field, so a bare % inside the quotes still truncates
# the command; systemd substitutes $VAR inside double quotes, so `$HOME` there is not the
# path it runs. Both fixtures name a runner that RESOLVES if the metacharacter is merely
# ignored — so a reader that failed to refuse would hand back a confident wrong verdict
# about a job that does not run, which is worse than the noisy kind.
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash '%s' # dotfiles-maint\n" "$_MRF_RUNNER%h" \
  >"$_MRF/cron-qpct"
mkdir -p "$_MRF/sd-qvar/systemd/user"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash "%s$HOME"\n' "$_MRF_RUNNER" \
  >"$_MRF/sd-qvar/systemd/user/dotfiles-maint.service"

ucheck "maint/refresh: a QUOTED cron runner carrying a bare % is refused (quoting is no defence)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-qpct"
ucheck "maint/refresh: a QUOTED systemd runner carrying a \$VAR reference is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-qvar"

# A RELATIVE recorded runner is the one value that cannot be tested at all: `[[ -f ]]`
# resolves it against whatever directory maint-status was invoked from, so the same unit
# would read dead in one shell and alive in another — a verdict about the caller, not the
# unit. maint-install never writes one ($_MAINT_SH is `:A`-resolved at the top of the
# module), and a hand-edited unit can legitimately pair a relative script with systemd's
# WorkingDirectory= or cron's implicit $HOME. All three arms must stay quiet.
mkdir -p "$_MRF/sd-rel/systemd/user" "$_MRF/ld-rel/Library/LaunchAgents"
_MRF_REL='core/maint/dotfiles-maint.sh'
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash %s\n' "$_MRF_REL" \
  >"$_MRF/sd-rel/systemd/user/dotfiles-maint.service"
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash %s # dotfiles-maint\n" "$_MRF_REL" >"$_MRF/cron-rel"
printf '<plist><dict><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x/bin</string></dict></dict></plist>\n' \
  "$_MRF_REL" >"$_MRF/ld-rel/Library/LaunchAgents/com.dotfiles.maint.plist"

ucheck "maint/refresh: a relative systemd runner is refused (verdict must not depend on cwd)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-rel"
ucheck "maint/refresh: a relative cron runner is refused (verdict must not depend on cwd)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-rel"
ucheck "maint/refresh: a relative launchd runner is refused (verdict must not depend on cwd)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  HOME="$_MRF/ld-rel"

# The last way to name a path the unit does not actually run: read an argument belonging to
# some OTHER program. Both fixtures below are healthy jobs — `/bin/echo /missing` succeeds —
# so extracting `/missing` from either would be a death notice for a live schedule. The
# interpreter has to be identified by POSITION (launchd argv[0]; cron's command, anchored to
# the closing quote of the PATH assignment), not merely found somewhere in the unit.
mkdir -p "$_MRF/ld-argv0/Library/LaunchAgents"
printf '<plist><dict><key>ProgramArguments</key><array><string>/bin/echo</string><string>%s</string></array><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x/bin</string></dict></dict></plist>\n' \
  "$_MRF_GONE" >"$_MRF/ld-argv0/Library/LaunchAgents/com.dotfiles.maint.plist"
printf "30 09 * * * PATH='/x/bin' /bin/echo /usr/bin/env bash %s # dotfiles-maint\n" "$_MRF_GONE" >"$_MRF/cron-spliced"

ucheck "maint/refresh: a launchd argv[0] that is not the interpreter is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  HOME="$_MRF/ld-argv0"
ucheck "maint/refresh: a cron command with another program spliced before the interpreter is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-spliced"

# ...and the version of that splice which HIDES the anchor inside a quoted argument. This
# is why the PATH value is consumed as a real single-quoted token (_maint_squote_rest)
# rather than located by searching: `/bin/echo '␣/usr/bin/env bash /missing'` runs echo and
# is healthy, but contains a quote followed by the exact interpreter text, so any
# appearance-based anchor reads /missing back as our runner. The escaped-quote fixture is
# the other half — the scanner must step OVER a '\'' inside the value, or a legitimate
# PATH containing an apostrophe would stop the scan early and lose the real runner.
printf "30 09 * * * PATH='/x' /bin/echo ' /usr/bin/env bash %s' # dotfiles-maint\n" "$_MRF_GONE" >"$_MRF/cron-quoted"
printf "30 09 * * * PATH='/we'\\\\''ird/bin' /usr/bin/env bash %s # dotfiles-maint\n" "$_MRF_GONE" >"$_MRF/cron-squote"

ucheck "maint/refresh: a cron argument that merely QUOTES the interpreter text is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-quoted"
ucheck "maint/refresh: a PATH value containing an escaped quote does not derail the scan" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ \"\$(_maint_unit_runner)\" == '$_MRF_GONE' ]]" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-squote"

# launchd entity decoding. A plist may legally encode a quote as &quot;/&apos;, and launchd
# resolves it to the real filename — returning the encoded text would name a path that does
# not exist and call a live job dead. Anything we CANNOT decode (a numeric reference, an
# unknown entity) is refused for the same reason, from the other direction: a filename we
# cannot reconstruct is not evidence of anything.
mkdir -p "$_MRF/ld-entity/Library/LaunchAgents" "$_MRF/ld-numref/Library/LaunchAgents"
_MRF_QUOTED="$_MRF/moved'away/core/maint/dotfiles-maint.sh"
printf '<plist><dict><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s/moved&apos;away/core/maint/dotfiles-maint.sh</string></array><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x/bin</string></dict></dict></plist>\n' \
  "$_MRF" >"$_MRF/ld-entity/Library/LaunchAgents/com.dotfiles.maint.plist"
printf '<plist><dict><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s&#47;gone&#47;dotfiles-maint.sh</string></array><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x/bin</string></dict></dict></plist>\n' \
  "$_MRF" >"$_MRF/ld-numref/Library/LaunchAgents/com.dotfiles.maint.plist"

# The expectation rides in via the ENVIRONMENT, not interpolated into the assertion text:
# the whole point of this fixture is a path containing a single quote, which would close
# the quoting of the body itself. (The other verbatim checks above interpolate safely only
# because their paths happen to hold no quote — a hazard of the harness, not of the code.)
ucheck "maint/refresh: launchd decodes &apos; so the hint names the real filename" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; [[ \"\$(_maint_unit_runner)\" == \"\$WANT\" ]] && _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  HOME="$_MRF/ld-entity" WANT="$_MRF_QUOTED"
ucheck "maint/refresh: a launchd path with an undecodable numeric reference is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  HOME="$_MRF/ld-numref"

# The two causes are not mutually exclusive, and a unit predating the PATH capture is if
# anything the LIKELIEST to have been orphaned by a move as well — it is the oldest thing
# on the box. Reporting the milder cause there tells the operator "some steps will skip"
# about a job that does not run at all. The runner is inspected first for that reason, and
# these fixtures pin it per arm, since each arm detects the PATH separately. The cron one
# also exercises the pre-capture LINE SHAPE (no `PATH=` prefix): refusing to parse it would
# silently reintroduce the misclassification for exactly the units most likely to hit it.
mkdir -p "$_MRF/sd-old-dead/systemd/user" "$_MRF/ld-old-dead/Library/LaunchAgents"
printf '[Service]\nExecStart=/usr/bin/env bash %s\n' "$_MRF_GONE" \
  >"$_MRF/sd-old-dead/systemd/user/dotfiles-maint.service"
printf '<plist><dict><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array><key>EnvironmentVariables</key><dict><key>LANG</key><string>C</string></dict></dict></plist>\n' \
  "$_MRF_GONE" >"$_MRF/ld-old-dead/Library/LaunchAgents/com.dotfiles.maint.plist"
printf '30 09 * * * /usr/bin/env bash %s # dotfiles-maint\n' "$_MRF_GONE" >"$_MRF/cron-old-dead"

ucheck "maint/refresh: a pre-capture systemd unit that is ALSO dead reports runner, not path" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  XDG_CONFIG_HOME="$_MRF/sd-old-dead"
ucheck "maint/refresh: a pre-capture launchd plist that is ALSO dead reports runner, not path" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo launchd }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  HOME="$_MRF/ld-old-dead"
ucheck "maint/refresh: a pre-capture cron line that is ALSO dead reports runner, not path" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; _maint_unit_needs_refresh && [[ \$_MAINT_REFRESH_WHY == runner ]]" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-old-dead"

# A `%` in the recorded runner means the literal text is NOT what runs. systemd expands
# specifiers in ExecStart (%h and friends) — the very expansion _maint_systemd_escape
# already doubles against in `Environment=` — and cron treats % as its newline
# metacharacter, so everything past it becomes stdin. `-f` on the raw text answers a
# question about a path nothing executes, so both arms must refuse. The fixtures use a
# runner that would RESOLVE if the % were simply ignored, so a reader that failed to
# refuse would emit a confident, wrong verdict rather than merely a noisy one.
mkdir -p "$_MRF/sd-pct/systemd/user"
printf '[Service]\nEnvironment="PATH=/x/bin"\nExecStart=/usr/bin/env bash %s\n' "$_MRF_RUNNER%h" \
  >"$_MRF/sd-pct/systemd/user/dotfiles-maint.service"
printf "30 09 * * * PATH='/x/bin' /usr/bin/env bash %s # dotfiles-maint\n" "$_MRF_RUNNER%m" >"$_MRF/cron-pct"

ucheck "maint/refresh: a systemd runner carrying a % specifier is refused (not the path that runs)" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo systemd }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  XDG_CONFIG_HOME="$_MRF/sd-pct"
ucheck "maint/refresh: a cron runner carrying % (cron's newline metacharacter) is refused" \
  "source '$UI'; source '$MNT'; _maint_scheduler() { echo cron }; [[ -z \"\$(_maint_unit_runner)\" ]] && ! _maint_unit_needs_refresh" \
  PATH="$_MRF/bin:$PATH" CRON_TABLE="$_MRF/cron-pct"
