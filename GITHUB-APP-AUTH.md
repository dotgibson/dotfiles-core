# Fleet auth: how the cross-repo GitHub App works

**This file is the live reference.** It describes the auth the fleet runs *today*, and
the two things you actually need it for: **adding a consumer**, and **recovering when
the App is not working**.

The migration that produced this — retiring two long-lived PATs (G2) — is a finished
piece of history and lives in [`GITHUB-APP-MIGRATION.md`](GITHUB-APP-MIGRATION.md). It is
a frozen record, not a template: the patterns it prescribes reference secrets that no
longer exist. Nothing here depends on reading it.

> **Why the split (#683).** These two concerns used to share one file, and they drifted
> apart: the top said both PATs were deleted, and a paragraph 157 lines down — inside a
> *migration* heading — said one was "still present", with the recovery procedure buried
> under it. An operator reaching for recovery during an incident had to read a historical
> runbook to find it, and what they found was wrong. Live and historical are separated so
> that a stale sentence in the record cannot masquerade as an operational instruction.

## What the fleet runs today

Every cross-repo write mints a **GitHub App installation token at run time**, expiring in
about an hour. **There are no long-lived PATs anywhere in the fleet, and no fallback behind
the App.**

**Two scoping shapes, and the difference is the real authorization boundary:**

- Most jobs pass `repositories:` and get a token good for **only that target** — the
  `notify-web` dispatch is scoped to `dotfiles-web`, and nothing else.
- **`sync-fanout.yml` deliberately omits it**, so its token covers the App's **entire
  installation** — every OS repo, `dotfiles-Offense`, `dotfiles-web` and `dotfiles-core`.
  That is intentional: hardcoding the fleet there would be a second copy of
  `scripts/os-repos.txt` that could drift and 403 a newly-added repo, so the installation
  list stays the one place scope lives. The trade is a broader token for that one job, and
  it is why the install list should stay minimal.

Two settings make it work, both at the **organization** level:

| Name | Kind | What it is |
| --- | --- | --- |
| `FLEET_APP_ID` | variable | the App's ID. A *variable*, not a secret — it is not sensitive, and variables are readable in a job `if:`, which is how the mint step gates itself |
| `FLEET_APP_PRIVATE_KEY` | secret | the App's `.pem`, in full, including the `-----BEGIN/END-----` lines |

> **Deletion verified 2026-09-01** (#683). `FLEET_SYNC_TOKEN` and `WEBHOOK_SECRET` are
> absent from **all twelve fleet repos**, at repo *and* org scope; the only org secrets
> the fleet can see are `FLEET_APP_PRIVATE_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`. Re-check
> rather than trusting this line — it is a fact about live infrastructure, and the reason
> this file exists is that such a line once went stale:
>
> ```sh
> gh api repos/dotgibson/<repo>/actions/secrets              --jq '.secrets[].name'
> gh api repos/dotgibson/<repo>/actions/organization-secrets --jq '.secrets[].name'
> ```
>
> Needs an admin token, or an empty listing is a permissions artefact rather than a fact.

## The permissions the App must hold

Least privilege — grant only these, and nothing else:

- **Contents: Read and write** — the `git push` of the sync branch, and the
  `repository_dispatch` POST, both require it.
- **Pull requests: Read and write** — `gh pr create` for the fan-out PRs.
- **Workflows: Read and write** — since
  [#482](https://github.com/dotgibson/dotfiles-core/issues/482) the fan-out moves each
  repo's reusable-workflow SHA pins in the same commit that stamps `core.lock`, so the
  sync branch can contain `.github/workflows/*` changes. GitHub refuses **any** push from
  an App that touches a workflow file without this grant — `Contents: write` is not
  enough — and it refuses the whole push, not just that file.
- Everything else: **No access**.

> **Workflows: write is not optional, even though only some repos need it.** Only repos
> that SHA-pin a Core caller (`dotfiles-MacBook`, `dotfiles-Defense`) ever have a workflow
> file in their sync branch — but the permission is a property of the **App**, not of a
> repo, so without it those repos fail every fan-out. Not hypothetical: the v4.12.1
> fan-out was refused on `dotfiles-MacBook` with *"refusing to allow a GitHub App to
> create or update workflow `.github/workflows/auto-tag.yml` without `workflows`
> permission"*.
>
> **It is also load-bearing with no safety net.** Since the PATs were deleted there is
> nothing behind this grant: a fan-out that loses it fails outright.
>
> **Changing permissions on an existing App requires the installation to accept them.**
> GitHub emails the owner a review request; until it is approved the token is still minted
> with the OLD permission set and the pushes keep failing with the same message. After
> approving, confirm on the App's **Install App → ⚙ → Permissions** page rather than
> assuming the edit took.

The App has **no webhook** (it only mints tokens), so there are no "recent deliveries" to
consult when debugging — and minting a token via the REST API generates none regardless.
The repo/org **audit log** is where a minted token's actions show up.

## Re-creating or re-keying the App

The App already exists; this is here for the two cases that need it — **rotating the
private key**, and re-creating the App if it is ever lost.

Registered under **GitHub → Settings → Developer settings → GitHub Apps** as
`dotgibson-fleet-sync` (any unique name), homepage set to the org URL (unused, but the
field is required), **Webhook → Active unchecked** (it only mints tokens and receives no
events), and **Where can this App be installed? → Only on this account.**

**The private key is the credential.** Under the App's **Private keys**, *Generate a
private key* downloads a `.pem`; its full contents — including the `-----BEGIN/END-----`
lines — become `FLEET_APP_PRIVATE_KEY`. **Store the `.pem` in a password manager and delete
the download.** Generating a new key does not revoke the old one: delete the superseded key
on the App's page, or rotation leaves two valid credentials.

The **App ID** is on the same page and becomes `FLEET_APP_ID`.

## Where the App is installed

Installed on **`dotgibson`**, on the repos something actually writes to — plus one
exception:

- **The Core-vendoring OS repos** (`scripts/os-repos.txt`) **and `dotfiles-Offense`** —
  targets of `dotfiles-core`'s fan-out. `htpx`'s companion fan-out targets
  **`dotfiles-Offense` only**, not the rest of that group.
- **`dotfiles-web`** — target of the `notify-web` dispatch.
- **`dotfiles-core`** — the exception, and **not** a cross-repo write: it is for Core's own
  **self-PRs**. `freshness.yml` opens a pin-bump PR *in Core*, and a PR opened by
  `GITHUB_TOKEN` has its CI held at `action_required` (GitHub's recursion guard).
  Installing the App here lets freshness open that PR as the App bot, so its CI runs
  without a manual "Approve and run".

The App does **not** need installing on the *source* repos that only mint (`htpx`, and
`dotfiles-core` for its *fan-out* minting) — a minted token's reach is decided by the
installation on the *other* repos. `htpx` in particular is read with the built-in token,
so do not add it.

## Adding a new consumer

Mint with the first-party **`actions/create-github-app-token`**, which — like every
external action — must be **pinned to a 40-hex commit SHA** (the modernization floor;
`actions/` is not the fleet's exempt owner). Resolve the SHA yourself; CI cannot reach the
Actions API to look it up:

```sh
gh api repos/actions/create-github-app-token/git/refs/tags/v3 --jq .object.sha
# (dereference to the commit if it returns an annotated-tag object)
```

Every consumer in this repo is on **v3.2.0**
(`bcd2ba49218906704ab6c1aa796996da409d3eb1`) — match them unless you are deliberately
moving the fleet, in which case move them together.

Then, in the job:

```yaml
jobs:
  your-job:
    env:
      # A secret cannot be tested in a step `if:`, but an env DERIVED from a secret
      # comparison can — and it never exposes the key, since the value is just
      # 'true'/'false'. The mint below gates on this. Omit it and `env.HAS_APP_KEY` is
      # empty, the `if:` is false, and the mint is ALWAYS skipped.
      HAS_APP_KEY: ${{ secrets.FLEET_APP_PRIVATE_KEY != '' }}
    steps:
      # Gated on BOTH the variable and the key. Either one missing skips the step — and a
      # skipped mint has nothing to fall back to, so guard for it below.
      - name: Mint a scoped installation token
        id: app
        if: vars.FLEET_APP_ID != '' && env.HAS_APP_KEY == 'true'
        uses: actions/create-github-app-token@<PIN-40-HEX-SHA> # vX.Y.Z
        with:
          app-id: ${{ vars.FLEET_APP_ID }}
          private-key: ${{ secrets.FLEET_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: dotfiles-Offense # scope to the one target this job writes to

      # Read the token inline in `env:` — never via $GITHUB_OUTPUT, where it can surface
      # in logs. A secret in `env` is masked. There is NO `|| secrets.…` fallback: the
      # PATs are gone, so an `||` here would only ever resolve to the empty string.
      - name: Do the cross-repo thing
        env:
          GH_TOKEN: ${{ steps.app.outputs.token }}
```

**Handle the two outcomes separately** — they are different failures and want different
responses:

- **No `FLEET_APP_ID`, or no key** → the mint step is **skipped** and the token is empty.
  Decide deliberately whether that is a clean no-op (a dispatch that can wait for the next
  push) or a hard error (a fan-out that must not half-run). Say which in the message, and
  name the missing credential rather than the App's behaviour.
- **The mint is attempted and the App cannot reach the target** → `create-github-app-token`
  **fails the step** and the job goes red before your code runs. You cannot catch this in a
  later guard, and you should not try to: a configured App that cannot reach its target is
  a misconfiguration, not something to swallow.

## One live constraint: the reusable's declared `WEBHOOK_SECRET`

`notify-web-call.yml` still **declares** a `WEBHOOK_SECRET` secret input, under
`on.workflow_call.secrets`. **Nothing reads it** — it is not part of the auth described
above, and no caller should pass it.

It is documented here, in the live reference rather than the historical record, because it
is a **current constraint on a future change**: it cannot be deleted until the next MAJOR.
Removing a declared secret is a **breaking change to the published `v6` reusable-workflow
contract**: a caller that passes a secret the reusable no longer declares fails workflow
validation. The nine OS-repo callers have stopped passing it (#819), which is what makes
the removal safe to schedule — but scheduling it is the whole point.

**A MAJOR does not push this onto existing callers, and that is exactly why it waits for
one.** Per `RELEASE-RUNBOOK.md` §1.1, a MAJOR mints `vN+1` and **leaves the outgoing `vN`
alias frozen** — precisely so a breaking change is not forced on callers still tracking it.
So `@v6` callers keep the contract they were published against, including this declaration,
and encounter the removal only when they **explicitly adopt `@v7`** — the deliberate,
reviewed caller sweep in §2 step 1. Deleting the declaration on a PATCH or MINOR would be
the harmful case, because there the alias *does* advance in place and every tracker would
take the change with no adoption step.

**Do not remove it as tidy-up.** It comes out on a MAJOR, paired with that caller bump.

## Recovery — re-provisioning off the App

**This is not a toggle, and unsetting `FLEET_APP_ID` does not restore service.** It
disables the mint, and with the PATs gone that means `sync-fanout.yml`'s preflight fails
the fan-out outright and the `notify-web` dispatch degrades to a `::warning::` naming the
missing credentials, then skips and exits 0.

**Fix the App first.** A failed mint is almost always the installation missing a repo, or
a **Workflows: write** change still awaiting approval. That is a minutes-long fix; the
procedure below is an hours-long one.

If you genuinely must run without the App, it is a deliberate **re-provisioning**. All
seven steps are ONE change — doing part of it looks like a rollback and does nothing:

1. **Mint fine-grained PATs** with the scopes the App holds — `FLEET_SYNC_TOKEN` needs
   contents, pull-requests and workflows write on the OS repos and `dotfiles-Offense`;
   `WEBHOOK_SECRET` needs contents write on `dotfiles-web`.
2. **Add each under that name, with visibility covering every repo that needs it.** Naming
   the secret is not sufficient. A *repo* secret exists only in that one repository, and an
   *org* secret can be scoped to selected repositories; either can leave another source
   repo reading an empty string even after step 6. `WEBHOOK_SECRET` is needed by every repo
   that dispatches (Core, the nine OS repos, and `dotfiles-Windows`); `FLEET_SYNC_TOKEN` by
   `dotfiles-core` and `htpx`. An org secret set to *all repositories* is the one option
   that cannot half-apply.
3. **Restore the fallback expressions**, replacing each bare read with the two-sided
   form. **The two paths take different secrets — copying one into the other restores the
   wrong credential:**

   ```yaml
   # dotfiles-core sync-fanout.yml — the cross-repo write path. FLEET_TOKEN also feeds
   # the `git config --global url."https://x-access-token:${FLEET_TOKEN}@github.com/"`
   # rewrite, so fixing these two env values covers git auth here as well.
   env:
     GH_TOKEN: ${{ steps.app.outputs.token || secrets.FLEET_SYNC_TOKEN }}
     FLEET_TOKEN: ${{ steps.app.outputs.token || secrets.FLEET_SYNC_TOKEN }}
   ```

   **htpx's fan-out wires git differently — read this before editing it.** It uses
   step-scoped `GIT_CONFIG_*` rather than `git config --global`, and **the token is
   interpolated into the KEY, not the value**:

   ```yaml
   # htpx sync-fanout.yml. GIT_CONFIG_VALUE_0 is the literal match URL — LEAVE IT ALONE.
   env:
     GH_TOKEN: ${{ steps.app.outputs.token || secrets.FLEET_SYNC_TOKEN }}
     GIT_CONFIG_KEY_0: "url.https://x-access-token:${{ steps.app.outputs.token || secrets.FLEET_SYNC_TOKEN }}@github.com/.insteadOf"
     GIT_CONFIG_VALUE_0: "https://github.com/" # unchanged
   ```

   Putting the fallback in `GIT_CONFIG_VALUE_0` looks plausible and does nothing: the
   rewrite keeps matching on an empty App token, and every clone and push goes out
   unauthenticated.

   ```yaml
   # notify-web.yml and notify-web-call.yml — the dispatch path.
   env:
     TOKEN: ${{ steps.app.outputs.token || secrets.WEBHOOK_SECRET }}
   ```

   Inline in `env:`, for the masking reason above.
4. **If a MAJOR has already removed the declaration, restore that first.** Once
   `on.workflow_call.secrets.WEBHOOK_SECRET` is gone from `notify-web-call.yml` (see *One
   live constraint*), the reusable cannot read that secret and a caller passing it fails
   validation — so re-declare it (`required: false`) before the next step. While the
   declaration is still present this step is a no-op; it is written down because this
   procedure must survive the removal.
5. **Publish the reusable change, or the callers will never see it.** This is the step
   that is easy to miss and silently wastes the whole procedure. Callers do not execute
   `notify-web-call.yml` from `main`. Most track the **moving `@vN` alias**, where `N` is
   the current major — read it from `core.version`, do not assume the one written here —
   and at least one (`dotfiles-MacBook` today) uses a **SHA pin** instead. Derive the
   current shape rather than trusting this paragraph:

   ```sh
   # who calls it, and at what ref
   grep -rn 'notify-web-call.yml@' ../dotfiles-*/.github/workflows/ 2>/dev/null
   ```

   Edits to steps 3-4 sit on `main`, invisible to every one of them. Until this lands,
   step 6 hands the reusable a secret that the version actually running still ignores, and
   step 7 then removes the App token that was holding the dispatch up — so the dispatch
   path goes dark fleet-wide with everything *looking* restored. Either:
   - **cut a Core release**, which advances the current `@vN` alias (see
     `RELEASE-RUNBOOK.md`) — the normal path, and it still leaves any SHA-pinned caller
     needing a pin bump; or
   - **temporarily repoint the callers** at the recovery commit (`@<sha>`), which is
     faster in an incident and is undone by the cleanup below.

   `sync-fanout.yml` and Core's own inline `notify-web.yml` are not reusable and are
   unaffected by this step — their step-3 edits take effect immediately.
6. **Restore each caller's `secrets:` mapping.** A reusable workflow does **not** inherit
   its caller's secrets: `notify-web-call.yml` sees only what the caller hands it, and
   `release.yml` passes `FLEET_APP_PRIVATE_KEY` alone. Restoring the expression inside the
   reusable without re-adding `WEBHOOK_SECRET: ${{ secrets.WEBHOOK_SECRET }}` to every
   caller — Core's `release.yml` and the nine OS-repo `notify-web.yml` files — leaves it
   empty there however the org secret is set. (`secrets: inherit` does the same job in one
   line.) `sync-fanout.yml` and Core's own inline `notify-web.yml` are not reusable
   workflows and need only step 3.
7. **Then unset `FLEET_APP_ID`**, or the restored expression will never choose the PAT.
   `steps.app.outputs.token || secrets.…` prefers the *left* side whenever it is non-empty,
   so an App that still mints — even an under-scoped one whose token 403s on the actual
   push — keeps winning; and an App that fails to mint fails the *step*, so execution never
   reaches the fallback at all. Unsetting the variable makes the mint step's `if:` false,
   which skips it, which finally leaves the output empty.

### Getting back off the PATs — do not skip this

The state the seven steps leave you in **is the state G2 existed to remove**: broad,
long-lived, hand-rotated credentials in many repos. It is worse than the pre-G2 state in
one respect — `token-health.yml`, the weekly probe that watched those PATs for silent
expiry, was retired precisely because minted tokens cannot expire, and it is **not coming
back on its own**. So while the PATs are live, nothing is watching them.

Treat the workaround as time-boxed:

- **While it is in force**, put the PATs' expiry dates somewhere that will actually reach
  you. Nothing in CI will warn you; the first symptom is a fan-out or dispatch failing on a
  403 for no visible reason, which is exactly the failure mode this whole migration closed.
- **Once the App is working again**, reverse all seven steps, in this order:
  1. Re-set `FLEET_APP_ID` (undoes step 7) — the mint resumes and takes precedence again.
  2. Remove the caller `secrets:` mappings (step 6) and drop the `|| secrets.…` fallbacks
     back to the bare `${{ steps.app.outputs.token }}` (step 3).
  3. **If step 4 re-declared `WEBHOOK_SECRET` after a MAJOR had removed it, remove it
     again** — otherwise the cleanup silently reinstates the very declaration that MAJOR
     was cut to retire, and the next reader finds a deprecated secret back in the contract
     with no record of why.
  4. **Re-publish** (step 5): advance the current `@vN` alias with a release, or unpin any
     callers you repointed at a recovery SHA. Use the same derivation as step 5 — if the
     recovery spanned a MAJOR, the alias callers now track is not the one you started on.
     Skipping this leaves callers running the recovery workflow indefinitely.
  5. **Delete the PATs** — from every repo and from the org. Verify with the listing
     command in *What the fleet runs today*; a forgotten PAT is a live credential nothing
     is monitoring.
