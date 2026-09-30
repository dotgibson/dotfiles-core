---
description: Go/no-go readiness check before cutting a Core release
argument-hint: "[target version X.Y.Z — optional]"
allowed-tools: Task, Read, Grep, Glob, Bash(./scripts/audit-core.sh:*), Bash(./scripts/fleet-drift.sh:*), Bash(./scripts/update-plugins.sh --check), Bash(./scripts/check-nvim-freshness.sh), Bash(git log:*), Bash(git tag:*), Bash(cat core.version), Bash(gh pr list:*), Bash(gh issue list:*), Bash(gh run list:*)
---

# /release-readiness

Answer ONE question: **is Core ready to cut a release right now, and if so, what version?**
This is the go/no-go gate that sits in front of `RELEASE-RUNBOOK.md` — it reports, it never
releases.

Target for this run: **$ARGUMENTS** (empty = infer the next version from the unreleased work).

## The readiness checklist (gather, then judge)

1. **Is there unreleased work worth shipping?** Read `CHANGELOG.md`'s `[Unreleased]` section
   and the Conventional Commits since the last release (`git log <last-release-tag>..HEAD`).
   If `[Unreleased]` is empty or only trivial, the verdict is "hold — nothing to ship yet."
2. **Is the tree green?** The one gate is `scripts/audit-core.sh`. A release cut off a red
   tree is never valid — note the audit status (the latest CI run on `main`, or `make audit`).
3. **Version coherence.** `core.version` vs the latest `vX.Y.Z` tag vs the `CHANGELOG.md`
   headings must line up (`release.sh` promotes `[Unreleased]` → a dated heading, opening a
   fresh one). Propose the next SemVer from the unreleased content: a breaking change → major,
   a `feat` → minor, only `fix`/`chore`/`docs` → patch.
4. **Is the fleet in a releasable state?** Run these **exactly as written**. The scheduled
   job grants each one as a literal string, so `scripts/…` without the `./`, an added flag,
   `make check-nvim`, or `gh release list` is refused, and the answer is lost. The 2026-09-30
   run (#1245) reported the editor pin as unverified that way, while the pin was current.
   - `./scripts/fleet-drift.sh` — are the OS repos on the latest Core?
   - `./scripts/update-plugins.sh --check` — the zsh plugin pins.
   - `./scripts/check-nvim-freshness.sh` — the vendored editor. It lists `dotfiles-nvim`'s
     release tags itself over `git ls-remote`, so no other tool is needed for this row.
     **Exit 0** with `✓ … is current` means current. **Exit 0** with `– … SKIPPED` means
     upstream was unreachable: report it as unverified, never as current. **Exit 2** means
     behind, and the output names the tag to move to. **Exit 1** means `nvim.lock` itself is
     broken, which is a blocker.

   A release fans out, so surface any drift or stale pins that ought
   to settle first — **advisory**, not hard blockers, with one thing worth calling out: the
   editor pin moves **at** a release and nowhere else (`NVIM-SPLIT-PROPOSAL.md` §7(3)), so a
   behind `nvim.lock` is a thing to DO in this release, not a reason to hold it. The bump is
   `scripts/sync-nvim.sh --ref vX.Y.Z`, with `nvim/` and `nvim.lock` in one commit.
5. **Do the fleet-wide gates pass against the siblings?** CI's audit checks out Core alone,
   so every gate that reads a sibling repo — §9m, §9n, §9o, §9p, the theme and desktop-parity
   drift — `skip_env`s there, and a PR can merge green while a sibling it now contradicts
   waits for the release. The first run that can see it is `sync-fanout`'s pre-fan-out audit,
   after the tag is cut: that is how #1210's corrected Kali matrix cells red the v7.14.0
   fan-out against dotfiles-Debian's stale `TOOLS_OPTIN` (#1239, #1240). So judge it HERE:
   `./scripts/audit-core.sh --quiet --scope none` with the fleet checked out **beside** Core
   (the gates read `$HERE/..`). The scheduled job has already run it and left the output at
   `../fleet-audit.txt` — read that rather than re-running; run it yourself only when the file
   is absent. **Any `✗` line is a HOLD**, and the fix usually lands in the named sibling, not
   in Core — cite the repo and the one declaration to change. An environment skip that names
   a sibling as *not checked out* (every one of them, from a Claude worktree or a lone clone)
   means the gate **did not run**: report it as unverified, never as a pass.
6. **Any open blockers?** Open `freshness-triage` **Hold** verdicts, a failing scheduled
   sweep, or a security bump that should ride the release.

## How to report

A one-line **verdict** up top — **READY to cut vX.Y.Z** or **HOLD** — then:

- **What would ship** — the grouped highlights from `[Unreleased]` (the release's story).
- **Proposed version + why** — the SemVer bump the unreleased content implies.
- **Blockers / pre-flight** — anything that must be true first (red audit, a red fleet-wide
  gate against the siblings, fleet drift, a Hold PR), each with the one command that clears
  it, in `RELEASE-RUNBOOK.md` order.
- **Next command** — literally `make release VERSION=X.Y.Z` when READY, or the specific
  blocker to clear when HOLD.

Report only — do **not** run `release.sh` / `tag-release.sh` or edit `core.version` /
`CHANGELOG.md`. The maintainer drives `RELEASE-RUNBOOK.md` from here.
