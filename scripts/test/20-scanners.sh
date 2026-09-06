# scripts/test/20-scanners.sh
# common.sh content scanners (fail_detail, pipefail, RETURN-trap, owned-block, conflict-marker, routine refs)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the content scanners in scripts/lib/common.sh ─────────────────────────────
# common.sh owns a family of `_core_*_hits` extractors: each greps a tracked file for one
# banned shape and prints what it found, and audit-core.sh turns that output into a verdict.
# Splitting extraction from judgement is what makes them testable at all — the arms below
# drive each extractor against purpose-built fixtures and assert BOTH directions, what it
# must catch and what it must not, because a scanner that fires on everything and one that
# fires on nothing are equally useless and only the second one looks green.
# Pure bash, so it all runs even where zsh/nvim are absent.
# ── failing-gate detail (scripts/lib/common.sh :: fail_detail) ────────────────
# WHY THIS IS TESTED. The audit used to discard every linter's own report, so a red CI run
# named a gate and nothing else — "✗ markdownlint reported issues", no rule, no file, no
# line — and CI is exactly where you cannot re-run the tool by hand (#456). fail_detail is
# what closes that, which makes its two easy-to-break properties worth pinning: it must go
# to STDERR (stdout carries the --json summary object, and polluting it would trade one
# broken output for another), and it must CAP, or a pathological run buries the summary it
# is meant to explain. The herestrings inside it are the #459 SIGPIPE trap; a "tidy-up"
# back to `printf | head` reintroduces it, so the cap assertion doubles as that guard.
hdr "failing-gate detail (fail_detail)"
_fdt_out="$(fail_detail "one
two" 2>/dev/null)"
if [[ -z "$_fdt_out" ]]; then pass "fail_detail: writes nothing to stdout (--json stays parseable)"; else fail "fail_detail: leaked to stdout: $_fdt_out"; fi

_fdt_err="$(fail_detail "alpha
beta" 2>&1 >/dev/null)"
if grep -q '^    alpha$' <<<"$_fdt_err" && grep -q '^    beta$' <<<"$_fdt_err"; then
  pass "fail_detail: writes the tool's report to stderr, indented"
else fail "fail_detail: stderr was [$_fdt_err]"; fi

_fdt_err="$(fail_detail "" 2>&1 >/dev/null)"
if [[ -z "$_fdt_err" ]]; then pass "fail_detail: empty output is a no-op"; else fail "fail_detail: emitted [$_fdt_err] for empty input"; fi

# cap: 60 lines with a limit of 5 → 5 shown plus one "… N more" line, and the count right
_fdt_many="$(seq 1 60)"
_fdt_err="$(CORE_FAIL_DETAIL_LINES=5 fail_detail "$_fdt_many" 2>&1 >/dev/null)"
_fdt_n="$(wc -l <<<"$_fdt_err" | tr -d ' ')"
if [[ "$_fdt_n" == 6 ]] && grep -q '… 55 more line' <<<"$_fdt_err"; then
  pass "fail_detail: caps at CORE_FAIL_DETAIL_LINES and reports the remainder"
else fail "fail_detail: cap produced $_fdt_n line(s): $(head -3 <<<"$_fdt_err")"; fi

# ── pipefail SIGPIPE scanner (scripts/lib/common.sh :: _core_pipefail_hits) ───
# WHY THIS IS TESTED. audit-core.sh §5d exists because this repo has hit the pipefail +
# SIGPIPE trap three times — a 4000-line `git show` into `grep -q`, `ldd --version |
# grep -qi musl`, and nvim-reachability.sh inventing orphans on main (#458, #459). A gate
# for a bug that has recurred that often is only worth having if it actually fires, and
# probe-testing this one already caught a real defect: it used to scan any file that merely
# MENTIONED pipefail in a comment, which is the false-positive class that gets a gate
# switched off. Both halves are pinned below — what it catches AND what it must ignore.
if have git; then
  hdr "pipefail SIGPIPE scanner (_core_pipefail_hits)"
  _pfd="$SANDBOX/pipefail"
  mkdir -p "$_pfd"
  _pf_write() { printf '%s\n' "$2" >"$_pfd/$1"; }   # _pf_write <name> <body>
  # THE PIPE IS ASSEMBLED, NOT WRITTEN LITERALLY. This file sets `pipefail`, so §5d scans
  # it — and a file whose job is to TEST the banned shape necessarily contains it, which
  # made the gate flag its own fixtures on the first run. Keeping the literal out of this
  # source is the honest fix: the fixture written to disk is byte-identical to the real
  # hazard, so the assertions still exercise the true pattern. The alternative — an
  # inline "allow" marker in the scanner — was rejected as an escape hatch that invites
  # silencing a real finding, on a gate that exists because this bug keeps coming back.
  _pf_p='|'

  _pf_write grepq.sh "set -euo pipefail
printf '%s' \"\$big\" $_pf_p grep -q needle"
  if [[ "$(_core_pipefail_hits "$_pfd/grepq.sh")" == 2 ]]; then pass "pipefail scan: catches a printf piped into grep -q"; else fail "pipefail scan: missed a printf piped into grep -q"; fi

  # FLAG ORDER must not matter. The regex used to require `q` to be the LAST letter of the
  # cluster, so `-q` and `-xq` were caught while `-qx` and `-Eqi` walked past — identical
  # hazard, different spelling. That blind spot was hiding a live one in ci-pr-link.sh's
  # No-Issue probe (`-Eqi`), where a body over the pipe buffer would have failed a
  # correctly-exempt PR. Pin every spelling so the gate cannot go half-blind again (#501).
  _pf_write grepqx.sh "set -euo pipefail
printf '%s' \"\$big\" $_pf_p grep -qx needle"
  if [[ "$(_core_pipefail_hits "$_pfd/grepqx.sh")" == 2 ]]; then pass "pipefail scan: catches grep -qx (q not last in the cluster)"; else fail "pipefail scan: missed grep -qx — the regex still requires q to be last"; fi

  _pf_write grepeqi.sh "set -euo pipefail
printf '%s' \"\$big\" $_pf_p grep -Eqi needle"
  if [[ "$(_core_pipefail_hits "$_pfd/grepeqi.sh")" == 2 ]]; then pass "pipefail scan: catches grep -Eqi (the real ci-pr-link.sh shape)"; else fail "pipefail scan: missed grep -Eqi"; fi

  _pf_write grepxq.sh "set -euo pipefail
printf '%s' \"\$big\" $_pf_p grep -xq needle"
  if [[ "$(_core_pipefail_hits "$_pfd/grepxq.sh")" == 2 ]]; then pass "pipefail scan: still catches grep -xq (q last, the original form)"; else fail "pipefail scan: regressed on grep -xq"; fi

  # The widened cluster must not swallow a grep with NO q at all — that has no early exit.
  _pf_write grepnoq.sh "set -euo pipefail
printf '%s' \"\$big\" $_pf_p grep -Ei needle"
  if [[ -z "$(_core_pipefail_hits "$_pfd/grepnoq.sh")" ]]; then pass "pipefail scan: a grep with no quiet flag is not a finding"; else fail "pipefail scan: widened regex now flags a non-quiet grep"; fi

  _pf_write head.sh "set -euo pipefail
echo \"\$v\" $_pf_p head -n1"
  if [[ "$(_core_pipefail_hits "$_pfd/head.sh")" == 2 ]]; then pass "pipefail scan: catches an echo piped into head"; else fail "pipefail scan: missed an echo piped into head"; fi

  _pf_write awkexit.sh "set -euo pipefail
printf '%s' \"\$v\" $_pf_p awk '/x/ { print; exit }'"
  if [[ "$(_core_pipefail_hits "$_pfd/awkexit.sh")" == 2 ]]; then pass "pipefail scan: catches a printf piped into awk with exit"; else fail "pipefail scan: missed a printf piped into awk with exit"; fi

  # the herestring form is the FIX — it must never be flagged, or the gate punishes the cure
  _pf_write safe.sh 'set -euo pipefail
grep -q needle <<<"$big"'
  if [[ -z "$(_core_pipefail_hits "$_pfd/safe.sh")" ]]; then pass "pipefail scan: a herestring is not a finding"; else fail "pipefail scan: flagged the herestring fix"; fi

  # writing ABOUT the hazard must not trip it — this very repo documents it in comments
  _pf_write comment.sh "set -euo pipefail
# printf '%s' \"\$x\" $_pf_p grep -q foo is the trap this gate exists to catch
grep -q foo <<<\"\$x\""
  if [[ -z "$(_core_pipefail_hits "$_pfd/comment.sh")" ]]; then pass "pipefail scan: a comment describing the hazard is not a finding"; else fail "pipefail scan: flagged a comment"; fi

  # no pipefail set → the shape is harmless, and flagging it is the false positive that
  # gets a gate disabled. (The word appearing in prose must not count as enabling it.)
  _pf_write nopipefail.sh "set -eu
# this file only mentions pipefail in a comment
printf '%s' \"\$v\" $_pf_p grep -q needle"
  if [[ -z "$(_core_pipefail_hits "$_pfd/nopipefail.sh")" ]]; then pass "pipefail scan: a file that never enables pipefail is not a finding"; else fail "pipefail scan: flagged a file that never enables pipefail"; fi

  # pipefail enabled in a SPLIT form — an earlier version anchored on the first option
  # token and skipped these entirely, so the gate silently permitted the hazard
  _pf_write splitset.sh "set -e -o pipefail
