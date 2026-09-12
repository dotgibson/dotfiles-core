# scripts/test/06-scope-contract.sh
# the --scope truth table (scripts/lib/common.sh :: _set_scope)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# dispatcher's header for why the suite is split this way (#699).
#
# WHY THIS EXISTS. _set_scope decides what a run asserts, and nothing tested it — the one
# function in the tree whose bugs are invisible by construction, because getting it wrong
# makes the suite SMALLER and a smaller suite still reports green. That is the failure this
# repo names everywhere else (the dispatcher refuses an empty glob rather than reporting a
# clean run over zero fragments, for exactly this reason) and the scope parser was the hole
# in it.
#
# It matters more since SCOPE_TOOLING, which is DERIVED rather than parsed: `none` is now
# the only input that turns the cross-cutting bash-tooling fragments off, so a regression
# that quietly widened `none` would silently drop five fragments from every CI docs run and
# from both halves of the --json self-run fixture (#467).
#
# ALWAYS RUNS, and it is not gated on anything: it is pure parameter arithmetic with no
# subprocesses, and a gate on the thing that computes gates is a circular argument.
#
# EVERY CASE RUNS IN A SUBSHELL. _set_scope assigns the live SCOPE_* globals this very run
# is using, so calling it here without one would re-scope the suite mid-flight — the
# fragments after this one would then honour whatever the last case happened to set.
hdr "--scope truth table (_set_scope)"

# Snapshot the live scope so the last assertion can prove the subshelling held.
_scp_live="$SCOPE_SHELL $SCOPE_NVIM $SCOPE_ATUIN $SCOPE_TOOLING"

# → "<shell> <nvim> <atuin> <tooling>". stderr is dropped: the fail-safe arms deliberately
# warn there, and those warnings are asserted separately below.
_scp() { # _scp <scope-string>
  (
    _set_scope "$1"
    printf '%s %s %s %s\n' "$SCOPE_SHELL" "$SCOPE_NVIM" "$SCOPE_ATUIN" "$SCOPE_TOOLING"
  ) 2>/dev/null
}

_scp_is() { # _scp_is <label> <scope-string> <want>
  local got
  got="$(_scp "$2")"
  if [[ "$got" == "$3" ]]; then
    pass "scope '$2' → $3 ($1)"
  else
    fail "scope '$2' → got '$got', want '$3' ($1)"
  fi
}

#         label                              scope          shell nvim atuin tooling
_scp_is "the minimal run, and the only one that drops tooling" none "0 0 0 0"
_scp_is "one area still carries the cross-cutting tooling" shell "1 0 0 1"
_scp_is "…and so does nvim alone" nvim "0 1 0 1"
_scp_is "…and atuin alone" atuin "0 0 1 1"
_scp_is "two areas" "shell,nvim" "1 1 0 1"
_scp_is "all" all "1 1 1 1"
_scp_is "full is all's synonym" full "1 1 1 1"
# `none` is a no-op token, not a subtractive one — CI builds the list by appending, so a
# stray `none` beside a real area must not cancel it.
_scp_is "none beside an area does not cancel it" "none,shell" "1 0 0 1"

# The two fail-safe arms. Both must widen to EVERYTHING, tooling included — that is what
# makes SCOPE_TOOLING safe to derive rather than parse: it inherits the fail-safe for free.
_scp_is "an unknown token fails SAFE, not quiet" "banana" "1 1 1 1"
_scp_is "an empty scope fails SAFE" "" "1 1 1 1"

# …and they must SAY so. A fail-safe that widens silently teaches nobody that their scope
# was wrong, and the typo survives into the next run.
for _scp_bad in banana ""; do
  if [[ -n "$( (_set_scope "$_scp_bad") 2>&1 >/dev/null )" ]]; then
    pass "scope '${_scp_bad:-<empty>}' warns on stderr as well as widening"
  else
    fail "scope '${_scp_bad:-<empty>}' widened to full silently — the typo is invisible"
  fi
done

# The live run must be unharmed by the eleven calls above: every one was subshelled.
if [[ "$SCOPE_SHELL $SCOPE_NVIM $SCOPE_ATUIN $SCOPE_TOOLING" == "$_scp_live" ]]; then
  pass "the truth-table cases did not re-scope the run they are part of"
else
  fail "this fragment changed the live scope: was '$_scp_live', now '$SCOPE_SHELL $SCOPE_NVIM $SCOPE_ATUIN $SCOPE_TOOLING'"
fi

unset -f _scp _scp_is
unset _scp_bad _scp_live
