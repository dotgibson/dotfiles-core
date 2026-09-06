# scripts/test/85-escalation.sh
# escalation + failure tally (blib_resolve_su / blib_priv / blib_note_fail)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── escalation + failure tally (lib/bootstrap-lib.sh) ─────────────────────────
# The provisioning half of the bootstrap scaffold: blib_resolve_su picks the escalator,
# blib_priv runs a command through it, blib_user_bindirs_on_path stops the presence guards
# lying, and blib_note_fail/blib_failures_report make a half-provisioned box say so. All
# pure bash — no package manager, no network, no privileges — so it runs everywhere.
#
# Each of these encodes a real fresh-machine failure: a hard-coded `sudo` that exited 127
# on a container, a PATH-only guard that rebuilt every Rust crate on every run, and ~20
# `|| true` steps that still reported "bootstrap complete".
hdr "escalation + failure tally (blib_resolve_su / blib_priv / blib_note_fail)"
# NB: lib/bootstrap-lib.sh is deliberately NOT re-sourced here. Earlier fragments already
# source it at file scope, and its `_CORE_BOOTSTRAP_LIB_SH` re-entry guard makes a repeat
# `source` a runtime no-op regardless. It is not free for `shellcheck -x` though: a third
# source re-reads the lib's `${XDG_STATE_HOME:-…}` expansions AFTER the v4-migration arm's subshell
# assignment of that same variable, which is enough to trip SC2030/SC2031 on that arm's
# otherwise untouched line 2215.

# An explicitly-set BLIB_SU always wins — INCLUDING an empty one, which is the "already
# root / run directly" contract bootstrap-test.yml depends on. A resolver testing
# emptiness instead of set-ness would silently re-add sudo in CI.
_su_after() { (
  eval "$1"
  blib_resolve_su >/dev/null 2>&1
  printf '%s' "${BLIB_SU-UNSET}"
); }
if [[ "$(_su_after 'BLIB_SU=')" == "" ]]; then pass "blib_resolve_su: an explicit empty BLIB_SU is preserved"; else fail "blib_resolve_su clobbered an explicit BLIB_SU= (would re-add sudo as root)"; fi
if [[ "$(_su_after 'BLIB_SU=doas')" == "doas" ]]; then pass "blib_resolve_su: an explicit BLIB_SU=doas is preserved"; else fail "blib_resolve_su clobbered BLIB_SU=doas"; fi
# `command -v` also reports aliases, builtins and FUNCTIONS, so an exported `sudo()` makes
# it print the bare word `sudo`. Recording that defeats the absolute-path pinning (a bare
# name is re-resolved at every call) and could hand privileged execution to the function.
if [[ "$(id -u)" -ne 0 ]]; then
  # shellcheck disable=SC2030,SC2031,SC2123,SC2317,SC2329  # emptying PATH and defining a
  # shadowing `sudo` function are both the POINT here; the function is reached via
  # `command -v` and never called, which is why BOTH unreachability codes are suppressed.
  # SC2317 alone used to cover it; 0.10 split "this function is never invoked" out into
  # SC2329, so the older list went red on every audit leg over an info-level finding.
  _su_fn="$( unset BLIB_SU; PATH="$SANDBOX/emptybin"
    sudo() { :; }
    blib_resolve_su >/dev/null 2>&1
    printf '%s' "$BLIB_SU" )"
  if [[ -z "$_su_fn" ]]; then pass "blib_resolve_su ignores a shell FUNCTION named sudo"; else fail "blib_resolve_su recorded a non-executable [$_su_fn]"; fi
else
  skip "blib_resolve_su function-shadowing case (suite is running as root)"
fi

# With no escalator on PATH and not root, --require must FAIL (rc 1) rather than hand back
# a broken escalator; without --require it must SUCCEED (links-only needs no privileges).
mkdir -p "$SANDBOX/emptybin"
# shellcheck disable=SC2123  # emptying PATH is the POINT: it hides sudo/doas (and id)
_su_none() { ( unset BLIB_SU; PATH="$SANDBOX/emptybin"; blib_resolve_su "$@" >/dev/null 2>&1 ); }
if [[ "$(id -u)" -ne 0 ]]; then
  if _su_none --require; then fail "blib_resolve_su --require succeeded with no escalator and no root"; else pass "blib_resolve_su --require fails when there is no escalator"; fi
  if _su_none; then pass "blib_resolve_su (no --require) succeeds — links-only needs no privileges"; else fail "blib_resolve_su without --require must not fail"; fi
else
  # The MINIMAL-ROOT contract, and the only leg that can test it: as root with no id, sudo
  # or doas reachable, --require must SUCCEED with an empty BLIB_SU, because root needs no
  # escalator. This is exactly what $EUID buys — the previous `id -u` probe returned "" on a
  # PATH with no `id`, concluded "not root", and failed --require on the minimal container
  # this scaffold exists to serve. Non-root legs cannot reach the branch, so without this
  # case the regression ships unseen (and every root leg skipped the whole section).
  # shellcheck disable=SC2030,SC2031,SC2123  # emptying PATH is the point: it hides `id` too
  _su_root="$( unset BLIB_SU; PATH="$SANDBOX/emptybin"
    blib_resolve_su --require >/dev/null 2>&1 && printf 'ok/%s' "${BLIB_SU-UNSET}" || printf 'failed/%s' "${BLIB_SU-UNSET}" )"
  if [[ "$_su_root" == "ok/" ]]; then pass "blib_resolve_su --require succeeds as root on an empty PATH (no id/sudo/doas)"; else fail "root minimal-PATH --require regressed (got $_su_root; want ok/ with an empty BLIB_SU)"; fi
  skip "blib_resolve_su NON-root no-escalator cases (suite is running as root)"
fi

# ── --prefer: the order is not a universal fact (#867) ────────────────────────
# sudo-first is right for eight repos and WRONG for dotfiles-Alpine, whose
# os/alpine.capabilities declares "DOAS, NOT SUDO — the Alpine fact this file exists to
# declare" and says so explicitly for "the rare Alpine box that installs sudo as well".
# Without --prefer, adopting blib_resolve_su there would silently invert a declared OS fact,
# so the repo kept its hand-rolled probe instead — which is how `[[ "$(id -u)" -eq 0 ]]`, the
# arithmetic comparison an empty `id` output satisfies, survived there. A helper the fleet
# cannot adopt without a behaviour change is a helper the fleet does not adopt.
#
# THE DEFAULT IS PINNED ALONGSIDE, and it carries as much weight as the new flag: eight repos
# depend on sudo-first, so a change that made doas win by default would be a silent
# escalator swap across the fleet with nothing to catch it.
_su_pref_d="$(mktemp -d "$SANDBOX/supref.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$_su_pref_d/sudo"
printf '#!/bin/sh\nexit 0\n' >"$_su_pref_d/doas"
chmod +x "$_su_pref_d/sudo" "$_su_pref_d/doas"
# _su_pref <keep> <args...> — resolve with only <keep> on PATH, print the basename recorded.
_su_pref() {
  local keep="$1" bin
  shift
  bin="$(mktemp -d "$SANDBOX/suprefbin.XXXXXX")"
  case "$keep" in *sudo*) cp "$_su_pref_d/sudo" "$bin/sudo" ;; esac
  case "$keep" in *doas*) cp "$_su_pref_d/doas" "$bin/doas" ;; esac
  ( unset BLIB_SU; PATH="$bin"
    blib_resolve_su "$@" >/dev/null 2>&1
    printf '%s' "${BLIB_SU##*/}" )
}
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ "$(_su_pref 'sudo doas')" == sudo ]]; then pass "blib_resolve_su: the DEFAULT order still prefers sudo (eight repos rely on it)"; else fail "blib_resolve_su default order changed — got [$(_su_pref 'sudo doas')], want sudo"; fi
  if [[ "$(_su_pref 'sudo doas' --prefer doas)" == doas ]]; then pass "blib_resolve_su --prefer doas wins over an installed sudo (the Alpine contract)"; else fail "blib_resolve_su --prefer doas did not win — got [$(_su_pref 'sudo doas' --prefer doas)]"; fi
  # A preference is a preference, not a requirement: a box missing the preferred tool must
  # still resolve rather than behave as if nothing were installed.
  if [[ "$(_su_pref 'sudo' --prefer doas)" == sudo ]]; then pass "blib_resolve_su --prefer falls back when the preferred tool is absent"; else fail "blib_resolve_su --prefer did not fall back — got [$(_su_pref 'sudo' --prefer doas)]"; fi
  if [[ "$(_su_pref 'sudo doas' --prefer=doas)" == doas ]]; then pass "blib_resolve_su accepts the --prefer=VALUE spelling"; else fail "blib_resolve_su --prefer=doas not honoured"; fi
  # --prefer must COMPOSE with --require rather than replace the argument parse. The old
  # parser read only $1, so `--prefer doas --require` would have dropped the requirement —
  # turning a hard error into a warning, which is the direction that hurts.
  # shellcheck disable=SC2123  # emptying PATH is the POINT: it hides sudo/doas, as above
  if ( unset BLIB_SU; PATH="$SANDBOX/emptybin"; blib_resolve_su --prefer doas --require >/dev/null 2>&1 ); then
    fail "blib_resolve_su --prefer doas --require succeeded with no escalator — --require was dropped"
  else
    pass "blib_resolve_su --prefer composes with --require (the requirement is not dropped)"
  fi
