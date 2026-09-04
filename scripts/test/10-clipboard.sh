# scripts/test/10-clipboard.sh
# clipboard detection ladder (bin/clip, bin/clip-paste)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── clipboard detection ladder (bin/clip / bin/clip-paste) ────────────────────
# bin/clip is the single highest-fan-out runtime artifact in Core — used by zsh
# (pbcopy alias), tmux (copy-pipe), AND nvim (clipboard provider), across all nine OS
# repos — yet its WSL→macOS→Wayland→X11→OSC 52 ladder had no test, only `bash -n`. We drive
# the ladder HERMETICALLY: PATH is pointed at a fake bin holding a stub `uname` that
# reports the OS we want, a stub `grep` that answers the /proc/version probe, and
# stub backends that print a marker instead of touching a real clipboard — then we
# assert the RIGHT backend was exec'd. PATH is the fake dir ONLY (a real `bash`
# symlink keeps the `#!/usr/bin/env bash` shebang resolvable), so backend probing is
# fully deterministic regardless of what the host happens to have installed. Pure
# bash — runs with no zsh, exactly where bin/clip most needs to work.
hdr "clipboard detection ladder (bin/clip, bin/clip-paste)"
CLIP="$HERE/bin/clip"
CLIPPASTE="$HERE/bin/clip-paste"
CBIN="$SANDBOX/clipbin"
_real_bash="$(command -v bash)"
_real_tr="$(command -v tr)"

_stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$CBIN/$1"
  chmod +x "$CBIN/$1"
}
# Fresh fake bin + cleared env before each scenario. `bash` is symlinked so the
# shebang resolves under the stripped PATH; `uname` defaults to "Linux" and Darwin
# cases override it. The WSL probe now reads /proc/version via a bash builtin (no
# grep fork — see bin/clip), so we point CLIP_PROC_VERSION at a NON-WSL fixture; the
# WSL cases either set WSL_DISTRO_NAME or overwrite that fixture with a microsoft one.
_clip_reset() {
  rm -rf "$CBIN"
  mkdir -p "$CBIN"
  # TMUX and CLIP_SENSITIVE are inherited from the shell running the audit — from inside a
  # tmux pane, an "outside tmux" scenario would otherwise land in clip's sensitive tmux arm.
  # Scenarios that need them pass them explicitly on the command line.
  unset WSL_DISTRO_NAME WAYLAND_DISPLAY DISPLAY TMUX CLIP_SENSITIVE
  ln -s "$_real_bash" "$CBIN/bash"
  _stub uname 'echo Linux'
  printf 'Linux version 6.1.0-0 (gcc) #1 SMP\n' >"$CBIN/procversion"
  export CLIP_PROC_VERSION="$CBIN/procversion"
  # Point the OSC 52 fallback at a path that cannot be opened, so a scenario which
  # reaches it fails LOUDLY instead of quietly writing to the runner's real terminal
  # (or accidentally passing because CI happens to have no tty). The OSC 52 cases
  # below override this with a real file.
  export CLIP_TTY="$CBIN/no-such-dir/tty"
}
# Assert prog's stdout is exactly the marker the chosen backend prints.
_clip_is() { # _clip_is <label> <prog> <expected>
  local out
  out="$(printf 'payload' | PATH="$CBIN" "$2" 2>/dev/null)"
  if [[ "$out" == "$3" ]]; then pass "$1"; else fail "$1 (got '${out}', want '${3}')"; fi
}
# Assert prog exits non-zero — the no-backend-found path.
_clip_fails() { # _clip_fails <label> <prog>
  if printf 'payload' | PATH="$CBIN" "$2" >/dev/null 2>&1; then
    fail "$1 (expected non-zero exit)"
  else pass "$1"; fi
}

