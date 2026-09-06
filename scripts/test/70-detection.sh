# scripts/test/70-detection.sh
# detection + UX unit tests (ui.zsh), tool ladders, PATH order, band placement
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── detection + UX unit tests (ui.zsh / update.zsh / maint.zsh) ───────────────
# The load-order and function-unit fragments (60-loader.sh, 65-functions.sh) and
# audit-core.sh's static pass leave the highest-LOGIC, highest
# fan-out helpers unproven: the package-manager and scheduler detection LADDERS
# (which differ per distro and silently mis-fire) and ui.zsh's defensive no-TTY
# confirm. A regression in any of these ships to all nine Core-vendoring repos — exactly what a
# behavioral gate must catch. Each is driven HERMETICALLY against a stubbed PATH
# (the same technique the clip ladder in scripts/test/10-clipboard.sh uses), so the result is
# deterministic on every CI userland (glibc / BSD / musl) regardless of what's
# actually installed there.
hdr "detection + UX unit tests (ui / update / maint)"
_real_zsh="$(command -v zsh)"
UPD="$HERE/zsh/60-update.zsh"
# MNT is read by scripts/test/72-maint.sh, which runs later in the same shell — it is set
# here with the other module paths so the whole zsh-fixture preamble stays in one place.
# shellcheck disable=SC2034  # cross-fragment: consumed by scripts/test/72-maint.sh
MNT="$HERE/zsh/55-maint.zsh"
CAPZ="$HERE/zsh/02-capabilities.zsh"
# Since #763 Core carries NO built-in package-manager row, so every case below that
# exercises a resolved verb has to seed a declaration — an undeclared box resolves nothing
# and that is now the correct answer, not a fallback. $CAPDECL is the shared scratch
# declaration for this section, seeded by _decl_as and read through CORE_CAPABILITIES_FILE;
# each case names the archive whose behaviour it is pinning.
CAPDECL="$SANDBOX/section-decl.capabilities"
_decl_as() { printf '%s\n' "$1" >"$CAPDECL"; } # _decl_as <KEY=value lines>
# The apt/Debian declaration, which is what most of this section's stubs impersonate. It is
# a copy of dotfiles-Debian/os/debian.capabilities' package half, kept here rather than read
# from the sibling clone: this suite must be hermetic and green with no fleet checked out.
_DECL_APT='PKG_UPGRADE=sudo apt-get full-upgrade
PKG_UPGRADE_PRE=sudo apt-get update
PKG_UPGRADE_PARTIAL=sudo apt-get install --only-upgrade
PKG_CLEANUP=sudo apt-get autoremove
PKG_ASSUME_YES=-y
PKG_COUNT_PENDING=apt-get -s upgrade
PKG_PENDING_MATCH=^Inst[[:space:]]
PKG_PENDING_FIELD=2'
_decl_as "$_DECL_APT"
# A fake bin dir holding ONE stub command, used to pin a detection ladder's answer.
PMBIN="$SANDBOX/pmbin"
_pm_only() {
  rm -rf "$PMBIN"
  mkdir -p "$PMBIN"
  [[ -n "${1:-}" ]] && {
    printf '#!/bin/sh\n:\n' >"$PMBIN/$1"
    chmod +x "$PMBIN/$1"
  }
}

# Run a zsh assertion that must exit 0; on failure print the captured output indented
# (same diagnostics contract as check() above). Trailing args are `VAR=VAL` env prefixes
# applied to the child — used to isolate PATH for the detection ladders. Runs INTERACTIVE
# (-i): update.zsh gates its whole body behind `[[ $- == *i* ]]`, so a non-interactive
# `-fc` would source to a no-op. `$_real_zsh` (absolute) keeps zsh reachable even when
# the test isolates PATH down to the stub dir.
ucheck() { # ucheck <label> <zsh-body> [VAR=VAL ...]
  local label="$1" body="$2"
  shift 2
  local out
  # `env -u GHOSTTY_SHELL_FEATURES`, and it is NOT cosmetic. 00-tools.zsh stands the OSC 133
  # marks down when that variable is set and $TMUX is empty (line ~263), which is exactly the
  # environment every mark-ON case below pins: they pass TMUX= explicitly and say nothing
  # about Ghostty. A bare `env` inherits the caller's, so running `make audit` from a Ghostty
  # window — the reference terminal this repo ships a config for — cleared _CORE_OSC133,
  # left _core_osc133_prompt undefined, and red 7 assertions on a tree CI called green.
  # The section header already claims TERM and TMUX are pinned "wherever they matter"
  # BECAUSE env would otherwise leak the real values; this is the third variable that
  # reasoning applies to and it was the one missed.
  # Order is load-bearing: -u is an OPTION, "$@" the assignments after it, so cases (e)/(f)
  # setting GHOSTTY_SHELL_FEATURES=... explicitly still win over the unset.
  if out="$(HOME="$SANDBOX" env -u GHOSTTY_SHELL_FEATURES "$@" "$_real_zsh" -fic "$body" 2>&1)"; then
    pass "$label"
  else
    fail "$label"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

# ui.zsh: _core_confirm is DEFENSIVE — with no controlling TTY (captured run, stdin
# redirected) it must DECLINE (non-zero), so wrapping a destructive action (please/up)
# in it is fail-safe in a pipe/cron/CI context instead of blocking or assuming yes.
ucheck "ui: _core_confirm declines with no TTY (fail-safe)" \
  "source '$UI'; _core_confirm 'x' </dev/null; (( \$? != 0 ))"

# ui.zsh: _core_spin must return the WRAPPED command's exit code (the non-TTY path
# runs it directly) — the contract plugins.zsh's first-run installer relies on to know
# a clone step failed. true → 0, false → non-zero.
ucheck "ui: _core_spin propagates the wrapped command's exit code" \
  "source '$UI'; _core_spin t true 2>/dev/null && ! _core_spin t false 2>/dev/null"

# ui.zsh: the spinner's animation loop must not become a BUSY loop when its pacing
# primitive stops pacing. _core_nap cannot report failure — it swallows both arms
# (`zselect … 2>/dev/null`, `sleep 0.1 2>/dev/null`) and always returns 0 — so a box with
# neither zsh/zselect nor a usable `sleep` silently turns a 100ms tick into an unthrottled
# spin that pegs a core for the whole wrapped command. Measured before the guard: 100% CPU
# for the command's full duration; after: 0%, same wall time, same exit status.
#
# Needs a REAL pty: _core_spin returns early unless stderr is a tty (`[[ ! -t 2 ]]` runs the
# command directly), so a captured run never reaches the loop at all — which is exactly how
# this went unnoticed. The command must also be a FUNCTION: with gum installed _core_spin
# delegates real binaries to `gum spin` and the hand-rolled loop is skipped.
#
# Also asserted: the guard leaves a STATIC "(still running…)" frame on its way out. Giving
# up on the animation must not mean going silent for the rest of the run — a stopped spinner
# and a wedged one look identical, and the wrapped command here still has seconds to go.
#
# Asserted on the ITERATION COUNT, not on CPU%: deterministic and CI-safe. With the guard,
# the loop stops animating just past 200; without it a broken nap runs six figures of
# iterations in the same window.
if have python3; then
  _spinout="$(python3 - "$UI" <<'PYSPIN' 2>/dev/null
import pty, os, sys, select, time, re
ui = sys.argv[1]
body = (
    "source %s; typeset -g NAPS=0; _core_nap(){ (( NAPS++ )); return 0 }; "
    "slowfn(){ sleep 3; return 7 }; _core_spin t slowfn; print RC=$?; print NAPS=$NAPS"
) % ui
pid, fd = pty.fork()
if pid == 0:
    os.execvp("zsh", ["zsh", "-f", "-i", "-c", body]); os._exit(1)
out, start = b"", time.time()
while time.time() - start < 60:
    r, _, _ = select.select([fd], [], [], 0.01)
    if r:
        try: d = os.read(fd, 262144)
        except OSError: break
        if not d: break
        out += d
    p, _st = os.waitpid(pid, os.WNOHANG)
    if p: break
else:
    os.kill(pid, 9)
txt = out.decode(errors="replace")
rc = re.findall(r"RC=(\d+)", txt)
naps = re.findall(r"NAPS=(\d+)", txt)
print("%s %s %s" % (rc[-1] if rc else "x", naps[-1] if naps else "x",
                    "STILL" if "still running" in txt else "SILENT"))
PYSPIN
  )"
  read -r _srrc _srnaps _srstill <<<"$_spinout"
  if [[ "$_srrc" == 7 && "$_srnaps" =~ ^[0-9]+$ ]] && ((_srnaps <= 250)); then
    pass "ui: _core_spin stops animating instead of busy-spinning when _core_nap cannot pace (naps=$_srnaps, rc=$_srrc)"
  else
    fail "ui: _core_spin busy-spins when _core_nap cannot pace (rc=$_srrc naps=$_srnaps; want rc=7 and naps<=250)"
  fi
  if [[ "$_srstill" == STILL ]]; then
    pass "ui: _core_spin leaves a '(still running…)' frame when the busy-spin guard fires"
  else
    fail "ui: _core_spin goes silent after the busy-spin guard fires (want a static '(still running…)' frame)"
  fi
else
  skip "_core_spin busy-loop guard (python3 absent — needs a pty to reach the animation loop)"
fi

# lib/ux.sh: ux_spin's loop body must be NORMALISED, because this library is SOURCED by
# callers running `set -euo pipefail` (bootstrap.sh is one). A bare command that fails inside
# the loop therefore kills the CALLER, not just the animation — and the case that matters is
# precisely the one the busy-spin guard above exists for: with a `sleep` that exits non-zero,
# an unnormalised `sleep 0.1` aborted the whole shell at 127 before the spin counter was ever
# incremented, so the guard could not run, the wrapped child was left running, and the cursor
# stayed hidden. Same pty requirement as above (ux_spin runs the command directly when stdout
# is not a tty, never reaching the loop), so this is python3-gated too.
if have python3; then
  _uxout="$(python3 - "$HERE/lib/ux.sh" <<'PYUX' 2>/dev/null
import pty, os, sys, select, time, re
ux = sys.argv[1]
# The wrapped command must SUCCEED and ux_spin must be called BARE. Both matter:
# `ux_spin … || rc=$?` puts the call in a tested context, which suspends `set -e` for the
# whole function body — so the very condition under test would be switched off, and the
# check would pass no matter what (it did, until this was corrected). A bare call keeps
# `set -e` live, and a succeeding command means the ONLY thing that can abort the script
# is the unnormalised pacing failure inside the loop.
script = (
    "set -euo pipefail\n"
    "source %s\n"
    "sleep() { return 127; }\n"          # pacing primitive absent / rejecting
    "fn() { command sleep 2; return 0; }\n"
    "ux_spin lbl fn\n"                   # BARE: set -e stays in force
    "echo UXRC=$?\n"
    "echo UXEND\n"
) % ux
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", script]); os._exit(1)
out, start = b"", time.time()
while time.time() - start < 60:
    r, _, _ = select.select([fd], [], [], 0.01)
    if r:
        try: d = os.read(fd, 262144)
        except OSError: break
        if not d: break
        out += d
    p, _st = os.waitpid(pid, os.WNOHANG)
    if p: break
else:
    os.kill(pid, 9)
