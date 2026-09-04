# scripts/test/56-fleet-vocabulary.sh
# Makefile vocabulary register + test floor (scripts/fleet-vocabulary.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the Makefile vocabulary register + test floor (scripts/fleet-vocabulary.sh) ───────
# Nine repos, nine dialects (#691): the register exists so a target spelled `bootstrap-dry`
# instead of `dry-run` is a visible cell rather than the next contributor's confusion. These
# drive the real script against a fake fleet root, one throwaway sibling per case, and pin
# the two facts that make the register a contract: an ALIAS does not satisfy a verb, and
# the test floor has no waiver line.
hdr "Makefile vocabulary register (fleet-vocabulary.sh)"
_fv_root="$SANDBOX/fleet-vocab"
_fv_reset() { rm -rf "$_fv_root"; mkdir -p "$_fv_root"; }
_fv_repo() { # _fv_repo <repo> [Makefile-body] — a fake sibling clone; no body means no Makefile
  mkdir -p "$_fv_root/$1/.git"
  [[ $# -ge 2 ]] && printf '%b' "$2" >"$_fv_root/$1/Makefile"
  return 0
}
_fv_run() { REPOS_ROOT="$_fv_root" "$HERE/scripts/fleet-vocabulary.sh" "$@" 2>&1; }
_fv_ci() { # _fv_ci <repo> <workflow-line> — one workflow that carries the given line
  mkdir -p "$_fv_root/$1/.github/workflows"
  printf 'on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: %s\n' "$2" >"$_fv_root/$1/.github/workflows/ci.yml"
}
# shellcheck disable=SC2317,SC2329  # reached through the eval in _fv_floor, which shellcheck cannot see
_fv_wf() { # _fv_wf <repo> <relative-path-under-.github/workflows> <printf-body> — a RUNNABLE workflow file
  # A fixture body says only what it is about; the `on:` trigger and each job`s `runs-on:`
  # that make a real workflow runnable are supplied here (a duplicated key is harmless to
  # the lexer). _fv_wf_raw writes the body as given, for fixtures ABOUT those keys.
  mkdir -p "$_fv_root/$1/.github/workflows/$(dirname "$2")"
  printf '%b' "$3" | awk '
    NR == 1 && $0 !~ /^(on|"on"|true):/ && !seen_on { print "on: push"; seen_on = 1 }
    /^on:/ { seen_on = 1 }
    { print }
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z_][A-Za-z0-9_-]*:[ \t]*$/ { print "    runs-on: ubuntu-latest" }
  ' >"$_fv_root/$1/.github/workflows/$2"
}
# shellcheck disable=SC2317,SC2329  # likewise, eval-only
_fv_wf_raw() { # _fv_wf_raw <repo> <path> <printf-body> — the body exactly as given
  mkdir -p "$_fv_root/$1/.github/workflows/$(dirname "$2")"
  printf '%b' "$3" >"$_fv_root/$1/.github/workflows/$2"
}
_fv_suite() { # _fv_suite <repo> [dir=test] — an EXECUTABLE smoke.sh, as a real suite script is
  mkdir -p "$_fv_root/$1/${2:-test}"; printf '#!/bin/sh\nexit 0\n' >"$_fv_root/$1/${2:-test}/smoke.sh"; chmod +x "$_fv_root/$1/${2:-test}/smoke.sh"
}
# Every canonical verb, as a rule at column 0, declared .PHONY as a real Makefile must
# (`test:` beside test/ is otherwise "up to date"). `check` shares a rule with a
# prerequisite and `bootstrap-dry` is an alias — both shapes the fleet actually uses.
_fv_all='.PHONY: help lint check dry-run packages-check core-verify test\nhelp:\n\t@true\nlint:\n\t@true\ncheck: lint\n\t@true\ndry-run:\n\t@true\nbootstrap-dry: dry-run\npackages-check:\n\t@true\ncore-verify:\n\t@true\ntest:\n\t@./test/smoke.sh\n'

_fv_reset
if _fv_out="$(_fv_run --check)"; then
  if [[ "$_fv_out" == *"no sibling repo checked out"* ]]; then
    pass "vocab: an empty fleet root is an environment notice, exit 0"
  else
    fail "vocab: empty root exited 0 without the no-sibling notice: $_fv_out"
  fi
else
  fail "vocab: an empty fleet root exited non-zero: $_fv_out"
fi

_fv_reset; _fv_repo dotfiles-Fedora "$_fv_all"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then
  pass "vocab: a repo defining every verb with a CI-run test/ passes --check"
else
  fail "vocab: the complete repo did not pass --check: $_fv_out"
fi

# THE ALIAS DOES NOT COUNT. Keep bootstrap-dry, drop dry-run: the cell must go missing.
# $_fv_all is ONE line of printf escapes, so the edits are unanchored substring edits.
_fv_mk="${_fv_all/dry-run:\\n\\t@true\\n/}"
_fv_reset; _fv_repo dotfiles-Arch "${_fv_mk/bootstrap-dry: dry-run/bootstrap-dry:\\n\\t@true}"
_fv_suite dotfiles-Arch; _fv_ci dotfiles-Arch "make test"
_fv_out="$(_fv_run --check)"; rc=$?
if ((rc == 1)) && [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* ]]; then
  pass "vocab: a historical spelling alone (bootstrap-dry, no dry-run) is one missing cell, exit 1"
else
  fail "vocab: bootstrap-dry without dry-run was not reported as missing (rc=$rc): $_fv_out"
fi
row="$(_fv_run | grep -F '`Arch`')"
if [[ "$row" == '| `Arch` | ok | ok | ok | **missing** | ok | ok | ok | ok |' ]]; then
  pass "vocab: the table puts the miss in the dry-run column and nowhere else"
else
  fail "vocab: unexpected Arch row: $row"
fi

# A STUB TARGET OF THE CANONICAL NAME RESOLVES; there is no declaring a verb away.
_fv_mk="${_fv_all/packages-check:\\n\\t@true\\n/packages-check: ## (n\/a)\\n\\t@echo \"packages-check: not applicable\"\\n}"
_fv_reset; _fv_repo dotfiles-Defense "${_fv_mk/core-verify:\\n\\t@true\\n/}"
_fv_suite dotfiles-Defense; _fv_ci dotfiles-Defense "make test"
mkdir -p "$_fv_root/dotfiles-Defense/.github"
printf 'make:core-verify none declarations are not a thing any more\n' >"$_fv_root/dotfiles-Defense/.github/core-gates.txt"
_fv_out="$(_fv_run --check)"; rc=$?
row="$(_fv_run | grep -F '| `Defense` |')"
if ((rc == 1)) && [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* && "$row" == *'| ok | **missing** | ok | ok |' ]]; then
  pass "vocab: a stub \`packages-check:\` resolves; a \`make:core-verify none\` line in core-gates.txt fills nothing"
else
  fail "vocab: stub/declaration handling wrong (rc=$rc): $_fv_out / $row"
fi
if [[ "$(_fv_run)" != *'[^'* ]]; then
  pass "vocab: the register carries no footnotes — every cell is a verdict"
else
  fail "vocab: footnotes reappeared in the register"
fi

_fv_reset; _fv_repo dotfiles-Gentoo; _fv_suite dotfiles-Gentoo; _fv_ci dotfiles-Gentoo "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* && "$_fv_out" == *'**no Makefile**'* ]]; then
  pass "vocab: a repo with no Makefile misses every verb, labelled as such"
else
  fail "vocab: no-Makefile case: $_fv_out"
fi

# A MANDATORY INCLUDE WITH A VARIABLE PATH cannot be resolved and fails closed; an
# optional one is skipped.
_fv_reset; _fv_repo dotfiles-Fedora "INC = missing.mk\\ninclude \$(INC)\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* ]]; then
  pass "vocab: \`include \$(INC)\` (mandatory, unevaluable) voids the Makefile"
else
  fail "vocab: variable mandatory include failed open: $_fv_out"
fi
_fv_reset; _fv_repo dotfiles-Fedora "INC = missing.mk\\n-include \$(INC)\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then
  pass "vocab: \`-include \$(INC)\` (optional, unevaluable) is skipped"
else
  fail "vocab: variable optional include not skipped: $_fv_out"
fi

# A CONTINUED INCLUDE DIRECTIVE is one directive.
_fv_reset; _fv_repo dotfiles-Fedora 'include \\\n  mk/verbs.mk\nlint:\n\t@true\n'
mkdir -p "$_fv_root/dotfiles-Fedora/mk"; printf '%b' "${_fv_all/lint:\\n\\t@true\\n/}" >"$_fv_root/dotfiles-Fedora/mk/verbs.mk"
_fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then
  pass "vocab: \`include \\\` over the path is one directive"
