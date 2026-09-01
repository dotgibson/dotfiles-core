# Fleet auth: retiring the cross-repo PATs with a GitHub App (G2)

This is the runbook for replacing the two broad, silently-expiring Personal Access
Tokens the fleet's automation depends on with a **GitHub App** that mints
**short-lived, per-repo-scoped installation tokens** at run time. It is written so the
repo owner can execute it end to end — the App registration and the private-key
handling are owner actions that cannot be automated from CI.

**Status: shipped.** Every consumer mints App tokens, both PATs are deleted, and the
`token-health` probe that guarded their expiry has been retired — a minted token lives
~1 hour and cannot silently expire, so there was nothing left for it to watch. This
document is retained as the reference for how the auth works and how to extend it.

> **Deletion verified 2026-09-01** (#683), because this file used to assert it in one
> place and contradict it 157 lines later. `FLEET_SYNC_TOKEN` and `WEBHOOK_SECRET` are
> absent from **all twelve fleet repos**, at repo *and* org scope; the only org secrets
> the fleet can see are `FLEET_APP_PRIVATE_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`, and
> `FLEET_APP_ID` is an org variable. Re-check with:
>
> ```sh
> gh api repos/dotgibson/<repo>/actions/secrets              --jq '.secrets[].name'
> gh api repos/dotgibson/<repo>/actions/organization-secrets --jq '.secrets[].name'
> ```
>
> Needs an admin token, or the empty listing is a permissions artefact rather than a fact.

## What we replaced, and why

Two secrets *were* long-lived PATs with broad scope and no automatic rotation. Both are
now deleted; the table is the historical record of what the App had to take over:

| Secret (deleted) | Was used by | What it authorised |
| --- | --- | --- |
| `FLEET_SYNC_TOKEN` | `dotfiles-core` `sync-fanout.yml`, `htpx` `sync-fanout.yml` | Clone another repo, push a `sync/…` branch, and open a PR (contents + pull-requests + workflows **write** on the OS repos and `dotfiles-Offense`). Workflows is needed because the sync branch can carry `.github/workflows/*` pin moves — see Step 1. |
| `WEBHOOK_SECRET` | every source repo's `notify-web.yml` (via `notify-web-call.yml`) | A `Bearer` token POSTing a `repository_dispatch` to `dotfiles-web` to trigger a docs rebuild (contents **write** on `dotfiles-web`). |

Both are the same anti-pattern: a **single broad token**, held as a secret in many
repos, that expires on a date nobody is watching (the failure G2 closes). A GitHub App
fixes all three problems at once — tokens are **minted per run**, **scoped to just the
target repo(s) and permissions** each job needs, and **expire in ~1 hour**, so a leak or
a missed rotation is bounded.

## Step 1 — register the App (owner action, one time)

In **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**:

- **Name:** `dotgibson-fleet-sync` (any unique name).
- **Homepage URL:** the org URL (unused, but required).
- **Webhook:** **uncheck** "Active" — this App is used only to mint tokens, it receives
  no events.
- **Repository permissions** (least privilege — grant only these):
  - **Contents: Read and write** — the `git push` of the sync branch, and the
    `repository_dispatch` POST both require it.
  - **Pull requests: Read and write** — `gh pr create` for the fan-out PRs.
  - **Workflows: Read and write** — since
    [#482](https://github.com/dotgibson/dotfiles-core/issues/482) the fan-out moves each
    repo's reusable-workflow SHA pins in the same commit that stamps `core.lock`, so the
    sync branch can contain `.github/workflows/*` changes. GitHub refuses **any** push
    from an App that touches a workflow file without this grant — `Contents: write` is
    not enough — and it refuses the whole push, not just that file.
  - Everything else: **No access**.

> **This one is not optional, even though only some repos need it.** Only repos that
> SHA-pin a Core caller (`dotfiles-MacBook`, `dotfiles-Defense`) ever have a workflow file
> in their sync branch — but the permission is a property of the **App**, not of a repo, so
> without it those repos fail every fan-out. That is not hypothetical: the v4.12.1 fan-out
> was refused on `dotfiles-MacBook` with *"refusing to allow a GitHub App to create or
> update workflow `.github/workflows/auto-tag.yml` without `workflows` permission"*.
>
> **Changing permissions on an existing App requires the installation to accept them.**
> GitHub emails the owner a review request; until it is approved the token is still minted
> with the OLD permission set and the pushes keep failing with the same message. After
> approving, confirm on the App's **Install App → ⚙ → Permissions** page rather than
> assuming the edit took.

- **Where can this App be installed?** **Only on this account.**

Create it, then note the **App ID** (shown on the App's page). Under **Private keys**,
**Generate a private key** and download the `.pem` — you will paste its contents into a
secret in Step 3. Store the `.pem` in your password manager and delete the download.

## Step 2 — install the App on the target repos

On the App's page → **Install App** → install on **`dotgibson`**, and select **only the
repos that RECEIVE cross-repo writes**:

- The Core-vendoring OS repos + `dotfiles-Offense` (targets of `dotfiles-core`'s fan-out).
- `dotfiles-Offense` (target of `htpx`'s companion fan-out — already in the list above).
- `dotfiles-web` (target of the `notify-web` dispatch).
- **`dotfiles-core`** — for its own **self-PRs**: `freshness.yml` opens a pin-bump PR *in
  Core*, and a PR opened by `GITHUB_TOKEN` has its CI held at `action_required` (GitHub's
  recursion guard). Installing the App here lets freshness open that PR as the App bot, so
  its CI runs without a manual "Approve and run". Without this install the mint step is
  skipped/fails and freshness falls back to `GITHUB_TOKEN` — the PR still opens, it just
  needs the one-click approval. (Core is the one repo that is both a *source* and a *target*.)

Aside from that one self-PR case, the App does **not** need to be installed on the *source*
repos (`htpx`, and `dotfiles-core` for its *fan-out* minting) — those only mint tokens whose
reach is decided by the installation on the *other* repos.

## Step 3 — store the credentials on the source repos

The **minting** happens in `dotfiles-core` and `htpx` (and, for `notify-web`, in every
source repo that dispatches). On each repo that runs a workflow which mints a token, set:

- **Variable** (not secret — the App ID is not sensitive): `FLEET_APP_ID` = the App ID
  from Step 1. Repo → Settings → Secrets and variables → Actions → **Variables**.
- **Secret**: `FLEET_APP_PRIVATE_KEY` = the **full contents** of the `.pem` (including the
  `-----BEGIN/END-----` lines). Repo → Settings → Secrets and variables → Actions →
  **Secrets**.

Using a *variable* for the App ID is deliberate: variables are readable in a job `if:`,
which is what makes the migration backward-compatible (Step 4).

## Step 4 — the workflow pattern (backward-compatible)

> **Historical — the original rollout PLAN, not a record of what ran, and not a template.**
> Steps 4 and 5 are the migration as it was *planned*; for what actually happened, and the
> one step still outstanding, read the retirement record at the end of Step 5. They differ:
> Step 5 prescribes dropping the `WEBHOOK_SECRET` secret input, and that has **not** been
> done — it is deferred to #819. The `|| secrets.…` fallback prescribed below *has* been
> removed (#683): the live workflows read `${{ steps.app.outputs.token }}` alone, and the
> secrets it names no longer exist, so copying Step 4 verbatim would reintroduce a dead
> secret reference. **A new consumer** takes only the mint step and reads the bare
> `${{ steps.app.outputs.token }}`. The fallback shape is retained here for exactly one
> reason: it is the pattern the emergency re-provisioning in *Rollback* restores.

Replace each `secrets.FLEET_SYNC_TOKEN` / `secrets.WEBHOOK_SECRET` use with a minted
token, **falling back to the legacy PAT** so the change is inert until the App is
configured. Mint with the first-party **`actions/create-github-app-token`** action —
which, like every external action, must be **pinned to a 40-hex commit SHA** (the
modernization floor; `actions/` is not the fleet's exempt owner). Resolve the SHA for the
latest release yourself — the CI environment cannot reach the Actions API to look it up:

```sh
gh api repos/actions/create-github-app-token/git/refs/tags/v2 --jq .object.sha
# (dereference to the commit if it returns an annotated-tag object)
```

Then, in the job:

```yaml
    steps:
      # Mint a short-lived token scoped to JUST the target repo — only when the App is
      # configured (vars are readable in `if:`; secrets are not). No App yet → skipped,
      # and the job falls back to the legacy PAT below, so merging this changes nothing
      # until you complete Steps 1-3.
      - name: Mint a scoped installation token
        id: app
        if: ${{ vars.FLEET_APP_ID != '' }}
        uses: actions/create-github-app-token@<PIN-40-HEX-SHA> # vX.Y.Z
        with:
          app-id: ${{ vars.FLEET_APP_ID }}
          private-key: ${{ secrets.FLEET_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: dotfiles-Offense # scope to the one target this job writes to

      # ... then wherever the job used the PAT, prefer the minted token:
      #   env:
      #     GH_TOKEN: ${{ steps.app.outputs.token || secrets.FLEET_SYNC_TOKEN }}
      # and for the git credential rewrite (GIT_CONFIG_VALUE_0 etc.), use the same
      # `${{ steps.app.outputs.token || secrets.FLEET_SYNC_TOKEN }}` expression.
```

Prefer the `||` expression **inline in `env:`** rather than writing the token to
`$GITHUB_OUTPUT` — a token in an output can surface in logs; a secret in `env` is masked.

## Step 5 — migrate the consumers, verify, then retire the PATs

Roll it out one consumer at a time, canary first, verifying a real run each time:

1. **`dotfiles-core/.github/workflows/sync-fanout.yml`** — the reference case (lives here;
   `make audit` / `check-modern.sh` validate the pinned action). Scope `repositories:` to
   the OS repo(s) a given run targets.
2. **`htpx/.github/workflows/sync-fanout.yml`** — same pattern, `repositories: dotfiles-Offense`.
3. **`notify-web-call.yml`** (reusable) — mint a `dotfiles-web`-scoped token and use it as
   the `Bearer` for the `dispatches` POST; drop the `WEBHOOK_SECRET` secret input. Fan the
   caller change out to every source repo's `notify-web.yml`.
   **Status: partly done.** The mint and the `Bearer` landed; dropping the secret input is
   **still outstanding** (#819) — see the retirement record below. Do not read this line as
   a completed step.

**Verify** after each: trigger the workflow (a real fan-out / a `refresh` dispatch) and
confirm the cross-repo write still lands. Because the token is minted per run and scoped to
the target, the repo/org **audit log** shows exactly what it did (the App has no webhook —
Step 1 — so there are no "recent deliveries" to consult, and minting a token via the REST
API generates none regardless).

**Retired — done.** For the record, in the order it happened:

- Both secrets **deleted** from every repo (verified 2026-09-01, above).
- `token-health.yml` **dropped** — a minted token cannot silently expire.
- The `|| secrets.…` fallbacks **removed — in `dotfiles-core` only** — from
  `sync-fanout.yml`, `notify-web.yml` and `notify-web-call.yml`, and `release.yml` no
  longer passes `WEBHOOK_SECRET` (#683). They had been dead code resolving to the empty
  string since the secrets were deleted.
  **This list is Core-local and is not the fleet's state.** Copies elsewhere still carry
  the dead fallbacks — `htpx/sync-fanout.yml`, `dotfiles-Windows`' inline `notify-web.yml`,
  and `dotfiles-web/fleet-sync.yml`'s three-way expression. They are tracked in #819; do
  not read the bullet above as covering them.
- **One item outstanding:** `notify-web-call.yml` still *declares* a `WEBHOOK_SECRET`
  secret input. Nothing reads it. It cannot simply be deleted, because the fleet's nine
  OS-repo callers still pass it and pin the **moving `@v6` alias** — so the removal would
  reach all of them the moment `make publish` advances `v6`. Same hazard as
  `RELEASE-RUNBOOK.md` §2's rule that *the caller bump MUST precede the fan-out merge*.
  Bump the callers first (#819), then drop the input on the next MAJOR.

**Rollback is not a toggle — there is nothing to fall back to.** Unsetting `FLEET_APP_ID`
does **not** restore service: it disables the mint, and with the PATs gone that means
`sync-fanout.yml`'s preflight fails the fan-out outright and the `notify-web` dispatch
degrades to a `::warning::` naming the missing App credentials, then skips the refresh and
exits 0. (Described rather than quoted on purpose: there are two wordings — the inline
dispatcher names this repo's own variable/secret, the reusable names the ones its CALLER
failed to pass — and a copied string here is one more thing to go stale, #823.)
Recovering off the App is a deliberate **re-provisioning**, not a switch — and doing it
during an incident is the worst time to discover that, which is why this says so here:

1. Mint a fine-grained PAT with the scopes in the table above (`FLEET_SYNC_TOKEN`:
   contents + pull-requests + workflows write on the OS repos and `dotfiles-Offense`;
   `WEBHOOK_SECRET`: contents write on `dotfiles-web`).
2. Add it under that name **with visibility covering every repo that needs it** — naming
   the secret is not sufficient. A *repo* secret exists only in that one repository, and an
   *org* secret can be scoped to selected repositories; either choice can leave another
   source repo's workflow reading an empty string even after step 4 restores its `secrets:`
   mapping. `WEBHOOK_SECRET` is needed by every repo that dispatches (Core plus the nine
   OS repos, and `dotfiles-Windows`); `FLEET_SYNC_TOKEN` by `dotfiles-core` and `htpx`. An
   org secret set to *all repositories* is the one option that cannot half-apply.
3. Restore the `|| secrets.…` expressions — Step 4 above is the exact pattern.
4. **Restore each caller's `secrets:` mapping.** A reusable workflow does *not* inherit
   its caller's secrets: `notify-web-call.yml` can only see what the caller hands it, and
   `release.yml` now passes `FLEET_APP_PRIVATE_KEY` alone. Restoring the expression inside
   the reusable workflow without re-adding
   `WEBHOOK_SECRET: ${{ secrets.WEBHOOK_SECRET }}` to every caller — Core's `release.yml`
   and the nine OS-repo `notify-web.yml` files — leaves `secrets.WEBHOOK_SECRET` empty
   there no matter how the org secret is set. (`secrets: inherit` on the caller does the
   same job in one line.) `sync-fanout.yml` and Core's own inline `notify-web.yml` are not
   reusable workflows and need only step 3.
5. **Then unset `FLEET_APP_ID`**, or the restored expression will never choose the PAT.
   `steps.app.outputs.token || secrets.…` prefers the *left* side whenever it is
   non-empty, so an App that still mints — even an under-scoped one whose token 403s on
   the actual push — keeps winning; and an App that fails to mint fails the *step*, so
   execution never reaches the fallback at all. Unsetting the variable makes the mint
   step's `if:` false, which skips it, which finally leaves the output empty. Steps 3-5
   are ONE change: restoring the expression without also rewiring the callers and
   disabling the mint looks like a rollback and does nothing.

Prefer fixing the App: a failed mint is almost always the installation missing a repo, or
a **Workflows: write** permission change still awaiting approval (Step 1).