txt = out.decode(errors="replace")
rc = re.findall(r"UXRC=(\d+)", txt)
print("%s %s %s" % (rc[-1] if rc else "x", "END" if "UXEND" in txt else "NOEND",
                    "STILL" if "still running" in txt else "SILENT"))
PYUX
  )"
  read -r _uxrc _uxend _uxstill <<<"$_uxout"
  if [[ "$_uxrc $_uxend" == "0 END" ]]; then
    pass "ux: ux_spin survives a failing pacing primitive under a 'set -e' sourcer"
  else
    fail "ux: a failing pacing primitive kills a 'set -e' caller of ux_spin (got '${_uxrc} ${_uxend}', want '0 END')"
  fi
  # Same guard-trip, same requirement as _core_spin's mirror above: ux_spin CLEARS the line
  # before `wait`, so without a static frame it shows nothing at all for the rest of the run
  # — the hang it cannot distinguish itself from. This is the stricter of the two cases.
  if [[ "$_uxstill" == STILL ]]; then
    pass "ux: ux_spin leaves a '(still running…)' frame when the busy-spin guard fires"
  else
    fail "ux: ux_spin goes silent after the busy-spin guard fires (want a static '(still running…)' frame)"
  fi

  # …and the COMMON path — a working `sleep`, guard never trips — must survive `set -e` too.
  # The case above only ever exercises the degraded branch, so every post-loop statement on
  # the happy path (cursor restore, the guard's own test, the ✓ frame, `rm -f`) was untested
  # under the very discipline this file is written for. That gap is not theoretical: an
  # arithmetic guard written as `((_degraded)) && { … }` returns 1 whenever _degraded is 0,
  # which is the normal case, and a future edit that moves it out of &&-list position (into a
  # bare statement, or a `local x=$((…))`) kills the caller on every successful spin.
  if have python3; then
    _uxok="$(python3 - "$HERE/lib/ux.sh" <<'PYUXOK' 2>/dev/null
import pty, os, sys, select, time, re
ux = sys.argv[1]
script = (
    "set -euo pipefail\n"
    "source %s\n"
    "fn() { command sleep 1; return 0; }\n"   # real sleep: the guard must NOT trip
    "ux_spin lbl fn\n"                        # BARE: set -e stays in force
    "echo UXRC=$?\n"
    "echo UXEND\n"
) % ux
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", script]); os._exit(1)
out, start = b"", time.time()
while time.time() - start < 60:
    r, _, _ = select.select([fd], [], [], 0.01)
    if r:
        try: d = os.read(fd, 262144)
        except OSError: break
        if not d: break
        out += d
    p, _st = os.waitpid(pid, os.WNOHANG)
    if p: break
else:
    os.kill(pid, 9)
txt = out.decode(errors="replace")
rc = re.findall(r"UXRC=(\d+)", txt)
print("%s %s %s" % (rc[-1] if rc else "x", "END" if "UXEND" in txt else "NOEND",
                    "STILL" if "still running" in txt else "QUIET"))
PYUXOK
    )"
    if [[ "$_uxok" == "0 END QUIET" ]]; then
      pass "ux: a normal ux_spin run survives 'set -e' and prints no degraded frame"
    else
      fail "ux: a normal ux_spin run under 'set -e' (got '${_uxok}', want '0 END QUIET')"
    fi
  fi
else
  skip "ux_spin set -e normalisation (python3 absent — needs a pty to reach the animation loop)"
fi

# ui.zsh: _core_nap is the spinner's per-frame delay primitive — it must return 0
# (the while-loop relies on it not aborting) and complete promptly via zselect WITHOUT
# forking a fractional `sleep` that busybox may reject. We can't time it portably here,
# but asserting it succeeds exercises the zselect path on every CI userland (glibc/musl)
# — the bare-box regression the old literal `sleep 0.1` risked. Driven without a TTY.
ucheck "ui: _core_nap completes and returns 0 (zselect tick, no fractional sleep fork)" \
  "source '$UI'; _core_nap; (( \$? == 0 ))"

# functions.zsh: the command-not-found handler (U1) is defined ONLY in an interactive
# shell (ucheck runs -fic), and on a near typo it must suggest the closest Core verb in
# Core's voice rather than zsh's terse default. extarct → extract is a 1-transposition miss.
ucheck "fn: command_not_found_handler suggests the nearest Core verb on a typo" \
  "source '$UI'; source '$FN'; out=\$(extarct foo 2>&1); [[ \$out == *'did you mean extract'* ]]"

# update.zsh: _pkgup_mgr must pick the manager that's actually on PATH. Isolate PATH to
# a lone apt-get stub (so the brew/pacman/dnf/zypper arms above it all miss) and disable
# the two background startup hooks, so the answer is deterministic on any runner.
_pm_only apt-get
ucheck "update: _pkgup_mgr detects apt from an isolated PATH" \
  "source '$UPD'; [[ \$(_pkgup_mgr) == apt ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# …and reports `none` when NO supported manager is reachable (the silent-stay path).
_pm_only ""
ucheck "update: _pkgup_mgr reports none on a bare PATH" \
  "source '$UPD'; [[ \$(_pkgup_mgr) == none ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# The startup hook's CLAIM-SLOT write must leave a POSITIONALLY WELL-FORMED cache, i.e.
