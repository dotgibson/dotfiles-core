# scripts/test/71-prompt-atuin.sh
# OSC 133 prompt marks + the atuin ATUIN_NOBIND/daemon guard
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── OSC 133 prompt marks + the command-block rule (00-tools.zsh) ─────────────
# The marks are what tmux's next-prompt/previous-prompt (bound to ] / [ in
# tmux.reset.conf) read, so a regression here silently costs the keybinding its meaning
# with nothing to see on screen — precisely the shape a behavioral gate must catch. The
# hooks also moved OUT of the HAVE_STARSHIP gate (the marks must work on a bare box and
# over SSH, where the rule is starship-only), which is what cases (h)/(i) below pin.
#
# MECHANICS. Capture by REDIRECTING TO A FILE, never `$(…)`: the exit-code cases need $?
# to reach the hook intact, and a file redirect leaves it untouched with no subshell
# question to reason about. `(exit 7)` sets that status with no external binary, so the
# cases stay valid under an isolated PATH. TERM and TMUX are passed EXPLICITLY wherever
# they matter — this suite may itself be running inside tmux, under any terminal, and
# `env` would otherwise leak the real values into the assertion.
OSCOUT="$SANDBOX/osc133.out"
OSCEMPTY="$SANDBOX/oscempty" # an EMPTY PATH: no starship, so the rule cannot be drawn
mkdir -p "$OSCEMPTY"
# (a) THE A MARK IS IN $PROMPT, and it is there because a hook-emitted one does not
#     survive: zsh's prompt preamble ends in ED (\e[J) over the line the mark was just
#     written to, and tmux drops that line's prompt flag when it is cleared — measured on
#     3.7b, previous-prompt would not move at all. Zero-width %{…%}, or every prompt's
#     width math is off by the length of an escape sequence.
ucheck "osc133: the A mark is carried in \$PROMPT as a zero-width %{…%} escape" \
  "source '$TOOLS_FILE'; _core_osc133_prompt; [[ \$PROMPT == '%{'*']133;A'*'%}'* ]]" \
  TERM=xterm-256color TMUX=
# (a2) IDEMPOTENT — starship re-sets PROMPT every precmd, but on a box WITHOUT starship it
#      is static, so a hook that prepended unconditionally would grow a mark per prompt.
ucheck "osc133: re-marking an already-marked PROMPT does not stack marks" \
  "source '$TOOLS_FILE'; repeat 3 _core_osc133_prompt; p=\${PROMPT/']133;A'/}; [[ \$p != *']133;A'* ]]" \
  TERM=xterm-256color TMUX= PATH="$OSCEMPTY"
# (a3) APPENDED, not prepended: starship_precmd re-sets PROMPT wholesale, so a mark applied
#      before it would be discarded again on every prompt. The contract is RELATIVE — after
#      starship — not "last": the atuin guard appends itself after us at the end of this
#      file, and an OS (80) or host (99) fragment may append more. A stand-in starship_precmd
#      is seeded before sourcing (PATH has no real starship, so nothing else registers one),
#      which is what makes the ordering assertable at all on a box without the binary.
ucheck "osc133: the PROMPT hook is ordered AFTER starship_precmd (which re-sets PROMPT)" \
  "starship_precmd() { : }; precmd_functions=(starship_precmd); source '$TOOLS_FILE'; [[ -n \${precmd_functions[(r)_core_osc133_prompt]} ]] && (( \$precmd_functions[(i)_core_osc133_prompt] > \$precmd_functions[(i)starship_precmd] ))" \
  TERM=xterm-256color TMUX= PATH="$OSCEMPTY"
# (a4) …and it must be transparent to \$?, since it now sits between the command and any
#      hook an OS (80) or host (99) fragment appends after it.
ucheck "osc133: the PROMPT hook preserves \$? for later precmd hooks" \
  "source '$TOOLS_FILE'; (exit 7); _core_osc133_prompt; (( \$? == 7 ))" \
  TERM=xterm-256color TMUX=
# (a5) The transient prompt is the other half: collapsing a finished prompt REDRAWS that
#      line and clears its flag, and scrollback is what previous-prompt jumps THROUGH.
check "osc133: the transient prompt carries the mark too (scrollback stays jumpable)" \
  "grep -q 'TRANSIENT_PROMPT_TRANSIENT_PROMPT=\"\${_CORE_OSC133_MARK:-}\"' '$HERE/zsh/45-plugins.zsh'"
