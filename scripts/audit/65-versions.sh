# scripts/audit/65-versions.sh
# version consistency, the os.capabilities schema and its fleet coverage, tool download integrity
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
# FOUR SECTIONS, TWO CROSS-READS, ONE FILE: §9 sets VERSIONS_ENV for §9b, and §9a sets
# CAP_CHECK for §9c. The file order 9 · 9a · 9c · 9b is the order the sections have always
# run in and is preserved verbatim — the letters are addition order, the position is the
# dependency.
#
# c_yel / c_rst come from common.sh's palette, sourced by the dispatcher; shellcheck's
# file scope cannot see the run's shell scope, exactly as for the scripts/test/ fragments.
# shellcheck disable=SC2154

# ── 9. version consistency (tool-versions.env ↔ .pre-commit-config.yaml) ──────
# scripts/tool-versions.env is the SINGLE SOURCE for the pinned dev-tool versions.
# CI loads it directly (no literals left in ci.yml), but .pre-commit-config.yaml is
# static YAML that can't read it — so the hook `rev:` fields are the one place a pin
# can still drift. Gate them: assert each hook rev equals its version here. A bump in
# one place without the other fails the audit instead of silently shipping mismatched
# author-time vs CI tooling. Pure bash + awk (busybox-safe); skips if either is gone.
hdr "version consistency (tool-versions.env ↔ pre-commit)"
VERSIONS_ENV="scripts/tool-versions.env"
PRECOMMIT_CFG=".pre-commit-config.yaml"
if [[ -r "$VERSIONS_ENV" && -r "$PRECOMMIT_CFG" ]]; then
  _ver() { sed -n "s/^$1=//p" "$VERSIONS_ENV" | head -n1; }
  # The rev: line immediately following a given repo: line in the pre-commit config.
  _pc_rev() { awk -v r="$1" '$0 ~ "repo:.*" r {f=1} f && $1=="rev:" {print $2; exit}' "$PRECOMMIT_CFG"; }
  _check_pin() { # _check_pin <repo-substr> <env-key> <label>
    local want got
    want="v$(_ver "$2")"
    got="$(_pc_rev "$1")"
    if [[ -n "$got" && "$got" == "$want" ]]; then
      pass "pre-commit $3 rev $got == tool-versions.env"
    else
      fail "pre-commit $3 rev '${got:-<none>}' != tool-versions.env '$want' — bump one to match"
    fi
  }
  _check_pin "koalaman/shellcheck-precommit" SHELLCHECK_VERSION shellcheck
  _check_pin "DavidAnson/markdownlint-cli2" MARKDOWNLINT_VERSION markdownlint
  _check_pin "gitleaks/gitleaks" GITLEAKS_VERSION gitleaks
  _check_pin "pre-commit/pre-commit-hooks" PRECOMMIT_HOOKS_VERSION pre-commit-hooks
else
  skip "version consistency ($VERSIONS_ENV or $PRECOMMIT_CFG unreadable)"
fi

# ── 9a. os.capabilities schema (the shipped example is held to the fleet's gate) ──
# scripts/check-capabilities.sh defines the v5 capability schema (#663) and is the
# validator each OS repo runs on its own os/<os>.capabilities. Core has no declaration
# of its own — it is the CONSUMER, not an OS layer — so what there is to gate here is
# the EXAMPLE the nine repos copy from.
#
# That is not a formality. examples/os.capabilities.example is the thing a human reads
# when authoring a real one (#667), so an example carrying a key the validator rejects
# would hand every OS repo the same defect nine times, and Core's own reader would skip
# it in silence. Running the fleet's gate on the fleet's template closes that: the
# example cannot drift from the schema without reddening this audit.
hdr "os.capabilities schema (example ↔ validator)"
CAP_CHECK="scripts/check-capabilities.sh"
CAP_EXAMPLE="examples/os.capabilities.example"
if [[ -x "$CAP_CHECK" && -r "$CAP_EXAMPLE" ]]; then
  if cap_out="$("$CAP_CHECK" "$CAP_EXAMPLE" 2>&1)"; then
    pass "os.capabilities example validates against the schema"
  else
    while IFS= read -r cap_line; do
      [ -n "$cap_line" ] || continue
      fail "os.capabilities: $cap_line"
    done <<EOF
$cap_out
EOF
  fi
else
  skip "os.capabilities schema ($CAP_CHECK or $CAP_EXAMPLE missing)"
