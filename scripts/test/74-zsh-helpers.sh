# scripts/test/74-zsh-helpers.sh
# completion drift, git.zsh, update.zsh, op.zsh
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

hdr "completion ↔ source flag drift (serve, up, core-whatsnew, core-status)"
_flag_drift() { # _flag_drift <verb> <completion-file> <source-file>
  local verb="$1" comp="$2" src="$3" f flags miss=0
  flags="$(sed 's/^[[:space:]]*#.*//' "$comp" | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
  for f in $flags; do
    grep -q -- "$f" "$src" || {
      fail "completion '$verb' advertises $f, absent from $src (drift)"
      miss=1
    }
  done
  ((miss)) || pass "completion '$verb' flags all still present in its source"
}
_flag_drift serve "$HERE/zsh/completions/_serve" "$HERE/zsh/30-functions.zsh"
_flag_drift up "$HERE/zsh/completions/_up" "$HERE/zsh/60-update.zsh"
_flag_drift core-whatsnew "$HERE/zsh/completions/_core-whatsnew" "$HERE/zsh/30-functions.zsh"
_flag_drift core-status "$HERE/zsh/completions/_core-status" "$HERE/zsh/30-functions.zsh"

# ── completion ↔ dispatcher subcommand mirror (#684) ─────────────────────────────
# _core hand-copies $_CORE_SUBCMDS and $_CORE_MAINT_SUBCMDS into `'verb:desc'` describe
# arrays, and NOTHING checked the copy — a verb added to the dispatcher without its line
# simply never completed, across nine repos. Extract the keys of each array from the
# completion file and compare them, sorted, to the dispatcher's own list.
_subs_mirror() { # _subs_mirror <describe-array-in-_core> <zsh-array-name>
  local want got
  want="$(zsh -fc "source '$UI' || exit 1; source '$FN' || exit 1; print -r -- \${(o)$2}")"
  got="$(sed -n "/local -a $1=(/,/^ *)/p" "$HERE/zsh/completions/_core" |
    grep -oE "^ *'[a-z-]+:" | tr -d " ':" | LC_ALL=C sort | tr '\n' ' ')"
  got="${got% }"
  if [[ -n "$want" && "$want" == "$got" ]]; then
    pass "_core's $1 mirrors \$$2"
  else
    fail "_core's $1 drifted from \$$2 (dispatcher: '$want'; completion: '$got')"
  fi
}
_subs_mirror subs _CORE_SUBCMDS
_subs_mirror maint_subs _CORE_MAINT_SUBCMDS

# ── git helper unit tests (git.zsh) ───────────────────────────────────────────
# git.zsh's trunk/branch resolution (git_main_branch's 6-way ref search, git_current_branch's
# detached-HEAD fallback) is real logic that branch-aware aliases (gcom/grbm/gpu) ride on and
# that fans out to nine repos — yet it was the ONE shell module with no behavioral coverage (only
# `zsh -n`). Drive each helper against throwaway repos, hermetic: HOME → sandbox and git config
# pinned to /dev/null so the host's init.defaultBranch can't skew the result. Skips without git.
hdr "git helper unit tests (git.zsh)"
if ! have git; then
  skip "git helpers (git not installed)"
