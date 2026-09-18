# scripts/audit/70-generated-drift.sh
# seven generated artifacts still match their source: theme blocks, the changelog digest, cross-shell parity, aliases.md, PORTING-MATRIX.md, the desktop PARITY pair, the vendored nvim tree
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
elif ((_gt_rc == 3)); then
  # A REGISTERED SIBLING IS NOT CHECKED OUT (#857). gen-theme.sh reaches into
  # dotfiles-MacBook's sketchybar palette, so a Core-only clone — every CI leg — cannot
  # inspect it. Recorded the way §9h and §9i record theirs, and for their reason:
  # skip_env, not a bare skip, so the class is carried by INDEX and --strict reads it as
  # "clone the sibling" rather than "install a tool". A bare skip would fail --strict on a
  # fully-provisioned box purely for being honest about what it could not reach.
  #
  # 3 is only returned when nothing else went wrong, so real drift still reports above.
  #
  # The names come from every `SKIPPED —` line, not a `${_gt_out#*not checked out: }` strip:
  # since #933 a sibling that IS checked out but lacks its registered file reports on a
  # second line with different wording, and a strip anchored on the first line's phrase
  # would have labelled that skip with the generator's whole output.
  _gt_missing="$(printf '%s\n' "$_gt_out" | sed -n 's/^gen-theme: SKIPPED — [^:]*: \(.*\) (.*$/\1/p' | tr '\n' ' ' | sed 's/ *$//')"
  skip_env "theme drift (${_gt_missing:-a registered sibling} — not covered by this run)"
  unset _gt_missing
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

# ── 9h. PORTING-MATRIX.md drift (the sources ↔ every generated block) ────────
# PORTING-MATRIX.md's generated blocks are registered in scripts/gen-porting-matrix.sh's
# BLOCK_IDS — READ IT rather than assuming a count, which is why no number appears here
# (#1082 added two and every count in this file was a lie for an afternoon). Two of them are
# the package-manager and package-name tables, rendered from the sibling OS repos'
# os/*.capabilities and install/packages.txt (#686) — the same answer §9d gives colour and
# §9g gives the alias cheat sheet. The rest are fleet-version enumerations, one per tool,
# rendered from scripts/fleet-package-versions.tsv in THIS repo. The ~1,230 hand-written
# lines of footnotes around them are untouched, with one exception worth knowing: those
# fleet-version blocks sit INSIDE footnotes (5, 33, 34), so each of those footnotes is
# authored prose around generated facts.
#
# THE GATE IS THREE FACTS, one more than §9g. --check exits 1 on drift (a repo renamed a
# package, bumped a `# min:` floor or changed a verb without regenerating; or a table was
# edited by hand). It exits 2 when it cannot answer — a derived cell no packages.txt line
# matches, an asserted cell the repo now installs, a declaration missing a key, a broken
# marker. And it exits 3 when a required sibling is NOT CHECKED OUT, which is the case
# §9g can never be in: its inputs are this repo's own files, these are another clone's.
#
# 3 IS A SCOPED ENVIRONMENT SKIP, not a failure and no longer the whole section — the
# posture §9c, §5f and fleet-drift.sh take for the same input. CI checks out this repo
# alone, so a red on the fleet-fed tables would be a gate that only passes on a laptop
# with the fleet beside it (#686's constraint); --strict counts only TOOL-absent skips,
# and --require-siblings is what reds an absent sibling. The script names which repos it
# could not read so the skip line says what was not covered. Inside a git worktree
# $HERE/.. is .claude/worktrees/, so the fleet half skips there too; pass --fleet DIR to
# gate it from a worktree.
#
# WHAT #1046 FOUND, and why there is a second call below. The fleet-version blocks' only
# input is in this repo and is therefore present on EVERY leg — but the whole of --check used to
# sit behind the fleet resolve, so this section skipped as a unit and reported "not
# covered" over an input it was holding. A hand-edit to that table was invisible to
# default CI. --check --local compares exactly the in-repo blocks, resolves no fleet and
# CANNOT return 3, so the arm below classifies on a number that call produced itself
# rather than on what the 3 implies.
#
# NOT SCOPE-GUARDED, for §9d's reason: PORTING-MATRIX.md is a `*.md` file, INERT to
# ci-classify.sh, so a push that hand-edits a table arrives as --scope none.
hdr "PORTING-MATRIX.md drift (gen-porting-matrix.sh --check)"
_gp_out="$("$HERE/scripts/gen-porting-matrix.sh" --check 2>&1)" && _gp_rc=0 || _gp_rc=$?
if ((_gp_rc == 0)); then
  pass "gen-porting-matrix (every generated block in PORTING-MATRIX.md matches its source)"
elif ((_gp_rc == 1)); then
  fail "PORTING-MATRIX.md drift — a generated block no longer matches its source; run: make gen-porting-matrix"
  fail_detail "$_gp_out"