fi

# ── 9c. os.capabilities fleet coverage (every OS repo declares, and it validates) ──
# The FLEET half of §9a. That section holds Core's shipped example to the schema; this
# one holds the repos that actually run on real boxes to it (#667).
#
# Numbered 9c and not 9b because a CHANGELOG entry already pins "section 9b" to the
# tool-integrity check above; renumbering that would falsify a shipped release note.
#
# WHY THE GATE LIVES HERE AND NOT ONLY IN EACH REPO. Every declaring repo runs the same
# validator from its own `make lint`, which catches a BROKEN declaration. Only a
# fleet-wide sweep catches a MISSING one — a repo that never authored a file has nothing
# for a per-repo target to fail on, and the absence is invisible from inside it. That is
# the failure this section exists for, and it is the state the whole fleet was in before
# #667: nine repos, zero declarations, `blib_link_os_layer`'s `[[ -f ]]` guard linking
# nothing, and every consumer silently on Core's built-in fallback rows.
#
# TWO FINDINGS, TWO SEVERITIES, AND THE SPLIT IS LOAD-BEARING.
#
#   a malformed declaration  BLOCKING. The repo authored one and got it wrong; nothing
#                            about the release cycle makes that temporarily acceptable.
#   no declaration at all    ADVISORY, for one release cycle.
#
# THE SECOND ONE SHIPPED BLOCKING AND DEADLOCKED THE FAN-OUT. scripts/sync-core.sh runs
# `make audit` over a fleet checkout BEFORE it vendors anything — deliberately, so a red
# tree never reaches nine repos. But a declaration cannot be merged into an OS repo until
# that repo has vendored the Core whose validator accepts it, and that vendoring IS the
# fan-out. So a blocking "you have no declaration" refused to fan out the very release
# that would let the declarations land. v5.4.0 published, the fan-out failed, and zero
# vendor PRs opened.
#
# This is the same red-on-arrival shape §5f and the owned-block gate in lint-call.yml both
# name, and both answer the same way: warn for a cycle, then flip. It is also the shape
# THIS FILE's own lint-call.yml step already got right — that step makes a missing
# declaration advisory and a malformed one blocking, and the asymmetry with this section
# was the defect, not the reasoning there.
#
# FLIP IT TO BLOCKING once `make fleet-drift` shows every OS repo carrying a declaration —
# a three-line change, and the tracking issue is #763's sibling.
#
# THE ROLE-REPO EXEMPTION IS STRUCTURAL, NOT A NAME LIST. dotfiles-Offense and
# dotfiles-Defense sit ON TOP of an OS-native layer rather than being one: neither has an
# os/ directory, neither calls blib_link_os_layer, and the OS band belongs to the repo
# underneath them. So the test is "does this repo have an os/ directory" — a repo that
# grows one starts being gated automatically, and a hardcoded pair of names could not do
# that. It also picks up per-tier declarations for free: dotfiles-Debian ships
# os/debian.capabilities plus os/debian.kali.capabilities, dotfiles-openSUSE ships a Leap
# twin, and the glob validates each without this section knowing they exist.
#
# --packages IS PASSED ONLY WHERE THERE IS A LIST TO PASS. dotfiles-MacBook declares its
# packages in a Brewfile, not install/packages.txt, and feeding a Brewfile to a reader
# that takes the first token of each line would test `brew` against `brew` and report
# nonsense. The cross-check is opt-in for exactly this reason.
#
# Same skip_env (ENVIRONMENT) class as §5f and the gitleaks section: --strict counts only
# TOOL-absent skips, so this is inert in CI (which checks out this repo alone) and bites
# locally and in any sweep that clones the fleet. --require-siblings is what reds an
# absent sibling.
hdr "os.capabilities fleet coverage"
_cf_root="$(cd "$HERE/.." && pwd)"
if [[ ! -x "$CAP_CHECK" ]]; then
  skip "os.capabilities fleet coverage ($CAP_CHECK missing)"