else
  skip "blib_resolve_su --prefer cases (suite is running as root — nothing to escalate with)"
fi
# A TYPO must be loud. Silently ignoring an unknown flag is how `--requrie` becomes a
# warning instead of a hard error on a box that cannot install packages.
( unset BLIB_SU; blib_resolve_su --requrie >/dev/null 2>&1 )
if [[ $? -eq 2 ]]; then pass "blib_resolve_su rejects an unknown flag (rc 2) rather than ignoring it"; else fail "blib_resolve_su accepted an unknown flag — a mistyped --require would silently downgrade to a warning"; fi
unset -f _su_pref
unset _su_pref_d

# "Resolve once" must mean ONCE: the recorded escalator has to survive a later PATH change,
# because blib_user_bindirs_on_path (same file) prepends user-writable dirs by design. A
# bare `sudo` would be re-resolved against the new PATH and could pick up a different
# binary — which would then receive the password prompt.
_su_pin_a="$(mktemp -d "$SANDBOX/supin-a.XXXXXX")"
_su_pin_b="$(mktemp -d "$SANDBOX/supin-b.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$_su_pin_a/sudo"; chmod +x "$_su_pin_a/sudo"
printf '#!/bin/sh\nexit 0\n' >"$_su_pin_b/sudo"; chmod +x "$_su_pin_b/sudo"   # the impostor
# Root-guarded, like the no-escalator cases above: as root the resolver correctly returns
# an EMPTY BLIB_SU (nothing to escalate with), so there is no path to pin. The Alpine and
# Arch audit legs run in root containers, which is exactly where an unguarded version of
# this assertion fails for the wrong reason.
if [[ "$(id -u)" -ne 0 ]]; then
  # shellcheck disable=SC2030,SC2031
  _su_pinned="$( unset BLIB_SU; PATH="$_su_pin_a:/usr/bin:/bin"
    blib_resolve_su >/dev/null 2>&1
    PATH="$_su_pin_b:$PATH"          # a later prepend, exactly what bindirs_on_path does
    printf '%s' "$BLIB_SU" )"
  if [[ "$_su_pinned" == "$_su_pin_a/sudo" ]]; then pass "blib_resolve_su pins the absolute path (survives a later PATH prepend)"; else fail "blib_resolve_su recorded [$_su_pinned] — a later PATH change can swap the escalator"; fi
else
  skip "blib_resolve_su path pinning (suite is running as root — no escalator to pin)"
fi

# blib_priv must never invoke an empty-string command: with BLIB_SU= it runs CMD directly,
# and with an escalator set it prefixes it (`env` stands in harmlessly for sudo).
if [[ "$(BLIB_SU='' blib_priv printf 'ran-%s' direct)" == "ran-direct" ]]; then pass "blib_priv with BLIB_SU= runs the command directly"; else fail "blib_priv mishandled an empty escalator"; fi
if [[ "$(BLIB_SU='env' blib_priv printf 'ran-%s' viasu)" == "ran-viasu" ]]; then pass "blib_priv routes through a non-empty BLIB_SU"; else fail "blib_priv did not route through BLIB_SU"; fi

# blib_user_bindirs_on_path: adds only EXISTING dirs, never duplicates.
#
# CARGO_HOME/GOBIN/GOPATH are UNSET here, as deliberately as HOME and PATH are pinned. These
# cases assert the $HOME-RELATIVE DEFAULTS, and the helper reaches those defaults only when
# the vars are absent — `${CARGO_HOME:-$HOME/.cargo}/bin`. Inherit an exported CARGO_HOME
# from the caller and the lookup retargets, so the fixture's own .cargo/bin never lands and
# the case reports "missed ~/.cargo/bin" on a perfectly healthy tree.
#
# Note where the leak actually lived: the RELOCATION block further down (search `_relo_home`)
# sets these vars explicitly and was always immune. It was the DEFAULT-path cases here that
# inherited. A gap between two blocks, not a coverage hole — and invisible to CI, because no
# runner exports CARGO_HOME while most developers' shells do. Same shape as the
# GHOSTTY_SHELL_FEATURES leak in the OSC 133 section: a fixture pins what it varies and
# inherits what it does not, so the ambient environment decides the verdict.
_bindirs_path() { (
  HOME="$1"
  PATH="/usr/bin"
  unset CARGO_HOME GOBIN GOPATH
  blib_user_bindirs_on_path
  blib_user_bindirs_on_path
  printf '%s' "$PATH"
); }
_bhome="$(mktemp -d "$SANDBOX/bindirs.XXXXXX")"
mkdir -p "$_bhome/.local/bin" "$_bhome/.cargo/bin" # deliberately NO go/bin, NO .atuin/bin
_bpath="$(_bindirs_path "$_bhome")"
case "$_bpath" in *"$_bhome/.local/bin"*) pass "blib_user_bindirs_on_path adds an existing ~/.local/bin" ;; *) fail "blib_user_bindirs_on_path missed ~/.local/bin" ;; esac
case "$_bpath" in *"$_bhome/.cargo/bin"*) pass "blib_user_bindirs_on_path adds an existing ~/.cargo/bin (the cargo-rebuild bug)" ;; *) fail "blib_user_bindirs_on_path missed ~/.cargo/bin" ;; esac
case "$_bpath" in *"$_bhome/go/bin"*) fail "blib_user_bindirs_on_path added a NON-EXISTENT dir (~/go/bin)" ;; *) pass "blib_user_bindirs_on_path skips directories that do not exist" ;; esac
if [[ "$(printf '%s' "$_bpath" | tr ':' '\n' | grep -cxF "$_bhome/.local/bin")" == "1" ]]; then pass "blib_user_bindirs_on_path is idempotent (no duplicate PATH entries)"; else fail "blib_user_bindirs_on_path duplicated a PATH entry on the second call"; fi

