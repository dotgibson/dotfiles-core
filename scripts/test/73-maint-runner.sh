# scripts/test/73-maint-runner.sh
# maint runner stdin contract + step() on a TTY
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── maint RUNNER stdin contract (hermetic, bash — the runner is not zsh) ──────
# The runner is unattended but inherits whatever stdin started it (a terminal, via
# `maint-run`). Every step's output goes to $LOG, so a step that PROMPTS asks its question
# where nobody can see it and then blocks on the tty forever — the run stops dead after the
# last ✓ with no error. THREE separate redirects prevent that, in three different shapes,
# and each is easy to drop in a refactor without any other test noticing:
#
#   step()          `"$@" </dev/null >>"$LOG" 2>&1`   — covers every labelled step
#   package count   `fi </dev/null` on the if/elif    — that chain is NOT a step()
#   mise bump       `</dev/null` on the $( ) probe    — a bare command substitution, and
#                                                       the only one whose stderr is
#                                                       /dev/null too, so a prompt there is
#                                                       invisible as well as blocking
#
# These extract the REAL definitions out of the runner rather than restating them, so the
# assertions track the shipped code: delete a redirect and the extracted text changes and
# the check fails. The extractors match the block boundaries only (`^step() {`..`^}`,
# `^count=-1`..`^fi`, and the `bump="$(_to ` assignment head), never the redirect itself —
# matching on `</dev/null` would make the test vacuously pass by finding nothing once the
# fix was gone.
#
# step() additionally has a SECOND arm (tty) that none of the above enters, since a command
# substitution is never a terminal; its own cases follow the package-count ones below.
hdr "maint runner stdin contract (unpromptable steps, hermetic)"
_MAINT_SH="$HERE/maint/dotfiles-maint.sh"
_MRT="$SANDBOX/maint-runner"
rm -rf "$_MRT"
mkdir -p "$_MRT/bin"

# A step that tries to eat a line of the caller's stdin. If step() has no redirect it
# succeeds and swallows the sentinel; with the redirect it reads EOF and the sentinel
# survives for the caller. Asserting on the SENTINEL (not on a hang) keeps a regression a
# fast failure — this suite has no timeout anywhere, so a test that detected the hang by
# hanging would wedge the run instead of reporting it.
if sed -n '/^step() {/,/^}/p' "$_MAINT_SH" >"$_MRT/step.bash" && [[ -s "$_MRT/step.bash" ]]; then
  if out="$(printf 'sentinel\n' | bash -c '
      LOG=/dev/null; log() { :; }
      . "'"$_MRT/step.bash"'"
      step "eats stdin" sh -c "read -r stolen; echo \"STOLE=\$stolen\" >&2"
      read -r survivor || survivor=GONE
      printf "%s\n" "$survivor"
    ' 2>/dev/null)" && [[ "$out" == sentinel ]]; then
    pass "maint: step() cannot consume the caller's stdin (unpromptable)"
  else
    fail "maint: step() cannot consume the caller's stdin (unpromptable) — got '${out:-}'"
  fi
else
  fail "maint: could not extract step() from ${_MAINT_SH##*/}"
fi