# (b) D carries the REAL exit code — the mark non-tmux OSC 133 consumers read for status.
ucheck "osc133: the D mark carries the real exit code (]133;D;7)" \
  "source '$TOOLS_FILE'; _CMD_BLOCK_RAN=1; (exit 7); _cmd_block_precmd >'$OSCOUT'; [[ \"\$(<'$OSCOUT')\" == *']133;D;7'* ]]" \
  TERM=xterm-256color TMUX=
# (c) The hook must RESTORE \$? — every later precmd (starship_precmd included) reads it,
#     and emitting a status mark makes that correctness load-bearing rather than cosmetic.
ucheck "osc133: _cmd_block_precmd returns the command's exit code, not its own" \
  "source '$TOOLS_FILE'; _CMD_BLOCK_RAN=1; (exit 7); _cmd_block_precmd >/dev/null; (( \$? == 7 ))" \
  TERM=xterm-256color TMUX=
# (b2) C is emitted at COMMAND START — the mark tmux's `-o` "jump to the output" variant
#      reads. Same -rn discipline: it must not open a line of its own.
ucheck "osc133: preexec emits the command-output mark (]133;C) and nothing else" \
  "source '$TOOLS_FILE'; _cmd_block_preexec >'$OSCOUT'; [[ \"\$(<'$OSCOUT')\" == *']133;C'* ]] && (( \$(wc -l <'$OSCOUT') == 0 ))" \
  TERM=xterm-256color TMUX=
# (d) A bare Enter: NO D and NO rule (both describe a command that ran) — the A mark is in
#     PROMPT, so an idle prompt is still a jump target without emitting anything. Pins the
#     _CMD_BLOCK_RAN gating the restructure moved. Empty PATH ⇒ no starship ⇒ the "no rule"
#     half is deterministic on any CI box.
ucheck "osc133: a bare prompt emits nothing — no D mark, no rule" \
  "source '$TOOLS_FILE'; _CMD_BLOCK_RAN=0; _cmd_block_precmd >'$OSCOUT'; [[ ! -s '$OSCOUT' ]]" \
  TERM=xterm-256color TMUX= PATH="$OSCEMPTY"
# (e) Ghostty injects its OWN prompt marking, so outside tmux Core stands down rather than
#     double-mark: no mark in PROMPT, and no C/D on the wire either.
ucheck "osc133: stands down under Ghostty's own shell integration (outside tmux)" \
  "source '$TOOLS_FILE'; _CMD_BLOCK_RAN=1; _cmd_block_precmd >'$OSCOUT'; [[ -z \$_CORE_OSC133_MARK && \$PROMPT != *']133;'* && \"\$(<'$OSCOUT')\" != *']133;'* ]]" \
  TERM=xterm-256color TMUX= GHOSTTY_SHELL_FEATURES=cursor,title
# (f) …but GHOSTTY_SHELL_FEATURES is EXPORTED and reaches the tmux server, while Ghostty
#     injects into the INITIAL shell only. Inside tmux Core is the only emitter — and tmux
#     copy mode is where the marks are actually spent — so it must NOT stand down there.
ucheck "osc133: still marks inside tmux under Ghostty (its integration isn't in the pane)" \
  "source '$TOOLS_FILE'; _core_osc133_prompt; [[ \$PROMPT == *']133;A'* ]]" \
  TERM=xterm-256color TMUX=/tmp/tmux-0/default,1,0 GHOSTTY_SHELL_FEATURES=cursor,title
# (g) A consumer that does not parse OSC (Emacs M-x shell) would render the sequence as
#     literal garbage in the prompt and above every command's output.
ucheck "osc133: stands down on TERM=dumb (no literal escape garbage)" \
  "source '$TOOLS_FILE'; _CMD_BLOCK_RAN=1; _cmd_block_precmd >'$OSCOUT'; [[ -z \$_CORE_OSC133_MARK && \$PROMPT != *']133;'* && \"\$(<'$OSCOUT')\" != *']133;'* ]]" \
  TERM=dumb TMUX=
# (h) THE HOIST: on a box with no starship the hooks must still be registered (marks are
#     not a prompt cosmetic) — and _cmd_block_precmd stays FIRST, so the rule and the D mark
#     land above whatever a later hook prints instead of interleaved with it.
ucheck "osc133: hooks registered without starship, and precmd stays first (output order)" \
  "source '$TOOLS_FILE'; [[ -z \${HAVE_STARSHIP:-} && \$precmd_functions[1] == _cmd_block_precmd && -n \${preexec_functions[(r)_cmd_block_preexec]} ]]" \
  TERM=xterm-256color TMUX= PATH="$OSCEMPTY"