# The failure tally. Empty ⇒ silent AND rc 0; non-empty ⇒ rc 1 and every entry listed.
# That rc IS the contract a caller maps onto its --strict flag.
if (BLIB_FAILED=(); blib_failures_report >/dev/null); then pass "blib_failures_report returns 0 when nothing failed"; else fail "blib_failures_report must return 0 on an empty tally"; fi
if [[ -z "$(BLIB_FAILED=(); blib_failures_report 2>&1)" ]]; then pass "blib_failures_report prints nothing when nothing failed"; else fail "blib_failures_report printed on an empty tally"; fi
_tally_out="$(BLIB_FAILED=(); blib_note_fail 'carapace: RPM install failed' >/dev/null 2>&1; blib_note_fail 'op: install failed' >/dev/null 2>&1; blib_failures_report 2>&1 || true)"
case "$_tally_out" in *"2 step(s) did not complete"*) pass "blib_failures_report counts the recorded steps" ;; *) fail "blib_failures_report lost the count" ;; esac
case "$_tally_out" in *"carapace: RPM install failed"*) pass "blib_failures_report lists the first failure" ;; *) fail "blib_failures_report dropped a recorded failure" ;; esac
case "$_tally_out" in *"op: install failed"*) pass "blib_failures_report lists the last failure" ;; *) fail "blib_failures_report dropped the last failure" ;; esac
if (BLIB_FAILED=(); blib_note_fail x >/dev/null 2>&1; blib_failures_report >/dev/null 2>&1); then fail "blib_failures_report must return NON-zero when a step failed"; else pass "blib_failures_report returns non-zero when a step failed (drives --strict)"; fi
if [[ "$(BLIB_FAILED=(); blib_note_fail a >/dev/null 2>&1; blib_note_fail b >/dev/null 2>&1; blib_failed_count)" == "2" ]]; then pass "blib_failed_count reports the tally size"; else fail "blib_failed_count wrong"; fi
# bash 3.2 + `set -u`: an empty array expansion counts as UNSET, so a bare
# "${BLIB_FAILED[@]}" would abort the report on the HAPPY path. Prove the guarded form
# survives errexit+nounset — which is exactly how a bootstrap runs.
# shellcheck disable=SC2034  # read by blib_failures_report in lib/bootstrap-lib.sh
if (set -eu; BLIB_FAILED=(); blib_failures_report >/dev/null 2>&1); then pass "blib_failures_report survives set -eu with an empty tally (bash 3.2 array rule)"; else fail "blib_failures_report tripped set -u on an empty array"; fi

# ── the relocatable bindirs (CARGO_HOME / GOBIN / GOPATH) ────────────────────
# cargo honours $CARGO_HOME and go honours $GOBIN then $GOPATH/bin. Hard-coding
# ~/.cargo/bin would leave a box with a custom CARGO_HOME still rebuilding every crate on
# every run — the same bug, just relocated.
_relo_home="$(mktemp -d "$SANDBOX/relo.XXXXXX")"
mkdir -p "$_relo_home/xdgcargo/bin" "$_relo_home/gobin" "$_relo_home/gopath/bin"
_relo_path="$( HOME="$_relo_home" CARGO_HOME="$_relo_home/xdgcargo" GOBIN="$_relo_home/gobin" PATH=/usr/bin; export CARGO_HOME GOBIN; blib_user_bindirs_on_path; printf '%s' "$PATH" )"
case "$_relo_path" in *"$_relo_home/xdgcargo/bin"*) pass "blib_user_bindirs_on_path honours CARGO_HOME" ;; *) fail "blib_user_bindirs_on_path ignored CARGO_HOME" ;; esac
case "$_relo_path" in *"$_relo_home/gobin"*) pass "blib_user_bindirs_on_path honours GOBIN" ;; *) fail "blib_user_bindirs_on_path ignored GOBIN" ;; esac
# shellcheck disable=SC2030,SC2031  # a subshell-local PATH is the POINT of every probe below
_relo_path2="$( HOME="$_relo_home" GOPATH="$_relo_home/gopath" PATH=/usr/bin; unset GOBIN; export GOPATH; blib_user_bindirs_on_path; printf '%s' "$PATH" )"
case "$_relo_path2" in *"$_relo_home/gopath/bin"*) pass "blib_user_bindirs_on_path falls back to GOPATH/bin when GOBIN is unset" ;; *) fail "blib_user_bindirs_on_path ignored GOPATH" ;; esac
# GOPATH is a LIST: go installs into the FIRST entry's bin/. Appending /bin to the whole
# value would probe "/first:/second/bin", which exists nowhere — so the Go tools stay off
# PATH and get rebuilt every run, the exact failure this helper exists to prevent.
# shellcheck disable=SC2030,SC2031
_relo_path3="$( HOME="$_relo_home" GOPATH="$_relo_home/gopath:$_relo_home/second" PATH=/usr/bin; unset GOBIN; export GOPATH; blib_user_bindirs_on_path; printf '%s' "$PATH" )"
case "$_relo_path3" in *"$_relo_home/gopath/bin"*) pass "blib_user_bindirs_on_path uses GOPATH's FIRST entry when it is a list" ;; *) fail "blib_user_bindirs_on_path mishandled a multi-entry GOPATH (got: $_relo_path3)" ;; esac
case "$_relo_path3" in *":$_relo_home/second/bin"*|*"gopath:$_relo_home/second/bin"*) fail "blib_user_bindirs_on_path built a bogus path from a multi-entry GOPATH" ;; *) pass "blib_user_bindirs_on_path builds no bogus /a:/b/bin entry" ;; esac

# ── sudo keepalive (hermetic: a shimmed `sudo` on PATH, never the real one) ───
# The riskiest code in this batch — it forks a background refresher and installs no trap of
# its own — so pin the branches that decide whether it runs at all, that a failed FIRST
# authentication is reported (so a caller can abort before half-provisioning), and that
# stop() is idempotent and leaves no orphan.
_ka_bin="$(mktemp -d "$SANDBOX/kabin.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$_ka_bin/sudo"; chmod +x "$_ka_bin/sudo"
# TWO intervals, and the difference between them is deliberate — see each use site.
#   _KA_INTERVAL          the SHORT one, for the block that must watch the loop go round.
#   _KA_DEFAULT_INTERVAL  the SHIPPED default, for the block whose assertion needs a
#                         sleeper that would still be alive if stop() had not reaped it.
# The shipped default is pinned below rather than assumed: the sleeper shim keys on it, so
# a change to bootstrap-lib.sh that this file did not follow must say so by name instead of
# surfacing as the much vaguer "forked no sleeper".
_KA_INTERVAL=1
_KA_DEFAULT_INTERVAL=50
_ka_shipped="$(sed -n 's/^  local interval="${BLIB_SUDO_KEEPALIVE_INTERVAL:-\([0-9]*\)}"$/\1/p' "$HERE/lib/bootstrap-lib.sh")"
if [[ "$_ka_shipped" == "$_KA_DEFAULT_INTERVAL" ]]; then
  pass "keepalive: the shipped refresh interval is still ${_KA_DEFAULT_INTERVAL}s (the sleeper shim keys on it)"
else
  fail "keepalive: lib/bootstrap-lib.sh ships a ${_ka_shipped:-unreadable} refresh interval, but this suite's sleeper shim keys on ${_KA_DEFAULT_INTERVAL} — update _KA_DEFAULT_INTERVAL or the shim records nothing and the reaping assertion goes vacuous"
fi
# _ka_pid <BLIB_SU> <BLIB_DRY> — start the keepalive against the shimmed sudo, print the
# pid it recorded (empty when it correctly declined to fork). _ka_rc is the same, returning
# the rc instead. Both wrap the subshell so the SC2030/SC2031 suppression is stated once.
# shellcheck disable=SC2030,SC2031  # a subshell-local PATH is the POINT (hermetic sudo shim)
_ka_pid() { ( BLIB_SU="$1"; BLIB_DRY="$2"; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  blib_sudo_keepalive_start >/dev/null 2>&1
  _p="${BLIB_SUDO_KEEPALIVE_PID:-}"
  blib_sudo_keepalive_stop  # reap BEFORE printing: a live refresher would otherwise be
  printf '%s' "$_p" ); }    # a second writer on this substitution's pipe
