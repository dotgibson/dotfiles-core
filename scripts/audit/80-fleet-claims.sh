# scripts/audit/80-fleet-claims.sh
# claims about the fleet: the fan-out count, the callers' pins, the subtree wording, the ²¹ marks
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

# ── 9m. the fan-out count (scripts/os-repos.txt ↔ every claim about it) ──────
# §9l is the hero-tape render-date check (#877), so this takes 9m.
#
# THE SAME SHAPE AS EVERY OTHER §9: one source of truth, many copies, and nothing reading
# the two together. Here the truth is scripts/os-repos.txt — whose own header says "THIS
# FILE IS THE ONLY EDIT" — and the copies are the sentences that say how many repos a Core
# change reaches. #770 found five saying EIGHT against ~20 saying nine, two of them in Core
# files, so the wrong number was replicated nine ways on every sync. #668 had found one of
# the five a year earlier and deliberately left it: correcting one of several inconsistent
# sites makes the tree no more correct, which is the argument for a gate rather than a fix.
#
# KEYED ON THE CLAIM, NOT THE NUMBER — see _core_fanout_count_hits for why. Three different
# numbers are correct here about three different sets (9 vendoring, 8 OS-native, 11 total),
# so a check on the bare number would red on a dozen legitimate lines. Only a sentence whose
# verb says FAN-OUT has committed to which set it counts, and only those are judged.
#
# ADVISORY POSTURE ON AN UNREADABLE FLEET LIST, like §5f's helper-adoption gate: if
# load_os_repos cannot enumerate, this cannot know the right number, and a section that
# does not know must say so rather than fail.
hdr "fan-out count (os-repos.txt ↔ the claims about it)"
if ! load_os_repos; then
  skip_env "fan-out count ($CORE_OS_REPOS_ERR — cannot enumerate the fleet, so the right number is unknown)"