# (i) The other side of that gate: marks stood down AND no starship means neither hook has
#     any work at all, so a shell must not carry either of them for the life of the session.
ucheck "osc133: no hooks at all when the marks stand down and starship is absent" \
  "source '$TOOLS_FILE'; [[ -z \${precmd_functions[(r)_cmd_block_precmd]} && -z \${preexec_functions[(r)_cmd_block_preexec]} && -z \${precmd_functions[(r)_core_osc133_prompt]} ]]" \
  TERM=dumb TMUX= PATH="$OSCEMPTY"

# (j) THE REGRESSION GATE on the harness itself, not on the shell layer — and the reason it
#     is here rather than left to CI: this bug was INVISIBLE to CI by construction. No runner
#     is hosted in Ghostty, so every mark-ON case above passed on ubuntu, macos, arch and
#     alpine while the identical tree red 7 assertions for an operator running `make audit`
#     from the terminal this repo ships a config for. A green CI lane was not evidence.
#
#     Drive one mark-ON assertion with GHOSTTY_SHELL_FEATURES genuinely EXPORTED — exactly
#     what a Ghostty-hosted audit does — and require the same verdict. This fails loudly if
#     anyone drops the `env -u` from ucheck. Exported for real, not passed as an argument:
#     an argument is the thing cases (e)/(f) already do and would test nothing, because the
#     leak is about what `env` INHERITS.
_osc_amb_set=0
[[ -n ${GHOSTTY_SHELL_FEATURES+x} ]] && _osc_amb_set=1
_osc_amb_saved="${GHOSTTY_SHELL_FEATURES-}"
export GHOSTTY_SHELL_FEATURES=cursor,title
ucheck "osc133: the harness is insulated from an ambient GHOSTTY_SHELL_FEATURES (an audit run inside Ghostty cannot red a green tree)" \
  "source '$TOOLS_FILE'; _core_osc133_prompt; [[ \$PROMPT == '%{'*']133;A'*'%}'* ]]" \
  TERM=xterm-256color TMUX=
# Restore rather than blanket-unset: the caller's environment is not ours to edit, and a
# later section reading it would otherwise see a value this block invented.
if ((_osc_amb_set)); then export GHOSTTY_SHELL_FEATURES="$_osc_amb_saved"; else unset GHOSTTY_SHELL_FEATURES; fi
unset _osc_amb_set _osc_amb_saved

# ── atuin: ATUIN_NOBIND + the OPT-IN daemon guard (00-tools.zsh) ──────────────
# Two things were ungated here. (1) ATUIN_NOBIND=true is what keeps atuin from grabbing
# the keys 40-bindings.zsh/35-fzf.zsh own (Ctrl+E is OURS, Ctrl+R stays on the fzf widget),
# and it doubles as the _cache_eval salt — yet nothing asserted it. (2) The daemon guard:
# with the daemon enabled and its socket absent or STALE, atuin does not fall back — measured
# on 18.19.0 it exits 0, prints a well-formed id, writes nothing to stderr and DISCARDS the
# entry. So Core probes the socket before the first prompt AND THEN, THROTTLED, FOR THE LIFE OF
# THE SHELL, and forces the daemon off permanently the first time a connect fails — which is what
# makes atuin really write SQLite. The stake is the history itself,
# not per-command latency. Case (d) below pins the OTHER half of that contract — the accept-but-silent
# state it deliberately does not claim to catch. Both are hermetic — no atuin
# binary needed: the guard is defined unconditionally (only its precmd registration is
# HAVE_ATUIN-gated), and a real listener comes from zsh's own zsocket.
# Cases (g)-(l) are the WATCHDOG half (dotgibson/dotfiles-core#366). They manufacture a
# mid-session daemon death by closing the listening fd `zsocket -l` handed back — the socket FILE
# survives, which is exactly case (c)'s stale state, but arrived at mid-run — and they time-travel
# past the throttle window by BACK-DATING _CORE_ATUIN_DAEMON_NEXT. This suite has no `sleep`
# anywhere and must not grow one. Two rules every body below obeys: never wrap the guard in
# `$(…)` or a pipeline (the globals and the precmd_functions edits would be lost to the subshell)
# — redirect stderr to a file under $SANDBOX and grep that instead; and where an assertion touches
# precmd_functions, pass PATH="$ATBIN:$PATH" so the registration actually happened, or the check
# is vacuously true.
ATBIN="$SANDBOX/atbin"
ATCACHE="$SANDBOX/atcache"
rm -rf "$ATBIN" "$ATCACHE"
mkdir -p "$ATBIN" "$ATCACHE/zsh" "$SANDBOX/atempty" # atempty = an EMPTY PATH: no atuin at all
printf '#!/bin/sh\n:\n' >"$ATBIN/atuin"
chmod +x "$ATBIN/atuin"
# EXPORTED, not merely set: an unexported ATUIN_NOBIND never reaches the atuin binary, so
# atuin would go back to grabbing the up-arrow and Ctrl+R behind Core's back.
ucheck "atuin: ATUIN_NOBIND is EXPORTED true (Core owns Ctrl+E / Ctrl+R, not atuin)" \
  "source '$TOOLS_FILE'; [[ \$ATUIN_NOBIND == true && \${(t)ATUIN_NOBIND} == *export* ]]"
