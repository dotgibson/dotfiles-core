# Changelog — recent releases

GENERATED FILE — do not edit by hand. `scripts/gen-changelog-recent.sh` rewrites it
wholesale, `scripts/release.sh` runs that generator on every release, and
`scripts/audit-core.sh` §9e fails when this file is not byte-identical to a fresh
render. To fix a conflict or a stray edit, re-run the generator — never patch it.

The last 8 released sections of `CHANGELOG.md` (v5.5.0 … v5.1.0), vendored into every OS repo's
`core/` by `core.vendor` so `core whatsnew` can answer offline. The full changelog is
repo-meta and stays upstream:
[dotgibson/dotfiles-core/CHANGELOG.md](https://github.com/dotgibson/dotfiles-core/blob/main/CHANGELOG.md).

## [v5.5.0] - 2026-08-30

### Changed

- **`atuin/config.toml` no longer pins `search_mode`, so a machine can finally choose it.**
  The line asserted `"fuzzy"` — which is atuin's OWN default (`atuin default-config` ships
  it commented out at that value), so it pinned a default rather than choosing anything.
  What it DID do was shadow `ATUIN_SEARCH_MODE`, under the same precedence rule `[daemon]`
  documents at length: atuin builds config as defaults → Environment → **file**, and the
  later source wins, so any key present here beats the environment.

  That blocked the one mode worth opting into. **`daemon-fuzzy`** routes interactive search
  through the atuin daemon, and is meaningful only where that daemon runs — which Core
  ships **off**, per machine, for the reasons already recorded in `[daemon]`. It cannot be
  a fleet-wide assertion: even on a host that opted in, `os/alpine.zsh` deliberately leaves
  the daemon off **inside containers**, and these repos target containers as much as hosts,
  so a blanket `daemon-fuzzy` would apply on precisely the shells with no daemon to talk to.

  **No host changes behaviour.** atuin still defaults to `"fuzzy"`, so an unset key and the
  old assertion are the same thing everywhere — the difference is only that the override
  now reaches. A machine running the daemon sets `ATUIN_SEARCH_MODE=daemon-fuzzy` from its
  OS layer (`os/<os>.zsh`) or host layer (`99-local`), beside the `ATUIN_DAEMON__*` exports
  that turned the daemon on.

  This is the trap `[daemon]` already warned about, found in the block above it: _"The same
  trap applies to any future per-machine key: if a machine is meant to override it via
  `ATUIN_*`, it must not be written here."_ `search_mode` was written here.

### Fixed

- **`make publish` reported a network failure for a stale tag, and hid the evidence.**
  `scripts/tag-release.sh` opened phase 2 with `git fetch -q --tags origin 2>/dev/null`.
  The `vN` major alias is **force-moved to every release**, so any clone that missed one
  carries a stale local `vN` — and a plain `git fetch --tags` REFUSES to move it
  (`! [rejected] v5 -> v5 (would clobber existing tag)`), exits 1, and takes `publish`
  down with it. Nothing was wrong with the network, but with stderr redirected to
  `/dev/null` the only thing the operator saw was `could not fetch origin — publishing
  needs the remote's view of main`, which points at exactly the wrong thing. Hit cutting
  **v5.4.3**, on a clone whose `v4` and `v5` were both behind; the actual repair was a
  one-line tag update.

  The fetch now passes `--force` and no longer swallows stderr, so a real failure names
  its cause (`Could not resolve host: …`) instead of wearing the generic message.
  Forcing is correct rather than merely convenient: `vN` is a MOVING alias whose remote
  value is authoritative by definition, so a local ref that disagrees is stale, never a
  competing truth. Immutable `vX.Y.Z` release tags are unaffected — they never move, so
  `--force` has nothing to overwrite there, and the tag ruleset forbids it regardless.

  Verified both ways: with `v5` deliberately pointed at `v5.4.2`, the old fetch exits 1
  and the new one exits 0 and realigns it, leaving `v5.4.2`/`v5.4.3` untouched; against
  an unresolvable remote it still exits 1, now printing the reason.

## [v5.4.3] - 2026-08-30

### Added

