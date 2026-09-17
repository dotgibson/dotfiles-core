---
description: Interpret fleet-drift into ranked, per-repo remediation (report-first)
argument-hint: "[repo, optional — defaults to the whole fleet]"
allowed-tools: Read, Grep, Glob, WebSearch, Bash(./scripts/fleet-drift.sh:*), Bash(git log:*), Bash(git describe:*), Bash(git tag:*)
---

# /drift-triage

`fleet-drift.yml` reports **which** repos have drifted from the latest Core release,
but it doesn't judge *how far behind* or *what to do*. Answer that: for each repo,
how far off it is, what it's missing, and the exact remediation — **ranked** so the
most-stale / highest-risk repo is first.

The sweep has **three** states, and they take different remediations. Read the row,
don't assume red:

| Row | Meaning | Remediation |
| --- | --- | --- |
| `✓ current` | nothing owed. Either pinned exactly to the reference tag, or — for `✓ current (nvim up to date)` on Windows — a `nvim/` subtree already byte-identical to the release's, whatever its marker reads | none |
| `• current (ahead of vX.Y.Z …, on origin/main)` | carries **unreleased** Core — newer than the tag, still on main's lineage. **Not drift**; does not fail the sweep on its own | **cut a release** (see below) |
| `✗ BEHIND` / `DIFFERS` / `OFF-LINEAGE` / `DIVERGED` / `missing …` | genuine drift; forces exit **1** | `make sync`, or investigate the recorded sha |

The states **mix**. A sweep can be stale in one repo and unpinned in seven: the `•`
rows and the unreleased tally still print on a red run, and the exit code is 1
because of the `✗` rows. Read the exit code from the run itself, not from which row
types you can see.

A `•` row carries **two** numbers, and they mean different things:

- **`ahead of vX.Y.Z by N`** — a **release** is owed. `make sync` alone cannot fix
  this: it re-vendors the same lineage and stamps another `git describe` string, so
  the tag stays missing.
- **`N behind its tip`** — the fleet has not been re-synced since Core moved on, so
  a **sync** is owed as well. No such clause means the row sits exactly on main's
  tip and only the release is outstanding.

When both appear, the order is release **then** sync (`RELEASE-RUNBOOK.md`): syncing
first just re-stamps another untagged `describe` string, while the post-release sync
closes the unvendored commits *and* re-pins `core_tag` to a clean `vX.Y.Z`.

Scope for this run: **$ARGUMENTS** (empty = whole fleet).

## Baseline first — interpret, don't just echo

`fleet-drift.yml` already computes the drift rows and files/updates the standing
`"ci-failure: fleet-drift sweep is red"` issue; `core-integrity` gates each vendored
tree. Re-running the sweep here is fine — that's how you *gather* the current rows —
but the deliverable is the **interpretation** (how far behind, what's missing, what
to run), never a copy of the sweep's raw output.

**Run the sweep; never reconstruct it.** Do **not** re-derive the verdict by reading
`core.lock` markers and applying the classifier's logic yourself: that has already
produced a confident report that contradicted the script
(`dotgibson/dotfiles-core#381`).

**A non-zero exit is not a failure to run.** Read the exit code before deciding:

| Exit | Meaning | What to do |
| --- | --- | --- |
| `0` | no repo lags (may still carry `•` unreleased rows) | interpret the rows |
| `1` | **drift found — the sweep ran fine.** This is the case the routine exists for | **interpret the rows**; never treat it as a failed run |
| `2` | usage error (bad `--root`/`--ref`/`--color`) | the invocation is wrong — fix it and re-run |
| denied / not executed | the tool call never produced a sweep | say so plainly and **stop** |

Only the last two rows mean "no sweep". An **unrun** sweep is a finding to report,
not a gap to fill in by hand — but a **red** sweep is the deliverable's raw material,
so stopping on exit 1 would refuse exactly the job this routine was written to do.