else
  fail "vocab: continued include mishandled: $_fv_out"
fi

# A test: BESIDE test/ WITHOUT .PHONY is a no-op verb even when CI runs the suite by path.
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/.PHONY: help lint check dry-run packages-check core-verify test\\n/}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "bash test/smoke.sh"
_fv_out="$(_fv_run --check)"; rc=$?
row="$(_fv_run | grep -F '| `Fedora` |')"
if ((rc == 1)) && [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* && "$row" == *'| **no-op** | ok |' ]]; then
  pass "vocab: an unphony \`test:\` shadowing test/ is **no-op** even when CI runs the suite by path"
else
  fail "vocab: unphony shadowing test with direct-path CI (rc=$rc): $_fv_out / $row"
fi

# THE CANONICAL test MUST RUN THE SUITE: a phony no-op `test:` beside CI running the
# suite by path meets the floor but not the vocabulary — the cell says **no-op**.
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/test:\\n\\t@.\/test\/smoke.sh/test:\\n\\t@true}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "bash test/smoke.sh"
_fv_out="$(_fv_run --check)"; rc=$?
row="$(_fv_run | grep -F '| `Fedora` |')"
if ((rc == 1)) && [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* && "$_fv_out" == *"0 repo(s) under the test floor"* && "$row" == *'| **no-op** | ok |' ]]; then
  pass "vocab: a no-op \`test:\` is **no-op** in the verb column even when CI runs the suite by path"
else
  fail "vocab: no-op test target handling (rc=$rc): $_fv_out / $row"
fi

# THE INCLUDE NESTING BOUND FAILS CLOSED: a chain deeper than the scanner follows makes
# the Makefile unloadable rather than partially read.
_fv_reset; _fv_repo dotfiles-Fedora "include mk/a.mk\\n${_fv_all}"; mkdir -p "$_fv_root/dotfiles-Fedora/mk"
for pair in a:b b:c c:d d:e; do printf 'include mk/%s.mk\n' "${pair#*:}" >"$_fv_root/dotfiles-Fedora/mk/${pair%%:*}.mk"; done; printf 'deep:\n\t@true\n' >"$_fv_root/dotfiles-Fedora/mk/e.mk"
_fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* ]]; then
  pass "vocab: an include chain past the nesting bound voids the Makefile (fail closed)"
else
  fail "vocab: nesting bound failed open: $_fv_out"
fi

# AN INCLUDE INSIDE A CONDITIONAL follows the condition where it can be decided, and a
# mandatory one under an undecidable condition fails closed.
_fv_reset; _fv_repo dotfiles-Fedora "ifeq (1,1)\\ninclude missing.mk\\nendif\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* ]]; then pass "vocab: a missing mandatory include in an active ifeq branch voids the Makefile"; else fail "vocab: active-branch missing include failed open: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "ifeq (1,0)\\ninclude missing.mk\\nelse\\ninclude mk/verbs.mk\\nendif\\nlint:\\n\\t@true\\n"
mkdir -p "$_fv_root/dotfiles-Fedora/mk"; printf '%b' "${_fv_all/lint:\\n\\t@true\\n/}" >"$_fv_root/dotfiles-Fedora/mk/verbs.mk"
_fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: the else of a false ifeq is the active branch — its include is followed, the other skipped"; else fail "vocab: ifeq/else include handling: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "ifdef CI\\ninclude missing.mk\\nendif\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* ]]; then pass "vocab: a mandatory include under an undecidable ifdef fails closed"; else fail "vocab: undecidable conditional include failed open: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "ifdef CI\\n-include missing.mk\\nendif\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: an optional include under an undecidable ifdef is skipped"; else fail "vocab: undecidable optional include: $_fv_out"; fi