else
  GITZSH="$HERE/zsh/25-git.zsh"
  gcheck() { # gcheck <label> <zsh-body that must exit 0>
    local out
    if out="$(HOME="$SANDBOX" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e \
      zsh -fc "source '$GITZSH' || exit 1; $2" 2>&1)"; then
      pass "$1"
    else
      fail "$1"
      [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
    fi
  }
  gcheck "git_current_branch reads the checked-out branch" \
    'd=$(mktemp -d); cd "$d"; git -c init.defaultBranch=main init -q .; [[ $(git_current_branch) == main ]]'
  gcheck "git_current_branch falls back to a short SHA on detached HEAD" \
    'd=$(mktemp -d); cd "$d"; git -c init.defaultBranch=main init -q .; git commit -q --allow-empty -m x; git checkout -q --detach HEAD; [[ -n $(git_current_branch) ]]'
  gcheck "git_current_branch is empty outside a repo" \
    'd=$(mktemp -d); cd "$d"; [[ -z $(git_current_branch) ]]'
  gcheck "git_main_branch resolves main when present" \
    'd=$(mktemp -d); cd "$d"; git -c init.defaultBranch=main init -q .; git commit -q --allow-empty -m x; [[ $(git_main_branch) == main ]]'
  gcheck "git_main_branch resolves master when that is the trunk" \
    'd=$(mktemp -d); cd "$d"; git -c init.defaultBranch=master init -q .; git commit -q --allow-empty -m x; [[ $(git_main_branch) == master ]]'
  gcheck "git_main_branch defaults to master when no known trunk exists" \
    'd=$(mktemp -d); cd "$d"; git -c init.defaultBranch=main init -q .; git commit -q --allow-empty -m x; git branch -m weirdtrunk; [[ $(git_main_branch) == master ]]'
  gcheck "git_main_branch ignores a dangling origin/HEAD (stale after a remote rename)" \
    'd=$(mktemp -d); cd "$d"; git -c init.defaultBranch=master init -q .; git commit -q --allow-empty -m x; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main; [[ $(git_main_branch) == master ]]'
fi

# ── update.zsh per-manager parse ──────────────────────────────────────────────
# The detection LADDER is covered above (apt), but _pkgup_count/_pkgup_list use a DISTINCT
# grep/awk heuristic PER manager — and only apt had a test. A regex that miscounts a header
# or blank row would ship silently to that one distro's repo. Pin each: isolate PATH to a
# lone manager stub (+ the coreutils its pipeline forks) so _pkgup_mgr resolves to it, feed
# canned `outdated` output, and assert the parsed count/names. Mirrors the apt stub above.
hdr "core whatsnew version-bump nudge (60-update.zsh)"
# ── the version-bump nudge (zsh/60-update.zsh) ────────────────────────────────
# Band 60, and it calls band-30 helpers — so these source ui + functions + update, the
# loader's real order. `up`'s module early-returns on a non-interactive shell, hence ucheck
# (zsh -fic) rather than check. CORE_WHATSNEW_NUDGE=0 suppresses the module's OWN call site
# so each body drives the function itself, one "shell start" at a time.
_wsn="$SANDBOX/whatsnew-nudge"
mkdir -p "$_wsn"
printf '5.5.0\n' >"$_wsn/core.version"
_wsn_src="source '$UI'; source '$FN'; source '$UPD'; _CORE_VERSION_FILE='$_wsn/core.version'; _CORE_WHATSNEW_STATE='$_wsn/whatsnew';"

# A fresh box has no state and no honest "from" version — _core_welcome greets it instead.
# The suppression is STRUCTURAL (no `announced` key ⇒ seed and stay silent), not a matter of
# print order, so a later refactor cannot reintroduce a spurious "Core moved" on install.
ucheck "the bump nudge seeds silently on a box with no state (a fresh install gets the welcome, not this)" \
  "$_wsn_src rm -f '$_wsn/whatsnew'
   out=\$(_core_whatsnew_nudge 2>&1); [[ -z \$out ]] && [[ \$(<'$_wsn/whatsnew') == *'announced=5.5.0'* ]]" \
  NO_COLOR=1 UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_WHATSNEW_NUDGE=0

ucheck "the bump nudge fires ONCE on a version bump, then stays quiet" \
  "$_wsn_src printf 'seen=5.5.0\\nannounced=5.5.0\\n' >| '$_wsn/whatsnew'
   print -r -- '5.6.0' >| '$_wsn/core.version'
   first=\$(_core_whatsnew_nudge 2>&1); second=\$(_core_whatsnew_nudge 2>&1)
   [[ \$first == *'Core moved 5.5.0'*'5.6.0'* && \$first == *'core whatsnew'* && -z \$second ]]" \
  NO_COLOR=1 UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_WHATSNEW_NUDGE=0

# `seen` is carried through announcements UNCHANGED, so a host that ignored two bumps is told
# the REAL span. Collapsing the two keys would understate it as "5.6.0 → 5.7.0".
ucheck "the bump nudge names the last-READ version, not the last-announced one (multi-hop)" \
  "$_wsn_src printf 'seen=5.5.0\\nannounced=5.6.0\\n' >| '$_wsn/whatsnew'
   print -r -- '5.7.0' >| '$_wsn/core.version'
   out=\$(_core_whatsnew_nudge 2>&1); [[ \$out == *'Core moved 5.5.0'*'5.7.0'* ]]" \
  NO_COLOR=1 UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_WHATSNEW_NUDGE=0

# THE never-nag-forever CONTRACT (_core_welcome's rule). A state file it cannot write means
# it cannot remember having spoken — so it must not speak, and must not leak the shell's own
# "permission denied" from the failed redirection either. Both would recur on EVERY shell.
if [[ "$(id -u)" == 0 ]]; then
  skip "the bump nudge stays silent when the state cannot be written (running as root — file modes do not apply)"
else
  printf 'seen=5.5.0\nannounced=5.5.0\n' >"$_wsn/whatsnew"
  printf '5.9.0\n' >"$_wsn/core.version"
  chmod 444 "$_wsn/whatsnew"
  ucheck "the bump nudge stays SILENT (stdout and stderr) when the state file cannot be written" \
    "$_wsn_src a=\$(_core_whatsnew_nudge 2>&1); b=\$(_core_whatsnew_nudge 2>&1); [[ -z \$a && -z \$b ]]" \
    NO_COLOR=1 UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 CORE_WHATSNEW_NUDGE=0
  chmod 644 "$_wsn/whatsnew"
fi

hdr "update.zsh per-manager parse (apk / dnf / zypper / pacman)"
_mgr_stub() { # _mgr_stub <mgr> <sh-body>
  rm -rf "$PMBIN"
  mkdir -p "$PMBIN"
  printf '#!/bin/sh\n%s\n' "$2" >"$PMBIN/$1"
  chmod +x "$PMBIN/$1"
  local t
  for t in grep awk sort cut sed; do
    [[ -e "$PMBIN/$t" ]] || ln -s "$(command -v "$t")" "$PMBIN/$t" 2>/dev/null
  done
}
_mgr_stub apk 'case "$*" in *"list -u"*) printf "a-1.0 ...\nb-2.0 ...\nc-3.0 ...\n" ;; esac'
ucheck "update: _pkgup_count parses apk (3 upgradable)" \
  "source '$UPD'; [[ \$(_pkgup_count) == 3 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: _pkgup_list parses apk package names" \
  "source '$UPD'; out=\$(_pkgup_list); [[ \$out == *a-1.0* && \$out == *c-3.0* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
_mgr_stub dnf 'case "$*" in *check-update*) printf "bash.x86_64    5.1-2    baseos\nvim.x86_64    9.0-1    appstream\n" ;; esac'
ucheck "update: _pkgup_count parses dnf check-update (2 upgradable)" \
  "source '$UPD'; [[ \$(_pkgup_count) == 2 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: _pkgup_list parses dnf package names" \
  "source '$UPD'; out=\$(_pkgup_list); [[ \$out == *bash.x86_64* && \$out == *vim.x86_64* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
_mgr_stub zypper 'case "$*" in *list-updates*) printf "v | repo | bash | 1 | 2 | x86_64\nv | repo | vim | 1 | 2 | x86_64\n" ;; esac'
ucheck "update: _pkgup_count parses zypper list-updates (2 upgradable)" \
  "source '$UPD'; [[ \$(_pkgup_count) == 2 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: _pkgup_list parses zypper package names" \
  "source '$UPD'; out=\$(_pkgup_list); [[ \$out == *bash* && \$out == *vim* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
_mgr_stub pacman 'case "$*" in *-Qu*) printf "bash 5.1.0\nvim 9.0.0\n" ;; esac'
ucheck "update: _pkgup_count parses pacman -Qu (2 upgradable)" \
  "source '$UPD'; [[ \$(_pkgup_count) == 2 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: _pkgup_list parses pacman package names" \
  "source '$UPD'; out=\$(_pkgup_list); [[ \$out == *bash* && \$out == *vim* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# brew and emerge had NO parse coverage at all — the header above claimed four managers and
# the file has seven. brew is the reference implementation's manager and emerge is the one
# whose count verb can legitimately be absent, so both are exactly the arms a silent
# regression would sit in longest.
_mgr_stub brew 'case "$*" in *outdated*) printf "wget\nzsh\n" ;; esac'
ucheck "update: _pkgup_count parses brew outdated (2 upgradable)" \
  "source '$UPD'; [[ \$(_pkgup_count) == 2 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: _pkgup_list parses brew package names" \
  "source '$UPD'; out=\$(_pkgup_list); [[ \$out == *wget* && \$out == *zsh* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# Gentoo asks Portage, not eix (#756), so the fixture is an `emerge --pretend` resolve —
# ebuild/binary lines counted, [nomerge] ignored, ::repo and the -rN revision stripped off
# the atom.
_mgr_stub emerge 'case "$*" in
*--pretend*) printf "[ebuild  U  ] app-editors/neovim-0.12.3-r1::gentoo\n[binary   N ] dev-libs/tree-sitter-c-0.24.1\n[nomerge     ] sys-apps/eza-0.20.0\n" ;;
esac'
ucheck "update: _pkgup_count counts a Portage resolve, not [nomerge] lines (2)" \
  "source '$UPD'; [[ \$(_pkgup_count) == 2 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