# clip (copy) — each scenario leaves ONLY the intended backend reachable.
_clip_reset
export WSL_DISTRO_NAME=Ubuntu
_stub clip.exe 'echo WSL'
_clip_is "clip → clip.exe when WSL_DISTRO_NAME set" "$CLIP" WSL
unset WSL_DISTRO_NAME
_clip_reset
# WSL with NO WSL_DISTRO_NAME — detection must come from /proc/version content.
printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' >"$CBIN/procversion"
_stub clip.exe 'echo WSL'
_clip_is "clip → clip.exe via /proc/version (no WSL_DISTRO_NAME)" "$CLIP" WSL
_clip_reset
_stub uname 'echo Darwin'
_stub pbcopy 'echo MAC'
_clip_is "clip → pbcopy on Darwin" "$CLIP" MAC
_clip_reset
export WAYLAND_DISPLAY=wayland-0
_stub wl-copy 'echo WL'
_clip_is "clip → wl-copy under Wayland" "$CLIP" WL
unset WAYLAND_DISPLAY
_clip_reset
# DISPLAY is required, not incidental: xclip/xsel cannot talk to an X server without
# one, and the guard is what lets a box that merely HAS xclip installed (a common
# desktop dependency) fall through to OSC 52 over ssh instead of exec'ing a doomed
# binary. See the ladder's own comment in bin/clip.
export DISPLAY=:0
_stub xclip 'echo XCLIP'
_clip_is "clip → xclip on X11" "$CLIP" XCLIP
_clip_reset
export DISPLAY=:0
_stub xsel 'echo XSEL'
_clip_is "clip → xsel when xclip absent" "$CLIP" XSEL
_clip_reset
# The regression that motivated the guard: xclip present, no DISPLAY. This MUST NOT
# exec xclip — it must fall past it. The stub writes a marker file so we can prove the
# backend never ran, rather than inferring it from stdout.
_stub xclip "echo RAN >'$CBIN/xclip-ran'"
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
export CLIP_TTY="$CBIN/tty-x11"
if printf 'payload' | PATH="$CBIN" "$CLIP" 2>/dev/null && [[ ! -e "$CBIN/xclip-ran" ]]; then
  pass "clip: xclip installed but no DISPLAY falls through to OSC 52 (does not exec a doomed xclip)"
else
  fail "clip: xclip was exec'd with no DISPLAY, or the OSC 52 fallback did not run"
fi
_clip_reset
# base64/tr must be present, or `clip` dies during ENCODING and never reaches the tty
# write — leaving this assertion green even if the write-error handling is broken. It
# would then be testing "the fallback failed", not "the fallback failed FOR THE REASON
# THIS TEST NAMES". CLIP_TTY still points at _clip_reset's unopenable path.
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_fails "clip exits non-zero with no backend and no terminal" "$CLIP"

# OSC 52 fallback — the branch that makes `clip` work at all on a headless ssh box.
# Asserted on the WIRE FORMAT, not just "did something happen": a terminal ignores a
# malformed sequence silently, so a test that only checked for output would pass while
# the user's copy vanished. base64/tr are symlinked in because the fallback shells out
# to them under the stripped PATH.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
export CLIP_TTY="$CBIN/tty-osc52"
_osc_payload='hello osc52'
if printf '%s' "$_osc_payload" | PATH="$CBIN" "$CLIP" 2>/dev/null; then
  # \033]52;c;<base64>\a  — selection `c`, BEL-terminated.
  # `$(cat …)` strips ALL trailing newlines, which would normalise a stray LF after the
  # BEL right out of the comparison — so a regression that emitted
  # `ESC ]52;c;<b64> BEL LF` would sail through a test whose whole job is the exact wire
  # format. The X sentinel preserves the file's trailing bytes; strip it after.
  _osc_raw="$(cat "$CBIN/tty-osc52"; printf X)"
  _osc_raw="${_osc_raw%X}"
  _osc_b64="${_osc_raw#$'\033']52;c;}"
  _osc_b64="${_osc_b64%$'\a'}"
  if [[ "$_osc_raw" == $'\033']52\;c\;*$'\a' ]]; then
    pass "clip: OSC 52 fallback emits a BEL-terminated \\033]52;c; sequence"
  else
    fail "clip: OSC 52 framing wrong (got: $(printf '%q' "$_osc_raw"))"
  fi
  if [[ "$(printf '%s' "$_osc_b64" | base64 -d 2>/dev/null)" == "$_osc_payload" ]]; then
    pass "clip: OSC 52 payload base64-decodes back to exactly what was piped in"
  else
    fail "clip: OSC 52 payload did not round-trip"
  fi
  # A newline anywhere in the base64 terminates the escape early and the terminal
  # copies a truncated value — which is why the encoder pipes through `tr -d`, and
  # why `base64 -w0` (GNU-only) is not used.
  #
  # The payload has to be LONG to test this. GNU base64 wraps at 76 columns, so it
  # only emits a newline once the encoding exceeds that — i.e. past ~57 bytes of
  # input. A short multi-line string encodes to one line either way, and an assertion
  # built on one passes just as happily with the `tr` removed. (Confirmed by deleting
  # it: the short-input version of this test did not notice.) 300 bytes forces
  # several wraps on any implementation that wraps at all.
  _osc_long="$(printf 'the quick brown fox jumps over the lazy dog %.0s' 1 2 3 4 5 6 7)"
  printf '%s\n%s\n' "$_osc_long" "$_osc_long" | PATH="$CBIN" "$CLIP" 2>/dev/null
  _osc_multi="$(cat "$CBIN/tty-osc52"; printf X)"
  if [[ "${_osc_multi%X}" != *$'\n'* ]]; then
    pass "clip: OSC 52 payload stays one unbroken line for multi-line input"
  else
    fail "clip: OSC 52 payload contains a newline — the sequence would be truncated"
  fi
