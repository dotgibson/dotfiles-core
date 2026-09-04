#!/usr/bin/env bash
# scripts/audit-core.sh
# ──────────────────────────────────────────────────────────────────────────────
# THE AUDIT BUTTON — this repo's test suite.
#
# core.manifest calls itself "the contract. Audit scripts and the promotion
# checklist read it." This is that audit script. It verifies Core is internally
# consistent BEFORE it gets vendored (via scripts/sync-core.sh) into all nine OS repos,
# where a defect would fan out N-way.
#
# Checks (each is a section; a failure in one does not abort the others):
#   1. manifest <-> filesystem drift   — every manifest path exists; every
#                                         tracked Core file is listed or allowlisted
#  1b. routine reference integrity     — every .claude/ path the maintenance routines
#                                         say they READ exists and is tracked (the
#                                         mirror of §1: an accounted-for file that was
#                                         never tracked is invisible to git ls-files)
#   2. executable-bit assertions       — *.sh and bin/clip* must be +x in the
#                                         git index; zsh/*.zsh must NOT be (sourced)
#   3. shell syntax                     — bash -n on bash scripts; zsh -n on zsh modules
#   4. lua                              — luacheck nvim/        (if luacheck present)
#  4b. nvim module reachability        — no orphaned lua module under nvim/lua/gerrrt
#                                         (the backstop the directory-granular manifest
#                                          entry for nvim/ cannot provide)
#   5. lint                             — shellcheck            (if present)
#  5c. Core⇄OS boundary                — no OS-absolute paths in portable zsh modules
#  5d. pipefail SIGPIPE hazard        — no shell-string producer piped into a reader
#                                         that exits early (grep -q / awk exit / head)
#  5e. leaked RETURN trap             — no `trap … RETURN` that fails to disarm the
#                                         slot (it fires again in the CALLER's frame)
#  5j. HAVE_* contract                — PORTABILITY.md §5's declared flags ⊆ what
#                                         00-tools.zsh sets, every flag it sets has a
#                                         reader, and no OS/role repo reads an undeclared
#                                         one (the fleet half is an environment SKIP when
#                                         a sibling is not checked out)
#   6. config files                     — toml/yaml parse-check (if python3 present)
#   7. markdown                          — markdownlint (if markdownlint-cli2 present)
#   8. workflows                         — actionlint on .github/workflows (if present)
#  8b. secrets                           — gitleaks working-tree scan (if present)
#  8d. Makefile gates                    — no skip that cannot skip, no checker whose
#                                          status is discarded, no missing local mirror
#  9d. theme drift                      — every generated block still matches
#                                          theme/palette.toml (gen-theme.sh --check)
#   9. version consistency              — pre-commit hook revs == tool-versions.env;
#                                         core.version SemVer + CHANGELOG coherence
#  9e. changelog digest                 — CHANGELOG.recent.md is byte-identical to a
#                                         fresh scripts/gen-changelog-recent.sh render
#  9h. porting-matrix drift             — PORTING-MATRIX.md's two tables match the sibling
#                                         OS repos (gen-porting-matrix.sh --check; an
#                                         absent sibling is an environment SKIP)
#  9i. desktop-parity drift             — both desktop repos' PARITY.md match
#                                         desktop/PARITY.shared.md (gen-desktop-parity.sh
#                                         --check; an absent sibling is an environment SKIP)
#  10. behavioral                       — load-order smoke + function units (test-core.sh)
#
# We deliberately do NOT enforce shfmt: the hand-tuned scripts here use an
# intentional compact one-liner style that shfmt would expand. shellcheck (real
# bugs) is enforced; formatting is left to .editorconfig + the author's eye.
#
# Graceful degradation (mirrors zsh/00-tools.zsh): a missing linter is SKIPPED with
# a notice, never a failure — so this runs on a bare box AND in CI, where the
# tools are installed. Exit status is non-zero only on a real FAIL.
#
# Usage:
#   ./scripts/audit-core.sh            # run every section
#   ./scripts/audit-core.sh --quiet    # only print SKIP/FAIL + the summary
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

QUIET=0
JSON=0           # --json: machine-readable summary on stdout (implies quiet); for CI/editors
STRICT=0         # --strict: treat any SKIP as a failure (a gate that didn't actually run)
REQUIRE_SIBLINGS=0 # --require-siblings: fail if a fleet-wide gate had no sibling OS repo
                   # to read. Opt-in: absent siblings are normal on a dev box, and the
                   # default must not red for where you happened to invoke from.
CHANGED=0        # --changed: derive the scope from the local git diff (fast dev loop)
SCOPE_EXPLICIT=0 # an explicit --scope always wins over --changed
# Scope gates the SLOW, area-specific sections so a per-area push (driven by
# scripts/ci-classify.sh) pays only for what it changed — e.g. a docs-only PR runs
# the cheap structural/config/markdown checks but skips the zsh and nvim toolchains.
# FAIL-CLOSED default: with no --scope, BOTH areas run (full audit), so a local
# `make audit`, pre-commit, and an un-classified push are never silently narrowed.
# Only ci.yml passes an explicit, classifier-derived --scope. The cheap, cross-cutting
# checks (manifest, exec-bits, toml/yaml/json, markdown, workflows, version) ALWAYS run.
SCOPE_SHELL=1
SCOPE_NVIM=1
SCOPE_ATUIN=1
# Shared palette + pass/skip/fail/hdr/have + _set_scope (one definition for every gate
# script). Sourced HERE — before the arg loop below calls _set_scope — and after QUIET
# is set so the lib's `: "${QUIET:=0}"` preserves it.
#
# Via the ALREADY-ABSOLUTE $HERE, not ${BASH_SOURCE[0]%/*}: line 48 has already cd'd,
# while BASH_SOURCE stays relative to the caller's original directory, so the two
# disagree the moment this script is invoked by a relative path from somewhere else.
# `bash ../../repo/scripts/audit-core.sh` printed "lib/common.sh: No such file or
# directory" and then carried on with every helper undefined. Pre-existing; found while
# fixing the same shape in check-modern.sh, and fixed here rather than left as the one
# copy of the bug the reader would trip over next.
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"
# Render the active scope as test-core.sh expects it (a comma list of shell/nvim/atuin,
# or `none`).
_scope_str() {
  local s=""
  ((SCOPE_SHELL)) && s="shell"
  ((SCOPE_NVIM)) && s="${s:+$s,}nvim"
  ((SCOPE_ATUIN)) && s="${s:+$s,}atuin"
  printf '%s' "${s:-none}"
}

# Parse EVERY argument (not just $1), so an unknown flag OR a stray extra operand is
# REJECTED with a hint rather than silently ignored — `audit-core.sh --quiet extra`
# or a typo like `--hepl` used to slip through and just run the full audit, masking it.
# -h/--help prints usage and exits clean.
while (($#)); do
  case "$1" in
  -q | --quiet) QUIET=1 ;;
  --json) JSON=1 QUIET=1 CORE_JSON=1 && export CORE_JSON ;; # only JSON on stdout (incl. nested skips)
  --strict) STRICT=1 ;;
  --require-siblings) REQUIRE_SIBLINGS=1 ;;
  --scope)
    # Require an explicit value: without this, `--scope --quiet` would swallow the
    # next flag as the scope list and silently drop it.
    if (($# < 2)) || [[ "$2" == -* ]]; then
      printf 'audit-core.sh: --scope requires a value (shell,nvim,atuin|all|none)\n' >&2
      printf 'try: audit-core.sh --help\n' >&2
      exit 2
    fi
    shift
    _set_scope "$1"
    SCOPE_EXPLICIT=1
    ;;
  --scope=*)
    _set_scope "${1#*=}"
    SCOPE_EXPLICIT=1
    ;;
  --changed) CHANGED=1 ;;
  --color)
    if (($# < 2)) || ! _core_set_color "$2"; then
      printf 'audit-core.sh: --color requires a value (auto|always|never)\n' >&2
      printf 'try: audit-core.sh --help\n' >&2
      exit 2
    fi
    shift
    ;;
  --color=*)
    _core_set_color "${1#*=}" || {
      printf 'audit-core.sh: --color requires auto|always|never\n' >&2
      exit 2
    }
    ;;
  -h | --help)
    cat <<'EOF'
usage: audit-core.sh [-q|--quiet] [--strict] [--require-siblings] [--scope LIST] [--changed]
                     [--color WHEN] [--json] [-h|--help]

THE audit button — manifest/exec-bit/syntax/lint/config/markdown/workflow/
version/behavioral checks. CI and pre-commit run this exact script.

  -q, --quiet     only print SKIP/FAIL lines and the final summary
  --json          emit a machine-readable summary object on stdout (implies --quiet):
                  {pass,skip,fail,seconds,strict,tool_skips,env_skips,partial,
                  skipped[],result}. `partial` is true whenever anything skipped. For CI
                  steps / editor integrations that want to parse, not scrape, the result.
  --strict        fail if any gate SKIPPED because its TOOL is absent — that gate did
                  not actually run, so a "green" with such skips is only PARTIAL. An
                  out-of-scope skip (a narrowed --scope/--changed run) is intentional and
                  does NOT trip --strict, so this is safe on a fully-provisioned CI leg
                  where every IN-SCOPE tool is installed. The summary names every skip.
  --require-siblings
                  fail if ANY fleet-wide gate had no sibling repo checked out to read.
                  Those gates skip silently-by-default on a lone clone — including in CI,
                  which checks out only this repo — so they have never actually run there.
                  This is the flag that says "I expect full fleet coverage from this run".
                  Deliberately NOT enumerated here: the gates declare this case through
                  skip_env and the verdict counts every one of them, so a list in help
                  text is one more thing to keep in sync by hand — and it had already
                  drifted, naming four of the eight. The run summary lists every
                  environment skip the run actually recorded; that is the real answer.
  --scope LIST    limit the slow area-specific sections to a comma list:
                  shell, nvim, atuin, all (default), none. Cheap structural/config/
                  markdown/workflow/version checks always run. CI sets this from
                  scripts/ci-classify.sh; omit it locally to run the full audit.
                  `atuin` is the hermetic self-test of the premise detector
                  (scripts/research/verify-atuin-guard.sh) — the suite's most expensive
                  section by a wide margin, and reachable only from that script,
                  zsh/00-tools.zsh and atuin/.
  --color WHEN    auto (default) | always | never. `always` keeps colour when piped
                  (e.g. into `less -R`); NO_COLOR still wins. Also via CORE_COLOR env.
  --changed       derive the scope from your local git diff (working tree vs HEAD,
                  falling back to the branch delta vs the default branch) using the
                  SAME scripts/ci-classify.sh CI uses — so a docs- or nvim-only edit
                  skips the gates it can't affect, tightening the dev loop. Fails SAFE
                  to the full run when the diff can't be resolved. An explicit --scope
                  overrides this.
  -h, --help      show this help and exit
EOF
    exit 0
    ;;
  *)
    printf 'audit-core.sh: unexpected argument: %s\n' "$1" >&2
    printf 'try: audit-core.sh --help\n' >&2
    exit 2
    ;;
  esac
  shift
done

# ── --changed: derive the scope from the local git diff ───────────────────────
# Reuse the EXACT classifier CI runs (scripts/ci-classify.sh) so `make audit-changed`
# narrows to the same gates a push would — one definition of path→gate, no drift. The
# changed set is the working tree vs HEAD plus untracked files; when the tree is clean
# we fall back to the branch delta vs the default branch. Anything unresolvable → the
# full run (fail-safe), matching CI's "detection miss never hides a gate" rule. An
# explicit --scope already set SCOPE_EXPLICIT and wins.
_changed_scope() {
  if ! have git || ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'all'
    return
  fi
  local files base
  files="$({
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u)"
  if [[ -z "$files" ]]; then
    for base in origin/main main origin/master master; do
      git rev-parse -q --verify "$base" >/dev/null 2>&1 || continue
      files="$(git diff --name-only "$base"...HEAD 2>/dev/null)"
      break
    done
  fi
  [[ -n "$files" ]] || {
    printf 'all'
    return
  } # nothing resolvable → full (safe)
  local out scope=""
  out="$(printf '%s\n' "$files" | "$HERE/scripts/ci-classify.sh" 2>/dev/null)"
  # Parse via the shared reader (scripts/lib/common.sh): it sets CLASSIFY_SHELL/CLASSIFY_NVIM/
  # CLASSIFY_ATUIN and returns non-zero if the classifier errored or emitted garbage on ANY of
  # the three — in which case fail SAFE to the full run rather than silently returning "none"
  # and skipping every slow gate.
  if ! _core_read_classify "$out"; then
    printf 'all'
    return
  fi
  [[ "$CLASSIFY_SHELL" == true ]] && scope="shell"
  [[ "$CLASSIFY_NVIM" == true ]] && scope="${scope:+$scope,}nvim"
  [[ "$CLASSIFY_ATUIN" == true ]] && scope="${scope:+$scope,}atuin"
  printf '%s' "${scope:-none}"
}
if ((CHANGED)) && ((!SCOPE_EXPLICIT)); then
  _cs="$(_changed_scope)"
  ((QUIET)) || printf '%s== --changed → scope %s ==%s\n' "$c_blu" "$_cs" "$c_rst"
  _set_scope "$_cs"
fi

# Wall-clock from here, surfaced in the summary — so a long run (the headless nvim /
# zsh legs) reads as "took Ns", not "hung", and a regression in audit cost is visible.
SECONDS=0