# shellcheck disable=SC2030,SC2031
_ka_rc() { ( BLIB_SU="$1"; BLIB_DRY="$2"; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  blib_sudo_keepalive_start >/dev/null 2>&1 ); }
# not-sudo escalators must no-op: doas has no refreshable timestamp, root has nothing to prime.
if [[ -z "$(_ka_pid doas 0)" ]]; then pass "blib_sudo_keepalive_start no-ops under doas"; else fail "blib_sudo_keepalive_start started a refresher under doas"; fi
if [[ -z "$(_ka_pid '' 0)" ]]; then pass "blib_sudo_keepalive_start no-ops as root (BLIB_SU=)"; else fail "blib_sudo_keepalive_start started a refresher as root"; fi
# BLIB_DRY must PREVIEW, never authenticate or fork.
if [[ -z "$(_ka_pid sudo 1)" ]]; then pass "blib_sudo_keepalive_start forks nothing under BLIB_DRY"; else fail "blib_sudo_keepalive_start forked a refresher during a dry run"; fi
# BLIB_SU is documented as a single command TOKEN, so an absolute path is a valid override.
# Matching the literal string `sudo` skipped priming for it, silently restoring the very
# timestamp expiry (and invisible prompt) this helper exists to prevent.
if [[ -n "$(_ka_pid "$_ka_bin/sudo" 0)" ]]; then pass "blib_sudo_keepalive_start primes an absolute-path BLIB_SU (/…/sudo)"; else fail "an absolute-path BLIB_SU silently disabled the keepalive"; fi
# a FAILED initial `sudo -v` must return non-zero — that rc is what lets a caller abort.
printf '#!/bin/sh\nexit 1\n' >"$_ka_bin/sudo"
if _ka_rc sudo 0; then fail "blib_sudo_keepalive_start returned 0 when sudo -v failed"; else pass "blib_sudo_keepalive_start reports a failed initial authentication"; fi
# the happy path: it forks exactly one refresher, and stop() reaps it and is re-callable.
# The shim now RECORDS its argv, so the refresh MODE is assertable further down: a shim that
# merely exits 0 accepts `-n true` and `-n -v` alike, and the suite passed either way — it
# could not see the restricted-sudoers fix at all.
#
# `printf`, not `echo`: given argv `-n -v`, dash's echo eats the `-n` as its own no-newline
# flag and records a bare `-v` — a harness that reports the OLD behaviour as the new one.
_ka_argv="$_ka_bin/argv"
: >"$_ka_argv"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$_ka_argv" >"$_ka_bin/sudo"
# shellcheck disable=SC2030,SC2031  # subshell-local PATH again: the shimmed sudo
_ka_out="$( BLIB_SU=sudo; BLIB_DRY=0; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  blib_sudo_keepalive_start >/dev/null 2>&1
  pid="$BLIB_SUDO_KEEPALIVE_PID"
  kill -0 "$pid" 2>/dev/null && alive=yes || alive=no
  blib_sudo_keepalive_stop
  sleep 0.2
  kill -0 "$pid" 2>/dev/null && after=alive || after=reaped
  blib_sudo_keepalive_stop   # second call must be a harmless no-op
  printf '%s/%s/%s' "$alive" "$after" "${BLIB_SUDO_KEEPALIVE_PID:-empty}" )"
