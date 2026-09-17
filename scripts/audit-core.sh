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
# THIS FILE IS THE DISPATCHER; the gates live in scripts/audit/NN-name.sh. Each fragment
# is SOURCED into this shell in NN order, so the run is the single stream it has always
# been: one set of PASS/SKIP/FAIL counters, one summary, one exit code, one EXIT trap. The
# CLI is unchanged, and so is every gate the audit already had: the split moved them, it
# did not rewrite or prune them (a failure in one section still does not abort the others).
# The one addition is scripts/audit/05-shape.sh, which gates the layout this file now
# depends on — and gates section-id uniqueness, which one file never could.
#
# WHY IT IS SPLIT. This was one 3,064-line file with 52 sections, and it had reproduced
# exactly the condition that split scripts/test-core.sh in #699: shellcheck's cost grows
# superlinearly with file length, so this one file cost ~2.5s of CPU on every CI leg for
# any PR touching any shell file; the letters had drifted (1b ran fifth, 5k between 5e and
# 5f, 9c before 9b), two unrelated gates wore `1c`, and the index that used to sit here
# named 23 of the 48. Names fix the ordering by construction, and the shape gate fixes the
# duplicate by assertion.
#
# THE §-IDS ARE STABLE. Fragments keep their `# ── 5f. title ──` banners and hdr text —
# CLAUDE.md, CONTRIBUTING.md, VENDORING.md, PORTABILITY.md, lint-call.yml, common.sh and
# the CHANGELOG all cite gates by id, and core.vendor's comments are vendored to nine
# repos — so `§5c` is still `§5c` wherever you read it. The NN- prefix carries RUN ORDER
# only; the letters are addition order within a family and were never meant to sort.
# Cite a gate by its id, never by a line number in this file.
#
# ADDING A SECTION = adding scripts/audit/NN-name.sh. The glob below picks it up; there is
# no registry to forget and therefore no way to add a gate that never runs. NN is a sort
# key only, and the gaps in it are room to insert. Fragments are sourced libraries: mode
# 100644 (§2 asserts it), no shebang, and NO `trap … EXIT` — the one installed below reaps
# the backgrounded behavioral suite, and a second would replace it.
#
# SHARED STATE a fragment may assume: everything this file defines above the loop — the
# flags, $HERE (cd'd to), the SCOPE_* flags, META_ALLOWLIST/META_PREFIXES, the helpers
# common.sh defines — plus what an EARLIER fragment defined: MANIFEST_PATHS/VENDOR_PATHS
# (10-manifest.sh, read by §5c in 30-boundary.sh), VERSIONS_ENV and CAP_CHECK (both within
# 65-versions.sh). Two variable names are shared across fragments by prior accident and
# survive only because each site unsets or overwrites cleanly: `_fc_out` (§5h and §9m)
# and the `_gp_*` prefix (§5g and §9h). Namespace new locals with a fragment prefix.
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
# Derived by _set_scope from the three above; initialised here for the no---scope
# default (everything runs) and so `set -u` has it before any fragment reads it.
SCOPE_TOOLING=1
# Shared palette + pass/skip/fail/hdr/have + _set_scope (one definition for every gate
# script). Sourced HERE — before the arg loop below calls _set_scope — and after QUIET
# is set so the lib's `: "${QUIET:=0}"` preserves it.
#
# Via the ALREADY-ABSOLUTE $HERE, not ${BASH_SOURCE[0]%/*}: the `cd "$HERE"` above has run,
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
                  The behavioral suite's cross-cutting bash-tooling sections run for
                  ANY area and are skipped only by `none`.
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

