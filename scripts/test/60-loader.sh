# scripts/test/60-loader.sh
# ZSH GATE, then the load-order smoke test, consumer integration and the caches
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── THE ZSH GATE (everything from this fragment on) ───────────────────────────
# This fragment and every one after it needs a real zsh. On a bare box we SKIP them (not
# fail) and end the run here, so a failure in one of the pure-bash fragments above still
# surfaces as exit 1. The gate lives at the TOP of the first zsh-dependent fragment
# rather than in the dispatcher because that is where the boundary actually is, and NN
# order is what puts every zsh-dependent fragment after it.
if ! ((SCOPE_SHELL)) || ! have zsh; then
  hdr "zsh behavioral sections (loader, functions, detection, maint, tmux)"
  if ! ((SCOPE_SHELL)); then
    skip "zsh behavioral sections (out of scope)"
  else
    skip "load-order smoke + function units (zsh not installed — runs in CI)"
  fi
  # Ends the whole run, from inside a sourced fragment — the fragments after this one are
  # the zsh-dependent ones, and that has been the shape since before the split. The ending
  # itself lives in the dispatcher so this path and the normal one cannot drift.
  _core_test_finish
fi

# ── load-order smoke test (drives the v4 numbered-fragment loader) ────────────
hdr "load-order smoke test (v4 numbered-fragment loader)"
# v4: an OS .zshrc sets ZSH_CFG and sources the vendored loader, which globs the
# numbered fragments (NN-*.zsh) in ZSH_CFG, sorts by NN, and sources each. We
# build a sandbox ZSH_CFG of SYMLINKS to the repo's Core fragments + the loader, then
# drive it exactly as a host would — exercising the REAL glob/sort/compile path, not a
# hand-rolled source loop. The .zwc land beside the symlinks in the sandbox, never the repo.
ZDOT="$SANDBOX/zdot"
mkdir -p "$ZDOT"
ln -s "$HERE/zsh/loader.zsh" "$ZDOT/loader.zsh"
core_frags=("$HERE"/zsh/[0-9][0-9]-*.zsh)
for f in "${core_frags[@]}"; do ln -s "$f" "$ZDOT/$(basename "$f")"; done

# Pre-seed empty plugin dirs at the v4 location ($XDG_DATA_HOME/zsh/plugins) so
# 45-plugins.zsh's first-run clone is a hermetic no-op (no network). The dir list lives
# once in common.sh (_seed_plugin_dirs), shared with the integration + bench.
_seed_plugin_dirs "$SANDBOX/data/zsh/plugins"

# Generate the sandbox .zshrc the v4 way: set ZSH_CFG, source the loader,
# print a sentinel. We deliberately do NOT key success on each fragment's exit code — a
# fragment whose LAST statement is a false guard (e.g. 20-aliases.zsh ends on
# `[[ -n $HAVE_GPING ]] && alias ping=gping`, false on a bare box) returns non-zero while
# having loaded perfectly. The real signal of a broken load-order contract is a RUNTIME
# error on stderr (a fragment using a fn/widget/var an EARLIER one must define first) — so
# we assert: the chain REACHED THE END (sentinel) with CLEAN stderr. Parse errors are
# already caught per-file by audit-core.sh's `zsh -n`.
{
  printf 'ZSH_CFG=%q\n' "$ZDOT"
  printf 'source "$ZSH_CFG/loader.zsh"\n'
  printf 'print -r -- "SMOKE_OK"\n'
} >"$ZDOT/.zshrc"