case "$_ka_out" in yes/*) pass "blib_sudo_keepalive_start forks a live refresher" ;; *) fail "blib_sudo_keepalive_start did not fork a refresher (got $_ka_out)" ;; esac
case "$_ka_out" in */reaped/*) pass "blib_sudo_keepalive_stop reaps the refresher shell" ;; *) fail "blib_sudo_keepalive_stop left the refresher running (got $_ka_out)" ;; esac
# The refresh must use sudo's VALIDATION mode. `-n true` additionally requires the account
# to be authorised to run `true`, which a sudoers restricted to the provisioning commands
# denies — the refresh then fails silently and the timestamp expires, restoring the hang.
# The initial prime is a bare `-v`, so require the `-n -v` line specifically.
#
# Its OWN run, which POLLS for that line before stopping. Reusing the block above would
# make this scheduler-dependent: that one stops after a fixed short delay, and a loaded
# runner need not have scheduled the background loop's first refresh by then. It did not on
# macOS — the argv log held only the initial `-v` and the assertion failed for a timing
# reason that had nothing to do with the behaviour under test.
#
# THIS BLOCK CAN STALL FOR ONE FULL REFRESH INTERVAL, and the cause is NOT yet known. Read
# the next 20 lines before trying to fix it — two plausible explanations have already been
# measured and killed, and the interval seam only bounds the damage.
#
# MEASURED:
#   • It is INTERMITTENT, not the constant an earlier version of this comment asserted:
#     2 stalls in 16 instrumented suite runs (50.017s pre-seam, 20.016s driven at 20), every
#     other run 0.02–0.13s. Expect to see "already fast" and wrongly conclude it is fixed.
#   • The cost is exactly one interval + ~20ms, at every interval it has been driven at.
#   • During a stall, sampling /proc/<pid>/fd across the whole window (1644 samples): ONE
#     sleeper, all three fds on /dev/null the entire time, its parent — the refresher loop
#     shell — alive throughout. So the subshell was still inside blib_sudo_keepalive_stop,
#     whose `wait` was blocked on a loop shell that did not act on its TERM until its sleeper
#     expired on its own. This is a TEARDOWN stall.
#
# RULED OUT — do not re-propose these:
#   • Pipe retention by the refresher keeping the command substitution open. An unredirected
#     sleeper does reproduce the one-interval signature by construction (0.329s redirected vs
#     7.023s not, at an interval of 7), but the shipped loop redirects and the fd sampling
#     above never once caught a pipe. A matching duration is not a diagnosis.
#   • Rewriting this as `( … )` + reading the argv file afterwards, i.e. removing the
#     substitution. Measured on the converted block: 2 stalls in 2 runs, 30.012s and 30.013s.
#     The parent waits for the subshell either way, and the subshell is what blocks.
#
# RESOLVED (#529): teardown was the right suspect, but not for the expected reason. The
# trap's TERM DID reach the sleeper — `kill` returned 0 — and the sleeper went on to exit
# normally after its full interval anyway, with no signal blocked, ignored or caught. It was
# killable and the signal was lost, not refused. lib/bootstrap-lib.sh now follows the TERM
# with a KILL, which cannot be lost, and the gate further down forces that case with a
# SIGTERM-ignoring sleeper so it is not left to a 1-in-3 race.
#
# The mechanism behind the lost signal was never isolated, and nothing here should pretend
# otherwise: it reproduces only inside this suite. stop() alone is clean (0/60 at an interval
# of 5), this block outside the suite is clean (0/40, 0/30), and no start→stop delay from
# 0–50ms provokes it.
#
# BLIB_SUDO_KEEPALIVE_INTERVAL does NOT keep this poll short, whatever it may once have
# claimed: the poll is bounded by its own 100 × 0.1s, and the `-n -v` it waits for is written
# BEFORE the loop's first sleep, so it returns on iteration zero at any interval. What the
# seam does is cap a stall at ~1s instead of ~50s when the race fires.
# shellcheck disable=SC2030,SC2031  # subshell-local PATH: the shimmed sudo
_ka_mode="$( BLIB_SU="$_ka_bin/sudo"; BLIB_DRY=0; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  BLIB_SUDO_KEEPALIVE_INTERVAL="$_KA_INTERVAL"
  : >"$_ka_argv"
  blib_sudo_keepalive_start >/dev/null 2>&1
  n=0
  while ((n < 100)); do grep -qe '-n -v' "$_ka_argv" 2>/dev/null && break; sleep 0.1; n=$((n + 1)); done
  blib_sudo_keepalive_stop
  tr '\n' '|' <"$_ka_argv" )"
case "$_ka_mode" in *"-n -v"*) pass "the background refresh uses 'sudo -n -v' (validation mode)" ;; *) fail "the refresher did not use -n -v (argv recorded: $_ka_mode)" ;; esac
# The refresher's SLEEPER is a separate process. Killing only the loop shell leaves it
# running — orphaned for up to its full duration — and the pid check above cannot see that,
# so it certified a "no orphan" property it never tested.
#
# Assert on THIS keepalive's own sleeper, by pid. Comparing a global `pgrep -x sleep` count
# before and after could not tell our sleeper from the box's, and failed in BOTH directions:
# an unrelated sleep exiting between the two snapshots dropped the count and passed the
# assertion while this keepalive had in fact leaked one, and an unrelated sleep starting
# failed it for something no one here did. On a CI leg (or a dev box running two suites at
# once) that is a coin toss, and the direction that matters is the silent pass.
#
# The shim records the sleeper's pid and then EXECs the real sleep, so the recorded pid IS
# the surviving process — no parent/child indirection to get wrong. Only the refresher's own
# sleeper is recorded: the harness's own short sleeps reach this shim through the same
# scoped PATH, and counting those would put us right back to measuring the box.
#
# This block deliberately does NOT shorten the interval the way the refresh-mode block above
# does, and that is the whole reason the two constants exist. The assertion here is that
# stop() REAPED the sleeper — which is only meaningful while the sleeper would otherwise
# still be running. Under a 1s interval it would exit on its own inside the poll window and
# the check would pass for a reason that has nothing to do with stop(): a silent vacuous
# pass, the exact failure mode the "recorded none" guard below exists to prevent.
_ka_sleeper_file="$SANDBOX/ka-sleeper.pids"
: >"$_ka_sleeper_file"
_ka_real_sleep="$(command -v sleep)"
cat >"$_ka_bin/sleep" <<SHIM
#!/bin/sh
case "\$1" in $_KA_DEFAULT_INTERVAL) printf '%s\n' "\$\$" >>"$_ka_sleeper_file" ;; esac
exec "$_ka_real_sleep" "\$@"
SHIM
chmod +x "$_ka_bin/sleep"
# shellcheck disable=SC2030,SC2031
# No fixed delays, in EITHER direction. A pre-stop sleep can fire before the refresher has
# been scheduled on a loaded runner (that is the macOS failure documented above), so poll
# for the recording instead. And a post-stop grace period is worse than useless here: it
# lets a NON-synchronous stop() pass whenever the sleeper happens to die shortly after,
# which is exactly the contract under test — so assert the instant stop() returns.
# shellcheck disable=SC2030,SC2031
( BLIB_SU="$_ka_bin/sudo"; BLIB_DRY=0; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  blib_sudo_keepalive_start >/dev/null 2>&1
  n=0; while ((n < 100)) && [[ ! -s "$_ka_sleeper_file" ]]; do sleep 0.1; n=$((n + 1)); done
  blib_sudo_keepalive_stop ) >/dev/null 2>&1
_ka_sleeper_pid="$(head -n1 "$_ka_sleeper_file" 2>/dev/null || true)"
# An empty recording is a FAILURE, not a pass. If the shim never fired, no sleeper was ever
# forked and the reaping claim is vacuous — precisely the silent-pass mode being removed.
if [[ -z "$_ka_sleeper_pid" ]]; then
  fail "the keepalive forked no sleeper (shim recorded none) — the reaping assertion would be vacuous"
elif kill -0 "$_ka_sleeper_pid" 2>/dev/null; then
  fail "blib_sudo_keepalive_stop returned with its sleeper (pid $_ka_sleeper_pid) still alive — teardown is not synchronous"
else
  pass "blib_sudo_keepalive_stop reaps the SLEEPER before returning (synchronous teardown)"
fi
case "$_ka_out" in */empty) pass "blib_sudo_keepalive_stop clears the pid and is idempotent" ;; *) fail "blib_sudo_keepalive_stop did not clear the pid (got $_ka_out)" ;; esac
# BLIB_SUDO_KEEPALIVE_INTERVAL exists for this suite, which means the fleet now ships a knob
# that a stray value in someone's environment can reach. Its guard has to be tested, or the
# seam that made this suite fast is also a way to make a provisioning run hammer sudo in a
# busy-loop — the interval is the ONLY thing bounding that loop's rate.
#
# Assert on the argument the sleeper is actually given, not on the source: a regex that
# merely LOOKS right (`[0-9]*` accepts the empty string, `+` vs `*`) is precisely how a
# validator passes review and admits `0` anyway. The shim records argv; each case reads back
# what the loop asked for.
_ka_iv_argv="$_ka_bin/sleep-argv"
cat >"$_ka_bin/sleep" <<SHIM
#!/bin/sh
case "\$1" in 0.*) ;; *) printf '%s\n' "\$1" >>"$_ka_iv_argv" ;; esac
exec "$_ka_real_sleep" "\$@"
SHIM
chmod +x "$_ka_bin/sleep"
# _ka_iv <override> — run one keepalive cycle under that override, print the interval the
# refresher's sleeper was handed. Unset is spelled by passing the literal token `unset`.
# shellcheck disable=SC2030,SC2031
_ka_iv() { ( : >"$_ka_iv_argv"
  BLIB_SU="$_ka_bin/sudo"; BLIB_DRY=0; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  if [[ "$1" == unset ]]; then unset BLIB_SUDO_KEEPALIVE_INTERVAL; else BLIB_SUDO_KEEPALIVE_INTERVAL="$1"; fi
  blib_sudo_keepalive_start >/dev/null 2>&1
  n=0; while ((n < 100)) && [[ ! -s "$_ka_iv_argv" ]]; do sleep 0.1; n=$((n + 1)); done
  blib_sudo_keepalive_stop ) >/dev/null 2>&1
  head -n1 "$_ka_iv_argv" 2>/dev/null || true; }
# The honoured case FIRST: a guard that rejects everything would pass every fail-safe case
# below and still have broken the seam this change exists for.
_ka_iv_got="$(_ka_iv "$_KA_INTERVAL")"
if [[ "$_ka_iv_got" == "$_KA_INTERVAL" ]]; then pass "keepalive: a valid BLIB_SUDO_KEEPALIVE_INTERVAL is honoured (the test seam works)"; else fail "keepalive: BLIB_SUDO_KEEPALIVE_INTERVAL=$_KA_INTERVAL was not honoured (sleeper got '${_ka_iv_got:-nothing}')"; fi
# `0` and `-1` are the values that turn the loop into a sudo busy-loop; the empty string is
# what an exported-but-unset variable looks like; `5s`/`abc` are ordinary typos. Every one
# must land on the shipped default, not on itself and not on an error.
_ka_iv_bad=0
for _ka_iv_case in 0 -1 "" 5s abc 1.5 " " 01; do
  _ka_iv_got="$(_ka_iv "$_ka_iv_case")"
  [[ "$_ka_iv_got" == "$_KA_DEFAULT_INTERVAL" ]] || { _ka_iv_bad=1; fail "keepalive: BLIB_SUDO_KEEPALIVE_INTERVAL='$_ka_iv_case' did not fall back to ${_KA_DEFAULT_INTERVAL}s — the sleeper got '${_ka_iv_got:-nothing}'"; }
