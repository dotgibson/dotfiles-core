# scripts/audit/40-fleet-registers.sh
# the fleet registers: helper adoption, secret-scan policy, gate × repo coverage, vocabulary, release triggers, vendoring hints — and leftover conflict markers
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
#
# §5f THROUGH §5i ARE ONE FILE ON PURPOSE. scripts/test/36-bootstrap-lib.sh's --json guard
# scans a LINE RANGE it derives from the `5f.` and `5i.` banners, so those two banners must
# sit in one file's numbering with §5g and the four §5h registers between them. §5i (the
# conflict-marker scan) rides along here as the range's terminator; separating it would
# leave that guard covering half the fleet sections, and the guard fails rather than
# narrows when it finds the banners in two files.
#
# c_yel / c_rst come from common.sh's palette, sourced by the dispatcher; shellcheck's
# file scope cannot see the run's shell scope, exactly as for the scripts/test/ fragments.
# shellcheck disable=SC2154

# ── 5f. bootstrap-lib helper adoption across the fleet (a ratchet) ────────────
# Core ships lib/bootstrap-lib.sh so the shared half of a bootstrap stops being hand-forked
# nine ways. Helpers get ADDED to it over time — usually because one repo hit a bug — and
# nothing has ever checked whether the other eight picked them up. So the file grows a fix
# and the fleet keeps the defect (#516).
#
# Measured adoption, and it is not a hypothetical spread. These are CALL counts — repos
# whose bootstrap.sh really invokes the helper — which is not what the old bare grep gave,
# and is also not the same question as "how many repos are compliant": an EXEMPT repo calls
# nothing and is short of nothing. Both numbers are given, because conflating them is how
# `blib_user_bindirs_on_path` got written up as 8/9 when seven repos call it:
#   blib_resolve_su 8/9 (+1 exempt = 9/9 compliant) ·
#   blib_sudo_keepalive_start 7/9 (+2 exempt = 9/9 compliant) ·
#   blib_user_bindirs_on_path 7/9 (+1 exempt = 8/9 compliant) ·
#   blib_note_fail 8/9 (+1 exempt = 9/9 compliant) · blib_failures_report 9/9 ·
#   blib_wire_summary 8/9 · blib_install_core_guard 7/9 · BLIB_DRY 9/9
#   (the four 1/9 rows went 3/9 → 4/9 → 5/9 → 6/9 → 7/9 → 8/9 on 2026-09-13 as Debian and
#   Fedora, openSUSE, Alpine, Arch, Offense and MacBook adopted, then Defense closed the
#   last row: it adopts the report and is exempt from the other two with the reasons in
#   the case below. Offense lost its keepalive exemption that day and MacBook gained one.
#   #867, #973 — the four rows are compliant fleet-wide.)
#
# Each gap is a live defect in the repos missing it: no blib_resolve_su means a hand-rolled
# `[[ "$(id -u)" -eq 0 ]]`, an ARITHMETIC comparison where an empty `id` output evaluates as
# 0 and the whole run proceeds unescalated; no blib_sudo_keepalive_start means sudo's
# timestamp expires during a long install and the re-prompt goes to a discarded stderr, i.e.
# a silent hang; no blib_failures_report means the script can record failures via
# blib_note_fail and then exit 0 announcing "complete".
#
# WHY THIS IS NO LONGER A BARE COUNTER (#748). The section used to print a fraction per
# repo and stop there. `blib_user_bindirs_on_path 1/9` was in that report from the day it was
# written, and in the meantime the gap it names shipped a live bug: openSUSE's bootstrap
# probed `command -v mise` for a mise its own mise.run install had just written to
# ~/.local/bin — a directory only the SHELL layer prefixes — so the probe was false, the Go
# fallback's every arm failed, and the run exited 2 on EVERY bootstrap. No gate could see it,
# because a stubbed run installs nothing and a real one had never been looked at. Alpine
# carried the identical probe, kept harmless only by an apk-installed `go` masking the broken
# arm. The counter had been reporting the cause the entire time; a number nothing acts on is
# where a defect hides in plain sight.
#
# SO: the measurement is a LEDGER, and the ledger RATCHETS. _core_helper_verdict (lib/
# common.sh) holds the whole judgment and carries the argument for it. In one line: `gap`
# stays advisory, because 8 of 9 repos are short on arrival and a gate that is red on
# arrival is a gate someone turns off — that reasoning was right and is kept. But both
# MOVEMENTS are blocking. A repo that DROPS a helper it had (`regressed`) fails; a repo that
# ADOPTS one nobody recorded (`advanced`) also fails, until the pair below is added. Failing
# on good news is what tightens the ratchet: without it the ledger goes stale, every later
# regression reads as an unremarkable `gap`, and this is a counter again. It is the shape
# gen-porting-matrix.sh's PKG_ROWS already uses for the same reason (CLAUDE.md).
#
# THE LEDGER IS THE ONLY EDIT. Adopt a helper in an OS repo, then add `<repo>` to that
# helper's line here in the same sweep. The audit prints the exact pair to add.
#
# --STRICT SAFETY: the "sibling not checked out" skip goes through skip_env, which records
# it as an ENVIRONMENT skip. --strict counts only TOOL-absent skips, so the SKIPS stay inert
# there — CI checks out only this repo, so the ratchet's fails cannot fire in CI either. It
# used to achieve that by WORDING the skip "out of scope" so the substring classifier would
# let it through, which made the message text the gate and conflated "you narrowed this" with
# "this box cannot run it". The class is structural now, so the wording is free to say what is
# actually true, and --require-siblings can red on precisely this case without touching
# --strict.
#
# Enumerates the fleet through load_os_repos (lib/common.sh) — the ONE reader, since #669
# removed the three hardcoded fallback arrays. This check keeps the skip_env posture rather
# than the fan-out gates' hard exit: an unreadable fleet list should not red an advisory
# section of an otherwise-fine audit, it should say it could not cover the fleet.
hdr "bootstrap-lib helper adoption (ratcheted)"
_ha_root="$(cd "$HERE/.." && pwd)"
if ! load_os_repos; then
  skip_env "helper adoption ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  # ── the ledger ──────────────────────────────────────────────────────────────
  # `<helper> <repo>[ <repo>…]` — the repos whose bootstrap.sh is KNOWN to call that helper.
  # A repo absent from a line is an unclaimed gap: reported, not failed. Kept here rather
  # than in bootstrap-lib.sh so the rationale lives with the check that reports it;
  # VENDORING.md carries the human contract.
  _ha_ledger='