# ── Overlap the behavioral suite with the static gates ────────────────────────
# scripts/test-core.sh (headless nvim ×2 + the zsh -i load legs) dominates wall-clock,
# and it shares NOTHING with the static sections below (manifest/exec-bit/syntax/lint/
# config) — they're read-only and independent. So kick it off NOW in the background and
# collect it at section 10, overlapping its slow legs with the fast static checks instead
# of running strictly after them. It still contributes EXACTLY one pass/fail to the
# summary (on its exit code), as before — only the wall-clock changes. Output is buffered
# to a file and re-printed in place at section 10 so it never interleaves with the static
# sections; CLICOLOR_FORCE keeps its colour when our own stdout is a tty. CORE_AUDIT_SERIAL=1
# forces the old inline behaviour (debugging / a shell with no job control).
BEHAV_BG=0
BEHAV_PID=""
BEHAV_OUT=""
TEST_ARGS=(--scope "$(_scope_str)")
((QUIET)) && TEST_ARGS+=(--quiet)
if [[ "${CORE_AUDIT_SERIAL:-0}" != 1 ]]; then
  BEHAV_OUT="$(mktemp "${TMPDIR:-/tmp}/core-audit-behav.XXXXXX")"
  # Force colour through the file capture only when OUR stdout is a real terminal.
  _behav_color=""
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && _behav_color="CLICOLOR_FORCE=1"
  env $_behav_color CORE_TEST_NESTED=1 \
    ./scripts/test-core.sh ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} >"$BEHAV_OUT" 2>&1 &
  BEHAV_PID=$!
  BEHAV_BG=1
fi

# Reap the backgrounded behavioral child + remove its capture file on ANY exit. The
# normal path (section 10) already waits for it and rm's the temp; but a Ctrl-C — or
# an early FAIL/exit — mid-audit otherwise orphans the slow nvim/zsh leg and leaks the
# mktemp. EXIT does the cleanup (idempotent: kill on a reaped pid and a second rm -f are
# both no-ops); INT/TERM just exit with the conventional 128+signal code and let EXIT fire.
_audit_cleanup() {
  [[ -n "${BEHAV_PID:-}" ]] && kill "$BEHAV_PID" 2>/dev/null
  [[ -n "${BEHAV_OUT:-}" ]] && rm -f "$BEHAV_OUT"
}
trap _audit_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Tracked files that live in dotfiles-core and are NOT vendored into OS repos' core/
# subtree — repo-meta and dev tooling. Anything tracked, not matched by the manifest and
# not in core.vendor, must appear here (or under a META_PREFIXES dir) or section 1 flags it.
#
# SINCE #676 THIS IS A CLAIM ABOUT DISK, NOT JUST ABOUT SYMLINKS. It used to say "not
# vendored" while the subtree copied every one of these files into all nine repos anyway —
# "not shipped" meant "not in the manifest", not "not on disk", and CONTRIBUTING.md asserted
# the stronger thing for years. sync-core.sh now materializes `core.manifest` ∪ `core.vendor`
# and nothing else, so a file here genuinely does not leave this repo.
#
# THREE ENTRIES LEFT WHEN #676 LANDED, because an OS repo actually reads them from core/:
# PORTING-MATRIX.md, core.manifest and gitleaks.toml moved to core.vendor with their
# consumers named. If you are about to add something back here that a fleet repo greps out
# of core/, it belongs in core.vendor instead — §1d fails a path that is in both.
META_ALLOWLIST=(
  README.md CONTRIBUTING.md CHANGELOG.md LICENSE SECURITY.md aliases.md CLAUDE.md
  ARCHITECTURE.md PORTABILITY.md VENDORING.md CODE_OF_CONDUCT.md
  PARITY.md RELEASE-STRATEGY.md RELEASE-RUNBOOK.md GITHUB-APP-AUTH.md GITHUB-APP-MIGRATION.md V5-PROPOSAL.md
  .gitignore .gitattributes .editorconfig .pre-commit-config.yaml .markdownlint.jsonc .shellcheckrc renovate.json .prettierrc.json
  Makefile cliff.toml
  nvim/.luacheckrc
  CODEOWNERS pull_request_template.md
  # theme/palette.toml is a generation-time INPUT to scripts/gen-theme.sh (already covered
  # by the scripts/ prefix below), not shipped Core: nothing symlinks it and no OS repo
  # reads it out of core/. Its OUTPUTS ship — the generated blocks in zsh/, tmux/,
  # starship/, lazygit/ and lib/ux.sh — which is exactly the core.manifest-vs-core.vendor
  # distinction those two files draw. Listed as an EXACT path, not a theme/ prefix, so a
  # second file dropped into that directory has to be accounted for deliberately.
  theme/palette.toml
  # desktop/PARITY.shared.md is theme/palette.toml's shape exactly: a generation-time INPUT
  # to scripts/gen-desktop-parity.sh, not shipped Core. Nothing symlinks it and no OS repo
  # reads it out of core/ — its OUTPUT lands OUTSIDE any vendored core/ tree
  # (dotfiles-Windows/desktop/PARITY.md, dotfiles-MacBook/sketchybar/PARITY.md), which is why
  # it is neither a manifest row nor a core.vendor row. Note the two differ: dotfiles-MacBook
  # DOES vendor Core (scripts/os-repos.txt) and its copy is simply an OS-layer file outside
  # core/, whereas dotfiles-Windows vendors no core/ at all. Listed as an EXACT path, not a
  # desktop/ prefix, so a second file dropped there has to be accounted for deliberately.
  desktop/PARITY.shared.md
)
# Directory prefixes whose tracked contents are allowlisted wholesale. scripts/ is
# this repo's DEV TOOLING (audit/test/bench/sync/update-plugins) — the gate scripts
# themselves, NOT shipped Core (absent from core.manifest, so not symlinked by an OS
# repo's bootstrap; only bin/clip* + the manifest paths are). The subtree copy still
# carries them physically — "not shipped" means "not in the manifest", not "not on disk".
# Listing the dir, not each script, means a new dev tool is covered the moment it lands
# here — the bin/-vs-scripts/ split is exactly what makes that unambiguous.
# .claude/ holds the Claude-Code config — the SessionStart hook (provisions the gate
# toolchain in a remote session) plus the maintenance routines (commands/ + agents/
# for /doc-audit, /tool-scout, /freshness-triage) — repo-meta tooling, not shipped Core
# (absent from core.manifest).
# .devcontainer/ is the dev-environment definition (one-command CI parity) — dev tooling
# too, not part of the shipped Core layer (not in core.manifest).
# assets/ is README media (the VHS demo tape + rendered gif) — repo-meta for the public
# showcase, not shipped Core (absent from core.manifest). Before #676 it rode along
# physically in the subtree copy anyway: 1.8 MB of README GIF, larger than the entire Core
# payload, replicated into nine repos where no README displays it. It no longer ships.
#
# THESE PREFIXES ARE THE RESIDUAL, AND THEY OVERLAP core.vendor BY DESIGN. Four of them
# (examples/, .github/, scripts/, and the root docs above) contain a handful of files an OS
# repo genuinely reads from core/ — check-capabilities.sh, tool-versions.env,
# setup-core-tools, the atuin unit. Those are named per-file in core.vendor; everything else
# under the prefix stays here. Enumerating the non-vendored remainder per-file instead would
# be ~90 lines that change every time a dev script lands, to state the same thing.
#
# So §1's three buckets are NOT a strict partition, and §1d does not pretend otherwise: it
# fails an EXACT overlap (a path in core.manifest and core.vendor, or hand-listed in both
# META_ALLOWLIST and core.vendor), which is the drift that actually happens — someone adds a
# consumer and forgets to remove the old allowlist line. A prefix that contains a vendored
# file is the intended shape, not drift.
META_PREFIXES=(examples/ .github/ scripts/ .claude/ .devcontainer/ assets/)


# ── 1. manifest <-> filesystem drift ─────────────────────────────────────────
hdr "manifest ↔ filesystem"
# Parse manifest: strip comments/blank lines, take the first whitespace token.
# Use a read loop (not `mapfile`) — mapfile is bash 4+, and this gate must also
# run on macOS's stock bash 3.2 (the dotfiles-MacBook target / the macOS CI leg).
MANIFEST_PATHS=()
while IFS= read -r p; do
  MANIFEST_PATHS+=("$p")
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' core.manifest | awk 'NF {print $1}')
# core.vendor is parsed with the SAME parser, deliberately: it shares core.manifest's format
# so there is one thing to learn and one thing to get wrong (#676).
VENDOR_PATHS=()
while IFS= read -r p; do
  VENDOR_PATHS+=("$p")
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' core.vendor 2>/dev/null | awk 'NF {print $1}')
for p in "${MANIFEST_PATHS[@]}"; do
  if [[ "$p" == */ ]]; then
    if [[ -d "$p" ]]; then pass "dir  $p"; else fail "manifest lists missing dir:  $p"; fi
  else
    if [[ -e "$p" ]]; then pass "file $p"; else fail "manifest lists missing file: $p"; fi
  fi
done

# Reverse direction: tracked Core files not covered by the manifest or allowlist.
is_listed() { # $1 = path
  local f="$1" m pre
  for m in "${MANIFEST_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0                # exact file match
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0 # under a listed dir
  done
  for m in "${VENDOR_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0                # exact file match
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0 # under a listed dir
  done
  for m in "${META_ALLOWLIST[@]}"; do [[ "$f" == "$m" ]] && return 0; done
  for pre in "${META_PREFIXES[@]}"; do [[ "$f" == "$pre"* ]] && return 0; done
  return 1
}
if have git && git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_listed "$f" || fail "tracked file not in manifest/allowlist: $f"
  done < <(git ls-files)
  pass "reverse-drift scan complete (tracked files all accounted for)"
else
  skip "reverse-drift scan (not a git checkout)"
fi

# ── 1c. vendor allowlist ↔ filesystem ────────────────────────────────────────
# The manifest direction of §1, for the second list. A core.vendor entry naming a path that
# does not exist would silently shrink the vendored set: core_vendor_tree keeps what the
# filter matches, and a typo matches nothing. The consumer that needed it then fails at
# runtime, in ITS repo's CI, one fan-out later.
hdr "vendor allowlist ↔ filesystem"
if [[ ! -r core.vendor ]]; then
  fail "core.vendor is missing or unreadable — sync-core.sh would silently fall back to vendoring the WHOLE tree (core_vendor_effective_tree's version switch keys on this file's presence at a commit)"