# Run one interactive zsh against the sandbox rc. We do NOT rely on zsh auto-sourcing
# $ZDOTDIR/.zshrc: a global /etc/zshenv can force ZDOTDIR (overriding the env we pass), and
# auto-load doesn't fire when stdout is captured (non-TTY). So -f disables rc auto-load, we
# set ZDOTDIR INSIDE -c (after /etc/zshenv ran) and `source` the rc explicitly; -i keeps the
# fragments' `[[ $- == *i* ]]` guards live. MISE_TRUSTED_CONFIG_PATHS pre-trusts the vendored
# mise config so `mise activate` doesn't abort under the sandbox HOME.
smoke_out="$(
  HOME="$SANDBOX" \
    XDG_CACHE_HOME="$SANDBOX/cache" XDG_STATE_HOME="$SANDBOX/state" \
    XDG_DATA_HOME="$SANDBOX/data" \
    XDG_RUNTIME_DIR="$SANDBOX/run" MISE_TRUSTED_CONFIG_PATHS="$HERE" \
    zsh -f -i -c "ZDOTDIR='$ZDOT'; source \"\$ZDOTDIR/.zshrc\"" 2>"$SANDBOX/smoke.err"
)"
# High-signal zsh runtime-error markers — what a real load-order break looks like.
smoke_errs="$(grep -Ei \
  'command not found|parse error|: no such file or directory|not defined|bad pattern|bad math expression|maximum nested' \
  "$SANDBOX/smoke.err" 2>/dev/null || true)"
if ! grep -q '^SMOKE_OK$' <<<"$smoke_out"; then
  fail "load-order chain did not reach the end (no SMOKE_OK sentinel — a fragment aborted)"
  [[ -s "$SANDBOX/smoke.err" ]] && sed 's/^/    /' "$SANDBOX/smoke.err" >&2
elif [[ -n "$smoke_errs" ]]; then
  fail "runtime errors during canonical load (load-order contract broken):"
  printf '%s\n' "$smoke_errs" | sed 's/^/    /' >&2
else
  pass "all ${#core_frags[@]} fragments loaded in NN order via the loader (clean stderr)"
fi

# ── consumer integration (Core + 80-os + 99-local via the loader) ─────────────
# Core NEVER loads alone in production: a host also carries the OS layer (80-os.zsh) and
# any machine overrides (99-local.zsh), both globbed by the loader from ZSH_CFG (bands
# globbed out of the same flat ZSH_CFG as Core's own). The smoke test above proves
# Core-in-isolation;
# this proves the documented CONSUMPTION — the Core→OS CONTRACT at the real fan-out shape.
# The 80-os stub uses exactly what an OS layer relies on Core to have left defined:
# _cache_eval (00-tools's API — NOT unfunctioned like _have is), _core_is_wsl (the second
# such API, added in #449 so six OS layers could stop re-deriving the same probe), the
# _core_* UX primitives (05-ui), and an alias override (the macOS rm→trash pattern).
# 99-local overrides a Core default. If Core ever stops exporting one of those, this fails
# — where the smoke test above, loading Core alone, would stay green.
#
# IT ALSO PROVES WHAT BAND 80 USED TO PROVE AND NO LONGER CAN. The direnv/gh/uv/ty inits
# moved into Core in #449, so the generate→cache→source path for the four tools the whole
# fleet installs is now Core's own code on the real loader — see the stub generators below.
hdr "consumer integration (Core + 80-os + 99-local, v4 loader)"
INTEG="$SANDBOX/integ"
mkdir -p "$INTEG"
ln -s "$HERE/zsh/loader.zsh" "$INTEG/loader.zsh"
for f in "${core_frags[@]}"; do ln -s "$f" "$INTEG/$(basename "$f")"; done
_seed_plugin_dirs "$SANDBOX/integ-data/zsh/plugins"
# 80-os.zsh: realistic OS-layer fragment. Exercises the Core helpers an OS repo depends
# on; any reference to an undefined helper prints to stderr (the failure signal below).
# Stub generators for the four tools Core now hooks itself (#449). A real box has some
# subset of these installed; the sandbox has none, so without stubs the helpers bail on
# ${commands[…]} and all four lines are silent no-ops that could rot unnoticed. (Side effect
# worth naming so nobody chases it: the `uv` stub sets HAVE_UV, so 20-aliases.zsh defines
# uvr/uvs. Harmless here.)
#
# TWO SHAPES, because the two mechanisms have different observable end states (#579):
#   direnv is still SOURCED, so its generated init is a sentinel print and the sentinel
#   reaching stdout proves generate→cache→source ran, at band 00, under the real loader.
#   gh/uv/ty are no longer sourced at all — they are written into an fpath dir and autoloaded
#   — so a sentinel print would prove nothing and never appear. Their stubs emit a REAL
#   clap_complete-shaped script (`#compdef` header + the autoload shim), and the assertion
#   below reads $_comps instead. That is the stronger claim anyway: it checks the completion
#   is REGISTERED for the command in a live shell, which is the user-facing fact, and it
#   survives a future change of mechanism without needing to be rewritten again.
INTEGBIN="$SANDBOX/integ-bin"
mkdir -p "$INTEGBIN"
printf '#!/bin/sh\nprintf "%%s\\n" "print -r -- CORE_INIT_DIRENV"\n' >"$INTEGBIN/direnv"
for _it in gh uv ty; do
  printf '#!/bin/sh\ncat <<STUB\n#compdef %s\n_%s() { _message CORE_INIT_%s }\nif [ "\$funcstack[1]" = "_%s" ]; then\n  _%s "\$@"\nelse\n  compdef _%s %s\nfi\nSTUB\n' \
    "$_it" "$_it" "$(printf '%s' "$_it" | tr '[:lower:]' '[:upper:]')" "$_it" "$_it" "$_it" "$_it" >"$INTEGBIN/$_it"
