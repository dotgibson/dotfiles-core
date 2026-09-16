# scripts/audit/15-exec-syntax.sh
# exec bits in the git index, and every shell file parses (bash -n / zsh -n)
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

# ── 2. executable-bit assertions ─────────────────────────────────────────────
hdr "executable bits"
if have git && git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r line; do
    mode="${line%% *}"
    path="${line#* }"
    case "$path" in
    scripts/lib/*.sh | scripts/research/lib/*.sh | scripts/test/*.sh | scripts/audit/*.sh | lib/*.sh)
      # Sourced bash libraries — the bash sibling of zsh/*.zsh: no shebang, NOT
      # executable. scripts/lib/ is dev-tooling, scripts/research/lib/ is the archived
      # research apparatus's own lib (#687); scripts/test/ is the behavioral suite's
      # numbered fragments, which scripts/test-core.sh sources into its own shell and
      # which do nothing useful when run on their own (#699); lib/ (core/lib/ux.sh) is
      # the VENDORED bash UX lib bootstrap.sh sources. Must precede the generic *.sh arm
      # (first match).
      if [[ "$mode" == 100644 ]]; then
        pass "src  $path"
      else fail "sourced lib must NOT be executable, is $mode: $path"; fi
      ;;
    *.sh | bin/clip | bin/clip-paste)
      if [[ "$mode" == 100755 ]]; then
        pass "+x   $path"
      else fail "must be executable (100755), is $mode: $path"; fi
      ;;
    zsh/*.zsh)
      if [[ "$mode" == 100644 ]]; then
        pass "src  $path"
      else fail "sourced module must NOT be executable, is $mode: $path"; fi
      ;;
    esac
  done < <(git ls-files -s | awk '{print $1, $4}')
else
  skip "exec-bit check (not a git checkout)"
fi

# ── 3. shell syntax ──────────────────────────────────────────────────────────
# The parser's MESSAGE is kept, not discarded. This used to be `2>/dev/null` with a bare
# "bash syntax error: <file>", which is the whole finding a reader got — and when the only
# leg that disagrees is macOS's bash 3.2, "which line, and why" is the entire question.
# #1075 spent a CI round trip bisecting a file by hand for want of the line number that was
# sitting in the stderr this check was throwing away. §5k now catches that particular
# construct locally, but it covers one shape and names its gaps; this covers the rest.
hdr "shell syntax (bash -n / zsh -n)"
while IFS= read -r f; do
  if syn_out="$(bash -n "$f" 2>&1)"; then
    pass "bash -n $f"
  else
    fail "bash syntax error: $f"
    [ -n "$syn_out" ] && fail_detail "$syn_out"
  fi
done < <(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
if ((SCOPE_SHELL)); then
  if have zsh; then
    # The sourced modules AND the autoloaded completion functions (zsh/completions/_*,
    # no .zsh extension) — both are zsh that fans out to ten repos; both must parse.
    while IFS= read -r f; do
      if syn_out="$(zsh -n "$f" 2>&1)"; then
        pass "zsh -n  $f"
      else
        fail "zsh syntax error: $f"
        [ -n "$syn_out" ] && fail_detail "$syn_out"
      fi
    done < <(_audit_ls 'zsh/*.zsh' 'zsh/completions/*')
  else
    skip "zsh -n (zsh not installed)"
  fi
else
  skip "zsh -n (out of scope)"
fi