# The other half of that contract: the init cache is SALTED on ATUIN_NOBIND, so flipping it
# selects a different cache instead of serving a stale init. A regression that dropped
# --salt would write the unsalted name and quietly reintroduce the stale-cache bug.
ucheck "atuin: the init cache is salted on ATUIN_NOBIND (atuin.true.zsh, not atuin.zsh)" \
  "source '$TOOLS_FILE'; [[ -f \$XDG_CACHE_HOME/zsh/atuin.true.zsh && ! -e \$XDG_CACHE_HOME/zsh/atuin.zsh ]]" \
  PATH="$ATBIN:$PATH" XDG_CACHE_HOME="$ATCACHE"
# The guard is REGISTERED only where atuin exists (the function itself is defined either way,
# so the tests below can drive it) — a bare box must not carry a precmd hook for a tool it
# does not have.
ucheck "atuin daemon: the guard is hooked onto precmd when atuin is present" \
  "source '$TOOLS_FILE'; [[ -n \${precmd_functions[(r)_core_atuin_daemon_guard]} ]]" \
  PATH="$ATBIN:$PATH" XDG_CACHE_HOME="$ATCACHE"
ucheck "atuin daemon: no precmd hook on a box without atuin (fully inert)" \
  "source '$TOOLS_FILE'; [[ -z \${precmd_functions[(r)_core_atuin_daemon_guard]} ]]" \
  PATH="$SANDBOX/atempty" XDG_CACHE_HOME="$ATCACHE"
# (a) NOT opted in — the guard must leave the env exactly as it found it (no daemon, no
#     socket probe, no surprise export on the eight machines that never asked for it).
ucheck "atuin daemon: guard is a no-op when the daemon was never opted into" \
  "source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ -z \${ATUIN_DAEMON__ENABLED:-} && -z \${_CORE_ATUIN_DAEMON_DEGRADED:-} ]]"
# (b) OPTED IN, socket unreachable — degrade to direct SQLite writes, which is what stops
#     atuin silently dropping every command it is handed.
ucheck "atuin daemon: an unreachable socket degrades the daemon off (no silently discarded history)" \
  "source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == false && -n \$_CORE_ATUIN_DAEMON_DEGRADED ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
# (c) A STALE socket FILE (bound then closed — no listener) is the case a plain -S test
#     passes, and the one that silently eats history rather than erroring. The connect
#     probe must still degrade.
ucheck "atuin daemon: a stale socket file (no listener) degrades too, not just an absent one" \
  "rm -f '$SANDBOX/stale-atuin.sock'; zmodload zsh/net/socket; zsocket -l '$SANDBOX/stale-atuin.sock'; exec {REPLY}>&-; source '$TOOLS_FILE'; [[ -S '$SANDBOX/stale-atuin.sock' ]] && { _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == false ]] }" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/stale-atuin.sock"
# (d) A LISTENING socket must be left alone — the guard exists to catch a dead daemon, not
#     to second-guess a working one. zsocket -l gives a real listener with no atuin involved.
#     Note what this listener also IS: accept-but-silent, i.e. the exact blind spot named in
#     00-tools.zsh (a socket-activated socket in front of a dead daemon looks like this). The
#     assertion therefore pins the guard's DOCUMENTED scope in both directions — it must not
#     claim to catch a state a connect cannot distinguish. A live listener also ARMS the
#     watchdog, so _CORE_ATUIN_DAEMON_WAS_UP is the healthy path's new observable.
ucheck "atuin daemon: a listening socket keeps the daemon enabled (accept-but-silent is out of scope)" \
  "rm -f '$SANDBOX/live-atuin.sock'; zmodload zsh/net/socket; zsocket -l '$SANDBOX/live-atuin.sock'; source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == true && -z \${_CORE_ATUIN_DAEMON_DEGRADED:-} && -n \$_CORE_ATUIN_DAEMON_WAS_UP ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/live-atuin.sock"