done
for _it in direnv gh uv ty; do chmod +x "$INTEGBIN/$_it"; done
unset _it
cat >"$INTEG/80-os.zsh" <<'OSZSH'
# stub 80-os.zsh — must be able to use the API Core promises the OS layer.
(( $+functions[_cache_eval] )) || print -u2 "80-os.zsh: _cache_eval missing (00-tools API gone)"
(( $+functions[_core_ok]    )) || print -u2 "80-os.zsh: _core_ok missing (05-ui API gone)"
(( $+functions[_core_is_wsl] )) || print -u2 "80-os.zsh: _core_is_wsl missing (00-tools API gone)"
# The shape all six WSL-carrying OS layers adopt in place of their deleted probe (#449).
# The answer does not matter here; that the call works from band 80 does.
if _core_is_wsl; then alias winopen='explorer.exe'; fi
# the documented gh/uv/ty pattern: _cache_eval a tool AFTER 10-options.zsh set NO_CLOBBER.
# The generator must emit SOURCEABLE zsh (real tools emit an init script); a comment is
# a valid no-op init and proves the generate→cache→source path works under NO_CLOBBER.
_cache_eval faketool printf '# faketool cached init (integration stub)\n' >/dev/null
alias rm='rm -i'   # OS layer overriding a safety net (macOS does rm→trash here)
OSZSH
# 99-local.zsh: machine-specific overrides (identity/toggles). Overriding a Core default
# is the whole reason it loads LAST (band 99).
cat >"$INTEG/99-local.zsh" <<'LOCALZSH'
# stub 99-local.zsh — last word on this machine.
UPDATE_CHECK_ENABLED=0
LOCALZSH
{
  printf 'ZSH_CFG=%q\n' "$INTEG"
  printf 'source "$ZSH_CFG/loader.zsh"\n'
  # Report the COMPLETION REGISTRATION for the three that are no longer sourced (#579).
  printf 'for _t in gh uv ty; do print -r -- "CORE_COMP_${(U)_t}=${_comps[$_t]:-NONE}"; done\n'
  printf 'print -r -- "INTEG_OK"\n'
} >"$INTEG/.zshrc"
integ_out="$(
  HOME="$SANDBOX" \
    XDG_CACHE_HOME="$SANDBOX/integ-cache" XDG_STATE_HOME="$SANDBOX/integ-state" \
    XDG_DATA_HOME="$SANDBOX/integ-data" \
    XDG_RUNTIME_DIR="$SANDBOX/run" MISE_TRUSTED_CONFIG_PATHS="$HERE" \
    PATH="$INTEGBIN:$PATH" \
    zsh -f -i -c "ZDOTDIR='$INTEG'; source \"\$ZDOTDIR/.zshrc\"" 2>"$INTEG/integ.err"
)"
integ_errs="$(grep -Ei \
  'command not found|parse error|: no such file or directory|not defined|missing|bad pattern|bad math expression|maximum nested' \
  "$INTEG/integ.err" 2>/dev/null || true)"
