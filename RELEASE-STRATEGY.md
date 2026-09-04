# Release Strategy

How and when changes ship across the eleven-repo fleet. This is the **policy
layer** that ties together the machinery already in the tree — `core.version`,
`scripts/release.sh`, `scripts/sync-core.sh`, the `core.lock` provenance stamp,
`scripts/fleet-drift.sh`, and the weekly bots — into one cadence, one tagging
discipline, and one safe-rollout path. When a rule here drifts from `README.md`
or `CONTRIBUTING.md`, those win; fix this.

> Looking for the **exact commands** to cut a release (Core, the OS-repo rollout, or
> htpx)? See **`RELEASE-RUNBOOK.md`** — the step-by-step recipe. This doc is the *why*
> and *when*; the runbook is the *what to type*.
>
> Looking for the **three-layer model**, the load-order chain, or why Core is vendored
> rather than submoduled? See **`ARCHITECTURE.md`** — this doc assumes that shape and
> describes only how it is released.

The short version: **Core is the only thing released on a planned cadence. The OS
and Role repos are consumers that pull a named Core version when they choose to —
and that tag their own installable work as it lands.** Core releases are cut on a
predictable monthly rhythm (plus out-of-band for security), tagged `vX.Y.Z`, proven
green by the audit before they fan out, and rolled out canary-first so a bad Core can
never reach all nine operating systems at once. A consumer's own tag needs no cadence:
CI cuts it when that repo's installable state moves.

## 1. The unit of release

**Core is the fleet's unit of change.** Every repo also carries a `vX.Y.Z` of
its own, but only Core's is a coordinated release with a curated changelog:

- **Core** (`dotfiles-core`) carries the SemVer in `core.version` (read it there
  rather than trusting a number copied into prose). It is the single source of truth,
  vendored into each OS repo's `core/`. A defect here fans out N-way, so Core is the
  thing that earns a version number, a tag, and a changelog.
- **OS-native repos** (`dotfiles-{MacBook,Fedora,Arch,Debian,openSUSE,Alpine,Gentoo}`)
  and **Role repos** (`dotfiles-Offense`, `dotfiles-Defense`) carry **two version
  lines, and they answer different questions.** `core.lock` — generated, recording
  `core_version`, `core_sha` and `core_ref` — answers *"what Core does Alpine run?"*
  offline and exactly. Their own `vX.Y.Z` tag, cut in CI by `auto-tag.sh`, answers
  *"what does this repo's own installable state look like?"* Neither substitutes for
  the other, and asking the second question of `core.lock` is how the tag line went
  wrong (below).
- **`dotfiles-Windows`** vendors **no** `core/` subtree (so no `core.lock`) and carries
  only the second line — advanced by an automatic patch when the `nvim/`/`starship/`
  assets it mirrors from Core move, or by a deliberate minor/major a human cuts for
  host work (see the runbook §3).
- **`dotfiles-web`** documents the system; it ships when its content is true,
  not on this cadence.

