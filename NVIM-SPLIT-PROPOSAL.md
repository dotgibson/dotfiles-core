# nvim split proposal — Core stops being a shell config

> **Status: DECISION PENDING (opened 2026-09-14) — extract or freeze.** This is the
> planning document for the roadmap milestone *"Core stops being a shell config"*: the
> editor tree that has been deferred three times — v4, `V5-PROPOSAL.md` §11 (*"6,346 LOC
> and 61 plugins, but it breaks no public contract and re-vendors with zero migration"*),
> and `V8-PROPOSAL.md` §10 (*"three deferrals is the signal that it needs its own release,
> not a fourth ride-along slot"*). The milestone exists to pick one of two ways out, and
> so does this file. It measures first (§2), lays out both options with what each breaks
> (§3, §4), and **recommends one** (§5) — with the numbers that would change the
> recommendation named. Written in the "Current → Proposed → What breaks" voice of the v4,
> v5 and v8 proposals.
>
> When a claim here drifts from `VENDORING.md`, `ARCHITECTURE.md` or `core.manifest`,
> **those win** — fix this.
>
> **No version.** Whichever option is chosen, the milestone stays unnumbered per the
> Additive Backlog's rule. Extraction is expected to be a **minor** in Core (nothing an
> OS repo consumes changes shape — see §3.4); freezing is not a release at all.

## 1. Summary

`nvim/` is the largest single tree in Core and the only one that is not shell:

| Measured at `v7.4.3` (2026-09-14) | |
| --- | --- |
| Lua source | **6,404 lines** in **98 files** (`nvim/init.lua`, `nvim/lua/gerrrt/{config,plugins,servers,utils}`) |
| Plugins pinned | **61** in `nvim/lazy-lock.json` (the milestone text says 51; it grew) |
| Manifest footprint | **one** `core.manifest` entry — the directory — linked whole by `blib_link_core` to `$XDG_CONFIG_HOME/nvim` on every host |
| Consumers | all nine Unix OS/Role repos via `core/nvim`; **dotfiles-Windows** via `nvim-sync.ps1`, a standalone copy pinned by `nvim/.core-ref` (*"the only Core asset worth sharing on the host is the Neovim Lua tree"*) with its own parity tests |
| Runtime floor | Neovim **≥ 0.12.0** fleet-wide, because `nvim-treesitter` is pinned to `main`; tree-sitter-cli ≥ 0.26.1 — Alpine's three older stable branches sit below both (`PORTING-MATRIX.md` ³³) |

The milestone's framing — *"living inside a repo whose single gate is a SHELL audit"* —
is out of date and worth correcting before deciding on it: the audit runs **luacheck**
over the tree (`scripts/audit/20-lua.sh`, with an orphaned-module check), and the
behavioral suite has two nvim fragments, `scripts/test/15-nvim.sh` and
`scripts/test/80-nvim-reachability.sh` (a headless reachability run). What the gate does
**not** do is start Neovim with the real plugin set and assert health — the check that
would catch a plugin pin bump breaking startup, which is the change class this tree
receives most.

The cost is churn, and it is measurable (§2.2): in the 87 days since `v4` (2026-06-18),
**102 of 1,178 commits** touched `nvim/`, **38 of them touched nothing else**, and **36 of
82 releases** carried an nvim diff — 30 of those commits are `lazy-lock.json` pin bumps
from the freshness job. Every one of those releases re-vendored the editor to nine repos
whose shells did not change.

Two ways out, from the milestone:

- **EXTRACT** it into `dotfiles-nvim`, vendored the way Core is — *"the htpx pattern
  turned inward"* (Offense vendors `offensive/companion` from `dotgibson/htpx` with its
  own `companion.lock`). The seam is half-cut: Windows already consumes `nvim/` alone.
- **FREEZE** it against a pinned Neovim and *"stop paying to pretend it moves."*

§5 recommends **extract, in the form where Core keeps vendoring it** (§3, option A2) —
the fleet keeps one lock and one fan-out, the editor gets its own gate and cadence, and
Windows becomes a first-class consumer instead of a side channel.

## 2. Current

### 2.1 How nvim ships today