if ! grep -q '^INTEG_OK$' <<<"$integ_out"; then
  fail "consumer load (Core+80-os+99-local) did not reach the end — a layer aborted"
  [[ -s "$INTEG/integ.err" ]] && sed 's/^/    /' "$INTEG/integ.err" >&2
elif [[ -n "$integ_errs" ]]; then
  fail "errors during consumer load (Core→OS contract broken):"
  printf '%s\n' "$integ_errs" | sed 's/^/    /' >&2
else
  pass "Core + 80-os + 99-local loaded via the loader (Core→OS contract holds)"
fi

# The four tool inits Core took over from the OS layers in #449. Asserted individually
# rather than as a set: when this breaks it is nearly always ONE tool (a renamed generator
# subcommand, a line moved across a band boundary), and a combined check would only say
# "something".
#
# direnv is SOURCED, so the sentinel its stub prints must reach stdout.
if grep -q '^CORE_INIT_DIRENV$' <<<"$integ_out"; then
  pass "consumer load: Core sourced the DIRENV init (was the OS layer's job until #449)"
else
  fail "consumer load: Core never sourced the DIRENV init — the block is not reaching a real shell"
fi
# gh/uv/ty are NOT sourced (#579) — they are generated into an fpath dir at band 00 and
# autoloaded by compinit at band 10. So assert the end state that actually matters: the
# command is REGISTERED to the tool's own completion function, in a real shell, under the
# real loader and the real band order. This also pins the carapace-precedence half — the
# band-45 re-assert runs after carapace in this load, so a regression that let the bridge
# win would show up here as the wrong function name, not merely as an absent one.
for _it in GH UV TY; do
  _it_lc="$(printf '%s' "$_it" | tr '[:upper:]' '[:lower:]')"
  if grep -q "^CORE_COMP_$_it=_$_it_lc\$" <<<"$integ_out"; then
    pass "consumer load: the $_it completion is registered from fpath (_comps[$_it_lc] = _$_it_lc)"
  else
    fail "consumer load: the $_it completion never registered — got '$(grep -o "^CORE_COMP_$_it=.*" <<<"$integ_out")'"
  fi
done
unset _it _it_lc

# ── _cache_eval convergence (#580) ───────────────────────────────────────────
# _cache_eval decides "is this cache usable?" on `-s` alone, and it writes the generator's
# output straight at the destination. Both halves were wrong, and both failed SILENTLY —
# `2>/dev/null` is deliberate there (a generator's chatter must never be sourced), so a
# broken generator leaves nothing behind but the file itself.
#
# These fixtures drive the REAL _cache_eval, extracted from 00-tools.zsh by its own
# function header, against stub generators — the same "parse the shipped source, do not
# re-spell it" discipline the probe-coverage guards below use. Extracting rather than
# sourcing the whole file is deliberate: band 00 activates mise/atuin/starship against the
# host, which is neither hermetic nor fast.
#
# Each case runs the SAME shell twice. One run cannot tell "regenerated once" from
# "regenerates forever" — and forever is the actual defect.
hdr "_cache_eval convergence (#580)"
CEV="$SANDBOX/cache-eval"
mkdir -p "$CEV/bin"

# exits 0, prints nothing — a renamed/removed generator subcommand, the observed trigger.
printf '#!/bin/sh\nexit 0\n' >"$CEV/bin/ce-empty"
# prints a PARTIAL script, then fails — truncated init, the case that never self-heals.
printf '#!/bin/sh\nprintf %%s "alias ce=true\\nif [ "\nexit 1\n' >"$CEV/bin/ce-partial"
# prints nothing and fails — exit status alone would catch this one; -s alone would not.
printf '#!/bin/sh\nexit 3\n' >"$CEV/bin/ce-emptyfail"
# a healthy generator, to prove the fix does not break the path that always worked.
printf '#!/bin/sh\nprintf %%s "# ce good\\nalias cegood=true\\n"\n' >"$CEV/bin/ce-good"
chmod +x "$CEV/bin"/ce-*

