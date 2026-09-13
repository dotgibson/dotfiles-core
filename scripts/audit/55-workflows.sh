# scripts/audit/55-workflows.sh
# actionlint over .github/workflows, and the three reusable-workflow major registers (ref:, caller examples, first-vendor pins)
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

# ── 8. workflows (actionlint) ─────────────────────────────────────────────────
# .github/workflows/*.yml is a fan-out artifact with no gate of its own: the YAML
# parse in section 6 proves it's well-formed text, not that the workflow is VALID —
# a bad `needs:`, an undefined job output, or a shellcheck error inside a run: block
# all parse as YAML and still break CI for every push. actionlint catches those (and
# runs shellcheck on the run: scripts). Graceful skip when absent, like every linter
# above; CI installs it pinned (ACTIONLINT_VERSION) so the gate actually runs there.
hdr "workflows (actionlint)"
if have actionlint; then
  if al_out="$(actionlint 2>&1)"; then
    pass "actionlint (workflows valid)"
  else
    fail "actionlint reported issues — run: actionlint"
    fail_detail "$al_out"
  fi
else
  skip "actionlint (not installed — go install github.com/rhysd/actionlint/cmd/actionlint@latest)"
fi

# ── 8a. reusable-workflow ref majors ─────────────────────────────────────────
# actionlint above proves the workflows are VALID. It cannot know that a valid
# `ref: v4` is the wrong major — that is a fleet-policy question, and it is the one
# this repo has now got wrong twice (v3→v4, ten minors; v4→v5, until #744). See
# _core_workflow_ref_hits for the full history and the release ordering this implies.
#
# Always-on: no tool to be absent, so this never skips and cannot go green-because-absent
# — which is the exact failure mode it exists to close.
hdr "reusable-workflow ref majors"
if [[ -r core.version ]]; then
  wfr_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ "$wfr_major" =~ ^[0-9]+$ ]]; then
    wfr_out="$(_core_workflow_ref_hits . "$wfr_major")"
    if [[ -z "$wfr_out" ]]; then
      pass "every dotfiles-core checkout in .github/workflows/ pins ref: v$wfr_major (matches core.version)"
    else
      fail "a reusable workflow checks dotfiles-core out at a foreign major — the job would run another major's scripts"
      fail_detail "$wfr_out"
    fi
    unset wfr_out
  else
    fail "core.version major unreadable ('$wfr_major') — cannot check workflow ref majors"
  fi
  unset wfr_major
else
  fail "core.version missing — cannot check workflow ref majors"
fi

# ── 8a-bis. reusable-workflow caller-example majors ───────────────────────────
# 8a proves the `ref:` KEYS point at the right major. It does not read comments, so at
# v5 → v6 every ref moved and 25 `@v5` references survived in the prose describing them
# (#821) — including the copyable `uses:` examples six *-call.yml headers hand to OS-repo
# maintainers. Nothing failed, because nothing was wrong in the code; a maintainer who
# copied one simply pinned a retired major. Same silent shape 8a exists to end, one level
# up, so it gets the same treatment: made executable rather than commented about.
#
# Scoped to a full `dotfiles-core/.github/workflows/<file>@vN` path, which is always a
# copyable reference and never narrative — see _core_workflow_example_hits for why a
# blanket `@vN` scan would be worse than no gate.
#
# Always-on, for 8a's reason: no tool to be absent, so it cannot go green-because-absent.
hdr "reusable-workflow caller-example majors"
if [[ -r core.version ]]; then
  wfe_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ "$wfe_major" =~ ^[0-9]+$ ]]; then
    wfe_out="$(_core_workflow_example_hits . "$wfe_major")"
    if [[ -z "$wfe_out" ]]; then
      pass "every documented caller example in .github/workflows/ names @v$wfe_major (matches core.version)"
    else
      fail "a documented caller example pins a foreign major — copying it would put an OS repo on a retired Core"
      fail_detail "$wfe_out"
    fi
    unset wfe_out
  else
    fail "core.version major unreadable ('$wfe_major') — cannot check caller-example majors"
  fi
  unset wfe_major
else
  fail "core.version missing — cannot check caller-example majors"
fi

# ── 8a-ter. first-vendor pin majors ──────────────────────────────────────────
# 8a holds the `ref:` keys to the current major and 8a-bis the copyable caller examples.
# The third copyable instruction that names a major is the FIRST-VENDOR recipe — the
# `refs/tags/vN` a new OS repo subtree-adds, the `git checkout vN` / `vN^{commit}` that
# stamps its lock, and new-os-repo.sh's default for the same — and it has rotted at every
# major cut so far (v4 → v5 by hand in three entries; v5 → v6 unnoticed for two releases,
# so a freshly scaffolded repo vendored a retired Core by default). Same silent shape,
# same treatment: read the major from core.version, hold the text to it. The rule and its
# exemptions (history, fixtures, exact pins) live on _core_vendor_pin_hits.
#
# Always-on, for 8a's reason: no tool to be absent, so it cannot go green-because-absent.
hdr "first-vendor pin majors"
if [[ -r core.version ]]; then
  vpn_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ "$vpn_major" =~ ^[0-9]+$ ]]; then
    vpn_out="$(_core_vendor_pin_hits . "$vpn_major")"
    if [[ -z "$vpn_out" ]]; then
      pass "every first-vendor pin (docs + scripts/, incl. new-os-repo.sh's default) names v$vpn_major (matches core.version)"
    else
      fail "a first-vendor pin names a foreign major — a new repo scaffolded from it vendors a retired Core"
      fail_detail "$vpn_out"
    fi
    unset vpn_out
  else
    fail "core.version major unreadable ('$vpn_major') — cannot check first-vendor pin majors"
  fi
  unset vpn_major
else
  fail "core.version missing — cannot check first-vendor pin majors"
fi