1. `nvim/` is authored in Core and listed in `core.manifest` as a directory.
2. `scripts/sync-core.sh` vendors it (it is in the filtered set) into each repo's
   `core/nvim`; `blib_link_core` links `core/nvim` → `~/.config/nvim` on `bootstrap`.
3. `nvim/lazy-lock.json` pins every plugin revision. `.github/workflows/freshness.yml`
   rolls the pins forward on a schedule through `scripts/update-nvim-plugins.sh`, which
   runs `nvim --headless +Lazy! sync` — *"pins exist so nothing floats silently into the
   8 OS repos, and THIS is the one place the nvim ones move — under review, not on their
   own."* A bump is a Core PR, then a Core release, then nine sync PRs.
4. `dotfiles-Windows` runs `nvim-sync.ps1` to copy `nvim/` from a Core ref into its own
   `nvim/`, records the commit in `nvim/.core-ref`, and `fleet-drift.yml` reads that pin
   beside the Unix repos' `core.lock`. `tests/NvimParity.Tests.ps1` and
   `Assert-NvimParity.ps1` hold the copy to the source.
5. Gates: luacheck (audit `§2`), the two test fragments, `scripts/nvim-reachability.sh`;
   `gen-theme.sh` writes the palette's `# core:theme:gen` block into the nvim colours, so
   the theme gate (`§9d`) reaches into the tree too.

### 2.2 The cost, measured

| Since 2026-06-18 (87 days) | Count |
| --- | --- |
| Commits on `main` | 1,178 |
| … touching `nvim/` | 102 |
| … touching **only** `nvim/` | 38 |
| … that are `lazy-lock.json` bumps | 30 |
| Releases (`vX.Y.Z` tags) | 82 |
| … whose diff touches `nvim/` | 36 |

So **44% of releases carry an editor change**, and about a third of the nvim commits are
the freshness job moving pins. Each such release costs the fleet nine sync PRs and each
repo a patch tag of its own (`auto-tag.yml`). None of that is wrong; all of it is the
editor's cadence imposed on the shell's.

The other cost is the **floor**: `nvim-treesitter` on `main` requires Neovim 0.12, so the
fleet's package floors moved with it, and Alpine's bootstrap grew version-guarded cargo
fallbacks and a warn-only neovim floor check (`dotfiles-Alpine#170`) — editor churn
surfacing as OS-repo provisioning code.

### 2.3 What is not a cost

- **No public contract.** Nothing outside `nvim/` reads it except the theme generator
  (which writes into it) and the link. `PORTABILITY.md`'s `HAVE_*` surface has nothing
  editor-specific. This is why v5 deferred it: extraction breaks no consumer.
- **The vendor mechanism is proven twice** — Core into nine repos, htpx into Offense.

## 3. Option A — EXTRACT into `dotfiles-nvim`

### 3.1 Two ways to wire it, and why one is better

**A1 — the OS repos vendor it directly.** Each repo carries `core/` *and* `nvim/`, a
second lock, a second fan-out workflow, a second sync PR per release. That is the htpx
pattern exactly — and it doubles the fleet's vendoring surface for a tree that has one
consumer per host. Rejected on cost alone: nine more PRs per editor release is the churn
this document exists to remove, moved rather than removed.

**A2 — Core vendors `dotfiles-nvim`, the fleet keeps vendoring Core.** `dotfiles-nvim`
is the editor's source of truth with its own gate and release line; Core's `nvim/`
becomes a **vendored copy** pinned by an `nvim.lock` (shape of `core.lock`), refreshed by
a `make sync-nvim` or a bump PR on an nvim release. The OS repos see nothing new:
`core/nvim` is still one directory in the filtered set, `blib_link_core` still links it,
`core.lock` still records one commit. What changes is *when* it moves: an editor release
reaches the fleet only when Core chooses to bump the pin — which can ride on the next
Core release rather than force one.

Windows is the tell: `nvim-sync.ps1` today copies `nvim/` out of Core at a Core ref. Under
A2 it copies from `dotfiles-nvim` at an nvim ref — the same script, one URL, and its
`.core-ref` becomes an `nvim.lock`-shaped pin. The side channel becomes the front door.

### 3.2 What moves