elif ((${#VENDOR_PATHS[@]} == 0)); then
  fail "core.vendor parses to zero paths — every OS repo would vendor an empty core/"
else
  for p in "${VENDOR_PATHS[@]}"; do
    if [[ "$p" == */ ]]; then
      if [[ -d "$p" ]]; then pass "vendor dir  $p"; else fail "core.vendor lists missing dir:  $p"; fi
    else
      if [[ -e "$p" ]]; then pass "vendor file $p"; else fail "core.vendor lists missing file: $p"; fi
    fi
  done
fi

# ── 1d. the two lists must not disagree about a path ─────────────────────────
# core.manifest answers "is this SHIPPED Core — symlinked into $HOME?"; core.vendor answers
# "does this RIDE ALONG in core/ so vendored tooling resolves?". A path in both means nobody
# decided which it is, and the two lists are read by different code for different purposes.
#
# A FAIL, not a warning: the duplicate is harmless to the tree today (the filter unions
# them), which is exactly why it would sit there accumulating until someone removed the
# manifest line and silently unshipped a Core file that "was still listed".
hdr "core.manifest ↔ core.vendor"
_dupes=0
for p in "${VENDOR_PATHS[@]}"; do
  for m in "${MANIFEST_PATHS[@]}"; do
    if [[ "$p" == "$m" ]] || [[ "$m" == */ && "$p" == "$m"* ]]; then
      fail "listed in BOTH core.manifest and core.vendor: $p (decide which — shipped Core, or rides along for a consumer)"
      _dupes=1
    fi
  done
  for m in "${META_ALLOWLIST[@]}"; do
    if [[ "$p" == "$m" ]]; then
      fail "listed in BOTH core.vendor and audit-core.sh's META_ALLOWLIST: $p (META_ALLOWLIST is the NOT-vendored list — drop the entry there)"
      _dupes=1
    fi
  done
done
((_dupes)) || pass "no path claimed by two lists"
# The two contract files must vendor themselves. Vendored tooling parses core.manifest from
# its OWN root (a filtered core/ that omitted it breaks the moment anything in it reads the
# manifest), and core.vendor is what lets a checkout with no Core objects answer "why are
# these files here?" from core/ alone.
for _self in core.manifest core.vendor; do
  _found=0
  for p in "${VENDOR_PATHS[@]}"; do [[ "$p" == "$_self" ]] && _found=1; done
  if ((_found)); then pass "core.vendor lists $_self (self-describing)"
  else fail "core.vendor does not list $_self — a vendored core/ could not explain or parse itself"; fi
done

# ── 1e. vendored closure: does a shipped script reach a file nobody ships? ───
# The gate #676 needs and nothing else provides. Before it, a script that shipped could
# `source` any sibling, because every sibling shipped. Now core/ carries ~180 of 285 files,
# so a vendored entry point can reach a path that stayed behind — and NOTHING else catches
# it: §1's reverse drift sees a tracked, accounted-for file either way, and core-integrity
# compares tree hashes, where a consistently-wrong subset hashes consistently. It surfaces on
# a box, at runtime, as "no such file or directory".
#
# BFS FROM DECLARED ENTRY POINTS, not a sweep of every vendored script. Entry points are the
# files a consumer EXECUTES or SOURCES, marked `# entry` in core.vendor. Sweeping everything
# instead would immediately demand that release-only tooling's references be vendored —
# scripts/release.sh reaches CHANGELOG.md, gen-release-notes.sh reaches cliff.toml — and the
# only ways out are to hand back 687 KB or to start a suppression list. A gate whose first
# act is to demand a suppression is a gate someone turns off (the _core_pipefail_hits
# argument). Walking from entry points puts that tooling out of scope by construction.
#
# See _core_vendor_ref_hits for what the scanner deliberately cannot see (computed paths,
# Lua requires, YAML). Those paths are hand-listed in core.vendor with their consumer named.
hdr "vendored closure (core.vendor '# entry' roots)"
_is_vendored() { # _is_vendored <path>
  local f="$1" m
  for m in "${MANIFEST_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0
  done
  for m in "${VENDOR_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0
  done
  return 1
}
_ENTRIES=()
while IFS= read -r p; do
  [[ -n "$p" ]] && _ENTRIES+=("$p")
done < <(grep -E '^[^#[:space:]]+[[:space:]]+#[[:space:]]*entry([[:space:]]|$)' core.vendor 2>/dev/null | awk '{print $1}')
if ((${#_ENTRIES[@]} == 0)); then
  fail "core.vendor declares no '# entry' roots — the closure check has nothing to walk from, so a vendored script could reach an unvendored file unnoticed"
else
  # bash 3.2: no associative arrays (this gate runs on macOS's stock 3.2), so `seen` is a
  # newline-delimited string and membership is a case glob. The frontier is bounded by the
  # vendored set, so this terminates in a handful of rounds.
  _seen=$'\n'
  _queue=("${_ENTRIES[@]}")
  _closure_bad=0
  while ((${#_queue[@]})); do
    _cur="${_queue[0]}"
    _queue=("${_queue[@]:1}")
    case "$_seen" in *$'\n'"$_cur"$'\n'*) continue ;; esac
    _seen="${_seen}${_cur}"$'\n'
    [[ -f "$_cur" ]] || continue
    while IFS= read -r _hit; do
      [[ -n "$_hit" ]] || continue
      _ln="${_hit%%:*}"; _ref="${_hit#*:}"
      if _is_vendored "$_ref"; then
        _queue+=("$_ref")
      else
        fail "vendored $_cur:$_ln reaches $_ref, which is NOT vendored — add it to core.vendor (with its consumer named) or stop reaching for it"
        _closure_bad=1
      fi
    # One line per REFERENCED PATH, not per reference. This tree puts a
    # `# shellcheck source=` directive above every `source` line, so an unvendored sibling
    # is named twice by construction and the gate would report each break twice — noise that
    # reads like two problems.
    done < <(_core_vendor_ref_hits "$_cur" | sort -t: -k2,2 -u)
  done
  ((_closure_bad)) || pass "closure clean from ${#_ENTRIES[@]} entry root(s) — every path they reach is vendored"
fi

# ── 1b. routine reference integrity (the inverse of §1's reverse drift) ──────
# §1 above asks, in both directions, whether every TRACKED file is accounted for. This
# asks the mirror question: is every file the maintenance routines say they READ actually
# there, and actually shipped? Those are different failures and §1 structurally cannot see
# the second one — its reverse walk is fed by `git ls-files`, so a file that was never
# tracked is not in the stream and `is_listed` is never called on it. The manifest
# direction never looks either: .claude/ is repo-meta, allowlisted wholesale by
# META_PREFIXES, which is correct and is also why nothing was watching.
#
# WHY IT EXISTS. #661 taught /tool-scout to consult a decided-and-rejected ledger at
# .claude/tool-decisions.md, shipped the three files that reference it, and did not ship
# the ledger: .gitignore's `.claude/*` negations are per-DIRECTORY, so commands/ and
# agents/ vendored out while the file they point at stayed untracked (#700). The routine's
# own instruction is to say "none" when a candidate has no prior decision — so with no
# file every candidate resolves to "none", in the exact voice that means CHECKED. The
# report then asserts the ledger was consulted while consulting nothing, which is worse
# than the ambiguity #634 was filed to remove, because the absence is no longer visible.
# It is the same shape as core.manifest naming a verify-core backstop that never existed
# (#454): an assertion pointing at a file nobody created.
#
# TWO VERDICTS, NOT ONE. "absent" and "present but untracked" are different bugs with
# different fixes — author the file, versus negate it in .gitignore — and this defect was
# the second, which every report of it so far has called the first. Collapsing them into
# one message would hand the reader the wrong repair.
#
# PLAIN `git ls-files`, NOT _audit_ls. The rule is in common.sh: a gate asking "what does
# GIT RECORD?" takes the tracked list, and _audit_ls deliberately adds
# untracked-but-not-ignored files. Here that inclusion would be fatal rather than noisy —
# an ignored file is exactly what this gate exists to catch, and _audit_ls would wave the
# one on the author's disk straight through while every clone stayed broken.
#
# WHY IT BLOCKS ON ARRIVAL, the §5i argument: the tree is green the moment this lands (the
# four references all resolve), so every future hit is a regression introduced by the
# commit under test, not inherited fleet drift.
hdr "routine reference integrity"
if ! have git || ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "routine reference integrity (not a git checkout)"
else
  cref_fail=0
  # Newline-DELIMITED, not merely newline-separated: the leading and trailing newlines let
  # the membership test below match a whole line without a subprocess, and without
  # `.claude/tool-decisions.md` being satisfied by a hypothetical `x.claude/tool-decisions.md`.
  # A `grep -qxF` per reference would be the obvious spelling and is exactly what §5d
  # forbids — a shell string piped into a reader that exits early.
  cref_tracked=$'\n'"$(git ls-files)"$'\n'
  while IFS= read -r cref_src; do
    [[ -z "$cref_src" ]] && continue
    while IFS= read -r cref_hit; do
      [[ -z "$cref_hit" ]] && continue
      cref_line="${cref_hit%%:*}"
      cref_path="${cref_hit#*:}"
      if [[ ! -e "$cref_path" ]]; then
        fail "$cref_src:$cref_line names $cref_path, which does not exist — a routine instructed to read a missing file reports 'none' rather than failing, so the absence reads as a clean check"
        cref_fail=1
      elif [[ "$cref_tracked" != *$'\n'"$cref_path"$'\n'* ]]; then
        fail "$cref_src:$cref_line names $cref_path, which exists here but is NOT TRACKED — it reaches no clone, no CI run and none of the nine vendored repos. Negate it in .gitignore (#700)"
        cref_fail=1
      fi
    done <<EOF
$(_core_claude_ref_hits "$cref_src")
EOF
  done <<EOF
$(git ls-files '.claude/commands/*.md' '.claude/agents/*.md')
EOF
  ((cref_fail)) || pass "routine reference integrity (every .claude/ path the routines name resolves and is tracked)"
  unset cref_fail cref_tracked cref_src cref_hit cref_line cref_path
fi

# ── 1c. unreferenced .claude/ files (the half §1b structurally cannot reach) ──
# §1b asks whether every .claude/ path a routine NAMES is shipped. That only fires because
# something pointed at the file. This asks the question with no reference to lean on: is any
# file under .claude/ sitting on this disk and going nowhere?
#
# WHY BOTH ARE NEEDED. #700 was caught only because three routine files named the ledger. A
# .claude/ file nothing references — a new subagent, a convention-named config a hook reads,
# a second ledger — has no such witness, and `.gitignore`'s blanket `.claude/*` means git
# prints nothing about it: not in `git status`, not added by `git add -A`, not in any content
# gate here (they all read the working tree, where it is present and correct). The audit was
# answering "is this tree consistent" — it was — while nobody asked "will this reach a clone".
#
# THE RULE THAT WINS IS THE VERDICT. The scanner asks `git check-ignore -v` which line hid the
# file. The blanket `.claude/*` means nobody decided anything about it; any more specific rule
# means somebody wrote a line naming it, which is a decision and stays quiet. So
# settings.local.json is exempt because .gitignore names it, not because this gate lists it,
# and the next per-machine file becomes exempt the moment its rule is written.
#
# The two verdicts §1b separates do not arise here: a file this gate sees always EXISTS (it
# was found on disk), so "author it" is never the repair. The repair is always one .gitignore
# line — a negation if it should ship, a specific rule if it should not.
#
# WHY IT BLOCKS ON ARRIVAL, the §5i/§1b argument: the tree is green the moment this lands —
# settings.local.json is the only untracked file under .claude/, and it carries its own rule —
# so every future hit is a regression introduced by the commit under test.
hdr "unreferenced .claude/ files"
if ! have git || ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "unreferenced .claude/ files (not a git checkout)"
elif [[ ! -d .claude ]]; then
  skip "unreferenced .claude/ files (no .claude/ directory)"
else
  cunt_fail=0
  while IFS= read -r cunt_path; do
    [[ -z "$cunt_path" ]] && continue
    fail "$cunt_path exists here but git will never ship it — it is hidden by the blanket \`.claude/*\` rule, so it reaches no clone, no CI run and none of the nine vendored repos, and nothing else reports it. Negate it in .gitignore if it is shared; give it its own ignore rule if it is per-machine (#700)"
    cunt_fail=1
  done <<EOF
$(_core_claude_untracked_hits "$HERE")
EOF
  ((cunt_fail)) || pass "unreferenced .claude/ files (every file under .claude/ either ships or is deliberately ignored)"
  unset cunt_fail cunt_path
fi

# ── 2. executable-bit assertions ─────────────────────────────────────────────
hdr "executable bits"
if have git && git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r line; do
    mode="${line%% *}"
    path="${line#* }"
    case "$path" in
    scripts/lib/*.sh | scripts/research/lib/*.sh | scripts/test/*.sh | lib/*.sh)
      # Sourced bash libraries — the bash sibling of zsh/*.zsh: no shebang, NOT
      # executable. scripts/lib/ is dev-tooling, scripts/research/lib/ is the archived
      # research apparatus's own lib (#687); scripts/test/ is the behavioral suite's
      # numbered fragments, which scripts/test-core.sh sources into its own shell and
      # which do nothing useful when run on their own (#699); lib/ (core/lib/ux.sh) is
      # the VENDORED bash UX lib bootstrap.sh sources. Must precede the generic *.sh arm
      # (first match).
      if [[ "$mode" == 100644 ]]; then
        pass "src  $path"
      else fail "sourced lib must NOT be executable, is $mode: $path"; fi
      ;;
    *.sh | bin/clip | bin/clip-paste)
      if [[ "$mode" == 100755 ]]; then
        pass "+x   $path"
      else fail "must be executable (100755), is $mode: $path"; fi
      ;;
    zsh/*.zsh)
      if [[ "$mode" == 100644 ]]; then
        pass "src  $path"
      else fail "sourced module must NOT be executable, is $mode: $path"; fi
      ;;
    esac
  done < <(git ls-files -s | awk '{print $1, $4}')
else
  skip "exec-bit check (not a git checkout)"
fi

# ── 3. shell syntax ──────────────────────────────────────────────────────────
hdr "shell syntax (bash -n / zsh -n)"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then pass "bash -n $f"; else fail "bash syntax error: $f"; fi
done < <(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
if ((SCOPE_SHELL)); then
  if have zsh; then
    # The sourced modules AND the autoloaded completion functions (zsh/completions/_*,
    # no .zsh extension) — both are zsh that fans out to nine repos; both must parse.
    while IFS= read -r f; do
      if zsh -n "$f" 2>/dev/null; then pass "zsh -n  $f"; else fail "zsh syntax error: $f"; fi
    done < <(_audit_ls 'zsh/*.zsh' 'zsh/completions/*')
  else
    skip "zsh -n (zsh not installed)"
  fi
else
  skip "zsh -n (out of scope)"
fi

# ── 4. lua ───────────────────────────────────────────────────────────────────
hdr "lua (luacheck)"
# PROBE BEFORE LINTING, so a broken toolchain is never reported as a defect in nvim/ (#726).
# `have luacheck` is a weak precondition: luarocks generates a wrapper that `exec`s an ABSOLUTE
# interpreter path, so the name stays on PATH long after the lua it was built against is gone,
# and the wrapper still answers `command -v`.
#
# EXIT CODE ALONE CANNOT SEPARATE THE TWO, which is why this is a probe and not a status check.
# luacheck's own vocabulary is 0 clean / 1 warnings / 2 syntax errors / 3 I/O error, and a
# LOAD failure — luacheck's source failing to parse or a module going missing — also exits 1.
# That is the documented mise/config.toml case: luacheck 1.2.0 cannot load under Lua 5.5 at
# all ("attempt to assign to const variable" in its own source), and it would land here as
# exit 1, indistinguishable from honest lint warnings. A missing interpreter is the easier
# shape (the shell's 126/127) and would be separable; the 5.5 one is not.
#
# `--version` lints nothing and exercises the same module load, so ANY failure from it is a
# toolchain failure by construction. One extra process on a leg that only runs when nvim/ is
# in scope.
if ! ((SCOPE_NVIM)); then
  skip "luacheck (out of scope)"
elif ! have luacheck; then
  # Name the 5.4 requirement HERE, at the moment the reader learns they need the tool —
  # mise/config.toml carries the full explanation, but nobody reaching for `luarocks install
  # luacheck` is reading a runtime pin file (#726).
  skip "luacheck (not installed — install it against an explicit Lua 5.4; luacheck 1.2.0 cannot load under 5.5, see mise/config.toml)"
else
  # The probe lints nothing; only its STATUS matters, and its output is the diagnostic to
  # show when it fails. luacheck discovers .luacheckrc by searching UP from the CWD, not the
  # target — so the lint pass runs from inside nvim/, where nvim/.luacheckrc lives. From repo
  # root it would miss the config and emit hundreds of false "undefined vim" warnings.
  lua_probe="$(luacheck --version 2>&1)"
  lua_probe_rc=$?
  if ((lua_probe_rc == 0)); then
    lua_out="$(cd nvim && luacheck . --no-color 2>&1)"
    lua_rc=$?
  else
    lua_out="$lua_probe"
    lua_rc=0
  fi
  # The three-way call is in common.sh so test-core.sh can drive every branch; this only
  # renders. Same split §1b uses, and for the same reason.
  case "$(_core_luacheck_verdict "$lua_probe_rc" "$lua_rc")" in
  ok)
    pass "luacheck nvim/"
    ;;
  broken)
    fail "luacheck is on PATH but cannot RUN — a broken toolchain, NOT a lint finding in nvim/. If it was installed with luarocks against mise's lua, that is the trap mise/config.toml describes; the sanctioned installers each pin their own 5.4. Re-running luacheck will only repeat this."
    fail_detail "$lua_probe"
    ;;
  broken-midrun)
    fail "luacheck stopped being runnable mid-audit (exit $lua_rc) — the toolchain broke after the version probe passed, so this is not a lint finding in nvim/"
    fail_detail "$lua_out"
    ;;
  *)
    fail "luacheck reported issues — run: (cd nvim && luacheck .)"
    fail_detail "$lua_out"
    ;;
  esac
  unset lua_rc lua_probe_rc lua_probe lua_out
fi

# ── 4b. nvim module reachability (the orphan backstop) ───────────────────────
# core.manifest lists `nvim/` as a DIRECTORY, so §1's manifest⇄fs drift check auto-lists
# every new path under it and cannot see an orphan — a lua module nothing loads would sit
# in the tree and fan out to all nine OS repos silently. core.manifest said that gap was
# covered "by verify-core.sh instead"; that script has never existed here (#454). The real
# logic — a graph walk from nvim/init.lua, not a "is this name mentioned" scan — lives in
# the script below, along with the rationale for its roots and its two resolved edges. It
# is a standalone script rather than an inline block precisely so test-core.sh can drive
# it against synthetic fixtures. Findings arrive one per line; each becomes a fail.
hdr "nvim module reachability"
if ! ((SCOPE_NVIM)); then
  skip "nvim reachability (out of scope)"
elif [[ ! -d nvim/lua/gerrrt ]]; then
  skip "nvim reachability (no nvim/lua/gerrrt)"
else
  # Gate on the EXIT STATUS as well as the output. Deciding purely on "did it print
  # anything" means a silent non-zero exit — the script killed, or dying before it can
  # emit a diagnostic — reads as a passing gate, which is the one outcome a backstop must
  # never produce. Pass requires rc 0 AND no findings; anything else fails, and a
  # status-without-output still says something actionable rather than nothing.
  orph_out="$("$HERE/scripts/nvim-reachability.sh" --root "$HERE" 2>&1)"
  orph_rc=$?
  if [[ -n "$orph_out" ]]; then
    while IFS= read -r orph_line; do
      [[ -n "$orph_line" ]] && fail "nvim: $orph_line"
    done <<EOF
$orph_out
EOF
    ((orph_rc == 0)) && fail "nvim: reachability reported findings but exited 0 (contract violation)"
  elif ((orph_rc == 0)); then
    pass "nvim module reachability (no orphaned lua modules)"
  else
    fail "nvim: reachability exited $orph_rc with no output — the gate did not actually run"
  fi
fi

# ── 5. lint (shellcheck) ─────────────────────────────────────────────────────
hdr "lint (shellcheck)"
if ! ((SCOPE_SHELL)); then
  skip "shellcheck (out of scope)"
elif have shellcheck; then
  sc_fail=0
  while IFS= read -r f; do
    if ! sc_out="$(shellcheck -x "$f" 2>&1)"; then
      sc_fail=1
      fail "shellcheck: $f"
      fail_detail "$sc_out"
    fi
  done < <(_audit_ls '*.sh' 'bin/clip' 'bin/clip-paste')
  ((sc_fail)) || pass "shellcheck (all bash scripts clean)"
else
  skip "shellcheck (not installed)"
fi

# ── 5b. fzf preview binary resolution (regression gate) ──────────────────────
# fzf / fzf-tab previews run their command STRING in a subshell, so a LITERAL `bat`
# there printed "command not found" in every preview pane on Debian/Ubuntu — those
# distros ship bat as `batcat` — a silent breakage that fanned out to those OS repos
# with no failing gate. The fix routes previews through $BAT_BIN (00-tools.zsh resolves
# the real name) with a cat/ls fallback. Lock it so the bug can't recur: no uncommented
# preview line in zsh/35-fzf.zsh or zsh/45-plugins.zsh may invoke a literal bat/batcat, and
# 35-fzf.zsh must still reference $BAT_BIN. Pure sed+grep (busybox-safe), shell-scoped.
hdr "fzf preview binary resolution"
if ((SCOPE_SHELL)); then
  pv_fail=0
  for f in zsh/35-fzf.zsh zsh/45-plugins.zsh; do
    # Strip comments (from the first #), then flag a bare lowercase bat/batcat command
    # token — $BAT_BIN (uppercase) is intentionally NOT matched, which is the point.
    if sed 's/#.*//' "$f" | grep -qE '(^|[^A-Za-z_$])bat(cat)?[[:space:]]'; then
      pv_fail=1
      fail "literal bat/batcat in a preview command ($f) — route it through \$BAT_BIN"
    fi
  done
  grep -q 'BAT_BIN' zsh/35-fzf.zsh || {
    pv_fail=1
    fail "zsh/35-fzf.zsh no longer references \$BAT_BIN (preview resolution lost)"
  }
  # fzf-tab appends $realpath itself and does NOT substitute fzf's `{}` placeholder. So a
  # fzf-tab preview must use the placeholder-free $_FZF_TAB_PREVIEW_CMD — NOT $_FZF_PREVIEW_CMD
  # (which ends in `{}`, the bug: that trailing `{}` reaches the previewer as a phantom arg),
  # and not an inline literal `{}` either. Flag any fzf-preview line that pairs $realpath with
  # the wrong var or a stray `{}`. ($_FZF_TAB_PREVIEW_CMD is not a substring of the check, so
  # the correct line passes.)
  while IFS= read -r _pvln; do
    [[ "$_pvln" == *fzf-preview* && "$_pvln" == *"\$realpath"* ]] || continue
    if [[ "$_pvln" == *'{}'* || "$_pvln" == *"\$_FZF_PREVIEW_CMD"* ]]; then
      pv_fail=1
      fail "fzf-tab preview must use \$_FZF_TAB_PREVIEW_CMD (no {} / no \$_FZF_PREVIEW_CMD): $_pvln"
    fi
  done < <(sed 's/#.*//' zsh/45-plugins.zsh)
  ((pv_fail)) || pass "fzf/fzf-tab previews resolve \$BAT_BIN (no literal bat/batcat, no stray {})"
else
  skip "fzf preview resolution (out of scope)"
fi

# ── 5c. Core⇄OS boundary (portable shell modules carry no OS-absolute paths) ──
# README's contract: "if it changes when the OS changes, it does NOT belong in Core."
# That rule is documented but was ungated — a hard-coded /opt/homebrew, /home/linuxbrew,
# or macOS ~/Library path could slip into a portable shell module and fan out to nine repos
# where it is simply wrong. Assert the sourced zsh modules stay OS-agnostic.
#
# THERE ARE NO PER-FILE EXCEPTIONS ANY MORE (#763). zsh/55-maint.zsh used to have one, for
# the `~/Library/LaunchAgents` literal in its built-in unit-directory fallback; deleting
# that fallback deleted the last OS-absolute path in Core, so the exemption guards nothing
# and is gone with it. Do not add another: an exception here is a standing invitation for
# a second literal to ride along beside the sanctioned one.
#
# Pure grep (busybox-safe), and CROSS-CUTTING rather than shell-scoped — the scope is
# the manifest, so it covers configs and the nvim tree too, and no --scope may skip it.
hdr "Core⇄OS boundary (no OS paths in portable Core files)"
# The scope is DERIVED FROM core.manifest, not from a hand-kept list. That list had
# quietly fallen behind the manifest three times: first the symlinked configs were
# ungated (a real /opt/homebrew drift was found downstream, baked into mise/config.toml),
# then bin/, maint/ and tmux/scripts/ — and when THOSE were added, zsh/completions/*,
# lib/ux.sh, lib/bootstrap-lib.sh and .bin/sync-upstream.sh were still missing. Every one
# of those omissions is the same bug, so the fix is structural: the manifest already IS
# the definition of "what is Core", and a file added to it is now scanned automatically.
# The blind spot cannot silently reopen, because reopening it would mean the file is not
# Core at all — which section 1 already fails on.
#
# It is also UNCONDITIONAL now (no SCOPE_SHELL guard). It used to be shell-scoped, but it
# now covers manifested nvim/, toml and config files too, and it is pure sed+grep over
# ~150 small files — cheap and cross-cutting, like the manifest/exec-bit/markdown gates.
# A narrowed --scope run must not be able to skip a fan-out-correctness check.
#
# EXCLUDED, deliberately and visibly — one class, and it is not a file of Core's:
#   · *.example — user-edited illustrations, not the live config.
bnd_fail=0
while IFS= read -r f; do
  case "$f" in
  *.example) continue ;; # user-edited illustration, not live config
  esac
  [[ -f "$f" ]] || continue
  # NOTHING is stripped. Comment-stripping was a false-negative machine: `#` is a comment
  # in shell and toml but the LENGTH OPERATOR in Lua, a delimiter inside a string is code
  # (`export P="#/opt/…"`), and a line inside a heredoc or a Lua long-bracket string is
  # runtime data however it starts. Each fix uncovered the next, because getting it right
  # needs a parser for all five grammars this now scans.
  #
  # So the rule is simply: a manifested Core file must not contain an OS-absolute path
  # ANYWHERE, prose included. Name the prefix instead of spelling it — "the Homebrew
  # prefix", not the literal. That costs one wording choice in a comment and buys a gate
  # with no hiding places at all.
  if grep -qE '/opt/homebrew|/home/linuxbrew|/usr/local/Cellar|/Library/|/mnt/c/' "$f"; then
    bnd_fail=1
    fail "OS-specific path in a portable Core file ($f) — it belongs in the OS layer, not Core"
  fi
done < <(
  # Expand the manifest: directory entries (nvim/) into their files, file entries as-is.
  #
  # _audit_ls, not plain `git ls-files`: this list feeds a CONTENT scan — each file is
  # cat'd and grepped for OS-absolute paths above — so it sits on the content side of the
  # rule in common.sh. It reads like a manifest question and is not one; the manifest
  # names the DIRECTORY, and every file under it is in scope whether or not git has seen
  # it yet. Without this, a new nvim/ lua module hardcoding a Homebrew prefix would pass
  # the boundary gate locally and only fail after `git add` — the same blind spot this
  # rule exists to close, wearing manifest clothing.
  for m in "${MANIFEST_PATHS[@]}"; do
    if [[ "$m" == */ ]]; then _audit_ls "$m"; else printf '%s\n' "$m"; fi
  done | sort -u
)
((bnd_fail)) || pass "every manifested Core file carries no OS-absolute path (scope derived from core.manifest)"

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

# ── 5f. bootstrap-lib helper adoption across the fleet ───────────────────────
# Core ships lib/bootstrap-lib.sh so the shared half of a bootstrap stops being hand-forked
# nine ways. Helpers get ADDED to it over time — usually because one repo hit a bug — and
# nothing has ever checked whether the other eight picked them up. So the file grows a fix
# and the fleet keeps the defect (#516).
#
# Measured when this section was written, and it is not a hypothetical spread:
#   blib_resolve_su 2/9 · blib_sudo_keepalive_start 1/9 · blib_user_bindirs_on_path 1/9 ·
#   blib_note_fail + blib_failures_report 2/9 · blib_wire_summary 7/9 ·
#   blib_install_core_guard 7/9 · BLIB_DRY 9/9
# Each gap is a live defect in the repos missing it: no blib_resolve_su means a hand-rolled
# `[[ "$(id -u)" -eq 0 ]]`, an ARITHMETIC comparison where an empty `id` output evaluates as
# 0 and the whole run proceeds unescalated; no blib_sudo_keepalive_start means sudo's
# timestamp expires during a long install and the re-prompt goes to a discarded stderr, i.e.
# a silent hang; no blib_failures_report means the script can record failures via
# blib_note_fail and then exit 0 announcing "complete".
#
# REPORT, DO NOT BLOCK — deliberately, and this is the load-bearing design decision.
# Seven of nine repos are short on arrival, so a failing gate would be red from its first
# run, and a gate that is red on arrival is a gate someone turns off. It states the gap and
# leaves remediation to per-repo work. Turn it into a fail only once the fleet is clean.
#
# --STRICT SAFETY: the "sibling not checked out" skip goes through skip_env, which records
# it as an ENVIRONMENT skip. --strict counts only TOOL-absent skips, so this section stays
# inert there — CI checks out only this repo. It used to achieve that by WORDING the skip
# "out of scope" so the substring classifier would let it through, which made the message
# text the gate and conflated "you narrowed this" with "this box cannot run it". The class
# is structural now, so the wording is free to say what is actually true, and
# --require-siblings can red on precisely this case without touching --strict.
#
# Enumerates the fleet through load_os_repos (lib/common.sh) — the ONE reader, since #669
# removed the three hardcoded fallback arrays. This check keeps the skip_env posture rather
# than the fan-out gates' hard exit: an unreadable fleet list should not red an advisory
# section of an otherwise-fine audit, it should say it could not cover the fleet.
hdr "bootstrap-lib helper adoption (advisory)"
_ha_root="$(cd "$HERE/.." && pwd)"
if ! load_os_repos; then
  skip_env "helper adoption ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
else
  # <helper> <what its absence costs>. Kept here rather than in bootstrap-lib.sh so the
  # rationale lives with the check that reports it; VENDORING.md carries the human contract.
  _ha_checked=0
  _ha_missing=0
  _ha_absent=0
  for _ha_repo in "${CORE_OS_REPOS[@]}"; do
    _ha_dir="$(resolve_repo_dir "$_ha_root" "$_ha_repo")" || _ha_dir="$_ha_root/$_ha_repo"
    if [[ ! -f "$_ha_dir/bootstrap.sh" ]]; then
      _ha_absent=$((_ha_absent + 1))
      continue
    fi
    _ha_checked=$((_ha_checked + 1))
    _ha_gaps=""
    for _ha_h in blib_resolve_su blib_sudo_keepalive_start blib_user_bindirs_on_path \
      blib_note_fail blib_failures_report blib_wire_summary blib_install_core_guard BLIB_DRY; do
      # A ROLE repo layers on top of an OS repo's bootstrap and does no package installation
      # of its own, so the two helpers that exist for long privileged installs do not apply.
      # Exempting them is what keeps the report actionable rather than noisy — the same shape
      # as the doctor's own exemption list.
      case "$_ha_repo:$_ha_h" in
      dotfiles-Defense:blib_sudo_keepalive_start | dotfiles-Offense:blib_sudo_keepalive_start | \
        dotfiles-Defense:blib_user_bindirs_on_path | dotfiles-Offense:blib_user_bindirs_on_path)
        continue
        ;;
      esac
      grep -q "$_ha_h" "$_ha_dir/bootstrap.sh" 2>/dev/null || _ha_gaps="$_ha_gaps $_ha_h"
    done
    if [[ -n "$_ha_gaps" ]]; then
      _ha_missing=$((_ha_missing + 1))
      ((${CORE_JSON:-0})) || printf '  %s%s%s %s does not call:%s\n' "${c_yel}" "•" "${c_rst}" "$_ha_repo" "$_ha_gaps"
    fi
  done

  if ((_ha_checked == 0)); then
    skip_env "helper adoption (no sibling OS repo checked out — nothing to read here)"
  elif ((_ha_missing)); then
    # pass(), not fail(): see REPORT, DO NOT BLOCK above. The count is the signal; the
    # per-repo lines printed just above are the detail.
    pass "helper adoption: $_ha_missing of $_ha_checked checked-out repo(s) have not adopted every helper (advisory — see the lines above, VENDORING.md has the contract)"
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
    if [[ ! -d "$_gp_dir/.git" ]]; then
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
# this is fleet drift, not a regression in the commit under test.
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

# ── 5j. the HAVE_* contract (PORTABILITY.md §5 ↔ 00-tools.zsh ↔ the fleet) ────
# zsh/00-tools.zsh sets HAVE_<TOOL> flags into every interactive shell, three OS repos read
# one of them from their os/*.zsh, and until #694 nothing declared any of that: PORTABILITY.md
# — the file that documents the Core→OS API, with a shim table naming _cache_eval and
# _core_is_wsl — did not contain the string HAVE_. So there was no basis for saying which
# flags were safe downstream, and none for saying which were removable; a rename here would
# have surfaced downstream as a shell function quietly not firing.
#
# PORTABILITY.md §5 is the declaration. This is the gate, and it runs in three directions —
# the both-ways shape §1 already gives core.manifest, plus a third that keeps the pruning
# from undoing itself:
#
#   1. DECLARED ⊆ SET.      A flag the doc offers downstream that 00-tools.zsh does not set
#                           is a lie in the contract — exactly what a Core rename leaves
#                           behind, and the failure mode the doc exists to prevent.
#   2. FLEET READS ⊆ DECLARED. An OS or role repo reading a Core-namespace flag it does not
#                           itself set is coupled to Core's internals. Declare it (a one-line
#                           table row) or stop reading it.
#   3. SET ⇒ HAS A READER.  A flag nothing reads is a global in every interactive shell that
#                           can only go stale, and nothing notices when it does. #694 dropped
#                           fourteen of those; this is what stops them coming back.
#
# WHAT "READS" MEANS, and why it is a sigil match rather than a bare name. A read is
# `$HAVE_X` or `${HAVE_X…}`; a comment mentioning the flag writes the bare name. That
# distinction is the whole reason this needs no comment-stripping — the trap PORTABILITY.md
# §3 documents at length, where five grammars each hide a `#` somewhere. Measured across the
# fleet when this was written: bare-name matching found HAVE_ASTGREP/HAVE_JNV/HAVE_SHELLCHECK
# in one dotfiles-Offense COMMENT and HAVE_DIFFT/HAVE_UV/HAVE_VIDDY in five more, none of them
# reads; sigil matching found exactly the three real ones. The cost is one wording rule, in
# the doc: do not put a `$` in front of a flag name in prose.
#
# A repo that SETS a flag owns it — dotfiles-Offense and dotfiles-Defense define ~20 apiece in
# the same namespace, legitimately, and dotfiles-Defense re-probes jq into HAVE_JQ. Subtracting
# each repo's own assignments before comparing is what keeps those out of direction 2; the
# contract is only ever about reading a name you did not set.
#
# NO --exclude-dir AND NO -I anywhere below. Both are GNU extensions that busybox grep
# REJECTS, and the Alpine leg runs busybox — the same trap that made _core_make_gate_hits
# report Core as the repo missing its own rule. The vendored core/ subtree (which would
# otherwise answer for Core in every OS repo and make direction 2 vacuous) is pruned with
# `find` instead, which is portable.
#
# Direction 2 reads sibling clones, so it takes the skip_env posture of §5f and §5h: CI checks
# out this repo alone, and a gate that only passes on a laptop with the fleet beside it is a
# gate nobody trusts.
#
# WHICH MEANS DIRECTION 2 IS ADVISORY IN PRACTICE TODAY, and saying so is better than letting
# the next reader assume otherwise. It fires where the fleet sits beside Core — a maintainer's
# `make audit`, the scheduled fleet jobs — and records a skip on every default CI run. The
# reusable lint workflow the OS repos call does not run it, so an OS-repo PR adding an
# undeclared read can merge without a red. The fix is a caller-side leg in lint-call.yml
# beside the _core_return_trap_hits and _core_owned_block_hits legs, which already share
# rules with this file for exactly this reason — but that leg needs the DECLARED table from a
# vendored checkout, and PORTABILITY.md is not in core.vendor. Vendoring it is a change to
# the allowlist with its own nine-repo blast radius, so it is #866 rather than this PR.
#
# Directions 1 and 3 read this repo's own files and are unconditional.
hdr "HAVE_* contract (PORTABILITY.md §5 ↔ 00-tools.zsh ↔ fleet)"
hv_tools="$HERE/zsh/00-tools.zsh"
hv_doc="$HERE/PORTABILITY.md"
hv_fail=0
if [ ! -f "$hv_tools" ] || [ ! -f "$hv_doc" ]; then
  fail "HAVE_* contract: zsh/00-tools.zsh or PORTABILITY.md is missing — the contract gate checked NOTHING this run"
  hv_fail=1
else
  # The declared surface: the table under PORTABILITY.md §5's "What downstream may use".
  # Range-anchored to that heading so an unrelated table elsewhere in the doc can never
  # widen the surface by accident.
  hv_declared=" $(awk '
    /^### What downstream may use/ { inb = 1; next }
    inb && /^### / { inb = 0 }
    inb && /^\|[ \t]*`HAVE_[A-Z0-9_]+`/ {
      if (match($0, /HAVE_[A-Z0-9_]+/)) print substr($0, RSTART, RLENGTH)
    }
  ' "$hv_doc" | sort -u | tr '\n' ' ') "
  # What Core actually sets. Comment lines are dropped first: this file's own prose spells
  # the idiom as `_have x && HAVE_X=1`, which would otherwise register as a flag named
  # HAVE_X that nothing sets and nothing reads — a finding invented by the gate's own docs.
  hv_set=" $(grep -v '^[[:space:]]*#' "$hv_tools" | grep -oE 'HAVE_[A-Z0-9_]+=1' | sed 's/=1$//' | sort -u | tr '\n' ' ') "
  # Every sigil read in Core's own zsh modules — and ONLY those, which is the whole
  # precision of direction 3. A HAVE_* flag is a shell parameter that is never exported, so
  # the only code that can read one is code SOURCED INTO THE SAME SHELL: zsh/*.zsh here, and
  # the OS/role layers downstream that direction 2 covers. bin/, scripts/, maint/ and
  # tmux/scripts/ run as CHILD processes where the flag does not exist, and nvim's lua cannot
  # see a zsh parameter at all — every HAVE_* mention in those trees is prose about Core, not
  # a read of it.
  #
  # SCANNING THEM ANYWAY IS WHAT MADE AN EARLIER DRAFT WRONG (#694 review): including
  # scripts/ let scripts/test-core.sh count as a reader, and HAVE_GRON — whose only
  # `${HAVE_GRON:-}` in the tree is one negative fixture — passed direction 3 while being
  # exactly the dead global this section exists to find. A test is not a consumer. Its flag
  # is pruned and that fixture now asserts against the ledger, which is what it meant.
  #
  # Whole-line comments are dropped for the reason _core_have_read_hits states: the sigil
  # rule alone still reads `# gated on $HAVE_X` as a read.
  # Both read shapes, kept in step with _core_have_read_hits: the sigil forms, and the
  # no-sigil ARITHMETIC form `(( HAVE_X ))`, which needs no `$` and which the sigil pattern
  # cannot see. Out of step, direction 3 would report a flag as unread that a Core module
  # reads perfectly well, and the fix would be to delete a live flag.
  hv_read=" $( { grep -rhv '^[[:space:]]*#' "$HERE/zsh" 2>/dev/null \
      | grep -oE '[$][{]?([(][^)]*[)])?[+]?HAVE_[A-Z0-9_]+' 2>/dev/null
    grep -rhv '^[[:space:]]*#' "$HERE/zsh" 2>/dev/null | grep -F '((' 2>/dev/null \
      | grep -oE 'HAVE_[A-Z0-9_]+' 2>/dev/null
  } | grep -oE 'HAVE_[A-Z0-9_]+' | sort -u | tr '\n' ' ') "

  # PARSING NOTHING IS A FAILURE, NOT A PASS. Rename or delete §5's heading and hv_declared
  # comes back empty — at which point direction 1 is vacuous, direction 2 skips on any box
  # without the fleet beside it (which is every CI runner), and direction 3 still passes
  # because HAVE_ATUIN has an internal reader in 00-tools.zsh too. The whole section would
  # report green over NO declared surface at all, which is the failure mode #682 named: a
  # drift gate that checked nothing must never report green.
  hv_ndecl=0
  for hv_f in $hv_declared; do hv_ndecl=$((hv_ndecl + 1)); done
  if ((hv_ndecl == 0)); then
    fail "HAVE_* contract: parsed NO declared flags out of PORTABILITY.md §5 — its '### What downstream may use' heading or table is missing or renamed. The contract gate checked nothing this run"
    hv_fail=1
  fi

  # ── direction 1: every declared flag is one Core sets ──
  for hv_f in $hv_declared; do
    case "$hv_set" in
    *" $hv_f "*) ;;
    *)
      fail "HAVE_* contract: PORTABILITY.md §5 declares $hv_f for downstream use, but zsh/00-tools.zsh does not set it — the declaration is stale. Restore the assignment, or drop the table row (and migrate whoever reads it)"
      hv_fail=1
      ;;
    esac
  done

  # ── direction 3: every flag Core sets has a reader ──
  for hv_f in $hv_set; do
    case "$hv_read$hv_declared" in
    *" $hv_f "*) ;;
    *)
      fail "HAVE_* contract: zsh/00-tools.zsh sets $hv_f and nothing reads it — not a Core module, not PORTABILITY.md §5's table. Drop the \`&& $hv_f=1\` and keep the bare \`_have\` probe (the _CORE_PROBED ledger is what core-doctor reads), or declare it"
      hv_fail=1
      ;;
    esac
  done

  # ── direction 2: no OS or role repo reads an undeclared Core-namespace flag ──
  hv_root="$(cd "$HERE/.." && pwd)"
  hv_checked=0
  hv_absent=0
  hv_fleet=1
  if ! load_os_repos; then
    hv_fleet=0
    skip_env "HAVE_* contract: fleet half ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
  else
    for hv_repo in "${CORE_OS_REPOS[@]}"; do
      hv_dir="$(resolve_repo_dir "$hv_root" "$hv_repo")" || hv_dir="$hv_root/$hv_repo"
      if [ ! -d "$hv_dir" ]; then
        hv_absent=$((hv_absent + 1))
        continue
      fi
      # The matcher lives in scripts/lib/common.sh so it can be driven by fixtures rather
      # than only by hand (#694 review): it returns the names this repo READS and does not
      # itself SET, with vendored core/ pruned and whole-line comments dropped on both sides.
      # A layer that assigns a name owns it — both role repos legitimately carry ~20 of their
      # own — so subtracting the repo's own assignments is what keeps those out of here.
      [ -d "$hv_dir" ] || continue
      hv_checked=$((hv_checked + 1))
      hv_uses="$(_core_have_read_hits "$hv_dir")"
      for hv_f in $hv_uses; do
        case "$hv_declared" in *" $hv_f "*) continue ;; esac
        # Two different defects, and the remedy differs, so they are reported apart: a flag
        # Core no longer sets is already broken on every box, while an undeclared one that
        # Core does set works today and is merely uncontracted.
        case "$hv_set" in
        *" $hv_f "*)
          fail "HAVE_* contract: $hv_repo reads Core's $hv_f, which PORTABILITY.md §5 does not declare for downstream use. Add the table row in the same change (declaring is the ask, not a workaround), or probe the tool with \`command -v\` instead"
          ;;
        *)
          fail "HAVE_* contract: $hv_repo reads $hv_f, which it does not set and Core does not set either — a flag Core has removed or renamed, so the read is already dead on every box. Fix the read, or restore the flag in zsh/00-tools.zsh and declare it in PORTABILITY.md §5"
          ;;
        esac
        hv_fail=1
      done
    done
    [ "$hv_checked" = 0 ] && skip_env "HAVE_* contract: fleet half (no sibling OS repo checked out — nothing to read here)"
    ((hv_absent)) && skip_env "HAVE_* contract: $hv_absent repo(s) not checked out — fleet half not covered by this run"
  fi
  if ((hv_fail == 0)); then
    if ((hv_fleet)) && [ "$hv_checked" != 0 ]; then
      pass "HAVE_* contract (declared ⊆ set, set ⇒ read, and $hv_checked checked-out repo(s) read only declared flags)"
    else
      pass "HAVE_* contract (declared ⊆ set, set ⇒ read; the fleet half did not run — see the skip above)"
    fi
  fi