**What an OS repo's own tag does *not* mean, and used to.** Until #696 every
consumer's `auto-tag.yml` fired on `paths: ['core/**']` — the vendored subtree and
nothing else. So the tag advanced when *Core* moved and at no other time: measured on
`dotfiles-Fedora`, seven Core syncs produced seven releases and six native commits
produced none, including a package-name gate that had never run on any PR. `v1.3.68`
meant "68 Core syncs received", which `core.lock` already says precisely and offline.
The release *notes* were always right — `auto-tag.sh --notes-file` groups Conventional
Commits over the whole range — so it was the trigger and the granularity that were
wrong, never the content. Consumers now watch their **installable surface** (a denylist;
`.github/workflows/auto-tag-call.yml` documents the shape and
`scripts/fleet-release-triggers.sh` is the register that keeps the fleet to it), and
`bump: minor|major` is reachable from each repo's `workflow_dispatch` rather than
existing only as an input nobody passed.

**Core is still the only thing released as a coordinated event**, and that is
deliberate: nine independently *planned* release cycles would multiply the review
surface ninefold, and `core.lock` beats any repo tag at "what Core am I on?". But the
old justification for it — that the OS layer is a thin shim over package manager,
clipboard, and paths — stopped being true when the OS repo took ownership of
`os.capabilities` (#663/#667), the dispatch table deciding how `up`, `clip`, `maint-*`
and `core-doctor` behave on that box. A wrong entry there is a host-visible defect Core
cannot cause and Core's version cannot describe. That layer earns a version line that
moves when *it* moves.

## 2. Release cadence

Three tracks moving at three speeds. Conflating them is what causes cascade
failures — keep them separate.

| Track | Trigger | Frequency | Tagged | Blast radius |
| --- | --- | --- | --- | --- |
| Continuous integration | every merge to `main` | per-merge | no | none until synced |
| Routine pin bumps | the freshness bot | weekly (Mon 06:00 UTC) | no | one PR to review |
| Tagged Core release | calendar + on-demand | monthly + security | `vX.Y.Z` | the whole fleet |

### Continuous (per-merge)

`main` is always green: `ci.yml` runs the audit on every push and PR, and the
fan-out gate in `sync-core.sh` refuses to vendor a red tree. Merging to `main`
is **not** a release — nothing reaches a host until a sync happens. This is what
lets you commit freely without fear of breaking a live machine.

### Routine (weekly, automated)

The weekly bots **report first** — they open a PR or a deduped issue and never
vendor anything on their own. They run on two offset slots so the reviews don't
all land at once:

- **Mondays 06:00 UTC** — `freshness.yml` (rolls the zsh-plugin + nvim pins
  forward as a PR) and `fleet-drift.yml` (flags any OS repo lagging the latest **released**
  Core tag — not `main`'s tip, which would report every unreleased commit as drift).
- **Tuesdays 07:00 UTC** — `claude-routines.yml` (`/doc-audit` + `/tool-scout`),
  deliberately offset a day behind freshness so its findings issue lands after
  that week's pin PR.

Plugin and nvim pin bumps are batched into the weekly freshness PR, never landed
per-tool, so the fleet sees one reviewed step a week rather than a trickle of
unaudited churn. A quiet week means nothing needs doing.

### Tagged releases (monthly + security)

Cut a tagged Core release **once a month** on a fixed day (e.g. the first
Monday, after that week's freshness PR has merged and baked on `main`), plus
**out-of-band** for a security fix or a regression that is actively biting a
host.

Why monthly is the sweet spot for a nine-repo fleet (`scripts/os-repos.txt`):

- **Weekly tags** would 8× the fan-out churn — every OS repo re-syncs, every
  host re-bootstraps — for changes that are mostly already on `main` and
  available to anyone who wants them early.
- **Quarterly tags** let Core drift far enough from the synced fleet that a
  sync becomes a big, risky catch-up instead of a small, boring one.
- **Monthly** keeps each release small enough to reason about and roll back,
  while giving the weekly pin bumps time to bake on `main` before they are
  frozen into a tag.

### SemVer, mapped to dotfiles

The policy is one sentence: **choose the bump by blast radius on a host, not by how big
the diff looks.** `release.sh` enforces clean `X.Y.Z` (no pre-release suffix) and a
matching dated CHANGELOG heading around that decision.

The bump table itself lives in **`RELEASE-RUNBOOK.md` §1.0** — one copy, beside the
commands that act on it, with the three tiebreakers for the ambiguous cases and the note
that `tag-release.sh` now *enforces* the MAJOR rule rather than merely advising it.

## 3. Safe deployment: testing Arch without breaking Alpine or macOS

This is the core safety question, and the three-layer model (`ARCHITECTURE.md`) answers
most of it *by construction* before any tagging discipline is added.

### A change "meant for Arch" is one of two things

1. **OS-specific** (a `pacman`/AUR tweak, an Arch path). It belongs in
   `dotfiles-Arch`'s own `os/` layer and goes in **no** Core release. Alpine,
   macOS, and the rest literally never see it — they vendor Core, not each
   other's OS layers. This is total isolation for free; it is also the "is it
   Core?" test doing its job. **If a change is not identical on every machine,
   it is not Core, and it cannot reach another OS.**
2. **Actually Core** (identical everywhere). Then it is *supposed* to reach all
   nine — so the safety you want is not isolation but a **staged rollout** with
   a rollback per OS, below.

### Why a host cannot be broken behind your back

A Core change reaches a live host only after **three independent opt-in gates**,
in order. Core never pushes to a machine:

1. It is merged and **tagged** in `dotfiles-core` (and `release.sh` + the
   `sync-core.sh` gate both require a green audit first).
2. The target OS repo **receives** it (the fan-out PR `sync-fanout.yml` opens, or
   a `make sync` from Core) and commits the new `core.lock`.
3. The host **re-bootstraps or re-sources** to pick up the new files.

Skip any one and the host stays on what it had. An Alpine container that never
runs step 2 is unaffected by anything you tag, forever.

### Pin OS repos to a tag, not to `main`

Today `core.lock` records a `core_sha` on `main` — meaning "whatever `main`
happened to be at sync time." Tighten this so each OS repo vendors a **named
tag**:

```sh
# from a dotfiles-core checkout — pin ONE repo to a specific Core release
git checkout v<X.Y.Z>
CORE_BRANCH="$(git rev-parse v<X.Y.Z>^{commit})" ./scripts/sync-core.sh dotfiles-<Repo>
```

The `git checkout` is **not** optional, and neither constraint behind it is visible from
the script's usage:

- `sync-core.sh` refuses (exit 1) unless the local `HEAD` **is** the commit being
  vendored — "the audit above validated your LOCAL tree, not what will vendor." Hence the
  checkout; pinning from elsewhere needs `SYNC_SKIP_AUDIT=1`, which skips the very audit
  that makes a fan-out trustworthy.
- Pass the **peeled commit**, never `refs/tags/vX.Y.Z`. Releases are annotated tags, and
  the script resolves its pin with `git ls-remote`, which hands back the *tag object* —
  a SHA that is never the `HEAD` a tag checkout leaves you on, so the gate above could
  never pass and the lock would record the tag object rather than the commit.
  `git rev-parse v<X.Y.Z>^{commit}` is the same shape `sync-fanout.yml` passes.
- `core_version` is read from the **working tree's** `core.version`, not from the pinned
  commit. Pin `refs/tags/v5.3.0` while sitting on `main` and the lock records
  `core_version=5.4.1` beside `core_sha=<the v5.3.0 commit>` — a silently wrong lock.
  (`core_tag` is safe either way: it describes the resolved SHA.)

**The normal path is not this.** Every release opens a fan-out PR in each repo
(`sync-fanout.yml`), and adopting the release is merging that PR. Hand-run the recipe
above only for a deliberate single-repo pin or rollback. Either way, `sync-core.sh` is the
**only** sanctioned writer of `core.lock` — never a raw `git subtree pull`, which moves
`core/` but not the lock and leaves `core-integrity.sh` reporting `TAMPERED` (see
`VENDORING.md`), and never a per-repo `make core-lock`: three consumers carried an
independent generator of a format Core owns and all three had drifted from it, so #593
retired them into redirects that write nothing. The one sanctioned second writer is
`dotfiles-Offense`, which vendors Core on its own schedule and stamps the lock from what it
pulled; `VENDORING.md` has the contract.

Now "what Alpine runs" is a frozen, named version, and rolling one OS back touches no
other repo. `sync-core.sh`
stamps the release into each `core.lock` as a `core_tag` field (`git describe`
of the vendored commit), so the named version is recorded automatically and
`make fleet-drift` reports against it, not just the SHA.

**Rolling back is the same recipe at an older pin** — `git checkout v<previous>`, then the
same `CORE_BRANCH=...` sync naming only the affected repo. It needs no un-merging: `core/`
is materialized wholesale from the pinned tree, so the repo ends up byte-identical to that
release whatever it was carrying before, and it touches no other repo. Push the resulting
commit, then confirm with `make core-integrity` and `make fleet-drift`.

### The staged rollout for a Core release

1. **Tag** `vX.Y.Z` in Core. The audit is green (enforced by `release.sh` and
   the fan-out gate).
2. **Canary** into one low-risk repo first — `dotfiles-MacBook` (the reference
   implementation) or a throwaway Alpine/Arch container. Bootstrap it and smoke
   test: shell starts, load order intact, no broken bindings.
3. **Bake** on the canary for a few days. Real use surfaces what CI cannot.
4. **Fan out**: on release, the `sync-fanout` workflow
   (`.github/workflows/sync-fanout.yml`) opens a `core.lock`-bump PR against every
   repo in `scripts/os-repos.txt`, pinned to the released commit — so the fan-out is
   now "merge the PRs," canary first, instead of a remembered `make sync` (which
   still works locally). `make fleet-drift` confirms every repo converged on the new
   tag. The PRs are opened, never auto-merged — the opt-in gates above are intact.
5. **Roll back per OS** if needed: re-pull the previous tag in just the affected
   repo. Alpine rolling back to `v3.5.0` does not touch macOS on `v3.6.0` — the
   repos are independent consumers.

### Pinning reusable workflows (the `@vN` policy)

The fleet's reusable workflows — `auto-tag-call.yml`, `bootstrap-test.yml`,
`claude-routines-call.yml`, `core-integrity-call.yml`, `lint-call.yml`,
`notify-failure-call.yml`, `notify-web-call.yml` — are called cross-repo from each
OS repo. Pinning the caller's `uses:` ref trades off two
things: **determinism** (a mutable `@main` can change a repo's CI with zero diff in
that repo — a real supply-chain concern for an *integrity* guard) against
**auto-propagation** (a guard/bootstrap improvement should reach every repo without
hand-bumping N callers).

The policy resolves both with a **moving major tag**: callers pin to **`@vN`** (e.g.
`@v2`), and `tag-release.sh` force-advances `vN` to each new `vN.x` at release time
(alongside the immutable `vX.Y.Z` tag). So a caller's behavior can change **only via a
Core release** (deterministic between releases), yet patch/minor guard fixes still fan
out automatically; a major bump is the one intentional, reviewed caller edit. This is
GitHub's own recommended pattern for reusable workflows.

- **Authoring:** new callers use `@vN` for the current major (not `@main`, not a bare SHA).
  A minority SHA-pin instead, trading the auto-fan-out for immunity to a moved tag, and what
  that costs depends on whether the repo is in the fan-out:
  - **Inside it** (`dotfiles-MacBook`, `dotfiles-Defense` today): since
    [#482](https://github.com/dotgibson/dotfiles-core/issues/482) `sync-core.sh` moves the pin
    in the same commit that stamps `core.lock`, so the trade costs nothing at release time —
    but it does require the fleet App to hold **Workflows: write**, because the sync branch
    then carries a `.github/workflows/*` change (`GITHUB-APP-AUTH.md`).
  - **Outside it** (`dotfiles-Windows`): it vendors no `core/`, so it is absent from
    `scripts/os-repos.txt`, nothing moves its pin, and it needs a hand bump.

  Don't trust a frozen count of who pins what — `RELEASE-RUNBOOK.md` §"Step 5, by bump type"
  carries a one-liner that derives it from the callers.
- **Bootstrapping a major:** `vN` is created/advanced by `make publish`; the very first
  `vN` can also be stamped by hand (`git tag -fa vN vN.0.0^{commit} -m vN && git push -f origin vN`  — peel the release
  tag with `^{commit}`, or the alias becomes a *nested* tag pointing at a tag rather than
  the direct-to-commit alias `make publish` creates).
- **Trade vs. exact-SHA pinning:** a SHA is maximally deterministic but needs a manual
  caller bump fleet-wide on every change — rejected as too high-churn for a first-party,
  same-owner reusable workflow. `dotfiles-Windows` takes the opposite side of that trade for
  its one caller, and pays exactly that cost — its pin only advances when a human bumps it, so
  it lags Core by however long that goes unnoticed.

### What CI must prove before a tag

The pre-tag gate is already most of the way there and should be treated as
release-blocking:

- `ci.yml` runs the full audit on push and PR across four userlands: the
  **Ubuntu** (glibc) and **macOS bash 3.2** matrix legs, plus container legs for
  **Alpine** (`audit-alpine` — musl + busybox) and **Arch** (`audit-arch` — the
  rolling GNU toolchain, newer than Ubuntu LTS). So a Bashism that breaks the
  Mac, a busybox-applet assumption that breaks Alpine, or a coreutils deprecation
  that will bite Arch first is all caught before a tag.
- `bootstrap-test.yml` exercises the bootstrap path.
- The behavioral suite (`test-core.sh`) checks load order and function units
  cross-shell.

## 4. Tooling that backs this policy

The pieces this policy leaned on are now wired:

- **`core_tag` in `core.lock`.** `sync-core.sh` stamps `git describe` of the
  vendored commit into each repo's `core.lock`, and `make fleet-drift` surfaces
  it — so the dashboard reports drift against named releases, not just SHAs.
- **Per-OS container smoke in CI.** `ci.yml` runs the shell-scope audit on
  **Alpine** (`audit-alpine`, musl + busybox) and **Arch** (`audit-arch`, the
  rolling GNU toolchain) on top of the Ubuntu + macOS matrix — closing the
  "passed on Fedora, assumed elsewhere" gap before a tag.
- **`make tag` / `make publish`.** `scripts/tag-release.sh` commits `core.version` + `CHANGELOG`
  and creates the annotated `vX.Y.Z` tag (re-running the audit gate), so
  `make release VERSION=X.Y.Z && make tag` stages and commits; `make publish` finishes
  it AFTER the PR merges. The tag is created only then, at the release commit on
  `origin/main` — never on a commit that is not yet on `main` (see RELEASE-RUNBOOK.md
  §"Why the tag comes last").
- **Auto-published GitHub Release.** `.github/workflows/release.yml` fires on a
  `vX.Y.Z` tag push and publishes the Release, its body taken from the curated
  `CHANGELOG.md` section — gated on the tag matching `core.version`.

### Where GitHub Releases come from (four paths)

Almost every tag becomes a **Release** automatically, by one of four routes — the
exception is a deliberate `dotfiles-Windows` minor/major, which a human tags and
releases by hand (last row). The automatic split is forced by GitHub's rule that
**a tag pushed by `GITHUB_TOKEN` cannot trigger another workflow** (anti-recursion),
so a CI-cut tag can't rely on a separate `on: push: tags` workflow:

| Repo | Tag cut by | Release created by | Notes source |
| ---- | ---------- | ------------------ | ------------ |
| **dotfiles-core** | you (`make publish`, after the PR merges) | `release.yml` (`on: push: tags`) — fires because *you* pushed the tag | curated `CHANGELOG.md` section |
| **Core-vendoring consumers** (×9 — seven OS-native plus `dotfiles-Offense`/`-Defense`; `scripts/os-repos.txt` is the list) | `auto-tag.sh` in CI when the repo's **installable surface** moves — a Core fan-out or its own work (#696) — or on a `workflow_dispatch` naming `bump` | `auto-tag.sh --release`, **in the same job** (the token-pushed tag can't trigger `release.yml`) | grouped Conventional-Commit notes (`auto-tag.sh` → `--notes-file`; `--generate-notes` only as the empty-range fallback) |
| **dotfiles-Windows** — auto patch | `auto-tag.sh` in CI on an `nvim/`/`starship/` sync | same as OS repos, but SHA-pinned (calls `auto-tag-call.yml` at a commit, not the moving `@vN` alias) | grouped Conventional-Commit notes (same `auto-tag.sh` `--notes-file` path) |
| **dotfiles-Windows** — deliberate minor/major | **you**, by hand for host work (`git tag` → push) | **you** (`gh release create --notes-file`) — Windows' caller is push-only, so its auto-tag never fires on a CHANGELOG commit or a tag push, and only ever patches | curated `CHANGELOG.md` section |

So: Core releases read like the changelog; OS-repo and Windows **auto-patch** releases get
grouped Conventional-Commit notes generated by `auto-tag.sh` (they carry no curated per-tag
CHANGELOG of their own), and those auto
paths are idempotent and need no manual tag/Release push. The one exception is a **deliberate
`dotfiles-Windows` minor/major** for accumulated host work: there is no `release.yml` on that
repo, so a human promotes its `CHANGELOG.md` and cuts the tag + Release by hand. Both Windows
flows are in `RELEASE-RUNBOOK.md` §3.

### Still worth doing

- **Promote `audit-arch`/`audit-alpine` to required checks** in branch
  protection so a regression on either userland blocks a merge to `main`. This is
  a GitHub **repo setting**, not a file: Settings → Branches → the `main` rule →
  *Require status checks to pass* → add `audit-arch` and `audit-alpine`.