# CHAINED `else ifeq` ARMS are evaluated after only-false arms and dead after a taken one;
# a conditional-looking line inside a define body is text.
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifeq (1,0)\\nx:\\n\\t@true\\nelse ifeq (1,0)\\ndry-run:\\n\\t@true\\nendif\\n"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* ]]; then pass "vocab: a verb under a false \`else ifeq\` arm is missing"; else fail "vocab: false else-ifeq arm counted: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifeq (1,0)\\nx:\\n\\t@true\\nelse ifeq (1,1)\\ndry-run:\\n\\t@true\\nendif\\n"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: a verb under a true \`else ifeq\` arm after a false arm resolves"; else fail "vocab: true else-ifeq arm not counted: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifeq (1,1)\\nx:\\n\\t@true\\nelse ifeq (1,1)\\ndry-run:\\n\\t@true\\nendif\\n"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* ]]; then pass "vocab: an \`else ifeq\` arm after a taken arm is dead"; else fail "vocab: else-ifeq after taken arm counted: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifeq (1,0)\\nx:\\n\\t@true\\nelse ifdef CI\\ndry-run:\\n\\t@true\\nendif\\n"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* ]]; then pass "vocab: an undecidable \`else ifdef\` arm stays missing"; else fail "vocab: undecidable else-ifdef counted: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "define tmpl\\nifeq (1,0)\\nendef\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: a conditional-looking line inside a define body is text"; else fail "vocab: define body mutated the conditional stack: $_fv_out"; fi

# A SPACE-INDENTED RULE is a rule (only a tab makes a recipe), for targets and .PHONY.
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/  dry-run: ; @true\\n}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: a space-indented \`  dry-run: ; @true\` resolves"; else fail "vocab: indented rule missed: $_fv_out"; fi

# NESTED CONDITIONALS ARE A CONJUNCTION: an inactive level makes its contents dead even
# under an undecidable outer one, so a missing mandatory include there is never read.
_fv_reset; _fv_repo dotfiles-Fedora "ifdef CI\\nifeq (1,0)\\ninclude missing.mk\\nendif\\nendif\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: a missing include in a dead inner branch under an undecidable outer one is never read"; else fail "vocab: inactive-under-undecidable folded wrong: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "ifeq (1,1)\\nifdef CI\\ninclude missing.mk\\nendif\\nendif\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* ]]; then pass "vocab: a mandatory include under an undecidable inner branch of an active outer one fails closed"; else fail "vocab: undecidable-under-active folded wrong: $_fv_out"; fi

# A MAKEFILE MAKE REJECTS RESOLVES NOTHING: a stray endif, an unterminated conditional, a
# recipe before any rule, or a line that is not a Makefile line; an expansion line is fine.
for _fv_bad in "endif\\n" "ifeq (1,1)\\n" "\\t@true\\n" "this is not make\\n"; do
  _fv_reset; _fv_repo dotfiles-Fedora "${_fv_bad}${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
  _fv_out="$(_fv_run --check)"
  if [[ "$_fv_out" == *"7 verb x repo cell(s) missing"* ]]; then pass "vocab: a Makefile starting with $(printf '%q' "$_fv_bad") is unloadable — every verb missing"; else fail "vocab: unloadable Makefile ($(printf '%q' "$_fv_bad")) failed open: $_fv_out"; fi
done
unset _fv_bad
_fv_reset; _fv_repo dotfiles-Fedora "\$(info loading)\\nexport CI=1\\n${_fv_all}"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: an expansion line and an export are Makefile lines"; else fail "vocab: valid top-level lines read as unloadable: $_fv_out"; fi

# A RULE IN A STATICALLY ACTIVE BRANCH counts; one under an undecidable condition does not.
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifeq (1,1)\\ndry-run:\\n\\t@true\\nendif\\n"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then pass "vocab: a verb defined inside an active \`ifeq (1,1)\` branch resolves"; else fail "vocab: active-branch rule not counted: $_fv_out"; fi
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifdef CI\\ndry-run:\\n\\t@true\\nendif\\n"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"1 verb x repo cell(s) missing"* ]]; then pass "vocab: a verb defined under an undecidable \`ifdef\` stays missing"; else fail "vocab: undecidable-branch rule counted: $_fv_out"; fi

# AN INCLUDE INSIDE A FALSE CONDITIONAL is not followed: its targets are not appended
# after the endif as if make had read them.
_fv_reset; _fv_repo dotfiles-Fedora 'ifeq (1,0)\ninclude mk/verbs.mk\nendif\nlint:\n\t@true\n'
mkdir -p "$_fv_root/dotfiles-Fedora/mk"; printf '%b' "$_fv_all" >"$_fv_root/dotfiles-Fedora/mk/verbs.mk"
_fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
_fv_out="$(_fv_run --check)"
if [[ "$_fv_out" == *"6 verb x repo cell(s) missing"* ]]; then
  pass "vocab: an include inside a false conditional defines nothing"
else
  fail "vocab: conditional include was followed: $_fv_out"
fi

# A RULE THE SCANNER CANNOT PROVE make defines — inside a conditional or a define body —
# is not counted: the register says "missing" rather than guess.
_fv_reset; _fv_repo dotfiles-Fedora "${_fv_all/dry-run:\\n\\t@true\\n/}ifeq (1,0)\\ndry-run:\\n\\t@true\\nendif\\ndefine tmpl\\npackages-check:\\n\\t@true\\nendef\\n"
_fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
row="$(_fv_run | grep -F '`Fedora`')"
if [[ "$row" == '| `Fedora` | ok | ok | ok | **missing** | ok | ok | ok | ok |' ]]; then
  pass "vocab: a verb defined only inside an inactive \`ifeq (1,0)\` is missing; a define body defines nothing"
else
  fail "vocab: conditional/define handling wrong: $row"
fi

# `make <verb>` RESOLVING is the promise, not where the rule sits: a verb defined in an
# included file counts, and so does a suite target defined there; a missing optional
# include is simply absent.
_fv_reset; _fv_repo dotfiles-Fedora 'include mk/*.mk\n-include local.mk\nlint:\n\t@true\n'
mkdir -p "$_fv_root/dotfiles-Fedora/mk"
printf '%b' "${_fv_all/lint:\\n\\t@true\\n/}" >"$_fv_root/dotfiles-Fedora/mk/verbs.mk"
_fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_out="$(_fv_run --check)" && [[ "$_fv_out" == *"every verb x repo cell resolves"* ]]; then
  pass "vocab: verbs and the suite target defined through a globbed \`include mk/*.mk\` resolve"
else
  fail "vocab: included targets were not seen: $_fv_out"
fi

# THE TEST FLOOR: a directory with content, run from a workflow. Each rung is its own cell.
_fv_floor() { # _fv_floor <label> <want-cell> <setup-commands>
  local label="$1" want="$2" _fv_out
  _fv_reset; _fv_repo dotfiles-Alpine "$_fv_all"
  eval "$3"
  _fv_out="$(_fv_run | grep -F '`Alpine`')"
  if [[ "$_fv_out" == *"| $want |" ]]; then pass "vocab floor: $label → $want"; else fail "vocab floor: $label (want '$want'): $_fv_out"; fi
}
_fv_floor "no test dir" '**no-dir**' true
_fv_floor "an empty tests/ dir" '**empty**' 'mkdir -p "$_fv_root/dotfiles-Alpine/tests"'
_fv_floor "a suite nothing in CI runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine'
_fv_floor "a suite only bootstrap-test/ mentions (boundary)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "./bootstrap-test/run.sh"'
_fv_floor "a suite CI runs via make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "a suite CI runs by path" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash test/smoke.sh"'
# Either directory name is the suite, so a stale empty test/ beside a real tests/ is not `empty`.
_fv_floor "an empty test/ beside a populated, CI-run tests/" 'ok' 'mkdir -p "$_fv_root/dotfiles-Alpine/test"; _fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "bash tests/smoke.sh"'
# A MENTION IS NOT AN EXECUTION. Only a `run:` step counts; a path filter, a comment, a
# file GitHub never loads as a workflow, or a nested directory must all stay not-in-ci.
_fv_floor "a workflow that only path-filters on test/**" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "on:\n  push:\n    paths: [\"test/**\"]\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make lint\n"'
_fv_floor "a run block whose only mention is a comment" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          # make test is run elsewhere\n          make lint  # not test/\n"'
_fv_floor "a notes.txt in the workflows dir" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine notes.txt "make test\n"'
_fv_floor "a yaml in a nested workflows subdirectory" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine old/ci.yml "jobs:\n  t:\n    steps:\n      - run: make test\n"'
_fv_floor "a run: | block that runs make test (.yaml)" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yaml "jobs:\n  t:\n    steps:\n      - name: suite\n        run: |\n          set -e\n          make test\n      - run: echo done\n"'
# A TARGET THAT RUNS THE SUITE COUNTS, whatever it is called: dotfiles-MacBook runs
# `make test-repo` → ./test/test-repo.sh from CI, and the verb column already reports the
# missing `test` alias, so the floor must not report that gap a second time. A same-prefix
# target that does NOT touch the directory is not the suite.
_fv_floor "CI runs a differently-named target whose recipe runs test/" 'ok' '_fv_suite dotfiles-Alpine; printf "test-repo: lint\n\t@./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make test-repo"'
_fv_floor "CI runs a target that inherits the suite through a prerequisite" 'ok' '_fv_suite dotfiles-Alpine; printf "suite-run:\n\t@./test/smoke.sh\nci-all: lint suite-run\n\t@true\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make -j2 ci-all"'
_fv_floor "CI runs a same-prefix target that never touches test/" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "test-report:\n\t@echo report\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make test-report"'
_fv_floor "CI runs one target of a multi-target rule whose shared recipe runs test/" 'ok' '_fv_suite dotfiles-Alpine; printf "smoke test-repo:\n\t@./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make smoke"'
_fv_floor "a suite target whose name is ERE metacharacters (test+coverage)" 'ok' '_fv_suite dotfiles-Alpine; printf "test+coverage:\n\t@./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make test+coverage"'
# A PATH MENTIONED IS NOT A PATH RUN: only command position or an interpreter counts.
_fv_floor "a step that only echoes the test path" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo test/smoke.sh"'
_fv_floor "a step that only lints the test dir" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "shellcheck test/*.sh"'
_fv_floor "a step that runs the suite in command position" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "set -e; ./test/smoke.sh"'
_fv_floor "a step that runs it through an interpreter with flags" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash -e test/smoke.sh"'
_fv_floor "a recipe that only lints test/ does not make its target the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "lint-tests:\n\t@shellcheck test/*.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make lint-tests"'
# `make` IN COMMAND POSITION ONLY: a string that mentions it is not a run, and only the
# POPULATED directory is the suite, so a step running a nonexistent tests/ credits nothing.
_fv_floor "a step that echoes a string mentioning make test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo \"make test is disabled\""'
_fv_floor "a step running tests/ when only test/ is populated" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash tests/missing.sh"'
_fv_floor "a recipe running tests/ when only test/ is populated is not the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "ghost:\n\t@bash tests/missing.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ghost"'
_fv_floor "make test after cd && and under sudo" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "cd . && sudo make test"'
# `test` EARNS ITS PLACE: a test: whose recipe runs nothing is not the suite even under
# the canonical name; `echo make test` is an argument, not a run; a `run` key outside
# steps: is data; and a block-scalar path keeps its indentation and still counts.
_fv_floor "make test whose recipe is @true" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/test:\\n\\t@.\/test\/smoke.sh/test:\\n\\t@true}"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "a step that echoes make test as arguments" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo make test"'
_fv_floor "a job-level env: with a run: key" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    env:\n      run: bash test/smoke.sh\n    steps:\n      - run: make lint\n"'
_fv_floor "a run: | block whose command is an indented ./test/ path" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          set -e\n          ./test/smoke.sh\n"'
# A FOLDED BLOCK IS ONE COMMAND PER PARAGRAPH (YAML joins `>` lines with a space): `echo`
# over `test/smoke.sh` runs `echo test/smoke.sh`, and `make` over `test` runs `make test`.
_fv_floor "a run: > block folding echo over the test path" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: >\n          echo\n          test/smoke.sh\n"'
_fv_floor "a run: > block folding make over test" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: >-\n          make\n          test\n"'
# A DRY-RUN MAKE PRINTS THE RECIPE AND RUNS NOTHING.
_fv_floor "make -n test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -n test"'
_fv_floor "make --dry-run test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make --dry-run test"'
_fv_floor "make -kn test (n inside a short cluster)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -kn test"'
_fv_floor "make -n test then a real make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -n test && make -j2 test"'
# COMMAND POSITION FOR INTERPRETERS TOO, and no-execute modes never count: `echo bash
# test/smoke.sh` is an argument list; `bash -n` and `node --check` only parse; `make -q`
# only asks. An inline recipe (`test: ; ./test/smoke.sh`) is a recipe like any other.
_fv_floor "a step that echoes an interpreter and the test path" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo bash test/smoke.sh"'
_fv_floor "bash -n test/smoke.sh (syntax check only)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash -n test/smoke.sh"'
_fv_floor "node --check test/x.js (parse only)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "node --check test/x.js"'
_fv_floor "make --question test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make --question test"'
_fv_floor "a recipe that only syntax-checks test/ is not the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "syntax:\n\t@bash -n test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make syntax"'
_fv_floor "an inline recipe target (suite: ; ./test/smoke.sh)" 'ok' '_fv_suite dotfiles-Alpine; printf "suite: lint ; ./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite"'
# STEP SEMANTICS: a step-level env: entry named run is data; a quoted scalar is unquoted;
# a folded block over echo / make test is `echo make test`.
_fv_floor "a step-level env: entry named run" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: make lint\n        env:\n          run: bash test/smoke.sh\n"'
_fv_floor "a double-quoted run scalar" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: \"make test\"\n"'
_fv_floor "a run: > block folding echo over make test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: >\n          echo\n          make test\n"'
# QUOTES HIDE OPERATORS: `echo "disabled && make test"` is one echo, in a step or a recipe.
# A full-line comment has no indentation semantics, so it does not end the steps block.
_fv_floor "a step echoing a quoted && make test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo \"disabled && make test\""'
_fv_floor "a recipe echoing a quoted ; ./test/ path is not the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "notice:\n\t@echo \"disabled; ./test/smoke.sh\"\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make notice"'
_fv_floor "a full-line comment at the steps: column before the run step" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: make lint\n    # the suite\n      - run: make test\n"'
_fv_floor "a single-quoted run scalar" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: '"'"'make test'"'"'\n"'
# HOW STEPS ARE ACTUALLY WRITTEN: `steps:` with a trailing comment, `CI=1 make test`,
# `env CI=1 make test`, and a suite target that is not the first operand.
_fv_floor "steps: with a trailing comment" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps: # smoke tests\n      - run: make test\n"'
_fv_floor "CI=1 make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "CI=1 TERM=dumb make test"'
_fv_floor "env CI=1 make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "env CI=1 make test"'
_fv_floor "make lint test (suite target second)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make lint test"'
_fv_floor "CI=1 make -n test is still a dry run" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "CI=1 make -n test"'
# ESCAPES, CONTINUATIONS, OPTION ARGUMENTS, COMMENTS: `\"` does not close a string; a
# trailing backslash joins the next line in a literal block and in a Makefile (rule or
# recipe); `-C test` is a directory, not a goal; a YAML-quoted scalar is unquoted before
# its shell comment is stripped, and a `#` inside quotes is not a comment.
_fv_floor "an escaped quote inside a double-quoted echo" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo \"disabled \\\" && make test\""'
_fv_floor "make \\ continued onto test in a literal block" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          make \\\\\n            test\n"'
_fv_floor "a double-quoted string continued onto a line with && make test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          echo \"disabled \\\\\n          && make test\"\n"'
_fv_floor "make -C test lint (directory operand, not a goal)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -C test lint"'
_fv_floor "a quoted scalar carrying a shell comment" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: \"make test # suite\"\n"'
_fv_floor "a # inside quotes before the real make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo \"value #\"; make test"'
_fv_floor "a rule whose prerequisite list is backslash-continued" 'ok' '_fv_suite dotfiles-Alpine; printf "alltests: \\\\\n  suite-run\nsuite-run:\n\t@./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make alltests"'
_fv_floor "a recipe continued across lines that runs the suite" 'ok' '_fv_suite dotfiles-Alpine; printf "verbose:\n\t@./test/smoke.sh \\\\\n\t  --verbose\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make verbose"'
_fv_floor "a recipe echoing a continued quoted string is not the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "notice:\n\t@echo \"disabled \\\\\n\t&& ./test/smoke.sh\"\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make notice"'
# A GOAL IS A WHOLE OPERAND, and a no-execute flag disqualifies wherever GNU make accepts it.
_fv_floor "make test/report (a different operand)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test/report"'
_fv_floor "make test.coverage" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test.coverage"'
_fv_floor "make test=disabled (a variable, not a goal)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test=disabled lint"'
_fv_floor "make test -n (flag after the goal)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test -n"'
_fv_floor "make test --question" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test --question"'
_fv_floor "make test 2>&1 still counts" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test 2>&1"'
# `cd test && ./smoke.sh` RUNS THE SUITE: a cd into the suite directory carries over the
# rest of the command list, in a recipe or a step; a cd elsewhere does not.
_fv_floor "a recipe that cds into test/ and runs the script" 'ok' '_fv_suite dotfiles-Alpine; printf "insuite:\n\t@cd test && ./smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make insuite"'
_fv_floor "a step that cds into tests/ and runs bash on the script" 'ok' '_fv_suite dotfiles-Alpine tests; cp "$_fv_root/dotfiles-Alpine/tests/smoke.sh" "$_fv_root/dotfiles-Alpine/tests/run.sh"; _fv_ci dotfiles-Alpine "cd tests/ && bash run.sh"'
_fv_floor "a step that cds into test/ and only echoes" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "cd test && echo smoke.sh"'
_fv_floor "a step that cds elsewhere before running a script" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "cd docs && ./smoke.sh"'
# MAKE MODES THAT EXIT BEFORE BUILDING, another Makefile, and options that belong to the
# interpreter: `--help`/`--version` run nothing; `-C tools`/`-f other.mk` build from a
# Makefile whose targets were never inspected; `pwsh -noprofile` and `python -I` RUN.
_fv_floor "make --help test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make --help test"'
_fv_floor "make --version test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make --version test"'
_fv_floor "make -C tools test (another Makefile)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -C tools test"'
_fv_floor "make -f other.mk test (another Makefile)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -f other.mk test"'
_fv_floor "make --directory=tools test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make --directory=tools test"'
_fv_floor "make -I test lint (-I takes a dir, not a goal)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -I test lint"'
_fv_floor "pwsh -noprofile test/smoke.ps1 runs" 'ok' '_fv_suite dotfiles-Alpine; : >"$_fv_root/dotfiles-Alpine/test/smoke.ps1"; _fv_ci dotfiles-Alpine "pwsh -noprofile test/smoke.ps1"'
_fv_floor "python -I test/smoke.py runs (-I is python isolation, not make)" 'ok' '_fv_suite dotfiles-Alpine; : >"$_fv_root/dotfiles-Alpine/test/smoke.py"; _fv_ci dotfiles-Alpine "python3 -I test/smoke.py"'
# THE EFFECTIVE WORKING DIRECTORY: a step in `tools/` runs another Makefile; the job's and
# the workflow's `defaults.run.working-directory` apply unless the step overrides them;
# a step in the suite directory itself runs the suite. And a `cd` anywhere else drops the
# rest of the list rather than judging it against the root.
_fv_floor "run: make test with a step working-directory of tools" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: make test\n        working-directory: tools\n"'
_fv_floor "working-directory before run: in the same step" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - working-directory: tools\n        run: bash test/smoke.sh\n"'
_fv_floor "a job-level defaults.run.working-directory of tools" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    defaults:\n      run:\n        working-directory: tools\n    steps:\n      - run: make test\n"'
_fv_floor "a workflow-level defaults.run.working-directory of tools" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "defaults:\n  run:\n    working-directory: tools\njobs:\n  t:\n    steps:\n      - run: make test\n"'
_fv_floor "a step overriding a job default of tools with ." 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    defaults:\n      run:\n        working-directory: tools\n    steps:\n      - run: make test\n        working-directory: .\n"'
_fv_floor "a step whose working-directory is the suite dir" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: ./smoke.sh\n        working-directory: test\n"'
_fv_floor "a second job does not inherit the first job default" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  a:\n    defaults:\n      run:\n        working-directory: tools\n    steps:\n      - run: make lint\n  b:\n    steps:\n      - run: make test\n"'
_fv_floor "cd tools && make test is another Makefile" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "cd tools && make test"'
# A BLANK OR COMMENT LINE between a rule and its recipe is allowed by make.
_fv_floor "a comment and a blank line between the rule and its recipe" 'ok' '_fv_suite dotfiles-Alpine; printf "suite:\n# why\n\n\t@./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite"'
# OPTIONS THAT TAKE AN OPERAND, statically disabled steps, and the .PHONY gotcha.
_fv_floor "bash -o pipefail test/smoke.sh" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash -o pipefail test/smoke.sh"'
_fv_floor "python3 -m pytest tests/" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m pytest tests/"'
_fv_floor "a step with if: false" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - if: false\n        run: make test\n"'
_fv_floor "a step with if: \${{ false }} after its run" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: make test\n        if: \${{ false }}\n"'
_fv_floor "a step with a runtime if: condition still counts" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - if: github.event_name == '"'"'push'"'"'\n        run: make test\n"'
_fv_floor "test: beside test/ without .PHONY is up to date, not a run" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/.PHONY: help lint check dry-run packages-check core-verify test\\n/}"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor ".PHONY declared after the rule still counts" 'ok' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/.PHONY: help lint check dry-run packages-check core-verify test\\n/}.PHONY: test\\n"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "a suite target named like no path needs no .PHONY" 'ok' '_fv_suite dotfiles-Alpine; printf "suite-run:\n\t@./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite-run"'
# ATTACHED OPERANDS AND TOUCH MODE: `-fother.mk`/`-C../tools` select another Makefile
# just as the spaced forms do; `-t`/`--touch` marks a target updated and runs nothing.
_fv_floor "make -fother.mk test (attached operand)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -fother.mk test"'
_fv_floor "make -C../tools test (attached operand)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -C../tools test"'
_fv_floor "make -t test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -t test"'
_fv_floor "make test --touch" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test --touch"'
_fv_floor "make -kt test (t in a cluster)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -kt test"'
_fv_floor "make -Wfile.txt test still counts (W takes an attached operand)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -Wfile.txt test"'
# KEY ORDER IS NOT SEMANTIC, a disabled job runs no step, and `||` is a failure path.
_fv_floor "a job-level if: false before steps" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    if: false\n    steps:\n      - run: make test\n"'
_fv_floor "a job-level if: false after steps" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: make test\n    if: \${{ false }}\n"'
_fv_floor "a job default working-directory declared after steps" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: make test\n    defaults:\n      run:\n        working-directory: tools\n"'
_fv_floor "a disabled job beside an enabled one that runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  a:\n    if: false\n    steps:\n      - run: make lint\n  b:\n    steps:\n      - run: make test\n"'
_fv_floor "true || make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "true || make test"'
_fv_floor "make test || echo failed still runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make test || echo failed"'
_fv_floor "a .PHONY: test inside a false conditional does not rescue test: beside test/" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/.PHONY: help lint check dry-run packages-check core-verify test\\n/}ifeq (1,0)\\n.PHONY: test\\nendif\\n"; _fv_ci dotfiles-Alpine "make test"'
# A COMMENT AFTER AN INCLUDE is not a path, and a shell -n hides behind an operand option.
_fv_floor "bash -o pipefail -n test/smoke.sh is still a syntax check" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash -o pipefail -n test/smoke.sh"'
# A BARE DIRECTORY OPERAND to a runner is the suite; a bare `test` command is the shell
# utility. And reachability is decided where it can be: after a literal true/false.
_fv_floor "python3 -m pytest tests (no slash)" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m pytest tests"'
_fv_floor "test -f test/smoke.sh is the shell utility" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "test -f test/smoke.sh"'
_fv_floor "false || make test always runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false || make test"'
_fv_floor "false && make test never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false && make test"'
# AN INTERPRETER'S HELP OR VERSION MODE prints and exits without touching the operand.
_fv_floor "python3 --version tests/smoke.py" '**not-in-ci**' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 --version tests/smoke.py"'
_fv_floor "node -v test/x.js" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "node -v test/x.js"'
_fv_floor "bash --help test/smoke.sh" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash --help test/smoke.sh"'
# ATTACHED OPERANDS THAT HAPPEN TO CONTAIN A NO-RUN LETTER run; make inside the suite dir
# reads another Makefile; a shell `if` is followed as far as it is static, across the
# lines of one step.
_fv_floor "make -Otarget test (output sync, runs)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -Otarget test"'
_fv_floor "make -Wnothing test (attached -W operand, runs)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -Wnothing test"'
_fv_floor "cd test && make test reads test/Makefile" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "cd test && make test"'
_fv_floor "if false; then make test; fi (inline)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then make test; fi"'
_fv_floor "if false / make test / fi across literal-block lines" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          if false; then\n            make test\n          fi\n"'
_fv_floor "if true; then make test; fi" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true; then make test; fi"'
_fv_floor "the else of a false if runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then echo skip; else make test; fi"'
_fv_floor "the else of a true if never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true; then echo yes; else make test; fi"'
_fv_floor "a runtime if condition may run its body" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n \"\$CI\" ]; then make test; fi"'
_fv_floor "an elif after a false if may run" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then echo a; elif [ -n \"\$CI\" ]; then make test; fi"'
_fv_floor "a cd on one literal-block line governs the next" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          cd tools\n          make test\n"'
# A COMMENT LINE INSIDE A run: | BLOCK comments out that line only, not the lines after it
# (the real dotfiles-Debian packages step: `# note` above `bash test/check-packages.sh`).
_fv_floor "a full-line comment before the run inside a literal block" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          set -uo pipefail\n          # the suite sources core/lib\n          bash test/smoke.sh | tee /tmp/r.txt\n          rc=\${PIPESTATUS[0]}\n"'
# THE LAST SINGLE-COLON RECIPE WINS (make keeps it and warns); `::` rules are additive; a
# rule with no recipe adds prerequisites only. Includes are spliced where they sit.
_fv_floor "test: redefined later with @true runs only true" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "test:\n\t@true\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "test:: rules are additive" 'ok' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/test:\\n\\t@.\/test\/smoke.sh\\n/test::\\n\\t@.\/test\/smoke.sh\\ntest::\\n\\t@true\\n}"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "a later recipe-less rule keeps the recipe" 'ok' '_fv_suite dotfiles-Alpine; printf "test: lint\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "an included real recipe overridden by a later root @true" '**not-in-ci**' '_fv_suite dotfiles-Alpine; mkdir -p "$_fv_root/dotfiles-Alpine/mk"; printf "test:\n\t@./test/smoke.sh\n" >"$_fv_root/dotfiles-Alpine/mk/real.mk"; _fv_repo dotfiles-Alpine ".PHONY: test\ninclude mk/real.mk\ntest:\n\t@true\n"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "a root @true overridden by a later included real recipe" 'ok' '_fv_suite dotfiles-Alpine; mkdir -p "$_fv_root/dotfiles-Alpine/mk"; printf "test:\n\t@./test/smoke.sh\n" >"$_fv_root/dotfiles-Alpine/mk/real.mk"; _fv_repo dotfiles-Alpine ".PHONY: test\ntest:\n\t@true\ninclude mk/real.mk\n"; _fv_ci dotfiles-Alpine "make test"'
# CODE-STRING MODES take source text, not a file.
_fv_floor "python3 -c test/smoke.py is source text" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "python3 -c test/smoke.py"'
_fv_floor "node -e test/x.js is source text" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "node -e test/x.js"'
_fv_floor "bash -c test/smoke.sh executes its string" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash -c test/smoke.sh"'
# A SKIPPED ARM DOES NOT CHANGE THE LIST STATUS, and `if` state is kept per nesting depth.
_fv_floor "true || false || make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "true || false || make test"'
_fv_floor "false && true || make test always reaches make" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false && true || make test"'
_fv_floor "a false if nested inside a runtime if never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n \"\$CI\" ]; then if false; then make test; fi; fi"'
_fv_floor "a runtime if nested inside a false if never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then if [ -n \"\$CI\" ]; then make test; fi; fi"'
_fv_floor "after a nested block closes, the outer body resumes" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true; then if false; then echo no; fi; make test; fi"'
# BRANCH STATE: an elif/else after a taken branch never runs; `elif false` never runs; an
# else after only false conditions always runs. A compile-only python module runs nothing.
# Only defaults.run.working-directory is a default; a matrix key of that name is data.
_fv_floor "elif after if true never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true; then echo yes; elif false; then make test; fi"'
_fv_floor "elif [runtime] after if true never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true; then echo yes; elif [ -n \"\$CI\" ]; then make test; fi"'
_fv_floor "elif false after if false never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then echo a; elif false; then make test; fi"'
_fv_floor "else after only false conditions runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then echo a; elif false; then echo b; else make test; fi"'
_fv_floor "else after an elif true never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then echo a; elif true; then echo b; else make test; fi"'
_fv_floor "python3 -m compileall tests/ compiles only" '**not-in-ci**' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m compileall tests/"'
_fv_floor "a matrix key named working-directory is not a job default" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    strategy:\n      matrix:\n        working-directory: [linux]\n    steps:\n      - run: make test\n"'
_fv_floor "a job env named working-directory is not a job default" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    env:\n      working-directory: tools\n    steps:\n      - run: make test\n"'
# A FUNCTION BODY RUNS ONLY WHEN THE FUNCTION IS CALLED; a bare group runs where it stands.
_fv_floor "an uncalled function whose body runs make test" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          unused_suite() {\n            make test\n          }\n          make lint\n"'
_fv_floor "a called function whose body runs make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "run_suite() { make test; }; run_suite"'
_fv_floor "a function keyword form, called" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          function suite {\n            make test\n          }\n          suite\n"'
_fv_floor "a bare { } group runs where it stands" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "{ make test; }"'
_fv_floor "a subshell runs where it stands" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "( make test )"'
_fv_floor "a function defined but only mentioned in an echo" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; echo suite"'
# A HEREDOC PAYLOAD IS DATA: `cat <<EOF` … `EOF` writes its lines, never runs them.
_fv_floor "make test inside a quoted heredoc payload" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          cat <<'"'"'EOF'"'"' > notes.txt\n          make test\n          EOF\n          make lint\n"'
_fv_floor "make test inside an unquoted heredoc payload" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          tee notes.txt <<EOF\n          make test\n          EOF\n"'
_fv_floor "make test after the heredoc closes" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          cat <<EOF > notes.txt\n          hello\n          EOF\n          make test\n"'
_fv_floor "a herestring is not a heredoc" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          grep -q x <<<\"y\" || true\n          make test\n"'
# LOOPS AS FAR AS THEY ARE STATIC; a sequence item at the steps: column is a step; an
# explicitly empty inline recipe replaces the earlier one.
_fv_floor "while false; do make test; done never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "while false; do make test; done"'
_fv_floor "until true; do make test; done never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "until true; do make test; done"'
_fv_floor "for t in a b; do make test; done runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for t in a b; do make test; done"'
_fv_floor "make test after a while-false loop closes" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "while false; do echo never; done; make test"'
_fv_floor "steps: with its items at the same indent" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n    - run: make lint\n    - run: make test\n"'
_fv_floor "test: ; (an empty inline recipe) replaces the earlier recipe" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "test: ;\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make test"'
# A BACKSLASH-QUOTED HEREDOC DELIMITER, pytest collection-only, and a function called only
# from an unreachable branch.
_fv_floor "make test inside a <<\\EOF heredoc payload" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          cat <<\\\\EOF > notes.txt\n          make test\n          EOF\n"'
_fv_floor "python3 -m pytest --collect-only tests/ discovers only" '**not-in-ci**' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m pytest --collect-only tests/"'
_fv_floor "python3 -m pytest tests/ --co discovers only" '**not-in-ci**' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m pytest tests/ --co"'
_fv_floor "a function called only inside if false is never invoked" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; if false; then suite; fi"'
_fv_floor "a function called inside if true is invoked" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; if true; then suite; fi"'
# A DIRECTORY IS NOT A SCRIPT (a runner may take one), a python module other than a test
# runner reads and does not run, nothing runs after an unconditional exit, a real `if`
# condition runs, an empty `for` list never iterates, and a single `&` is not `&&`.
_fv_floor "./test/ executes a directory, not a suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "./test/"'
_fv_floor "bash test/ reads a directory, not a suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash test/"'
_fv_floor "bats test/ runs the directory" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bats test/"'
_fv_floor "python3 -m unittest discover tests" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m unittest discover tests"'
_fv_floor "python3 -m tokenize test/smoke.py reads only" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "python3 -m tokenize test/smoke.py"'
_fv_floor "python3 test/smoke.py runs the file" 'ok' '_fv_suite dotfiles-Alpine; : >"$_fv_root/dotfiles-Alpine/test/smoke.py"; _fv_ci dotfiles-Alpine "python3 test/smoke.py"'
_fv_floor "exit 0; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "exit 0; make test"'
_fv_floor "make lint || exit 1; make test still runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make lint || exit 1; make test"'
_fv_floor "an exit inside a block ends only that block" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n \"\$SKIP\" ]; then exit 0; fi; make test"'
_fv_floor "if make test; then … runs the suite as the condition" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if make test; then echo passed; fi"'
_fv_floor "while make test; do break; done runs it at least once" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "while make test; do break; done"'
_fv_floor "for t in; do make test; done never iterates" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for t in; do make test; done"'
_fv_floor "false & make test backgrounds false and runs make" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false & make test"'
# A COMMENT RIGHT AFTER AN OPERATOR, a compound condition folded before the if is judged,
# and a call before its definition.
_fv_floor ":;# disabled && make test is a comment" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine ":;# disabled && make test"'
_fv_floor "if true && false; then make test; fi never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true && false; then make test; fi"'
_fv_floor "if false || true; then make test; fi runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false || true; then make test; fi"'
_fv_floor "if [ -n x ] && false; then make test; fi never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n x ] && false; then make test; fi"'
_fv_floor "if false && make test; then …: the suite arm is unreachable" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false && make test; then echo yes; fi"'
_fv_floor "if true && make test; then …: the suite arm runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true && make test; then echo yes; fi"'
_fv_floor "while true && false; do make test; done never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "while true && false; do make test; done"'
_fv_floor "a call before the definition is not an invocation" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite; suite() { make test; }"'
# AN EXIT IN A STATICALLY TAKEN BRANCH ends the shell; a helper called from a called
# function is invoked.
_fv_floor "if true; then exit 0; fi; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if true; then exit 0; fi; make test"'
_fv_floor "if false; then :; else exit 0; fi; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if false; then :; else exit 0; fi; make test"'
_fv_floor "while true; do exit 0; done; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "while true; do exit 0; done; make test"'
_fv_floor "an exit under a runtime condition ends only its block" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n \"\$CI\" ]; then exit 0; fi; make test"'
_fv_floor "an exit under a literally true test ends the step" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n x ]; then exit 0; fi; make test"'
_fv_floor "a helper called from a called function is invoked" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "helper() { make test; }; suite() { helper; }; suite"'
_fv_floor "a helper called only from an uncalled function is not" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "helper() { make test; }; suite() { helper; }; echo done"'
# A BARE pytest RUNNER, a body judged where it is called, a subshell exit, and a list that
# continues onto the next block line.
_fv_floor "pytest tests/ runs the directory" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "pytest tests/"'
_fv_floor "pytest --collect-only tests/ discovers only" '**not-in-ci**' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "pytest --collect-only tests/"'
_fv_floor "suite() { make test; }; cd tools; suite runs make from tools" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; cd tools; suite"'
_fv_floor "suite() { cd test; }; suite; ./smoke.sh runs inside the suite dir" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { cd test; }; suite; ./smoke.sh"'
_fv_floor "a return in a called helper ends only the helper" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "helper() { return 0; echo never; }; helper; make test"'
_fv_floor "( exit 0 ); make test runs make" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "( exit 0 ); make test"'
_fv_floor "( exit 0; make test ) never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "( exit 0; make test )"'
_fv_floor "false && over make test on the next block line never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          false &&\n            make test\n"'
_fv_floor "true || over make test on the next block line never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          true ||\n            make test\n"'
_fv_floor "false || over make test on the next block line runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          false ||\n            make test\n"'
# ERREXIT: a step runs under bash -e, so a bare literal false ends it; set +e lifts that;
# an arm of && or || is not bare; a Makefile recipe line runs under plain sh -c.
_fv_floor "false; make test never reaches make under bash -e" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false; make test"'
_fv_floor "set +e; false; make test runs make" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "set +e; false; make test"'
_fv_floor "set +e; set -e; false; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "set +e; set -e; false; make test"'
_fv_floor "false || true; make test runs make (false is an arm)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false || true; make test"'
_fv_floor "a recipe with false; make test still runs make (no -e under make)" 'ok' '_fv_suite dotfiles-Alpine; printf "suite2:\n\t@false; ./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite2"'
_fv_floor "a false under a runtime if does not end the step" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n \"\$CI\" ]; then false; fi; make test"'
_fv_floor "a false under a literally true test ends the step" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -n x ]; then false; fi; make test"'
# A CREDITED PATH MUST EXIST, in a step or a recipe; a glob must match; `0`/`null`/`""`
# are false in a GitHub expression.
_fv_floor "bash test/missing.sh beside a real test/smoke.sh" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash test/missing.sh"'
_fv_floor "a recipe running test/missing.sh is not the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "ghost2:\n\t@bash test/missing.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ghost2"'
_fv_floor "bats test/*.bats with no .bats files" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bats test/*.bats"'
_fv_floor "bash test/*.sh matches the real script" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for f in test/*.sh; do bash test/*.sh; done"'
_fv_floor "a path built from a variable is taken on trust" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash test/\$NAME.sh"'
_fv_floor "a step with if: \${{ 0 }} never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - if: \${{ 0 }}\n        run: make test\n"'
_fv_floor "a step with if: null never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - if: null\n        run: make test\n"'
_fv_floor "a job with if: \"\" never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    if: \"\"\n    steps:\n      - run: make test\n"'
# LITERAL TESTS decide; a multi-line function definition is a definition, not a group.
_fv_floor "if [ -z x ]; then make test; fi never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ -z x ]; then make test; fi"'
_fv_floor "if test a = a; then make test; fi runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if test a = a; then make test; fi"'
_fv_floor "if [ a != a ]; then make test; fi never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "if [ a != a ]; then make test; fi"'
_fv_floor "an uncalled multi-line function (brace on its own line)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          suite()\n          {\n            make test\n          }\n          make lint\n"'
_fv_floor "a called multi-line function (brace on its own line)" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          suite()\n          {\n            make test\n          }\n          suite\n"'
# A SPACE-INDENTED .PHONY is a .PHONY.
_fv_floor "a space-indented .PHONY: test still counts" 'ok' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/.PHONY: help lint check dry-run packages-check core-verify test\\n/  .PHONY: test\\n}"; _fv_ci dotfiles-Alpine "make test"'
# QUOTED WORDS are the same words to the program: a quoted script path or make goal runs.
_fv_floor "bash \"test/smoke.sh\" runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "bash \"test/smoke.sh\""'
_fv_floor "make \"test\" builds test" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make \"test\""'
_fv_floor "./'"'"'test/smoke.sh'"'"' runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "./'"'"'test/smoke.sh'"'"'"'
_fv_floor "a recipe running a quoted script path is the suite" 'ok' '_fv_suite dotfiles-Alpine; printf "quoted:\n\t@bash \"test/smoke.sh\"\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make quoted"'
_fv_floor "echo \"make test\" is still an argument" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "echo \"make test\""'
# WHAT THE PATH MUST BE: executed directly it must be an executable regular file; handed to
# an interpreter, a regular file; a runner may take a directory. A subshell keeps its cd
# to itself. `-C .` and `-f Makefile` are the root Makefile.
_fv_floor "./test/plain.sh (not executable) runs nothing" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "exit 0\n" >"$_fv_root/dotfiles-Alpine/test/plain.sh"; _fv_ci dotfiles-Alpine "./test/plain.sh"'
_fv_floor "bash test/plain.sh (not executable) runs it" 'ok' '_fv_suite dotfiles-Alpine; printf "exit 0\n" >"$_fv_root/dotfiles-Alpine/test/plain.sh"; _fv_ci dotfiles-Alpine "bash test/plain.sh"'
_fv_floor "./test/helpers (a directory) runs nothing" '**not-in-ci**' '_fv_suite dotfiles-Alpine; mkdir -p "$_fv_root/dotfiles-Alpine/test/helpers"; _fv_ci dotfiles-Alpine "./test/helpers"'
_fv_floor "bash test/helpers (a directory) runs nothing" '**not-in-ci**' '_fv_suite dotfiles-Alpine; mkdir -p "$_fv_root/dotfiles-Alpine/test/helpers"; _fv_ci dotfiles-Alpine "bash test/helpers"'
_fv_floor "bats test/helpers over an EMPTY directory runs zero tests" '**not-in-ci**' '_fv_suite dotfiles-Alpine; mkdir -p "$_fv_root/dotfiles-Alpine/test/helpers"; _fv_ci dotfiles-Alpine "bats test/helpers"'
_fv_floor "bats test/helpers over a directory holding a file" 'ok' '_fv_suite dotfiles-Alpine; mkdir -p "$_fv_root/dotfiles-Alpine/test/helpers"; : >"$_fv_root/dotfiles-Alpine/test/helpers/a.bats"; _fv_ci dotfiles-Alpine "bats test/helpers"'
_fv_floor "(cd test); ./smoke.sh runs from the root" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "(cd test); ./smoke.sh"'
_fv_floor "(cd test && ./smoke.sh) runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "(cd test && ./smoke.sh)"'
_fv_floor "make -C . test is the root Makefile" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -C . test"'
_fv_floor "make --directory=. test is the root Makefile" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make --directory=. test"'
_fv_floor "make -f Makefile test is the root Makefile" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -f Makefile test"'
_fv_floor "make -C tools test is still another Makefile" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "make -C tools test"'
# exec RUNS ITS OPERAND then the shell is gone; a bare exec continues. The effective
# shell decides whether a step is command text and which of -e / pipefail apply.
_fv_floor "exec make test runs the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "exec make test"'
_fv_floor "exec >log; make test (bare exec continues)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "exec >log; make test"'
_fv_floor "exec echo hi; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "exec echo hi; make test"'
_fv_floor "shell: python with run: make test is not shell" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - shell: python\n        run: make test\n"'
_fv_floor "shell: bash {0} (custom template, no -e): false; make test runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - shell: bash {0}\n        run: false; make test\n"'
_fv_floor "shell: bash (bare) is -eo pipefail: false | true; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - shell: bash\n        run: false | true; make test\n"'
_fv_floor "the default shell has no pipefail: false | true; make test runs" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "false | true; make test"'
_fv_floor "set -o pipefail; false | true; make test never reaches make" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "set -o pipefail; false | true; make test"'
_fv_floor "true | false; make test never reaches make (last command fails)" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "true | false; make test"'
_fv_floor "a job defaults.run.shell of pwsh still runs make test" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    defaults:\n      run:\n        shell: pwsh\n    steps:\n      - run: make test\n"'
_fv_floor "shell: pwsh runs a .ps1 suite script (no execute bit needed)" 'ok' '_fv_suite dotfiles-Alpine; : >"$_fv_root/dotfiles-Alpine/test/smoke.ps1"; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - shell: pwsh\n        run: ./test/smoke.ps1\n"'
_fv_floor "shell: pwsh has no errexit: false; make test runs make" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - shell: pwsh\n        run: false; make test\n"'
_fv_floor "a step shell: bash overrides a job default of pwsh" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    defaults:\n      run:\n        shell: pwsh\n    steps:\n      - run: make test\n        shell: bash\n"'
# A HELPER DEFINED AFTER THE OUTER CALL is not there when the body runs.
_fv_floor "suite() { helper; }; suite; helper() { make test; } fails at helper" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { helper; }; suite; helper() { make test; }"'
_fv_floor "helper defined before the outer call is inlined" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "helper() { make test; }; suite() { helper; }; suite"'
# RUNNABLE AT ALL: no `on:`, or a job without `runs-on:`, runs nothing. Bare pytest
# discovers the suite. `False`/`Null` are false. `$(MAKE) test` in a recipe is an edge.
_fv_floor "a workflow file with no on: trigger is inert" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf_raw dotfiles-Alpine ci.yml "jobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make test\n"'
_fv_floor "a job with no runs-on: is inert" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf_raw dotfiles-Alpine ci.yml "on: push\njobs:\n  t:\n    steps:\n      - run: make test\n"'
_fv_floor "runs-on: declared after steps still counts" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf_raw dotfiles-Alpine ci.yml "on: push\njobs:\n  t:\n    steps:\n      - run: make test\n    runs-on: ubuntu-latest\n"'
_fv_floor "the YAML-1.1 true: spelling of on: is a trigger" 'ok' '_fv_suite dotfiles-Alpine; _fv_wf_raw dotfiles-Alpine ci.yml "true:\n  push:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make test\n"'
_fv_floor "a bare pytest discovers a populated tests/" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "pytest -q"'
_fv_floor "a bare python -m pytest discovers a populated tests/" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "python3 -m pytest"'
_fv_floor "a bare pytest --collect-only still runs nothing" '**not-in-ci**' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "pytest --collect-only"'
_fv_floor "if: False (capitalised) never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    if: False\n    steps:\n      - run: make test\n"'
_fv_floor "if: Null never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - if: Null\n        run: make test\n"'
_fv_floor "ci: \$(MAKE) test reaches the suite" 'ok' '_fv_suite dotfiles-Alpine; printf "ci:\n\t\$(MAKE) test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: ; \${MAKE} -j2 lint test (inline, braces) reaches the suite" 'ok' '_fv_suite dotfiles-Alpine; printf "ci: ; \${MAKE} -j2 lint test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: \$(MAKE) -n test is a dry run" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "ci:\n\t\$(MAKE) -n test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: \$(MAKE) -C tools test is another Makefile" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "ci:\n\t\$(MAKE) -C tools test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
# A LITERAL make IN A RECIPE recurses like $(MAKE).
_fv_floor "ci: ; make test (literal make) reaches the suite" 'ok' '_fv_suite dotfiles-Alpine; printf "ci: ; make test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: make -n test (literal make, dry run) does not" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "ci:\n\tmake -n test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
# A RECURSIVE make IS JUDGED FOR REACHABILITY LIKE ANY COMMAND, and -C . / -f Makefile are
# the same Makefile.
_fv_floor "ci: ; true || \$(MAKE) test never recurses" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "ci: ; true || \$(MAKE) test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: ; false || \$(MAKE) test always recurses" 'ok' '_fv_suite dotfiles-Alpine; printf "ci: ; false || \$(MAKE) test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: \$(MAKE) -C . test is the same Makefile" 'ok' '_fv_suite dotfiles-Alpine; printf "ci:\n\t\$(MAKE) -C . test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
_fv_floor "ci: \$(MAKE) -f Makefile test is the same Makefile" 'ok' '_fv_suite dotfiles-Alpine; printf "ci:\n\t\$(MAKE) -f Makefile test\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make ci"'
# .ONESHELL: a rule`s recipe is one script — an exit or a cd on one line governs the next;
# without it each line is its own sh -c. .SHELLFLAGS -e makes a bare false end the script.
_fv_floor ".ONESHELL: exit 0 on one line ends the recipe" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf ".ONESHELL:\nsuite3:\n\texit 0\n\t./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite3"'
_fv_floor ".ONESHELL: cd test on one line, ./smoke.sh on the next, runs the suite" 'ok' '_fv_suite dotfiles-Alpine; printf ".ONESHELL:\nsuite3:\n\tcd test\n\t./smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite3"'
_fv_floor "without .ONESHELL each recipe line is its own shell: cd does not carry" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf "suite3:\n\tcd test\n\t./smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite3"'
_fv_floor ".ONESHELL with .SHELLFLAGS -ec: false ends the script" '**not-in-ci**' '_fv_suite dotfiles-Alpine; printf ".ONESHELL:\n.SHELLFLAGS = -ec\nsuite3:\n\tfalse\n\t./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite3"'
_fv_floor ".ONESHELL without -e: false does not end the script" 'ok' '_fv_suite dotfiles-Alpine; printf ".ONESHELL:\nsuite3:\n\tfalse\n\t./test/smoke.sh\n" >>"$_fv_root/dotfiles-Alpine/Makefile"; _fv_ci dotfiles-Alpine "make suite3"'
# PYTEST OPTIONS THAT TAKE A VALUE do not end discovery.
_fv_floor "pytest -q -m smoke discovers a populated tests/" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_ci dotfiles-Alpine "pytest -q -m smoke"'
_fv_floor "a test: recipe of pytest -q -m smoke is the suite" 'ok' '_fv_suite dotfiles-Alpine tests; _fv_repo dotfiles-Alpine "${_fv_all/test:\\n\\t@.\/test\/smoke.sh/test:\\n\\tpytest -q -m smoke}"; _fv_ci dotfiles-Alpine "make test"'
# A for LOOP OVER A LITERAL LIST binds its variable: bash "$f" over test/*.sh runs the suite.
_fv_floor "for f in test/*.sh; do bash \"\$f\"; done (step)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for f in test/*.sh; do bash \"\$f\"; done"'
_fv_floor "for f in test/*.sh; do bash \"\$f\"; done (test: recipe) is the suite" 'ok' '_fv_suite dotfiles-Alpine; _fv_repo dotfiles-Alpine "${_fv_all/test:\\n\\t@.\/test\/smoke.sh/test:\\n\\tfor f in test\/*.sh; do bash \"\$\$f\"; done}"; _fv_ci dotfiles-Alpine "make test"'
_fv_floor "for f in docs/*.md; do bash \"\$f\"; done is not the suite" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for f in docs/*.md; do bash \"\$f\"; done"'
_fv_floor "for f in \$(ls test); do bash \"\$f\"; done binds nothing" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for f in \$(ls test); do bash \"\$f\"; done"'
_fv_floor "for f in test/*.sh; do bash \${f}; done (braced)" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "for f in test/*.sh; do bash \${f}; done"'
# A FUNCTION CALLED AS A CONDITION runs where the condition is evaluated.
_fv_floor "suite() { make test; }; if suite; then echo passed; fi" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; if suite; then echo passed; fi"'
_fv_floor "suite() { make test; }; if ! suite; then echo failed; fi" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; if ! suite; then echo failed; fi"'
_fv_floor "suite() { make test; }; while suite; do break; done" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; while suite; do break; done"'
_fv_floor "suite() { make test; }; if true && suite; then :; fi" 'ok' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; if true && suite; then :; fi"'
_fv_floor "suite() { make test; }; if false; then if suite; then :; fi; fi never runs" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_ci dotfiles-Alpine "suite() { make test; }; if false; then if suite; then :; fi; fi"'
# A compact-sequence block ends at the key column, so a sibling env: is not command text.
_fv_floor "an env: sibling after a run: block is not part of the block" '**not-in-ci**' '_fv_suite dotfiles-Alpine; _fv_wf dotfiles-Alpine ci.yml "jobs:\n  t:\n    steps:\n      - run: |\n          make lint\n        env:\n          SUITE: make test\n      - run: make lint\n        env: { SUITE_COMMAND: make test }\n"'
_fv_reset; _fv_repo dotfiles-Alpine "$_fv_all"
_fv_out="$(_fv_run --check)"; rc=$?
row="$(_fv_run | grep -F '| `Alpine` |')"
if ((rc == 1)) && [[ "$_fv_out" == *"1 verb x repo cell(s) missing; 1 repo(s) under the test floor"* && "$row" == *'| **no-op** | **no-dir** |' ]]; then
  pass "vocab floor: with no suite dir, --check exits 1 — the floor is no-dir AND a \`test:\` that can run nothing is **no-op**"
else
  fail "vocab floor: no-suite-dir verdicts (rc=$rc): $_fv_out / $row"
fi

# An unreadable vocabulary is a loud stop, never an empty register (the fleet-list posture).
_fv_out="$(_fv_reset; _fv_repo dotfiles-Fedora "$_fv_all"; CORE_MAKE_VOCABULARY=/nonexistent/vocab.txt _fv_run --check)"; rc=$?
if ((rc == 2)) && [[ "$_fv_out" == *"vocabulary list unreadable"* ]]; then
  pass "vocab: a missing vocabulary file is exit 2 with a notice §5h reads as an environment skip"
else
  fail "vocab: missing vocabulary file (rc=$rc): $_fv_out"
fi

# PINS. The seven verbs #691 settled on, in scripts/make-vocabulary.txt; §5h reading the
# notices above; a `make` entry point for the register.
want="help lint check dry-run packages-check core-verify test"
have="$(sed -e 's/#.*//' "$HERE/scripts/make-vocabulary.txt" | awk 'NF{print $1}' | tr '\n' ' ' | sed 's/ $//')"
if [[ "$have" == "$want" ]]; then
  pass "vocab: make-vocabulary.txt declares exactly the #691 verb set, in order"