| To `dotfiles-nvim` | Stays in Core |
| ------------------ | ------------- |
| `nvim/` (the tree), `lazy-lock.json` | the vendored copy under `nvim/` + `nvim.lock` |
| `scripts/update-nvim-plugins.sh`, the freshness job's nvim leg | the freshness job's zsh leg; a new "nvim pin behind" nudge |
| `scripts/nvim-reachability.sh`, `scripts/test/15-nvim.sh`, `80-nvim-reachability.sh` | `audit-core.sh`'s luacheck leg as a *vendored-tree* check (or dropped — the source repo gates it) |
| the `# core:theme:gen` block in the nvim colours — **open question §7(1)** | `theme/palette.toml`, `gen-theme.sh` |
| a headless startup + `:checkhealth` gate (new) | — |
| the Neovim floor and its `PORTING-MATRIX.md` footnotes (the *fact*); the matrix keeps rendering it | `gen-porting-matrix.sh` |

### 3.3 What the new repo gains that Core cannot give it

- **A gate that starts the editor.** Core's CI runners have no Neovim; `dotfiles-nvim`'s
  can (the reachability script already needs one). Headless startup with the real pins,
  `:checkhealth` clean, luacheck, stylua — on every pin bump, *before* it reaches a lock.
- **Its own cadence.** Pin bumps become nvim releases; Core bumps `nvim.lock` when it
  wants them. The 36-of-82 number becomes whatever Core chooses.
- **Its own floor.** "Neovim ≥ 0.12" is a property of the editor repo, consumed by the
  OS repos through the matrix footnotes as today; a future bump does not have to ship
  inside a Core release that also changes the shell.

### 3.4 What breaks (A2)

- **Nothing an OS repo consumes.** `core/nvim` keeps its path; `core.manifest` keeps its
  entry (now pointing at a vendored tree — `core.vendor`'s entry model, the way
  `CHANGELOG.recent.md` is a generated payload); `blib_link_core` is unchanged. This is
  what keeps extraction a **minor**.
- **Core's manifest audit** (`§1`) needs the vendored tree treated like `CHANGELOG.recent.md`:
  present, tracked, generated, not hand-edited — a `# nvim:vendored` marker or the lock's
  hash as the drift check, the way `core-integrity.sh` checks a repo's `core/`.
- **The freshness job** loses its nvim leg (moves) and gains a "nvim.lock is N releases
  behind" nudge, the way `fleet-drift.yml` reports `core.lock`.
- **The theme generator** either keeps writing into the vendored copy (and the source repo
  carries the palette block by another route) or the palette becomes an input the nvim
  repo reads — §7(1).
- **Windows' parity tests** re-point at the nvim repo; `fleet-drift.yml`'s Windows row
  reads the new pin.
- **Docs:** `VENDORING.md` gains the second vendored line (htpx already documents the
  shape), `ARCHITECTURE.md`'s tree, `CLAUDE.md`'s layer table, the README's tour.

### 3.5 Migration sketch