done
((_ka_iv_bad)) || pass "keepalive: a zero/negative/non-numeric interval falls back to ${_KA_DEFAULT_INTERVAL}s (no sudo busy-loop from a stray override)"
_ka_iv_got="$(_ka_iv unset)"
if [[ "$_ka_iv_got" == "$_KA_DEFAULT_INTERVAL" ]]; then pass "keepalive: an unset interval is the shipped ${_KA_DEFAULT_INTERVAL}s (the seam changes no default)"; else fail "keepalive: with no override the sleeper got '${_ka_iv_got:-nothing}', not ${_KA_DEFAULT_INTERVAL}"; fi
rm -f "$_ka_bin/sleep"
# ── #529: stop() must not block when a TERM to the sleeper goes unheeded ─────
# The shipped hang was a race: a TERM aimed at the sleeper is sometimes accepted by kill(2)
# — rc 0 — and never acted on, so the handler's `wait` sits out the sleeper's entire
# interval and stop() blocks behind it. 50s in a real provisioning run. In this suite it
# reproduced about 1 run in 3 at a 30s interval and never once outside it, and a 1-in-3
# race is not a gate: it would pass on the run that mattered.
#
# So force the case instead of waiting for it. A sleeper that IGNORES SIGTERM is the lost
# signal made deterministic — SIG_IGN survives exec, so the real `sleep` inherits it from
# the shim. The handler's KILL cannot be caught or ignored, so stop() still returns at
# once; drop the KILL and this blocks for the whole interval, every time.
#
# Asserted on WALL CLOCK on purpose. "stop() eventually returned and the sleeper was gone"
# is true in BOTH cases — it is the passing-for-the-wrong-reason this exists to catch.
# NO fixed pre-stop delay, for the reason stated at the reaping block above: on a loaded
# runner a fixed sleep can elapse before the refresher has been scheduled at all, and then
# stop() finds no job to signal, returns instantly, and this passes with the KILL deleted —
# the vacuous pass it exists to prevent. Poll for the shim's recording instead, and treat an
# empty recording as a FAILURE rather than a pass.
#
# The shim records only the refresher's own sleeper (it keys on the interval), so the poll's
# 0.1s sleeps reaching the same shim are not counted. Timing is taken INSIDE the subshell
# around stop() alone, so the poll's own duration cannot mask a blocked teardown.
_ka_ign_iv=5
_ka_ign_file="$SANDBOX/ka-ignterm.pids"
_ka_ign_dur="$SANDBOX/ka-ignterm.dur"
: >"$_ka_ign_file"
: >"$_ka_ign_dur"
cat >"$_ka_bin/sleep" <<SHIM
#!/bin/sh
trap '' TERM
case "\$1" in $_ka_ign_iv) printf '%s\n' "\$\$" >>"$_ka_ign_file" ;; esac
exec "$_ka_real_sleep" "\$@"
SHIM
chmod +x "$_ka_bin/sleep"
# shellcheck disable=SC2030,SC2031  # subshell-local PATH: the shimmed sudo + sleep
( BLIB_SU="$_ka_bin/sudo"; BLIB_DRY=0; BLIB_SUDO_KEEPALIVE_PID=""; PATH="$_ka_bin:$PATH"
  # shellcheck disable=SC2034  # read by blib_sudo_keepalive in lib/bootstrap-lib.sh
  BLIB_SUDO_KEEPALIVE_INTERVAL="$_ka_ign_iv"
  blib_sudo_keepalive_start >/dev/null 2>&1
  n=0; while ((n < 100)) && [[ ! -s "$_ka_ign_file" ]]; do sleep 0.1; n=$((n + 1)); done
  _ka_ign_t0=$SECONDS
  blib_sudo_keepalive_stop
  printf '%s' "$((SECONDS - _ka_ign_t0))" >"$_ka_ign_dur" ) >/dev/null 2>&1
rm -f "$_ka_bin/sleep"
_ka_ign_pid="$(head -n1 "$_ka_ign_file" 2>/dev/null || true)"
_ka_ign_d="$(cat "$_ka_ign_dur" 2>/dev/null || true)"
if [[ -z "$_ka_ign_pid" ]]; then
  fail "keepalive: no SIGTERM-ignoring sleeper was ever forked (shim recorded none) — the timing assertion would be vacuous (#529)"
elif [[ -n "$_ka_ign_d" ]] && ((_ka_ign_d < _ka_ign_iv - 1)); then
  pass "keepalive: stop() returns promptly when the sleeper ignores SIGTERM (${_ka_ign_d}s < ${_ka_ign_iv}s)"
else
  fail "keepalive: stop() blocked ${_ka_ign_d:-?}s waiting out a SIGTERM-ignoring sleeper (pid $_ka_ign_pid) — the handler's KILL is gone (#529)"
fi

# The TERM handler must target the JOB, never a pid. `$!` does not clear when `wait` reaps
# the sleeper, so a handler holding it signals that dead pid for the whole of the next
# `sudo -n -v` — and once the box has cycled through the pid space, whatever now owns it,
# as root. A saved copy is wrong the other way (assigned after the fork, so a TERM in
# between orphans the new sleeper). Only a job spec is set by the fork AND cleared by the
# reap. This is a STRUCTURAL gate because the failure needs a 50s iteration boundary plus a
# pid wrap to observe — unreachable in a suite, which is exactly why it needs pinning.
#
# The KILL is pinned here for the same reason but a different failure: a lone TERM is
# sometimes accepted by kill(2) and never acted on, and the handler then blocks in `wait`
# for the sleeper's whole interval (#529). Dropping the KILL back out would restore an
# intermittent 50s hang that the behavioral gate below can catch only because it forces the
# case with a TERM-ignoring sleeper — in the wild it is roughly a 1-in-3 race, so this line
# is what keeps someone from "simplifying" it away on a green run.
_ka_trap_want="trap 'kill %% 2>/dev/null; kill -9 %% 2>/dev/null; wait %% 2>/dev/null; exit 0' TERM"
# ONE matcher, used for BOTH the extraction and the count. Two matchers could disagree,
# and a gate whose two halves disagree is the failure this whole change is about.
#
# It recognises TERM ANYWHERE in the signal operand list, not only as the final token. The
# first version anchored on `.*TERM$`, which made a second handler invisible:
#     trap 'exit 0' TERM INT   -> not matched (TERM is not last)
#     trap 'exit 0' 15         -> not matched (numeric spelling)
# Bash gives a signal to the MOST RECENT trap, so either line added later would replace the
# keepalive's TERM behaviour while this gate still counted one handler, still saw the safe
# line, and still passed. That is a matcher asserting less than it appears to — precisely
# the defect this change exists to remove, sitting inside the fix for it.
#
# Anchoring the signal list AFTER the quoted handler is what keeps it honest in the other
# direction too: `trap 'echo TERM' INT` mentions TERM in the COMMAND and is correctly
# ignored, where a bare `.*TERM` would have matched it.
_ka_trap_re="^[[:space:]]*trap[[:space:]]+('[^']*'|\"[^\"]*\")[[:space:]]+([A-Za-z0-9]+[[:space:]]+)*(TERM|SIGTERM|15)([[:space:]]|\$)"
_ka_trap="$(grep -E "$_ka_trap_re" "$HERE/lib/bootstrap-lib.sh" 2>/dev/null)"
_ka_trap="${_ka_trap#"${_ka_trap%%[![:space:]]*}"}" # ltrim indentation, keep the statement
# Exactly one TERM handler is expected. If a second is ever added the equality below would
# compare a two-line string and red for a confusing reason, so say the real one out loud.
_ka_trap_n="$(grep -cE "$_ka_trap_re" "$HERE/lib/bootstrap-lib.sh" 2>/dev/null || echo 0)"
# REQUIRE the job spec, do not merely reject the pid spellings. A blacklist passes anything
# it did not think of — `trap 'exit 0' TERM` names no pid, sails through, and silently
# restores the orphan leak; so does a differently-named pid variable. Demand both halves
# positively (`kill %%` to signal the sleeper, `wait %%` to reap it before exiting) AND
# keep the pid rejection, so the two failure modes are covered from both directions.
if [[ -z "$_ka_trap" ]]; then
  fail "keepalive: no TERM handler found in lib/bootstrap-lib.sh — the reaping gate cannot check anything"
