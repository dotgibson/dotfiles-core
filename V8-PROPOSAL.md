# v8 proposal — the OS repo stops carrying code Core owns

> **Status: PROPOSED — awaiting a verdict.** Nothing here has shipped. Core is at
> `7.3.0` with an empty `[Unreleased]`, no open PRs, and a **Breaking Backlog milestone
> with zero open issues** — so this document is the content of a major, written because
> there was none to find. That is the same situation `V5-PROPOSAL.md` was written into,
> and `CHANGELOG.md` records the reasoning: *"the machinery for cutting a major was
> documented and rehearsed while the content of one was not written down anywhere."*
>
> Written in the RFC "Current → Proposed → What breaks" voice the v4 proposal established
> and the v5 proposal kept. When a claim here drifts from `RELEASE-STRATEGY.md`,
> `CONTRIBUTING.md` or `ARCHITECTURE.md`, **those win** — fix this.
>
> **The major it proposes is `v8.0.0`.** Per the Additive Backlog's standing rule, the
> milestone that carries this work stays **unnumbered**: a version-named milestone is a
> promise about which release the work lands in, and here numbers get consumed by
> whatever merges first (`v4.19.0`, `v5.0.0` and `v6.0.0` each shipped with their own
> milestone still open). If something unrelated takes `8.0.0` first, read every bare "v8"
> below as the *proposal's* name for whatever major this ships as.

## 1. Summary

Core is at `7.3.0`, `HEAD` is the release commit, the tree is clean and the whole fleet
is synced to it. This proposes a single coordinated major around one idea:

**the OS repo stops carrying code Core owns.**

v5 made the OS layer *declare* its capabilities. v6 made the vendored payload *only Core*.
v7 deleted the last built-in fallbacks, so `ARCHITECTURE.md`'s "deliberate exceptions"
section now reads **zero**. What is left is the other direction, and no gate has ever
been allowed to fail on it: **portable logic stranded outside Core, hand-maintained N
times.** Three changes:

1. **The three advisory legs of `lint-call.yml` flip to blocking** — duplicated
   Core-owned blocks, undeclared `HAVE_*` reads, and an `os/` band with no capability
   declaration all stop being warnings.
2. **`bootstrap.sh` consolidates** into `blib_*` plus a thin per-repo hook. Four helpers
   sit at **1/9** adoption, and the size spread is 1,604 lines (MacBook) to 270
   (Defense).
3. **`audit-core.sh` gets the `#699` treatment** — 3,059 lines and 47 sections in one
   file, with a duplicate `§1c`, reproducing exactly the condition that justified
   splitting `test-core.sh`.

They are bundled because the first two are the same move seen from two sides — the gate makes
the duplication *fail*, the consolidation gives it *somewhere to go* — and because both
need the **same per-repo event**: one PR per repo that bumps its `@v7` pin and adopts.
Shipping them separately would make every OS repo take two migration PRs for one idea.
One `v8.0.0` pays the fan-out cost once, which is the batching discipline
`RELEASE-STRATEGY.md` §2 is built around and the same argument v4 and v5 each made.

## 2. Why these earn a major — and where this proposal's own framing failed

A **MAJOR** is chosen by *blast radius on a host, not by how big the diff looks*
(`RELEASE-RUNBOOK.md` §1.0, which `RELEASE-STRATEGY.md` names as the single copy of the
bump table). Its concrete triggers: reordering the load chain; removing or renaming a
public alias, binding or function; changing the `bootstrap.sh` symlink contract; dropping
a `core.manifest` path. And the tiebreaker that decides this release: *"If nothing a host
already uses changes meaning, it's at most MINOR — even if the diff is large."*

| change | trigger it clears | verdict |
| ------ | ----------------- | ------- |
| §3 the three advisory legs flip | changes the reusable-workflow contract every OS repo's CI calls | **earns it** — the v7.0.0 `WEBHOOK_SECRET` precedent |
| §4 `bootstrap.sh` consolidation | **only if** it adds or moves a linked overlay | **open — §4.4 decides** |
| §5 the audit split | none; ships to no repo | ride-along |
| §6 doc and comment repair | none | ride-along |

**Two claims this release was expected to rest on did not survive contact with the
code**, and they are recorded rather than quietly corrected, because the shape of the
error is the argument for checking:

**The consolidation does not change the symlink contract, as written.** The roadmap
milestone asserts that collapsing `bootstrap.sh` into `blib_*` *"changes the symlink
contract, so every host re-bootstraps."* It does not follow. The symlink contract **is**
`blib_link_core`, `blib_link_os_layer` and `blib_link_role_layer`
(`lib/bootstrap-lib.sh:558,718,826`) — they already live in Core, and every OS repo
already calls them. What consolidation moves is *provisioning*: package installation,
privilege escalation, failure reporting. None of that is linked onto a host, so none of
it is visible to one. v5 earned its major here because `#663` added a **new overlay**
(`os/<os>.capabilities` → `$ZSH_CFG/os.capabilities`), and that is the thing that forced
`./bootstrap.sh --links-only` on every box. Absent a new overlay, §4 is a large refactor
of OS-repo-owned code, and the bump table calls that **MINOR** however many lines it
touches. §4.4 puts the decision explicitly instead of assuming it.

**The audit split is not breaking either.** It was expected to change what a consumer
repo receives, in the `#676` mould. It does not: `scripts/audit-core.sh` is **absent from
`core.vendor`**, so it ships to nobody and no `core.lock` tree object contains it. It
rides along. (The near miss is worth naming: `scripts/lib/common.sh` **is** vendored —
`dotfiles-MacBook`'s `test/check-return-traps.sh` sources it for
`_core_return_trap_hits` — so a split that moved analysis engines *out of `common.sh`*
would be breaking. §5 must not.)

So the major rests on §3. That is not a thin result, because §3 is not merely *permitted*
by a major — it is **impossible without one**, which §3.2 is about.

## 3. Change 1 — the gates stop being advisory

### 3.1 Current

Three legs of the reusable `lint-call.yml` ship **advisory with an explicit promise to
flip**, and two of them already say so to users, in CI output, on every run:

```text
This warning becomes a BLOCKING failure in the next Core release.
```

| leg | line | what it catches |
| --- | ---- | --------------- |
| Core-owned block duplication (repo-owned zsh) | `:299` | portable logic Core already owns, re-implemented locally |
| Undeclared Core `HAVE_*` reads | `:373` | a repo reading a Core flag outside `zsh/have-api.txt`'s declared surface |
| `os/` band with no `os/*.capabilities` | `:439` | an OS layer that never declared |

The first has been promised since **2026-08-21**, the second since **2026-09-06**. Three
releases have shipped in between (`v7.1.0`, `v7.2.0`, `v7.3.0`) and none of them flipped
anything. That is not neglect — it is structural, and the workflow says so itself.

`shfmt` at `:493` is **not** in this queue: it is deliberately permanent-advisory and
stays that way.

### 3.2 Why a minor cannot do this

`lint-call.yml:293-298` records the blocker exactly:

> callers pin `@v7`, a moving major tag, so every OS repo sees this leg the moment
> auto-tag moves — and no repo can delete its copy until it has vendored the Core that
> replaces it. It is **red-on-arrival by construction**.

That is the whole trap. On a **minor**, `tag-release.sh` force-advances the `v7` alias
onto the new release, so all nine callers change behaviour simultaneously, with no diff
in their own repos and no window in which to prepare. The measured markdownlint leg
predicted the same thing before it landed — *"Seven of nine repos would go red the moment
auto-tag moves `@v7`, before a maintainer could act."*

On a **major**, `RELEASE-RUNBOOK.md` §1.1 step 5 does the opposite: it mints `v8` fresh at
the merged tip and leaves **`v7` frozen** — *"do not run the alias line against the
outgoing major"* — and every caller is then bumped `@v7` → `@v8` **by hand**.

That single difference converts one simultaneous fleet-wide break into **nine independent
opt-ins**. A repo stays green on `@v7` for as long as it likes; it adopts the blocking
gate on the day it merges its own bump PR, having done the cleanup in that same PR. The
frozen alias is not a convenience here. It is the only mechanism the fleet owns that makes
these flips landable at all.

### 3.3 Proposed

Flip all three legs to blocking in the `v8` line, and **only** in the `v8` line. Each is a
small edit to the step — drop the `— advisory` suffix, turn the `::warning::` into a
failing exit — and the analysis behind each already lives in one place in
`scripts/lib/common.sh` (`_core_owned_block_hits` and the `HAVE_*` reader), covered by
fixtures in `scripts/test/`. No new machinery.

