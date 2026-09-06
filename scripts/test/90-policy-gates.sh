# scripts/test/90-policy-gates.sh
# gitleaks policy matcher, Makefile gate guard, parity coverage gate
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── _core_gitleaks_policy_hits: the secret-scan policy matcher (#623) ────────
# The gate audit-core.sh §5g rests on. Fixture-driven in BOTH directions before it is
# trusted on the real fleet, for the reason the diffutils gate above states outright: a gate
# whose exemption is untested is how the last one shipped broken.
#
# THE TRAP THIS PINS, and it cost real time while surveying for the issue: a naive
# `-c|--config` match also fires on the `-c` inside `--exit-code`, which two of the repos in
# scope actually pass. An invocation carrying `--exit-code` and NO config must still be a
# finding — that is case 2 below, and it is the whole reason the flag is matched as a word.
#
# The offending strings are ASSEMBLED with printf rather than spelled out, the same technique
# _core_owned_block_hits uses for its own self-reference problem: this repo scans itself, and
# a literal config-less invocation written here would be a finding in Core's own tree.
hdr "_core_gitleaks_policy_hits (secret-scan policy)"
_gph="$(mktemp -d "$SANDBOX/gpolicy.XXXXXX")"
_gp_w() { printf '%s\n' "$2" >"$_gph/$1"; } # _gp_w <file> <line>
_gp_is() {                                  # _gp_is <label> <file> <expected>
  local got
  got="$(_core_gitleaks_policy_hits "$_gph/$2")"
  if [[ "$got" == "$3" ]]; then
    pass "gitleaks policy: $1"
  else
    fail "gitleaks policy: $1 (want '$3', got '$got')"
  fi
}

_gp_scan="$(printf 'gitleaks %s' dir)"       # assembled: this file is scanned too
_gp_det="$(printf 'gitleaks %s' detect)"
_gp_hist="$(printf 'gitleaks %s' git)"

# FINDINGS — a scan running under whatever rule set gitleaks happens to pick up.
_gp_w a.mk "$_gp_scan . --no-banner --redact"
_gp_is "a config-less 'dir' scan is a finding" a.mk "1:no-config"
_gp_w b.mk "$_gp_hist --redact"
_gp_is "a config-less history scan is a finding" b.mk "1:no-config"
# THE --exit-code TRAP: contains the substring '-c', carries no policy, must still fire.
_gp_w c.mk "$_gp_det --no-git --redact --verbose --exit-code 1"
_gp_is "--exit-code does NOT read as -c (the false-positive trap this rule is built around)" c.mk "1:no-config"

# NOT FINDINGS — a policy is passed, in any of the spellings the fleet actually uses.
_gp_w d.mk "$_gp_scan . -c core/gitleaks.toml --no-banner --redact"
_gp_is "-c with Core's policy is clean" d.mk ""
_gp_w e.mk "$_gp_det --config core/gitleaks.toml --redact --exit-code 1"
_gp_is "--config alongside --exit-code is clean (both directions of the trap)" e.mk ""
_gp_w f.mk "$_gp_scan . --config=.gitleaks.toml --redact"
_gp_is "the --config=VALUE spelling is clean" f.mk ""
_gp_w g.mk "$_gp_scan . -c \"\$GITLEAKS_CONFIG\" --no-banner --redact -v"
_gp_is "a config passed through a variable is clean" g.mk ""

# NOT INVOCATIONS AT ALL — the discipline that keeps the gate switched on.
_gp_w h.mk "# $_gp_scan . --no-banner   (a comment describing the call)"
_gp_is "a commented-out invocation is not a finding" h.mk ""
_gp_w i.mk 'command -v gitleaks >/dev/null 2>&1 || { echo "gitleaks not installed"; exit 0; }'
_gp_is "a presence check that merely names gitleaks is not a finding" i.mk ""
_gp_w j.mk 'gitleaks version'
_gp_is "a non-scanning subcommand is not a finding" j.mk ""

# Core's OWN consumers must be clean, or §5g would be asking the fleet for something Core
# does not do itself — the same inverse property the owned-block scan asserts.
_gp_core_ok=1
for _gpf in "$HERE/audit-core.sh" "$HERE/scripts/audit-core.sh" "$HERE/Makefile"; do
  [[ -f "$_gpf" ]] || continue
  [[ -z "$(_core_gitleaks_policy_hits "$_gpf")" ]] || _gp_core_ok=0
done
if (( _gp_core_ok )); then
  pass "gitleaks policy: Core's own gitleaks calls all pass a config (Core meets the rule it sets)"
else
  fail "gitleaks policy: Core itself runs gitleaks with no config — the rule §5g applies to the fleet"
fi
unset _gp_scan _gp_det _gp_hist _gp_core_ok _gpf _gph
unset -f _gp_w _gp_is

# ── Makefile gate guard (common.sh :: _core_make_gate_hits) ──────────────────
# WHY THESE FIXTURES ARE THE REAL RECIPES, not synthetic ones. This guard exists because
# eleven real defects shipped across eight repos and stayed green (#775). A guard for a
# historical defect that is never RUN against that defect is the same category error it
# exists to fix — the note on _core_workflow_ref_hits records the same reasoning — so the
# fixtures below are the exact pre-fix and post-fix recipes, copied verbatim.
#
# It drives _core_make_gate_hits DIRECTLY, never a reimplementation of its loop.
#
# THE NEGATIVE CASES CARRY THE WEIGHT. A first draft of this guard used the blunter rule
# "any `exit 0` before the last recipe line" and reported dotfiles-Alpine's `shell` target,
# which guards shellcheck and then runs shellcheck ON THE SAME LINE — a correct skip. It
# also flagged `lint-zsh` and `zsh-syntax`, which handle failure with `|| exit 1` inside
# the loop. A gate that cries wolf on working code teaches the fleet to ignore it, so
# every one of those shapes is pinned below as MUST-NOT-FIRE.
hdr "Makefile gate guard (_core_make_gate_hits)"
_mg_="$SANDBOX/makegate"
mkdir -p "$_mg_"
# Each case stands alone: a stale Makefile or config leaking into the next case is exactly
# how the first draft of the ref-major tests produced three findings that were not defects.
_mg_write() { rm -f "$_mg_/Makefile" "$_mg_/.markdownlint.jsonc"; printf '%s\n' "$1" >"$_mg_/Makefile"; }
_mg_count() {
  local got n=0
  got="$(_core_make_gate_hits "$_mg_")"
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
  if [[ "$n" == "$2" ]]; then pass "make-gate: $1"; else fail "make-gate: $1 (got $n finding(s), want $2)"; fi
}

# ── R1, verbatim from dotfiles-Debian before #38. The guard and the tool are on separate
# recipe lines, so the exit 0 skips nothing.
_mg_write "markdown:
	@command -v markdownlint-cli2 >/dev/null 2>&1 \\
		|| { echo \"markdownlint-cli2 not installed: npm i -g markdownlint-cli2 — skipping\"; exit 0; }
	@markdownlint-cli2 '*.md' '!core/**'
"
# THREE findings, not two: R5 (#873) reads the same recipe and adds the unpinned linter to
# the skip and the narrow glob. All three were genuinely wrong with it at once, which is the
# point — each rule was added after a separate sweep found the shape it names.
_mg_count "the real Debian pre-fix recipe reports the skip, the narrow glob AND the unpinned linter" 3

# The same target after #38 — one recipe line, git ls-files. R1 and R4 clear... and R5 does
# NOT, because this recipe still calls a global `markdownlint-cli2`. That is not a
# regression in the fixture; it is the history. #38 fixed the skip and the scope, the target
# read clean to every rule that existed, and #873 found eighteen months later that on a box
# without `npm i -g markdownlint-cli2` — the default — it had never linted anything at all.
# Pinning R1-R4 as clean and R5 as a finding on the SAME recipe is what records that.
_mg_write "markdown:
	@if ! command -v markdownlint-cli2 >/dev/null 2>&1; then \\
	  echo \"markdownlint-cli2 not installed: npm i -g markdownlint-cli2 — skipping\"; \\
	elif test -z \"\$(MD_FILES)\"; then echo \"no repo-owned .md\"; \\
	else echo \"markdownlint-cli2 \$(MD_FILES)\"; markdownlint-cli2 \$(MD_FILES); fi
"
_mg_count "the post-#38 recipe clears the skip and the scope but is still UNPINNED" 1

# ── R5 clean: the post-#873 recipe the whole fleet now runs, verbatim from dotfiles-Debian.
# npx plus a pinned version read from the vendored pins, and a refusal rather than a guess
# when that pin is unreadable. All five rules must clear.
_mg_write "markdown:
	@if ! command -v npx >/dev/null 2>&1; then echo \"npx not available — skipping markdown\"; \\
	elif test -z \"\$(MARKDOWNLINT_VERSION)\"; then \\
	  echo \"!! MARKDOWNLINT_VERSION unreadable from \$(CORE_PINS) — refusing to lint unpinned\"; exit 1; \\
	elif test -z \"\$(MD_FILES)\"; then echo \"no repo-owned .md\"; \\
	else echo \"markdownlint-cli2@\$(MARKDOWNLINT_VERSION) \$(MD_FILES)\"; \\
	  npx --yes markdownlint-cli2@\$(MARKDOWNLINT_VERSION) \$(MD_FILES); fi
"
_mg_count "the post-#873 recipe the fleet now runs is clean under all five rules" 0

# ── R5 MUST NOT FIRE on the comment that explains the fix. Every converged recipe carries a
# block naming the bare binary it replaced, and a rule that reds its own rationale is the
# false-positive class this whole function is written around (see the note on tool_runs).
_mg_write "markdown:
	@# npx AND A PIN, not a global markdownlint-cli2 (dotfiles-core#873). The probe used to
	@# be \`command -v markdownlint-cli2\`, and nothing in this repo installs that.
	@if ! command -v npx >/dev/null 2>&1; then echo \"npx not available — skipping markdown\"; \\
	else npx --yes markdownlint-cli2@\$(MARKDOWNLINT_VERSION) \$(MD_FILES); fi
"
_mg_count "a comment naming the bare binary it replaced is not an unpinned invocation" 0

# ── R5 MUST NOT FIRE on a QUOTED invocation. dotfiles-MacBook writes its pin that way, and
# tool_runs treats quoted text as prose fleet-wide, so this reads as not-an-invocation
# rather than as unpinned. Under-checked by design, and that repo is pinned regardless —
# recorded here so the gap is a decision on the record and not a surprise.
_mg_write "markdownlint:
	@if ! command -v npx >/dev/null 2>&1; then echo \"skip\"; exit 0; fi; \\
	 v=\"\$\$(sed -n 's/^MARKDOWNLINT_VERSION=//p' core/scripts/tool-versions.env)\"; \\
	 npx --yes \"markdownlint-cli2@\$\${v:-latest}\" \$(MD_FILES)
"
_mg_count "a quoted (MacBook-shaped) pinned invocation is not reported" 0

# ── R1 must survive the tool being named in its own skip MESSAGE. Every one of these
# guards does that ("markdownlint-cli2 not installed: npm i -g markdownlint-cli2"), and a
# first draft treated the name in the message as an invocation — which silently suppressed
# ALL FIVE real findings. Quoted text is prose, not a command.
_mg_write "zsh-syntax:
	@command -v zsh >/dev/null 2>&1 || { echo \"zsh not installed — skipping\"; exit 0; }
	@for f in \$(ZSH_FILES); do echo \"zsh -n \$\$f\"; zsh -n \"\$\$f\" || exit 1; done
"
_mg_count "the tool named inside its own skip message is not mistaken for an invocation" 1

# ── R1 MUST NOT FIRE: dotfiles-Alpine's `shell`. The guard and the guarded tool are on the
# SAME logical line, so the exit 0 skips precisely what it promises.
_mg_write "shell:
	@command -v shellcheck >/dev/null 2>&1 || { echo '- shellcheck not installed — SKIP'; exit 0; }; \\
	  echo ':: shellcheck'; shellcheck \$(SH_FILES)
	@[ -n \"\$(SH_FILES)\" ] || exit 0; \\
	  for f in \$(SH_FILES); do bash -n \"\$\$f\" || exit 1; done
"
_mg_count "a guard whose tool runs on the SAME line is not a finding" 0

# ── R1 MUST NOT FIRE on exit 1: a hard failure aborts make on that line, which is what its
# author meant. dotfiles-MacBook's brew-check escaped the original bug for exactly this
# reason, and its check-skip-guards.sh header records why.
_mg_write "brew-check:
	@command -v brew >/dev/null 2>&1 || { echo \"brew missing\"; exit 1; }
	@brew bundle check
"
_mg_count "an exit 1 guard is not a finding — it aborts the target as intended" 0

# ── R2, verbatim from dotfiles-openSUSE's lint-sh before #139.
_mg_write "lint-sh:
	@if command -v shellcheck >/dev/null 2>&1; then \\
	  echo \":: shellcheck \$(SH_FILES)\"; \\
	  shellcheck -x \$(SH_FILES); \\
	  echo \"   ok\"; \\
	else \\
	  echo \"!! shellcheck not installed — skipping\"; \\
	fi
"
_mg_count "a checker whose status is discarded by \`;\` before a success echo is a finding" 1

# R2 MUST NOT FIRE on either correct shape in the same file — `&&`, and `|| exit 1` inside
# a loop followed by a success echo. Both are real fleet code; both were false positives
# in the first draft.
_mg_write "lint-sh:
	@shellcheck -x \$(SH_FILES) && echo \"   ok\"
lint-zsh:
	@if command -v zsh >/dev/null 2>&1; then \\
	  for f in \$(ZSH_FILES); do zsh -n \"\$\$f\" || exit 1; done; \\
	  echo \"   ok\"; \\
	fi
"
_mg_count "\`&&\` and \`|| exit 1\` before a success echo are correct, not findings" 0

# ── R3: the config exists, nothing runs it. This is what Arch, Gentoo and openSUSE shipped.
_mg_write "lint:
	@echo nothing
"
printf '{}\n' >"$_mg_/.markdownlint.jsonc"
_mg_count "a .markdownlint.jsonc with no local runner is a finding" 1
rm -f "$_mg_/.markdownlint.jsonc"

# ── R3's reachability probe must not use GNU-only grep flags, and must not read a grep
# ERROR as "absent". The first draft used `--exclude-dir` and `-I`; busybox grep rejects
# the former, so on Alpine the probe exited 2, was read as "no mirror", and reported CORE —
# the repo that authors this rule — as the one repo missing it. A false finding produced by
# an unsupported flag, in the gate whose whole subject is checks that answer wrongly.
#
# The fixture is a grep that rejects those flags exactly as busybox's does, so this case
# fails on the old shape and passes on the new one WITHOUT needing an Alpine runner. The
# audit-alpine CI leg is the real proof; this is the one that runs on a developer box.
_mg_bb="$SANDBOX/bbgrep"
mkdir -p "$_mg_bb"
cat >"$_mg_bb/grep" <<'BBEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    --exclude-dir=*|-I) echo "grep: unrecognized option: ${a#--}" >&2; exit 2 ;;
  esac
done
exec /usr/bin/grep "$@"
BBEOF
chmod +x "$_mg_bb/grep"
if [[ -x /usr/bin/grep ]]; then
  # An ABSOLUTE PATH set inside the substitution, never `$PATH` prefixed onto the call.
  # Reading $PATH anywhere here pairs with the subshell PATH assignment ~350 lines above
  # and shellcheck reports SC2030 there and SC2031 here — a false pair on two unrelated
  # tests. This is the same shape as that earlier block, which is clean for the same
  # reason: the assignment is scoped to the subshell and nothing reads PATH after it.
  _mg_bb_out="$( PATH="$_mg_bb:/usr/bin:/bin"; _core_make_gate_hits "$HERE/.." )"
  if [[ -z "$_mg_bb_out" ]]; then
    pass "make-gate: Core stays clean under a grep that rejects GNU-only flags (the Alpine case)"
  else
    fail "make-gate: a busybox-style grep makes the mirror probe report a false finding: $_mg_bb_out"
  fi
  unset _mg_bb_out
else
  skip "make-gate: busybox-grep fixture (no /usr/bin/grep to delegate to)"
fi
rm -rf "$_mg_bb"
unset _mg_bb

# ── Core must satisfy the rule it authors. §8d asserts this in the audit; asserting it
# here too means a `make test` catches it without a full audit run.
if [[ -z "$(_core_make_gate_hits "$HERE/..")" ]]; then
  pass "make-gate: Core's own Makefile meets the rule it sets for the fleet"
else
  fail "make-gate: Core's own Makefile breaks the rule §8d applies to every caller"
fi
unset _mg_
unset -f _mg_write _mg_count

# ── the parity coverage gate can actually fail (scripts/parity-check.sh) ───────
# parity-check.sh's whole claim after #682 is that PARITY.md's one-to-one contract is
# PROVEN rather than promised. A gate nobody has watched fail is exactly the thing that
# claim rejects, and the negative runs that justified it were done by hand on a branch —
# which is a discipline, not a gate, and the second time this repo has learned that.
#
# HERMETIC FIXTURE, real script, real CHECKS array — the gen-theme pattern from
# scripts/test/40-gen-theme-aliases.sh. Only
# PARITY.md varies between rows, so every verdict below is attributable to the coverage
# logic and nothing else. dotfiles-Windows is deliberately absent from the fixture root,
# so the pwsh half self-skips and cannot colour the result.
# ── the recovery runbook's caller derivation (GITHUB-APP-AUTH.md) ────────────
# #832: the Recovery section tells the operator to DERIVE the caller list rather than trust
# a written one — and then handed them a grep that could not see Core's own caller. It
# needled `notify-web-call.yml@`, the REMOTE `uses:` form; Core's caller is LOCAL
# (`release.yml` reads `uses: ./.github/workflows/notify-web-call.yml`, no `@`), so an
# operator following the procedure omitted Core's mapping and lost the release-path dispatch
# the moment step 7 disabled the App.
#
# WHY THIS IS A TEST AND NOT A CAREFUL REREAD. That grep was itself added to fix an earlier
# review finding — "derive it, do not freeze it" — so the derivation was made AUTHORITATIVE
# before it was made CORRECT, which is worse than the frozen list it replaced, because the
# next step instructs the operator to trust it. A derivation nothing exercises is a frozen
# list that looks live. This runs the documented commands, as written, against Core's own
# tree and asserts they find the caller that is actually there.
hdr "recovery caller derivation (GITHUB-APP-AUTH.md)"
_rc_doc="$HERE/GITHUB-APP-AUTH.md"
_rc_wf="$HERE/.github/workflows"
# GROUND TRUTH FIRST. If Core stops calling the reusable locally, the assertions below would
# pass vacuously against a pattern that matches nothing — so the caller's existence is
# asserted separately from the patterns' ability to see it.
_rc_local="$(grep -rlE '^[[:space:]]*uses:[[:space:]]*\./\.github/workflows/notify-web-call\.yml' "$_rc_wf" 2>/dev/null)"
if [[ -n "$_rc_local" ]]; then
  pass "recovery derivation: Core still has a LOCAL notify-web-call caller ($(basename "$_rc_local")) — the case the runbook's grep must see"
else
  fail "recovery derivation: no local notify-web-call caller in $_rc_wf — the assertions below would go green against a shape Core no longer has; re-check the runbook before deleting this"
fi
# THE PATTERNS ARE READ OUT OF THE DOC, not restated here. Restating them would test this
# file against itself and stay green over a reworded runbook — the same render-vs-judge
# separation the parity verdict's notice pin exists for. Selected by CONTENT rather than by
# position, so inserting an unrelated grep into the procedure does not silently shift which
# command is under test.
# EVERY `-e 'PATTERN'` on a `grep -r` line, then the ones about notify-web-call. The
# `[-]e` bracket avoids a leading dash that grep would read as an option, without needing
# `--` (busybox and GNU disagree less about brackets than about option terminators), and
# the whole pipeline is POSIX so it runs on the Alpine leg that caught the ERE in the first
# place. Step 2's other pattern is the INLINE dispatcher half and is not expected to match
# release.yml, so filtering to notify-web-call is what makes the assertion meaningful.
_rc_pats="$(sed -n '/grep -r/p' "$_rc_doc" | grep -o "[-]e '[^']*'" | sed "s/^-e '//; s/'\$//" | grep -F 'notify-web-call')"
_rc_n="$(printf '%s\n' "$_rc_pats" | grep -c . || true)"
if ((_rc_n == 2)); then
  pass "recovery derivation: both documented notify-web-call greps were extracted from the runbook"
else
  fail "recovery derivation: extracted $_rc_n notify-web-call grep(s) from GITHUB-APP-AUTH.md, want 2 (steps 2 and 5) — the runbook's commands were reshaped and this check is reading the wrong thing"
fi
# The pattern is applied WITHOUT -E, exactly as the runbook now spells it: a step that
# reverted to an ERE-only construct would fail here rather than only on the Alpine leg.
# Numbered, because the two commands legitimately carry the SAME pattern now and two
# identical lines in the output would look like a duplicate rather than two checks.
_rc_i=0
while IFS= read -r _rc_pat; do
  [[ -n "$_rc_pat" ]] || continue
  _rc_i=$((_rc_i + 1))
  if [[ -n "$_rc_local" ]] && grep -rl -e "$_rc_pat" "$_rc_wf" 2>/dev/null | grep -qxF "$_rc_local"; then
    pass "recovery derivation: runbook grep $_rc_i of 2 (/${_rc_pat}/, BRE) finds Core's own local caller"
  else
    fail "recovery derivation: runbook grep $_rc_i (/${_rc_pat}/) does NOT find Core's own local caller under a plain BRE grep — an operator following the procedure would omit Core's secrets mapping and lose the release-path dispatch at step 7 (#832)"
  fi
done <<<"$_rc_pats"
unset _rc_doc _rc_wf _rc_local _rc_pats _rc_n _rc_pat _rc_i

# ── the fan-out count (common.sh :: _core_fanout_count_hits) ─────────────────
# #770 found the number contradicting itself across the tree — five sites saying EIGHT
# against ~20 saying nine — after #668 had found one of the five a year earlier and
# deliberately left it, because correcting one of several inconsistent sites makes the tree
# no more correct. A gate is the answer to drift that has recurred; these cases pin the two
# properties that decide whether it is a USEFUL one.
#
# BOTH DIRECTIONS, deliberately. The negative cases carry as much weight as the positive:
# three different numbers are correct here about three different sets (9 Core-vendoring,
# 8 OS-native, 11 total), and a gate that reds on the legitimate ones is noise — which is
# how a check teaches the fleet to ignore it. Those lines are verbatim from the tree.
hdr "fan-out count guard (_core_fanout_count_hits)"
_fc_="$SANDBOX/fanout"
_fc_setup() { # _fc_setup <file-content...> — a throwaway git repo holding one tracked file
  rm -rf "$_fc_"
  mkdir -p "$_fc_"
  git -C "$_fc_" init -q >/dev/null 2>&1 || return 1
  printf '%s\n' "$@" >"$_fc_/claims.md"
  git -C "$_fc_" add -A >/dev/null 2>&1
}
_fc_count() { # _fc_count <label> <want-findings>
  local got n=0
  got="$(_core_fanout_count_hits "$_fc_" 9)"
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
  if [[ "$n" == "$2" ]]; then pass "fan-out count: $1"; else fail "fan-out count: $1 (got $n finding(s), want $2)"; fi
}

if ! git --version >/dev/null 2>&1; then
  skip_env "fan-out count guard (git not available — the helper enumerates through git ls-files)"
else
  # THE TWO SURVIVORS OF #770, verbatim. CODEOWNERS:1 is the one #668 found and left.
  _fc_setup '# CODEOWNERS — Core fans out to all eight OS repos, so every change' # core:fanout-fixture
  _fc_count "the CODEOWNERS line #668 found and left is a finding" 1

  _fc_setup '--         2. `cond` gates the whole spec on the `claude` binary. Core vendors into eight OS repos' # core:fanout-fixture
  _fc_count "the nvim plugin comment is a finding" 1

  # THE WRAPPED CLAIM. ci.yml put the verb on one comment line and the number on the NEXT,
  # so a line-based check read neither half as a claim and the defect survived a sweep that
  # was looking straight at it. Reported against the line carrying the NUMBER — the line an
  # author edits.
  _fc_setup \
    "  # or a shebang script that isn't +x sails through green and vendors into all" \
    '  # 8 repos. The audit job deliberately does NOT replicate these file-hygiene hooks' # core:fanout-fixture
  _fc_count "a claim wrapped across two comment lines is still a claim" 1
  if [[ "$(_core_fanout_count_hits "$_fc_" 9)" == claims.md:2:* ]]; then
    pass "fan-out count: a wrapped claim is reported against the line holding the number"
  else
    fail "fan-out count: a wrapped claim was reported against the verb's line, which is not the line to edit"
  fi

  # ── the legitimate other-set usages, all verbatim from the tree ─────────────
  # 8, correctly: the nine vendoring repos minus dotfiles-Alpine, which uses doas.
  _fc_setup '# sudo-first is right for eight repos and WRONG for dotfiles-Alpine, whose'
  _fc_count "eight repos relying on sudo-first is not a fan-out claim" 0

  # 8, correctly again, and a DIFFERENT eight: the lint-call.yml callers (nine minus MacBook).
  _fc_setup '  # by hand and found ELEVEN defects across eight repos in three shapes:'
  _fc_count "#775's eleven-defects-across-eight-repos sweep is not a fan-out claim" 0

  # 11, correctly: the whole system, 8 OS + 2 Role + dotfiles-core.
  _fc_setup 'a eleven-repo dotfiles system built on a three-layer model'
  _fc_count "the eleven-repo system count is not a fan-out claim" 0

  # A number that is not a count of repos at all.
  _fc_setup 'Core fans out to all nine OS repos, and 8 of them ship a Makefile.'
  _fc_count "a correct claim followed by an unrelated number stays clean" 0

  # THE POSITIVE CONTROL. A gate whose clean cases all pass because it matches nothing is
  # the failure mode these fixtures exist to rule out.
  _fc_setup 'A change here fans out to all nine OS repos, so the bar is high.'
  _fc_count "a correct claim is clean" 0
  if [[ -n "$(_core_fanout_count_hits "$_fc_" 8)" ]]; then
    pass "fan-out count: the same correct-at-9 claim IS a finding when the fleet lists 8 (the check reads the list, not a constant)"
  else
    fail "fan-out count: a nine-repo claim went clean against a fleet of 8 — the number is hardcoded, so the gate cannot follow os-repos.txt"
  fi

  # CHANGELOG IS EXCLUDED: it records what was true when written, and rewriting old entries
  # to match today's fleet would be a lie about what shipped.
  _fc_setup 'placeholder'
  printf '%s\n' '  fan out to all eight OS repos, silently. luacheck does not help' >"$_fc_/CHANGELOG.md" # core:fanout-fixture
  git -C "$_fc_" add -A >/dev/null 2>&1
  _fc_count "a historical fan-out claim in CHANGELOG.md is not rewritten by the gate" 0

  # THE OPT-OUT ITSELF. `core:fanout-fixture` is how the cases above hold the wrong claims
  # verbatim without reddening the gate that reads this very file. An exemption nothing
  # tests is an exemption that can silently swallow a real claim, so both halves are pinned:
  # a marked line is exempt, and an unmarked one in the SAME file is still judged.
  _fc_setup \
    '# Core fans out to all eight OS repos # core:fanout-fixture' \
    '# Core fans out to all eight OS repos' # core:fanout-fixture (this physical line, too)
  _fc_count "the fixture marker exempts its own line and nothing else" 1

  # AND UNTRACKED FILES: a claim in a scratch file is not a claim the fleet ships.
  _fc_setup 'placeholder'
  printf '%s\n' '# Core fans out to all eight OS repos' >"$_fc_/scratch.md" # core:fanout-fixture
  _fc_count "an UNTRACKED file's fan-out claim is not judged" 0
fi
rm -rf "$_fc_"
unset _fc_
unset -f _fc_setup _fc_count

hdr "parity coverage gate (scripts/parity-check.sh)"
PCR="$SANDBOX/parityrepo"
PCOUT="$SANDBOX/parity-run.out"

# _pc_fixture <parity-md-path> — rebuild the fixture around a given PARITY.md, run the
# real script in it, leave the output in $PCOUT and RETURN the script's exit code. Every
# needled source is copied verbatim from the real tree, so the zsh half always holds and
# only coverage can move the verdict.
#
# The rc comes back as this function's own exit status, not a variable it sets: callers
# read the output via $PCOUT rather than command substitution, because a `$(...)` call
# runs the function in a SUBSHELL and any rc it assigned there would never reach them.
_pc_fixture() {
  rm -rf "$PCR"
  mkdir -p "$PCR/scripts/lib" "$PCR/zsh" "$PCR/theme" "$PCR/lib" "$PCR/fleet"
  cp "$HERE/scripts/parity-check.sh" "$PCR/scripts/"
  cp "$HERE/scripts/lib/common.sh" "$PCR/scripts/lib/"
  cp "$HERE/lib/ux.sh" "$PCR/lib/" # common.sh sources it from the repo root
  cp "$HERE/scripts/parity-aliases.txt" "$PCR/scripts/"
  cp "$HERE/theme/palette.toml" "$PCR/theme/"
  cp "$HERE"/zsh/{00-tools,20-aliases,25-git,30-functions,35-fzf,40-bindings}.zsh "$PCR/zsh/"
  cp "$1" "$PCR/PARITY.md"
  [[ "${2:-}" == win ]] && _pc_win
  # --root at an EMPTY fleet dir, and $DOTFILES_ROOT stripped: the pwsh half must be
  # absent by construction, not by accident of the caller's environment. Without this the
  # rows below flip meaning under `make audit` (which exports DOTFILES_ROOT at the real
  # fleet) versus a bare `make test` — a test whose verdict depends on who ran it.
  env -u DOTFILES_ROOT "$PCR/scripts/parity-check.sh" --root "$PCR/fleet" --color never >"$PCOUT" 2>&1
}

# _pc_win — synthesise a dotfiles-Windows inside the fixture fleet, DERIVED FROM THE CHECKS
# ARRAY ITSELF so a check added later cannot silently stop being covered here. Without a
# Windows-present fixture the `-` (framework-default) branch and the qualified closing summary
# never execute at all: deleting the `-` handling would restore a false full pass and every
# test would stay green, since the rows below force the pwsh half to be absent.
#
# The array is EVAL'd out of the real script rather than read as text: that yields each needle
# exactly as the gate will grep for it, escapes resolved, so the fixture cannot disagree with
# the contract about what a needle says.
_pc_win() {
  local win="$PCR/fleet/dotfiles-Windows" row k l zf zn pf pn fg want i anchor
  local CHECKS=()
  rm -rf "$win"
  eval "$(sed -n '/^CHECKS=(/,/^)$/p' "$HERE/scripts/parity-check.sh")"
  for row in ${CHECKS[@]+"${CHECKS[@]}"}; do
    # The leading fields are named rather than discarded into `_`, so the split documents
    # the row format where it is parsed; only the pwsh half is written out here.
    # shellcheck disable=SC2034
    IFS='|' read -r k l zf zn pf pn <<<"$row"
    [[ "$pn" == "-" ]] && continue # the framework defaults: nothing to write, by definition
    # A `count:N:` needle demands N matching LINES (pwsh binds Ctrl+R twice on purpose), so
    # the fixture has to satisfy the count, not just the string.
    want=1
    anchor=""
    case "$pn" in
    count:[0-9]*:*)
      want="${pn#count:}"
      want="${want%%:*}"
      pn="${pn#count:*:}"
      ;;
    after:*)
      # position matters for this one: write the anchor first so the needle lands BELOW it,
      # rather than relying on the order rows happen to appear in CHECKS.
      anchor="${pn#after:}"
      anchor="${anchor%%:*}"
      pn="${pn#after:*:}"
      ;;
    esac
    mkdir -p "$win/${pf%/*}"
    [[ -n "$anchor" ]] && printf '%s\n' "$anchor" >>"$win/$pf"
    i=0
    while ((i < want)); do
      printf '%s\n' "$pn" >>"$win/$pf"
      i=$((i + 1))
    done
  done
  # The palette VALUE comparison wants a real hex, not just the needle's prefix.
  fg="$(sed -nE 's/^color_fg[[:space:]]*=[[:space:]]*"(#[0-9a-f]{6})".*/\1/p' "$HERE/theme/palette.toml" | head -n1)"
  printf -- '--color=query:%s:regular\n' "$fg" >>"$win/powershell/core/10-tools.ps1"
  # ...and the alias loop wants the `provides:` contract line, built from the same manifest
  # parity-check.sh reads, so the two cannot disagree either.
  printf '# provides: %s\n' \
    "$(awk -F'|' '!/^[[:space:]]*#/ && NF >= 3 && $1 != "" { printf "%s,", $3 }' "$HERE/scripts/parity-aliases.txt")" \
    >"$win/powershell/core/00-aliases.ps1"
}

# _pc_row <label> <expected-rc> <needle-in-output> <awk-program-against-PARITY.md>
# An empty program means "the real contract, unmodified".
#
# AWK, NOT SED, for the mutations. `\n` in a sed REPLACEMENT is a GNU extension: BSD sed
# (macOS, a supported CI leg) does not expand it, so a row meant to be INSERTED would have
# merged into the following line and these negative rows would have quietly stopped testing
# the thing they are named for. A test that cannot fail is the defect this file exists to
# catch, so the mutations use only portable awk.
_pc_row() {
  local label="$1" want_rc="$2" want_txt="$3" prog="${4:-}"
  local fx="$SANDBOX/parity-fixture.md" rc=0
  if [[ -n "$prog" ]]; then awk "$prog" "$HERE/PARITY.md" >"$fx"; else cp "$HERE/PARITY.md" "$fx"; fi
  _pc_fixture "$fx" || rc=$?
  if ((rc == want_rc)) && grep -qF -- "$want_txt" "$PCOUT"; then
    pass "parity coverage: $label"
  else
    fail "parity coverage: $label (rc=$rc, wanted $want_rc; output did not contain '$want_txt')"
    grep -E "coverage|cross-shell" "$PCOUT" | sed 's/^/    /' >&2
  fi
}

# The control. If this row ever goes red the fixture drifted from the real tree, and every
# negative row below is meaningless — so it runs first.
_pc_row "the real contract is fully covered" 0 \
  "aligned PARITY.md rows have a check"

# 1. An aligned row nobody enforces — the defect #682 was filed for. It must NAME the row:
#    a bare count would send the reader diffing two lists by hand.
_pc_row "an aligned row with no needle fails, and names it" 1 \
  "no check behind them: clipboard-sync" \
  '/^\| Word nav \|/ { print "| Clipboard sync | `pbcopy` | `Set-Clipboard` | `aligned` |" } { print }'

# 2. The other direction: rename a Capability cell and its check no longer matches a row.
#    Both halves of the mapping must fire — the old key orphans, the new row is uncovered.
_pc_row "a renamed row orphans its check, and names the key" 1 \
  "match no PARITY.md table row: session-picker" \
  '{ sub(/^\| Session picker \|/, "| Session chooser |"); print }'

# 3. Two rows slugifying alike would let one row's needle certify the other — coverage
#    would read as complete while a row went untested. That is the #682 failure wearing a
#    different hat, so it is a hard fail rather than a warning.
_pc_row "two rows slugifying to one key fail" 1 \
  "both slugify to \`theme\`" \
  '/^\| Word nav \|/ { print "| Theme | x | y | `aligned` |" } { print }'

# 4. The case the PR description got WRONG before review caught it: reclassifying a row
#    does NOT orphan its check. `deliberate`/`gap` rows may keep one (see `cheat`), and
#    only `aligned` rows are required to have one. Pinned here because the prose claimed
#    otherwise in four places, and prose is what this gate exists to stop trusting.
_pc_row "reclassifying an aligned row keeps its check valid" 0 \
  "aligned PARITY.md rows have a check" \
  '/^\| Session picker \|/ { sub(/`aligned`/, "`deliberate`") } { print }'

# 5. A misspelled status is the nastiest input this parser takes: the row stays known (so
#    its check is not orphaned) but stops being REQUIRED, quietly dropping a contract row
#    out of enforcement with the gate green. Only the three documented statuses are
#    accepted, and anything else is a hard fail naming the row and what it said.
_pc_row "an unknown status is rejected, not treated as not-aligned" 1 \
  "has status \`aligend\`" \
  '/^\| Word nav \|/ { sub(/`aligned`/, "`aligend`") } { print }'

# 6. A pwsh half that is a framework default must be REPORTED, never certified. The
#    summary line is the assertion: it may not say "all aligned rows hold" when a half was
#    skipped. (Windows is absent from the fixture, so this pins the Core-side wording.)
_pc_fixture "$HERE/PARITY.md" || true
if grep -qF "pwsh side skipped" "$PCOUT"; then
  pass "parity coverage: a run without dotfiles-Windows says so instead of claiming both shells"
else
  fail "parity coverage: a pwsh-less run did not qualify its summary — it certified a half it never read"
fi

# 7. AN INDENTED ROW IS STILL A ROW. Anchoring the parser at column 0 meant a Markdown-legal
#    row with one to three leading spaces parsed as nothing: the gate reported "all 20 aligned
#    rows have a check" and exited 0 while a new aligned row sat there unenforced. Four or
#    more spaces IS an indented code block, so that one must still be ignored — both
#    directions are pinned, because a fix that swallowed code blocks would be its own bug.
_pc_row "a one-space-indented aligned row is enforced, not ignored" 1 \
  "no check behind them: clipboard-sync" \
  '/^\| Word nav \|/ { print " | Clipboard sync | `pbcopy` | `Set-Clipboard` | `aligned` |" } { print }'
_pc_row "a 4-space-indented row is an indented code block, not a contract row" 0 \
  "aligned PARITY.md rows have a check" \
  '/^\| Word nav \|/ { print "     | Clipboard sync | `pbcopy` | `x` | `aligned` |" } { print }'

# 8. THE WINDOWS-PRESENT PATH. Everything above forces the pwsh half to be absent, so the `-`
#    branch and the qualified summary never ran. With a synthetic dotfiles-Windows in place
#    both must: each Word-nav half is reported as a skip, and the closing line must NOT say
#    "all aligned rows hold across zsh + pwsh" — the overclaim this PR exists to remove.
_pc_fixture "$HERE/PARITY.md" win && _pc_win_rc=0 || _pc_win_rc=$?
_pc_win_n="$(grep -c "nothing to grep" "$PCOUT" || true)"
if ((_pc_win_rc == 0)) && ((_pc_win_n == 2)) &&
  grep -qF "every CONFIGURED aligned row holds" "$PCOUT" &&
  ! grep -qF "all aligned rows hold across zsh + pwsh" "$PCOUT"; then
  pass "parity coverage: a Windows-present run reports both framework-default halves and refuses to certify them"
else
  fail "parity coverage: Windows-present run (rc=$_pc_win_rc, $_pc_win_n default skips) did not report both halves and qualify its summary"
  grep -E "coverage|nothing to grep|aligned rows hold|CONFIGURED" "$PCOUT" | sed 's/^/    /' >&2
fi
unset _pc_win_rc _pc_win_n

# 9. `after:` is POSITION, not presence — the one property a count cannot express. pwsh's
#    Ctrl+R re-assertion only means anything BELOW `atuin init`, because atuin ignores
#    ATUIN_NOBIND there and seizes the chord on init. Hoisting both bindings above the anchor
#    keeps the count satisfied and must still fail, or the row certifies a runtime break.
_pc_fixture "$HERE/PARITY.md" win >/dev/null 2>&1 || true
_pc_f10="$PCR/fleet/dotfiles-Windows/powershell/core/10-tools.ps1"
{
  grep -F -- "-Chord 'Ctrl+r'" "$_pc_f10"
  grep -vF -- "-Chord 'Ctrl+r'" "$_pc_f10"
} >"$_pc_f10.hoisted" && mv "$_pc_f10.hoisted" "$_pc_f10"
env -u DOTFILES_ROOT "$PCR/scripts/parity-check.sh" --root "$PCR/fleet" --color never >"$PCOUT" 2>&1 && _pc_ord_rc=0 || _pc_ord_rc=$?
if ((_pc_ord_rc == 1)) && grep -qF "BELOW 'atuin init'" "$PCOUT"; then
  pass "parity coverage: two Ctrl+R bindings both ABOVE atuin still fail — count cannot express position"
else
  fail "parity coverage: hoisting both Ctrl+R bindings above atuin was accepted (rc=$_pc_ord_rc) — the row would certify a runtime break"
  grep -E "survives atuin|history search on" "$PCOUT" | sed 's/^/    /' >&2
fi
unset _pc_f10 _pc_ord_rc

rm -rf "$PCR"
unset PCR PCOUT
unset -f _pc_fixture _pc_row _pc_win

# ── how audit-core.sh §9f CLASSIFIES that run (common.sh :: _core_parity_verdict) ──
# The rows above drive parity-check.sh directly and never reach the audit integration —
# which is where both of the falsely-complete reports review found actually lived. The
# classification is therefore a helper, and this drives it: caller renders, helper decides,
# test drives the helper (the _core_luacheck_verdict split).
_pv_is() { # _pv_is <label> <rc> <output> <expected-verdict>
  local got
  got="$(_core_parity_verdict "$2" "$3")"
  if [[ "$got" == "$4" ]]; then
    pass "parity verdict: $1"
  else
    fail "parity verdict: $1 (got '$got', wanted '$4')"
  fi
}
_pv_is "a clean both-shells run is ok-full" 0 "✓ all aligned rows hold across zsh + pwsh" ok-full
_pv_is "an absent dotfiles-Windows is ok-no-sibling, not a full pass" \
  0 "– dotfiles-Windows not checked out at /x — pwsh side not verified" ok-no-sibling
_pv_is "an unasserted framework default is ok-defaults, not a full pass" \
  0 "– word nav: forward-word on Ctrl+Right — pwsh half is a PSReadLine default; nothing to grep" ok-defaults
# Precedence: with no sibling repo the pwsh half never runs, so a default can never ALSO be
# reported. If both notices somehow appear, the weaker claim must win.
_pv_is "no-sibling outranks framework-default when both appear" \
  0 "– dotfiles-Windows not checked out — nothing to grep" ok-no-sibling
_pv_is "exit 1 is drift, whatever it printed" 1 "" drift
_pv_is "exit 2 is broken, NOT a clean contract" 2 "" broken
_pv_is "a non-standard exit is broken, not silently ok" 127 "" broken
unset -f _pv_is

# The verdict is matched on parity-check.sh's own notice wording, and §9f's whole
# classification rests on reading them. Pin both ends so a reword on either side is a
# failure HERE rather than a silently-wrong audit line — the luacheck pin's reason (:2035).
if grep -qF 'dotfiles-Windows not checked out' "$HERE/scripts/parity-check.sh" &&
  grep -qF 'nothing to grep' "$HERE/scripts/parity-check.sh"; then
  pass "parity verdict: parity-check.sh still emits both notices _core_parity_verdict reads"
else
  fail "parity verdict: parity-check.sh reworded a notice _core_parity_verdict matches on — §9f will misclassify"
fi
if grep -q '_core_parity_verdict' "$HERE/scripts/audit-core.sh"; then
  pass "parity verdict: audit-core.sh §9f classifies via the helper, not an inline if-chain"
else
  fail "parity verdict: audit-core.sh §9f stopped using _core_parity_verdict — the classification is untestable again"
fi
# CORE_JSON=1 is EXPORTED by `audit --json` and silences common.sh's skip(), which is where
# both notices above come from. Without the reset at the child boundary a --json run
# classifies every box as ok-full — it reported a full zsh+pwsh pass on a box with no pwsh
# file. That reset is one token with no runtime symptom in a normal run, so it is pinned.
if grep -q 'CORE_JSON=0 "\$HERE/scripts/parity-check.sh"' "$HERE/scripts/audit-core.sh"; then
  pass "parity verdict: §9f clears CORE_JSON at the child boundary (a --json run would else read no notices)"
else
  fail "parity verdict: §9f no longer clears CORE_JSON for the parity child — --json runs will report a full pass on a box with no pwsh file"
fi