elif [[ "$_ka_trap_n" != 1 ]]; then
  fail "keepalive: expected exactly one TERM handler in lib/bootstrap-lib.sh, found $_ka_trap_n — this gate assumes the keepalive owns the only one"
elif [[ "$_ka_trap" == *'$!'* || "$_ka_trap" == *'_sleeper'* ]]; then
  fail "keepalive: the TERM handler targets a pid, not a job — \$! survives the reap and can signal a recycled pid: $_ka_trap"
elif [[ "$_ka_trap" != "$_ka_trap_want" ]]; then
  # WHOLE-HANDLER equality, not a pattern. Each looser form let something through, because
  # a wildcard between two command names asserts nothing about what sits in the gap:
  #   membership   accepted `exit 0; kill %%; wait %%`   (cleanup after the exit, dead code)
  #   ordered glob accepted `kill %%; exit 0; wait %%; exit 0` (reaps after exiting) and
  #                         `kill %%; wait %% & exit 0`  (reap backgrounded — not synchronous)
  # The production handler has exactly one safe form, so compare against it verbatim. A
  # deliberate change to it must update this expectation in the same commit — which is the
  # point: this gate exists because the failure needs a 50s boundary plus a pid wrap to
  # observe at runtime, so review is the only place it can be caught.
  fail "keepalive: the TERM handler is not the expected form.
    want: $_ka_trap_want
    got:  $_ka_trap"
else
  pass "keepalive: the TERM handler kills AND waits the job (%%), so it cannot leak or signal a recycled pid"
fi

# The matcher above is the gate's blind-spot surface: anything it cannot SEE is a handler
# that can replace the keepalive's TERM behaviour while the count stays 1 and the equality
# still compares the safe line. Bash gives a signal to the most recent trap, so an
# invisible second handler wins silently. Pin what it must see and what it must not, or
# the anchor can quietly narrow again (it did: `.*TERM$` missed both forms below).
_ka_re_is() { # _ka_re_is <label> <candidate-line> <want:0|1>
  local n
  n="$(printf '%s\n' "$2" | grep -cE "$_ka_trap_re")"
  if [[ "$n" == "$3" ]]; then pass "trap matcher: $1"; else fail "trap matcher: $1 (matched=$n want=$3)"; fi
}
_ka_re_is "sees the shipped handler" "    trap 'kill %% 2>/dev/null; kill -9 %% 2>/dev/null; wait %% 2>/dev/null; exit 0' TERM" 1
_ka_re_is "sees TERM when it is NOT the last operand" "    trap 'exit 0' TERM INT" 1
_ka_re_is "sees TERM after another signal" "    trap 'exit 0' INT TERM" 1
_ka_re_is "sees the SIGTERM spelling" "    trap 'exit 0' SIGTERM" 1
_ka_re_is "sees the numeric spelling (15)" "    trap 'exit 0' 15" 1
_ka_re_is "sees a double-quoted handler" '    trap "exit 0" TERM' 1
# The other direction: it must not fire on traps that do not take TERM, or the gate reds on
# unrelated edits and someone deletes it.
_ka_re_is "ignores a trap that does not take TERM" "    trap 'exit 0' HUP INT" 0
_ka_re_is "ignores TERM appearing inside the COMMAND, not the signal list" "    trap 'echo TERM' INT" 0

# ── blib_set_login_shell must never abort a completed wiring ─────────────────
# It runs at the very END of wire_links, so a failure here would discard an otherwise
# correct install. Shim zsh/getent/chsh so the function reaches its mutating half, then
# make each mutation fail and assert the whole thing still returns 0 under `set -e`.
_ls_bin="$(mktemp -d "$SANDBOX/lsbin.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$_ls_bin/zsh"; chmod +x "$_ls_bin/zsh"
# getent reports a NON-zsh current shell so the early "already zsh" return is not taken.
printf '#!/bin/sh\necho "u:x:1:1::/home/u:/bin/sh"\n' >"$_ls_bin/getent"; chmod +x "$_ls_bin/getent"
printf '#!/bin/sh\nexit 1\n' >"$_ls_bin/chsh"; chmod +x "$_ls_bin/chsh"   # chsh FAILS
printf '#!/bin/sh\nexit 1\n' >"$_ls_bin/tee"; chmod +x "$_ls_bin/tee"     # /etc/shells append FAILS
printf '#!/bin/sh\nexit 1\n' >"$_ls_bin/grep"; chmod +x "$_ls_bin/grep"   # ...so the append is attempted
for _b in id printf cut awk; do [[ -x "$_ls_bin/$_b" ]] || ln -sf "$(command -v "$_b")" "$_ls_bin/$_b" 2>/dev/null; done
# shellcheck disable=SC2034  # the BLIB_* knobs are read by lib/bootstrap-lib.sh, which an
# earlier fragment sources into this shell (see the note at the top of this file)
if ( set -eu
     PATH="$_ls_bin:/usr/bin:/bin"
     BLIB_SU=""; BLIB_DRY=0; BLIB_ONLY=""; BLIB_SKIP=""
     blib_set_login_shell >/dev/null 2>&1 ); then
  pass "blib_set_login_shell returns 0 under set -e when /etc/shells AND chsh both fail"
else
  fail "blib_set_login_shell still aborts a completed wiring when its last step fails"
fi
# ...and it must SAY so rather than failing silently.
_ls_msg="$( PATH="$_ls_bin:/usr/bin:/bin" BLIB_SU="" BLIB_DRY=0 BLIB_ONLY="" BLIB_SKIP="" blib_set_login_shell 2>&1 || true )"
# Match the two warnings SEPARATELY and on strings unique to each. A bare *chsh* match is
# vacuous: the /etc/shells warning also says "chsh may refuse it", so it passed whether or
# not the chsh branch ever ran.
case "$_ls_msg" in *"could not add"*) pass "blib_set_login_shell warns when the /etc/shells append fails" ;; *) fail "blib_set_login_shell swallowed the /etc/shells failure (got: $_ls_msg)" ;; esac
case "$_ls_msg" in *"chsh failed"*) pass "blib_set_login_shell warns when chsh fails, naming the manual fallback" ;; *) fail "blib_set_login_shell swallowed the chsh failure (got: $_ls_msg)" ;; esac

# The OTHER no-op outcome: chsh is absent entirely (a distro without `shadow`). The login
# shell is just as unchanged as in the failure branch above, but this one announced itself
# with blib_say — blue `::` on STDOUT — so it read as a status line rather than a problem.
# The block above cannot cover it: its shim PATH always contains a chsh, and it merges
# stdout into stderr with 2>&1, so it could neither reach this branch nor tell the streams
# apart if it did. Hence a separate fixture, with the streams kept SEPARATE.
#
# PATH is the bindir ALONE — adding /usr/bin:/bin would find the system chsh and silently
# test the wrong branch. So every binary the function reaches for is shimmed or linked in.
_lsn_bin="$(mktemp -d "$SANDBOX/lsnbin.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$_lsn_bin/zsh"; chmod +x "$_lsn_bin/zsh"
printf '#!/bin/sh\necho "u:x:1:1::/home/u:/bin/sh"\n' >"$_lsn_bin/getent"; chmod +x "$_lsn_bin/getent"
# grep exits 0 = "$zsh_path is already listed in /etc/shells", so the privileged tee append
# is skipped and this stays a pure no-privilege test.
printf '#!/bin/sh\nexit 0\n' >"$_lsn_bin/grep"; chmod +x "$_lsn_bin/grep"
for _b in id cut awk printf; do [[ -x "$_lsn_bin/$_b" ]] || ln -sf "$(command -v "$_b")" "$_lsn_bin/$_b" 2>/dev/null; done
PATH="$_lsn_bin" BLIB_SU="" BLIB_DRY=0 BLIB_ONLY="" BLIB_SKIP="" \
  blib_set_login_shell >"$SANDBOX/lsn.out" 2>"$SANDBOX/lsn.err" || true