## What to do

1. **Read the current state.** Run the sweep from this repo's root:

   ```bash
   ./scripts/fleet-drift.sh --color never
   ```

   The leading `./` is required — it's what the tool allowlist matches. No other flag
   is needed: `--root` defaults to this repo's *parent*, which is where the fleet is
   checked out (in CI too), and the baseline defaults to the latest released Core
   tag. Pass `--root DIR` only if the fleet lives somewhere else. `--add-dir` is a
   Claude Code flag, not a script flag — passing it to the script is a usage error.

   Also read this repo's `core.version` + latest `vX.Y.Z` tag.
2. **Compute the gap** per repo. For the ten Core-vendoring repos: `core.lock`'s
   `core_tag` / `core_sha` vs the latest tag → how many releases it skipped. For a
   `•` row, the gap that matters is the two numbers in the row itself: commits ahead
   of the tag (a release is owed) and `behind its tip` (a sync is owed).

   **dotfiles-Windows is not measured against Core at all** (#1124). It vendors no
   `core/`; its one vendored asset is the editor, and it takes that from
   `dotgibson/dotfiles-nvim` — the same repo Core vendors `nvim/` from. Its row is a
   **two-lock compare**: the `nvim_tag` in its own `nvim.lock` against the `nvim_tag`
   in Core's. So its RECORDED column shows an EDITOR release (`v1.0.0`), not a Core
   one, and subtracting it from the latest Core tag is a category error that
   manufactures a "N releases behind" that isn't real — the same false diagnosis
   `#381` reached by a different route. **Trust the row's verdict.**

   `current (ahead of nvim.lock: …)` is expected, not a finding: the Windows bot syncs
   weekly while Core adopts an editor release only with a Core release
   (`NVIM-SPLIT-PROPOSAL.md` §7(3)). `BEHIND (nvim …)` is the real signal — the weekly
   bot stopped. To quantify either, count editor releases, not Core ones:

   ```bash
   git -C <a dotfiles-nvim clone> tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=v:refname
   ```

3. **Weigh what it's missing:** read `CHANGELOG.md` across the skipped range. A
   security / hardening fix outranks a docs-only bump — rank by that, not just by
   count-behind.
4. **Give the exact remediation** per repo, matched to its state: `make sync` for a
   repo that genuinely **lags**; for Windows, `nvim-sync.ps1` (which re-pins `nvim.lock`
   from `dotfiles-nvim`) and/or `starship-sync.ps1`, matched to which row is red; a
   **release cut** for `•` unreleased rows, followed by `make sync` only if the row
   also reported `behind its tip` — in that order, per the table above. Flag any repo
   that would need manual conflict resolution.

## How to report

Ranked, most-stale / highest-risk first:

- **`<repo>` — N releases behind (vX.Y.Z → vA.B.C)** · what it's missing (1 line) ·
  the remediation command.
- **Unreleased** — the `•` rows: how far ahead of the tag, whether they're also
  behind main's tip, and that the fix is a release cut. Say plainly that these are
  **not** drift — but do **not** infer the exit code from them. A `•` row does not
  fail the sweep *on its own*; it coexists with `✗` rows in a mixed run, which exits
  **1** and still prints the unreleased tally. Report the exit code you actually
  observed, never one deduced from the row types.
- **Current** — the repos with nothing owed, so a green run is trustworthy. Report
  Windows from its verdict, not by comparing its tag to a Core release: the tag in
  that row is an EDITOR version, and `current (nvim vX.Y.Z, in step with nvim.lock)`
  means done. `current (ahead of nvim.lock: …)` is also done — see step 2.

If the sweep exited 0 with no `•` rows, say so in one line — a fully-pinned fleet is
the whole point, and a routine that manufactures concern from a green run is worse
than one that says nothing.

Report-first — this routine *proposes* the sync or the release; it does not run
either. Do not edit anything unless I explicitly ask.