ucheck "update: _pkgup_list strips ::repo and the -rN revision off each atom" \
  "source '$UPD'; out=\$(_pkgup_list); [[ \$out == *app-editors/neovim* && \$out != *::gentoo* && \$out != *-r1* && \$out != *eza* ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# A RESOLVE THAT FAILS MUST REPORT -1, NOT 0 (#756). The two are different claims — 0 is
# "I checked, nothing pending" — and a box whose Portage cannot resolve (blocks, conflicts)
# is not a box with nothing to do. This is what PKG_COUNT_EXIT_TRUSTED buys, and Gentoo is
# the only archive that declares it: everywhere else a non-zero exit means something else
# entirely (dnf exits 100 when updates EXIST; pacman -Qu exits non-zero when there are NONE).
_mgr_stub emerge 'exit 1'
ucheck "update: a failed Portage resolve reports -1 (unknown), never 0" \
  "source '$UPD'; [[ \$(_pkgup_count) == -1 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0
# ...and the same failure on an archive that does NOT declare the key still counts lines,
# because there a non-zero exit is not a failure. dnf is the case that proves it: exit 100
# is how it says updates EXIST, and reading that as "could not answer" would report unknown
# on every Fedora box that has anything to install.
_mgr_stub dnf 'printf "bash.x86_64    5.1-2    baseos\n"; exit 100'
ucheck "update: dnf's exit 100 (updates EXIST) is not read as a failure" \
  "source '$UPD'; [[ \$(_pkgup_count) == 1 ]]" \
  PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0