The flip is **not** gated on the fleet being clean first. That precondition was written
for a minor, where clean-first was the only protection; under a frozen alias the per-repo
bump PR *is* the cleanup window, and requiring fleet-clean-first would mean doing all nine
repos' work before any of them could opt in.

### 3.4 What breaks

An OS repo's CI, on the commit where that repo bumps its own pin to `@v8` — and not
before. Each repo's bump PR must therefore also delete its duplicated Core-owned blocks,
stop reading undeclared `HAVE_*` flags, and declare `os/*.capabilities` if it somehow
still has not. §8 is the per-repo runbook.

**Every caller of this workflow is alias-pinned, which is what makes §3.2's argument hold
uniformly.** Measured across the cloned fleet, all of `dotfiles-Alpine`, `-Arch`,
`-Defense`, `-Fedora`, `-Gentoo`, `-Offense` and `-openSUSE` pin `lint-call.yml@v7`;
none SHA-pins it. `dotfiles-Defense` SHA-pins only its `auto-tag` caller, which these
legs do not touch. So no repo gets these flips through `sync-core.sh`'s automatic pin
move (`#482`) — each one arrives by a deliberate edit, which is the whole design.

**`dotfiles-Windows` calls none of these legs. Neither does `dotfiles-MacBook`** — it runs
its own `ci.yml` and does not call `lint-call.yml` at all. That is worth stating plainly,
because `ARCHITECTURE.md` names MacBook the reference implementation and
`RELEASE-STRATEGY.md` makes it the canary that every rollout bakes on first: **the canary
cannot canary a gate it does not run.** For this release the first repo to actually
exercise the flips is whichever OS repo bumps second. Either MacBook adopts the caller —
which is a `v8`-shaped change and would make its exemption from the Core-owned-block leg
checkable for the first time — or §8's rollout order names a different canary for §3, and
says why. This proposal recommends the former and does not assume it.

## 4. Change 2 — `bootstrap.sh` becomes a hook

### 4.1 Current

`lib/bootstrap-lib.sh` is 1,576 lines and 28 `blib_*` helpers, and the fleet's adoption of
it is tracked by `audit-core.sh` §5f as a **ratchet**, not a gate: a repo that drops a
helper fails, a repo that adopts an unrecorded one fails, and an unclaimed gap is merely
reported. The ledger (`scripts/audit-core.sh:1155-1162`) is the roadmap's thesis in one
table:

| helper | repos that call it |
| ------ | ------------------ |
| `blib_resolve_su` | Gentoo — **1/9** |
| `blib_note_fail` | Gentoo — **1/9** |
| `blib_failures_report` | Gentoo — **1/9** |
| `blib_sudo_keepalive_start` | Gentoo — **1/7** (both role repos exempt) |
| `blib_user_bindirs_on_path` | 7/8 (MacBook short; Defense exempt) |
| `blib_wire_summary` | 8/9 (MacBook short) |
| `blib_install_core_guard` | 7/9 (Defense, openSUSE short) |
| `BLIB_DRY` | 9/9 |

**Four helpers sit at 1/9, all of them adopted by `dotfiles-Gentoo` alone.** Core has
written the shared implementation four times and the fleet has taken it once.

`dotfiles-MacBook` — the repo `ARCHITECTURE.md` names the **reference implementation**,
synced first as the canary — is absent from four of the eight rows and carries its own
`fail_note` / `print_ledger` instead. It is also the size outlier, and the spread has
**widened** since `V5-PROPOSAL.md` §11 deferred this work:

```text
MacBook 1604   Gentoo 1312   Fedora 795   openSUSE 667
Alpine   660   Offense 596   Arch    418   Defense  270
```

MacBook was 1,505 lines when the v5 proposal measured it. Nothing was done, and it grew.

**Core already knows what a 1/9 reading costs.** `#748` is exactly that story:
`blib_user_bindirs_on_path` sat at 1/9 in an advisory report while the gap it named
shipped a live defect — openSUSE's `bootstrap.sh` probed for a `mise` that `mise.run` had
just written to `~/.local/bin`, a directory only the *shell* layer prefixes, so both arms
of its Go fallback missed and the run exited 2 on **every** bootstrap. The v7.0.0
changelog drew the conclusion in one sentence: **"A number nothing acts on is where a
defect hides in plain sight."** `#867` then recorded that four more helpers sit at the
same 1/9 — *"the same reading that preceded #748."*