else
  fail "vocab: make-vocabulary.txt drifted from the #691 set: '$have'"
fi
if grep -q 'fleet-vocabulary.sh" --check' "$HERE/scripts/audit-core.sh" &&
  grep -qF '"fleet list "' "$HERE/scripts/audit-core.sh"; then
  pass "vocab: audit-core.sh §5h runs the register and reads its fleet-list notice as an environment skip"
else
  fail "vocab: audit-core.sh §5h no longer runs fleet-vocabulary.sh --check or dropped the fleet-list match"
fi
# The CONTRACT failing to load is Core broken, not a missing sibling: §5h must go red.
if grep -qF 'vocabulary list "* ]]; then' "$HERE/scripts/audit-core.sh" &&
  sed -n '/vocabulary list "\* \]\]; then/,/elif/p' "$HERE/scripts/audit-core.sh" | grep -q 'fail "vocabulary register: scripts/make-vocabulary.txt would not load'; then
  pass "vocab: audit-core.sh §5h FAILS (not skips) when make-vocabulary.txt itself would not load"
else
  fail "vocab: audit-core.sh §5h turns an unreadable make-vocabulary.txt into an environment skip"
fi
if grep -qE '^fleet-vocabulary: ' "$HERE/Makefile"; then
  pass "vocab: \`make fleet-vocabulary\` prints the register"
else
  fail "vocab: Makefile has no fleet-vocabulary target"
fi
# Rendering is not a verdict: a full table must exit 0 (a trailing `[[ … ]] && printf`
# shape once made `make fleet-vocabulary` exit 1 for rendering).
_fv_reset; _fv_repo dotfiles-Fedora "$_fv_all"; _fv_suite dotfiles-Fedora; _fv_ci dotfiles-Fedora "make test"
if _fv_run >/dev/null; then pass "vocab: report mode exits 0 (rendering is not a verdict)"; else fail "vocab: report mode exits non-zero"; fi
if REPOS_ROOT="$_fv_root" "$HERE/scripts/fleet-coverage.sh" >/dev/null 2>&1; then pass "vocab: fleet-coverage.sh report mode exits 0 with no footnotes too"; else fail "vocab: fleet-coverage.sh report mode still exits 1 with no footnotes"; fi
rm -rf "$_fv_root"

