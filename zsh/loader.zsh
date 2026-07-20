# core/zsh/loader.zsh — the canonical numbered-fragment loader (v4).
# ──────────────────────────────────────────────────────────────────────────────
# v4 replaced the hand-declared `_CORE_MODULES` name array with numbered fragments:
# every Core module is `NN-name.zsh`, the OS layer lands as `80-os.zsh`, a role stage
# as `85-*.zsh`, and host tweaks as `99-local.zsh` — all symlinked FLAT into $ZSH_CFG.
# An OS .zshrc no longer lists module names; it sets the config dir + profile and
# sources this file, which globs the fragments, sorts by the NN prefix, and sources
# each in order:
#
#     ZSH_CFG="${ZDOTDIR:-$HOME/.config/zsh}"
#     CORE_PROFILE=full            # minimal | standard | full (default full)
#     source "$ZSH_CFG/loader.zsh"
#
# CRITICAL — this is SOURCED at the caller's scope, NOT wrapped in a function. The
# fragments set options (setopt), define aliases, and run compinit; those must persist
# into the interactive shell. A function body with `emulate -L`/LOCAL_OPTIONS (as most
# Core helpers use) would REVERT every option change on return — silently breaking the
# shell. So the loop runs inline; the only state it leaves behind (the `_cl_*` scratch
# vars) is unset at the end.
#
# CORE_PROFILE gates ONLY Core-owned fragments (bands 00-69): `minimal` stops after
# 30-functions, `standard` after 50-op, `full` loads all Core. Outer fragments (>=70:
# OS at 80, role at 85-94, host-local at 99) ALWAYS load regardless of profile, so a
# lean profile can never drop essential OS setup or 99-local.zsh.
#
# Each fragment is byte-compiled to a sibling .zwc before sourcing: `source file`
# auto-loads `file.zwc` wordcode when it is present and current, skipping a re-parse —
# meaningful across ~13 fragments on every shell. The compile only runs when the source
# is newer than its .zwc (or the .zwc is missing), so it self-heals: edit a fragment (or
# `git pull`) and the next shell recompiles just that file. zcompile is a builtin (no
# `>` redirection), so 10-options.zsh's NO_CLOBBER doesn't apply, and it writes the .zwc
# atomically. The .zwc lands beside the fragment symlink in $ZSH_CFG (a real, writable
# dir of symlinks), never the repo; `2>/dev/null` keeps a read-only $ZSH_CFG a silent
# no-op that just sources the plain script. NOTE: the .zwc MUST sit beside its source —
# that is how zsh's automatic wordcode pickup works — so byte-compiled wordcode is the
# one piece of runtime state the v4 XDG split deliberately leaves in $ZSH_CFG rather
# than relocating to $XDG_CACHE_HOME (history/compdump/plugins do move).
# ──────────────────────────────────────────────────────────────────────────────

: "${ZSH_CFG:=${ZDOTDIR:-$HOME/.config/zsh}}"
: "${CORE_PROFILE:=full}"
# Nothing to do without a config dir — keeps a bare source (e.g. a tool that sources
# this file with no fragments present) a clean no-op, even under `setopt nounset`.
[[ -d "$ZSH_CFG" ]] || return 0

# Core-band ceiling per profile: Core fragments (00-69) numbered ABOVE it are skipped;
# outer fragments (>=70) always load. An unknown value falls through to `full` (safest).
case "$CORE_PROFILE" in
  minimal)  _cl_ceil=30 ;;
  standard) _cl_ceil=50 ;;
  *)        _cl_ceil=69 ;;
esac

# Plain (not `local`) scratch vars + an explicit unset at the end: this file is SOURCED
# at the caller's top level, where `local` is an error — mirroring the inline loop it
# replaces. Glob qualifiers: `N` nullglob (no fragments → clean no-op), `n` numeric sort
# (so 05 precedes 40 precedes 99). `<->` matches the leading NN prefix, so loader.zsh
# itself (no NN- prefix) is never globbed and never sources itself.
for _cl_f in "$ZSH_CFG"/<->-*.zsh(Nn); do
  [[ -r "$_cl_f" ]] || continue
  _cl_nn=$(( 10#${${_cl_f:t}%%-*} ))                   # leading NN as base-10 (leading-zero safe)
  (( _cl_nn < 70 && _cl_nn > _cl_ceil )) && continue   # profile gate — Core band only
  # NO trailing name arg = script mode: writes "$_cl_f.zwc" (a function-name arg would
  # switch zcompile to digest mode, which `source` can't use as wordcode — keep it single-arg).
  [[ -s "$_cl_f.zwc" && ! "$_cl_f" -nt "$_cl_f.zwc" ]] || zcompile -R -- "$_cl_f" 2>/dev/null
  source "$_cl_f"
done
unset _cl_f _cl_nn _cl_ceil
