# scripts/audit/35-shell-hazards.sh
# three text scans the linters cannot make: SIGPIPE under pipefail, a leaked RETURN trap, a bash-4 construct
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

# ── 5d. pipefail SIGPIPE hazard (regression gate) ────────────────────────────
# Under `set -o pipefail`, piping into a reader that EXITS EARLY turns a success into a
# failure. `grep -q` stops on its first match, `awk` on its `exit`, `head` after N lines;
# the writer then takes EPIPE and dies with 141, and pipefail reports the PIPELINE as
# failed even though the reader matched.
#
# This repo has hit it three times. Twice it was found and fixed by hand — the CHANGELOG
# records a 4000-line `git show` into `grep -q` reporting "no heading" on a file that had
# one, and test-core.sh has an assertion literally named "the pipefail trap this repo has
# hit before" for `ldd --version | grep -qi musl`. The third broke `main`:
# nvim-reachability.sh invented two orphans because a visited module's membership lookup
# returned 141 (#458). The fix each time was a hand sweep of the tree — correct for its
# moment, and unable to cover code written afterwards. Hence a gate (#459).
#
# SCOPE IS DELIBERATELY NARROW: a SHELL-STRING producer (`printf`/`echo`) into an
# early-exiting reader. `sed <file> | head -n1` — a FILE producer, ~15 instances — is left
# alone on purpose: converting those is not free, and a gate that fires fifteen times on
# working code is a gate someone turns off.
#
# THE REMEDY IS "REMOVE THE PIPE", NOT "ALWAYS USE A HERESTRING". A herestring appends a
# newline, so `printf '%s' "\$v" | head -c 3` and `head -c 3 <<<"\$v"` differ by a byte —
# for a byte-counting reader the naive rewrite corrupts the value. Capturing to a variable
# preserves the producer's exact bytes; a herestring is the right fix wherever a trailing
# newline is immaterial, which is most places but not all.
#
# The scanner is textual (see _core_pipefail_hits) and so a heuristic backstop, not a
# proof: a pipeline split across lines, or a reader reached via a variable, is not seen.
hdr "pipefail SIGPIPE hazard"
if ! ((SCOPE_SHELL)); then
  skip "pipefail SIGPIPE (out of scope)"
else
  pf_fail=0
  while IFS= read -r pf_f; do
    [ -n "$pf_f" ] || continue
    while IFS= read -r pf_line; do
      [ -n "$pf_line" ] || continue
      fail "pipefail: $pf_f:$pf_line — shell-string producer feeds a reader that exits early; remove the pipe (capture to a variable, or a herestring where a trailing newline is immaterial)"
      pf_fail=1
    done <<EOF
$(_core_pipefail_hits "$pf_f")
EOF
  done <<EOF