### 4.2 Proposed

Drive provisioning from Core and leave each OS repo a declaration plus a hook.

Concretely, in the order the evidence supports:

1. **Ratchet the four 1/9 helpers to the fleet.** `blib_resolve_su`,
   `blib_note_fail`, `blib_failures_report` and `blib_sudo_keepalive_start` are already
   written, already tested and already proven in Gentoo. Adoption is per-repo and the
   §5f ledger tightens one line at a time. This is the whole of the change that is
   *ready*, and it is not breaking.
2. **Bring MacBook to the contract.** It is the canary and the template, and it is the
   least adopted. Retiring its private `fail_note` / `print_ledger` in favour of
   `blib_note_fail` / `blib_failures_report` is the single highest-value row in the
   ledger.
3. **Define the per-repo hook** for what genuinely remains OS-specific after (1) and (2).
   §4.4 is the open decision about what shape that takes.

### 4.3 What breaks

Steps (1) and (2): nothing a host uses. They are OS-repo-internal refactors behind
helpers Core already ships, and §5f's ratchet is the mechanism that lands them
incrementally. They ride in this release because the per-repo bump PR is already open for
§3 — not because they need a major.

### 4.4 The open decision: does the hook become an overlay?

Two shapes, and they differ in bump class, not just design:

- **Repo-internal hook** — each `bootstrap.sh` keeps a small, named function that Core's
  driver calls. Nothing new is linked; nothing on a host changes meaning. **MINOR**, and
  §3 alone carries the major.
- **Declared overlay** — provisioning facts become data in a file `blib_link_os_layer`
  symlinks into `$ZDOTDIR`, the way `os.capabilities` already is. **MAJOR**: every host
  must run `./bootstrap.sh --links-only` before the declaration is live.

**Recommendation: the repo-internal hook, unless a concrete consumer for a new overlay
emerges.** A smaller claim that is true beats a larger one that is not, and §2 is this
document's own demonstration of the cost of the reverse. If provisioning data genuinely
needs to be readable by something other than `bootstrap.sh`, extending the existing
`os.capabilities` file is the cheaper answer than a second overlay — it is already
KEY=value, already read-never-sourced, already linked, and already validated by
`scripts/check-capabilities.sh`.

**And the sequencing constraint from v5 applies either way.** `ARCHITECTURE.md` records
why `#667` (author the declarations) and `#763` (delete the fallbacks) had to be two
separate releases: what a box reads is a **symlink**, and only `bootstrap.sh` creates it,
so between the two events the declaration exists in the repo and not on the machine. If
§4.4 chooses the overlay, then authoring it is `v8` and depending on it is `v9` — and the
gate for the second is evidence that the fleet has **re-bootstrapped**, which neither
`make fleet-drift` nor `audit-core.sh` can supply, because both report whether a repo
*declares* and what matters is whether a *box has relinked*.

## 5. Change 3 — the audit gets the `#699` treatment

### 5.1 Current

`scripts/audit-core.sh` is **3,059 lines** and **47 sections** in one file, plus 2,353
lines of analysis engines in `scripts/lib/common.sh` — 5,412 lines for one gate. Its
section identifiers, in the order the file defines them:

```text
1 1c 1d 1e 1b 1c 2 3 4 4b 5 5b 5c 5d 5e 5k 5f 5g 5h 5i 5j 5m 6 7 8 8a 8b 8c 8d
9 9a 9c 9b 9d 9e 9f 9g 9h 9i 9j 9k 9l 9m 9n 9o 9p 10
```

- **`1c` is defined twice** — "vendor allowlist ↔ filesystem" at `:442` and "unreferenced
  `.claude/` files" at `:634`. Two unrelated gates, one identifier.
- `1b` runs after `1c`, `1d` and `1e`. `5k` runs between `5e` and `5f`. `9c` runs before
  `9b`.
- `5l` is deliberately skipped, and the file says why: *"§5l is free; this is 5m so the
  letter matches the file's own reference in `core.vendor`."* The identifier is pinned to
  an external document rather than to sequence.
- The `§9` family is **17 sections deep**.
- The file's own header index documents roughly 25 of the 47. `CLAUDE.md` describes the
  range as "§1..§9l"; `§9m`, `§9n`, `§9o` and `§9p` all exist.

