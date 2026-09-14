# scripts/test/37-bootstrap-driver.sh — blib_main, the bootstrap driver (#976), driven end to end
# ──────────────────────────────────────────────────────────────────────────────
# A SOURCED FRAGMENT of scripts/test-core.sh, not a standalone script: it runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh.
#
# WHAT IT PINS. The driver is the shared skeleton nine bootstraps hand-rolled, so the
# contract worth a test is the ORDER and the GATING: a hook that must not run under
# --links-only, provisioning that must never run under --dry-run, an escalator demanded
# only when there is something to install, misses that change the exit code only under
# --strict, and a repo flag the driver hands to the hook rather than rejecting. Proven by
# a fixture repo — the real Core tree copied in, a fake role layer, and a bootstrap.sh
# whose hooks write their name to a log — so the assertions are about behaviour, not text.
if have git; then
  hdr "bootstrap driver (blib_main against a fixture repo)"
  BD="$SANDBOX/driver"
  rm -rf "$BD"
  mkdir -p "$BD/home" "$BD/config/tmux/plugins/tpm" "$BD/dotfiles/core" "$BD/dotfiles/defense/templates"
  # Same copy-per-directory as 34-link-run.sh, for the same reason (chmod +x inside
  # blib_link_core must never touch the checkout the audit is reading concurrently).
  for _bd_d in zsh nvim tmux vim git starship lazygit mise jujutsu atuin tealdeer sesh ssh bin lib; do
    [[ -e "$HERE/$_bd_d" ]] && cp -R "$HERE/$_bd_d" "$BD/dotfiles/core/$_bd_d"
  done
  printf '# fixture role layer\n' >"$BD/dotfiles/defense/defense.zsh"
  printf 'fixture template\n' >"$BD/dotfiles/defense/templates/README"
  cat >"$BD/dotfiles/bootstrap.sh" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
source "$DOTFILES/core/lib/ux.sh"
source "$DOTFILES/core/lib/bootstrap-lib.sh"
BOOTSTRAP_NAME="Fixture"
BOOTSTRAP_ROLE=defense
BOOTSTRAP_LOGIN_SHELL=0
DO_CHECK=1
_log() { printf '%s\n' "$1" >>"${FIX_LOG:?}"; }
bootstrap_usage() { printf 'fixture bootstrap — wires a fake role layer\n  --no-check   skip the probe\n'; }
bootstrap_flag() {
  case "$1" in
  --no-check) DO_CHECK=0; return 0 ;;
  --fix-policy=*) BOOTSTRAP_STRICT_DEFAULT=1; BOOTSTRAP_FAIL_EXIT="${1#*=}"; return 0 ;;
  --fix-take) _log "flag:$2"; return 2 ;;
  esac
  return 1
}
bootstrap_guard() { _log guard; }
# `((BLIB_DRY))` BARE, on purpose: the fixture runs under set -u, so this line is the
# regression test for a driver that leaves the knob unset on a real run (Debian#78).
bootstrap_check() { ((DO_CHECK)) || return 0; ((BLIB_DRY)) && _log dry; _log check; }
[[ "${FIX_LAZY:-0}" != 0 ]] && BOOTSTRAP_SU=lazy
if [[ "${FIX_PROVISION:-0}" != 0 ]]; then
  bootstrap_provision() {
    _log provision
    # Under lazy the driver must have resolved nothing and primed nothing before us.
    [[ "${BOOTSTRAP_SU:-}" == lazy && -z "${BLIB_SU+x}" && -z "${BLIB_SUDO_KEEPALIVE_PID:-}" ]] && _log lazy-clean
    [[ "${FIX_FAIL:-0}" != 0 ]] && blib_note_fail "fixture step did not complete"
    return 0
  }
