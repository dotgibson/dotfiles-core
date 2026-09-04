#!/usr/bin/env bash
# scripts/ci-classify.sh — map a set of changed paths to which CI gates must run.
# ──────────────────────────────────────────────────────────────────────────────
# ci.yml's change-detection decides, per push, whether the shell matrix / nvim
# steps / Alpine + bench legs run. That logic used to be inline bash INSIDE the
# workflow YAML: untested, unlinted, and drift-prone — a NEW top-level path not
# added to its glob lists would silently skip a gate, and a skipped gate fans out
# to all nine OS repos undetected. Pulling it here makes it shellcheck-clean, unit-
# tested (scripts/test-core.sh asserts the mapping), and FAIL-CLOSED.
#
# Reads changed paths on stdin, one per line (or the single token `__ALL__` when the
# diff base couldn't be resolved). Writes three KEY=value lines to stdout:
#     shell=<true|false>
#     nvim=<true|false>
#     atuin=<true|false>
# so the caller can append them straight to $GITHUB_OUTPUT.
#
# Buckets (first match per file wins):
#   • atuin-infra  scripts/research/ scripts/lib/ scripts/test/ scripts/test-core.sh
#                  scripts/ci-classify.sh — the four paths the detector's self-test
#                  actually reaches, plus this file → the FULL run
#   • infra      the REST of scripts/, .github/ .claude/ core.manifest core.version
#                .pre-commit-config.yaml .shellcheckrc Makefile — cross-cutting for the
#                shipped modules, so shell AND nvim, but NOT atuin
#   • atuin      zsh/00-tools.zsh + atuin/**      → shell AND atuin
#   • nvim       nvim/**                         → nvim
#   • shell      zsh/ bin/ maint/ tmux/ sesh/ starship/ mise/ git/ tealdeer/ theme/ **/*.sh → shell
#                (theme/ is the palette gen-theme.sh renders into zsh+tmux+starship+lazygit;
#                 NOT nvim — nvim's colours come from the tokyonight plugin, which is that
#                 script's SOURCE, not one of its outputs)
#   • inert      *.md + repo-meta dotfiles + examples/ (nothing links it) → no gate
#   • anything else → FAIL CLOSED: force the full run and log it. Getting the inert
#     list wrong only costs a wasted full run (safe); the old code's failure mode was
#     a SKIPPED gate (unsafe) — this inverts that, matching ci.yml's "safe default".
#
# WHY atuin IS ITS OWN AXIS. The `atuin` gate is the hermetic self-test of
# scripts/research/verify-atuin-guard.sh — 197s of a 286s behavioral suite, 68% of it, and the
# single largest cost on the CI critical path. It exercises the premise DETECTOR against
# stub binaries; the detector's real job, measuring live upstream atuin, runs on manual
# dispatch of .github/workflows/atuin-guard-verify.yml (#687) and not on pushes at all.
#
# AND THE AXIS IS NARROW ON BOTH SIDES NOW. `scripts/*` used to force it wholesale, on the
# reasoning that the detector lives under scripts/ and infra is cross-cutting. True of the
# detector; false of the other forty scripts beside it. Every one of the last seven merges
# to main touched scripts/, so every one paid the full 197s on all four legs for a harness
# the change could not reach — the leftover #699 named and did not fix.
#
# What can move the self-test's result is a checkable question, not a judgement call,
# BECAUSE THE TEST IS HERMETIC: it stubs `atuin` and doctors a SANDBOX copy of
# zsh/00-tools.zsh, so the real tree is not an input. Its reachable set is therefore exactly
# what the fragments source — scripts/research/ (the script under test and its lib),
# scripts/lib/ (common.sh), scripts/test/ + test-core.sh (the harness) — plus this file,
# which decides the scope. scripts/test/22-ci-classify.sh DERIVES that set from the
# fragments and reds if this arm stops covering it.
#
# gen-theme.sh is the case that makes the distinction real rather than pedantic: it writes a
# generated block INTO zsh/00-tools.zsh (gen-theme.sh:210), the module carrying
# _core_atuin_daemon_guard. It reaches the guard and still cannot reach the guard's TEST, so
# it forces shell and nvim and not atuin.
#
# The other half of the axis is unchanged: zsh/00-tools.zsh and atuin/ still force it, and a
# change to zsh/10-ui.zsh still does not.
#
# Note the ORDER below: zsh/00-tools.zsh must be matched BEFORE the general `zsh/*` arm,
# because first match per file wins.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

