# Non-mutable host proposal — the fleet on a box it cannot write to

> **Status: RESEARCH (opened 2026-09-14). Nothing is decided, nothing is scheduled, and no
> consumer changes until §5's research phase reports — R1 has measured all three hosts and R2
> has its verdict (additive; four optional keys and one conditional rule, prototyped and
> validated); R3–R6 are open.** This is the planning document for the
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

### R1 findings — rung one, containers (2026-09-14, run 34811939804)

The harness ran on `main` at v7.4.3 (dotfiles-Fedora at v7.4.3; the NixOS repo scaffolded
by `new-os-repo.sh` with this Core seeded). Reports: the `r1-*` artifacts of that run.
**Everything below is a container, not a booted host** — what a container can and cannot
say is itself the first finding.

**bootc (`quay.io/fedora/fedora-bootc:42`, dotfiles-Fedora unchanged).**

- *What the image is.* `ID=fedora`, `VERSION_ID=42`, **no `VARIANT_ID`** in the bootc base
  image (Silverblue's is set by its own image build — R1's VM leg checks). `rpm-ostree`,
  `bootc`, `dnf`, `toolbox` present; `flatpak`, `distrobox`, `brew` absent. `/usr`, `/etc`,
  `/var` all writable (a container; the read-only `/usr` is a property of the *deployed*
  host). `sudo`, `chsh`, `getent`, `zsh` present; `/etc/shells` already lists zsh.
- *The verbs.* `bootc status` **works in a container** (exit 0, reports the image) —
  `bootc upgrade --check` refuses: *"Detected container; this command requires a booted
  host system"* (exit 1). Every `rpm-ostree` verb refuses: *"This system was not booted via
  libostree"* (exit 1). `dnf5 5.2.18` works. **So the update verbs cannot be measured in a
  container at all** — R5 is VM-only, as expected; `bootc status` is the one read-only probe
  a container can answer and is how a provisioner could detect "bootc image" at build time.
- *The driver, unchanged.* `--help`, `--links-only` (34 links, the managed `~/.zshrc`), and
  `--dry-run` (38-package plan, wrote nothing) all exit 0. The **real run exits 0** and
  installs the whole list through `dnf` — which is the image-build path, exactly the case
  §3 said a container would show; it says nothing about a deployed Silverblue.
- *Two things worth recording anyway.* (1) `--links-only` **changed root's login shell**
  (`chsh` ran, "Shell changed"): with `BLIB_SU=` set and `chsh` present the driver's login-
  shell step is not gated on `--links-only`, only on the escalator — on a NixOS host that
  step would fight the declaration; on any host it is a system write inside a "links only"
  run. Worth a `BOOTSTRAP_LOGIN_SHELL` re-read for the atomic/declarative arm (§4(3)).
  (2) Fedora 42's repos installed **`neovim` 0.11.5** and **`tree-sitter-cli` 0.25.10** —
  both *below* the fleet's floors (≥ 0.12.0, ≥ 0.26.1; `PORTING-MATRIX.md` ³³ and ⁵). A
  side finding for the matrix, not for this proposal, filed separately.

**NixOS (`nixos/nix:latest`, a scaffolded `dotfiles-NixOS`).**