# Run <tool> through _cache_eval N times in N separate shells; echo one line per run:
#   <size-in-bytes|MISSING> <would-regenerate-next: YES|no> <sourced-ok: ok|ERR>
_ce_runs() { # _ce_runs <tool> <count>
  local _i
  for _i in $(seq 1 "$2"); do
    XDG_CACHE_HOME="$CEV/cache" PATH="$CEV/bin:$PATH" HOME="$SANDBOX" \
      zsh -fc '
        setopt NO_CLOBBER   # 10-options.zsh sets this; the >| redirections depend on it
        eval "$(sed -n "/^_cache_eval() {/,/^}/p" "'"$HERE"'/zsh/00-tools.zsh")"
        _cache_eval '"$1"' '"$1"' && _ok=ok || _ok=ERR
        c="$XDG_CACHE_HOME/zsh/'"$1"'.zsh"
        if [[ -e "$c" ]]; then _sz=$(wc -c <"$c" | tr -d " "); else _sz=MISSING; fi
        printf "%s %s %s\n" "$_sz" "$([[ -s $c ]] && echo no || echo YES)" "$_ok"
      ' 2>/dev/null
  done
}

# 1. exits 0, prints nothing. Pre-fix: a 0-byte cache, so `-s` fails on EVERY later shell
#    and each one re-forks a generator that can never succeed — invisible, forever.
rm -rf "$CEV/cache"
_ce_out="$(_ce_runs ce-empty 2)"
if [[ -z "$(printf '%s\n' "$_ce_out" | awk '$2!="no"')" ]]; then
  pass "_cache_eval: a generator that exits 0 and prints nothing converges (no re-fork per shell)"
else
  fail "_cache_eval: empty-output generator never converges — every shell re-forks it"
  printf '%s\n' "$_ce_out" | sed 's/^/    /' >&2
fi

# 2. prints nothing AND fails. Same convergence requirement; separate case because a fix
#    that only checked $? would pass this and still leave case 1 broken.
rm -rf "$CEV/cache"
_ce_out="$(_ce_runs ce-emptyfail 2)"
if [[ -z "$(printf '%s\n' "$_ce_out" | awk '$2!="no"')" ]]; then
  pass "_cache_eval: a generator that prints nothing and exits non-zero converges"
else
  fail "_cache_eval: failing empty generator never converges"
  printf '%s\n' "$_ce_out" | sed 's/^/    /' >&2
fi

# 3. partial output then failure. `>|` truncates BEFORE the generator runs, so pre-fix the
#    cache held `alias ce=true\nif [ ` — non-empty AND newer than the binary, so BOTH halves
#    of the freshness test go false and that truncated init is sourced on every shell from
#    then on. Assert the fragment never lands, not merely that the run succeeded.
rm -rf "$CEV/cache"
_ce_runs ce-partial 2 >/dev/null
if [[ ! -f "$CEV/cache/zsh/ce-partial.zsh" ]] || ! grep -q 'if \[ *$' "$CEV/cache/zsh/ce-partial.zsh"; then
  pass "_cache_eval: a partially-written init is never installed (no truncated cache to source)"
else
  fail "_cache_eval: installed a TRUNCATED init — every later shell sources it"
  sed 's/^/    /' "$CEV/cache/zsh/ce-partial.zsh" >&2
fi

# 4. the last-good cache survives a generator that breaks later. Warm a good cache, then
#    swap the binary for a broken one and make it NEWER so the mtime half fires. Degrading
#    a working shell because a generator regressed is a strictly worse outcome than
#    serving yesterday's completions.
rm -rf "$CEV/cache"
printf '#!/bin/sh\nprintf %%s "# ce keep\\nalias cekeep=true\\n"\n' >"$CEV/bin/ce-keep"
chmod +x "$CEV/bin/ce-keep"
_ce_runs ce-keep 1 >/dev/null
printf '#!/bin/sh\nexit 0\n' >"$CEV/bin/ce-keep"
chmod +x "$CEV/bin/ce-keep"
touch "$CEV/bin/ce-keep"          # binary newer than cache -> the -nt half fires
_ce_out="$(_ce_runs ce-keep 2)"
if grep -q 'alias cekeep=true' "$CEV/cache/zsh/ce-keep.zsh" 2>/dev/null \
  && [[ -z "$(printf '%s\n' "$_ce_out" | awk '$2!="no"')" ]]; then
  pass "_cache_eval: keeps the last good cache when a generator breaks, and still converges"