else
  fail "clip: OSC 52 fallback did not run with no backend and a writable CLIP_TTY"
fi
# The escape must go to the terminal, never stdout: `clip` is used in pipelines and as
# nvim's provider, so anything on stdout corrupts the caller's data.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
export CLIP_TTY="$CBIN/tty-stdout"
_osc_stdout="$(printf 'payload' | PATH="$CBIN" "$CLIP" 2>/dev/null)"
if [[ -z "$_osc_stdout" && -s "$CBIN/tty-stdout" ]]; then
  pass "clip: OSC 52 writes to the tty and leaves stdout empty"
else
  fail "clip: OSC 52 leaked to stdout (got '$_osc_stdout')"
fi
unset _osc_payload _osc_raw _osc_b64 _osc_stdout _osc_long _osc_multi

# ── the tmux copy-pipe case (#525) ───────────────────────────────────────────
# Every OSC 52 case above points CLIP_TTY at a writable FILE, so all of them exercise a
# clip that has somewhere to write. The one binding that actually names `clip` does not:
#
#   tmux.reset.conf:  bind -T copy-mode-vi y  send -X copy-pipe-and-cancel "clip"
#
# `copy-pipe` runs its command through tmux's job_run(), a child of the daemonized server
# — setsid'd, no controlling terminal, stderr to /dev/null. So /dev/tty fails to OPEN
# (ENXIO; it still exists and still passes a -w permission test, which is why clip attempts
# the write rather than probing), the error goes nowhere, and clip exits 1 in silence.
#
# `setsid` is the faithful reproduction of that shape, and the only one — a redirected or
# closed stdin does not detach the controlling terminal. Absent on macOS, so this skips
# there rather than pretending to cover it.
if ! have setsid; then
  skip "clip: tmux copy-pipe fallback (setsid not available — Linux-only reproduction)"