# (d2) THE CANDIDATE LIST (#518). atuin PR #3910 (merged 2026-08-12, ships in 18.20.0) moves
#      the default socket for `systemd_socket = false` — the shape Core recommends — to
#      $TMPDIR/atuin-$UID/atuin.sock. The client got a legacy search list; this guard had
#      none and resolved ONE expression, so on 18.20.0 every shell would export
#      ATUIN_DAEMON__ENABLED=false at its first precmd and unhook, with NO warning
#      (_CORE_ATUIN_DAEMON_WAS_UP is never set on that path). Silent, fleet-wide, and in the
#      cheap direction — which is exactly why it would go unnoticed.
#
#      Each case puts a REAL listener on exactly one candidate and leaves the others absent,
#      so a guard that probed only the other path degrades and the assertion fails.
ATSOCKTMP="$SANDBOX/atsock"
mkdir -p "$ATSOCKTMP/atuin-$(id -u)" "$ATSOCKTMP/xdgrun" "$ATSOCKTMP/xdgdata/atuin"
# The 18.20.0 default, with XDG_RUNTIME_DIR set — i.e. a systemd box, where the OLD single
# expression would have resolved $XDG_RUNTIME_DIR/atuin.sock and found nothing.
ucheck "atuin daemon: finds the 18.20.0 default \$TMPDIR/atuin-\$UID/atuin.sock (#518)" \
  "rm -f '$ATSOCKTMP/atuin-$(id -u)/atuin.sock'; zmodload zsh/net/socket; zsocket -l '$ATSOCKTMP/atuin-$(id -u)/atuin.sock'; source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == true && -n \$_CORE_ATUIN_DAEMON_WAS_UP ]]" \
  ATUIN_DAEMON__ENABLED=true TMPDIR="$ATSOCKTMP" XDG_RUNTIME_DIR="$ATSOCKTMP/xdgrun" \
  XDG_DATA_HOME="$ATSOCKTMP/xdgdata"
# The legacy systemd path — a daemon predating 18.20.0, or one with systemd_socket = true,
# which PR #3910 left unchanged. Must still be reached.
ucheck "atuin daemon: still reaches the legacy \$XDG_RUNTIME_DIR/atuin.sock (#518)" \
  "rm -f '$ATSOCKTMP/xdgrun/atuin.sock'; zmodload zsh/net/socket; zsocket -l '$ATSOCKTMP/xdgrun/atuin.sock'; source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == true && -n \$_CORE_ATUIN_DAEMON_WAS_UP ]]" \
  ATUIN_DAEMON__ENABLED=true TMPDIR="$ATSOCKTMP/nowhere" XDG_RUNTIME_DIR="$ATSOCKTMP/xdgrun" \
  XDG_DATA_HOME="$ATSOCKTMP/xdgdata"
# The legacy data-dir path — macOS and anywhere XDG_RUNTIME_DIR is unset.
ucheck "atuin daemon: still reaches the legacy data-dir socket (#518)" \
  "rm -f '$ATSOCKTMP/xdgdata/atuin/atuin.sock'; zmodload zsh/net/socket; zsocket -l '$ATSOCKTMP/xdgdata/atuin/atuin.sock'; source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == true && -n \$_CORE_ATUIN_DAEMON_WAS_UP ]]" \
  ATUIN_DAEMON__ENABLED=true TMPDIR="$ATSOCKTMP/nowhere" XDG_RUNTIME_DIR= \
  XDG_DATA_HOME="$ATSOCKTMP/xdgdata"
# An EXPLICIT ATUIN_DAEMON__SOCKET_PATH must win outright and probe nothing else. Point it at
# an absent path while a live listener sits on a candidate: the guard must still degrade, or
# the config knob has stopped being authoritative — which would be a worse bug than the one
# this change fixes, since it silently overrides what the user asked for.
ucheck "atuin daemon: an explicit socket path wins outright (candidates are not tried) (#518)" \
  "rm -f '$ATSOCKTMP/xdgrun/atuin.sock'; zmodload zsh/net/socket; zsocket -l '$ATSOCKTMP/xdgrun/atuin.sock'; source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == false && -n \$_CORE_ATUIN_DAEMON_DEGRADED ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock" \
  TMPDIR="$ATSOCKTMP" XDG_RUNTIME_DIR="$ATSOCKTMP/xdgrun" XDG_DATA_HOME="$ATSOCKTMP/xdgdata"