# ── update.zsh dispatches through os.capabilities (#664) ──────────────────────
# The block above proves the built-in defaults still parse every archive identically. This
# one proves the OTHER half: that a DECLARATION is what actually drives `up`, because until
# a box re-bootstraps onto the declaration #667 authored it has none, and the built-ins
# would happily hide a dispatcher
# that never reads the table at all.
#
# Every stub here prints its own argv, so the assertion is on the exact command line `up`
# builds — the thing a host notices — rather than on an exit status that a no-op also
# produces. 02-capabilities.zsh is sourced alongside update.zsh (it is band 02, far ahead of
# every consumer) and pointed at a scratch declaration via CORE_CAPABILITIES_FILE.
hdr "update.zsh dispatch through os.capabilities (#664)"
CAPD_UP="$SANDBOX/capup"
rm -rf "$CAPD_UP"
mkdir -p "$CAPD_UP"
CAPZ="$HERE/zsh/02-capabilities.zsh"
# _up_stub <name>... — a stub per name that echoes "RUN: <name> <args>".
_up_stub() {
  rm -rf "$PMBIN"
  mkdir -p "$PMBIN"
  local n
  for n in "$@"; do
    printf '#!/bin/sh\nprintf "RUN: %s %%s\\n" "$*"\n' "$n" >"$PMBIN/$n"
    chmod +x "$PMBIN/$n"
  done
  local t
  for t in grep awk sort cut sed; do
    [[ -e "$PMBIN/$t" ]] || ln -s "$(command -v "$t")" "$PMBIN/$t" 2>/dev/null
  done
}
# _upcheck <label> <decl-lines> <zsh-body> — seed a declaration, then run the body with
# ui + capabilities + update sourced. `_core_confirm` is stubbed to accept: `up`'s
# pre-confirm declines with no TTY by design, which would otherwise short-circuit every
# assertion here before the dispatch it is testing.
_upcheck() { # _upcheck <label> <decl> <body>
  printf '%s\n' "$2" >"$CAPD_UP/os.capabilities"
  ucheck "$1" \
    "source '$UI'; source '$CAPZ'; source '$UPD'; _core_confirm() { return 0 }; $3" \
    PATH="$PMBIN" UPDATE_CHECK_ENABLED=0 CORE_WELCOME=0 \
    CORE_CAPABILITIES_FILE="$CAPD_UP/os.capabilities"
}