This is, precisely, the state `scripts/test-core.sh`'s own header cites as the reason for
the `#699` split: *"the sections were lettered A–L, the letters had drifted into two
different 'E's and an A that ran after J."* Core solved this once, one file ago.

**And the other half of `#699`'s argument applies here too, measurably.** That split was
driven first by cost, not tidiness: *"shellcheck's cost grows superlinearly with file
length"*, and one 18,700-line file was 42.6s of the audit's 65.9s of ShellCheck, paid on
all four CI legs by any PR touching any shell file. `audit-core.sh` is a sixth that size,
so the effect is smaller — but it is not gone. Splitting this file into four equal parts
and linting them separately costs **698 ms against the whole file's 2,405 ms**: the same
3,059 lines, same rule set, **3.4x cheaper**. That is paid on every leg of every PR that
touches any shell file in the repo.

### 5.2 Proposed

The same answer, because it is already proven: `scripts/audit/NN-name.sh` fragments
globbed in `NN` order and **sourced** into one shell by a thin `audit-core.sh` dispatcher
— one `$SANDBOX`, one set of counters, one summary, no registry to update. The `NN-`
prefix replaces the letter suffixes, so ordering becomes the file name and the duplicate
`1c` cannot recur. `scripts/test/05-suite-shape.sh` is the precedent for the shape gate
that keeps a fragment from being added without its prefix.

Two constraints the split must respect:

- **Do not move analysis engines out of `scripts/lib/common.sh`.** It is in `core.vendor`
  and `dotfiles-MacBook` sources it directly. Moving `_core_return_trap_hits` would break
  a consumer; moving *sections* out of `audit-core.sh` breaks nobody.
- **The comments are the artifact.** `audit-core.sh` is 48% comment and that prose carries
  rationale, issue numbers, measurements, and the "why it blocks vs reports" policy that
  exists nowhere else. It travels with its section; it does not get summarised away.

### 5.3 What breaks

Nothing outside this repo. `scripts/audit-core.sh` is not in `core.vendor` and not in
`core.manifest`; it ships to no machine. `make audit`, `make audit-changed`, the
pre-commit hook and `ci.yml` all keep calling the same path. It rides along because a
major is when the fleet re-reads its own tooling, not because it needs one.

## 6. Ride-alongs

These break nothing and need no migration. They land with the major because a major is
when the fleet re-reads its own documentation.

- **`lint-call.yml:571`'s `ADVISORY IN THIS RELEASE, BLOCKING IN THE NEXT` comment is
  stale.** `#592`/`#651` flipped the markdownlint leg to blocking on 2026-08-24; the step
  no longer warns, and the measured per-repo backlog in that comment block is now a
  historical record presented as a live one. Exactly the drift class `/doc-audit` exists
  to catch.
- **`CLAUDE.md` says the audit runs "§1..§9l".** Four sections past that exist.
- **`V5-PROPOSAL.md`'s status header is wrong.** It records `#690` and `#694` as *"still
  open"*; both are closed (`#694` in v7.0.0, and `PORTABILITY.md` §5 is the surface it
  declared). With §10's milestone findings, that file becomes a fully closed record.
- **The behavioral suite takes 25 minutes locally, and `#467` has been re-opened with the
  measurements.** That issue — *"`scripts/test-core.sh` hangs on macOS, so neither `make
  test` nor `make core-audit` can be run locally on the fleet's canary platform"* — was
  closed `not_planned` on a diagnosis that does not hold: the suite **does not hang**. On
  Darwin 25.6.0 at `7.3.0` it completes, `pass 2074 skip 6 fail 0`, in **1,536s**.
  `--scope none` is **1,119s** and is not the workaround it looks like. A single fragment,
  `scripts/test/52-atuin-autostart.sh`, is **61.5%** of the full run — not for atuin work,
  but because its `--json` contract fixture runs the whole suite against itself **twice**
  (`:1272`, `:1295`) at 372s a time, while its own comment at `:1255` calls that *"the
  cheapest scope, a few seconds."* Both nested runs capture their output, so the parent
  emits nothing for 15.8 minutes, which is what every report of a "hang" has actually
  been looking at. Worth naming against §5: the gate whose instruction is *"green it
  before you push"* costs 25 minutes on the canary platform, and 83% of even its cheapest
  scope is five fragments no scope gates.
- **`RELEASE-STRATEGY.md` promises a "predictable monthly rhythm."** The tag history says
  otherwise: 84 tags and **seven majors** since 2026-06-18, the last four majors within
  ten days of each other. Either the cadence claim moves to match the practice or the
  practice is deliberate and the doc should say what it actually is.

## 7. Combined blast radius

A host reaches `v8` only through the three independent opt-in gates
`RELEASE-STRATEGY.md` §"Safe deployment" defines — nothing is pushed:

1. Merged, audited green, and **tagged** `v8.0.0` in `dotfiles-core`.
2. The OS repo **merges its bump + fan-out PRs**.
3. The host **re-bootstraps** — required only if §4.4 chooses the overlay.

Skip any gate and the host stays on `v7.x`. Roll back per OS by reverting that repo's
adoption commit.

Costs specific to this major:

- **The `@v7` → `@v8` caller sweep.** `audit-core.sh` §9n reads each sibling's live
  `uses:` and reds `make audit` until it completes, so this one reports itself — but only
  where the fleet is cloned beside Core, otherwise it records an environment SKIP.
  `dotfiles-MacBook` and `dotfiles-Defense` SHA-pin *and* sit inside the fan-out, so
  `sync-core.sh` moves their pins in the same commit that stamps `core.lock` (`#482`) and
  they need no hand bump.