# Same contract, different construct: the upgradable-count chain is a bare if/elif, so it
# carries its own `</dev/null` on the `fi`. Driven with a prompting stub manager (the live
# case is dnf5 asking to import a repo_gpgcheck key into the per-user keyring, forever,
# because a declined import is never persisted).
printf '#!/bin/sh\nprintf "Import key? [y/N]: "\nread -r a\nprintf "pkg-alpha 1.0 updates\\n"\n' >"$_MRT/bin/stubmgr"
chmod +x "$_MRT/bin/stubmgr"
#
# The chain goes through _pkgcount_decl, so that helper is extracted alongside the chain
# (same block-boundary rule as step()). _to stays STUBBED here — this case is about stdin,
# and the real timeout is exercised by the separate case below.
#
# cap_declared/cap ARE THE FIXTURE NOW (#763). The chain used to end in a seven-arm
# `have brew / checkupdates / pacman / dnf / zypper / apt-get / apk` ladder, and this case
# shadowed every arm onto the prompting stub to be deterministic on any host. That ladder is
# gone: an undeclared box runs nothing at all, so the declaration IS the input, and stubbing
# the two reader functions is both simpler and closer to what a real box does.
sed -n '/^_pkgcount_decl() {/,/^}/p' "$_MAINT_SH" >"$_MRT/pkgcount.bash"
if sed -n '/^count=-1$/,/^fi/p' "$_MAINT_SH" >"$_MRT/count.bash" &&
  [[ -s "$_MRT/count.bash" && -s "$_MRT/pkgcount.bash" ]]; then
  if out="$(printf 'sentinel\n' | bash -c '
      _to() { shift; "$@"; }
      cap_declared() { return 0; }
      cap() { [ "$1" = PKG_COUNT_PENDING ] && printf "stubmgr"; return 0; }
      . "'"$_MRT/pkgcount.bash"'"
      MAINT_PKGCOUNT_TIMEOUT=30
      PATH="'"$_MRT/bin"'":$PATH
      . "'"$_MRT/count.bash"'" >/dev/null 2>&1
      read -r survivor || survivor=GONE
      printf "%s\n" "$survivor"
    ' 2>/dev/null)" && [[ "$out" == sentinel ]]; then
    pass "maint: package-count chain cannot consume the caller's stdin (unpromptable)"
  else
    fail "maint: package-count chain cannot consume the caller's stdin (unpromptable) — got '${out:-}'"
  fi
else
  fail "maint: could not extract the package-count chain from ${_MAINT_SH##*/}"
fi

# Same contract, a THIRD construct: the `mise outdated --bump` probe is a bare command
# substitution, not a step() call, so it carries its own `</dev/null`. It is also the one
# command in the run whose stderr goes to /dev/null, so a mise that prompts here asks a
# question that is invisible AND blocking — the worse of the two shapes, and the reason this
# case exists separately from step()'s. Driven with a prompting stub mise (the live case is
# mise asking whether to trust a config path).
printf '#!/bin/sh\nprintf "Trust config file? [y/N]: "\nread -r a\nprintf "node lts 24.19.0 [NONE] 26.8.1 config.toml\\n"\n' >"$_MRT/bin/stubmise"
chmod +x "$_MRT/bin/stubmise"
# Extracted by the assignment's HEAD (`bump="$(_to `), never by the redirect — matching
# `</dev/null` would find nothing once the fix was gone and pass vacuously, the same trap
# the two cases above are written around.
if sed -n '/^  bump="\$(_to /p' "$_MAINT_SH" >"$_MRT/bump.bash" && [[ -s "$_MRT/bump.bash" ]]; then
  if out="$(printf 'sentinel\n' | bash -c '
      _to() { shift; "$@"; }
      MAINT_MISE_TIMEOUT=30
      PATH="'"$_MRT/bin"'":$PATH
      mise() { stubmise "$@"; }
      . "'"$_MRT/bump.bash"'"
      read -r survivor || survivor=GONE
      printf "%s\n" "$survivor"
    ' 2>/dev/null)" && [[ "$out" == sentinel ]]; then
    pass "maint: the mise bump probe cannot consume the caller's stdin (unpromptable)"
  else
    fail "maint: the mise bump probe cannot consume the caller's stdin (unpromptable) — got '${out:-}'"
  fi
else
  fail "maint: could not extract the mise bump probe from ${_MAINT_SH##*/}"
fi