fi
bootstrap_wire_pre_loader() { _log wire_pre; [[ -e "$HOME/.zshrc" ]] && _log "LOADER-ALREADY-WRITTEN"; return 0; }
bootstrap_wire_post_loader() { _log wire_post; blib_link "$DOTFILES/defense/defense.zsh" "$CONFIG/fixture-extra.zsh"; }
bootstrap_closing() { _log "closing:$1"; BLIB_NEXT_HINT="then: exec zsh"; return 0; }
blib_main "$@"
FIX
  _bd_run() { # _bd_run <log-name> <args…> — sets BD_OUT / BD_RC; fresh HOME+config each time
    local log="$BD/$1.log"; shift
    rm -rf "${BD:?}/home" "${BD:?}/config"
    mkdir -p "$BD/home" "$BD/config/tmux/plugins/tpm"
    : >"$log"
    local -a _bd_env=(HOME="$BD/home" XDG_CONFIG_HOME="$BD/config" FIX_LOG="$log"
      FIX_PROVISION="${FIX_PROVISION:-0}" FIX_FAIL="${FIX_FAIL:-0}" FIX_LAZY="${FIX_LAZY:-0}"
      BLIB_ONLY="" BLIB_SKIP="")
    # BLIB_SU is set EMPTY (what CI does) unless a case needs the driver to see it unset.
    [[ "${BD_UNSET_SU:-0}" != 0 ]] || _bd_env+=(BLIB_SU='')
    BD_OUT="$(cd "$BD/dotfiles" && env -u BLIB_SU "${_bd_env[@]}" bash ./bootstrap.sh "$@" 2>&1)" && BD_RC=0 || BD_RC=$?
    BD_LOG="$(tr '\n' ' ' <"$log")"
    BD_LOG="${BD_LOG% }"
  }

  # ── help + usage errors ────────────────────────────────────────────────────
  _bd_run help --help
  if [[ $BD_RC -eq 0 && "$BD_OUT" == *"fixture bootstrap"*"--no-check"*"--links-only"*"--strict"* ]]; then
    pass "driver: --help prints the repo's banner and flags, then the shared flags, exit 0"
  else
    fail "driver: --help (rc=$BD_RC): $BD_OUT"
  fi
  _bd_run bogus --bogus
  if [[ $BD_RC -eq 2 && "$BD_OUT" == *"unknown flag: --bogus"* && -z "$BD_LOG" ]]; then
    pass "driver: an unknown flag exits 2 before any hook runs"
  else
    fail "driver: unknown flag (rc=$BD_RC, log='$BD_LOG'): $BD_OUT"
  fi
  _bd_run onlyval --only
  if [[ $BD_RC -eq 2 && "$BD_OUT" == *"--only requires module names"* ]]; then
    pass "driver: --only with no value is a usage error, not an empty selector"
  else
    fail "driver: bare --only (rc=$BD_RC): $BD_OUT"
  fi

  # ── links-only: wiring, no probe, no provisioning, no escalator demanded ───
  FIX_PROVISION=1 _bd_run links --links-only
  if [[ $BD_RC -eq 0 && "$BD_LOG" == "guard wire_pre wire_post closing:0" ]]; then
    pass "driver: --links-only runs guard → wire_pre → loader → wire_post → closing and skips the probe and provisioning"
  else
    fail "driver: --links-only order (rc=$BD_RC, log='$BD_LOG'): $BD_OUT"
  fi
  if [[ -L "$BD/config/zsh/85-defense.zsh" && -L "$BD/config/defense/templates" && -L "$BD/config/fixture-extra.zsh" && -L "$BD/config/zsh/loader.zsh" ]]; then
    pass "driver: Core, the band-85 role layer, its templates and the repo's extra link are wired"
  else
    fail "driver: links missing after --links-only under $BD/config"
  fi
  if grep -q 'dotfiles-managed v4' "$BD/home/.zshrc" 2>/dev/null; then
    pass "driver: the managed ~/.zshrc loader is written"
  else
    fail "driver: ~/.zshrc is not the managed loader"
  fi
  if [[ "$BD_OUT" == *"Fixture bootstrap complete — then: exec zsh"* ]]; then
    pass "driver: the closing line names the repo and honours BLIB_NEXT_HINT from the closing hook"
  else
    fail "driver: closing line not as expected: $(printf '%s' "$BD_OUT" | tail -2)"
  fi

  # ── full run: guard → check → provision → wire_extra → closing ─────────────
  FIX_PROVISION=1 _bd_run full
  if [[ $BD_RC -eq 0 && "$BD_LOG" == "guard check provision wire_pre wire_post closing:0" ]]; then
    pass "driver: a full run orders guard → check → provision → wire_pre → wire_post → closing (pre-loader before the loader is written)"
  else
    fail "driver: full-run order (rc=$BD_RC, log='$BD_LOG'): $(printf '%s' "$BD_OUT" | tail -3)"
  fi
  FIX_PROVISION=1 _bd_run nocheck --no-check
  if [[ $BD_RC -eq 0 && "$BD_LOG" == "guard provision wire_pre wire_post closing:0" ]]; then
    pass "driver: a repo flag (--no-check) is consumed by bootstrap_flag and honoured"
  else
    fail "driver: --no-check via the flag hook (rc=$BD_RC, log='$BD_LOG')"
  fi

  # ── dry-run: probe yes, provisioning never, nothing written ────────────────
  FIX_PROVISION=1 _bd_run dry --dry-run
  if [[ $BD_RC -eq 0 && "$BD_LOG" == "guard dry check wire_pre wire_post closing:0" && ! -e "$BD/config/zsh/85-defense.zsh" && ! -e "$BD/home/.zshrc" ]]; then
    pass "driver: --dry-run runs the probe, skips provisioning, and writes nothing"
  else
    fail "driver: --dry-run (rc=$BD_RC, log='$BD_LOG', wrote something under $BD/config/zsh)"
  fi
  if [[ "$BD_OUT" == *"dry run complete"* ]]; then
    pass "driver: a dry run closes as a dry run, not as a completed bootstrap"
  else
    fail "driver: dry-run closing line: $(printf '%s' "$BD_OUT" | tail -1)"
  fi

  # ── the failure tally and --strict ─────────────────────────────────────────
  FIX_PROVISION=1 FIX_FAIL=1 _bd_run miss
  if [[ $BD_RC -eq 0 && "$BD_LOG" == *"closing:1" && "$BD_OUT" == *"1 step(s) did not complete"* && "$BD_OUT" == *"finished WITH the misses above"* ]]; then
    pass "driver: a recorded miss is reported, hands degraded=1 to the closing hook, and still exits 0"
  else
    fail "driver: miss without --strict (rc=$BD_RC, log='$BD_LOG'): $(printf '%s' "$BD_OUT" | tail -3)"
  fi
  FIX_PROVISION=1 FIX_FAIL=1 _bd_run strict --strict
  if [[ $BD_RC -eq 1 && "$BD_OUT" == *"exiting non-zero (--strict)"* ]]; then
    pass "driver: the same miss under --strict exits 1"
  else
    fail "driver: miss under --strict (rc=$BD_RC): $(printf '%s' "$BD_OUT" | tail -2)"
  fi

  # ── declared exit policy: BOOTSTRAP_STRICT_DEFAULT / BOOTSTRAP_FAIL_EXIT ───
  FIX_PROVISION=1 FIX_FAIL=1 _bd_run policy2 --fix-policy=2
  if [[ $BD_RC -eq 2 && "$BD_OUT" == *"exiting non-zero"* ]]; then
    pass "driver: BOOTSTRAP_STRICT_DEFAULT=1 + BOOTSTRAP_FAIL_EXIT=2 make a miss exit 2 with no --strict (openSUSE's contract)"
  else
    fail "driver: declared exit policy (rc=$BD_RC): $(printf '%s' "$BD_OUT" | tail -2)"
  fi
  FIX_PROVISION=1 _bd_run flagval --fix-take next-value
  if [[ $BD_RC -eq 0 && "$BD_LOG" == "flag:next-value guard check provision wire_pre wire_post closing:0" ]]; then
    pass "driver: a bootstrap_flag that returns 2 consumes the value after it (the driver shifts twice)"
  else
    fail "driver: flag with value (rc=$BD_RC, log='$BD_LOG'): $(printf '%s' "$BD_OUT" | tail -2)"
  fi

  # ── BOOTSTRAP_SU=lazy: the hook owns escalation and the keepalive ──────────
  # BLIB_SU is deliberately UNSET here (the harness sets it empty for every other case):
  # an unset BLIB_SU is what lets blib_resolve_su probe, and the point is that the driver
  # must not probe, resolve or prime anything before a lazy hook decides it needs to.
  FIX_PROVISION=1 FIX_LAZY=1 BD_UNSET_SU=1 _bd_run lazy
  if [[ $BD_RC -eq 0 && "$BD_LOG" == "guard check provision lazy-clean wire_pre wire_post closing:0" ]]; then
    pass "driver: BOOTSTRAP_SU=lazy runs the provision hook with no escalator resolved and no keepalive primed"
  else
    fail "driver: lazy escalation (rc=$BD_RC, log='$BD_LOG'): $(printf '%s' "$BD_OUT" | tail -2)"
  fi

  # ── module selection reaches blib_select ───────────────────────────────────
  _bd_run skip --links-only --skip=zsh
  if [[ $BD_RC -eq 0 && ! -e "$BD/config/zsh/85-defense.zsh" && -L "$BD/config/starship.toml" ]]; then
    pass "driver: --skip=zsh drops the zsh group (and the role stage that rides it) while the rest wires"
  else
    fail "driver: --skip=zsh (rc=$BD_RC): 85-defense present=$([[ -e "$BD/config/zsh/85-defense.zsh" ]] && echo yes || echo no)"
  fi
  _bd_run badsel --links-only --only=nope
  if [[ $BD_RC -ne 0 && -z "$BD_LOG" ]]; then
    pass "driver: a malformed --only aborts before any hook runs (blib_select's own exit)"
  else
    fail "driver: --only=nope (rc=$BD_RC, log='$BD_LOG')"
  fi

  unset -f _bd_run
  unset BD BD_OUT BD_RC BD_LOG _bd_d
else
  skip "bootstrap driver: git not available (fixture copies the tree with git-aware tooling absent)"
fi