- **`dotfiles-Windows` is the one hand bump no gate catches.** It vendors no `core/`, is
  deliberately absent from `scripts/os-repos.txt`, and SHA-pins its `auto-tag` caller —
  currently at `f431e8ac`, i.e. `v7.2.0`. Nothing advances it automatically. `#805`
  records the cost of forgetting: *a full major behind, for five releases.* It is the one
  repo where "checked" has to mean a person looked.
- **Core's own in-tree `v7` strings**, roughly thirty of them, across three always-on
  gates keyed off `core.version`'s major: §8a (`ref: v7` keys in Core's own workflows),
  §8a-bis (the copyable `@v7` caller examples in workflow headers) and §8a-ter (the
  first-vendor pin recipes in `ARCHITECTURE.md`, `VENDORING.md`, `PORTING-MATRIX.md`,
  `sync-core.sh` and `new-os-repo.sh`). All three red automatically on the version bump.
- **The ordering rule.** `RELEASE-RUNBOOK.md`: *if the major changes what
  `core_lock_expected_tree` returns, the caller bump MUST precede the fan-out merge* —
  otherwise the outgoing major's verifier reports `TAMPERED` and the fan-out PR cannot
  merge, as measured at `v6.0.0`. **This release does not change it** (§5 touches no
  vendored path), but the sweep runs first anyway, because bump-first is safe in both
  directions.

## 8. Per-repo migration runbook

For each repo in `scripts/os-repos.txt`, after `v8.0.0` is tagged — `dotfiles-MacBook`
first as the canary, then the rest:

1. **Bump the callers** — `@v7` → `@v8` in that repo's `.github/workflows/*-call.yml`
   `uses:` lines. This is step 1, before the fan-out PR merges.
2. **In the same PR, clear what the newly-blocking legs will catch:**
   - delete any Core-owned block the repo re-implements (the leg names the lines);
   - stop reading any `HAVE_*` flag outside `core/zsh/have-api.txt`'s declared surface;
   - confirm `os/*.capabilities` exists and validates under `make check-capabilities`.
3. **Merge the fan-out PR** — `sync-fanout.yml` opens `sync/core-v8.0.0` automatically.
   It opens PRs; it never merges.
4. **Adopt the ratcheted helpers** where §4.2 names a gap for that repo, and tighten the
   §5f ledger line in Core in the same pass.
5. **Re-bootstrap** — only if §4.4 chose the overlay. Then `make test-repo` where the repo
   has one.
6. **Verify** — `make fleet-drift` in Core confirms convergence, `make core-integrity` is
   clean, and `core status` on a real box reports the right OS layer.

**`dotfiles-MacBook` is the canary for the rollout but not for §3** — it calls no
`lint-call.yml`, so steps 1 and 2 above are no-ops there for the flipped legs and its bake
period proves nothing about them (§3.4). Either it adopts the caller in this release, or
step 2's first real exercise is the second repo in the order — pick one deliberately and
record which.

**`dotfiles-Windows`** vendors no `core/` and receives no sync PR. Its pin is moved by
hand, and it is invisible to `fleet-drift`.

## 9. CHANGELOG entry