1. Create `dotgibson/dotfiles-nvim` with `git subtree split`/`filter-repo` of `nvim/`
   (history preserved), the moved scripts and tests, a `make audit` of its own (luacheck,
   stylua, headless startup, `:checkhealth`), and a release workflow that tags and moves
   a major alias (Core's `tag-release.sh` shape).
2. In Core: `nvim.lock`, `scripts/sync-nvim.sh` (or a `--from-nvim` mode of the existing
   vendor producer), the manifest/vendor entries, the drift check, the freshness nudge.
   First sync from the tag that equals today's tree — a **byte-identical** vendored copy,
   so the fleet's next `core.lock` bump carries no editor change at all.
3. Windows: `nvim-sync.ps1 -Source dotfiles-nvim`; `.core-ref` → the nvim pin.
4. Retire Core's nvim tests where the source repo now runs them; keep luacheck over the
   vendored copy only if it costs nothing (it is the cheapest leg).
5. `RELEASE-RUNBOOK.md` gains the nvim line beside htpx's.

## 4. Option B — FREEZE against a pinned Neovim

Pin the Neovim floor (0.12.x) and the plugin set as they are; stop the freshness job's
nvim leg; accept that the editor no longer moves unless someone moves it by hand.

- **What it costs now:** nothing. One workflow edit and a sentence in the README.
- **What it removes:** the 30 pin-bump commits per quarter and the releases they force;
  the floor pressure on Alpine and the matrix footnotes.
- **What it does not remove:** the tree still ships in every Core release (it is in the
  manifest), still has no startup gate, still has the shell's cadence when the shell
  moves. It removes *churn*, not *coupling*.
- **What it risks:** pinned plugin revisions rot — a plugin's remote moves or a repo is
  deleted and `Lazy! sync` on a fresh box fails; Neovim's own package moves past the
  pinned plugins' compatibility on rolling distributions (Arch, Alpine edge, Gentoo) and
  the fleet's floor becomes a ceiling. Freezing is stable until it is not, and the
  failure lands on a fresh bootstrap.
- **When it is the right answer:** if the editor is *done* — if the author expects no
  plugin changes and the fleet's Neovim versions are stable — or if maintenance budget is
  the binding constraint. It is also the **fallback**: an extracted repo that stops being
  released is a freeze with better provenance.

## 5. Recommendation — extract, Core keeps vendoring (A2)

The measured churn (44% of releases) is real and the coupling (one manifest entry,
nine consumers, a Windows side channel) is exactly the shape the vendoring model already
handles for Core itself. A2 removes the churn *and* the coupling without changing anything
an OS repo consumes, gives the editor the one gate it lacks, and turns the Windows mirror
into the second consumer of a proper release line. B removes the churn only and leaves a
fresh-bootstrap failure mode armed.

**What would change the recommendation:**

- If the count of nvim-only commits over the *next* quarter is under ~10 (the editor has
  settled), freezing is nearly free and extraction is overhead → **B**.
- If A2's manifest/vendor-tree drift check turns out to need more than the
  `core-integrity.sh` shape already provides (a second integrity model), the "minor"
  claim in §3.4 is wrong → re-evaluate against B.
- If the theme block (§7(1)) cannot be moved cleanly, the two repos share a generated
  file across a vendor boundary — the exact drift class `§9d` exists to prevent → design
  that first, or B.

**Decision gate:** the author picks A2 or B on this file. If A2, §3.5 becomes the
runbook and the milestone's issues are filed from it; the first sync must be
byte-identical, measured by `git diff --stat` between Core's `nvim/` before and after.

## 6. Non-goals

- **An nvim overhaul.** Config changes, plugin choices, the LSP set — none of it. The
  split moves the tree; it does not edit it.
- **Vendoring `dotfiles-nvim` into the OS repos directly (A1).** Rejected in §3.1.
- **Dropping `CHANGELOG.md` from the vendored payload** (#676). The milestone text paired
  them; that question was answered separately (`V8-PROPOSAL.md` §10 Q2: promoted, with
  `CHANGELOG.recent.md` as the vendored digest) and is not reopened here.
- **Windows adopting `core/`.** It still cannot consume the shell layers; it consumes the
  editor, which is the point.

## 7. Open questions

1. **The theme block.** `gen-theme.sh` writes `# core:theme:gen` into the nvim colours from
   `theme/palette.toml`. Under A2 the palette is Core's and the file is the nvim repo's.
   Options: the nvim repo vendors `palette.toml` (a second small vendor line) and runs its
   own generator; or the block is generated into the *vendored copy* only, at sync time,
   and the source repo carries a neutral palette. The first keeps "colour is generated,
   not typed" true in both repos; the second keeps the source repo palette-free. Decide
   before step 1 of §3.5.
2. **Does luacheck stay in Core's audit over the vendored copy?** It is cheap and it
   catches a corrupt sync; it is also a duplicate gate. Lean: keep, as a vendored-tree
   integrity check, the way `check-links.sh` is vendored and gated.
3. **Who cuts nvim releases, and how often?** The freshness job moving pins into a PR in
   the nvim repo, and a release on merge (`auto-tag.yml`'s shape), makes every bump a
   release; Core then bumps `nvim.lock` at its own pace. Confirm that pace is "with the
   next Core release" and not "immediately", or the churn comes back through the lock.
4. **Naming.** `dotfiles-nvim` matches the fleet; the milestone text uses it. The vendored
   path in Core stays `nvim/` so nothing downstream changes.