fi
unset hv_tools hv_doc hv_declared hv_ndecl hv_set hv_read hv_f hv_root hv_repo hv_dir hv_uses hv_checked hv_absent hv_fleet hv_fail

# ── 6. config files (toml / yaml parse) ──────────────────────────────────────
# A malformed starship.toml / mise config.toml / ci.yml is still valid *text* —
# so zsh -n and shellcheck never look at it — yet it breaks every one of the 9
# consumers at runtime (dead prompt, dead runtime manager, dead CI). Assert that
# every tracked TOML and YAML file actually PARSES. Best-effort + graceful skip,
# exactly like the linters above: TOML via python3 `tomllib` (stdlib since 3.11),
# YAML via python3 PyYAML when importable. pre-commit's check-toml/check-yaml are
# the hermetic author-time mirror of this same gate.
hdr "config files (toml / yaml)"
if have python3 && python3 -c 'import tomllib' 2>/dev/null; then
  while IFS= read -r f; do
    if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$f" 2>/dev/null; then
      pass "toml $f"
    else fail "toml parse error: $f"; fi
  done < <(_audit_ls '*.toml' '*.toml.example')
else
  skip "toml parse (python3 tomllib unavailable — needs python ≥3.11)"
fi
if have python3 && python3 -c 'import yaml' 2>/dev/null; then
  while IFS= read -r f; do
    # safe_load_all: workflow/compose YAML can be multi-document (--- separators).
    if python3 -c 'import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))' "$f" 2>/dev/null; then
      pass "yaml $f"
    else fail "yaml parse error: $f"; fi
  done < <(_audit_ls '*.yml' '*.yaml')