The breaking entries land under `## [Unreleased]` in `CHANGELOG.md` — that file is the
single source of truth — and move under a `## [v8.0.0]` heading when the release is cut.
They are deliberately **not** duplicated here, to avoid the two-copies drift v4 and v5
both refused.

`tag-release.sh` refuses to cut a release whose section carries a `**BREAKING` bullet or a
`BREAKING CHANGE:` footer unless the version is `X.0.0`, and it has no bypass. If §4.4
lands on the repo-internal hook, §3 is the only section that writes such a bullet — and it
must, or the `v8` alias would never be minted and the flips would fan out onto `@v7`
callers, which is the precise failure that check exists to prevent.

## 10. Non-goals and open questions

**Findings about the roadmap itself**, which should be settled before v8 is scheduled:

- **The "one source, generated outward" milestone has already shipped, and should be
  closed rather than scheduled.** All five of its named inputs are closed — `#679`
  (palette), `#685` (`aliases.md`), `#686` (`PORTING-MATRIX.md`), `#682`/`#693` (the
  PARITY pair) — and the generators plus their gates `§9d`, `§9g`, `§9h`, `§9i` and `§9j`
  are live. It predicted it would need a major because *"hand-edits to those files stop
  being possible"*; in the event every input was additive on its own and shipped as a
  minor. The milestone was right about the destination and wrong about the bump class.
- **The load-chain renumbering milestone has not triggered.** Its stated trigger is a
  **fourth layer** needing a band; none exists. Its real deliverable — band *ownership*
  metadata — remains unbuilt and unforced: `zsh/loader.zsh` has no owner metadata, 56 of
  70 Core slots are free, and since `#677` deleted `CORE_PROFILE` a squatted band number
  is merely unconventional rather than silently destructive.

**Non-goals (deliberately out of this major):**

- **The non-mutable host.** Atomic and declarative targets (Silverblue/bootc,
  Aeon/MicroOS, NixOS) break the `os.capabilities` **schema** rather than adding a
  backend, so all nine repos re-author their declaration. It is the only roadmap theme
  with an external forcing function — *"whether this lands well decides whether the fleet
  is still installable on a 2031 desktop"* — and it is the right **next** major. It is out
  of this one because no work has started and the design needs research first, not because
  it is less important. It is, in fact, more.
- **The nvim split.** ~6,400 LOC and ~51 plugins inside a repo whose single gate is a
  shell audit, deferred in v4, in `V5-PROPOSAL.md` §11, and again. It cannot be scheduled
  until the decision it is waiting on is made — **extract** to a `dotfiles-nvim` vendored
  the way Core is (the seam is half-cut: `dotfiles-Windows` already mirrors `nvim/` via
  `nvim-sync.ps1`), or **freeze** it against a pinned Neovim. Three deferrals is the
  signal that it needs its own release, not a fourth ride-along slot — so it does not get
  one here.
- **Retiring the bare verb names** (`up`, `serve`, `gsync`, `maint-*`). `#692` closed
  `not_planned` with an explicit revisit condition: **evidence of a real collision**, not
  a fresh aesthetic objection. No such evidence has appeared. Unchanged.
- **`bootstrap.sh` consolidation beyond §4.2's ratchet.** The full collapse is real work
  and §4.4 may well make it a `v9` item; what ships here is the part that is ready.

**Open questions:**

1. **§4.4 — repo-internal hook or declared overlay?** The recommendation is the hook, and
   it decides whether this release is a major on §3 alone or on §3 and §4 together.
2. **`CHANGELOG.md`: dropped or promoted?** `V5-PROPOSAL.md` §9 recorded this and declined
   to settle it. It is now decidable: `#680` shipped, `core whatsnew` exists, and
   `CHANGELOG.recent.md` is in `core.vendor` as its backing store while the full 947 KB
   `CHANGELOG.md` is repo-meta. The question is therefore already answered in the tree —
   what remains is deleting the sentence in `V5-PROPOSAL.md` that says it is open.
3. **Does the `core.vendor` consumer list get rationalised or transcribed?**
   `V5-PROPOSAL.md` §11 asked this and it was **left unfound**. Only Alpine calls
   `verify-atuin-guard.sh`; only MacBook sources `scripts/lib/common.sh`;
   `scripts/check-links.sh` is vendored with **no caller yet, deliberately**. Some of
   those are probably accidents, and every major is another moment to find out.
