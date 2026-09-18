# nvim split proposal — Core stops being a shell config

> **Status: SHIPPED — a closed record.** Decided 2026-09-17 (A2: extract into
> `dotfiles-nvim`, Core keeps vendoring it); §3.5 ran to completion the same day. §5's
> recommendation stood unchanged to the end: none of the three conditions it named as
> recommendation-flipping fired, and §7's four questions are answered in full at §7 — one
> of them **corrected while shipping** (below). All five steps land together in the **next**
> Core release; this file names no version, per the Additive Backlog's rule, so the release
> that carries them is the one that promotes their `[Unreleased]` entries.
>
> What shipped, in §3.5's order: `dotgibson/dotfiles-nvim` with the editor's history and a
> gate that starts it ([#1122][i1122]); Core vendoring `nvim/` behind `nvim.lock`, first
> sync byte-identical ([#1123][i1123]); `dotfiles-Windows` consuming the editor directly and
> `fleet-drift`'s Windows row becoming a two-lock compare ([#1124][i1124]); the editor's
> tests retired here because upstream already runs them against a real Neovim
> ([#1125][i1125]); and the docs learning the second vendored line — Core is now on **both**
> ends of a vendoring contract — ([#1126][i1126]). **Nothing here is open.**
>
> **§3.5 step 1 is done (2026-09-17, [#1122](https://github.com/dotgibson/dotfiles-core/issues/1122)).**
> [`dotgibson/dotfiles-nvim`](https://github.com/dotgibson/dotfiles-nvim) exists with the
> editor's history preserved — the `nvim/` tree object is identical on both sides, which is
> what makes step 2's byte-identical first sync true by construction rather than by
> inspection. Its gate starts the editor.
>
> **Step 2 is done (2026-09-17, [#1123](https://github.com/dotgibson/dotfiles-core/issues/1123)).**
> Core no longer authors the editor: `nvim/` is a vendored copy of `dotfiles-nvim` `v1.0.0`
> behind `nvim.lock`, refreshed by `scripts/sync-nvim.sh` and gated by audit §9q. The first
> sync was byte-identical, as step 1 had made it by construction.
>
> **Step 3 is done (2026-09-17, [#1124](https://github.com/dotgibson/dotfiles-core/issues/1124)).**
> `dotfiles-Windows` vendors the editor from `dotfiles-nvim` directly
> ([its PR](https://github.com/dotgibson/dotfiles-Windows/pull/271)), pinned by a root-level
> `nvim.lock` in Core's own field names; `fleet-drift.sh`'s Windows row became a two-lock
> compare against that pin. That sync moved **no editor bytes** either — the same guarantee,
> now observed on the second consumer. The side channel is the front door: Windows tracks the
> editor's release line rather than a Core ref.
>
> **Step 4 is done (2026-09-17, [#1125](https://github.com/dotgibson/dotfiles-core/issues/1125)).**
> Core stopped running the editor's tests. `scripts/test/15-nvim.sh`,
> `scripts/nvim-reachability.sh` and the nvim half of `scripts/test/80-nvim-reachability.sh`
> were **byte-identical** to the copies `dotfiles-nvim` already runs — there, against a real
> pinned Neovim with the committed plugin pins installed — so this retired duplicates, not
> coverage. Audit **§4b** went with the script it drove; **§4 (luacheck) stays** over the
> vendored copy, as §7(2) decided, though not for the reason §7(2) gives: **§9q** compares
> `nvim/`'s committed tree against `nvim.lock` byte for byte, so a corrupt sync is its
> catch now and luacheck is defence in depth. The one thing that was **not** a duplicate is
> the `#633` routine `allowed-tools` mirror, which had been lodging in that second file
> under a name that described the other half of it; it survives as
> `scripts/test/24-routine-allowed-tools.sh`, moved out of the zsh band (`NN >= 60`) that
> had been suppressing it on every scope but `shell`.
>
> **Step 5 is done (2026-09-17, [#1126](https://github.com/dotgibson/dotfiles-core/issues/1126)).**
> `VENDORING.md`, `ARCHITECTURE.md`, `CLAUDE.md`, `README.md`, `RELEASE-RUNBOOK.md` and
> `PORTING-MATRIX.md` describe the inbound line: the topology diagram has an arrow into
> Core, the runbook has a fifth flow, and the Neovim floor is attributed to the repo that
> authors it. It went wider than §3.4 listed, because the sweep found the same staleness in
> `RELEASE-STRATEGY.md` (which still batched the editor pin into the weekly freshness PR,
> contradicting §7(3)) and in six smaller places.
>
> One answer was **corrected while shipping it**: §7(1) was written against a generated
> `# core:theme:gen` block in the nvim colours that does not exist and never did. The
> coupling it was reaching for is real and runs the other way; §7(1) says what it is and
> what was built instead. Steps 2–5 are unaffected.
>
> This is the planning document for the roadmap milestone *"Core stops being a shell
> config"*: the editor tree that had been deferred three times — v4, `V5-PROPOSAL.md` §11
> (*"6,346 LOC and 61 plugins, but it breaks no public contract and re-vendors with zero
> migration"*), and `V8-PROPOSAL.md` §10 (*"three deferrals is the signal that it needs its
> own release, not a fourth ride-along slot"*). It measures first (§2), lays out both
> options with what each breaks (§3, §4), and **recommends one** (§5) — with the numbers
> that would change the recommendation named. Written in the "Current → Proposed → What
> breaks" voice of the v4, v5 and v8 proposals, and kept in that tense: §2 describes the
> tree as it was at `v7.4.3`, not as it is.
>
> **The §7 answers, in short.** (1) `dotfiles-nvim` vendors `theme/palette.toml` and runs
> the *assertion* half of `gen-theme.sh --refresh`, so *"colour is generated, not typed"*
> stays true in **both** repos — **corrected during §3.5 step 1**, because the generated
> block this originally described has never existed; §7(1) has the detail.
> (2) luacheck stays in Core's audit over the vendored copy, as an integrity check.
> (3) Core bumps `nvim.lock` **with the next Core release**, never on every nvim release.
> (4) The repo is `dotgibson/dotfiles-nvim`; the vendored path in Core stays `nvim/`.
>
> When a claim here drifts from `VENDORING.md`, `ARCHITECTURE.md` or `core.manifest`,
> **those win** — fix this.
>
> **No version.** The milestone stays unnumbered per the Additive Backlog's rule, and this
> file never names one. A2 is expected to be a **minor** in Core — nothing an OS repo
> consumes changes shape (§3.4). Per `RELEASE-STRATEGY.md`, that is the whole test, and it
> is why this decision does not produce a major however large the diff is.

[i1122]: https://github.com/dotgibson/dotfiles-core/issues/1122
[i1123]: https://github.com/dotgibson/dotfiles-core/issues/1123
[i1124]: https://github.com/dotgibson/dotfiles-core/issues/1124
[i1125]: https://github.com/dotgibson/dotfiles-core/issues/1125
[i1126]: https://github.com/dotgibson/dotfiles-core/issues/1126

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
5. Gates: luacheck (audit `§4`), the two test fragments, `scripts/nvim-reachability.sh`.
   The theme gate (`§9d`) does **not** reach into the tree — `nvim/` carries no
   `# core:theme:gen` block and never has, because it holds zero hex literals and asks the
   plugin (`nvim/lua/gerrrt/utils/palette.lua`). The coupling runs the other way:
   `gen-theme.sh --refresh` *reads* the tokyonight pin out of `nvim/lazy-lock.json` and
   the style out of `palette.lua`. See §7(1).

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
  (which reads two values out of it — §7(1)) and the link. `PORTABILITY.md`'s `HAVE_*`
  surface has nothing editor-specific. This is why v5 deferred it: extraction breaks no
  consumer.
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
| a vendored `theme/palette.toml` + the pin/style assertion — §7(1), corrected | `theme/palette.toml` (authored), `gen-theme.sh` |
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
- **The theme generator** keeps `theme/palette.toml` as its input and keeps rendering
  Core's own consumers from it. What moves is the pair of values `--refresh` asserts
  against — the tokyonight pin and the style — which are now authored in the nvim repo,
  so that repo vendors the palette and carries the assertion. §7(1).
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
3. Windows: `nvim-sync.ps1 -Source dotfiles-nvim`; `.core-ref` → the nvim pin. **(Done —
   the pin became a root-level `nvim.lock` rather than a re-shaped `.core-ref`, which moved
   it out of the tree it describes and let the parity gate drop its exclusion set. A bare
   sync there pins a RELEASE, not a branch tip, so the two consumers' pins are comparable.)**
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
- If the theme coupling (§7(1)) cannot be moved cleanly, the two repos share a generated
  file across a vendor boundary — the exact drift class `§9d` exists to prevent → design
  that first, or B.

**Decision gate — closed 2026-09-17, A2.** None of the three conditions above fired:
the editor has not settled (the quarter is not up, and the measured rate is unchanged),
§7(1) resolves cleanly in the direction that keeps both repos generated rather than typed,
and the drift check needs no second integrity model — the vendored tree is checked the way
`CHANGELOG.recent.md` already is. §3.5 is therefore the runbook, and the milestone's issues
are filed from it. **The first sync must be byte-identical**, measured by `git diff --stat`
between Core's `nvim/` before and after; that assertion is the one non-negotiable in §3.5,
because it is what keeps the fleet's next `core.lock` bump free of editor content.

## 6. Non-goals

- **An nvim overhaul.** Config changes, plugin choices, the LSP set — none of it. The
  split moves the tree; it does not edit it.
- **Vendoring `dotfiles-nvim` into the OS repos directly (A1).** Rejected in §3.1.
- **Dropping `CHANGELOG.md` from the vendored payload** (#676). The milestone text paired
  them; that question was answered separately (`V8-PROPOSAL.md` §10 Q2: promoted, with
  `CHANGELOG.recent.md` as the vendored digest) and is not reopened here.
- **Windows adopting `core/`.** It still cannot consume the shell layers; it consumes the
  editor, which is the point.

## 7. Open questions — answered (2026-09-17)

All four are decided. They were the conditions on §5's recommendation, so they are settled
here rather than during §3.5.

1. **The theme coupling — the nvim repo vendors `palette.toml` and carries the assertion.**

   **Corrected 2026-09-17, during §3.5 step 1.** This answer was written against a premise
   that does not hold: that `gen-theme.sh` writes a `# core:theme:gen` block into the nvim
   colours. **There is no such block, and there never was.** `nvim/` carries zero generated
   theme blocks — `scripts/gen-theme.sh:11` and `theme/palette.toml:9` both say why, in the
   same words: *"nvim never had the problem: it holds zero hex literals and asks the plugin
   (`nvim/lua/gerrrt/utils/palette.lua`)."* The editor was the exception that proved the
   rule, not a consumer of it.

   The coupling that **does** exist runs the other way, and it is real. `gen-theme.sh
   --refresh` resolves the palette *from* the tokyonight revision pinned in
   `nvim/lazy-lock.json`, at the style named in `palette.lua`, and refuses unless
   `palette.toml`'s `source_commit` and `style` agree with those two
   (`scripts/gen-theme.sh:830` and `:840`). That is the only machine check tying the palette
   to the editor — and it is maintainer-only, needs a live nvim with the plugin installed,
   and deliberately never runs on the `--check` path, so across the whole fleet it ran
   **nowhere**.

   Before the split that was survivable: one repo, one commit, one reviewer. After it the
   freshness bot moves the tokyonight pin in `dotfiles-nvim` while `palette.toml` stays in
   Core, and Core's rendered colours go quietly stale against a plugin revision no longer
   installed anywhere. So the answer survives its own premise: **`dotfiles-nvim` vendors
   `palette.toml`** (beside a `theme/.core-ref`, the way `dotfiles-Windows` already does —
   that repo has no `core/` at all and hash-gates the pair in its own CI) **and its gate
   carries the assertion half of `--refresh`**, in pure bash, in the repo where the pin now
   moves. An empty parse is its own failure there, because two empty strings compare equal.

   The alternative — keep the palette out of the nvim repo and let Core's `--refresh` read
   the *vendored* copy — still works mechanically, and is rejected for the reason it was
   rejected before: it leaves the assertion running nowhere on any CI path, on a fact that
   now changes in a different repo from the one that records it.

   §5 named this the condition most likely to flip the recommendation back to B. It does
   not: the check is cheaper than the generated-block version would have been, and it turns
   an assertion nothing was running into one that runs on every pin bump.
2. **luacheck stays in Core's audit, over the vendored copy.** It is the cheapest leg in
   the gate and it catches a corrupt sync, which is exactly the failure a vendored tree
   has and a source tree does not. It is a duplicate of the source repo's own luacheck
   only in the sense that `check-links.sh` is — vendored, and gated where it lands.
3. **Core bumps `nvim.lock` with the next Core release, never on every nvim release.**
   The freshness job moves pins into a PR in the nvim repo and a release follows on merge
   (`auto-tag.yml`'s shape), so every bump is an nvim release — but Core adopting each one
   as it lands would reimport the churn through the lock and leave the 36-of-82 number
   where it is. The pin moves when Core is cutting anyway. A "`nvim.lock` is N releases
   behind" nudge (§3.4) makes the lag visible so that "at Core's pace" does not decay into
   "never".
4. **Naming: `dotgibson/dotfiles-nvim`.** It matches the fleet and the milestone text. The
   vendored path in Core stays `nvim/`, so nothing downstream changes — `core.manifest`
   keeps its one entry and `blib_link_core` is untouched.

One consequence worth stating, since it is not in `scripts/os-repos.txt`'s shape:
`dotfiles-nvim` is a repo Core vendors **from**, not one Core fans out **to**. It does not
belong in `scripts/os-repos.txt`, and the fleet App's installation list needs checking
against it separately (`make fleet-app-scope`).