else
  skip "yaml parse (python3 PyYAML not importable)"
fi
# JSON: nvim/lazy-lock.json pins every Neovim plugin's commit for a reproducible
# editor across the 8 repos — a truncated/corrupt lock breaks `:Lazy restore` for
# all of them, and like the toml/yaml above it's valid *text* the other gates skip.
# `*.json` (not `*.jsonc`) so the JSONC config files keep their comments. json is in
# the stdlib, so this only needs python3 — no extra import gate like PyYAML.
if have python3; then
  while IFS= read -r f; do
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
      pass "json $f"
    else fail "json parse error: $f"; fi
  done < <(_audit_ls '*.json')
else
  skip "json parse (python3 unavailable)"
fi

# ── 7. markdown (markdownlint) ────────────────────────────────────────────────
# The docs ARE the deliverable on a public showcase repo, and they're the one file
# class shellcheck/zsh -n/toml-yaml never look at — so a leaked template tag or a
# broken heading ships unnoticed (it did: see CHANGELOG.md's history). markdownlint
# is the gate; .markdownlint.jsonc is the shared rule config (line-length off for
# the wide tables, everything structural on). Graceful skip when absent, exactly
# like the linters above; pre-commit's markdownlint-cli2 hook is the author-time
# mirror, and CI installs it so the gate actually runs there.
hdr "markdown (markdownlint)"
# Resolve a RUNNABLE markdownlint WITHOUT requiring it on PATH — the npm global bin
# frequently lands off PATH, making this the most-skipped gate in remote sessions even
# when the tool IS installed. Prefer a PATH binary; else `npx --no-install` (resolves a
# global/local install with NO network fetch); else a repo-local node_modules bin. Only a
# genuinely-absent tool still skips — which --strict (a fully-provisioned CI leg) then catches.
_mdl=()
if have markdownlint-cli2; then
  _mdl=(markdownlint-cli2)