if grep -q "chsh not found" "$SANDBOX/lsn.err"; then
  pass "blib_set_login_shell warns on STDERR when chsh is absent"
else
  fail "blib_set_login_shell did not warn on stderr when chsh is absent (got: $(tr '\n' ' ' <"$SANDBOX/lsn.err"))"
fi
if grep -q "chsh not found" "$SANDBOX/lsn.out"; then
  fail "'chsh not found' is on STDOUT (blib_say regression — the shell was NOT changed, it must warn)"
else
  pass "'chsh not found' is NOT on stdout (no longer a blib_say status line)"
fi

# ── core_files_identical: the comparison that must not need diffutils ─────────
# sync-core.sh and update-nvim-plugins.sh both asked "did that rewrite change anything"
# with `cmp -s`, which needs diffutils. On a box without it, `command not found` is a
# non-zero exit indistinguishable from "differs", so sync-core.sh counted every candidate
# workflow as repointed (#572) and update-nvim-plugins.sh reported drift that did not
# exist. Both now call core_files_identical, so pin both directions AND the property that
# made the old shape fail: it must not depend on any binary outside git.
_cfi="$(mktemp -d "$SANDBOX/cfi.XXXXXX")"
printf 'alpha\nbeta\n' >"$_cfi/a"
printf 'alpha\nbeta\n' >"$_cfi/b"
printf 'alpha\nGAMMA\n' >"$_cfi/c"
printf 'alpha\nbeta' >"$_cfi/d" # same bytes as a, minus the trailing newline

if core_files_identical "$_cfi/a" "$_cfi/b"; then
  pass "core_files_identical: identical files compare equal"
else
  fail "core_files_identical: identical files reported as differing"
fi
if core_files_identical "$_cfi/a" "$_cfi/c"; then
  fail "core_files_identical: differing files reported as equal"
else
  pass "core_files_identical: differing files compare unequal"
fi
# The trailing-newline case is why this is a hash of the bytes and not `[[ $(cat a) == $(cat b) ]]`:
# command substitution strips trailing newlines from BOTH sides, so a real one-byte
# difference would compare equal and the rewrite would be skipped.
if core_files_identical "$_cfi/a" "$_cfi/d"; then
  fail "core_files_identical: a trailing-newline-only difference was missed (\$(cat) semantics leaked in)"
else
  pass "core_files_identical: a trailing-newline-only difference still counts as different"
fi
# A missing operand must read as "differs", so a caller that lost its temp file rewrites
# rather than silently skipping.
if core_files_identical "$_cfi/a" "$_cfi/nope"; then
  fail "core_files_identical: a missing operand compared equal"
else
  pass "core_files_identical: a missing operand counts as different"
fi
# The regression itself: with diffutils absent it must still be correct. Run it with a
# PATH holding only git, so any reintroduced cmp/diff call fails the way it did in #572.
_cfi_git="$(command -v git)"
_cfi_bin="$(mktemp -d "$SANDBOX/cfibin.XXXXXX")"
ln -s "$_cfi_git" "$_cfi_bin/git"
if PATH="$_cfi_bin" core_files_identical "$_cfi/a" "$_cfi/b" &&
  ! PATH="$_cfi_bin" core_files_identical "$_cfi/a" "$_cfi/c"; then
  pass "core_files_identical: correct on a PATH with git but no cmp/diff (the #572 box)"
else
  fail "core_files_identical: wrong answer without diffutils on PATH — the #572 regression is back"
fi
# And no caller may quietly go back to cmp — OR to diff, which is the same hole one step
# over: both ship in diffutils, so a box without it (the Arch CI container) has neither.
# Banning only `cmp` is what let a `diff <(…) <(…)` into this very file and red audit-arch
# while every local gate was green.
#
# `git diff` MUST be exempt — git is the one tool these scripts already cannot run without,
# which is why core_files_identical is built on git hash-object. Getting that exemption
# right is the whole difficulty, and the first attempt got it wrong: it enumerated the
# invocation forms it could think of (`git diff`, `git --no-pager diff`) and so false-fired
# on sync-core.sh's `git -C "$path" diff --cached`, reddening four CI legs on correct code.
#
# So the exemption is now structural rather than a list of spellings: `diff` is a git
# SUBCOMMAND if a `git` invocation precedes it in the same pipeline stage. `[^|;&]*` is what
# scopes it to that stage — it stops at a pipe, so `git log | diff -u - x` is still caught.
# _diffutils_hits is a function purely so the fixtures below can test BOTH directions; a
# gate whose exemption is untested is how the last one shipped broken.
_diffutils_hits() { # _diffutils_hits <file>… — print offending "file:line:text"
  # The comment filter must skip grep's "file:line:" PREFIX before looking for the #.
  # The original gate used `grep -v "^\s*#"` against this same prefixed stream, so it
  # never stripped a single comment — latent only because no commented `cmp -` existed.
  # -H as well as -n: grep OMITS the filename when handed a single file, so the output
  # format would change between the multi-file tree scan and a one-file fixture call — and
  # the comment filter below, which skips past "file:line:", would then miss the "#".
  grep -nHE '(^|[|;&( ])(cmp|diff)[[:space:]]+-' "$@" 2>/dev/null |
    grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' |
    grep -vE 'git[^|;&]*[[:space:]]diff[[:space:]]' || true
}
# Fixtures first: prove the matcher catches a real call and the exemption spares every git
# form actually used in this repo, before trusting its verdict on the tree.
_du_fx="$(mktemp -d "$SANDBOX/diffutils.XXXXXX")"
# The offending literals are ASSEMBLED, never written out, because this fixture lives inside
# a file the gate itself scans — spelled directly, test-core.sh would flag its own test data
# and the only fixes would be to stop scanning the very file that carried the real bug, or to
# stop testing the gate. (Same reason the pipefail scanner has a "does not flag its own
# definition" case.)
_du_d=diff _du_c=cmp
{
  printf 'if %s -u "$a" "$b" >/dev/null; then echo same; fi\n' "$_du_d"
  printf '%s -s "$a" "$b" && echo identical\n' "$_du_c"
  printf 'git log --oneline | %s -u - expected.txt\n' "$_du_d"
} >"$_du_fx/bad.sh"
cat >"$_du_fx/good.sh" <<'DUGOOD'
if git diff --quiet HEAD -- "$f"; then echo clean; fi
git --no-pager diff --no-index -- "$a" "$b"
git -C "$path" diff --cached --quiet
git -C "$path" diff --cached --quiet -- core
DUGOOD
# The commented-out call goes in the same assembled way, for the same reason.
printf '# %s -u is fine in a comment\n' "$_du_d" >>"$_du_fx/good.sh"
_du_bad="$(_diffutils_hits "$_du_fx/bad.sh" | wc -l | tr -d ' ')"
_du_good="$(_diffutils_hits "$_du_fx/good.sh" | wc -l | tr -d ' ')"
if [[ "$_du_bad" == 3 ]]; then
  pass "diffutils gate: catches diff, cmp, and a diff piped from git (3/3)"
else
  fail "diffutils gate: missed a real cmp/diff call (found $_du_bad of 3)"
fi
if [[ "$_du_good" == 0 ]]; then
  pass "diffutils gate: every git-subcommand form and a comment are exempt (no false fires)"
else
  fail "diffutils gate: false-fired on a legitimate git diff — $(_diffutils_hits "$_du_fx/good.sh" | tr '\n' ' ')"
fi
if _diffutils_hits "$HERE/scripts"/*.sh "$HERE/scripts/lib"/*.sh | grep -q .; then
  fail "a script calls cmp/diff again — use core_files_identical (#572)"
else
  pass "no script calls cmp (diffutils stays optional)"
fi