else
  _clip_reset
  ln -s "$_real_tr" "$CBIN/tr"
  ln -s "$(command -v base64)" "$CBIN/base64"
  # A tmux stub that records the call and captures what was piped to it, so the assertion
  # is "the payload arrived intact", not merely "something invoked tmux".
  _tmux_log="$CBIN/tmux.calls"
  # The stub touches a .done marker AFTER the payload is fully written. Waiting on the
  # payload file itself would race: `cat >file` CREATES it empty and fills it after, so a
  # reader that waits for existence can read nothing and call it corruption.
  # `cat` by ABSOLUTE path: the stub inherits the stripped PATH="$CBIN", where cat does
  # not exist. A bare `cat` there fails AFTER the shell has already created the redirect
  # target, leaving a 0-byte payload that reads exactly like a corrupted copy.
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nif [ "$1" = load-buffer ]; then %s >"%s.payload"; : >"%s.done"; exit 0; fi\nexit 1\n' \
    "$_tmux_log" "$(command -v cat)" "$_tmux_log" "$_tmux_log" >"$CBIN/tmux"
  chmod +x "$CBIN/tmux"

  _clip_pipe_out="$(printf 'yanked\ttext\n' \
    | setsid env PATH="$CBIN" TMUX=/tmp/fake,1,0 CLIP_PROC_VERSION="$CBIN/procversion" \
        "$_real_bash" "$CLIP" </dev/stdin 2>&1)"
  _clip_pipe_rc=$?
  # setsid detaches, so the write to the log races our read by a few ms.
  _cp_i=0
  while [ ! -f "$_tmux_log.done" ] && [ "$_cp_i" -lt 50 ]; do sleep 0.1; _cp_i=$((_cp_i + 1)); done

  if [ "$_clip_pipe_rc" -eq 0 ] && grep -q 'load-buffer -w -' "$_tmux_log" 2>/dev/null; then
    pass "clip: with no controlling terminal inside tmux, falls back to tmux load-buffer -w"
  else
    fail "clip: the tmux copy-pipe path did not reach load-buffer (rc=$_clip_pipe_rc)"
    [ -n "$_clip_pipe_out" ] && printf '%s\n' "$_clip_pipe_out" | sed 's/^/    /' >&2
  fi

  # The payload must survive the base64 round-trip EXACTLY — clip reconstructs the raw
  # bytes by decoding, so a decode that mangled tabs or ate the trailing newline would be
  # a silent corruption of every yank taken this way.
  if [ -f "$_tmux_log.payload" ] \
    && [ "$(od -An -c <"$_tmux_log.payload" | tr -s ' ')" = "$(printf 'yanked\ttext\n' | od -An -c | tr -s ' ')" ]; then
    pass "clip: the tmux fallback payload round-trips byte-for-byte (tabs and trailing newline)"
  else
    fail "clip: the tmux fallback corrupted the payload"
    [ -f "$_tmux_log.payload" ] && od -c "$_tmux_log.payload" | sed 's/^/    /' >&2
  fi

  # Outside tmux the same detached shape must still fail LOUDLY. A fallback that swallowed
  # this would hide a genuinely missing backend, which is the failure the OSC 52 work in
  # v4.13.0 set out to make visible.
  _clip_reset
  ln -s "$_real_tr" "$CBIN/tr"
  ln -s "$(command -v base64)" "$CBIN/base64"
  if printf 'x' | setsid env PATH="$CBIN" CLIP_PROC_VERSION="$CBIN/procversion" \
      "$_real_bash" "$CLIP" </dev/stdin >/dev/null 2>&1; then
    fail "clip: detached with no tmux and no backend should exit non-zero"
  else
    pass "clip: detached with no tmux and no backend still fails loudly (no silent success)"
  fi
  unset _clip_pipe_out _clip_pipe_rc _tmux_log _cp_i
fi

# ── --sensitive: a TOTP must not be left in a tmux paste buffer (#690) ────────
# optoken pipes a live TOTP through `clip --sensitive`. Under tmux with Core's own
# `set-clipboard on`, the plain OSC 52 write leaves the code in a tmux paste buffer that
# anything on the socket can `show-buffer` — so the sensitive arm must never write a plain
# OSC 52 to the pane's tty inside tmux. Two ways out, both asserted on the wire: DCS
# passthrough when the pane allows it (no buffer ever exists), else a NAMED transient buffer
# that is deleted in the same breath. And the default path — nvim, tmux copy-pipe, pbcopy —
# must be byte-for-byte what it was, flag or no flag.
#
# A tmux stub (named apart from U11's `_tmux_stub`, which stubs the status scripts' tools)
# that answers `show-options … allow-passthrough` with a fixed value, captures
# what load-buffer was fed, logs every call in order, and exits as told on delete-buffer.
# Synchronous (no setsid — optoken runs in a pane that HAS a tty), so no race to wait out.
# A third argument makes load-buffer SIGTERM its parent — clip — after taking the payload,
# which is the "interrupted between the two commands" shape.
_clip_tmux_stub() { # _clip_tmux_stub <allow-passthrough value> [delete-buffer exit code] [interrupt]
  _tmux_log="$CBIN/tmux.calls"
  rm -f "$_tmux_log" "$_tmux_log.payload"
  cat >"$CBIN/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$_tmux_log"
case "\$1" in
  show-options) printf '%s\n' '$1' ;;
  load-buffer) $(command -v cat) >"$_tmux_log.payload"${3:+; kill -TERM \$PPID} ;;
  delete-buffer) exit ${2:-0} ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$CBIN/tmux"
}
_sens_payload='123456'