elif have npx && npx --no-install markdownlint-cli2 --version >/dev/null 2>&1; then
  _mdl=(npx --no-install markdownlint-cli2)
elif [[ -x node_modules/.bin/markdownlint-cli2 ]]; then
  _mdl=(node_modules/.bin/markdownlint-cli2)
fi
if ((${#_mdl[@]})); then
  if md_out="$("${_mdl[@]}" "**/*.md" 2>&1)"; then
    pass "markdownlint (all tracked markdown clean)"
  else
    fail "markdownlint reported issues — run: markdownlint-cli2 '**/*.md'"
    fail_detail "$md_out"
  fi
else
  skip "markdownlint (markdownlint-cli2 not installed — npm i -g markdownlint-cli2)"
fi

# ── 8. workflows (actionlint) ─────────────────────────────────────────────────
# .github/workflows/*.yml is a fan-out artifact with no gate of its own: the YAML
# parse in section 6 proves it's well-formed text, not that the workflow is VALID —
# a bad `needs:`, an undefined job output, or a shellcheck error inside a run: block
# all parse as YAML and still break CI for every push. actionlint catches those (and
# runs shellcheck on the run: scripts). Graceful skip when absent, like every linter
# above; CI installs it pinned (ACTIONLINT_VERSION) so the gate actually runs there.
hdr "workflows (actionlint)"
if have actionlint; then
  if al_out="$(actionlint 2>&1)"; then
    pass "actionlint (workflows valid)"
  else
    fail "actionlint reported issues — run: actionlint"
    fail_detail "$al_out"
  fi
else
  skip "actionlint (not installed — go install github.com/rhysd/actionlint/cmd/actionlint@latest)"
fi

# ── 8a. reusable-workflow ref majors ─────────────────────────────────────────
# actionlint above proves the workflows are VALID. It cannot know that a valid
# `ref: v4` is the wrong major — that is a fleet-policy question, and it is the one
# this repo has now got wrong twice (v3→v4, ten minors; v4→v5, until #744). See
# _core_workflow_ref_hits for the full history and the release ordering this implies.
#
# Always-on: no tool to be absent, so this never skips and cannot go green-because-absent
# — which is the exact failure mode it exists to close.
hdr "reusable-workflow ref majors"
if [[ -r core.version ]]; then
  wfr_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ "$wfr_major" =~ ^[0-9]+$ ]]; then
    wfr_out="$(_core_workflow_ref_hits . "$wfr_major")"
    if [[ -z "$wfr_out" ]]; then
      pass "every dotfiles-core checkout in .github/workflows/ pins ref: v$wfr_major (matches core.version)"
    else
      fail "a reusable workflow checks dotfiles-core out at a foreign major — the job would run another major's scripts"
      fail_detail "$wfr_out"
    fi
    unset wfr_out
  else
    fail "core.version major unreadable ('$wfr_major') — cannot check workflow ref majors"
  fi
  unset wfr_major
else
  fail "core.version missing — cannot check workflow ref majors"
fi

# ── 8a-bis. reusable-workflow caller-example majors ───────────────────────────
# 8a proves the `ref:` KEYS point at the right major. It does not read comments, so at
# v5 → v6 every ref moved and 25 `@v5` references survived in the prose describing them
# (#821) — including the copyable `uses:` examples six *-call.yml headers hand to OS-repo
# maintainers. Nothing failed, because nothing was wrong in the code; a maintainer who
# copied one simply pinned a retired major. Same silent shape 8a exists to end, one level
# up, so it gets the same treatment: made executable rather than commented about.
#
# Scoped to a full `dotfiles-core/.github/workflows/<file>@vN` path, which is always a
# copyable reference and never narrative — see _core_workflow_example_hits for why a
# blanket `@vN` scan would be worse than no gate.
#
# Always-on, for 8a's reason: no tool to be absent, so it cannot go green-because-absent.
hdr "reusable-workflow caller-example majors"
if [[ -r core.version ]]; then
  wfe_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ "$wfe_major" =~ ^[0-9]+$ ]]; then
    wfe_out="$(_core_workflow_example_hits . "$wfe_major")"
    if [[ -z "$wfe_out" ]]; then
      pass "every documented caller example in .github/workflows/ names @v$wfe_major (matches core.version)"
    else
      fail "a documented caller example pins a foreign major — copying it would put an OS repo on a retired Core"
      fail_detail "$wfe_out"
    fi
    unset wfe_out
  else
    fail "core.version major unreadable ('$wfe_major') — cannot check caller-example majors"
  fi
  unset wfe_major
else
  fail "core.version missing — cannot check caller-example majors"
fi

# ── 8a-ter. first-vendor pin majors ──────────────────────────────────────────
# 8a holds the `ref:` keys to the current major and 8a-bis the copyable caller examples.
# The third copyable instruction that names a major is the FIRST-VENDOR recipe — the
# `refs/tags/vN` a new OS repo subtree-adds, the `git checkout vN` / `vN^{commit}` that
# stamps its lock, and new-os-repo.sh's default for the same — and it has rotted at every
# major cut so far (v4 → v5 by hand in three entries; v5 → v6 unnoticed for two releases,
# so a freshly scaffolded repo vendored a retired Core by default). Same silent shape,
# same treatment: read the major from core.version, hold the text to it. The rule and its
# exemptions (history, fixtures, exact pins) live on _core_vendor_pin_hits.
#
# Always-on, for 8a's reason: no tool to be absent, so it cannot go green-because-absent.
hdr "first-vendor pin majors"
if [[ -r core.version ]]; then
  vpn_major="$(tr -d '[:space:]' <core.version | cut -d. -f1)"
  if [[ "$vpn_major" =~ ^[0-9]+$ ]]; then
    vpn_out="$(_core_vendor_pin_hits . "$vpn_major")"
    if [[ -z "$vpn_out" ]]; then
      pass "every first-vendor pin (docs + scripts/, incl. new-os-repo.sh's default) names v$vpn_major (matches core.version)"
    else
      fail "a first-vendor pin names a foreign major — a new repo scaffolded from it vendors a retired Core"
      fail_detail "$vpn_out"
    fi
    unset vpn_out
  else
    fail "core.version major unreadable ('$vpn_major') — cannot check first-vendor pin majors"
  fi
  unset vpn_major
else
  fail "core.version missing — cannot check first-vendor pin majors"
fi

# ── 8b. secrets (gitleaks) ────────────────────────────────────────────────────
# Core ships 1Password helpers (zsh/50-op.zsh), a git-identity template, and history
# secret-ignore patterns — and fans out to 9 PUBLIC repos, where a committed token
# amplifies N-way. None of the gates above look for secrets: shellcheck/zsh -n read
# syntax, the toml/yaml/json checks read structure, markdownlint reads prose. So
# scan the working tree for credentials. `gitleaks dir` is the filesystem scan (every
# tracked + untracked file at HEAD), the CI mirror of the gitleaks pre-commit hook
# (which guards the commit diff at author time). Always-on + graceful skip, exactly
# like the linters above; CI installs it pinned (GITLEAKS_VERSION) so it runs there.
hdr "secrets (gitleaks)"
if have gitleaks; then
  # -v is what makes the captured output worth anything: without it gitleaks prints only
  # "leaks found: N" and the file/line/rule stay hidden — the same non-answer this change
  # exists to remove. --no-color matches the flag already passed to luacheck, so the text
  # captured into a log is plain rather than escape sequences.
  # -c gitleaks.toml: the ONE fleet policy (see that file's header). Without it this
  # gate and lint-call.yml's `secrets` job would run different rule sets against the same
  # class of tree — and a finding that is real here and allowlisted there (or the reverse)
  # is worse than either gate alone, because it makes the disagreement look like a bug in
  # the code rather than in the config.
  if gl_out="$(gitleaks dir . -c gitleaks.toml --no-banner --redact -v --no-color 2>&1)"; then
    pass "gitleaks (no secrets in the working tree)"
  else
    fail "gitleaks found potential secrets — run: gitleaks dir . -c gitleaks.toml --redact -v"
    # Safe to print BECAUSE of --redact: gitleaks replaces the matched value with
    # REDACTED, so the report names the file, line, rule and fingerprint without
    # reproducing the secret. Drop --redact and this becomes the one gate whose output
    # must stay dark.
    fail_detail "$gl_out"
  fi
else
  skip "gitleaks (not installed — https://github.com/gitleaks/gitleaks/releases)"
fi

# ── 8c. modernization floor (check-modern.sh) ────────────────────────────────
# actionlint (8) proves a workflow is VALID; it says nothing about whether it's MODERN.
# scripts/modern-baseline.yml declares the floor (no ::set-output, no EOL runners, every
# external action SHA-pinned, every container image @sha256-pinned) and check-modern.sh
# enforces it — so a workflow can't silently regress below it (this closes G8: mutable
# container tags were the one break in the fleet's otherwise-strict pinning). Pure
# bash+awk, always run (our own script, no `have` gate).
hdr "modernization floor (check-modern.sh)"
if _cm_out="$("$HERE/scripts/check-modern.sh" 2>&1)"; then
  pass "check-modern (CI meets scripts/modern-baseline.yml)"
else
  printf '%s\n' "$_cm_out" >&2
  fail "check-modern found violations (above) — run: ./scripts/check-modern.sh"
fi