# ── step() on a TTY: mirrors to the terminal, and still reports the COMMAND's rc ──────
# The other arm of the same function. `maint-run` is a foreground run, and a step that
# prints nothing for the tens of minutes a musl source build takes is indistinguishable
# from a wedged one — so the operator interrupts it and the build is lost. The tty arm
# exists to make that visible, and it needs a REAL terminal to enter, hence the pty.
#
# Four assertions, because the arm has four ways to be wrong and only the first is obvious:
# it can fail to mirror; it can lose the command's rc entirely; it can double-write $LOG;
# and — the subtle one — it can report `tee`'s status instead of the command's.
#
# That last one needs its own case, and a specific one. Under `pipefail` a plain `rc=$?`
# after the pipeline returns 7 for a step that exited 7, so a failing-step fixture cannot
# tell `${PIPESTATUS[0]}` from `$?` at all — it passes either way and proves nothing. The
# two diverge only when TEE fails and the COMMAND succeeds, which is the real-world case
# (a full disk, an unwritable $LOG): PIPESTATUS[0] correctly reports the step's own 0, while
# `$?` under pipefail reports tee's failure and blames the step for it. So the fourth case
# points $LOG at a directory to make tee fail, and asserts the successful step still logs ✓.
if have python3; then
  cat >"$_MRT/tty-harness.sh" <<HARNESS
LOG="$_MRT/tty.log"; : >"\$LOG"
log() { printf '%s\n' "\$*" >>"\$LOG"; }
. "$_MRT/step.bash"
step "mirror" sh -c 'echo MIRRORED; exit 7'
HARNESS
  python3 - "$_MRT" <<'PYPTY' >/dev/null 2>&1
import os, pty, sys
mrt = sys.argv[1]
buf = []
def rd(fd):
    d = os.read(fd, 1024)
    buf.append(d)
    return d
pty.spawn(["bash", mrt + "/tty-harness.sh"], rd)
open(mrt + "/pty.out", "wb").write(b"".join(buf))
PYPTY
  _tty_seen="$(tr -d '\r' <"$_MRT/pty.out" 2>/dev/null | grep -c '^MIRRORED$' || true)"
  _tty_logged="$(grep -c '^MIRRORED$' "$_MRT/tty.log" 2>/dev/null || true)"
  _tty_rc="$(grep -c 'rc=7' "$_MRT/tty.log" 2>/dev/null || true)"
  if [[ "${_tty_seen:-0}" -ge 1 ]]; then
    pass "maint: step() mirrors to the terminal when stdout is a tty"
  else
    fail "maint: step() mirrors to the terminal when stdout is a tty — nothing reached the pty"
  fi
  if [[ "${_tty_rc:-0}" -ge 1 ]]; then
    pass "maint: step() reports the command's rc on a tty (a failing step is logged as failed)"
  else
    fail "maint: step() reports the command's rc on a tty — rc=7 never logged"
  fi
  if [[ "${_tty_logged:-0}" == 1 ]]; then
    pass "maint: step()'s tty arm writes \$LOG exactly once (tee, not a second append)"
  else
    fail "maint: step()'s tty arm writes \$LOG exactly once — got ${_tty_logged:-0} copies"
  fi

  # The PIPESTATUS case proper: tee fails (its target is a DIRECTORY), the step succeeds.
  # `pipefail` is set here deliberately — it is set in the real runner, and it is exactly
  # what turns a naive `rc=$?` into a wrong answer.
  mkdir -p "$_MRT/unwritable"
  cat >"$_MRT/tee-harness.sh" <<HARNESS
set -o pipefail
LOG="$_MRT/unwritable"
OBS="$_MRT/tee.obs"; : >"\$OBS"
log() { printf '%s\n' "\$*" >>"\$OBS"; }
. "$_MRT/step.bash"
step "tee-fails" sh -c 'echo X; exit 0'
HARNESS
  python3 -c "
import os, pty, sys
pty.spawn(['bash', sys.argv[1]], lambda fd: os.read(fd, 1024))" "$_MRT/tee-harness.sh" >/dev/null 2>&1
  if grep -q '✓ tee-fails' "$_MRT/tee.obs" 2>/dev/null; then
    pass "maint: a step that SUCCEEDS is not blamed for a failing tee (PIPESTATUS, not \$?)"
  else
    fail "maint: a step that SUCCEEDS is not blamed for a failing tee — got '$(tr '\n' ' ' <"$_MRT/tee.obs" 2>/dev/null)'"
  fi