else
  _fc_out="$(_core_fanout_count_hits "$HERE" "${#CORE_OS_REPOS[@]}")"
  if [[ -z "$_fc_out" ]]; then
    pass "fan-out count — every fan-out claim in the tree says ${#CORE_OS_REPOS[@]}, the number os-repos.txt lists"
  else
    fail "a fan-out claim disagrees with scripts/os-repos.txt — the fleet list is the source of truth; fix the prose, not the list"
    fail_detail "$_fc_out"
  fi
  unset _fc_out
fi

# ── 9n. the fleet's CALLER pins (os-repos.txt ↔ each repo's live `uses:`) ─────
# §9l is the hero-tape render-date check (#877), §9m is the fan-out count, so this
# takes 9n.
#
# THE THIRD HALF OF A CHECK THAT ONLY HAD TWO (#804). §8a reads Core's own `ref:` keys;
# §8b reads Core's own comment examples. Neither reads the thing an OS repo actually
# EXECUTES — its live `uses: …/<file>@vN`. So the v5 → v6 caller sweep, 45 pins across 8
# repos, was done entirely by hand and nothing would have reported a repo that was missed.
# #736 predicted this in as many words and expected #672 to close it; #672 closed as "done
# and now gated", but the gating it refers to is §8a — Core's own refs, not the fleet's
# callers.
#
# WHY A MISSED REPO IS WORSE THAN AN ORDINARY STALE PIN. It runs the OUTGOING major's
# reusable workflows. On a major that changes what core-integrity expects — #676 is exactly
# one — that repo's CI reports TAMPERED against a tree nobody touched and its fan-out PR
# cannot merge, which is why RELEASE-RUNBOOK.md §2 makes the caller bump step 1. It is also
# self-healing in the WRONG direction: the repo keeps working until its pinned workflow is
# deleted or diverges, so the failure surfaces long after the release that caused it.
#
# A SHA PIN IS NOT JUDGED, and that is deliberate rather than an oversight: dotfiles-MacBook
# pins by SHA on purpose. This gate answers "which major", not "which pinning style" —
# check-modern.sh owns the latter, and a second opinion here would make it two gates
# wearing one name.
#
# dotfiles-Windows IS OUT OF SCOPE, because scripts/os-repos.txt is the fleet list and it is
# deliberately absent from it (it vendors no core/). That is a real blind spot — it is
# exactly the first of the three that let #805's pin sit a full major behind — but widening
# THIS gate to a repo the fleet list does not contain would put the list and the gate in
# disagreement, which is its own defect. The list is the one place scope lives.
#
# ADVISORY POSTURE ON AN UNREADABLE FLEET LIST and an environment skip on absent siblings,
# exactly like §9c: an absent sibling is genuinely uncovered, and --require-siblings is what
# reds it.
hdr "fleet caller pins (@vN ↔ core.version)"
if [[ ! -r core.version ]]; then
  fail "core.version missing — cannot check the fleet's caller pins"
elif ! load_os_repos; then
  skip_env "fleet caller pins ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  _cp_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ ! "$_cp_major" =~ ^[0-9]+$ ]]; then
    fail "core.version major unreadable ('$_cp_major') — cannot check the fleet's caller pins"
  else
    _cp_root="$(cd "$HERE/.." && pwd)"
    _cp_checked=0 _cp_absent=0 _cp_bad=0 _cp_out=""
    for _cp_repo in "${CORE_OS_REPOS[@]}"; do
      _cp_dir="$(resolve_repo_dir "$_cp_root" "$_cp_repo")" || _cp_dir="$_cp_root/$_cp_repo"
      # `-e`: a linked worktree's .git is a FILE (#850).
      if [[ ! -e "$_cp_dir/.git" ]]; then
        _cp_absent=$((_cp_absent + 1))
        continue
      fi
      _cp_checked=$((_cp_checked + 1))
      _cp_hits="$(_core_caller_pin_hits "$_cp_dir" "$_cp_major")"
      if [[ -n "$_cp_hits" ]]; then
        _cp_bad=$((_cp_bad + 1))
        _cp_out="$_cp_out
$_cp_repo:
$(printf '%s\n' "$_cp_hits" | sed 's/^/  /')"
      fi
    done
    if ((_cp_checked == 0)); then
      skip_env "fleet caller pins (no sibling OS repo checked out — nothing to read here)"
    elif ((_cp_bad)); then
      fail "$_cp_bad of $_cp_checked checked-out repo(s) call a dotfiles-core reusable workflow at a RETIRED major — those jobs run v$_cp_major's body against another major's scripts; bump them (RELEASE-RUNBOOK.md §2)"
      fail_detail "$_cp_out"
    else
      pass "fleet caller pins — every checked-out repo calls @v$_cp_major or pins a SHA ($_cp_checked repo(s))"
    fi
    ((_cp_absent)) && skip_env "fleet caller pins: $_cp_absent repo(s) not checked out — not covered by this run"
    unset _cp_root _cp_checked _cp_absent _cp_bad _cp_out _cp_hits _cp_dir _cp_repo
  fi
  unset _cp_major
fi

# ── 9o. `core/` described as a git subtree (the fleet's markdown) ────────────
# #891, the gate #774 asked for. #587 replaced the fan-out's `git subtree pull --squash`
# with a pinned fetch plus `git read-tree --prefix=core/`; #668 retired the framing from
# Core's docs; #774 swept the eight OS repos' CLAUDE.md by hand. This is what makes the
# next recurrence a checked fact rather than a remembered one.
#
# BLOCKING, and it earned that in one step. Running it for the first time surfaced
# TWENTY-ONE more sites in files #774 never looked at — README.md, CONTRIBUTING.md,
# SECURITY.md and the PR templates, across all nine repos. A hand sweep scoped to one
# filename missed them precisely because it was scoped to one filename, which is the argument
# for the gate. Those landed as nine PRs, and the fleet was re-checked against origin/main
# (0 of 21 remaining, nine repos) before this flipped from advisory — the tree, not the PR
# list, because a repo can regain a line and an environment skip looks like a pass.
#
# KEYED ON THE CLAIM, NOT THE TOKEN — see _core_vendoring_claim_hits for why that is
# forced: two `git subtree` mentions in dotfiles-Offense are CORRECT, one of them a sentence
# arguing this gate's own position, and a blanket scan would red both.
hdr 'vendoring claims (core/ is not a git subtree)'
if ! load_os_repos; then
  skip_env "vendoring claims ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  _vc_root="$(cd "$HERE/.." && pwd)"
  _vc_checked=0 _vc_absent=0 _vc_repos=0 _vc_lines=0 _vc_out=""
  for _vc_repo in "${CORE_OS_REPOS[@]}"; do
    _vc_dir="$(resolve_repo_dir "$_vc_root" "$_vc_repo")" || _vc_dir="$_vc_root/$_vc_repo"
    # `-e`: a linked worktree's .git is a FILE (#850).
    if [[ ! -e "$_vc_dir/.git" ]]; then
      _vc_absent=$((_vc_absent + 1))
      continue
    fi
    _vc_checked=$((_vc_checked + 1))
    _vc_hits="$(_core_vendoring_claim_hits "$_vc_dir")"
    if [[ -n "$_vc_hits" ]]; then
      _vc_repos=$((_vc_repos + 1))
      _vc_lines=$((_vc_lines + $(printf '%s\n' "$_vc_hits" | grep -c .)))
      _vc_out="$_vc_out
$_vc_repo:
$(printf '%s\n' "$_vc_hits" | sed 's/^/  /')"
    fi
  done
  if ((_vc_checked == 0)); then
    skip_env "vendoring claims (no sibling OS repo checked out — nothing to read here)"
  elif ((_vc_repos)); then
    # The fix is upstream in the repo that owns the prose, never here — Core cannot edit it,
    # so the message names the repo and the line rather than offering a command to run.
    fail "$_vc_lines line(s) in $_vc_repos of $_vc_checked repo(s) describe core/ as a git subtree — the fan-out has used a pinned fetch plus read-tree since #587; fix the prose in that repo"
    fail_detail "$_vc_out"
  else
    pass "vendoring claims: no checked-out repo describes core/ as a git subtree ($_vc_checked repo(s))"
  fi
  ((_vc_absent)) && skip_env "vendoring claims: $_vc_absent repo(s) not checked out — not covered by this run"
  unset _vc_root _vc_checked _vc_absent _vc_repos _vc_lines _vc_out _vc_hits _vc_dir _vc_repo
fi

# ── 9p. TOOLS_OPTIN ↔ PORTING-MATRIX.md's cell-level ²¹ marks ────────────────
# #890, out of #836. Three copies of one set, and only two were gated: the matrix's ²¹
# marks (the human contract), Core's _CORE_DOCTOR_OPTIN (the ROW-level set, re-derived and
# asserted by test/65-functions.sh), and each OS repo's TOOLS_OPTIN (the CELL-level marks,
# gated by nothing).
#
# THE MISS ALREADY HAPPENED, and was found by eye rather than by check: `uv` is in
# _CORE_DOCTOR_WIRED, dotfiles-openSUSE installs none and declared no TOOLS_OPTIN, so it fell
# back to Core's default — which does not list uv — and core-doctor rendered a false ✗ on
# every openSUSE box. That is the alarm-fatigue failure the opt-in state exists to prevent,
# and nothing would have caught the next one.
#
# BLOCKING, unlike §9o, and the difference is the state of the fleet rather than a change of
# heart: every covered repo satisfies the rule today (verified against origin/main), so this
# can red on a regression without reddening anything that exists. §9o reports because its
# backlog is real; this fails because its backlog is empty.
#
# FIVE REPOS, NOT NINE. The matrix's package table has columns for Arch, openSUSE, Alpine,
# Gentoo, Kali and Debian/Ubuntu — the last two being one repo. dotfiles-MacBook, -Fedora,
# -Offense and -Defense have no column, so this says nothing about them: the matrix is the
# authority for what it covers and silent about the rest, which is better than inventing a
# verdict for a repo it cannot see.
hdr "TOOLS_OPTIN ↔ matrix ²¹ marks"
if ! load_os_repos; then
  skip_env "TOOLS_OPTIN ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  _to_root="$(cd "$HERE/.." && pwd)"
  # A COVERED repo absent from the box is an environment skip, not a pass: the helper is
  # silent on a directory it cannot read, and silence must never be reported as agreement.
  _to_seen=0
  for _to_repo in dotfiles-Arch dotfiles-openSUSE dotfiles-Alpine dotfiles-Gentoo dotfiles-Debian; do
    [[ -e "$_to_root/$_to_repo/.git" ]] && _to_seen=$((_to_seen + 1))
  done
  if ((_to_seen == 0)); then
    skip_env "TOOLS_OPTIN (none of the five matrix-covered repos checked out — nothing to read here)"
  else
    _to_out="$(_core_tools_optin_hits "$HERE" "$_to_root")"
    if [[ -z "$_to_out" ]]; then
      pass "TOOLS_OPTIN — every checked-out matrix-covered repo declares what its column marks ($_to_seen of 5)"
    else
      fail "a repo's TOOLS_OPTIN disagrees with its PORTING-MATRIX.md column — core-doctor will misreport a tool's absence on every box of that OS"
      fail_detail "$_to_out"
    fi
    unset _to_out
    ((_to_seen < 5)) && skip_env "TOOLS_OPTIN: $((5 - _to_seen)) of the 5 matrix-covered repos not checked out — not covered by this run"
  fi
  unset _to_root _to_seen _to_repo
fi