# 1. Outside tmux the flag is a no-op on the wire: the same bytes reach the tty.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
export CLIP_TTY="$CBIN/tty-plain"
printf '%s' "$_sens_payload" | PATH="$CBIN" "$CLIP" 2>/dev/null
export CLIP_TTY="$CBIN/tty-sens"
if printf '%s' "$_sens_payload" | PATH="$CBIN" "$CLIP" --sensitive 2>/dev/null \
  && core_files_identical "$CBIN/tty-plain" "$CBIN/tty-sens"; then
  pass "clip --sensitive: outside tmux, emits exactly the bytes the default path emits"
else
  fail "clip --sensitive: outside tmux diverged from the default path"
fi

# 2. The DEFAULT pane path under tmux is untouched: with a writable tty the same plain
#    OSC 52 bytes reach it as outside tmux, and tmux is never invoked (no probe, no
#    buffer). The copy-pipe shape — no controlling terminal — still takes `load-buffer -w`,
#    asserted above; that path is deliberately not sensitive.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_tmux_stub off
export CLIP_TTY="$CBIN/tty-notmux"
printf '%s' "$_sens_payload" | PATH="$CBIN" "$CLIP" 2>/dev/null
export CLIP_TTY="$CBIN/tty-default"
if printf '%s' "$_sens_payload" | PATH="$CBIN" TMUX=/tmp/fake,1,0 "$CLIP" 2>/dev/null \
  && core_files_identical "$CBIN/tty-notmux" "$CBIN/tty-default" \
  && [[ "$(cat "$CBIN/tty-default")" == $'\033']52\;c\;*$'\a' ]] && [[ ! -e "$_tmux_log" ]]; then
  pass "clip: the default pane path under tmux (writable tty) still writes a plain OSC 52 and never calls tmux"
else
  fail "clip: the default pane path under tmux changed (tmux calls: $(tr '\n' ';' <"$_tmux_log" 2>/dev/null))"
fi

# 3. --sensitive under tmux, passthrough off: no plain OSC 52 on the tty; a NAMED buffer
#    is loaded with -w, then deleted, in that order, with the same name; payload intact;
#    the transient-buffer fact is on stderr; exit 0.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_tmux_stub off
export CLIP_TTY="$CBIN/tty-sens-off"
: >"$CLIP_TTY"
_sens_err="$(printf '%s' "$_sens_payload" | PATH="$CBIN" TMUX=/tmp/fake,1,0 "$CLIP" --sensitive 2>&1 >/dev/null)"
_sens_rc=$?
_sens_load="$(grep '^load-buffer' "$_tmux_log" 2>/dev/null || true)"
_sens_name="${_sens_load#load-buffer -w -b }"; _sens_name="${_sens_name% -}"
if [[ "$_sens_rc" -eq 0 && ! -s "$CLIP_TTY" && "$_sens_load" == "load-buffer -w -b clip-sensitive-"*" -" ]] \
  && [[ "$(grep -n '^load-buffer\|^delete-buffer' "$_tmux_log" | tr '\n' ' ')" == 2:load-buffer*" 3:delete-buffer -b $_sens_name " ]]; then
  pass "clip --sensitive: under tmux without passthrough, loads a NAMED buffer with -w and deletes that same buffer at once"