shell=false
nvim=false
atuin=false
full() {
  shell=true
  nvim=true
  atuin=true
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" == "__ALL__" ]]; then
    full
    break
  fi
  case "$f" in
  # ── infra that can reach the atuin harness → the FULL run, atuin included ────
  # The hermetic detector self-test reads exactly four things out of this tree, and this arm
  # is those four plus the classifier that decides scope at all. scripts/test/22-ci-classify.sh
  # DERIVES that list from the fragments themselves and fails if this arm stops covering it,
  # so it is a checked claim rather than a hand-kept exception list of the sort #5c deleted.
  scripts/research/* | scripts/lib/* | scripts/test/* | scripts/test-core.sh | scripts/ci-classify.sh) full ;;
  # ── the rest of infra → cross-cutting for shell and nvim, but NOT atuin ──────
  # Everything else under scripts/ (the generators, the release and fan-out apparatus, the
  # audit itself), plus .github/, .claude/ and the repo-meta config, is genuinely
  # cross-cutting — it can rewrite or re-gate any shipped module, so shell and nvim stay
  # forced. It cannot move the atuin verdict, and that is a property of the TEST, not a
  # guess about the script: the atuin fragments stub `atuin` and doctor a SANDBOX copy of
  # zsh/00-tools.zsh, so nothing they assert depends on the real tree. gen-theme.sh is the
  # sharp case and the reason this needed checking — it writes a generated block INTO
  # zsh/00-tools.zsh (scripts/gen-theme.sh:210), which is why it forces shell; the atuin
  # self-test still cannot see that file.
  #
  # This is the #699 leftover. Every one of the last seven merges to main touched scripts/,
  # so every one paid ~197s of atuin harness on all four legs — 68% of the behavioral suite
  # — for a gate the change could not reach. #687 archived that apparatus as on-demand
  # research; this stops its TEST from sitting on the push path of unrelated work.
  scripts/* | .github/* | .claude/* | core.manifest | core.version | .pre-commit-config.yaml | .shellcheckrc | Makefile)
    shell=true
    nvim=true
    ;;
  nvim/*) nvim=true ;;
  # The guard's own module and the atuin config tree — the only non-infra paths that can
  # change what the premise detector's self-test observes. Matched BEFORE the general
  # `zsh/*` arm below, which would otherwise swallow 00-tools.zsh as plain shell.
  zsh/00-tools.zsh | atuin/*)
    shell=true
    atuin=true
    ;;
  zsh/* | bin/* | maint/* | tmux/* | sesh/* | starship/* | mise/* | git/* | tealdeer/* | theme/* | *.sh) shell=true ;;
  # examples/ is repo-meta: bootstrap links NOTHING from it (see examples/README.md), so a
  # change there gates nothing — it would otherwise hit the fail-closed arm and force a full
  # run with an "unrecognised path" line, which reads like a bug rather than a showcase edit.
  *.md | examples/* | LICENSE | CODEOWNERS | .gitignore | .gitattributes | .editorconfig | .markdownlint.jsonc | .prettierrc.json) ;;
  *)
    printf "ci-classify: unrecognised path '%s' → forcing full run (add it to a bucket)\n" "$f" >&2
    full
    ;;
  esac
done

printf 'shell=%s\nnvim=%s\natuin=%s\n' "$shell" "$nvim" "$atuin"