# 1. A declared verb WINS over Core's built-in row. Tumbleweed is the case this whole
#    refactor exists for: the built-in row still probes /etc/os-release to choose between
#    `dup` and `up`, and a declaration must make that probe irrelevant — on any host,
#    including the one running this suite, which is not openSUSE.
_up_stub zypper sudo
_upcheck "up: a declared PKG_UPGRADE overrides Core's built-in row (zypper dup)" \
  'PKG_UPGRADE=sudo zypper dup' \
  'out=$(up -y 2>&1); [[ $out == *"RUN: sudo zypper dup"* ]]'
# 2. PKG_ASSUME_YES is what `up -y` appends — and its ABSENCE means never auto-confirm,
#    which is how pacman/emerge/apk keep the behaviour they had when it was hardcoded.
_upcheck "up -y appends the declared PKG_ASSUME_YES token" \
  'PKG_UPGRADE=sudo zypper up
PKG_ASSUME_YES=-y' \
  'out=$(up -y 2>&1); [[ $out == *"RUN: sudo zypper up -y"* ]]'
# OMISSION IS A STATEMENT, and this is the assertion that proves Core honours it. The
# stubbed PATH resolves to a manager whose BUILT-IN row does declare `-y`, so a per-key
# fallback would hand one back to a repo that deliberately left it out — auto-confirming a
# privileged upgrade nobody asked to auto-confirm. A declaration is all-or-nothing.
_upcheck "up -y appends nothing when the archive declares no PKG_ASSUME_YES" \
  'PKG_UPGRADE=sudo zypper up' \
  'out=$(up -y 2>&1); [[ $out == *"RUN: sudo zypper up"* && $out != *" -y"* ]]'
_upcheck "up without -y never auto-confirms, even where a token is declared" \
  'PKG_UPGRADE=sudo zypper up
PKG_ASSUME_YES=-y' \
  'out=$(up 2>&1); [[ $out == *"RUN: sudo zypper up"* && $out != *" -y"* ]]'