else
  fail "clip --sensitive: tmux transient-buffer arm wrong (rc=$_sens_rc, tty=$(wc -c <"$CLIP_TTY")B, calls: $(tr '\n' ';' <"$_tmux_log" 2>/dev/null))"
fi
if [[ "$(cat "$_tmux_log.payload" 2>/dev/null)" == "$_sens_payload" ]]; then
  pass "clip --sensitive: the transient buffer received the payload byte-for-byte"
else
  fail "clip --sensitive: transient buffer payload wrong (got '$(cat "$_tmux_log.payload" 2>/dev/null)')"
fi
if [[ "$_sens_err" == *"tmux buffer"* && "$_sens_err" == *"deleted"* ]]; then
  pass "clip --sensitive: says on stderr that the copy went through a (deleted) tmux buffer"
else
  fail "clip --sensitive: stderr does not disclose the transient buffer (got '$_sens_err')"
fi

# 4. CLIP_SENSITIVE=1 is the same switch as the flag.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_tmux_stub off
export CLIP_TTY="$CBIN/tty-sens-env"
: >"$CLIP_TTY"
if printf '%s' "$_sens_payload" | PATH="$CBIN" TMUX=/tmp/fake,1,0 CLIP_SENSITIVE=1 "$CLIP" >/dev/null 2>&1 \
  && [[ ! -s "$CLIP_TTY" ]] && grep -q '^delete-buffer -b clip-sensitive-' "$_tmux_log"; then
  pass "clip: CLIP_SENSITIVE=1 selects the sensitive arm exactly like --sensitive"
else
  fail "clip: CLIP_SENSITIVE=1 did not select the sensitive arm"
fi

# 5. --sensitive under tmux, passthrough on: the OSC 52 goes to the tty wrapped in a DCS
#    passthrough (ESC doubled inside, ST-terminated), so tmux's parser never sees it and no
#    buffer is ever created — tmux is asked about passthrough and nothing else.
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_tmux_stub on
export CLIP_TTY="$CBIN/tty-sens-on"
_dcs_pre=$'\033Ptmux;\033\033]52;c;'
_dcs_suf=$'\a\033\\'
if printf '%s' "$_sens_payload" | PATH="$CBIN" TMUX=/tmp/fake,1,0 "$CLIP" --sensitive 2>/dev/null; then
  _dcs_raw="$(cat "$CLIP_TTY"; printf X)"; _dcs_raw="${_dcs_raw%X}"
  _dcs_b64="${_dcs_raw#"$_dcs_pre"}"; _dcs_b64="${_dcs_b64%"$_dcs_suf"}"
  if [[ "$_dcs_raw" == "$_dcs_pre"*"$_dcs_suf" && "$(printf '%s' "$_dcs_b64" | base64 -d 2>/dev/null)" == "$_sens_payload" ]]; then
    pass "clip --sensitive: with allow-passthrough on, wraps the OSC 52 in a DCS passthrough (ESC doubled, ST-terminated)"
  else
    fail "clip --sensitive: DCS passthrough framing wrong (got: $(printf '%q' "$_dcs_raw"))"
  fi
  if ! grep -q '^load-buffer\|^delete-buffer' "$_tmux_log"; then
    pass "clip --sensitive: with passthrough, no tmux buffer is ever created"
  else
    fail "clip --sensitive: created a tmux buffer despite passthrough (calls: $(tr '\n' ';' <"$_tmux_log"))"
  fi
else
  fail "clip --sensitive: passthrough arm exited non-zero"
fi

# 6. A buffer that cannot be deleted is a FAILURE with the fix-it command, not a "sent".
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_tmux_stub off 1
export CLIP_TTY="$CBIN/tty-sens-stuck"
_sens_err="$(printf '%s' "$_sens_payload" | PATH="$CBIN" TMUX=/tmp/fake,1,0 "$CLIP" --sensitive 2>&1 >/dev/null)"
if [[ $? -ne 0 && "$_sens_err" == *"tmux delete-buffer -b clip-sensitive-"* ]]; then
  pass "clip --sensitive: a transient buffer that survives delete-buffer is exit 1, naming the buffer to delete"
