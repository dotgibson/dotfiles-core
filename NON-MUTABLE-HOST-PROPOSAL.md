# Non-mutable host proposal — the fleet on a box it cannot write to

> **Status: RESEARCH (opened 2026-09-14). Nothing is decided, nothing is scheduled, and no
> code changes until §5's research phase reports.** This is the planning document for the
> roadmap milestone *"the non-mutable host"* — the one theme on the roadmap with an
> external forcing function rather than an internal cleanup. `V8-PROPOSAL.md` §10 named it
> the right **next** major and put it out of scope *"because no work has started and the
> design needs research first."* This file is where that research is planned, and later
> where its findings are recorded. It is written in the "Current → Proposed → What breaks"
> voice the v4, v5 and v8 proposals established, with one deliberate difference: **§4 is a
> candidate shape, not a proposal**, and §5 exists to find out whether it survives contact
> with three real hosts. The v8 proposal's lesson applies with full force here — *"the
> content did not survive measurement, which is a result"* — so every claim below that is
> not measured is marked as an expectation.
>
> When a claim here drifts from `RELEASE-STRATEGY.md`, `PORTABILITY.md`, `VENDORING.md` or
> `examples/os.capabilities.example`, **those win** — fix this.
>
> **Whatever major this ships as is unnumbered.** The v8 proposal produced no major, so the
> next one is still `v8.0.0` by count; per the Additive Backlog's standing rule the milestone
> stays unnumbered and this file never names a version. If it turns out (§5 R2) that the
> work is additive after all, the milestone closes without a major, as the last two did.

## 1. Summary

The fleet's operating model assumes a **mutable host with an imperative package manager**:
`bootstrap.sh` installs packages and writes under `/etc`, `up` runs the archive's upgrade
verb and counts what is pending, `core-doctor` expects tools on `PATH` that a package put
there, and `os.capabilities` — the v5 contract — is a table of *verbs* (`PKG_INSTALL`,
`PKG_UPGRADE`, `PKG_COUNT_PENDING`, …) that every OS repo fills in for its archive.

Three families of desktop target do not have that shape:

| Family | Representatives | How software arrives | How the base updates |
| ------ | --------------- | -------------------- | -------------------- |
| **Atomic (image-based)** | Fedora Silverblue / Kinoite, `bootc` hosts | `rpm-ostree install` *layers* onto the next deployment; Flatpak; toolbox/distrobox; Homebrew-on-Linux | `rpm-ostree upgrade` / `bootc upgrade` stages a new deployment — applied on **reboot** |
| **Transactional (snapshot-based)** | openSUSE Aeon / MicroOS / Kalpa | `transactional-update pkg in` into a new btrfs snapshot; distrobox is the recommended path for CLI tools | `transactional-update dup` into a snapshot — applied on **reboot** |
| **Declarative** | NixOS (and `home-manager` on any host) | packages are *declared* in `configuration.nix` / `home.nix`; `nix profile install` exists but is the anti-pattern | `nixos-rebuild switch` — no reboot, but no imperative install either |

The milestone text says why this is a schema problem and not a ninth row in a dispatch
table: *"os.capabilities assumes a mutable package manager. Atomic and declarative hosts
… make you layer, containerize, or rebuild. That breaks the SCHEMA, not a backend."* The
forcing function is external and dated: *"whether this lands well decides whether the
fleet is still installable on a 2031 desktop"* — Fedora, openSUSE and the desktop-Linux
mainstream are moving their defaults toward image-based delivery, and the fleet's Fedora
and openSUSE repos target the mutable editions of both.

What this document does **not** do is propose the schema change. §4 sketches the shape
the milestone suggested — a `PROVISIONER` axis, `up` learning the three update verbs,
bootstrap learning it may not be able to write where it assumes — so that §5 has something
concrete to test. §5 is the deliverable: a research phase with measured exit criteria,
after which this file's status line changes to PROPOSED or CLOSED.