# 3. PKG_UPGRADE_PRE runs first and its failure ABORTS — an upgrade computed against an
#    index that could not be refreshed is how a box half-applies.
_upcheck "up runs PKG_UPGRADE_PRE before the upgrade" \
  'PKG_UPGRADE=sudo zypper up
PKG_UPGRADE_PRE=sudo zypper refresh' \
  'out=$(up 2>&1); [[ $out == *"RUN: sudo zypper refresh"*"RUN: sudo zypper up"* ]]'
_up_stub zypper sudo false
_upcheck "up aborts the upgrade when PKG_UPGRADE_PRE fails" \
  'PKG_UPGRADE=sudo zypper up
PKG_UPGRADE_PRE=false' \
  'out=$(up 2>&1); (( $? != 0 )) && [[ $out != *"RUN: sudo zypper up"* ]]'
# 4. PKG_CLEANUP runs after a successful FULL upgrade, and carries the auto-confirm token
#    too: an unattended `up -y` that then stops to ask whether to autoremove has not been
#    unattended.
_up_stub apt-get sudo
_upcheck "up -y runs PKG_CLEANUP after the upgrade, with the assume-yes token" \
  'PKG_UPGRADE=sudo apt-get full-upgrade
PKG_CLEANUP=sudo apt-get autoremove
PKG_ASSUME_YES=-y' \
  'out=$(up -y 2>&1); [[ $out == *"RUN: sudo apt-get full-upgrade -y"*"RUN: sudo apt-get autoremove -y"* ]]'
# 5. THE SAFETY DECLARATION. `up -i` refuses on an archive that declares no partial verb —
#    which is how Arch, Gentoo and Alpine say "this must update as a whole". It is the
#    ABSENCE that refuses, so an archive Core has never heard of gets the safe answer by
#    default instead of being waved through.
# Same shape, and the higher-stakes half: apt's BUILT-IN row names a partial verb, so a
# per-key fallback would let `up -i` through on a declaration that refused it.
_upcheck "up -i refuses when the declaration names no PKG_UPGRADE_PARTIAL" \
  'PKG_UPGRADE=sudo apt-get full-upgrade' \
  'out=$(up -i 2>&1); (( $? == 1 )) && [[ $out == *"does not support safe partial upgrades"* ]]'
_upcheck "up -i gets past the safety refusal when a partial verb IS declared" \
  'PKG_UPGRADE=sudo apt-get full-upgrade
PKG_UPGRADE_PARTIAL=sudo apt-get install --only-upgrade' \
  'out=$(up -i </dev/null 2>&1); (( $? == 1 )) && [[ $out == *"needs fzf or gum"* ]]'
# 6. A DECLARED sudo NAMES THE INTENT, NOT THE TOOL. Alpine has doas and not sudo, and a
#    container has neither — so a declaration that says `sudo` must still work on both.
#    _pkgup_run strips the prefix and hands the rest to _pkgup_priv, which is the ladder.
_up_stub zypper doas
_upcheck "up maps a declared sudo onto doas on a box that has only doas" \
  'PKG_UPGRADE=sudo zypper up' \
  'out=$(up 2>&1); [[ $out == *"RUN: doas zypper up"* ]]'
_up_stub brew
_upcheck "up runs an unprefixed verb bare (Homebrew must never be privileged)" \
  'PKG_UPGRADE=brew upgrade' \
  'out=$(up 2>&1); [[ $out == *"RUN: brew upgrade"* ]]'
# 7. The count path, declared. PKG_PENDING_FS/MATCH/FIELD are the three values that replaced
#    seven hand-written grep/awk heuristics, and they reach awk as DATA — a declaration is
#    never eval'd. zypper's `|`-delimited table is the one that needs all three.
rm -rf "$PMBIN"
mkdir -p "$PMBIN"
printf '#!/bin/sh\ncase "$*" in *list-updates*) printf "S | repo | name | old | new | arch\nv | repo | bash | 1 | 2 | x86_64\nv | repo | vim | 1 | 2 | x86_64\n" ;; esac\n' >"$PMBIN/zypper"
chmod +x "$PMBIN/zypper"
for t in grep awk sort cut sed; do ln -s "$(command -v "$t")" "$PMBIN/$t" 2>/dev/null; done
_upcheck "count: a declared MATCH/FS/FIELD parses the zypper table (header excluded)" \
  'PKG_COUNT_PENDING=zypper -q list-updates