blib_resolve_su          dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Fedora dotfiles-Gentoo dotfiles-MacBook dotfiles-Offense dotfiles-openSUSE
blib_sudo_keepalive_start dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Fedora dotfiles-Gentoo dotfiles-Offense dotfiles-openSUSE
blib_user_bindirs_on_path dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Fedora dotfiles-Gentoo dotfiles-Offense dotfiles-openSUSE
blib_note_fail           dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Fedora dotfiles-Gentoo dotfiles-MacBook dotfiles-Offense dotfiles-openSUSE
blib_failures_report     dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Defense dotfiles-Fedora dotfiles-Gentoo dotfiles-MacBook dotfiles-Offense dotfiles-openSUSE
blib_wire_summary        dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Defense dotfiles-Fedora dotfiles-Gentoo dotfiles-Offense dotfiles-openSUSE
blib_install_core_guard  dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Fedora dotfiles-Gentoo dotfiles-MacBook dotfiles-Offense
BLIB_DRY                 dotfiles-Alpine dotfiles-Arch dotfiles-Debian dotfiles-Defense dotfiles-Fedora dotfiles-Gentoo dotfiles-MacBook dotfiles-Offense dotfiles-openSUSE
blib_main
'
  _ha_checked=0
  _ha_missing=0
  _ha_absent=0
  _ha_fail=0
  for _ha_repo in "${CORE_OS_REPOS[@]}"; do
    _ha_dir="$(resolve_repo_dir "$_ha_root" "$_ha_repo")" || _ha_dir="$_ha_root/$_ha_repo"
    if [[ ! -f "$_ha_dir/bootstrap.sh" ]]; then
      _ha_absent=$((_ha_absent + 1))
      continue
    fi
    _ha_checked=$((_ha_checked + 1))
    _ha_gaps=""
    for _ha_h in blib_resolve_su blib_sudo_keepalive_start blib_user_bindirs_on_path \
      blib_note_fail blib_failures_report blib_wire_summary blib_install_core_guard BLIB_DRY \
      blib_main; do
      # A ROLE repo layers on top of an OS repo's bootstrap and does no package installation
      # of its own, so the helper that exists for long privileged installs does not apply.
      # Exempting it is what keeps the report actionable rather than noisy — the same shape
      # as the doctor's own exemption list.
      #
      # That reasoning has now been wrong for dotfiles-Offense TWICE, and it is exempt from
      # nothing. blib_user_bindirs_on_path first (#748): `--install` there does `go install`
      # into ~/.local/bin and pipx shims beside it, and it had hand-rolled its own
      # `export PATH=` prelude to say so, which the exemption hid. Then the keepalive (#973):
      # the same `--install` runs Kali's whole apt list — "go get coffee", its own comment
      # said — behind a one-shot `sudo -v` that primed once and expired mid-run, the exact
      # invisible-prompt hang blib_sudo_keepalive_start exists for. An exemption is a claim
      # about what a repo does; both times the repo's own file said otherwise.
      # dotfiles-Defense installs nothing and probes nothing, so it stays exempt — and for
      # the same two facts it is exempt from blib_resolve_su (nothing in its bootstrap is
      # privileged; it deliberately declines blib_set_login_shell because that sudo's) and
      # from blib_note_fail (no best-effort step of its own: the host-tool probe is
      # report-only by design, and every write goes through blib_link, which records its
      # own misses). It DOES adopt blib_failures_report, because the scaffold it calls can
      # still record a failure — a tpm clone behind a proxy — and a closing "complete" over
      # that is the exact silence the ledger exists to end (dotfiles-Defense#291).
      #
      # dotfiles-MacBook is exempt from the keepalive for the opposite reason to a role repo:
      # os/macos.capabilities declares NOTHING HERE IS PRIVILEGED (Homebrew refuses root),
      # and the one sudo in its bootstrap is a single `tee -a /etc/shells` behind an
      # interactive confirm on the opt-in --set-shell path — which it now reaches through
      # blib_resolve_su and blib_priv (dotfiles-MacBook#247). A background refresher loop
      # around one write would be theatre, so the row is exempt rather than adopted. If a
      # long privileged install ever appears there, the exemption goes the way Offense's did.
      case "$_ha_repo:$_ha_h" in
      dotfiles-Defense:blib_sudo_keepalive_start | dotfiles-Defense:blib_user_bindirs_on_path | \
        dotfiles-Defense:blib_resolve_su | dotfiles-Defense:blib_note_fail | \
        dotfiles-MacBook:blib_sudo_keepalive_start)
        continue
        ;;
      esac
      _ha_in_led=0
      # One ledger line per helper, matched whole-word at both ends so `blib_note_fail`
      # cannot be answered by a line for some future `blib_note_fail_once`.
      case "$(printf '%s\n' "$_ha_ledger" | grep -E "^${_ha_h}[[:space:]]" || true)" in
      *" $_ha_repo "* | *" $_ha_repo") _ha_in_led=1 ;;
      esac
      # A CALL, not a mention — _core_helper_called strips comments and matches the
      # helper as a whole shell identifier. A bare grep counted a COMMENT, and since an
      # adoption PR's whole shape is "add the call, explain why", deleting the call and
      # leaving the paragraph behind kept that grep green. It was already inflating three
      # rows before this section grew a ledger at all: dotfiles-MacBook was credited with
      # blib_note_fail + blib_failures_report on the strength of four comment lines (it
      # has its own fail_note/print_ledger), and dotfiles-Fedora with blib_resolve_su on
      # one comment reading "same fix landed upstream in blib_resolve_su". The measured
      # figures in this section's header were wrong by three, in the flattering direction.
      _ha_present=0
      _core_helper_called "$_ha_dir/bootstrap.sh" "$_ha_h" && _ha_present=1
      # A repo on the DRIVER (#976) calls every helper through blib_main rather than by
      # name, so the name is absent from its bootstrap.sh and present in its behaviour.
      # Credit the whole contract to it; the driver's own row ratchets like the rest.
      ((_ha_present)) || { _core_helper_called "$_ha_dir/bootstrap.sh" blib_main && _ha_present=1; }
      case "$(_core_helper_verdict "$_ha_in_led" "$_ha_present")" in
      ok) ;;
      gap) _ha_gaps="$_ha_gaps $_ha_h" ;;
      regressed)
        _ha_fail=1
        fail "helper adoption: $_ha_repo no longer calls $_ha_h — the ledger records it as adopted (a repo lost a helper, or audit-core.sh §5f's ledger landed ahead of that repo's adoption PR)"
        ;;
      advanced)
        _ha_fail=1
        fail "helper adoption: $_ha_repo now calls $_ha_h and the ledger does not say so — ratchet it: add \`$_ha_repo\` to the \`$_ha_h\` line in audit-core.sh §5f"
        ;;
      esac
    done
    if [[ -n "$_ha_gaps" ]]; then
      _ha_missing=$((_ha_missing + 1))
      ((${CORE_JSON:-0})) || printf '  %s%s%s %s does not call:%s\n' "${c_yel}" "•" "${c_rst}" "$_ha_repo" "$_ha_gaps"
    fi
  done

  if ((_ha_checked == 0)); then
    skip_env "helper adoption (no sibling OS repo checked out — nothing to read here)"
  elif ((_ha_fail)); then
    : # the fail() lines above are the report; a pass() here would contradict them
  elif ((_ha_missing)); then
    # pass(), not fail(): an unclaimed gap is the on-arrival state — see the ratchet note
    # above. The per-repo lines printed just above are the detail.
    pass "helper adoption: ledger holds; $_ha_missing of $_ha_checked checked-out repo(s) still short of the full contract (advisory — VENDORING.md has it)"
  else
    pass "helper adoption: every checked-out OS repo calls the whole bootstrap-lib contract ($_ha_checked repo(s))"
  fi
  ((_ha_absent)) && skip_env "helper adoption: $_ha_absent repo(s) not checked out — not covered by this run"