- **A gate for local gates that cannot do what their name says (#775).**
  `scripts/lib/common.sh :: _core_make_gate_hits` reads a repo's `Makefile` and reports
  three shapes, all found by hand across the fleet and none previously catchable:

  - **A skip that cannot skip.** `command -v x || { echo "skipping"; exit 0; }` on one
    recipe line, the tool on the next. `make` gives each recipe line its own shell, so the
    `exit 0` ends only that line — the target announces a skip and then runs the missing
    tool, exiting 127. Found in Debian, Fedora (×2), Offense (×3) and Defense (×2).
  - **A check that cannot fail.** A checker ended with `;` before a success echo: the echo
    runs regardless _and_ becomes the line's exit status, so findings print and the target
    exits 0. openSUSE's `lint-sh` did this while its two siblings used `&&` and
    `|| exit 1` — which is exactly why nobody looked at it.
  - **A blocking CI leg with no local mirror.** A `.markdownlint.jsonc` that only CI ever
    read, for a leg blocking since #592, plus the narrower case where the local target
    globs `'*.md'` (top-level only) while the gate lints `git ls-files` recursively.

  Rendered in two places, because the defect is in the callers and Core's audit can only
  see Core: **§8d** of `audit-core.sh` keeps the authoring repo honest, and a new
  **`make-gates`** leg in `lint-call.yml` judges each caller's own `Makefile`. Both drive
  the shipped function rather than a copy — the discipline `_core_tool_skip_count`
  records, where a test that re-implemented its subject stayed green while the defect it
  existed to catch was fully reintroduced.

  **Blocking**, and only because the fleet was cleared first. #592's markdown leg had to
  ship advisory for a release because seven of nine callers would have gone red before a
  maintainer could act; the nine #775 PRs merged while this was in review, so every
  caller's `main` measures 0 and that staging is unnecessary here. The measurement is the
  precondition, not a formality: a future rule that any caller fails must ship advisory
  the way #592 did, because callers read `lint-call.yml` at the **moving** `@v5` tag and
  meet a new rule the moment `auto-tag` moves — red on arrival, in a repo whose author
  changed nothing. Recorded on the job so nobody loosens the rule to get past a red.

  Three things worth recording about how it was built, because they are the reason to
  trust it:

  - **It found four defects the hand sweep missed** — Offense's `shellcheck` and `secrets`
    (both exit 127 with the tool absent) and Defense's `core-check`, which is the worst of
    the set: it prints its skip notice, runs `gh` anyway, and reports
    `vendored core is 5.4.1, upstream is  — a sync from dotfiles-core is owed` from an
    empty variable. A confidently wrong answer about fleet drift, not a crash.
  - **The false positives shaped the rules more than the true ones.** A first draft used
    "any `exit 0` before the last recipe line" and reported Alpine's `shell`, which guards
    shellcheck and runs it _on the same line_ — a correct skip. It also flagged `lint-zsh`
    and `zsh-syntax`, which handle failure with `|| exit 1` inside the loop. All three are
    pinned as must-not-fire cases: a gate that cries wolf on working code teaches the
    fleet to ignore it.
  - **It was seen failing before being trusted.** The fixtures are the real pre-fix and
    post-fix recipes copied verbatim, not synthetic approximations, and §8d was run
    against a defect injected into Core's own `Makefile`. A guard for a historical defect
    that is never run against that defect is the same category error it exists to fix.

  The `audit-alpine` leg caught the guard doing the thing it hunts. Its markdownlint
  reachability probe used `grep --exclude-dir` and `-I`, both GNU extensions; busybox grep
  rejects the first, so the probe exited 2, that was read as "no mirror", and Core — the
  repo that authors the rule — was reported as the one repo missing it. **A false finding
  produced by an unsupported flag, in the gate whose entire subject is checks that answer
  wrongly.** Neither flag was needed. The probe now also distinguishes "searched, absent"
  from "could not search", and stays silent in the second case: unknown and absent are
  different facts and only one is a defect. Pinned by a fixture that rejects those flags
  exactly as busybox does, so a developer box catches it without an Alpine runner.

  Complements, and does not replace, `dotfiles-MacBook/test/check-skip-guards.sh`, which
  tests the first shape at _runtime_ by rebuilding a PATH without the guarded tool. That
  is stronger evidence per finding but can only judge the repo it sits in; this is the
  static, fleet-portable half.

### Fixed

- **Footnote `¹⁴` said `ouch` was "unpackaged on Alpine outright". It is in
  `edge/testing`, and the matrix already said so one line away.** `PORTING-MATRIX.md`'s
  `ouch` row carries `testing¹⁴` in its Alpine cell; the footnote that cell points at then
  denied it, splitting `ouch` off from `duf`/`glow`/`tealdeer` as a fourth, distinct case.
  Re-queried on pkgs.alpinelinux.org: **`ouch` 0.6.1-r0, `edge`/`testing`**, maintainer
  listed, built 2025-05-28, on x86_64 and aarch64 — and absent from v3.21, v3.22, v3.23 and
  v3.24, each queried individually. That is exactly the other three's shape
  (`duf` 0.9.1-r9, `glow` 3.0.0-r0, `tealdeer` 1.8.0-r0, all `edge`/`testing`, none on
  stable). The footnote now reads `testing`-only and groups all four; the table cell was
  right and is unchanged.

  **How the file came to contradict itself is the part worth recording.** This cell was
  already corrected once, the OTHER way: an earlier `/os-package-availability` stamp set
  Alpine's `ouch` to `testing`. Then #519 flipped `¹⁴` back, citing `dotfiles-Alpine`'s
  `bootstrap.sh` comment ("also unpackaged on Alpine — cargo only") as its evidence — and
  that comment was itself wrong. Two documents agreeing is not two sources; a claim about
  what a distro packages is only ever settled by querying the distro. The `bootstrap.sh`
  comment is corrected in the same sweep (dotgibson/dotfiles-Alpine#146), so the citation
  and the cited now say the same true thing.

  **Nothing operational changes.** `testing` is not enabled on a stable release and `ouch`
  is on no stable branch, so `cargo install --locked ouch --no-default-features` remains
  its real source on Alpine — as does the bzip3/bindgen reason for those flags, which is
  unaffected and kept verbatim. The neighbouring `¹⁷` is also left alone: `jnv` returns no
  results on edge including `testing`, so it is the genuinely-unpackaged one.

- **Footnote `³⁴`'s jq security floor omitted the branch furthest below it.** The fleet
  position named Alpine 3.22/3.23/3.24 (1.8.1) as below the recorded ≥ 1.8.2 floor but
  skipped **Alpine 3.21, which carries 1.7.1-r0** — further below than any Alpine branch
  listed, and a branch the fleet still supports (EOL 2026-11-01; `dotfiles-Alpine`'s
  `install/packages.txt` reasons about it explicitly for `yazi` and `gron`). Now listed with
  the other 1.7.1 builds. Verified alongside the rest: edge 1.8.2-r0, v3.22/v3.23/v3.24
  1.8.1-r0, v3.21 1.7.1-r0.

- **`watchexec` 2.7.0 on Arch and Homebrew — the same bullet, one release later.**
  (`PORTING-MATRIX.md`) Footnote `²⁵`'s Arch/Homebrew bullet read 2.6.1, with `2.6.1-1` as Arch's
  package revision. Both have moved to **2.7.0** (`2.7.0-1`), and the block's `versions
  re-verified` stamp is now 2026-08-30. The `verified 2026-08-12` and `Linux-repo coverage
  re-verified 2026-08-21` stamps beside it are deliberately unchanged: only versions were
  re-checked, not availability or which Linux repos carry it.

  Re-checked against each repo's own package pages, per the convention the footnote declares —
  `formulae.brew.sh` (2.7.0, neither deprecated nor disabled) and `archlinux.org` (2.7.0-1). The
  other four bullets hold unchanged: openSUSE Tumbleweed and nixpkgs 2.5.1, Alpine `community`
  2.5.1-r0, GURU 2.5.0 (still the top non-`9999` ebuild), and Fedora/Debian/Kali packaging it
  nowhere. So the two-way split #611 introduced is still the right shape, and the parenthetical
  explaining it still reads true — Arch and Homebrew moved together again.

  This is the **second** bump of this line in eight days; #611 stamped 2.6.1 on 2026-08-23. That
  cadence is inherent to recording an exact version for a fast-moving upstream, and it is still
  worth recording here, because the cell's whole claim is that Homebrew packages `watchexec`
  while the MacBook `Brewfile` is the one ²¹ entry that deliberately declines it — a reader
  checking that wants a date beside the number. That assertion is unchanged, and so is the
  `Brewfile`: the audit that surfaced this found all 77 entries resolving under their canonical
  names, none deprecated or disabled.

  Surfaced by `/os-package-availability macbook` (dotfiles-MacBook#211).

- **`VENDORING.md` described a resolved `core.lock` defect as a live hazard (#670).** It
  warned, in the present tense, that three OS repos independently generate `core.lock` and
  "have already drifted from it and from each other" — naming Arch's hardcoded
  `core_branch=main`, openSUSE's SHA-in-that-field, and MacBook's read-back of the previous
  value. #593 retired all three more than a release ago. Every one of the four `make
  core-lock` targets in the fleet is now an echo-only redirect that writes nothing and names
  its own retired defect in the past tense (Offense's runs a read-only freshness check and
  points at its own pull). Telling a reader the fleet is in a state it is not in is worse
  than silence: it also spends the credibility of the surrounding warnings, which are still
  live.

  The paragraph now states the rule that survives — Core's `sync-core.sh` is the only writer
  of `core.lock` in a fan-out repo, because it stamps the lock in the same commit that
  materializes `core/` — and records the four redirects as the **enforcement** of that rule
  rather than as breaches of it. The three retired generators stay in the text as the
  evidence for why a second writer cannot be kept in step by discipline; they are no longer
  presented as something to go and fix.

- **The same stale claim stood in a second document.** `RELEASE-STRATEGY.md` also read
  "three consumers carry an independent generator of a format Core owns, and all three have
  already drifted from it", so correcting `VENDORING.md` alone would have left two Core
  documents disagreeing about the repo's own rule — the shape of defect #668 had just
  finished clearing out. Both now say one thing.

- **The runbook told you a patch cut moves `v4`, four lines after saying the fleet pins
  `@v5` (#672).** The v5.0.0 sweep corrected `RELEASE-RUNBOOK.md:183` to "currently `@v5`"
  and stopped there, leaving the bullet 26 lines below it saying a PATCH or MINOR keeps "the
  **same** alias (`v4` today)" and that every caller pinned `@v4` picks the change up. Read
  literally on the next patch cut, that force-advances the **frozen** major — the exact
  motion `RELEASE-STRATEGY.md` §"Pinning reusable workflows" forbids, and the one §8a was
  built to catch on the receiving end. Three more live claims had gone the same way: the
  straggler-hunt command (`grep -rl 'uses:.*@v4'`) now matches nothing fleet-wide and so
  reports a clean sweep by construction, and `RELEASE-RUNBOOK.md` §2/§3a plus
  `RELEASE-STRATEGY.md`'s release-paths table each described `dotfiles-Windows` as
  SHA-pinning "rather than tracking `@v4`" — a contrast drawn against an alias nothing
  tracks.

  **The rest went version-neutral rather than being bumped**, which is the point: an `@vN`
  that names no major cannot go stale, so this is the last time these lines need a sweep.
  That covers `VENDORING.md`'s two live rules, the `freshness-triage` and `modernize`
  routines' descriptions of what the fleet pins, and — deliberately outside the docs — the
  same claims where they are stated in code. `sync-core.sh:370` was a verbatim twin of
  `VENDORING.md`'s sentence about the mutable alias. Fixing the prose alone would have left
  the docs and the code contradicting each other on one rule, which is the defect #668 and
  #670 just finished clearing.

  One site took the opposite treatment, and the distinction is the rule: `sync-core.sh`'s
  `--help` still offered `refs/tags/v4` as the tag to vendor a new repo at — a ref the
  reader **pastes**, not a claim they read, so it is corrected to a concrete `refs/tags/v5`
  rather than genericized. That matches its own file's header, `ARCHITECTURE.md`,
  `VENDORING.md`, `PORTING-MATRIX.md`, and the live default in `new-os-repo.sh`. It is the
  one instance the v5.4.2 sweep missed while correcting its sibling in `new-os-repo.sh`, and
  it was user-facing output the whole time.

  The MAJOR worked example is now `@vN` → `@vN+1`, with the concrete v4→v5 commands kept but
  framed as the historical cut they are. This **supersedes** the v5.0.0 note above declaring
  that block "correct as written": it was, on the day it was written, and it stopped being
  correct the moment `v5` shipped — which is the argument for not writing a present tense
  that has to be swept every major. `CHANGELOG.md`, the proposal docs, the #515 history, and
  the `dotfiles-managed v4` marker chain are untouched; the marker is an architecture
  generation asserted by `bootstrap-test.yml` and the suite, not a tag alias.

### Changed

- **`core_branch` is documented as gone, and the flat "only sanctioned writer" claim is
  qualified (#670).** Two things were true but unwritten. First, `dotfiles-Offense` is a
  real second writer: `make core-sync` runs that repo's own `scripts/sync-core.sh`, a
  `git subtree pull --squash` that stamps all four fields, and Offense's `CONTRIBUTING.md`
  teaches it as the update route there. It is sanctioned — unlike the three retired
  generators it writes Core's format from what it actually pulled, taking `core_sha` from the
  squash commit's `git-subtree-split` trailer and `core_version` from the tree on disk, so
  the lock cannot name a commit its own `core/` does not contain — but an unqualified "only
  sanctioned writer" read as covering it and did not. `VENDORING.md` now names it as the one
  exception, and notes the consequence: Offense has two paths into `core/`, the fan-out which
  replaces the tree and its own pull which merges, and `core-integrity` gates both because
  both stamp the lock.

  Second, the pre-#453 `core_branch` field survives in no `core.lock` anywhere — all nine
  fleet locks are Core-stamped with `core_ref` — so it is now documented as gone as of v5,
  and a lock still carrying it is pre-v5 and fixed by a sync rather than by hand. Offense's
  reader-side fallback (`scripts/sync-core.sh:80-82,183`,
  `test/check-core-freshness.sh:59-63`) is the last consumer of the old name and is dead
  against every lock that exists; retiring it is a `dotfiles-Offense` change, tracked
  separately.

## [v5.4.2] - 2026-08-28

### Fixed

- **The docs still taught `git subtree` as the live mechanism (#668).** #587 replaced the
  fan-out's `git subtree pull --squash` with a pinned fetch plus `read-tree --prefix`, but
  the record never followed. Two Core documents contradicted each other on the repo's
  central mechanism, and the one giving instructions was the wrong one:
  `RELEASE-STRATEGY.md` handed the reader
  `git subtree pull --prefix=core <core-remote> vX.Y.Z --squash` for both adopting a release
  and rolling one OS back — precisely what `VENDORING.md` forbids, because it moves `core/`
  but not `core.lock` and leaves `core-integrity.sh` reporting `TAMPERED`.

  Both recipes are now the real incantation, run from a Core checkout, with the three
  constraints that make it work stated for the first time: `sync-core.sh` refuses unless
  local `HEAD` **is** the pinned commit; it reads `core_version` from the **working
  tree**, so pinning an older tag from `main` writes a silently wrong lock; and the pin
  must be the **peeled commit**, never `refs/tags/vX.Y.Z` — releases are annotated tags,
  and the script resolves its pin with `git ls-remote`, which returns the _tag object_, a
  SHA that can never equal the `HEAD` a tag checkout leaves you on. The three pre-existing
  `CORE_BRANCH=refs/tags/v…` recipes in `ARCHITECTURE.md`, `VENDORING.md` and
  `PORTING-MATRIX.md` carried that same latent defect and are corrected too. The claim that
  a rollback "merges backwards, it does not un-merge" is deleted — materializing replaces
  the tree outright, so an older pin is just an ordinary sync.

  Several surfaces an operator actually reads at runtime were asserting the retired
  mechanism: `make help`, `sync-core.sh --help`, both lines of the core-guard hook's
  refusal message, the README `new-os-repo.sh` writes into every new OS repo, and the
  **fan-out PR body shipped into nine repos on every release** ("Vendors the released Core
  into `core/` via `git subtree pull --squash`"). `.bin/sync-upstream.sh` recommended the
  forbidden command in its own error tip. All corrected, along with the now-false "the
  subtree squash records the exact Core commit" in `ARCHITECTURE.md`, `core.manifest` and
  `zsh/30-functions.zsh` — `core.lock` records it.

  One-line mechanism claims in `CLAUDE.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `ARCHITECTURE.md`, `README.md`, the PR and issue templates, the `doc-consistency`
  subagent, and the non-Markdown surfaces that carried the same sentence (`ci.yml`,
  `core-integrity.yml`, `sync-fanout.yml`, `core-integrity.sh`, `CODEOWNERS`,
  `.gitattributes`, `.pre-commit-config.yaml`) simply drop the clause: they state the invariant that matters (`core/` is a copy; a defect
  fans out N-way) and leave `VENDORING.md` the single owner of _how_, so no mechanism claim
  can go stale in ten files again.

  What **stays** is the one `git subtree` that is still live: the one-time `subtree add`
  that creates a `core/` where none exists (`scripts/new-os-repo.sh` runs it, and
  `sync-core.sh` skips a repo without one). It is now labelled as initial vendoring and
  never the update path, and its `refs/tags/v4` is corrected to `v5`. `PORTING-MATRIX.md`
  step 5 also stopped instructing an add that could not work: step 1 copies Fedora's
  `core/` across, so `subtree add` there fails with _prefix 'core' already exists_ — the
  step is a re-vendor via `sync-core.sh`.

## [v5.4.1] - 2026-08-28

### Fixed

- **The `os.capabilities` fleet gate deadlocked the fan-out it depends on (#667).** §9c shipped
  BLOCKING on a missing declaration, and `scripts/sync-core.sh` runs `make audit` over a fleet
  checkout **before** it vendors anything — deliberately, so a red tree never reaches nine repos.
  But a declaration cannot merge into an OS repo until that repo has vendored the Core whose
  validator accepts it, and **that vendoring is the fan-out**. So the gate refused to fan out the
  very release that would let the declarations land: v5.4.0 published, `sync-fanout` failed, and
  zero vendor PRs opened.

  The two findings now carry two severities. A **malformed** declaration still blocks — the repo
  authored one and got it wrong, and no release cycle makes that acceptable. **No declaration at
  all** is advisory for one cycle, then flips.

  This is the same red-on-arrival shape §5f and `lint-call.yml`'s owned-block gate both name, and
  both answer the same way. It is also the shape this change's _own_ `lint-call.yml` step already
  got right — that step makes a missing declaration advisory and a malformed one blocking. The
  asymmetry between the two halves was the defect, not the reasoning in the workflow.

## [v5.4.0] - 2026-08-27

### Added

- **The fleet declares (#667).** #663 defined `os.capabilities` and #664/#665/#666 made `up`, the
  maint runner and `core-doctor` dispatch through it — but **nothing had authored one**. All nine
  repos lacked `os/<os>.capabilities`, so `blib_link_os_layer`'s `[[ -f ]]` guard linked nothing,
  `$_CORE_CAP` was empty on every box, and all three consumers ran Core's built-in fallback rows.
  The mechanism was live and unexercised for two releases. **Seven declarations** now exist,
  transcribed from `PORTING-MATRIX.md` §"Package-manager commands" and cross-read against Core's
  built-in rows, so a declaration that behaves differently from the row it replaces is a visible
  diff rather than a silent one.

  **Seven, not nine, and that is the answer to the question #667 left open.** `dotfiles-Offense`
  and `dotfiles-Defense` have no `os/` directory and never call `blib_link_os_layer` — the OS band
  belongs to the repo underneath them — so they declare nothing and inherit the OS layer's table.

- **`audit-core.sh` §9c — fleet coverage.** §9a holds Core's shipped example to the schema; this
  holds the repos that run on real boxes to it. It is the half that matters for the failure above:
  a per-repo `make lint` catches a _broken_ declaration, but only a fleet sweep catches a _missing_
  one — a repo that never authored a file has nothing for a per-repo target to fail on, and the
  absence is invisible from inside it. The Role-repo exemption is **structural** (does this repo
  have an `os/` directory) rather than a name list, so a repo that grows an OS band starts being
  gated automatically, and per-tier declarations are picked up without the gate knowing they exist.

- **`scripts/new-os-repo.sh` scaffolds a schema-valid declaration.** The script already centralised
  the load order _"so a scaffolded repo can never start out of order"_; the capability table is the
  same argument, and a repo scaffolded without one boots onto the fallbacks and **looks fine** —
  which is precisely how the fleet reached nine repos and zero declarations. The stub carries every
  required key (so `make capabilities` is green on day one) with Fedora's values and a banner saying
  they are wrong anywhere else. The optional keys are deliberately **not** stubbed: in this schema an
  omission is a statement, so pre-declaring them would hand every new repo the permissive answer.

### Changed

- **`_core_install_prefix` reads `PKG_INSTALL` (#667).** The last **17** of the 154 package-manager
  references Core carried in portable modules. It also fixes a reach the mapping could not make: the
  `<mgr>` token came from `_pkgup_mgr`, which is band 60 and absent under `CORE_PROFILE=minimal` and
  `standard`, so `core-doctor`'s "install missing" remedy and the command-not-found hint printed
  **nothing** on a lean profile while the `✗` rows they explain stayed. `$_CORE_CAP` is band 02 and
  in every profile, so on a declaring box both now work everywhere.

- **`scripts/new-os-repo.sh` vendors `refs/tags/v5`, not `v4`.** Unrelated to the above and found
  next to it: a repo scaffolded today pinned a Core **a major behind** — one with no capability
  dispatch at all, so the stub it now writes would have had nothing to dispatch through.

### Fixed

- **Two comments that named a key the schema has never had.** `zsh/55-maint.zsh` and its
  `audit-core.sh` §5c note both said `SCHEDULER_UNIT_PATH`; the key is `SCHEDULER_UNIT_DIR`, and the
  DIRECTORY-not-path distinction is the whole reason it exists — Core appends its own unit name so
  the unit it writes cannot be decoupled from the one it enables.

### Note

- **The built-in fallbacks are NOT deleted here.** Three blocks say "DELETE THIS BLOCK IN #667";
  they now say #763. A declaration reaches a box only once `bootstrap.sh` has **linked** it, and
  that is a separate event from the Core fan-out that delivers this release — so deleting them here
  would leave `up` answering "this archive does not offer that" on every host that pulled and had
  not re-run `./bootstrap.sh --links-only`. #763 does the demolition, gated on evidence that the
  fleet has actually re-bootstrapped rather than on elapsed time.

- **No clipboard capability key, superseded rather than skipped.** #667 listed
  `PORTING-MATRIX.md` §"Clipboard packages to install" as a transcription source; #663 had already
  decided otherwise and the schema rejects such a key. `bin/clip` is re-exec'd by nvim and tmux on
  every yank and paste, and its WSL probe was already rewritten once to avoid forking a `grep` per
  invocation — a file read and parse there would give back exactly what that bought, for a value
  that changes once per machine. The matrix now records this so it is not re-opened.

## [v5.3.0] - 2026-08-27

### Changed

- **The scheduled runner dispatches through `os.capabilities` too (#665).** `maint/dotfiles-maint.sh`
  carried **49 package-manager references** — the second-largest concentration of OS knowledge in
  Core, and a second copy of the ladder #664 just removed from `zsh/60-update.zsh`. Two copies of
  one fact drift, and these had: the maint ladder grew **no emerge arm at all**, so a Gentoo box's
  daily run has never counted anything, and its zypper apply says `up` where the interactive one
  says `dup` on Tumbleweed. There is now one.

  `zsh/55-maint.zsh` keeps `_maint_scheduler` as the dispatcher — switching on a capability rather
  than an OS name was always the right shape — but the answer now comes from the OS layer's
  declared `SCHEDULER`, with the probe as the fallback for a box that has not declared.

- **`SCHEDULER` gains `cron`, which was a defect in the schema rather than a judgement about cron.**
  Core's `_maint_scheduler` has had a live cron arm all along — it is what an OpenRC box (Alpine,
  Gentoo) gets, having `crontab` and no systemd — so #663's enum was rejecting a value Core itself
  produces, and `scripts/test-core.sh` asserted that rejection. Alpine's only honest declaration was
  `none`, which means "this box cannot hold a timer", on a box that can.

- **A bash reader for the declaration, which the contract promised and nothing implemented.**
  `examples/os.capabilities.example` and `lib/bootstrap-lib.sh` both said `maint/dotfiles-maint.sh`
  reads the same file with `sed`; it did not. It now does — extracted, never sourced, for the reason
  #663 chose flat `KEY=value`: sourcing a per-repo file into the one process in this system that may
  call `sudo -n` is a code-execution surface, and extraction cannot execute anything. Same strictness
  and the same trailing-whitespace trim as the zsh reader, so the two cannot disagree about one file.

### Added

- **`SCHEDULER_UNIT_DIR` — the key that gets the last OS-absolute path out of Core.**
  `~/Library/LaunchAgents` appeared at **six sites** in `zsh/55-maint.zsh` and was the reason
  `audit-core.sh` §5c carried a per-file exception. It now survives in exactly one place: the
  built-in fallback for a box that has not declared. #667 authors the key across the fleet and
  deletes that block, **and the §5c exception goes with it** — together with #664's sibling
  package-manager fallback.

  A **directory**, not a path, and the split is load-bearing: where units live is an OS fact, but
  what Core calls its own job (`dotfiles-maint.service`, `com.dotfiles.maint`) is Core's identity and
  is what `systemctl enable` and `launchctl` name. A declaration that could rename the file would
  decouple the unit Core writes from the one it then enables — installed, reported healthy, never
  run. The validator rejects a value ending in `.service`/`.plist`/`.timer` for that reason.

  The plist and unit **templates stay in Core**, and are not the exception. They are portable text
  parameterised by paths, selected by `_maint_scheduler`. Pushing them outward would put one systemd
  unit in seven copies with no owner — the hand-maintained N-way drift `VENDORING.md` records as the
  #449 failure. The OS layer owns _where_ the unit goes, not _what it says_.

- **`MAINT_UNATTENDED_UPGRADE`, and the direction of its default is the whole point.** Scheduled
  system upgrades are now gated twice: the operator's `MAINT_SYSTEM_UPGRADE=1` env var **and** the
  repo's declared opt-in. **Omitting it refuses.** A fail-open here silently applies full system
  upgrades on an engagement box, unattended, on a schedule nobody is watching — so `=0` is _rejected_
  by the validator rather than read as "declared", which is how a value written to forbid something
  would have permitted it.

  This replaces two hand-rolled refusals: Kali, read out of `/etc/os-release` (OS knowledge in Core),
  and Arch/Gentoo, inferred from `have pacman || have emerge` — a probe for a **binary** standing in
  for a claim about a **distro**, true on any box with pacman installed for other reasons. Each repo
  now says so itself, and a repo Core has never heard of refuses by default instead of being waved
  through.

### Fixed

- **`XDG_CONFIG_HOME` was never defaulted in `maint/dotfiles-maint.sh`.** It defaults `XDG_CACHE_HOME`,
  `XDG_STATE_HOME` and `XDG_DATA_HOME` but not `CONFIG`, so the new declaration path would have
  resolved to a bare `/zsh/os.capabilities` on a box that does not export it — unreadable, and the
  runner would have silently behaved as though the box declared nothing. Found while wiring the
  reader; it would have been a silent no-op rather than an error.

- **An empty assume-yes vector no longer risks a bash 3.2 `set -u` abort.** Expanding an empty array
  as `"${a[@]}"` is an unbound-variable error on bash 3.2, which macOS still ships and every gate here
  is held to — and an archive that declares no `PKG_ASSUME_YES` (Arch, Gentoo, Alpine) is exactly the
  empty case. Uses the `${a[@]+"${a[@]}"}` guard.

- **`core-doctor` classified opt-in-vs-expected from one Core-side list, so it reported
  healthy boxes as degraded (#666).** A tool that is genuinely optional on one distro and
  expected on another was reported as expected everywhere. `jj` and `ast-grep` are the known
  cases — `PORTING-MATRIX.md` marks them 21 in the **Gentoo and Kali cells only**, while Arch,
  openSUSE and Alpine package them — and `dust` is the same shape on the Debian family. The
  result was a health report showing a degraded integration on a box where nothing was wrong,
  which is the failure mode most likely to train an operator to ignore the report.

  Core recorded this as unfixable without a new artifact and said so in its own words:
  _"a Core-side list cannot say 'opt-in there, expected here' … Fixing that properly needs a
  per-repo manifest; this is the fallback default until one exists."_ #663 landed the
  manifest; this spends it. `core-doctor` now reads the split from the repo's own
  `TOOLS_OPTIN`, and the JSON `expected` object moves with the render so a gate asserting it
  cannot disagree with the glyph a human reads two lines above.

  **A declared list REPLACES Core's default rather than adding to it**, so a repo declaring
  this key must re-state everything it still considers optional — recorded in the example,
  because the failure mode is silent and lands on whoever authors the nine declarations.

  **This key falls back per-key, and that is deliberately unlike `up` and the maint runner.**
  Those treat a declaration as authoritative all-or-nothing because for them an omission is a
  SAFETY statement — no `PKG_ASSUME_YES` means never auto-confirm, no
  `MAINT_UNATTENDED_UPGRADE` means refuse — and answering a refusal with a Core default would
  permit what the repo forbade. `TOOLS_OPTIN` carries no such claim: omitting it says the repo
  has not curated a list, not that nothing is optional. Reading it the other way would mark
  every uninstalled optional tool as degraded and manufacture exactly the alarm fatigue the
  opt-in state exists to prevent.

  #666 flagged that this could disagree with #697's stale-flag reporting, since it changes
  what "expected" means underneath it. They are independent by construction —
  `_core_doctor_stale` runs on both the opt-in and the missing branch — and there is now a
  test pinning that, so a future edit cannot quietly stop checking a reclassified tool.

## [v5.2.0] - 2026-08-27

### Changed

- **`up` is a dispatcher now, not a seven-package-manager driver (#664).** `zsh/60-update.zsh`
  was the largest concentration of OS knowledge in Core — five `case` statements that knew how
  seven archives count and apply updates, including a `grep -qi tumbleweed /etc/os-release` to
  choose `zypper dup` over `zypper up`. `ARCHITECTURE.md` named it one of two deliberate
  exceptions to Core's own rule and defended it as "one verb with N backends". The defence of
  the **verb** was right and still stands; one verb with N backends is what a dispatch table is
  for, and #663 landed the table.

  What runs is now resolved through `_pkgup_verb` from the OS layer's `os.capabilities`
  declaration. The seven per-manager parse heuristics collapsed into one pipeline — run the
  declared count verb, keep lines matching `PKG_PENDING_MATCH`, print field
  `PKG_PENDING_FIELD` split on `PKG_PENDING_FS` — and the apply `case` into four resolved
  verbs and one `&&` chain. `_pkgup_mgr` stays: probing with `command -v` is the shape
  `PORTABILITY.md` asks for, and the token it returns is the label every message interpolates.

  **`ARCHITECTURE.md`'s "two deliberate exceptions" is now one**, and `PORTABILITY.md`'s
  companion section with it. Note that the issue expected an `audit-core.sh` §5c exception to
  be removed here and **there was never one to remove** — §5c excepts `zsh/55-maint.zsh` (the
  `LaunchAgents` segment only) and `*.example`, nothing else. `PORTABILITY.md` already said so:
  this file was excepted _architecturally, not at the gate_.

- **Core still carries built-in defaults, and they are a stopgap with a demolition date.**
  #667 — which authors the nine declarations — is **blocked by this change**, so on the day
  this lands no box in the fleet has one and the built-ins are what every host actually runs.
  They live in one `typeset -gA` at the top of `zsh/60-update.zsh`, in the declaration's own
  `KEY=value` shape, so each row is the transcription source for the repo that will replace
  it and a declaration that behaves differently from its row is a visible diff. #667 deletes
  the block.

- **A declaration is authoritative — all or nothing, never merged per key.** Per-key fallback
  is the obvious shape and it is wrong, because in this schema an **omission is a statement**:
  no `PKG_ASSUME_YES` means _never auto-confirm_, and no `PKG_UPGRADE_PARTIAL` means `up -i`
  _refuses, this archive updates as a whole_. Merging Core's built-in row into a real
  declaration answers both of those with a default — handing an auto-confirm flag to a repo
  that deliberately withheld one, and letting `up -i` through into the partial upgrade a repo
  deliberately refused. A missing **required** verb is a broken declaration, and the thing
  that catches it is `scripts/check-capabilities.sh`, a gate you run — not a silent
  substitution on a box you are SSH'd into.

### Added

- **Nine optional keys, and one required key redefined (#664).** `PKG_UPGRADE` is now the
  **interactive** upgrade verb — `up` without a flag must still let the manager print its
  transaction summary and ask, which is what it has always done — and auto-confirm moved to
  the new `PKG_ASSUME_YES`. New optional keys: `PKG_ASSUME_YES`, `PKG_UPGRADE_PRE`,
  `PKG_CLEANUP`, `PKG_UPGRADE_PARTIAL`, `PKG_COUNT_REFRESH`, `PKG_COUNT_EXIT_TRUSTED`,
  `PKG_PENDING_MATCH`, `PKG_PENDING_FIELD`, `PKG_PENDING_FS`. Every one is optional and
  every default reproduces
  what the box did before, so #667's authoring burden stays small and a declaration written
  against the v5 schema keeps validating. `--packages` no longer checks the `PKG_PENDING_*`
  values as if they were binaries, and `PKG_PENDING_FIELD` is gated as a positive integer —
  a typo there does not fail at runtime, it reads a different column and reports confident
  nonsense.

- **`PORTING-MATRIX.md` §"Package-manager commands" gained its macOS and Fedora columns**, and
  a `count-pending` row. #667 is told to transcribe declarations from that table, and it was
  two managers short — missing exactly the reference implementation (`dotfiles-MacBook`) and
  the template the other Linux repos stamp from (`dotfiles-Fedora`), so the two most-copied
  repos had nothing to copy.

- **`PKG_COUNT_EXIT_TRUSTED`, which is what carries #756 through the refactor.** Gentoo's
  count is a real Portage resolve, and a resolve that **fails** must report the `-1` unknown
  sentinel rather than `0` — a box whose Portage cannot resolve is not a box with nothing to
  do. That distinction cannot be inferred generically, because most archives overload the
  exit status of their count verb in the opposite direction: `dnf check-update` exits **100
  when updates exist**, and `pacman -Qu` and `checkupdates` exit non-zero when there are
  **none**. So Core ignores the status by default and counts lines; an archive whose verb
  means what it says declares this key. Gentoo is the only one that does.

- **Tests for the dispatch, and two parse arms that never had any.** `brew` and `emerge` had
  no `_pkgup_count`/`_pkgup_list` coverage at all — the section header claimed four managers
  and the file has seven — including, now, Gentoo's Portage resolve, its `[nomerge]`
  filtering and atom stripping, and the failed-resolve sentinel. Both directions of the
  exit-status question are pinned: a failed resolve reports `-1`, and dnf's exit 100 does
  **not**. Plus the declared path end to end: a declared verb overriding the built-in row, the
  assume-yes token appended and _not_ appended, `PKG_UPGRADE_PRE` aborting the upgrade when it
  fails, `up -i`'s refusal driven by omission, a declared `sudo` mapped onto `doas` on a box
  that has only `doas`, and a `;` in a declared value staying an argument rather than becoming
  a command separator.

### Fixed

- **A declared privilege prefix names the intent, not the tool.** A declaration says
  `sudo zypper dup`, but Alpine has `doas` and not `sudo`, and a container has neither.
  `_pkgup_run` strips the prefix and hands the rest to `_pkgup_priv`, the existing ladder, so
  the same declaration is correct on all three. A value with no prefix (`brew upgrade`) runs
  bare, which for Homebrew is the only correct answer.

### Behaviour deltas

Two, both toward safety, both deliberate — everything else a host types is unchanged:

- **A failing `PKG_UPGRADE_PRE` now aborts the upgrade.** Debian's `apt-get update` used to
  run un-chained, so a failed index refresh still proceeded to `full-upgrade`; apk, emerge and
  brew all chained theirs with `&&`. One rule now, and it is the safer three's: an upgrade
  computed against an index that could not be refreshed is how a box half-applies.
- **`up -i` on macOS now runs `brew update` first.** The partial path previously skipped it
  while the full path did not. It costs a network round-trip and removes the case where you
  hand-pick from a stale outdated list.

## [v5.1.0] - 2026-08-27

### Added

- **The weekly sweep can finally tell a full box from a half-provisioned one (#750).**
  `real-bootstrap.yml` is the only job in the fleet that installs anything, and it asserted
  exactly two things on the far side of `./bootstrap.sh`: that it returned 0, and that the
  wiring survived. Both necessary; neither can see whether the packages actually arrived.

  The Gentoo leg proved it. The first leg of this sweep ever to run to completion — 75.3
  minutes, 131 packages emerged — was **green** while the bootstrap printed a ledger naming
  two steps that did not complete: one atom unreachable through its own dependency chain, one
  whose upstream build cannot succeed on that toolchain at all. Both were real, and both are
  now fixed in the OS repo (#751 corrected the matrix cells that had pointed at them). The
  **reporting** gap is this repo's, and it outlives whichever two tools exposed it: this job
  was the only one in the fleet that could ever have caught them, and it reported success.

  New opt-in `bootstrap_postcheck` input on `bootstrap-test.yml`, declared where every other
  per-leg knob already lives — the repo's own caller — and read **statically** by
  `scripts/fleet-bootstrap-matrix.py`, exactly as `bootstrap_timeout` is. The value is a
  command run **inside** the `docker run`, after `./bootstrap.sh`, where the box it asserts
  still exists; `--rm` has destroyed that filesystem by the time a following step starts,
  which is the bug the wiring assertion itself carried until #742. Absent by default, so no
  leg changes behaviour on landing.

  **Not `--strict`**, which is the obvious lever and the wrong instrument. It turns each
  bootstrap's end-of-run ledger into a non-zero exit, and that ledger deliberately mixes a
  genuine provisioning gap (an atom that will never install) with an infrastructure blip (a
  rate-limited `mise.run`, a GURU sync hiccup, a failed `tpm` clone). `--strict` cannot tell
  them apart, so it would red an advisory lane over somebody else's outage — per this
  workflow's own header, "exactly how these lanes get switched off". `dotfiles-Fedora`'s
  `bootstrap-full.yml` refused it in those words and did a far-side presence assertion
  instead; this is that, made reusable and derived rather than listed. A repo's own script
  **can** make the distinction Core cannot, because it knows which tools its own list
  promises, so the bootstrap exit code stays an honest signal nobody weakens.

  **A leg with no postcheck now says so** — in the fleet listing at the top of the run and
  again in its own summary line. The previous single sentence read identically whether the
  packages had been asserted or not, which is the pass that hid those two atoms behind a
  green tick. `dotfiles-Gentoo` ships `scripts/assert-provisioned.sh` already, so the hook
  has a real consumer as soon as `@v5` moves.

  First tests for `fleet-bootstrap-matrix.py`, which had none: a scratch-fleet fixture
  covering declared/absent/non-string, plus two assertions that encode #742 — that every
  `matrix.leg.<key>` the sweep reads is a key the script actually **emits** (a mismatch
  would make the hook a permanent silent no-op that reads as coverage), and that the
  postcheck reference sits inside the `sh -euc` block rather than in a later step.

### Changed

- **`scripts/os-repos.txt` is now the single source of the fleet, not one of four (#669).**
  The file was documented as canonical and its own header admitted it was not: `sync-core.sh`,
  `fleet-drift.sh` and `core-integrity.sh` each carried a hardcoded nine-name fallback array
  for when the file was missing or unreadable. Adding a target meant **four** coordinated
  edits, and **the copy you forgot was the one that ran** — the fallback fires precisely when
  the data file is already broken, which is the moment nobody is watching. `test-core.sh`
  asserted the four agreed, which is a backstop for a design flaw rather than a fix.

  All three arrays are deleted. There is one parser, `load_os_repos` in
  `scripts/lib/common.sh`, and **no fallback anywhere**: an absent, unreadable or
  commented-out-to-empty fleet list now exits 2 in those three gates instead of sweeping a
  list nobody chose. That is the posture `real-bootstrap.yml` already takes when it derives
  zero legs — a gate that silently never runs reads as coverage.

  Rejected the alternative of _generating_ the fallbacks from the file: it trades one
  duplication for a codegen step plus a new gate asserting the generated output is current,
  i.e. the same "these must agree" problem with an extra moving part — and the generated
  array would still run silently when its source was unreadable. Regenerating stale data
  more reliably does not stop it being substituted.

  `resolve_repo_dir` is untouched, so a repo renamed upstream still resolves from a clone
  sitting under its old directory name. The loader turns the file into names; that function
  still turns a name into a path.

  **Seven further copies folded in while the list was open**, because "one edit" has to mean
  every consumer:

  - `test-core.sh`'s owned-block fleet scan hardcoded **seven of the nine** names —
    `dotfiles-Defense` and `dotfiles-Offense` were silently never scanned, in the same file
    that policed the other three arrays.
  - `fleet-coverage.sh` swallowed an unreadable file with `2>/dev/null` and rendered an
    **empty coverage register**, indistinguishable from a fleet where nothing is covered.
  - `audit-core.sh`'s two sibling checks and `freshness-dashboard.sh` each hand-rolled the
    same parse. The advisory ones keep their `skip_env` posture — they now say they could
    not enumerate the fleet rather than implying they covered it.
  - `claude-routines.yml`'s doc-audit and drift-triage sweeps each spelled the nine names out
    inline, uncovered by any test; a tenth repo would have left both blind to it.

  The `test-core.sh` agreement assertion is **repurposed**, not just deleted: it now asserts
  the file is loadable, that each of the three scripts calls `load_os_repos`, and that no
  hardcoded list has grown back — plus new fixtures that **drive** the fail-closed path
  (absent and comments-only) and check the fan-out touched nothing, rather than trusting a
  comment that says it fails closed. Registering a fleet target is one line, and
  `new-os-repo.sh` now says so at the end of a scaffold.