else
  skip "maint: step() tty arm (python3 not available — no pty to allocate)"
fi

# ── the neovim step reports the SESSION's outcome, not nvim's exit status (#829) ──────
# `nvim --headless` exits 0 when a `-c` command FAILS: the error goes to stderr and the
# process still succeeds. step() is not at fault — PIPESTATUS[0] is the right status to read
# — but the status it reads carried no information about whether anything ran. A box whose
# config aborts at load logged a green ✓ over a session that did nothing, indefinitely, and
# under the systemd timer nothing would ever surface it. So the arms record their failures and
# a final -c turns a non-empty record into a real rc via `:cq`.
#
# The argv under test is the SHIPPED one — extracted by sourcing the real step invocation with
# step/_to/nvim stubbed, so the stub captures exactly the arguments the runner passes. Building
# a hand-written copy here would let the two drift and prove nothing about what actually runs.
#
# The session itself is hermetic: `--clean` plus --cmd-injected stand-ins for the three arms
# (a Lazy command, a preloaded nvim-treesitter, a mason module + its command). No config, no
# network, no plugin manager. The negative case removes ONE stand-in — the Lazy command — which
# is precisely the live failure from the report, where lazy.nvim never loaded and `:Lazy! sync`
# did not exist.
hdr "maint neovim step: a session in which nothing ran is not a ✓ (#829)"
if have nvim; then
  if sed -n '/^  step "neovim: Lazy sync/,/^    "+qa!"$/p' "$_MAINT_SH" >"$_MRT/nvimstep.bash" &&
    [[ -s "$_MRT/nvimstep.bash" ]]; then
    # Capture the shipped argv. NUL-delimited so an argument containing whitespace (every
    # -c lua arm does) survives the round trip intact.
    bash -c '
      step() { shift; "$@"; }
      _to()  { shift; "$@"; }
      MAINT_NVIM_TIMEOUT=1
      nvim() { printf "%s\0" "$@" >"'"$_MRT/nvim.argv"'"; }
      . "'"$_MRT/nvimstep.bash"'"
    ' >/dev/null 2>&1
    _nvargv=()
    if [[ -s "$_MRT/nvim.argv" ]]; then mapfile -t -d '' _nvargv <"$_MRT/nvim.argv"; fi
    # Drop the leading --headless; this harness supplies its own flags.
    _nvarms=()
    for _a in "${_nvargv[@]}"; do [[ "$_a" == "--headless" ]] && continue; _nvarms+=("$_a"); done

    # The three stand-ins, as --cmd (they must exist BEFORE the -c arms run).
    _ts_stub='lua package.preload["nvim-treesitter"] = function() return { update = function() return { wait = function() end } end } end; package.preload["nvim-treesitter.config"] = function() return { get_installed = function() return {} end } end; package.preload["mason"] = function() return {} end'
    _lazy_stub='command! -bang -nargs=* Lazy echo ""'
    _mason_stub='command! MasonUpdate echo ""'

    if ((${#_nvarms[@]} == 0)); then
      fail "maint: could not capture the neovim step's argv from ${_MAINT_SH##*/}"
    else
      # Positive: every arm can run → the step must succeed, or the fix would red every
      # healthy box and get reverted.
      nvim --clean --headless \
        --cmd "$_ts_stub" --cmd "$_lazy_stub" --cmd "$_mason_stub" \
        "${_nvarms[@]}" >/dev/null 2>&1
      _nv_ok=$?
      # Negative: no :Lazy command — the reported failure exactly. nvim still exits 0 on its
      # own; only the sentinel makes this visible.
      nvim --clean --headless \
        --cmd "$_ts_stub" --cmd "$_mason_stub" \
        "${_nvarms[@]}" >/dev/null 2>&1
      _nv_bad=$?

      if ((_nv_ok == 0)); then
        pass "maint: the neovim step still exits 0 when every arm runs"
      else
        fail "maint: the neovim step must exit 0 when every arm runs — got rc=$_nv_ok"
      fi
      if ((_nv_bad != 0)); then
        pass "maint: a neovim arm that FAILED exits non-zero (no ✓ over a session that did nothing)"
      else
        fail "maint: a failing neovim arm still exits 0 — the false ✓ of #829 is back"
      fi
    fi
  else
    fail "maint: could not extract the neovim step from ${_MAINT_SH##*/}"
  fi
else
  skip "maint: neovim step outcome (nvim not available)"
fi

# A package probe that TIMES OUT must leave the -1 "we don't know" sentinel, not 0.
# The old chain was `count=$(_to … <mgr> | grep -c …)`: when timeout SIGTERMs a stalled
# manager there is no output, grep prints 0, and grep's non-zero status — the pipeline's —
# is discarded by the assignment. So the daily log asserted "0 upgradable" (an up-to-date
# box) on exactly the failure the timeout was added to survive, and the sentinel two lines
# above the chain could never fire. This drives the REAL _to and _pkgcount_decl (only the
# declaration reader is stubbed — the point is the status `timeout` itself reports) against a
# manager that stalls forever,
# with the bound turned down to 1s so the case costs about a second.
#
# That status is NOT one number across the fleet, which is why the observed rc is carried
# into the failure message: GNU coreutils reports expiry as 124, while BUSYBOX reports its
# SIGTERM as 143. A 124-only gate passed everywhere except Alpine, where this case caught it
# reporting a stalled manager as 0 — so if a future userland picks a third spelling, the
# failure here names it instead of just saying "want -1".
#
# The stall stub is a REAL EXECUTABLE named `brew`, not a shell function: `timeout` execs its
# argument, so it cannot run a function (it would fail 127 and the case would pass for the
# wrong reason). `exec sleep` so the stub process IS the sleep and takes the SIGTERM directly
# instead of orphaning a 30s child. The declaration names it as the count verb, so this is
# the path a real box takes on any host.
if have timeout; then
  printf '#!/bin/sh\nexec sleep 30\n' >"$_MRT/bin/brew"
  chmod +x "$_MRT/bin/brew"
  sed -n '/^_to() {/,/^}/p' "$_MAINT_SH" >"$_MRT/to.bash"
  if [[ -s "$_MRT/to.bash" && -s "$_MRT/pkgcount.bash" && -s "$_MRT/count.bash" ]]; then
    if out="$(bash -c '
        PATH="'"$_MRT/bin"'":$PATH
        have() { command -v "$1" >/dev/null 2>&1; }
        cap_declared() { return 0; }
        cap() { [ "$1" = PKG_COUNT_PENDING ] && printf "brew outdated --quiet"; return 0; }
        . "'"$_MRT/to.bash"'"
        . "'"$_MRT/pkgcount.bash"'"
        MAINT_PKGCOUNT_TIMEOUT=1
        . "'"$_MRT/count.bash"'" >/dev/null 2>&1
        # The raw status too, so a userland whose timeout reports neither 124 nor 128+n is
        # named by the failure rather than merely disagreeing with it.
        _to 1 brew >/dev/null 2>&1
        printf "%s %s\n" "$count" "$?"
      ' 2>/dev/null)" && [[ "${out%% *}" == -1 ]]; then
      pass "maint: a timed-out package probe reports the -1 sentinel, not 0 upgradable (timeout rc=${out##* })"
    else
      fail "maint: a timed-out package probe reports count='${out%% *}' at timeout rc=${out##* } (want count -1 — 0 would log the box as up to date)"
    fi
  else
    fail "maint: could not extract _to/_pkgcount_decl from ${_MAINT_SH##*/}"
  fi
else
  skip "maint timed-out package probe (no \`timeout\` — _to runs the command unbounded)"
fi

# …and pin the BUSYBOX spelling on EVERY host, not just the Alpine leg of the matrix. The
# case above asserts whatever the local timeout happens to report, so on a GNU box it only
# ever proves the 124 arm — which is exactly how a 124-only gate reached CI green here and
# red on Alpine. A fake `timeout` that exits 143 (128+SIGTERM, busybox's spelling) makes the
# other arm deterministic and instant: no sleeping, and `brew` succeeds immediately, so the
# ONLY thing that can produce -1 is _pkgcount_decl reading the wrapper's status.
printf '#!/bin/sh\nexit 143\n' >"$_MRT/bin/timeout"
printf '#!/bin/sh\nexit 0\n' >"$_MRT/bin/brew"
chmod +x "$_MRT/bin/timeout" "$_MRT/bin/brew"
sed -n '/^_to() {/,/^}/p' "$_MAINT_SH" >"$_MRT/to.bash"
if [[ -s "$_MRT/to.bash" && -s "$_MRT/pkgcount.bash" && -s "$_MRT/count.bash" ]]; then
  if out="$(bash -c '
      PATH="'"$_MRT/bin"'":$PATH
      have() { command -v "$1" >/dev/null 2>&1; }
      cap_declared() { return 0; }
      cap() { [ "$1" = PKG_COUNT_PENDING ] && printf "brew outdated --quiet"; return 0; }
      . "'"$_MRT/to.bash"'"
      . "'"$_MRT/pkgcount.bash"'"
      MAINT_PKGCOUNT_TIMEOUT=1
      . "'"$_MRT/count.bash"'" >/dev/null 2>&1
      printf "%s\n" "$count"
    ' 2>/dev/null)" && [[ "$out" == -1 ]]; then
    pass "maint: a busybox-style timeout (143, not 124) also reports the -1 sentinel"
  else
    fail "maint: a busybox-style timeout (143) reports '${out:-}' (want -1 — this is the Alpine regression)"
  fi
else
  fail "maint: could not extract _to/_pkgcount_decl from ${_MAINT_SH##*/}"
fi
rm -f "$_MRT/bin/timeout" "$_MRT/bin/brew"

# update.zsh: the first-run welcome (U2 — the cheat-sheet discoverability hint) must
# greet EXACTLY ONCE per machine. Drive _core_welcome directly (the TTY gate lives at
# its call site, so a captured run can exercise the greet+sentinel logic): first call
# prints the `core` front-door pointer and persists the sentinel; a second call is silent.
# An isolated XDG_STATE_HOME keeps the sentinel out of the shared sandbox.
ucheck "update: _core_welcome greets once, then the sentinel silences it" \
  "source '$UPD'; o1=\$(_core_welcome); [[ \$o1 == *\"run 'core'\"* ]] || exit 1; [[ -e \$XDG_STATE_HOME/dotfiles-core/.welcomed ]] || exit 1; o2=\$(_core_welcome); [[ -z \$o2 ]]" \
  XDG_STATE_HOME="$SANDBOX/welcome-once" NO_COLOR=1 UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# …and the startup hook stays SILENT without an interactive tty (captured/piped/CI):
# sourcing update.zsh prints no greet and writes no sentinel, so it never spams logs.
ucheck "update: welcome stays silent (no greet, no sentinel) without a tty" \
  "o=\$(source '$UPD'); [[ \$o != *'dotfiles Core loaded'* && ! -e \$XDG_STATE_HOME/dotfiles-core/.welcomed ]]" \
  XDG_STATE_HOME="$SANDBOX/welcome-notty" NO_COLOR=1 UPDATE_CHECK_ENABLED=0 CORE_WELCOME=1

# completions (U3 / DERIVED regression gate): every first-party PUBLIC verb must have a
# #compdef that compinit resolves off the vendored fpath dir — a missing/typo'd tag
# means no tab-completion for that command across all nine repos, with nothing else to
# catch it. The verb set is DERIVED from the source (top-level functions whose names
# don't start with `_`, Core's private-helper convention) minus an explicit allowlist
# of public-but-non-completable functions: the zsh-vi-mode init HOOK, the git-alias
# helpers, and the internal plugin updater — none are user verbs. So a NEW verb shipped
# WITHOUT a completion now FAILS here — the regression the OLD hardcoded list couldn't
# catch (it silently omitted update-check + opssh, which had no completion at all). This
# mirrors audit-core.sh's META_ALLOWLIST pattern: derive from the tree, exempt by name.
# `cheat` (alias → core-help) is appended so the aliased #compdef tag is exercised too.
COMP_ALLOWLIST=" git_main_branch git_current_branch zvm_after_init zplugin-update "
COMP_VERBS=()
while IFS= read -r _v; do
  case " $COMP_ALLOWLIST " in *" $_v "*) continue ;; esac
  COMP_VERBS+=("$_v")
done < <(grep -rhoE '^(function[[:space:]]+)?[A-Za-z][A-Za-z0-9_-]*\(\)|^function[[:space:]]+[A-Za-z][A-Za-z0-9_-]*[[:space:]]*\{' "$HERE"/zsh/*.zsh |
  sed -E 's/^function[[:space:]]+//; s/\(\).*//; s/[[:space:]]*\{.*//' |
  grep -vE '^_' | sort -u)
COMP_VERBS+=(cheat)
ucheck "completions: every first-party verb has a compinit-resolved completion (derived)" \
  "fpath=('$HERE/zsh/completions' \$fpath); autoload -Uz compinit && compinit -u -d '$SANDBOX/zcd-comp' >/dev/null 2>&1; for c in ${COMP_VERBS[*]}; do [[ -n \${_comps[\$c]:-} ]] || { print \"no completion registered for: \$c\"; exit 1; }; done"

# core-help coverage: the cheat sheet is a HAND-MAINTAINED rows=() array — so a new
# verb is trivially forgotten and the one discoverability surface silently drifts from
# reality, with nothing to catch it across nine repos. Derive the public-verb set from the
# source (same technique as the completion gate above), then assert each appears in the
# RENDERED core-help output (rows OR the footer line, where the op/health/front-door verbs
# live). `cheat` is the alias and `core` is the dispatcher whose own help IS the sheet —
# both exempt. A verb shipped without a sheet entry now FAILS here. ui.zsh + functions.zsh
# are sourced so core-help renders; NO_COLOR keeps the match on plain text.
HELP_ALLOWLIST=" $COMP_ALLOWLIST cheat core "
HELP_VERBS=()
for _v in "${COMP_VERBS[@]}"; do
  case "$HELP_ALLOWLIST" in *" $_v "*) continue ;; esac
  HELP_VERBS+=("$_v")
done
ucheck "core-help lists every first-party verb (derived coverage gate)" \
  "source '$UI'; source '$FN'; sheet=\$(COLUMNS=200 core-help 2>&1); for v in ${HELP_VERBS[*]}; do [[ \" \$sheet \" == *\" \$v \"* || \$sheet == *\"\$v \"* || \$sheet == *\" \$v\"* ]] || { print \"verb missing from core-help: \$v\"; exit 1; }; done" \
  NO_COLOR=1

# completion ↔ source flag drift: the coverage test above proves a completion EXISTS;
# this proves its FLAGS still match the verb. Every long flag a flag-bearing completion
# advertises must still be mentioned in the verb's zsh source — so removing `--dry-run`
# from `up` (or renaming `--local`) without updating its #compdef now FAILS here instead
# of silently shipping a completion that offers a flag the verb rejects to all nine repos.
# Pure sed+grep (busybox-safe); comment lines in the completion are stripped first.