fi

# ── 5g. the secret-scan policy, in the files §5f cannot see ──────────────────
# §5f reports which repos have not adopted lib/bootstrap-lib.sh's helpers, and it greps
# bootstrap.sh ONLY. The identical drift class — Core grows a capability, some repos keep a
# hand-rolled predecessor, nothing notices — lives in the WORKFLOW and MAKEFILE dimension too,
# and it went red across four repos on the 2026-08-23 sync (#623).
#
# WHAT HAPPENED. Core's gitleaks.toml narrows one false-positive class: a credential position
# holding a VARIABLE REFERENCE rather than a value. Core's reusable lint-call.yml secrets leg
# states the rule — "ONE POLICY FILE, Core's … no repo can widen its own allowlist" — and
# passes -c accordingly. Four repos ran their own gitleaks with no config at all, so they used
# the stock rule set, where `curl-auth-user` matches on credential-shaped POSITION rather than
# content. The vendored core/CHANGELOG.md documents that very allowlist and quotes the example
# it was written for, so CORE'S EXPLANATION OF THE RULE READ AS A VIOLATION OF IT, on a sync
# that carried no credential. Two further repos were green only because each keeps its own root
# .gitleaks.toml that gitleaks auto-discovers — the same defect failing in the quiet direction,
# which is worse: a private allowlist can widen over time with nothing comparing it to Core's,
# and the next person to look sees a passing gate (#624).
#
# TWO CHECKS, because they are two different claims and each must be able to be true alone:
#   (a) every `gitleaks dir|detect|git` invocation carries a config flag at all
#       (scripts/lib/common.sh :: _core_gitleaks_policy_hits, fixture-tested both directions);
#   (b) a repo-local .gitleaks.toml must `[extend]` core/gitleaks.toml, so a repo can ADD a
#       distro-specific rule without silently DROPPING the fleet's.
# A repo that legitimately needs local rules is not doing anything wrong; replacing Core's
# policy rather than extending it is.
#
# BLOCKING as of #624 — it shipped advisory, for the reason §5f gives: repos are short on
# arrival, and a gate that is red from its first run is a gate someone turns off. That reason
# has expired. The fleet is clean: dotfiles-Alpine and dotfiles-Gentoo each carried a private
# .gitleaks.toml that gitleaks auto-discovered, so every local scan there ran under a rule set
# that was simultaneously narrower than Core's (stock defaults, Core's variable-reference
# allowlist dropped) and wider (whole-path exemptions). Both are gone, both verified clean under
# core/gitleaks.toml — working tree and, for Gentoo, all 271 commits of history. All 9 repos now
# measure the same way, so this can hold the line instead of narrating it. Same move §5i makes,
# for the same stated reason.
#
# The failure is quiet by nature — a private allowlist widens over time with nothing comparing
# it to Core's, and the next person to look sees a passing gate. Advisory is the wrong posture
# for a finding whose whole hazard is that it looks fine.
#
# Same skip_env (ENVIRONMENT) class as §5f — --strict counts only TOOL-absent skips, so this
# is inert there (CI checks out only this repo) and bites locally and in any sweep that clones
# the fleet. --require-siblings is what makes an absent sibling red.
hdr "secret-scan policy adoption"
_gp_root="$(cd "$HERE/.." && pwd)"
if ! load_os_repos; then
  skip_env "gitleaks policy ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  _gp_checked=0
  _gp_bad=0
  _gp_absent=0
  for _gp_repo in "${CORE_OS_REPOS[@]}"; do
    _gp_dir="$(resolve_repo_dir "$_gp_root" "$_gp_repo")" || _gp_dir="$_gp_root/$_gp_repo"
    # `-e`: a linked worktree's .git is a FILE (#850).
    if [[ ! -e "$_gp_dir/.git" ]]; then
      _gp_absent=$((_gp_absent + 1))
      continue
    fi
    _gp_checked=$((_gp_checked + 1))
    _gp_gaps=""
    # (a) invocations with no policy at all
    for _gp_f in "$_gp_dir"/Makefile "$_gp_dir"/.github/workflows/*.yml "$_gp_dir"/.github/workflows/*.yaml; do
      [[ -f "$_gp_f" ]] || continue # unmatched glob stays literal (nullglob is off)
      _gp_h="$(_core_gitleaks_policy_hits "$_gp_f")"
      [[ -n "$_gp_h" ]] || continue
      _gp_gaps="$_gp_gaps
      ${_gp_f#"$_gp_dir"/}: $(printf '%s' "$_gp_h" | sed 's/:no-config//' | tr '\n' ',' | sed 's/,$//') — gitleaks runs with no -c/--config, so the STOCK rule set applies, not Core's"
    done
    # (b) a private config that replaces Core's instead of extending it
    if [[ -f "$_gp_dir/.gitleaks.toml" ]] &&
      ! grep -qE '^[[:space:]]*path[[:space:]]*=.*core/gitleaks\.toml' "$_gp_dir/.gitleaks.toml"; then
      _gp_gaps="$_gp_gaps
      .gitleaks.toml: a private rule set that does not [extend] core/gitleaks.toml — gitleaks auto-discovers it, so EVERY scan here silently runs under it"
    fi
    if [[ -n "$_gp_gaps" ]]; then
      _gp_bad=$((_gp_bad + 1))
      ((${CORE_JSON:-0})) || printf '  %s%s%s %s%s\n' "${c_yel}" "•" "${c_rst}" "$_gp_repo" "$_gp_gaps"
    fi
  done

  if ((_gp_checked == 0)); then
    skip_env "gitleaks policy (no sibling OS repo checked out — nothing to read here)"
  elif ((_gp_bad)); then
    fail "gitleaks policy: $_gp_bad of $_gp_checked checked-out repo(s) do not measure by Core's policy (see the lines above; VENDORING.md has the contract)"
  else
    pass "gitleaks policy: every checked-out OS repo scans under Core's policy ($_gp_checked repo(s))"
  fi
  ((_gp_absent)) && skip_env "gitleaks policy: $_gp_absent repo(s) not checked out — not covered by this run"
fi

# ── 5h. the gate x repo coverage register ────────────────────────────────────
# Coverage used to be inferred by reading the `uses:` lines in each repo's workflows, and
# that inference is WRONG for any repo that satisfies a gate its own way. It has misfired
# twice, identically, both times in good faith: dotfiles-MacBook#154 (the RETURN-trap gate,
# ported by hand) and dotfiles-MacBook#178 (the provision-stub job, already gated on the
# macOS leg via a BOOTSTRAP_BREW seam). Same failure mode two gates apart, because a rollout
# audit had no way to tell "not covered" from "covered elsewhere" (#607).
#
# scripts/fleet-coverage.sh derives the `reusable` cells from each repo's real `uses:` lines
# and reads .github/core-gates.txt for the ones that cannot be derived. This asserts every
# cell is filled — so a NEW reusable workflow cannot ship without each repo declaring a
# position on it, which is the property that makes the register stay true.
#
# Advisory and "out of scope"-skipped when siblings are absent, like §5f/§5g.
hdr "gate x repo coverage register (advisory)"
if [[ ! -x "$HERE/scripts/fleet-coverage.sh" ]]; then
  skip "coverage register (scripts/fleet-coverage.sh missing — out of scope)"
else
  _fc_out="$("$HERE/scripts/fleet-coverage.sh" --check 2>&1)"
  _fc_rc=$?
  if [[ "$_fc_out" == *"no sibling repo checked out"* ]]; then
    skip_env "coverage register (no sibling OS repo checked out — nothing to read here)"
  elif [[ "$_fc_out" == *"fleet list "* ]]; then
    # It could not build the register at all (#669), which is not the same finding as
    # "some cells are undeclared" — reporting it as the latter would name a cause that is
    # not there and hide the one that is.
    skip_env "coverage register (fleet list would not load — cannot enumerate the fleet)"
  elif ((_fc_rc == 0)); then
    pass "coverage register: $_fc_out"
  elif ((_fc_rc == 1)); then
    # pass(), not fail(): see REPORT, DO NOT BLOCK on §5f. Exit 1 is the reporter's
    # verdict; anything else is the reporter itself failing, which is red below (#846).
    ((${CORE_JSON:-0})) || printf '%s\n' "$_fc_out" | sed 's/^/  /'
    pass "coverage register: undeclared gate x repo cell(s) — advisory; each repo declares in .github/core-gates.txt (VENDORING.md has the contract)"
  else
    fail "coverage register: scripts/fleet-coverage.sh exited $_fc_rc — the reporter is broken, not the fleet"
    fail_detail "$_fc_out"
  fi
  unset _fc_out _fc_rc
fi

# ── 5h (cont.) the Makefile vocabulary x repo register, and the test floor ────
# The surface a contributor actually touches was a convention, and it failed measurably:
# "dry run" had two spellings across the fleet, "verify core" had five, and only `help`
# was common to every Makefile (#691). Five of nine repos had no repo-owned tests at all —
# including dotfiles-Fedora, the template every Linux repo is stamped from.
#
# scripts/make-vocabulary.txt declares the canonical verbs ONCE; scripts/fleet-vocabulary.sh
# reads each sibling's Makefile and reports, per verb, whether the canonical target resolves
# (an alias TO it is fine — the requirement is that the canonical name resolves; a verb a
# repo genuinely lacks is a stub target that says so, never declared away)
# and whether the repo meets the test floor: a test/ (or tests/) directory with content,
# run from a workflow. Same shape as the register above and the same advisory posture —
# this is fleet drift, not a regression in the commit under test. dotfiles-Windows rides
# as a last row read by name (#855): the same verbs, spelled `.\task.ps1 <verb>`.
hdr "Makefile vocabulary x repo register + test floor (advisory)"
if [[ ! -x "$HERE/scripts/fleet-vocabulary.sh" ]]; then
  skip "vocabulary register (scripts/fleet-vocabulary.sh missing — out of scope)"
else
  _fv_out="$("$HERE/scripts/fleet-vocabulary.sh" --check 2>&1)"
  _fv_rc=$?
  if [[ "$_fv_out" == *"no sibling repo checked out"* ]]; then
    skip_env "vocabulary register (no sibling OS repo checked out — nothing to read here)"
  elif [[ "$_fv_out" == *"vocabulary list "* ]]; then
    # The CONTRACT itself — scripts/make-vocabulary.txt, in this repo — would not load.
    # That is Core broken, not an environment short of siblings: red, never a skip.
    fail "vocabulary register: scripts/make-vocabulary.txt would not load — the contract is unreadable or empty"
    fail_detail "$_fv_out"
  elif [[ "$_fv_out" == *"fleet list "* ]]; then
    # Could not enumerate the fleet at all — not the same finding as "cells are missing".
    skip_env "vocabulary register (fleet list would not load — cannot enumerate the fleet)"
  elif ((_fv_rc == 0)); then
    pass "vocabulary register: $_fv_out"
  elif ((_fv_rc == 1)); then
    # pass(), not fail(): see REPORT, DO NOT BLOCK on §5f. Exit 1 is the reporter's
    # verdict; anything else is the reporter itself failing, which is red below.
    ((${CORE_JSON:-0})) || printf '%s\n' "$_fv_out" | sed 's/^/  /'
    pass "vocabulary register: missing verb(s) or repo(s) under the test floor — advisory; scripts/make-vocabulary.txt is the contract (VENDORING.md has the alias recipe)"
  else
    fail "vocabulary register: scripts/fleet-vocabulary.sh exited $_fv_rc — the reporter is broken, not the fleet"
    fail_detail "$_fv_out"
  fi
  unset _fv_out _fv_rc
fi

# ── 5h (cont.) the release-trigger register ──────────────────────────────────
# The register above answers "who calls auto-tag-call?" and reported `reusable` for all
# nine repos — green, while six of them cut a tag ONLY when a Core fan-out landed. Right
# answer, wrong question (#696): calling the gate is not the same as the gate releasing
# anything this repo owns. On dotfiles-Fedora that meant seven Core syncs → seven
# releases and six native commits → zero, with the tag attributed to "Core moved".
#
# scripts/fleet-release-triggers.sh reads each sibling's .github/workflows/auto-tag.yml
# and reports two things: whether its path filter watches anything outside core/, and
# whether a deliberate non-patch bump is reachable without editing the file (the `bump`
# input existed from the start and no caller had ever passed one). Same shape as the two
# registers above, same advisory posture — this is fleet drift, not a regression in the
# commit under test, and Core's own fix is the caller shape it documents.
hdr "release-trigger register (advisory)"
if [[ ! -x "$HERE/scripts/fleet-release-triggers.sh" ]]; then
  skip "release-trigger register (scripts/fleet-release-triggers.sh missing — out of scope)"
else
  _fr_out="$("$HERE/scripts/fleet-release-triggers.sh" --check 2>&1)"
  _fr_rc=$?
  if [[ "$_fr_out" == *"no sibling repo checked out"* ]]; then
    skip_env "release-trigger register (no sibling OS repo checked out — nothing to read here)"
  elif [[ "$_fr_out" == *"fleet list "* ]]; then
    # Could not enumerate the fleet at all — not the same finding as "repos have findings".
    skip_env "release-trigger register (fleet list would not load — cannot enumerate the fleet)"
  elif ((_fr_rc == 0)); then
    pass "release-trigger register: $_fr_out"
  elif ((_fr_rc == 1)); then
    # pass(), not fail(): see REPORT, DO NOT BLOCK on §5f. Exit 1 is the reporter's
    # verdict; anything else is the reporter itself failing, which is red below.
    ((${CORE_JSON:-0})) || printf '%s\n' "$_fr_out" | sed 's/^/  /'
    pass "release-trigger register: repo(s) releasing only on Core syncs, or unable to cut a non-patch — advisory; .github/workflows/auto-tag-call.yml documents the caller shape"
  else
    fail "release-trigger register: scripts/fleet-release-triggers.sh exited $_fr_rc — the reporter is broken, not the fleet"
    fail_detail "$_fr_out"
  fi
  unset _fr_out _fr_rc
fi

# ── 5h (cont.) the vendoring-hint register ───────────────────────────────────
# Every OS repo prints a hint when core/ is missing or half-vendored, and eight of nine
# printed a WRONG one: `git subtree add ... main --squash` to create and `git subtree pull`
# to update. Vendoring from a branch is not the commit the fan-out pins, so core-integrity
# reports the fresh repo as TAMPERED; `git subtree pull` moves core/ without core.lock and
# merges the whole tree rather than the vendor set (#676). The hint fires exactly when a
# user is already repairing a broken clone, so it handed them the two commands that make it
# worse (dotgibson/dotfiles-Arch#158 and the fleet sweep behind it).
#
# THE FIX EXISTED AND DID NOT PROPAGATE — which is what this register is really for.
# dotfiles-MacBook had the correct "released tag, never main" warning the whole time;
# nothing read the other eight to notice they disagreed. Then MacBook's own hint went stale
# at the v4 major against a v7 fleet, landing in the same TAMPERED state its warning exists
# to prevent. So the register asserts the guidance is RIGHT (a tag, not a branch; no subtree
# pull for core/) and CURRENT (the tag's major matches core.version, derived at run time —
# the day Core cuts v8 every stale v7 hint reports itself).
#
# Advisory, like the three registers above and for the same reason: a sibling can drift
# without Core changing, so this is fleet drift rather than a regression in the commit under
# test. Core's own VENDORING.md row is the exception in spirit — but a per-row posture would
# be more machinery than the finding is worth.
hdr "vendoring-hint x repo register (advisory)"
if [[ ! -x "$HERE/scripts/fleet-vendor-guidance.sh" ]]; then
  skip "vendoring-hint register (scripts/fleet-vendor-guidance.sh missing — out of scope)"
else
  _vg_out="$("$HERE/scripts/fleet-vendor-guidance.sh" --check 2>&1)"
  _vg_rc=$?
  if [[ "$_vg_out" == *"no sibling repo checked out"* ]]; then
    skip_env "vendoring-hint register (no sibling OS repo checked out — nothing to read here)"
  elif [[ "$_vg_out" == *"core.version unreadable"* ]]; then
    # The expected major could not be DERIVED, so the register has no contract to judge
    # against. Core broken, not an environment short of siblings: red, never a skip —
    # "every hint is current" against an empty expectation is the green-because-absent
    # result skip_env exists to avoid.
    fail "vendoring-hint register: core.version would not load — cannot derive the expected tag major"
    fail_detail "$_vg_out"
  elif [[ "$_vg_out" == *"fleet list "* ]]; then
    # Could not enumerate the fleet at all — not the same finding as "hints are stale".
    skip_env "vendoring-hint register (fleet list would not load — cannot enumerate the fleet)"
  elif ((_vg_rc == 0)); then
    pass "vendoring-hint register: $_vg_out"
  elif ((_vg_rc == 1)); then
    # pass(), not fail(): see REPORT, DO NOT BLOCK on §5f. Exit 1 is the reporter's
    # verdict; anything else is the reporter itself failing, which is red below.
    ((${CORE_JSON:-0})) || printf '%s\n' "$_vg_out" | sed 's/^/  /'
    pass "vendoring-hint register: core/ vendoring hint(s) pinning a branch, a stale major, or using subtree pull — advisory; VENDORING.md has the one-time vendor recipe"
  else
    fail "vendoring-hint register: scripts/fleet-vendor-guidance.sh exited $_vg_rc — the reporter is broken, not the fleet"
    fail_detail "$_vg_out"
  fi
  unset _vg_out _vg_rc
fi

# ── 5i. leftover conflict markers (tracked files) ────────────────────────────
# A conflict resolved by hand can leave a marker behind, and bcdd7dd (#650) did exactly
# that: a literal base marker landed in CHANGELOG.md at the end of [Unreleased]'s Fixed
# section and sat on main undetected. Under zdiff3 a conflict has FOUR marker lines, not
# three, and the base one is the half people forget because it only exists in that style.
#
# WHY IT BLOCKS RATHER THAN REPORTS, unlike §5f/§5g above: this is not fleet drift that
# arrives red on seven repos. The tree is clean today (measured: zero hits across every
# tracked file), so the gate is green on arrival and every future hit is a genuine
# regression introduced by the commit under test. That is the condition §5f names for
# turning an advisory check into a failing one.
#
# WHY IT IS WORTH A GATE. git refuses to parse a conflict region containing a stray
# marker — rebasing onto the affected main produced `error: could not parse conflict
# hunks in CHANGELOG.md` — and CONTRIBUTING.md requires every user-visible change to
# touch [Unreleased], so one marker there taxes every future branch. Nothing else sees
# it: `bash -n`/`zsh -n` never read markdown, markdownlint reads the line as ordinary
# paragraph text, and gitleaks is looking for credentials.
#
# NO ALLOWLIST, ON PURPOSE. The obvious design is to exempt the files that legitimately
# CONTAIN markers — this script, the matcher, the test fixtures. None of them need it:
# scripts/lib/common.sh assembles its patterns from fragments (the discipline §5d/§5e
# already follow), and test-core.sh writes its fixtures into $SANDBOX at run time, so
# they are never tracked and never scanned. An allowlist would be a hole in the one gate
# whose value is that it has none. A doc that genuinely must SHOW a marker indents it by
# one space — column 0 is what git keys on, and what this gate keys on.
#
# Scope is every tracked text file, not just shell: the defect that motivated this was in
# markdown. Binaries are skipped by the matcher's `grep -I` (assets/ carries images).
hdr "leftover conflict markers"
cm_fail=0
while IFS= read -r cm_f; do
  [ -n "$cm_f" ] || continue
  while IFS= read -r cm_line; do
    [ -n "$cm_line" ] || continue
    fail "conflict marker: $cm_f:$cm_line — a resolution left a VCS marker behind; git cannot parse a conflict region containing one. Delete it (under zdiff3 a conflict has FOUR marker lines, and the base one is the half that gets missed)"
    cm_fail=1
  done <<EOF
$(_core_conflict_marker_hits "$cm_f")
EOF
done <<EOF
$(_audit_ls '*')
EOF
((cm_fail)) || pass "conflict markers (no tracked file carries a leftover marker)"