$(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
EOF
  ((pf_fail)) || pass "pipefail (no shell-string producer feeds an early-exiting reader)"
fi

# ── 5e. leaked RETURN trap (fleet regression gate) ───────────────────────────
# A bash RETURN trap is a GLOBAL slot, not a function-scoped one. Armed inside a function it
# survives into the CALLER's frame and fires a SECOND time on that frame's return, where the
# local it cleans up is out of scope and `set -u` makes it fatal. dotgibson/dotfiles-Debian#2:
# every fresh-box bootstrap died the instant provision() returned, AFTER installing everything
# but BEFORE wire_links — a box carrying the whole stack and not one symlink.
#
# WHY IT NEEDS ITS OWN SECTION rather than a shellcheck rule: shellcheck cannot see it. The
# broken line is valid bash, and `bash -n` passes it too. §5's shellcheck leg and §3's syntax
# leg both run over the offending file and both go green. Only a textual scan catches it.
#
# WHY IT IS A CORE CONCERN even though the two known instances were in OS repos: this is the
# tree that fans out to nine of them, and `lib/bootstrap-lib.sh` is exactly the kind of code
# that arms cleanup traps. .github/workflows/lint-call.yml carries the same rule for the
# CALLER repos, but it checks the caller out into `caller/` and never looks at Core's own
# 38 shell scripts. This section is that half. The two must stay in step —
# scripts/lib/common.sh :: _core_return_trap_hits is the canonical expression of the rule.
#
# Scope matches §5d: repo-owned bash, including the extensionless bin/clip helpers. zsh is
# excluded on purpose — it has no RETURN signal, so the bug cannot exist there.
hdr "leaked RETURN trap"
if ! ((SCOPE_SHELL)); then
  skip "RETURN trap (out of scope)"
else
  rt_fail=0
  while IFS= read -r rt_f; do
    [ -n "$rt_f" ] || continue
    while IFS= read -r rt_line; do
      [ -n "$rt_line" ] || continue
      fail "RETURN trap: $rt_f:$rt_line — armed without disarming the slot; it will fire again in the CALLER's frame. Make the body disarm FIRST: trap 'trap - RETURN; …' RETURN"
      rt_fail=1
    done <<EOF
$(_core_return_trap_hits "$rt_f")
EOF
  done <<EOF
$(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
EOF
  ((rt_fail)) || pass "RETURN traps (every one disarms the slot before the caller's frame sees it)"
fi

# ── 5k. the bash 3.2 floor (PORTABILITY.md §1) ───────────────────────────────
# PORTABILITY.md §1 puts the shell floor at bash 3.2, because macOS ships 2007's bash and
# this matrix runs a macos-latest leg. NINE scripts here carry a comment saying so. Nine
# comments and, until #874, zero checks — a convention enforced only by a CI leg that takes
# seventeen minutes to answer, on one platform of four, after the fact.
#
# #871 is the case. It added one array-reading-builtin call to test/73-maint-runner.sh and
# every gate that could have caught it locally did not: the line is valid syntax so §3's
# `bash -n` passes, shellcheck does not model bash versions so §5 passes, and §10's suite
# passes on bash 5. ubuntu, alpine and arch passed too. macOS alone failed, seventeen minutes
# in, and it took the whole behavioral section down with it — `pass 388 skip 17 fail 1`.
#
# THIS SECTION IS FOUR SECONDS AND RUNS EVERYWHERE, which is the entire argument for it: the
# same defect now reds on the author's machine, on the first leg, on every platform.
#
# It is also GREEN ON ARRIVAL — 92 tracked shell files, zero findings — which is the property
# #748's ledger insists on: a gate red the day it lands is a gate someone turns off.
#
# scripts/lib/common.sh :: _core_bash4_hits is the canonical expression of the rule, and
# carries the two deliberate gaps (the empty-array `set -u` rule, and `typeset -A`, which is
# the zsh spelling that the embedded-zsh test fragments legitimately use). Scope matches §5d
# and §5e: repo-owned bash, including the extensionless bin/clip helpers. The zsh modules are
# excluded because the floor is a BASH floor — zsh has all five constructs.
#
# _core_bash32_parse_hits runs beside it over the same files, for the OTHER half of the
# floor: syntax 3.2's parser refuses outright, where `bash -n` rejects the file and nothing
# in it runs. #1075 is that case — a `case` opening a command substitution with bare
# patterns, which parses on bash 5 and, inside double quotes, on 3.2 too, right up until an
# arm contains an apostrophe. It reached CI the same way #871 did and was reported as
# nothing more than `✗ bash syntax error: <file>` by §3, on one leg, eleven minutes in.
hdr "bash 3.2 floor (PORTABILITY.md §1)"
if ! ((SCOPE_SHELL)); then
  skip "bash 3.2 floor (out of scope)"
else
  b4_fail=0
  while IFS= read -r b4_f; do
    [ -n "$b4_f" ] || continue
    while IFS= read -r b4_hit; do
      [ -n "$b4_hit" ] || continue
      fail "bash 3.2 floor: $b4_f:${b4_hit%%:*} — ${b4_hit#*:}; macOS ships bash 3.2 and the audit matrix runs it (PORTABILITY.md §1)"
      b4_fail=1
    done <<EOF
$(_core_bash4_hits "$b4_f"; _core_bash32_parse_hits "$b4_f")
EOF
  done <<EOF
$(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
EOF
  ((b4_fail)) || pass "bash 3.2 floor (no bash 4+ construct, and nothing 3.2 cannot parse)"
fi
