# scripts/audit/60-secrets-make.sh
# gitleaks over the working tree, the CI modernization floor, and the Makefile gates
#
# A SOURCED FRAGMENT of scripts/audit-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: the PASS/SKIP/FAIL counters, $HERE (already cd'd
# to), the SCOPE_* flags, META_ALLOWLIST/META_PREFIXES, MANIFEST_PATHS/VENDOR_PATHS (parsed
# by 10-manifest.sh, §1), and the pass/skip/skip_env/fail/fail_detail/hdr/have helpers from
# scripts/lib/common.sh. NO EXIT TRAP HERE: the dispatcher installs the one that reaps the
# backgrounded behavioral suite, and `trap … EXIT` REPLACES rather than appends. The §-ids
# below are the STABLE gate ids — CLAUDE.md, CONTRIBUTING.md, VENDORING.md, PORTABILITY.md
# and the CHANGELOG all cite them — and the split did not renumber one; the NN- in this
# file's name carries run order only. See the header of scripts/audit-core.sh for the
# contract.

# ── 8b. secrets (gitleaks) ────────────────────────────────────────────────────
# Core ships 1Password helpers (zsh/50-op.zsh), a git-identity template, and history
# secret-ignore patterns — and fans out to 9 PUBLIC repos, where a committed token
# amplifies N-way. None of the gates above look for secrets: shellcheck/zsh -n read
# syntax, the toml/yaml/json checks read structure, markdownlint reads prose. So
# scan the working tree for credentials. `gitleaks dir` is the filesystem scan (every
# tracked + untracked file at HEAD), the CI mirror of the gitleaks pre-commit hook
# (which guards the commit diff at author time). Always-on + graceful skip, exactly
# like the linters above; CI installs it pinned (GITLEAKS_VERSION) so it runs there.
hdr "secrets (gitleaks)"
if have gitleaks; then
  # -v is what makes the captured output worth anything: without it gitleaks prints only
  # "leaks found: N" and the file/line/rule stay hidden — the same non-answer this change
  # exists to remove. --no-color matches the flag already passed to luacheck, so the text
  # captured into a log is plain rather than escape sequences.
  # -c gitleaks.toml: the ONE fleet policy (see that file's header). Without it this
  # gate and lint-call.yml's `secrets` job would run different rule sets against the same
  # class of tree — and a finding that is real here and allowlisted there (or the reverse)
  # is worse than either gate alone, because it makes the disagreement look like a bug in
  # the code rather than in the config.
  if gl_out="$(gitleaks dir . -c gitleaks.toml --no-banner --redact -v --no-color 2>&1)"; then
    pass "gitleaks (no secrets in the working tree)"
  else
    fail "gitleaks found potential secrets — run: gitleaks dir . -c gitleaks.toml --redact -v"
    # Safe to print BECAUSE of --redact: gitleaks replaces the matched value with
    # REDACTED, so the report names the file, line, rule and fingerprint without
    # reproducing the secret. Drop --redact and this becomes the one gate whose output
    # must stay dark.
    fail_detail "$gl_out"
  fi
else
  skip "gitleaks (not installed — https://github.com/gitleaks/gitleaks/releases)"
fi

# ── 8c. modernization floor (check-modern.sh) ────────────────────────────────
# actionlint (8) proves a workflow is VALID; it says nothing about whether it's MODERN.
# scripts/modern-baseline.yml declares the floor (no ::set-output, no EOL runners, every
# external action SHA-pinned, every container image @sha256-pinned) and check-modern.sh
# enforces it — so a workflow can't silently regress below it (this closes G8: mutable
# container tags were the one break in the fleet's otherwise-strict pinning). Pure
# bash+awk, always run (our own script, no `have` gate).
hdr "modernization floor (check-modern.sh)"
if _cm_out="$("$HERE/scripts/check-modern.sh" 2>&1)"; then
  pass "check-modern (CI meets scripts/modern-baseline.yml)"
else
  printf '%s\n' "$_cm_out" >&2
  fail "check-modern found violations (above) — run: ./scripts/check-modern.sh"
fi

# ── 8d. Makefile gates that cannot do what their name says ────────────────────
# ShellCheck reads this file's SYNTAX and `make -n` would read what it EXPANDS to; neither
# answers the question this asks, which is whether a target's own claim survives the shell
# make gives it. A guard that prints "skipping" and then runs the missing tool is valid
# bash, expands fine, and exits 127 — the same shape as §8a's `ref: vN`, where the ref
# resolves, the job goes green, and the wrong code runs.
#
# THIS IS CORE'S HALF ONLY. The defect was found in the eight OS repos
# (dotgibson/dotfiles-core#775, eleven instances); those are judged by lint-call.yml's
# `make-gates` leg, which runs this same function against the CALLER. This section keeps
# the authoring repo honest, because Core has a Makefile with the same target shapes and
# nothing would otherwise stop the pattern being reintroduced here and vendored outward.
#
# Always-on: no tool to be absent, so it can never skip — the exact failure mode it exists
# to close, and the same reasoning §8a records.
hdr "Makefile gates (skip guards, discarded statuses, missing mirrors)"
mkg_out="$(_core_make_gate_hits .)"
if [[ -z "$mkg_out" ]]; then
  pass "every Makefile gate skips, fails and scopes as its help text claims"
else
  fail "a Makefile gate does not do what its name says — see dotgibson/dotfiles-core#775"
  fail_detail "$mkg_out"
fi
unset mkg_out