## 2. Current — what Core assumes today, measured

Everything in this section is read off `main` at `v7.4.3` (2026-09-14). It is the
inventory of assumptions the research phase has to test against each target.

### 2.1 The schema and who reads it

`os.capabilities` (`examples/os.capabilities.example`, validated by
`scripts/check-capabilities.sh`) has **eight required keys** and eleven optional ones:

- **Required:** `PKG_REFRESH`, `PKG_UPGRADE`, `PKG_INSTALL`, `PKG_REMOVE`, `PKG_SEARCH`,
  `PKG_OWNS`, `PKG_COUNT_PENDING`, `SCHEDULER` (+ `SCHEDULER_UNIT_DIR`, required for
  `systemd`/`launchd`).
- **Optional, and their absence is a statement:** `PKG_ASSUME_YES` (absent → never
  auto-confirm), `PKG_UPGRADE_PARTIAL` (absent → `up -i` refuses), `MAINT_UNATTENDED_UPGRADE`
  (absent → refuse), `PKG_UPGRADE_PRE`, `PKG_CLEANUP`, `PKG_COUNT_REFRESH`,
  `PKG_COUNT_EXIT_TRUSTED`, `PKG_PENDING_MATCH` / `_FIELD` / `_FS`, `TOOLS_OPTIN`.

The readers, by key (`grep _core_cap` across `zsh/` and `maint/`):

| Reader | Keys it reads | What it does with them |
| ------ | ------------- | ---------------------- |
| `zsh/60-update.zsh` (`up`) | `PKG_UPGRADE`, `PKG_UPGRADE_PRE`, `PKG_CLEANUP`, `PKG_ASSUME_YES`, `PKG_UPGRADE_PARTIAL`, `PKG_COUNT_PENDING`, `PKG_COUNT_REFRESH`, `PKG_COUNT_EXIT_TRUSTED`, `PKG_PENDING_*` | runs the upgrade; counts and lists pending updates for the once-a-day nudge |
| `zsh/55-maint.zsh` | `SCHEDULER`, `SCHEDULER_UNIT_DIR` | installs/offers the maint timer (systemd user unit, launchd agent, cron line, or the manual verb for `none`) |
| `zsh/02-capabilities.zsh` | `PKG_INSTALL`, `TOOLS_OPTIN` | `core-doctor`'s install hints; which missing tools are opt-in rather than gaps |
| `maint/dotfiles-maint.sh` (bash) | `PKG_COUNT_PENDING`, `PKG_COUNT_EXIT_TRUSTED`, `MAINT_UNATTENDED_UPGRADE`, `PKG_UPGRADE` | the unattended runner: counts pending, upgrades only when the declaration allows |

Every required verb is an **imperative** that acts on the running system and returns when
the change is live. That is the assumption an atomic host breaks: `rpm-ostree install`
returns with the change *staged*, and nothing is different until reboot.

### 2.2 What the fleet declares

