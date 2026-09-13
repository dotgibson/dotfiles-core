# scripts/audit/25-lint.sh
# the shellcheck sweep over every bash script, and the fzf preview binary resolves
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

# ── 5. lint (shellcheck) ─────────────────────────────────────────────────────
hdr "lint (shellcheck)"
if ! ((SCOPE_SHELL)); then
  skip "shellcheck (out of scope)"
elif have shellcheck; then
  sc_fail=0
  while IFS= read -r f; do
    if ! sc_out="$(shellcheck -x "$f" 2>&1)"; then
      sc_fail=1
      fail "shellcheck: $f"
      fail_detail "$sc_out"
    fi
  done < <(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
  ((sc_fail)) || pass "shellcheck (all bash scripts clean)"
else
  skip "shellcheck (not installed)"
fi

# ── 5b. fzf preview binary resolution (regression gate) ──────────────────────
# fzf / fzf-tab previews run their command STRING in a subshell, so a LITERAL `bat`
# there printed "command not found" in every preview pane on Debian/Ubuntu — those
# distros ship bat as `batcat` — a silent breakage that fanned out to those OS repos
# with no failing gate. The fix routes previews through $BAT_BIN (00-tools.zsh resolves
# the real name) with a cat/ls fallback. Lock it so the bug can't recur: no uncommented
# preview line in zsh/35-fzf.zsh or zsh/45-plugins.zsh may invoke a literal bat/batcat, and
# 35-fzf.zsh must still reference $BAT_BIN. Pure sed+grep (busybox-safe), shell-scoped.
hdr "fzf preview binary resolution"
if ((SCOPE_SHELL)); then
  pv_fail=0
  for f in zsh/35-fzf.zsh zsh/45-plugins.zsh; do
    # Strip comments (from the first #), then flag a bare lowercase bat/batcat command
    # token — $BAT_BIN (uppercase) is intentionally NOT matched, which is the point.
    if sed 's/#.*//' "$f" | grep -qE '(^|[^A-Za-z_$])bat(cat)?[[:space:]]'; then
      pv_fail=1
      fail "literal bat/batcat in a preview command ($f) — route it through \$BAT_BIN"
    fi
  done
  grep -q 'BAT_BIN' zsh/35-fzf.zsh || {
    pv_fail=1
    fail "zsh/35-fzf.zsh no longer references \$BAT_BIN (preview resolution lost)"
  }
  # fzf-tab appends $realpath itself and does NOT substitute fzf's `{}` placeholder. So a
  # fzf-tab preview must use the placeholder-free $_FZF_TAB_PREVIEW_CMD — NOT $_FZF_PREVIEW_CMD
  # (which ends in `{}`, the bug: that trailing `{}` reaches the previewer as a phantom arg),
  # and not an inline literal `{}` either. Flag any fzf-preview line that pairs $realpath with
  # the wrong var or a stray `{}`. ($_FZF_TAB_PREVIEW_CMD is not a substring of the check, so
  # the correct line passes.)
  while IFS= read -r _pvln; do
    [[ "$_pvln" == *fzf-preview* && "$_pvln" == *"\$realpath"* ]] || continue
    if [[ "$_pvln" == *'{}'* || "$_pvln" == *"\$_FZF_PREVIEW_CMD"* ]]; then
      pv_fail=1
      fail "fzf-tab preview must use \$_FZF_TAB_PREVIEW_CMD (no {} / no \$_FZF_PREVIEW_CMD): $_pvln"
    fi
  done < <(sed 's/#.*//' zsh/45-plugins.zsh)
  ((pv_fail)) || pass "fzf/fzf-tab previews resolve \$BAT_BIN (no literal bat/batcat, no stray {})"
else
  skip "fzf preview resolution (out of scope)"
fi