elif ! load_os_repos; then
  skip_env "os.capabilities fleet coverage ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  _cf_checked=0
  _cf_bad=0
  _cf_absent=0
  _cf_role=0
  _cf_undeclared=0
  for _cf_repo in "${CORE_OS_REPOS[@]}"; do
    _cf_dir="$(resolve_repo_dir "$_cf_root" "$_cf_repo")" || _cf_dir="$_cf_root/$_cf_repo"
    # `-e`: a linked worktree's .git is a FILE (#850).
    if [[ ! -e "$_cf_dir/.git" ]]; then
      _cf_absent=$((_cf_absent + 1))
      continue
    fi
    # No os/ directory → a Role repo, which has no OS band to declare for.
    if [[ ! -d "$_cf_dir/os" ]]; then
      _cf_role=$((_cf_role + 1))
      continue
    fi
    _cf_checked=$((_cf_checked + 1))
    _cf_gaps=""
    _cf_found=0
    # Unmatched globs stay LITERAL here (nullglob is off), so every hit is tested with
    # -e before it is used — otherwise a repo with no declaration would "validate" a file
    # named os/*.capabilities and this gate would pass on nothing, which is the one
    # outcome a coverage check must never produce.
    _cf_pkgs="$_cf_dir/install/packages.txt"
    for _cf_f in "$_cf_dir"/os/*.capabilities; do
      [[ -e "$_cf_f" ]] || continue
      _cf_found=$((_cf_found + 1))
      if [[ -r "$_cf_pkgs" ]]; then
        _cf_out="$("$CAP_CHECK" "$_cf_f" --packages "$_cf_pkgs" 2>&1)" || _cf_gaps="$_cf_gaps
      ${_cf_f#"$_cf_dir"/}: $(printf '%s' "$_cf_out" | grep '^FAIL' | tr '\n' ';' | sed 's/;$//')"
      else
        _cf_out="$("$CAP_CHECK" "$_cf_f" 2>&1)" || _cf_gaps="$_cf_gaps
      ${_cf_f#"$_cf_dir"/}: $(printf '%s' "$_cf_out" | grep '^FAIL' | tr '\n' ';' | sed 's/;$//')"
      fi
    done
    # UNDECLARED IS COUNTED SEPARATELY FROM MALFORMED — see the header. Rolling it into
    # _cf_gaps is what made this blocking and deadlocked the fan-out.
    if ((_cf_found == 0)); then
      _cf_undeclared=$((_cf_undeclared + 1))
      ((${CORE_JSON:-0})) || printf '  %s%s%s %s\n      no os/*.capabilities — Core is running its built-in fallback rows here (see examples/os.capabilities.example)\n' \
        "${c_yel}" "•" "${c_rst}" "$_cf_repo"
      continue
    fi
    if [[ -n "$_cf_gaps" ]]; then
      _cf_bad=$((_cf_bad + 1))
      ((${CORE_JSON:-0})) || printf '  %s%s%s %s%s\n' "${c_yel}" "•" "${c_rst}" "$_cf_repo" "$_cf_gaps"
    fi
  done

  # A ROLE REPO IS REPORTED IN THE PASS LINE, NOT AS A SKIP, and the distinction is not
  # cosmetic. `skip` means "this gate did not run"; --strict reds on any skip that is not
  # an environment or out-of-scope one, and _core_tool_skip_count classifies exactly that
  # way. But a Role repo carrying no declaration is the CORRECT answer, fully determined
  # by this run — nothing went unchecked. Emitting it as a skip made `--strict` fail on a
  # complete, green fleet, and put "2 Role repo(s) exempt" in the summary's "this run is
  # PARTIAL" list, where it claimed the opposite of what is true.
  _cf_role_note=""
  ((_cf_role)) && _cf_role_note="; $_cf_role Role repo(s) exempt — no os/ band of their own"
  if ((_cf_checked == 0)); then
    skip_env "os.capabilities fleet coverage (no sibling OS repo checked out — nothing to read here)"
  elif ((_cf_bad)); then
    fail "os.capabilities: $_cf_bad of $_cf_checked checked-out OS repo(s) have a declaration that does not satisfy the schema (see the lines above)"
  elif ((_cf_undeclared)); then
    # ADVISORY, not a skip and not a failure. `pass` is honest here — the sweep RAN and
    # answered; what it found is a gap the fleet is mid-way through closing. A skip would
    # claim the check did not run (and --strict would red on it); a fail deadlocks the
    # fan-out that closes the gap.
    pass "os.capabilities: $_cf_undeclared of $_cf_checked checked-out OS repo(s) have not declared yet — advisory until the fleet is stamped (#667), then this blocks$_cf_role_note"
  else
    pass "os.capabilities: every checked-out OS repo declares and validates ($_cf_checked repo(s)$_cf_role_note)"
  fi
  # An ABSENT sibling is genuinely uncovered, so it stays a skip — and an ENVIRONMENT one,
  # which --strict ignores because CI checks out this repo alone. --require-siblings is
  # what reds it.
  ((_cf_absent)) && skip_env "os.capabilities: $_cf_absent repo(s) not checked out — not covered by this run"
fi

# ── 9b. tool download integrity (every downloaded *_VERSION has a *_SHA256) ────
# The setup-core-tools composite action verifies each release download against a
# pinned SHA-256 from tool-versions.env before installing it — the real supply-chain
# control over the gate toolchain (a tampered or MITM'd asset fails the build instead
# of running). That guarantee only holds if the hash exists: a version bumped without
# refreshing its checksum would trip the action's `:?` guard at best, or verify against
# a stale digest at worst. Gate it here — every tool the action downloads must carry a
# 64-hex *_SHA256 beside its *_VERSION. Recompute with scripts/update-tool-checksums.sh.
hdr "tool download integrity (version ⇒ checksum)"
if [[ -r "$VERSIONS_ENV" ]]; then
  _v() { sed -n "s/^$1=//p" "$VERSIONS_ENV" | head -n1; }
  _check_sha() { # _check_sha <env-prefix> <label>
    local ver sha
    ver="$(_v "${1}_VERSION")"
    sha="$(_v "${1}_SHA256")"
    if [[ -z "$ver" ]]; then
      fail "tool integrity: ${1}_VERSION missing — the action downloads $2"
    elif [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      pass "tool integrity: $2 $ver has a 64-hex ${1}_SHA256"
    else
      fail "tool integrity: $2 $ver has no valid ${1}_SHA256 — run scripts/update-tool-checksums.sh"
    fi
  }
  _check_sha SHELLCHECK shellcheck
  _check_sha ACTIONLINT actionlint
  _check_sha GITLEAKS gitleaks
  _check_sha NVIM neovim
  _check_sha SHFMT shfmt
else
  skip "tool download integrity ($VERSIONS_ENV unreadable)"
fi

# core.version is the human-readable Core stamp vendored into all nine OS repos (read by
# the `core-version` verb). A missing or malformed stamp would fan out a bogus version
# everywhere, so assert it exists and is SemVer-shaped (MAJOR.MINOR.PATCH, optional
# -prerelease). Single line only — the verb and sync-core.sh both read it whole.
if [[ -r core.version ]]; then
  cv="$(tr -d '[:space:]' <core.version)"
  if [[ "$cv" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    pass "core.version well-formed ($cv)"
  else
    fail "core.version malformed ('$cv') — expected SemVer MAJOR.MINOR.PATCH[-pre]"
  fi
else
  fail "core.version missing — the vendored version stamp (core-version reads it)"
fi

# core.version ↔ CHANGELOG coherence. A release is a TWO-file edit (bump core.version,
# move CHANGELOG's [Unreleased] under a dated heading) done by hand — so the two drift.
# Gate it: a -dev/prerelease stamp means work-in-progress, so CHANGELOG must keep an
# [Unreleased] section open; a CLEAN release stamp (X.Y.Z) must have a matching heading
# (## [vX.Y.Z] / ## [X.Y.Z]). Catches "bumped the stamp but forgot the CHANGELOG entry"
# (and vice-versa) before it fans out. Pure grep (busybox-safe); skips if a file is gone.
if [[ -r core.version && -r CHANGELOG.md ]]; then
  cvc="$(tr -d '[:space:]' <core.version)"
  if [[ "$cvc" == *-* ]]; then
    if grep -qE '^## +\[[Uu]nreleased\]' CHANGELOG.md; then
      pass "core.version ($cvc) is prerelease and CHANGELOG keeps an [Unreleased] section"
    else
      fail "core.version ($cvc) is prerelease but CHANGELOG.md has no [Unreleased] section"
    fi
  elif grep -qE "^## +\[v?${cvc//./\\.}\]" CHANGELOG.md; then
    pass "core.version ($cvc) has a matching CHANGELOG release heading"
  else
    fail "core.version ($cvc) has no '## [v$cvc]' heading in CHANGELOG.md — cut the release section"
  fi
else
  skip "core.version ↔ CHANGELOG coherence (a file is unreadable)"
fi