# (e) AUTOSTART — atuin supervises its own daemon there (the no-systemd answer for
#     Alpine/macOS), so an absent socket is EXPECTED, not a fault. Don't disable it — and don't
#     keep re-probing for the life of the shell either: stand down means UNHOOK.
ucheck "atuin daemon: autostart owns the lifecycle, so the guard stands down and unhooks" \
  "source '$TOOLS_FILE'; _core_atuin_daemon_guard; [[ \$ATUIN_DAEMON__ENABLED == true && -z \${precmd_functions[(r)_core_atuin_daemon_guard]} ]]" \
  PATH="$ATBIN:$PATH" XDG_CACHE_HOME="$ATCACHE" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__AUTOSTART=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
# (f) NOT OPTED IN → the guard unhooks PERMANENTLY. The machines that never asked for the daemon
#     must not carry even the throttle's integer compare for the life of the shell. This is a
#     STAND-DOWN, not the one-shot the guard used to be — an opted-in shell now stays hooked on
#     purpose, which is case (g). (This body never sets ATUIN_DAEMON__ENABLED, so it has always
#     exercised the stand-down; only the label was wrong.)
ucheck "atuin daemon: a shell that never opted in unhooks the guard for good" \
  "source '$TOOLS_FILE'; [[ -n \${precmd_functions[(r)_core_atuin_daemon_guard]} ]] && { _core_atuin_daemon_guard; [[ -z \${precmd_functions[(r)_core_atuin_daemon_guard]} ]] }" \
  PATH="$ATBIN:$PATH" XDG_CACHE_HOME="$ATCACHE"
# (g) WATCHDOG, NOT ONE-SHOT — the regression that would silently reintroduce #366. An opted-in
#     shell with a LIVE daemon must KEEP the hook, arm the throttle deadline, and record that it
#     was ever healthy. Without all three the shell reverts to the old behaviour: fine at
#     startup, then blind for the rest of its life.
ucheck "atuin daemon: an opted-in shell with a live daemon KEEPS the guard hooked and arms the window" \
  "zmodload zsh/net/socket
   rm -f '$SANDBOX/wd-live.sock'; zsocket -l '$SANDBOX/wd-live.sock'
   source '$TOOLS_FILE'; _core_atuin_daemon_guard
   [[ \$ATUIN_DAEMON__ENABLED == true && -n \$_CORE_ATUIN_DAEMON_WAS_UP ]] || exit 1
   [[ -n \${precmd_functions[(r)_core_atuin_daemon_guard]} ]] || exit 1
   (( _CORE_ATUIN_DAEMON_NEXT > 0 ))" \
  PATH="$ATBIN:$PATH" XDG_CACHE_HOME="$ATCACHE" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/wd-live.sock"