# ── 8d. Makefile gates that cannot do what their name says ────────────────────
# ShellCheck reads this file's SYNTAX and `make -n` would read what it EXPANDS to; neither
# answers the question this asks, which is whether a target's own claim survives the shell
# make gives it. A guard that prints "skipping" and then runs the missing tool is valid
# bash, expands fine, and exits 127 — the same shape as §8a's `ref: vN`, where the ref
# resolves, the job goes green, and the wrong code runs.
#
# THIS IS CORE'S HALF ONLY. The defect was found in the eight OS repos
# (dotgibson/dotfiles-core#775, eleven instances); those are judged by lint-call.yml's
# `make-gates` leg, which runs this same function against the CALLER. This section keeps
# the authoring repo honest, because Core has a Makefile with the same target shapes and
# nothing would otherwise stop the pattern being reintroduced here and vendored outward.
#
# Always-on: no tool to be absent, so it can never skip — the exact failure mode it exists
# to close, and the same reasoning §8a records.
hdr "Makefile gates (skip guards, discarded statuses, missing mirrors)"
mkg_out="$(_core_make_gate_hits .)"
if [[ -z "$mkg_out" ]]; then
  pass "every Makefile gate skips, fails and scopes as its help text claims"
else
  fail "a Makefile gate does not do what its name says — see dotgibson/dotfiles-core#775"
  fail_detail "$mkg_out"
fi
unset mkg_out

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
    if [[ ! -d "$_cf_dir/.git" ]]; then
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

# ── 9d. theme drift (theme/palette.toml ↔ every generated block) ─────────────
# theme/palette.toml is the ONE place a colour is authored; scripts/gen-theme.sh renders
# the ~90 literals that were previously kept in step BY COMMENT across thirteen files.
# Those comments said "kept in sync with starship.toml + tmux.conf @tn_*" — six of them,
# in as many words — and nothing checked any of them, which is the whole defect: a
# hand-edit to one file was a valid, lintable, shippable change that fanned a
# half-recoloured stack out to nine repos. A comment is not a gate (the lesson
# _core_workflow_ref_hits records twice over).
#
# Numbered 9d because the §9 family is derived-copy consistency — 9 is
# tool-versions.env ↔ .pre-commit-config.yaml, 9b is *_VERSION ⇒ *_SHA256 and
# core.version ↔ CHANGELOG. Appended, never renumbered: §9c's own comment records why
# section numbers are append-only once a CHANGELOG entry has pinned them.
#
# ALWAYS ON, no `have` gate — §8c's posture, for §8c's reason. gen-theme.sh --check is
# pure bash + awk with no optional dependency, so it can never SKIP, so --strict on the
# Linux leg can never trip on it and the Alpine and Arch container legs run it
# identically. The moment this needs python3 it stops being a gate on a bare macOS box
# and becomes a suggestion.
#
# NOT SCOPE-GUARDED, for §5c's reason: the consumers include starship.toml,
# lazygit/config.yml and examples/starship.showcase.toml, and `examples/` and `*.md` are
# INERT to ci-classify.sh — so a showcase-only push arrives here as --scope none and must
# still be gated. A narrowed run must not be able to skip a fan-out-correctness check.
#
# THE EXIT CODES ARE THE CONTRACT, and the two failures are different facts. 1 = DRIFT (a
# generated block is stale). 2 or anything else = the generator could not run, which must
# NOT be rendered as drift: a crashing gate that reports "theme drift" teaches everyone to
# re-run it and ignore it, which is how a gate stops being one.
hdr "theme drift (gen-theme.sh --check)"
_gt_out="$("$HERE/scripts/gen-theme.sh" --check 2>&1)" && _gt_rc=0 || _gt_rc=$?
if ((_gt_rc == 0)); then
  pass "gen-theme (every generated block matches theme/palette.toml)"
elif ((_gt_rc == 1)); then
  fail "theme drift — a generated block no longer matches theme/palette.toml; run: make gen-theme"
  fail_detail "$_gt_out"
else
  fail "gen-theme.sh --check could not run (exit $_gt_rc) — the drift gate checked NOTHING this run"
  fail_detail "$_gt_out"
fi
unset _gt_out _gt_rc
# ── 9e. the vendored CHANGELOG digest is not stale ───────────────────────────
# CHANGELOG.recent.md is GENERATED (scripts/gen-changelog-recent.sh) and COMMITTED, and
# core.vendor ships it into every OS repo's core/ so `core whatsnew` can answer offline
# (#680). Generated-and-committed only works if something proves the commit still matches
# the generator, and NOTHING ELSE HERE CAN: §1c proves only that the path EXISTS, §1e never
# walks it (it is DATA, not an `# entry` root), and core-integrity.sh compares TREE HASHES —
# where a consistently-stale blob hashes consistently and reads as `pristine` in all nine
# repos. So re-render and compare BYTES.
#
# A stale digest is a box being told about releases it does not have, or not told about the
# one it does — the exact failure the feature exists to prevent, fanned out nine ways.
# release.sh regenerates at promotion time precisely so this gate PROVES the result rather
# than reporting staleness the release itself created.
#
# ALWAYS-ON: no tool can be absent, so it cannot go green-because-absent. The only skip
# mirrors the coherence gate above — an unreadable CHANGELOG.md. A missing GENERATOR is a
# fail, not a skip: it is tracked, so its absence is real drift.
hdr "vendored CHANGELOG digest (CHANGELOG.recent.md)"
_cr_gen="scripts/gen-changelog-recent.sh"
_cr_out="CHANGELOG.recent.md"
if [[ ! -r CHANGELOG.md ]]; then
  skip "CHANGELOG digest freshness (CHANGELOG.md unreadable)"
elif [[ ! -x "$_cr_gen" ]]; then
  fail "$_cr_gen missing or not executable — nothing can regenerate $_cr_out, and nine repos would vendor whatever last landed"
elif [[ ! -r "$_cr_out" ]]; then
  fail "$_cr_out missing — core.vendor ships it to nine repos for \`core whatsnew\`; run: ./$_cr_gen"
else
  _cr_tmp="$(mktemp "${TMPDIR:-/tmp}/core-changelog-recent.XXXXXX")"
  if [[ -z "$_cr_tmp" ]]; then
    fail "CHANGELOG digest freshness: mktemp failed — cannot render a comparison copy"
  elif ! ./"$_cr_gen" --stdout >"$_cr_tmp" 2>/dev/null; then
    fail "$_cr_gen --stdout failed — run it by hand to see why"
    rm -f "$_cr_tmp"
  elif core_files_identical "$_cr_tmp" "$_cr_out"; then
    pass "$_cr_out is byte-identical to a fresh render"
    rm -f "$_cr_tmp"
  else
    # NAME THE FIX IN THE FAIL LINE: the operator has the answer here, not after a round
    # trip. fail_detail carries the actual delta.
    fail "$_cr_out is STALE or hand-edited — nine repos would vendor a digest that does not match CHANGELOG.md. Run: ./$_cr_gen"
    # `git diff --no-index`, not diffutils: same #572 rule as the comparison above — the
    # delta must render on a box that has no `diff`.
    fail_detail "$(git --no-pager diff --no-index -- "$_cr_out" "$_cr_tmp" 2>/dev/null)"
    rm -f "$_cr_tmp"
  fi
  unset _cr_tmp
fi
unset _cr_gen _cr_out

# ── 9f. the cross-shell parity contract covers itself ────────────────────────
# PARITY.md is the zsh<->pwsh contract and scripts/parity-check.sh is its gate. Until
# #682 that gate ran ONLY on `make parity-check` and a weekly cron, so an unenforced or
# false row merged clean and sat until Monday — which is how PARITY.md promised an
# `Alt+C` dir-jump binding that NEITHER shell has ever bound, for years, with the gate
# green the whole time.
#
# It belongs on the blocking path because its most valuable assertion is Core-only: the
# coverage half (every `aligned` row has a check, every check names a real row) reads
# PARITY.md and the CHECKS array, both in THIS repo, and needs no sibling checkout. The
# cross-repo half self-skips without dotfiles-Windows, exactly like §9c's fleet coverage,
# so a Core-only clone still runs green here.
#
# NOT SCOPE-GUARDED, for §9d's reason: PARITY.md is a `*.md` file and INERT to
# ci-classify.sh, so the very push that adds an unenforced row arrives as --scope none.
# A narrowed run must not be able to skip a contract check.
#
# THE EXIT CODES ARE THE CONTRACT, as in §9d: 1 = a real finding (drift or an uncovered
# row), 2+ = the gate could not run, which must NOT be rendered as a clean contract.
hdr "cross-shell parity (parity-check.sh)"
# CORE_JSON=0 at the child boundary, deliberately. `audit --json` EXPORTS CORE_JSON=1 (see
# the --json arm), which tells common.sh's skip() to print nothing — and the notices below
# are read out of this child's output. Inheriting it would have made a --json run see no
# skip lines and report a full zsh+pwsh pass on a box with no pwsh file: a gate reporting
# more coverage than it had, which is the defect this whole section exists to end. The
# child's stdout is captured either way, so nothing leaks into the JSON object on stdout.
_pc_out="$(CORE_JSON=0 "$HERE/scripts/parity-check.sh" --quiet 2>&1)" && _pc_rc=0 || _pc_rc=$?
# The CLASSIFICATION lives in common.sh (_core_parity_verdict) so test-core.sh can drive it;
# this block only RENDERS. Both defects review found here — inheriting CORE_JSON and printing
# an unqualified pass — were in logic that no test could reach from outside the audit.
case "$(_core_parity_verdict "$_pc_rc" "$_pc_out")" in
ok-full)
  pass "parity coverage — every aligned PARITY.md row has a check behind it"
  pass "parity contract holds across zsh + pwsh"
  ;;
ok-defaults)
  pass "parity coverage — every aligned PARITY.md row has a check behind it"
  # QUALIFIED HERE, not walked back on the next line: the reader believes the green line.
  pass "parity contract holds across zsh + pwsh for every CONFIGURED row (framework-default halves are reported below, not asserted)"
  # A half the child refused to certify must stay uncertified here too.
  # skip_note, not skip: nothing is ABSENT here. A plain skip counts as a missing TOOL, so
  # --strict would fail a fully-provisioned box purely because the contract is being honest
  # about a PSReadLine default — and would disagree with `parity-check.sh --strict`, which
  # accepts the same reported default.
  skip_note "cross-shell parity: $(printf '%s\n' "$_pc_out" | grep -c "nothing to grep") pwsh half/halves are framework defaults — reported by parity-check.sh, not asserted"
  ;;
ok-no-sibling)
  pass "parity coverage — every aligned PARITY.md row has a check behind it"
  # skip_env, not skip: a coverage gap the BOX could not cover (no sibling repo), so
  # --require-siblings can redden it, exactly like §5f/§9c's fleet-wide gates.
  skip_env "cross-shell parity: dotfiles-Windows not checked out — the pwsh half was NOT verified"
  ;;
drift)
  fail "cross-shell parity — an aligned PARITY.md row is unenforced or has drifted; run: make parity-check"
  fail_detail "$_pc_out"
  ;;
*)
  fail "parity-check.sh could not run (exit $_pc_rc) — the parity contract went UNCHECKED this run"
  fail_detail "$_pc_out"
  ;;
esac
unset _pc_out _pc_rc

# ── 9g. aliases.md drift (the zsh sources ↔ every generated table) ───────────
# aliases.md's tables are GENERATED by scripts/gen-aliases.sh from zsh/20-aliases.zsh,
# zsh/25-git.zsh and zsh/30-functions.zsh (#685). Until then they were a hand-copy of
# ~200 lines the shell already held, kept in step by a sentence — "the descriptions
# below are the same one-liners those surfaces print" — and one already wasn't: mkcd was
# described three ways in three places. The defect §9d closes for colour, the same answer.
#
# THE GATE IS TWO FACTS. --check exits 1 when a rendered table differs from what is on
# disk (a source edited without regenerating, or a table edited by hand). It exits 2 when
# the sources and the registry disagree — an alias defined that no table lists, a name
# listed that nothing defines, a marker missing or unregistered — which is "cannot run",
# not drift, and is rendered as a different failure so a broken gate is never read as a
# stale doc. Both are red; only the message differs, and the message names the fix.
#
# ALWAYS ON and NOT SCOPE-GUARDED, for §9d's reasons: pure bash + awk, so it can never
# SKIP; and aliases.md is a `*.md` file, INERT to ci-classify.sh, so the very push that
# hand-edits a table arrives here as --scope none and must still be gated.
hdr "aliases.md drift (gen-aliases.sh --check)"
_ga_out="$("$HERE/scripts/gen-aliases.sh" --check 2>&1)" && _ga_rc=0 || _ga_rc=$?
if ((_ga_rc == 0)); then
  pass "gen-aliases (every generated table in aliases.md matches the zsh sources)"
elif ((_ga_rc == 1)); then
  fail "aliases.md drift — a generated table no longer matches the zsh sources; run: make gen-aliases"
  fail_detail "$_ga_out"
else
  fail "gen-aliases.sh --check could not run (exit $_ga_rc) — an alias is unlisted, a listed name is undefined, or a marker is broken; the drift gate checked NOTHING this run"
  fail_detail "$_ga_out"
fi
unset _ga_out _ga_rc

# ── 9h. PORTING-MATRIX.md drift (the OS repos ↔ both generated tables) ───────
# PORTING-MATRIX.md's package-manager and package-name tables are GENERATED by
# scripts/gen-porting-matrix.sh from the sibling OS repos' os/*.capabilities and
# install/packages.txt (#686) — the same answer §9d gives colour and §9g gives the alias
# cheat sheet. The ~1,100 lines of footnotes around them are hand-written and untouched.
#
# THE GATE IS THREE FACTS, one more than §9g. --check exits 1 on drift (a repo renamed a
# package, bumped a `# min:` floor or changed a verb without regenerating; or a table was
# edited by hand). It exits 2 when it cannot answer — a derived cell no packages.txt line
# matches, an asserted cell the repo now installs, a declaration missing a key, a broken
# marker. And it exits 3 when a required sibling is NOT CHECKED OUT, which is the case
# §9g can never be in: its inputs are this repo's own files, these are another clone's.
#
# 3 IS AN ENVIRONMENT SKIP, not a failure — the posture §9c, §5f and fleet-drift.sh take
# for the same input. CI checks out this repo alone, so a red here would be a gate that
# only passes on a laptop with the fleet beside it (#686's constraint); --strict counts
# only TOOL-absent skips, and --require-siblings is what reds an absent sibling. The
# script names which repos it could not read so the skip line says what was not covered.
# Inside a git worktree $HERE/.. is .claude/worktrees/, so this skips there too; run the
# script with --fleet DIR to gate from a worktree.
#
# NOT SCOPE-GUARDED, for §9d's reason: PORTING-MATRIX.md is a `*.md` file, INERT to
# ci-classify.sh, so a push that hand-edits a table arrives as --scope none.
hdr "PORTING-MATRIX.md drift (gen-porting-matrix.sh --check)"
_gp_out="$("$HERE/scripts/gen-porting-matrix.sh" --check 2>&1)" && _gp_rc=0 || _gp_rc=$?
if ((_gp_rc == 0)); then
  pass "gen-porting-matrix (both generated tables in PORTING-MATRIX.md match the OS repos)"