else
  fail "_cache_eval: lost the last good cache (or kept re-forking) after a generator broke"
  printf '%s\n' "$_ce_out" | sed 's/^/    /' >&2
fi

# 5. the happy path still works — a fix that quarantined everything would pass 1-4.
rm -rf "$CEV/cache"
_ce_out="$(_ce_runs ce-good 2)"
if [[ -z "$(printf '%s\n' "$_ce_out" | awk '$2!="no" || $3!="ok"')" ]] \
  && grep -q 'alias cegood=true' "$CEV/cache/zsh/ce-good.zsh"; then
  pass "_cache_eval: a healthy generator still caches and sources its init"
else
  fail "_cache_eval: broke the working path"
  printf '%s\n' "$_ce_out" | sed 's/^/    /' >&2
fi
unset _ce_out

# ── _cache_completion: fpath autoload, not a source (#579) ────────────────────
# _cache_eval ends in `source`, which for uv means 6,976 lines read into EVERY interactive
# shell to serve a completion most shells never invoke — measured here at +35 ms per shell.
# _cache_completion writes the same generated text into an fpath directory instead. Same
# fixtures, same technique as the block above: extract the REAL function out of 00-tools.zsh
# and drive it across separate shells, so the code under test is the shipped code.
hdr "_cache_completion (fpath autoload)"
CCM="$SANDBOX/cachecomp"
rm -rf "$CCM"
mkdir -p "$CCM/bin"
# a healthy clap_complete-shaped generator: #compdef header + the autoload shim footer
printf '#!/bin/sh\nprintf %%s "#compdef cc-good\\n_cc-good() { _message ok }\\n"\n' >"$CCM/bin/cc-good"
# exits 0, prints nothing — the #580 shape, which must converge here too
printf '#!/bin/sh\nexit 0\n' >"$CCM/bin/cc-empty"
chmod +x "$CCM/bin"/cc-*

_cc_run() { # _cc_run <tool> → drives the real _cache_completion in a fresh shell
  XDG_CACHE_HOME="$CCM/cache" PATH="$CCM/bin:$PATH" HOME="$SANDBOX" \
    zsh -fc '
      setopt NO_CLOBBER   # 10-options.zsh sets this; the >| redirections depend on it
      eval "$(sed -n "/^_cache_completion() {/,/^}/p" "'"$HERE"'/zsh/00-tools.zsh")"
      _cache_completion '"$1"' '"$1"'
    ' 2>/dev/null
}

# 1. THE POINT OF THE CHANGE: it writes a file and sources NOTHING. A regression back to
#    `source` would still leave a working completion, so the only observable difference is
#    that the generator's output does not enter the calling shell.
rm -rf "$CCM/cache"
_cc_out="$(XDG_CACHE_HOME="$CCM/cache" PATH="$CCM/bin:$PATH" HOME="$SANDBOX" \
  zsh -fc '
    setopt NO_CLOBBER
    eval "$(sed -n "/^_cache_completion() {/,/^}/p" "'"$HERE"'/zsh/00-tools.zsh")"
    _cache_completion cc-good cc-good
    print -r -- "defined=${+functions[_cc-good]}"
  ' 2>/dev/null)"
if [[ -s "$CCM/cache/zsh/completions/_cc-good" ]] && [[ "$_cc_out" == "defined=0" ]]; then
  pass "_cache_completion: writes _<tool> into the fpath dir and sources nothing into the shell"
else
  fail "_cache_completion: did not write the fpath file, or leaked the completion into the shell ($_cc_out)"
fi