# (h) THROTTLE — the other half of (g), and what keeps the prompt path honest. Kill the daemon
#     INSIDE the window and probe again: the guard must NOT connect, so the shell stays enabled
#     and undegraded. If this ever goes green→red the throttle is gone and every prompt is paying
#     a connect(2).
ucheck "atuin daemon: a second precmd inside the window does not re-connect (throttled)" \
  "zmodload zsh/net/socket
   rm -f '$SANDBOX/thr.sock'; zsocket -l '$SANDBOX/thr.sock'; LFD=\$REPLY
   source '$TOOLS_FILE'; _core_atuin_daemon_guard
   (( _CORE_ATUIN_DAEMON_NEXT > 0 )) || exit 1
   exec {LFD}>&-                                   # the daemon dies; the stale socket file remains
   [[ -S '$SANDBOX/thr.sock' ]] || exit 1
   _core_atuin_daemon_guard
   [[ \$ATUIN_DAEMON__ENABLED == true && -z \${_CORE_ATUIN_DAEMON_DEGRADED:-} ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/thr.sock"
# (i) MID-SESSION DEATH — the whole point of #366, driven end to end without a sleep: healthy
#     probe, daemon dies, BACK-DATE the deadline to travel past the window, probe again. The
#     shell must degrade, unhook for good, and say so EXACTLY once — that warning is the only
#     signal a session which is already open ever gets.
ucheck "atuin daemon: past the window a mid-session death degrades, warns once and unhooks" \
  "zmodload zsh/net/socket
   rm -f '$SANDBOX/wd.sock' '$SANDBOX/wd.err'; zsocket -l '$SANDBOX/wd.sock'; LFD=\$REPLY
   source '$UI'; source '$TOOLS_FILE'
   _core_atuin_daemon_guard
   [[ -n \$_CORE_ATUIN_DAEMON_WAS_UP ]] || exit 1
   exec {LFD}>&-
   _CORE_ATUIN_DAEMON_NEXT=0                       # time travel: no sleep in this suite, ever
   _core_atuin_daemon_guard 2>'$SANDBOX/wd.err'
   [[ \$ATUIN_DAEMON__ENABLED == false && -n \$_CORE_ATUIN_DAEMON_DEGRADED ]] || exit 1
   [[ -z \${precmd_functions[(r)_core_atuin_daemon_guard]} ]] || exit 1
   grep -q 'atuin daemon' '$SANDBOX/wd.err'" \
  PATH="$ATBIN:$PATH" XDG_CACHE_HOME="$ATCACHE" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/wd.sock"
# (j) SILENT AT STARTUP — the other side of (i), and the assertion that stops a well-meant future
#     change turning this into startup noise on every machine whose daemon simply is not running.
#     A shell ALREADY degraded at its first prompt had nothing change under it, so it must
#     degrade with an EMPTY stderr.
ucheck "atuin daemon: a shell that started with the daemon already down degrades SILENTLY" \
  "rm -f '$SANDBOX/quiet.err'
   source '$UI'; source '$TOOLS_FILE'
   _core_atuin_daemon_guard 2>'$SANDBOX/quiet.err'
   [[ \$ATUIN_DAEMON__ENABLED == false && -n \$_CORE_ATUIN_DAEMON_DEGRADED ]] || exit 1
   [[ -z \${_CORE_ATUIN_DAEMON_WAS_UP:-} ]] || exit 1
   [[ ! -s '$SANDBOX/quiet.err' ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
# (k) CLOCK SKEW, FAIL-SAFE — a deadline further out than one window cannot mean "early", it
#     means the clock moved (backwards NTP step, resume from suspend, or the EPOCHSECONDS/SECONDS
#     fallback changing source mid-shell — they share no epoch). Honouring it would park the
#     watchdog for the length of the jump, SILENTLY, which is the failure this hook exists to
#     end. So the guard must probe anyway.
ucheck "atuin daemon: a deadline beyond one window means the clock moved — probe anyway" \
  "source '$TOOLS_FILE'
   _CORE_ATUIN_DAEMON_NEXT=\$(( \${EPOCHSECONDS:-SECONDS} + 10 * _CORE_ATUIN_DAEMON_INTERVAL ))
   _core_atuin_daemon_guard
   [[ \$ATUIN_DAEMON__ENABLED == false && -n \$_CORE_ATUIN_DAEMON_DEGRADED ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
# (l) THE WINDOW is a real number with a real escape hatch — the knob is what makes a box where
#     connect(2) on that path is NOT cheap (a socket on a networked or wedged FS) tunable without
#     patching Core, and what makes the manual repro take 5s instead of 60.
#     The override is set AFTER sourcing, which is the only test of it worth having: os/<os>.zsh
#     (80) and 99-local.zsh (99) load after 00-tools.zsh, so that is where a per-machine knob is
#     actually written. Setting it BEFORE the source — the obvious way to write this — passes
#     even when the guard reads the env at source time and therefore ignores every real override.
ucheck "atuin daemon: the probe window defaults to 60s and the first precmd is due immediately" \
  "source '$TOOLS_FILE'; (( _CORE_ATUIN_DAEMON_INTERVAL == 60 && _CORE_ATUIN_DAEMON_NEXT == 0 ))"
ucheck "atuin daemon: CORE_ATUIN_PROBE_INTERVAL set by a LATER fragment still overrides the window" \
  "source '$TOOLS_FILE'
   CORE_ATUIN_PROBE_INTERVAL=5           # as os/<os>.zsh or 99-local.zsh would: after 00, not before
   _core_atuin_daemon_guard
   (( _CORE_ATUIN_DAEMON_INTERVAL == 5 ))" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
# (m) \$REPLY CROSS-TALK — `local REPLY` inside the guard was a nicety when it ran once before the
#     first prompt. As a persistent hook it runs between every pair of commands, where
#     read/vared/zsocket/completion all live in \$REPLY, so dropping it would produce an
#     intermittent, unreproducible bug. Pin it.
ucheck "atuin daemon: the guard does not clobber the caller's \$REPLY" \
  "source '$TOOLS_FILE'; REPLY=mine; _core_atuin_daemon_guard; [[ \$REPLY == mine ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
# (n)-(p) \$? TRANSPARENCY, on all four exit paths. As a one-shot the guard could return whatever
#     it liked: it ran once, before the first prompt, and unhooked. As a PERSISTENT precmd it sits
#     in the hook list for the life of the shell, so any precmd an OS (80) or host (99) fragment
#     appends AFTER it would see the guard's status instead of the user's command — a prompt that
#     never shows a failure again, and nothing in Core would notice. That is why the guard opens
#     with `local -i _rc=\$?` (before `emulate -L zsh`, which resets it) and returns \$_rc from
#     every exit. Four paths, so four exits: throttled, healthy, degrade, stand-down.
ucheck "atuin daemon: \$? survives the guard on the healthy and throttled paths" \
  "zmodload zsh/net/socket
   rm -f '$SANDBOX/rc-live.sock'; zsocket -l '$SANDBOX/rc-live.sock'
   source '$TOOLS_FILE'
   false; _core_atuin_daemon_guard; (( \$? == 1 )) || exit 1   # healthy probe: arms the window
   (( _CORE_ATUIN_DAEMON_NEXT > 0 )) || exit 1
   false; _core_atuin_daemon_guard; (( \$? == 1 )) || exit 1   # throttled: the gate's early return
   true;  _core_atuin_daemon_guard; (( \$? == 0 ))             # and a success survives too" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/rc-live.sock"
ucheck "atuin daemon: \$? survives the guard on the degrade path" \
  "source '$UI'; source '$TOOLS_FILE'
   false; _core_atuin_daemon_guard; (( \$? == 1 )) || exit 1
   [[ -n \$_CORE_ATUIN_DAEMON_DEGRADED ]]" \
  ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SANDBOX/absent-atuin.sock"
ucheck "atuin daemon: \$? survives the guard on the stand-down path" \
  "source '$TOOLS_FILE'; false; _core_atuin_daemon_guard; (( \$? == 1 ))"

# atuin/config.toml must NOT write `enabled`/`autostart` into [daemon]. atuin layers the
# config FILE after the Environment source (settings.rs), so the later file source wins and
# any key written here SHADOWS its ATUIN_* override — which silently disabled the entire
# per-machine opt-in the OS layers rely on (verified against 18.19.0: zero connect() calls
# to the socket with the key present, one with it absent). Upstream's own defaults are
# already false/false, so leaving them unset ships the same OFF default AND lets the
# override through. A static assertion because the behavioural proof needs an atuin binary,
# which CI does not have.
# PARSE the TOML rather than pattern-match its text. Grep can only ever cover the spellings
# someone thought of: a `[daemon]` table, the dotted `daemon.enabled = false`, the inline
# table `daemon = { enabled = false }`, and `daemon . enabled = false` (TOML permits
# whitespace around the dots) all deserialize to the same key, and a regex that catches two
# of them reports green on the other two. What matters is the key atuin ends up resolving,
# so ask the parser. `tomllib` is stdlib since 3.11 and is already how audit-core.sh's
# config gate works; the graceful skip mirrors that gate too.
if [[ ! -f "$HERE/atuin/config.toml" ]]; then
  skip "atuin config: daemon override check (no atuin/config.toml)"
elif ! have python3 || ! python3 -c 'import tomllib' 2>/dev/null; then
  skip "atuin config: daemon override check (python3 tomllib unavailable)"
else
  _atd="$(python3 -c '
import tomllib, sys
d = tomllib.load(open(sys.argv[1], "rb")).get("daemon") or {}
print(" ".join(f"{k}={d[k]!r}" for k in ("enabled", "autostart") if k in d))
' "$HERE/atuin/config.toml" 2>/dev/null)" || _atd="__PARSE_FAILED__"
  if [[ "$_atd" == "__PARSE_FAILED__" ]]; then
    # Distinct from "key present": a file that will not parse is a different defect, owned by
    # audit-core.sh's config gate. Still red here — this assertion cannot vouch for a file it
    # could not read, and failing closed is the only safe reading.
    fail "atuin config: atuin/config.toml does not parse as TOML — cannot verify the daemon keys"
  elif [[ -z "$_atd" ]]; then
    pass "atuin config: daemon.enabled/autostart absent from the parsed TOML (ATUIN_* override not shadowed)"
  else
    fail "atuin config: parsed TOML sets daemon $_atd — this shadows the ATUIN_DAEMON__* override and disables the opt-in"
  fi
fi

# maint.zsh: _maint_scheduler must always resolve to a REAL scheduler token, never empty
# or garbage. With systemctl absent (isolated PATH) and crontab present as the fallback,
# it lands on cron (Linux/Alpine) or launchd (macOS, OSTYPE-driven) — both valid — so the
# assertion is the same green on every CI userland while still exercising the full ladder.
_pm_only crontab
ucheck "maint: _maint_scheduler resolves to a valid scheduler" \
  "source '$UI'; source '$MNT'; [[ \$(_maint_scheduler) == (systemd|launchd|cron) ]]" \
  PATH="$PMBIN"
