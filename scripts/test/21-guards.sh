# scripts/test/21-guards.sh
# common.sh verdicts + major-version guards (luacheck, workflow refs, caller examples, vendor pins, fail digest)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── luacheck verdict (common.sh :: _core_luacheck_verdict) ───────────────────
# WHY THIS IS TESTED. audit-core.sh §4 used to treat EVERY non-zero luacheck exit as
# "luacheck reported issues", so a toolchain that never ran was announced as a lint failure in
# nvim/ — and the repair it printed ("re-run luacheck") only reproduced the error (#726). The
# fix is a three-way decision, and the whole value is that the three stay distinguishable.
#
# THE CASE THAT MAKES THE PROBE NECESSARY is `a load failure also exits 1`. luacheck's own
# codes are 0/1/2/3, and luacheck 1.2.0 failing to load under Lua 5.5 — the documented
# mise/config.toml trap, and the likeliest toolchain break going forward — exits 1 too. So the
# lint rc ALONE cannot separate "warnings" from "did not run", at any threshold. If someone
# later "simplifies" this to a status check on the lint rc, these cases fail.
hdr "luacheck verdict (_core_luacheck_verdict)"
_lv_is() { # _lv_is <label> <probe-rc> <lint-rc> <expected>
  local got
  got="$(_core_luacheck_verdict "$2" "$3")"
  if [[ "$got" == "$4" ]]; then
    pass "luacheck verdict: $1"
  else
    fail "luacheck verdict: $1 (probe=$2 lint=$3 → '$got', want '$4')"
  fi
}
# ── the tool ran ──
_lv_is "a clean run is ok" 0 0 ok
_lv_is "exit 1 after a passing probe is warnings, not a broken tool" 0 1 issues
_lv_is "exit 2 (syntax errors in a checked file) is still a lint result" 0 2 issues
_lv_is "exit 3 (luacheck's I/O error) is still a lint result" 0 3 issues
# ── the tool did not run ──
# The #726 shape: the luarocks wrapper execs an absolute interpreter path that is gone.
_lv_is "a failing probe is a broken tool even when the lint rc looks clean" 127 0 broken
# THE UNDECIDABLE-WITHOUT-A-PROBE CASE: luacheck 1.2.0 under Lua 5.5 fails to LOAD and exits
# 1 — byte-identical in status to honest warnings. Only the probe separates them.
_lv_is "a load failure that exits 1 is broken, not warnings" 1 1 broken
_lv_is "a failing probe wins over any lint rc" 1 2 broken
# 126/127 are the shell's "could not exec", never one of luacheck's codes, so after a passing
# probe they can only mean it stopped being runnable mid-audit — its own sentence.
_lv_is "exit 127 after a passing probe is a mid-run break" 0 127 broken-midrun
_lv_is "exit 126 (found but not executable) is a mid-run break" 0 126 broken-midrun
# The boundary itself, both sides — 3 is luacheck's highest own code.
_lv_is "exit 125 stays a lint result (below the shell's exec-failure range)" 0 125 issues
# Defaults: called with nothing, claim nothing is wrong rather than inventing a failure.
_lv_is "no arguments is ok (no inputs, no claim)" "" "" ok

# LIVE CANARY, the _core_claude_ref_hits lesson: every case above is synthetic, so all of them
# would still pass if §4 stopped consulting this function. Assert the real gate still routes
# through it — otherwise these tests pin a helper nothing calls, which is the shape of a gate
# that is green because it checks nothing.
if grep -q '_core_luacheck_verdict' "$HERE/scripts/audit-core.sh"; then
  pass "luacheck verdict: audit-core.sh §4 still routes its verdict through this function"
else
  fail "luacheck verdict: audit-core.sh no longer calls _core_luacheck_verdict — §4 decides on its own again, so every case above pins a helper nothing uses (#726)"
fi
unset -f _lv_is