printf '%s' \"\$v\" $_pf_p grep -q needle"
  if [[ "$(_core_pipefail_hits "$_pfd/splitset.sh")" == 2 ]]; then pass "pipefail scan: sees set -e -o pipefail"; else fail "pipefail scan: missed the split set form"; fi

  _pf_write longset.sh "set -o errexit -o pipefail
printf '%s' \"\$v\" $_pf_p grep -q needle"
  if [[ "$(_core_pipefail_hits "$_pfd/longset.sh")" == 2 ]]; then pass "pipefail scan: sees set -o errexit -o pipefail"; else fail "pipefail scan: missed the long-option set form"; fi

  # quiet grep has more spellings than -q
  _pf_write grepeq.sh "set -euo pipefail
printf '%s' \"\$v\" $_pf_p grep -E -q needle"
  if [[ "$(_core_pipefail_hits "$_pfd/grepeq.sh")" == 2 ]]; then pass "pipefail scan: catches a separated quiet flag"; else fail "pipefail scan: missed grep -E -q"; fi

  _pf_write grepquiet.sh "set -euo pipefail
printf '%s' \"\$v\" $_pf_p grep --quiet needle"
  if [[ "$(_core_pipefail_hits "$_pfd/grepquiet.sh")" == 2 ]]; then pass "pipefail scan: catches --quiet"; else fail "pipefail scan: missed grep --quiet"; fi

  # awk that merely PRINTS the word exit does not exit early — flagging it would be an
  # invented finding, the other way this gate loses trust
  _pf_write awkstring.sh "set -euo pipefail
printf '%s' \"\$v\" $_pf_p awk '{ print \"exit\" }'"
  if [[ -z "$(_core_pipefail_hits "$_pfd/awkstring.sh")" ]]; then pass "pipefail scan: awk printing the word exit is not a finding"; else fail "pipefail scan: flagged awk that never exits"; fi

  # a file producer is deliberately out of scope (~15 legitimate instances in-tree)
  _pf_write fileproducer.sh 'set -euo pipefail
sed -n "s/^x=//p" "$f" | head -n1'
  if [[ -z "$(_core_pipefail_hits "$_pfd/fileproducer.sh")" ]]; then pass "pipefail scan: a file producer stays out of scope"; else fail "pipefail scan: flagged sed <file> | head"; fi

  # and the gate must not flag the library that defines it
  if [[ -z "$(_core_pipefail_hits "$HERE/scripts/lib/common.sh")" ]]; then pass "pipefail scan: does not flag its own definition"; else fail "pipefail scan: flagged common.sh itself"; fi
fi

# ── leaked-RETURN-trap scanner (scripts/lib/common.sh :: _core_return_trap_hits) ───
# WHY THIS IS TESTED. audit-core.sh §5e is the ONLY gate anywhere that can see this bug.
# The broken line is valid bash, so the lint and syntax sections both pass it; and
# bootstrap-test.yml only ever runs --links-only, so the code where it detonates is executed
# by nothing (#512, #461). A gate that is the sole line of defence, for a bug that has
# already shipped green in two repos, is worth proving fires. Probe-testing it while it was
# written is what found the line-start anchor: the version this repo nearly shipped catches
# ONE of the four broken shapes below, and the one it misses is the likeliest of them.
#
# Both halves are pinned — what it catches AND what it must ignore. The second half is not
# padding. The false-positive class is what gets a gate switched off, and dotfiles-Debian's
# own fix carries three comment lines naming the signal directly above its corrected traps:
# a scanner without the comment filter would red the repo that FIXED the bug.
#
# THE SIGNAL NAME IS ASSEMBLED, NOT WRITTEN LITERALLY — the same move, for the same reason,
# as _pf_p in the pipefail block above. §5e scans this file, and a file whose job is to test
# the banned shape necessarily contains it; the first run flagged eight of its own lines.
# Keeping the literal out of this source is the honest fix: the fixture written to disk is
# byte-identical to the real hazard, so the assertions still exercise the true pattern. An
# inline "allow" marker in the scanner was rejected for the same reason it was there — an
# escape hatch invites silencing a real finding. The assertion MESSAGES are worded around
# it too, which is why none of them says the shape out loud.
if have git; then
  hdr "leaked-RETURN-trap scanner (_core_return_trap_hits)"
  _rtd="$SANDBOX/returntrap"
  mkdir -p "$_rtd"
  _rt_write() { printf '%s\n' "$2" >"$_rtd/$1"; }   # _rt_write <name> <body>
  _rt_s='RETURN'
  # The handler body is a placeholder, not a real cleanup: what is under test is the signal
  # operand and the disarm, so a literal `rm -rf` in a fixture would be risk for no gain.

  # ── the four broken shapes ──
  # The ONE-LINE BODY is first because it is the shape a line-start anchor misses, and it is
  # how this is most often written: the whole helper fits on one line, so the handler does too.
  _rt_write oneline.sh "#!/usr/bin/env bash
f() { trap CLEAN $_rt_s; }"
  if [[ "$(_core_return_trap_hits "$_rtd/oneline.sh")" == 2 ]]; then pass "RETURN scan: catches a one-line function body"; else fail "RETURN scan: missed the one-line function body — is the pattern anchored to line-start again?"; fi

  _rt_write ownline.sh "#!/usr/bin/env bash
f() {
  trap CLEAN $_rt_s
}"
  if [[ "$(_core_return_trap_hits "$_rtd/ownline.sh")" == 3 ]]; then pass "RETURN scan: catches the dotfiles-Debian#2 shape (handler on its own line)"; else fail "RETURN scan: missed the own-line shape"; fi

  # A TRAILING COMMENT must not hide it. This is why the signal is matched as a TOKEN rather
  # than as the last word on the line — anchoring to end-of-line waves this straight through.
  _rt_write trailing.sh "#!/usr/bin/env bash
f() { trap CLEAN $_rt_s  # cleanup
}"
  if [[ "$(_core_return_trap_hits "$_rtd/trailing.sh")" == 2 ]]; then pass "RETURN scan: catches a handler with a trailing comment"; else fail "RETURN scan: missed a trailing comment — is the signal anchored to end-of-line again?"; fi

  # TWO SIGNALS leak in exactly the same way, and here the signal is not the last operand.
  _rt_write multisig.sh "#!/usr/bin/env bash
f() { trap CLEAN $_rt_s EXIT; }"
  if [[ "$(_core_return_trap_hits "$_rtd/multisig.sh")" == 2 ]]; then pass "RETURN scan: catches a second signal after the first"; else fail "RETURN scan: missed the two-signal form"; fi

  # ── what it must NOT flag ──
  # The disarming form is the FIX. Flagging it would punish the cure and leave no way to
  # write a correct one at all.
  _rt_write fixed.sh "#!/usr/bin/env bash