elif ((_gp_rc == 3)); then
  # The fleet is absent — but only `commands` and `packages` needed it. Gate the in-repo
  # blocks here rather than filing them under the same skip.
  _gp_missing="${_gp_out#*not checked out under }"
  _gp_loc_out="$("$HERE/scripts/gen-porting-matrix.sh" --check --local 2>&1)" && _gp_loc_rc=0 || _gp_loc_rc=$?
  if ((_gp_loc_rc == 0)); then
    pass "gen-porting-matrix (the in-repo blocks — the fleet-version enumerations — match scripts/fleet-package-versions.tsv)"
  elif ((_gp_loc_rc == 1)); then
    fail "PORTING-MATRIX.md drift — a fleet-version block no longer matches scripts/fleet-package-versions.tsv; run: scripts/gen-porting-matrix.sh --local (no sibling clone needed)"
    fail_detail "$_gp_loc_out"
  else
    fail "gen-porting-matrix.sh --check --local could not run (exit $_gp_loc_rc) — the in-repo half of the drift gate checked NOTHING this run"
    fail_detail "$_gp_loc_out"
  fi
  # SCOPED: the label names which blocks were not covered, rather than implying the whole
  # section went unchecked. Still skip_env, so --require-siblings can still red it.
  skip_env "PORTING-MATRIX.md drift: the commands + packages tables (${_gp_missing%% — *} — not covered by this run)"
  unset _gp_missing _gp_loc_out _gp_loc_rc
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

# ── 9q. the vendored nvim tree matches its pin (nvim/ ↔ nvim.lock) ───────────
# Since #1123 Core does not AUTHOR the editor: nvim/ is a vendored copy of
# dotgibson/dotfiles-nvim, pinned by nvim.lock. That makes it generated payload in exactly
# CHANGELOG.recent.md's sense — present, tracked, and not hand-edited — so it needs §9e's
# kind of proof, and for §9e's reason: §1 proves only that the PATH exists (core.manifest
# lists `nvim/` as a directory, so any tree at all satisfies it), §1e never walks it, and
# §4 checks that the lua is CLEAN, not that it is the lua upstream shipped. A hand-edit here
# passes every one of them. (§4b used to add REACHABLE to that list; it retired with the
# editor's tests in #1125, and the walk runs in dotfiles-nvim's own audit now — which is
# only load-bearing BECAUSE this section proves the tree is the one upstream walked.)
#
# WHY A RECORDED HASH AND NOT A DERIVED ONE. core-integrity.sh answers the same question
# for an OS repo's core/ by resolving the pinned commit to a tree — which it can, because
# the consumer fetched that commit and holds the objects. Core holds NO dotfiles-nvim
# objects, so deriving the expectation here would mean a network fetch, and a gate that
# self-skips offline is green-because-absent in precisely the clone where a corrupt sync
# landed. nvim.lock records nvim_tree instead, so this is a two-file comparison: the same
# tree-hash integrity model, not a second one (NVIM-SPLIT-PROPOSAL.md §5), made ALWAYS-ON.
#
# READ FROM THE COMMIT, NOT THE WORKTREE — core-vendor.sh's rule. `HEAD:nvim` is what a
# sync produced and what the fleet will vendor; an untracked scratch file under nvim/ is
# not part of it and must not red this gate (§1's reverse-drift scan is what catches those).
#
# NOT SCOPE-GUARDED, for §9d's reason: it reads two files, and a narrowed run must never be
# able to skip a contract check. A missing or malformed nvim.lock is a FAIL, not a skip —
# the file is tracked, so its absence is real drift, and the whole point of the lock is
# that the tree cannot be trusted without it.
hdr "vendored nvim tree (nvim/ ↔ nvim.lock)"
_nv_lock="nvim.lock"
if [[ ! -r "$_nv_lock" ]]; then
  fail "$_nv_lock missing or unreadable — nvim/ is a vendored copy of dotgibson/dotfiles-nvim and nothing else records which revision it is. Run: make sync-nvim"
else
  _nv_want="$(sed -n 's/^[[:space:]]*nvim_tree[[:space:]]*=[[:space:]]*//p' "$_nv_lock" 2>/dev/null | head -n1)"
  _nv_have="$(git rev-parse --verify --quiet 'HEAD:nvim' 2>/dev/null || echo '')"
  if [[ -z "$_nv_want" ]]; then
    fail "$_nv_lock has no nvim_tree — the pin cannot be verified offline, which is the one thing it exists to do. Run: make sync-nvim"
  elif [[ ! "$_nv_want" =~ ^[0-9a-f]{40}$ ]]; then
    fail "$_nv_lock has an invalid nvim_tree ($_nv_want) — expected a 40-char hex tree object"
  elif [[ -z "$_nv_have" ]]; then
    # No HEAD:nvim at all. In a normal checkout that is a deleted tree; in a fresh repo with
    # no commits it is simply unanswerable. Distinguish them, because the second is not drift.
    if git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
      fail "nvim/ is not present at HEAD but $_nv_lock pins tree ${_nv_want:0:12} — the vendored editor is gone. Run: make sync-nvim"
    else
      skip "vendored nvim tree (no commits yet — nothing to compare)"
    fi
  elif [[ "$_nv_have" == "$_nv_want" ]]; then
    pass "nvim/ matches nvim.lock (tree ${_nv_want:0:12}, $(sed -n 's/^[[:space:]]*nvim_tag[[:space:]]*=[[:space:]]*//p' "$_nv_lock" | head -n1))"
  else
    # NAME THE FIX IN THE FAIL LINE (§9e's rule): the operator has the answer here, not
    # after a round trip. The two likely causes read very differently, so say both.
    fail "nvim/ does NOT match $_nv_lock — the vendored editor was hand-edited, or the lock was not committed with the tree. Edit upstream in dotgibson/dotfiles-nvim, then run: make sync-nvim"
    fail_detail "  nvim.lock nvim_tree: $_nv_want
  HEAD:nvim          : $_nv_have"
  fi
  unset _nv_want _nv_have
fi
unset _nv_lock