- *What the image is.* **No `/etc/os-release`**, no `sudo`/`doas`/`chsh`/`getent`/`zsh`, no
  `/etc/shells`, no `/run/current-system` — this is a mutable container carrying `nix`
  2.35.2 and `nix-env`, not NixOS. The prep's `nix-env -iA nixpkgs.zsh …` did not land a
  `zsh` (the image's channel layout differs; to fix in the harness), so the tool-detection
  half is unmeasured here. **Nothing about NixOS-the-host is learned from this image**; the
  leg proves only the scaffold and the driver on a bare box.
- *The driver, unchanged.* The `new-os-repo.sh` starter (driver form, #999) works
  end-to-end on it: `--help`, `--links-only` (28 links, the managed `~/.zshrc`, the guard
  installed), `--dry-run` (wrote nothing), real run — all exit 0, and with
  `BOOTSTRAP_LOGIN_SHELL=0` **no login-shell step ran** (the `chsh`-less host was never
  asked). This is the shape the NixOS repo would start from; the declaration and the
  provisioner arm are what it lacks.

**MicroOS / Aeon.** **There is no MicroOS container image.** `registry.opensuse.org`
serves `opensuse/tumbleweed`, `opensuse/leap` and the BCI set; every plausible
`opensuse/microos*` / `opensuse/aeon` name is HTTP 404 (measured). That is a finding in
itself — MicroOS *is* the booted-host transaction, and the project ships it as a disk
image only. The leg re-ran as **Tumbleweed with the `transactional-update` package**
(run 34816013743), a labelled stand-in: `transactional-update` 6.1.3 is present and
`snapper list` fails at once (*"org.freedesktop.DBus.Error.FileNotFound"* — no snapper
daemon, no btrfs, nothing to transact); `findmnt` is absent from the base image; no
`sudo`/`doas` in the image but `chsh`, `getent`, `zsh` present. `dotfiles-openSUSE` at
v7.4.4 held its guard (`ID="opensuse-tumbleweed"`, `ID_LIKE="opensuse suse"`),
`--links-only` (34 links) and `--dry-run` (wrote nothing) exit 0; the real run **exits 2**
— openSUSE's declared exit-on-any-miss (`BOOTSTRAP_FAIL_EXIT=2`) after optional installs
that a container cannot complete, which is the contract working, not a target finding.
The qcow2 VM is the only real MicroOS measurement.

**What rung one settles.** (1) `--links-only` and `--dry-run` hold unchanged on both
images — the `$HOME`-only half of the fleet survives, as §3 expected. (2) The update verbs
are unmeasurable without a booted host, on both families that have them; R5 moves entirely
to the VM legs. (3) One driver behaviour to reconsider regardless of target: the
login-shell step runs inside `--links-only`. (4) The scaffold is ready to become
`dotfiles-NixOS` the day the declaration exists.

**Rung two (next):** the VM legs — a bootc disk built from the same image
(`bootc-image-builder` → qcow2 → QEMU/KVM on `ubuntu-latest`), the Aeon/MicroOS qcow2
from `download.opensuse.org`, and `nixos-rebuild build-vm` — each running the same script
over ssh, each answering §3's first three rows for real.

### R1 findings — rung two, booted hosts (2026-09-14, run 34819015395)

Three VMs on `ubuntu-latest`'s KVM (`research-nonmutable-vm.yml`): a **bootc** disk built
from `fedora-bootc:42` with `bootc-image-builder`, the **MicroOS** OpenStack-Cloud qcow2
with a cloud-init seed, and a **NixOS 25.05** guest from `nixos-rebuild build-vm`. Same
script, over ssh. These are the measurements §3 asked for.

**MicroOS (`ID="opensuse-microos"`, `ID_LIKE="suse opensuse opensuse-tumbleweed microos
sl-micro"`; `/` is btrfs **ro**, snapshot subvolume; `/usr` not writable, `/etc` `/var`
`/home` `/root` writable).**

- **The transactional round trip, measured.** `transactional-update -n pkg install git zsh
  …`: opened snapshot 2 from 1, ran `zypper -R <snapshot> install` inside it, closed it —
  *"New default snapshot is #2 … Please reboot your machine to activate the changes"* —
  **21 s wall**, exit 0. Before the reboot `command -v git zsh` found nothing; after it,
  both. §3 row 1 (**`PKG_INSTALL` is synchronous: breaks**) is measured, and the shape of
  the two-phase bootstrap §4(3) sketched is exactly this.
- **The declared verb is refused outright.** `dotfiles-openSUSE` unchanged, guard passed
  (`opensuse` is in `ID`), `--links-only` (34 links) and `--dry-run` exit 0 — and the
  **real run exits 2**: every `zypper in` answers *"Transactional system detected: A
  transactional-wrapper command is not installed. Please use transactional-update to
  modify or update the system"* (rc 5), the per-package fallback records each as a miss,
  and openSUSE's exit-on-any-miss contract fires. So `PKG_INSTALL=sudo zypper in` **is a
  lie on this host today**, and the honest value is `transactional-update -n pkg in`. The
  upstream installers that write under `$HOME` (starship's `curl | sh`) succeeded — after
  the run, `zsh git starship` were on `PATH`. **`chsh` works** (login shell → zsh) and
  `/etc/shells` is writable — the `/etc` overlay holds for this; whether it survives the
  next `transactional-update dup` is R1's remaining MicroOS question.
- `snapper list` works on the host (it could not in a container); `transactional-update`
  6.1.3; `sudo` present.

**bootc (Fedora 42 bootc, `ID=fedora`, no `VARIANT_ID`; as the user: `/usr` `/etc` `/var`
`/home` `/opt` all NOT writable, only `/var/home/<user>`; as root: `/etc` `/var` `/home`
writable, `/usr` `/opt` not).**

- **The update verbs, from a user session.** `rpm-ostree status` and `rpm-ostree status
  --pending-exit-77` answer as the user (exit 0, *"State: idle"*, nothing pending);
  `rpm-ostree upgrade --check` needs authorisation (*"AutomaticUpdateTrigger not allowed
  for user"*); `bootc status` and `bootc upgrade --check` **require root**. As root
  `bootc status` answers; `upgrade --check` fails because this disk's origin is the local
  image it was built from (*"pinging container registry localhost"*) — a registry-backed
  Silverblue image is needed for that one (`bootc switch quay.io/fedora/fedora-bootc:42`
  first; next iteration). So the count verb for `up` is **`rpm-ostree status
  --pending-exit-77`** (user-runnable, exit 77 = pending) with `rpm-ostree upgrade --check`
  behind `sudo` for the "is there one" question — both already modelled by
  `PKG_COUNT_PENDING` + the `PKG_PENDING_EXIT_NONE` gap §5's documentation findings named.
- **The driver, as the user.** `--links-only`: 34 links, and **`chsh` ran and succeeded
  without sudo** (*"Changing shell for research. Shell changed."*) — the setuid `chsh`
  edits `/etc/passwd` on a host where the user cannot write `/etc`. `--dry-run` wrote
  nothing. The **real run exited 1 at the sudo keepalive**: *"sudo: a terminal is required
  to read the password … sudo authentication failed — cannot provision packages"* — a
  harness fact (the layered `sudoers.d` drop-in did not take on the deployed host; the
  next iteration grants it after boot), but also a real one: the driver's keepalive has no
  askpass path, so a non-interactive run on any host with a passworded sudo stops there.
- **The driver, as root.** The real run **exits 1 inside `dnf`** after resolving the full
  38-package transaction — the report's 6 KB cap cut the refusal itself (fixed: head and
  tail are kept now); rung-two iteration 2 records the exact message. Root's login shell
  moved to zsh; `/etc/shells` gained the entry.

**NixOS 25.05 (`ID=nixos`, `VARIANT_ID=""`; everything "writable" to root — `/etc` is a
real directory of generated links, rebuilt on `switch`; `sudo`, `chsh`, `getent`, `zsh`
under `/run/wrappers` and `/run/current-system/sw/bin`; `/etc/shells` lists zsh because
`programs.zsh.enable` was declared).**

- **The scaffolded `dotfiles-NixOS` runs clean end to end** on a real NixOS: `--help`,
  `--links-only` (28 links), `--dry-run` (wrote nothing), real run — all exit 0, nothing
  provisioned (no hook), login shell left alone (`BOOTSTRAP_LOGIN_SHELL=0`). This is the
  starting point for the NixOS repo; what it lacks is the declaration and the arm.
- `nix` 2.28.5, `nixos-rebuild` present, `home-manager` absent (not declared). The
  `chsh`-then-rebuild question (does `mutableUsers` keep a hand-set shell across `switch`?)
  is the next iteration's probe; so is `nix profile install --dry-run`, the imperative verb
  the declaration would otherwise name.

**What rung two settles.** (1) On MicroOS the schema's `PKG_INSTALL` is a *refusal*, not a
slow path: the required verb cannot be filled truthfully with zypper → **R2 leans
breaking-or-conditional** for that family unless `transactional-update -n pkg in` plus a
reboot verb is accepted as the honest value (it fits the existing key; the *reboot* is
what the schema lacks). (2) On bootc the user-runnable verbs exist and the read-only tree
bites the provisioner, not the wiring. (3) `--links-only` is clean on all three booted
hosts — the driver's `$HOME` half needs no arm. (4) `chsh` is the one system write that
worked everywhere it was tried, as a user, without an escalator.

### R1 findings — rung two, iteration 3 (2026-09-14, run 34820719480): the refusals, verbatim

- **bootc, as root: `dnf` resolves everything and refuses at the last step.** The
  unchanged `dotfiles-Fedora` run refreshed metadata, added RPM Fusion, resolved the full
  list — *"Transaction Summary: Installing: 317 packages … 394 MiB"* — and then:
  **`Error: this bootc system is configured to be read-only. For more information, run
  bootc --help.`** Exit 1, after several minutes of work. So `PKG_INSTALL=sudo dnf install
  -y` on Silverblue/bootc is not a slow path and not a partial one: it is a refusal that
  arrives *after* the resolution, which is the worst shape for a bootstrap (the run spends
  the cost and gets nothing). The same fact as MicroOS's *"Transactional system
  detected"*, one distribution over — and the second required verb that cannot be filled
  truthfully.
- **bootc, as the user: the layering verb is gated by polkit.** `rpm-ostree install
  --dry-run tmux` → *"rpmostreed OS operation PkgChange not allowed for user"*; likewise
  `upgrade --check` (*AutomaticUpdateTrigger*). `rpm-ostree status` and `status
  --pending-exit-77` remain user-runnable. So an atomic declaration's install and upgrade
  verbs need the escalator like everyone else's, while its *count* verb does not — the
  same split the mutable repos have. (As root, `rpm-ostree install --dry-run` checked out
  the tree and then **exited 134** — an abort, on a disk whose origin is a local image;
  re-check against a registry-backed image before reading anything into it.)
- **bootc, the user pass, again stopped at the keepalive** (*"sudo: a terminal is required
  to read the password"*) — the post-boot `sudoers.d` grant did not change the outcome in
  a fresh session. Iteration 4 records `sudo -l` and pre-warms the ticket in the same
  session; until then the user-with-sudo measurement on bootc is missing, and the driver
  fact stands: **the keepalive has no non-interactive path** (no `SUDO_ASKPASS`, no `-A`),
  so any unattended run on a passworded-sudo host stops at provisioning. Worth a driver
  change regardless of this proposal.
- **NixOS: `chsh` takes.** `chsh -s $(command -v zsh)` as root → `getent passwd` reads
  `/run/current-system/sw/bin/zsh`; `users.mutableUsers` (default true) let it through.
  Whether the next `nixos-rebuild switch` keeps or reverts it is still unmeasured (a
  `build-vm` guest carries no `/etc/nixos/configuration.nix`, so `nixos-rebuild dry-build`
  exits 1 there — harness, not target). `nix profile install` has no `--dry-run`. The
  scaffold's core guard installed once the shipped tree was `chown`ed (git's "dubious
  ownership" had read as "not a git working tree").
- **MicroOS: the closing report is the contract working.** 40 packages *"not available;
  check with: zypper se --provides …"* — every one a *"Transactional system detected"*
  refusal recorded as a miss — plus atuin's installer failing, carapace's RPM install
  refused the same way, op's key import failing; then *"the rest of the box is wired and
  usable … exiting non-zero (this repo exits 2 whenever an optional install did not
  complete)"*. Starship's `curl | sh` landed in `$HOME`. The `zypper lu` / `zypper in
  --dry-run` probes came back exit 105 — **zypper's "exit on signal": the harness piped
  them into `head -1`** and they died of SIGPIPE, so those two cells are unmeasured;
  iteration 4's probes capture to a file first. (`dnf --assumeno`'s 141 in the user pass
  is the same artifact.)

**§3, measured.** The table §3 guessed, with the cells rung two answered:

| Assumption | Silverblue / bootc | MicroOS | NixOS |
| --- | --- | --- | --- |
| `PKG_INSTALL` is synchronous | **Refused** — `dnf` resolves 317 pkgs, then *"configured to be read-only"* (root); `rpm-ostree install` needs polkit (user) | **Refused** — *"Transactional system detected"*, rc 5, every package; `transactional-update pkg in` = 21 s + reboot | Not a verb — the starter provisions nothing; `nix profile install` exists (no dry-run) |
| `PKG_UPGRADE` returns with the box updated | unmeasured (`upgrade --check` needs a registry-backed origin) | measured in the prep: staged, reboot to apply | unmeasured (`switch` needs a config the VM lacks) |
| `PKG_COUNT_PENDING` lists packages | `rpm-ostree status --pending-exit-77` user-runnable, exit 0/77 (a deployment, not N packages) | `zypper lu` — unmeasured (SIGPIPE artifact) | unmeasured |
| `/etc` writable: `chsh`, `/etc/shells`, system files | user: `/etc` **not** writable, `chsh` **works** (setuid); root: `/etc` `/var` writable, `/usr` not | root: `/etc` writable (overlay), `chsh` works, `/usr` not | root: everything writable, `chsh` takes; regenerated on `switch` (per docs) |
| Escalator + keepalive | `sudo` present; **keepalive needs a TTY or askpass** | `sudo` present | `sudo` under `/run/wrappers` |
| Tools on `PATH` by package | layered → `/usr/bin` after reboot (unmeasured); `$HOME` installers land | `$HOME` installers land (starship); packages after reboot | declared → `/run/current-system/sw/bin` (855 entries) |
| `--links-only` holds unchanged | **yes** (34 links, user and root) | **yes** (34) | **yes** (28) |
| Guard accepts the host | `ID=fedora` → yes (no `VARIANT_ID` on the bootc base) | `opensuse` in `ID` → yes | n/a (new repo) |

**R2 lean, after rung two.** Two of three families **refuse** the required `PKG_INSTALL`
verb outright, and the honest replacements (`rpm-ostree install`, `transactional-update
-n pkg in`) both *stage* — the schema has no word for "and then reboot". Filling
`PKG_INSTALL` with the staging verb is truthful only if a `PKG_APPLY` (or the driver's
two-phase run) exists to say what happens next. That is one new optional key plus a
consumer change, **not** a change to a required key's meaning — so the additive path is
still open, and R2's prototype declarations are the next thing to write.

**Still open in R1:** `bootc upgrade --check` against a registry-backed image (`bootc
switch quay.io/fedora/fedora-bootc:42` in the guest first); `chsh` across
`nixos-rebuild switch`; `/etc` edits across `transactional-update dup`; the two zypper
cells; the bootc user-with-sudo pass.

### R2 findings — the prototype declarations (2026-09-14)

Written, validated and kept under `scripts/research/nonmutable/` (`bootc.capabilities`,
`microos.capabilities`, `nixos.capabilities`, and a README with the reasoning). The
validator, `scripts/check-capabilities.sh`, gained the four **optional** prototype keys
they need — `PROVISIONER`, `PKG_APPLY`, `PKG_PENDING_EXIT_SOME`, `PKG_PENDING_EXIT_NONE`
— read by no consumer yet, and one conditional rule: `PKG_COUNT_PENDING` may be absent
when `PROVISIONER=declarative`. The shipped example and every fleet declaration validate
unchanged.

**Verdict: additive.** The R2 test was whether a required key ends up a lie on any host:

- `PKG_INSTALL` / `PKG_UPGRADE` — the mutable verbs are refusals on both atomic and
  transactional hosts (R1, measured), but the honest verbs (`rpm-ostree install
  --idempotent`, `transactional-update -n pkg in`, `rpm-ostree upgrade`,
  `transactional-update dup`) fit the existing keys exactly. What they lack is the next
  step, which **`PKG_APPLY`** (a reboot) supplies. No required key changes meaning.
- `PKG_COUNT_PENDING` — on bootc the truthful user-runnable answer is an **exit status**
  (`rpm-ostree status --pending-exit-77`), which `PKG_PENDING_EXIT_SOME=77` describes;
  on NixOS there is no truthful unprivileged verb, so the key is **absent** and the
  validator allows that for `declarative` — `up` already reads an absent count as the
  silent `-1` sentinel. A validator rule, not a re-author.
- Everything else filled in on all three (`nix-env -i`/`-e`, `nix-locate`, `zypper se`,
  `rpm -qf`, `SCHEDULER=systemd` with a user unit directory — the last measured).

So: four optional keys, one conditional relaxation, consumer changes that branch on them,
and **no schema version, no coordinated re-author of the nine**. The major this proposal
was written to plan does not come from the schema. What the atomic and transactional
families *do* need from Core is behavioural: `up` printing `PKG_APPLY` after a staged
upgrade and counting by exit status; `core-doctor`'s hint saying "layered — reboot to
use"; the driver's provision hook running and then saying the same (the two-phase run of
§4(3)); the maint runner never running `PKG_APPLY`. R4's head start is measured too: the
atomic and transactional prototypes touch **12 and 7 keys** of their mutable siblings'
declarations (18 and 10 changed lines, comment-stripped) — small enough for the variant
shape, and R4 still diffs the bootstrap hooks before deciding.

**Still "to verify" inside the files:** `dnf search` on a booted bootc host;
`rpm-ostree upgrade --check` against a registry-backed image; `zypper -q list-updates` on
the MicroOS guest; `chsh` across `nixos-rebuild switch`.

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
