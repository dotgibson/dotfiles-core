# scripts/test/34-link-run.sh
# the REAL link run (blib_link_core against a throwaway HOME)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the REAL link run (blib_link_core against a throwaway $HOME) ─────────────
# bootstrap-test.yml asserts the symlink graph, but it is workflow_call-only and
# dotfiles-core ships no bootstrap.sh — so it only ever runs from the nine OS repos.
# Core's own CI unit-tests the blib_* helpers and never performs a real link run, which
# means a bootstrap-lib regression is caught downstream, in nine repos, instead of here.
#
# This closes that: link the ACTUAL Core tree into a sandbox $HOME/$config and assert the
# graph a consumer depends on. Hermetic — the tpm directory is pre-seeded so the one-time
# clone is skipped, which is the only network call in the whole function.
if have git; then
  hdr "bootstrap link run (blib_link_core against a sandbox HOME)"
  LR="$SANDBOX/linkrun"
  rm -rf "$LR"
  mkdir -p "$LR/home" "$LR/config" "$LR/dotfiles"
  # A consumer's layout is <repo>/core -> the vendored Core tree. COPY it rather than
  # symlinking: blib_link_core runs `chmod +x` on core/tmux/scripts/*.sh and core/bin/clip*,
  # and audit-core.sh launches this suite CONCURRENTLY with its own exec-bit gate — a
  # symlink here would let the test mutate the very checkout that gate is reading, which is
  # both a race and a violation of the read-only assumption the whole suite is built on.
  # Copying per top-level directory keeps .git out without needing a non-portable tar flag.
  mkdir -p "$LR/dotfiles/core"
  for _lr_d in zsh nvim tmux vim git starship lazygit mise jujutsu atuin tealdeer sesh ssh bin lib; do
    [[ -e "$HERE/$_lr_d" ]] && cp -R "$HERE/$_lr_d" "$LR/dotfiles/core/$_lr_d"
  done
  mkdir -p "$LR/config/tmux/plugins/tpm"   # pre-seed: skips the tpm clone (offline)
  (
    # shellcheck source=lib/bootstrap-lib.sh
    HOME="$LR/home" XDG_CONFIG_HOME="$LR/config" \
      BLIB_ONLY="" BLIB_SKIP="" \
      bash -c '
        set -u
        . "'"$HERE/lib/bootstrap-lib.sh"'"
        blib_link_core "'"$LR/dotfiles"'" "'"$LR/config"'" >/dev/null 2>&1
      '
  ) || true

  _lr_is_link_to() { # <link> <target>  — a symlink resolving to the expected file
    [[ -L "$1" ]] && [[ "$(readlink "$1")" == "$2" ]]
  }
  _lr_mode() { # <path> — octal permission bits, GNU or BSD stat (the macOS CI leg)
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
  }
  # The zsh chain is the load-order contract: every numbered Core fragment must land FLAT
  # in $config/zsh under its own basename, because loader.zsh globs NN-*.zsh there. A
  # rename or a missed file here is precisely what silently drops a stage on nine boxes.
  _lr_missing=""
  for f in "$HERE"/zsh/[0-9][0-9]-*.zsh; do
    b="$(basename "$f")"
    _lr_is_link_to "$LR/config/zsh/$b" "$LR/dotfiles/core/zsh/$b" || _lr_missing="$_lr_missing $b"
  done
  if [[ -z "$_lr_missing" ]]; then
    pass "link run: every numbered Core zsh fragment is linked flat into \$ZSH_CFG"
  else
    fail "link run: zsh fragments missing or mislinked —$_lr_missing"
  fi
  # loader.zsh is not a numbered fragment but IS what sources them; a graph without it
  # produces a shell that starts and loads nothing.
  if _lr_is_link_to "$LR/config/zsh/loader.zsh" "$LR/dotfiles/core/zsh/loader.zsh"; then
    pass "link run: loader.zsh is linked (the chain has an entry point)"
  else
    fail "link run: loader.zsh was not linked"
  fi
  # nvim is linked as a DIRECTORY symlink — the one manifest entry that is a whole tree.
  if [[ -L "$LR/config/nvim" && -d "$LR/config/nvim" && -f "$LR/config/nvim/init.lua" ]]; then
    pass "link run: nvim/ is a directory symlink resolving to a real init.lua"
  else
    fail "link run: nvim/ is not a resolvable directory symlink"
  fi
  # The rest of the symlinked surface, at the exact destinations bootstrap promises.
  _lr_bad=""
  _lr_is_link_to "$LR/config/tmux/tmux.conf" "$LR/dotfiles/core/tmux/tmux.conf" || _lr_bad="$_lr_bad tmux.conf"
  _lr_is_link_to "$LR/config/starship.toml" "$LR/dotfiles/core/starship/starship.toml" || _lr_bad="$_lr_bad starship.toml"
  _lr_is_link_to "$LR/config/lazygit/config.yml" "$LR/dotfiles/core/lazygit/config.yml" || _lr_bad="$_lr_bad lazygit"
  _lr_is_link_to "$LR/config/jj/config.toml" "$LR/dotfiles/core/jujutsu/config.toml" || _lr_bad="$_lr_bad jj"
  _lr_is_link_to "$LR/config/tealdeer/config.toml" "$LR/dotfiles/core/tealdeer/config.toml" || _lr_bad="$_lr_bad tealdeer"
  # mise and atuin were absent from this group for as long as it has existed (#718) — the
  # gap the checklist rewrite predicts, found by reading the list it now tells you to edit.
  # Both are in the `tools` group beside lazygit/jj/tealdeer and were only ever covered by
  # the fixture-directory list above, which proves the SOURCE was copied, not that the LINK
  # lands where bootstrap promises.
  # mise is deliberately NOT in this group — it is ADOPTED (a real file), not linked,
  # because `mise use -g` rewrites it and a symlink pointed that write into vendored
  # core/. Asserted separately below.
  _lr_is_link_to "$LR/config/atuin/config.toml" "$LR/dotfiles/core/atuin/config.toml" || _lr_bad="$_lr_bad atuin"
  _lr_is_link_to "$LR/home/.gitconfig" "$LR/dotfiles/core/git/gitconfig" || _lr_bad="$_lr_bad .gitconfig"
  _lr_is_link_to "$LR/home/.vimrc" "$LR/dotfiles/core/vim/vimrc" || _lr_bad="$_lr_bad .vimrc"
  # Resolve the target, don't just prove it is *a* symlink — a dangling link, or one
  # pointing at the wrong directory, would otherwise pass this grouped assertion.
  _lr_is_link_to "$LR/config/tmux/scripts" "$LR/dotfiles/core/tmux/scripts" || _lr_bad="$_lr_bad tmux/scripts"
  [[ -d "$LR/config/tmux/scripts" ]] || _lr_bad="$_lr_bad tmux/scripts(dangling)"
  if [[ -z "$_lr_bad" ]]; then
    pass "link run: tmux, starship, lazygit, jj, tealdeer, atuin, gitconfig and vimrc land where bootstrap promises"
  else
    fail "link run: wrong or missing links —$_lr_bad"
  fi

  # ── mise is ADOPTED, not linked ─────────────────────────────────────────────
  # The regression this pins: a symlink here is a write path back into the vendored
  # core/ tree. `mise use -g ruby@4.0` followed it, tampered the tree, and took the
  # repo out of the next fleet sync. Asserting "not a symlink" IS the contract.
  if [[ -f "$LR/config/mise/config.toml" && ! -L "$LR/config/mise/config.toml" ]]; then
    pass "adopt run: mise config is a real file, not a symlink into core/"
  else
    fail "adopt run: mise config is missing or is a symlink (the write-through regression)"
  fi
  if [[ "$(git hash-object -- "$LR/config/mise/config.toml" 2>/dev/null)" == \
        "$(git hash-object -- "$LR/dotfiles/core/mise/config.toml" 2>/dev/null)" ]]; then
    pass "adopt run: a freshly adopted mise config matches Core byte-for-byte"
  else
    fail "adopt run: adopted mise config does not match Core's source"
  fi
  # And the write that started all this must now stay local: simulate the rewrite and
  # prove the vendored tree is untouched.
  _lr_core_before="$(git hash-object -- "$LR/dotfiles/core/mise/config.toml")"
  cp "$LR/config/mise/config.toml" "$SANDBOX/mise-adopted.orig"
  printf '\n[tools]\nruby = "4.0"\n' >>"$LR/config/mise/config.toml"
  if [[ "$(git hash-object -- "$LR/dotfiles/core/mise/config.toml")" == "$_lr_core_before" ]]; then
    pass "adopt run: a local mise rewrite does NOT reach vendored core/"
  else
    fail "adopt run: a local mise rewrite wrote through into vendored core/"
  fi
  # Restore: the later "second pass is a true no-op" assertion shares this fixture, and a
  # drifted file there would make THIS test the cause of an unrelated failure.
  cp "$SANDBOX/mise-adopted.orig" "$LR/config/mise/config.toml"
  # clip is SYMLINKED onto PATH — bootstrap-lib chmod +x's the SOURCE, not the link — so
  # assert the target as well as the mode. nvim's clipboard provider, tmux copy-pipe and
  # the zsh helpers all shell out to it by name, so a dangling link breaks copy on every
  # surface at once while `-x` alone would still look fine on a wrong-but-executable file.
  if _lr_is_link_to "$LR/home/.local/bin/clip" "$LR/dotfiles/core/bin/clip" &&
    _lr_is_link_to "$LR/home/.local/bin/clip-paste" "$LR/dotfiles/core/bin/clip-paste" &&
    [[ -x "$LR/home/.local/bin/clip" && -x "$LR/home/.local/bin/clip-paste" ]]; then
    pass "link run: clip + clip-paste link onto ~/.local/bin and resolve executable"
  else
    fail "link run: clip/clip-paste missing, mislinked, or not executable"
  fi
  # ssh (#450). Core OWNS the client config now — it used to be read from the OS repo's
  # ROOT ($dotfiles/ssh/config), a path Core neither shipped nor listed in core.manifest,
  # so a repo that simply lacked one silently got no ssh config at all. Assert the link
  # resolves INTO core/, not just that ~/.ssh/config exists: a leftover file from the
  # pre-#450 layout would satisfy the weaker check while the vendored config went unused.
  _lr_ssh_bad=""
  _lr_is_link_to "$LR/home/.ssh/config" "$LR/dotfiles/core/ssh/config" || _lr_ssh_bad="$_lr_ssh_bad config"
  # ssh REFUSES to use ~/.ssh when the perms are loose, and ControlMaster fails outright
  # on a missing sockets dir — both are silent-at-link-time, loud-at-first-connect.
  # config.d is the override chain Core's Include depends on; without it, the drop-in
  # mechanism that replaces each repo's forked config has nowhere to put a file.
  for _lr_sd in .ssh .ssh/sockets .ssh/config.d; do
    [[ -d "$LR/home/$_lr_sd" ]] || { _lr_ssh_bad="$_lr_ssh_bad $_lr_sd(missing)"; continue; }
    # 700 exactly — ssh rejects group/other access on ~/.ssh, and a 755 here is the
    # failure mode that only shows up on a box with a real key in it.
    [[ "$(_lr_mode "$LR/home/$_lr_sd")" == 700 ]] || _lr_ssh_bad="$_lr_ssh_bad $_lr_sd($(_lr_mode "$LR/home/$_lr_sd"))"
  done
  if [[ -z "$_lr_ssh_bad" ]]; then
    pass "link run: ssh/config links out of core/, with ~/.ssh, sockets and config.d at 0700"
  else
    fail "link run: ssh wiring wrong —$_lr_ssh_bad"
  fi
  # The dropped chmod, pinned so it cannot creep back. blib_link_core used to run
  # `chmod 600` on the SOURCE — reaching into the consumer repo's working tree to change
  # a tracked file's mode, which post-#450 means Core chmod'ing its own vendored tree in
  # nine repos. It was never needed: ssh only refuses a config that is group/world
  # WRITABLE, and git checks out 0644. Assert the source keeps the mode git gave it.
  if [[ "$(_lr_mode "$LR/dotfiles/core/ssh/config")" != 600 ]]; then
    pass "link run: core/ssh/config keeps its checked-out mode (no chmod into the vendored tree)"
  else
    fail "link run: something chmod 600'd core/ssh/config — Core must not mutate the vendored tree"
  fi
  # The SEEDED files are the inverse contract: real copies, never symlinks, so a user's
  # identity/local edits are never tracked back into Core. A symlink here would publish
  # someone's git identity into the repo on their next commit.
  if [[ -f "$LR/config/git/local.gitconfig" && ! -L "$LR/config/git/local.gitconfig" ]] &&
    [[ -f "$LR/config/sesh/sesh.toml" && ! -L "$LR/config/sesh/sesh.toml" ]]; then
    pass "link run: seeded local.gitconfig and sesh.toml are COPIES, not symlinks"
  else
    fail "link run: a seeded file is missing or was symlinked (user edits would track back)"
  fi
  # Idempotency: bootstrap is re-run after every sync, so a second pass must be a no-op.
  # Comparing sorted PATH NAMES is not enough — blib_link removing and recreating every
  # symlink leaves the exact same names behind, which is precisely the churn this is
  # supposed to catch. Compare INODES: a torn-down-and-remade link gets a new one.
  # The second run's exit status is captured rather than discarded, so a rerun that fails
  # outright cannot pass this as "nothing changed".
  _lr_inodes() { find "$LR/config" "$LR/home" -maxdepth 4 -type l -exec ls -di {} + 2>/dev/null | sort -k2; }
  _lr_before="$(find "$LR/config" "$LR/home" -maxdepth 4 2>/dev/null | sort)"
  _lr_ino_before="$(_lr_inodes)"
  HOME="$LR/home" XDG_CONFIG_HOME="$LR/config" bash -c '
    set -u
    . "'"$HERE/lib/bootstrap-lib.sh"'"
    blib_link_core "'"$LR/dotfiles"'" "'"$LR/config"'" >/dev/null 2>&1
  '
  _lr_rc=$?
  _lr_after="$(find "$LR/config" "$LR/home" -maxdepth 4 2>/dev/null | sort)"
  _lr_ino_after="$(_lr_inodes)"
  if ((_lr_rc == 0)) && [[ "$_lr_before" == "$_lr_after" ]] &&
    [[ -n "$_lr_ino_before" && "$_lr_ino_before" == "$_lr_ino_after" ]] &&
    [[ -z "$(find "$LR/config" "$LR/home" -name '*.pre-dotfiles.*')" ]]; then
    pass "link run: a second pass is a true no-op (same inodes, no backups, rc=0)"
  else
    fail "link run: re-running bootstrap churned links, backed a file up, or failed (rc=$_lr_rc)"
  fi

  # A FAILED tpm clone must read as a failure. It used to be announced with blib_say —
  # blue `::` on STDOUT, the identical shape to the "cloning tpm" progress line above —
  # with git's error discarded by `>/dev/null 2>&1`. Behind a proxy that left tmux with no
  # plugin manager, nothing in the log to notice, and an empty tally, so an adopting
  # bootstrap could not tell a degraded box from a good one.
  #
  # Hermetic and OFFLINE: GIT_ALLOW_PROTOCOL=file makes git refuse the https transport, so
  # the clone fails deterministically without depending on the remote being unreachable
  # (or reachable). $config is fresh, so the clone is genuinely attempted.
  TF="$SANDBOX/tpmfail"
  rm -rf "$TF"
  mkdir -p "$TF/home" "$TF/config"
  HOME="$TF/home" XDG_CONFIG_HOME="$TF/config" GIT_ALLOW_PROTOCOL=file \
    BLIB_ONLY="tmux" BLIB_SKIP="" bash -c '
      set -u
      . "'"$HERE/lib/bootstrap-lib.sh"'"
      blib_link_core "'"$LR/dotfiles"'" "'"$TF/config"'"
      printf "TALLY=%s\n" "$(blib_failed_count)"
    ' >"$TF/out" 2>"$TF/err"
  if grep -q "tpm clone failed" "$TF/err"; then
    pass "tpm clone failure warns on STDERR"
  else
    fail "tpm clone failure did not reach stderr"
  fi
  # The regression itself: the message must not be on stdout, where blib_say put it.
  if grep -q "tpm clone failed" "$TF/out"; then
    fail "tpm clone failure is on STDOUT (blib_say regression — it must use blib_note_fail)"
  else
    pass "tpm clone failure is NOT on stdout (no longer a blib_say status line)"
  fi
  # Recorded, so blib_failures_report / a caller's --strict can act on it downstream.
  if grep -q "^TALLY=[1-9]" "$TF/out"; then
    pass "tpm clone failure lands in the blib_note_fail tally"
  else
    fail "tpm clone failure was not recorded in the tally"
  fi
  # git's own error is the whole diagnosis (DNS, proxy, TLS, rate limit) and used to be
  # thrown away. Assert the indented passthrough, not git's wording, which varies.
  #
  # `[^[:space:]]` is load-bearing, not decoration: an EMPTY capture still produces an
  # indented line, because `printf '%s\n' ""` emits one empty line and sed indents it to
  # four spaces. A bare `^    ` therefore passed whether or not anything was captured —
  # exactly the regression this is here to catch. Require real content after the indent.
  if grep -q '^    [^[:space:]]' "$TF/err"; then
    pass "tpm clone failure surfaces git's own error, indented under it"
  else
    fail "tpm clone failure discarded git's error output"
  fi
else
  skip "bootstrap link run (git unavailable)"
fi