else
  fail "clip --sensitive: an undeletable transient buffer was not reported as a failure (got '$_sens_err')"
fi

# 6b. A signal in the instant between load-buffer and delete-buffer must not strand the
#     buffer: the trap deletes it on the way out, and clip exits non-zero (no "sent").
_clip_reset
ln -s "$_real_tr" "$CBIN/tr"
ln -s "$(command -v base64)" "$CBIN/base64"
_clip_tmux_stub off 0 interrupt
export CLIP_TTY="$CBIN/tty-sens-int"
printf '%s' "$_sens_payload" | PATH="$CBIN" TMUX=/tmp/fake,1,0 "$CLIP" --sensitive >/dev/null 2>&1
_sens_rc=$?
if [[ "$_sens_rc" -ne 0 ]] && [[ "$(grep -c '^delete-buffer -b clip-sensitive-' "$_tmux_log" 2>/dev/null)" -eq 1 ]]; then
  pass "clip --sensitive: SIGTERM between load-buffer and delete-buffer still deletes the buffer (trap) and exits non-zero"
else
  fail "clip --sensitive: an interrupted transient buffer was stranded or reported as success (rc=$_sens_rc, calls: $(tr '\n' ';' <"$_tmux_log" 2>/dev/null))"
fi

# 7. An unknown argument is refused (exit 2) before anything is read or written.
_clip_reset
export CLIP_TTY="$CBIN/tty-badarg"
printf 'x' | PATH="$CBIN" "$CLIP" --bogus >/dev/null 2>&1
_sens_rc=$?
if [[ "$_sens_rc" -eq 2 && ! -e "$CLIP_TTY" ]]; then
  pass "clip: an unknown argument is refused with exit 2 and touches nothing"
else
  fail "clip: unknown-argument exit status or side effect wrong (rc=$_sens_rc)"
fi
unset _sens_payload _sens_err _sens_rc _sens_load _sens_name _dcs_pre _dcs_suf _dcs_raw _dcs_b64 _tmux_log

# clip-paste (paste) — mirror ladder; the WSL leg also strips the CR powershell adds.
_clip_reset
export WSL_DISTRO_NAME=Ubuntu
ln -s "$_real_tr" "$CBIN/tr"
_stub powershell.exe 'printf "WSLPASTE\r"'
_clip_is "clip-paste → powershell + CR-strip on WSL" "$CLIPPASTE" WSLPASTE
unset WSL_DISTRO_NAME
_clip_reset
# WSL detected from /proc/version alone (no WSL_DISTRO_NAME).
printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' >"$CBIN/procversion"
ln -s "$_real_tr" "$CBIN/tr"
_stub powershell.exe 'printf "WSLPASTE\r"'
_clip_is "clip-paste → powershell via /proc/version (no WSL_DISTRO_NAME)" "$CLIPPASTE" WSLPASTE
_clip_reset
_stub uname 'echo Darwin'
_stub pbpaste 'echo MAC'
_clip_is "clip-paste → pbpaste on Darwin" "$CLIPPASTE" MAC
_clip_reset
export WAYLAND_DISPLAY=wayland-0
_stub wl-paste 'echo WL'
_clip_is "clip-paste → wl-paste under Wayland" "$CLIPPASTE" WL
unset WAYLAND_DISPLAY
_clip_reset
export DISPLAY=:0
_stub xclip 'echo XCLIP'
_clip_is "clip-paste → xclip -o on X11" "$CLIPPASTE" XCLIP
_clip_reset
# No OSC 52 mirror here, deliberately: reading the clipboard over OSC 52 means querying
# the terminal and waiting for a reply that most terminals refuse to send, so clip-paste
# still fails — loudly — where clip now succeeds. bin/clip-paste's header explains why,
# and the asymmetry is intentional rather than an oversight.
_clip_fails "clip-paste exits non-zero with no backend (no OSC 52 read path)" "$CLIPPASTE"

