# CLAUDE.md — dotfiles-core

Project memory for Claude Code. This file is auto-loaded every session, so it is
the shared context that keeps every routine (and every ad-hoc edit) reasoning
from the system's real rules instead of guessing. Keep it short and true; when a
rule here drifts from `README.md` / `CONTRIBUTING.md`, those win — fix this.

## What this repo is

`dotfiles-core` is the **single source of truth** for the Core layer of a
**eleven-repo dotfiles system** built on a three-layer model. Core is authored
**once here** and vendored into each OS repo's `core/` — so a
defect here fans out N-way. Treat every change as if it ships to all of them,
because it does.

| Layer         | Lives in                                                               | Examples                                                           |
| ------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **Core**      | **this repo**, vendored into each OS repo's `core/`                    | zsh modules, tmux, nvim, git, starship                             |
| **OS-native** | `dotfiles-{MacBook,Windows,Fedora,Arch,Debian,openSUSE,Alpine,Gentoo}` | package manager, clipboard, paths                                  |
| **Role**      | `dotfiles-Offense` (offensive), `dotfiles-Defense` (defensive)         | offensive engagement + defensive detection tooling on the OS layer |

Plus `dotfiles-web` — the public Astro showcase/docs site (the system's public
face, **not** a config layer). The canonical Core-vendoring fleet is
`scripts/os-repos.txt`; `dotfiles-Windows` is a machine repo but vendors no
`core/` (its host config is replicated from scratch in PowerShell, not ported).

## The rules that bite

- **Is it Core?** It belongs here **only** if it is identical on every machine
  **and** not OS-specific **and** not offensive. Changes with the OS → the OS
  repo. Changes with the operator → `dotfiles-Offense`. (See `CONTRIBUTING.md`.)
- **The manifest is the contract.** `core.manifest` is the canonical inventory.
  Adding a Core file means adding its path to `core.manifest` in the same change;
  `scripts/audit-core.sh` enforces this both directions. Repo-meta and dev tooling
  (docs, `.github/`, `.claude/`, `scripts/`, `theme/palette.toml`) live in the
  audit's allowlist instead.
- **Never edit vendored `core/` in an OS repo.** That tree is a copy of this repo
  and is overwritten on the next sync. Fix it **here**, then fan out.
- **Load order is load-bearing.** `tools → capabilities → ui → options → history →
  aliases → git → functions → fzf → bindings → plugins → op → maint → update → os →
  role → local`
  (bands: Core 00-69, OS-native 70-84, Role 85-94 on Offense/Defense, host-local 95-99)
  (the canonical order in `core.manifest`). Don't reorder casually.
- **Colour is generated, not typed.** `theme/palette.toml` is the only place a hex is
  authored. `zsh/`, `tmux/`, `starship/`, `lazygit/`, `lib/ux.sh` and `examples/` carry
  **generated** `# core:theme:gen` blocks — hand-editing one is a gate failure
  (`audit-core.sh` §9d). Edit the palette, run `make gen-theme`. Comments name palette
  tokens, never hexes, so prose cannot drift from the code it describes.
- **`aliases.md`'s tables are generated, not typed.** `scripts/gen-aliases.sh` renders
  them from `zsh/20-aliases.zsh`, `zsh/25-git.zsh` and `zsh/30-functions.zsh` into
  `<!-- core:aliases:gen … -->` blocks — hand-editing a table, or adding an alias without
  listing it in the script's `BLOCKS` registry, is a gate failure (`audit-core.sh` §9g).
  Edit the zsh source (a trailing `# comment` on an alias line is its Note column), run
  `make gen-aliases`. The prose around the tables stays hand-written.
- **`PORTING-MATRIX.md`'s two tables are generated, not typed.** `scripts/gen-porting-matrix.sh`
  renders the package-manager table from each sibling OS repo's `os/*.capabilities` and the
  package-name table from its `install/packages.txt` (Debian's through its `pkg-filter.sh`
  tiers, `# min:` floors shown as `≥`) into `<!-- core:porting-matrix:gen … -->` blocks —
  hand-editing a table is a gate failure (`audit-core.sh` §9h; an absent sibling clone is
  an environment SKIP, not red). A cell the repo installs is derived; the ²¹ "available, not
  installed" names and the `asset`/`cargo`/`AUR` routes are asserted in the script's
  `PKG_ROWS` registry, and a repo starting to install one fails the gate until the cell is
  flipped to `=`. Fix the OS repo (or the registry), run `make gen-porting-matrix` — from a
  worktree, `scripts/gen-porting-matrix.sh --fleet DIR`. The ~1,100 footnote lines stay
  hand-written; `/os-package-availability` refreshes them.