f() { trap \"trap - $_rt_s; CLEAN\" $_rt_s; }"
  if [[ -z "$(_core_return_trap_hits "$_rtd/fixed.sh")" ]]; then pass "RETURN scan: a self-disarming body is not a finding"; else fail "RETURN scan: flagged the disarming fix"; fi

  # Writing ABOUT the hazard must not trip it — this repo now documents it in three places,
  # and so does the fix in dotfiles-Debian.
  _rt_write comment.sh "#!/usr/bin/env bash
# trap CLEAN $_rt_s is the shape this gate exists to catch
f() { trap \"trap - $_rt_s; CLEAN\" $_rt_s; }"
  if [[ -z "$(_core_return_trap_hits "$_rtd/comment.sh")" ]]; then pass "RETURN scan: a comment describing the hazard is not a finding"; else fail "RETURN scan: flagged a comment"; fi

  # Every OTHER signal is fine — only this one has the leaking-slot semantics. An EXIT
  # handler inside a function is ordinary, and this repo uses several.
  _rt_write exitonly.sh '#!/usr/bin/env bash
f() { trap CLEAN EXIT; }'
  if [[ -z "$(_core_return_trap_hits "$_rtd/exitonly.sh")" ]]; then pass "RETURN scan: an EXIT handler is not a finding"; else fail "RETURN scan: flagged an EXIT handler"; fi

  # The word in prose, or as part of a longer identifier, is not a signal operand.
  _rt_write prose.sh "#!/usr/bin/env bash
f() { echo \"check the $_rt_s value\"; }"
  if [[ -z "$(_core_return_trap_hits "$_rtd/prose.sh")" ]]; then pass "RETURN scan: the bare word in prose is not a finding"; else fail "RETURN scan: flagged the word where no handler is armed"; fi

  # and the gate must not flag the library that defines it
  if [[ -z "$(_core_return_trap_hits "$HERE/scripts/lib/common.sh")" ]]; then pass "RETURN scan: does not flag its own definition"; else fail "RETURN scan: flagged common.sh itself"; fi

  # nor THIS SUITE, whose fixtures are the banned shape by construction — the assembly above
  # is what makes that true, and a regression in it must fail HERE rather than in §5e.
  # The whole suite, not just the dispatcher: since #699 the fixtures live in a fragment, and
  # scanning only scripts/test-core.sh would have been a check that could no longer fire.
  _rt_self=""
  for _rt_f in "$HERE/scripts/test-core.sh" "$HERE"/scripts/test/[0-9][0-9]-*.sh; do
    [[ -e "$_rt_f" ]] || continue
    if [[ -n "$(_core_return_trap_hits "$_rt_f")" ]]; then _rt_self="${_rt_self:+$_rt_self }${_rt_f#"$HERE/"}"; fi
  done
  if [[ -z "$_rt_self" ]]; then pass "RETURN scan: does not flag the suite's own fixtures (the signal name stays assembled)"; else fail "RETURN scan: the suite now spells the banned shape literally — keep the name in \$_rt_s: $_rt_self"; fi
  unset _rt_self _rt_f

  # ── SHELLCHECK_OPTS parity across the two workflows that lint the same file ──
  # lint-call.yml and bootstrap-test.yml BOTH run shellcheck over an OS repo's bootstrap.sh.
  # For a long time only the first set the fleet's curated exclusions, so the same commit
  # could be green in `lint` and red in `bootstrap` — with an error naming a rule the fleet
  # had documented as excluded (#517). SC2088 is the one that fires, because a bootstrap's
  # user-facing strings are full of ~/.zshrc and ~/.config.
  #
  # It is not shareable state: GitHub has no way to import an env value from one workflow
  # into another, so the value is authored twice by necessity. This is the assertion that
  # keeps the two copies equal — the same shape as the os-repos.txt fallback-array check
  # above, and for the same reason: a literal duplicated across files with nothing comparing
  # them is exactly the N-way drift the reusable workflows exist to end.
  # The multi-value test below is `== *$'\n'*`, NOT `$(wc -l) != 1`: BSD wc pads its count
  # with leading spaces ("       1"), so the string compare is true on macOS and false on
  # Linux — this assertion shipped with exactly that bug and the macOS leg caught it. A
  # bash-native newline test has no such divergence, and needs no external tool.
  _sco_of() { # _sco_of <workflow> → the SHELLCHECK_OPTS value, or empty
    sed -n 's/^[[:space:]]*SHELLCHECK_OPTS:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" 2>/dev/null | sort -u
  }
  _sco_lc="$(_sco_of "$HERE/.github/workflows/lint-call.yml")"
  _sco_bt="$(_sco_of "$HERE/.github/workflows/bootstrap-test.yml")"
  if [[ -z "$_sco_lc" || -z "$_sco_bt" ]]; then
    fail "SHELLCHECK_OPTS parity: could not read the value from both workflows (lint-call='$_sco_lc' bootstrap-test='$_sco_bt')"
  elif [[ "$_sco_lc" == *$'\n'* ]]; then
    fail "SHELLCHECK_OPTS parity: lint-call.yml carries more than one distinct value — the steps disagree with each other"
  elif [[ "$_sco_lc" != "$_sco_bt" ]]; then
    fail "SHELLCHECK_OPTS parity: lint-call.yml has '$_sco_lc' but bootstrap-test.yml has '$_sco_bt' — the same bootstrap.sh would be green in one gate and red in the other (#517)"
  else
    pass "SHELLCHECK_OPTS parity: both gates that lint bootstrap.sh use the same exclusions"
  fi

  # ── ONE definition, and it must stay one ──
  # The fleet-facing leg in .github/workflows/lint-call.yml gates the nine caller repos with
  # the SAME rule §5e applies here. It first shipped with the pattern inlined (#552) while
  # the helper landed separately (#555), so for one release the rule existed twice and only
  # the copy below was tested — the fleet-facing half was the one that could drift unseen.
  # These two assertions are what stop that from recurring: the workflow must CALL the
  # helper, and must not carry a second copy of the expression. Cheap, and it fails in the
  # suite rather than the next time someone corrects one copy and not the other.
  _rt_wf="$HERE/.github/workflows/lint-call.yml"
  if [[ ! -r "$_rt_wf" ]]; then
    skip "RETURN scan: lint-call.yml not readable (partial checkout?)"
  elif ! grep -q '_core_return_trap_hits' "$_rt_wf"; then
    fail "RETURN scan: lint-call.yml no longer calls _core_return_trap_hits — the fleet gate has drifted off the shared definition"
  elif grep -qE 'trap\[\[:space:\]\]' "$_rt_wf"; then
    fail "RETURN scan: lint-call.yml carries its own copy of the pattern — call the helper instead, so the rule has one definition"
  else
    pass "RETURN scan: the fleet gate (lint-call.yml) calls the helper rather than copying the pattern"
  fi
fi
# ── Core-owned block scanner (scripts/lib/common.sh :: _core_owned_block_hits) ─────
# WHY THIS IS TESTED. This scanner is the ONLY thing standing between the fleet and the
# defect it was written for coming straight back. Seven OS repos each hand-maintained the
# direnv/gh/uv/ty init block and six the WSL probe; by the time anyone counted, the copies
# had drifted into THREE variants of one block, and two repos silently lacked half the
# tools. Nothing could see it: the duplicate is valid zsh, `zsh -n` passes it, the shell
# keeps working, and audit-core.sh §5c looks the other way down the boundary (OS-specifics
# leaking INTO Core, not portable logic stranded outside it). It was found by reading two
# layers side by side, which is not a gate (#449).
#
# Both halves are pinned, as in the RETURN block above, and for the same reason: the
# false-positive class is what gets a gate switched off. Here that risk is sharper than
# usual, because an OS layer's legitimate business — hooking a tool that exists on ONE OS —
# looks superficially identical to the thing being banned. Every ignore case below is a
# shape a real OS layer either has today or will write tomorrow.
#
# NOTE the inverted self-reference rule vs the two scanners above: those must not flag their
# own definition or this file. THIS one must not flag common.sh (the pattern table spells the
# kernel version file as a character class precisely so it doesn't) but MUST flag Core's two
# owning modules — that is the inverse assertion at the end of this block, and it is the
# only direction that catches Core quietly losing a block the fleet has been made to delete.
hdr "Core-owned block scanner (_core_owned_block_hits)"
_obd="$SANDBOX/ownedblock"
mkdir -p "$_obd"
_ob_write() { printf '%s\n' "$2" >"$_obd/$1"; }   # _ob_write <name> <body>
# _ob_is <file> <expected>  — the scanner's full output must equal <expected> exactly.
# Exact, not "contains": a rule that fires on the right line for the wrong reason, or fires
# twice, is a finding the operator has to triage, and this gate's whole value is that its
# output is a delete-list.
_ob_is() { # _ob_is <label> <file> <expected>
  local got
  got="$(_core_owned_block_hits "$_obd/$2")"
  if [[ "$got" == "$3" ]]; then
    pass "owned-block scan: $1"
  else
    fail "owned-block scan: $1 (got '${got//$'\n'/, }', want '${3//$'\n'/, }')"
  fi
}

# ── what it must catch: the cached arm, one fixture per rule ──
_ob_write direnv.zsh "# os layer
_cache_eval direnv direnv hook zsh"
_ob_is "the direnv hook is a finding" direnv.zsh "2:direnv-hook"

_ob_write gh.zsh "# os layer
_cache_eval gh gh completion -s zsh"
_ob_is "the gh completion is a finding" gh.zsh "2:gh-completion"

_ob_write uv.zsh "# os layer
_cache_eval uv uv generate-shell-completion zsh"
_ob_is "the uv completion is a finding" uv.zsh "2:uv-completion"

_ob_write ty.zsh "# os layer
_cache_eval ty ty generate-shell-completion zsh"
_ob_is "the ty completion is a finding" ty.zsh "2:ty-completion"

# THE EAGER FALLBACK ARM, which is half of every real copy. All seven os/*.zsh wrapped the
# block in `if (( \$+functions[_cache_eval] )); then … else <bare eval> fi`, so a scanner
# that only knew the _cache_eval shape would wave through the else-branch of every one of
# them and report the repo clean after a half-deletion.
_ob_write fallback.zsh "# os layer
command -v gh >/dev/null 2>&1 && eval \"\$(gh completion -s zsh 2>/dev/null)\""
_ob_is "the bare-eval fallback arm is a finding too" fallback.zsh "2:gh-completion"

# ── what it must catch: the WSL probe, both halves ──
_ob_write wslproc.zsh "# os layer
elif [[ -r /proc/version ]]; then"
_ob_is "reading the kernel version file is a finding" wslproc.zsh "2:wsl-detect"

_ob_write wslvar.zsh "# os layer
_IS_WSL=0"
_ob_is "the hand-rolled _IS_WSL flag is a finding" wslvar.zsh "2:wsl-detect"

# ── the whole block, as an OS layer actually writes it ──
# Sorted numerically, deduped, one entry per offending line: this output IS the delete-list
# the fan-out PRs work from, so its shape is part of the contract.
_ob_write full.zsh "# ── Detect WSL once ──
_IS_WSL=0
if [[ -n \"\${WSL_DISTRO_NAME:-}\" ]]; then
  _IS_WSL=1
elif [[ -r /proc/version ]]; then
  _pv=\"\$(</proc/version)\"; _pv=\${_pv:l}
  [[ \"\$_pv\" == *microsoft* || \"\$_pv\" == *wsl* ]] && _IS_WSL=1
fi
if (( \$+functions[_cache_eval] )); then
  _cache_eval direnv direnv hook zsh
  _cache_eval gh gh completion -s zsh
else
  command -v direnv >/dev/null 2>&1 && eval \"\$(direnv hook zsh)\"
fi"
_ob_is "a real os-layer block reports every line, sorted and deduped" full.zsh \
  "2:wsl-detect
4:wsl-detect
5:wsl-detect
6:wsl-detect
7:wsl-detect
10:direnv-hook
11:gh-completion
13:direnv-hook"

# ── what it must NOT catch ──
# The pointer comment the fan-out PRs replace the deleted block with. If this fires, the
# gate reds the repo that made the fix — the failure mode that switches a gate off.
_ob_write comment.zsh "# Deleted: direnv hook zsh is Core's now (core/zsh/00-tools.zsh), as is the
# WSL probe (_core_is_wsl); this file read /proc/version itself until #449."
_ob_is "the pointer comment replacing a deleted block is not a finding" comment.zsh ""

# AN OS-ONLY TOOL'S HOOK IS THE OS LAYER'S BUSINESS — the entire point of the band. This is
# the ignore case that matters most: it is the shape the fix's own comment tells authors to
# keep writing, and the one a tool-name-based pattern would have destroyed.
_ob_write osonly.zsh "# os layer
_cache_eval brew brew shellenv
_cache_eval pyenv pyenv init -"
_ob_is "an OS-only tool's own hook is not a finding" osonly.zsh ""

# Using a tool is not registering its completion.
_ob_write verbs.zsh "alias dv=direnv
direnv allow
gh pr create --fill
uv sync"
_ob_is "calling the tools is not a finding" verbs.zsh ""

# Reading the distro NAME is a different use from re-implementing the DETECTION — a prompt
# segment, a window title, a hostname. Only the latter is Core's, which is why the rule keys
# on the version file and the flag rather than on the env var.
_ob_write distroname.zsh "[[ -n \${WSL_DISTRO_NAME:-} ]] && print -r -- \"\$WSL_DISTRO_NAME\""
_ob_is "reading the distro name is not a finding" distroname.zsh ""

# THE FIX ITSELF MUST NEVER BE A FINDING.
_ob_write fixed.zsh "if _core_is_wsl; then
  alias open='explorer.exe'
fi"
_ob_is "calling Core's _core_is_wsl is not a finding" fixed.zsh ""

# and the gate must not flag the library that defines it (see the character-class note there)
if [[ -z "$(_core_owned_block_hits "$HERE/scripts/lib/common.sh")" ]]; then
  pass "owned-block scan: does not flag its own definition"
else
  fail "owned-block scan: flagged common.sh itself — the rule table now spells a pattern it defines"
fi

# ── the INVERSE assertion: Core must still carry what it makes the fleet delete ──
# This is this gate's counterpart to §5e, and the reason there is deliberately no
# audit-core.sh section calling the scanner: Core's own tree matches every pattern, which is
# the point. A gate that forces nine repos to delete a block Core has quietly lost is worse
# than no gate — the niceties simply go silent everywhere at once, with every repo green.
# Keyed on the RULE IDS, not on a list of files: #579 moved the three completion generators
# from 45-plugins.zsh to 00-tools.zsh, and a per-file assertion reported that as Core having
# LOST a block it still carries. What matters is that every rule the fleet is gated on is
# provided somewhere in Core, so ask exactly that.
_ob_core_ok=1
_ob_hits="$(for _obf in "$HERE"/zsh/*.zsh; do _core_owned_block_hits "$_obf"; done | sed 's/^[0-9]*://' | sort -u)"
for _obr in direnv-hook gh-completion uv-completion ty-completion wsl-detect; do
  grep -qx "$_obr" <<<"$_ob_hits" || { _ob_core_ok=0; printf '    missing Core-side block: %s\n' "$_obr" >&2; }
done
unset _ob_hits _obr
if (( _ob_core_ok )); then
  pass "owned-block scan: Core still carries the blocks it makes the fleet drop"
else
  fail "owned-block scan: Core no longer carries a block the fleet is gated on — the fleet gate is now making nine repos delete a feature nobody provides"
fi
unset _ob_core_ok _obf

# ── the fleet itself, when it is checked out ──
# The direct regression signal, and the only assertion here that watches the real defect
# rather than a fixture. SKIPs when a sibling clone is absent (CI, a partial checkout), the
# same graceful degradation scripts/fleet-drift.sh uses — a missing repo is not a failure.
# EXPECTED TO SKIP OR FAIL until the fan-out lands: the copies are still there on the day
# Core takes the blocks over, which is exactly why the lint leg ships advisory (#449).
_ob_fleet_seen=0 _ob_fleet_dirty=""
# Siblings of this repo, the layout every fleet script assumes (see scripts/sync-core.sh).
_ob_root="$(cd "$HERE/.." && pwd)"
# The fleet comes from scripts/os-repos.txt via load_os_repos (#669). It used to be a
# hand-typed list of SEVEN of the nine names right here — dotfiles-Defense and
# dotfiles-Offense were silently never scanned, in the very file that asserted the other
# three copies of this list agreed. A fourth copy nobody was policing is the argument for
# having no copies.
_ob_fleet=1
load_os_repos || _ob_fleet=0
# Guarded rather than looped-over-empty: "${CORE_OS_REPOS[@]}" on an empty array trips
# `set -u` on bash <= 4.3, and this file runs on macOS's bash 3.2.
if ((_ob_fleet)); then
  for _obr in "${CORE_OS_REPOS[@]}"; do
    _obp="$(resolve_repo_dir "$_ob_root" "$_obr" 2>/dev/null)" || continue
    [[ -n "$_obp" && -d "$_obp" ]] || continue
    for _obf in "$_obp"/os/*.zsh; do
      [[ -f "$_obf" ]] || continue
      _ob_fleet_seen=$((_ob_fleet_seen + 1))
      [[ -z "$(_core_owned_block_hits "$_obf")" ]] || _ob_fleet_dirty="$_ob_fleet_dirty ${_obr}"
    done
  done
fi
if (( ! _ob_fleet )); then
  skip "owned-block scan: $CORE_OS_REPOS_ERR (fleet regression check)"
elif (( _ob_fleet_seen == 0 )); then
  skip "owned-block scan: no sibling OS repo checked out (fleet regression check)"
elif [[ -n "$_ob_fleet_dirty" ]]; then
  skip "owned-block scan: fan-out pending —$_ob_fleet_dirty still carry a Core-owned block (#449 step 7)"
else
  pass "owned-block scan: all $_ob_fleet_seen checked-out os layers are free of Core-owned blocks"
fi
unset _ob_fleet_seen _ob_fleet_dirty _ob_fleet _ob_root _obr _obp _obf

# ── ONE definition, and it must stay one (same contract as the RETURN leg above) ──
_ob_wf="$HERE/.github/workflows/lint-call.yml"
if [[ ! -r "$_ob_wf" ]]; then
  skip "owned-block scan: lint-call.yml not readable (partial checkout?)"
elif ! grep -q '_core_owned_block_hits' "$_ob_wf"; then
  fail "owned-block scan: lint-call.yml no longer calls _core_owned_block_hits — the fleet gate has drifted off the shared definition"
elif grep -qE 'generate-shell-completion|hook\[\[:space:\]\]' "$_ob_wf"; then
  fail "owned-block scan: lint-call.yml carries its own copy of the patterns — call the helper instead, so the rule has one definition"
else
  pass "owned-block scan: the fleet gate (lint-call.yml) calls the helper rather than copying the patterns"
fi
unset _ob_wf


# ── the HAVE_* contract scanner (scripts/lib/common.sh :: _core_have_read_hits) ──
# Drives the fleet half of audit-core.sh §5j. Extracted from that section and pinned here
# because the review of #694 made the fair point that a gate verified only by hand regresses
# unnoticed — the same reason _core_conflict_marker_hits below is fixture-driven.
#
# The scanner answers ONE question: which HAVE_* names does this repo READ that it does not
# itself SET? Every case below is a way an earlier draft got that wrong, and the ones that
# matter most are the SILENT directions — a scanner that over-reports reds a clean fleet and
# gets turned off, but one that under-reports passes forever while the contract rots.
hdr "HAVE_* contract scanner (_core_have_read_hits)"
_hvs="$SANDBOX/havescan"
_hv_repo() { # _hv_repo <name> — fresh fixture repo, echoes its path
  rm -rf "${_hvs:?}/$1"
  mkdir -p "$_hvs/$1/os" "$_hvs/$1/core/zsh"
  # Every fixture carries a vendored core/ that both sets AND reads the whole flag set. If
  # the prune ever stops working, EVERY case below goes silent at once — which is the point:
  # an OS repo's core/ is a copy of the file being checked against, so counting it would
  # make the entire direction vacuous rather than merely wrong on one case.
  printf '_have rg && HAVE_RG=1\n_have atuin && HAVE_ATUIN=1\n[[ -n ${HAVE_RG:-} ]] && :\n' \
    >"$_hvs/$1/core/zsh/00-tools.zsh"
  printf '%s\n' "$_hvs/$1"
}
_hv_is() { # _hv_is <label> <repo> <expected, space-separated>
  local got
  got="$(_core_have_read_hits "$_hvs/$2" | sort | tr '\n' ' ')"
  got="${got% }"
  if [[ "$got" == "$3" ]]; then
    pass "HAVE_* scan: $1"
  else
    fail "HAVE_* scan: $1 (got '$got', want '$3')"
  fi
}

# ── what it must catch ──
d="$(_hv_repo reads)"; printf '[[ -n ${HAVE_RG:-} ]] && alias grep=rg\n' >"$d/os/x.zsh"
_hv_is "a read of a flag the repo does not set is reported" reads "HAVE_RG"

d="$(_hv_repo bare)"; printf 'x=$HAVE_ATUIN\n' >"$d/os/x.zsh"
_hv_is "the braceless \$HAVE_X form is a read too" bare "HAVE_ATUIN"

d="$(_hv_repo insh)"; printf '[[ -n "${HAVE_JQ:-}" ]] && echo hi\n' >"$d/bootstrap.sh"
_hv_is "a .sh outside os/ is scanned too (see the asymmetry note in the helper)" insh "HAVE_JQ"

# The zsh EXISTENCE form. `(( ${+NAME} ))` asks whether a parameter is set without caring
# what it holds — this tree uses it for exactly that (`(( ${+_CORE_PROBED} ))`,
# 30-functions.zsh) — and an OS layer gating that way slipped past the first matcher, which
# demanded `HAVE_` immediately after the brace. A silent miss in direction 2, so it is pinned.
d="$(_hv_repo plusform)"; printf '(( ${+HAVE_RG} )) && :\n' >"$d/os/x.zsh"
_hv_is "the zsh \${+HAVE_X} existence form is a read" plusform "HAVE_RG"

# ...and the PARENTHESISED flag forms, which the `+` fix alone still missed. `${(t)NAME}` is
# zsh asking for a parameter type and `${(P)NAME}` for an indirect read; 00-tools.zsh uses
# the first and 30-functions.zsh the second, so neither is exotic here.
d="$(_hv_repo flagform)"; printf '[[ ${(t)HAVE_RG} == scalar* ]] && :\n' >"$d/os/x.zsh"
_hv_is "a parenthesised expansion flag (\${(t)HAVE_X}) is a read" flagform "HAVE_RG"

# ...and the form with NO sigil at all. Inside `(( ))` a shell resolves a bare name as a
# parameter, so `(( HAVE_RG ))` is an ordinary read that no sigil pattern can see. This is
# house style for booleans here — `((UPDATE_CHECK_ENABLED))` in 60-update.zsh,
# `((CORE_CNF_ENABLED))` in 30-functions.zsh — so an OS layer writing it this way is
# following the local idiom, not being clever, and it passed direction 2 in silence.
d="$(_hv_repo arith)"; printf '(( HAVE_RG )) && :\n' >"$d/os/x.zsh"
_hv_is "a bare arithmetic read (( HAVE_X )) is a read" arith "HAVE_RG"

# ── what it must stay SILENT on ──
# The vendored core/ prune, asserted on its own: this repo reads HAVE_RG only from core/.
d="$(_hv_repo vendored)"
_hv_is "a read inside vendored core/ is pruned, not reported" vendored ""

# Ownership: a layer that assigns a name owns it. This is the role-repo case — dotfiles-
# Offense and -Defense each define ~20 of their own, and reporting those would red a clean
# fleet on arrival, which is how a gate gets disabled.
d="$(_hv_repo owns)"; printf '_have zeek && HAVE_ZEEK=1\n[[ -n ${HAVE_ZEEK:-} ]] && :\n' >"$d/os/x.zsh"
_hv_is "a flag the repo sets itself is not reported" owns ""

# Ownership across FILES, not just within one: Defense sets HAVE_JQ in defense.zsh and reads
# it from helpers in the same tree.
d="$(_hv_repo owns2)"; printf '_have jq && HAVE_JQ=1\n' >"$d/os/a.zsh"
printf '[[ -n ${HAVE_JQ:-} ]] && :\n' >"$d/os/b.zsh"
_hv_is "ownership is repo-wide, not per-file" owns2 ""

# THE COMMENT CASES. Bare names in prose are why this matches on the sigil at all: the real
# dotfiles-Offense line that a bare-name scanner mis-flagged mentions three Core flags.
d="$(_hv_repo comment)"; printf '# Detect-only, like Core HAVE_ASTGREP / HAVE_JNV / HAVE_SHELLCHECK.\n' >"$d/os/x.zsh"
_hv_is "a bare flag name in a comment is not a read" comment ""

d="$(_hv_repo sigilcomment)"; printf '# gated on ${HAVE_LNAV:-} upstream\n' >"$d/os/x.zsh"
_hv_is "a SIGIL form inside a whole-line comment is not a read either" sigilcomment ""

# The one that makes the scanner too LENIENT rather than too noisy, and so the one worth
# pinning hardest: a commented-out assignment must NOT confer ownership, or it would
# suppress the real read on the next line.
d="$(_hv_repo commentedset)"
printf '# HAVE_RG=1   # historical note\n[[ -n ${HAVE_RG:-} ]] && :\n' >"$d/os/x.zsh"
_hv_is "a commented-out assignment does not confer ownership" commentedset "HAVE_RG"

# Same false-negative shape, different disguise: a bootstrap that GENERATES a zsh fragment
# writes the assignment as data. Counting it as ownership would silently pass the real read
# on the next line. The match refuses a name abutting a quote, which is what separates them.
d="$(_hv_repo printfset)"
printf '%s\n' "printf 'HAVE_RG=1\\n' > frag.zsh" '[[ -n ${HAVE_RG:-} ]] && :' >"$d/os/x.zsh"
_hv_is "an assignment inside a quoted string does not confer ownership" printfset "HAVE_RG"

# The INVERSE of that, and the direction whose error reds a clean repo: a bootstrap that
# generates a fragment containing a READ. Inside single quotes the sigil never expands, so
# the line is literal text and reporting it would be a false finding.
d="$(_hv_repo printfread)"
printf '%s\n' "printf '\${HAVE_RG:-}\\n' > frag.zsh" >"$d/os/gen.sh"
_hv_is "a read inside a SINGLE-quoted string is literal text, not a read" printfread ""

# ...and the regression guard that makes the rule above safe to have. A DOUBLE quote does
# not suppress expansion, and `[[ -n "${HAVE_X:-}" ]]` is the commonest real form in the
# fleet — rejecting on any quote rather than the single one would have made it invisible.
d="$(_hv_repo dquoteread)"
printf '[[ -n "${HAVE_RG:-}" ]] && :\n' >"$d/os/x.zsh"
_hv_is "a DOUBLE-quoted read is still a read" dquoteread "HAVE_RG"

# An absent or empty repo is not a finding — CI checks out this repo alone, and §5j treats a
# missing sibling as an environment SKIP rather than letting it read as "reads nothing".
_hv_is "a repo with no shell files at all reports nothing" nosuchrepo ""
unset d

# ── leftover conflict markers (scripts/lib/common.sh :: _core_conflict_marker_hits) ──
# Drives audit-core.sh §5h. Two properties have to hold at once and they pull against each
# other, which is why both directions are pinned rather than just the firing one:
#   • it FIRES on every marker that names a ref, including a lone base marker with no
#     partners — the exact shape bcdd7dd (#650) committed and that nothing noticed
#   • it stays SILENT on a bare row of seven `=`, which is also a setext H1 underline that
#     .markdownlint.jsonc permits (MD003 defaults to `consistent`, not `atx`)
#
# THE FIRST VERSION OF THIS MATCHER FAILED OPEN and these fixtures are what caught it. `|` is
# ERE's alternation operator, so a literal row of seven pipes in the pattern read as eight
# EMPTY alternatives and the scanner reported NOTHING, on any input — a green gate that
# checked nothing. A firing-only test would have gone green on the broken version too,
# because the broken version was silent on the clean fixtures as well.
#
# ── TOOLS_OPTIN vs the matrix (common.sh :: _core_tools_optin_hits) ──────────
# #890. The rule is exact and the fleet already satisfies it, so these fixtures drive the
# DIRECTIONS a real repo can drift in — an undeclared column, a stale declaration, and the
# two shapes the parser must not get wrong.
hdr "TOOLS_OPTIN vs matrix (_core_tools_optin_hits)"
_to_="$SANDBOX/toolsoptin"
_to_setup() { # _to_setup <optin-line-or-empty> — a fleet with one openSUSE repo in it
  rm -rf "$_to_"; mkdir -p "$_to_/dotfiles-openSUSE/os"
  git -C "$_to_/dotfiles-openSUSE" init -q >/dev/null 2>&1
  : >"$_to_/dotfiles-openSUSE/os/opensuse.capabilities"
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" >"$_to_/dotfiles-openSUSE/os/opensuse.capabilities"
}
_to_is() { # _to_is <label> <want-hits>
  local got n=0
  got="$(_core_tools_optin_hits "$HERE" "$_to_")"
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | grep -c .)"
  if [[ "$n" == "$2" ]]; then pass "TOOLS_OPTIN: $1"; else fail "TOOLS_OPTIN: $1 (got $n, want $2) — $got"; fi
}

# THE REAL DEFECT, as it existed: openSUSE's column marks uv²¹ and the repo declared nothing,
# so core-doctor counted uv EXPECTED and rendered a false ✗ on every box.
_to_setup ""
_to_is "a column with a cell-level mark and NO declaration is a finding" 1

# ...and the message must name the fix, not just the fault.
_to_setup ""
if _core_tools_optin_hits "$HERE" "$_to_" | grep -q 'Declare: TOOLS_OPTIN='; then
  pass "TOOLS_OPTIN: the finding spells out the declaration to add"
else
  fail "TOOLS_OPTIN: the finding did not name the fix"
fi

# THE CORRECT DECLARATION: Core's row-level nine PLUS this column's cell-level uv. A declared
# list REPLACES the default, which is why the nine are repeated rather than just the delta.
_to_setup 'TOOLS_OPTIN=lnav hyperfine watchexec shellcheck shfmt ouch git-absorb jnv gping uv'
_to_is "the correct declaration is clean" 0

# ORDER IS NOT THE CONTRACT — the set is. The fleet writes these in table order; a repo that
# sorts them differently is not drifting, and a gate that said so would be noise.
_to_setup 'TOOLS_OPTIN=uv gping jnv git-absorb ouch shfmt shellcheck watchexec hyperfine lnav'
_to_is "a reordered but identical set is clean" 0

# DECLARING ONLY THE DELTA is the trap the rule exists to state: it would trade one false ✗
# for nine, because a declared list replaces the default rather than adding to it.
_to_setup 'TOOLS_OPTIN=uv'
_to_is "declaring only the delta is a finding, not a shortcut" 1

# A STALE DECLARATION — the shape a repo drifts into after the matrix gains a mark.
_to_setup 'TOOLS_OPTIN=lnav hyperfine watchexec shellcheck shfmt ouch git-absorb jnv gping'
_to_is "a declaration missing the column's new mark is a finding" 1

# THE PARSER TRAPS, both real. Footnote 21 carries a coverage table of its OWN whose first
# column is backticked tool names (`gping`¹⁹ at PORTING-MATRIX.md:653); a scan that stays
# armed past the package table sweeps it in and invents a flag. And `jujutsu (jj)` is an
# alias while `op (1Password)` is a description, so a blanket parenthetical rule would look
# for a tool called 1Password. Both are asserted through the EXPECTED SET the helper builds.
_to_setup ""
if _core_tools_optin_hits "$HERE" "$_to_" | grep -q '`gping`'; then
  fail "TOOLS_OPTIN: footnote 21's own table leaked into the derived set (the :653 trap)"
else
  pass "TOOLS_OPTIN: footnote 21's own coverage table does not widen the derived set"
fi
_to_setup ""
if _core_tools_optin_hits "$HERE" "$_to_" | grep -qE '1Password|jujutsu'; then
  fail "TOOLS_OPTIN: a parenthesised Tool cell was read as a binary name"
else
  pass 'TOOLS_OPTIN: op (1Password) is not mistaken for a tool called 1Password'
fi

# AN ABSENT REPO IS SILENCE, NEVER AGREEMENT — the audit turns that into an environment skip.
rm -rf "$_to_"; mkdir -p "$_to_"
_to_is "a fleet with no covered repo checked out yields no verdict" 0

rm -rf "$_to_"
unset _to_
unset -f _to_setup _to_is
# ── the vendoring-claim scanner (common.sh :: _core_vendoring_claim_hits) ────
# #891, the gate #774 asked for. Every fixture below is REAL TEXT — the positives lifted
# from the repos #774 corrected, the negatives from what replaced them plus the two
# dotfiles-Offense lines that are correct and must survive. Invented fixtures would prove
# the regex matches itself; these prove it separates the CLAIM from the TOKEN.
hdr "vendoring-claim scanner (_core_vendoring_claim_hits)"
_vcs="$SANDBOX/vendorclaim"
_vcs_write() { # _vcs_write <line...> — a fresh one-file fixture repo
  rm -rf "$_vcs"; mkdir -p "$_vcs"
  git -C "$_vcs" init -q >/dev/null 2>&1 || return 1
  printf '%s\n' "$@" >"$_vcs/CLAUDE.md"
  git -C "$_vcs" add -A >/dev/null 2>&1
}
_vcs_count() { # _vcs_count <label> <want>
  local got n=0
  got="$(_core_vendoring_claim_hits "$_vcs")"
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | grep -c .)"
  if [[ "$n" == "$2" ]]; then pass "vendoring claim: $1"; else fail "vendoring claim: $1 (got $n, want $2)"; fi
}

if ! git --version >/dev/null 2>&1; then
  skip_env "vendoring-claim scanner (git unavailable — the helper enumerates through git ls-files)"
else
  _vcs_write '`core/` is a **vendored `git subtree` copy of [dotfiles-core](https://github.com/dotgibson/dotfiles-core)** — it'
  _vcs_count "the CLAUDE.md opener seven repos carried is a finding" 1

  _vcs_write '- `core/` is a vendored subtree of dotfiles-core — never edit it here; fix'
  _vcs_count "dotfiles-Defense's softer 'a vendored subtree of' is also a finding" 1

  _vcs_write '`core/` is a vendored subtree and is **already present** in a clone — there is no'
  _vcs_count "the README phrasing #774 never looked at is a finding" 1

  # This one argues the gate's own position; reddening it would teach the next author to
  # falsify a true sentence — the failure mode #770's §9m records for repo counts.
  _vcs_write 'filtered subset of upstream, which `git subtree pull` cannot produce). It is also no'
  _vcs_count "the sentence saying a subtree pull CANNOT produce core/ is not a finding" 0

  # offensive/companion genuinely IS a subtree of htpx, and sync-companion.sh really pulls it.
  # `core/` appears late in this line, AFTER `subtree` — which is what the ordered match uses
  # to tell the two apart, with no allowlist to maintain.
  _vcs_write '- `offensive/companion` — **a vendored `git subtree` of [dotgibson/htpx](https://github.com/dotgibson/htpx)** (provenance in `companion.lock`). **Same rule as `core/`: do not hand-edit the vendored tree** — it is overwritten on the next sync.'
  _vcs_count "the htpx companion subtree, a DIFFERENT prefix, is not a finding" 0

  _vcs_write '`core/` is a **vendored copy of [dotfiles-core](https://github.com/dotgibson/dotfiles-core)** — it' \
    'The sync is a **pinned fetch plus `git read-tree --prefix=core/`**, with `core.lock`' \
    'recording the commit — **not** `git subtree` (dotgibson/dotfiles-core#587). That distinction' \
    'has teeth: `git subtree pull` moves `core/` without moving `core.lock`, and `core-integrity`' \
    'then reports the tree as **TAMPERED**.'
  _vcs_count "#774's replacement text is clean (the gate does not red its own fix)" 0

  # THE VENDORED COPY IS PRUNED. An OS repo's core/ is a copy of the repo being checked
  # against, so counting it would report every repo for Core's own prose.
  _vcs_write 'nothing to see here'
  mkdir -p "$_vcs/core"
  printf '%s\n' '`core/` is a **vendored `git subtree` copy of upstream** — it' >"$_vcs/core/VENDORING.md"
  git -C "$_vcs" add -A >/dev/null 2>&1
  _vcs_count "a claim inside the VENDORED core/ is pruned, not attributed to the repo" 0

  # NON-MARKDOWN IS OUT OF SCOPE: new-os-repo.sh's one-time `git subtree add` is still live
  # (#668's own note), and a scanner reading .sh would report the scaffold for working.
  _vcs_write 'nothing to see here'
  printf '%s\n' 'git subtree add --prefix=core "$remote" "$ref" --squash' >"$_vcs/scaffold.sh"
  git -C "$_vcs" add -A >/dev/null 2>&1
  _vcs_count "a live subtree add in a shell script is out of scope" 0

  _vcs_write 'nothing to see here'
  printf '%s\n' '`core/` is a vendored subtree of dotfiles-core' >"$_vcs/scratch.md"
  _vcs_count "an UNTRACKED markdown file is not judged" 0
fi
rm -rf "$_vcs"
unset _vcs
unset -f _vcs_write _vcs_count

# Fixtures are BUILT, never typed: every marker below is assembled with printf, so this file
# does not itself contain the thing it tests. It is tracked, §5h scans every tracked file, and
# a literal fixture here would make the gate report its own test suite. They are written into
# $SANDBOX, which is untracked, so the scanner never sees them at all — that is also why §5h
# needs no allowlist.
hdr "conflict-marker scanner (_core_conflict_marker_hits)"
_cmd_="$SANDBOX/conflictmarker"
mkdir -p "$_cmd_"
_cm_open="$(printf '<%.0s' 1 2 3 4 5 6 7)"
_cm_base="$(printf '|%.0s' 1 2 3 4 5 6 7)"
_cm_close="$(printf '>%.0s' 1 2 3 4 5 6 7)"
_cm_sep="$(printf '=%.0s' 1 2 3 4 5 6 7)"
_cm_write() { printf '%s\n' "$2" >"$_cmd_/$1"; }   # _cm_write <name> <body>
# _cm_is <label> <file> <expected> — the scanner's full output must equal <expected> exactly.
# Exact, not "contains": the line numbers ARE the report an operator acts on.
_cm_is() { # _cm_is <label> <file> <expected>
  local got
  got="$(_core_conflict_marker_hits "$_cmd_/$2")"
  if [[ "$got" == "$3" ]]; then
    pass "conflict-marker scan: $1"
  else
    fail "conflict-marker scan: $1 (got '${got//$'\n'/, }', want '${3//$'\n'/, }')"
  fi
}

# ── what it must catch ──
_cm_write lonebase.md "## [Unreleased]
$_cm_base parent of fcb0308 (feat(audit): extend the adoption audit (#623))"
_cm_is "a lone base marker is a finding (the #650 shape)" lonebase.md "2"

_cm_write open.txt "a
$_cm_open HEAD"
_cm_is "an open marker is a finding" open.txt "2"

_cm_write close.txt "a
$_cm_close 6fe44bd (some commit subject)"
_cm_is "a close marker is a finding" close.txt "2"

# The separator counts ONLY alongside an unambiguous marker — here it has one, so all four
# lines report. This is the whole conflict as git would leave it under zdiff3.
_cm_write full.txt "a
$_cm_open HEAD
ours
$_cm_base parent of abc1234 (subject)
base
$_cm_sep
theirs
$_cm_close abc1234 (subject)"
_cm_is "a whole zdiff3 conflict reports all four marker lines" full.txt "2
4
6
8"

# ── what it must NOT catch ──
# A setext H1 underline of exactly seven `=`. MD003 defaults to `consistent`, so a document
# that uses setext throughout is valid house style — reddening it would be a false alarm on
# correct markdown, and the gate would get switched off.
_cm_write setext.md "Some Heading
$_cm_sep

body text"
_cm_is "a bare separator alone is NOT a finding (setext underline)" setext.md ""

_cm_write clean.md "## [Unreleased]

### Fixed

- something"
_cm_is "a clean file is silent" clean.md ""

# Column 0 is what git keys on, so it is what the scanner keys on — and indenting is the
# documented escape for a doc that must SHOW a marker.
_cm_write indented.md "Example of a conflict:

    $_cm_open HEAD"
_cm_is "an indented marker is NOT a finding (the documented escape)" indented.md ""

# The self-reference guard, asserted rather than assumed: the matcher lives in a tracked file
# that §5h scans, so if it ever stops assembling its patterns from fragments it reports itself
# and the audit goes permanently red. Same class as the obfuscated `/proc/versio[n]` in
# _core_owned_block_hits, and cheaper to assert than to rediscover.
if [[ -z "$(_core_conflict_marker_hits "$HERE/scripts/lib/common.sh")" ]]; then
  pass "conflict-marker scan: the matcher does not report itself"
else fail "conflict-marker scan: common.sh reports itself — the patterns stopped being assembled from fragments"; fi
# Same widening as the RETURN guard above: the suite is the dispatcher PLUS every fragment,
# and the printf-assembled fixtures are spread across them (#699).
_cm_self=""
for _cm_f in "$HERE/scripts/test-core.sh" "$HERE"/scripts/test/[0-9][0-9]-*.sh; do
  [[ -e "$_cm_f" ]] || continue
  if [[ -n "$(_core_conflict_marker_hits "$_cm_f")" ]]; then _cm_self="${_cm_self:+$_cm_self }${_cm_f#"$HERE/"}"; fi
done
if [[ -z "$_cm_self" ]]; then
  pass "conflict-marker scan: the suite does not report itself"
else fail "conflict-marker scan: the suite reports itself ($_cm_self) — a fixture was typed literally instead of built with printf"; fi
unset _cm_self _cm_f

# ── routine reference scanner (scripts/lib/common.sh :: _core_claude_ref_hits) ─
# WHY THIS IS TESTED. audit-core.sh §1b is the backstop for a defect that shipped and was
# then reported wrong twice: #661 wired /tool-scout to read .claude/tool-decisions.md and
# never tracked the file, because .gitignore's `.claude/*` negations are per-DIRECTORY. The
# gate's value is entirely in what it EXTRACTS — §1b decides existence and trackedness from
# git, which no fixture can stand in for, so the scanner is the half that can be pinned
# here. Driven on fixtures for the same reason the digest below is: making the real gate
# fail means un-tracking a file mid-audit, and CI cannot repeat that.
#
# The line numbers are load-bearing, not decoration: §1b prints `<src>:<line> names <path>`
# and that citation is the whole repair instruction. So these assert exact output.
hdr "routine reference scanner (_core_claude_ref_hits)"
_crd="$SANDBOX/clauderef"
mkdir -p "$_crd"
_cr_bt="$(printf '\140')"
_cr_write() { printf '%s\n' "$2" >"$_crd/$1"; } # _cr_write <name> <body>
_cr_is() {                                      # _cr_is <label> <file> <expected>
  local got
  got="$(_core_claude_ref_hits "$_crd/$2")"
  if [[ "$got" == "$3" ]]; then
    pass "routine reference scan: $1"
  else
    fail "routine reference scan: $1 (got '${got//$'\n'/, }', want '${3//$'\n'/, }')"
  fi
}

# ── what it must catch ──
# The real shape, verbatim from .claude/commands/tool-scout.md — a code span in a bullet.
_cr_write bullet.md "Those five describe what Core has. One more describes what it turned down:

- ${_cr_bt}.claude/tool-decisions.md${_cr_bt} — tools considered and declined."
_cr_is "a backticked path in a bullet is reported with its line" bullet.md "3:.claude/tool-decisions.md"

_cr_write two.md "read ${_cr_bt}.claude/tool-decisions.md${_cr_bt} first
then ${_cr_bt}.claude/agents/tool-scout.md${_cr_bt} too"
_cr_is "every reference reports, one per line" two.md "1:.claude/tool-decisions.md
2:.claude/agents/tool-scout.md"

# Two on ONE line. grep -o emits both with the same line number, which is what the operator
# needs — the citation points at the line, and a line can make two claims.
_cr_write same.md "both ${_cr_bt}.claude/a.md${_cr_bt} and ${_cr_bt}.claude/b.md${_cr_bt} are read"
_cr_is "two references on one line both report" same.md "1:.claude/a.md
1:.claude/b.md"

# A citation carries a line number; the FILE is still the claim being made.
_cr_write cite.md "see ${_cr_bt}.claude/commands/tool-scout.md:164${_cr_bt} for the wording"
_cr_is "a trailing :NN is stripped — a citation names a file, not a line" cite.md "1:.claude/commands/tool-scout.md"

# ── what it must NOT catch ──
# A pattern describes a SET. Resolving it would mean inventing a semantics the prose does
# not have, and the first false positive is what gets a gate switched off (the §5f argument).
_cr_write glob.md "the routines live in ${_cr_bt}.claude/commands/*.md${_cr_bt}"
_cr_is "a glob is NOT a file claim" glob.md ""

_cr_write dir.md "everything under ${_cr_bt}.claude/agents/${_cr_bt} is shared"
_cr_is "a directory is NOT a file claim" dir.md ""

# Prose that merely says the word is not asserting a path exists. Requiring the code span
# is what keeps this gate keyed on "this exact file" rather than on any mention of .claude.
_cr_write prose.md "The .claude/tool-decisions.md ledger is worth reading."
_cr_is "an unbackticked mention is NOT a finding" prose.md ""

_cr_write other.md "read ${_cr_bt}PORTING-MATRIX.md${_cr_bt} and ${_cr_bt}zsh/00-tools.zsh${_cr_bt}"
_cr_is "paths outside .claude/ are out of scope" other.md ""

_cr_is "a missing file is silent, not an error" nosuchfile.md ""

# NO SELF-REFERENCE GUARD HERE, unlike the conflict-marker matcher above, and the
# difference is real rather than an omission. That scanner reads EVERY tracked file, so
# common.sh is inside its own scan set and a literally-typed pattern would redden the audit
# permanently. This one only ever opens .claude/{commands,agents}/*.md — common.sh is not in
# the set, and the backticked `.claude/…` examples in its own comments are documentation of
# the contract, not claims about files. Asserting silence here would forbid the scanner from
# being explained in prose, which is a worse trade than it looks.
#
# What IS worth pinning is the scanner against the real routine docs rather than fixtures.
# Every assertion above is synthetic; this one fails if the house form ever moves away from
# a code span (an autolink, a markdown link, a bare path), which would leave §1b silently
# scanning for a shape nobody writes any more — a gate that passes because it found nothing
# to check, which is the exact failure #700 was.
_cr_live="$(_core_claude_ref_hits "$HERE/.claude/commands/tool-scout.md")"
if [[ "$_cr_live" == *":.claude/tool-decisions.md" ]]; then
  pass "routine reference scan: the live routine doc still parses (tool-scout.md names the ledger)"
else fail "routine reference scan: .claude/commands/tool-scout.md yielded '${_cr_live//$'\n'/, }' — the routines stopped writing paths as code spans, so §1b is scanning for a shape that no longer exists"; fi

# ── .gitignore: crash dumps vs the core.* files this repo actually tracks ─────
# The rule is `core.[0-9]*`, and the whole point is what it does NOT match. `core.*` is the
# obvious spelling and is wrong twice: this repo tracks core.manifest and core.version, every
# OS repo also tracks core.lock, and in those repos bare `core` is the vendored Core
# DIRECTORY. Gitignore does not untrack a file that is already tracked, so the damage from
# "simplifying" this would not show up here — it would show up the next time someone adds a
# core.<something> and git silently declines to see it. That is #700's failure mode exactly,
# which is why this is pinned rather than left to a comment.
#
# Asserted against the REAL .gitignore via git check-ignore, not a fixture: the question is
# what this repo's own rules do, and a fixture would only test a copy of them.
#
# --no-index is load-bearing. Without it check-ignore consults the INDEX first and never calls
# an already-tracked path ignored — so the core.manifest and core.version cases would pass
# under `core.*` as readily as under the correct rule, and this block would be three tautologies
# guarding nothing. Verified: with the rule mutated to `core.*`, all three go red only with
# --no-index; without it, only core.lock (untracked HERE) catches the mistake.
if have git && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  hdr ".gitignore: crash dumps, without swallowing core.* files"
  _gi_is() { # _gi_is <path> <ignored|tracked-able> <why>
    local want="$2" got
    if git -C "$HERE" check-ignore -q --no-index "$1" 2>/dev/null; then got="ignored"; else got="tracked-able"; fi
    if [[ "$got" == "$want" ]]; then
      pass "gitignore: $1 is $want ($3)"
    else
      fail "gitignore: $1 is $got, want $want ($3)"
    fi
  }
  _gi_is "core.1234"      ignored      "a crash dump is noise"
  _gi_is "core.99999"     ignored      "any pid width"
  _gi_is "core.manifest"  tracked-able "TRACKED here — core.* would have hidden it"
  _gi_is "core.version"   tracked-able "TRACKED here — core.* would have hidden it"
  _gi_is "core.lock"      tracked-able "TRACKED in every OS repo; keep the rule fleet-safe"
  # A bare `mise.lock` line would have no slash, so it would match at EVERY depth. mise's
  # lockfile is meant to be COMMITTED (mise/config.toml sets lockfile = true and its comment
  # says so), and the file lands next to that config — so this is the path that matters.
  _gi_is "mise/mise.lock" tracked-able "lockfile = true wants this COMMITTED, not ignored"
  unset -f _gi_is
else
  skip "gitignore crash-dump rule (not a git checkout)"
fi

# ── the bash 3.2 floor scanner (scripts/lib/common.sh :: _core_bash4_hits) ────
# WHY THIS IS TESTED. audit-core.sh §5k is the only gate that can see a bash 4+ construct
# before the macos-latest leg does, and everything else looks green: the constructs are valid
# SYNTAX, so §3's `bash -n` passes; shellcheck does not model bash versions, so §5 passes;
# and the whole suite runs on bash 5 here, so §10 passes. #871 shipped exactly that way and
# cost a seventeen-minute matrix leg to find out.
#
# BOTH DIRECTIONS, and the second half is the important one. A gate that fires on prose ABOUT
# the rule would be reverted the day it landed — and this repo has TEN scripts whose comments
# name these constructs, plus one fragment (65-functions.sh) carrying ten legitimate zsh
# `typeset -gA` lines embedded as single-quoted literals for a zsh child. Both were live
# false positives during development; both are pinned below.
#
# THE NEEDLES ARE ASSEMBLED, NOT WRITTEN LITERALLY — the same move as _rt_s above, for the
# same reason: §5k scans this file, and a file whose job is to test the banned shapes
# necessarily contains them. The fixtures written to disk are byte-identical to the real
# constructs, so the assertions exercise the true patterns; only this source stays clean.
if have git; then
  hdr "bash 3.2 floor scanner (_core_bash4_hits)"
  _b4d="$SANDBOX/bash4"
  mkdir -p "$_b4d"
  _b4_write() { printf '%s\n' "$2" >"$_b4d/$1"; }   # _b4_write <name> <body>
  _b4_mf='map''file'                                 # the array-reading builtin
  _b4_ra='read''array'                               # ...and its second spelling
  _b4_at='-A'                                        # the associative-array flag
  _b4_amp='&>''>'                                    # append-both-streams
  _b4_ff=';;''&'                                     # case fallthrough
  _b4_lc='${v'',,}'                                  # case-conversion expansion
  _b4_pipe='|''&'                                    # pipe-both-streams
  _b4_wn='wait ''-n'                                 # wait -n (bash 4.3, not 4.0)
  # _core_bash4_hits prints "<line>:<what>"; the arms below assert the LINE, so a scanner
  # that fires on the wrong line (an off-by-one in the comment strip) is still a failure.
  _b4_line() { _core_bash4_hits "$1" | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//'; }

  # ── the five shapes it must catch ──
  # The array-reading builtin first: it is the one #871 actually shipped.
  _b4_write mapf.sh "#!/usr/bin/env bash
$_b4_mf -t arr <input"
  if [[ "$(_b4_line "$_b4d/mapf.sh")" == 2 ]]; then pass "bash 3.2 scan: catches the array-reading builtin (the #871 shape)"; else fail "bash 3.2 scan: missed the array-reading builtin"; fi

  _b4_write reada.sh "#!/usr/bin/env bash
$_b4_ra -t arr <input"
  if [[ "$(_b4_line "$_b4d/reada.sh")" == 2 ]]; then pass "bash 3.2 scan: catches its second spelling"; else fail "bash 3.2 scan: missed the second spelling of the array-reading builtin"; fi

  _b4_write assoc.sh "#!/usr/bin/env bash
declare $_b4_at seen
f() { local $_b4_at inner; }"
  if [[ "$(_b4_line "$_b4d/assoc.sh")" == "2 3" ]]; then pass "bash 3.2 scan: catches associative arrays in both declare and local"; else fail "bash 3.2 scan: missed an associative array — got '$(_b4_line "$_b4d/assoc.sh")'"; fi

  _b4_write conv.sh "#!/usr/bin/env bash
x=\"$_b4_lc\""
  if [[ "$(_b4_line "$_b4d/conv.sh")" == 2 ]]; then pass "bash 3.2 scan: catches the case-conversion expansion"; else fail "bash 3.2 scan: missed the case-conversion expansion"; fi

  # This one fails SILENTLY on 3.2 — it parses as a control operator and BACKGROUNDS the
  # command — so it is the shape least likely to be noticed without a gate.
  _b4_write redir.sh "#!/usr/bin/env bash
run_it $_b4_amp log"
  if [[ "$(_b4_line "$_b4d/redir.sh")" == 2 ]]; then pass "bash 3.2 scan: catches append-both-streams (the one that fails silently)"; else fail "bash 3.2 scan: missed append-both-streams"; fi

  _b4_write fall.sh "#!/usr/bin/env bash
case \$x in a) : $_b4_ff b) : ;; esac"
  if [[ "$(_b4_line "$_b4d/fall.sh")" == 2 ]]; then pass "bash 3.2 scan: catches case fallthrough"; else fail "bash 3.2 scan: missed case fallthrough"; fi

  _b4_write pipeboth.sh "#!/usr/bin/env bash
make build $_b4_pipe tee log"
  if [[ "$(_b4_line "$_b4d/pipeboth.sh")" == 2 ]]; then pass "bash 3.2 scan: catches pipe-both-streams"; else fail "bash 3.2 scan: missed pipe-both-streams"; fi

  # bash 4.3, not 4.0, and the OTHER silent one: 3.2's `wait` ignores the flag and waits for
  # ALL jobs, so a bounded parallel loop quietly becomes a serial barrier. sync-core.sh's
  # prefetch uses batched waits precisely to avoid it (PORTABILITY.md §1).
  _b4_write waitn.sh "#!/usr/bin/env bash
$_b4_wn"
  if [[ "$(_b4_line "$_b4d/waitn.sh")" == 2 ]]; then pass "bash 3.2 scan: catches the bounded-wait flag (bash 4.3)"; else fail "bash 3.2 scan: missed the bounded-wait flag"; fi

  # ── what it must NOT flag ──
  # Prose about the rule. Ten scripts in this repo do exactly this, so a scanner without the
  # comment strip reds its own documentation.
  _b4_write prose.sh "#!/usr/bin/env bash
# Read loop, NOT mapfile — mapfile is bash 4+, and declare $_b4_at, $_b4_lc and $_b4_amp too.
while IFS= read -r l; do arr=(\"\${arr[@]}\" \"\$l\"); done <input"
  if [[ -z "$(_core_bash4_hits "$_b4d/prose.sh")" ]]; then pass "bash 3.2 scan: prose ABOUT the rule is not a finding"; else fail "bash 3.2 scan: flagged a comment documenting the rule — it would red ten scripts here"; fi

  # The zsh spelling. scripts/test/65-functions.sh carries ten of these as single-quoted zsh
  # literals for a zsh CHILD, and zsh has had associative arrays forever. No textual scan can
  # tell that from bash, so `typeset` is deliberately out of the needle (common.sh says so).
  _b4_write zshspell.sh "#!/usr/bin/env bash
ucheck 'zsh child' 'typeset -gA _CORE_PROBED=(jq 1)'"
  if [[ -z "$(_core_bash4_hits "$_b4d/zshspell.sh")" ]]; then pass "bash 3.2 scan: the zsh typeset spelling stays out of scope (embedded zsh is not bash)"; else fail "bash 3.2 scan: flagged embedded zsh — 65-functions.sh has ten such lines"; fi

  # Characters that merely resemble the constructs. Without word/adjacency anchoring these
  # read as hits, and a gate that fires on an echo is one nobody keeps.
  _b4_write lookalike.sh "#!/usr/bin/env bash
echo \"a & b >> c\"
run_it >>log 2>&1
case \$x in a) : ;; b) : ;; esac
grep -A2 pattern file
echo \"\${v}\" | tr 'A-Z' 'a-z'
awk '/^(&&|\\|\\||&)\$/ { print }' file
gsub(/command[ \\t]+-v[ \\t]+[^ \\t;|&)}]+/, \" \", s)
wait \"\$pid\""
  if [[ -z "$(_core_bash4_hits "$_b4d/lookalike.sh")" ]]; then pass "bash 3.2 scan: near-miss spellings are not findings"; else fail "bash 3.2 scan: flagged a look-alike — $(_core_bash4_hits "$_b4d/lookalike.sh" | tr '\n' ' ')"; fi

  # And the two files that define and run the rule. Both necessarily discuss it.
  if [[ -z "$(_core_bash4_hits "$HERE/scripts/lib/common.sh")" ]]; then pass "bash 3.2 scan: does not flag its own definition"; else fail "bash 3.2 scan: flagged common.sh itself"; fi
  if [[ -z "$(_core_bash4_hits "$HERE/scripts/audit-core.sh")" ]]; then pass "bash 3.2 scan: does not flag the gate that calls it"; else fail "bash 3.2 scan: flagged audit-core.sh itself"; fi

  unset -f _b4_write _b4_line
  unset _b4d _b4_mf _b4_ra _b4_at _b4_amp _b4_ff _b4_lc _b4_pipe _b4_wn
else
  skip "bash 3.2 floor scanner (not a git checkout)"
fi