# 2. It lands in the CACHE dir, never in zsh/completions/ — that directory is Core's authored
#    set, listed per-file in core.manifest so an added file is a manifest failure.
if [[ ! -e "$HERE/zsh/completions/_cc-good" ]]; then
  pass "_cache_completion: generated files stay out of Core's authored zsh/completions/"
else
  fail "_cache_completion: wrote a generated completion into the manifest-checked authored dir"
fi

# 3. The compdump is invalidated on a regeneration. Without this the new file is INVISIBLE
#    for up to 24h: 10-options.zsh takes `compinit -C` when the dump is under a day old, and
#    -C skips the scan for new completion functions entirely.
rm -rf "$CCM/cache"
mkdir -p "$CCM/cache/zsh"
: >"$CCM/cache/zsh/zcompdump"
: >"$CCM/cache/zsh/zcompdump.zwc"
_cc_run cc-good
if [[ ! -e "$CCM/cache/zsh/zcompdump" && ! -e "$CCM/cache/zsh/zcompdump.zwc" ]]; then
  pass "_cache_completion: a regeneration invalidates the compdump (else compinit -C never sees the new file)"
else
  fail "_cache_completion: the stale compdump survived a regeneration — the completion would be invisible for 24h"
fi

# 4. …and a run that regenerates NOTHING must leave the dump alone, or every shell pays a
#    full compinit and the fast path is gone.
: >"$CCM/cache/zsh/zcompdump"
_cc_run cc-good
if [[ -e "$CCM/cache/zsh/zcompdump" ]]; then
  pass "_cache_completion: a no-op run leaves the compdump intact (the compinit -C fast path survives)"
else
  fail "_cache_completion: deleted the compdump when nothing was regenerated"
fi

# 5. An absent binary writes nothing and says nothing — the invariant that lets these callers
#    ship with no HAVE_* flag.
rm -rf "$CCM/cache"
_cc_out="$(_cc_run cc-absent-tool)"
if [[ -z "$_cc_out" && ! -d "$CCM/cache/zsh/completions" ]]; then
  pass "_cache_completion: an absent binary writes nothing and prints nothing (no HAVE_* flag needed)"
else
  fail "_cache_completion: an absent binary produced output or a cache dir ($_cc_out)"
fi

# 6. A generator that cannot succeed must CONVERGE, or every shell re-forks it forever
#    (#580). The marker is deliberately NOT an `_<tool>` stub: any file named _cc-empty in
#    fpath IS a completion function, so a stub would register an empty completion and shadow
#    whatever carapace would otherwise have bridged. Assert both halves.
rm -rf "$CCM/cache"
_cc_run cc-empty
_cc_run cc-empty
if [[ -e "$CCM/cache/zsh/completions/.cc-empty.failed" ]] &&
  [[ ! -e "$CCM/cache/zsh/completions/_cc-empty" ]]; then
  pass "_cache_completion: a failing generator converges on a dotfile marker, NOT an _<tool> stub that would shadow the bridged completion"
else
  fail "_cache_completion: failing generator did not converge, or wrote a stub into fpath"
fi

# 7. An upgrade re-opens the question: the binary's mtime is the only invalidation key.
rm -rf "$CCM/cache"
_cc_run cc-good
_cc_sz0="$(wc -c <"$CCM/cache/zsh/completions/_cc-good" | tr -d ' ')"
printf '#!/bin/sh\nprintf %%s "#compdef cc-good\\n_cc-good() { _message v2 }\\n# grown\\n"\n' >"$CCM/bin/cc-good"
chmod +x "$CCM/bin/cc-good"
touch "$CCM/bin/cc-good"
_cc_run cc-good
_cc_sz1="$(wc -c <"$CCM/cache/zsh/completions/_cc-good" | tr -d ' ')"
if [[ "$_cc_sz1" != "$_cc_sz0" ]]; then
  pass "_cache_completion: a newer binary regenerates the completion (mtime is the invalidation key)"
else
  fail "_cache_completion: an upgraded binary did not regenerate ($_cc_sz0 -> $_cc_sz1)"
fi
unset _cc_out _cc_sz0 _cc_sz1 CCM
unset -f _cc_run