- **The desktop-bar `PARITY.md` pair is generated, not typed.** The Zebar ↔ sketchybar
  contract is authored once in `desktop/PARITY.shared.md` and rendered between the
  `<!-- desktop-parity:gen -->` and `<!-- desktop-parity:end -->` markers into
  `dotfiles-Windows/desktop/PARITY.md` and `dotfiles-MacBook/sketchybar/PARITY.md` by
  `scripts/gen-desktop-parity.sh` — hand-editing either copy inside the markers is a gate
  failure (`audit-core.sh` §9i, plus the weekly `parity-check.yml`; an absent sibling clone is
  an environment SKIP, not red). Edit the source, run `make gen-desktop-parity`. Anything a
  single host adds lives **outside** the markers, marked `deliberate` in the
  `aligned`/`deliberate`/`gap` vocabulary — that is where Windows' psmux battery-scale note
  sits. Keep the source a **prettier fixed-point** (`prettier --parser markdown`): Core's nvim
  formats markdown with prettierd, and a one-sided format is how the pair drifted 3.5 KB apart
  in the first place (#693).
- **Exec bits are asserted.** `bin/`, `scripts/`, `tmux/scripts/`, `maint/` runners
  are `+x`; the sourced `zsh/*.zsh` modules must stay non-executable.
- **A user-visible change lands in `CHANGELOG.md` under `[Unreleased]`** in the
  same commit, with a [Conventional Commits](https://www.conventionalcommits.org/)
  message (`type(scope): summary`).

## The one gate

`scripts/audit-core.sh` is the single definition of "Core is healthy" (manifest
drift, exec-bits, syntax, shellcheck, luacheck, markdownlint, behavioral suite).
CI, pre-commit, and `make audit` all call it. **Green it before you push** — a red
tree must never be vendored out.

```bash
make audit          # the full gate
make audit-changed  # only what your diff touches (fast loop)
make sync           # fan Core out to every OS repo (after a green audit)
```

The **behavioral suite** the gate delegates to is `scripts/test/NN-name.sh` — one numbered
fragment per subject — and `scripts/test-core.sh` is the dispatcher that globs them in `NN`
order and **sources** them into its own shell (one `$SANDBOX`, one set of counters, one
summary). Adding a section is adding a file; there is no registry to update. The `NN-` prefix
is load-bearing (the glob skips anything without it, and `scripts/test/05-suite-shape.sh`
fails the run if you leave one off), and the fragments are sourced libraries, so they are
`100644`, not `+x`. They were one 18,747-line file until #699, where its ShellCheck cost was
65% of the whole lint gate on every CI leg.

Run `make` with no target for the discoverable list of entry points.

To cut a release, follow `RELEASE-RUNBOOK.md` (exact commands for Core, the OS-repo
rollout, and htpx); `RELEASE-STRATEGY.md` is the policy behind it.

## Maintenance routines (`.claude/`)

On-demand routines that automate the judgment-heavy chores `audit-core.sh` can't:

- `/doc-audit` — cross-check prose against reality across the fleet (docs ↔
  manifest ↔ code ↔ each OS repo). Delegates to the `doc-consistency` subagent.
- `/tool-scout` — research the modern-CLI stack for newer/better tools and major
  features worth adopting. Delegates to the `tool-scout` subagent.
- `/freshness-triage` — review open dependency-bump PRs (zsh plugins, nvim lock,
  actions) against upstream changelogs and flag breaking changes.
- `/runtime-freshness` — decide whether the **pinned** language runtimes in
  `mise/config.toml` (python/ruby/java/lua) are due to cross a pin, weighing EOL
  calendars and tooling compatibility against the maint job's `mise outdated --bump`
  nudge. Report-first.
- `/modernize` — scout the next CI modernization floor (newly-EOL runners, deprecated
  action runtimes, new hardening dimensions) and propose bumps to `modern-baseline.yml`.
- `/release-readiness` — go/no-go before a Core release: unreleased work, audit status,
  version coherence, fleet drift → a READY-to-cut-vX.Y.Z / HOLD verdict.
- `/release-notes` — draft the next release's notes from Conventional Commits (git-cliff, or
  the first-party `gen-release-notes.sh`) for curation into `CHANGELOG.md`.
- `/shell-review` — read the week's changed `zsh`/`bash` for runtime footguns lint can't catch
  (tmux/terminal-state, docs-vs-reality overclaims, quoting, `set -e`/subshell/`exec` traps,
  idempotency, startup-cost regressions).
- `/drift-triage` — interpret `fleet-drift`'s red rows into ranked, per-repo remediation (how
  many releases behind, what's missing, the exact `make sync` / `nvim-sync.ps1` to run).
- `/os-package-availability` — audit an OS repo's package list for renamed/dropped/moved
  packages vs upstream + `PORTING-MATRIX.md`. Shipped as the reusable
  `.github/workflows/claude-routines-call.yml`, which each OS repo consumes as a 3–5 line
  `@v5` caller (the `lint-call.yml` idiom) instead of a per-repo copy.

Each routine **reports first** and only proposes changes; nothing is vendored out
without a green `make audit`.
