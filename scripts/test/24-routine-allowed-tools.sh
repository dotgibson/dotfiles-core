# scripts/test/24-routine-allowed-tools.sh
# the routine allowed-tools ⇄ workflow --allowedTools mirror
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $HERE, and the
# pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. It touches neither $SANDBOX
# nor the SCOPE_* flags, which the siblings' boilerplate lists and which is the whole
# reason it can sit this early — see the band note below. See the header of
# scripts/test-core.sh for the contract.
#
# THIS FILE WAS 80-nvim-reachability.sh, which held two unrelated subjects: the nvim
# orphan backstop and the gate below. The backstop retired to dotgibson/dotfiles-nvim
# along with the script it drove (#1125), and took the filename with it — a fragment
# named after a check it no longer contains is how the OTHER one gets deleted by someone
# tidying up. Retiring the editor's tests was therefore a SPLIT here, not a deletion:
# nothing below has anything to do with nvim, and nothing below moved.
#
# AND IT CAME DOWN FROM THE 80s BAND, which is not cosmetic. NN >= 60 is the ZSH BAND:
# scripts/test/60-loader.sh gates on `SCOPE_SHELL && have zsh` and calls _core_test_finish,
# ENDING THE RUN, so every fragment after it is unreachable under `--scope nvim`,
# `--scope atuin` or `--scope none`, and on any box without zsh. This gate is python3 and
# two file reads — it needs no zsh, no $SANDBOX and no scope — and it only ever sat up
# there because it was a lodger in an nvim file. 10-23 is the always-run pure-bash band,
# and unlike the SCOPE_TOOLING-gated generator fragments at 40-42 this one stays UNGATED:
# that gating bought back 311.9s (#467) and this costs milliseconds, so a gate here would
# only be a new way for it not to run.
#
# NO file-wide `# shellcheck disable=SC2016` here, unlike its siblings. Every fragment
# that embeds shell for a zsh CHILD needs one; this one embeds python in a QUOTED
# heredoc, which ShellCheck does not look inside, so the directive suppressed nothing
# once the nvim half left. It was dropped rather than carried — a suppression with no
# finding under it reads as "this file has a known false positive" and outlives the
# reason someone believed that.

# ── routine allowed-tools ⇄ workflow --allowedTools mirror (#633) ─────────────
# .github/workflows/claude-routines.yml states the invariant: "each job's --allowedTools MIRRORS
# the routine's own allowed-tools frontmatter (.claude/commands/<routine>.md) and is never
# broader." Nothing enforced it. The two live ~200 lines apart in different files, in different
# spellings (", " vs ","), and a routine that drifts BROADER hands a scheduled, token-bearing,
# Opus-driven job a capability its own definition never granted — while one that drifts NARROWER
# fails at runtime, weekly, in a job nobody watches unless it files an issue.
#
# Driven off the WORKFLOW side: every --allowedTools in the two rails must match the frontmatter
# of the routine its `claude -p "/<name>"` names. A command with no mirror is simply not
# scheduled (release-notes is dispatch-only, several are unscheduled) and is not a finding; a
# mirror naming a command that does not exist is.
if have python3; then
  hdr "routine allowed-tools mirror the workflow --allowedTools (#633)"
  _atm_out="$(
    HERE="$HERE" python3 - <<'PY'
import os, re, sys, glob

here = os.environ["HERE"]
rails = [".github/workflows/claude-routines.yml", ".github/workflows/claude-routines-call.yml"]

def norm(tools):
    # the two files spell the same list differently; compare as SETS of trimmed entries so
    # ordering and whitespace are not findings, but a missing or extra capability is.
    return frozenset(t.strip() for t in tools.split(",") if t.strip())

def frontmatter_tools(cmd):
    p = os.path.join(here, ".claude/commands/%s.md" % cmd)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as fh:
        text = fh.read()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None
    m2 = re.search(r"^allowed-tools:[ \t]*(.+)$", m.group(1), re.M)
    return norm(m2.group(1)) if m2 else None

problems, checked = [], 0
for rail in rails:
    path = os.path.join(here, rail)
    if not os.path.exists(path):
        continue
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    # pair each --allowedTools with the nearest PRECEDING `claude -p "/<routine>"`
    for m in re.finditer(r'--allowedTools\s+"([^"]*)"', text):
        before = text[: m.start()]
        names = re.findall(r'claude -p "/([A-Za-z0-9_-]+)[^"]*"', before)
        if not names:
            problems.append("a --allowedTools with no `claude -p \"/<routine>\"` above it in %s" % rail)
            continue
        cmd = names[-1]
        checked += 1
        want = frontmatter_tools(cmd)
        if want is None:
            problems.append("%s: mirrors /%s, which has no .claude/commands/%s.md with allowed-tools"
                            % (rail, cmd, cmd))
            continue
        got = norm(m.group(1))
        if got != want:
            extra = sorted(got - want)
            missing = sorted(want - got)
            bits = []
            if extra:
                bits.append("BROADER than the frontmatter by: %s" % ", ".join(extra))
            if missing:
                bits.append("NARROWER than the frontmatter, missing: %s" % ", ".join(missing))
            problems.append("/%s in %s is %s" % (cmd, rail, "; and ".join(bits)))

if checked == 0:
    print("NONE")
elif problems:
    print("BAD %d" % checked)
    for p in problems:
        print("  " + p)
else:
    print("OK %d" % checked)
PY
  )"
  case "$_atm_out" in
  "OK "*)
    pass "allowed-tools mirror: every scheduled routine matches its workflow --allowedTools (${_atm_out#OK } mirror(s))"
    ;;
  NONE)
    fail "allowed-tools mirror: found no --allowedTools to check — the scan is broken, not the tree"
    ;;
  *)
    fail "allowed-tools mirror: a routine's frontmatter and its workflow --allowedTools disagree"
    fail_detail "$_atm_out"
    ;;
  esac
  unset _atm_out
else
  skip "allowed-tools mirror (python3 not installed)"
fi