# ── workflow ref-major guard (common.sh :: _core_workflow_ref_hits) ──────────
# WHY THIS IS TESTED AGAINST REAL HISTORY, not only synthetic fixtures. This guard exists
# because two real regressions shipped and stayed green (v3->v4 for ten minors, v4->v5
# until #744). A guard for a historical defect that is never RUN against that defect is
# the same category error it exists to fix, so the last two cases below rebuild the exact
# trees from the tags and require the guard to red on them.
#
# It drives _core_workflow_ref_hits DIRECTLY — never a reimplementation of its loop. The
# note on _core_tool_skip_count records what happens otherwise: the test and the shipped
# logic drift apart, both stay green, and the defect walks back in.
hdr "workflow ref-major guard (_core_workflow_ref_hits)"
_wfr_="$SANDBOX/wfref"
mkdir -p "$_wfr_/.github/workflows"
# _wfr_reset — every case starts from an EMPTY workflows dir. Without this a fixture from
# an earlier case leaks its finding into the next one's count, which is exactly what the
# first draft of these tests did: three "failures" that were stale files, not defects.
_wfr_reset() { rm -f "$_wfr_"/.github/workflows/*.yml "$_wfr_"/.github/workflows/*.yaml 2>/dev/null || :; }
# _wfr_write <name> <body> — resets first, so each fixture stands alone.
_wfr_write() { _wfr_reset; printf '%s\n' "$2" >"$_wfr_/.github/workflows/$1"; }
# _wfr_count <label> <major> <expected-line-count> — how many findings the guard reports.
_wfr_count() {
  local got n
  got="$(_core_workflow_ref_hits "$_wfr_" "$2")"
  n=0
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
  if [[ "$n" == "$3" ]]; then
    pass "workflow ref-major: $1"
  else
    fail "workflow ref-major: $1 (got $n finding(s), want $3)"
  fi
}

_wfr_write a.yml '      - uses: actions/checkout@v5
        with:
          repository: ${{ github.repository_owner }}/dotfiles-core
          ref: v4'
_wfr_count "a foreign major on a dotfiles-core checkout is a finding" 5 1
_wfr_count "the SAME file is clean when core.version agrees" 4 0

# Order within the step must not matter — YAML does not promise key order, and a guard
# that only works one way round is a coin flip on the next author's formatting.
_wfr_write b.yml '      - uses: actions/checkout@v5
        with:
          ref: v4
          repository: ${{ github.repository_owner }}/dotfiles-core'
_wfr_count "ref: before repository: is judged the same" 5 1

# The association is per STEP. A ref belonging to somebody else s checkout is not ours to
# judge, and attributing it here would make the gate cry wolf on any workflow that pulls a
# second repository at a tag.
_wfr_write c.yml '      - uses: actions/checkout@v5
        with:
          repository: ${{ github.repository_owner }}/dotfiles-core
          ref: v5
      - uses: actions/checkout@v5
        with:
          repository: someone/other-repo
          ref: v1'
_wfr_count "another repository at v1 is NOT attributed to dotfiles-core" 5 0

# A non-vN ref is deliberately out of scope: this gate answers "which major", and a SHA or
# an expression is a pinning-style question with a different right answer.
_wfr_write d.yml '      - uses: actions/checkout@v5
        with:
          repository: ${{ github.repository_owner }}/dotfiles-core
          ref: 0123456789012345678901234567890123456789'
_wfr_count "a SHA ref is not judged as a major" 5 0

# A tree with no workflows at all must be silent, not an error — role repos vendoring Core
# run this same lib.
_wfr_reset
_wfr_count "an empty workflows dir is clean" 5 0

# ── the two real regressions ──
# Rebuild each tag s .github/workflows and require the guard to red on it. If either of
# these ever goes quiet, the guard has stopped covering the thing it was written for.
if have git && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  _wfr_hist() { # _wfr_hist <tag> <expected-major> <min-findings>
    local tag="$1" major="$2" want="$3" dir="$SANDBOX/wfhist-$1" f got n
    git -C "$HERE" rev-parse -q --verify "$tag^{commit}" >/dev/null 2>&1 || {
      skip "workflow ref-major: $tag not present in this clone (shallow?)"
      return 0
    }
    mkdir -p "$dir/.github/workflows"
    while IFS= read -r f; do
      [[ "$f" == *.yml || "$f" == *.yaml ]] || continue
      git -C "$HERE" show "$tag:$f" >"$dir/$f" 2>/dev/null || :
    done < <(git -C "$HERE" ls-tree --name-only "$tag" .github/workflows/ 2>/dev/null)
    got="$(_core_workflow_ref_hits "$dir" "$major")"
    n=0
    [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
    if [[ "$n" -ge "$want" ]]; then
      pass "workflow ref-major: catches the real $tag regression ($n site(s))"
    else
      fail "workflow ref-major: $tag regression NOT caught (got $n finding(s), want >= $want)"
    fi
  }
  # v4.0.0 shipped four sites still on ref: v3; not corrected until v4.10.0.
  _wfr_hist v4.0.0 4 4
  # v5.0.2 shipped six sites still on ref: v4; corrected in #744.
  _wfr_hist v5.0.2 5 6
else
  skip "workflow ref-major: historical regression cases (git/repo unavailable)"
fi

# And the tree as it stands must be clean against its own core.version — the gate running
# on itself, which is what CI will do on every push.
if [[ -r "$HERE/core.version" ]]; then
  _wfr_now="$(tr -d '[:space:]' <"$HERE/core.version" | cut -d. -f1)"
  if [[ -z "$(_core_workflow_ref_hits "$HERE" "$_wfr_now")" ]]; then
    pass "workflow ref-major: this tree pins ref: v$_wfr_now everywhere (matches core.version)"
  else
    fail "workflow ref-major: this tree has a workflow on a foreign major"
  fi
  unset _wfr_now
fi

# ── caller-example major guard (common.sh :: _core_workflow_example_hits) ────
# Sibling of the ref-major guard above, and tested the same way: against the REAL
# regression, not only fixtures. #821 is the case — 25 `@v5` references survived the
# v5 → v6 cut while every `ref:` moved correctly, so the guard above stayed green while
# six copyable caller examples pointed at a retired major.
#
# The negative cases matter as much as the positive ones here. Legitimate historical `vN`
# prose exists in these files and MUST NOT be flagged; a guard that reds on a true
# sentence would train the next person to falsify it.
hdr "caller-example major guard (_core_workflow_example_hits)"
_wfe_="$SANDBOX/wfexample"
mkdir -p "$_wfe_/.github/workflows"
_wfe_reset() { rm -f "$_wfe_"/.github/workflows/*.yml "$_wfe_"/.github/workflows/*.yaml 2>/dev/null || :; }
_wfe_write() { _wfe_reset; printf '%s\n' "$2" >"$_wfe_/.github/workflows/$1"; }
_wfe_count() {
  local got n
  got="$(_core_workflow_example_hits "$_wfe_" "$2")"
  n=0
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
  if [[ "$n" == "$3" ]]; then
    pass "caller-example major: $1"
  else
    fail "caller-example major: $1 (got $n finding(s), want $3)"
  fi
}

_wfe_write a.yml '#       uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v5'
_wfe_count "a commented example on a foreign major is a finding" 6 1

_wfe_write a.yml '#       uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v6'
_wfe_count "a commented example on the current major is clean" 6 0

# THE CASE THAT DECIDES THE DESIGN. These are the real surviving sentences from
# claude-routines-call.yml and lint-call.yml. A blanket @vN scan reds on all of them and
# would push someone to rewrite true history.
_wfe_write a.yml '          # every caller moved to `@v5`, so the workflow body was v5 and the scripts it
          # majors of fixes stale; at v4→v5 it was left on `v4` (frozen at v4.19.0) while
      - name: os.capabilities (schema — Core v5 #663/#667)
            echo "no vendored $chk — this core/ predates the v5 capability schema"'
_wfe_count "historical vN prose is NOT judged (no workflow path)" 6 0

# A live `uses:` is check-modern.sh business, not this gate: only comments are read.
_wfe_write a.yml '    uses: dotgibson/dotfiles-core/.github/workflows/lint-call.yml@v5'
_wfe_count "an uncommented uses: is out of scope (check-modern owns pinning)" 6 0

# Prose that names the path without a `uses:` key is still a copyable instruction.
_wfe_write a.yml '# call this via `dotgibson/dotfiles-core/.github/workflows/notify-failure-call.yml@v5`'
_wfe_count "a path in prose counts, not only a uses: line" 6 1

# TWO complete paths, deliberately: with only one, a regression that stopped the `while`
# loop after its first match would still pass and the case would prove nothing.
_wfe_write a.yml '#  a@v5 b@v5 dotgibson/dotfiles-core/.github/workflows/x.yml@v4 plus dotgibson/dotfiles-core/.github/workflows/y.yml@v3 and .../z.yml@v5'
_wfe_count "every occurrence on the line is reported, not just the first" 6 2

# BOUNDARY. Without an owner anchor and a left boundary, `dotfiles-core` matches inside
# ANOTHER repository's name and this always-on gate reds on a file it has no business
# judging. Both shapes below did exactly that before the boundary was added.
_wfe_write a.yml '#   uses: someone/not-dotfiles-core/.github/workflows/x.yml@v5
#   uses: notdotgibson/dotfiles-core/.github/workflows/x.yml@v5'
_wfe_count "a lookalike repository name is NOT attributed to dotfiles-core" 6 0

_wfe_reset
# ── the real regression ──
# #821 is this guard's reason to exist: v6.0.0 and v6.0.1 both SHIPPED with the caller
# examples still on @v5 while every `ref:` had moved to v6 — which is why the sibling
# guard stayed green throughout. Rebuild those tags and require a red, for the reason
# the sibling records: a guard for a historical defect that is never RUN against that
# defect is the category error it exists to fix.
if have git && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  _wfe_hist() { # _wfe_hist <tag> <min-findings>
    local tag="$1" want="$2" dir="$SANDBOX/wfehist-$1" f got n major
    git -C "$HERE" rev-parse -q --verify "$tag^{commit}" >/dev/null 2>&1 || {
      skip "caller-example major: $tag not present in this clone (shallow?)"
      return 0
    }
    major="$(git -C "$HERE" show "$tag:core.version" 2>/dev/null | tr -d '[:space:]' | cut -d. -f1)"
    [[ "$major" =~ ^[0-9]+$ ]] || { skip "caller-example major: $tag core.version unreadable"; return 0; }
    mkdir -p "$dir/.github/workflows"
    while IFS= read -r f; do
      [[ "$f" == *.yml || "$f" == *.yaml ]] || continue
      git -C "$HERE" show "$tag:$f" >"$dir/$f" 2>/dev/null || :
    done < <(git -C "$HERE" ls-tree --name-only "$tag" .github/workflows/ 2>/dev/null)
    got="$(_core_workflow_example_hits "$dir" "$major")"
    n=0
    [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
    if [[ "$n" -ge "$want" ]]; then
      pass "caller-example major: catches the real $tag regression ($n example(s))"
    else
      fail "caller-example major: $tag regression NOT caught (got $n finding(s), want >= $want)"
    fi
  }
  # Both v6 releases shipped seven documented examples still naming @v5.
  _wfe_hist v6.0.0 7
  _wfe_hist v6.0.1 7
else
  skip "caller-example major: historical regression cases (git/repo unavailable)"
fi

# And the tree as it stands must be clean against its own core.version — the gate running
# on itself, exactly as CI will.
if [[ -r "$HERE/core.version" ]]; then
  _wfe_now="$(tr -d '[:space:]' <"$HERE/core.version" | cut -d. -f1)"
  if [[ -z "$(_core_workflow_example_hits "$HERE" "$_wfe_now")" ]]; then
    pass "caller-example major: this tree documents @v$_wfe_now everywhere (matches core.version)"
  else
    fail "caller-example major: this tree documents a foreign major"
  fi
  unset _wfe_now
fi

# ── first-vendor pin major guard (common.sh :: _core_vendor_pin_hits) ─────────
# Third sibling of the two guards above, for the third copyable instruction that names a
# major: the first-vendor recipe (`refs/tags/vN`, `git checkout vN`, `vN^{commit}`) and
# new-os-repo.sh's default for it. It rotted at v4 → v5 (fixed by hand, three CHANGELOG
# entries) and again at v5 → v6, where it sat for two releases while every `ref:` and
# every caller example was held to the major — a greenfield repo vendored a retired Core
# by default and nothing was red. Same treatment as its siblings, tested the same way.
#
# The exemptions carry the weight: CHANGELOG history, test fixtures, exact pins and another
# repo's tag behind an API path are all TRUE text that a blunter scan would red on, and a
# guard that reds on a true sentence teaches the next person to falsify it.
hdr "first-vendor pin major guard (_core_vendor_pin_hits)"
_vpn_="$SANDBOX/vendorpin"
_vpn_reset() { rm -rf "$_vpn_"; mkdir -p "$_vpn_/scripts"; }
_vpn_write() { _vpn_reset; printf '%s\n' "$2" >"$_vpn_/$1"; }
_vpn_count() {
  local got n
  got="$(_core_vendor_pin_hits "$_vpn_" "$2")"
  n=0
  [[ -n "$got" ]] && n="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
  if [[ "$n" == "$3" ]]; then
    pass "first-vendor pin: $1"
  else
    fail "first-vendor pin: $1 (got $n finding(s), want $3): $(printf '%s' "$got" | tr '\n' ' ')"
  fi
}

_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5 --squash'
_vpn_count "a subtree-add on a foreign major is a finding" 6 1
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v6 --squash'
_vpn_count "a subtree-add on the current major is clean" 6 0
_vpn_write README.md 'git checkout v5                                    # in dotfiles-core'
_vpn_count "\`git checkout vN\` is judged" 6 1
_vpn_write README.md 'CORE_BRANCH="$(git rev-parse v5^{commit})" ./scripts/sync-core.sh dotfiles-<Distro>'
_vpn_count "the peeled-commit form is judged" 6 1
# THE LINE THAT MATTERS MOST: the scaffold default, where the major is preceded by `:-`.
# The first draft treated `-` as a word character and skipped exactly this line.
_vpn_write scripts/new-os-repo.sh 'CORE_BRANCH="${CORE_BRANCH:-refs/tags/v5}"'
_vpn_count "new-os-repo.sh's :-refs/tags/vN default is judged" 6 1
# The exact-pin exemption below does NOT reach the scaffold default: a recipe's freeze is
# a choice its reader made, the default is what every new repo inherits unasked.
_vpn_write scripts/new-os-repo.sh 'CORE_BRANCH="${CORE_BRANCH:-refs/tags/v5.3.0}"'
_vpn_count "an exact-but-retired scaffold default (v5.3.0 on a v6 tree) is still a finding" 6 1
_vpn_write scripts/new-os-repo.sh 'CORE_BRANCH="${CORE_BRANCH:-refs/tags/v6.1.0}"'
_vpn_count "an exact scaffold default on the current major is clean" 6 0
# A QUOTED default inside the expansion is still the default — and never exempt.
_vpn_write scripts/new-os-repo.sh 'CORE_BRANCH="${CORE_BRANCH:-"refs/tags/v5.3.0"}"'
_vpn_count "a quoted exact-but-retired scaffold default (\"refs/tags/v5.3.0\") is still a finding" 6 1
# The --help text documents the same default in prose form, and is what a reader pastes.
_vpn_write scripts/new-os-repo.sh '     CORE_BRANCH (default: refs/tags/v5.3.0 — a RELEASED tag, never main; pin a specific'
_vpn_count "the --help form of an exact-but-retired default is judged too" 6 1
# Default-ness is decided per MATCH, not per line: the current default and a deliberate
# freeze in one sentence must leave the freeze exempt.
_vpn_write README.md 'the default is CORE_BRANCH:-refs/tags/v6, but pin refs/tags/v5.3.0 to freeze'
_vpn_count "a freeze on the same line as the current default keeps its exemption" 6 0
# Exemptions — every one of these is a TRUE sentence that must not be flagged.
_vpn_write RELEASE-STRATEGY.md 'Pin `refs/tags/v5.3.0` while sitting on `main` and the lock records'
_vpn_count "an exact vN.M.P pin is a deliberate freeze, not a finding" 6 0
# Only a COMPLETE vN.M.P is exempt. A two-component `v5.3` is not a tag this repo cuts,
# so it is a stale pin wearing a dot; a first draft exempted every dotted suffix.
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3 --squash'
_vpn_count "a two-component v5.3 is NOT an exact pin — still a finding" 6 1
_vpn_write README.md 'git checkout v6.1.0 && CORE_BRANCH="$(git rev-parse v6.1.0^{commit})"'
_vpn_count "an exact pin on the current line in the other two shapes is clean" 6 0
# The peeled shape must SEE a dotted version, not skip it: a first draft matched only
# `vN^{commit}`, so a stale `v5.3^{commit}` was invisible rather than judged.
_vpn_write README.md 'CORE_BRANCH="$(git rev-parse v5.3^{commit})" ./scripts/sync-core.sh dotfiles-<Distro>'
_vpn_count "a dotted-but-incomplete peeled pin (v5.3^{commit}) is a finding" 6 1
_vpn_write README.md 'CORE_BRANCH="$(git rev-parse v5.3.0^{commit})" ./scripts/sync-core.sh dotfiles-<Distro>'
_vpn_count "an exact peeled pin (v5.3.0^{commit}) is a deliberate freeze, exempt" 6 0
# Only EXACTLY vN.M.P (optionally -pre, as core.version allows) is exempt: a fourth
# component is no tag this repo cuts, so it is judged by its leading major.
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3.0.1 --squash'
_vpn_count "a four-component v5.3.0.1 is malformed, not exact — still a finding" 6 1
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3.0-rc1 --squash'
_vpn_count "a SemVer pre-release pin (v5.3.0-rc1) is an exact release, exempt" 6 0
# The exact-pin class is core.version's own (audit §: SemVer [-pre] with `.` and `-`
# allowed inside the label), so a pin the validator would accept is never reported stale.
_vpn_write README.md 'git checkout v5.3.0-alpha-beta && refs/tags/v5.3.0-alpha.1'
_vpn_count "a pre-release label with a second hyphen or a dot (as core.version allows) is exempt" 6 0
# Prose runs into pins. A sentence-ending period is not part of the version, so an exact
# freeze stays exempt and a bare major at the end of a sentence is still judged as vN.
_vpn_write README.md 'Pin `refs/tags/v5.3.0`. Or, less carefully, pin refs/tags/v5.3.0.'
_vpn_count "an exact pin followed by a sentence-ending period is still exempt" 6 0
_vpn_write README.md 'so vendor refs/tags/v5.'
_vpn_count "a bare major followed by a sentence-ending period is still a finding" 6 1
# A period inside a QUOTED argument is handed to git, so it is part of a malformed ref.
_vpn_write README.md 'git subtree add --prefix=core <core-remote> "refs/tags/v5.3.0." --squash'
_vpn_count "a trailing period inside a quoted ref (\"refs/tags/v5.3.0.\") is malformed — a finding" 6 1
# Exactly ONE trailing period is prose; a second one is part of a malformed ref.
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3.0.. --squash'
_vpn_count "\`v5.3.0..\` is not an exact pin with a sentence period — a finding" 6 1
# Only the period is prose. A trailing `+` or `-` makes the token malformed, and a
# malformed foreign pin is judged, never trimmed into an exempt exact one.
_vpn_write README.md 'refs/tags/v5.3.0+ and refs/tags/v5.3.0-'
_vpn_count "\`v5.3.0+\` and \`v5.3.0-\` are malformed foreign pins, both findings" 6 2
# ...and so is a suffix the token class does not admit: `v5.3.0_bad` must not be read as
# `v5.3.0` and exempted on the strength of its well-formed prefix.
_vpn_write README.md 'refs/tags/v5.3.0_bad and git checkout v5.3.0x'
_vpn_count "a word character glued to an exact-looking pin makes it malformed — both findings" 6 2
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3.0/foo --squash'
_vpn_count "a \`/\` continuing an exact-looking pin (v5.3.0/foo) makes it malformed — a finding" 6 1
# `@` is legal inside a git ref, and so are others; the rule is the inverse — only a
# terminator may follow an exempt pin — so nothing glued on can slip through.
_vpn_write README.md 'refs/tags/v5.3.0@foo and refs/tags/v5.3.0%x'
_vpn_count "any non-terminator glued to an exact-looking pin (v5.3.0@foo, v5.3.0%x) is a finding" 6 2
_vpn_write README.md '(`refs/tags/v5.3.0`), "refs/tags/v5.3.0"; refs/tags/v5.3.0) refs/tags/v5.3.0 # note'
_vpn_count "an exact pin followed by a quote, paren, semicolon or a spaced comment stays exempt" 6 0
# Prose punctuation ends a pin only when whitespace or the line ends after it: `v5.3.0,`
# and `v5.3.0:` are exempt, `v5.3.0,foo` and `v5.3.0:foo` are glued text and judged.
_vpn_write README.md 'pin refs/tags/v5.3.0, or refs/tags/v5.3.0: either is a freeze; also refs/tags/v5.3.0,'
_vpn_count "an exact pin followed by a comma or colon and then whitespace or end of line stays exempt" 6 0
_vpn_write README.md 'refs/tags/v5.3.0:foo and refs/tags/v5.3.0,foo'
_vpn_count "a comma or colon GLUED to more text (v5.3.0:foo, v5.3.0,foo) is malformed — both findings" 6 2
# This scans root Markdown: a bold delimiter or sentence-final punctuation closes a pin.
_vpn_write README.md 'Pin **refs/tags/v5.3.0** here. Pin refs/tags/v5.3.0! Or refs/tags/v5.3.0? Or _refs/tags/v5.3.0_'
_vpn_count "Markdown delimiters and sentence-final ! or ? after an exact pin stay exempt" 6 0
# An underscore delimiter is scanned only at a word boundary: `_refs/tags/v5_` is the same
# copyable bare-major pin (judged); `foo_refs/tags/v5` is an intraword identifier (not).
_vpn_write README.md 'vendor _refs/tags/v5_ first'
_vpn_count "an underscore-emphasised bare-major pin (_refs/tags/v5_) is a finding" 6 1
_vpn_write README.md 'foo_refs/tags/v5 is an identifier, and _refs/tags/v5.3.0_ an exact freeze'
_vpn_count "an intraword underscore is not a delimiter, and an emphasised exact pin stays exempt" 6 0
# A period inside a PEELED revision is never a sentence period.
_vpn_write README.md 'git rev-parse v5.3.0.^{commit} and git rev-parse refs/tags/v5.3.0.^{commit}'
_vpn_count "a trailing period inside a peeled revision (v5.3.0.^{commit}) is malformed — both findings" 6 2
# A `#` glued to the word is NOT a comment — bash hands `v5.3.0#note` to git as one
# argument — so it is a non-exact foreign ref and must be judged, not exempted.
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3.0#note --squash'
_vpn_count "a glued \`#note\` is part of the ref, not a comment — a finding" 6 1
# The peeled form: its sentence period lands in rest, not the token, and must still be
# prose; and a caret that is NOT the literal ^{commit} is a malformed ref, judged.
_vpn_write README.md 'CORE_BRANCH="$(git rev-parse v5.3.0^{commit})" — then run it. Or git rev-parse v5.3.0^{commit}.'
_vpn_count "an exact peeled pin at sentence end (v5.3.0^{commit}.) stays exempt" 6 0
_vpn_write README.md 'git subtree add --prefix=core <core-remote> refs/tags/v5.3.0^foo --squash'
_vpn_count "\`v5.3.0^foo\` — a caret that is not ^{commit} — is malformed, a finding" 6 1
# The peel written against the FULL ref: `refs/tags/v5.3.0^{commit}` matches through the
# refs/tags shape and leaves the literal ^{commit} in rest — the same freeze, still exempt.
_vpn_write README.md 'CORE_BRANCH="$(git rev-parse refs/tags/v5.3.0^{commit})" ./scripts/sync-core.sh dotfiles-<Distro>'
_vpn_count "an exact peeled pin in full-ref form (refs/tags/v5.3.0^{commit}) stays exempt" 6 0
_vpn_write README.md 'CORE_BRANCH="$(git rev-parse refs/tags/v5^{commit})" ./scripts/sync-core.sh dotfiles-<Distro>'
_vpn_count "a bare-major peel in full-ref form (refs/tags/v5^{commit}) is still judged" 6 1
# A reformatted `git checkout` — two spaces, or a tab — is the same copyable command.
_vpn_write README.md 'git  checkout v5'
_vpn_count "\`git  checkout vN\` with doubled whitespace is still judged" 6 1
printf 'git\tcheckout v5\n' >"$_vpn_/README.md"
_vpn_count "\`git<TAB>checkout vN\` is still judged" 6 1
_vpn_write README.md 'gh api repos/actions/create-github-app-token/git/refs/tags/v3 --jq .object.sha'
_vpn_count "another repository's tag behind an API path (git/refs/tags/) is not a finding" 6 0
_vpn_write CHANGELOG.md 'so it is corrected to a concrete `refs/tags/v5`'
_vpn_count "CHANGELOG history is exempt" 6 0
_vpn_write CHANGELOG.recent.md 'so it is corrected to a concrete `refs/tags/v5`'
_vpn_count "the generated CHANGELOG digest is exempt too" 6 0
_vpn_write scripts/test-core.sh 'git -C "$TR/origin" update-ref refs/tags/v1 "$_tr_div"'
_vpn_count "test-core.sh's fixture tags are data, not instructions" 6 0
_vpn_write README.md 'the v5 line, `@v5`, Core v5 #663, and "at v4→v5 it was left on v4"'
_vpn_count "narrative vN prose with none of the three shapes is not judged" 6 0
# Option-bearing, quoted and `switch` spellings of the checkout are the same recipe.
_vpn_write README.md 'git checkout --detach v5; git checkout -q --detach v5; git switch --detach v5; git checkout '"'"'v5'"'"'; git checkout "v5"'
_vpn_count "\`checkout --detach vN\`, \`switch --detach vN\` and a quoted ref are all judged" 6 5
_vpn_write README.md 'git checkout --detach v6 && git checkout "v5.3.0" && git switch --detach '"'"'v6.1.0'"'"''
_vpn_count "the same forms on the current major or an exact pin are clean" 6 0
# Options that take an operand put a branch name between the flag and the tag.
_vpn_write README.md 'git checkout -b vendor-v5 v5 && git switch -c work v5'
_vpn_count "\`checkout -b <branch> vN\` and \`switch -c <branch> vN\` are judged past the operand" 6 2
_vpn_write README.md 'git checkout -B vendor v5.3.0 && git switch -C work v6'
_vpn_count "the same operand forms on an exact pin or the current major are clean" 6 0
# The branch NAME may look like a pin; the ref is the last token, whatever the name says.
_vpn_write README.md 'git checkout -b vendor-v6 v5'
_vpn_count "\`checkout -b vendor-v6 v5\` is judged on v5, not on the branch name" 6 1
_vpn_write README.md 'git checkout -b vendor-v5 v6'
_vpn_count "\`checkout -b vendor-v5 v6\` is clean — the branch name is not the pin" 6 0
# The long spellings of the operand-taking options consume a branch name too.
_vpn_write README.md 'git switch --create vendor-v6 v5 && git checkout --orphan vendor-v6 v5 && git switch --force-create work v5'
_vpn_count "\`--create\`, \`--orphan\` and \`--force-create\` consume their operand; the pin after it is judged" 6 3
_vpn_write README.md 'git switch --create work v6.1.0 && git checkout --orphan fresh v6'
_vpn_count "the same long options on an exact pin or the current major are clean" 6 0
# Git's GLOBAL options come before the subcommand; this repo writes `git -C "$HERE" …` all the time.
_vpn_write README.md 'git -C "$HERE" checkout v5 && git --no-pager -c core.pager=cat switch --detach v5'
_vpn_count "global options before checkout/switch (-C, -c, --no-pager) are seen through — both findings" 6 2
_vpn_write README.md 'git -C "$HERE" checkout v6.1.0'
_vpn_count "the same with an exact pin is clean" 6 0
# An operand is a shell WORD: a quoted path with a space must not hide the pin behind it.
_vpn_write README.md 'git -C "/tmp/core checkout" checkout v5 && git -C '"'"'/tmp/my core'"'"' switch --detach v5 && git checkout -b "vendor branch" v5'
_vpn_count "quoted operands with spaces (-C \"/tmp/core checkout\", -b \"vendor branch\") are consumed whole — three findings" 6 3
# A branch NAMED vN with no start point pins nothing: the operand is the last token.
_vpn_write README.md 'git checkout -b v5 && git switch -c v5 && git switch --create v5 && git checkout --orphan v5'
_vpn_count "operand-only branch creation (checkout -b v5, switch -c v5, --create v5, --orphan v5) is not a pin" 6 0
# A bare `--` ends checkout's options and makes the next token a PATH, not a ref; for
# switch the token after `--` is still a branch.
_vpn_write README.md 'git checkout -- v5 && git checkout -q -- v5'
_vpn_count "\`git checkout -- v5\` restores a path, not a pin — not a finding" 6 0
_vpn_write README.md 'git switch -- v5'
_vpn_count "\`git switch -- v5\` names a branch and is still judged" 6 1
_vpn_write README.md 'git checkout v60 && CORE_BRANCH="$(git rev-parse v5^{commit})" x refs/tags/v5 refs/tags/v6'
_vpn_count "every occurrence on a line is reported and the number is read whole (v60 is not v6)" 6 3
# Core must satisfy the rule it authors — the inverse assertion, so `make test` catches a
# stale pin without a full audit, exactly as the two siblings above do.
if [[ -r "$HERE/core.version" ]]; then
  _vpn_now="$(tr -d '[:space:]' <"$HERE/core.version" | cut -d. -f1)"
  _vpn_real="$(_core_vendor_pin_hits "$HERE" "$_vpn_now")"
  if [[ -z "$_vpn_real" ]]; then
    pass "first-vendor pin: this tree's recipe and new-os-repo.sh default name v$_vpn_now everywhere (matches core.version)"
  else
    fail "first-vendor pin: this tree names a foreign major: $(printf '%s' "$_vpn_real" | tr '\n' ' ')"
  fi
  # And the guard can fail on THIS tree: at any other major every pin must surface,
  # including the scaffold default — asserted by its exact file:line, resolved from the
  # assignment itself, so a finding on the --help text two lines down cannot stand in
  # for it. Captured first, then a here-string: the producer walks the whole tree and
  # `| grep -q` under pipefail is the SIGPIPE hazard _core_pipefail_hits documents.
  _vpn_line="$(grep -n '^CORE_BRANCH="\${CORE_BRANCH:-refs/tags/v' "$HERE/scripts/new-os-repo.sh" | head -1 | cut -d: -f1)"
  _vpn_next="$(_core_vendor_pin_hits "$HERE" "$((_vpn_now + 1))")"
  if [[ -n "$_vpn_line" ]] && grep -qF "scripts/new-os-repo.sh:$_vpn_line: " <<<"$_vpn_next"; then
    pass "first-vendor pin: at the next major the scaffold default itself (new-os-repo.sh:$_vpn_line) is reported"
  else
    fail "first-vendor pin: the scaffold default (new-os-repo.sh:${_vpn_line:-?}) would not be reported at the next major — the gate misses the line it exists for"
  fi
  unset _vpn_now _vpn_real _vpn_line _vpn_next
fi
rm -rf "$_vpn_"
unset _vpn_
unset -f _vpn_reset _vpn_write _vpn_count

# ── unreferenced .claude/ scanner (common.sh :: _core_claude_untracked_hits) ──
# WHY THIS IS TESTED ON A REAL REPO. Unlike _core_claude_ref_hits, which is pure text
# extraction, every verdict here comes from git: is the path tracked, and which .gitignore
# rule wins. No text fixture can stand in for that, so each case builds a throwaway repo with
# its own index and .gitignore — the same approach the nvim-reachability tests take, and for
# the same reason.
#
# The discriminator under test is the one that makes the gate self-maintaining: a file hidden
# by the BLANKET `.claude/*` is a finding, one named by a MORE SPECIFIC rule is a decision.
# Get that backwards in either direction and the gate either cries wolf on every per-machine
# file or goes silent on the defect it exists for (#700).
if have git; then
  hdr "unreferenced .claude/ scanner (_core_claude_untracked_hits)"
  _cud="$SANDBOX/claudeuntracked"
  _cu_fresh() { # a repo whose .gitignore mirrors Core's: blanket + per-path negations
    rm -rf "$_cud"
    mkdir -p "$_cud/.claude/commands" "$_cud/.claude/agents"
    git -C "$_cud" init -q
    git -C "$_cud" config user.email t@example.com
    git -C "$_cud" config user.name tester
    cat >"$_cud/.gitignore" <<'GI'
.claude/*
!.claude/commands/
!.claude/agents/
!.claude/tool-decisions.md
.claude/settings.local.json
GI
    printf 'cmd\n' >"$_cud/.claude/commands/a.md"
    git -C "$_cud" add -A >/dev/null 2>&1
    git -C "$_cud" commit -qm init >/dev/null 2>&1
  }
  _cu_is() { # _cu_is <label> <expected>
    local got
    got="$(_core_claude_untracked_hits "$_cud")"
    if [[ "$got" == "$2" ]]; then
      pass "unreferenced .claude/ scan: $1"
    else
      fail "unreferenced .claude/ scan: $1 (got '${got//$'\n'/, }', want '${2//$'\n'/, }')"
    fi
  }

  # ── what it must catch ──
  # THE #700 SHAPE, with no reference to betray it: a top-level file under the blanket rule.
  _cu_fresh
  printf 'ledger\n' >"$_cud/.claude/tool-decisions-v2.md"
  _cu_is "a top-level file hidden by the blanket rule is a finding" ".claude/tool-decisions-v2.md"
  # …and #700 itself, exactly: the negations are per-path, so a name one character off the
  # negated one is invisible.
  _cu_fresh
  printf 'x\n' >"$_cud/.claude/tool-decisions.md.bak"
  _cu_is "a near-miss on a negated filename is a finding" ".claude/tool-decisions.md.bak"

  # ── what it must NOT catch ──
  _cu_fresh
  _cu_is "a clean tree yields nothing" ""
  # The negated file, actually tracked — the state the gate wants the tree in.
  _cu_fresh
  printf 'ledger\n' >"$_cud/.claude/tool-decisions.md"
  git -C "$_cud" add -A >/dev/null 2>&1
  git -C "$_cud" commit -qm ledger >/dev/null 2>&1
  _cu_is "a tracked file is not a finding" ""
  # THE EXEMPTION THAT MUST HOLD: its own .gitignore line is a decision, not an oversight.
  # If this regresses, every developer's per-machine settings turn the audit red.
  _cu_fresh
  printf '{}\n' >"$_cud/.claude/settings.local.json"
  _cu_is "a file with its own specific ignore rule is exempt" ""
  # UNTRACKED BUT VISIBLE is deliberately out of scope — inside a negated directory git shows
  # the file in `git status`, so this gate flagging it would red the audit on every
  # work-in-progress file. The scope is invisibility, not un-added-ness.
  _cu_fresh
  printf 'new\n' >"$_cud/.claude/commands/b.md"
  _cu_is "an untracked file git can still SEE is not a finding" ""
  # Degenerate inputs: silence, never a crash or a false claim.
  rm -rf "$_cud"; mkdir -p "$_cud"
  _cu_is "a directory with no .claude/ yields nothing" ""
  rm -rf "$_cud"; mkdir -p "$_cud/.claude"; printf 'x\n' >"$_cud/.claude/f.md"
  _cu_is "a non-git directory yields nothing (no repo, no claim)" ""

  # LIVE CANARY, the _core_claude_ref_hits lesson: every case above is synthetic, so all of
  # them would still pass if .gitignore stopped using the blanket spelling the scanner
  # matches — leaving a gate that is green because it recognises nothing. Assert the real
  # rule still exists in the form the case arm keys on.
  if grep -qxE '\.claude/\*\*?' "$HERE/.gitignore"; then
    pass "unreferenced .claude/ scan: .gitignore still uses the blanket rule the scanner keys on"
  else
    fail "unreferenced .claude/ scan: .gitignore no longer carries a bare '.claude/*' line — _core_claude_untracked_hits keys its finding on that exact pattern, so it now recognises nothing and passes vacuously"
  fi
  rm -rf "$_cud"
  unset -f _cu_fresh _cu_is
  unset _cud
else
  skip "unreferenced .claude/ scanner (git not installed)"
fi

# ── nested-gate failure digest (scripts/lib/common.sh :: _core_fail_digest) ───
# WHY THIS IS TESTED AT ALL. audit-core.sh reports the behavioural suite through this, and its
# whole reason for existing is that an INTERMITTENT failure is unreproducible by the time the
# operator is told to re-run — so the one line that names it has to be right on the FIRST
# occurrence. Every branch below is a QUIET failure: it renders a plausible line and loses the
# name, which is indistinguishable from the flake simply not being nameable. Driven straight on
# fixtures because the alternative — making a real gate fail — means recursively invoking the
# audit or hand-injecting a fault, and CI repeats neither.
hdr "nested-gate failure digest (_core_fail_digest)"
_fdg="$SANDBOX/faildigest"
mkdir -p "$_fdg"
_fdesc="$(printf '\033')"

# 1. COLOUR IS THE ONE THAT WOULD GO QUIET UNNOTICED. fail() prefixes ✗ with $c_red, so an
#    anchored ^✗ finds nothing whenever colour is forced — and the runs where a human forces
#    colour are exactly the runs a human is watching. Fixture carries the real SGR bytes.
{
  printf 'preamble noise\n'
  printf '%s✗%s atuin autostart: the sandbox leaked\n' "${_fdesc}[31m" "${_fdesc}[0m"
  printf '%s✓%s something fine\n' "${_fdesc}[32m" "${_fdesc}[0m"
} >"$_fdg/coloured.txt"
_fdout="$(_core_fail_digest "$_fdg/coloured.txt")"
if [[ "$_fdout" == "1: atuin autostart: the sandbox leaked" ]]; then
  pass "fail digest: a COLOURED ✗ is still extracted (an anchored match would report nothing here)"
else
  fail "fail digest: colour hid the failure — got '$_fdout', want '1: atuin autostart: the sandbox leaked'"
fi

# 2. The count is the TRUE total while only three are named; "+N more" is what keeps that from
#    being a silent truncation. This is the line that tells one flaky assertion apart from a
#    section that is wholly down, which is what decides re-run versus investigate.
: >"$_fdg/many.txt"
for _fdi in alpha beta gamma delta epsilon; do printf '✗ case %s failed\n' "$_fdi" >>"$_fdg/many.txt"; done
_fdout="$(_core_fail_digest "$_fdg/many.txt")"
if [[ "$_fdout" == "5: case alpha failed | case beta failed | case gamma failed (+2 more)" ]]; then
  pass "fail digest: five failures render as three names + a true total (+2 more), not a silent cut"
else
  fail "fail digest: overflow rendering wrong — got '$_fdout'"
fi

# 3. EXACTLY three must not grow a "(+0 more)" tail — an off-by-one here is the kind of wart
#    that gets copied into the next renderer because it looks deliberate.
: >"$_fdg/three.txt"
for _fdi in one two three; do printf '✗ %s\n' "$_fdi" >>"$_fdg/three.txt"; done
_fdout="$(_core_fail_digest "$_fdg/three.txt")"
if [[ "$_fdout" == "3: one | two | three" ]]; then
  pass "fail digest: exactly three names render with no '(+0 more)' tail"
else
  fail "fail digest: boundary at three is wrong — got '$_fdout'"
fi

# 3b. A RECORD IS NOT REWRITTEN TO FIT THE SEPARATOR. The first implementation joined with
#     `tr '\n' '|' | sed 's/|/ | /g'`, which also spaced out every literal `|` INSIDE a
#     message — and nine assertions in this very file contain one, `'exec … || exec …' cannot
#     fall back` among them. Two failures then rendered with four apparent boundaries while
#     the count said 2, inventing structure in the one line someone has when they cannot
#     reproduce the failure. Fixtures use the real offending text rather than a stand-in.
{
  printf "✗ atuin unit: 'exec … || exec …' cannot fall back — exec replaces the process\n"
  printf '✗ serve: plain second failure\n'
} >"$_fdg/pipes.txt"
_fdout="$(_core_fail_digest "$_fdg/pipes.txt")"
if [[ "$_fdout" == "2: atuin unit: 'exec … || exec …' cannot fall back — exec replaces the process | serve: plain second failure" ]]; then
  pass "fail digest: a literal '||' inside a message survives verbatim — the count and the visible boundaries agree"
else
  fail "fail digest: a message's own pipes were rewritten as separators — got '$_fdout'"
fi

# 4. NO MARKER MUST YIELD NOTHING, so the caller can tell "these assertions failed" from "it
#    died before it could report". Rendering an empty list beside a red line would read as zero
#    failures and send the reader hunting a contradiction that is not there; audit-core.sh
#    branches on this emptiness to say "exited N without printing a ✗" instead.
printf 'ran fine\nno markers here\n' >"$_fdg/nomark.txt"
_fdout="$(_core_fail_digest "$_fdg/nomark.txt")"
_fdout2="$(_core_fail_digest "$_fdg/does-not-exist.txt")"
if [[ -z "$_fdout" && -z "$_fdout2" ]]; then
  pass "fail digest: output with no ✗, and an unreadable file, both yield EMPTY so a crash is not misreported as assertions"
else
  fail "fail digest: expected empty for both no-marker ('$_fdout') and missing file ('$_fdout2')"
fi

