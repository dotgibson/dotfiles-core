# scripts/test/35-new-os-repo.sh
# scaffolded entry files + the --no-vendor recovery command (scripts/new-os-repo.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── new-os-repo.sh emits LINTABLE entry files (scripts/new-os-repo.sh) ───────
# Every OS repo this generator stamps inherits whatever it writes, so a defect here
# ships to each new layer from birth and is only ever noticed downstream.
#
# #451: it emitted the three ZDOTDIR entry files EXTENSIONLESS — zsh/zshenv,
# zsh/zprofile, zsh/zshrc — because their symlink destinations (~/.zshenv,
# $ZDOTDIR/.zshrc, $ZDOTDIR/.zprofile) have no extension either. Core's reusable lint
# gate selects repo-owned zsh with `git ls-files '*.zsh'`, so none of the three matched
# and none was ever syntax-checked, in any repo, from the day the generator was added.
#
# ~/.zshenv is the file that makes this worth a fixture rather than a one-line fix: it
# is sourced on EVERY zsh invocation including non-interactive ones, and it carries the
# ZDOTDIR indirection, so a syntax error there breaks login shells outright rather than
# degrading them. It was simultaneously the highest-blast-radius file in an OS repo and
# the only one the gate could not see.
#
# Asserted here rather than trusted, because the pull toward renaming these back to
# match their destinations is permanent — the filenames LOOK wrong until you know why.
if have git && have zsh; then
  hdr "new-os-repo.sh entry files (lintable by construction)"
  NOR="$SANDBOX/newosrepo"
  rm -rf "$NOR"
  # --no-vendor: skip the `git subtree add`, which is the only network call in the
  # script. Everything this asserts is written before/independently of it.
  # BORN ON main, whatever the author's init.defaultBranch says (here forced to trunk):
  # the scaffolded workflows filter pushes to [main, master], so any other birth branch
  # would leave the repo with no push-triggered CI — the floor's "CI runs it" rung gone.
  if env -u CORE_JSON GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=trunk bash "$HERE/scripts/new-os-repo.sh" --no-vendor Fixture "$SANDBOX/nor-trunk" >/dev/null 2>&1 && [[ "$(git -C "$SANDBOX/nor-trunk" symbolic-ref --short HEAD 2>/dev/null)" == main ]]; then
    pass "new-os-repo: the scaffold is born on main even under init.defaultBranch=trunk (the workflows' push filter cannot miss it)"
  else
    fail "new-os-repo: under init.defaultBranch=trunk the scaffold landed on '$(git -C "$SANDBOX/nor-trunk" symbolic-ref --short HEAD 2>/dev/null)', not main"
  fi
  rm -rf "$SANDBOX/nor-trunk"
  if env -u CORE_JSON bash "$HERE/scripts/new-os-repo.sh" --no-vendor Fixture "$NOR" >/dev/null 2>&1; then
    _nor_bad=""
    for _nor_f in zshenv zprofile zshrc; do
      [[ -f "$NOR/zsh/$_nor_f.zsh" ]] || _nor_bad="$_nor_bad zsh/$_nor_f.zsh(missing)"
      # The extensionless name must NOT come back alongside it: a generator writing both
      # would satisfy the check above while still shipping an unlinted file.
      [[ -e "$NOR/zsh/$_nor_f" ]] && _nor_bad="$_nor_bad zsh/$_nor_f(extensionless)"
    done
    if [[ -z "$_nor_bad" ]]; then
      pass "new-os-repo: the three ZDOTDIR entry files are written as *.zsh (lint-gate visible)"
    else
      fail "new-os-repo: entry-file naming wrong —$_nor_bad"
    fi
    # The rename is only behaviour-neutral if the generated bootstrap follows it. A repo
    # with zshenv.zsh on disk and `link .../zsh/zshenv` in bootstrap.sh has no ~/.zshenv
    # at all — no ZDOTDIR, so the loader is never reached and the shell starts bare.
    if grep -q 'link "\$REPO/zsh/zshenv\.zsh" *"\$HOME/\.zshenv"' "$NOR/bootstrap.sh" &&
      grep -q 'link "\$REPO/zsh/zprofile\.zsh" *"\$CFG/zsh/\.zprofile"' "$NOR/bootstrap.sh" &&
      grep -q 'link "\$REPO/zsh/zshrc\.zsh" *"\$CFG/zsh/\.zshrc"' "$NOR/bootstrap.sh"; then
      pass "new-os-repo: bootstrap.sh links the .zsh sources to the extensionless destinations"
    else
      fail "new-os-repo: bootstrap.sh link lines disagree with the scaffolded filenames"
    fi
    # And the gate can only help if what it reads actually parses. This is the check that
    # never ran on these three files in any repo until #451.
    _nor_syn=""
    for _nor_f in "$NOR"/zsh/*.zsh; do
      zsh -n "$_nor_f" 2>/dev/null || _nor_syn="$_nor_syn $(basename "$_nor_f")"
    done
    if [[ -z "$_nor_syn" ]]; then
      pass "new-os-repo: every scaffolded entry file passes zsh -n"
    else
      fail "new-os-repo: scaffolded entry file(s) fail zsh -n —$_nor_syn"
    fi

    # ── #691: born meeting the fleet's make vocabulary and the test floor ──────────
    # The scaffold is the OTHER way a repo enters the fleet (the first is `cp -r
    # dotfiles-Fedora`), and until this landed it stamped no Makefile and no test/ — so a
    # greenfield repo was **missing** across its whole row of the vocabulary register the
    # day it joined scripts/os-repos.txt. These pin that it now is not, and they judge it
    # with the SAME script that judges the fleet, not a re-implementation of its rules.
    #
    # Every generated gate must clear the make-gate rule (#775) the fleet is held to. A
    # template that ships the broken guard shape would seed it into every future repo.
    _nor_mg="$(_core_make_gate_hits "$NOR")"
    if [[ -z "$_nor_mg" ]]; then
      pass "new-os-repo: the scaffolded Makefile clears the #775 make-gate rule"
    else
      fail "new-os-repo: a scaffolded Makefile gate cannot do what it says — $_nor_mg"
    fi
    _nor_syn=""
    for _nor_f in bootstrap.sh test/check-links.sh; do
      bash -n "$NOR/$_nor_f" 2>/dev/null || _nor_syn="$_nor_syn $_nor_f"
    done
    [[ -x "$NOR/test/check-links.sh" ]] || _nor_syn="$_nor_syn test/check-links.sh(not executable)"
    if [[ -z "$_nor_syn" ]]; then
      pass "new-os-repo: bootstrap.sh and test/check-links.sh parse, and the suite is executable"
    else
      fail "new-os-repo: scaffolded bash is broken —$_nor_syn"
    fi
    if have shellcheck; then
      # The reusable gate's exact opts (lint-call.yml), which the scaffolded Makefile exports too.
      if (cd "$NOR" && SHELLCHECK_OPTS="-e SC1090 -e SC1091 -e SC2015 -e SC2088" shellcheck -x bootstrap.sh test/check-links.sh) >/dev/null 2>&1; then
        pass "new-os-repo: the scaffolded bash is shellcheck-clean under the fleet gate's options"
      else
        fail "new-os-repo: scaffolded bash fails shellcheck: $(cd "$NOR" && SHELLCHECK_OPTS="-e SC1090 -e SC1091 -e SC2015 -e SC2088" shellcheck -x bootstrap.sh test/check-links.sh 2>&1 | head -5 | tr '\n' ' ')"
      fi
    else
      skip "new-os-repo: shellcheck over the scaffolded bash (shellcheck unavailable)"
    fi
    if have actionlint; then
      if actionlint "$NOR/.github/workflows/test.yml" "$NOR/.github/workflows/lint.yml" "$NOR/.github/workflows/auto-tag.yml" >/dev/null 2>&1; then
        pass "new-os-repo: the scaffolded test, lint and auto-tag workflows pass actionlint"
      else
        fail "new-os-repo: a scaffolded workflow fails actionlint: $(actionlint "$NOR/.github/workflows/test.yml" "$NOR/.github/workflows/lint.yml" "$NOR/.github/workflows/auto-tag.yml" 2>&1 | head -3 | tr '\n' ' ')"
      fi
    else
      skip "new-os-repo: actionlint over the scaffolded workflows (actionlint unavailable)"
    fi
    # The lint caller pins the CURRENT major, read from core.version — the Makefile's
    # claim that the gate's other legs run in CI is only true if this caller exists and
    # points at a live major.
    _nor_major="$(tr -d '[:space:]' <"$HERE/core.version" | cut -d. -f1)"
    if grep -qF "uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v$_nor_major" "$NOR/.github/workflows/lint.yml" 2>/dev/null; then
      pass "new-os-repo: the scaffolded lint caller uses lint-call.yml@v$_nor_major (core.version's major, not a typed one)"
    else
      fail "new-os-repo: the scaffolded lint caller is missing or pins a foreign major (want @v$_nor_major): $(grep -h 'uses:' "$NOR/.github/workflows/lint.yml" 2>/dev/null)"
    fi
    unset _nor_major
    # A scaffolded repo used to be born with NO auto-tag.yml, so it never cut a release of
    # its own — the collapsed version line #696 is about, in its most complete form. Assert
    # the caller exists AND carries the corrected shape, by asking the register itself: a
    # grep for the paths would pass on a file the register still calls core-only.
    _nor_frt="$SANDBOX/nor-frt"
    rm -rf "$_nor_frt"; mkdir -p "$_nor_frt"
    if cp -r "$NOR" "$_nor_frt/dotfiles-Fedora" 2>/dev/null && mkdir -p "$_nor_frt/dotfiles-Fedora/.git" &&
      _nor_frt_out="$(REPOS_ROOT="$_nor_frt" "$HERE/scripts/fleet-release-triggers.sh" --check 2>&1)"; then
      pass "new-os-repo: the scaffolded auto-tag caller passes the release-trigger register"
    else
      fail "new-os-repo: the scaffold is born releasing only on Core syncs, or unable to cut a non-patch: ${_nor_frt_out:-<no output>}"
    fi
    rm -rf "$_nor_frt"
    unset _nor_frt _nor_frt_out
    # The suite is a TEST, not an `exit 0` stub — run it, in both states the scaffold
    # actually produces. AS GENERATED with --no-vendor there is no core/ at all, and the
    # starter bootstrap refuses to run without one — correctly: a bootstrap that links
    # nothing from Core and reports "done" is the quiet failure. So the honest assertion
    # for that state is that the suite goes RED and names the cause. A first draft
    # manufactured an empty core/ here and called it the --no-vendor state, which the
    # scaffold never produces and which masked exactly this refusal.
    if (cd "$NOR" && ./test/check-links.sh) >"$SANDBOX/nor-suite.out" 2>&1; then
      fail "new-os-repo: the scaffolded suite passed on an UNVENDORED scaffold (no core/) — it would sign off a repo that links nothing from Core"
    elif grep -q 'core/ subtree missing' "$SANDBOX/nor-suite.out"; then
      pass "new-os-repo: as generated with --no-vendor (no core/), the suite fails loudly and names the missing core/"
    else
      fail "new-os-repo: the suite failed on the unvendored scaffold but did not say why — $(head -3 "$SANDBOX/nor-suite.out" | tr '\n' ' ')"
    fi
    # A core/ that EXISTS but is empty is the state between a bad vendor and a good one,
    # and it is the one bootstrap accepts: the suite must still go red, naming the loader
    # the scaffolded zshrc cannot live without — every other Core link is conditional.
    mkdir -p "$NOR/core"
    if (cd "$NOR" && ./test/check-links.sh) >"$SANDBOX/nor-empty.out" 2>&1; then
      fail "new-os-repo: the scaffolded suite passed with an EMPTY core/ — it would sign off a repo whose shells start bare"
    elif grep -q 'core/zsh/loader.zsh is missing' "$SANDBOX/nor-empty.out"; then
      pass "new-os-repo: with a core/ that lacks zsh/loader.zsh, the suite fails and names the loader"
    else
      fail "new-os-repo: the empty-core/ run failed but did not name the loader — $(grep FAIL "$SANDBOX/nor-empty.out" | head -2 | tr '\n' ' ')"
    fi
    # Then the VENDORED state: core/ seeded from Core's OWN tree — the same directories
    # bootstrap.sh links — so the Core-provided branches (every zsh module, both tmux
    # files, the single configs, mise-as-copy) are exercised rather than skipped.
    for _nor_d in zsh tmux starship nvim git mise; do
      [[ -d "$HERE/$_nor_d" ]] && cp -r "$HERE/$_nor_d" "$NOR/core/"
    done
    # ...and the three vendored files the lint legs read: the scanners, the pinned tool
    # versions and the ONE secrets policy (all in core.vendor, so a real vendor has them).
    mkdir -p "$NOR/core/scripts/lib"
    cp "$HERE/scripts/lib/common.sh" "$NOR/core/scripts/lib/"
    cp "$HERE/scripts/tool-versions.env" "$NOR/core/scripts/"
    cp "$HERE/gitleaks.toml" "$NOR/core/"
    # THE LINT LEGS, each driven both ways through PATH shims, so the fixture does not
    # depend on which linters this box happens to have. A shim dir with fake
    # markdownlint-cli2 / actionlint / gitleaks that RECORD their argv and exit 0 proves
    # each leg invokes its tool, on the right files, against Core's policy file; the same
    # shims exiting 1 prove a finding fails the leg; and a PATH holding only what make
    # and the recipes need (no linters, no npx) proves the absent-tool path SAYS it
    # skipped and still exits 0 — a silent skip is the failure mode #775 is about. The
    # two scanner legs need no tool: they run for real against the vendored common.sh.
    if have make; then
      _nor_shim="$SANDBOX/nor-shim"; _nor_min="$SANDBOX/nor-minbin"
      rm -rf "$_nor_shim" "$_nor_min"; mkdir -p "$_nor_shim" "$_nor_min"
      for _nor_t in markdownlint-cli2 actionlint gitleaks; do
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/%s.argv"\nexit "${NOR_SHIM_RC:-0}"\n' "$_nor_shim" "$_nor_t" >"$_nor_shim/$_nor_t"
        chmod +x "$_nor_shim/$_nor_t"
      done
      for _nor_t in sh bash make git sed grep awk cat env; do
        _nor_p="$(command -v "$_nor_t" 2>/dev/null)" && ln -s "$_nor_p" "$_nor_min/$_nor_t"
      done
      (cd "$NOR" && git add -A >/dev/null 2>&1 && git -c user.email=t@example.com -c user.name=tester commit -q -m 'scaffold + seeded core' >/dev/null 2>&1)
      _nor_legs=""
      # The trap scan must cover EVERY tracked file, the first one included: bash -c puts
      # the library in $0, so a stray `shift` there silently dropped SH_FILES' first entry.
      # Plant a leaked RETURN trap in a file that sorts first and it must be named.
      # Assembled from fragments, so THIS file never spells the banned shape: Core's own
      # RETURN-trap gate scans test-core.sh too, and the literal was a finding against it.
      _nor_sig="RET"; _nor_sig="${_nor_sig}URN"
      printf '#!/usr/bin/env bash\nf() { %s '"'"'echo bye'"'"' %s; :; }\nf\n' trap "$_nor_sig" >"$NOR/aaa-leak.sh"
      (cd "$NOR" && git add aaa-leak.sh >/dev/null 2>&1)
      if (cd "$NOR" && make trap-guard) >"$SANDBOX/nor-legs-leak.out" 2>&1 || ! grep -q 'aaa-leak.sh:2: a RETURN trap is armed without disarming itself' "$SANDBOX/nor-legs-leak.out"; then
        _nor_legs="$_nor_legs trap-guard-missed-first-file($(tail -1 "$SANDBOX/nor-legs-leak.out"))"
      fi
      (cd "$NOR" && git rm -q -f aaa-leak.sh >/dev/null 2>&1); command rm -f "$NOR/aaa-leak.sh"
      if ! (cd "$NOR" && make trap-guard make-gate) >"$SANDBOX/nor-legs-scan.out" 2>&1; then
        _nor_legs="$_nor_legs scanners-red($(tail -1 "$SANDBOX/nor-legs-scan.out"))"
      elif ! grep -q 'RETURN traps disarm themselves' "$SANDBOX/nor-legs-scan.out" || ! grep -q 'every Makefile gate skips' "$SANDBOX/nor-legs-scan.out"; then
        _nor_legs="$_nor_legs scanners-silent"
      fi
      if ! (cd "$NOR" && PATH="$_nor_shim:$PATH" make markdownlint actionlint secrets) >"$SANDBOX/nor-legs-tools.out" 2>&1; then
        _nor_legs="$_nor_legs tools-red($(tail -1 "$SANDBOX/nor-legs-tools.out"))"
      else
        grep -q 'README.md' "$_nor_shim/markdownlint-cli2.argv" 2>/dev/null || _nor_legs="$_nor_legs markdownlint-not-given-README"
        grep -q 'core/' "$_nor_shim/markdownlint-cli2.argv" 2>/dev/null && _nor_legs="$_nor_legs markdownlint-given-core/"
        [[ -e "$_nor_shim/actionlint.argv" ]] || _nor_legs="$_nor_legs actionlint-not-run"
        grep -qx 'core/gitleaks.toml' "$_nor_shim/gitleaks.argv" 2>/dev/null || _nor_legs="$_nor_legs gitleaks-not-on-Core-policy"
      fi
      if (cd "$NOR" && NOR_SHIM_RC=1 PATH="$_nor_shim:$PATH" make markdownlint) >/dev/null 2>&1; then _nor_legs="$_nor_legs markdownlint-finding-ignored"; fi
      if (cd "$NOR" && NOR_SHIM_RC=1 PATH="$_nor_shim:$PATH" make secrets) >/dev/null 2>&1; then _nor_legs="$_nor_legs secrets-finding-ignored"; fi
      if ! (cd "$NOR" && env -i PATH="$_nor_min" HOME="$HOME" make shellcheck markdownlint actionlint secrets) >"$SANDBOX/nor-legs-absent.out" 2>&1; then
        _nor_legs="$_nor_legs absent-tool-red($(tail -1 "$SANDBOX/nor-legs-absent.out"))"
      elif [[ "$(grep -c 'skipped; CI runs it' "$SANDBOX/nor-legs-absent.out")" != 4 ]]; then
        _nor_legs="$_nor_legs absent-tool-silent($(grep -c 'skipped; CI runs it' "$SANDBOX/nor-legs-absent.out")/4)"
      fi
      # The capability leg: a vendored Core older than v4.19.0 has no validator, and the
      # gate's leg skips there — so must this one, saying so; with the validator vendored
      # it must run and pass on the Fedora-verb stub the scaffold writes.
      if ! (cd "$NOR" && make capabilities) >"$SANDBOX/nor-legs-cap.out" 2>&1 || ! grep -q 'not vendored (Core older than v4.19.0) — skipped' "$SANDBOX/nor-legs-cap.out"; then
        _nor_legs="$_nor_legs capabilities-without-validator($(tail -1 "$SANDBOX/nor-legs-cap.out"))"
      fi
      cp "$HERE/scripts/check-capabilities.sh" "$NOR/core/scripts/" && chmod +x "$NOR/core/scripts/check-capabilities.sh"
      mkdir -p "$NOR/core/examples" && cp "$HERE/examples/os.capabilities.example" "$NOR/core/examples/" 2>/dev/null
      if ! (cd "$NOR" && make capabilities) >"$SANDBOX/nor-legs-cap2.out" 2>&1 || grep -q 'skipped' "$SANDBOX/nor-legs-cap2.out"; then
        _nor_legs="$_nor_legs capabilities-with-validator($(tail -1 "$SANDBOX/nor-legs-cap2.out"))"
      fi
      # A vendored Core OLDER than the scanners: an empty common.sh (no
      # _core_return_trap_hits, no _core_make_gate_hits) and no gitleaks.toml. Each of the
      # three legs must say it skipped and exit 0 — never scan nothing and pass.
      command cp "$NOR/core/scripts/lib/common.sh" "$SANDBOX/nor-common.bak"
      : >"$NOR/core/scripts/lib/common.sh"; command rm -f "$NOR/core/gitleaks.toml" "$_nor_shim/gitleaks.argv"
      if ! (cd "$NOR" && PATH="$_nor_shim:$PATH" make trap-guard make-gate secrets) >"$SANDBOX/nor-legs-old.out" 2>&1; then
        _nor_legs="$_nor_legs old-core-red($(tail -1 "$SANDBOX/nor-legs-old.out"))"
      elif [[ "$(grep -c 'skipped; CI runs it' "$SANDBOX/nor-legs-old.out")" != 3 ]] || [[ -e "$_nor_shim/gitleaks.argv" ]]; then
        _nor_legs="$_nor_legs old-core-silent-or-scanned($(grep -c 'skipped; CI runs it' "$SANDBOX/nor-legs-old.out")/3, gitleaks ran: $([[ -e "$_nor_shim/gitleaks.argv" ]] && echo yes || echo no))"
      fi
      command cp "$SANDBOX/nor-common.bak" "$NOR/core/scripts/lib/common.sh"; command cp "$HERE/gitleaks.toml" "$NOR/core/"
      if [[ -z "$_nor_legs" ]]; then
        pass "new-os-repo: every lint leg runs its tool on the right files (markdown minus core/, workflows, Core's gitleaks policy), fails on a finding, and says so when the tool is absent (shellcheck included); the two scanner legs run against the vendored common.sh; the capability leg skips without the validator and runs with it; a Core older than the scanners or the policy file makes trap-guard, make-gate and secrets skip, saying so"
      else
        fail "new-os-repo: the lint legs —$_nor_legs"
      fi
      rm -rf "$_nor_shim" "$_nor_min"
      unset _nor_shim _nor_min _nor_t _nor_p _nor_legs _nor_sig
    else
      skip "new-os-repo: driving the lint legs (make unavailable)"
    fi
    if (cd "$NOR" && ./test/check-links.sh) >"$SANDBOX/nor-suite-core.out" 2>&1; then
      # Not "passed" alone: prove the Core-provided branches actually RAN. Each named
      # link is one bootstrap.sh link line; the count is every Core zsh module + the rest.
      _nor_core_ok=1
      for _nor_l in 'zsh/loader.zsh' 'tmux/tmux.conf' 'tmux/tmux.reset.conf' 'starship.toml' '.config/nvim' '.gitconfig' 'mise config is seeded as a COPY'; do
        grep -q "^  ok .*$_nor_l" "$SANDBOX/nor-suite-core.out" || _nor_core_ok=0
      done
      _nor_core_n="$(grep -c '^  ok .* -> core/' "$SANDBOX/nor-suite-core.out")"
      # A bash glob, not `find -maxdepth` (GNU; this runs on the macOS lane too).
      _nor_zsh_files=("$HERE"/zsh/*.zsh)
      _nor_zsh_n=${#_nor_zsh_files[@]}
      [[ -e "${_nor_zsh_files[0]}" ]] || _nor_zsh_n=0
      # EXACTLY every module once + tmux ×2 + starship + nvim + git: a spare count would
      # let one skipped module hide behind a double-counted loader.
      if ((_nor_core_ok)) && ((_nor_core_n == _nor_zsh_n + 5)); then
        pass "new-os-repo: against a Core-seeded core/ the suite asserts every Core link exactly once ($_nor_core_n Core links: $_nor_zsh_n zsh modules + tmux ×2 + starship + nvim + git) and mise-as-copy"
      else
        fail "new-os-repo: the suite's Core-provided branches did not all run exactly once against a seeded core/ ($_nor_core_n Core links asserted, want $((_nor_zsh_n + 5)); named-link coverage ok=$_nor_core_ok)"
      fi
      unset _nor_core_ok _nor_core_n _nor_zsh_n _nor_zsh_files _nor_l
    else
      fail "new-os-repo: the scaffolded suite fails against a Core-seeded core/ — $(grep FAIL "$SANDBOX/nor-suite-core.out" | head -3 | tr '\n' ' ')"
    fi
    unset _nor_d
    # ...and it CAN fail. A gate nobody has seen red is not known to work (the bench-gate
    # lesson, #688). Strip the "already linked" short-circuit from a copy of the bootstrap,
    # so every run re-links and announces it: the idempotency assertion must go red.
    _nor_brk="$SANDBOX/newosrepo-broken"
    rm -rf "$_nor_brk"
    cp -r "$NOR" "$_nor_brk"
    sed -i.bak '/readlink "\$dest"/d' "$_nor_brk/bootstrap.sh" && rm -f "$_nor_brk/bootstrap.sh.bak"
    if (cd "$_nor_brk" && ./test/check-links.sh) >/dev/null 2>&1; then
      fail "new-os-repo: the scaffolded suite passed a bootstrap that re-links on every run — it cannot fail"
    else
      pass "new-os-repo: the scaffolded suite goes red on a non-idempotent bootstrap"
    fi
    # ...and on one that re-links SILENTLY. The primary idempotency witness is the
    # mutating commands the second run invokes (rm/ln/mv/cp/mkdir, logged by PATH shims),
    # not the `linked` lines and not inode identity — a filesystem may hand a re-created
    # link the same inode straight back. So a bootstrap that removes and re-creates every
    # link while saying nothing must go red on THAT witness.
    sed -i.bak '/echo "linked /d' "$_nor_brk/bootstrap.sh" && rm -f "$_nor_brk/bootstrap.sh.bak"
    if (cd "$_nor_brk" && ./test/check-links.sh) >"$SANDBOX/nor-silent.out" 2>&1; then
      fail "new-os-repo: the scaffolded suite passed a bootstrap that re-links silently — the mutating-command witness (the rm/ln shims) did not fire"
    elif grep -q 'invoked mutating commands' "$SANDBOX/nor-silent.out"; then
      pass "new-os-repo: the scaffolded suite goes red on a bootstrap that re-links silently (the rm/ln were observed, inode reuse or not)"
    else
      fail "new-os-repo: the silent re-link failed for another reason — $(grep FAIL "$SANDBOX/nor-silent.out" | head -2 | tr '\n' ' ')"
    fi
    rm -rf "$_nor_brk"
    # ...and on one that REWRITES a regular file in place THROUGH A REDIRECTION — the one
    # mutation no wrapped command performs and an inode survives. That is what the
    # snapshot's per-file checksum is for, and this proves it fires on its own: the
    # rewrite appends one byte to the seeded mise config via `>>`, invoking no rm/ln/mv/
    # cp/mkdir, so only the checksum can see it. Inserted BEFORE the seed and guarded on
    # the file existing, so run one still seeds a faithful copy (the suite compares the
    # copy's bytes with the seed) and only run two mutates. The line is inserted with awk,
    # not `sed … \n`, and the byte is fixed, not `date +%N`: BSD sed does not expand \n in
    # a replacement and macOS date has no %N, and this runs on the macOS lane too.
    _nor_brk="$SANDBOX/newosrepo-rewrite"
    rm -rf "$_nor_brk"
    cp -r "$NOR" "$_nor_brk"
    awk '{ print } /^CFG="\$HOME\/\.config"$/ { print "[[ -f \"$CFG/mise/config.toml\" ]] && printf x >>\"$CFG/mise/config.toml\"" }' \
      "$NOR/bootstrap.sh" >"$_nor_brk/bootstrap.sh"
    if (cd "$_nor_brk" && ./test/check-links.sh) >"$SANDBOX/nor-rewrite.out" 2>&1; then
      fail "new-os-repo: the scaffolded suite passed a bootstrap that rewrites the mise seed in place on every run — the checksum witness does not fire"
    elif grep -q 'changed the tree' "$SANDBOX/nor-rewrite.out"; then
      pass "new-os-repo: the scaffolded suite goes red on an in-place rewrite through a redirection (checksum witness, with no command to observe)"
    else
      fail "new-os-repo: the in-place rewrite failed for another reason — $(grep FAIL "$SANDBOX/nor-rewrite.out" | head -2 | tr '\n' ' ')"
    fi
    rm -rf "$_nor_brk"
    # ...and on one that rewrites a file with the SAME bytes, through a redirection: no
    # wrapped command, and inode, mode, kind and checksum all survive — only the stamp
    # witness (mtime) can see it. Same placement and guard as the other two cases.
    _nor_brk="$SANDBOX/newosrepo-samebytes"
    rm -rf "$_nor_brk"
    cp -r "$NOR" "$_nor_brk"
    awk '{ print } /^CFG="\$HOME\/\.config"$/ { print "[[ -f \"$CFG/mise/config.toml\" ]] && cat \"$REPO/core/mise/config.toml\" >\"$CFG/mise/config.toml\"" }' \
      "$NOR/bootstrap.sh" >"$_nor_brk/bootstrap.sh"
    if (cd "$_nor_brk" && ./test/check-links.sh) >"$SANDBOX/nor-samebytes.out" 2>&1; then
      fail "new-os-repo: the scaffolded suite passed a bootstrap that rewrites a file with identical bytes on every run — no write witness"
    elif grep -q 'rewrote files in place' "$SANDBOX/nor-samebytes.out"; then
      pass "new-os-repo: the scaffolded suite goes red on a same-byte rewrite (the stamp witness, when nothing else can see it)"
    else
      fail "new-os-repo: the same-byte rewrite fixture failed for another reason — $(grep FAIL "$SANDBOX/nor-samebytes.out" | head -2 | tr '\n' ' ')"
    fi
    rm -rf "$_nor_brk"
    # ...and on one that changes a MODE, through an absolute-path chmod so the PATH shims
    # never see it: inode, kind and bytes all survive, and only the snapshot's mode field
    # can. Same placement and guard as the rewrite case, so run one is untouched. It ADDS
    # an executable bit rather than setting 600: the tracked TOML seed is never executable,
    # so the delta is guaranteed — under `umask 077` the seeded copy is already 600 and a
    # `chmod 600` would change nothing, passing the suite for the wrong reason.
    _nor_brk="$SANDBOX/newosrepo-chmod"
    rm -rf "$_nor_brk"
    cp -r "$NOR" "$_nor_brk"
    awk '{ print } /^CFG="\$HOME\/\.config"$/ { print "[[ -f \"$CFG/mise/config.toml\" ]] && /bin/chmod u+x \"$CFG/mise/config.toml\"" }' \
      "$NOR/bootstrap.sh" >"$_nor_brk/bootstrap.sh"
    if (cd "$_nor_brk" && ./test/check-links.sh) >"$SANDBOX/nor-chmod.out" 2>&1; then
      fail "new-os-repo: the scaffolded suite passed a bootstrap that changes a file's mode on every run — the snapshot does not carry modes"
    elif grep -q 'changed the tree' "$SANDBOX/nor-chmod.out"; then
      pass "new-os-repo: the scaffolded suite goes red on a mode change made past the shims (mode field in the snapshot)"
    else
      fail "new-os-repo: the mode-change fixture failed for another reason — $(grep FAIL "$SANDBOX/nor-chmod.out" | head -2 | tr '\n' ' ')"
    fi
    rm -rf "$_nor_brk"
    if have make; then
      # Every canonical verb RESOLVES (the promise scripts/make-vocabulary.txt makes): -n
      # expands all seven without needing shellcheck or a Core checkout; then the four that
      # need no tool run for real.
      if make -C "$NOR" -n help lint check dry-run packages-check core-verify test >/dev/null 2>&1; then
        pass "new-os-repo: all seven canonical make verbs resolve in the scaffold"
      else
        fail "new-os-repo: a canonical make verb does not resolve — $(make -C "$NOR" -n help lint check dry-run packages-check core-verify test 2>&1 | grep -i 'no rule' | head -2 | tr '\n' ' ')"
      fi
      if make -C "$NOR" help dry-run packages-check test >/dev/null 2>&1; then
        pass "new-os-repo: make help / dry-run / packages-check / test run green in the scaffold"
      else
        fail "new-os-repo: a tool-free canonical verb fails in the scaffold — $(make -C "$NOR" help dry-run packages-check test 2>&1 | tail -3 | tr '\n' ' ')"
      fi
      # --help is a usage() heredoc, not a line range of the header: a range drifts the
      # moment a line is added above it and then prints implementation as help (the
      # pattern sync-core.sh itself had to drop). Assert the text, and that no code leaks.
      _nor_help="$(bash "$NOR/bootstrap.sh" --help 2>&1)"; _nor_help_rc=$?
      if ((_nor_help_rc == 0)) && grep -q '^usage: bootstrap.sh ' <<<"$_nor_help" && grep -q -- '--links-only' <<<"$_nor_help" && ! grep -qE 'set -e|BASH_SOURCE|^#' <<<"$_nor_help" && ! grep -qE "sed -n '[0-9]+,[0-9]+p'" "$NOR/bootstrap.sh"; then
        pass "new-os-repo: bootstrap.sh --help prints a usage() heredoc (every flag named, no implementation line, no line range to drift)"
      else
        fail "new-os-repo: bootstrap.sh --help is not a drift-proof usage (rc=$_nor_help_rc): $(head -3 <<<"$_nor_help" | tr '\n' ' ')"
      fi
      unset _nor_help _nor_help_rc
    else
      skip "new-os-repo: running the canonical verbs (make unavailable)"
    fi
    # THE ASSERTION THAT MATTERS: the register itself. A fake fleet root holding the scaffold
    # under a name from scripts/os-repos.txt (the scaffold ran `git init`, so .git exists)
    # must render a row of `ok` and a clean --check — the same verdict the fleet is held to.
    _nor_fleet="$SANDBOX/scaffold-fleet"
    rm -rf "$_nor_fleet"
    mkdir -p "$_nor_fleet"
    cp -r "$NOR" "$_nor_fleet/dotfiles-Alpine"
    _nor_fv="$(REPOS_ROOT="$_nor_fleet" "$HERE/scripts/fleet-vocabulary.sh" --check 2>&1)"
    _nor_rc=$?
    if ((_nor_rc == 0)) && [[ "$_nor_fv" == *"every verb x repo cell resolves"* ]]; then
      pass "new-os-repo: fleet-vocabulary.sh --check credits the scaffold on every verb and the test floor"
    else
      fail "new-os-repo: the vocabulary register does not credit the scaffold (rc=$_nor_rc): $(printf '%s' "$_nor_fv" | tr '\n' ' ')"
    fi
    rm -rf "$_nor_fleet"
    unset _nor_mg _nor_brk _nor_fleet _nor_fv _nor_rc
  else
    fail "new-os-repo: --no-vendor scaffold run failed outright"
  fi
else
  skip "new-os-repo entry files (git or zsh unavailable)"
fi

# ── the --no-vendor recovery command new-os-repo.sh advertises ────────────────
# The scaffold prints ONE copyable command for the state it cannot finish itself (no
# core/ yet), and nothing ran it: the --no-vendor output above goes to /dev/null. Every
# property it has been reviewed for is pinned here — ordering (guarded canonical-name
# symlink, commit, subtree add, then the pinned sync in a throwaway worktree), %q
# escaping (a parent with a space, a name with an apostrophe), CORE_REMOTE propagation,
# the peeled-commit pin, REPOS_ROOT, and that it parses — plus the guard itself, the one
# part that runs without network: it must create the link when the path is free, be
# idempotent, and refuse a foreign occupant of the canonical path.
if have git; then
  hdr "new-os-repo.sh recovery command (the advertised --no-vendor path)"
  _rc_parent="$SANDBOX/recovery/parent dir"
  rm -rf "$SANDBOX/recovery"
  mkdir -p "$_rc_parent"
  # NORMALIZED through pwd, as the scaffold normalizes its own paths: on macOS TMPDIR
  # ends in a slash, so $SANDBOX carries a `//` that the scaffold's `cd && pwd` folds
  # away, and a literal comparison against $SANDBOX was one slash off on that lane.
  _rc_parent="$(cd "$_rc_parent" && pwd)"
  _rc_recov="$(cd "$SANDBOX/recovery" && pwd)"
  _rc_target="$_rc_parent/O'Brien"
  _rc_out="$(env -u CORE_JSON CORE_REMOTE='https://example.invalid/fork.git' CORE_BRANCH='refs/tags/v9' bash "$HERE/scripts/new-os-repo.sh" --no-vendor Fixture "$_rc_target" 2>&1)"
  # PURE-BASH extraction, no grep/sed: the hint is one ~3 KB line that carries every
  # %q-quoted path and message of the chain, and BSD sed on macOS returns NOTHING
  # ("illegal byte sequence") for a line it cannot decode, which read here as "no
  # recovery command" on a lane where the scaffold had printed it in full.
  _rc_cmd=""
  if [[ "$_rc_out" == *"run later: "* ]]; then
    _rc_cmd="${_rc_out#*run later: }"; _rc_cmd="${_rc_cmd%%$'\n'*}"; _rc_cmd="${_rc_cmd%; sync-core.sh resolves the NAME*}"
  fi
  if [[ -z "$_rc_cmd" ]]; then
    fail "recovery: the --no-vendor run printed no recovery command — the run said: $(tail -3 <<<"$_rc_out" | tr '\n' '|' | cut -c1-400)"
  else
    if bash -n <(printf '%s\n' "$_rc_cmd") 2>/dev/null; then
      pass "recovery: the command parses with a space in the parent and an apostrophe in the name (%q holds)"
    else
      fail "recovery: the command does not parse — $_rc_cmd"
    fi
    # PURE ASCII: every message in the chain goes through %q, and bash 3.2 quotes a
    # multibyte character byte by byte — invalid UTF-8 that BSD grep refuses to match
    # (which is how this fixture went red on macOS while awk and bash -n agreed).
    if LC_ALL=C grep -q '[^ -~]' <<<"$_rc_cmd"; then
      fail "recovery: the command carries non-ASCII bytes — $(LC_ALL=C grep -o '[^ -~]\{1,\}' <<<"$_rc_cmd" | head -3 | tr '\n' ' ')"
    else
      pass "recovery: the command is pure ASCII (safe through bash 3.2's %q and BSD grep)"
    fi
    # Ordering: each marker must appear, and after the previous one. Positions, not one
    # regex — a regex over a %q-escaped command is unreadable and was wrong on arrival.
    _rc_prev=0; _rc_order=""
    # The commit marker sits between `add -A` and the subtree add on purpose: subtree add
    # needs a valid HEAD, and a chain that staged but never committed would otherwise
    # pass this ordering check.
    for _rc_m in '{ {' 'ln -sfn ' ' add -A ' ' commit -q -m ' ' cat-file -e HEAD:core 2>/dev/null || ' 'subtree add --prefix=core ' 'git fetch ' 'git worktree add --detach ' 'sync-core.sh ' 'grep -Eq ' 'git worktree remove --force ' '&& rmdir "$_wtp" && exit '; do
      _rc_pos="$(awk -v m="$_rc_m" '{ print index($0, m) }' <<<"$_rc_cmd")"
      ((_rc_pos > _rc_prev)) || _rc_order="$_rc_order [$_rc_m]"
      _rc_prev=$_rc_pos
    done
    if [[ -z "$_rc_order" ]]; then
      pass "recovery: ordering — guarded symlink, stage, commit, HEAD:core test, subtree add, fetch, throwaway worktree, sync, worktree and parent removed"
    else
      fail "recovery: ordering wrong at$_rc_order — $_rc_cmd"
    fi
    _rc_bad=""
    grep -qF 'git fetch https://example.invalid/fork.git refs/tags/v9' <<<"$_rc_cmd" || _rc_bad="$_rc_bad fetch-from-CORE_REMOTE"
    grep -qF 'CORE_REMOTE=https://example.invalid/fork.git ' <<<"$_rc_cmd" || _rc_bad="$_rc_bad CORE_REMOTE-forwarded"
    grep -qF "CORE_BRANCH=\"\$(git rev-parse 'HEAD^{commit}')\"" <<<"$_rc_cmd" || _rc_bad="$_rc_bad peeled-commit-pin"
    grep -qF "REPOS_ROOT=$(printf '%q' "$_rc_parent") " <<<"$_rc_cmd" || _rc_bad="$_rc_bad REPOS_ROOT"
    grep -qF 'subtree add --prefix=core https://example.invalid/fork.git refs/tags/v9 --squash' <<<"$_rc_cmd" || _rc_bad="$_rc_bad subtree-add-source"
    # The worktree subshell must return the SYNC's status, not the cleanup's. (Here-strings
    # throughout: `printf … | grep -q` under pipefail is the SIGPIPE hazard §5d rejects.)
    grep -qF '{ git worktree add --detach "$_wt" FETCH_HEAD || { rmdir "$_wtp"; false; }; } && { _o="$( (cd "$_wt" && ' <<<"$_rc_cmd" || _rc_bad="$_rc_bad add-failure-removes-own-parent+cleanup-nested+captured-sync"
    grep -qF 'mktemp -d "${TMPDIR:-/tmp}/dotfiles-core-sync.XXXXXX"' <<<"$_rc_cmd" || _rc_bad="$_rc_bad mktemp-without-template(BSD mktemp needs one)"
    grep -qF 'CORE_COLOR=never REPOS_ROOT=' <<<"$_rc_cmd" || _rc_bad="$_rc_bad color-off-for-the-summary"
    grep -qF '_l="$(awk '"'"'/^ *repos: /{l=$0} END{print l}'"'"' <<<"$_o")"; if grep -Eq '"'"'^ *repos: +updated 1 +skipped 0 +failed 0 +\(of 1 targeted\)$'"'"' <<<"$_l"; then _rc=0; else _rc=1; fi; git worktree remove --force "$_wt" && rmdir "$_wtp" && exit "$_rc"; })' <<<"$_rc_cmd" || _rc_bad="$_rc_bad last-row-summary-verdict+parent-removed"
    grep -qF ') 2>&1)" || true; printf ' <<<"$_rc_cmd" || _rc_bad="$_rc_bad capture-is-errexit-safe"
    if [[ -z "$_rc_bad" ]]; then
      pass "recovery: CORE_REMOTE (twice), the ref, the peeled-commit pin and REPOS_ROOT are all carried"
    else
      fail "recovery: the command is missing —$_rc_bad"
    fi
    # The worktree subshell's STATUS, behaviourally: take the emitted subshell (from the
    # Core-side `(cd` to the end), stub the four network/worktree steps — fetch → true,
    # worktree add → mkdir, the sync → a printf of a chosen SUMMARY LINE (the released
    # script's is the verdict), worktree remove → rmdir — and run it UNDER `bash -e`, since the
    # reader's shell may have errexit on and the cleanup must still be reached. A shape
    # assertion alone could pass a chain whose cleanup still masked the sync.
    _rc_sub="${_rc_cmd#*"--squash; } && (cd "}"   # drop everything up to the Core-side subshell (the FIRST `(cd` after the subtree add)
    _rc_sub="(cd ${_rc_sub%%   # VENDORING*}"  # and the trailing comment
    _rc_drive() { # _rc_drive <sync-status-cmd> <remove-cmd> → exit status of the driven subshell
      local d
      # mktemp is pointed INSIDE the sandbox so the parent's removal can be asserted.
      d="$(printf '%s' "$_rc_sub" |
        sed -e 's|git fetch [^&]* && |true \&\& |' \
            -e "s|mktemp -d \"[^\"]*\"|mktemp -d '$SANDBOX/recovery/wt.XXXXXX'|" \
            -e 's|git worktree add --detach "$_wt" FETCH_HEAD|mkdir -p "$_wt"|' \
            -e "s|\./scripts/sync-core\.sh [^)]*)|$1)|" \
            -e "s|git worktree remove --force \"\$_wt\"|$2 \"\$_wt\"|")"
      (cd "$SANDBOX/recovery" && bash -e -c "$d") >/dev/null 2>&1
    }
    _rc_st=""
    _rc_ok="printf 'repos:  updated 1   skipped 0   failed 0   (of 1 targeted)'"
    _rc_ko="printf 'repos:  updated 0   skipped 0   failed 1   (of 1 targeted)'"
    _rc_sk="printf 'repos:  updated 0   skipped 1   failed 0   (of 1 targeted)'"
    _rc_drive "$_rc_ko" rmdir; _rc_st="$_rc_st sync-fails:$?"
    _rc_leftover_fail="$(find "$SANDBOX/recovery" -name 'wt.*' -print)"
    _rc_drive "$_rc_sk" rmdir; _rc_st="$_rc_st sync-skipped:$?"
    _rc_drive "$_rc_ok" rmdir; _rc_st="$_rc_st sync-ok:$?"
    _rc_leftover="$(find "$SANDBOX/recovery" -name 'wt.*' -print)"
    _rc_drive "$_rc_ok" false; _rc_st="$_rc_st cleanup-fails:$?"
    # The cleanup-fails drive leaks its parent BY CONSTRUCTION (the stubbed removal fails
    # before the rmdir); tidy that one here, so the add-fails assertion below measures
    # only what the add-fails path leaves behind.
    find "$SANDBOX/recovery" -name 'wt.*' -type d -exec rm -rf {} + 2>/dev/null
    if [[ "$_rc_st" == " sync-fails:1 sync-skipped:1 sync-ok:0 cleanup-fails:1" ]]; then
      pass "recovery: the verdict is the released script's summary (failed 1 → 1, skipped 1 → 1, updated 1 → 0, failed cleanup → 1)"
    else
      fail "recovery: the worktree subshell masks a status —$_rc_st — driven: $_rc_sub"
    fi
    if [[ -z "$_rc_leftover" ]]; then
      pass "recovery: a successful recovery leaves no temp directory behind (the mktemp parent is removed)"
    else
      fail "recovery: the mktemp parent survives a successful recovery — $_rc_leftover"
    fi
    # The verdict is the FOOTER LINE, anchored at both ends: the captured log also carries
    # the target's name and every per-repo line, so an unanchored substring could be met
    # by earlier output (a name containing it) while the footer itself reports a failure.
    _rc_trap="echo '  ok  dotfiles-repos:  updated 1   skipped 0   failed 0   (of 1 targeted)'; echo '  repos:  updated 0   skipped 0   failed 1   (of 1 targeted)'"
    _rc_drive "$_rc_trap" rmdir; _rc_trap_st=$?
    if ((_rc_trap_st == 1)); then
      pass "recovery: the verdict is the anchored footer line — the success text earlier in the log, mid-line, does not outvote a failed footer"
    else
      fail "recovery: an unanchored success substring earlier in the log passed a failed footer (status $_rc_trap_st)"
    fi
    # ...and it is the LAST footer that is judged: the target's own output (a git hook)
    # could print a success-shaped footer before the sync prints its real one.
    _rc_trap="echo '  repos:  updated 1   skipped 0   failed 0   (of 1 targeted)'; echo '  repos:  updated 0   skipped 0   failed 1   (of 1 targeted)'"
    _rc_drive "$_rc_trap" rmdir; _rc_trap_st="$?"
    _rc_trap="echo '  repos:  updated 0   skipped 0   failed 1   (of 1 targeted)'; echo '  repos:  updated 1   skipped 0   failed 0   (of 1 targeted)'"
    _rc_drive "$_rc_trap" rmdir; _rc_trap_st="$_rc_trap_st/$?"
    if [[ "$_rc_trap_st" == "1/0" ]]; then
      pass "recovery: only the LAST repos: row is the verdict (a success footer followed by a failed one → 1; the reverse → 0)"
    else
      fail "recovery: the verdict is not the last repos: row (success-then-failed/failed-then-success → $_rc_trap_st, want 1/0)"
    fi
    unset _rc_trap _rc_trap_st
    if [[ -z "$_rc_leftover_fail" ]]; then
      pass "recovery: under bash -e a FAILED sync still reaches the cleanup (no temp directory left behind)"
    else
      fail "recovery: under bash -e a failed sync skipped the cleanup — $_rc_leftover_fail"
    fi
    # When `worktree add` FAILS, the cleanup must never run: the pasted subshell inherits
    # the reader's variables, and a force-remove of an inherited `_wt` would be the
    # worst outcome of a failed recovery. Drive with the add failing and a cleanup that
    # leaves a marker; the marker must not appear and the status must be non-zero.
    _rc_dr="$(printf '%s' "$_rc_sub" |
      sed -e 's|git fetch [^&]* && |true \&\& |' \
          -e "s|mktemp -d \"[^\"]*\"|mktemp -d '$SANDBOX/recovery/wt.XXXXXX'|" \
          -e 's|git worktree add --detach "$_wt" FETCH_HEAD|false|' \
          -e "s|git worktree remove --force \"\$_wt\"|touch '$SANDBOX/recovery/cleanup-ran'|")"
    (cd "$SANDBOX/recovery" && _wt=/should/never/be/touched bash -e -c "$_rc_dr") >/dev/null 2>&1; _rc_addfail=$?
    _rc_left_add="$(find "$SANDBOX/recovery" -name 'wt.*' -print)"
    if ((_rc_addfail != 0)) && [[ ! -e "$SANDBOX/recovery/cleanup-ran" ]]; then
      pass "recovery: when worktree add fails the cleanup never runs (an inherited \$_wt is never force-removed) and the status is non-zero"
    else
      fail "recovery: a failed worktree add still ran the cleanup (marker=$([[ -e "$SANDBOX/recovery/cleanup-ran" ]] && echo yes || echo no), status=$_rc_addfail)"
    fi
    # ...and the mktemp parent the chain itself created must not be leaked by that failure.
    # Asserted, not tidied: a first draft rm -rf'd the leak here and so never saw it.
    if [[ -z "$_rc_left_add" ]]; then
      pass "recovery: a failed worktree add removes the mktemp parent it just created (nothing left behind)"
    else
      fail "recovery: a failed worktree add leaked its mktemp parent — $_rc_left_add"
      find "$SANDBOX/recovery" -name 'wt.*' -type d -exec rm -rf {} + 2>/dev/null
    fi
    unset -f _rc_drive
    # The guard is the executable part: everything before the first `&& git -C`.
    _rc_guard="${_rc_cmd%% && git -C*}"
    _rc_canon="$_rc_parent/dotfiles-Fixture"
    if bash -c "$_rc_guard" 2>/dev/null && [[ -L "$_rc_canon" && "$(readlink "$_rc_canon")" == "$_rc_target" ]]; then
      pass "recovery: the canonical-name guard creates the symlink when the path is free"
    else
      fail "recovery: the guard did not create the canonical symlink — $_rc_guard"
    fi
    if bash -c "$_rc_guard" 2>/dev/null && [[ -L "$_rc_canon" && "$(readlink "$_rc_canon")" == "$_rc_target" && ! -e "$_rc_target/O'Brien" ]]; then
      pass "recovery: re-running the guard is idempotent (the link is replaced; nothing nests inside the target)"
    else
      fail "recovery: a second run of the guard nested a link or failed"
    fi
    rm -f "$_rc_canon"
    mkdir -p "$_rc_canon"
    : >"$_rc_canon/unrelated"
    if ! bash -c "$_rc_guard" >/dev/null 2>"$SANDBOX/recovery/guard.err" && grep -q 'refusing' "$SANDBOX/recovery/guard.err" && [[ -d "$_rc_canon" && ! -L "$_rc_canon" && -e "$_rc_canon/unrelated" && ! -e "$_rc_canon/O'Brien" ]]; then
      pass "recovery: the guard refuses a foreign directory at the canonical path and leaves it untouched"
    else
      fail "recovery: the guard did not refuse a foreign occupant of the canonical path"
    fi
    # RESUMABILITY, behaviourally: the materialize half (everything before the Core-side
    # subshell) run TWICE against the scaffold. The first run gets past the commit and
    # fails at the subtree add (the remote is example.invalid; no network is needed to
    # prove the add was reached — the scaffold commit exists and the status is non-zero).
    # Then core/ is committed by hand, standing in for an add that succeeded before the
    # sync failed, and the SAME command must skip the one-time add (the prefix is in
    # HEAD) and run through to where the sync would start: status 0, and no new commit.
    rm -rf "$_rc_canon"
    git -C "$_rc_target" config user.email t@example.com
    git -C "$_rc_target" config user.name tester
    _rc_pre="${_rc_cmd%%   # VENDORING*}"; _rc_pre="${_rc_pre% && (cd *}"
    # The driven copy points at a LOCAL path that cannot exist, so the subtree add fails
    # at once instead of entering DNS/proxy handling for example.invalid — hermetic and
    # deterministic offline; what is proved (the add was reached and failed) is unchanged.
    _rc_pre="${_rc_pre//https:\/\/example.invalid\/fork.git/$SANDBOX/recovery/no-such-remote.git}"
    (cd "$SANDBOX/recovery" && bash -c "$_rc_pre") >/dev/null 2>&1; _rc_pre1=$?
    _rc_pre1_log="$(git -C "$_rc_target" log --format=%s 2>/dev/null)"
    mkdir -p "$_rc_target/core" && : >"$_rc_target/core/placeholder"
    git -C "$_rc_target" add -A && git -C "$_rc_target" commit -q -m 'core/ landed' 2>/dev/null
    _rc_head="$(git -C "$_rc_target" rev-parse HEAD 2>/dev/null)"
    (cd "$SANDBOX/recovery" && bash -c "$_rc_pre") >"$SANDBOX/recovery/pre2.out" 2>&1; _rc_pre2=$?
    if ((_rc_pre1 != 0)) && grep -qF 'scaffold dotfiles-Fixture' <<<"$_rc_pre1_log" && ((_rc_pre2 == 0)) && [[ "$(git -C "$_rc_target" rev-parse HEAD 2>/dev/null)" == "$_rc_head" ]]; then
      pass "recovery: rerun after core/ is in HEAD skips the one-time subtree add and reaches the sync (resumable)"
    else
      fail "recovery: not resumable — first run rc=$_rc_pre1 (committed: $(tr '\n' ',' <<<"$_rc_pre1_log")), second run rc=$_rc_pre2: $(tail -1 "$SANDBOX/recovery/pre2.out" 2>/dev/null)"
    fi
    unset _rc_pre _rc_pre1 _rc_pre1_log _rc_pre2 _rc_head
  fi
  # --dry-run --no-vendor prints the same command BEFORE the target exists, so the
  # cd-based resolution above cannot run; a relative target must still come out anchored
  # to the invocation directory, or the chain (which cd's into the Core checkout) hands
  # the sync a REPOS_ROOT under Core and the sync skips the repo the hint was written for.
  _rc_dry="$(cd "$_rc_recov" && env -u CORE_JSON CORE_REMOTE='https://example.invalid/fork.git' bash "$HERE/scripts/new-os-repo.sh" --dry-run --no-vendor Fixture 'not yet/dotfiles-Fixture' 2>&1)"
  if [[ "$_rc_dry" == *"run later: "* ]]; then _rc_dry="${_rc_dry#*run later: }"; _rc_dry="${_rc_dry%%$'\n'*}"; else _rc_dry=""; fi
  if [[ -n "$_rc_dry" ]] && grep -qF "REPOS_ROOT=$(printf '%q' "$_rc_recov/not yet") " <<<"$_rc_dry" && grep -qF "git -C $(printf '%q' "$_rc_recov/not yet/dotfiles-Fixture") add -A" <<<"$_rc_dry" && [[ ! -e "$_rc_recov/not yet" ]]; then
    pass "recovery: a dry run of a not-yet-existing relative target embeds it ANCHORED to the invocation directory (REPOS_ROOT and git -C)"
  else
    fail "recovery: a dry-run relative target was embedded unanchored — expected [REPOS_ROOT=$(printf '%q' "$_rc_recov/not yet") ]; 'not yet' exists: $([[ -e "$_rc_recov/not yet" ]] && echo yes || echo no); hint: $(cut -c1-300 <<<"$_rc_dry")"
  fi
  unset _rc_dry
  # That verdict reads the released script's `repos:` footer, which exists since v4.1.0:
  # an older exact freeze prints a per-CHECK count, so a successful sync would be reported
  # as a failure AFTER vendoring and stamping the target. The scaffold refuses such a pin
  # before writing anything (exit 2, target absent); the floor itself, a major alias at or
  # above it, a newer freeze and a ref it cannot judge (a branch) all pass. A prerelease
  # sorts below its release: v4.0.2-rc1 and v4.1.0-rc.1 are older than the floor,
  # v4.1.1-rc1 is not.
  _rc_floor_bad=""
  for _rc_pin in v3.9.0 refs/tags/v3 v4.0.2 refs/tags/v4.0.9 refs/tags/v4.0.2-rc1 v4.1.0-rc.1; do
    _rc_fo="$(env -u CORE_JSON CORE_REMOTE='https://example.invalid/fork.git' CORE_BRANCH="$_rc_pin" bash "$HERE/scripts/new-os-repo.sh" --no-vendor Fixture "$SANDBOX/recovery/old-pin" 2>&1)"; _rc_frc=$?
    { ((_rc_frc == 2)) && grep -qF 'older than v4.1.0' <<<"$_rc_fo" && [[ ! -e "$SANDBOX/recovery/old-pin" ]]; } || _rc_floor_bad="$_rc_floor_bad $_rc_pin(rc=$_rc_frc,exists=$([[ -e "$SANDBOX/recovery/old-pin" ]] && echo yes || echo no))"
    rm -rf "$SANDBOX/recovery/old-pin"
  done
  for _rc_pin in v4.1.0 refs/tags/v4 refs/tags/v4.10.0 v4.1.1-rc1 v6.1.0 main; do
    env -u CORE_JSON CORE_REMOTE='https://example.invalid/fork.git' CORE_BRANCH="$_rc_pin" bash "$HERE/scripts/new-os-repo.sh" --dry-run --no-vendor Fixture "$SANDBOX/recovery/new-pin" >/dev/null 2>&1 || _rc_floor_bad="$_rc_floor_bad $_rc_pin(refused:$?)"
  done
  if [[ -z "$_rc_floor_bad" ]]; then
    pass "recovery: a pin older than v4.1.0 (no repos: footer to judge, prereleases included) is refused before anything is written; the floor, a v4+ alias, a newer freeze and a branch pass"
  else
    fail "recovery: the footer floor is wrong for —$_rc_floor_bad"
  fi
  unset _rc_floor_bad _rc_pin _rc_fo _rc_frc
  # The canonical path ALREADY resolving to the scaffold — a pre-made link here, standing
  # in for a basename that differs only by case on a case-insensitive filesystem — gets
  # NO guarded link in the chain: the guard would read the canonical spelling as a foreign
  # real directory and refuse the reader's own repo.
  mkdir -p "$SANDBOX/recovery/pre" && ln -s "$SANDBOX/recovery/pre/Custom" "$SANDBOX/recovery/pre/dotfiles-Fixture"
  _rc_pre_out="$(env -u CORE_JSON CORE_REMOTE='https://example.invalid/fork.git' bash "$HERE/scripts/new-os-repo.sh" --no-vendor Fixture "$SANDBOX/recovery/pre/Custom" 2>&1)"
  _rc_pre_cmd=""; [[ "$_rc_pre_out" == *"run later: "* ]] && { _rc_pre_cmd="${_rc_pre_out#*run later: }"; _rc_pre_cmd="${_rc_pre_cmd%%$'\n'*}"; }
  if [[ -n "$_rc_pre_cmd" && "$_rc_pre_cmd" != *"ln -sfn "* && "$_rc_pre_cmd" == "git -C "* ]]; then
    pass "recovery: a canonical path that already resolves to the scaffold (case-insensitive FS, or a prior link) gets no guarded link in the chain"
  else
    fail "recovery: the chain still prepends the guarded link when the canonical path already IS the scaffold — $(cut -c1-200 <<<"$_rc_pre_cmd")"
  fi
  unset _rc_pre_out _rc_pre_cmd
  # A Core checkout with NO origin and no CORE_REMOTE must not bake an empty remote into
  # the command: it renders `"${CORE_REMOTE:?…}"`, which fails loudly at paste time until
  # the reader exports the URL. Reproduced on a copy of the scaffold in an origin-less repo.
  _rc_nocore="$SANDBOX/recovery/nocore"
  mkdir -p "$_rc_nocore/scripts/lib" "$_rc_nocore/lib"
  cp "$HERE/scripts/new-os-repo.sh" "$_rc_nocore/scripts/"
  cp "$HERE/scripts/lib/common.sh" "$HERE/scripts/lib/core-lock.sh" "$HERE/scripts/lib/core-vendor.sh" "$_rc_nocore/scripts/lib/"
  cp "$HERE/lib/ux.sh" "$_rc_nocore/lib/"
  cp "$HERE/core.version" "$_rc_nocore/"
  git -C "$_rc_nocore" init -q >/dev/null 2>&1
  _rc_noout="$(env -u CORE_JSON -u CORE_REMOTE bash "$_rc_nocore/scripts/new-os-repo.sh" --no-vendor Fixture "$SANDBOX/recovery/no-origin-target" 2>&1)"
  _rc_nocmd=""
  if [[ "$_rc_noout" == *"run later: "* ]]; then _rc_nocmd="${_rc_noout#*run later: }"; _rc_nocmd="${_rc_nocmd%%$'\n'*}"; fi
  if [[ -n "$_rc_nocmd" ]] && grep -qF '"${CORE_REMOTE:?' <<<"$_rc_nocmd" && ! grep -qE "subtree add --prefix=core '' |git fetch '' |CORE_REMOTE='' " <<<"$_rc_nocmd" && bash -n <(printf '%s\n' "$_rc_nocmd"); then
    pass "recovery: with no origin and no CORE_REMOTE the command carries a \${CORE_REMOTE:?…} expansion, never an empty remote"
  else
    fail "recovery: an origin-less Core baked an empty remote into the hint — cmd: [$(cut -c1-200 <<<"$_rc_nocmd")]; the run said: $(tail -3 <<<"$_rc_noout" | tr '\n' '|' | cut -c1-400)"
  fi
  unset _rc_nocore _rc_noout _rc_nocmd
  rm -rf "$SANDBOX/recovery"
  unset _rc_parent _rc_recov _rc_target _rc_out _rc_cmd _rc_bad _rc_guard _rc_canon _rc_prev _rc_order _rc_m _rc_pos _rc_sub _rc_st _rc_leftover _rc_leftover_fail _rc_dr _rc_addfail _rc_left_add _rc_ok _rc_ko _rc_sk
else
  skip "new-os-repo.sh recovery command (git unavailable)"
fi