elif ((_gp_rc == 1)); then
  fail "PORTING-MATRIX.md drift — a generated table no longer matches the OS repos; run: make gen-porting-matrix"
  fail_detail "$_gp_out"
elif ((_gp_rc == 3)); then
  _gp_missing="${_gp_out#*not checked out under }"
  skip_env "PORTING-MATRIX.md drift (${_gp_missing%% — *} — not covered by this run)"
  unset _gp_missing
else
  fail "gen-porting-matrix.sh --check could not run (exit $_gp_rc) — a cell has no package behind it, a repo installs an asserted one, a declaration is incomplete, or a marker is broken; the drift gate checked NOTHING this run"
  fail_detail "$_gp_out"
fi
unset _gp_out _gp_rc

# ── 9i. desktop-bar parity drift (PARITY.shared.md ↔ both desktop repos) ──────
# The Zebar ↔ sketchybar contract is authored once in desktop/PARITY.shared.md and
# rendered between markers into dotfiles-Windows/desktop/PARITY.md and
# dotfiles-MacBook/sketchybar/PARITY.md — the same generated-block answer §9d gives colour,
# §9g the alias tables and §9h the porting matrix.
#
# It replaces a SENTENCE. The two files were an admitted verbatim pair whose only mechanism
# was "Edit both together", and it did not hold: they drifted 3.5 KB apart — ~4.4 KB of it a
# one-sided Markdown reformat, 947 bytes a real Windows-only block never marked deliberate
# (#693). That block now lives OUTSIDE the markers, where the generator does not touch it.
#
# Exit shape is §9h's, for §9h's reason: 1 = drift or a malformed target in a repo that IS
# checked out; 3 = a repo is not checked out, an environment SKIP rather than a red, because
# the default CI job checks out this repo ALONE and both targets are OS-layer files
# outside any vendored core/ (dotfiles-MacBook DOES vendor Core; dotfiles-Windows vendors
# none). Anything else means
# the gate could not answer, which is a failure — a drift gate that checked nothing must
# never report green (#682).
#
# NOT SCOPE-GUARDED, for §9d's reason: the targets are `*.md`, INERT to ci-classify.sh, so a
# push that hand-edits a copy arrives as --scope none.
hdr "desktop-bar parity drift (gen-desktop-parity.sh --check)"
_dp_out="$("$HERE/scripts/gen-desktop-parity.sh" --check 2>&1)" && _dp_rc=0 || _dp_rc=$?
if ((_dp_rc == 0)); then
  pass "gen-desktop-parity (both desktop repos' PARITY.md match desktop/PARITY.shared.md)"
elif ((_dp_rc == 1)); then
  fail "desktop-bar parity drift — a copy no longer matches desktop/PARITY.shared.md; run: make gen-desktop-parity"
  fail_detail "$_dp_out"
elif ((_dp_rc == 3)); then
  _dp_missing="${_dp_out#*not checked out under }"
  skip_env "desktop-bar parity drift (${_dp_missing%% — *} — not covered by this run)"
  unset _dp_missing
else
  fail "gen-desktop-parity.sh --check could not run (exit $_dp_rc) — a usage error, or desktop/PARITY.shared.md itself is missing; a missing target or broken markers are exit 1, handled above. The drift gate checked NOTHING this run"
  fail_detail "$_dp_out"
fi
unset _dp_out _dp_rc

# ── 10. behavioral tests (load-order smoke + function unit tests) ─────────────
# Static analysis above proves the modules PARSE; this proves they LOAD TOGETHER
# in canonical order and that the pure functions behave. Delegated to test-core.sh
# (single source of truth) but folded into ONE audit summary via CORE_TEST_NESTED.
# Self-gates on zsh: with none installed it SKIPs, exactly like sections 3–5.
hdr "behavioral (scripts/test-core.sh)"
# Collect the suite launched in the background near the top (overlapping its slow legs
# with the static gates above). `wait` yields the child's exit code; we re-print its
# buffered output in place, then fold the result into ONE pass/fail line — identical to
# the old inline run, just time-shifted. CORE_AUDIT_SERIAL=1 takes the inline path below.
if ((BEHAV_BG)); then
  if wait "$BEHAV_PID"; then _behav_rc=0; else _behav_rc=$?; fi
  # In --json mode the behavioral output must not reach stdout (JSON-only); send it to
  # stderr so it's still there for debugging. Otherwise print it in place as before.
  if [[ -s "$BEHAV_OUT" ]]; then
    if ((JSON)); then cat "$BEHAV_OUT" >&2; else cat "$BEHAV_OUT"; fi
  fi
  # NAME WHAT BROKE, in the fail line itself. "run: ./scripts/test-core.sh" sends the operator
  # away to reproduce a result this run already has — and for an INTERMITTENT failure that is
  # advice that cannot be taken: the re-run passes and the evidence is gone. It has already
  # cost two occurrences of an unattributed flake here, both lost because the ✗ scrolled past
  # far above the summary and only the summary survived being piped through `tail`.
  #
  # Read BEFORE the buffer is removed. The rendering itself lives in common.sh so the suite can
  # test it on fixtures — see _core_fail_digest for why each of its branches is a quiet-failure
  # risk that hand-injecting a fault would not keep honest.
  _behav_digest="$(_core_fail_digest "$BEHAV_OUT")"
  rm -f "$BEHAV_OUT"
  if ((_behav_rc == 0)); then
    pass "behavioral tests (load-order smoke + function units)"
  elif [[ -n "$_behav_digest" ]]; then
    fail "behavioral tests failed ($_behav_digest) — run: ./scripts/test-core.sh"
  else
    # rc says failed and no ✗ was printed: the suite died before it could report (a crash, a
    # kill, a timeout). Say THAT rather than render an empty list, which would read as zero
    # failures beside a red line and send the reader hunting a mismatch that is not there.
    fail "behavioral tests failed — it exited $_behav_rc without printing a ✗, so it died before reporting; run: ./scripts/test-core.sh"
  fi
else
  # Serial fallback. `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `set -u`, expanding
  # an EMPTY array raises "unbound variable" on bash < 4.4 — i.e. macOS's stock bash 3.2,
  # which this gate must run on. The `+` form expands to nothing when unset/empty and to
  # the quoted elements otherwise, so the non-QUIET (empty TEST_ARGS) path doesn't abort.
  if CORE_TEST_NESTED=1 ./scripts/test-core.sh ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}; then
    pass "behavioral tests (load-order smoke + function units)"
  else
    fail "behavioral tests failed — run: ./scripts/test-core.sh"
  fi
fi

# Partition the skips up front so both the human summary and the --json object can report
# it. (Done before either render.) Three classes, not two:
#   tool         absent tool — a real coverage gap; --strict reds
#   out of scope the caller narrowed the run (--scope/--changed) — intentional
#   environment  a sibling OS repo isn't checked out — recorded STRUCTURALLY by skip_env,
#                not by wording, so the message can say what is true without moving a gate
# Environment skips are subtracted rather than string-matched: they are already counted in
# the non-"out of scope" tally above, and skip_env is the only thing that declares them.
# This keeps --strict's meaning EXACTLY as it was (absent tools only) while letting
# --require-siblings gate the third class on its own.
# The tool/scope/environment partition is decided by _core_tool_skip_count in
# scripts/lib/common.sh, NOT here. It was inline until the test meant to guard it turned out to
# re-implement the same loop in test-core.sh — so both stayed green while the defect they
# existed to catch was reintroduced in this file. Rendering stays here; the judgement is the
# helper's, and test-core.sh drives that helper directly. Same split as _core_luacheck_verdict.
#
# Assigned ONCE, straight from the helper. Do not post-process it: the original bug was exactly
# a second statement adjusting this number after the classification was already correct, and a
# static assertion in test-core.sh now fails if this stops being a single assignment.
_env_skips=${#_CORE_ENV_SKIPS[@]}
_tool_skips="$(_core_tool_skip_count)"

# ── machine-readable summary (--json): one object on stdout, then exit with the same
# status the human path would. Lets a CI step / editor parse the result instead of
# scraping coloured text. Strings are JSON-escaped (\ and ") via parameter expansion. ──
if ((JSON)); then
  if ((FAIL > 0)); then
    _result=failed
  elif ((STRICT && _tool_skips > 0)); then
    _result=failed-strict
  elif ((REQUIRE_SIBLINGS && _env_skips > 0)); then
    # New verdict, but only reachable via --require-siblings, which nothing passes today —
    # so it cannot move an existing consumer's result. `ok` deliberately keeps its meaning:
    # `partial` below is ADDITIVE rather than a new `ok-*` spelling, because the "--json
    # must not change the VERDICT" invariant compares this string against the plain run.
    _result=failed-siblings
  else _result=ok; fi
  printf '{"pass":%d,"skip":%d,"fail":%d,"seconds":%d,"strict":%s,"tool_skips":%d,"env_skips":%d,"partial":%s,"skipped":[' \
    "$PASS" "$SKIP" "$FAIL" "$SECONDS" "$( ((STRICT)) && echo true || echo false)" "$_tool_skips" "$_env_skips" \
    "$( ((SKIP > 0)) && echo true || echo false)"
  _first=1
  for _s in ${_CORE_SKIPS[@]+"${_CORE_SKIPS[@]}"}; do
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    ((_first)) || printf ','
    printf '"%s"' "$_s"
    _first=0
  done
  printf '],"result":"%s"}\n' "$_result"
  [[ "$_result" == ok ]] && exit 0 || exit 1
fi

# ── summary ──────────────────────────────────────────────────────────────────
printf '\n%s──────── audit summary ────────%s\n' "$c_blu" "$c_rst"
printf '  %spass %d%s   %sskip %d%s   %sfail %d%s   %s(%ds)%s\n' \
  "$c_grn" "$PASS" "$c_rst" "$c_yel" "$SKIP" "$c_rst" "$c_red" "$FAIL" "$c_rst" \
  "$c_blu" "$SECONDS" "$c_rst"
# Name the SKIPPED gates so a "green" run is honestly labelled PARTIAL: a check whose tool
# was absent did not actually run, and several of those (markdownlint, actionlint, gitleaks,
# luacheck, nvim) ARE enforced in CI — so a clean local box can still differ from the gate.
# This makes the gap explicit instead of hiding it behind a bare count. --strict turns it red.
# Partition the skips: a gate skipped because its TOOL is absent is a real coverage gap;
# one skipped because its AREA is out of scope (a narrowed --scope/--changed run) is
# intentional. --strict fails ONLY on the former, so it can run on a fully-provisioned CI
# leg (every in-scope tool installed) without tripping on deliberately-narrowed areas.
if ((SKIP > 0)); then
  printf '  %s%d check(s) SKIPPED — this run is PARTIAL, not full:%s\n' "$c_yel" "$SKIP" "$c_rst" >&2
  for _s in "${_CORE_SKIPS[@]}"; do
    printf '    %s–%s %s\n' "$c_yel" "$c_rst" "$_s" >&2
  done
fi
# Say what the fleet-wide gates need, and how to get it. These skip on ANY lone clone —
# including CI, which checks out only this repo — so without this line the reader has no
# way to learn that three gates have simply never run for them.
if ((_env_skips > 0)); then
  printf '  %s%d of those are FLEET-WIDE gates with no sibling repo to read — they did not run.%s\n' \
    "$c_yel" "$_env_skips" "$c_rst" >&2
  printf '  %sClone the OS repos beside this one (see scripts/os-repos.txt), or pass --require-siblings to make this red.%s\n' \
    "$c_yel" "$c_rst" >&2
fi
((FAIL == 0)) || {
  printf '%saudit FAILED%s\n' "$c_red" "$c_rst" >&2
  exit 1
}
if ((STRICT && _tool_skips > 0)); then
  printf '%saudit FAILED (--strict: %d gate(s) skipped because their tool is absent — must all run)%s\n' "$c_red" "$_tool_skips" "$c_rst" >&2
  exit 1
fi
if ((REQUIRE_SIBLINGS && _env_skips > 0)); then
  printf '%saudit FAILED (--require-siblings: %d fleet-wide gate(s) had no sibling OS repo to read)%s\n' "$c_red" "$_env_skips" "$c_rst" >&2
  exit 1
fi
# THE LAST LINE IS THE ONE PEOPLE READ. A bare "audit OK" after a run that skipped a third
# of the fleet-wide gates is the false green this whole script exists to prevent — the body
# said PARTIAL, but the verdict said OK, and the verdict is what gets quoted in a PR. Say it
# where it cannot be missed. Exit status is unchanged (0): partial is not failure, and
# --strict / --require-siblings remain the ways to make it one.
if ((SKIP > 0)); then
  printf '%saudit OK — PARTIAL (%d check(s) skipped; see above)%s\n' "$c_yel" "$SKIP" "$c_rst"
else
  printf '%saudit OK%s\n' "$c_grn" "$c_rst"
fi
