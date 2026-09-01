# G2: retiring the fleet's cross-repo PATs (historical record)

> **Frozen record. Not maintained, and not a template.**
>
> This is what the G2 migration *planned* and what it *did*, kept because the reasoning
> is worth having and the fleet has re-learned these lessons before. It is **not** a
> description of how anything works now — for that, read
> [`GITHUB-APP-AUTH.md`](GITHUB-APP-AUTH.md), which is the live reference.
>
> **Do not copy the workflow patterns below into anything.** They prescribe
> `|| secrets.FLEET_SYNC_TOKEN` / `|| secrets.WEBHOOK_SECRET` fallbacks, and those
> secrets **no longer exist** — a job written from them would carry a dead reference that
> resolves to the empty string. The live pattern is in *Adding a new consumer* in the
> reference.
>
> This file was split out of `GITHUB-APP-AUTH.md` in #683, because the two lived together
> and the historical half kept being read as current. That is not hypothetical: the file
> asserted "both PATs are deleted" at the top and "still present until the retire step"
> 157 lines down, and the second sentence was a migration-era leftover.

## What was replaced, and why

Two secrets were long-lived PATs with broad scope and no automatic rotation. Both are now
deleted; this is the record of what the App had to take over:

| Secret (deleted) | Was used by | What it authorised |
| --- | --- | --- |
| `FLEET_SYNC_TOKEN` | `dotfiles-core` `sync-fanout.yml`, `htpx` `sync-fanout.yml` | Clone another repo, push a `sync/…` branch, and open a PR (contents + pull-requests + workflows **write** on the OS repos and `dotfiles-Offense`). Workflows was needed because the sync branch can carry `.github/workflows/*` pin moves. |
| `WEBHOOK_SECRET` | every source repo's `notify-web.yml` — most via the reusable `notify-web-call.yml`, but `dotfiles-core` and `dotfiles-Windows` carry inline copies | A `Bearer` token POSTing a `repository_dispatch` to `dotfiles-web` to trigger a docs rebuild (contents **write** on `dotfiles-web`). |

Both were the same anti-pattern: a **single broad token**, held as a secret in many repos,
expiring on a date nobody was watching. A GitHub App fixes all three problems at once —
tokens are **minted per run**, **scoped by repository** where the job passes
`repositories:`, and **expire in ~1 hour**, so a leak or a missed rotation is bounded. The
fan-out is the deliberate exception — it omits `repositories:` and takes an
installation-wide token; see the reference for why.

**What the rollout did NOT narrow, and this record should not imply it did:** none of the
migrated jobs passes `permission-*` inputs, so every minted token carries the
**installation's full grant set** (Contents + Pull requests + Workflows write) on whatever
repositories it covers. The bound achieved was lifetime and repository reach, not verbs.
Tightening that is #830.

## The rollout, as planned

The migration was designed to be **inert until the App was configured**, so it could land
before the credentials existed. Every consumer read
`${{ steps.app.outputs.token || secrets.<LEGACY_PAT> }}` with the mint step gated on
`vars.FLEET_APP_ID != ''` — no App, no mint, and the expression fell through to the PAT.
That backward-compatibility is the *only* reason the `||` form ever existed; it is also
why the App ID is a variable rather than a secret, since variables are readable in a job
`if:` and secrets are not.

It rolled out one consumer at a time, canary first, verifying a real cross-repo write each
time:

1. `dotfiles-core/.github/workflows/sync-fanout.yml` — the reference case.
2. `htpx/.github/workflows/sync-fanout.yml` — same pattern, scoped to `dotfiles-Offense`.
3. `notify-web-call.yml` (reusable) — mint a `dotfiles-web`-scoped token for the
   `dispatches` `Bearer`, then fan the caller change out to every source repo.

## What actually happened

In the order it happened:

- Both secrets **deleted** from every repo. Verified across all twelve, at repo *and* org
  scope, on 2026-09-01 (#683) — see the reference for the re-check command.
- `token-health.yml` **dropped**. It existed to catch a PAT silently expiring; a minted
  token lives ~1 hour and cannot, so there was nothing left for it to watch.
- The `|| secrets.…` fallbacks **removed** — from `sync-fanout.yml`, `notify-web.yml` and
  `notify-web-call.yml`, with `release.yml` no longer passing `WEBHOOK_SECRET` (#683).
  They had been dead code resolving to the empty string ever since the secrets were
  deleted, and the documented rollback that depended on them was a dead path.
- The same dead fallbacks **removed fleet-wide** (#819): `htpx/sync-fanout.yml`,
  `dotfiles-Windows`' inline `notify-web.yml`, `dotfiles-web/fleet-sync.yml`'s three-way
  expression, and the nine OS-repo callers that were still passing `WEBHOOK_SECRET`.
  `dotfiles-web`'s `docs/WEBHOOK-SETUP.md` — an eleven-repo walkthrough for minting the
  deleted PAT — was rewritten in the same pass. Verified after merge: none of the nine
  callers passes the secret on its default branch.

### The one step still outstanding

**As of this record (2026-09-01)**, the migration was complete except for removing
`notify-web-call.yml`'s declared `WEBHOOK_SECRET` input, which was deferred to a MAJOR.

**Whether that has since happened is not recorded here, deliberately.** A frozen file
stating "waits for the next MAJOR" goes stale the moment that MAJOR ships — the exact
drift this split exists to prevent. For the current status and the condition on removal,
see *One live constraint* in [`GITHUB-APP-AUTH.md`](GITHUB-APP-AUTH.md); if that section
is gone, the removal has landed.

## What this cost, and what stops a repeat

The defect that prompted the split was not the migration — it was that the document
describing it kept asserting things nothing checked. `make audit` now covers two of those
classes:

- **§8a** — every `ref:` naming a `dotfiles-core` checkout matches `core.version`.
- **§8a-bis** — every documented `@vN` caller example matches it too (#821), because at
  v5 → v6 every `ref:` moved and twenty-five `@v5` references survived in the prose
  describing them.

Both exist for the same reason this file is marked frozen: **a comment is not a gate**, and
a document is not a gate either. Anything in here that must stay true belongs in the
reference, under a check.