# "-1\n<epoch>" and never "\n<epoch>". The hook persists whatever $count holds, and on the
# first shell of a fresh box there is no cache at all, so an unnormalised (or normalised-to-
# empty) count wrote a file whose first line was blank — the exact shape that, read back
# with an UNQUOTED (f) split, slides the epoch into the count slot and prints "1786128391
# updates available". The reader-side quoting is one half of the fix; this asserts the other.
#
# Deterministic against the refresh the hook backgrounds a line later: the stub `brew` sleeps,
# and _pkgup_count calls it twice, so the claim write is what is on disk when we look. The
# stub dir is PREPENDED to the real PATH (not isolated to it) because the hook needs `mkdir`;
# brew is first in _pkgup_mgr's ladder, so the stub still wins on any host.
#
# NOT ucheck, deliberately — this is the one update.zsh case that leaves the startup hook
# ENABLED, so it is the only one that forks the refresh. ucheck captures with `$(…)`, and a
# command substitution reads until the pipe's LAST writer closes: the disowned `&|` refresh
# inherits that pipe, so bash would sit there for as long as the stub sleeps even though the
# assertion finished in microseconds. Measured: 60.0s via ucheck, 8ms redirected to a file,
# same verdict — and it would have been paid on every leg of the CI matrix. Redirecting to a
# file means the parent waits only for the zsh it actually started. The stub's sleep is now
# just "comfortably longer than the assertion window", not a cost.
#
# The macOS declaration is seeded so the sleeping stub is actually REACHED. Since #763 an
# undeclared box resolves no count verb and _pkgup_count returns -1 without running
# anything — which would still satisfy the assertion below, but for the wrong reason, and
# the timing window this case depends on would not exist at all.
_PKGUPT="$SANDBOX/pkgup-claim"
rm -rf "$_PKGUPT"
mkdir -p "$_PKGUPT/bin" "$_PKGUPT/cache/zsh"
printf '#!/bin/sh\nsleep 10\n' >"$_PKGUPT/bin/brew"
chmod +x "$_PKGUPT/bin/brew"
printf 'PKG_COUNT_PENDING=brew outdated --quiet\nPKG_COUNT_REFRESH=brew update\n' >"$_PKGUPT/os.capabilities"
if HOME="$SANDBOX" env PATH="$_PKGUPT/bin:$PATH" XDG_CACHE_HOME="$_PKGUPT/cache" CORE_WELCOME=0 \
  CORE_CAPABILITIES_FILE="$_PKGUPT/os.capabilities" \
  "$_real_zsh" -fic "source '$CAPZ'; source '$UPD'
   c=\$XDG_CACHE_HOME/zsh/pkg-updates
   [[ -r \$c ]] || { print -u2 'no cache written'; exit 1 }
   local -a l; l=(\"\${(@f)\$(<\$c)}\")
   [[ \${l[1]} == -1 ]] || { print -u2 \"count slot is '\${l[1]}', want -1\"; exit 1 }
   [[ \${l[2]} == <-> ]] || { print -u2 \"epoch slot is '\${l[2]}'\"; exit 1 }
   [[ -z \$(_pkgup_notice) ]]" >"$_PKGUPT/out" 2>&1; then
  pass "update: the claim-slot write leaves a well-formed cache (-1, not an empty count)"
else
  fail "update: the claim-slot write leaves a well-formed cache (-1, not an empty count)"
  [[ -s "$_PKGUPT/out" ]] && sed 's/^/    /' "$_PKGUPT/out" >&2
fi
# up --help must print usage and return 0 WITHOUT attempting an update — the bug the
# help guard fixes (it used to fall through, not being -y, and run the upgrade). Run
# on a bare PATH so a regressed guard reaching _pkgup_mgr → none → returns 1, failing
# this test loudly instead of silently passing.
_pm_only ""
ucheck "update: up --help returns 0 and does not attempt an update" \
  "source '$UI'; source '$UPD'; out=\$(up --help); (( \$? == 0 )) && [[ \$out == *'usage: up'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# up's pre-confirm PREVIEW: _pkgup_list surfaces the upgradable package NAMES (the
# count is already in the nudge) so `up` shows what will change before the destructive
# sync. Stub apt-get's `-s upgrade` simulate output; mgr pins to apt via isolated PATH.
rm -rf "$PMBIN"
mkdir -p "$PMBIN"
printf '#!/bin/sh\ncase "$*" in *"-s upgrade"*) printf "Inst foo [1.0] (1.1)\\nInst bar [2.0] (2.1)\\n";; esac\n' >"$PMBIN/apt-get"
chmod +x "$PMBIN/apt-get"
# The apt arm pipes to awk; the isolated PATH has only the stub, so symlink the real
# awk in (like the clip ladder symlinks bash/tr). It's not a package manager, so
# _pkgup_mgr still resolves to apt — the isolation we want.
ln -s "$(command -v awk)" "$PMBIN/awk"
ucheck "update: _pkgup_list surfaces upgradable package names (apt)" \
  "source '$CAPZ'; source '$UPD'; out=\$(_pkgup_list); [[ \$out == *foo* && \$out == *bar* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"

# REGRESSION (stdin): the probes must be UNPROMPTABLE. They run with stdout captured by
# $(...) and stderr discarded, so a package manager that stops to ask a question writes it
# where nobody can see and then blocks on the terminal forever — `up` printing "Complete!"
# and never returning, because _pkgup_refresh runs _pkgup_count in the FOREGROUND after the
# upgrade. (Live case: dnf5 keys repos per user under <cachedir>/<repo>/pubring, so a repo
# with repo_gpgcheck=1 whose key only reached root's keyring re-prompts every non-root
# --refresh, forever, since a declined import is never persisted.)
#
# The guard is `esac </dev/null` INSIDE each function. It deliberately is not on the function
# definition: `f() { ... } </dev/null` binds at definition time in zsh and does nothing at
# call time, which looks identical in review and fixes nothing — these tests are what tell
# the two apart.
#
# Asserted as "the probe did not EAT the caller's stdin" rather than "the probe did not
# hang": same property (an unpinned probe reaches the caller's stdin; a pinned one cannot),
# but it FAILS on regression instead of hanging. This harness has no timeout, so a test that
# detected the hang by hanging would wedge the suite rather than report it. The stub reads a
# line, so an unpinned probe swallows the sentinel and the outer read comes up empty.
rm -rf "$PMBIN"
mkdir -p "$PMBIN"
printf '#!/bin/sh\nprintf "Import key? [y/N]: "\nread -r a\nprintf "Inst foo [1.0] (1.1)\\n"\n' >"$PMBIN/apt-get"
chmod +x "$PMBIN/apt-get"
ln -s "$(command -v awk)" "$PMBIN/awk"
ln -s "$(command -v grep)" "$PMBIN/grep"
ucheck "update: _pkgup_count cannot consume the caller's stdin (unpromptable)" \
  "source '$CAPZ'; source '$UPD'; printf 'sentinel\\n' | { _pkgup_count >/dev/null; read -r l; [[ \$l == sentinel ]] }" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
ucheck "update: _pkgup_list cannot consume the caller's stdin (unpromptable)" \
  "source '$CAPZ'; source '$UPD'; printf 'sentinel\\n' | { _pkgup_list >/dev/null; read -r l; [[ \$l == sentinel ]] }" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
# Put the fixture back the way the checks below expect it. $PMBIN is shared state, and the
# stub above is the one thing in this file that BLOCKS: leaving it in place hands a prompting
# apt-get to every later check, including the startup-hook ones that run _pkgup_refresh with
# UPDATE_CHECK_ENABLED=1. With the stdin pin they survive it; without it they wedge the whole
# suite instead of failing the two tests above — which is exactly backwards for a regression
# test whose job is to report this bug.
rm -rf "$PMBIN"
mkdir -p "$PMBIN"
printf '#!/bin/sh\ncase "$*" in *"-s upgrade"*) printf "Inst foo [1.0] (1.1)\\nInst bar [2.0] (2.1)\\n";; esac\n' >"$PMBIN/apt-get"
chmod +x "$PMBIN/apt-get"
ln -s "$(command -v awk)" "$PMBIN/awk"
# REGRESSION (prompt_subst): _pkgup_notice prints its 'run up to apply' nudge via
# `print -P`. Under `setopt prompt_subst` (starship and any substitution prompt enable
# it) print -P performs command substitution on a backtick'd word — so a literal \`up\`
# in the string would RUN the up function at prompt-paint time. The nudge fires from a
# precmd hook BEFORE up() is even defined, surfacing as "command not found: up" (and, once
# defined, silently triggering a privileged upgrade prompt every shell). Define an up()
# sentinel, enable prompt_subst, seed a positive cached count, and assert the rendered
# nudge MENTIONS up but never EXECUTED it.
ucheck "update: _pkgup_notice nudge is prompt_subst-safe (mentions up, never runs it)" \
  "source '$UPD'; setopt prompt_subst; up(){ print RAN_UP }; mkdir -p \${_PKGUP_CACHE:h}; print -rl -- 3 \$EPOCHSECONDS >| \$_PKGUP_CACHE; out=\$(_pkgup_notice); [[ \$out == *\"run 'up'\"* && \$out != *RAN_UP* ]]" \
  XDG_CACHE_HOME="$SANDBOX/psubst-notice" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# REGRESSION (positional cache parse): _PKGUP_CACHE is "<count>\n<epoch>", read with a
# (f) split. Unquoted, zsh DROPS empty fields — so a cache whose count line is empty
# collapses to one element and the EPOCH shifts into the count slot. It then passes the
# <1-> test (an epoch IS a positive integer) and renders as "1786128391 updates available".
#
# Where the empty count comes from: NOT _pkgup_refresh, which normalises an empty result
# to -1 (`: "${n:=-1}"`). It is the startup hook's claim-slot write — on the first shell of
# a fresh box there is no cache, so $count is empty and the claim persists "\n<epoch>"
# while the background refresh is still in flight. Seed exactly that shape and assert the
# nudge stays SILENT.
ucheck "update: _pkgup_notice ignores an empty-count cache (epoch must not become the count)" \
  "source '$UPD'; mkdir -p \${_PKGUP_CACHE:h}; print -rl -- '' \$EPOCHSECONDS >| \$_PKGUP_CACHE; out=\$(_pkgup_notice); [[ -z \$out ]]" \
  XDG_CACHE_HOME="$SANDBOX/emptycount-notice" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# …and the healthy two-line cache still renders, so the quoting fix didn't just mute it.
ucheck "update: _pkgup_notice still renders a real cached count" \
  "source '$UPD'; mkdir -p \${_PKGUP_CACHE:h}; print -rl -- 7 \$EPOCHSECONDS >| \$_PKGUP_CACHE; out=\$(_pkgup_notice); [[ \$out == *'7 updates available'* ]]" \
  XDG_CACHE_HOME="$SANDBOX/goodcount-notice" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# The STARTUP HOOK has its own copy of the same positional read, and it is the one that
# matters: it decides the throttle AND writes the count back when it claims the slot, so an
# unquoted split there both re-fires the check every shell and PERSISTS the epoch as the
# count. _pkgup_notice tests cannot see that — they'd pass with this reader still broken.
# Seed the poisoned shape with a RECENT epoch: parsed correctly, `last` is now and the
# throttle must suppress any refresh, leaving the cache byte-identical. Parsed unquoted,
# `last` collapses to empty ⇒ 0, the window looks elapsed, and the claim-slot write fires
# and rewrites the file. Assert it is untouched.
ucheck "update: startup hook reads the cache positionally (empty count can't defeat the throttle)" \
  "zmodload zsh/datetime; mkdir -p \$XDG_CACHE_HOME/zsh; _c=\$XDG_CACHE_HOME/zsh/pkg-updates; print -rl -- '' \$EPOCHSECONDS >| \$_c; _before=\$(<\$_c); source '$CAPZ'; source '$UPD'; sleep 0.3; [[ \$(<\$_c) == \$_before ]]" \
  XDG_CACHE_HOME="$SANDBOX/hook-emptycount" UPDATE_CHECK_ENABLED=1 PATH="$PMBIN:$PATH" CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
# Control: with a STALE epoch the same hook SHOULD claim the slot, so the assertion above
# is proving the throttle works, not that the hook is inert.
ucheck "update: startup hook still refreshes once the throttle window has elapsed" \
  "zmodload zsh/datetime; mkdir -p \$XDG_CACHE_HOME/zsh; _c=\$XDG_CACHE_HOME/zsh/pkg-updates; print -rl -- 5 1 >| \$_c; _before=\$(<\$_c); source '$CAPZ'; source '$UPD'; sleep 0.3; [[ \$(<\$_c) != \$_before ]]" \
  XDG_CACHE_HOME="$SANDBOX/hook-stale" UPDATE_CHECK_ENABLED=1 PATH="$PMBIN:$PATH" CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
# up --dry-run (#8): the non-destructive inspect — list what WOULD upgrade and exit 0,
# applying nothing. Same apt stub as above; assert the names print and the rc is 0.
ucheck "update: up --dry-run lists pending packages and exits 0 (applies nothing)" \
  "source '$UI'; source '$CAPZ'; source '$UPD'; out=\$(up --dry-run); (( \$? == 0 )) && [[ \$out == *foo* && \$out == *bar* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
# ...and the SAME flag on an UNDECLARED box must refuse, not report a clean bill of health.
# This is the regression #763 nearly shipped: the PKG_UPGRADE guard used to sit down at the
# dispatch, after `-n` had already returned, so `up -n` resolved no PKG_COUNT_PENDING, read
# the empty list as an empty ANSWER, and printed "nothing to upgrade" — asserting the box is
# up to date when nothing was measured, which is the 0-vs-unknown confusion the -1 sentinel
# exists to prevent in _pkgup_count arriving through a different door. Assert the refusal AND
# the absence of the reassuring string, because a guard that fires with the wrong message
# would still pass a bare rc check.
ucheck "update: up --dry-run on an undeclared box refuses, never says 'nothing to upgrade'" \
  "source '$UI'; source '$CAPZ'; source '$UPD'; out=\$(up --dry-run 2>&1); (( \$? == 1 )) && [[ \$out == *'no upgrade verb declared'* && \$out == *'--links-only'* && \$out != *'nothing to upgrade'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$SANDBOX/does-not-exist.capabilities"
# The read-only modes are the ones that regressed, but the guard is per-BOX and not per-mode,
# so pin every entry point at once: a fix that only taught `-n` to refuse would leave `up -i`
# reporting the partial-upgrade refusal instead of the real cause.
ucheck "update: every up mode refuses on an undeclared box, not just the applying ones" \
  "source '$UI'; source '$CAPZ'; source '$UPD'; _core_confirm() { return 1 }
   for _m in --dry-run -i -y ''; do
     out=\$(up \${_m:+\$_m} 2>&1); (( \$? == 1 )) || exit 1
     [[ \$out == *'no upgrade verb declared'* ]] || exit 1
   done" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$SANDBOX/does-not-exist.capabilities"
# up strict flag parsing: every arg is parsed (not just $1), so an unknown flag is
# REJECTED in Core's voice (rc 1 — the verb-layer usage-error convention, same as
# serve/mkcd/…) instead of silently falling through to a real, privileged update —
# and -y/-n together (apply vs inspect-only) is refused as contradictory. Both
# rejections happen BEFORE _pkgup_mgr, so the manager doesn't matter.
ucheck "update: up rejects an unknown flag (rc 1, does not attempt an update)" \
  "source '$UI'; source '$UPD'; out=\$(up --bogus 2>&1); (( \$? == 1 )) && [[ \$out == *'unexpected argument'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: up refuses -y and -n together (mutually exclusive, rc 1)" \
  "source '$UI'; source '$UPD'; out=\$(up -y -n 2>&1); (( \$? == 1 )) && [[ \$out == *'mutually exclusive'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# up -i interactive selection (U2): contracts checked BEFORE any privileged apply.
# (a) -i is mutually exclusive with -y/-n; (b) with NO picker it errbox-names fzf/gum;
# (c) with a picker but no TTY it declines for the terminal; (d) --help advertises -i.
# (b)/(c) are kept DISTINCT so the message never conflates the two (Copilot, PR #15).
ucheck "update: up refuses -i with -y (three-way mutual exclusion, rc 1)" \
  "source '$UI'; source '$UPD'; out=\$(up -i -y 2>&1); (( \$? == 1 )) && [[ \$out == *'mutually exclusive'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# (b) no fzf AND no gum on the isolated PATH → the picker errbox, not a TTY/cancel message.
# The apt declaration is seeded because the PARTIAL-UPGRADE safety check runs FIRST: on an
# archive that declares no PKG_UPGRADE_PARTIAL (or on an undeclared box, which since #763 is
# the same thing) `up -i` refuses before it ever looks for a picker, and this case would
# pass on the wrong message.
ucheck "update: up -i names fzf/gum when no picker is installed" \
  "source '$UI'; source '$CAPZ'; source '$UPD'; out=\$(up -i </dev/null 2>&1); (( \$? == 1 )) && [[ \$out == *'needs fzf or gum'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
# (c) stub a picker (fzf) onto the isolated PATH so the picker check passes; a non-TTY run
# must then decline with the TERMINAL message — proving the two failure modes are separate.
printf '#!/bin/sh\n:\n' >"$PMBIN/fzf"
chmod +x "$PMBIN/fzf"
ucheck "update: up -i with a picker present still declines without a TTY" \
  "source '$UI'; source '$CAPZ'; source '$UPD'; out=\$(up -i </dev/null 2>&1); (( \$? == 1 )) && [[ \$out == *'needs an interactive terminal'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
rm -f "$PMBIN/fzf"
ucheck "update: up --help advertises -i/--interactive" \
  "source '$UI'; source '$UPD'; out=\$(up --help); (( \$? == 0 )) && [[ \$out == *'-i'* && \$out == *interactive* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# up -i must REFUSE on full-sync-only archives (pacman/emerge/apk): a partial upgrade there
# risks a broken system, so the safety model (documented in update.zsh) forbids it. It is the
# ABSENCE of PKG_UPGRADE_PARTIAL that refuses, so seed dotfiles-Arch's declaration — which
# omits it deliberately — rather than leaving the box undeclared, where every key is absent
# and the case would pass without proving anything about Arch.
_pm_only pacman
_decl_as 'PKG_UPGRADE=sudo pacman -Syu
PKG_COUNT_PENDING=checkupdates'
ucheck "update: up -i refuses on pacman (full-sync-only safety, rc 1)" \
  "source '$UI'; source '$CAPZ'; source '$UPD'; out=\$(up -i 2>&1); (( \$? == 1 )) && [[ \$out == *'does not support safe partial upgrades'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_CAPABILITIES_FILE="$CAPDECL"
_decl_as "$_DECL_APT"
# core-help context-awareness (U7): a row whose tool is ABSENT on this box must be
# tagged "needs <tool>", while an always-on verb (mkcd) still renders normally. Drive
# it on a bare PATH so fzf is guaranteed missing, making the assertion deterministic.
_pm_only ""
ucheck "core-help annotates an unavailable tool (needs fzf when fzf absent)" \
  "source '$UI'; source '$FN'; out=\$(COLUMNS=120 NO_COLOR=1 core-help); [[ \$out == *'needs fzf'* && \$out == *mkcd* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# fzf.zsh verbs (fif/fbr) must degrade in Core's voice on a bare box — a raw "command
# not found" is the bug this guards (fcd already did; fif/fbr/zoxide-jump did not).
# Drive on an isolated PATH (fzf guaranteed absent) so the error path is deterministic.
FZF_FILE="$HERE/zsh/35-fzf.zsh"
_pm_only ""
ucheck "fif rejects cleanly without fzf (Core error voice, not 'command not found')" \
  "source '$UI'; source '$FZF_FILE' 2>/dev/null; out=\$(fif foo 2>&1); (( \$? != 0 )) && [[ \$out == *'fif: requires fzf'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "fbr rejects cleanly without fzf (Core error voice, not 'command not found')" \
  "source '$UI'; source '$FZF_FILE' 2>/dev/null; out=\$(fbr 2>&1); (( \$? != 0 )) && [[ \$out == *'fbr: requires fzf'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# zle-widget graceful degradation (regression gate for the Ctrl-T/Ctrl-R bare-box bug):
# both are bound UNCONDITIONALLY in bindings.zsh, so on a box without fzf/fd their widget
# bodies must warn in Core's voice and repaint — NOT leak a raw "command not found" (the
# class of bug fif/fbr/Alt-Z already guard; Ctrl-T/Ctrl-R lacked it). `zle` is stubbed to a
# no-op so `zle reset-prompt` is callable outside an active ZLE; PATH is isolated so fzf/fd
# are guaranteed absent. Alt-Z is asserted too, locking in the parity across all three.
_pm_only ""
ucheck "Ctrl-T widget degrades in Core's voice without fzf/fd (no 'command not found')" \
  "source '$UI'; source '$FZF_FILE' 2>/dev/null; zle() { : }; FD_BIN=''; out=\$(_fzf_file_no_hidden 2>&1); (( \$? != 0 )) && [[ \$out == *'Ctrl-T: needs'* && \$out != *'command not found'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "Ctrl-R widget degrades in Core's voice without fzf (no 'command not found')" \
  "source '$UI'; source '$FZF_FILE' 2>/dev/null; zle() { : }; out=\$(_fzf_history_clean 2>&1); (( \$? != 0 )) && [[ \$out == *'Ctrl-R: needs'* && \$out != *'command not found'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "Alt-Z widget degrades in Core's voice without zoxide/fzf (no 'command not found')" \
  "source '$UI'; source '$FZF_FILE' 2>/dev/null; zle() { : }; out=\$(_fzf_zoxide_jump 2>&1); (( \$? != 0 )) && [[ \$out == *'Alt-Z: needs'* && \$out != *'command not found'* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# Colour degradation (U8): the nudge/welcome accents must drop from 24-bit hex to a
# 256-colour code when the terminal doesn't advertise truecolor — so a 16/256-colour
# TTY never receives a raw 24-bit escape. Assert both arms of the $COLORTERM gate.
ucheck "update: accents degrade to 256-colour without truecolor" \
  "source '$UPD'; [[ \$_PKGUP_ACCENT == 75 && \$_PKGUP_MUTED == 244 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 COLORTERM=
ucheck "update: accents use truecolor hex when COLORTERM advertises it" \
  "source '$UPD'; [[ \$_PKGUP_ACCENT == '#7aa2f7' ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 COLORTERM=truecolor

# ── terminal-browser detection ladder (00-tools.zsh) + web/$BROWSER wiring (20-aliases.zsh) ──
# 00-tools.zsh resolves BROWSER_BIN (w3m preferred, then lynx/links2/links/elinks) and
# 20-aliases.zsh turns it into the `web` verb plus a HEADLESS-ONLY $BROWSER export. A
# regression here fans out to every OS repo, so pin the whole ladder + consumer
# hermetically against a stubbed PATH — the same isolation the pkg-mgr ladder uses.
# DISPLAY/WAYLAND_DISPLAY/OSTYPE are set INSIDE the body (zsh re-derives OSTYPE at
# startup, so an env prefix wouldn't stick) to drive the headless/GUI/macOS branches.
TOOLS_FILE="$HERE/zsh/00-tools.zsh"
ALIASES_FILE="$HERE/zsh/20-aliases.zsh"
BRBIN="$SANDBOX/brbin"
_br_only() { # _br_only [browser-name ...] — stub these onto an otherwise-empty bin dir
  rm -rf "$BRBIN"
  mkdir -p "$BRBIN"
  local n
  for n in "$@"; do
    printf '#!/bin/sh\n:\n' >"$BRBIN/$n"
    chmod +x "$BRBIN/$n"
  done
}
# (a) PRECEDENCE — w3m wins even when other text browsers are also present.
_br_only lynx w3m links
ucheck "browser: w3m takes precedence over other text browsers" \
  "source '$TOOLS_FILE'; [[ \$BROWSER_BIN == w3m && -n \${HAVE_BROWSER:-} ]]" \
  PATH="$BRBIN"
# (b) FALLBACK — with w3m absent, resolve the next present browser in the ladder.
_br_only lynx
ucheck "browser: falls back to lynx when w3m is absent" \
  "source '$TOOLS_FILE'; [[ \$BROWSER_BIN == lynx && -n \${HAVE_BROWSER:-} ]]" \
  PATH="$BRBIN"
# (c) NONE — no browser at all → HAVE_BROWSER stays unset and no `web` alias is defined.
_br_only
ucheck "browser: no browser present → HAVE_BROWSER unset, no web alias (graceful no-op)" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; [[ -z \${HAVE_BROWSER:-} ]] && ! (( \$+aliases[web] ))" \
  PATH="$BRBIN"
# (d) HEADLESS — no DISPLAY/WAYLAND_DISPLAY, non-macOS → `web` defined AND $BROWSER exported.
_br_only w3m
ucheck "browser: headless box defines web and exports \$BROWSER=w3m" \
  "DISPLAY=''; WAYLAND_DISPLAY=''; OSTYPE=linux-gnu; source '$TOOLS_FILE'; source '$ALIASES_FILE'; (( \$+aliases[web] )) && [[ \$BROWSER == w3m ]]" \
  PATH="$BRBIN"
# (e) GUI — a live \$DISPLAY must keep `web` but leave \$BROWSER untouched (no hijack).
ucheck "browser: a GUI \$DISPLAY keeps web but leaves \$BROWSER unset" \
  "DISPLAY=':0'; WAYLAND_DISPLAY=''; OSTYPE=linux-gnu; source '$TOOLS_FILE'; source '$ALIASES_FILE'; (( \$+aliases[web] )) && [[ -z \${BROWSER:-} ]]" \
  PATH="$BRBIN"
# (f) macOS — always a GUI, so \$BROWSER stays unset even when it looks headless.
ucheck "browser: macOS (OSTYPE=darwin) leaves \$BROWSER unset even with no DISPLAY" \
  "DISPLAY=''; WAYLAND_DISPLAY=''; OSTYPE=darwin24; source '$TOOLS_FILE'; source '$ALIASES_FILE'; (( \$+aliases[web] )) && [[ -z \${BROWSER:-} ]]" \
  PATH="$BRBIN"

# ── renamed binaries: fd/bat symmetry + an honest doctor (#418) ──────────────
# Debian/Ubuntu/Kali ship fd as `fdfind` and bat as `batcat`. 00-tools.zsh resolves both
# into FD_BIN/BAT_BIN, but the two were then handled ASYMMETRICALLY: 20-aliases.zsh gave
# fd an alias under its canonical name and bat none, so `bat` was untypeable on those
# boxes — and core-doctor reported `✗ bat` two lines above a `resolved` section printing
# `bat → batcat`. The ✓ that fd got was itself accidental: it came from zsh's `command -v`
# resolving the ALIAS, not from PATH, which is why `core-doctor -v` still printed a bare
# versionless `✓ fd` there (the probe forks `"$bin" --version`, a parameter expansion, and
# parameters are never alias-expanded — the error was swallowed by the pipeline).
# Both halves are pinned here against a stubbed PATH, hermetically, because a regression
# fans out to all nine Core-vendoring repos and is invisible on macOS where the names are canonical.
RNBIN="$SANDBOX/rnbin"
_real_grep="$(command -v grep)"
_real_head="$(command -v head)"
_rn_only() { # _rn_only [binary-name ...] — stub these onto an otherwise-empty bin dir
  rm -rf "$RNBIN"
  mkdir -p "$RNBIN"
  local n
  for n in "$@"; do
    printf '#!/bin/sh\necho "%s 0.24.0"\n' "$n" >"$RNBIN/$n"
    chmod +x "$RNBIN/$n"
  done
  # grep/head are linked in, not stubbed: `core-doctor -v` pipes each tool's --version
  # through them, so case (c) cannot run on a PATH that lacks them. Linking the real ones
  # keeps the dir hermetic for the names that MATTER — a stubbed batcat/fdfind/bat/fd
  # still wins by precedence, and no real bat/fd from /usr/bin can leak in and hand the
  # version assertion someone else's release number on a Fedora or Debian runner.
  ln -sf "$_real_grep" "$RNBIN/grep"
  ln -sf "$_real_head" "$RNBIN/head"
}
# (a) SYMMETRY — the issue itself: on Debian names, BOTH tools are typeable canonically.
_rn_only batcat fdfind
ucheck "renamed: Debian names → alias bat=batcat AND alias fd=fdfind (symmetric)" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; [[ \${aliases[bat]} == batcat && \${aliases[fd]} == fdfind ]]" \
  PATH="$RNBIN"
# (b) HONEST DOCTOR — and it must NOT depend on (a). 20-aliases.zsh is deliberately NOT
# sourced here, so a ✓ can only come from _core_doctor_bin resolving $BAT_BIN/$FD_BIN.
ucheck "renamed: core-doctor --json reports bat/fd present without the aliases loaded" \
  "source '$TOOLS_FILE'; source '$UI'; source '$FN'; j=\$(core-doctor --json); [[ \$j == *'\"bat\":true'* && \$j == *'\"fd\":true'* ]]" \
  PATH="$RNBIN" CORE_NO_PAGER=1
# (c) VERSIONS — the latent half: -v forks the RESOLVED binary, so both rows carry a
# version. Before the fix this printed `✓ fd` bare, with the failure swallowed.
ucheck "renamed: core-doctor -v reads versions off the resolved binary" \
  "source '$TOOLS_FILE'; source '$UI'; source '$FN'; o=\$(core-doctor -v); [[ \$o == *'bat 0.24.0'* && \$o == *'fd 0.24.0'* ]]" \
  PATH="$RNBIN" CORE_NO_PAGER=1
# (d) CANONICAL NAMES — the non-Debian answer is unchanged: self-named aliases, still ✓.
_rn_only bat fd
ucheck "renamed: canonical names → aliases stay self-named and the doctor still reports ✓" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; source '$UI'; source '$FN'; j=\$(core-doctor --json); [[ \${aliases[bat]} == bat && \${aliases[fd]} == fd && \$j == *'\"bat\":true'* && \$j == *'\"fd\":true'* ]]" \
  PATH="$RNBIN" CORE_NO_PAGER=1
# (e) NEITHER — a bare box degrades: no HAVE_*, no bat/fd/cat alias, and an honest ✗.
_rn_only
ucheck "renamed: neither present → no bat/fd/cat alias and the doctor reports absent" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; source '$UI'; source '$FN'; j=\$(core-doctor --json); [[ -z \${HAVE_BAT:-} && -z \${HAVE_FD:-} ]] && ! (( \$+aliases[bat] )) && ! (( \$+aliases[fd] )) && ! (( \$+aliases[cat] )) && [[ \$j == *'\"bat\":false'* && \$j == *'\"fd\":false'* ]]" \
  PATH="$RNBIN" CORE_NO_PAGER=1


# ── user bindirs reach PATH BEFORE detection (#425) ──────────────────────────
# 00-tools.zsh prepends the per-user bindirs language installers write into, then probes
# for HAVE_* flags. It used to prepend only ~/.local/bin, so a `cargo install`ed tool —
# which lands in $CARGO_HOME/bin, and reached PATH only via the OS layer at band 80, a
# whole load-order band AFTER detection — got no flag, no alias, and no shell init, while
# core-doctor (which probes LIVE, later, against the finished PATH) reported it ✓. Same
# shell, two answers. atuin's own installer writes ~/.atuin/bin and had the identical
# hole, which is the severe one: no HAVE_ATUIN means `atuin init zsh` never runs, so
# Ctrl+E is dead and no history is recorded behind a green doctor row.
#
# Hermetic, and it has to be: the box running this suite has its own cargo/go/atuin dirs
# one way or the other, and neither arrangement can prove the other's. Each case pins HOME
# to a purpose-built fixture and PATH to a stub dir holding nothing but real grep/head.
#
# CARGO_HOME/GOBIN/GOPATH are neutralised (passed EMPTY — `:-` treats empty as unset) in
# every case that is not deliberately setting them. That is the same trap v4.13.2 fixed in
# the blib_user_bindirs_on_path fixture below: the resolution is `${CARGO_HOME:-$HOME/...}`
# precisely so a relocated dir still works, so a developer with CARGO_HOME exported in
# their own shell retargets the lookup, the fixture's dir never lands, and the case reds a
# perfectly healthy tree while no CI runner — none of which export it — ever sees it.
UBHOME="$SANDBOX/ubhome"
UBSYS="$SANDBOX/ubsys"
mkdir -p "$UBSYS"
ln -sf "$(command -v grep)" "$UBSYS/grep"
ln -sf "$(command -v head)" "$UBSYS/head"
_ub_fixture() { # _ub_fixture <reldir>:<tool> ... — fresh $UBHOME holding exactly these stubs
  rm -rf "$UBHOME"
  mkdir -p "$UBHOME"
  local spec d n
  for spec in "$@"; do
    d="${spec%%:*}"
    n="${spec##*:}"
    mkdir -p "$UBHOME/$d"
    # Answers --version and NOTHING else: `atuin init zsh` must emit no script, or
    # _cache_eval would source the stub's chatter back into the shell.
    printf '#!/bin/sh\n[ "$1" = --version ] && echo "%s 1.0.0"\nexit 0\n' "$n" >"$UBHOME/$d/$n"
    chmod +x "$UBHOME/$d/$n"
  done
}

# (a) THE REPORTED BUG: a cargo-installed tool is detected, aliased and wired.
_ub_fixture .cargo/bin:procs
ucheck "bindirs: a tool in ~/.cargo/bin sets HAVE_PROCS and gets its alias (#425)" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; [[ -n \${HAVE_PROCS:-} && \${aliases[ps]} == procs ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# (a2) THE #545 AXIS, END TO END: a bindir that joins PATH AFTER band 00 leaves the tool
# present but unwired, and the doctor must say so. This is the real shape — 80-os.zsh, an
# 85-* role fragment or 99-local.zsh prepending a directory — reproduced by exporting PATH
# between sourcing 00-tools.zsh and asking the doctor. Needs python3 for the JSON read;
# `have` is checked inline because ucheck has no dep variant.
if have python3; then
  # python3 by ABSOLUTE path: $UBSYS is deliberately a near-empty PATH (grep + head only),
  # and widening it for these two cases would change the environment every other bindir
  # assertion is pinned against.
  _UB_PY="$(command -v python3)"
  _ub_fixture latebin:procs
  ucheck "detection: a bindir that joins PATH after band 00 is reported in detection.missed (#545)" \
    "source '$TOOLS_FILE'
     export PATH=\"\$HOME/latebin:\$PATH\"
     source '$UI'; source '$FN'
     core-doctor --json | '$_UB_PY' -c \"
import json, sys
d = json.load(sys.stdin)
assert d['detection']['ran'] is True, d['detection']
assert d['tools']['procs'] is True, 'the live probe should still see it'
assert 'procs' in d['detection']['missed'], d['detection']
\"" \
    HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=
  # …and the mirror case, which is what stops the above passing against a doctor that flags
  # EVERYTHING. Same tool, but in a directory 00-tools.zsh prepends itself (#425's
  # arrangement), so detection saw it and nothing is missed.
  _ub_fixture .cargo/bin:procs
  ucheck "detection: a tool detected at band 00 is NOT reported missed (no false positives)" \
    "source '$TOOLS_FILE'; source '$UI'; source '$FN'
     core-doctor --json | '$_UB_PY' -c \"
import json, sys
d = json.load(sys.stdin)
assert d['detection']['ran'] is True, d['detection']
assert d['tools']['procs'] is True, d['tools']
assert d['detection']['missed'] == [], d['detection']
\"" \
    HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=
  unset _UB_PY
else
  skip "detection: the #545 end-to-end cases (python3 not installed)"
fi

# (b) THE SEVERE ONE: atuin's own installer dir, whose miss silently loses history.
_ub_fixture .atuin/bin:atuin
ucheck "bindirs: a tool in ~/.atuin/bin sets HAVE_ATUIN (so atuin init zsh runs)" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_ATUIN:-} ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# (c) RELOCATABLE: rustup honours $CARGO_HOME, so hard-coding ~/.cargo/bin would leave a
# relocated box still undetected. NOTE there is no ~/.cargo/bin in this fixture at all —
# the flag can only be set by resolving through the variable.
_ub_fixture xdgcargo/bin:procs
ucheck "bindirs: CARGO_HOME is honoured (a relocated cargo dir is still detected)" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_PROCS:-} ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME="$UBHOME/xdgcargo" GOBIN= GOPATH=

# (d) go honours $GOBIN first.
_ub_fixture gobin:xh
ucheck "bindirs: GOBIN is honoured" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_XH:-} ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN="$UBHOME/gobin" GOPATH=

# (e) …then $GOPATH — which is a path LIST, and go writes to the FIRST entry's bin/.
# Expanding "$GOPATH/bin" against /a:/b would probe a nonexistent "/a:/b/bin", so this
# asserts BOTH that the first entry is used and that no such bogus entry is built.
_ub_fixture gopath/bin:xh second/bin:gron
ucheck "bindirs: GOPATH's FIRST entry is used, and no bogus /a:/b/bin entry is built" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_XH:-} && \$_CORE_PROBED[gron] == 0 && \$PATH != *'gopath:'* ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH="$UBHOME/gopath:$UBHOME/second"

# (f) IDEMPOTENT: the guard is a containment test, so a second source must not duplicate.
# Duplicates are not cosmetic — 00-tools.zsh is re-sourced by `core reload`, and an
# unbounded PATH is a real leak over a long session.
_ub_fixture .cargo/bin:procs .local/bin:eza
ucheck "bindirs: sourcing twice adds each dir exactly once" \
  "source '$TOOLS_FILE'; source '$TOOLS_FILE'; p=(\${(s.:.)PATH}); [[ \${#\${(M)p:#\$HOME/.cargo/bin}} == 1 && \${#\${(M)p:#\$HOME/.local/bin}} == 1 ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# (g) Only dirs that EXIST are added — no phantom entries on a box without go or atuin.
_ub_fixture .cargo/bin:procs
ucheck "bindirs: directories that do not exist are never added to PATH" \
  "source '$TOOLS_FILE'; [[ \$PATH != *'/go/bin'* && \$PATH != *'/.atuin/bin'* && \$PATH == *'/.cargo/bin'* ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# (h) ORDER IS A DECISION, not an accident. Each existing dir is prepended, so the front of
# PATH ends up in reverse list order: ~/.atuin/bin ahead of ~/.local/bin. That matches
# lib/bootstrap-lib.sh's blib_user_bindirs_on_path, examples/atuin-daemon.service's
# Environment=PATH, and the OS layers — inverting it here would silently change which
# binary wins on a box holding atuin in both places.
_ub_fixture .cargo/bin:procs .local/bin:eza .atuin/bin:atuin
ucheck "bindirs: ~/.atuin/bin precedes ~/.local/bin, and all of them precede the old PATH" \
  "source '$TOOLS_FILE'; p=(\${(s.:.)PATH}); [[ \${p[(i)\$HOME/.atuin/bin]} -lt \${p[(i)\$HOME/.local/bin]} && \${p[(i)\$HOME/.local/bin]} -lt \${p[(i)$UBSYS]} ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# (i) THE DISAGREEMENT ITSELF. The issue's symptom was not "no alias" but that core-doctor
# and the flags answered differently about the same tool in the same shell. Assert they now
# agree: the doctor says present AND Core wired it. Before the fix the first half passed and
# the second failed, which is exactly the bug.
_ub_fixture .cargo/bin:procs
ucheck "bindirs: core-doctor and HAVE_PROCS now agree about a cargo-installed tool (#425)" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; source '$UI'; source '$FN'; j=\$(core-doctor --json); [[ \$j == *'\"procs\":true'* && -n \${HAVE_PROCS:-} && \${aliases[ps]} == procs ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH= CORE_NO_PAGER=1

# ── ...and the same agreement for EVERY probed tool, not just the one that was reported ──
# #447's point: the five bugs it collected were one defect sampled five times, and the reason
# CI never caught any of them is that nothing asserted the two answers match. The check above
# pins procs because procs is what #425 happened to be reported against; a sixth tool
# packaged unusually would have walked straight past it. Generalise: for every tool
# 00-tools.zsh probes, "the doctor says present" and "Core set the flag" must be the SAME
# boolean. A disagreement in either direction is a bug — doctor=1/flag=0 is #425 exactly (a
# green row for a tool Core never wired, so no alias, and for atuin no history recorded),
# and doctor=0/flag=1 is the mirror (Core wired something the report calls absent).
#
# The tool -> flag mapping is READ OUT OF THE SOURCE, never restated here, so it cannot rot
# and needs no hand-maintained table for the one irregular name (git-absorb ->
# HAVE_GIT_ABSORB, dash to underscore). The `+` quantifiers matter: 00-tools.zsh aligns some
# comments with two spaces, and a single-space regex silently drops those rows.
#
# The regex ALSO skips the bare `_have <tool>` probes #694 left behind — deliberately, and
# it is why this pairs on the assignment rather than on the probe. Those tools set no flag,
# so "the doctor and the flag agree" has nothing to compare; the ledger row they DO write is
# what core-doctor reads, and _core_doctor_stale/_core_doctor_unwired are tested directly.
#
# Excluded BY CONSTRUCTION rather than by a skip list, which is why the pattern is anchored
# to `^_have`: op has no _have line (the doctor probes it live), and fd/bat are set from
# FD_BIN/BAT_BIN inside `if` blocks after resolving fdfind/batcat — all three are pinned by
# their own tests above. Sourcing 20-aliases.zsh keeps this close to a real shell; the one
# alias that shadows a row name (`alias fd=$FD_BIN`) is already outside the pair list.
#
# Pure zsh, no python3: the values are bare true/false against a quoted unique key, so a
# substring test is exact — and unlike the check_dep neighbours this then runs everywhere
# instead of skipping on a box without python3. $'\42' is a literal double quote, which
# survives this bash layer without a thicket of backslashes.
# NO env overrides and no fixture: this one wants the REAL box — real PATH, real tools,
# whatever this runner happens to have installed. That is the whole point. It is only as
# strong as the runner is populated, but it costs nothing on a bare one (everything absent,
# everything unflagged, agreement holds) and it is the assertion that fails the moment a
# tool arrives by a route detection misses.
ucheck "core-doctor and every HAVE_* flag agree about the same box (#447)" \
  "source '$TOOLS_FILE'; source '$ALIASES_FILE'; source '$UI'; source '$FN'
   j=\$(core-doctor --json); bad=(); n=0
   # Narrow to the tools object before substring-matching. --json grew a sibling expected
   # object with the SAME key set (#513), so a bare match on <name>:true now finds whichever
   # object happens to say true — and for a tool that is expected but absent that is the
   # expected object, giving doctor=1 against an unset HAVE_ flag. The substring trick stays
   # (it keeps this assertion python3-free, so it runs on every box); it just has to be
   # pointed at one object. No literal quote marks in this comment: it lives inside a
   # double-quoted bash string, where one would end the string early.
   tj=\${j#*'\"tools\":{'}; tj=\${tj%%'}'*}
   for line in \${(f)\"\$(<'$TOOLS_FILE')\"}; do
     [[ \$line =~ '^_have +([A-Za-z0-9_.-]+) +&& +(HAVE_[A-Z0-9_]+)=1' ]] || continue
     t=\$match[1]; f=\$match[2]; (( n++ ))
     [[ \$tj == *\$'\\42'\$t\$'\\42'':true'* ]] && d=1 || d=0
     [[ -n \${(P)f:-} ]] && h=1 || h=0
     (( d == h )) || bad+=(\"\$t (doctor=\$d \$f=\$h)\")
   done
   (( n >= 24 )) || { print -r -- \"parsed only \$n tool->flag pairs out of 00-tools.zsh\"; exit 1; }
   (( \${#bad} == 0 )) || { print -r -- \"doctor and HAVE_* disagree: \${(j:, :)bad}\"; exit 1; }" \
  CORE_NO_PAGER=1
# ── the HAVE_* contract: the probe outlives the flag (00-tools.zsh, #694) ───────
# #694 cut fourteen `_have <tool> && HAVE_<X>=1` lines down to a bare `_have <tool>`, because
# the flags had no reader anywhere in the fleet. What those lines still do is the entire
# reason they were not deleted outright: `_have` writes _CORE_PROBED[<tool>], and that ledger
# — not any flag — is what core-doctor, _core_doctor_stale and _core_doctor_unwired read.
#
# So the regression this pins is a READING one, not a typo: the next person to open that
# block sees a probe whose result is discarded and deletes the line. Nothing would fail. The
# doctor would simply stop knowing about fourteen tools, and a tool it does not probe is
# reported as "Core does not probe this row" — indistinguishable, from the outside, from a
# tool Core looked for and did not find. That is #545's exact defect class, re-entered from
# the other side.
#
# Derived from the source, never restated: the pattern is a `_have` line with NO `&&`, which
# is precisely the shape #694 created. The floor is 14 because that is how many it created;
# a future prune raises it, and a regression that re-flags or deletes them drops it below.
ucheck "detection: every bare \`_have\` probe still writes its _CORE_PROBED row (#694)" \
  "source '$TOOLS_FILE'
   bad=(); n=0
   for line in \${(f)\"\$(<'$TOOLS_FILE')\"}; do
     [[ \$line =~ '^_have +([A-Za-z0-9_.-]+) *(#.*)?\$' ]] || continue
     t=\$match[1]; (( n++ ))
     (( \${+_CORE_PROBED[\$t]} )) || bad+=(\$t)
   done
   (( n >= 14 )) || { print -r -- \"parsed only \$n bare _have probes out of 00-tools.zsh — #694 left 14\"; exit 1; }
   (( \${#bad} == 0 )) || { print -r -- \"probed but absent from the ledger: \${(j:, :)bad}\"; exit 1; }" \
  CORE_NO_PAGER=1

# …and the flags those lines used to set must stay gone. Named explicitly rather than derived,
# because a deleted line leaves nothing behind to derive FROM — the list IS the assertion, and
# re-adding any of these is a deliberate act that should have to edit this test and declare the
# flag in PORTABILITY.md §5 (audit-core.sh §5j fails an undeclared flag with no reader anyway).
# ast-grep is why this is not computed from the tool names: its flag was HAVE_ASTGREP, not the
# HAVE_AST_GREP a mechanical uppercase would produce.
ucheck "detection: the fourteen flags #694 removed are not set" \
  "source '$TOOLS_FILE'
   bad=()
   for f in HAVE_ASTGREP HAVE_DELTA HAVE_GRON HAVE_GUM HAVE_HYPERFINE HAVE_JNV HAVE_JQ \
            HAVE_LNAV HAVE_SD HAVE_SESH HAVE_SHELLCHECK HAVE_SHFMT HAVE_WATCHEXEC HAVE_YQ; do
     (( \${+parameters[\$f]} )) && bad+=(\$f)
   done
   (( \${#bad} == 0 )) || { print -r -- \"set again without a declaration: \${(j:, :)bad}\"; exit 1; }" \
  CORE_NO_PAGER=1

# ── the declared surface itself: HAVE_ATUIN, both directions (#694) ─────────────
# PORTABILITY.md §5 declares exactly one flag for downstream use, and three OS repos gate
# their atuin daemon exports on it (dotfiles-Alpine/Debian/Fedora, os/*.zsh). A declared flag
# is a promise about BOTH answers, so both are asserted — and hermetically, against a stub in
# a fixture $HOME, because "atuin happens to be installed on this runner" proves only the
# direction that box can show. The #447 agreement check above covers the real box; this covers
# the contract.
_ub_fixture .local/bin:atuin
ucheck "contract: HAVE_ATUIN is set when atuin is on PATH (PORTABILITY.md §5, #694)" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_ATUIN:-} && \$_CORE_PROBED[atuin] == 1 ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# The absent direction pins the ledger's 0 alongside the unset flag. A missing ROW and a row
# reading 0 are different facts — "Core does not probe this" versus "Core looked and it is not
# here" — and only the second is what an OS layer reading the flag is entitled to assume.
_ub_fixture .local/bin:eza
ucheck "contract: HAVE_ATUIN is unset, and the ledger says 0, when atuin is absent (#694)" \
  "source '$TOOLS_FILE'; [[ -z \${HAVE_ATUIN:-} && \$_CORE_PROBED[atuin] == 0 ]]" \
  HOME="$UBHOME" PATH="$UBSYS" CARGO_HOME= GOBIN= GOPATH=

# ── _core_is_wsl: one WSL predicate for the fleet (00-tools.zsh, #449) ───────────
# Six OS layers each carried a byte-identical copy of this probe, and Core had the same fact
# twice more (bash's blib_is_wsl, and a private copy inside bin/clip) with neither reachable
# from zsh. Core owns it now, so it is Core's job to prove it — including the direction each
# individual copy was never tested in at all.
#
# HERMETIC IN BOTH DIRECTIONS, which is the entire reason $CORE_PROC_VERSION exists. This
# suite is developed on a WSL host and runs on non-WSL CI runners; against the real kernel
# version file exactly ONE of the two answers is assertable on each machine, so without a
# seam half the predicate would go untested everywhere and nobody would see the gap. Same
# seam, same reason, as bin/clip's CLIP_PROC_VERSION at the top of this file.
#
# WSL_DISTRO_NAME= IS PASSED EXPLICITLY IN EVERY FILE-PATH CASE. The predicate reads the env
# var FIRST, and a developer running this from inside WSL has it exported — so without the
# neutralisation every case below would pass for the wrong reason, on the one machine most
# likely to be running them. (The same trap the CARGO_HOME= neutralisation above documents.)
WSLFIX="$SANDBOX/wsl"
mkdir -p "$WSLFIX"
printf 'Linux version 6.6.87.2-microsoft-standard-WSL2 (root@build) #1 SMP\n' >"$WSLFIX/wsl2"
printf 'Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com) #488\n' >"$WSLFIX/wsl1"
printf 'Linux version 6.1.0 (nobody@nowhere) WSL banner, no vendor marker\n' >"$WSLFIX/wslword"
printf 'Linux version 5.15.0-generic (buildd@lcy02) #72-Ubuntu SMP\n' >"$WSLFIX/plain"

# (a) The env var short-circuits — asserted by pointing the seam at the NON-WSL fixture, so
# a predicate that consulted the file anyway would answer no and fail here.
ucheck "_core_is_wsl: WSL_DISTRO_NAME alone answers yes (the version file is never consulted)" \
  "source '$TOOLS_FILE'; _core_is_wsl" \
  WSL_DISTRO_NAME=Ubuntu CORE_PROC_VERSION="$WSLFIX/plain"

# (b)-(d) the file fallback, for a login that never inherited the env (su -, a unit, ssh cmd)
ucheck "_core_is_wsl: the WSL2 marker in the version file is WSL" \
  "source '$TOOLS_FILE'; _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wsl2"
# WSL1 capitalises the vendor string. This is the case-fold (${_pv:l}), not a second pattern
# — drop the fold and every WSL1 box silently reads as plain Linux.
ucheck "_core_is_wsl: WSL1's capitalised marker is WSL (the case-fold, not a second pattern)" \
  "source '$TOOLS_FILE'; _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wsl1"
ucheck "_core_is_wsl: a bare wsl marker with no vendor string is WSL (the second pattern)" \
  "source '$TOOLS_FILE'; _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wslword"

# (e) THE NEGATIVE, which is the half no OS-layer copy could ever assert on its own box.
ucheck "_core_is_wsl: a plain Linux version string is NOT WSL" \
  "source '$TOOLS_FILE'; ! _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/plain"

# (f) No version file at all — the macOS/BSD path, where this must be silent and cheap
# rather than an error. Core runs on macOS; the six copies that moved here never did.
ucheck "_core_is_wsl: no version file and no env is NOT WSL (the macOS path, no error)" \
  "source '$TOOLS_FILE'; ! _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/absent"

# (g)-(i) the memo. It is what makes a per-prompt caller free, so it is worth pinning that it
# exists, that it is actually consulted, and that the documented escape re-probes.
ucheck "_core_is_wsl: memoises the answer into _CORE_IS_WSL" \
  "source '$TOOLS_FILE'; _core_is_wsl; [[ \$_CORE_IS_WSL == 1 ]]" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wsl2"
ucheck "_core_is_wsl: the memo is honoured — a second call does not re-read the file" \
  "source '$TOOLS_FILE'; _core_is_wsl; CORE_PROC_VERSION='$WSLFIX/plain'; _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wsl2"
ucheck "_core_is_wsl: unset _CORE_IS_WSL forces a re-probe (the documented escape)" \
  "source '$TOOLS_FILE'; _core_is_wsl; unset _CORE_IS_WSL; CORE_PROC_VERSION='$WSLFIX/plain'; ! _core_is_wsl" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wsl2"

# (j) ZERO FORK, asserted the way the git exec-path suite asserts its own: a PATH holding
# nothing but RECORDING stubs, and an empty call log. This is the guard that fails if someone
# "simplifies" $(<file) into a `grep -qi` — which is exactly what the bash sibling does, and
# what this deliberately does not, because it runs on every interactive shell and a caller may
# put it in a hook. The log is truncated AFTER sourcing so the assertion is about the
# predicate, not about what 00-tools does on the way in.
WSLBIN="$SANDBOX/wslbin"
mkdir -p "$WSLBIN"
for _wc in cat grep head sed awk; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\nexit 0\n' "$_wc" "$WSLFIX" >"$WSLBIN/$_wc"
  chmod +x "$WSLBIN/$_wc"
done
unset _wc
ucheck "_core_is_wsl: reads the version file with no fork (no cat, no grep)" \
  "source '$TOOLS_FILE'; : >|'$WSLFIX/calls'; _core_is_wsl; [[ ! -s '$WSLFIX/calls' ]]" \
  WSL_DISTRO_NAME= CORE_PROC_VERSION="$WSLFIX/wsl2" PATH="$WSLBIN"

# (k) It is Core→OS API, so unlike _have it must SURVIVE 00-tools.zsh. The OS layer calls it
# at band 80; _have is unfunctioned at the end of that file and would not be there.
ucheck "_core_is_wsl: survives 00-tools.zsh (Core→OS API), where _have does not" \
  "source '$TOOLS_FILE'; (( \$+functions[_core_is_wsl] )) && (( ! \$+functions[_have] ))"

# ── band placement of the four tool inits (#449) — structure, not behaviour ──────
# Four decisions that BEHAVIOUR CANNOT SEE. Every one of them is silent when broken: the
# shell still starts, no error is printed, and the damage shows up as a feature quietly not
# working on a subset of hosts. Each assertion below therefore says WHAT breaks, not just
# that a line moved, because the message is the only thing a future contributor will read
# before deciding whether the constraint is real.
PLUGINS_FILE="$HERE/zsh/45-plugins.zsh"
# First-match line number. `grep -n | sed`, not `| head`: a file producer feeding an
# early-exiting reader is exactly the SIGPIPE shape audit-core.sh §5d bans.
_zln() { grep -nE "$2" "$1" | sed -n '1s/:.*//p'; } # _zln <file> <ere>
_zsay() { if [[ -n "$2" ]]; then pass "band placement: $1"; else fail "band placement: $1"; fi; }

_z_direnv_t="$(_zln "$TOOLS_FILE" '^_cache_eval[[:space:]]+direnv')"
_z_direnv_p="$(_zln "$PLUGINS_FILE" '^_cache_eval[[:space:]]+direnv')"
_z_mise="$(_zln "$TOOLS_FILE" '_cache_eval[[:space:]]+mise')"
_z_carapace="$(_zln "$PLUGINS_FILE" '_cache_eval[[:space:]]+--salt.*carapace')"

# (1) direnv's hook is initialised in 00-tools.zsh, and in exactly one file. The louder half
# of this rationale died with CORE_PROFILE (#677): band 45 is no longer gated, so filing it
# there would no longer stop .envrc files loading dead on every `minimal` host. Two reasons
# survive, both still silent when broken. BAND — this registers a HOOK, not a compdef, so it
# gains nothing from waiting for 10-options.zsh's compinit and belongs beside the three other
# hook inits at band 00. OWNERSHIP — the half (4) below cannot see, because (4) compares two
# line numbers WITHIN 00-tools.zsh and stays green if a SECOND copy reappears at band 45.
# #449 hoisted this out of seven os/*.zsh copies that had already drifted (one suppressed the
# generator's stderr, two carried half the block); a duplicate anywhere is that defect back.
_zsay "direnv's hook is in 00-tools.zsh and in no other band — it registers a hook, not a compdef, so band 00 (ahead of compinit) is where it belongs, and a second copy at band 45 is the pre-#449 drift returning" \
  "$([[ -n "$_z_direnv_t" && -z "$_z_direnv_p" ]] && echo ok)"

# (2) …and the three completions are GENERATED at band 00 (#579). Inverted from what this
# asserted before: they used to be sourced at band 45 because they called compdef. They are
# now written into an fpath directory instead, and fpath must be populated BEFORE compinit
# scans it — compinit is band 10, so band 00 is the only band that can guarantee it. Filed at
# band 45 the file would be written a whole shell too late to be seen.
_z_ok=1
for _zt in gh uv ty; do
  [[ -n "$(_zln "$TOOLS_FILE" "^_cache_completion[[:space:]]+${_zt}[[:space:]]")" ]] || _z_ok=""
  [[ -z "$(_zln "$PLUGINS_FILE" "^_cache_completion[[:space:]]+${_zt}[[:space:]]")" ]] || _z_ok=""
  # …and nothing SOURCES them any more. _cache_eval ends in `source`, which is the entire
  # 35 ms this change removes; a caller that slid back to it would be silent otherwise.
  [[ -z "$(_zln "$TOOLS_FILE" "^_cache_eval[[:space:]]+${_zt}[[:space:]]")" ]] || _z_ok=""
  [[ -z "$(_zln "$PLUGINS_FILE" "^_cache_eval[[:space:]]+${_zt}[[:space:]]")" ]] || _z_ok=""
done
unset _zt
_zsay "gh/uv/ty are GENERATED by _cache_completion in 00-tools.zsh and sourced by nothing — fpath must be populated before compinit (band 10) scans it, and _cache_eval would source 6,976 lines per shell" "$_z_ok"

# (3) …and the compdef re-assert is still AFTER carapace. This is the half that survives the
# move, and it is the whole reason a band-45 line still exists: fpath autoloading registers
# these at COMPINIT — band 10, i.e. BEFORE carapace at band 45 — so without re-asserting here
# the move would silently hand gh back to the bridged completion. Whichever compdef runs last
# owns the command.
_z_compdef="$(_zln "$PLUGINS_FILE" 'compdef "_\$t" "\$t"')"
_zsay "the gh/uv/ty compdef re-assert is AFTER the carapace block — fpath autoload registers at band 10, before carapace, so without this the bridged completion silently wins" \
  "$([[ -n "$_z_carapace" && -n "$_z_compdef" ]] && (( _z_compdef > _z_carapace )) && echo ok)"
unset _z_compdef

# (4) direnv after mise. Both PREPEND their hooks, so the one sourced last runs FIRST.
_zsay "direnv is initialised AFTER mise — both PREPEND their hooks, so the one sourced last runs first; inverting this changes per-directory env resolution with no visible symptom" \
  "$([[ -n "$_z_direnv_t" && -n "$_z_mise" ]] && (( _z_direnv_t > _z_mise )) && echo ok)"
unset _z_direnv_t _z_direnv_p _z_mise _z_carapace _z_ok

# ── git subcommands in git's exec-path: an honest doctor off $PATH (#424) ────
# The Debian family packages a git SUBCOMMAND into git's exec-path (`git --exec-path`) and
# keeps that directory off $PATH on purpose — git dispatches `git absorb` by looking there
# itself. Verified on Kali, git-absorb 0.6.17-2+b4: `dpkg -L` lists the exec-path binary and
# a man page and NOTHING in a PATH dir, `command -v git-absorb` finds nothing, and
# `git absorb --version` prints 0.6.17. core-doctor printed `✗ git-absorb` for a tool the
# reader had just used — #418's failure one directory further out, and it earns the same
# hermetic treatment for the same reason: the box running this suite has it one way or the
# other (a Kali runner ONLY in the exec-path, an Arch one ONLY on PATH) and neither can
# prove the other's path.
#
#   $GXROOT/bin/git                  stub: answers --exec-path, and LOGS every invocation
#   $GXROOT/lib/git-core/git-absorb  the subcommand — executable, NOT on $PATH
#   $GXROOT/bin/{grep,head}          real, symlinked: `core-doctor -v` pipes --version through them
#
# The bin/ · lib/git-core/ layout is not cosmetic: 00-tools.zsh's zero-fork fallback derives
# its candidates from ${commands[git]:h:h} rather than naming a distro path, so the tree has
# to be shaped like a real prefix for that half to be exercised at all. The call log is what
# lets the fork budget itself be asserted, in (d) and (e) and (h).
#
# HERMETIC AGAINST THE DEVELOPER'S OWN ENVIRONMENT. `ucheck` runs `env "$@" zsh`, which
# passes the named variables ON TOP of the inherited environment — it does not clear it. So
# a box with GIT_EXEC_PATH exported would leak it into every case here: the git stub honours
# the variable exactly as real git does, so it would answer with the developer's directory
# instead of $GXLIB and cases (a)-(h) would fail for a reason that has nothing to do with
# the code under test. Unset it once, here, for the whole block; the cases that need it
# pass it explicitly through ucheck's env.
unset GIT_EXEC_PATH
GXROOT="$SANDBOX/gitexec"
GXBIN="$GXROOT/bin"
GXLIB="$GXROOT/lib/git-core"
_gx_tree() { # _gx_tree [name ...] — rebuild the tree; each name also lands on $PATH as a stub
  rm -rf "$GXROOT"
  mkdir -p "$GXBIN" "$GXLIB"
  # $1/$* below belong to the /bin/sh stub being written, not to this shell — hence printf
  # with %s rather than an expanding heredoc.
  # The stub honours $GIT_EXEC_PATH exactly as real git does. That is not decoration: it is
  # the only way to move the exec-path BETWEEN two reports using nothing but an env var,
  # and this PATH is hermetic — it carries git, grep and head and nothing else, so a test
  # body cannot reach for `mv` to rearrange the tree.
  printf '#!/bin/sh\necho "$*" >>"%s/calls"\n[ "$1" = --exec-path ] && { echo "${GIT_EXEC_PATH:-%s}"; exit 0; }\nexit 1\n' \
    "$GXROOT" "$GXLIB" >"$GXBIN/git"
  printf '#!/bin/sh\necho "git-absorb 0.6.17"\n' >"$GXLIB/git-absorb"
  chmod +x "$GXBIN/git" "$GXLIB/git-absorb"
  local n
  for n in "$@"; do
    printf '#!/bin/sh\necho "%s 0.6.17"\n' "$n" >"$GXBIN/$n"
    chmod +x "$GXBIN/$n"
  done
  ln -sf "$_real_grep" "$GXBIN/grep"
  ln -sf "$_real_head" "$GXBIN/head"
}
# (a) THE ISSUE. 00-tools.zsh is deliberately NOT sourced, so a ✓ can only come from
#     _core_doctor_bin asking git — not from a HAVE_* flag and not from an alias.
_gx_tree
ucheck "git exec-path: core-doctor reports a subcommand that lives ONLY in git's exec-path" \
  "source '$UI'; source '$FN'; j=\$(core-doctor --json); [[ \$j == *'\"git-absorb\":true'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (b) VERSIONS — the latent half, exactly as in the fd/bat suite above: -v forks the RESOLVED
#     binary. A bare `git-absorb --version` cannot run on this family at all, so this row
#     could not have carried a version even if presence had somehow been right.
ucheck "git exec-path: core-doctor -v reads the version off the exec-path binary" \
  "source '$UI'; source '$FN'; o=\$(core-doctor -v); [[ \$o == *'git-absorb 0.6.17'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (c) NO LEAK — the row is keyed and PRINTED by its canonical name; the absolute path the
#     resolver hands back is an implementation detail and must not reach the report. The
#     `resolved` footer names the exec-path DIRECTORY, which is why this asserts against the
#     full binary path rather than against the directory.
ucheck "git exec-path: the report prints the canonical name, never the resolved absolute path" \
  "source '$UI'; source '$FN'; o=\$(NO_COLOR=1 core-doctor); [[ \$o == *'✓ git-absorb'* && \$o != *'$GXLIB/git-absorb'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (d) ONE FORK PER REPORT. The cache is the reason forking here is acceptable at all; without
#     it the answer is re-derived per git-* row and per renderer. Driven through
#     _core_doctor_bin with TWO different names rather than through a report, deliberately:
#     _CORE_DOCTOR_GROUPS carries exactly one `git-*` row today, so a whole-report assertion
#     would read `== 1` with the cache torn out and prove nothing. Two names is the smallest
#     input that can tell a cache from its absence, and it stays honest if the inventory
#     never grows a second git subcommand.
_gx_tree
ucheck "git exec-path: two git-* rows resolve on ONE fork (the cache, not a one-row artefact)" \
  "source '$UI'; source '$FN'; _core_doctor_bin git-absorb; _core_doctor_bin git-imaginary; (( \$(grep -c -- '--exec-path' '$GXROOT/calls') == 1 ))" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (d2) …AND THE CACHE MUST NOT OUTLIVE ITS REPORT. Only the TTY render runs in a `$(…)`
#     subshell; --json and the non-TTY path run in the caller's shell, so core-doctor unsets
#     the cache on entry. Without that unset a shell that ran one report before git was
#     installed would keep answering from the cached EMPTY value forever. Asserted by
#     MOVING THE EXEC-PATH between two reports in ONE shell, via $GIT_EXEC_PATH, which the
#     git stub honours as real git does: the first report is pointed at an empty directory
#     and must say false, the second at the real one and must say true. A cache that outlives
#     its report answers the second from the first's directory and the assertion fails.
#     Done with an env var rather than by rearranging the tree because this PATH is hermetic
#     — no `mv` on it — and a body that shells out to a missing tool fails silently, which
#     is how the first draft of this case passed for the wrong reason.
_gx_tree
mkdir -p "$GXROOT/lib/git-core-empty"
#     REDIRECT TO A FILE, never `$(…)` — the same rule the OSC 133 block below states for its
#     own reason. A command substitution is itself a subshell, so it discards the cache on the
#     way out and this case passes no matter what core-doctor does. Redirection keeps both
#     reports in the one shell, which is the only place the leak is observable.
ucheck "git exec-path: a second report re-derives — the cache does not outlive its invocation" \
  "source '$UI'; source '$FN'
   export GIT_EXEC_PATH='$GXROOT/lib/git-core-empty'; core-doctor --json >'$GXROOT/j1'
   export GIT_EXEC_PATH='$GXLIB';                     core-doctor --json >'$GXROOT/j2'
   [[ \$(<'$GXROOT/j1') == *'\"git-absorb\":false'* && \$(<'$GXROOT/j2') == *'\"git-absorb\":true'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (e) PATH FIRST. A git-absorb on $PATH must be used as-is and git must never be asked — this
#     is what keeps the fix free on every box that never had the bug.
_gx_tree git-absorb
ucheck "git exec-path: a git-absorb on \$PATH is used as-is — git is never forked to find it" \
  "source '$UI'; source '$FN'; j=\$(core-doctor --json); [[ \$j == *'\"git-absorb\":true'* ]] && [[ ! -s '$GXROOT/calls' ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (f) HONEST ✗, twice: git present with no subcommand, and no git at all. core-doctor is
#     read-only diagnostics and must return 0 through both.
_gx_tree; rm -f "$GXLIB/git-absorb"
ucheck "git exec-path: git present but no subcommand in its exec-path → an honest ✗, rc 0" \
  "source '$UI'; source '$FN'; j=\$(core-doctor --json) && [[ \$j == *'\"git-absorb\":false'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
_gx_tree; rm -f "$GXBIN/git" "$GXLIB/git-absorb"
ucheck "git exec-path: no git at all → an honest ✗ and no error (the empty answer is cached)" \
  "source '$UI'; source '$FN'; j=\$(core-doctor --json) && [[ \$j == *'\"git-absorb\":false'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
# (g) THE RESOLVER'S CONTRACT: a RUNNABLE absolute path, which is what makes the -v fork work.
_gx_tree
ucheck "git exec-path: _core_doctor_bin hands back a runnable absolute path for the resolved row" \
  "source '$UI'; source '$FN'; _core_doctor_bin git-absorb; [[ \$REPLY == '$GXLIB/git-absorb' ]] && [[ \$(\$REPLY --version) == 'git-absorb 0.6.17' ]]" \
  PATH="$GXBIN"
# (h) 00-tools.zsh's half — and its ZERO-FORK contract in the same assertion: the flag must be
#     set from git's exec-path, derived via $commands, with `git` itself never invoked. This is
#     the guard that fails if someone "simplifies" the fallback into a $(git --exec-path).
_gx_tree
ucheck "git exec-path: HAVE_GIT_ABSORB is set from git's exec-path, with no fork (00-tools.zsh)" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_GIT_ABSORB:-} ]] && [[ ! -s '$GXROOT/calls' ]]" \
  PATH="$GXBIN"
_gx_tree; rm -f "$GXLIB/git-absorb"
ucheck "git exec-path: HAVE_GIT_ABSORB stays unset when the exec-path has no git-absorb" \
  "source '$TOOLS_FILE'; [[ -z \${HAVE_GIT_ABSORB:-} ]]" \
  PATH="$GXBIN"
# (i) $GIT_EXEC_PATH is git's own override, so the flag must honour it — asserted from a
#     directory OUTSIDE the derived prefix, or the derived candidate would satisfy it anyway.
_gx_tree; rm -f "$GXLIB/git-absorb"
mkdir -p "$GXROOT/elsewhere"
printf '#!/bin/sh\necho "git-absorb 0.6.17"\n' >"$GXROOT/elsewhere/git-absorb"
chmod +x "$GXROOT/elsewhere/git-absorb"
ucheck "git exec-path: \$GIT_EXEC_PATH is honoured for the flag (git's own override wins)" \
  "source '$TOOLS_FILE'; [[ -n \${HAVE_GIT_ABSORB:-} ]]" \
  PATH="$GXBIN" GIT_EXEC_PATH="$GXROOT/elsewhere"
# (i2) …and the INVERSE, which case (i) alone cannot see: the override must be EXCLUSIVE, not
#     one more candidate. GIT_EXEC_PATH REPLACES git's compiled-in exec-path — point it at an
#     empty directory and `git absorb` answers "'absorb' is not a git command" even with the
#     binary still sitting in the default one. So with the override empty and the DEFAULT
#     exec-path populated, the flag must stay unset: setting it would claim a subcommand git
#     can no longer dispatch, and core-doctor — which asks `git --exec-path` and therefore
#     inherits the override — would rightly disagree. #503 shipped the fall-through; this is
#     the guard against it coming back.
_gx_tree   # git-absorb IS in the default exec-path here; the override deliberately is not
mkdir -p "$GXROOT/empty-override"
ucheck "git exec-path: a \$GIT_EXEC_PATH without the subcommand wins over the default (no false ✓)" \
  "source '$TOOLS_FILE'; [[ -z \${HAVE_GIT_ABSORB:-} ]]" \
  PATH="$GXBIN" GIT_EXEC_PATH="$GXROOT/empty-override"
# …and the doctor must AGREE with the flag on that same box, which is the whole point of
# keeping the two in step (#425). The git stub honours GIT_EXEC_PATH exactly as real git
# does, so this puts both assertions on one configuration.
ucheck "git exec-path: flag and doctor agree under an empty override (both absent)" \
  "source '$TOOLS_FILE'; source '$UI'; source '$FN'; j=\$(core-doctor --json)
   [[ -z \${HAVE_GIT_ABSORB:-} && \$j == *'\"git-absorb\":false'* ]]" \
  PATH="$GXBIN" GIT_EXEC_PATH="$GXROOT/empty-override" CORE_NO_PAGER=1
# (i3) EXPORTED, not merely set. git reads GIT_EXEC_PATH from its ENVIRONMENT, so a plain
#     shell assignment — `scalar`, not `scalar-export` — is invisible to it. Treating any
#     non-empty parameter as authoritative gives the MIRROR of (i2): the flag honours an
#     override git ignores and reports absent while `git absorb` and the doctor both work.
#     Set INSIDE the body rather than passed through `ucheck`'s env, which is the whole
#     point — anything ucheck exports arrives as `scalar-export` and cannot express this.
#     git-absorb is in the default exec-path, so the correct answer is present-and-agreeing.
_gx_tree
#     `unset` FIRST, then assign: assigning to an already-exported parameter PRESERVES the
#     export attribute, so on a box where GIT_EXEC_PATH is exported a bare assignment would
#     leave it `scalar-export` and this case would fail for the wrong reason. Unsetting drops
#     the attribute with the value, and the plain assignment then creates a fresh `scalar`.
#     The type is asserted rather than assumed, so if that ever stops holding this fails
#     loudly instead of quietly testing the exported path twice.
ucheck "git exec-path: an UNEXPORTED GIT_EXEC_PATH is ignored, as git ignores it" \
  "unset GIT_EXEC_PATH; GIT_EXEC_PATH='$GXROOT/empty-override'   # set, deliberately NOT exported
   [[ \${(t)GIT_EXEC_PATH} == scalar ]] || return 1
   source '$TOOLS_FILE'; source '$UI'; source '$FN'; j=\$(core-doctor --json)
   [[ -n \${HAVE_GIT_ABSORB:-} && \$j == *'\"git-absorb\":true'* ]]" \
  PATH="$GXBIN" CORE_NO_PAGER=1