The seven Unix repos, `PKG_INSTALL` | `PKG_UPGRADE` | `SCHEDULER` (read from each
repo's `os/*.capabilities`):

| Repo | `PKG_INSTALL` | `PKG_UPGRADE` | `SCHEDULER` |
| ---- | ------------- | ------------- | ----------- |
| Fedora | `sudo dnf install -y` | `sudo dnf upgrade --refresh` | `systemd` |
| Arch | `sudo pacman -S --noconfirm` | `sudo pacman -Syu` | `systemd` |
| Debian | `sudo apt-get install -y` | `sudo apt-get full-upgrade` | `systemd` |
| openSUSE | `sudo zypper in` | `sudo zypper dup` | `systemd` |
| Alpine | `doas apk add` | `doas apk upgrade` | `cron` |
| Gentoo | `sudo emerge` | `sudo emerge -auvDN @world` | `cron` |
| MacBook | `brew install` | `brew upgrade` | `launchd` |

Two of the three target families map onto **existing repos' distributions** — Silverblue
is Fedora, Aeon is openSUSE — which is the first shape question (§5 R4): a *variant* of an
existing repo, or a new one.

### 2.3 What bootstrap assumes it can write

The driver (`lib/bootstrap-lib.sh :: blib_main`, `V8-PROPOSAL.md` §4.2) and the hooks the
eight repos define assume:

- **An escalator exists and package installs are synchronous.** `blib_resolve_su` finds
  `sudo`/`doas`, `blib_sudo_keepalive_start` keeps it warm through a long
  `bootstrap_provision`, and every repo's provision body is `<escalator> <PKG_INSTALL>
  <list>` followed by tools that expect the packages to be present *now* (the Go builds,
  the cargo fallbacks, `core-doctor`).
- **`/etc` is writable.** `blib_set_login_shell` appends to `/etc/shells` and runs `chsh`;
  `blib_install_system_file` writes system files under the escalator (`tee`, with a
  backup); Arch and Alpine write `/etc/wsl.conf`; Alpine appends to
  `/etc/apk/repositories` and installs a signing key under `/etc/apk/keys`.
- **`$HOME` is the only place links go.** Every `blib_link` destination is under `$HOME`
  or `$XDG_CONFIG_HOME`; `--links-only` needs no escalator at all. This is the part that
  is expected to *survive* every target unchanged — and is the first thing §5 R1 measures.
- **Tools land on `PATH` by package.** `core-doctor`'s `HAVE_*` probes and the shell's
  `00-tools.zsh` detection read `PATH`; user-local bindirs (`~/.local/bin`, `~/.cargo/bin`,
  GOBIN) are prefixed by the shell layer and, since #748, by the bootstrap prelude. A host
  where CLI tools live in a toolbox, a Flatpak sandbox, or `/run/current-system/sw/bin`
  changes what "installed" means to the doctor.

### 2.4 The gates that would see a new target

- `scripts/check-capabilities.sh` and audit `§9c` — validate every `os/*.capabilities`
  against **one** schema; a new required key fails all nine declarations until they
  re-author, which is the "breaking because the schema versions" argument.
- `scripts/gen-porting-matrix.sh` — renders `PORTING-MATRIX.md`'s package-manager table
  *from* the fleet's declarations; a new axis is a new column.
- `.github/workflows/bootstrap-test.yml` — the reusable links-only + stubbed-provision
  legs run in a container image each repo names (`archlinux:latest`, `alpine:3.24`, …);
  an image-based target has a container image (`quay.io/fedora/fedora-bootc`) but its
  package verb needs the `rpm-ostree` daemon, which a container does not run; MicroOS's
  `transactional-update` needs btrfs snapshots, which a container cannot do at all.
- audit `§5f`/`§5h` and the vocabulary register — a new repo must be born on the driver
  and the `make` vocabulary; `scripts/new-os-repo.sh` now writes both (#999).

## 3. What each target is expected to break — pre-research

**Everything in this section is an expectation to be verified in §5 R1, not a finding.**
It is written down first so the research has hypotheses to confirm or refute.

| Assumption (§2) | Silverblue / bootc | Aeon / MicroOS | NixOS |
| --------------- | ------------------ | -------------- | ----- |
| `PKG_INSTALL` is synchronous | **Breaks.** `rpm-ostree install` layers into the *next* deployment; live-apply exists (`--apply-live`) but is partial. Homebrew/toolbox installs are synchronous but not "the package manager" | **Breaks.** `transactional-update pkg in` lands in a snapshot; nothing is live until reboot | **Breaks the model.** The verb is "edit the declaration and rebuild"; `nix profile install` is imperative but is not how a NixOS box is meant to be managed |
| `PKG_UPGRADE` returns with the box updated | **Breaks.** `rpm-ostree upgrade` / `bootc upgrade` stage; reboot applies | **Breaks.** `transactional-update dup` stages; reboot applies | **Holds** for `nixos-rebuild switch` (activates live); `home-manager switch` likewise |
| `PKG_COUNT_PENDING` lists packages | **Different question.** "Is a newer image staged/available?" (`rpm-ostree upgrade --check`, `bootc upgrade --check`) — the answer is one deployment, not N packages | **Different question.** `transactional-update --dry-run dup`? (to verify) | **Different question.** A flake input behind its lock, or a channel behind |
| `PKG_UPGRADE_PARTIAL` (`up -i`) | **Absent by construction** — atomic means whole-image; the schema already models "absent = refuses" | Same | Same |
| `/etc` writable: `chsh`, `/etc/shells`, `blib_install_system_file`, `wsl.conf` | **Mostly holds.** `/etc` is a writable 3-way merge on ostree; `chsh` works. Expect to verify `/etc/shells` and the merge on upgrade | **Holds with a caveat.** `/etc` is an overlay; writes made outside a transaction may be lost on the next snapshot rollback (to verify) | **Breaks.** `/etc` is generated; the login shell is `users.users.<name>.shell`; a hand edit does not survive a rebuild |
| Escalator + keepalive | **Holds** (`sudo` present) | **Holds** (`sudo`) | **Holds** (`sudo`), but there is nothing to escalate *for* if provisioning is declarative |
| Tools on `PATH` by package | **Partially breaks.** Layered RPMs land in `/usr/bin`; toolbox/distrobox tools are not on the host `PATH` (distrobox can export); Homebrew is under `/home/linuxbrew` | **Partially breaks**, same shape; distrobox is the documented answer | **Holds** for declared packages (`/run/current-system/sw/bin`, `~/.nix-profile/bin` are on `PATH`) |
| `SCHEDULER=systemd`, user units | **Holds** | **Holds** | **Holds** — but the *declarative* way is `systemd.user.services` in the config, and a hand-installed unit under `~/.config/systemd/user` still works |
| `--links-only` bootstrap (all of `$HOME`) | **Expected to hold unchanged** | **Expected to hold unchanged** | **Expected to hold unchanged** — unless `home-manager` owns the same files (§5 R3) |
| `bootstrap-test.yml` container legs | **Partially.** links-only and stubbed provision run in `fedora-bootc`; the real verb needs a VM | **links-only only** in a container; the verb needs a VM with btrfs | **links-only** in `nixos/nix`; a real host needs `nixos-rebuild build-vm` |

The row that matters most is the first: **the schema's verbs are imperative and
synchronous, and on two of three targets the truth is "staged, reboot to apply."** That
is a *semantic* break, not a spelling one — which is what makes it a schema question.

## 4. Candidate shape — the milestone's sketch, made concrete enough to test

Not a proposal. The milestone suggested three moves; here they are as testable
statements, each with the additive-vs-breaking question attached (§5 R2 settles it).

1. **A `PROVISIONER` axis:** `PROVISIONER=mutable | atomic | declarative`. Absent means
   `mutable` (so every existing declaration is unchanged — **additive if it stays optional**).
   Consumers branch on it: `up` prints "staged — reboot to apply" and offers the reboot
   verb after an `atomic` upgrade; `core-doctor` reports a missing tool with the
   target's own install path (`rpm-ostree install`, `distrobox`, "add to `home.nix`")
   rather than `PKG_INSTALL`; `blib_set_login_shell` declines on `declarative` with the
   declaration to add.
2. **`up` learns the three update verbs.** Mostly *no schema change*: `PKG_UPGRADE=sudo
   rpm-ostree upgrade`, `PKG_COUNT_PENDING=rpm-ostree upgrade --check` already fit the
   existing keys; what does not fit is the *meaning* of the count (one image, not N
   packages) and the *reboot* that follows. A `PKG_APPLY` key (the reboot/switch verb) and
   a `PKG_PENDING_KIND=packages|image` hint may cover it — both optional.
3. **Bootstrap learns it may not be able to write.** A `BOOTSTRAP_PROVISIONER` declaration
   the driver reads: on `atomic`, run `bootstrap_provision` and then say "layered — reboot,
   then re-run for the tools that need them" (a two-phase bootstrap, idempotent by
   construction because every step already is); on `declarative`, skip provisioning,
   print the declaration the repo ships (`nix/home.nix`?), and wire links only.
   `blib_install_system_file` and `blib_set_login_shell` get a "cannot on this host" arm
   with the target's own instruction — the exact shape `blib_login_shell_hint` already
   has for a repo that declines to `chsh`.

**Where the breaking version hides.** If R1 shows that a *required* verb is wrong on
these hosts — that `PKG_INSTALL` cannot honestly be filled in for a declarative host at
all, say — then the schema needs a required key to change meaning or a required key to
become conditional on `PROVISIONER`, and every one of the nine declarations re-authors
under a `CAP_SCHEMA_VERSION`. That is the major. If R1 shows the required verbs can be
filled honestly on all three and only the *consumers* need to learn the new keys, the
whole thing is a minor with three new repos, the way the v8 content turned out to be.

## 5. The research phase

Six research items, each with a deliverable, measured on real hosts, before any code
changes to Core. Timebox: **three weeks of calendar time**, revisited if a host cannot be
stood up. Findings are recorded **in this file** under each item, the way `V8-PROPOSAL.md`
§6 carried its outcomes inline.

### R1 — Stand up the three hosts and run the fleet against them, unchanged

- **Hosts:** Fedora Silverblue **42** or a `bootc` image (`quay.io/fedora/fedora-bootc:42`
  as a VM, not a container — the verb needs the daemon); openSUSE **Aeon** (or MicroOS
  with a desktop) as a VM with btrfs; NixOS **25.05** via `nixos-rebuild build-vm` from a
  minimal configuration. Disposable, scripted, reproducible — the recipe goes in
  `scripts/research/` beside `verify-atuin-guard.sh`, so it can be re-run.
- **Runs, per host:** `dotfiles-Fedora` (on Silverblue), `dotfiles-openSUSE` (on Aeon),
  and a scaffolded `dotfiles-NixOS` from `new-os-repo.sh` (on NixOS) — first `--links-only`,
  then `--dry-run`, then a real run — recording every step that fails, warns, or lies
  (exits 0 having done nothing).
- **Deliverable:** §3's table with every cell replaced by a measurement, and the list of
  lib functions that need a `PROVISIONER` arm. Expected headline: links hold everywhere;
  provisioning and the login shell break exactly where §3 says.

### R2 — Additive or breaking?

- Prototype `PROVISIONER` as an **optional** key on a branch; fill in a full declaration
  for each host honestly, using only existing keys plus the optional ones §4 sketches.
- **The test:** does any *required* key end up with a value that is a lie on any host? If
  `PKG_INSTALL` must be filled with something that does not install (NixOS), or
  `PKG_COUNT_PENDING` with something that counts the wrong thing without a hint the
  consumer reads, the schema versions. If every required key can be filled truthfully and
  only consumers change, it is additive.
- **Deliverable:** a one-paragraph verdict with the three declarations attached, and —
  if breaking — the schema diff and the count of keys each of the nine repos re-authors.

### R3 — The Nix answer, on the record

The milestone asks for it explicitly: *"home-manager already does declarative per-host
layering natively, and this repo's habit is to document its rejections."*

- Build a `home.nix` that reproduces what `blib_link_core` + the Fedora layer wire, on
  NixOS and on one mutable host (Fedora) — measure how much of Core it can *own* (links,
  packages, the zsh entry) and what it cannot (the numbered-fragment loader, the
  capability contract, `core-doctor`, the tmux/nvim trees as symlinks into a vendored
  `core/`).
- Three possible answers, each acceptable if measured: **adopt** (home-manager becomes
  the declarative provisioner and the fleet's link step on every host), **coexist**
  (home-manager owns packages on NixOS; the driver owns links everywhere; the NixOS repo
  ships both), **reject** (with the measured reason). The expected answer is coexist;
  the point is to have the reason written down.
- **Deliverable:** the paragraph, plus the `home.nix` kept under `scripts/research/`.

### R4 — Repo shape: variant or new repo?

- Silverblue is Fedora (`ID=fedora`, `VARIANT_ID=silverblue`); Aeon is openSUSE
  (`ID=opensuse-aeon`? — to verify). The existing repos' OS guards match `ID`; the
  package lists and `os/*.zsh` layers are 90% right on the atomic edition.
- Options: (a) the existing repo grows a variant — `os/fedora.capabilities` +
  `os/fedora-silverblue.capabilities`, chosen by `VARIANT_ID`, and `bootstrap_guard`
  learns the pair; (b) a new repo per target, scaffolded by `new-os-repo.sh`, vendoring
  Core like the other nine. Measure: how many lines differ between a working Silverblue
  declaration + provision hook and Fedora's today. Under ~150 → variant; above → repo.
  NixOS is a new repo either way.
- **Deliverable:** the diff counts and the recommendation. This also decides whether
  `scripts/os-repos.txt` grows by one or by three, which sets the fan-out cost.

### R5 — `up` and the maint runner on a staged host

- What does the once-a-day nudge say on a host with a staged deployment? What does
  `MAINT_UNATTENDED_UPGRADE` mean when the upgrade needs a reboot the runner must not
  perform? Measure `rpm-ostree upgrade --check`, `bootc upgrade --check`,
  `transactional-update --dry-run`, and a flake-lock check for exit codes, output shape,
  and cost — the same fields `PKG_COUNT_*` and `PKG_PENDING_*` already model.
- **Deliverable:** the declarations for the three, and the list of consumer changes in
  `60-update.zsh` and `maint/dotfiles-maint.sh` — with the "reboot to apply" line
  designed, since it is the one user-visible change on every atomic box.

### R6 — What CI can hold

- Which of the reusable legs run where: `bootstrap-test.yml`'s links-only and
  stubbed-provision in `fedora-bootc` and `nixos/nix` containers (expected: yes);
  `packages_check` against `rpm-ostree` without the daemon (expected: no — fall back to
  `dnf --installroot`-style resolution or `rpm -q --whatprovides` against the image);
  anything at all for MicroOS in a container (expected: links-only only).
- **Deliverable:** the CI matrix a new target repo is born with, and the gap list — what
  only a VM can test, and therefore what the register must mark *not covered* rather
  than green.

### Findings so far — documentation, 2026-09-14 (before any host was measured)

Read off the upstream manuals while the first R1 harness run was in flight (the harness
is `scripts/research/nonmutable-host.sh` + `.github/workflows/research-nonmutable.yml`,
landed in #1005). These are what the tools *document*, not what a host *did*; each is
re-checked by R1's probes and marked measured when it is.

**rpm-ostree / bootc (R5).** The verbs the schema would call already exist and already
model "staged" as a first-class state:

- `rpm-ostree upgrade --check` — *"just check if an upgrade is available, without
  downloading it or performing a package-level diff"*; `--unchanged-exit-77` — *"exit
  status 77 to indicate that the system is already up to date. This tristate return
  model is intended to support idempotency-oriented systems automation tools like
  Ansible"*; `rpm-ostree status --pending-exit-77` — *"exit status 77 if a pending
  deployment is available."* `rpm-ostree install` *"has no effect on your running system,
  and will only take effect when you reboot"*; `-A`/`--apply-live` exists. *"The only
  writable directories are `/etc` and `/var`"*; at upgrade *"the process takes the new
  default `/etc`, and adds your changes on top."* ([man/rpm-ostree.xml][rpo],
  [administrator handbook][rpo-hb])
- `bootc upgrade` — *"Download and queue an updated container image to apply. This does
  not affect the running system … A queued update is visible as `staged` in `bootc
  status`."* `--check` downloads only the manifest; the update is applied at shutdown by
  `ostree-finalize-staged.service`, or by `bootc upgrade --apply`, which *"currently always
  reboots the system"* (`--soft-reboot=auto` where available); `--download-only` /
  `--from-downloaded` split staging from applying. ([bootc-upgrade(8)][bootc])
- **What this means for the schema.** `PKG_COUNT_PENDING=rpm-ostree upgrade --check
  --unchanged-exit-77` answers with **exit 77 = nothing pending, exit 0 = an update is
  available** — an exit code that *means* "none", the dnf-exits-100 shape inverted. The
  schema's `PKG_COUNT_EXIT_TRUSTED` says "non-zero = could not answer", which would read
  77 as *unknown*. So even the additive path needs one more optional key — a
  `PKG_PENDING_EXIT_NONE=77` (an exit status meaning "none pending") — or the count verb
  is wrapped. First schema gap, found before a host was touched. A `PKG_APPLY` verb has an
  obvious value on both (`bootc upgrade --apply`, `systemctl reboot`).

**transactional-update (R5, R1).** `pkg install`/`pkg in` install into a new snapshot;
`dup` is `zypper dup --no-allow-vendor-change` and `up` is `zypper up`, both *into the
snapshot*, both needing a reboot to activate. **There is no dry-run or check mode** —
so `PKG_COUNT_PENDING` cannot be a `transactional-update` verb at all; it would be plain
`zypper --non-interactive lu` (read-only against the running system's repo cache — to
verify it works on the read-only root). `apply` *"mounts /usr, /etc and /boot of the (new)
default snapshot into the currently running system"* but *"is not one atomic operation"*
and services are not restarted. Exit codes: 0 ok, 1 a command failed and the snapshot was
deleted, 2 `apply` failed. `/etc` is an overlay per snapshot under `/var/lib/overlay`:
*"configuration file changes applied to the currently running system will be visible in
the new system, but not vice versa"*, with a documented loss case when a file changes both
during an update and afterwards in the running system — the caveat §3 guessed at, and the
reason `blib_install_system_file` and `chsh` on MicroOS need R1's real run, not a container.
([transactional-update(8)][tu])

**NixOS (R3, R1).** `users.users.<name>.shell` — *"The path to the user's shell … Don't
forget to enable your shell in `programs` if necessary, like `programs.zsh.enable =
true;`"* — and an assertion refuses a shell whose `programs.<shell>.enable` is false
(*"might make logging in as that user impossible"*). `/etc/shells` is generated from the
configured users' shells. `users.mutableUsers` (default true) merges the existing
`/etc/passwd` with the generated one on activation — so a `chsh` may *work* and then be
reverted or contradicted by the next `nixos-rebuild switch`; which, is exactly what R1's VM
leg measures. `blib_set_login_shell` on NixOS therefore prints the declaration rather than
running `chsh`, as §4(3) sketched — and the declaration is two lines, not one.
([nixpkgs users-groups.nix][nix])

**Repo shape (R4).** Aeon's `/etc/os-release` reads `ID="opensuse-aeon"` with
`ID_LIKE="suse opensuse opensuse-tumbleweed opensuse-microos microos"`
([openSUSE bug 1228361][aeon-id]); Silverblue is `ID=fedora` with `VARIANT_ID=silverblue`
(to verify on the host). `dotfiles-Fedora`'s guard matches on `ID=fedora`, so Silverblue
passes it unchanged; `dotfiles-openSUSE`'s matches `ID=opensuse*`, which `opensuse-aeon`
satisfies — both existing repos will *run* on their atomic editions and reach the
provisioning verb before anything refuses. That is the case for the **variant** shape
(R4 option a) before a line is diffed; the diff count decides.

[rpo]: https://github.com/coreos/rpm-ostree/blob/main/man/rpm-ostree.xml
[rpo-hb]: https://coreos.github.io/rpm-ostree/administrator-handbook/
[bootc]: https://github.com/bootc-dev/bootc/blob/main/docs/src/man/bootc-upgrade.8.md
[tu]: https://kubic.opensuse.org/documentation/man-pages/transactional-update.8.html
[nix]: https://github.com/NixOS/nixpkgs/blob/nixos-25.05/nixos/modules/config/users-groups.nix
[aeon-id]: https://lists.opensuse.org/archives/list/bugs@lists.opensuse.org/message/JCQCE4KZE6VRZIOQQNSF4W4C7D2B4CXV/

### Exit criteria

The research phase is done when this file carries, under R1–R6, measured answers and:

1. a **verdict** — additive (minor: new keys, new repos, consumers learn them) or breaking
   (the schema versions, nine re-authors, a major);
2. the **three declarations** as they would ship, validated by `check-capabilities.sh`;
3. the **lib change list** with each function's new arm named;
4. the **repo-shape decision** (R4) and the **Nix decision** (R3) recorded.

Then this file's status line changes to PROPOSED, §4 is rewritten as a proposal with a
"What breaks" section and a per-repo runbook, and the milestone's issues are filed from it.

## 6. What breaks — if it is the major

Recorded now so the cost is visible before the research decides whether to pay it.

- **Every OS repo re-authors `os/*.capabilities`** under a versioned schema; the
  fan-out's audit (`§9c`) is red fleet-wide until they do — the same coordinated event
  `V5-PROPOSAL.md` §9 planned and never had to run. The v5 migration runbook is the
  template.
- **`PORTING-MATRIX.md`'s generated table** gains a column and the footnotes gain three
  targets' package availability — `/os-package-availability` does the footnotes.
- **`bootstrap-test.yml`** grows a `provisioner` input so a stubbed provision on an atomic
  image stubs `rpm-ostree` too, and the register learns that some legs are VM-only.
- **`new-os-repo.sh`** stamps the new key in its capability stub (which today copies
  Fedora's dnf verbs and says so).

## 7. Non-goals

- **Windows.** `dotfiles-Windows` vendors no `core/` and has no capability declaration;
  nothing here changes that.
- **Containers as the fleet's home** (toolbox/distrobox as the primary target). A
  container is a mutable host inside an immutable one; the existing repos already work
  there. The question this document asks is about the *host*.
- **Replacing the vendoring model with Nix.** R3 may find home-manager can own more than
  expected; even then, `core/` stays the vendored source of truth and `core.lock` the
  provenance. A declarative provisioner is a provisioner, not a distribution mechanism.
- **The nvim split.** Its own document, `NVIM-SPLIT-PROPOSAL.md`.

## 8. Open questions

1. **Does the escalator model survive `declarative`?** If nothing needs root on NixOS,
   `BOOTSTRAP_SU=lazy` (Offense's shape) may already be the answer — a repo whose hook
   never escalates.
2. **Is "reboot to apply" a bootstrap concern or an `up` concern, or both?** The two-phase
   bootstrap in §4(3) assumes both; R1 says whether the second phase is needed in practice
   (layered RPMs *are* visible after reboot, so phase two may be "just re-run").
3. **Homebrew-on-Linux as the atomic CLI answer.** Both Fedora's and openSUSE's atomic
   editions point at it for CLI tools. If R1 finds it covers `install/packages.txt` on
   both, the atomic declaration may be `PKG_INSTALL=brew install` — MacBook's row — and the
   "schema break" shrinks to `PKG_UPGRADE` and the reboot. That would be a finding worth
   the whole phase.
4. **Which Fedora?** Silverblue (GNOME) vs Kinoite vs a plain `bootc` server image; the
   package list differs, the provisioning model does not. Pick the one the author would
   run.