PKG_PENDING_MATCH=^v[[:space:]]
PKG_PENDING_FS=|
PKG_PENDING_FIELD=3' \
  '[[ $(_pkgup_count) == 2 ]] && out=$(_pkgup_list) && [[ $out == *bash* && $out == *vim* && $out != *name* ]]'
# The defaults must cover an archive that needs none of the three — one name per line is
# the common case, and forcing every repo to declare a `.`/1 pair would be schema noise.
rm -rf "$PMBIN"
mkdir -p "$PMBIN"
printf '#!/bin/sh\nprintf "a-1.0 x\nb-2.0 x\n"\n' >"$PMBIN/apk"
chmod +x "$PMBIN/apk"
for t in grep awk sort cut sed; do ln -s "$(command -v "$t")" "$PMBIN/$t" 2>/dev/null; done
_upcheck "count: MATCH/FIELD/FS default to '.'/1/whitespace when undeclared" \
  'PKG_COUNT_PENDING=apk list -u' \
  '[[ $(_pkgup_count) == 2 ]] && out=$(_pkgup_list) && [[ $out == *a-1.0* && $out == *b-2.0* ]]'
# A declaration is DATA. If a value ever reached a shell as code, a `;` in it would run —
# and the one place that would have been easy to get wrong is the count command, which is
# the only declared value Core word-splits. Assert the split, not an eval.
rm -rf "$PMBIN"
mkdir -p "$PMBIN"
printf '#!/bin/sh\nprintf "RUN: %%s\\n" "$*"\n' >"$PMBIN/marker"
chmod +x "$PMBIN/marker"
for t in grep awk sort cut sed; do ln -s "$(command -v "$t")" "$PMBIN/$t" 2>/dev/null; done
_upcheck "count: a ';' in a declared value is an argument, never a command separator" \
  "PKG_COUNT_PENDING=marker one ; touch $CAPD_UP/pwned" \
  "_pkgup_list >/dev/null 2>&1; [[ ! -e '$CAPD_UP/pwned' ]]"
rm -rf "$PMBIN"

# ── op.zsh 1Password helpers ──────────────────────────────────────────────────
# op.zsh fans out to nine repos and handles SECRETS, yet had zero behavioral coverage. The
# module short-circuits (returns) unless `op` is on PATH, so we stub a fake `op` (echoes
# its args) + a fake `clip` (captures stdin) on an isolated PATH — the same hermetic
# technique as the clip ladder — and assert the verbs' input-guards, the op:// path
# construction, and optoken's clip dependency. No real 1Password, no network, no secrets.
hdr "op.zsh 1Password helpers (hermetic stubs)"
OPZSH="$HERE/zsh/50-op.zsh"
OPBIN="$SANDBOX/opbin"
_op_reset() { # _op_reset [with-clip]
  rm -rf "$OPBIN"
  mkdir -p "$OPBIN"
  # $_real_zsh: the absolute zsh, resolved once in scripts/test/70-detection.sh's preamble.
  # shellcheck disable=SC2154  # cross-fragment: set in scripts/test/70-detection.sh
  ln -s "$_real_zsh" "$OPBIN/zsh" 2>/dev/null
  # fake op: print the OTP for `item get --otp`, a table for `item list`, else echo args.
  cat >"$OPBIN/op" <<'OPSTUB'
#!/bin/sh
case "$*" in
*"item get"*--otp*) echo 123456 ;;
*"item list"*) printf 'NAME\tKEY\nmykey\tabc\n' ;;
*) printf 'op %s\n' "$*" ;;
esac
OPSTUB
  chmod +x "$OPBIN/op"
  # fake clip: records its argv and what it was fed, so a test can prove optoken passed
  # `--sensitive` (#690) — a stub that discarded both would pass with the flag deleted.
  if [[ "${1:-}" == with-clip ]]; then
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"%s"\ncat >"%s"\n' "$OPBIN/clip.args" "$OPBIN/clip.stdin" >"$OPBIN/clip"
    chmod +x "$OPBIN/clip"
  fi
}
# ocheck: source ui+op under a PATH that includes the op stub, run a body, expect exit 0.
ocheck() { # ocheck <label> <zsh-body> [extra PATH entries already in OPBIN]
  local out
  if out="$(PATH="$OPBIN:$PATH" HOME="$SANDBOX" "$_real_zsh" -fc "source '$UI'||exit 1; source '$OPZSH'||exit 1; $2" 2>&1)"; then
    pass "$1"
  else
    fail "$1"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}