The sections live in scripts/audit/NN-name.sh and are sourced in NN order; this script
is the dispatcher. Adding a section is adding a file there.
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
# Read by scripts/audit/10-manifest.sh (§1's is_listed and §1d), which this file sources
# into its own shell below; shellcheck's file scope cannot see the run's shell scope.
# shellcheck disable=SC2034
META_ALLOWLIST=(
  README.md CONTRIBUTING.md CHANGELOG.md LICENSE SECURITY.md aliases.md CLAUDE.md
  ARCHITECTURE.md PORTABILITY.md VENDORING.md CODE_OF_CONDUCT.md
  PARITY.md RELEASE-STRATEGY.md RELEASE-RUNBOOK.md GITHUB-APP-AUTH.md GITHUB-APP-MIGRATION.md V5-PROPOSAL.md V8-PROPOSAL.md NON-MUTABLE-HOST-PROPOSAL.md NVIM-SPLIT-PROPOSAL.md
  .gitignore .gitattributes .editorconfig .pre-commit-config.yaml .markdownlint.jsonc .shellcheckrc renovate.json .prettierrc.json
  Makefile cliff.toml
  nvim/.luacheckrc
  CODEOWNERS pull_request_template.md
  # nvim.lock — the INBOUND vendoring pin (#1123). It records which dotgibson/dotfiles-nvim
  # revision nvim/ is a copy of, and §9q compares its nvim_tree against the committed tree.
  #
  # NOT core.manifest: nothing symlinks it into $HOME, and the tree it describes already has
  # the manifest's one `nvim/` entry. NOT core.vendor either, which is the question worth
  # answering out loud, because core.lock's mirror image is so nearly the same shape. An OS
  # repo's core.lock says "here is the Core you carry" and lives in the CONSUMER; this says
  # "here is the editor I carry" and lives in the PRODUCER of that same tree. No OS repo
  # Makefile, bootstrap or CI reads it — they get the editor through core/nvim like any
  # other Core path, and core.lock already pins the Core commit that fixes which nvim that
  # is. Vendoring it would ship a provenance file about a repo the consumer does not talk to.
  nvim.lock
  # theme/palette.toml is a generation-time INPUT to scripts/gen-theme.sh (already covered
  # by the scripts/ prefix below), not shipped Core: nothing symlinks it and no OS repo
  # reads it out of core/. Its OUTPUTS ship — the generated blocks in zsh/, tmux/,
  # starship/, lazygit/ and lib/ux.sh — which is exactly the core.manifest-vs-core.vendor
  # distinction those two files draw. Listed as an EXACT path, not a theme/ prefix, so a
  # second file dropped into that directory has to be accounted for deliberately.
  #
  # IT NOW HAS A CONSUMER, and the line above is still the right home for it (#798).
  # dotfiles-Windows vendors this FILE — theme-sync.ps1 copies it to its own theme/
  # alongside a theme/.core-ref pinning the Core commit, CI hash-gates the pair, and its
  # gen-theme.ps1 renders nine blocks from it (dotgibson/dotfiles-Windows#229). So "no OS
  # repo reads it out of core/" is still literally true and is no longer the whole story:
  # that repo vendors no core/ AT ALL and reads this path out of THIS repo directly.
  #
  # WHY NOT A core.manifest ROW, which is what #798 asked about. The manifest is the set
  # sync-core.sh materializes into each OS repo's core/. Adding this would ship a
  # generation-time input into nine trees where nothing reads it, to describe a dependency
  # held by the one repo that has no core/ — the manifest would become less true, not more.
  # The dependency is recorded where it can be acted on instead: in this comment and in the
  # file's own header, both of which say that moving the path breaks a downstream CI gate.
  # desktop/PARITY.shared.md below is the same shape and the precedent for it.
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
# Read by scripts/audit/10-manifest.sh, as above. `scripts/` being here is also why the
# fragments needed no allowlist edit of their own.
# shellcheck disable=SC2034
META_PREFIXES=(examples/ .github/ scripts/ .claude/ .devcontainer/ assets/)

# ── the gates: scripts/audit/NN-name.sh, sourced in NN order ──────────────────
# GLOB + SORT, not a hand-maintained list — the same reason zsh/loader.zsh globs its
# numbered fragments and scripts/test-core.sh globs its suite. A registry is a second
# place to edit, and the copy you forget is the one that silently drops a gate from an
# `audit OK`; the index that used to sit in this file's header had done exactly that.
#
# SOURCED, not executed: every fragment runs in THIS shell and shares its state — the
# PASS/SKIP/FAIL counters, $HERE, the SCOPE_* flags, META_ALLOWLIST/META_PREFIXES, the
# helpers common.sh defined above, and whatever an earlier fragment parsed (MANIFEST_PATHS
# from 10-manifest.sh). That is what makes the split a pure move: the stream of gates,
# their order, the summary and the exit code are what they were when this was one file.
# Section 10 below waits on the behavioral suite launched above; it stays here rather
# than in a fragment because it is the collect half of that launch and the EXIT trap
# that reaps it, and because "last" has to be structural, not a matter of NN.
#
# AN EMPTY GLOB IS A HARD FAILURE, not an empty run. An audit that quietly asserts nothing
# reports `audit OK`, and OK is what sync-core.sh, tag-release.sh and release.sh act on;
# this is the posture common.sh's load_os_repos takes on an unreadable fleet list, for
# the same reason. `nullglob` is not set here, so an unmatched pattern comes through
# literally and the -e test catches it. scripts/test/23-audit-shape.sh drives this arm.
_audit_frags=0
for _audit_frag in "$HERE"/scripts/audit/[0-9][0-9]-*.sh; do
  [[ -e "$_audit_frag" ]] || break
  # Deliberately NOT a `# shellcheck source=` directive: one directive cannot name sixteen
  # files, and following them would re-merge the audit into one 3,000-line unit for the
  # linter — which is the cost the split removed. Each fragment is a tracked *.sh and is
  # linted on its own by §5.
  # shellcheck source=/dev/null
  source "$_audit_frag"
  _audit_frags=$((_audit_frags + 1))
done
if ((_audit_frags == 0)); then
  printf 'audit-core.sh: no fragments matched %s/scripts/audit/[0-9][0-9]-*.sh\n' "$HERE" >&2
  printf 'audit-core.sh: refusing to report a clean run having asserted nothing\n' >&2
  exit 2
fi
unset _audit_frag _audit_frags

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