if ! have zsh; then
  skip "op.zsh helpers (zsh not installed)"
else
  _op_reset with-clip
  # input guards: a missing required arg is a usage error (rc 1), in Core's voice.
  ocheck "opsecret with no arg is a usage error" 'opsecret 2>/dev/null; (( $? != 0 ))'
  ocheck "openv with no arg is a usage error" 'openv 2>/dev/null; (( $? != 0 ))'
  ocheck "optoken with no arg is a usage error" 'optoken 2>/dev/null; (( $? != 0 ))'
  # op:// path construction: opsecret <path> must call `op read op://<path>` verbatim.
  ocheck "opsecret builds the op:// read path" \
    'out=$(opsecret Personal/AWS/key); [[ $out == *"op read op://Personal/AWS/key"* ]]'
  # optoken copies the OTP via clip and confirms — present clip → success + the ok line.
  # "sent", not "copied": clip's OSC 52 last resort returns success once the escape is
  # WRITTEN, which is not the same as a terminal having accepted it (#525).
  ocheck "optoken fetches the OTP and hands it to clip" \
    'out=$(optoken Personal/GitHub 2>&1); (( $? == 0 )) && [[ $out == *"TOTP sent"* ]]'
  # The integration #690 hinges on: the OTP must reach clip on stdin, with --sensitive and
  # nothing else on argv, and with no trailing newline (a bare `\n` pasted into a TOTP
  # field submits the form early on some sites).
  if [[ "$(cat "$OPBIN/clip.args" 2>/dev/null)" == "--sensitive" ]] \
    && [[ "$(od -An -c "$OPBIN/clip.stdin" 2>/dev/null | tr -d ' ')" == "123456" ]]; then
    pass "optoken invokes clip --sensitive with exactly the OTP on stdin (no newline)"
  else
    fail "optoken did not invoke clip --sensitive with the bare OTP (argv='$(cat "$OPBIN/clip.args" 2>/dev/null)', stdin=$(od -An -c "$OPBIN/clip.stdin" 2>/dev/null | tr -s ' '))"
  fi
  ocheck "opssh lists stored SSH keys (rc 0)" \
    'out=$(opssh 2>&1); (( $? == 0 )) && [[ $out == *mykey* ]]'
  # uniform --help contract: each op verb answers --help on stdout, rc 0.
  ocheck "opsecret --help returns 0 with usage" \
    'out=$(opsecret --help); (( $? == 0 )) && [[ $out == *"usage: opsecret"* ]]'
  # optoken's clip dependency (U4 errbox): with NO clip on PATH it must fail in Core's
  # voice (rc 1) rather than silently swallow the TOTP down a broken pipe.
  _op_reset # no clip this time
  ocheck "optoken fails clearly when clip is absent (no silent TOTP loss)" \
    'path=(/usr/bin /bin); out=$(optoken Personal/GitHub 2>&1); (( $? != 0 )) && [[ $out == *"requires Core"* && $out == *clip* ]]'
fi

